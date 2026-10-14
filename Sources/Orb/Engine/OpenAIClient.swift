import Foundation

/// Client for OpenAI-compatible Chat Completions APIs (xAI, OpenAI, OpenRouter, Ollama, LM Studio).
struct OpenAIClient: LLMClient {
    let baseURL: URL
    /// Asked before every request, so a rotated or refreshed credential is picked up (see `CredentialsProvider`).
    let credentials: CredentialsProvider
    var extraHeaders: [String: String] = [:]
    /// Keys the provider's prompt cache to this conversation (sent only to OpenAI itself).
    var conversationID: String?
    let session: URLSession

    init(baseURL: URL, credentials: @escaping CredentialsProvider, extraHeaders: [String: String] = [:],
         conversationID: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.extraHeaders = extraHeaders
        self.conversationID = conversationID
        self.session = session
    }

    /// A client with one fixed key.
    init(baseURL: URL, apiKey: String?, extraHeaders: [String: String] = [:], conversationID: String? = nil,
         session: URLSession = .shared) {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(baseURL: baseURL, credentials: { _ in key }, extraHeaders: extraHeaders, conversationID: conversationID,
                  session: session)
    }

    /// OpenAI itself, which accepts `prompt_cache_key`; other compatible servers may reject unknown fields.
    var isOpenAI: Bool { baseURL.host() == "api.openai.com" }
    /// OpenRouter, which takes a top-level `cache_control` (for Claude) and a `session_id` for sticky routing.
    var isOpenRouter: Bool { baseURL.host() == "openrouter.ai" }
    private static let usageHosts: Set<String> = ["openrouter.ai", "api.commandcode.ai", "opencode.ai"]
    /// Only OpenAI itself caches the chat format without markers. OpenRouter caches Claude when the body carries a
    /// top-level `cache_control` (sent below), but this property does not know the model, and claiming a cache for
    /// every OpenRouter model would be wrong for the ones without it.
    var arrangesPromptCache: Bool { isOpenAI }
    /// Servers known to take `stream_options` (local ones may reject it): OpenAI, OpenRouter, Command Code (its docs
    /// show `include_usage`) and OpenCode (whose own client sends it to every OpenAI-compatible endpoint).
    var reportsUsage: Bool {
        isOpenAI || (baseURL.host().map(Self.usageHosts.contains) ?? false)
    }

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        ProviderTransport.stream(session: session, credentials: credentials, body: {
            try WireEncoder.encode(Self.requestBody(
                model: model, messages: messages, tools: tools, includeUsage: reportsUsage,
                promptCacheKey: isOpenAI ? conversationID : nil,
                sessionID: isOpenRouter ? conversationID : nil,
                cacheMarker: isOpenRouter && Self.isAnthropicModel(model),
                toolChoice: toolChoice), trailing: Self.trailingKeys)
        }, request: {
            ProviderTransport.authorizedRequest(baseURL.appending(path: "chat/completions"), apiKey: $0, headers: extraHeaders)
        }, mapper: ChatStreamMapper())
    }

    func models() async throws -> [String] {
        Set(try await modelEntries().compactMap { $0["id"]?.string }).sorted()
    }

    /// The `data` entries of the model list, whole (some servers say more about each model than its id).
    func modelEntries() async throws -> [JSONValue] {
        let data = try await ProviderTransport.fetch(ProviderTransport.authorizedRequest(
            baseURL.appending(path: "models"), apiKey: try await credentials(false), headers: extraHeaders), session: session)
        guard let entries = JSONValue.parse(String(decoding: data, as: UTF8.self))?["data"]?.array else {
            throw LLMError.invalidResponse("lista de modelos ausente")
        }
        return entries
    }
}

// MARK: - Wire format

extension OpenAIClient {
    /// Last in the body, so the part that repeats comes first (see `WireEncoder`).
    static let trailingKeys = ["messages", "tool_choice"]

    /// A Claude model as OpenRouter names it ("anthropic/claude-…", or an alias such as "~anthropic/claude-…-latest").
    static func isAnthropicModel(_ model: String) -> Bool {
        model.hasPrefix("anthropic/") || model.hasPrefix("~anthropic/")
    }

