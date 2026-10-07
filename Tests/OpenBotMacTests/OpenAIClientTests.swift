import Foundation
import os
import Testing
@testable import OpenBotMac

struct OpenAIClientTests {
    @Test func parsesSSELines() {
        #expect(SSEParser.parse(#"data: {"a":1}"#) == .data(#"{"a":1}"#))
        #expect(SSEParser.parse(#"data:{"a":1}"#) == .data(#"{"a":1}"#))
        #expect(SSEParser.parse("data: [DONE]") == .done)
        #expect(SSEParser.parse(": OPENROUTER PROCESSING") == nil)
        #expect(SSEParser.parse("") == nil)
        #expect(SSEParser.parse("data: ") == nil)
        #expect(SSEParser.parse("event: ping") == nil)
    }

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
        let message = { (text: String) in OpenAIClient.errorMessage(from: Data(text.utf8), status: 404) }
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
        #expect(events == [.text("Olá"), .text(", mundo"), .toolCalls([ToolCallRequest(id: "c1", name: "now", arguments: "{}")])])

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

/// Serves canned responses keyed by host, so parallel tests don't interfere.
final class StubProtocol: URLProtocol {
    struct Response: Sendable {
        var status: Int
        var body: Data
    }

    static let responses = OSAllocatedUnfairLock<[String: Response]>(initialState: [:])
    static let requests = OSAllocatedUnfairLock<[String: URLRequest]>(initialState: [:])

    static func client(host: String, apiKey: String?, status: Int, body: String) -> OpenAIClient {
        responses.withLock { $0[host] = Response(status: status, body: Data(body.utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return OpenAIClient(baseURL: URL(string: "https://\(host)/v1")!, apiKey: apiKey,
                            session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let host = request.url?.host() ?? ""
        Self.requests.withLock { $0[host] = request }
        guard let url = request.url, let stub = Self.responses.withLock({ $0[host] }),
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
