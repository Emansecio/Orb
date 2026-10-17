import Foundation
import Testing
@testable import Orb

/// A throwaway folder, removed when the test ends.
private final class Folder {
    let url: URL

    init(_ name: String = "folder") throws {
        url = FileManager.default.temporaryDirectory.appending(path: "OrbSnapshotTests-\(UUID().uuidString)").appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { removeTestFolder(url.deletingLastPathComponent()) }

    @discardableResult
    func write(_ path: String, _ text: String = "x") throws -> URL {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Runs git in the folder with a private config, so nothing of the user's own setup leaks in.
    func git(_ arguments: [String]) async throws {
        let environment = ["PATH": "/usr/bin:/bin", "HOME": url.deletingLastPathComponent().path, "GIT_CONFIG_NOSYSTEM": "1",
                           "GIT_AUTHOR_NAME": "Teste", "GIT_AUTHOR_EMAIL": "t@example.com",
                           "GIT_COMMITTER_NAME": "Teste", "GIT_COMMITTER_EMAIL": "t@example.com"]
        let result = try await ProcessRunner.run("/usr/bin/git", arguments, directory: url, environment: environment, timeout: .seconds(20))
        #expect(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
    }
}

/// A shell environment that answers at once without starting the user's real shell.
private func quickShell() -> ShellEnvironment {
    ShellEnvironment(shell: "/nonexistent/shell", base: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()])
}

private func capture(_ folder: Folder, home: URL? = nil, gitPath: String? = nil, gitTimeout: Duration = .seconds(20),
                     environmentTimeout: Duration? = nil, shell: ShellEnvironment? = nil) async -> WorkspaceSnapshot {
    await WorkspaceSnapshot.capture(folder: folder.url, shell: shell ?? quickShell(), gitPath: gitPath, gitTimeout: gitTimeout,
                                    environmentTimeout: environmentTimeout,
                                    home: home ?? FileManager.default.temporaryDirectory.appending(path: "not-the-home"))
}

struct WorkspaceSnapshotTests {
    @Test func listsTheTopLevelWithFoldersMarked() async throws {
        let folder = try Folder()
        try folder.write("README.md")
        try folder.write("src/main.swift")
        try folder.write(".DS_Store")
        let snapshot = await capture(folder)
        #expect(snapshot.state == .scanned)
        #expect(snapshot.entries == ["README.md", "src/"])
        #expect(snapshot.git == nil)
        #expect(snapshot.text.contains("Top level (2): README.md, src/"))
    }

    @Test func capsTheTopLevelAtFortyEntries() async throws {
        let folder = try Folder()
        for index in 0..<55 { try folder.write(String(format: "file%02d.txt", index)) }
        let snapshot = await capture(folder)
        #expect(snapshot.entries.count == 40)
        #expect(snapshot.extraEntries == 15)
        #expect(snapshot.text.contains("Top level (55)"))
        #expect(snapshot.text.contains("and 15 more"))
    }

    @Test func recentFilesGoTwoLevelsDeepAndSkipBuildFolders() async throws {
        let folder = try Folder()
        try folder.write("top.txt")
        try folder.write("src/inner.swift")
        try folder.write("src/deeper/too-deep.swift")
        try folder.write("node_modules/pkg.js")
        try folder.write(".build/artifact.o")
        try folder.write("DerivedData/cache.bin")
        try folder.write(".hidden-file")
        let paths = await capture(folder).recentFiles.map(\.path)
        #expect(Set(paths) == ["top.txt", "src/inner.swift"])
    }

