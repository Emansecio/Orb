import Foundation

enum TeamCheckResult: Sendable, Equatable {
    case passed(command: String, summary: String = "")
    case failed(command: String, output: String)
}

enum TeamIntegrationOutcome: Sendable, Equatable {
    case integrated(commit: String, cleanedBranches: [String])
    case postMergeFailed(commit: String, command: String, output: String)
    case conflict(String)
    case unavailable(String)
}

/// Manages per-member isolation (`worktree` inside git repos or `times/<teamID>/espaco/` otherwise),
/// sequential ordered integration into the main checkout, post-merge verification, and live-board sync.
enum TeamWorkspaces {
    /// Prepares the working folder for a Team member turn:
    /// - When `projectFolder` is a git repo, non-orchestrator members get isolated `WorkFolders` worktrees while the orchestrator uses main checkout.
    /// - When `projectFolder` is empty, each front writes into an isolated subfolder under `times/<teamID>/espaco/`.
    /// - When `projectFolder` is a plain non-git folder, all members share that folder safely with a note.
    static func prepareMemberFolder(team: OrbTeam, member: TeamMember, runID: UUID, dataFolder: URL,
                                    gitPath: String? = nil) async -> WorkFolder {
        let trimmed = team.projectFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let base = dataFolder
                .appendingPathComponent(TeamFiles.rootFolder, isDirectory: true)
                .appendingPathComponent(team.id.uuidString, isDirectory: true)
                .appendingPathComponent(TeamFiles.workspaceFolder, isDirectory: true)
            let slug = WorkFolders.slug(member.name)
            let folder = member.id == team.orchestratorID
                ? base
                : base.appendingPathComponent(slug, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return WorkFolder(url: folder)
        }
        let project = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        if member.id == team.orchestratorID || !WorkspaceSnapshot.hasRepository(project) {
            return WorkFolder(url: project)
        }
        return await WorkFolders.prepare(project: project, member: member.name, run: runID,
                                         root: WorkFolders.root(in: dataFolder), gitPath: gitPath)
    }

    /// Merges an approved branch sequentially into `project`, runs the post-merge check on the integrated checkout,
    /// updates Block 3 (Contracts) & Block 4 (Verification Log) in `TeamBoard`, and cleans up merged worktrees.
    static func integrateBranch(_ branch: String, into project: URL, stageTitle: String, team: OrbTeam,
                                board: MemoryBank, runID: UUID, dataFolder: URL, gitPath: String? = nil,
                                verify: (@Sendable () async -> TeamCheckResult)? = nil) async -> TeamIntegrationOutcome {
        let mergeResult = await WorkFolders.mergeBranch(
            branch,
            into: project,
            message: "time(\(WorkFolders.slug(team.name))): \(stageTitle)",
            gitPath: gitPath
        )
        switch mergeResult {
        case .conflict(let detail):
            return .conflict(detail)
        case .unavailable(let reason):
            return .unavailable(reason)
        case .merged(let commit):
            if let verify {
                let check = await verify()
                switch check {
                case .failed(let command, let output):
                    await TeamBoard.recordVerification(stageTitle: stageTitle, command: command, passed: false,
                                                       commit: commit, summary: output, to: board)
                    return .postMergeFailed(commit: commit, command: command, output: output)
                case .passed(let command, let summary):
                    await TeamBoard.recordVerification(stageTitle: stageTitle, command: command, passed: true,
                                                       commit: commit, summary: summary, to: board)
                }
            }
            let touched = await WorkFolders.changedFiles(in: commit, project: project, gitPath: gitPath)
            if !touched.isEmpty {
                await TeamBoard.markStaleContracts(touching: touched, commit: commit, to: board)
            }
            let author = team.orchestrator?.name ?? "Líder"
            await TeamBoard.recordContract(title: "Integração \(stageTitle)",
                                           summary: "Ramo \(branch) integrado no commit \(commit).",
                                           author: author, to: board)
            let removed = await WorkFolders.cleanUpBranch(branch, in: project,
                                                          root: WorkFolders.root(in: dataFolder), gitPath: gitPath)
            return .integrated(commit: commit, cleanedBranches: removed ? [branch] : [])
        }
    }
}
