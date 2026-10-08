import Foundation
import Testing
@testable import Orb

/// A throwaway tree that stands for the Mac: a home folder and the base where Orbs get their folders (`~/Orbs`).
/// The real home and the real `~/Orbs` are never touched.
final class OrbFolderSandbox: Sendable {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbFolderTests-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    var base: URL { home.appending(path: "Orbs") }

    init() throws { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func makeFolder(_ path: String) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func write(_ file: URL, modified: Date? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: file, atomically: true, encoding: .utf8)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
        return file
    }
}

// MARK: - Folder names

struct OrbFolderNameTests {
    @Test func replacesTheCharactersAFolderNameCannotHold() {
        #expect(OrbFolder.folderName(for: "Contas/2026") == "Contas-2026")
        #expect(OrbFolder.folderName(for: "Casa: reforma") == "Casa- reforma")
        #expect(OrbFolder.folderName(for: "a\\b") == "a-b")
        #expect(!OrbFolder.folderName(for: "////").contains("/"))
    }

    @Test func leadingDotsWouldHideTheFolder() {
        #expect(OrbFolder.folderName(for: ".segredo") == "segredo")
        #expect(OrbFolder.folderName(for: "..  ..Atlas") == "Atlas")
        #expect(OrbFolder.folderName(for: "Atlas.v2") == "Atlas.v2")
        #expect(OrbFolder.folderName(for: "..") == "Orb")
        #expect(OrbFolder.folderName(for: ".") == "Orb")
    }

    @Test func emojiAccentsAndSpacesStay() {
        #expect(OrbFolder.folderName(for: "🤖 Assistente") == "🤖 Assistente")
        #expect(OrbFolder.folderName(for: "Conceição  da   Silva") == "Conceição da Silva")
        #expect(OrbFolder.folderName(for: "  Atlas \n") == "Atlas")
    }

    @Test func emptyAndControlOnlyNamesGetAFallback() {
        #expect(OrbFolder.folderName(for: "") == "Orb")
        #expect(OrbFolder.folderName(for: "   ") == "Orb")
        #expect(OrbFolder.folderName(for: "\u{0}\u{7}\t") == "Orb")
        #expect(OrbFolder.folderName(for: "a\u{0}b") == "a b")
    }

    @Test func aLongNameStaysWithinTheFileSystemLimit() {
        let long = String(repeating: "🤖", count: 100)
        let name = OrbFolder.folderName(for: long)
        #expect(name.utf8.count <= 200)
        #expect(!name.isEmpty)
        #expect(name.allSatisfy { $0 == "🤖" }) // cut on a character, not in the middle of one
    }
}

// MARK: - Creating

struct OrbFolderCreationTests {
    @Test func createsTheBaseAndTheFolderInIt() throws {
        let sandbox = try OrbFolderSandbox()
        #expect(!FileManager.default.fileExists(atPath: sandbox.base.path))
        let folder = try OrbFolder.create(for: "Atlas", in: sandbox.base)
        #expect(folder.lastPathComponent == "Atlas")
        #expect(folder.deletingLastPathComponent().standardizedFileURL.path == sandbox.base.standardizedFileURL.path)
        #expect(folder.isExistingDirectory)
    }

    @Test func aTakenNameGetsANumber() throws {
        let sandbox = try OrbFolderSandbox()
        let first = try OrbFolder.create(for: "Atlas", in: sandbox.base)
        let second = try OrbFolder.create(for: "Atlas", in: sandbox.base)
        let third = try OrbFolder.create(for: "Atlas", in: sandbox.base)
        #expect([first, second, third].map(\.lastPathComponent) == ["Atlas", "Atlas 2", "Atlas 3"])
        // The one created first keeps its content.
        try sandbox.write(first.appending(path: "nota.txt"))
        let fourth = try OrbFolder.create(for: "Atlas", in: sandbox.base)
        #expect(fourth.lastPathComponent == "Atlas 4")
        #expect(FileManager.default.fileExists(atPath: first.appending(path: "nota.txt").path))
    }

    @Test func aFileWithTheNameCountsAsTaken() throws {
        let sandbox = try OrbFolderSandbox()
        try sandbox.write(sandbox.base.appending(path: "Atlas"))
        #expect(OrbFolder.availableURL(for: "Atlas", in: sandbox.base).lastPathComponent == "Atlas 2")
        #expect(try OrbFolder.create(for: "Atlas", in: sandbox.base).lastPathComponent == "Atlas 2")
    }

