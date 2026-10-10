import AppKit
import Foundation

// The app's side of the groups (docs/MULTI-ORBS.md, 7): making, changing and deleting them, keeping them true to the Orbs that
// exist, a group's thread and live state, and the doors the person uses to talk to a group, continue it, end it or stop it.
// The loop itself is `GroupHub`.

extension GroupBudget {
    /// The presets of the panel and the new-group sheet (Econômico, Equilibrado, Amplo).
    static let economic = GroupBudget(maxTurns: 8, maxTokens: 100_000)
    static let balanced = GroupBudget(maxTurns: 12, maxTokens: 150_000)
    static let wide = GroupBudget(maxTurns: 24, maxTokens: 300_000)
}

extension AppModel {
    // MARK: Looking

    func group(_ id: UUID) -> OrbGroup? { groups.first { $0.id == id } }

    /// The groups the Orb is a member of.
    func groups(containing botID: UUID) -> [OrbGroup] { groups.filter { $0.memberIDs.contains(botID) } }

    /// The group's live state (made when first asked for).
    func groupLive(_ id: UUID) -> GroupLive {
        if let live = groupLives[id] { return live }
        let live = GroupLive(id: id)
        groupLives[id] = live
        return live
    }

    /// The group's thread, read from disk the first time it is asked for. Nil for a group that does not exist.
    func groupSession(_ id: UUID) -> GroupSession? {
        guard group(id) != nil else { return nil }
        if let session = groupSessions[id] {
            session.lastUsed = .now
            return session
        }
        let read = store.readGroupConversation(group: id)
        addNotice(read.notice)
        var conversation = read.value?.closingInterruptedTurn() ?? Conversation()
        // A request in flight does not survive the app closing: an assignment still open is lost.
        for index in conversation.items.indices {
            if case .orbMessage(var message) = conversation.items[index].kind, message.direction == .post, message.state == .open {
                message.state = .lost
                conversation.items[index].kind = .orbMessage(message)
            }
        }
        let session = GroupSession(groupID: id, conversation: conversation)
        session.persist = { [store] saved in store.saveGroupConversation(saved, group: id) }
        groupSessions[id] = session
        return session
    }

    /// Lets go of the threads nobody looks at: no request running, nothing left to save, not the open one, unused for `idle`.
    func unloadIdleGroupSessions(idle: Duration = .seconds(600)) {
        for (id, session) in groupSessions {
            guard selection != .group(id), !groupHub.isActive(id), !session.isDirty,
                  ContinuousClock.now - session.lastUsed > idle else { continue }
            groupSessions[id] = nil
        }
    }

    /// Writes every thread that changed (quitting).
    func saveGroupSessionsNow() {
        for session in groupSessions.values { session.saveNow() }
    }

    // MARK: Making and changing

    /// Makes a group of `members` (2 to 8 existing Orbs; the first is the orchestrator unless `orchestrator` is one of them).
    /// Nil when the members do not fit. `objective` is the group's goal on its board.
    @discardableResult
    func createGroup(name: String, members: [UUID], orchestrator: UUID? = nil, objective: String = "",
                     budget: GroupBudget = GroupBudget(), policy: GroupPolicy = GroupPolicy()) -> OrbGroup? {
        var seen = Set<UUID>()
        let ids = members.filter { bot($0) != nil && seen.insert($0).inserted }
        guard OrbGroup.memberLimits.contains(ids.count) else { return nil }
        let title = Self.groupTitle(name, fallback: ids.compactMap { bot($0)?.name })
        let group = OrbGroup(name: title, memberIDs: ids, orchestratorID: orchestrator.flatMap { ids.contains($0) ? $0 : nil } ?? ids[0],
                             budget: budget, policy: policy)
        groups.append(group)
        let session = groupSession(group.id)
        session?.append(.event(OrbEvent(kind: .groupCreated, detail: "\(title) · \(ids.count)", groupID: group.id)))
        for id in ids {
            appendToChat(.event(OrbEvent(kind: .joinedGroup, subject: orbRef(id), detail: title, groupID: group.id)), of: id)
        }
        let goal = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty {
            let bank = memory.groupBank(for: group.id)
            Task { await bank.setIdentity(goal) }
        }
        return group
    }

