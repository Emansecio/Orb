import Foundation

/// Client for the OpenAI Responses API (`POST {base}/responses`), used by GPT/Grok-class models that
/// providers only serve there. Stateless (`store: false`): the full history is sent every turn.
struct ResponsesClient: LLMClient {
    let baseURL: URL
    /// Asked before every request, so a refreshed sign-in token is picked up (see `CredentialsProvider`).
    let credentials: CredentialsProvider
    var extraHeaders: [String: String] = [:]
    /// Send tools as an `additional_tools` input item (required by Sign in with ChatGPT) instead of top-level `tools`.
    var toolsAsInputItem = false
    /// Sent as `prompt_cache_key`, so turns of one conversation land on the same cache (only to hosts that take it).
    var conversationID: String?
    /// Upper bound on the reply (reasoning included), sent as `max_output_tokens`; nil sends none.
    var maxOutputTokens: Int?
    let session: URLSession

    /// Hosts known to accept `prompt_cache_key`. A gateway that checks the body strictly rejects the whole request
    /// over a field it does not know, which costs the turn; a host outside the list just loses a routing hint (the
    /// cache itself works on the prompt prefix).
    static let cacheKeyHosts: Set<String> = ["api.openai.com", "chatgpt.com"]
    var sendsCacheKey: Bool { baseURL.host().map(Self.cacheKeyHosts.contains) ?? false }
    var arrangesPromptCache: Bool { sendsCacheKey }

    /// OpenAI's own API takes `max_output_tokens`; the ChatGPT sign-in and other gateways are not known to, and a body
    /// they reject would cost the note. The cap leaves room for the reasoning of a small reasoning model.
    var forShortReply: any LLMClient {
        guard baseURL.host() == "api.openai.com" else { return self }
        var copy = self
        copy.maxOutputTokens = 4_000
        return copy
    }

    init(baseURL: URL, credentials: @escaping CredentialsProvider, extraHeaders: [String: String] = [:],
         toolsAsInputItem: Bool = false, conversationID: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.extraHeaders = extraHeaders
        self.toolsAsInputItem = toolsAsInputItem
        self.conversationID = conversationID
        self.session = session
    }

