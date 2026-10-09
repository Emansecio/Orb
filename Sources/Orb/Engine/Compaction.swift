import Foundation

// What a compaction did, told once and with numbers (the report that becomes a notice in the transcript), and manual
// compaction ("Compactar agora"). When and how much is folded is `ContextWindow.fit`'s business; this file only says
// what happened and lets the user ask for it.

// MARK: - Report

/// One compaction, for the notice in the transcript and for the context meter.
struct CompactionReport: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// Older turns of the conversation became a summary, at the start of a message.
        case turns
        /// The first steps of the request in progress were set aside to fit (the turn itself goes on).
        case steps
        /// The user asked for it ("Compactar agora").
        case manual
        /// Claude Code compacted its own session.
        case claudeCode
    }

    /// What a fold in the middle of a turn leaves for the app to keep (the next turn starts from it).
    struct Fold: Sendable, Equatable {
        var summary: String
        var ledger: ConversationLedger?
        /// How many turns (user messages and what followed each) this fold took out of the history the engine had.
        /// The engine's history is not the conversation's message list (steps may have been set aside, replies made
        /// up for calls that got none), so only whole turns carry over from one to the other.
        var turns: Int
    }

    var kind: Kind
    /// Messages that became part of the summary; for `.steps`, the number of model steps set aside.
    var foldedMessages: Int
    /// Your requests the summary stands for now (all of them, the ones folded before included): what the notice counts,
    /// since the chat shows your requests and not the model's messages. nil when not known (it is filled in by the
    /// conversation that keeps the fold).
    var foldedRequests: Int?
    /// Estimated tokens the history would take without the compaction and with it; nil when not known.
    var tokensBefore: Int?
    var tokensAfter: Int?
    /// Claude Code: "auto" or "manual".
    var trigger: String?
    var fold: Fold?
    /// The model's notes on the stretches this fold took (see `ChunkSummary`): they go to the memory with them.
    var digests: [String] = []

    init(kind: Kind, foldedMessages: Int, tokensBefore: Int?, tokensAfter: Int?, trigger: String? = nil, fold: Fold? = nil,
         digests: [String] = []) {
        self.kind = kind
        self.digests = digests
        self.foldedMessages = foldedMessages
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.trigger = trigger
        self.fold = fold
    }

    /// The line shown in the transcript.
    var notice: String {
        switch kind {
        case .turns, .manual:
            let what: String
            if let requests = foldedRequests, requests > 0 {
                what = requests == 1 ? "o primeiro pedido virou um resumo" : "os \(requests) primeiros pedidos viraram um resumo"
            } else {
                what = foldedMessages == 1 ? "1 mensagem antiga virou um resumo" : "\(foldedMessages) mensagens antigas viraram um resumo"
            }
            return "Compactei a conversa: \(what)\(range)."
        case .steps:
            let what = foldedMessages == 1 ? "o primeiro passo" : "os \(foldedMessages) primeiros passos"
            return "Neste pedido, resumi \(what) para caber no modelo\(range)."
        case .claudeCode:
            let how = trigger == "manual" ? "" : " sozinho"
            if let before = tokensBefore, let after = tokensAfter {
                return "O Claude Code compactou a sessão\(how) (de \(Self.tokenText(before)) para \(Self.tokenText(after)) tokens)."
            }
            if let before = tokensBefore { return "O Claude Code compactou a sessão\(how) (tinha \(Self.tokenText(before)) tokens)." }
            return "O Claude Code compactou a sessão\(how)."
        }
    }

    /// " (≈ 58 mil → 19 mil tokens)", or nothing when the numbers are not known.
    private var range: String {
        guard let before = tokensBefore, let after = tokensAfter else { return "" }
        return " (≈ \(Self.tokenText(before)) → \(Self.tokenText(after)) tokens)"
    }

    /// "850", "1,2 mil", "58 mil".
    static func tokenText(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000: return "\(max(tokens, 0))"
        case ..<10_000:
            let tenths = Int((Double(tokens) / 100).rounded())
            return tenths % 10 == 0 ? "\(tenths / 10) mil" : "\(tenths / 10),\(tenths % 10) mil"
        default: return "\(Int((Double(tokens) / 1_000).rounded())) mil"
        }
    }
}

