import Foundation
import Testing
@testable import Orb

struct ResponsesClientTests {
    @Test func convertsHistoryToResponsesItems() throws {
        let call = ToolCallRequest(id: "call_1", name: "list_directory", arguments: "")
        let body = ResponsesClient.requestBody(model: "gpt-x", messages: [
            .system("Seja breve."), .user("Liste"), ChatMessage(role: .assistant, content: "", toolCalls: [call]),
            .tool("call_1", "a.txt"),
        ], tools: [ToolSpec(name: "list_directory", description: "Lists", parameters: .schema([:]))])
        #expect(body["instructions"] == .string("Seja breve."))
        #expect(body["store"] == .bool(false))
        let input = try #require(body["input"]?.array)
        #expect(input.map { $0["type"]?.string ?? $0["role"]?.string } == ["user", "function_call", "function_call_output"])
        #expect(input[1]["arguments"] == .string("{}"))
        #expect(input[2]["call_id"] == .string("call_1"))
        #expect(body["tools"]?.array?.first?["name"] == .string("list_directory"))
    }

    @Test func assemblesTextAndFunctionCalls() throws {
        let events = [
            #"{"type":"response.output_text.delta","output_index":0,"delta":"Vou listar"}"#,
            #"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_7","name":"list_directory","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"path\":"}"#,
            #"{"type":"response.function_call_arguments.delta","output_index":1,"delta":"\"~\"}"}"#,
            #"{"type":"response.completed","response":{"id":"r"}}"#,
        ]
        var assembler = ResponsesStreamAssembler()
        var output: [LLMEvent] = []
        for event in events { output += try assembler.ingest(try #require(JSONValue.parse(event))) }
        #expect(output == [.text("Vou listar")])
        #expect(assembler.isFinished)
        #expect(assembler.toolCalls == [ToolCallRequest(id: "call_7", name: "list_directory", arguments: #"{"path":"~"}"#)])
    }

    @Test func failuresAreThrown() throws {
        var assembler = ResponsesStreamAssembler()
        #expect(throws: LLMError.self) {
            try assembler.ingest(#require(JSONValue.parse(#"{"type":"response.failed","response":{"error":{"message":"quota"}}}"#)))
        }
    }

    // MARK: Cache, reasoning

    @Test func sendsPromptCacheKeyAndAsksForEncryptedReasoning() {
        let body = ResponsesClient.requestBody(model: "gpt-x", messages: [.user("oi")], tools: [], promptCacheKey: "bot-1")
        #expect(body["prompt_cache_key"] == .string("bot-1"))
        #expect(body["include"] == .array([.string("reasoning.encrypted_content")]))
        #expect(ResponsesClient.requestBody(model: "m", messages: [], tools: [])["prompt_cache_key"] == nil)
    }

    @Test func aModelThatDoesNotReasonIsNotAskedForEncryptedReasoning() {
        for model in ["gpt-4.1-mini", "gpt-4o", "gpt-4o-mini", "chatgpt-4o-latest", "openai/gpt-4.1", "gpt-3.5-turbo"] {
            #expect(ResponsesClient.requestBody(model: model, messages: [.user("oi")], tools: [])["include"] == nil, "\(model)")
        }
        for model in ["gpt-5", "o4-mini", "o3", "gpt-5.1-codex", "um-modelo-novo"] {
            #expect(ResponsesClient.requestBody(model: model, messages: [.user("oi")], tools: [])["include"]
                == .array([.string("reasoning.encrypted_content")]), "\(model)")
        }
        // The ChatGPT backend always gets it.
        #expect(ResponsesClient.requestBody(model: "gpt-4.1", messages: [], tools: [], toolsAsInputItem: true)["include"] != nil)
    }

    private let reasoningStream = [
        #"{"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[]}}"#,
        #"{"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"Vou listar."}],"encrypted_content":"gAAAA=="}}"#,
        #"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_7","name":"list_directory","arguments":""}}"#,
        #"{"type":"response.function_call_arguments.done","output_index":1,"arguments":"{\"path\":\"~\"}"}"#,
        #"{"type":"response.completed","response":{"usage":{"input_tokens":200,"output_tokens":30,"input_tokens_details":{"cached_tokens":150}}}}"#,
    ]

    private func ingest(_ events: [String]) throws -> (output: [LLMEvent], assembler: ResponsesStreamAssembler) {
        var assembler = ResponsesStreamAssembler()
        var output: [LLMEvent] = []
        for event in events { output += try assembler.ingest(try #require(JSONValue.parse(event))) }
        return (output, assembler)
    }

    @Test func recordsEncryptedReasoningItemsAndUsage() throws {
        let (_, assembler) = try ingest(reasoningStream)
        #expect(assembler.reasoning == [ReasoningPart(kind: .encrypted, text: "Vou listar.", data: "gAAAA==", id: "rs_1", callsBefore: 0)])
        #expect(assembler.stopReason == .toolUse)
        #expect(assembler.usage == TokenUsage(input: 50, output: 30, cacheRead: 150, cacheWrite: nil))
        // A reasoning item without encrypted content cannot be replayed statelessly.
        let (_, plain) = try ingest([#"{"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs","summary":[]}}"#])
        #expect(plain.reasoning.isEmpty)
    }

    @Test func sendsReasoningItemsBeforeTheirFunctionCalls() throws {
        let (_, assembler) = try ingest(reasoningStream)
        let trace = ReasoningTrace(format: .responses, provider: "api.openai.com", model: "gpt-x", parts: assembler.reasoning)
        let call = ToolCallRequest(id: "call_7", name: "list_directory", arguments: #"{"path":"~"}"#)
        let messages: [ChatMessage] = [
            .user("Liste"), ChatMessage(role: .assistant, content: "Listando.", toolCalls: [call], reasoning: trace),
            .tool("call_7", "a.txt"),
        ]
        let body = ResponsesClient.requestBody(model: "gpt-x", messages: messages, tools: [], provider: "api.openai.com")
        let input = try #require(body["input"]?.array)
        #expect(input.map { $0["type"]?.string ?? $0["role"]?.string } == ["user", "reasoning", "assistant", "function_call", "function_call_output"])
        let item = input[1]
        #expect(item["encrypted_content"] == .string("gAAAA=="))
        #expect(item["summary"] == .array([.object(["type": .string("summary_text"), "text": .string("Vou listar.")])]))
        #expect(item["id"] == .string("rs_1")) // the API requires the id on a replayed reasoning item
    }

    @Test func keepsReasoningItemsNextToTheCallsTheyProduced() throws {
        let (_, assembler) = try ingest([
            #"{"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_a","summary":[],"encrypted_content":"A"}}"#,
            #"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"c1","name":"one","arguments":"{}"}}"#,
            #"{"type":"response.output_item.done","output_index":2,"item":{"type":"reasoning","id":"rs_b","summary":[],"encrypted_content":"B"}}"#,
            #"{"type":"response.output_item.added","output_index":3,"item":{"type":"function_call","call_id":"c2","name":"two","arguments":"{}"}}"#,
            #"{"type":"response.output_item.done","output_index":4,"item":{"type":"reasoning","id":"rs_c","summary":[],"encrypted_content":"C"}}"#,
            #"{"type":"response.completed","response":{}}"#,
        ])
        #expect(assembler.reasoning.map(\.callsBefore) == [0, 1, 2])
        let trace = ReasoningTrace(format: .responses, provider: "api.openai.com", model: "gpt-x", parts: assembler.reasoning)
        let message = ChatMessage(role: .assistant, content: "", toolCalls: assembler.toolCalls, reasoning: trace)
        let body = ResponsesClient.requestBody(model: "gpt-x", messages: [.user("u"), message], tools: [], provider: "api.openai.com")
        let input = try #require(body["input"]?.array)
        // The trailing item (nothing after it) is left out.
        #expect(input.map { $0["id"]?.string ?? $0["call_id"]?.string ?? $0["role"]?.string } == ["user", "rs_a", "c1", "rs_b", "c2"])
    }

    @Test func dropsReasoningSavedWithoutAnId() throws {
        let old = ReasoningPart(kind: .encrypted, text: "t", data: "blob")
        let trace = ReasoningTrace(format: .responses, provider: "api.openai.com", model: "gpt-x", parts: [old])
        let call = ToolCallRequest(id: "c", name: "n", arguments: "{}")
        let message = ChatMessage(role: .assistant, content: "", toolCalls: [call], reasoning: trace)
        let body = ResponsesClient.requestBody(model: "gpt-x", messages: [.user("u"), message], tools: [], provider: "api.openai.com")
        #expect(try #require(body["input"]?.array).map { $0["type"]?.string ?? $0["role"]?.string } == ["user", "function_call"])
    }

    @Test func skipsReasoningThatCannotBeUsed() throws {
        let part = ReasoningPart(kind: .encrypted, data: "blob", id: "rs_1")
        let call = ToolCallRequest(id: "c", name: "n", arguments: "{}")
        func types(_ trace: ReasoningTrace, content: String = "", calls: [ToolCallRequest]) throws -> [String?] {
            let message = ChatMessage(role: .assistant, content: content, toolCalls: calls, reasoning: trace)
            let body = ResponsesClient.requestBody(model: "gpt-x", messages: [.user("u"), message], tools: [], provider: "api.openai.com")
            return try #require(body["input"]?.array).map { $0["type"]?.string ?? $0["role"]?.string }
        }
        let own = ReasoningTrace(format: .responses, provider: "api.openai.com", model: "gpt-x", parts: [part])
        #expect(try types(own, calls: [call]) == ["user", "reasoning", "function_call"])
        // Another provider, model or format: never sent.
        #expect(try types(ReasoningTrace(format: .responses, provider: "other.test", model: "gpt-x", parts: [part]), calls: [call]) == ["user", "function_call"])
        #expect(try types(ReasoningTrace(format: .responses, provider: "api.openai.com", model: "gpt-y", parts: [part]), calls: [call]) == ["user", "function_call"])
        #expect(try types(ReasoningTrace(format: .messages, provider: "api.openai.com", model: "gpt-x",
                                         parts: [ReasoningPart(kind: .thinking, text: "t", signature: "s")]), calls: [call]) == ["user", "function_call"])
        // A reasoning item must be followed by its output: an empty reply sends none.
        #expect(try types(own, calls: []) == ["user"])
    }

    // MARK: Stop reasons

    @Test func incompleteResponsesCarryTheirReason() throws {
        let stop = { (reason: String) throws -> StopReason in
            try ingest([#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"\#(reason)"}}}"#]).assembler.stopReason
        }
        #expect(try stop("max_output_tokens") == .maxTokens)
        #expect(try stop("content_filter") == .refusal)
        #expect(try stop("something_else") == .incomplete)
        #expect(try ingest([#"{"type":"response.output_text.delta","delta":"x"}"#]).assembler.stopReason == .incomplete)
        #expect(try ingest([#"{"type":"response.completed","response":{}}"#]).assembler.stopReason == .done)
        #expect(try ingest([#"{"type":"response.completed","response":{}}"#]).assembler.usage == nil)
    }

    @Test func refusalsAreShownAndReported() throws {
        let (output, assembler) = try ingest([
            #"{"type":"response.refusal.delta","output_index":0,"delta":"Não posso ajudar."}"#,
            #"{"type":"response.refusal.done","output_index":0,"refusal":"Não posso ajudar."}"#,
            #"{"type":"response.completed","response":{}}"#,
        ])
        #expect(output == [.text("Não posso ajudar.")])
        #expect(assembler.stopReason == .refusal)
        // A refusal inside a finished message item counts too.
        let (_, viaItem) = try ingest([
            #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","content":[{"type":"refusal","refusal":"no"}]}}"#,
            #"{"type":"response.completed","response":{}}"#,
        ])
        #expect(viaItem.stopReason == .refusal)
    }

    @Test func failuresKeepTheirCodeAndContextOverflowIsDistinct() throws {
        var assembler = ResponsesStreamAssembler()
        let event = try #require(JSONValue.parse(#"{"type":"response.failed","response":{"error":{"code":"server_error","message":"oops"}}}"#))
        let error = try #require(#expect(throws: LLMError.self) {
            _ = try assembler.ingest(event)
        })
        #expect(error == .stream(type: "server_error", message: "oops"))
        #expect(error.isRetryable)
        let secondEvent = try #require(JSONValue.parse(#"{"type":"response.failed","response":{"error":{"code":"context_length_exceeded","message":"Too long"}}}"#))
        let secondError = try #require(#expect(throws: LLMError.self) {
            _ = try assembler.ingest(secondEvent)
        })
        #expect(secondError == .contextExceeded("Too long"))
        let thirdEvent = try #require(JSONValue.parse(#"{"type":"error","code":"rate_limit_exceeded","message":"Slow down"}"#))
        let thirdError = try #require(#expect(throws: LLMError.self) {
            _ = try assembler.ingest(thirdEvent)
        })
        #expect(thirdError == .stream(type: "rate_limit_exceeded", message: "Slow down"))
    }

    // MARK: End to end (stubbed network)

    @Test func streamsReasoningCallsAndFinishWithTheCacheKey() async throws {
        let sse = reasoningStream.map { "data: \($0)\n\n" }.joined()
        StubProtocol.queue(host: "chatgpt.com", [.init(body: sse)])
        let client = ResponsesClient(baseURL: URL(string: "https://chatgpt.com/v1")!, apiKey: "k", conversationID: "bot-9",
                                     session: StubProtocol.session)
        var events: [LLMEvent] = []
        for try await event in client.stream(model: "gpt-x", messages: [.user("oi")], tools: []) { events.append(event) }
        let trace = ReasoningTrace(format: .responses, provider: "chatgpt.com", model: "gpt-x",
                                   parts: [ReasoningPart(kind: .encrypted, text: "Vou listar.", data: "gAAAA==", id: "rs_1", callsBefore: 0)])
        #expect(events == [
            .reasoning(trace),
            .toolCalls([ToolCallRequest(id: "call_7", name: "list_directory", arguments: #"{"path":"~"}"#)]),
            .finished(.toolUse, TokenUsage(input: 50, output: 30, cacheRead: 150, cacheWrite: nil)),
        ])
        let sent = try #require(StubProtocol.sent(to: "chatgpt.com").first)
        #expect(sent.body?["prompt_cache_key"] == .string("bot-9"))
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func a401RefreshesTheTokenAndRetriesOnce() async throws {
        StubProtocol.queue(host: "responses-401.test", [
            .init(status: 401, body: #"{"error":{"message":"token expired"}}"#),
            .init(body: "data: {\"type\":\"response.completed\",\"response\":{}}\n\n"),
        ])
        let asked = Box<[Bool]>([])
        let client = ResponsesClient(baseURL: URL(string: "https://responses-401.test/v1")!, credentials: { force in
            asked.update { $0.append(force) }
            return force ? "new" : "old"
        }, session: StubProtocol.session)
        var events: [LLMEvent] = []
        for try await event in client.stream(model: "m", messages: [.user("oi")], tools: []) { events.append(event) }
        #expect(events == [.finished(.done, nil)])
        #expect(asked.value == [false, true])
        #expect(StubProtocol.sent(to: "responses-401.test").map { $0.request.value(forHTTPHeaderField: "Authorization") } == ["Bearer old", "Bearer new"])
    }
}

extension ResponsesClientTests {
    @Test func toolChoiceNoneKeepsTheToolsAndForbidsCalls() {
        let tools = [ToolSpec(name: "a", description: "A", parameters: .schema([:]))]
        for asInputItem in [false, true] {
            let auto = ResponsesClient.requestBody(model: "m", messages: [.user("oi")], tools: tools, toolsAsInputItem: asInputItem)
            let none = ResponsesClient.requestBody(model: "m", messages: [.user("oi")], tools: tools, toolsAsInputItem: asInputItem,
                                                   toolChoice: .none)
            #expect(auto["tool_choice"] == nil)
            if asInputItem {
                // No `tool_choice` without top-level tools: the instruction is a final developer message instead.
                #expect(none["tool_choice"] == nil && none["tools"] == nil)
                let sent = none["input"]?.array ?? []
                #expect(sent.count == (auto["input"]?.array ?? []).count + 1)
                #expect(sent.last?["content"] == .string(ResponsesClient.noToolsInstruction))
                #expect(sent.last?["role"] == .string("developer"))
            } else {
                #expect(none["tool_choice"] == .string("none"))
                #expect(none["tools"] == auto["tools"] && none["input"] == auto["input"])
            }
        }
        #expect(ResponsesClient.requestBody(model: "m", messages: [.user("oi")], tools: [], toolChoice: .none)["tool_choice"] == nil)
    }
}
