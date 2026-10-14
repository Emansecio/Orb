import Foundation

extension AppModel {
    /// Starts a `MemoryConsolidation` pass when the Orb's pinned memory has grown past its threshold (or no longer fits its share): in the background,
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
            let identityLength = await bank.identityLength()
            guard MemoryConsolidation.isDue(pinned, identityLength: identityLength), !isResetting,
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
            await refreshMemory(botID) // the panel's Memória tab shows the pages as they are now
        }
    }

    /// Starts a `MemoryMerge` pass when the pages the Orb wrote have grown past its threshold: in the background, and
    /// a failed pass waits a day like the consolidation. What it finds is only proposed (a notice with "Unificar");
    /// nothing changes until you accept. Not while a routine has the Orb (the notice would land in its conversation),
    /// nor in an Orb that only reads.
    func proposeMemoryMergeIfDue(_ session: BotSession, now: Date = .now) {
        guard !isResetting, session.memoryMerge == nil, session.routineID == nil,
              now.timeIntervalSince(session.memoryMergeTried ?? .distantPast) >= MemoryConsolidation.retryInterval,
              let bot = bot(session.id), bot.permissionMode != .readOnly,
              let ref = modelRef(for: bot), let account = account(ref.provider), account.isEnabled, isUsable(account) else { return }
        let botID = session.id
        let model = Self.dictationReviewer(in: account, orb: ref.model)
        let bank = memory.bank(for: botID)
        session.memoryMerge = Task {
            defer { session.memoryMerge = nil }
            guard let candidates = await bank.mergeDue(now: now), !isResetting,
                  let client = clientOverride?() ?? account.client(for: account.models.first { $0.id == model },
                                                                   credentials: Self.credentials(for: ref.provider),
                                                                   conversationID: botID.uuidString + "-memoria") else { return }
            session.memoryMergeTried = now
            let groups = await Task.detached(priority: .utility) { MemoryMerge.groups(candidates) }.value // every pair: off the main thread
            var merged: [MemoryMerge.Group] = [], answered = false
            for pages in groups {
                let (outcome, usage) = await MemoryMerge.merge(pages, client: client, model: model)
                guard !isResetting, self.bot(botID) != nil else { return }
                if let usage { recordAuxiliaryUsage(usage, botID: botID, model: ModelRef(provider: ref.provider, model: model).text) }
                if case .merged(let group) = outcome { merged.append(group) }
                if outcome != .failed { answered = true }
            }
            // Every call failed, or a routine took the Orb meanwhile (the notice would land in its run, and a proposal
            // with no notice could never be accepted): tried again in a day. Otherwise the next proposal waits for `step`
            // more pages.
            guard answered || groups.isEmpty, merged.isEmpty || sessions[botID]?.routineID == nil,
                  await bank.saveMergeProposal(merged, askedCount: candidates.count, now: now) else { return }
            session.memoryMergeTried = nil
            guard !merged.isEmpty else { return }
            let pages = merged.reduce(0) { $0 + $1.sources.count }
            let titles = merged.map { "“\($0.title)”" }.joined(separator: ", ")
            append(.notice("\(NoticeAction.memoryMergePrefix) \(pages) páginas parecidas viram \(merged.count): \(titles). "
                           + "Os originais ficam no arquivo da memória."), to: botID)
        }
    }

    /// Whether the proposal `notice` shows still waits: an older notice left in the chat does not offer a newer one.
    func hasMemoryMergeProposal(_ botID: UUID, notice: String) async -> Bool {
        guard sessions[botID] != nil else { return false }
        let groups = await memory.bank(for: botID).pendingMerge()
        return !groups.isEmpty && groups.allSatisfy { notice.contains("“\($0.title)”") }
    }

    /// "Unificar": applies the proposal and says in the chat what was done.
    func applyMemoryMerge(_ botID: UUID) async {
        guard sessions[botID] != nil, bot(botID)?.permissionMode != .readOnly else { return }
        let text = switch await memory.bank(for: botID).applyMerge() {
        case nil: "A proposta de unificação já não vale (foi aplicada ou expirou); nada mudou."
        case let done? where done.groups == 0: "A memória mudou desde a proposta; nada foi unificado."
        case let done?: "Memória unificada: \(done.pages) páginas viraram \(done.groups). Os originais estão em _arquivo/consolidacoes."
        }
        append(.notice(text), to: botID)
        await refreshMemory(botID)
    }
}
