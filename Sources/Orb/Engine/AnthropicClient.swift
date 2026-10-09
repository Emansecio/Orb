import Foundation

/// Client for the Anthropic Messages API (Claude with an API key, or any Anthropic-compatible gateway).
struct AnthropicClient: LLMClient {
    let baseURL: URL
    /// Asked before every request, so a rotated or refreshed credential is picked up (see `CredentialsProvider`).
    let credentials: CredentialsProvider
    var extraHeaders: [String: String] = [:]
    let session: URLSession
    /// Upper bound on the reply length (the API requires one).
    var maxTokens = 16_000
    /// Also sends the key as `Authorization: Bearer` (gateways that document that header on every route).
    var sendsBearer = false
    /// Whether the last block of the last message gets a cache marker (the tail that the next step of the turn reads).
    var marksTail = true

    static let apiVersion = "2023-06-01"

    /// The Messages format carries the cache markers itself (see `requestBody`).
    var arrangesPromptCache: Bool { true }

    /// A note is about 700 tokens (1,200 leaves room); its request is read once, so it writes no cache for its tail
    /// (a write costs a quarter more than a plain read of the input).
    var forShortReply: any LLMClient {
        var copy = self
        copy.maxTokens = 1_200
        copy.marksTail = false
        return copy
    }

    init(baseURL: URL, credentials: @escaping CredentialsProvider, extraHeaders: [String: String] = [:],
         session: URLSession = .shared) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.extraHeaders = extraHeaders
        self.session = session
    }

    /// A client with one fixed key.
    init(baseURL: URL, apiKey: String?, extraHeaders: [String: String] = [:], session: URLSession = .shared) {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(baseURL: baseURL, credentials: { _ in key }, extraHeaders: extraHeaders, session: session)
    }

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        let provider = baseURL.host() ?? ""
        return ProviderTransport.stream(session: session, credentials: credentials, acceptsEventStream: false, body: {
            try WireEncoder.encode(Self.requestBody(
                model: model, messages: messages, tools: tools, maxTokens: maxTokens, provider: provider, toolChoice: toolChoice,
                stablePrefixTTL: Self.stablePrefixTTL(host: provider), marksTail: marksTail), trailing: Self.trailingKeys)
        }, request: { makeRequest("messages", key: $0) }, mapper: AnthropicStreamAssembler(provider: provider, model: model))
    }

    /// All model ids (follows `has_more` / `last_id` pagination).
    func models() async throws -> [String] {
        var ids: [String] = []
        var after: String?
        for _ in 0..<20 {
            var request = makeRequest("models", key: try await credentials(false))
            var components = URLComponents(url: request.url ?? baseURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "limit", value: "1000")] + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
            request.url = components?.url
            let data = try await ProviderTransport.fetch(request, session: session)
            guard let json = JSONValue.parse(String(decoding: data, as: UTF8.self)), let page = json["data"]?.array else {
                throw LLMError.invalidResponse("lista de modelos ausente")
            }
            ids += page.compactMap { $0["id"]?.string }
            guard json["has_more"]?.bool == true, let last = json["last_id"]?.string else { break }
            after = last
        }
        return Array(Set(ids)).sorted()
    }

    private func makeRequest(_ path: String, key: String?) -> URLRequest {
        // Anthropic takes the key in `x-api-key`; gateways accept it there too.
        var request = ProviderTransport.authorizedRequest(baseURL.appending(path: path), apiKey: nil, headers: extraHeaders)
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if let key, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            if sendsBearer { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        return request
    }
}

// MARK: - Wire format

extension AnthropicClient {
    /// How long a cache entry lives after it was written or last read.
    enum CacheTTL: Sendable, Equatable {
        /// The API's default. Sent without a `ttl` field, so gateways that only know the plain marker accept it.
        case fiveMinutes
        /// `"ttl": "1h"`: costs twice the base price to write (1.25 times for five minutes), reads are the same.
        case oneHour

        var control: JSONValue {
            switch self {
            case .fiveMinutes: .object(["type": .string("ephemeral")])
            case .oneHour: .object(["type": .string("ephemeral"), "ttl": .string("1h")])
            }
        }
    }

    /// Last in the body, so the part that repeats comes first (see `WireEncoder`).
    static let trailingKeys = ["messages", "tool_choice"]

    /// The marker for the conversation's growing tail. It always lives five minutes: a step of a tool loop comes
    /// seconds after the previous one and renews it, and a longer life would double every write for nothing.
    static let ephemeral = CacheTTL.fiveMinutes.control

    /// How long the part that does not change between turns (the tools and the system prompt, thousands of tokens
    /// that every request repeats) is kept. People come back to a conversation after more than five minutes much more
    /// often than after more than an hour, so on Anthropic's own API this part is written once for an hour instead
    /// of again at every return. The tail keeps five minutes, which the API allows (the longer life must come first
    /// in the prompt, and the tools and the system prompt do). Other hosts get the plain marker.
    static func stablePrefixTTL(host: String) -> CacheTTL {
        host == "api.anthropic.com" ? .oneHour : .fiveMinutes
    }

