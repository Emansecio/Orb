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
    /// The model's window (an estimate from the budget when the window is not known).
    var windowTokens: Int
    /// History tokens allowed before a compaction starts.
    var budgetTokens: Int
    /// Messages already folded into the summary.
    var foldedMessages: Int
    /// What compacting now (a manual compaction brings the history down to `compactingShare` of the budget) would drop;
    /// nil when there is nothing to fold (a single turn).
    var compaction: Compaction?

    /// Share of the window in use, 0 to 1 (more than 1 when the estimate says the request would not fit).
    var fraction: Double { windowTokens > 0 ? Double(usedTokens) / Double(windowTokens) : 0 }
    /// Share of the history budget in use: at 1 the next message starts a compaction.
    var budgetFraction: Double { budgetTokens > 0 ? Double(historyTokens) / Double(budgetTokens) : 0 }
}

enum ContextMeter {
    /// Where a manual compaction ("Compactar agora") brings the history: this share of the budget.
    static let compactingShare = 0.3
    /// A compaction that would free fewer tokens than this is not offered.
    static let minimumFreed = 100

    /// `conversation`'s history as the next message would find it, measured against `budget`. Nothing is changed.
    static func fill(of conversation: Conversation, budget: ContextBudget, compactingShare: Double = compactingShare) -> ContextFill {
        let covered = conversation.summary == nil ? 0 : min(max(conversation.summaryCoveredCount ?? 0, 0), conversation.messages.count)
        let slice = Array(conversation.messages[covered...])
        let condensing = max((conversation.condensedCount ?? 0) - covered, 0)
        // A task waiting for "continua" keeps its fresh outputs whole in the next request: measure it the same way.
        let paused = conversation.isTaskPaused

        // The history as it stands: nothing new folded away, however far over the budget it is.
        var cut = ContextCut(summary: conversation.summary, ledger: conversation.currentLedger)
        let unlimited = ContextBudget(tokens: Int.max / 8)
        let current = ContextWindow.fit(slice, budget: unlimited, cut: &cut, condensing: condensing, paused: paused)
        let history = tokens(current.messages)

        // A compaction condenses the older stretch too (see `Conversation.prepareHistory`): what it would fold is
        // measured on the history condensed that far, as `Conversation.compact` does.
        var compaction: ContextFill.Compaction?
        let frontier = max(ContextCondensing.frontier(in: slice), condensing)
        let smaller = manualBudget(for: conversation, budget: budget, share: compactingShare)
        var folding = ContextCut(summary: conversation.summary, ledger: conversation.currentLedger)
        folding.chunks = conversation.pendingChunks(after: covered)
        let compacted = ContextWindow.fit(slice, budget: smaller, cut: &folding, condensing: frontier, paused: paused)
        if folding.covered > 0 {
            let foldedMessages = Array(slice.prefix(compacted.droppedCount))
            // What the compaction leaves is measured as the app measures it afterwards (`Conversation.compact`): the
            // summary and what follows it, whole (the rungs and steps set aside to fit the smaller budget are only for
            // that one request), not the window that fit just produced.
            var kept = ContextCut(summary: folding.summary, ledger: folding.ledger)
            let remaining = ContextWindow.fit(Array(slice.dropFirst(compacted.droppedCount)), budget: unlimited, cut: &kept,
                                              condensing: max(frontier - compacted.droppedCount, 0), paused: paused)
            let freed = max(history - tokens(remaining.messages), 0)
            // A summary that frees next to nothing (the latest turn is the whole history) is not worth offering.
            if freed >= minimumFreed {
                compaction = .init(turns: foldedMessages.filter { $0.role == .user }.count, messages: compacted.foldedCount,
                                   tokensFreed: freed)
            }
        }

        let window = budget.window ?? budget.tokens + budget.overheadTokens + budget.replyTokens
        return ContextFill(usedTokens: budget.overheadTokens + history, historyTokens: history,
                           overheadTokens: budget.overheadTokens, windowTokens: window,
                           budgetTokens: budget.tokens, foldedMessages: covered, compaction: compaction)
    }

    /// The budget a manual compaction fits the history to: `share` of `budget`, or half of what the history takes
    /// (`historyTokens`, once its older stretch is condensed) when that is less, so a conversation that is not big yet
    /// still has turns folded; folded only as far as needed (no low-water mark below it).
    static func manualBudget(_ budget: ContextBudget, historyTokens: Int, share: Double = compactingShare) -> ContextBudget {
        var smaller = budget
        smaller.tokens = max(min(Int(Double(budget.tokens) * share), historyTokens / 2), 500)
        smaller.lowWaterShare = 1
        return smaller
    }

    /// The budget `Conversation.compact` uses for `conversation` (see `manualBudget`).
    static func manualBudget(for conversation: Conversation, budget: ContextBudget, share: Double = compactingShare) -> ContextBudget {
        let covered = conversation.coveredMessageCount
        let slice = Array(conversation.messages[covered...])
        let stored = max((conversation.condensedCount ?? 0) - covered, 0)
        var cut = ContextCut(summary: conversation.summary, ledger: conversation.currentLedger)
        let condensed = ContextWindow.fit(slice, budget: ContextBudget(tokens: Int.max / 8), cut: &cut,
                                          condensing: max(ContextCondensing.frontier(in: slice), stored), paused: conversation.isTaskPaused)
        return manualBudget(budget, historyTokens: tokens(condensed.messages), share: share)
    }

    private static func tokens(_ messages: [ChatMessage]) -> Int {
        ContextBudget.tokens(forCharacters: messages.contextCharacters)
    }
}

extension Conversation {
    /// How full the context is (see `ContextMeter`).
    func contextFill(budget: ContextBudget) -> ContextFill { ContextMeter.fill(of: self, budget: budget) }

    /// The user's requests among `messages[range]`: what the chat shows as your bubbles, not the model's steps between them.
    func requestCount(in range: Range<Int>) -> Int {
        messages[range.clamped(to: messages.indices)].reduce(0) { $0 + ($1.role == .user && !$1.content.hasPrefix(ContextSummary.marker) ? 1 : 0) }
    }
}
