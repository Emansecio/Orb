import Foundation
import Testing
@testable import Orb

/// `--snapshot` and `--render-*` draw made-up data and exit: they never touch the user's data folder or Keychain.
@Suite struct DevRunTests {
    let support = URL(fileURLWithPath: "/Users/x/Library/Application Support")
    let temporary = URL(fileURLWithPath: "/var/tmp")

    private func folder(_ arguments: [String], environment: [String: String] = [:]) -> DevRun.DataFolder {
        DevRun.dataFolder(environment: environment, arguments: ["Orb"] + arguments, support: support, temporary: temporary, token: "T")
    }

    @Test func aNormalLaunchUsesTheUsersFolder() {
        #expect(folder([]) == .standard(support.appending(path: "Orb")))
        #expect(folder([]).allowsLegacyMigration)
    }

    @Test func everyDeveloperModeGetsAFreshTemporaryFolder() {
        for arguments in [["--snapshot", "conversations", "out.png"], ["--snapshot", "app", "out.png"],
                          ["--render-orbs", "out.png"], ["--render-icon", "out.png"]] {
            let location = folder(arguments)
            #expect(location == .temporary(temporary.appending(path: "orb-render-T")))
            #expect(!location.allowsLegacyMigration)
            #expect(!location.url.path.hasPrefix(support.path))
        }
    }

    @Test func eachProcessGetsItsOwnTemporaryFolder() {
        let first = DevRun.dataFolder(environment: [:], arguments: ["--snapshot", "a", "b"], support: support, temporary: temporary)
        let second = DevRun.dataFolder(environment: [:], arguments: ["--snapshot", "a", "b"], support: support, temporary: temporary)
        #expect(first != second)
    }

    @Test func anExplicitDataDirWinsInEveryMode() {
        let environment = ["ORB_DATA_DIR": "/tmp/orb-teste"]
        let custom = DevRun.DataFolder.custom(URL(fileURLWithPath: "/tmp/orb-teste"))
        #expect(folder([], environment: environment) == custom)
        #expect(folder(["--snapshot", "conversations", "o.png"], environment: environment) == custom)
        #expect(folder(["--render-icon", "o.png"], environment: environment) == custom)
        #expect(!custom.allowsLegacyMigration)
    }

    @Test func anEmptyDataDirDoesNotCountAsSet() {
        #expect(folder(["--snapshot", "app", "o.png"], environment: ["ORB_DATA_DIR": ""]) == .temporary(temporary.appending(path: "orb-render-T")))
        #expect(folder([], environment: ["ORB_DATA_DIR": ""]) == .standard(support.appending(path: "Orb")))
    }

    @Test func theKeychainIsOutOfReachOnlyInDeveloperModes() {
        #expect(DevRun.allowsKeychain(arguments: ["Orb"]))
        for flag in DevRun.flags { #expect(!DevRun.allowsKeychain(arguments: ["Orb", flag, "x"])) }
        // Even with an explicit data folder: the secrets are never read or written by these modes.
        #expect(!DevRun.allowsKeychain(arguments: ["Orb", "--snapshot", "app", "o.png"]))
    }

    @Test func theTestRunnerIsNotADeveloperMode() {
        #expect(!DevRun.isActive)
        #expect(DevRun.allowsKeychain(arguments: CommandLine.arguments))
    }

    /// A developer mode leaves nothing behind in the temp directory; a custom or the user's own folder is never removed.
    @Test func finishingRemovesOnlyTheTemporaryFolder() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "orb-devrun-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let kinds: [(DevRun.DataFolder, Bool)] = [
            (.temporary(base.appending(path: "t")), false), (.custom(base.appending(path: "c")), true),
            (.standard(base.appending(path: "s")), true)]
        for (kind, survives) in kinds {
            try FileManager.default.createDirectory(at: kind.url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: kind.url.appending(path: "state.json"))
            DevRun.removeTemporaryFolder(kind)
            #expect(FileManager.default.fileExists(atPath: kind.url.path) == survives, "\(kind)")
        }
    }
}

/// A developer mode (`--snapshot`, `--render-*`) draws and exits: even over a data folder with routines and connectors
/// it starts nothing that acts outside the process (the routine scheduler, the connectors' servers, Claude Code).
@Suite(.serialized) struct DevRunBackgroundTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbDevRun-\(UUID().uuidString)")

    init() { QuietNotifications.hold() }

    /// A folder with an Orb, a routine that is long overdue, and a connector whose "server" leaves a mark when it starts.
    private func seeded() throws -> (store: Store, marker: URL, routineID: UUID, botID: UUID) {
        var state = AppState.initial
        let marker = root.appending(path: "servidor-iniciou")
        var routine = Routine(name: "Vencida", botID: state.bots[0].id, prompt: "faça algo", schedule: .everyHours(1))
        routine.lastRun = Date(timeIntervalSince1970: 0)
        state.routines = [routine]
        state.connectors = [MCPServerConfig(name: "Marcador", command: "/usr/bin/touch", arguments: [marker.path])]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = Store(directory: root)
        store.save(state)
        store.flush()
        return (store, marker, routine.id, state.bots[0].id)
    }

    @Test @MainActor func aDeveloperModeStartsNeitherTheSchedulerNorTheConnectors() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = try seeded()
        let model = AppModel(store: seed.store, runsBackgroundWork: true, secretVault: MemoryVault(), devRun: true)

        // The rest of the background work did run (the Orb's memory folder appears), so waiting is over, not just slow.
        let memory = root.appending(path: "memoria/\(seed.botID.uuidString)")
        await waitUntil("the memory folder") { FileManager.default.fileExists(atPath: memory.path) }
        try await Task.sleep(for: .milliseconds(150))

        #expect(model.scheduler == nil)
        #expect(model.routines[0].lastRun == Date(timeIntervalSince1970: 0))
        #expect(!model.isRoutineRunning(seed.routineID))
        #expect(!FileManager.default.fileExists(atPath: seed.marker.path))
        #expect(model.connectorStatus.isEmpty)
    }

    @Test @MainActor func outsideADeveloperModeTheConnectorsAreKnownButStartOnlyWhenUsed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = try seeded()
        // Same data, no scheduler (tests never start one): the marker is the proof that the check above can fail.
        let model = AppModel(store: seed.store, runsBackgroundWork: false, secretVault: MemoryVault(), devRun: false)
        let id = try #require(model.connectors.first?.id)
        await waitUntil("the connector to be registered") { model.connectorStatus[id] == .idle(toolCount: nil) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!FileManager.default.fileExists(atPath: seed.marker.path))

        _ = await model.testConnector(id)
        #expect(FileManager.default.fileExists(atPath: seed.marker.path))
        await model.mcp.sync([])
    }
}
