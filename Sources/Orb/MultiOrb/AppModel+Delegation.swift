import Foundation

// The app's side of Orbs asking each other for work: what a turn is handed (the tool, the teammates' section, the grant),
// and what the views and the other packages ask of the runtime. The hub itself is `DelegationHub`; `canTakeSideWork` and
// `startNextQueuedWork` (who runs next on a free Orb) are in `AppModel.swift`, beside the routines' queue they extend.

extension AppModel {
    /// What `orbs` asks of the app for `botID`, for a native turn (`ToolContext.orbs`).
    func delegationHandler(for botID: UUID) -> BridgeHandler {
        { [weak self] arguments in
            guard let model = self else { throw ToolError("O app está fechando.") }
            return try await model.delegation.handleTool(arguments, orb: botID)
        }
    }

    /// The group whose turn the Orb is running now, if it is one (the extension point of the groups' package: the board and the
    /// teammates of a group turn come from it).
    func turnGroup(of botID: UUID) -> UUID? {
        guard let session = sessions[botID], session.sideKind == .group else { return nil }
        return session.chain?.groupID
    }

    /// Which multi-Orb tools the Orb's next turn is offered. `orbs`: the switch is on and there is a teammate, or the turn is a
    /// group's. `propose` (WP3): the Orb's own chat only, not a routine's or a request's side conversation, which nobody
    /// watches to answer the card. `groupMemory` belongs to the groups' package and is off here.
    func multiOrbOffering(for botID: UUID) -> MultiOrbOffering {
        // MultiOrb (WP5): in a member's turn the group decides: `orbs` when it lets members talk (the orchestrator always may),
        // and the board's tools.
        if let group = groupTurnExtras(for: botID) { return group.offering }
        let inGroup = turnGroup(of: botID) != nil
        let hasTeam = inGroup || (orbsCanTalk && bots.count > 1)
        let ownChat = sessions[botID].map { $0.routineID == nil && $0.sideKind == nil } ?? true
        return MultiOrbOffering(orbs: hasTeam, propose: ownChat, groupMemory: false)
    }

    /// The system prompt's section about the teammates (empty when there are none).
    func orbsSection(for bot: Bot) -> String {
        let group = turnGroup(of: bot.id)
        let team = delegation.roster(for: bot.id, groupID: group).compactMap { self.bot($0.id) }
        return OrbsPrompt.section(for: bot, roster: team, isGroup: group != nil)
    }

    /// Who asked the request the Orb is working on, for the working line ("Pedido de Atlas"); nil outside a request.
    func requesterName(of botID: UUID) -> String? { delegation.requesterName(of: botID) }

    /// The request, if any, the Orb's running side run answers.
    func servingRequest(of botID: UUID) -> DelegationRequest? {
        sessions[botID]?.servingRequest.flatMap { delegation.requests[$0] }
    }
}
