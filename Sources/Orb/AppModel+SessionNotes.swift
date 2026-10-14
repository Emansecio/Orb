import Foundation

extension AppModel {
    /// Whether long stretches saved to the memory get a note from the model (`SessionNote`): off unless you turn it on, for
    /// it is a call.
    var summarizesSessions: Bool { preferences.object(forKey: SessionNote.settingKey) as? Bool ?? false }

    /// What asks the model for the note on a stretch saved to the memory (see `SessionNote`), or nil when none is asked: the
    /// setting off, a developer run or a test that does not look at it, a routine's run, Claude Code (each request a CLI
    /// process) or a local server (one slot, which the chat needs), an account that cannot be used. The smaller model of
    /// the same maker when there is one (`ChunkSummarizer.model`), else the Orb's.
    func sessionNoteWriter(for botID: UUID) -> (@Sendable (String) async -> String?)? {
        guard summarizesSessions, writesStretchNotes, !isDevRun, !isResetting, sessions[botID]?.routineID == nil,
              let bot = bot(botID), let ref = modelRef(for: bot), ref.provider != .claudeCode, !Self.hasSingleSlot(ref.provider),
              let account = account(ref.provider), account.isEnabled, isUsable(account) else { return nil }
        let writer = ChunkSummarizer.model(in: account, orb: ref.model)?.id ?? ref.model
        guard let client = clientOverride?() ?? account.client(for: account.models.first { $0.id == writer },
                                                               credentials: Self.credentials(for: ref.provider),
                                                               conversationID: botID.uuidString + "-memoria") else { return nil }
        let label = ModelRef(provider: ref.provider, model: writer).text
        return { [weak self] input in
            let note = await ChunkSummarizer.write(ChunkSummarizer.Plan(range: 0..<0, input: input), client: client, model: writer)
            if let usage = note.usage { await self?.recordSessionNoteUsage(usage, botID: botID, model: label) }
            return note.text
        }
    }

    /// On the Uso page, apart from the chat: a call the app made for itself, counted whether or not it gave a note.
    private func recordSessionNoteUsage(_ usage: TokenUsage, botID: UUID, model: String) {
        guard !isResetting, bot(botID) != nil else { return }
        recordAuxiliaryUsage(usage, botID: botID, model: model)
    }
}
