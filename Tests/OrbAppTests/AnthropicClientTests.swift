import Foundation
import Testing
@testable import Orb

struct AnthropicClientTests {
    @Test func convertsHistoryToMessagesFormat() throws {
        let call = ToolCallRequest(id: "toolu_1", name: "read_file", arguments: #"{"path":"a.txt"}"#)
        let body = AnthropicClient.requestBody(model: "claude-x", messages: [
            .system("Seja breve."), .user("Leia a.txt"),
            ChatMessage(role: .assistant, content: "Vou ler.", toolCalls: [call]),
            .tool("toolu_1", "conteúdo"), .user("e agora?"),
        ], tools: [ToolSpec(name: "read_file", description: "Reads", parameters: .schema([:]))], maxTokens: 1000)

        // The system prompt is a block so it can carry a cache marker.
        #expect(body["system"] == .array([.object(["type": .string("text"), "text": .string("Seja breve."),
                                                   "cache_control": .object(["type": .string("ephemeral")])])]))
        #expect(body["max_tokens"] == .number(1000))
        let turns = try #require(body["messages"]?.array)
        #expect(turns.map { $0["role"]?.string } == ["user", "assistant", "user"])
        let assistant = try #require(turns[1]["content"]?.array)
        #expect(assistant[1]["type"] == .string("tool_use"))
        #expect(assistant[1]["input"]?["path"] == .string("a.txt"))
        // The tool result and the next user text share one user turn.
        let last = try #require(turns[2]["content"]?.array)
        #expect(last.map { $0["type"]?.string } == ["tool_result", "text"])
        #expect(last[0]["cache_control"] == nil) // only the last block of the last message is marked
        #expect(last[1]["cache_control"] == .object(["type": .string("ephemeral")]))
        #expect(last[0]["tool_use_id"] == .string("toolu_1"))
        #expect(body["tools"]?.array?.first?["input_schema"]?["type"] == .string("object"))
    }

    @Test func assemblesStreamedTextAndToolUse() throws {
        let events = [
            #"{"type":"message_start","message":{"id":"m"}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Vou ler"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_9","name":"read_file","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"a.txt\"}"}}"#,
            #"{"type":"message_stop"}"#,
        ]
        var assembler = AnthropicStreamAssembler()
        var output: [LLMEvent] = []
        for event in events { output += try assembler.ingest(try #require(JSONValue.parse(event))) }
        #expect(output == [.text("Vou ler")])
        #expect(assembler.isFinished)
        #expect(assembler.toolCalls == [ToolCallRequest(id: "toolu_9", name: "read_file", arguments: #"{"path":"a.txt"}"#)])
    }

    @Test func streamErrorsAreThrown() throws {
        var assembler = AnthropicStreamAssembler()
        #expect(throws: LLMError.self) {
            try assembler.ingest(#require(JSONValue.parse(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)))
        }
    }

    @Test func marksTheCacheablePrefixWithAtMostFourMarkers() throws {
        let tools = [ToolSpec(name: "a", description: "A", parameters: .schema([:])), ToolSpec(name: "b", description: "B", parameters: .schema([:]))]
        let body = AnthropicClient.requestBody(model: "m", messages: [.system("s"), .user("1"), .user("2")], tools: tools, maxTokens: 10)
        let text = body.jsonString
        let markers = text.components(separatedBy: #""cache_control""#).count - 1
        #expect(markers == 3 && markers <= 4)
        let specs = try #require(body["tools"]?.array)
        #expect(specs[0]["cache_control"] == nil)
        #expect(specs[1]["cache_control"] == .object(["type": .string("ephemeral")]))
        // No system prompt, no tools: only the conversation tail is marked.
        let bare = AnthropicClient.requestBody(model: "m", messages: [.user("oi")], tools: [], maxTokens: 10)
        #expect(bare["system"] == nil && bare["tools"] == nil)
        #expect(bare.jsonString.components(separatedBy: #""cache_control""#).count - 1 == 1)
    }

    @Test func aLongTaskGetsAFourthMarkerWhereItsPreviewsEnd() throws {
        let tools = [ToolSpec(name: "a", description: "A", parameters: .schema([:]))]
        var history: [ChatMessage] = [.system("s"), .user("faça")]
        for step in 0..<4 {
            history.append(ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: "c\(step)", name: "a", arguments: "{}")]))
            history.append(.tool("c\(step)", "saída \(step)"))
        }
        func markers(_ body: JSONValue) -> Int { body.jsonString.components(separatedBy: #""cache_control""#).count - 1 }
        func marked(_ body: JSONValue) throws -> [String] {
            try #require(body["messages"]?.array).flatMap { $0["content"]?.array ?? [] }
                .filter { $0["cache_control"] != nil }.compactMap { $0["tool_use_id"]?.string }
        }
        let body = AnthropicClient.requestBody(model: "m", messages: history, tools: tools, maxTokens: 10, stableToolCallID: "c1")
        #expect(markers(body) == 4)
        #expect(try marked(body) == ["c1", "c3"]) // the stable end, and the tail
        // An id the request no longer has (set aside, folded) adds nothing; the tail itself is one marker, not two.
        #expect(markers(AnthropicClient.requestBody(model: "m", messages: history, tools: tools, maxTokens: 10, stableToolCallID: "x")) == 3)
        #expect(markers(AnthropicClient.requestBody(model: "m", messages: history, tools: tools, maxTokens: 10, stableToolCallID: "c3")) == 3)
        // A history from another provider that repeats ids still gets one marker for it.
        let repeated = history + [ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: "c1", name: "a", arguments: "{}")]),
                                  .tool("c1", "de novo"), .user("e agora?")]
        #expect(markers(AnthropicClient.requestBody(model: "m", messages: repeated, tools: tools, maxTokens: 10, stableToolCallID: "c1")) == 4)
        // The client carries it; a short reply drops it.
        let client = AnthropicClient(baseURL: URL(string: "https://api.anthropic.com/v1")!, apiKey: "k")
        let stable = try #require(client.markingStable(upTo: "c1") as? AnthropicClient)
        #expect(stable.stableToolCallID == "c1")
        #expect((stable.forShortReply as? AnthropicClient)?.stableToolCallID == nil)
    }

    // MARK: Stop reason and usage

    private func ingest(_ events: [String]) throws -> (output: [LLMEvent], assembler: AnthropicStreamAssembler) {
        var assembler = AnthropicStreamAssembler()
        var output: [LLMEvent] = []
        for event in events { output += try assembler.ingest(try #require(JSONValue.parse(event))) }
        return (output, assembler)
    }

    @Test func readsStopReasonAndUsage() throws {
        let (_, assembler) = try ingest([
            #"{"type":"message_start","message":{"id":"m","usage":{"input_tokens":25,"output_tokens":1,"cache_creation_input_tokens":300,"cache_read_input_tokens":1200}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"now","input":{}}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#,
            #"{"type":"message_stop"}"#,
        ])
        #expect(assembler.stopReason == .toolUse)
        #expect(assembler.usage == TokenUsage(input: 25, output: 42, cacheRead: 1200, cacheWrite: 300))
    }

    /// REVISAO-TOKENS-CONTAGEM P1-1: a gateway that repeats zeros in `message_delta` wiped the prompt `message_start` reported.
    @Test func aLaterEventNeverLowersWhatTheFirstOneReported() throws {
        let (_, assembler) = try ingest([
            #"{"type":"message_start","message":{"id":"m","usage":{"input_tokens":25,"output_tokens":1,"cache_creation_input_tokens":300,"cache_read_input_tokens":1200,"cache_creation":{"ephemeral_1h_input_tokens":200}}}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":42}}"#,
            #"{"type":"message_stop"}"#,
        ])
        #expect(assembler.usage == TokenUsage(input: 25, output: 42, cacheRead: 1200, cacheWrite: 300, cacheWrite1h: 200))
    }

    /// REVISAO-TOKENS-CONTAGEM P1-2: a response cut before `message_delta` was billed for what it had written.
    @Test func aResponseCutOffCountsWhatItHadWritten() throws {
        let words = String(repeating: "a", count: 3_500)
        let partial = [
            #"{"type":"message_start","message":{"id":"m","usage":{"input_tokens":25,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(words)"}}"#,
        ]
        let (_, cut) = try ingest(partial)
        #expect(cut.usage?.input == 25)
        #expect(cut.usage?.output == ContextBudget.tokens(forCharacters: 3_500))
        // With the provider's own closing count that count stands, whatever the estimate says.
        let (_, whole) = try ingest(partial + [#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#])
        #expect(whole.usage?.output == 7)
    }

    @Test func mapsStopReasons() {
        let map = { (reason: String?, calls: Bool) in AnthropicStreamAssembler.stopReason(reason, hasToolCalls: calls) }
        #expect(map("end_turn", false) == .done)
        #expect(map("stop_sequence", false) == .done)
        #expect(map("tool_use", true) == .toolUse)
        #expect(map("max_tokens", false) == .maxTokens)
        #expect(map("refusal", false) == .refusal)
        #expect(map("model_context_window_exceeded", false) == .contextExceeded)
        #expect(map("pause_turn", false) == .incomplete)
        #expect(map("something_new", false) == .unknown("something_new"))
        #expect(map(nil, false) == .done)
    }

    @Test func aStreamWithoutMessageStopIsIncomplete() throws {
        let (_, assembler) = try ingest([#"{"type":"message_start","message":{"usage":{"input_tokens":3}}}"#])
        #expect(!assembler.isFinished)
        #expect(assembler.stopReason == .incomplete)
        #expect(assembler.usage?.input == 3)
        #expect(try ingest([]).assembler.usage == nil)
    }

    @Test func inStreamErrorsKeepTheirTypeAndAreRetryable() throws {
        for type in ["overloaded_error", "api_error"] {
            var assembler = AnthropicStreamAssembler()
            let event = try #require(JSONValue.parse(#"{"type":"error","error":{"type":"\#(type)","message":"Overloaded"}}"#))
            let error = try #require(#expect(throws: LLMError.self) {
                _ = try assembler.ingest(event)
            })
            #expect(error == .stream(type: type, message: "Overloaded"))
            #expect(error.isRetryable)
        }
        var assembler = AnthropicStreamAssembler()
        let event = try #require(JSONValue.parse(#"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 9 > 8"}}"#))
        let error = try #require(#expect(throws: LLMError.self) {
            _ = try assembler.ingest(event)
        })
        guard case .contextExceeded = error else { Issue.record("not mapped: \(error)"); return }
    }

    // MARK: Reasoning

    private let thinkingStream = [
        #"{"type":"message_start","message":{"usage":{"input_tokens":5}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Preciso "}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"ler o arquivo."}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBsig=="}}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"opaque=="}}"#,
        #"{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Vou ler."}}"#,
        #"{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file","input":{}}}"#,
        #"{"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"a.txt\"}"}}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#,
        #"{"type":"message_stop"}"#,
    ]

    @Test func recordsThinkingBlocksWithTheirSignatures() throws {
        let (output, assembler) = try ingest(thinkingStream)
        #expect(output == [.text("Vou ler.")]) // thinking is never shown as text
        #expect(assembler.reasoning == [
            ReasoningPart(kind: .thinking, text: "Preciso ler o arquivo.", signature: "EqQBsig=="),
            ReasoningPart(kind: .redactedThinking, data: "opaque=="),
        ])
    }

    @Test func sendsThinkingBackFirstAndUnchanged() throws {
        let (_, assembler) = try ingest(thinkingStream)
        let trace = ReasoningTrace(format: .messages, provider: "api.anthropic.com", model: "claude-x", parts: assembler.reasoning)
        let call = ToolCallRequest(id: "toolu_1", name: "read_file", arguments: #"{"path":"a.txt"}"#)
        let history: [ChatMessage] = [
            .user("Leia a.txt"),
            ChatMessage(role: .assistant, content: "Vou ler.", toolCalls: [call], reasoning: trace),
            .tool("toolu_1", "conteúdo"),
        ]
        let body = AnthropicClient.requestBody(model: "claude-x", messages: history, tools: [], maxTokens: 10, provider: "api.anthropic.com")
        let assistant = try #require(body["messages"]?.array?[1]["content"]?.array)
        #expect(assistant.map { $0["type"]?.string } == ["thinking", "redacted_thinking", "text", "tool_use"])
        #expect(assistant[0]["thinking"] == .string("Preciso ler o arquivo."))
        #expect(assistant[0]["signature"] == .string("EqQBsig=="))
        #expect(assistant[1]["data"] == .string("opaque=="))
        // Thinking blocks are never marked for caching.
        #expect(assistant.allSatisfy { $0["cache_control"] == nil })
    }

    @Test func doesNotSendThinkingInAFinalAssistantTurn() throws {
        let trace = ReasoningTrace(format: .messages, provider: "api.anthropic.com", model: "claude-x",
                                   parts: [ReasoningPart(kind: .thinking, text: "t", signature: "sig")])
        let history: [ChatMessage] = [.user("u"), ChatMessage(role: .assistant, content: "Parcial", reasoning: trace)]
        let body = AnthropicClient.requestBody(model: "claude-x", messages: history, tools: [], maxTokens: 10, provider: "api.anthropic.com")
        #expect(try #require(body["messages"]?.array?[1]["content"]?.array).map { $0["type"]?.string } == ["text"])
    }

    @Test func doesNotSendReasoningFromAnotherProviderFormatOrModel() throws {
        let part = ReasoningPart(kind: .thinking, text: "t", signature: "sig")
        let call = ToolCallRequest(id: "c", name: "n", arguments: "{}")
        func types(_ trace: ReasoningTrace) throws -> [String?] {
            let message = ChatMessage(role: .assistant, content: "", toolCalls: [call], reasoning: trace)
            let body = AnthropicClient.requestBody(model: "claude-x", messages: [.user("u"), message, .tool("c", "ok")],
                                                   tools: [], maxTokens: 10, provider: "api.anthropic.com")
            return try #require(body["messages"]?.array?[1]["content"]?.array).map { $0["type"]?.string }
        }
        #expect(try types(ReasoningTrace(format: .messages, provider: "api.anthropic.com", model: "claude-x", parts: [part])) == ["thinking", "tool_use"])
        #expect(try types(ReasoningTrace(format: .messages, provider: "gateway.example", model: "claude-x", parts: [part])) == ["tool_use"])
        #expect(try types(ReasoningTrace(format: .messages, provider: "api.anthropic.com", model: "other-model", parts: [part])) == ["tool_use"])
        #expect(try types(ReasoningTrace(format: .responses, provider: "api.anthropic.com", model: "claude-x",
                                         parts: [ReasoningPart(kind: .encrypted, data: "x")])) == ["tool_use"])
        // A thinking block without its signature would be rejected, so it is dropped.
        #expect(try types(ReasoningTrace(format: .messages, provider: "api.anthropic.com", model: "claude-x",
                                         parts: [ReasoningPart(kind: .thinking, text: "t")])) == ["tool_use"])
    }

    // MARK: End to end (stubbed network)

    private func client(host: String, credentials: @escaping CredentialsProvider) -> AnthropicClient {
        AnthropicClient(baseURL: URL(string: "https://\(host)/v1")!, credentials: credentials, session: StubProtocol.session)
    }

    @Test func streamsThinkingToolCallsAndFinish() async throws {
        let sse = thinkingStream.map { "data: \($0)\n\n" }.joined()
        StubProtocol.queue(host: "anthropic-stream.test", [.init(body: sse)])
        let client = client(host: "anthropic-stream.test") { _ in "sk-ant" }
        var events: [LLMEvent] = []
        for try await event in client.stream(model: "claude-x", messages: [.user("oi")], tools: []) { events.append(event) }

        let trace = ReasoningTrace(format: .messages, provider: "anthropic-stream.test", model: "claude-x", parts: [
            ReasoningPart(kind: .thinking, text: "Preciso ler o arquivo.", signature: "EqQBsig=="),
            ReasoningPart(kind: .redactedThinking, data: "opaque=="),
        ])
        #expect(events == [
            .usage(TokenUsage(input: 5)), // the input tokens, announced as soon as message_start is read
            .text("Vou ler."), .reasoning(trace),
            .toolCalls([ToolCallRequest(id: "toolu_1", name: "read_file", arguments: #"{"path":"a.txt"}"#)]),
            .finished(.toolUse, TokenUsage(input: 5, output: 9, cacheRead: nil, cacheWrite: nil)),
        ])
        let sent = try #require(StubProtocol.sent(to: "anthropic-stream.test").first)
        #expect(sent.request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(sent.body?["system"] == nil)
    }

    @Test func a401RefreshesTheKeyAndRetriesOnce() async throws {
        StubProtocol.queue(host: "anthropic-401.test", [
            .init(status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#),
            .init(body: "data: {\"type\":\"message_stop\"}\n\n"),
        ])
        let asked = Box<[Bool]>([])
        let client = client(host: "anthropic-401.test") { force in
            asked.update { $0.append(force) }
            return force ? "new" : "old"
        }
        var events: [LLMEvent] = []
        for try await event in client.stream(model: "m", messages: [.user("oi")], tools: []) { events.append(event) }
        #expect(events == [.finished(.done, nil)])
        #expect(asked.value == [false, true])
        #expect(StubProtocol.sent(to: "anthropic-401.test").map { $0.request.value(forHTTPHeaderField: "x-api-key") } == ["old", "new"])
    }

    @Test func aStreamThatBreaksOffAfterTheInputWasReportedStillReportsIt() async throws {
        StubProtocol.queue(host: "anthropic-broken.test", [.init(body: """
            data: {"type":"message_start","message":{"usage":{"input_tokens":1200,"output_tokens":1}}}

            data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}


            """)])
        let client = client(host: "anthropic-broken.test") { _ in "k" }
        var events: [LLMEvent] = []
        let error = try #require(await #expect(throws: LLMError.self) {
            for try await event in client.stream(model: "m", messages: [.user("oi")], tools: []) { events.append(event) }
        })
        #expect(error.isRetryable)
        // The input is billed whether or not the answer arrives: it is announced as soon as it is read, and comes again ahead of the error.
        let used = TokenUsage(input: 1200, output: 1)
        #expect(events == [.usage(used), .finished(.incomplete, used)])
    }

    @Test func overloadedHTTPResponsesAreRetryableWithTheirDelay() async throws {
        StubProtocol.queue(host: "anthropic-529.test", [
            .init(status: 529, body: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, headers: ["retry-after": "3"]),
        ])
        let client = client(host: "anthropic-529.test") { _ in "k" }
        let error = try #require(await #expect(throws: LLMError.self) {
            for try await _ in client.stream(model: "m", messages: [.user("oi")], tools: []) {}
        })
        #expect(error == .http(status: 529, message: "Overloaded", retryAfter: 3))
        #expect(error.isRetryable)
    }
}

