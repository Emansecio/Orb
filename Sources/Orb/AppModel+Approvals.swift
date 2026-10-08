import SwiftUI

/// An open approval card and the Orb it belongs to.
struct PendingApproval: Identifiable {
    var bot: Bot
    var request: ApprovalRequest
    var id: UUID { request.id }
}

extension AppModel {
    /// The open cards of one Orb, oldest first.
    func pendingApprovals(of botID: UUID) -> [ApprovalRequest] {
        transcript(botID).compactMap { item in
            if case .approval(let request) = item.kind, request.decision == nil { request } else { nil }
        }
    }

    /// The card the keyboard answers: the Orb's newest open one.
    func newestPendingApprovalID(of botID: UUID) -> UUID? { pendingApprovals(of: botID).last?.id }

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

    /// A banner with "Permitir" and "Não permitir" when the user is not looking at this card.
    func announceApproval(_ request: ApprovalRequest, of botID: UUID) {
        // For VoiceOver, when the card appears in the chat being shown (the banner covers the other cases).
        if selectedBot?.id == botID, let name = bot(botID)?.name { announceForAccessibility("\(name) precisa da sua permissão") }
        guard let bot = bot(botID),
              ApprovalNotifications.shouldPost(appIsActive: NSApp?.isActive ?? false, selectedBotID: selectedBot?.id,
                                               botID: botID, enabled: Self.notificationsEnabled),
              ApprovalNotifications.isAvailable else { return }
        let payload = ApprovalNotifications.payload(botName: bot.name, botID: botID, request: request)
        Task { await ApprovalNotifications.post(payload) { [weak self] in self?.isPending(request.id, of: botID) == true } }
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
            if let botID, bot(botID) != nil { selection = .bot(botID) }
            ApprovalNotifications.bringAppToFront()
        case .ignore:
            break
        }
    }
}

extension AppModel {
    /// Your answer to an approval card. `rule` is the standing rule picked under "Sempre…"; "Sempre" without one
    /// takes the card's first suggestion, and "Só nesta tarefa" grants that rule until the turn ends. `note` is what
    /// you told the Orb to do instead of what it asked, on a denial. A card already answered stays as it was (a
    /// banner can be tapped after the card was answered in the app or the app was closed).
    func decide(_ decision: ApprovalDecision, rule: PermissionRule? = nil, note: String? = nil, approvalID: UUID, botID: UUID) {
        // Loaded first: a banner can arrive before this Orb's conversation was read, and a card left open by a run that
        // closed is already denied once it is. Only an open card is answered.
        guard bot(botID) != nil else { return }
        if sessions[botID]?.isLoading == true { // a read is under way: wait for it instead of reading the file again here
            Task {
                await loadedConversation(botID)
                decide(decision, rule: rule, note: note, approvalID: approvalID, botID: botID)
            }
            return
        }
        ensureLoaded(botID)
        guard isPending(approvalID, of: botID) else { return }
        var chosen = rule
        let note = decision == .deny ? ApprovalNote.clean(note) : nil
        let session = session(botID)
        session.mutateItems { items in
            for index in items.indices {
                if case .approval(var request) = items[index].kind, request.id == approvalID {
                    request.decision = decision
                    request.note = note
                    // A grouped card's "Só nesta tarefa" grants every rule it offered (the engine reads them from the card).
                    if decision == .always || (decision == .task && !request.isBatch) { chosen = chosen ?? request.suggestions.first }
                    items[index].kind = .approval(request)
                }
            }
        }
        session.updateAwaitingApproval()
        ApprovalNotifications.clear([approvalID])
        // Saved before the engine is answered, so its next tool call already sees the rule.
        if decision == .always, let chosen, chosen.isValid {
            update(botID) { if !$0.permissionRules.contains(chosen) { $0.permissionRules.append(chosen) } }
        }
        let answer = ApprovalAnswer(decision: decision, rule: chosen, note: note)
        Task { await gate.resolve(approvalID: approvalID, answer: answer) }
    }
}