    static func requestBody(model: String, messages: [ChatMessage], tools: [ToolSpec], includeUsage: Bool = false,
                            promptCacheKey: String? = nil, sessionID: String? = nil, cacheMarker: Bool = false,
                            toolChoice: ToolChoice = .auto) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "stream": .bool(true),
            "messages": .array(messages.movingToolImagesToUserMessages().map(wire)),
        ]
        if includeUsage { body["stream_options"] = .object(["include_usage": .bool(true)]) }
        if let promptCacheKey, !promptCacheKey.isEmpty { body["prompt_cache_key"] = .string(promptCacheKey) }
        // OpenRouter: the same upstream for the whole conversation from the first request on (its cache lives there),
        // and for Claude the marker without which nothing is cached (OpenRouter puts it on the last cacheable block).
        if let sessionID, !sessionID.isEmpty { body["session_id"] = .string(sessionID) }
        if cacheMarker { body["cache_control"] = .object(["type": .string("ephemeral")]) }
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object(["type": .string("function"), "function": .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": tool.parameters,
                ])])
            })
            if toolChoice == .none { body["tool_choice"] = .string("none") }
        }
        return .object(body)
    }

    static func wire(_ message: ChatMessage) -> JSONValue {
        let onlyCalls = message.role == .assistant && message.content.isEmpty && !message.toolCalls.isEmpty
        var object: [String: JSONValue] = [
            "role": .string(message.role.rawValue),
            "content": onlyCalls ? JSONValue.null : content(of: message),
        ]
        if !message.toolCalls.isEmpty {
            object["tool_calls"] = .array(message.toolCalls.map { call in
                .object(["id": .string(call.id), "type": .string("function"), "function": .object([
                    "name": .string(call.name),
                    // Some providers reject an empty arguments string.
                    "arguments": .string(call.arguments.isEmpty ? "{}" : call.arguments),
                ])])
            })
        }
        if message.role == .tool, let id = message.toolCallID {
            object["tool_call_id"] = .string(id)
        }
        return .object(object)
    }

    /// A message's content: plain text, or for a user message with pictures a list of parts (text, then one
    /// `image_url` data URL per picture). Tool messages never carry pictures here (`movingToolImagesToUserMessages`).
    private static func content(of message: ChatMessage) -> JSONValue {
        guard message.role == .user, !message.images.isEmpty else { return .string(message.content) }
        let payload = ImageWire.payload(of: message)
        var parts: [JSONValue] = []
        if !payload.text.isEmpty { parts.append(.object(["type": .string("text"), "text": .string(payload.text)])) }
        for image in payload.images {
            parts.append(.object(["type": .string("image_url"), "image_url": .object([
                "url": .string(ImageWire.dataURL(mediaType: image.mediaType, base64: image.base64)),
            ])]))
        }
        return .array(parts)
    }

    // MARK: Stop reason and usage

    /// `finish_reason` mapped to a `StopReason`. Without one, a stream that ended with `[DONE]` is judged by its
    /// tool calls (some local servers omit the field) and one that just stopped was cut off.
    static func stopReason(_ finishReason: String?, hasToolCalls: Bool, sawDone: Bool) -> StopReason {
        switch finishReason {
        case "stop": hasToolCalls ? .toolUse : .done
        case "tool_calls", "function_call": .toolUse
        case "length": .maxTokens
        case "content_filter": .refusal
        // DeepSeek's "out of resources" and OpenRouter's normalized "error": the answer was cut off, not finished.
        case "insufficient_system_resource", "error": .incomplete
        case let other?: .unknown(other)
        case nil: sawDone ? (hasToolCalls ? .toolUse : .done) : .incomplete
        }
    }

    /// Chat-completions `usage`, with cached tokens (`prompt_tokens_details.cached_tokens`, OpenRouter's
    /// `cache_write_tokens`, DeepSeek's `prompt_cache_hit_tokens`) split out of the input count.
    static func usage(in usage: JSONValue?) -> TokenUsage? {
        guard let usage, case .object = usage else { return nil }
        let details = usage["prompt_tokens_details"]
        let cacheRead = TokenUsage.sane(details?["cached_tokens"]?.int ?? usage["prompt_cache_hit_tokens"]?.int)
        let cacheWrite = TokenUsage.sane(details?["cache_write_tokens"]?.int)
        let prompt = TokenUsage.sane(usage["prompt_tokens"]?.int)
        return TokenUsage(input: prompt.map { max(0, $0 - (cacheRead ?? 0) - (cacheWrite ?? 0)) },
                          output: TokenUsage.sane(usage["completion_tokens"]?.int), cacheRead: cacheRead, cacheWrite: cacheWrite)
    }
}

