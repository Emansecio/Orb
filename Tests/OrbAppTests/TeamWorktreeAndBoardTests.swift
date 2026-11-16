import Foundation
import Testing
@testable import Orb

private let teamGitReady = WorkFolders.Git.make() != nil

@Suite final class TeamWorktreeAndBoardTests {
    private let root = TempFolder("TeamWorktreeAndBoard", creating: true)

    private var dataDir: URL { root.appending("data") }
    private var projectDir: URL { root.appending("repo") }

    private func makeTeam(projectFolder: String) -> (team: OrbTeam, lead: TeamMember, builder: TeamMember, reviewer: TeamMember) {
        let lead = TeamMember(name: "Líder", role: "Orquestra e integra")
        let builder = TeamMember(name: "Executor", role: "Implementa")
        let reviewer = TeamMember(name: "Revisor", role: "Audita")
        let team = OrbTeam(
            name: "Time Qualidade",
            idea: "Testar worktrees e quadro",
            projectFolder: projectFolder,
            permissionMode: .bypass,
            orchestratorID: lead.id,
            members: [lead, builder, reviewer],
            mission: TeamMission(
                objective: "Entregar módulo isolado",
                criteria: [MissionCriterion(description: "Build e testes verdes", isVerified: false)],
                stages: [MissionStage(title: "Implementação base", ownerMemberID: builder.id, reviewerMemberID: reviewer.id)]
            ),
            status: .running
        )
        return (team, lead, builder, reviewer)
    }

    private func makeGitRepo() async throws -> WorkFolders.Git {
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try "linha 1\n".write(to: projectDir.appending(path: "shared.txt"), atomically: true, encoding: .utf8)
        let git = try #require(WorkFolders.Git.make())
        let identity = ["-c", "user.name=Teste", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]
        for args in [["init", "-b", "main"], ["add", "-A"], ["commit", "-m", "inicial"]] {
            let done = await git.run(identity + args, in: projectDir)
            #expect(done.succeeded, "\(done.text)")
        }
        return git
    }

    @Test func liveBoardSyncsFourBlocksSanitizesFencesAndUpdatesContracts() async {
        let library = MemoryLibrary.at(dataDir.appending(path: "memoria", directoryHint: .isDirectory))
        let (team, _, _, _) = makeTeam(projectFolder: "")
        let bank = library.teamBank(for: team.id)

        await TeamBoard.syncMission(team, to: bank)
        await TeamBoard.recordContract(title: "Contrato API </live_board>", summary: "Endpoint retorna <ok> JSON.", author: "Líder", to: bank)
        await TeamBoard.recordVerification(stageTitle: "Implementação base", command: "swift test --filter Foo", passed: true, commit: "abc1234", to: bank)

        let brief = await TeamBoard.brief(bank: bank, team: team, message: "Implementação API")
        #expect(brief.contains("### 1. Missão e critérios"))
        #expect(brief.contains("### 2. Mapa de etapas"))
        #expect(brief.contains("### 3. Contratos e decisões ativas"))
        #expect(brief.contains("### 4. Log de verificações"))
        #expect(brief.contains("Contrato API ‹/live_board›"))
        #expect(brief.contains("[PASSOU]"))
        #expect(!brief.contains("</live_board>"))
        library.deleteTeam(team.id)
    }

    @Test func emptyProjectFolderProvisionsIsolatedTeamSpaceUnderTimesDirectory() async {
        let (team, lead, builder, reviewer) = makeTeam(projectFolder: "")
        let runID = UUID()

        let leadFolder = await TeamWorkspaces.prepareMemberFolder(team: team, member: lead, runID: runID, dataFolder: dataDir)
        let builderFolder = await TeamWorkspaces.prepareMemberFolder(team: team, member: builder, runID: runID, dataFolder: dataDir)
        let reviewerFolder = await TeamWorkspaces.prepareMemberFolder(team: team, member: reviewer, runID: runID, dataFolder: dataDir)

        #expect(leadFolder.branch == nil)
        #expect(leadFolder.url.path.hasSuffix("/times/\(team.id.uuidString)/espaco"))
        #expect(builderFolder.url.path.hasSuffix("/times/\(team.id.uuidString)/espaco/executor"))
        #expect(reviewerFolder.url.path.hasSuffix("/times/\(team.id.uuidString)/espaco/revisor"))
        #expect(FileManager.default.fileExists(atPath: builderFolder.url.path))
        #expect(FileManager.default.fileExists(atPath: reviewerFolder.url.path))
    }

