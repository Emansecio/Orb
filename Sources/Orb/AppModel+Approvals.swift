import SwiftUI

/// An open approval card and the Orb it belongs to.
struct PendingApproval: Identifiable {
    var bot: Bot
    var request: ApprovalRequest
    var id: UUID { request.id }
}

extension AppModel {
    /// The open cards of one Orb, oldest first. They are in the conversation the turn runs on: the chat itself, or a
    /// running routine's own conversation (the chat view shows the parked chat meanwhile, which has none).
    func pendingApprovals(of botID: UUID) -> [ApprovalRequest] {
        (sessions[botID]?.conversation?.items ?? transcript(botID)).compactMap { item in
            if case .approval(let request) = item.kind, request.decision == nil { request } else { nil }
        }
    }

    /// The card the keyboard answers: the Orb's newest open one.
    func newestPendingApprovalID(of botID: UUID) -> UUID? { pendingApprovals(of: botID).last?.id }

    /// Whether a card shows the keys (⌘↩, esc): only the one they answer, so two open cards never both claim them. A card
    /// the conversation does not hold (a sample) shows them.
    func showsApprovalKeys(_ approvalID: UUID, of botID: UUID) -> Bool {
        guard let newest = newestPendingApprovalID(of: botID) else { return true }
        return newest == approvalID
    }

    /// The Orb's open question (`ask_user`), when its newest open card is one: the message box answers it.
    func openQuestion(of botID: UUID) -> UUID? {
        guard let newest = pendingApprovals(of: botID).last, newest.isQuestion else { return nil }
        return newest.id
    }

    /// Every Orb's open cards, for the menu bar. Only reads conversations while some Orb is waiting, so the panel
    /// does not redraw with every streamed token otherwise.
    var pendingApprovals: [PendingApproval] {
        waitingIDs.flatMap { id in
            guard let live = liveBot(id) else { return [PendingApproval]() }
            return pendingApprovals(of: id).map { PendingApproval(bot: live.bot, request: $0) }
        }
    }

    /// The Orb is stopped on a question: the sidebar says so, from whichever Orb is open.
    func needsYou(_ botID: UUID) -> Bool { live(botID).needsYou }

    /// The routine this Orb is running and has stopped on a question: its card is in the routine's conversation, not in
    /// the chat.
    func routineWaitingForYou(_ botID: UUID) -> UUID? {
        guard live(botID).needsYou, sessions[botID]?.sideKind == nil else { return nil } // a request from another Orb is not a routine
        return sessions[botID]?.routineID
    }

    /// What a tap on a banner opens: the Orb's chat, or, for a routine waiting for an answer, its conversation.
    func showApprovalOwner(_ botID: UUID) {
        guard bot(botID) != nil else { return }
        if showGroupOfMember(botID) { return } // MultiOrb (WP5): a member waiting in a group's turn is answered in the group
        if routineWaitingForYou(botID) != nil { showRoutineRequest(of: botID); return }
        // MARK: MultiOrb (WP2): an approval raised inside a side run is in that run's conversation, not in the Orb's chat.
        if let session = sessions[botID], live(botID).needsYou {
            switch session.sideKind {
            case .delegation:
                if let request = session.servingRequest {
                    selection = .bot(botID)
                    sideWorkToShow = SideWorkTarget(botID: botID, requestID: request)
                    return
                }
            default: break
            }
        }
        // MARK: end MultiOrb (WP2)
        selection = .bot(botID)
    }

    /// Opens the routine's conversation, where its card is (Rotinas page, conversation sheet).
    func showRoutineRequest(of botID: UUID) {
        guard let routineID = routineWaitingForYou(botID) else { return }
        routineToShow = routineID
        selection = .routines
    }

    /// A banner with "Permitir" and "Não permitir" ("Pronto" and "Cancelar" for a hand-off) when the user is not looking at this card.
    func announceApproval(_ request: ApprovalRequest, of botID: UUID) {
        // For VoiceOver, when the card appears in the chat being shown (the banner covers the other cases).
        if selectedBot?.id == botID, let name = bot(botID)?.name {
            announceForAccessibility(request.isProposal ? "\(name) quer criar um Orb"
                                     : request.isQuestion ? "\(name) pergunta: \(request.command)"
                                     : request.isHandoff ? "\(name) espera você terminar no navegador" : "\(name) precisa da sua permissão")
        }
        watchUnanswered(request, of: botID)
        postBanner(for: request, of: botID)
    }

    /// The card's banner, unless the user is looking at it. `waited`: how long it has waited, for the reminder, whose
    /// banner takes the place of the first one (same identifier) instead of piling up.
    private func postBanner(for request: ApprovalRequest, of botID: UUID, waited: Duration? = nil) {
        guard let bot = bot(botID),
              ApprovalNotifications.shouldPost(appIsActive: NSApp?.isActive ?? false, selectedBotID: selectedBot?.id,
                                               botID: botID, enabled: Self.notificationsEnabled),
              ApprovalNotifications.isAvailable else { return }
        var payload = ApprovalNotifications.payload(botName: bot.name, botID: botID, request: request)
        if let waited { payload.body = ApprovalWait.reminder(waited) + payload.body }
        Task { await ApprovalNotifications.post(payload) { [weak self] in self?.isPending(request.id, of: botID) == true } }
    }