    @Test func previewingCreatesNothing() throws {
        let sandbox = try OrbFolderSandbox()
        let preview = OrbFolder.availableURL(for: "Atlas", in: sandbox.base)
        #expect(preview.lastPathComponent == "Atlas")
        #expect(!FileManager.default.fileExists(atPath: sandbox.base.path))
    }

    @Test func sanitizedNamesCreateOneFolderDirectlyInTheBase() throws {
        let sandbox = try OrbFolderSandbox()
        let folder = try OrbFolder.create(for: "../Fuga/ : x", in: sandbox.base)
        #expect(folder.deletingLastPathComponent().standardizedFileURL.path == sandbox.base.standardizedFileURL.path)
    }

    @Test func aBaseThatIsAFileFailsWithAMessage() throws {
        let sandbox = try OrbFolderSandbox()
        try sandbox.write(sandbox.base)
        #expect(throws: OrbFolderError.self) { try OrbFolder.create(for: "Atlas", in: sandbox.base) }
        do {
            _ = try OrbFolder.create(for: "Atlas", in: sandbox.base)
        } catch {
            #expect(error.localizedDescription.hasPrefix("Não consegui criar a pasta"))
        }
    }

    @Test func displayWritesTheHomeAsTilde() {
        #expect(OrbFolder.display(URL(fileURLWithPath: "/Users/ana/Orbs/Atlas"), home: "/Users/ana") == "~/Orbs/Atlas")
        #expect(OrbFolder.display(URL(fileURLWithPath: "/Users/ana"), home: "/Users/ana") == "~")
        #expect(OrbFolder.display(URL(fileURLWithPath: "/Users/anabela/x"), home: "/Users/ana") == "/Users/anabela/x")
    }
}

// MARK: - State and permissions

struct OrbFolderStateTests {
    @Test func missingHomeAndOwnFolderAreTold() throws {
        let sandbox = try OrbFolderSandbox()
        let own = try OrbFolder.create(for: "Atlas", in: sandbox.base)
        #expect(OrbFolder.state(of: own, home: sandbox.home) == .ownFolder)
        #expect(OrbFolder.state(of: sandbox.home, home: sandbox.home) == .noOwnFolder)
        #expect(OrbFolder.state(of: sandbox.root, home: sandbox.home) == .noOwnFolder) // contains the home folder
        #expect(OrbFolder.state(of: sandbox.root.appending(path: "gone"), home: sandbox.home) == .missing)
        try FileManager.default.removeItem(at: own)
        #expect(OrbFolder.state(of: own, home: sandbox.home) == .missing)
    }

    @Test func aFileInPlaceOfTheFolderIsMissing() throws {
        let sandbox = try OrbFolderSandbox()
        let file = try sandbox.write(sandbox.root.appending(path: "arquivo"))
        #expect(OrbFolder.state(of: file, home: sandbox.home) == .missing)
    }

    @Test func aCreatedFolderIsTheOrbsOwnFolderForThePolicy() throws {
        let sandbox = try OrbFolderSandbox()
        let folder = try OrbFolder.create(for: "Atlas", in: sandbox.base)
        let own = PermissionPolicy.ownFolder(folder, home: sandbox.home)
        #expect(own != nil)
        #expect(own?.lastPathComponent == "Atlas")
        // Through the stored string, as the Orb reads it.
        var bot = Bot(name: "Atlas", role: "", orb: OrbConfig())
        bot.workingDirectory = OrbFolder.storedPath(folder)
        #expect(PermissionPolicy.ownFolder(bot.workingURL, home: sandbox.home) != nil)

        // So a write inside needs no card in "Perguntar antes", and one outside still does.
        let context = ToolContext(workingDirectory: bot.workingURL)
        func verdict(_ path: String) -> PermissionVerdict {
            let call = PermissionPolicy.call(for: WriteFileTool(), arguments: .object(["path": .string(path), "content": .string("x")]),
                                             context: context, home: sandbox.home)
            return PermissionPolicy.evaluate(mode: .ask, call: call, rules: [], workspace: bot.workingURL, home: sandbox.home)
        }
        #expect(verdict("notas.md") == .allow)
        #expect(verdict(sandbox.home.appending(path: "fora.md").path) == .ask(.needsPermission))
    }
}

// MARK: - The app model

@Suite final class OrbFolderModelTests {
    let sandbox: OrbFolderSandbox