// MARK: - Manual compaction

extension Conversation {
    /// "Compactar agora": folds older turns into the summary with the same machinery as an automatic compaction
    /// (`prepareHistory`, which condenses the older stretch at the same time), but down to `share` of the budget
    /// (`ContextMeter.compactingShare`), or to half of what the condensed history takes when that is less, so a
    /// conversation that is not big yet still has turns folded. The latest turn stays whole. `focus` is something the user wants the summary to pay attention to; it stays in the summary until
    /// replaced. Returns nil when there was nothing to fold (a single turn).
    mutating func compact(budget: ContextBudget, share: Double = ContextMeter.compactingShare, focus: String? = nil) -> CompactionReport? {
        let before = contextFill(budget: budget).historyTokens
        let target = ContextMeter.manualBudget(for: self, budget: budget, share: share)
        guard var report = prepareHistory(budget: target, focus: focus).compaction else { return nil }
        report.kind = .manual
        report.tokensBefore = before
        report.tokensAfter = contextFill(budget: budget).historyTokens
        return report
    }

    /// For a Claude Code conversation, whose context is the CLI's own session: folds everything before the latest turn
    /// into the summary, so a new session can start from it and that turn. nil when there is no earlier turn. The
    /// numbers are estimates from Orb's own copy of the conversation (Claude Code's session is not visible to Orb).
    mutating func compactAllButLatestTurn(focus: String? = nil) -> CompactionReport? {
        let covered = coveredMessageCount
        guard let latest = messages.lastIndex(where: { $0.role == .user && !$0.content.hasPrefix(ContextSummary.marker) }),
              latest > covered else { return nil }
        var base = currentLedger ?? ConversationLedger()
        if let focus = Self.cleanFocus(focus) { base.focus = focus }
        // What a new session would have to be told, estimated: the summary and every message not yet in it, against
        // the summary as it becomes and the latest turn.
        func size(_ messages: ArraySlice<ChatMessage>) -> Int { messages.reduce(0) { $0 + $1.contextCharacters } }
        let before = (summary?.count ?? 0) + size(messages[covered...])
        base.absorb(Array(messages[covered..<latest]))
        let text = base.render()
        summary = text
        ledger = base
        summaryCoveredCount = latest
        compactions = (compactions ?? 0) + 1
        return CompactionReport(kind: .manual, foldedMessages: latest - covered,
                                tokensBefore: ContextBudget.tokens(forCharacters: before),
                                tokensAfter: ContextBudget.tokens(forCharacters: text.count + size(messages[latest...])))
    }
}

// MARK: - Result for the UI

/// What "Compactar agora" did, for the screen that asked: the numbers, and a sentence to show.
struct CompactionResult: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        /// Older messages became a summary.
        case compacted
        /// Claude Code: the session was dropped and the next message starts a new one from the summary.
        case claudeSessionRestarted
        /// Too little history to be worth it.
        case nothingToCompact
        /// A message is being answered; compaction waits.
        case busy
        /// No such Orb.
        case unavailable
    }

    var status: Status
    var foldedMessages = 0
    var tokensBefore = 0
    var tokensAfter = 0
    /// The essentials were saved to the Orb's memory before the old messages left the model's view.
    var savedToMemory = false
    /// The line shown to the user (also the transcript notice when something happened).
    var message: String

    var didCompact: Bool { status == .compacted || status == .claudeSessionRestarted }
}

/// The text "/compactar [foco]" in the composer.
enum CompactionCommand {
    static let name = "/compactar"

    /// `.some(focus)` when `text` is the command (the focus is nil when none was given), nil for any other message.
    static func parse(_ text: String) -> String?? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(name) else { return nil }
        let rest = trimmed.dropFirst(name.count)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        let focus = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return .some(focus.isEmpty ? nil : focus)
    }
}

/// What the summary holds, for a screen that shows it ("Ver resumo", "O que o Orb lembra").
struct ContextSummaryInfo: Sendable, Equatable {
    /// The text the model reads in place of the old messages.
    var text: String
    var foldedMessages: Int
    var compactions: Int
    var focus: String?
    var ledger: ConversationLedger?
}