// MARK: - Streaming helpers

/// Maps chat-completions chunks: text passes through, tool-call fragments are assembled and reported once at the end,
/// and the finish reason and usage (which arrives last, with an empty `choices`) close the response.
struct ChatStreamMapper: SSEMapper {
    private var toolCalls = ToolCallAccumulator()
    private var finishReason: String?
    private var usage: TokenUsage?
    /// Chat completions end with `[DONE]` (or the connection closing), never with an event of their own.
    let isFinished = false

    mutating func ingest(_ chunk: JSONValue) throws -> [LLMEvent] {
        // `"error": null` rides along on normal chunks of some gateways.
        if let error = chunk["error"], error != .null {
            let message = ProviderTransport.message(in: error) ?? error.jsonString
            if LLMError.isContextOverflow(message) { throw LLMError.contextExceeded(message) }
            // OpenRouter and friends report the upstream failure after the 200 already went out: a numeric `code`
            // is the HTTP status (429/5xx get retried), a string one the same kind of type Anthropic and Responses use.
            // Only a real HTTP status counts: a gateway's JSON-RPC style `-32000` or `0` is not one.
            if let status = error["code"]?.int ?? error["code"]?.string.flatMap({ Int($0) }), (400...599).contains(status) {
                throw LLMError.http(status: status, message: message)
            }
            let code = error["code"]?.string ?? error["code"]?.int.map(String.init)
            throw LLMError.stream(type: code ?? error["type"]?.string ?? "error", message: message)
        }
        if let reported = OpenAIClient.usage(in: chunk["usage"]) { usage = reported }
        let choice = chunk["choices"]?.array?.first
        if let reason = choice?["finish_reason"]?.string, !reason.isEmpty { finishReason = reason }
        guard let delta = choice?["delta"] else { return [] }
        if let fragments = delta["tool_calls"]?.array { toolCalls.ingest(fragments) }
        guard let text = delta["content"]?.string, !text.isEmpty else { return [] }
        return [.text(text)]
    }

    mutating func finish(sawDone: Bool) -> [LLMEvent] {
        let calls = toolCalls.requests
        return (calls.isEmpty ? [] : [.toolCalls(calls)])
            + [.finished(OpenAIClient.stopReason(finishReason, hasToolCalls: !calls.isEmpty, sawDone: sawDone), usage)]
    }
}

/// Assembles streamed `delta.tool_calls` fragments: id/name come first, `arguments` arrive in pieces.
struct ToolCallAccumulator {
    private var calls: [Int: ToolCallRequest] = [:]

    mutating func ingest(_ fragments: [JSONValue]) {
        for fragment in fragments {
            let index = slot(for: fragment)
            var call = calls[index] ?? ToolCallRequest(id: "", name: "", arguments: "")
            if let id = fragment["id"]?.string, !id.isEmpty { call.id = id }
            if let name = fragment["function"]?["name"]?.string, !name.isEmpty { call.name = name }
            if let arguments = fragment["function"]?["arguments"] {
                if let piece = arguments.string { call.arguments += piece }
                else if arguments != .null { call.arguments = arguments.jsonString } // some local servers send an object
            }
            calls[index] = call
        }
    }

    /// Which call a fragment continues. Providers that omit `index` repeat the call's `id` on every fragment (or send
    /// it only on the first); some send the same `index` for different calls, told apart by `id`.
    private func slot(for fragment: JSONValue) -> Int {
        let explicit = fragment["index"]?.int
        if let id = fragment["id"]?.string, !id.isEmpty {
            if let known = calls.first(where: { $0.value.id == id })?.key { return known }
            if let explicit, calls[explicit]?.id.isEmpty ?? true { return explicit }
            return (calls.keys.max() ?? -1) + 1
        }
        return explicit ?? calls.keys.max() ?? 0
    }

    /// Completed calls ordered by index; missing ids get a stable placeholder.
    var requests: [ToolCallRequest] {
        calls.sorted { $0.key < $1.key }.compactMap { index, call in
            guard !call.name.isEmpty else { return nil }
            var call = call
            if call.id.isEmpty { call.id = "call_\(index)" }
            return call
        }
    }
}
