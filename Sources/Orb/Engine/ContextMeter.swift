import Foundation

// How full an Orb's context is, for the meter in the composer: a pure function of the conversation and the
// budget, so the view only draws numbers (estimated at 3.5 characters per token, like the budget itself).

struct ContextFill: Sendable, Equatable {
    /// What compacting now would fold away.
    struct Compaction: Sendable, Equatable {
        /// Whole turns of the conversation that would become part of the summary.
        var turns: Int
        var messages: Int
        /// Estimated tokens the next request would shed.
        var tokensFreed: Int
    }

    /// Tokens the next request would carry: the fixed part (system prompt and tool specs) plus the history.
    var usedTokens: Int
    /// The history alone: the summary, if any, and the messages after it.
    var historyTokens: Int
    /// The fixed part of every request.
    var overheadTokens: Int
    /// The model's window (an estimate from the budget when the window is not known: see `windowIsKnown`).
    var windowTokens: Int
    var windowIsKnown: Bool
    /// History tokens allowed before a compaction starts.
    var budgetTokens: Int
    /// Messages already folded into the summary, and the summary's own size.
    var foldedMessages: Int
    var summaryTokens: Int
    /// What compacting now (a manual compaction brings the history down to `compactingShare` of the budget) would drop;
    /// nil when there is nothing to fold (a single turn).
    var compaction: Compaction?

    /// Share of the window in use, 0 to 1 (more than 1 when the estimate says the request would not fit).
    var fraction: Double { windowTokens > 0 ? Double(usedTokens) / Double(windowTokens) : 0 }
    /// Share of the history budget in use: at 1 the next message starts a compaction.
    var budgetFraction: Double { budgetTokens > 0 ? Double(historyTokens) / Double(budgetTokens) : 0 }
    var willCompactOnNextMessage: Bool { historyTokens > budgetTokens }
}

enum ContextMeter {
    /// Where a manual compaction ("Compactar agora") brings the history: this share of the budget.
    static let compactingShare = 0.3

    /// `conversation`'s history as the next message would find it, measured against `budget`. Nothing is changed.
    static func fill(of conversation: Conversation, budget: ContextBudget, compactingShare: Double = compactingShare) -> ContextFill {
        let covered = conversation.summary == nil ? 0 : min(max(conversation.summaryCoveredCount ?? 0, 0), conversation.messages.count)
        let slice = Array(conversation.messages[covered...])
        let condensing = max((conversation.condensedCount ?? 0) - covered, 0)
        // A task waiting for "continua" keeps its fresh outputs whole in the next request: measure it the same way.
        let paused = conversation.isTaskPaused

        // The history as it stands: nothing new folded away, however far over the budget it is.
        var cut = ContextCut(summary: conversation.summary)
        let unlimited = ContextBudget(tokens: Int.max / 8)
        let current = ContextWindow.fit(slice, budget: unlimited, cut: &cut, condensing: condensing, paused: paused)
        let history = tokens(current.messages)

        var compaction: ContextFill.Compaction?
        var smaller = budget
        smaller.tokens = max(Int(Double(budget.tokens) * compactingShare), 500)
        smaller.lowWaterShare = 1
        var folding = ContextCut(summary: conversation.summary)
        let compacted = ContextWindow.fit(slice, budget: smaller, cut: &folding, condensing: condensing, paused: paused)
        if folding.covered > 0 {
            let foldedMessages = Array(slice.prefix(compacted.droppedCount))
            compaction = .init(turns: foldedMessages.filter { $0.role == .user }.count, messages: compacted.droppedCount,
                               tokensFreed: max(history - tokens(compacted.messages), 0))
        }

        let window = budget.window ?? budget.tokens + budget.overheadTokens + budget.replyTokens
        return ContextFill(usedTokens: budget.overheadTokens + history, historyTokens: history,
                           overheadTokens: budget.overheadTokens, windowTokens: window, windowIsKnown: budget.window != nil,
                           budgetTokens: budget.tokens, foldedMessages: covered,
                           summaryTokens: conversation.summary.map { ContextBudget.tokens(forCharacters: $0.count) } ?? 0,
                           compaction: compaction)
    }

    private static func tokens(_ messages: [ChatMessage]) -> Int {
        ContextBudget.tokens(forCharacters: messages.reduce(0) { $0 + $1.contextCharacters })
    }
}

extension Conversation {
    /// How full the context is (see `ContextMeter`).
    func contextFill(budget: ContextBudget) -> ContextFill { ContextMeter.fill(of: self, budget: budget) }
}
