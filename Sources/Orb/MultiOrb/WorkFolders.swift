import Foundation

/// The folder an Orb works in for one turn of a shared project: the project itself, or, in a git repository, a worktree of its
/// own on a branch of its own, so that two Orbs never write over each other's files.
struct WorkFolder: Sendable, Equatable {
    var url: URL
    /// The branch checked out in `url`; nil when `url` is the project folder.
    var branch: String?
    /// Why a worktree was wanted and not made (git is missing or refused); the Orb is told it works in the shared folder.
    var problem: String?
}

/// Worktrees for the members of a group (or the Orb that was asked for work on a `folder`), kept under the app's data folder
/// (`trabalho/<project>-<hash>/<member>-<run>`) so nothing lands in the user's repository but a branch and a registered worktree.
/// The orchestrator works in the project folder and merges the branches; `cleanUp` removes what was merged when the run ends.
enum WorkFolders {
    static let timeout = Duration.seconds(30)
    /// A branch of ours: `orb/<member>/<run>`.
    static let branchPrefix = "orb/"

    /// Where the worktrees of the app live.
    static func root(in dataFolder: URL) -> URL { dataFolder.appending(path: "trabalho", directoryHint: .isDirectory) }

    // MARK: Making

    /// The folder `member` works in for `run`. A git repository gives it a worktree of its own (the same one again for the same
    /// member and run); anything else, or a git that fails, gives the project folder itself. `root`: `root(in:)`.
    static func prepare(project: URL, member: String, run: UUID, root: URL, gitPath: String? = nil) async -> WorkFolder {
        let project = project.standardizedFileURL
        guard WorkspaceSnapshot.hasRepository(project) else { return WorkFolder(url: project) }
        guard let git = Git.make(path: gitPath) else {
            return WorkFolder(url: project, problem: "git is not available")
        }
        return await GitQueue.shared.run { await make(project: project, member: member, run: run, root: root, git: git) }
    }

