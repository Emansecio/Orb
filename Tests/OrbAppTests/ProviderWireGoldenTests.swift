import Foundation
import Testing
@testable import Orb

/// Golden tests of what the three clients put on the wire and what they make of a streamed answer. They were
/// recorded before the transport was shared (`ProviderTransport`): the same input must keep producing the same
/// request (method, URL, headers, timeout, body bytes) and the same `LLMEvent`s.
struct ProviderWireGoldenTests {
    private static let history: [ChatMessage] = [
        .system("Você é o Orb."),
        .user("Liste a pasta."),
        ChatMessage(role: .assistant, content: "Vou listar.", toolCalls: [ToolCallRequest(id: "c1", name: "ls", arguments: #"{"path":"."}"#)]),
        .tool("c1", "a.txt"),
    ]
    private static let tools = [ToolSpec(name: "ls", description: "Lists a folder", parameters: .schema(["path": .string("Folder")]))]

    /// The request as the stub saw it: the headers that matter, the timeout and the body bytes.
    private func snapshot(of sent: StubProtocol.Sent) -> String {
        let request = sent.request
        let names = ["Authorization", "x-api-key", "anthropic-version", "Content-Type", "Accept", "X-Extra"]
        var lines = ["\(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")", "timeout=\(Int(request.timeoutInterval))"]
        for name in names { lines.append("\(name): \(request.value(forHTTPHeaderField: name) ?? "-")") }
        let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
        lines.append("User-Agent: \(agent.hasPrefix("Orb/") && agent.hasSuffix(" (macOS)") ? "Orb" : agent)")
        lines.append(sent.text)
        return lines.joined(separator: "\n")
    }

    private func run(_ client: some LLMClient, host: String, sse: String) async throws -> (events: [LLMEvent], sent: String) {
        StubProtocol.queue(host: host, [.init(body: sse)])
        var events: [LLMEvent] = []
        for try await event in client.stream(model: "m-1", messages: Self.history, tools: Self.tools, toolChoice: .auto) {
            events.append(event)
        }
        return (events, snapshot(of: try #require(StubProtocol.sent(to: host).first)))
    }

    @Test func chatCompletionsRequestAndEvents() async throws {
        let sse = """
        : OPENROUTER PROCESSING

        data: {"choices":[{"delta":{"role":"assistant","content":"Olá"}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c9","function":{"name":"ls","arguments":"{\\"path\\""}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\\".\\"}"}}]},"finish_reason":"tool_calls"}]}

        data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":40}}}

        data: [DONE]

        """
        let client = OpenAIClient(baseURL: URL(string: "https://golden-chat.test/v1")!, apiKey: " sk-1 ",
                                  extraHeaders: ["X-Extra": "yes"], conversationID: "bot-1", session: StubProtocol.session)
        let (events, sent) = try await run(client, host: "golden-chat.test", sse: sse)
        #expect(events == [.text("Olá"), .toolCalls([ToolCallRequest(id: "c9", name: "ls", arguments: #"{"path":"."}"#)]),
                           .finished(.toolUse, TokenUsage(input: 60, output: 7, cacheRead: 40, cacheWrite: nil))])
        #expect(sent == Self.chatSnapshot)
    }

    @Test func messagesRequestAndEvents() async throws {
        let sse = [
            #"{"type":"message_start","message":{"usage":{"input_tokens":12,"cache_read_input_tokens":3}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Hmm."}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Olá"}}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tu_1","name":"ls","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\".\"}"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#,
            #"{"type":"message_stop"}"#,
        ].map { "event: x\ndata: \($0)\n\n" }.joined()
        var client = AnthropicClient(baseURL: URL(string: "https://golden-messages.test/v1")!, apiKey: "sk-ant",
                                     extraHeaders: ["X-Extra": "yes"], session: StubProtocol.session)
        client.sendsBearer = true
        let (events, sent) = try await run(client, host: "golden-messages.test", sse: sse)
        let trace = ReasoningTrace(format: .messages, provider: "golden-messages.test", model: "m-1",
                                   parts: [ReasoningPart(kind: .thinking, text: "Hmm.", signature: "sig")])
        #expect(events == [.usage(TokenUsage(input: 12, cacheRead: 3)), // the input, announced at message_start
                           .text("Olá"), .reasoning(trace),
                           .toolCalls([ToolCallRequest(id: "tu_1", name: "ls", arguments: #"{"path":"."}"#)]),
                           .finished(.toolUse, TokenUsage(input: 12, output: 9, cacheRead: 3, cacheWrite: nil))])
        #expect(sent == Self.messagesSnapshot)
    }

    @Test func responsesRequestAndEvents() async throws {
        let sse = [
            #"{"type":"response.output_text.delta","output_index":0,"delta":"Olá"}"#,
            #"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"call_2","name":"ls","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.done","output_index":1,"arguments":"{\"path\":\".\"}"}"#,
            #"{"type":"response.completed","response":{"usage":{"input_tokens":50,"output_tokens":4,"input_tokens_details":{"cached_tokens":10}}}}"#,
        ].map { "data: \($0)\n\n" }.joined()
        let client = ResponsesClient(baseURL: URL(string: "https://golden-responses.test/v1")!, apiKey: "sk-r",
                                     extraHeaders: ["X-Extra": "yes"], toolsAsInputItem: true, conversationID: "bot-1",
                                     session: StubProtocol.session)
        let (events, sent) = try await run(client, host: "golden-responses.test", sse: sse)
        #expect(events == [.text("Olá"), .toolCalls([ToolCallRequest(id: "call_2", name: "ls", arguments: #"{"path":"."}"#)]),
                           .finished(.toolUse, TokenUsage(input: 40, output: 4, cacheRead: 10, cacheWrite: nil))])
        #expect(sent == Self.responsesSnapshot)
    }

    // MARK: Recorded requests

    static let chatSnapshot = #"""
POST https://golden-chat.test/v1/chat/completions
timeout=300
Authorization: Bearer sk-1
x-api-key: -
anthropic-version: -
Content-Type: application/json
Accept: text/event-stream
X-Extra: yes
User-Agent: Orb
{"model":"m-1","stream":true,"tools":[{"function":{"description":"Lists a folder","name":"ls","parameters":{"properties":{"path":"Folder"},"type":"object"}},"type":"function"}],"messages":[{"content":"Você é o Orb.","role":"system"},{"content":"Liste a pasta.","role":"user"},{"content":"Vou listar.","role":"assistant","tool_calls":[{"function":{"arguments":"{\"path\":\".\"}","name":"ls"},"id":"c1","type":"function"}]},{"content":"a.txt","role":"tool","tool_call_id":"c1"}]}
"""#
    static let messagesSnapshot = #"""
POST https://golden-messages.test/v1/messages
timeout=300
Authorization: Bearer sk-ant
x-api-key: sk-ant
anthropic-version: 2023-06-01
Content-Type: application/json
Accept: -
X-Extra: yes
User-Agent: Orb
{"max_tokens":16000,"model":"m-1","stream":true,"system":[{"cache_control":{"type":"ephemeral"},"text":"Você é o Orb.","type":"text"}],"tools":[{"cache_control":{"type":"ephemeral"},"description":"Lists a folder","input_schema":{"properties":{"path":"Folder"},"type":"object"},"name":"ls"}],"messages":[{"content":[{"text":"Liste a pasta.","type":"text"}],"role":"user"},{"content":[{"text":"Vou listar.","type":"text"},{"id":"c1","input":{"path":"."},"name":"ls","type":"tool_use"}],"role":"assistant"},{"content":[{"cache_control":{"type":"ephemeral"},"content":"a.txt","tool_use_id":"c1","type":"tool_result"}],"role":"user"}]}
"""#
    static let responsesSnapshot = #"""
POST https://golden-responses.test/v1/responses
timeout=300
Authorization: Bearer sk-r
x-api-key: -
anthropic-version: -
Content-Type: application/json
Accept: text/event-stream
X-Extra: yes
User-Agent: Orb
{"include":["reasoning.encrypted_content"],"instructions":"Você é o Orb.","model":"m-1","store":false,"stream":true,"input":[{"role":"developer","tools":[{"description":"Lists a folder","name":"ls","parameters":{"properties":{"path":"Folder"},"type":"object"},"strict":false,"type":"function"}],"type":"additional_tools"},{"content":"Liste a pasta.","role":"user"},{"content":"Vou listar.","role":"assistant"},{"arguments":"{\"path\":\".\"}","call_id":"c1","name":"ls","type":"function_call"},{"call_id":"c1","output":"a.txt","type":"function_call_output"}]}
"""#
}