    init() throws { sandbox = try OrbFolderSandbox() }

    @MainActor private func makeModel() -> AppModel {
        AppModel(store: Store(directory: sandbox.root.appending(path: "data")), runsBackgroundWork: false)
    }

    @MainActor private func create(_ model: AppModel, _ name: String = "Atlas", folder: OrbFolderChoice = .own) -> Bot {
        model.createBot(name: name, role: "Teste", orb: OrbConfig(), model: "", mode: .ask, identity: "", interview: false,
                        folder: folder, base: sandbox.base)
    }

    @Test @MainActor func aNewOrbGetsItsOwnFolder() {
        let model = makeModel()
        let bot = create(model)
        #expect(bot.workingDirectory == OrbFolder.storedPath(sandbox.base.appending(path: "Atlas")))
        #expect(model.bot(bot.id)?.workingURL.isExistingDirectory == true)
        #expect(model.bot(bot.id)?.workingURL.deletingLastPathComponent().lastPathComponent == "Orbs")
        // Not the home folder: the policy sees a folder of its own.
        #expect(PermissionPolicy.ownFolder(bot.workingURL, home: sandbox.home) != nil)
    }

    @Test @MainActor func twoOrbsWithTheSameNameGetDifferentFolders() {
        let model = makeModel()
        let first = create(model), second = create(model)
        #expect(first.workingDirectory != second.workingDirectory)
        #expect(URL(fileURLWithPath: second.workingDirectory).lastPathComponent == "Atlas 2")
    }

    @Test @MainActor func theHomeChoiceKeepsTheOldBehavior() {
        let model = makeModel()
        let bot = create(model, folder: .home)
        #expect(bot.workingDirectory.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.base.path))
    }

    @Test @MainActor func aChosenFolderIsUsedAsItIs() throws {
        let model = makeModel()
        let projeto = try sandbox.makeFolder("projetos/site")
        let bot = create(model, folder: .existing(projeto))
        #expect(bot.workingURL.standardizedFileURL.path == projeto.standardizedFileURL.path)
        #expect(!FileManager.default.fileExists(atPath: sandbox.base.path))
    }

    @Test @MainActor func whenTheFolderCannotBeMadeTheOrbStillExistsAndSaysSo() throws {
        let model = makeModel()
        try sandbox.write(sandbox.base) // ~/Orbs is a file
        let bot = create(model)
        #expect(bot.workingDirectory.isEmpty)
        #expect(model.bot(bot.id) != nil)
        let notices = model.transcript(bot.id).compactMap { item -> String? in
            if case .notice(let text) = item.kind { text } else { nil }
        }
        #expect(notices.count == 1)
        #expect(notices.first?.contains("pasta pessoal") == true)
        #expect(notices.first?.contains("..") == false) // the Cocoa message already ends with a period
    }

    @Test @MainActor func aLongNameIsClippedLikeARename() {
        let model = makeModel()
        let bot = create(model, String(repeating: "A", count: 200), folder: .home)
        #expect(bot.name.count == AppModel.nameLimit)
    }

    @Test @MainActor func anOrbOnTheHomeFolderCanGetItsOwn() throws {
        let model = makeModel()
        let bot = create(model, "Casa", folder: .home)
        try model.createOwnFolder(for: bot.id, base: sandbox.base)
        let updated = try #require(model.bot(bot.id))
        #expect(updated.workingURL.lastPathComponent == "Casa")
        #expect(updated.workingURL.isExistingDirectory)
        #expect(OrbFolder.state(of: updated.workingURL, home: sandbox.home) == .ownFolder)
    }

    @Test @MainActor func goingBackToTheHomeFolderLeavesTheOwnOneAlone() throws {
        let model = makeModel()
        let bot = create(model)
        let folder = bot.workingURL
        try sandbox.write(folder.appending(path: "nota.txt"))
        model.useHomeFolder(of: bot.id)
        #expect(model.bot(bot.id)?.workingDirectory == "")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "nota.txt").path))
    }

    @Test @MainActor func aMissingFolderCanBeMadeAgain() throws {
        let model = makeModel()
        let bot = create(model)
        try FileManager.default.removeItem(at: bot.workingURL)
        #expect(OrbFolder.state(of: bot.workingURL, home: sandbox.home) == .missing)
        try model.recreateFolder(of: bot.id)
        #expect(OrbFolder.state(of: bot.workingURL, home: sandbox.home) == .ownFolder)
        // Nothing to make for an Orb on the home folder.
        let home = create(model, "Casa", folder: .home)
        try model.recreateFolder(of: home.id)
        #expect(model.bot(home.id)?.workingDirectory == "")
    }