    @Test func recentFilesAreNewestFirstAndLimited() async throws {
        let folder = try Folder()
        for index in 0..<20 {
            let file = try folder.write("f\(index).txt")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60)],
                                                  ofItemAtPath: file.path)
        }
        let recent = await capture(folder).recentFiles
        #expect(recent.count == 15)
        #expect(recent.first?.path == "f19.txt")
        #expect(recent.last?.path == "f5.txt")
    }

    @Test func readsBranchChangesAndCommitsOfARepository() async throws {
        let folder = try Folder()
        try await folder.git(["init", "-q", "-b", "main"])
        try folder.write("a.txt", "one")
        try await folder.git(["add", "."])
        try await folder.git(["commit", "-q", "-m", "primeiro commit"])
        try folder.write("a.txt", "two")
        try await folder.git(["commit", "-q", "-a", "-m", "segundo commit"])
        try folder.write("a.txt", "three")
        try folder.write("novo.txt")

        let snapshot = await capture(folder)
        let git = try #require(snapshot.git)
        #expect(git.branch == "main")
        #expect(git.changes.contains { $0.hasSuffix("a.txt") && $0.hasPrefix(" M") })
        #expect(git.changes.contains("?? novo.txt"))
        #expect(git.commits.count == 2)
        #expect(git.commits.first?.contains("segundo commit") == true)
        #expect(git.note == nil)
        #expect(snapshot.text.contains("Git: main"))
        #expect(snapshot.text.contains("Uncommitted changes (2)"))
        #expect(snapshot.text.contains("primeiro commit"))
    }

    @Test func aRepositoryWithoutCommitsAndASubfolderOfOne() async throws {
        let folder = try Folder()
        try await folder.git(["init", "-q", "-b", "trunk"])
        let empty = await capture(folder)
        #expect(empty.git?.branch.contains("trunk") == true)
        #expect(empty.git?.commits.isEmpty == true)

        try folder.write("sub/file.txt")
        let inner = await WorkspaceSnapshot.capture(folder: folder.url.appending(path: "sub"), shell: quickShell(), home: FileManager.default.temporaryDirectory.appending(path: "x"))
        #expect(inner.git?.branch.contains("trunk") == true)
    }

    @Test func capsTheStatusAtTwentyLines() async throws {
        let folder = try Folder()
        try await folder.git(["init", "-q", "-b", "main"])
        for index in 0..<30 { try folder.write(String(format: "u%02d.txt", index)) }
        let git = try #require(await capture(folder).git)
        #expect(git.changes.count == 20)
        #expect(git.extraChanges == 10)
    }

    @Test func theHomeFolderIsNotScanned() async throws {
        let folder = try Folder("home")
        try folder.write("Documents/secret.txt")
        try await folder.git(["init", "-q"])
        let snapshot = await capture(folder, home: folder.url)
        #expect(snapshot.state == .home)
        #expect(snapshot.entries.isEmpty && snapshot.recentFiles.isEmpty && snapshot.git == nil)
        #expect(snapshot.text.contains("not scanned"))
        #expect(!snapshot.text.contains("secret.txt"))
    }

    @Test func aMissingFolderIsSaidSo() async throws {
        let folder = try Folder()
        let gone = folder.url.appending(path: "nao-existe")
        let snapshot = await WorkspaceSnapshot.capture(folder: gone, shell: quickShell())
        #expect(snapshot.state == .missing)
        #expect(snapshot.text.contains("pasta não encontrada"))
        // A file is not a folder either.
        let file = try folder.write("arquivo.txt")
        #expect(await WorkspaceSnapshot.capture(folder: file, shell: quickShell()).state == .missing)
    }

    @Test func anUnreadableFolderIsSaidSo() async throws {
        let folder = try Folder()
        try folder.write("a.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.url.path) }
        let snapshot = await capture(folder)
        #expect(snapshot.state == .unreadable)
        #expect(snapshot.text.contains("could not be read"))
    }

    @Test func gitIsNotStartedOutsideARepository() async throws {
        let folder = try Folder()
        let marker = folder.url.deletingLastPathComponent().appending(path: "git-ran")
        let script = folder.url.deletingLastPathComponent().appending(path: "fake-git")
        try writeExecutable("#!/bin/sh\ntouch '\(marker.path)'\n", to: script)
        try folder.write("a.txt")
        let snapshot = await capture(folder, gitPath: script.path)
        #expect(snapshot.git == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func aHungGitDoesNotHoldTheSnapshotBack() async throws {
        let folder = try Folder()
        try await folder.git(["init", "-q"])
        try folder.write("a.txt")
        let script = folder.url.deletingLastPathComponent().appending(path: "slow-git")
        try writeExecutable("#!/bin/sh\nsleep 30\n", to: script)

        let start = ContinuousClock.now
        let snapshot = await capture(folder, gitPath: script.path, gitTimeout: .milliseconds(300))
        #expect(ContinuousClock.now - start < .seconds(25)) // the timeout, not the thirty seconds of the script
        #expect(snapshot.git?.note?.contains("did not answer in time") == true)
        // The rest of the snapshot is still there.
        #expect(snapshot.entries.contains("a.txt"))
        #expect(snapshot.text.contains("git did not answer in time"))
    }

    @Test func aSlowUserShellDoesNotHoldTheSnapshotBack() async throws {
        let folder = try Folder()
        try await folder.git(["init", "-q", "-b", "main"])
        try folder.write("a.txt")
        let slow = try FakeShell.make(in: folder.url.deletingLastPathComponent(), preamble: "sleep 20")
        let shell = ShellEnvironment(shell: slow, base: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], timeout: .seconds(60))

        // The wait for the shell is short, while git itself gets time to answer however busy the machine is.
        let start = ContinuousClock.now
        let snapshot = await capture(folder, environmentTimeout: .milliseconds(300), shell: shell)
        #expect(ContinuousClock.now - start < .seconds(15)) // not the twenty seconds the shell takes
        #expect(snapshot.git?.note == nil)
        #expect(snapshot.git?.branch.contains("main") == true)
    }

    @Test func theHashFollowsTheContent() async throws {
        let folder = try Folder()
        try folder.write("a.txt")
        let first = await capture(folder)
        #expect(await capture(folder).hash == first.hash)
        try folder.write("b.txt")
        #expect(await capture(folder).hash != first.hash)
    }

    @Test func namesWithNewlinesStayOnOneLine() async throws {
        let folder = try Folder()
        try folder.write("odd\nname.txt")
        let snapshot = await capture(folder)
        #expect(snapshot.entries == ["odd⏎name.txt"])
    }
}

