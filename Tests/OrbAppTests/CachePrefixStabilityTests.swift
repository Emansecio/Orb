import Foundation
import Testing
@testable import Orb

/// REVISAO-TOKENS-CONTAGEM: what the provider's prompt cache needs, checked on the wire of every format. The request of one
/// step of a tool loop must be, item by item, the start of the request of the next step (reasoning, calls and results
/// included), and what comes before the conversation (the tools, the system prompt) must not move at all.
struct CachePrefixStabilityTests {
    private let specs = [
        ToolSpec(name: "read_file", description: "Reads", parameters: .schema(["path": JSONValue.property("string"), "limit": JSONValue.property("integer")])),
        ToolSpec(name: "grep", description: "Searches", parameters: .schema(["pattern": JSONValue.property("string")])),
    ]

    private func trace(_ format: APIFormat) -> ReasoningTrace {
        switch format {
        case .responses:
            ReasoningTrace(format: .responses, provider: "api.openai.com", model: "gpt-x",
                           parts: [ReasoningPart(kind: .encrypted, text: "", data: "enc-1", id: "rs_1", callsBefore: 0),
                                   ReasoningPart(kind: .encrypted, text: "", data: "enc-2", id: "rs_2", callsBefore: 2)])
        default:
            ReasoningTrace(format: .messages, provider: "api.anthropic.com", model: "claude-x",
                           parts: [ReasoningPart(kind: .thinking, text: "penso", signature: "sig")])
        }
    }

    /// The history of a turn as it stands before step `n` (1...3).
    private func history(step n: Int, _ format: APIFormat) -> [ChatMessage] {
        var messages: [ChatMessage] = [.system("sistema"), .user("<orb_context>\nNow: x\n</orb_context>\nfaça")]
        let first = [ToolCallRequest(id: "c1", name: "read_file", arguments: #"{"path":"a","limit":5}"#),
                     ToolCallRequest(id: "c2", name: "grep", arguments: #"{"pattern":"x"}"#)]
        let second = [ToolCallRequest(id: "c3", name: "read_file", arguments: #"{"path":"b"}"#)]
        if n >= 2 {
            messages += [ChatMessage(role: .assistant, content: "vou ler", toolCalls: first, reasoning: trace(format)),
                         .tool("c1", "um"), .tool("c2", "dois")]
        }
        if n >= 3 {
            messages += [ChatMessage(role: .assistant, content: "", toolCalls: second, reasoning: trace(format)), .tool("c3", "três")]
        }
        return messages
    }

    private func body(_ format: APIFormat, _ messages: [ChatMessage]) -> JSONValue {
        switch format {
        case .messages:
            AnthropicClient.requestBody(model: "claude-x", messages: messages, tools: specs, maxTokens: 100, provider: "api.anthropic.com",
                                        marksTail: false)
        case .responses:
            ResponsesClient.requestBody(model: "gpt-x", messages: messages, tools: specs, promptCacheKey: "k", provider: "api.openai.com")
        default:
            OpenAIClient.requestBody(model: "m", messages: messages, tools: specs, includeUsage: true, promptCacheKey: "k")
        }
    }

    @Test(arguments: [APIFormat.messages, .responses, .chat])
    func eachStepsRequestIsTheStartOfTheNextOne(format: APIFormat) throws {
        let key = format == .responses ? "input" : "messages"
        let bodies = (1...3).map { body(format, history(step: $0, format)) }
        for (earlier, later) in zip(bodies, bodies.dropFirst()) {
            guard case .object(let a) = earlier, case .object(let b) = later else { Issue.record("not objects"); return }
            // Everything but the conversation is the same.
            for field in a.keys where field != key && field != "tool_choice" { #expect(a[field] == b[field], "\(field) moved") }
            let before = try #require(earlier[key]?.array), after = try #require(later[key]?.array)
            // The last item may grow (an Anthropic user turn takes the next step's results into the same turn): every item
            // before it is identical.
            let stable = before.count - 1
            #expect(after.count > stable)
            #expect(Array(before.prefix(stable)) == Array(after.prefix(stable)), "\(format): the start of the request changed")
        }
    }
}
