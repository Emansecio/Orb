import Foundation
import os
import Testing
@testable import Orb

struct OpenAIClientTests {
    @Test func assemblesParallelToolCallsFromFragments() throws {
        let chunks = [
            #"[{"index":0,"id":"call_a","type":"function","function":{"name":"read_file","arguments":""}}]"#,
            #"[{"index":0,"function":{"arguments":"{\"path\":"}}]"#,
            #"[{"index":1,"id":"call_b","type":"function","function":{"name":"list_dir","arguments":"{\"dir\""}}]"#,
            #"[{"index":0,"function":{"arguments":"\"a.txt\"}"}}]"#,
            #"[{"index":1,"function":{"arguments":":\"~\"}"}}]"#,
        ]
        var accumulator = ToolCallAccumulator()
        for chunk in chunks {
            accumulator.ingest(try #require(JSONValue.parse(chunk)?.array))
        }
        #expect(accumulator.requests == [
            ToolCallRequest(id: "call_a", name: "read_file", arguments: #"{"path":"a.txt"}"#),
            ToolCallRequest(id: "call_b", name: "list_dir", arguments: #"{"dir":"~"}"#),
        ])
    }

    @Test func encodesConversationAndTools() throws {
        let call = ToolCallRequest(id: "call_1", name: "read_file", arguments: #"{"path":"a.txt"}"#)
        let messages: [ChatMessage] = [
            .user("Leia a.txt"),
            ChatMessage(role: .assistant, content: "", toolCalls: [call]),
            .tool("call_1", "conteúdo"),
        ]
        let schema = JSONValue.schema(["path": .property("string", "Caminho")], required: ["path"])
        let tools = [ToolSpec(name: "read_file", description: "Lê um arquivo", parameters: schema)]
        let body = OpenAIClient.requestBody(model: "grok-4", messages: messages, tools: tools)

        #expect(body["model"] == .string("grok-4"))
        #expect(body["stream"] == .bool(true))
        let wire = try #require(body["messages"]?.array)
        #expect(wire[0] == .object(["role": .string("user"), "content": .string("Leia a.txt")]))
        #expect(wire[1] == .object([
            "role": .string("assistant"),
            "content": .null,
            "tool_calls": .array([.object([
                "id": .string("call_1"), "type": .string("function"),
                "function": .object(["name": .string("read_file"), "arguments": .string(#"{"path":"a.txt"}"#)]),
            ])]),
        ]))
        #expect(wire[2] == .object(["role": .string("tool"), "content": .string("conteúdo"), "tool_call_id": .string("call_1")]))
        #expect(body["tools"] == .array([.object([
            "type": .string("function"),
            "function": .object(["name": .string("read_file"), "description": .string("Lê um arquivo"), "parameters": schema]),
        ])]))

        #expect(OpenAIClient.requestBody(model: "m", messages: [], tools: [])["tools"] == nil)
    }

    @Test func extractsErrorMessages() {
        let message = { (text: String) in ProviderTransport.errorMessage(from: Data(text.utf8), status: 404) }
        #expect(message(#"{"error":{"message":"Incorrect API key","type":"invalid_request_error"}}"#) == "Incorrect API key")
        #expect(message(#"{"error":"model not found"}"#) == "model not found")
        #expect(message(#"{"message":"rate limited"}"#) == "rate limited")
        #expect(message("Bad Gateway\n") == "Bad Gateway")
        #expect(message("") == HTTPURLResponse.localizedString(forStatusCode: 404))
    }

    // MARK: End to end (stubbed network)

    @Test func streamsTextThenToolCalls() async throws {
        let sse = """
        : keep-alive

        data: {"choices":[{"delta":{"role":"assistant","reasoning_content":"hmm"}}]}

        data: {"choices":[{"delta":{"content":"Olá"}}]}

        data: {"choices":[{"delta":{"content":", mundo"}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"now","arguments":""}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}]}

        data: [DONE]

        """
        let client = StubProtocol.client(host: "stream.test", apiKey: "sk-test", status: 200, body: sse)
        var events: [LLMEvent] = []
        for try await event in client.stream(model: "m", messages: [.user("oi")], tools: []) {
            events.append(event)
        }
        #expect(events == [.text("Olá"), .text(", mundo"), .toolCalls([ToolCallRequest(id: "c1", name: "now", arguments: "{}")]),
                           .finished(.toolUse, nil)])

        let request = try #require(StubProtocol.requests.withLock { $0["stream.test"] })
        #expect(request.url?.path() == "/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    }

    @Test func throwsHTTPErrorWithProviderMessage() async {
        let client = StubProtocol.client(host: "error.test", apiKey: nil, status: 401,
                                         body: #"{"error":{"message":"Incorrect API key"}}"#)
        await #expect(throws: LLMError.http(status: 401, message: "Incorrect API key")) {
            for try await _ in client.stream(model: "m", messages: [], tools: []) {}
        }
        let request = StubProtocol.requests.withLock { $0["error.test"] }
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func listsSortedUniqueModels() async throws {
        let client = StubProtocol.client(host: "models.test", apiKey: nil, status: 200,
                                         body: #"{"object":"list","data":[{"id":"grok-4"},{"id":"grok-3"},{"id":"grok-4"}]}"#)
        #expect(try await client.models() == ["grok-3", "grok-4"])
        #expect(StubProtocol.requests.withLock { $0["models.test"] }?.url?.path() == "/v1/models")
    }
}

/// A mutable value shared with `@Sendable` closures.
final class Box<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }
    var value: Value {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
    func update(_ change: (inout Value) -> Void) { lock.withLockUnchecked { change(&$0) } }
}