// MARK: - Cache

struct WorkspaceSnapshotCacheTests {
    private actor Counter {
        var count = 0
        func next() -> Int { count += 1; return count }
    }

    private func cache(lifetime: TimeInterval = 60, counter: Counter) -> WorkspaceSnapshots {
        WorkspaceSnapshots(lifetime: lifetime) { folder in
            let number = await counter.next()
            try? await Task.sleep(for: .milliseconds(50))
            return WorkspaceSnapshot(path: "\(folder.path)#\(number)")
        }
    }

    @Test func reusesTheSnapshotForAMinute() async {
        let counter = Counter()
        let cache = cache(counter: counter)
        let bot = UUID(), folder = URL(fileURLWithPath: "/tmp/a")
        let start = Date(timeIntervalSince1970: 1_000_000)
        let first = await cache.snapshot(for: bot, folder: folder, now: start)
        let soon = await cache.snapshot(for: bot, folder: folder, now: start.addingTimeInterval(59))
        #expect(first == soon)
        #expect(await counter.count == 1)
        let later = await cache.snapshot(for: bot, folder: folder, now: start.addingTimeInterval(61))
        #expect(later != first)
        #expect(await counter.count == 2)
    }

    @Test func eachOrbAndEachFolderHasItsOwn() async {
        let counter = Counter()
        let cache = cache(counter: counter)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let one = UUID(), two = UUID()
        _ = await cache.snapshot(for: one, folder: URL(fileURLWithPath: "/tmp/a"), now: now)
        _ = await cache.snapshot(for: two, folder: URL(fileURLWithPath: "/tmp/a"), now: now)
        _ = await cache.snapshot(for: one, folder: URL(fileURLWithPath: "/tmp/b"), now: now)
        #expect(await counter.count == 3)
    }

    @Test func concurrentRequestsShareOneScan() async {
        let counter = Counter()
        let cache = cache(counter: counter)
        let bot = UUID(), folder = URL(fileURLWithPath: "/tmp/a")
        async let first = cache.snapshot(for: bot, folder: folder)
        async let second = cache.snapshot(for: bot, folder: folder)
        let (a, b) = await (first, second)
        #expect(a == b)
        #expect(await counter.count == 1)
    }

    @Test func invalidatingForcesANewScan() async {
        let counter = Counter()
        let cache = cache(counter: counter)
        let bot = UUID(), folder = URL(fileURLWithPath: "/tmp/a")
        _ = await cache.snapshot(for: bot, folder: folder)
        await cache.invalidate(bot)
        _ = await cache.snapshot(for: bot, folder: folder)
        #expect(await counter.count == 2)
    }

    @Test func aScanInFlightWhenInvalidatedIsNotKept() async {
        let counter = Counter()
        let cache = cache(counter: counter)
        let bot = UUID(), folder = URL(fileURLWithPath: "/tmp/a")
        let running = Task { await cache.snapshot(for: bot, folder: folder) }
        while await counter.count == 0 { await Task.yield() } // the scan has begun, and has not ended
        await cache.invalidate(bot)
        _ = await running.value
        _ = await cache.snapshot(for: bot, folder: folder)
        #expect(await counter.count == 2)
    }
}
