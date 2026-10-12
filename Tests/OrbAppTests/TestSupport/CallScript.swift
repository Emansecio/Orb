import Foundation
@testable import Orb

/// What a model call was given, and the answers it gives in order (the last repeats). `failsCall` (1 = the first) makes
/// that call fail with `LLMError.notConfigured`; `holdsCall` makes it wait for `release()` before it answers.
actor CallScript {
    struct Call { var messages: [ChatMessage]; var tools: [String]; var system: String }
    private(set) var calls: [Call] = []
    private var answers: [[LLMEvent]]
    private let failsCall: Int?
    private let holdsCall: Int?
    private var released = false

    init(_ answers: [[LLMEvent]], failsCall: Int? = nil, holdsCall: Int? = nil) {
        self.answers = answers
        self.failsCall = failsCall
        self.holdsCall = holdsCall
    }

    func release() { released = true }

    /// Sets the answers after the init (when they need what `setUp` made).
    func setAnswers(_ new: [[LLMEvent]]) { answers = new }

    func answer(_ messages: [ChatMessage], _ tools: [ToolSpec]) async -> [LLMEvent]? {
        calls.append(Call(messages: Array(messages.dropFirst()), tools: tools.map(\.name), system: messages.first?.content ?? ""))
        let number = calls.count
        if failsCall == number { return nil }
        let events = answers.count > 1 ? answers.removeFirst() : answers.first ?? []
        while holdsCall == number, !released { try? await Task.sleep(for: .milliseconds(5)) }
        return events
    }
}

struct CallScriptModel: LLMClient {
    let script: CallScript

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let events = await script.answer(messages, tools) else {
                    continuation.finish(throwing: LLMError.notConfigured)
                    return
                }
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}