struct OpenAIReliabilityTests {
    private func events(_ client: some LLMClient, messages: [ChatMessage] = [.user("oi")]) async throws -> [LLMEvent] {
        var events: [LLMEvent] = []
        for try await event in client.stream(model: "m", messages: messages, tools: []) { events.append(event) }
        return events
    }

    private func client(host: String, credentials: @escaping CredentialsProvider) -> OpenAIClient {
        OpenAIClient(baseURL: URL(string: "https://\(host)/v1")!, credentials: credentials, session: StubProtocol.session)
    }

    // MARK: Tool-call fragments

    @Test func continuesACallByIdWhenTheProviderOmitsIndex() throws {
        let chunks = [
            #"[{"id":"call_a","type":"function","function":{"name":"read_file","arguments":""}}]"#,
            #"[{"id":"call_a","function":{"arguments":"{\"path\":"}}]"#,
            #"[{"id":"call_b","type":"function","function":{"name":"list_dir","arguments":"{"}}]"#,
            #"[{"id":"call_a","function":{"arguments":"\"a.txt\"}"}}]"#,
            #"[{"id":"call_b","function":{"arguments":"}"}}]"#,
        ]
        var accumulator = ToolCallAccumulator()
        for chunk in chunks { accumulator.ingest(try #require(JSONValue.parse(chunk)?.array)) }
        #expect(accumulator.requests == [
            ToolCallRequest(id: "call_a", name: "read_file", arguments: #"{"path":"a.txt"}"#),
            ToolCallRequest(id: "call_b", name: "list_dir", arguments: "{}"),
        ])
    }

    @Test func separatesCallsThatShareAnIndexButNotAnId() throws {
        let chunks = [
            #"[{"index":0,"id":"call_a","function":{"name":"one","arguments":"{}"}}]"#,
            #"[{"index":0,"id":"call_b","function":{"name":"two","arguments":"{}"}}]"#,
        ]
        var accumulator = ToolCallAccumulator()
        for chunk in chunks { accumulator.ingest(try #require(JSONValue.parse(chunk)?.array)) }
        #expect(accumulator.requests.map(\.name) == ["one", "two"])
    }

    @Test func fragmentsWithoutIdOrIndexContinueTheLastCall() throws {
        var accumulator = ToolCallAccumulator()
        accumulator.ingest(try #require(JSONValue.parse(#"[{"id":"c","function":{"name":"now","arguments":"{"}}]"#)?.array))
        accumulator.ingest(try #require(JSONValue.parse(#"[{"function":{"arguments":"}"}}]"#)?.array))
        #expect(accumulator.requests == [ToolCallRequest(id: "c", name: "now", arguments: "{}")])
    }

    // MARK: Stop reasons and usage

    @Test func mapsFinishReasons() {
        let reason = { (finish: String?, calls: Bool, done: Bool) in OpenAIClient.stopReason(finish, hasToolCalls: calls, sawDone: done) }
        #expect(reason("stop", false, true) == .done)
        #expect(reason("tool_calls", true, true) == .toolUse)
        #expect(reason("stop", true, true) == .toolUse)
        #expect(reason("length", false, true) == .maxTokens)
        #expect(reason("content_filter", false, true) == .refusal)
        #expect(reason("weird", false, true) == .unknown("weird"))
        #expect(reason(nil, false, true) == .done)
        #expect(reason(nil, true, true) == .toolUse)
        #expect(reason(nil, false, false) == .incomplete)
    }

    @Test func streamEndsWithStopReasonAndUsage() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"Oi"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"length"}],"usage":null}

        data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":100}}}

        data: [DONE]

        """
        let client = StubProtocol.client(host: "usage.test", apiKey: nil, status: 200, body: sse)
        #expect(try await events(client) == [.text("Oi"), .finished(.maxTokens, TokenUsage(input: 20, output: 7, cacheRead: 100, cacheWrite: nil))])
    }

    @Test func aStreamCutBeforeTheEndIsIncomplete() async throws {
        let client = StubProtocol.client(host: "cut.test", apiKey: nil, status: 200,
                                         body: "data: {\"choices\":[{\"delta\":{\"content\":\"Oi\"}}]}\n\n")
        #expect(try await events(client) == [.text("Oi"), .finished(.incomplete, nil)])
    }

    @Test func requestsUsageAndCacheKeyOnlyWhereSupported() throws {
        let plain = OpenAIClient.requestBody(model: "m", messages: [.user("oi")], tools: [])
        #expect(plain["stream_options"] == nil)
        #expect(plain["prompt_cache_key"] == nil)
        let full = OpenAIClient.requestBody(model: "m", messages: [.user("oi")], tools: [], includeUsage: true, promptCacheKey: "bot-1")
        #expect(full["stream_options"] == .object(["include_usage": .bool(true)]))
        #expect(full["prompt_cache_key"] == .string("bot-1"))

        let make = { (url: String) in OpenAIClient(baseURL: URL(string: url)!, apiKey: nil) }
        #expect(make("https://api.openai.com/v1").isOpenAI)
        #expect(make("https://api.openai.com/v1").reportsUsage)
        #expect(!make("https://openrouter.ai/api/v1").isOpenAI)
        #expect(make("https://openrouter.ai/api/v1").reportsUsage)
        for local in ["http://localhost:11434/v1", "http://localhost:1234/v1", "https://api.x.ai/v1", "https://example.com/v1"] {
            #expect(!make(local).isOpenAI)
            #expect(!make(local).reportsUsage)
        }
    }

    @Test func compatibleServersGetNeitherUsageNorCacheKeyOnTheWire() async throws {
        let stub = client(host: "compat.test") { _ in nil }
        var withKey = stub
        withKey.conversationID = "bot-1"
        StubProtocol.queue(host: "compat.test", [.init(body: "data: [DONE]\n\n")])
        _ = try await events(withKey)
        let body = try #require(StubProtocol.sent(to: "compat.test").first?.body)
        #expect(body["stream_options"] == nil)
        #expect(body["prompt_cache_key"] == nil)
    }

    @Test func openAIAndOpenRouterGetUsageOnTheWireButOnlyOpenAIGetsTheCacheKey() async throws {
        for (host, cacheKey) in [("api.openai.com", true), ("openrouter.ai", false)] {
            var client = OpenAIClient(baseURL: URL(string: "https://\(host)/v1")!, apiKey: nil, session: StubProtocol.session)
            client.conversationID = "bot-1"
            StubProtocol.queue(host: host, [.init(body: "data: [DONE]\n\n")])
            _ = try await events(client)
            let body = try #require(StubProtocol.sent(to: host).first?.body)
            #expect(body["stream_options"] == .object(["include_usage": .bool(true)]))
            #expect(body["prompt_cache_key"] == (cacheKey ? .string("bot-1") : nil))
        }
    }

    // MARK: Errors

    @Test func aLongRetryAfterIsSaidInTheErrorMessage() {
        let message = { (seconds: TimeInterval?) in LLMError.http(status: 429, message: "x", retryAfter: seconds).errorDescription ?? "" }
        #expect(message(nil).contains("pediu para aguardar") == false)
        #expect(message(0.2).contains("pediu para aguardar") == false)
        #expect(message(30).hasSuffix("O provedor pediu para aguardar 30 s."))
        #expect(message(600).hasSuffix("O provedor pediu para aguardar 10 min."))
    }

    @Test func parsesRetryAfterHeaders() throws {
        let response = { (headers: [String: String]) in
            HTTPURLResponse(url: URL(string: "https://x.test")!, statusCode: 429, httpVersion: nil, headerFields: headers)!
        }
        #expect(ProviderTransport.retryAfter(in: response(["Retry-After": "12"])) == 12)
        #expect(ProviderTransport.retryAfter(in: response(["Retry-After": "1.5"])) == 1.5)
        #expect(ProviderTransport.retryAfter(in: response(["retry-after-ms": "250"])) == 0.25)
        #expect(ProviderTransport.retryAfter(in: response(["Retry-After": "-3"])) == nil)
        #expect(ProviderTransport.retryAfter(in: response(["Retry-After": "soon"])) == nil)
        #expect(ProviderTransport.retryAfter(in: response([:])) == nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000) // Fri, 15 Jan 2027 08:00:00 GMT
        #expect(ProviderTransport.retryAfter(in: response(["Retry-After": "Fri, 15 Jan 2027 08:00:30 GMT"]), now: now) == 30)
        #expect(ProviderTransport.retryAfter(in: response(["Retry-After": "Fri, 15 Jan 2027 07:00:00 GMT"]), now: now) == 0)
    }

    @Test func rateLimitErrorsCarryRetryAfter() async {
        let client = StubProtocol.client(host: "limit.test", apiKey: nil, status: 429, body: #"{"error":{"message":"Slow down"}}"#)
        StubProtocol.queue(host: "limit.test", [.init(status: 429, body: #"{"error":{"message":"Slow down"}}"#, headers: ["Retry-After": "7"])])
        do {
            for try await _ in client.stream(model: "m", messages: [], tools: []) {}
            Issue.record("should have thrown")
        } catch let error as LLMError {
            #expect(error == .http(status: 429, message: "Slow down", retryAfter: 7))
            #expect(error.retryAfter == 7)
            #expect(error.isRetryable)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func anExhaustedQuotaIsNotRetriedAndPointsToTheBalance() async {
        let body = #"{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","code":"insufficient_quota"}}"#
        let client = StubProtocol.client(host: "quota.test", apiKey: nil, status: 429, body: body)
        StubProtocol.queue(host: "quota.test", [.init(status: 429, body: body), .init(status: 429, body: body)])
        let attempts = Box<Int>(0)
        do {
            try await withRetries(sleep: { _ in }) {
                attempts.update { $0 += 1 }
                for try await _ in client.stream(model: "m", messages: [], tools: []) {}
            }
            Issue.record("should have thrown")
        } catch let error as LLMError {
            #expect(!error.isRetryable)
            #expect(error.errorDescription?.contains("saldo") == true)
            #expect(error.errorDescription?.contains("espere um pouco") == false)
            #expect(error.errorDescription?.contains("insufficient_quota") == true)
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(attempts.value == 1)
        #expect(StubProtocol.sent(to: "quota.test").count == 1)
        // A plain rate limit is still a wait-and-retry.
        #expect(LLMError.http(status: 429, message: "Rate limit reached for requests").isRetryable)
        // Per-minute limits that mention billing or the quota are a wait, not a missing balance.
        let perMinute = [
            "Rate limit reached for gpt-4o in organization org-x on requests per min (RPM): Limit 3, Used 3. Please try again in 20s. Visit https://platform.openai.com/account/billing to add a payment method to increase your rate limits.",
            "You exceeded your current quota, please check your plan and billing details. Please retry in 12s.",
        ]
        for message in perMinute {
            let error = LLMError.http(status: 429, message: message, retryAfter: 12)
            #expect(error.isRetryable)
            #expect(error.errorDescription?.contains("limite de uso") == true)
            #expect(error.errorDescription?.contains("Sem saldo") == false)
        }
        // A spent cap is not, whatever the wording.
        for message in ["Insufficient balance", "Monthly limit reached", "You hit your spending limit"] {
            #expect(!LLMError.http(status: 429, message: message).isRetryable)
        }
    }

    @Test func contextOverflowIsDistinguishable() async {
        let bodies = [
            #"{"error":{"message":"This model's maximum context length is 128000 tokens.","code":"context_length_exceeded"}}"#,
            #"{"error":{"type":"invalid_request_error","message":"prompt is too long: 250000 tokens > 200000 maximum"}}"#,
            #"{"error":{"message":"Bad request","code":"context_length_exceeded"}}"#,
        ]
        for (index, body) in bodies.enumerated() {
            let client = StubProtocol.client(host: "ctx\(index).test", apiKey: nil, status: 400, body: body)
            do {
                for try await _ in client.stream(model: "m", messages: [], tools: []) {}
                Issue.record("should have thrown")
            } catch let error as LLMError {
                guard case .contextExceeded = error else { Issue.record("not mapped: \(error)"); continue }
                #expect(!error.isRetryable)
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
        // Another 400 stays a plain HTTP error.
        let other = StubProtocol.client(host: "ctx-other.test", apiKey: nil, status: 400, body: #"{"error":{"message":"bad tool schema"}}"#)
        await #expect(throws: LLMError.http(status: 400, message: "bad tool schema")) {
            for try await _ in other.stream(model: "m", messages: [], tools: []) {}
        }
    }

    @Test func transportFailuresBecomeRetryableNetworkErrors() async {
        let client = StubProtocol.client(host: "down.test", apiKey: nil, status: 200, body: "")
        StubProtocol.queue(host: "down.test", [.init(failure: URLError.timedOut.rawValue)])
        do {
            for try await _ in client.stream(model: "m", messages: [], tools: []) {}
            Issue.record("should have thrown")
        } catch let error as LLMError {
            guard case .network(let code, _) = error else { Issue.record("not wrapped: \(error)"); return }
            #expect(code == URLError.timedOut.rawValue)
            #expect(error.isRetryable)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: Credentials

    @Test func asksForCredentialsBeforeEveryRequest() async throws {
        let asked = Box<[Bool]>([])
        let tokens = Box<[String]>(["k1", "k2"])
        let client = client(host: "creds.test") { force in
            asked.update { $0.append(force) }
            return tokens.value.first
        }
        StubProtocol.queue(host: "creds.test", [.init(body: "data: [DONE]\n\n"), .init(body: "data: [DONE]\n\n")])
        _ = try await events(client)
        tokens.update { $0.removeFirst() }
        _ = try await events(client)
        let sent = StubProtocol.sent(to: "creds.test").map { $0.request.value(forHTTPHeaderField: "Authorization") }
        #expect(sent == ["Bearer k1", "Bearer k2"])
        #expect(asked.value == [false, false])
    }

    @Test func a401RefreshesTheCredentialAndRetriesOnce() async throws {
        let asked = Box<[Bool]>([])
        let client = client(host: "refresh.test") { force in
            asked.update { $0.append(force) }
            return force ? "fresh" : "stale"
        }
        StubProtocol.queue(host: "refresh.test", [
            .init(status: 401, body: #"{"error":{"message":"expired"}}"#),
            .init(body: "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"),
        ])
        #expect(try await events(client) == [.text("ok"), .finished(.done, nil)])
        #expect(asked.value == [false, true])
        let sent = StubProtocol.sent(to: "refresh.test").map { $0.request.value(forHTTPHeaderField: "Authorization") }
        #expect(sent == ["Bearer stale", "Bearer fresh"])
    }

    @Test func aSecond401IsReportedWithoutLooping() async {
        let asked = Box<[Bool]>([])
        let client = client(host: "denied.test") { force in
            asked.update { $0.append(force) }
            return force ? "still-nope" : "nope" // a renewed credential is tried once; an unchanged key is not resent
        }
        StubProtocol.queue(host: "denied.test", [.init(status: 401, body: #"{"error":{"message":"bad key"}}"#),
                                                 .init(status: 401, body: #"{"error":{"message":"bad key"}}"#),
                                                 .init(status: 401, body: #"{"error":{"message":"bad key"}}"#)])
        await #expect(throws: LLMError.http(status: 401, message: "bad key")) {
            for try await _ in client.stream(model: "m", messages: [], tools: []) {}
        }
        #expect(StubProtocol.sent(to: "denied.test").count == 2)
        #expect(asked.value == [false, true])
    }

    @Test func aFailingCredentialLookupSurfacesItsError() async {
        let client = client(host: "nocreds.test") { _ in throw ToolError("A sessão do ChatGPT expirou.") }
        await #expect(throws: ToolError("A sessão do ChatGPT expirou.")) {
            for try await _ in client.stream(model: "m", messages: [], tools: []) {}
        }
    }
}

/// Serves canned responses keyed by host, so parallel tests don't interfere. A host with a queue gets its
/// responses in order (then falls back to the fixed one); every request is logged with its body.
final class StubProtocol: URLProtocol {
    struct Response: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
        /// Fails the request with this `URLError` code instead of answering.
        var failure: Int?

        init(status: Int = 200, body: String = "", headers: [String: String] = [:], failure: Int? = nil) {
            self.status = status
            self.body = Data(body.utf8)
            self.headers = headers
            self.failure = failure
        }
    }

    struct Sent: Sendable {
        var request: URLRequest
        /// The body parsed as JSON (nil for form bodies).
        var body: JSONValue?
        var text: String
    }

    static let responses = OSAllocatedUnfairLock<[String: Response]>(initialState: [:])
    static let queues = OSAllocatedUnfairLock<[String: [Response]]>(initialState: [:])
    static let requests = OSAllocatedUnfairLock<[String: URLRequest]>(initialState: [:])
    static let log = OSAllocatedUnfairLock<[String: [Sent]]>(initialState: [:])

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func client(host: String, apiKey: String?, status: Int, body: String) -> OpenAIClient {
        responses.withLock { $0[host] = Response(status: status, body: body) }
        return OpenAIClient(baseURL: URL(string: "https://\(host)/v1")!, apiKey: apiKey, session: session)
    }

    /// Answers the next requests to `host` with these, in order.
    static func queue(host: String, _ list: [Response]) {
        queues.withLock { $0[host] = list }
        log.withLock { $0[host] = [] }
    }

    /// Everything sent to `host` so far.
    static func sent(to host: String) -> [Sent] { log.withLock { $0[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let host = request.url?.host() ?? ""
        Self.requests.withLock { $0[host] = request }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        let text = body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        Self.log.withLock { $0[host, default: []].append(Sent(request: request, body: JSONValue.parse(text), text: text)) }
        let queued: Response? = Self.queues.withLock { queues in
            guard var list = queues[host], !list.isEmpty else { return nil }
            let first = list.removeFirst()
            queues[host] = list
            return first
        }
        guard let url = request.url, let stub = queued ?? Self.responses.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: failure)))
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension OpenAIClientTests {
    @Test func toolChoiceNoneKeepsTheToolsAndForbidsCalls() {
        let tools = [ToolSpec(name: "a", description: "A", parameters: .schema([:]))]
        let auto = OpenAIClient.requestBody(model: "m", messages: [.user("oi")], tools: tools)
        let none = OpenAIClient.requestBody(model: "m", messages: [.user("oi")], tools: tools, toolChoice: .none)
        #expect(auto["tool_choice"] == nil)
        #expect(none["tool_choice"] == .string("none"))
        #expect(none["tools"] == auto["tools"])
        #expect(OpenAIClient.requestBody(model: "m", messages: [.user("oi")], tools: [], toolChoice: .none)["tool_choice"] == nil)
    }
}
