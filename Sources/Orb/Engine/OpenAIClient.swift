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
    /// Servers known to take `stream_options` (local ones may reject it).
    var reportsUsage: Bool { isOpenAI || baseURL.host() == "openrouter.ai" }

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try JSONEncoder().encode(Self.requestBody(
                        model: model, messages: messages, tools: tools, includeUsage: reportsUsage,
                        promptCacheKey: isOpenAI ? conversationID : nil, toolChoice: toolChoice))
                    let (bytes, response) = try await Self.open(session, credentials: credentials) { key in
                        var request = Self.authorizedRequest(baseURL.appending(path: "chat/completions"), apiKey: key,
                                                             headers: extraHeaders)
                        request.httpMethod = "POST"
                        request.timeoutInterval = 300 // local models can take long before the first token
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        request.httpBody = body
                        return request
                    }
                    try await Self.check(response, body: { try await Self.prefix(of: bytes) })

                    var toolCalls = ToolCallAccumulator()
                    var finishReason: String?
                    var usage: TokenUsage?
                    var sawDone = false
                    lines: for try await line in bytes.lines {
                        switch SSEParser.parse(line) {
                        case nil: continue
                        case .done: sawDone = true; break lines
                        case .data(let payload):
                            guard let chunk = JSONValue.parse(payload) else {
                                throw LLMError.invalidResponse(String(payload.prefix(200)))
                            }
                            if let error = chunk["error"] {
                                let message = Self.message(in: error) ?? error.jsonString
                                throw LLMError.isContextOverflow(message) ? LLMError.contextExceeded(message)
                                    : LLMError.invalidResponse(message)
                            }
                            // The usage chunk arrives last, with an empty `choices`.
                            if let reported = Self.usage(in: chunk["usage"]) { usage = reported }
                            let choice = chunk["choices"]?.array?.first
                            if let reason = choice?["finish_reason"]?.string, !reason.isEmpty { finishReason = reason }
                            guard let delta = choice?["delta"] else { continue }
                            if let text = delta["content"]?.string, !text.isEmpty {
                                continuation.yield(.text(text))
                            }
                            if let fragments = delta["tool_calls"]?.array {
                                toolCalls.ingest(fragments)
                            }
                        }
                    }
                    let calls = toolCalls.requests
                    if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                    continuation.yield(.finished(Self.stopReason(finishReason, hasToolCalls: !calls.isEmpty, sawDone: sawDone), usage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LLMError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func models() async throws -> [String] {
        Set(try await modelEntries().compactMap { $0["id"]?.string }).sorted()
    }

    /// The `data` entries of the model list, whole (some servers say more about each model than its id).
    func modelEntries() async throws -> [JSONValue] {
        let (data, response) = try await session.data(for: Self.authorizedRequest(
            baseURL.appending(path: "models"), apiKey: try await credentials(false), headers: extraHeaders))
        try await Self.check(response, body: { data.prefix(Self.errorBodyLimit) })
        guard let entries = JSONValue.parse(String(decoding: data, as: UTF8.self))?["data"]?.array else {
            throw LLMError.invalidResponse("lista de modelos ausente")
        }
        return entries
    }

    /// Identifies the app (some gateways reject generic HTTP-library user agents).
    static let userAgent = "Orb/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (macOS)"

    /// A request with `Authorization: Bearer` (when a key is set), the app's User-Agent and any extra headers.
    static func authorizedRequest(_ url: URL, apiKey: String?, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}

// MARK: - Wire format

extension OpenAIClient {
    static func requestBody(model: String, messages: [ChatMessage], tools: [ToolSpec], includeUsage: Bool = false,
                            promptCacheKey: String? = nil, toolChoice: ToolChoice = .auto) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "stream": .bool(true),
            "messages": .array(messages.movingToolImagesToUserMessages().map(wire)),
        ]
        if includeUsage { body["stream_options"] = .object(["include_usage": .bool(true)]) }
        if let promptCacheKey, !promptCacheKey.isEmpty { body["prompt_cache_key"] = .string(promptCacheKey) }
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

    // MARK: Requests and errors

    /// Opens a streaming request with the current credential. A 401 means the credential went stale (an expired
    /// sign-in): it asks for a fresh one once and sends the request again.
    static func open(_ session: URLSession, credentials: CredentialsProvider,
                     request build: (String?) -> URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let first = try await session.bytes(for: build(try await credentials(false)))
        guard (first.1 as? HTTPURLResponse)?.statusCode == 401 else { return first }
        return try await session.bytes(for: build(try await credentials(true)))
    }

    static let errorBodyLimit = 2048

    /// Throws `LLMError.http` for non-2xx responses, using the (lazily read) body as the message.
    static func check(_ response: URLResponse, body: () async throws -> Data) async throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("resposta não HTTP")
        }
        guard !(200..<300).contains(http.statusCode) else { return }
        let data = try await body()
        let message = errorMessage(from: data, status: http.statusCode)
        if http.statusCode == 400 || http.statusCode == 413,
           LLMError.isContextOverflow(message) || LLMError.isContextOverflow(String(decoding: data, as: UTF8.self)) {
            throw LLMError.contextExceeded(message)
        }
        throw LLMError.http(status: http.statusCode, message: message, retryAfter: retryAfter(in: http))
    }

    /// Seconds from `Retry-After` (a number of seconds or an HTTP date) or the millisecond variant some gateways send.
    static func retryAfter(in response: HTTPURLResponse, now: Date = .now) -> TimeInterval? {
        if let milliseconds = response.value(forHTTPHeaderField: "retry-after-ms").flatMap(Double.init), milliseconds >= 0 {
            return milliseconds / 1000
        }
        guard let value = response.value(forHTTPHeaderField: "retry-after")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = Double(value) { return seconds >= 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
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
        case let other?: .unknown(other)
        case nil: sawDone ? (hasToolCalls ? .toolUse : .done) : .incomplete
        }
    }

    /// Chat-completions `usage`, with cached tokens (`prompt_tokens_details.cached_tokens`, OpenRouter's
    /// `cache_write_tokens`, DeepSeek's `prompt_cache_hit_tokens`) split out of the input count.
    static func usage(in usage: JSONValue?) -> TokenUsage? {
        guard let usage, case .object = usage else { return nil }
        let details = usage["prompt_tokens_details"]
        let cacheRead = details?["cached_tokens"]?.int ?? usage["prompt_cache_hit_tokens"]?.int
        let cacheWrite = details?["cache_write_tokens"]?.int
        let prompt = usage["prompt_tokens"]?.int
        return TokenUsage(input: prompt.map { max(0, $0 - (cacheRead ?? 0) - (cacheWrite ?? 0)) },
                          output: usage["completion_tokens"]?.int, cacheRead: cacheRead, cacheWrite: cacheWrite)
    }

    /// `error.message` (OpenAI), `error` as a string (Ollama) or `message`; otherwise the raw text.
    static func errorMessage(from data: Data, status: Int) -> String {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = JSONValue.parse(text), let message = message(in: json["error"] ?? json) {
            return message
        }
        return text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : text
    }

    private static func message(in error: JSONValue) -> String? {
        error.string ?? error["message"]?.string
    }

    /// The start of an error body (enough for the message, without reading huge responses).
    static func prefix(of bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= errorBodyLimit { break }
        }
        return data
    }
}

// MARK: - Streaming helpers

/// Line-level Server-Sent Events parsing (one `data:` line per event, as chat-completions providers send).
enum SSEParser {
    enum Line: Equatable {
        case data(String)
        case done
    }

    /// The event carried by `line`; nil for comments, blank lines and other fields.
    static func parse(_ line: String) -> Line? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.isEmpty { return nil }
        return payload == "[DONE]" ? .done : .data(payload)
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
