import Foundation
import Testing
@testable import Orb

// Worktrees for the members of a group that shares a repository: made once per member and run, reused, absent without git,
// and cleaned up when their branch is in the project. The ones that need git run against a throwaway repository and are
// skipped on a Mac without it.

private let gitReady = WorkFolders.Git.make() != nil

/// A throwaway repository with one commit on `main`.
private final class Repo: Sendable {
    let folder: TempFolder
    let project: URL
    let work: URL

    init() async throws {
        folder = TempFolder("OrbWorkFolders", creating: true)
        project = folder.appending("projeto")
        work = folder.appending("trabalho")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "um\n".write(to: project.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try await git(["init", "-b", "main"], in: project)
        try await commit("primeiro", in: project)
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL) async throws -> String {
        let git = try #require(WorkFolders.Git.make())
        let identity = ["-c", "user.name=Teste", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]
        let result = await git.run(identity + arguments, in: directory)
        #expect(result.succeeded, "git \(arguments.joined(separator: " ")): \(result.text)")
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commit(_ message: String, in directory: URL) async throws {
        try await git(["add", "-A"], in: directory)
        try await git(["commit", "-m", message], in: directory)
    }

    func prepare(_ member: String, run: UUID) async -> WorkFolder {
        await WorkFolders.prepare(project: project, member: member, run: run, root: work)
    }

    func branches() async throws -> [String] {
        try await git(["branch", "--format=%(refname:short)"], in: project).split(separator: "\n").map(String.init)
    }
}

struct WorkFolderNamesTests {
    @Test func slugsAreSafeInBranchesAndPaths() {
        #expect(WorkFolders.slug("Atlas") == "atlas")
        #expect(WorkFolders.slug("Pesquisadora Nº 1") == "pesquisadora-n-1")
        #expect(WorkFolders.slug("Ação/Revisão") == "acao-revisao")
        #expect(WorkFolders.slug("../../etc") == "etc")
        #expect(WorkFolders.slug("日本語") == "orb")
        #expect(WorkFolders.slug(String(repeating: "a", count: 80)).count == 24)
    }

    @Test func namesThatLoseInformationInTheSlugStayApart() {
        #expect(WorkFolders.memberSlug("Atlas") == "atlas", "a plain name keeps its folder")
        #expect(WorkFolders.memberSlug("🔎") != WorkFolders.memberSlug("✍️"))
        #expect(WorkFolders.memberSlug("日本語") != WorkFolders.memberSlug("中文"))
        let long = String(repeating: "a", count: 30)
        #expect(WorkFolders.memberSlug(long + "1") != WorkFolders.memberSlug(long + "2"))
        #expect(WorkFolders.memberSlug("Revisão") == "revisao", "accents fold, nothing is lost")
        #expect(WorkFolders.memberSlug("🔎").hasPrefix("orb-"))
        #expect(WorkFolders.memberSlug("Back-end") != WorkFolders.memberSlug("Back end"))
        #expect(WorkFolders.memberSlug("C++") != WorkFolders.memberSlug("C#"))
        #expect(WorkFolders.memberSlug("Back end") == "back-end", "words split by spaces keep their folder")
    }

    @Test func theHashTellsTwoFoldersWithTheSameNameApart() {
        #expect(WorkFolders.hash("/a/app") != WorkFolders.hash("/b/app"))
        #expect(WorkFolders.hash("/a/app") == WorkFolders.hash("/a/app"))
        #expect(WorkFolders.hash("/a/app").count == 8)
    }

    @Test func worktreeListsAreParsed() {
        let text = """
        worktree /repo
        HEAD 1111
        branch refs/heads/main

        worktree /data/trabalho/p/atlas-1234
        HEAD 2222
        branch refs/heads/orb/atlas/1234

        worktree /data/other
        HEAD 3333
        detached
        """
        #expect(WorkFolders.parseWorktrees(text) == [
            .init(path: "/repo", branch: "main"),
            .init(path: "/data/trabalho/p/atlas-1234", branch: "orb/atlas/1234"),
            .init(path: "/data/other", branch: nil)])
    }

    @Test func theNotesTellWhereToWork() {
        let url = URL(fileURLWithPath: "/w/atlas-1")
        let own = WorkFolder(url: url, branch: "orb/atlas/1")
        #expect(WorkFolders.memberNote(own) == "Work in /w/atlas-1 (branch orb/atlas/1). Commit your work there before you answer.")
        #expect(WorkFolders.memberNote(own, asked: true).hasSuffix("Name the branch in your answer."))
        #expect(WorkFolders.memberNote(WorkFolder(url: url)) == "Shared folder /w/atlas-1: others edit it too; re-read a file before changing it.")
        let failed = WorkFolders.memberNote(WorkFolder(url: url, problem: "git is not available"))
        #expect(failed.hasPrefix("No separate worktree (git is not available).") && failed.contains("Shared folder /w/atlas-1"))
    }
}

