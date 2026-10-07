import Foundation
import Testing
@testable import OpenBotMac

struct AnthropicClientTests {
    @Test func convertsHistoryToMessagesFormat() throws {
        let call = ToolCallRequest(id: "toolu_1", name: "read_file", arguments: #"{"path":"a.txt"}"#)
        let body = AnthropicClient.requestBody(model: "claude-x", messages: [
            .system("Seja breve."), .user("Leia a.txt"),
            ChatMessage(role: .assistant, content: "Vou ler.", toolCalls: [call]),
            .tool("toolu_1", "conteúdo"), .user("e agora?"),
        ], tools: [ToolSpec(name: "read_file", description: "Reads", parameters: .schema([:]))], maxTokens: 1000)

        #expect(body["system"] == .string("Seja breve."))
        #expect(body["max_tokens"] == .number(1000))
        let turns = try #require(body["messages"]?.array)
        #expect(turns.map { $0["role"]?.string } == ["user", "assistant", "user"])
        let assistant = try #require(turns[1]["content"]?.array)
        #expect(assistant[1]["type"] == .string("tool_use"))
        #expect(assistant[1]["input"]?["path"] == .string("a.txt"))
        // The tool result and the next user text share one user turn.
        let last = try #require(turns[2]["content"]?.array)
        #expect(last.map { $0["type"]?.string } == ["tool_result", "text"])
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
}
