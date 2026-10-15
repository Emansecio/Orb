import Foundation
@testable import Orb

// What the context suites share: building conversations, checking them, and driving the engine with a scripted model.

func call(_ id: String, _ name: String = "read_file", _ arguments: String = "{}") -> ToolCallRequest {
    ToolCallRequest(id: id, name: name, arguments: arguments)
}

func assistant(_ text: String = "", calls: [ToolCallRequest] = []) -> ChatMessage {
    ChatMessage(role: .assistant, content: text, toolCalls: calls)
}

func characters(_ messages: [ChatMessage]) -> Int { messages.contextCharacters }

/// About 60,000 tokens of plain conversation: a retry after a refusal for size, with half the budget, sends less of it
/// (the engine never sends a refused request again unchanged).
func longHistory() -> [ChatMessage] {
    (0..<40).flatMap { [ChatMessage.user("pedido \($0) " + String(repeating: "a", count: 3_000)), assistant(String(repeating: "b", count: 3_000))] }
}

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

/// A `read_file` that returns `size` characters.
struct OutputTool: AgentTool {
    let size: Int
    /// Called whenever the tool runs (a test speaking to the turn while the tool works).
    var onRun: (@Sendable () -> Void)?
    var spec: ToolSpec { ToolSpec(name: "read_file", description: "Reads", parameters: .schema([:])) }
    var kind: ToolCall.Kind { .file }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Lendo", "arquivo") }
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        onRun?()
        return String(repeating: "y", count: size)
    }
}
