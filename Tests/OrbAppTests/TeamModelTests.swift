import Foundation
import Testing
@testable import Orb

@Suite struct TeamModelTests {
    private let temp = TempFolder("TeamModelTests")

    private func sampleTeam(name: String = "Auditoria UX",
                            memberNames: [String] = ["Arquiteto", "Revisor"],
                            projectFolder: String = "",
                            status: TeamStatus = .running) -> OrbTeam {
        let members = memberNames.map { TeamMember(name: $0, role: "Papel de \($0)") }
        return OrbTeam(name: name, idea: "Auditar interface", scouterModel: "anthropic/claude-sonnet-4-5",
                       projectFolder: projectFolder, permissionMode: .bypass,
                       orchestratorID: members[0].id, members: members,
                       mission: TeamMission(objective: "Entregar auditoria"), status: status)
    }

    @Test func tolerantDecodingHandlesUnknownEnumsAndMissingKeys() throws {
        let raw = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Time legado",
          "orchestratorID": "\(UUID().uuidString)",
          "status": "unknown_future_state",
          "members": [
            { "name": "Líder", "state": "alien_state" },
            { "name": "Executor" }
          ]
        }
        """
        let team = try JSONDecoder().decode(OrbTeam.self, from: Data(raw.utf8))
        #expect(team.name == "Time legado")
        #expect(team.status == .paused)
        #expect(team.permissionMode == .bypass)
        #expect(team.members.count == 2)
        #expect(team.members[0].state == .idle)
        #expect(team.members[0].capabilities == [.terminal, .browser, .computerUse])
        let normalized = team.normalized()
        #expect(normalized?.orchestratorID == team.members[0].id)
    }

    @Test func normalizationEnforcesBoundsDeduplicatesAndFixesOrchestrator() {
        let solo = sampleTeam(memberNames: ["Só um"])
        #expect(solo.normalized() == nil)

        var duplicate = sampleTeam(memberNames: ["Líder", "Executor"])
        duplicate.members.append(duplicate.members[0])
        duplicate.orchestratorID = UUID()
        duplicate.unread = -4
        let clean = duplicate.normalized()
        #expect(clean?.members.count == 2)
        #expect(clean?.orchestratorID == duplicate.members[0].id)
        #expect(clean?.unread == 0)

        let huge = sampleTeam(memberNames: (1...15).map { "Membro \($0)" })
        #expect(huge.normalized()?.members.count == OrbTeam.maxMembers)
    }

    @Test func memberNamesScopePerTeamAndResolvePromotionCollisions() {
        let teamA = sampleTeam(name: "Time A", memberNames: ["Líder", "Revisor"])
        let teamB = sampleTeam(name: "Time B", memberNames: ["Líder", "Revisor"])
        #expect(teamA.isMemberNameTaken("revisor"))
        #expect(teamA.isMemberNameTaken("REVÍSÓR"))
        #expect(teamA.uniqueMemberName(basedOn: "Revisor") == "Revisor 2")
        #expect(teamB.members[1].name == "Revisor")

        let promoted = teamA.promotedBot(for: teamA.members[1].id, existingBotNames: ["Revisor", "Atlas"])
        #expect(promoted?.name == "Revisor 2")
        #expect(promoted?.permissionMode == .bypass)
    }

    @Test func missionProgressTracksStagesAndCriteria() {
        let s1 = MissionStage(title: "Modelo", isDone: true)
        let s2 = MissionStage(title: "Lateral", isDone: false)
        let c1 = MissionCriterion(description: "Testes passam", isVerified: true, lastEvidence: "swift test ok")
        let mission = TeamMission(objective: "Entregar Fase 1", criteria: [c1], stages: [s1, s2])
        let progress = mission.progress
        #expect(progress.stagesDone == 1)
        #expect(progress.totalStages == 2)
        #expect(progress.criteriaVerified == 1)
        #expect(progress.fraction == 0.5)
        #expect(progress.stageSummary == "1 de 2 etapas")
    }

    @Test @MainActor func appModelAddPromoteDeletePersistsTeamsAndCleansDisk() async throws {
        let store = Store(directory: temp.url)
        let model = AppModel(store: store, runsBackgroundWork: false)
        let atlas = Bot(name: "Atlas", role: "Pessoal", orb: OrbConfig())
        model.bots = [atlas]

        var team = sampleTeam(name: "Time Produto", memberNames: ["Líder", "Atlas"])
        team.unread = 2
        let added = try #require(model.addTeam(team, select: true))
        #expect(model.teams.count == 1)
        #expect(model.bots.count == 1) // exclusive members never enter `bots`
        #expect(!model.isOrbNameTaken("Líder"))
        #expect(model.isTeamExpanded(added.id))
        #expect(model.selection == .team(added.id))
        #expect(model.team(added.id)?.unread == 0) // selecting marks read

        store.flush()
        let teamDir = store.teamDirectory(added.id)
        #expect(FileManager.default.fileExists(atPath: teamDir.path))
        #expect(FileManager.default.fileExists(atPath: store.teamWorkspaceDirectory(added.id).path))

        // Selecting a Team member keeps personal Orbs untouched, and promotion resolves Atlas -> Atlas 2.
        let secondMemberID = added.members[1].id
        model.selection = .teamMember(teamID: added.id, memberID: secondMemberID)
        #expect(model.selectedTeamMember?.member.id == secondMemberID)
        let promoted = try #require(model.promoteMemberToOrb(teamID: added.id, memberID: secondMemberID, select: false))
        #expect(promoted.name == "Atlas 2")
        #expect(model.bots.count == 2)

        // State persists in state.json and reloads cleanly.
        model.saveNow()
        let reloaded = AppModel(store: store, runsBackgroundWork: false)
        #expect(reloaded.teams.count == 1)
        let savedTeam = try #require(reloaded.teams.first)
        #expect(savedTeam.name == "Time Produto")

        // Selection points to a Team even when personal Orbs list is empty (`WelcomeSelection`).
        #expect(WelcomeSelection.resolved(.team(added.id), botIDs: []) == .team(added.id))
        #expect(WelcomeSelection.resolved(.teamMember(teamID: added.id, memberID: secondMemberID), botIDs: [])
            == .teamMember(teamID: added.id, memberID: secondMemberID))

        // Deleting a Team removes all exclusive members and its `times/<teamID>/` folder.
        model.deleteTeam(added.id)
        store.flush()
        #expect(model.teams.isEmpty)
        #expect(model.selection == .bot(atlas.id))
        #expect(!FileManager.default.fileExists(atPath: teamDir.path))
        #expect(model.bots.count == 2) // previously promoted personal Orb remains independent
    }

    @Test func resetGuardOwnsTimesFolderAndSidebarTextFormatsCleanly() {
        #expect(ResetGuard.removes(entry: TeamFiles.rootFolder))

        var team = sampleTeam(status: .running)
        team.unread = 3
        team.mission.stages = [MissionStage(title: "A", isDone: true), MissionStage(title: "B", isDone: false)]
        #expect(TeamRowText.subtitle(for: team) == "Executando · 1 de 2 etapas")
        #expect(TeamRowText.marker(for: team) == .unread)

        team.unread = 0
        #expect(TeamRowText.marker(for: team) == .working)

        team.status = .waitingUser
        #expect(TeamRowText.marker(for: team) == nil)
    }

    @Test @MainActor func teamThreadPersistsAndMessageReopensCompletedMission() throws {
        let store = Store(directory: temp.url.appendingPathComponent("thread"))
        let model = AppModel(store: store, runsBackgroundWork: false)
        let suite = "team-prefs-\(UUID().uuidString)"
        let prefs = try #require(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        model.preferences = prefs

        // ADR 0002: new Teams default to autonomous mode until the person picks another one.
        #expect(model.defaultTeamPermissionMode == .bypass)
        model.defaultTeamPermissionMode = .ask
        #expect(model.defaultTeamPermissionMode == .ask)

        var team = sampleTeam(status: .completed)
        team.mission.stages = [MissionStage(title: "Etapa inicial", isDone: true)]
        let added = try #require(model.addTeam(team))
        model.appendTeamThreadItem(TranscriptItem(.bot(text: "**Etapa concluída:** Etapa inicial", isStreaming: false)), to: added.id)
        model.saveNow()
        store.flush()

        let reloaded = AppModel(store: store, runsBackgroundWork: false)
        reloaded.loadTeamThreadIfNeeded(added.id)
        #expect(reloaded.teamThreads[added.id]?.count == 1)

        #expect(!reloaded.postTeamMessage("   ", to: added.id))
        #expect(reloaded.postTeamMessage("Adicionar validação extra", to: added.id))
        let updated = try #require(reloaded.team(added.id))
        reloaded.teamHub.pause(added.id)
        #expect(updated.status == .running)
        #expect(updated.mission.stages.count == 2)
        #expect(updated.mission.stages.last?.title == "Adicionar validação extra")
        #expect(updated.mission.stages.last?.ownerMemberID == updated.orchestratorID)
        #expect(updated.mission.stages.last?.reviewerMemberID != updated.orchestratorID)
        let kinds = reloaded.teamThreads[added.id]?.map(\.kind) ?? []
        #expect(kinds.contains { if case .user(let text, _) = $0 { text == "Adicionar validação extra" } else { false } })
    }
}