    private static func make(project: URL, member: String, run: UUID, root: URL, git: Git) async -> WorkFolder {
        let shared = { (problem: String) in WorkFolder(url: project, problem: problem) }
        guard let top = await git.run(["rev-parse", "--show-toplevel"], in: project).output else {
            return shared("git could not read the repository")
        }
        let topURL = URL(fileURLWithPath: top)
        let relative = relativePath(of: project, in: topURL)
        let short = shortID(run)
        let memberSlug = slug(member)
        let branch = "\(branchPrefix)\(memberSlug)/\(short)"
        let parent = root.appending(path: "\(slug(project.lastPathComponent))-\(hash(project.path))", directoryHint: .isDirectory)
        let folder = parent.appending(path: "\(memberSlug)-\(short)", directoryHint: .isDirectory)
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) } catch {
            return shared("the work folder could not be created")
        }
        let wanted = canonical(folder)
        let listed = await worktrees(in: project, git: git)
        if listed.contains(where: { canonical(URL(fileURLWithPath: $0.path)) == wanted }) {
            return WorkFolder(url: inside(folder, relative), branch: branch)
        }
        // The branch survives a pruned worktree: reuse it (its commits are the member's work) instead of failing on the name.
        let known = await git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: project).output != nil
        let arguments = known ? ["worktree", "add", folder.path, branch] : ["worktree", "add", folder.path, "-b", branch, "HEAD"]
        let added = await git.run(arguments, in: project)
        guard added.succeeded else { return shared(Self.firstLine(added.text)) }
        return WorkFolder(url: inside(folder, relative), branch: branch)
    }

    // MARK: Telling the Orb

    /// Added to a member's turn: where it works. English and short, it goes on every turn of the run.
    static func memberNote(_ folder: WorkFolder, asked: Bool = false) -> String {
        if let branch = folder.branch {
            return "Work in \(folder.url.path) (branch \(branch)). Commit your work there before you answer."
                + (asked ? " Name the branch in your answer." : "")
        }
        if let problem = folder.problem {
            return "No separate worktree (\(problem)). " + sharedNote(folder.url)
        }
        return sharedNote(folder.url)
    }

    static func sharedNote(_ project: URL) -> String {
        "Shared folder \(project.path): others edit it too; re-read a file before changing it."
    }

    /// Added to the orchestrator's turn: it works in the project folder and merges what the members commit.
    static func orchestratorNote(project: URL, run: UUID, root: URL, gitPath: String? = nil) async -> String {
        let project = project.standardizedFileURL
        guard WorkspaceSnapshot.hasRepository(project), let git = Git.make(path: gitPath) else { return sharedNote(project) }
        let branches = await runBranches(project: project, run: run, root: root, git: git).map(\.branch)
        let listed = branches.isEmpty ? "branches \(branchPrefix)<member>/\(shortID(run)) once they work"
            : "branches " + branches.joined(separator: ", ")
        return "Work in \(project.path) (main checkout). Members work in their own worktrees, \(listed). "
            + "Merge each approved branch into \(project.path) with git merge; resolve conflicts."
    }

    // MARK: Cleaning up

    struct CleanUp: Sendable, Equatable {
        struct Kept: Sendable, Equatable {
            var branch: String
            var path: String
        }
        /// Branches whose worktree was removed because their work is in the project's HEAD.
        var removed: [String] = []
        /// Worktrees left alone: their branch has commits the project does not, or the worktree has changes not committed.
        var kept: [Kept] = []
    }

    /// When a run ends: removes the worktrees of `run` whose branch is already in the project's HEAD (and the branch), leaves the
    /// others and says which. Never forces: a worktree with uncommitted changes stays.
    static func cleanUp(project: URL, run: UUID, root: URL, gitPath: String? = nil) async -> CleanUp {
        let project = project.standardizedFileURL
        guard WorkspaceSnapshot.hasRepository(project), let git = Git.make(path: gitPath) else { return CleanUp() }
        return await GitQueue.shared.run {
            let ours = await runBranches(project: project, run: run, root: root, git: git)
            guard !ours.isEmpty else { return CleanUp() }
            let merged = Set((await git.run(["branch", "--merged", "HEAD", "--format=%(refname:short)"], in: project).output ?? "")
                .split(separator: "\n").map(String.init))
            var report = CleanUp()
            for entry in ours {
                if merged.contains(entry.branch), await git.run(["worktree", "remove", entry.path], in: project).succeeded {
                    _ = await git.run(["branch", "-d", entry.branch], in: project)
                    report.removed.append(entry.branch)
                } else {
                    report.kept.append(CleanUp.Kept(branch: entry.branch, path: entry.path))
                }
            }
            _ = await git.run(["worktree", "prune"], in: project)
            removeIfEmpty(root.appending(path: "\(slug(project.lastPathComponent))-\(hash(project.path))"))
            return report
        }
    }

    // MARK: Git

    struct Worktree: Sendable, Equatable {
        var path: String
        /// Short name (`orb/atlas/1a2b3c4d`); nil when detached.
        var branch: String?
    }

    /// `git worktree list --porcelain`: blocks of `worktree <path>`, `HEAD <sha>`, `branch refs/heads/<name>`.
    static func parseWorktrees(_ text: String) -> [Worktree] {
        var result: [Worktree] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("worktree ") {
                result.append(Worktree(path: String(line.dropFirst("worktree ".count))))
            } else if line.hasPrefix("branch refs/heads/"), !result.isEmpty {
                result[result.count - 1].branch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        return result
    }

    private static func worktrees(in project: URL, git: Git) async -> [Worktree] {
        parseWorktrees(await git.run(["worktree", "list", "--porcelain"], in: project).output ?? "")
    }

    /// The worktrees this app made for `run`: under `root`, on a branch `orb/<member>/<run>`.
    private static func runBranches(project: URL, run: UUID, root: URL, git: Git) async -> [(branch: String, path: String)] {
        let suffix = "/" + shortID(run)
        let base = canonical(root).path + "/"
        return await worktrees(in: project, git: git).compactMap { entry in
            guard let branch = entry.branch, branch.hasPrefix(branchPrefix), branch.hasSuffix(suffix),
                  canonical(URL(fileURLWithPath: entry.path)).path.hasPrefix(base) else { return nil }
            return (branch, entry.path)
        }
    }

    /// git with the user's usual environment, minus anything that would wait for a prompt or an editor.
    struct Git: Sendable {
        var executable: String
        var environment: [String: String]

        /// Nil when git is not there, or is only the system's stub (running it opens an installer dialog).
        static func make(path: String? = nil) -> Git? {
            var environment = ShellEnvironment.prepared(ProcessInfo.processInfo.environment)
            environment["GIT_OPTIONAL_LOCKS"] = "0"
            let executable = path ?? WorkspaceSnapshot.findGit(in: environment)
            if path == nil, executable == WorkspaceSnapshot.systemGit, !WorkspaceSnapshot.developerToolsAreInstalled() { return nil }
            return Git(executable: executable, environment: environment)
        }

        struct Result: Sendable {
            var succeeded: Bool
            var text: String
            /// The trimmed text when the command succeeded and printed something.
            var output: String? {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return succeeded && !trimmed.isEmpty ? trimmed : nil
            }
        }

        func run(_ arguments: [String], in folder: URL) async -> Result {
            guard let done = try? await ProcessRunner.run(executable, arguments, directory: folder, environment: environment,
                                                          timeout: WorkFolders.timeout, outputLimit: 50_000) else {
                return Result(succeeded: false, text: "git did not start")
            }
            return Result(succeeded: done.status == 0 && !done.timedOut && done.signal == nil,
                          text: done.timedOut ? "git did not answer in time" : done.output)
        }
    }

    /// One git command at a time across the app: several members starting together would race for the repository's locks.
    private actor GitQueue {
        static let shared = GitQueue()
        private var tail: Task<Void, Never>?

        func run<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
            let previous = tail
            let task = Task { () -> T in
                await previous?.value
                return await work()
            }
            tail = Task { _ = await task.value }
            return await task.value
        }
    }

    // MARK: Names and paths

    static func shortID(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }

    /// Letters and digits only, lower case, accents folded: safe in a branch name and in a path.
    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX")).lowercased()
        var result = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("-") {
                result += "-"
            }
        }
        let trimmed = String(result.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(24))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "orb" : trimmed
    }

    /// FNV-1a of the project's path, 8 hex digits: two projects with the same folder name get different folders.
    static func hash(_ path: String) -> String {
        var value: UInt32 = 2_166_136_261
        for byte in path.utf8 { value = (value ^ UInt32(byte)) &* 16_777_619 }
        return String(format: "%08x", value)
    }

    /// The path with symbolic links resolved in its parent (git prints real paths; the folder may not exist yet).
    private static func canonical(_ url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: url.lastPathComponent)
    }

    /// `project` relative to the repository's top folder ("" when it is the top).
    private static func relativePath(of project: URL, in top: URL) -> String {
        let base = top.resolvingSymlinksInPath().path, path = project.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else { return "" }
        return String(path.dropFirst(base.count + 1))
    }

    private static func inside(_ worktree: URL, _ relative: String) -> URL {
        relative.isEmpty ? worktree : worktree.appending(path: relative, directoryHint: .isDirectory)
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? "git failed"
        return String(line.prefix(160))
    }

    private static func removeIfEmpty(_ folder: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["."]
        if contents.isEmpty { try? FileManager.default.removeItem(at: folder) }
    }
}