@Suite(.enabled(if: gitReady)) struct WorkFoldersTests {
    @Test func aMemberGetsAWorktreeOnABranchOfItsOwn() async throws {
        let repo = try await Repo()
        let run = UUID()
        let made = await repo.prepare("Atlas", run: run)
        #expect(made.problem == nil)
        #expect(made.branch == "orb/atlas/\(WorkFolders.shortID(run))")
        #expect(made.url.lastPathComponent == "atlas-\(WorkFolders.shortID(run))")
        #expect(made.url.path.hasPrefix(repo.work.path))
        #expect(FileManager.default.fileExists(atPath: made.url.appending(path: "a.txt").path), "it starts from the project's HEAD")
        #expect(try await repo.branches().contains(made.branch ?? "?"))
        // Work there does not touch the project.
        try "dois\n".write(to: made.url.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        #expect(!FileManager.default.fileExists(atPath: repo.project.appending(path: "b.txt").path))
    }

    @Test(.enabled(if: gitReady)) func aWorktreeLeftHalfMadeIsRebuiltInsteadOfHandedOver() async throws {
        let repo = try await Repo()
        let run = UUID()
        let first = await repo.prepare("Atlas", run: run)
        let gitDir = try await repo.git(["rev-parse", "--path-format=absolute", "--git-dir"], in: first.url)
        // What a git killed during checkout leaves: the worktree is registered and holds a stale lock.
        try "".write(to: URL(fileURLWithPath: gitDir).appending(path: "index.lock"), atomically: true, encoding: .utf8)
        let again = await repo.prepare("Atlas", run: run)
        #expect(again.problem == nil && again.branch == first.branch)
        let lock = try await repo.git(["rev-parse", "--path-format=absolute", "--git-path", "index.lock"], in: again.url)
        #expect(!FileManager.default.fileExists(atPath: lock))
        #expect(FileManager.default.fileExists(atPath: again.url.appending(path: "a.txt").path))
    }

    @Test(.enabled(if: gitReady)) func aFailedAddLeavesNoBranchOrFolderBehind() async throws {
        let repo = try await Repo()
        let run = UUID()
        // A file where the worktree folder must go makes the add fail after the branch name is chosen.
        let slot = repo.work.appending(path: "\(WorkFolders.slug("projeto"))-\(WorkFolders.hash(repo.project.standardizedFileURL.path))")
            .appending(path: "atlas-\(WorkFolders.shortID(run))")
        try FileManager.default.createDirectory(at: slot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: slot, atomically: true, encoding: .utf8)
        let made = await repo.prepare("Atlas", run: run)
        #expect(made.problem != nil && made.branch == nil)
        #expect(try await repo.branches() == ["main"])
    }

    @Test func theSameMemberAndRunGetTheSameWorktreeAgain() async throws {
        let repo = try await Repo()
        let run = UUID()
        let first = await repo.prepare("Atlas", run: run)
        try "meio\n".write(to: first.url.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        let again = await repo.prepare("Atlas", run: run)
        #expect(again == first)
        #expect(FileManager.default.fileExists(atPath: again.url.appending(path: "b.txt").path), "what it had done is still there")
        let other = await repo.prepare("Lia", run: run)
        let later = await repo.prepare("Atlas", run: UUID())
        #expect(other.url != first.url && later.url != first.url)
    }

    @Test func membersStartingTogetherDoNotCollide() async throws {
        let repo = try await Repo()
        let run = UUID()
        let made = await withTaskGroup(of: WorkFolder.self) { group in
            for name in ["Atlas", "Lia", "Teo", "Revisor"] { group.addTask { await repo.prepare(name, run: run) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(made.count == 4 && made.allSatisfy { $0.branch != nil && $0.problem == nil })
        #expect(Set(made.map(\.url)).count == 4)
    }

    @Test func aFolderInsideTheRepositoryGetsTheSameSubfolderInTheWorktree() async throws {
        let repo = try await Repo()
        let sub = repo.project.appending(path: "app")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "x\n".write(to: sub.appending(path: "m.txt"), atomically: true, encoding: .utf8)
        try await repo.commit("sub", in: repo.project)
        let made = await WorkFolders.prepare(project: sub, member: "Atlas", run: UUID(), root: repo.work)
        #expect(made.branch != nil && made.url.lastPathComponent == "app")
        #expect(FileManager.default.fileExists(atPath: made.url.appending(path: "m.txt").path))
    }

    @Test func aFolderWithoutGitIsSharedAsItIs() async throws {
        let folder = TempFolder("OrbWorkFoldersPlain", creating: true)
        let project = folder.appending("solto")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let made = await WorkFolders.prepare(project: project, member: "Atlas", run: UUID(), root: folder.appending("trabalho"))
        #expect(made == WorkFolder(url: project.standardizedFileURL))
        #expect(!FileManager.default.fileExists(atPath: folder.appending("trabalho").path))
        let note = await WorkFolders.orchestratorNote(project: project, run: UUID(), root: folder.appending("trabalho"))
        #expect(note == WorkFolders.sharedNote(project.standardizedFileURL))
    }

    @Test func aRepositoryWithoutCommitsFallsBackToTheProjectAndSaysWhy() async throws {
        let folder = TempFolder("OrbWorkFoldersEmpty", creating: true)
        let project = folder.appending("novo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let git = try #require(WorkFolders.Git.make())
        #expect(await git.run(["init", "-b", "main"], in: project).succeeded)
        let made = await WorkFolders.prepare(project: project, member: "Atlas", run: UUID(), root: folder.appending("trabalho"))
        #expect(made.url == project.standardizedFileURL && made.branch == nil)
        #expect(made.problem?.isEmpty == false)
        #expect(WorkFolders.memberNote(made).contains("No separate worktree"))
    }

    @Test func gitThatIsNotThereMeansTheSharedFolder() async throws {
        let repo = try await Repo()
        let made = await WorkFolders.prepare(project: repo.project, member: "Atlas", run: UUID(), root: repo.work,
                                             gitPath: "/nonexistent/git")
        #expect(made.branch == nil && made.url == repo.project.standardizedFileURL)
    }

    @Test func theOrchestratorWorksInTheProjectAndSeesTheBranches() async throws {
        let repo = try await Repo()
        let run = UUID()
        let before = await WorkFolders.orchestratorNote(project: repo.project, run: run, root: repo.work)
        #expect(before.contains("orb/<member>/\(WorkFolders.shortID(run))") && before.contains("git merge"))
        let atlas = await repo.prepare("Atlas", run: run)
        _ = await repo.prepare("Lia", run: UUID()) // another run's: not listed
        let after = await WorkFolders.orchestratorNote(project: repo.project, run: run, root: repo.work)
        let branch = try #require(atlas.branch)
        #expect(after.contains(branch) && !after.contains("orb/lia"))
        #expect(after.contains(repo.project.standardizedFileURL.path))
    }

    @Test func cleaningUpRemovesWhatWasMergedAndKeepsTheRest() async throws {
        let repo = try await Repo()
        let run = UUID()
        let atlas = await repo.prepare("Atlas", run: run)
        let lia = await repo.prepare("Lia", run: run)
        let teo = await repo.prepare("Teo", run: run) // never commits
        let other = await repo.prepare("Revisor", run: UUID()) // another run: left alone even though it is "merged"
        try "atlas\n".write(to: atlas.url.appending(path: "atlas.txt"), atomically: true, encoding: .utf8)
        try await repo.commit("atlas", in: atlas.url)
        try "lia\n".write(to: lia.url.appending(path: "lia.txt"), atomically: true, encoding: .utf8)
        try await repo.commit("lia", in: lia.url)
        let atlasBranch = try #require(atlas.branch), liaBranch = try #require(lia.branch), teoBranch = try #require(teo.branch)
        try await repo.git(["merge", "--no-edit", atlasBranch], in: repo.project)

        let report = await WorkFolders.cleanUp(project: repo.project, run: run, root: repo.work)
        #expect(Set(report.removed) == [atlasBranch, teoBranch])
        #expect(report.kept.map(\.branch) == [liaBranch])
        #expect(!FileManager.default.fileExists(atPath: atlas.url.path) && !FileManager.default.fileExists(atPath: teo.url.path))
        #expect(FileManager.default.fileExists(atPath: lia.url.appending(path: "lia.txt").path))
        #expect(FileManager.default.fileExists(atPath: other.url.path))
        let branches = try await repo.branches()
        #expect(!branches.contains(atlasBranch) && branches.contains(liaBranch))
        #expect(FileManager.default.fileExists(atPath: repo.project.appending(path: "atlas.txt").path))
    }

    @Test func aMergedWorktreeWithUncommittedChangesStays() async throws {
        let repo = try await Repo()
        let run = UUID()
        let atlas = await repo.prepare("Atlas", run: run)
        try "sem commit\n".write(to: atlas.url.appending(path: "rascunho.txt"), atomically: true, encoding: .utf8)
        let report = await WorkFolders.cleanUp(project: repo.project, run: run, root: repo.work)
        let branch = try #require(atlas.branch)
        #expect(report.removed.isEmpty && report.kept.map(\.branch) == [branch])
        #expect(FileManager.default.fileExists(atPath: atlas.url.appending(path: "rascunho.txt").path))
    }

    @Test func cleaningUpAFolderWithoutWorktreesDoesNothing() async throws {
        let repo = try await Repo()
        #expect(await WorkFolders.cleanUp(project: repo.project, run: UUID(), root: repo.work) == WorkFolders.CleanUp())
        let plain = TempFolder("OrbWorkFoldersNoGit", creating: true)
        #expect(await WorkFolders.cleanUp(project: plain.url, run: UUID(), root: plain.appending("t")) == WorkFolders.CleanUp())
    }
}