    @Test @MainActor func renamingKeepsTheFolderAndRefusesAnEmptyName() throws {
        let model = makeModel()
        let bot = create(model)
        #expect(model.rename(bot.id, to: "  Júpiter \n"))
        #expect(model.bot(bot.id)?.name == "Júpiter")
        #expect(model.bot(bot.id)?.workingDirectory == bot.workingDirectory)
        #expect(!model.rename(bot.id, to: "   "))
        #expect(!model.rename(bot.id, to: ""))
        #expect(model.bot(bot.id)?.name == "Júpiter")
        #expect(!model.rename(UUID(), to: "Outro"))
        #expect(model.bot(bot.id)?.workingURL.isExistingDirectory == true)
    }

    @Test @MainActor func aVeryLongNameIsCut() {
        let model = makeModel()
        let bot = create(model)
        #expect(model.rename(bot.id, to: String(repeating: "a", count: 500)))
        #expect(model.bot(bot.id)?.name.count == AppModel.nameLimit)
    }

    @Test @MainActor func theRoleIsTrimmedAndMayBeEmpty() {
        let model = makeModel()
        let bot = create(model)
        model.setRole(bot.id, to: "  Cuida da agenda \n")
        #expect(model.bot(bot.id)?.role == "Cuida da agenda")
        model.setRole(bot.id, to: "  ")
        #expect(model.bot(bot.id)?.role == "")
    }

    @Test @MainActor func theFolderSurvivesRestart() throws {
        let model = makeModel()
        let bot = create(model)
        model.saveNow()
        let next = AppModel(store: Store(directory: sandbox.root.appending(path: "data")), runsBackgroundWork: false)
        #expect(next.bot(bot.id)?.workingDirectory == bot.workingDirectory)
    }
}

// MARK: - Files

