import Foundation
@testable import Orb

// Views over `AppModel.sessions` that only the tests read (the app reads and changes one Orb's through its session),
// and a few helpers for driving a model by hand.

/// What the summary holds (the screens that would show it, "Ver resumo" and "O que o Orb lembra", do not exist).
struct ContextSummaryInfo: Sendable, Equatable {
    /// The text the model reads in place of the old messages.
    var text: String
    var foldedMessages: Int
    var compactions: Int
    var focus: String?
    var ledger: ConversationLedger?
}

extension AppModel {
    /// The conversations in memory, by Orb (a routine's while it runs).
    var conversations: [UUID: Conversation] { sessions.compactMapValues { $0.conversation } }

    /// Each Orb's running turn and its id.
    var turns: [UUID: Task<Void, Never>] { sessions.compactMapValues { $0.turnTask } }
    var turnIDs: [UUID: UUID] { sessions.compactMapValues { $0.turnID } }
    /// The snapshot and rules marks of each running turn (see `BotSession.pendingMarks`).
    var pendingMarks: [UUID: DeliveryMarks] { sessions.compactMapValues { $0.pendingMarks } }
    /// Tokens each Orb's last turn used, its latest model call alone, and its latest compaction.
    var usage: [UUID: TokenUsage] { sessions.compactMapValues { $0.usage } }
    var requestUsage: [UUID: TokenUsage] { sessions.compactMapValues { $0.requestUsage } }
    var lastCompaction: [UUID: CompactionReport] { sessions.compactMapValues { $0.lastCompaction } }

    /// Reads every conversation not in memory now (the app reads them when they are needed).
    func loadRemainingConversations() async {
        for bot in bots where sessions[bot.id]?.isUnloaded == true { await loadedConversation(bot.id) }
    }

    /// Flushes the streamed text when the test wants, not after a delay.
    func flushText(_ botID: UUID) { session(botID).flushText() }

    /// What the summary of the Orb's conversation holds (nil while nothing has been folded away).
    func contextSummary(for botID: UUID) -> ContextSummaryInfo? {
        ensureLoaded(botID)
        guard let conversation = sessions[botID]?.conversation, let text = conversation.summary else { return nil }
        return ContextSummaryInfo(text: text, foldedMessages: conversation.coveredMessageCount,
                                  compactions: conversation.compactions ?? 1, focus: conversation.ledger?.focus,
                                  ledger: conversation.ledger)
    }
}

extension [ChatMessage] {
    /// The part of a conversation sent to the model, fitted to `budget` (see `ContextWindow.fit`), with every
    /// tool call answered.
    func modelContext(budget: ContextBudget = .fallback) -> [ChatMessage] {
        ContextWindow.fit(self, budget: budget).messages
    }
}
