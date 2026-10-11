import Foundation
import Observation

// What the context meter in the composer shows, apart from how it is drawn: the numbers of the conversation turned
// into a `ContextReading` (a pure function, computed off the main thread), the words that say them in Portuguese,
// and the small object the composer's meter reads from.

// MARK: - Words

/// Numbers as the meter says them: "42 mil", "1,5 milhão". Always approximate (the counts are estimates).
enum ContextWords {
    /// "840", "3,5 mil", "42 mil", "1 milhão", "2,5 milhões".
    static func approx(_ tokens: Int) -> String {
        let n = max(tokens, 0)
        switch n {
        case ..<995:
            return "\((n + 5) / 10 * 10)"
        case ..<10_000:
            let tenths = Int((Double(n) / 100).rounded()) // in tenths of a thousand
            return tenths % 10 == 0 ? "\(tenths / 10) mil" : "\(tenths / 10),\(tenths % 10) mil"
        default:
            let thousands = Int((Double(n) / 1_000).rounded())
            if thousands < 1_000 { return "\(thousands) mil" }
            let tenths = Int((Double(n) / 100_000).rounded()) // in tenths of a million
            let whole = tenths / 10, rest = tenths % 10
            let unit = tenths >= 20 ? "milhões" : "milhão"
            return rest == 0 ? "\(whole) \(unit)" : "\(whole),\(rest) \(unit)"
        }
    }

    /// "cerca de 42 mil de 128 mil tokens" (and "de uns 128 mil" while the window is only assumed).
    static func usage(used: Int, window: Int, windowIsStated: Bool) -> String {
        "cerca de \(approx(used)) de \(windowIsStated ? "" : "uns ")\(approx(window)) tokens"
    }

    /// "De ~60 mil para ~18 mil tokens".
    static func compaction(before: Int, after: Int) -> String {
        "De ~\(approx(before)) para ~\(approx(after)) tokens"
    }

    /// What is kept word for word: the whole conversation, or a summary and the latest requests. It counts your
    /// requests, which the chat shows, and not the model's messages (calls and outputs of tools included).
    static func kept(totalRequests total: Int, foldedRequests folded: Int) -> String {
        guard folded > 0, folded < total else {
            if folded >= total, total > 0 { return "Só o resumo da conversa; os pedidos recentes ainda não chegaram." }
            return total == 1 ? "O pedido inteiro, palavra por palavra." : "Todos os \(total) pedidos, palavra por palavra."
        }
        let recent = total - folded
        let summary = folded == 1 ? "Um resumo do primeiro pedido" : "Um resumo dos \(folded) primeiros pedidos"
        let rest = recent == 1 ? "o último, palavra por palavra" : "os últimos \(recent), palavra por palavra"
        return "\(summary) e \(rest)."
    }

    /// "82% veio do cache do provedor".
    static func cache(_ ratio: Double) -> String {
        let percent = Int((min(max(ratio, 0), 1) * 100).rounded())
        return percent == 0 ? "Nada veio do cache do provedor" : "\(percent)% veio do cache do provedor"
    }

    /// What "Compactar agora" would do to a conversation that has something to fold: `requests` more of your requests
    /// become part of the summary (`alreadySummarized`: there is one already).
    static func wouldFree(requests: Int, alreadySummarized: Bool, tokens: Int) -> String {
        let what: String
        switch (requests, alreadySummarized) {
        case (1, false): what = "o primeiro pedido"
        case (_, false): what = "os \(requests) primeiros pedidos"
        case (1, true): what = "mais 1 pedido"
        default: what = "mais \(requests) pedidos"
        }
        return "Compactar agora resumiria \(what) e liberaria cerca de \(approx(tokens)) tokens."
    }

    /// Said when there is nothing older to fold into a summary (a single request, however long its answer).
    static let nothingToFold = "Só há um pedido nesta conversa: não há mensagens antigas para resumir."

    /// Said when "Compactar agora" has nothing to do, by what is true of the conversation: `requests` are yours that the
    /// summary does not stand for yet (a single one is `nothingToFold`; several short ones are just a short chat).
    static func nothingToCompact(requests: Int, alreadySummarized: Bool) -> String {
        if alreadySummarized { return "O começo já está resumido; não há mais o que compactar agora." }
        return requests > 1 ? "A conversa ainda é curta: não há o que compactar." : nothingToFold
    }
}

// MARK: - Reading

/// How worried the meter looks: neutral for most of the way, warmer from 70%, warm from 85% of the model's window
/// (the same share the ring's percentage says, so the colour and the number never disagree).
enum ContextTone: Equatable, Sendable {
    case calm, warming, full

