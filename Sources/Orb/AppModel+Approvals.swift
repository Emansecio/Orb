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
        guard !awaitingApproval.isEmpty else { return [] }
        return bots.flatMap { bot in
            awaitingApproval.contains(bot.id) ? pendingApprovals(of: bot.id).map { PendingApproval(bot: bot, request: $0) } : []
        }
    }

    /// The Orb is stopped on a question: the sidebar says so, from whichever Orb is open.
    func needsYou(_ botID: UUID) -> Bool { awaitingApproval.contains(botID) }

    /// A banner with "Permitir" and "Não permitir" when the user is not looking at this card.
    func announceApproval(_ request: ApprovalRequest, of botID: UUID) {
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