    /// The name a group gets when the person left it blank: its members', "Atlas, Pesquisador e Revisor".
    nonisolated static func groupTitle(_ name: String, fallback names: [String]) -> String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? GroupPresence.list(names) : String(typed.prefix(80))
    }

    func renameGroup(_ id: UUID, to name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = groups.firstIndex(where: { $0.id == id }), groups[index].name != String(title.prefix(80)) else { return }
        groups[index].name = String(title.prefix(80))
    }

    /// Adds an Orb to the group (up to 8). False when it cannot join.
    @discardableResult
    func addMember(_ botID: UUID, to groupID: UUID) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == groupID }), bot(botID) != nil,
              !groups[index].memberIDs.contains(botID), groups[index].memberIDs.count < OrbGroup.memberLimits.upperBound else { return false }
        groups[index].memberIDs.append(botID)
        let title = groups[index].name
        groupSession(groupID)?.append(.event(OrbEvent(kind: .joinedGroup, subject: orbRef(botID), detail: title, groupID: groupID)))
        appendToChat(.event(OrbEvent(kind: .joinedGroup, subject: orbRef(botID), detail: title, groupID: groupID)), of: botID)
        return true
    }

    /// Takes an Orb out of the group. A group left with fewer than two Orbs is dissolved; a member in the middle of the group's
    /// request stops the request first.
    @discardableResult
    func removeMember(_ botID: UUID, from groupID: UUID) -> Bool {
        leave(botID, group: groupID, name: bot(botID)?.name ?? "Orb", deleted: false)
    }

    /// Makes `botID` the orchestrator: it receives the person's messages from now on.
    @discardableResult
    func setOrchestrator(_ botID: UUID, of groupID: UUID) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == groupID }), groups[index].memberIDs.contains(botID) else { return false }
        if groups[index].orchestratorID != botID { groups[index].orchestratorID = botID }
        return true
    }

    func setGroupBudget(_ budget: GroupBudget, of groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }), groups[index].budget != budget else { return }
        groups[index].budget = budget
    }

    func setGroupPolicy(_ policy: GroupPolicy, of groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }), groups[index].policy != policy else { return }
        groups[index].policy = policy
    }

    /// The group's goal (the identity page of its board). False when the text is refused (too long).
    @discardableResult
    func setGroupObjective(_ text: String, of groupID: UUID) async -> Bool {
        guard group(groupID) != nil else { return false }
        return await memory.groupBank(for: groupID).setIdentity(text)
    }

    /// Deletes the group: its request stops, its thread, board and the members' conversations in it go. The Orbs stay.
    func deleteGroup(_ id: UUID) {
        guard let group = group(id) else { return }
        groupHub.forget(id, writesEvent: false)
        groups.removeAll { $0.id == id }
        removeData(of: group)
    }

    /// An Orb is being deleted: it leaves every group it is in (a group that would be left with one Orb is dissolved).
    func leaveGroups(_ botID: UUID, name: String) {
        for group in groups(containing: botID) { leave(botID, group: group.id, name: name, deleted: true) }
    }

    // MARK: Keeping groups true to the Orbs

    /// The invariants of 7.1: members that no longer exist leave, a missing orchestrator becomes the first member, a group with
    /// fewer than two members is dissolved. Runs when the state is read and whenever the list of Orbs changes.
    func normalizeGroups() {
        guard !groups.isEmpty else { return }
        let alive = Set(bots.map(\.id))
        var kept: [OrbGroup] = []
        var dissolved: [OrbGroup] = []
        for group in groups {
            if let normalized = group.normalized(alive: alive) { kept.append(normalized) } else { dissolved.append(group) }
        }
        if kept != groups { groups = kept }
        for group in dissolved { dissolve(group, remaining: group.memberIDs.filter { alive.contains($0) }) }
    }

    @discardableResult
    private func leave(_ botID: UUID, group groupID: UUID, name: String, deleted: Bool) -> Bool {
        guard let group = group(groupID), group.memberIDs.contains(botID) else { return false }
        if group.memberIDs.count <= OrbGroup.memberLimits.lowerBound {
            groups.removeAll { $0.id == groupID }
            dissolve(group, remaining: group.memberIDs.filter { $0 != botID && bot($0) != nil })
            return true
        }
        if groupHub.isWorking(botID, in: groupID) { groupHub.stopGroup(groupID) }
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        groups[index].memberIDs.removeAll { $0 == botID }
        if groups[index].orchestratorID == botID { groups[index].orchestratorID = groups[index].memberIDs[0] }
        let leaving = OrbEvent(kind: .leftGroup, subject: OrbRef(id: botID, name: name), detail: group.name, groupID: groupID)
        groupSession(groupID)?.append(.event(leaving))
        if !deleted { appendToChat(.event(leaving), of: botID) }
        store.deleteGroupSideConversation(group: groupID, for: botID)
        return true
    }

    /// A group that cannot go on: the Orbs that remain are told in their chats and everything of the group goes.
    private func dissolve(_ group: OrbGroup, remaining: [UUID]) {
        groupHub.forget(group.id, writesEvent: false)
        let note = "O grupo \(group.name) foi desfeito: ficou com menos de 2 Orbs."
        for id in remaining {
            appendToChat(.event(OrbEvent(kind: .unknown, subject: orbRef(id), detail: note, groupID: group.id)), of: id)
        }
        removeData(of: group)
    }

    private func removeData(of group: OrbGroup) {
        groupSessions[group.id]?.discard()
        groupSessions[group.id] = nil
        groupLives[group.id] = nil
        store.deleteGroupConversation(group: group.id)
        memory.deleteGroup(group.id)
        for member in group.memberIDs { store.deleteGroupSideConversation(group: group.id, for: member) }
        if selection == .group(group.id) { selection = bots.first.map { .bot($0.id) } }
    }

    // MARK: Talking to a group

    /// The person writes to the group (see `GroupHub.postUserMessage`).
    @discardableResult
    func postUserMessage(_ text: String, to groupID: UUID) -> Bool { groupHub.postUserMessage(text, to: groupID) }

    /// "Continuar" on the pause card.
    func continueRun(_ groupID: UUID) { groupHub.continueRun(groupID) }

    /// "Encerrar" on the pause card.
    func endRun(_ groupID: UUID) { groupHub.endRun(groupID) }

    /// "Parar grupo" and ⌘.: everything the group is doing stops.
    func stopGroup(_ groupID: UUID) { groupHub.stopGroup(groupID) }

    /// Whether the group has a request going on (the header shows "Parar grupo").
    func isGroupWorking(_ groupID: UUID) -> Bool { groupHub.isActive(groupID) }

    // MARK: Pieces for the hub and the engines

    /// The hub of the groups, wired to the app's delegation service, thread focus and banners.
    func makeGroupHub() -> GroupHub {
        let hub = GroupHub(model: self, delegation: delegation)
        hub.isFocused = { [weak self] id in self?.selection == .group(id) && (NSApp?.isActive ?? true) }
        hub.postNotice = { [weak self] title, body, id in self?.postGroupNotice(title: title, body: body, groupID: id) }
        return hub
    }

    /// A banner for a group (its pause, its end), when the app is behind other windows. A tap opens the group.
    private func postGroupNotice(title: String, body: String, groupID: UUID) {
        guard Self.notificationsEnabled, ApprovalNotifications.isAvailable, !(NSApp?.isActive ?? false) else { return }
        let content = ApprovalNotifications.plainContent(title: title, body: body)
        content.userInfo = [ApprovalNotifications.groupKey: groupID.uuidString]
        Task { await ApprovalNotifications.send(content) }
    }

    func orbRef(_ botID: UUID) -> OrbRef { OrbRef(id: botID, name: bot(botID)?.name ?? "Orb") }

    /// An event line in the Orb's own chat (in the chat itself, also while a side run has it parked).
    func appendToChat(_ kind: TranscriptItem.Kind, of botID: UUID) {
        guard bot(botID) != nil else { return }
        ensureLoaded(botID)
        let session = session(botID)
        if var parked = session.parkedChat {
            parked.items.append(TranscriptItem(kind))
            session.parkedChat = parked
            session.isDirty = true
            session.scheduleSave(delay: BotSession.streamingSaveInterval)
        } else {
            append(kind, to: botID)
        }
    }

    /// What a group's turn adds to the turn of an Orb (nil when the Orb is not in a turn of a group).
    func groupTurnExtras(for botID: UUID) -> GroupTurnExtras? {
        guard let turn = groupHub.turn(of: botID), let group = group(turn.groupID), let run = groupHub.run(turn.groupID) else { return nil }
        let isOrchestrator = botID == group.orchestratorID
        let role: GroupPrompt.Role = isOrchestrator ? .orchestrator : .member
        // A member may ask the others only when the group lets members talk; the orchestrator always may.
        let offering = MultiOrbOffering(orbs: isOrchestrator || group.policy.membersMayTalk, propose: false, groupMemory: true)
        return GroupTurnExtras(
            groupID: group.id, runID: run.id, requestID: turn.requestID,
            groupName: group.name, role: role, turnBudget: run.turnLimit,
            offering: offering, grants: [PermissionRule(family: .delegation), PermissionRule(family: .groupMemory)],
            bank: memory.groupBank(for: group.id), bankDirectory: memory.groupDirectory(for: group.id),
            sideRun: SideRunInfo(kind: .group, id: turn.requestID,
                                 chain: ChainContext(chainID: run.id, hop: 1, path: [], groupID: group.id, serving: turn.requestID)))
    }

    /// Where an approval card of a member in a group is answered: the group's own screen.
    func showGroupOfMember(_ botID: UUID) -> Bool {
        guard let groupID = groupHub.activeGroup(of: botID) else { return false }
        selection = .group(groupID)
        return true
    }
}

/// What the engines add to a member's turn in a group (see `AppModel.groupTurnExtras`): the section of the system prompt, which
/// of the multi-Orb tools are offered, the grants that let those tools run without a card per call, and the board's bank (and
/// folder, for Claude Code's tools server).
struct GroupTurnExtras {
    var groupID: UUID
    var runID: UUID
    var requestID: UUID
    var groupName: String
    var role: GroupPrompt.Role
    var turnBudget: Int
    var offering: MultiOrbOffering
    var grants: [PermissionRule]
    var bank: MemoryBank
    var bankDirectory: URL
    var sideRun: SideRunInfo

    /// The group section of the system prompt; in a Claude Code turn the tools carry the tools server's prefix.
    func system(claudeCode: Bool) -> String {
        GroupPrompt.section(groupName: groupName, role: role, turnBudget: turnBudget,
                            toolPrefix: claudeCode ? ClaudeCodeTools.memoryPrefix : "")
    }
}
