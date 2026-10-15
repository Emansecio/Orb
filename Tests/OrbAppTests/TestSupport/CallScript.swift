import Foundation
@testable import Orb

/// One scripted answer of a model call: the events it streams, and an error it ends with. With no events the error
/// comes before anything is streamed (a call that fails at once); with events, after them (a stream cut short).
struct ModelReply: Sendable {
    var events: [LLMEvent]
    var failure: (any Error)?

    init(_ events: [LLMEvent] = [], failure: (any Error)? = nil) {
        self.events = events
        self.failure = failure
    }

    /// A plain answer: the text, and `.finished(.done, usage)`.
    static func say(_ text: String, usage: TokenUsage? = nil) -> ModelReply {
        ModelReply([.text(text), .finished(.done, usage)])
    }

    /// An answer that asks for tools: the calls, and `.finished(.toolUse, nil)`.
    static func calling(_ calls: ToolCallRequest...) -> ModelReply {
        ModelReply([.toolCalls(calls), .finished(.toolUse, nil)])
    }

    /// A call that ends in `error`, after `events` (none by default).
    static func failing(_ error: any Error, after events: [LLMEvent] = []) -> ModelReply {
        ModelReply(events, failure: error)
    }
}

/// What a model call was given, and the answers it gives in order. When the answers run out, `whenExhausted` says what
/// the next calls get: the last answer again (the default), or a fixed one (`.fim`, a plain "fim" as the scripted models of
/// the suites answer). `failsCall` (1 = the first) makes that call fail with `LLMError.notConfigured` without using up an
/// answer; `holdsCall` makes it wait for `release()` before it answers; `before` runs ahead of every call, with the index of
/// the call (0 = the first), before it is answered.
actor CallScript {
    struct Call: Sendable {
        var model = ""
        /// Exactly what the call was sent, the system message included.
        var sent: [ChatMessage]
        /// `sent` without its first message (the system prompt).
        var messages: [ChatMessage]
        var tools: [String]
        var system: String
        var toolChoice: ToolChoice = .auto
    }

    enum WhenExhausted: Sendable {
        /// The last answer, for ever.
        case repeatLast
        /// This answer, once none is left to give.
        case reply(ModelReply)
        /// A plain "fim".
        static let fim = WhenExhausted.reply(ModelReply([.text("fim")]))
    }

    private(set) var calls: [Call] = []
    private var replies: [ModelReply]
    private let failsCall: Int?
    private let holdsCall: Int?
    private let whenExhausted: WhenExhausted
    private let before: (@Sendable (_ index: Int) async -> Void)?
    private var released = false

    /// Everything the calls were sent, in order, the system message of each included.
    var received: [[ChatMessage]] { calls.map(\.sent) }

    init(_ answers: [[LLMEvent]] = [], failsCall: Int? = nil, holdsCall: Int? = nil, whenExhausted: WhenExhausted = .repeatLast,
         before: (@Sendable (_ index: Int) async -> Void)? = nil) {
        self.replies = answers.map { ModelReply($0) }
        self.failsCall = failsCall
        self.holdsCall = holdsCall
        self.whenExhausted = whenExhausted
        self.before = before
    }

    init(replies: [ModelReply], failsCall: Int? = nil, holdsCall: Int? = nil, whenExhausted: WhenExhausted = .repeatLast,
         before: (@Sendable (_ index: Int) async -> Void)? = nil) {
        self.replies = replies
        self.failsCall = failsCall
        self.holdsCall = holdsCall
        self.whenExhausted = whenExhausted
        self.before = before
    }

    func release() { released = true }

    /// Sets the answers after the init (when they need what `setUp` made).
    func setAnswers(_ new: [[LLMEvent]]) { replies = new.map { ModelReply($0) } }

    func answer(model: String = "", _ messages: [ChatMessage], _ tools: [ToolSpec], toolChoice: ToolChoice = .auto) async -> ModelReply {
        calls.append(Call(model: model, sent: messages, messages: Array(messages.dropFirst()), tools: tools.map(\.name),
                          system: messages.first?.content ?? "", toolChoice: toolChoice))
        let number = calls.count
        if let before { await before(number - 1) }
        if failsCall == number { return .failing(LLMError.notConfigured) }
        let reply: ModelReply
        switch whenExhausted {
        case .repeatLast: reply = replies.count > 1 ? replies.removeFirst() : replies.first ?? ModelReply()
        case .reply(let fallback): reply = replies.isEmpty ? fallback : replies.removeFirst()
        }
        while holdsCall == number, !released { try? await Task.sleep(for: .milliseconds(5)) }
        return reply
    }
}

/// The `LLMClient` of a `CallScript`. `arrangesPromptCache` is what the client says about itself; `appendsFinished` adds
/// `.finished(.toolUse | .done, nil)` to an answer that has none (for the scripts that list only text and tool calls).
struct CallScriptModel: LLMClient {
    let script: CallScript
    var arrangesPromptCache = false
    var appendsFinished = false

    init(script: CallScript, arrangesPromptCache: Bool = false, appendsFinished: Bool = false) {
        self.script = script
        self.arrangesPromptCache = arrangesPromptCache
        self.appendsFinished = appendsFinished
    }

    /// The same answer to every call; `model.script.calls` keeps what each was sent.
    init(always events: [LLMEvent] = [], failure: (any Error)? = nil, arrangesPromptCache: Bool = false, appendsFinished: Bool = false) {
        self.init(script: CallScript(replies: [ModelReply(events, failure: failure)]), arrangesPromptCache: arrangesPromptCache,
                  appendsFinished: appendsFinished)
    }

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let reply = await script.answer(model: model, messages, tools, toolChoice: toolChoice)
                var events = reply.events
                if appendsFinished, reply.failure == nil, !events.contains(where: { if case .finished = $0 { true } else { false } }) {
                    let asksForTools = events.contains { if case .toolCalls = $0 { true } else { false } }
                    events.append(.finished(asksForTools ? .toolUse : .done, nil))
                }
                for event in events { continuation.yield(event) }
                if let failure = reply.failure { continuation.finish(throwing: failure) } else { continuation.finish() }
            }
        }
    }
}
