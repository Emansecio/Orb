import Foundation

/// Going on with what the app was doing when it closed (`WorkJournal`). A quit and a crash resume the same way, once per
/// interruption; Parar before quitting is how to really stop. Routines are not resumed: their schedule runs them again.
extension AppModel {
    /// How long a resumed task waits for an Orb that something else took at launch (a routine due at that moment).
    static let resumeBusyWait: (tries: Int, every: Duration) = (30, .seconds(2))

    /// What the person sees of a group's request that was cut off.
    static let groupResumedNotice = "O app fechou no meio deste pedido; retomando."

    /// Launch: reads what the previous run left and takes it up again, after the first look at the connections (a request sent
    /// before it would fail for want of a usable model). The returned task ends when every resumed piece has begun or given up.
    @discardableResult
    func resumeInterruptedWork(now: Date = .now) -> Task<Void, Never>? {
        let entries = workJournal.beginLaunch(now: now)
        guard !entries.isEmpty else { return nil }
        return Task { [weak self] in
            await self?.connectionsChecked()
            guard let self, !isResetting else { return }
            // Groups and requests only queue the work (the hub starts it when the Orb is free); an Orb's own task is waited for.
            for entry in entries {
                switch entry.kind {
                case .groupRun: resumeGroupRun(entry)
                case .request: resumeRequest(entry)
                case .pulse:
                    // A pulse is opportunistic: the next one looks again, so a cut one is dropped instead of resumed.
                    if let botID = entry.botID { workJournal.dropPulse(bot: botID) }
                case .chatTask, .unknown: break
                }
            }
            let tasks = entries.filter { $0.kind == .chatTask }.map { entry in Task { await self.resumeChatTask(entry) } }
            for task in tasks { await task.value }
        }
    }

    /// The Orb's own conversation was cut off by the close: it is asked to continue, as the notice's "Continuar" does, only when
    /// the cut is still the last word of the conversation (nobody wrote since).
    private func resumeChatTask(_ entry: WorkEntry) async {
        guard let botID = entry.botID, let chat = entry.chatID else { return }
        guard bot(botID) != nil else { return workJournal.chatTaskEnded(bot: botID, chat: chat) }
        let session = session(botID)
        func giveUp() {
            session.endWorkElsewhere() // nothing began: the one on show takes the turn machinery back
            workJournal.chatTaskEnded(bot: botID, chat: chat)
        }
        var tries = Self.resumeBusyWait.tries
        while bot(botID) != nil, !isResetting, !(canTakeSideWork(botID) && isOwnChat(botID)), tries > 0 {
            tries -= 1
            try? await Task.sleep(for: Self.resumeBusyWait.every)
        }
        await loadedConversation(botID)
        guard bot(botID) != nil, !isResetting, canTakeSideWork(botID), isOwnChat(botID), isChat(chat, of: botID),
              await prepareTurn(in: chat, of: botID), Self.wasCutOff(session.conversation?.items ?? []),
              send(Self.resumeMessage(lostJobs: entry.lostJobs), to: botID) else { return giveUp() }
    }

    /// The conversation ends on the app's "closed in the middle of this task" notice, with no message of the person after it.
    static func wasCutOff(_ items: [TranscriptItem]) -> Bool {
        for item in items.reversed() {
            switch item.kind {
            case .user: return false
            case .notice(let text) where text == BotSession.quitNotice: return true
            default: continue
            }
        }
        return false
    }

    /// What "Continuar" sends after the close, with a word about the processes that died with the app.
    static func resumeMessage(lostJobs: Int) -> String {
        let base = NoticeAction.continueMessage(after: BotSession.quitNotice)
        guard lostJobs > 0 else { return base }
        return base + " \(lostJobs) processo(s) em segundo plano pararam com o app: inicie de novo o que ainda for preciso."
    }

    /// A group's request: the thread says it was cut off, and the orchestrator is asked to check what is done and reassign the rest.
    private func resumeGroupRun(_ entry: WorkEntry) {
        guard let groupID = entry.groupID else { return }
        guard let session = groupSession(groupID) else { return workJournal.dropGroupRun(groupID) } // the group is gone
        let lost = session.items.compactMap { item -> String? in
            // The thread marks the assignments that were open as lost when it is read (`installGroupSession`).
            guard case .orbMessage(let post) = item.kind, post.direction == .post, (post.state == .lost || post.state == .cancelled), post.kind != .reply,
                  post.chainID == entry.runID else { return nil }
            return "\(post.to?.name ?? "?"): " + MemoryText.clip(MemoryText.flatten(post.text), 100)
        }
        let recovery = "The app closed during this request. Assignments marked lost: "
            + (lost.isEmpty ? "none" : lost.joined(separator: "; "))
            + ". Check what is already done, then reassign what is left."
        if !groupHub.resume(groupID, runID: entry.runID, request: entry.text ?? "", recovery: recovery, notice: Self.groupResumedNotice) {
            workJournal.dropGroupRun(groupID)
        }
    }

    /// An Orb's request to another: sent again with a note, in the same chain, so the answer wakes the asker as it would have.
    private func resumeRequest(_ entry: WorkEntry) {
        guard let envelope = entry.envelope else { return }
        if !delegation.resubmit(envelope) { workJournal.dropRequest(envelope.id) }
    }
}
