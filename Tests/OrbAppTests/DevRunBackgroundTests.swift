import Foundation
import Testing
@testable import Orb

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