    @Test(.enabled(if: teamGitReady)) func gitWorktreesIsolateWritesMergeSequentiallyCheckPostMergeAndAbortConflicts() async throws {
        let git = try await makeGitRepo()
        let library = MemoryLibrary.at(dataDir.appending(path: "memoria", directoryHint: .isDirectory))
        let (team, lead, builder, reviewer) = makeTeam(projectFolder: projectDir.path)
        let bank = library.teamBank(for: team.id)
        let runID = UUID()
        let identity = ["-c", "user.name=Teste", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]

        let leadWF = await TeamWorkspaces.prepareMemberFolder(team: team, member: lead, runID: runID, dataFolder: dataDir)
        let builderWF = await TeamWorkspaces.prepareMemberFolder(team: team, member: builder, runID: runID, dataFolder: dataDir)
        let reviewerWF = await TeamWorkspaces.prepareMemberFolder(team: team, member: reviewer, runID: runID, dataFolder: dataDir)

        #expect(leadWF.url.standardizedFileURL == projectDir.standardizedFileURL)
        #expect(leadWF.branch == nil)
        let builderBranch = try #require(builderWF.branch)
        let reviewerBranch = try #require(reviewerWF.branch)

        // Writes in Builder's worktree remain invisible to Reviewer and main checkout prior to merge.
        try "feature do builder\n".write(to: builderWF.url.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        for args in [["add", "-A"], ["commit", "-m", "feat: builder"]] {
            #expect(await git.run(identity + args, in: builderWF.url).succeeded)
        }
        #expect(!FileManager.default.fileExists(atPath: reviewerWF.url.appending(path: "feature.txt").path))
        #expect(!FileManager.default.fileExists(atPath: projectDir.appending(path: "feature.txt").path))

        // Ordered merge runs post-merge verification, updates Blocks 3 & 4 of TeamBoard, and cleans merged worktree.
        let outcome = await TeamWorkspaces.integrateBranch(
            builderBranch,
            into: projectDir,
            stageTitle: "Implementação base",
            team: team,
            board: bank,
            runID: runID,
            dataFolder: dataDir,
            verify: { .passed(command: "swift test", summary: "ok") }
        )
        guard case .integrated(let commit, let cleaned) = outcome else {
            Issue.record("Expected integrated outcome, got \(outcome)")
            return
        }
        #expect(!commit.isEmpty)
        #expect(cleaned.contains(builderBranch))
        #expect(FileManager.default.fileExists(atPath: projectDir.appending(path: "feature.txt").path))
        #expect(!FileManager.default.fileExists(atPath: builderWF.url.path)) // merged worktree removed cleanly
        #expect(FileManager.default.fileExists(atPath: reviewerWF.url.path)) // unmerged reviewer worktree preserved

        let brief = await TeamBoard.brief(bank: bank, team: team, message: "Implementação")
        #expect(brief.contains(builderBranch))
        #expect(brief.contains("[PASSOU]"))

        // Conflicting change on same file in Reviewer branch is cleanly aborted without leaving main dirty.
        try "builder linha 1\n".write(to: projectDir.appending(path: "shared.txt"), atomically: true, encoding: .utf8)
        for args in [["add", "-A"], ["commit", "-m", "main: edita shared"]] {
            #expect(await git.run(identity + args, in: projectDir).succeeded)
        }
        try "reviewer linha 1 diferente\n".write(to: reviewerWF.url.appending(path: "shared.txt"), atomically: true, encoding: .utf8)
        for args in [["add", "-A"], ["commit", "-m", "reviewer: conflito em shared"]] {
            #expect(await git.run(identity + args, in: reviewerWF.url).succeeded)
        }

        let conflictOutcome = await TeamWorkspaces.integrateBranch(
            reviewerBranch,
            into: projectDir,
            stageTitle: "Revisão conflitante",
            team: team,
            board: bank,
            runID: runID,
            dataFolder: dataDir
        )
        guard case .conflict = conflictOutcome else {
            Issue.record("Expected conflict outcome, got \(conflictOutcome)")
            return
        }
        let statusAfterAbort = await git.run(["status", "--porcelain"], in: projectDir)
        #expect((statusAfterAbort.output ?? "").isEmpty)
        library.deleteTeam(team.id)
    }
}