    /// A card nobody answers: one more banner after `ApprovalWait.remindAfter`, and after `giveUpAfter` the Orb stops
    /// waiting (`giveUpWaiting`). Each step first looks whether the card is still open; an answer, Parar or the end of
    /// the turn simply leaves nothing for it to do.
    /// Both steps are counted from when the card opened, on a clock that runs while the Mac sleeps: a reminder that comes
    /// late (the Mac woke) says how long it really waited.
    private func watchUnanswered(_ request: ApprovalRequest, of botID: UUID) {
        let opened = ContinuousClock.now, approvalID = request.id
        // The handles stay in `unansweredWatchers` so an answer (or the end of the turn) cancels the sleeping tasks
        // instead of leaving them for an hour or a day; they hold only the ids and look the card up when they wake.
        let reminder = Task { [weak self] in
            try? await Task.sleep(until: opened + ApprovalWait.remindAfter, clock: .continuous)
            guard !Task.isCancelled, let self,
                  let open = pendingApprovals(of: botID).first(where: { $0.id == approvalID }) else { return }
            postBanner(for: open, of: botID, waited: opened.duration(to: .now))
        }
        let giveUp = Task { [weak self] in
            try? await Task.sleep(until: opened + ApprovalWait.giveUpAfter, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.giveUpWaiting(on: approvalID, of: botID)
        }
        unansweredWatchers[approvalID] = [reminder, giveUp]
    }

    /// The cards stop being watched: they were answered or the turn that asked them ended.
    func stopWatching(_ approvalIDs: [UUID]) {
        for id in approvalIDs { unansweredWatchers.removeValue(forKey: id)?.forEach { $0.cancel() } }
    }

    /// The card is still open after a day: the Orb stops the task, as Parar would, so a forgotten question no longer
    /// holds its chat or the routines queued behind it, and the chat says why.
    func giveUpWaiting(on approvalID: UUID, of botID: UUID) {
        stopWatching([approvalID])
        guard isPending(approvalID, of: botID) else { return }
        stop(botID, notice: ApprovalWait.gaveUpNotice, reason: .gaveUp)
    }

    func isPending(_ approvalID: UUID, of botID: UUID) -> Bool {
        pendingApprovals(of: botID).contains { $0.id == approvalID }
    }

    /// What a tap on a banner asks for.
    func handle(_ route: ApprovalNotifications.Route) {
        switch route {
        case .decide(let decision, let botID, let approvalID):
            decide(decision, approvalID: approvalID, botID: botID)
        case .open(let botID):
            if let botID { showApprovalOwner(botID) }
            ApprovalNotifications.bringAppToFront()
        case .openGroup(let groupID):
            if group(groupID) != nil { selection = .group(groupID) }
            ApprovalNotifications.bringAppToFront()
        case .stop(let botID):
            if bot(botID) != nil, canStop(botID) { stopTurn(botID) }
        case .ignore:
            break
        }
    }
}

extension AppModel {
    /// Your answer to an approval card. `rule` is the standing rule picked under "Sempre…"; "Sempre" without one
    /// takes the card's first suggestion, and "Só nesta tarefa" grants that rule until the turn ends. `note` is what
    /// you told the Orb to do instead of what it asked, on a denial; `reply`, your answer to a question (`ask_user`), which
    /// `.deny` skips. A card already answered stays as it was (a banner can be tapped after the card was answered in the app or
    /// the app was closed).
    func decide(_ decision: ApprovalDecision, rule: PermissionRule? = nil, note: String? = nil, reply: String? = nil,
                approvalID: UUID, botID: UUID) {
        // Loaded first: a banner can arrive before this Orb's conversation was read, and a card left open by a run that
        // closed is already denied once it is. Only an open card is answered.
        guard bot(botID) != nil else { return }
        if sessions[botID]?.isLoading == true { // a read is under way: wait for it instead of reading the file again here
            Task {
                await loadedConversation(botID)
                decide(decision, rule: rule, note: note, reply: reply, approvalID: approvalID, botID: botID)
            }
            return
        }
        ensureLoaded(botID)
        guard isPending(approvalID, of: botID) else { return }
        var chosen = rule
        let note = decision == .deny ? ApprovalNote.clean(note) : nil
        let reply = decision == .deny ? nil : OrbQuestion.clean(reply)
        let session = session(botID)
        session.mutateItems { items in
            for index in items.indices {
                if case .approval(var request) = items[index].kind, request.id == approvalID {
                    request.decision = decision
                    request.note = note
                    request.question?.answer = reply
                    // A grouped card's "Só nesta tarefa" grants every rule it offered (the engine reads them from the card).
                    if decision == .always || (decision == .task && !request.isBatch) { chosen = chosen ?? request.suggestions.first }
                    items[index].kind = .approval(request)
                }
            }
        }
        session.updateAwaitingApproval()
        ApprovalNotifications.clear([approvalID])
        stopWatching([approvalID])
        // Saved before the engine is answered, so its next tool call already sees the rule.
        if decision == .always, let chosen, chosen.isValid {
            update(botID) { if !$0.permissionRules.contains(chosen) { $0.permissionRules.append(chosen) } }
        }
        let answer = ApprovalAnswer(decision: decision, rule: chosen, note: note, reply: reply)
        Task { await gate.resolve(approvalID: approvalID, answer: answer) }
    }
}

/// How long an open card waits for its answer (`AppModel.watchUnanswered`).
enum ApprovalWait {
    static let remindAfter: Duration = .seconds(60 * 60)
    static let giveUpAfter: Duration = .seconds(24 * 60 * 60)
    static let gaveUpNotice = "Ninguém respondeu em 24 horas: o Orb parou de esperar"

    /// What the reminder's banner says before the card's own line: "Esperando há 1 h · ".
    static func reminder(_ waited: Duration) -> String {
        let minutes = Int(waited.components.seconds / 60)
        return "Esperando há " + (minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min") + " · "
    }
}