    init(share: Double) {
        self = share >= ContextReading.fullAt ? .full : (share >= ContextReading.warmsAt ? .warming : .calm)
    }
}

/// Everything the meter needs to know about one Orb's conversation, taken on the main thread and measured elsewhere.
struct ContextInput: Sendable {
    var botID: UUID
    var conversation: Conversation
    /// nil while no model is connected to measure the conversation against.
    var budget: ContextBudget?
    /// The window comes from the provider's catalog or from a refusal (else Orb assumes one for the model's kind).
    var windowIsStated: Bool
    /// The Orb's latest model call.
    var usage: TokenUsage?
    var memory: ContextMemoryLevel
}

/// The context meter's numbers for one Orb. nil (see `make`) while there is nothing to measure.
struct ContextReading: Equatable, Sendable {
    /// From this share of the window the ring turns warm (and the popover tells when the history budget gets there).
    static let warmsAt = 0.7
    /// From this share of the window the ring is "full" (its colour is at its warmest).
    static let fullAt = 0.85

    var botID: UUID
    var fill: ContextFill
    var windowIsStated: Bool
    var messageCount: Int
    /// Your requests in the conversation, and the ones the summary stands for.
    var requestCount: Int
    var foldedRequests: Int
    var memory: ContextMemoryLevel
    /// Share of the latest request served by the provider's cache, when it said.
    var cacheHit: Double?

    /// Nil while the conversation has no messages, or when no model is connected to measure it against, or when the
    /// task measuring was cancelled (a newer measurement replaced it; it stops before the next step that walks the history).
    static func make(_ input: ContextInput) -> ContextReading? {
        let conversation = input.conversation
        guard !conversation.messages.isEmpty, !Task.isCancelled else { return nil }
        guard let budget = input.budget,
              let fill = ContextMeter.fill(of: conversation, budget: budget, isCancelled: { Task.isCancelled }) else { return nil }
        return ContextReading(botID: input.botID,
                              fill: fill, windowIsStated: input.windowIsStated, messageCount: conversation.messages.count,
                              requestCount: conversation.requestCount(in: 0..<conversation.messages.count),
                              foldedRequests: conversation.requestCount(in: 0..<conversation.coveredMessageCount),
                              memory: input.memory, cacheHit: input.usage?.cacheHitRatio)
    }

    /// Share of the model's window the next request would take, 0 to 1.
    var fraction: Double { min(max(fill.fraction, 0), 1) }

    /// The percentage on the meter, 1 to 100 (0 only for an empty request).
    var percent: Int {
        let share = fill.fraction * 100
        guard share > 0 else { return 0 }
        return min(max(Int(share.rounded()), 1), 100)
    }

    var tone: ContextTone { ContextTone(share: fraction) }

    /// Messages the summary has swallowed so far.
    var foldedMessages: Int { fill.foldedMessages }

    /// Whether "Compactar agora" has anything to do.
    var canCompact: Bool { fill.compaction != nil }

    /// "cerca de 42 mil de 128 mil tokens".
    var usageWords: String {
        ContextWords.usage(used: fill.usedTokens, window: fill.windowTokens, windowIsStated: windowIsStated)
    }

    /// The spoken state of the meter, for VoiceOver and the tooltip.
    var spokenState: String {
        return "\(percent)% usado, \(usageWords)"
    }
}

// MARK: - Shared state

/// The composer's context reading, kept where the meter in the bar can see it.
/// Written by `ContextGaugeDriver`, which measures when something that changes the numbers does.
@MainActor @Observable
final class ContextGauge {
    private(set) var reading: ContextReading?

    /// Shows `reading` (only when it differs: assigning an `@Observable` property notifies even for an equal value).
    func show(_ reading: ContextReading?) {
        if self.reading != reading { self.reading = reading }
    }
}

// MARK: - Learned windows

/// One row of "Janelas aprendidas" in the settings.
struct LearnedWindowRow: Identifiable, Equatable, Sendable {
    /// "provider/model", as `AppModel.learnedContexts` keys it.
    var id: String
    var name: String
    var tokens: Int
    var date: Date
    /// The refusal named no number: the window is a share of the one assumed.
    var isEstimate: Bool

    var words: String { "\(ContextWords.approx(tokens)) tokens" + (isEstimate ? " (estimada)" : "") }

    func age(now: Date = .now) -> String {
        let days = Int(now.timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1: return "aprendida hoje"
        case 1: return "aprendida ontem"
        default: return "aprendida há \(days) dias"
        }
    }
}