    /// A client with one fixed key.
    init(baseURL: URL, apiKey: String?, extraHeaders: [String: String] = [:], toolsAsInputItem: Bool = false,
         conversationID: String? = nil, session: URLSession = .shared) {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(baseURL: baseURL, credentials: { _ in key }, extraHeaders: extraHeaders, toolsAsInputItem: toolsAsInputItem,
                  conversationID: conversationID, session: session)
    }

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        let provider = baseURL.host() ?? ""
        return ProviderTransport.stream(session: session, credentials: credentials, body: {
            try WireEncoder.encode(Self.requestBody(
                model: model, messages: messages, tools: tools, toolsAsInputItem: toolsAsInputItem,
                promptCacheKey: sendsCacheKey ? conversationID : nil, provider: provider, toolChoice: toolChoice,
                maxOutputTokens: maxOutputTokens), trailing: Self.trailingKeys)
        }, request: {
            ProviderTransport.authorizedRequest(baseURL.appending(path: "responses"), apiKey: $0, headers: extraHeaders)
        }, mapper: ResponsesStreamAssembler(provider: provider, model: model))
    }

    /// Last in the body, so the part that repeats comes first (see `WireEncoder`).
    static let trailingKeys = ["input", "tool_choice"]

    /// Whether the model may reason: everything but the families known not to (GPT-4 and GPT-3.5 ones, `chatgpt-4o`),
    /// so a model this list does not know yet still gets its reasoning carried.
    static func reasons(_ model: String) -> Bool {
        let name = model.lowercased().split(separator: "/").last.map(String.init) ?? ""
        return !["gpt-4", "gpt-3.5", "chatgpt-4o"].contains { name.hasPrefix($0) }
    }

    /// System messages become `instructions`; tool calls and results become `function_call` /
    /// `function_call_output` items. Reasoning recorded by the same endpoint and model goes back as `reasoning`
    /// items right before what it produced (the API rejects one that is not followed by its output).
    static func requestBody(model: String, messages: [ChatMessage], tools: [ToolSpec], toolsAsInputItem: Bool = false,
                            promptCacheKey: String? = nil, provider: String = "", toolChoice: ToolChoice = .auto,
                            maxOutputTokens: Int? = nil) -> JSONValue {
        let instructions = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        var input: [JSONValue] = []
        for message in messages.movingToolImagesToUserMessages() {
            switch message.role {
            case .system:
                continue
            case .user:
                input.append(.object(["role": .string("user"), "content": userContent(message)]))
            case .assistant:
                // Reasoning items by the number of calls that preceded them; each goes right before the output it
                // produced. Items that would end up with nothing after them are left out.
                var items: [Int: [JSONValue]] = [:]
                if let trace = message.reasoning, !message.content.isEmpty || !message.toolCalls.isEmpty,
                   trace.isReusable(format: .responses, provider: provider, model: model) {
                    for part in trace.parts {
                        guard let item = reasoningItem(part) else { continue }
                        let position = min(max(part.callsBefore ?? 0, 0), message.toolCalls.count)
                        if position == message.toolCalls.count && position > 0 { continue }
                        items[position, default: []].append(item)
                    }
                }
                input += items[0] ?? []
                if !message.content.isEmpty {
                    input.append(.object(["role": .string("assistant"), "content": .string(message.content)]))
                }
                for (position, call) in message.toolCalls.enumerated() {
                    if position > 0 { input += items[position] ?? [] }
                    input.append(.object(["type": .string("function_call"), "call_id": .string(call.id),
                                          "name": .string(call.name),
                                          "arguments": .string(call.arguments.isEmpty ? "{}" : call.arguments)]))
                }
            case .tool:
                input.append(.object(["type": .string("function_call_output"), "call_id": .string(message.toolCallID ?? ""),
                                      "output": .string(message.content)]))
            }
        }
        var body: [String: JSONValue] = [
            "model": .string(model), "input": .array(input), "stream": .bool(true), "store": .bool(false),
        ]
        // Stateless requests only get reasoning back by carrying it encrypted. A model that does not reason is not
        // asked: the API refuses `include` for it ("Encrypted content is not supported with this model").
        if toolsAsInputItem || reasons(model) { body["include"] = .array([.string("reasoning.encrypted_content")]) }
        if !instructions.isEmpty { body["instructions"] = .string(instructions) }
        if let promptCacheKey, !promptCacheKey.isEmpty { body["prompt_cache_key"] = .string(promptCacheKey) }
        if let maxOutputTokens { body["max_output_tokens"] = .number(Double(maxOutputTokens)) }
        let functions = JSONValue.array(tools.map {
            .object(["type": .string("function"), "name": .string($0.name), "description": .string($0.description),
                     "parameters": $0.parameters, "strict": .bool(false)])
        })
        if !tools.isEmpty {
            if toolChoice == .none && !toolsAsInputItem { body["tool_choice"] = .string("none") }
            if toolsAsInputItem {
                // The ChatGPT backend takes its tools as an input item and is not known to accept `tool_choice`
                // without a top-level `tools`: the instruction travels as text instead.
                if toolChoice == .none {
                    input.append(.object(["role": .string("developer"), "content": .string(noToolsInstruction)]))
                }
                input.insert(.object(["type": .string("additional_tools"), "role": .string("developer"), "tools": functions]), at: 0)
                body["input"] = .array(input)
            } else {
                body["tools"] = functions
            }
        }
        return .object(body)
    }

    /// Plain text, or for a message with pictures a list of `input_text` and `input_image` parts.
    private static func userContent(_ message: ChatMessage) -> JSONValue {
        guard !message.images.isEmpty else { return .string(message.content) }
        let payload = ImageWire.payload(of: message)
        var parts: [JSONValue] = []
        if !payload.text.isEmpty { parts.append(.object(["type": .string("input_text"), "text": .string(payload.text)])) }
        for image in payload.images {
            parts.append(.object(["type": .string("input_image"),
                                  "image_url": .string(ImageWire.dataURL(mediaType: image.mediaType, base64: image.base64))]))
        }
        return .array(parts)
    }

    static let noToolsInstruction = "Do not call any tool in your next reply: answer in text with a summary of what was done and what is left."

    /// The item exactly as received: the API requires its `id` (and the encrypted content stands in for the stored
    /// state). A part saved without an id cannot be sent back and is dropped.
    private static func reasoningItem(_ part: ReasoningPart) -> JSONValue? {
        guard part.kind == .encrypted, let data = part.data, !data.isEmpty, let id = part.id, !id.isEmpty else { return nil }
        let summary: [JSONValue] = part.text.isEmpty ? [] : [.object(["type": .string("summary_text"), "text": .string(part.text)])]
        return .object(["type": .string("reasoning"), "id": .string(id), "summary": .array(summary),
                        "encrypted_content": .string(data)])
    }
}