    /// System messages become the top-level `system`; tool results travel as `tool_result` blocks in a user turn;
    /// consecutive turns of the same role are merged (the API expects user/assistant alternation).
    ///
    /// Prompt caching uses explicit markers (the API allows four): the last tool, the system prompt and the last
    /// block of the last message, so each step of a tool loop reads the previous step's prefix from the cache.
    /// The first two live `stablePrefixTTL`, the last five minutes (see `stablePrefixTTL(host:)`).
    /// `provider` is the endpoint's host: reasoning recorded by another endpoint or model is not sent back.
    static func requestBody(model: String, messages: [ChatMessage], tools: [ToolSpec], maxTokens: Int,
                            provider: String = "", toolChoice: ToolChoice = .auto,
                            stablePrefixTTL: CacheTTL = .fiveMinutes, marksTail: Bool = true) -> JSONValue {
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        var turns: [(role: String, blocks: [JSONValue])] = []
        let lastIndex = messages.lastIndex { $0.role != .system }
        for (index, message) in messages.enumerated() where message.role != .system {
            let role = message.role == .assistant ? "assistant" : "user"
            var blocks: [JSONValue] = []
            switch message.role {
            case .tool:
                var result: [String: JSONValue] = ["type": .string("tool_result"), "tool_use_id": .string(message.toolCallID ?? ""),
                                                   "content": toolResultContent(message)]
                if message.isError { result["is_error"] = .bool(true) }
                blocks.append(.object(result))
            case .assistant:
                // Thinking must come back unchanged and first, or the API rejects the turn. This client never turns
                // thinking on, so blocks only exist when the endpoint produced them unasked; with thinking off the
                // API tolerates them in earlier turns but not in a final assistant turn (a prefill), so those are dropped.
                if let trace = message.reasoning, index != lastIndex,
                   trace.isReusable(format: .messages, provider: provider, model: model) {
                    blocks += trace.parts.compactMap(thinkingBlock)
                }
                if !message.content.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string(message.content)])) }
                for call in message.toolCalls {
                    let input = JSONValue.parse(call.arguments).flatMap { value -> JSONValue? in
                        if case .object = value { value } else { nil }
                    } ?? .object([:])
                    blocks.append(.object(["type": .string("tool_use"), "id": .string(call.id), "name": .string(call.name),
                                           "input": input]))
                }
            default:
                if message.images.isEmpty {
                    blocks.append(.object(["type": .string("text"), "text": .string(message.content)]))
                } else {
                    let payload = ImageWire.payload(of: message)
                    blocks += payload.images.map(imageBlock)
                    if !payload.text.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string(payload.text)])) }
                }
            }
            guard !blocks.isEmpty else { continue }
            if turns.last?.role == role { turns[turns.count - 1].blocks += blocks } else { turns.append((role, blocks)) }
        }
        if marksTail, let last = turns.indices.last, let block = turns[last].blocks.last,
           !["thinking", "redacted_thinking"].contains(block["type"]?.string ?? ""),
           case .object(var object) = block {
            object["cache_control"] = ephemeral
            turns[last].blocks[turns[last].blocks.count - 1] = .object(object)
        }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
            "stream": .bool(true),
            "messages": .array(turns.map { .object(["role": .string($0.role), "content": .array($0.blocks)]) }),
        ]
        if !system.isEmpty {
            body["system"] = .array([.object(["type": .string("text"), "text": .string(system), "cache_control": stablePrefixTTL.control])])
        }
        if !tools.isEmpty {
            var specs = tools.map {
                JSONValue.object(["name": .string($0.name), "description": .string($0.description), "input_schema": $0.parameters])
            }
            if case .object(var last)? = specs.last {
                last["cache_control"] = stablePrefixTTL.control
                specs[specs.count - 1] = .object(last)
            }
            body["tools"] = .array(specs)
            if toolChoice == .none { body["tool_choice"] = .object(["type": .string("none")]) }
        }
        return .object(body)
    }

    /// The output of a tool: text, or text followed by the pictures it returned.
    private static func toolResultContent(_ message: ChatMessage) -> JSONValue {
        let text = message.content.isEmpty ? "(sem saída)" : message.content
        guard !message.images.isEmpty else { return .string(text) }
        let payload = ImageWire.payload(of: ChatMessage(role: .tool, content: text, images: message.images))
        return .array([.object(["type": .string("text"), "text": .string(payload.text)])] + payload.images.map(imageBlock))
    }

    private static func imageBlock(_ image: (mediaType: String, base64: String)) -> JSONValue {
        .object(["type": .string("image"), "source": .object([
            "type": .string("base64"), "media_type": .string(image.mediaType), "data": .string(image.base64),
        ])])
    }

    /// A recorded reasoning part as a request block; nil for parts of another kind or without the signature the API checks.
    private static func thinkingBlock(_ part: ReasoningPart) -> JSONValue? {
        switch part.kind {
        case .thinking:
            guard let signature = part.signature, !signature.isEmpty else { return nil }
            return .object(["type": .string("thinking"), "thinking": .string(part.text), "signature": .string(signature)])
        case .redactedThinking:
            guard let data = part.data, !data.isEmpty else { return nil }
            return .object(["type": .string("redacted_thinking"), "data": .string(data)])
        case .encrypted:
            return nil
        }
    }
}

