import Foundation

/// What a wire format adds to a streamed exchange: how its JSON events become `LLMEvent`s. The rest (the request,
/// the status check, reading the events, cancellation) is `ProviderTransport`.
protocol SSEMapper: Sendable {
    /// Maps one event; throws for an error the provider reported inside the stream.
    mutating func ingest(_ event: JSONValue) throws -> [LLMEvent]
    /// The response is complete: reading stops without waiting for the connection to close.
    var isFinished: Bool { get }
    /// The events that close the response (reasoning, tool calls, the stop reason and usage). `sawDone` says
    /// whether the stream ended with `[DONE]`.
    mutating func finish(sawDone: Bool) -> [LLMEvent]
}

/// A mapper that collects reasoning, tool calls and usage while it reads and reports them when the response ends.
protocol AssemblingMapper: SSEMapper {
    static var reasoningFormat: APIFormat { get }
    var provider: String { get }
    var model: String { get }
    var reasoning: [ReasoningPart] { get }
    var toolCalls: [ToolCallRequest] { get }
    var stopReason: StopReason { get }
    var usage: TokenUsage? { get }
}

extension AssemblingMapper {
    mutating func finish(sawDone: Bool) -> [LLMEvent] {
        var events: [LLMEvent] = []
        if !reasoning.isEmpty {
            events.append(.reasoning(ReasoningTrace(format: Self.reasoningFormat, provider: provider, model: model, parts: reasoning)))
        }
        if !toolCalls.isEmpty { events.append(.toolCalls(toolCalls)) }
        events.append(.finished(stopReason, usage))
        return events
    }
}

/// The pipeline the three clients share: an authorized request (a stale credential is renewed once), a status check
/// with readable errors, the response read as Server-Sent Events, cancellation and the `Retry-After` the provider
/// asked for. A client brings its request body and its `SSEMapper`.
enum ProviderTransport {
    /// How long a connection may stay silent before it is given up on (URLSession counts it between received bytes,
    /// so a long answer is fine; local models can take long before the first token).
    static let idleTimeout: TimeInterval = 300