/// Turns Responses API stream events into `LLMEvent`s; function calls are reported once, when complete.
struct ResponsesStreamAssembler: AssemblingMapper {
    static let reasoningFormat = APIFormat.responses
    let provider: String
    let model: String
    private var calls: [Int: ToolCallRequest] = [:]
    private var reasoningItems: [Int: ReasoningPart] = [:]
    private var refused = false
    private var outcome: StopReason?
    private(set) var usage: TokenUsage?
    private(set) var isFinished = false

    init(provider: String = "", model: String = "") {
        self.provider = provider
        self.model = model
    }

    var toolCalls: [ToolCallRequest] { calls.sorted { $0.key < $1.key }.map(\.value).filter { !$0.name.isEmpty } }
    /// Reasoning items in output order, each noting how many function calls came before it.
    var reasoning: [ReasoningPart] {
        let callPositions = calls.filter { !$0.value.name.isEmpty }.keys
        return reasoningItems.sorted { $0.key < $1.key }.map { index, part in
            var part = part
            part.callsBefore = callPositions.filter { $0 < index }.count
            return part
        }
    }

    /// Why the response ended; a stream that closed before `response.completed` was cut off.
    var stopReason: StopReason {
        guard let outcome else { return .incomplete }
        if outcome == .done { return refused ? .refusal : (toolCalls.isEmpty ? .done : .toolUse) }
        return outcome
    }

    mutating func ingest(_ event: JSONValue) throws -> [LLMEvent] {
        let index = event["output_index"]?.int ?? 0
        switch event["type"]?.string {
        case "response.output_text.delta":
            if let text = event["delta"]?.string, !text.isEmpty { return [.text(text)] }
        case "response.refusal.delta":
            // The refusal text is the answer the user should see.
            refused = true
            if let text = event["delta"]?.string, !text.isEmpty { return [.text(text)] }
        case "response.refusal.done":
            refused = true
        case "response.output_item.added", "response.output_item.done":
            guard let item = event["item"] else { break }
            switch item["type"]?.string {
            case "function_call":
                var call = calls[index] ?? ToolCallRequest(id: "", name: "", arguments: "")
                call.id = item["call_id"]?.string ?? item["id"]?.string ?? "call_\(index)"
                call.name = item["name"]?.string ?? call.name
                if let arguments = item["arguments"]?.string, !arguments.isEmpty { call.arguments = arguments }
                calls[index] = call
            case "reasoning" where event["type"]?.string == "response.output_item.done":
                // Without the encrypted content there is nothing a stateless request could send back.
                if let data = item["encrypted_content"]?.string, !data.isEmpty {
                    let summary = (item["summary"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n\n")
                    reasoningItems[index] = ReasoningPart(kind: .encrypted, text: summary, data: data, id: item["id"]?.string)
                }
            case "message" where item["content"]?.array?.contains(where: { $0["type"]?.string == "refusal" }) == true:
                refused = true
            default:
                break
            }
        case "response.function_call_arguments.delta":
            calls[index]?.arguments += event["delta"]?.string ?? ""
        case "response.function_call_arguments.done":
            if let arguments = event["arguments"]?.string { calls[index]?.arguments = arguments }
        case "response.completed":
            usage = Self.usage(in: event["response"]?["usage"])
            outcome = .done
            isFinished = true
        case "response.incomplete":
            usage = Self.usage(in: event["response"]?["usage"])
            switch event["response"]?["incomplete_details"]?["reason"]?.string {
            case "max_output_tokens": outcome = .maxTokens
            case "content_filter": outcome = .refusal
            default: outcome = .incomplete
            }
            isFinished = true
        case "response.failed":
            throw Self.failure(code: event["response"]?["error"]?["code"]?.string,
                               message: event["response"]?["error"]?["message"]?.string ?? "a resposta falhou")
        case "error":
            throw Self.failure(code: event["code"]?.string ?? event["error"]?["code"]?.string,
                               message: event["message"]?.string ?? event["error"]?["message"]?.string ?? event.jsonString)
        default:
            break
        }
        return []
    }

    /// `usage` with cached tokens split out of the input count.
    static func usage(in usage: JSONValue?) -> TokenUsage? {
        guard let usage, case .object = usage else { return nil }
        let cached = TokenUsage.sane(usage["input_tokens_details"]?["cached_tokens"]?.int)
        return TokenUsage(input: TokenUsage.sane(usage["input_tokens"]?.int).map { max(0, $0 - (cached ?? 0)) },
                          output: TokenUsage.sane(usage["output_tokens"]?.int), cacheRead: cached, cacheWrite: nil)
    }

    private static func failure(code: String?, message: String) -> LLMError {
        if code == "context_length_exceeded" || LLMError.isContextOverflow(message) { return .contextExceeded(message) }
        return .stream(type: code ?? "error", message: message)
    }
}
