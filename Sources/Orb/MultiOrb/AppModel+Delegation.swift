import Foundation

// The app's side of Orbs asking each other for work: what a turn is handed (the tool, the teammates' section, the grant),
// and what the views and the other packages ask of the runtime. The hub itself is `DelegationHub`; `canTakeSideWork` and
// `startNextQueuedWork` (who runs next on a free Orb) are in `AppModel.swift`, beside the routines' queue they extend.

extension AppModel {
    /// What `orbs` asks of the app for `botID`, for a native turn (`ToolContext.orbs`). `turn`: the turn it serves; a call that
    /// arrives once that turn was stopped or replaced acts on nothing (its chain and grants are gone).
    func delegationHandler(for botID: UUID, turn: UUID? = nil) -> BridgeHandler {
        { [weak self] arguments in
            guard let model = self else { throw ToolError("O app está fechando.") }
            return try await model.delegation.handleTool(arguments, orb: botID, turn: turn)
        }
    }

    /// The group whose turn the Orb is running now, if it is one (the extension point of the groups' package: the board and the
    /// teammates of a group turn come from it).
    func turnGroup(of botID: UUID) -> UUID? {
        guard let session = sessions[botID], session.sideKind == .group else { return nil }
        return session.chain?.groupID
    }

    /// Which multi-Orb tools the Orb's next turn is offered. `orbs`: the switch is on and there is a teammate, or the turn is a
    /// group's. `propose` (WP3): the Orb's own chat, and with "Orbs agem por conta própria" a routine's or a request's too (a
    /// card there follows the approvals of those turns). In the own chat too: reading the boards of its groups, and creating a group with "Orbs podem
    /// acionar grupos" on. `groupMemory` belongs to the groups' package and is off here.
    func multiOrbOffering(for botID: UUID) -> MultiOrbOffering {
        // MultiOrb (WP5): in a member's turn the group decides: `orbs` when it lets members talk (the orchestrator always may),
        // and the board's tools.
        // `sideRun` follows the session, as `sideRunRefusal` does: what the short `schedule` leaves out is what the app refuses.
        let ownChat = isOwnChat(botID)
        if let group = groupTurnExtras(for: botID) {
            var offering = group.offering
            offering.sideRun = !ownChat
            return offering
        }
        let inGroup = turnGroup(of: botID) != nil
        // A member of a group may ask the group from its chat even with the switch off: groups do not depend on it.
        // "Orbs agem por conta própria" takes groups out of the own chat: a routine or a request may start them too.
        let mayStart = ownChat || orbsActOnOwn
        let hasTeam = inGroup || (orbsCanTalk && bots.count > 1) || (mayStart && canStartGroups(botID))
        return MultiOrbOffering(orbs: hasTeam, propose: mayStart, groupMemory: false,
                                groupRecall: ownChat && !groups(containing: botID).isEmpty,
                                groupCreate: mayStart && orbsCanStartGroups && bots.count > 1,
                                groupEdit: orbsCanManageGroups && (!groups.isEmpty || bots.count > 1),
                                orbDelete: orbsCanManageGroups && bots.count > 1, askUser: ownChat, access: ownChat,
                                sideRun: !ownChat)
    }

    /// The Orb's turn (or the next one) is its own chat's: not a routine's run, a request from another Orb or a group's turn.
    func isOwnChat(_ botID: UUID) -> Bool {
        sessions[botID].map { $0.routineID == nil && $0.sideKind == nil && $0.pulseInChat == nil } ?? true
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
        guard group == nil else {
            // The orchestrator of a group's turn is told which other groups it can ask, or it would not know their names.
            let others = otherGroupLines(for: bot.id, inTurnOf: group)
            let list = OrbsPrompt.groups(others, canStart: true, actsOnOwn: true, canEdit: orbsCanManageGroups)
            return [teammates, list].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let groups = OrbsPrompt.groups(groupLines(for: bot.id), canStart: (isOwnChat(bot.id) || orbsActOnOwn) && orbsCanStartGroups,
                                       actsOnOwn: orbsActOnOwn,
                                       canRecall: isOwnChat(bot.id), canEdit: orbsCanManageGroups,
                                       elsewhere: self.groups.filter { !$0.memberIDs.contains(bot.id) }.map(\.name))
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

    /// The other groups an orchestrator may ask or create from a group's turn (`DelegationHub.submitToGroup`): empty for a
    /// member that does not orchestrate, without "Orbs agem por conta própria" and "Orbs podem acionar grupos", or outside a turn.
    func otherGroupLines(for botID: UUID, inTurnOf groupID: UUID?) -> [OrbsPrompt.GroupLine] {
        guard let groupID, orbsActOnOwn, orbsCanStartGroups, group(groupID)?.orchestratorID == botID else { return [] }
        let own = group(groupID)?.name
        return groupLines(for: botID).filter { $0.name != own }
    }

    /// Who asked the request the Orb is working on, for the working line ("Pedido de Atlas"); nil outside a request.
    func requesterName(of botID: UUID) -> String? { delegation.requesterName(of: botID) }
}
