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
        let ownChat = isOwnChat(botID)
        // A member of a group may ask the group from its chat even with the switch off: groups do not depend on it.
        let hasTeam = inGroup || (orbsCanTalk && bots.count > 1) || (ownChat && canStartGroups(botID))
        return MultiOrbOffering(orbs: hasTeam, propose: ownChat, groupMemory: false, askUser: ownChat)
    }

    /// The Orb's turn (or the next one) is its own chat's: not a routine's run, a request from another Orb or a group's turn.
    func isOwnChat(_ botID: UUID) -> Bool {
        sessions[botID].map { $0.routineID == nil && $0.sideKind == nil } ?? true
    }

    /// The Orb may send requests to its groups from its chat ("Orbs podem acionar grupos", and it is in some group).
    func canStartGroups(_ botID: UUID) -> Bool {
        orbsCanStartGroups && !groups(containing: botID).isEmpty
    }

    /// The system prompt's section about the teammates and, outside a group's turn, the groups the Orb is in (empty when
    /// there are none).
    func orbsSection(for bot: Bot) -> String {
        let group = turnGroup(of: bot.id)
        let team = delegation.roster(for: bot.id, groupID: group).compactMap { self.bot($0.id) }
        let teammates = OrbsPrompt.section(for: bot, roster: team, isGroup: group != nil)
        guard group == nil else { return teammates }
        let groups = OrbsPrompt.groups(groupLines(for: bot.id), canStart: isOwnChat(bot.id) && orbsCanStartGroups)
        return [teammates, groups].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The groups the Orb is in, as the prompt and `orbs list` name them.
    func groupLines(for botID: UUID) -> [OrbsPrompt.GroupLine] {
        groups(containing: botID).map { group in
            OrbsPrompt.GroupLine(name: group.name, orchestrator: bot(group.orchestratorID)?.name ?? "Orb",
                                 youOrchestrate: group.orchestratorID == botID,
                                 others: group.memberIDs.filter { $0 != botID }.compactMap { bot($0)?.name })
        }
    }

    /// Who asked the request the Orb is working on, for the working line ("Pedido de Atlas"); nil outside a request.
    func requesterName(of botID: UUID) -> String? { delegation.requesterName(of: botID) }

    /// The request, if any, the Orb's running side run answers.
    func servingRequest(of botID: UUID) -> DelegationRequest? {
        sessions[botID]?.servingRequest.flatMap { delegation.requests[$0] }
    }
}
