import Foundation
import Testing
@testable import Orb

struct ReasoningTests {
    private let trace = ReasoningTrace(format: .messages, provider: "api.anthropic.com", model: "claude-x", parts: [
        ReasoningPart(kind: .thinking, text: "pensando", signature: "sig"),
        ReasoningPart(kind: .redactedThinking, data: "blob"),
        ReasoningPart(kind: .encrypted, text: "resumo", data: "enc"),
    ])

    @Test func reasoningSurvivesAJSONRoundTrip() throws {
        let call = ToolCallRequest(id: "c", name: "n", arguments: "{}")
        let message = ChatMessage(role: .assistant, content: "oi", toolCalls: [call], reasoning: trace)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded == message)
    }

    @Test func messagesSavedBeforeReasoningExistedStillDecode() throws {
        let old = #"{"role":"assistant","content":"oi","toolCalls":[{"id":"c","name":"n","arguments":"{}"}]}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8))
        #expect(message.content == "oi")
        #expect(message.toolCalls.count == 1)
        #expect(message.reasoning == nil)
        let minimal = try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"role":"user"}"#.utf8))
        #expect(minimal.content.isEmpty && minimal.toolCalls.isEmpty)
    }

    @Test func aReasoningTraceThisVersionCannotReadDoesNotLoseTheMessage() throws {
        let futureKind = #"{"role":"assistant","content":"oi","reasoning":{"format":"messages","provider":"p","model":"m","parts":[{"kind":"hologram"}]}}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(futureKind.utf8))
        #expect(message.content == "oi")
        #expect(message.reasoning == nil)
        let futureFormat = #"{"role":"assistant","content":"oi","reasoning":{"format":"telepathy","provider":"p","model":"m","parts":[]}}"#
        #expect(try JSONDecoder().decode(ChatMessage.self, from: Data(futureFormat.utf8)).content == "oi")
    }

    @Test func partsDecodeWithOnlyTheirKind() throws {
        let part = try JSONDecoder().decode(ReasoningPart.self, from: Data(#"{"kind":"redactedThinking","data":"x"}"#.utf8))
        #expect(part == ReasoningPart(kind: .redactedThinking, data: "x"))
    }

    @Test func partsKeepTheirIdAndPositionAndDecodeWithoutThem() throws {
        let part = ReasoningPart(kind: .encrypted, text: "r", data: "enc", id: "rs_1", callsBefore: 2)
        #expect(try JSONDecoder().decode(ReasoningPart.self, from: JSONEncoder().encode(part)) == part)
        let old = try JSONDecoder().decode(ReasoningPart.self, from: Data(#"{"kind":"encrypted","text":"r","data":"enc"}"#.utf8))
        #expect(old.id == nil && old.callsBefore == nil)
        let odd = try JSONDecoder().decode(ReasoningPart.self, from: Data(#"{"kind":"encrypted","data":"enc","id":5,"callsBefore":"x"}"#.utf8))
        #expect(odd.data == "enc" && odd.id == nil && odd.callsBefore == nil)
    }

    @Test func aTraceIsOnlyReusableWhereItWasMade() {
        #expect(trace.isReusable(format: .messages, provider: "api.anthropic.com", model: "claude-x"))
        #expect(!trace.isReusable(format: .responses, provider: "api.anthropic.com", model: "claude-x"))
        #expect(!trace.isReusable(format: .messages, provider: "gateway.test", model: "claude-x"))
        #expect(!trace.isReusable(format: .messages, provider: "api.anthropic.com", model: "claude-y"))
        #expect(!ReasoningTrace(format: .messages, provider: "p", model: "m", parts: []).isReusable(format: .messages, provider: "p", model: "m"))
    }

    @Test func otherWireFormatsIgnoreReasoning() {
        let call = ToolCallRequest(id: "c", name: "n", arguments: "{}")
        let message = ChatMessage(role: .assistant, content: "", toolCalls: [call], reasoning: trace)
        let wire = OpenAIClient.wire(message)
        #expect(wire["reasoning"] == nil && wire["thinking"] == nil)
        #expect(wire.jsonString.contains("blob") == false)
    }
}
