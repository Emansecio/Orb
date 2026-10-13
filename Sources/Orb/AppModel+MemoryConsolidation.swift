import Foundation

extension AppModel {
    /// Starts a `MemoryConsolidation` pass when the Orb's pinned memory has grown past its threshold: in the background,
    /// without a word in the chat, at most once a day for a pass that gave nothing. Not in an Orb that only reads (its
    /// memory changes only when you ask).
    func consolidateMemoryIfDue(_ session: BotSession, now: Date = .now) {
        guard !isResetting, session.memoryConsolidation == nil,
              now.timeIntervalSince(session.memoryConsolidationTried ?? .distantPast) >= MemoryConsolidation.retryInterval,
              let bot = bot(session.id), bot.permissionMode != .readOnly,
              let ref = modelRef(for: bot), let account = account(ref.provider), account.isEnabled, isUsable(account) else { return }
        let botID = session.id
        let model = Self.dictationReviewer(in: account, orb: ref.model)
        let bank = memory.bank(for: botID)
        session.memoryConsolidation = Task {
            defer { session.memoryConsolidation = nil }
            let pinned = await bank.pinnedForConsolidation()
            guard pinned.count > MemoryConsolidation.threshold, !isResetting,
                  let client = clientOverride?() ?? account.client(for: account.models.first { $0.id == model },
                                                                   credentials: Self.credentials(for: ref.provider),
                                                                   conversationID: botID.uuidString + "-memoria") else { return }
            session.memoryConsolidationTried = now
            let result = await MemoryConsolidation.consolidate(pinned, client: client, model: model)
            guard !isResetting, self.bot(botID) != nil else { return }
            if let usage = result.usage {
                // On the Uso page, apart from the chat: a call the app made for itself.
                recordAuxiliaryUsage(usage, botID: botID, model: ModelRef(provider: ref.provider, model: model).text)
            }
            guard let consolidated = result.pinned, await bank.applyConsolidation(consolidated, replacing: pinned) else { return }
            session.memoryConsolidationTried = nil // done: the next pass waits for the threshold, not the clock
        }
    }
}