/// Turns Messages API stream events into `LLMEvent`s: text deltas pass through, `tool_use` blocks are assembled
/// from `input_json_delta` fragments and reported once at the end, and thinking blocks (with their signatures) are
/// collected so they can be sent back.
struct AnthropicStreamAssembler: AssemblingMapper {
    static let reasoningFormat = APIFormat.messages
    let provider: String
    let model: String
    private var calls: [Int: ToolCallRequest] = [:]
    private var thinking: [Int: ReasoningPart] = [:]
    private var stop: String?
    private(set) var usage: TokenUsage?
    private(set) var isFinished = false

    init(provider: String = "", model: String = "") {
        self.provider = provider
        self.model = model
    }

    var toolCalls: [ToolCallRequest] { calls.sorted { $0.key < $1.key }.map(\.value) }
    var reasoning: [ReasoningPart] { thinking.sorted { $0.key < $1.key }.map(\.value) }

    /// Why the response ended; a stream that closed before `message_stop` was cut off.
    var stopReason: StopReason {
        guard isFinished else { return .incomplete }
        return Self.stopReason(stop, hasToolCalls: !calls.isEmpty)
    }

    static func stopReason(_ reason: String?, hasToolCalls: Bool) -> StopReason {
        switch reason {
        case "end_turn", "stop_sequence": hasToolCalls ? .toolUse : .done
        case "tool_use": .toolUse
        case "max_tokens": .maxTokens
        case "refusal": .refusal
        case "model_context_window_exceeded": .contextExceeded
        case "pause_turn": .incomplete
        case let other?: .unknown(other)
        case nil: hasToolCalls ? .toolUse : .done
        }
    }

    mutating func ingest(_ event: JSONValue) throws -> [LLMEvent] {
        let index = event["index"]?.int ?? 0
        switch event["type"]?.string {
        case "message_start":
            record(usage: event["message"]?["usage"])
        case "content_block_start":
            guard let block = event["content_block"] else { break }
            switch block["type"]?.string {
            case "tool_use":
                calls[index] = ToolCallRequest(id: block["id"]?.string ?? "call_\(index)", name: block["name"]?.string ?? "",
                                               arguments: "")
            case "thinking":
                thinking[index] = ReasoningPart(kind: .thinking, text: block["thinking"]?.string ?? "",
                                                signature: block["signature"]?.string)
            case "redacted_thinking":
                thinking[index] = ReasoningPart(kind: .redactedThinking, data: block["data"]?.string)
            default:
                break
            }
        case "content_block_delta":
            let delta = event["delta"]
            switch delta?["type"]?.string {
            case "text_delta":
                if let text = delta?["text"]?.string, !text.isEmpty { return [.text(text)] }
            case "input_json_delta":
                calls[index]?.arguments += delta?["partial_json"]?.string ?? ""
            case "thinking_delta":
                thinking[index]?.text += delta?["thinking"]?.string ?? ""
            case "signature_delta":
                if let signature = delta?["signature"]?.string { thinking[index]?.signature = signature }
            default:
                break
            }
        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.string { stop = reason }
            record(usage: event["usage"])
        case "message_stop":
            isFinished = true
        case "error":
            let type = event["error"]?["type"]?.string ?? "error"
            let message = event["error"]?["message"]?.string ?? event.jsonString
            if LLMError.isContextOverflow(message) { throw LLMError.contextExceeded(message) }
            throw LLMError.stream(type: type, message: message)
        default:
            break
        }
        return []
    }

    /// `message_start` carries the input counts; `message_delta` the running output count (and sometimes more).
    private mutating func record(usage: JSONValue?) {
        guard let usage, case .object = usage else { return }
        var total = self.usage ?? TokenUsage()
        if let value = usage["input_tokens"]?.int { total.input = value }
        if let value = usage["output_tokens"]?.int { total.output = value }
        if let value = usage["cache_read_input_tokens"]?.int { total.cacheRead = value }
        if let value = usage["cache_creation_input_tokens"]?.int { total.cacheWrite = value }
        if let value = usage["cache_creation"]?["ephemeral_1h_input_tokens"]?.int { total.cacheWrite1h = value }
        self.usage = total
    }
}
