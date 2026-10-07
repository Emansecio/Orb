import Foundation
import Testing
@testable import OpenBotMac

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
}