extension AnthropicClientTests {
    @Test func flagsFailedToolResultsAsErrors() throws {
        let call = ToolCallRequest(id: "t1", name: "read_file", arguments: "{}")
        let body = AnthropicClient.requestBody(model: "claude-x", messages: [
            .user("oi"), ChatMessage(role: .assistant, content: "", toolCalls: [call, ToolCallRequest(id: "t2", name: "x", arguments: "{}")]),
            .tool("t1", "Error: não achei", isError: true), .tool("t2", "ok"),
        ], tools: [], maxTokens: 10)
        let results = try #require(body["messages"]?.array?.last?["content"]?.array)
        #expect(results[0]["is_error"] == .bool(true))
        #expect(results[1]["is_error"] == nil)
    }

    @Test func toolChoiceNoneKeepsTheToolsAndForbidsCalls() {
        let tools = [ToolSpec(name: "a", description: "A", parameters: .schema([:]))]
        let auto = AnthropicClient.requestBody(model: "m", messages: [.user("oi")], tools: tools, maxTokens: 10)
        let none = AnthropicClient.requestBody(model: "m", messages: [.user("oi")], tools: tools, maxTokens: 10, toolChoice: .none)
        #expect(auto["tool_choice"] == nil)
        #expect(none["tool_choice"] == .object(["type": .string("none")]))
        #expect(none["tools"] == auto["tools"]) // same prefix, so the provider's cache still applies
        // Nothing to forbid without tools (the API rejects tool_choice then).
        #expect(AnthropicClient.requestBody(model: "m", messages: [.user("oi")], tools: [], maxTokens: 10, toolChoice: .none)["tool_choice"] == nil)
    }
}
