import Foundation

// The note on the stretch the next fold will take (see `ChunkSummary`), asked for in the background when a turn of the
// chat ends and the history is near its budget. It never waits and is never waited for: nothing in the transcript, no
// steps, and when it fails the summary is simply the rules' alone.

extension AppModel {
    /// After a turn of the native engine ends: starts the note, when one is due. A routine's run, a developer mode and
    /// Claude Code (its side requests would each start a CLI process) never get one.
    func writeStretchNote(of botID: UUID) {
        let session = session(botID)
        guard writesStretchNotes, !isDevRun, !isResetting, session.routineID == nil, session.chunkTask == nil,
              let conversation = session.conversation, let bot = bot(botID), let ref = modelRef(for: bot), ref.provider != .claudeCode,
              let account = account(ref.provider), account.isEnabled, isUsable(account),
              let budget = contextBudget(for: bot) else { return }
        // A stretch is asked about at most `maxAttempts` times: checked before the plan, which is the costly part.
        let stretch = conversation.noteFrontier
        guard session.chunkAttempts[stretch, default: 0] < ChunkSummarizer.maxAttempts else { return }
        let identity = conversation.gatewaySessionID ?? botID.uuidString
        let idle = Self.hasSingleSlot(ref.provider) ? localNoteDelay : 0
        session.chunkTask = Task { [weak self] in
            // A local server has one slot, and a request for the note would push the start of the conversation out of its
            // cache: it is asked only once the cache is cold anyway (the next message pays for the whole history then), and
            // a message sent before that cancels this (`yieldStretchNote`).
            var conversation = conversation
            if idle > 0 {
                try? await Task.sleep(for: .seconds(idle))
                guard !Task.isCancelled else { return }
                // Five minutes went by: the Orb may have another model now, or be in a routine or a reset. Then nothing is asked.
                guard let self, let current = session.conversation, !self.isResetting, session.routineID == nil,
                      let now = self.bot(botID).flatMap(self.modelRef(for:)), now == ref,
                      let still = self.account(ref.provider), still.isEnabled, self.isUsable(still) else {
                    session.chunkTask = nil
                    return
                }
                conversation = current
            }
            let plan = await Task.detached(priority: .utility) { [conversation] in ChunkSummarizer.plan(for: conversation, budget: budget) }.value
            guard let self, let plan, !Task.isCancelled else {
                if !Task.isCancelled { session.chunkTask = nil }
                return
            }
            let writer = ChunkSummarizer.model(in: account, orb: ref.model)
            let client = self.clientOverride?() ?? account.client(for: writer ?? account.models.first { $0.id == ref.model },
                                                                  credentials: Self.credentials(for: ref.provider),
                                                                  conversationID: identity + "-resumo")
            var note: ChunkSummarizer.Note?
            if let client { note = try? await ChunkSummarizer.write(plan, client: client, model: writer?.id ?? ref.model) }
            guard !Task.isCancelled else { return } // the Orb, the conversation or the whole app was let go of meanwhile
            session.chunkAttempts[stretch, default: 0] += 1
            if let note {
                if let usage = note.usage {
                    // On the Uso page, apart from the chat: a call the app made for itself.
                    self.recordAuxiliaryUsage(usage, botID: botID, model: ModelRef(provider: ref.provider, model: writer?.id ?? ref.model).text)
                    if CacheHealth.logsUsage {
                        FileHandle.standardError.write(Data(("stretch note: " + CacheHealth.logLine(step: 0, usage: usage) + "\n").utf8))
                    }
                }
                session.keepStretchNote(ChunkSummary(start: plan.range.lowerBound, end: plan.range.upperBound, text: note.text))
            }
            session.chunkTask = nil
        }
    }

    /// Ollama and LM Studio serve one request at a time and keep one conversation in the cache of their slot.
    static func hasSingleSlot(_ provider: ProviderKind) -> Bool { provider == .ollama || provider == .lmstudio }

    /// A message is about to be sent. A local server has one slot, so a note waiting for its time (`localNoteDelay`) or
    /// still being written would make the message wait behind it or push the start of the conversation out of the server's
    /// cache: there the note gives way (and does not count as an attempt). Elsewhere it runs alongside the turn.
    func yieldStretchNote(to botID: UUID, provider: ProviderKind) {
        guard Self.hasSingleSlot(provider) else { return }
        session(botID).cancelChunkNote()
    }
}

extension BotSession {
    /// Keeps the note on a stretch; the next fold that takes the stretch carries it into the summary. Not while a
    /// routine's run has the conversation (the note is about the chat parked meanwhile).
    func keepStretchNote(_ note: ChunkSummary) {
        guard conversation != nil, routineID == nil, parkedChat == nil else { return }
        changeConversation { $0.keep(note) }
        scheduleSave(delay: Self.streamingSaveInterval)
    }

    /// The note being written is not wanted any more (the Orb, the conversation or the app was let go of).
    func cancelChunkNote() {
        chunkTask?.cancel()
        chunkTask = nil
    }
}
