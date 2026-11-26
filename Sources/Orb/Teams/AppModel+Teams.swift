import Foundation

/// AppModel state helpers and lifecycle actions for autonomous Teams (`Times`), kept isolated from personal `Orbs` and `Grupos`.
@MainActor
extension AppModel {
    static let lastScouterModelKey = "lastScouterModel"
    static let defaultTeamPermissionModeKey = "defaultTeamPermissionMode"

    /// Remembers the last model picked for the Olheiro (`""` = app default model).
    var lastScouterModel: String {
        get { preferences.string(forKey: Self.lastScouterModelKey) ?? "" }
        set { preferences.set(newValue, forKey: Self.lastScouterModelKey) }
    }

    /// Default permission mode used when opening "Novo time" (`.bypass` by default per ADR 0002).
    var defaultTeamPermissionMode: PermissionMode {
        get {
            guard let raw = preferences.string(forKey: Self.defaultTeamPermissionModeKey),
                  let mode = PermissionMode(rawValue: raw) else { return .bypass }
            return mode
        }
        set { preferences.set(newValue.rawValue, forKey: Self.defaultTeamPermissionModeKey) }
    }

    func team(_ id: UUID) -> OrbTeam? {
        teams.first { $0.id == id }
    }

    func teamMember(teamID: UUID, memberID: UUID) -> TeamMember? {
        team(teamID)?.member(id: memberID)
    }

    var selectedTeamID: UUID? {
        switch selection {
        case .team(let id): team(id) != nil ? id : nil
        case .teamMember(let teamID, _): team(teamID) != nil ? teamID : nil
        default: nil
        }
    }

    var selectedTeamMember: (team: OrbTeam, member: TeamMember)? {
        guard case .teamMember(let teamID, let memberID) = selection,
              let team = team(teamID),
              let member = team.member(id: memberID) else { return nil }
        return (team, member)
    }

    func isTeamExpanded(_ teamID: UUID) -> Bool {
        expandedTeamIDs.contains(teamID)
    }

    func setTeamExpanded(_ teamID: UUID, expanded: Bool) {
        if expanded {
            expandedTeamIDs.insert(teamID)
        } else {
            expandedTeamIDs.remove(teamID)
        }
    }

    func toggleTeamExpanded(_ teamID: UUID) {
        setTeamExpanded(teamID, expanded: !isTeamExpanded(teamID))
    }

    /// Adds a normalized Team, provisions its isolated `times/<teamID>/` directories, expands it, and selects it.
    @discardableResult
    func addTeam(_ team: OrbTeam, select: Bool = true) -> OrbTeam? {
        guard let valid = team.normalized() else { return nil }
        teams.append(valid)
        store.prepareTeamDirectories(team: valid.id, needsWorkspace: valid.projectFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        expandedTeamIDs.insert(valid.id)
        if select { selection = .team(valid.id) }
        let bank = memory.teamBank(for: valid.id)
        Task { await TeamBoard.syncMission(valid, to: bank) }
        return valid
    }

    /// Creates a new Team from an edited/scouted `TeamProposal`, expands its wing row, and selects it.
    @discardableResult
    func createTeam(from proposal: TeamProposal, idea: String, scouterModel: String,
                    projectFolder: String, permissionMode: PermissionMode, select: Bool = true,
                    startNow: Bool = false) -> OrbTeam? {
        guard let team = proposal.buildTeam(idea: idea, scouterModel: scouterModel,
                                            projectFolder: projectFolder, permissionMode: permissionMode),
              let added = addTeam(team, select: select) else {
            return nil
        }
        if startNow { teamHub.start(added.id) }
        return added
    }

    func startTeam(_ teamID: UUID) {
        teamHub.start(teamID)
    }

    func pauseTeam(_ teamID: UUID) {
        teamHub.pause(teamID)
    }

    /// Removes a Team and all of its exclusive members and on-disk files together.
    func deleteTeam(_ teamID: UUID) {
        teamHub.pause(teamID)
        guard let index = teams.firstIndex(where: { $0.id == teamID }) else { return }
        teams.remove(at: index)
        expandedTeamIDs.remove(teamID)
        teamThreads.removeValue(forKey: teamID)
        memory.deleteTeam(teamID)
        store.deleteTeamFiles(team: teamID)
        if case .team(let id) = selection, id == teamID {
            selection = sidebarBotIDs.first.map(SidebarItem.bot)
        } else if case .teamMember(let tid, _) = selection, tid == teamID {
            selection = sidebarBotIDs.first.map(SidebarItem.bot)
        }
    }

    func teamThreadItems(for teamID: UUID) -> [TranscriptItem] {
        teamThreads[teamID] ?? []
    }

    func loadTeamThreadIfNeeded(_ teamID: UUID) {
        guard teamThreads[teamID] == nil else { return }
        let read = store.readTeamThread(team: teamID)
        teamThreads[teamID] = read.value?.items ?? []
    }

    func appendTeamThreadItem(_ item: TranscriptItem, to teamID: UUID) {
        loadTeamThreadIfNeeded(teamID)
        var list = teamThreads[teamID] ?? []
        list.append(item)
        teamThreads[teamID] = list
        var conversation = Conversation()
        conversation.items = list
        store.saveTeamThread(conversation, team: teamID)
        if selection != .team(teamID),
           let idx = teams.firstIndex(where: { $0.id == teamID }) {
            teams[idx].unread += 1
        }
    }

    /// Sends a user message to the Team's shared thread (reopening or steering the Mission) and starts execution.
    @discardableResult
    func postTeamMessage(_ raw: String, to teamID: UUID) -> Bool {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isResetting, !typed.isEmpty, let idx = teams.firstIndex(where: { $0.id == teamID }) else { return false }
        appendTeamThreadItem(TranscriptItem(.user(text: typed, attachments: [])), to: teamID)
        markTeamRead(teamID)
        // Every next turn carries the message, also when the Team is already running (`start` is then a no-op).
        teamHub.steer(teamID, message: typed)
        if teams[idx].status == .completed || teams[idx].status == .failed {
            teams[idx].mission.stages.append(MissionStage(
                title: typed,
                ownerMemberID: teams[idx].orchestratorID,
                reviewerMemberID: teams[idx].members.first(where: { $0.id != teams[idx].orchestratorID })?.id
            ))
            // New work can break what was verified: the final audit checks every criterion again.
            for c in teams[idx].mission.criteria.indices {
                teams[idx].mission.criteria[c].isVerified = false
                teams[idx].mission.criteria[c].lastEvidence = ""
            }
        }
        teamHub.start(teamID)
        return true
    }

    func markTeamRead(_ teamID: UUID) {
        guard let index = teams.firstIndex(where: { $0.id == teamID }), teams[index].unread != 0 else { return }
        teams[index].unread = 0
    }

    /// Promotes one Team member to a standalone personal Orb (`AppState.bots`), resolving any global name clash.
    @discardableResult
    func promoteMemberToOrb(teamID: UUID, memberID: UUID, select: Bool = false) -> Bot? {
        guard let team = team(teamID),
              let bot = team.promotedBot(for: memberID, existingBotNames: bots.map(\.name)) else { return nil }
        bots.append(bot)
        if select { selection = .bot(bot.id) }
        return bot
    }
}