struct WorkspaceFilesTests {
    private func snapshot(_ folder: URL, changes: [String] = [], recent: [(String, Date)] = [],
                          state: WorkspaceSnapshot.State = .scanned) -> WorkspaceSnapshot {
        var snapshot = WorkspaceSnapshot(path: folder.path, state: state)
        snapshot.git = changes.isEmpty ? nil : WorkspaceSnapshot.Git(branch: "main", changes: changes)
        snapshot.recentFiles = recent.map { WorkspaceSnapshot.RecentFile(path: $0.0, modified: $0.1) }
        return snapshot
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func changedFilesComeFirstThenRecentOnes() throws {
        let sandbox = try OrbFolderSandbox()
        let folder = try sandbox.makeFolder("home/Orbs/Atlas")
        try sandbox.makeFolder("home/Orbs/Atlas/.git")
        try sandbox.write(folder.appending(path: "velho.txt"), modified: now.addingTimeInterval(-9000))
        try sandbox.write(folder.appending(path: "novo.txt"), modified: now.addingTimeInterval(-100))
        try sandbox.write(folder.appending(path: "meio.txt"), modified: now.addingTimeInterval(-500))
        try sandbox.write(folder.appending(path: "recente.txt"), modified: now.addingTimeInterval(-10))
        try sandbox.write(folder.appending(path: "docs/guia.md"), modified: now.addingTimeInterval(-60))

        let list = WorkspaceFiles.list(from: snapshot(
            folder,
            changes: [" M velho.txt", "?? novo.txt", " D apagado.txt", "A  meio.txt"],
            recent: [("recente.txt", now.addingTimeInterval(-10)), ("docs/guia.md", now.addingTimeInterval(-60)),
                     ("novo.txt", now.addingTimeInterval(-100))]), folder: folder)

        // Changed ones newest first, the deleted one last; then the recent ones that are not among them.
        #expect(list.map(\.path) == ["novo.txt", "meio.txt", "velho.txt", "apagado.txt", "recente.txt", "docs/guia.md"])
        #expect(list.map(\.marker) == [.untracked, .added, .modified, .deleted, nil, nil])
        #expect(list[0].url.standardizedFileURL.path == folder.appending(path: "novo.txt").standardizedFileURL.path)
        #expect(list[4].modified == now.addingTimeInterval(-10))
    }

    @Test func theListHasAtMostEightFiles() throws {
        let sandbox = try OrbFolderSandbox()
        let folder = try sandbox.makeFolder("pasta")
        let recent = (0..<15).map { ("r\($0).txt", now.addingTimeInterval(Double(-$0))) }
        #expect(WorkspaceFiles.list(from: snapshot(folder, recent: recent), folder: folder).count == 8)
        // Many changes crowd the recent ones out.
        try sandbox.makeFolder("pasta/.git")
        let changes = (0..<12).map { "?? c\($0).txt" }
        let list = WorkspaceFiles.list(from: snapshot(folder, changes: changes, recent: recent), folder: folder)
        #expect(list.count == 8)
        #expect(list.allSatisfy { $0.marker == .untracked })
    }

    @Test func nothingIsListedForTheHomeAMissingOrAnUnreadableFolder() throws {
        let sandbox = try OrbFolderSandbox()
        let recent = [("a.txt", now)]
        for state in [WorkspaceSnapshot.State.home, .missing, .unreadable] {
            #expect(WorkspaceFiles.list(from: snapshot(sandbox.home, recent: recent, state: state), folder: sandbox.home).isEmpty)
        }
    }

    @Test func changesOutsideTheOrbsFolderAreLeftOut() throws {
        // The Orb's folder sits inside a repository: git reports the whole repository, with paths from its root.
        let sandbox = try OrbFolderSandbox()
        let repository = try sandbox.makeFolder("repo")
        try sandbox.makeFolder("repo/.git")
        let folder = try sandbox.makeFolder("repo/orbs/atlas")
        try sandbox.write(folder.appending(path: "dentro.txt"), modified: now)
        try sandbox.write(repository.appending(path: "fora.txt"), modified: now)
        let list = WorkspaceFiles.list(from: snapshot(folder, changes: ["?? orbs/atlas/dentro.txt", " M fora.txt", "?? orbs/atlas2/x.txt"]),
                                       folder: folder)
        #expect(list.map(\.path) == ["dentro.txt"])
    }

    @Test func aRepositoryFolderThatIsTheOrbsFolderItselfIsNotListed() throws {
        let sandbox = try OrbFolderSandbox()
        let folder = try sandbox.makeFolder("repo")
        try sandbox.makeFolder("repo/.git")
        #expect(WorkspaceFiles.list(from: snapshot(folder, changes: ["?? ./"]), folder: folder).isEmpty)
    }

    @Test func parsesStatusLines() {
        #expect(WorkspaceFiles.parseStatusLine(" M src/a.swift")?.path == "src/a.swift")
        #expect(WorkspaceFiles.parseStatusLine(" M src/a.swift")?.code == " M")
        #expect(WorkspaceFiles.parseStatusLine("R  old.txt -> new.txt")?.path == "new.txt")
        #expect(WorkspaceFiles.parseStatusLine("?? build/")?.path == "build/")
        #expect(WorkspaceFiles.parseStatusLine("?? \"com espaço \\\"x\\\".txt\"")?.path == "com espaço \"x\".txt")
        #expect(WorkspaceFiles.parseStatusLine("?? \"caf\\303\\251.txt\"")?.path == "café.txt")
        #expect(WorkspaceFiles.parseStatusLine("") == nil)
        #expect(WorkspaceFiles.parseStatusLine("M") == nil)
    }

    @Test func markersFollowGitCodes() {
        typealias Marker = WorkspaceFile.Marker
        #expect(Marker(code: "??") == .untracked)
        #expect(Marker(code: " M") == .modified)
        #expect(Marker(code: "MM") == .modified)
        #expect(Marker(code: "A ") == .added)
        #expect(Marker(code: "AM") == .added)
        #expect(Marker(code: " D") == .deleted)
        #expect(Marker(code: "D ") == .deleted)
        #expect(Marker(code: "R ") == .renamed)
        #expect(Marker(code: "UU") == .conflict)
        #expect(Marker(code: "AA") == .conflict)
    }

    @Test func aRenamedAndQuotedPathPointsAtTheFile() throws {
        let sandbox = try OrbFolderSandbox()
        let folder = try sandbox.makeFolder("pasta")
        try sandbox.makeFolder("pasta/.git")
        let file = try sandbox.write(folder.appending(path: "café.txt"), modified: now)
        let list = WorkspaceFiles.list(from: snapshot(folder, changes: ["?? \"caf\\303\\251.txt\""]), folder: folder)
        #expect(list.map(\.path) == ["café.txt"])
        #expect(FileManager.default.fileExists(atPath: list.first?.url.path ?? ""))
        #expect(list.first?.url.standardizedFileURL.path == file.standardizedFileURL.path)
    }

    @Test func loadReadsTheFolderStateAndRefreshesOnRequest() async throws {
        let sandbox = try OrbFolderSandbox()
        let folder = try OrbFolder.create(for: "Atlas", in: sandbox.base)
        try sandbox.write(folder.appending(path: "a.txt"), modified: now)
        let counter = CaptureCounter()
        let snapshots = WorkspaceSnapshots(lifetime: 600, capture: { url in
            await counter.bump()
            return await WorkspaceSnapshot.capture(folder: url, home: sandbox.home)
        })
        let botID = UUID()
        let first = await WorkspaceFiles.load(botID: botID, folder: folder, refresh: false, snapshots: snapshots)
        #expect(first.snapshot == .scanned)
        #expect(first.files.map(\.path) == ["a.txt"])
        _ = await WorkspaceFiles.load(botID: botID, folder: folder, refresh: false, snapshots: snapshots)
        #expect(await counter.count == 1) // the cached snapshot, no second scan
        try sandbox.write(folder.appending(path: "b.txt"), modified: now.addingTimeInterval(5))
        let refreshed = await WorkspaceFiles.load(botID: botID, folder: folder, refresh: true, snapshots: snapshots)
        #expect(await counter.count == 2)
        #expect(refreshed.files.map(\.path) == ["b.txt", "a.txt"])
    }

    @Test func loadTellsAMissingFolder() async throws {
        let sandbox = try OrbFolderSandbox()
        let listing = await WorkspaceFiles.load(botID: UUID(), folder: sandbox.root.appending(path: "sumiu"), refresh: false,
                                                snapshots: WorkspaceSnapshots(capture: { url in
                                                    await WorkspaceSnapshot.capture(folder: url, home: sandbox.home)
                                                }))
        #expect(listing.folder == .missing)
        #expect(listing.snapshot == .missing)
        #expect(listing.files.isEmpty)
    }

    @Test func theHomeFolderIsNotScanned() async throws {
        let sandbox = try OrbFolderSandbox()
        try sandbox.write(sandbox.home.appending(path: "a.txt"))
        let listing = await WorkspaceFiles.load(botID: UUID(), folder: sandbox.home, refresh: false,
                                                snapshots: WorkspaceSnapshots(capture: { url in
                                                    await WorkspaceSnapshot.capture(folder: url, home: sandbox.home)
                                                }), home: sandbox.home)
        #expect(listing.snapshot == .home)
        #expect(listing.folder == .noOwnFolder)
        #expect(listing.files.isEmpty)
    }

    @Test func realGitStatusPointsAtTheChangedFiles() async throws {
        let sandbox = try OrbFolderSandbox()
        let folder = try OrbFolder.create(for: "Repo", in: sandbox.base)
        let environment = ["PATH": "/usr/bin:/bin", "HOME": sandbox.home.path, "GIT_CONFIG_NOSYSTEM": "1",
                           "GIT_AUTHOR_NAME": "Teste", "GIT_AUTHOR_EMAIL": "t@example.com",
                           "GIT_COMMITTER_NAME": "Teste", "GIT_COMMITTER_EMAIL": "t@example.com"]
        func git(_ arguments: [String]) async throws {
            let result = try await ProcessRunner.run("/usr/bin/git", arguments, directory: folder, environment: environment, timeout: .seconds(20))
            #expect(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
        }
        try sandbox.write(folder.appending(path: "tracked.txt"), modified: now)
        try await git(["init", "-q"])
        try await git(["add", "."])
        try await git(["commit", "-q", "-m", "um"])
        try "mudou".write(to: folder.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
        try sandbox.write(folder.appending(path: "novo arquivo.txt"))

        let shell = ShellEnvironment(shell: "/nonexistent/shell", base: environment)
        let captured = await WorkspaceSnapshot.capture(folder: folder, shell: shell, gitTimeout: .seconds(10), home: sandbox.home)
        let list = WorkspaceFiles.list(from: captured, folder: folder)
        let markers = Dictionary(uniqueKeysWithValues: list.map { ($0.path, $0.marker) })
        #expect(markers["tracked.txt"] == .modified)
        #expect(markers["novo arquivo.txt"] == .untracked)
        #expect(list.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    }
}

private actor CaptureCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}
