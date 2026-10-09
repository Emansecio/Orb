import Foundation
@testable import Orb

// What the context suites share: building conversations, checking them, and driving the engine with a scripted model.

func characters(_ messages: [ChatMessage]) -> Int { messages.contextCharacters }

/// Whether `later` starts with all of `earlier` (the provider's cache would still hold).
func extends(_ earlier: [ChatMessage], _ later: [ChatMessage]) -> Bool {
    later.count >= earlier.count && zip(earlier, later).allSatisfy { $0 == $1 }
}

/// Every tool message answers a call of the assistant message before it, and nothing starts with assistant/tool.
func isValidConversation(_ messages: [ChatMessage]) -> Bool {
    guard messages.first?.role == .user else { return false }
    var open: Set<String> = []
    for message in messages {
        switch message.role {
        case .assistant: open = Set(message.toolCalls.map(\.id))
        case .tool:
            guard let id = message.toolCallID, open.remove(id) != nil else { return false }
        default: open = []
        }
    }
    return true
}

/// Answers each request with the next scripted reply (or a failure first), and keeps what it was sent.
actor Recorder {
    private var responses: [[LLMEvent]]
    private(set) var received: [[ChatMessage]] = []
    private var failures: [Error]

    init(_ responses: [[LLMEvent]], failures: [Error] = []) {
        self.responses = responses
        self.failures = failures
    }

    func next(_ messages: [ChatMessage]) throws -> [LLMEvent] {
        received.append(messages)
        if !failures.isEmpty { throw failures.removeFirst() }
        return responses.isEmpty ? [.text("fim")] : responses.removeFirst()
    }
}

struct ReplayLLM: LLMClient {
    let recorder: Recorder

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for event in try await recorder.next(messages) { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func models() async throws -> [String] { ["fake"] }
}

/// A `read_file` that returns `size` characters.
struct OutputTool: AgentTool {
    let size: Int
    var spec: ToolSpec { ToolSpec(name: "read_file", description: "Reads", parameters: .schema([:])) }
    var kind: ToolCall.Kind { .file }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Lendo", "arquivo") }
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String { String(repeating: "y", count: size) }
}
