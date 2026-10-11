import Foundation

// What the context meter (composer), its "Compactar agora" popover and the memory settings need from the model. The
// engine does the measuring and the compacting (`ContextMeter`, `compactNow`); these only hand it the right pieces.

extension AppModel {
    /// What `ContextReading.make` needs for the Orb's conversation, taken on the main thread (the copy of the conversation
    /// is cheap) so the measuring can run elsewhere. nil while the Orb or its conversation is not in memory yet.
    /// A running routine's own conversation is not the chat: the chat waits parked, and is what the meter measures
    /// (so the routine's model calls are not read as the chat's cache hit).
    func contextInput(for botID: UUID) -> ContextInput? {
        guard let bot = bot(botID), let session = sessions[botID], let conversation = session.parkedChat ?? session.conversation else { return nil }
        let ref = modelRef(for: bot)
        var stated = false
        if let ref {
            let catalog = account(ref.provider)?.models.first { $0.id == ref.model }?.contextLength ?? 0
            stated = catalog > 0 || (learnedContexts[ref.text]?.isFresh() ?? false)
        }
        return ContextInput(botID: botID, conversation: conversation, budget: contextBudget(for: bot),
                            isClaudeCode: false, windowIsStated: stated, usage: session.routineID == nil ? live(botID).lastUsage : nil, memory: contextMemory)
    }

    /// "Compactar agora" from the meter or the card: compacts, says what happened to VoiceOver, and, for Claude Code,
    /// tells the transcript that the next message starts a new session (the same as "/compactar").
    @discardableResult
    func compactFromMeter(_ botID: UUID, focus: String?) -> CompactionResult {
        let trimmed = focus?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = compactNow(botID: botID, focus: trimmed?.isEmpty == false ? trimmed : nil)
        if result.status == .claudeSessionRestarted { append(.notice(Self.claudeRestartNote), to: botID) }
        announceForAccessibility(result.message)
        return result
    }

    /// The windows Orb learned from refusals that are still in force, for Ajustes (the oldest lesson last).
    func learnedWindowRows(now: Date = .now) -> [LearnedWindowRow] {
        learnedContexts
            .filter { $0.value.isFresh(at: now) }
            .map { key, learned in
                LearnedWindowRow(id: key, name: modelName(forModel: key).isEmpty ? key : modelName(forModel: key),
                                 tokens: learned.tokens, date: learned.date, isEstimate: learned.inferred == true)
            }
            .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }
}