    /// Streams one model response: `body` is encoded once, off the caller's thread; `request` addresses it for a
    /// credential. Events reach the stream as they are read; errors are `LLMError`s (see `LLMError.wrapping`).
    static func stream<Mapper: SSEMapper>(
        session: URLSession, credentials: @escaping CredentialsProvider, acceptsEventStream: Bool = true,
        body: @escaping @Sendable () throws -> Data, request: @escaping @Sendable (String?) -> URLRequest, mapper: Mapper
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var mapper = mapper
                do {
                    let payload = try body()
                    let (bytes, response) = try await open(session, credentials: credentials) { key in
                        var request = request(key)
                        request.httpMethod = "POST"
                        request.timeoutInterval = idleTimeout
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        if acceptsEventStream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
                        request.httpBody = payload
                        return request
                    }
                    try await check(response, body: { try await prefix(of: bytes) })

                    var decoder = SSEDecoder()
                    var sawDone = false
                    // The start of the body while no event has been read: if the stream turns out not to be one, it says why.
                    var sawEvent = false
                    var head = Data()
                    /// Maps one event; true when reading can stop.
                    func handle(_ event: SSEEvent) throws -> Bool {
                        sawEvent = true
                        let data = event.data
                        if event.isDone { sawDone = true; return true }
                        guard let value = JSONValue.parse(data) else {
                            throw LLMError.invalidResponse(String(data.prefix(200)))
                        }
                        for output in try mapper.ingest(value) { continuation.yield(output) }
                        return mapper.isFinished
                    }
                    reading: do {
                        for try await byte in bytes {
                            if !sawEvent, head.count < errorBodyLimit { head.append(byte) }
                            if let event = decoder.feed(byte), try handle(event) { break reading }
                        }
                        if let event = decoder.finish() {
                            // A connection closed in the middle of an event is a dropped connection, not a bad reply.
                            if !event.isDone, JSONValue.parse(event.data) == nil {
                                throw LLMError.network(code: URLError.networkConnectionLost.rawValue,
                                                       message: "a conexão terminou no meio de uma resposta")
                            }
                            _ = try handle(event)
                        }
                    }
                    if !sawEvent, let problem = notAStream(head) { throw problem }
                    for output in mapper.finish(sawDone: sawDone) { continuation.yield(output) }
                    continuation.finish()
                } catch {
                    // A response that broke off was billed for what it had read and written. What the provider already
                    // reported (Anthropic's input tokens come first) goes ahead of the error, as an unfinished response.
                    if let used = (mapper as? any AssemblingMapper)?.usage { continuation.yield(.finished(.incomplete, used)) }
                    continuation.finish(throwing: LLMError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A 200 reply that held no event: a gateway that ignored `stream: true` (the whole answer as JSON, or its error), or
    /// a proxy's page. nil for an empty body or one that still looks like a stream (comments, `data:` lines).
    static func notAStream(_ head: Data) -> LLMError? {
        let text = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix(":"), !["data:", "event:", "id:", "retry:"].contains(where: text.hasPrefix) else { return nil }
        if let json = JSONValue.parse(text), let error = json["error"], let message = message(in: error) {
            return .invalidResponse("o provedor devolveu um erro sem streaming: \(message)")
        }
        return .invalidResponse("o provedor não respondeu em streaming: \(String(text.prefix(200)))")
    }

    // MARK: Requests

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

    /// Opens a streaming request with the current credential. A 401 means the credential went stale (an expired
    /// sign-in): it asks for a fresh one once and sends the request again.
    static func open(_ session: URLSession, credentials: CredentialsProvider,
                     request build: (String?) -> URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let token = try await credentials(false)
        let first = try await session.bytes(for: build(token))
        guard (first.1 as? HTTPURLResponse)?.statusCode == 401 else { return first }
        // An API key comes back unchanged: asking again would repeat a request that failed for a reason the key
        // does not fix (OpenCode answers a missing balance or a disabled model with 401 too).
        let renewed = try await credentials(true)
        guard renewed != token else { return first }
        return try await session.bytes(for: build(renewed))
    }

    static let listTimeout: TimeInterval = 15

    /// A plain GET (model lists): the body, once the status has been checked.
    static func fetch(_ request: URLRequest, session: URLSession) async throws -> Data {
        // A list is short: a host that accepts the connection and never answers must not hold on for the default minute.
        var request = request
        request.timeoutInterval = min(request.timeoutInterval, listTimeout)
        let (data, response) = try await session.data(for: request)
        try await check(response, body: { data.prefix(errorBodyLimit) })
        return data
    }

    // MARK: Errors

    static let errorBodyLimit = 2048

    /// Throws `LLMError.http` for non-2xx responses, using the (lazily read) body as the message.
    static func check(_ response: URLResponse, body: () async throws -> Data) async throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("resposta não HTTP")
        }
        guard !(200..<300).contains(http.statusCode) else { return }
        let data = try await body()
        let message = errorMessage(from: data, status: http.statusCode, host: http.url?.host())
        if http.statusCode == 400 || http.statusCode == 413,
           LLMError.isContextOverflow(message) || LLMError.isContextOverflow(String(decoding: data, as: UTF8.self)) {
            throw LLMError.contextExceeded(message)
        }
        throw LLMError.http(status: http.statusCode, message: message, retryAfter: retryAfter(in: http))
    }

    /// The longest wait taken at face value: a day. A header like `inf` or `1e30` is a broken gateway, not a plan.
    static let maxRetryAfter: TimeInterval = 86_400

    /// Seconds from `Retry-After` (a number of seconds or an HTTP date) or the millisecond variant some gateways send.
    static func retryAfter(in response: HTTPURLResponse, now: Date = .now) -> TimeInterval? {
        if let milliseconds = response.value(forHTTPHeaderField: "retry-after-ms").flatMap(Double.init), milliseconds.isFinite, milliseconds >= 0 {
            return min(milliseconds / 1000, maxRetryAfter)
        }
        guard let value = response.value(forHTTPHeaderField: "retry-after")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = Double(value) { return seconds.isFinite && seconds >= 0 ? min(seconds, maxRetryAfter) : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { min(max(0, $0.timeIntervalSince(now)), maxRetryAfter) }
    }

    /// Error codes that tell the user what to do (Command Code's Go plan has no API); kept with the message,
    /// which does not always repeat them.
    static let actionableErrorCodes: Set<String> = ["upgrade_required", "cmd_zdr_no_providers", "unsupported_model", "insufficient_quota"]

    /// `error.message` (OpenAI), `error` as a string (Ollama) or `message`; otherwise the raw text. An actionable
    /// `error.code` (see `actionableErrorCodes`) is added in brackets when the message lacks it.
    static func errorMessage(from data: Data, status: Int, host: String? = nil) -> String {
        let message = rawErrorMessage(from: data, status: status)
        // Command Code's only 403 is the Go plan; /messages answers in Anthropic's envelope, which has no `code`.
        if status == 403, host?.hasSuffix("commandcode.ai") == true, !message.contains("upgrade_required") {
            return "\(message) [upgrade_required]"
        }
        return message
    }

    private static func rawErrorMessage(from data: Data, status: Int) -> String {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = JSONValue.parse(text), let message = message(in: json["error"] ?? json) {
            if let code = json["error"]?["code"]?.string, actionableErrorCodes.contains(code), !message.contains(code) {
                return "\(message) [\(code)]"
            }
            return message
        }
        return text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : text
    }

    /// The text of an `error` value: a string, or an object with a `message`.
    static func message(in error: JSONValue) -> String? {
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
