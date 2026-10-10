import Foundation
import Testing
@testable import Orb

/// No browser outlives what asked for it: the app quitting, an Orb changing engine, the browser being removed.
@Suite(.serialized) struct BrowserCleanupTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbCleanup-\(UUID().uuidString)")

    @MainActor @Test func changingTheEngineOrTurningTheSwitchOffClosesTheOpenBrowser() async throws {
        defer { removeTestFolder(root) }
        var state = AppState.initial
        let botID = state.bots[0].id
        state.bots[0].browserEngine = .chrome
        Store(directory: root).save(state)
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        let setup = FakeBrowserSetup(engine: .chrome)
        model.browserHub = setup.hub
        _ = try await setup.hub.session(botID: botID, engine: .chrome)
        #expect(setup.hub.existingSession(botID: botID) != nil)

        model.update(botID) { $0.name = "Outro nome" }
        try await Task.sleep(for: .milliseconds(100))
        #expect(setup.hub.existingSession(botID: botID) != nil, "a change that is not about the browser leaves it open")

        model.update(botID) { $0.browserEngine = .obscura }
        for _ in 0..<50 where setup.hub.existingSession(botID: botID) != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(setup.hub.existingSession(botID: botID) == nil && setup.driver.calls.contains("close"), "the old engine's browser is closed now")

        _ = try await setup.hub.session(botID: botID, engine: .obscura)
        model.update(botID) { $0.capabilities.remove(.browser) }
        for _ in 0..<50 where setup.hub.existingSession(botID: botID) != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(setup.hub.existingSession(botID: botID) == nil, "without \"Navegar na web\" there is no browser")
    }

    @Test func closingTheBrowsersOfAnEngineLeavesTheOtherEnginesAlone() async throws {
        let chrome = FakeBrowserSetup(engine: .chrome)
        let one = UUID(), two = UUID()
        _ = try await chrome.hub.session(botID: one, engine: .chrome)
        await chrome.hub.close(engine: .cloak)
        #expect(chrome.hub.existingSession(botID: one) != nil)
        await chrome.hub.close(engine: .chrome)
        #expect(chrome.hub.existingSession(botID: one) == nil && chrome.hub.existingSession(botID: two) == nil)
    }

    @Test func quittingClosesEveryBrowserTheHubStartedWithoutWaitingForATask() async throws {
        let setup = FakeBrowserSetup(engine: .chrome)
        _ = try await setup.hub.session(botID: setup.botID, engine: .chrome)
        let closed = LockedBox(0)
        let driver = ClosingDriver { closed.value += 1 }
        let hub = BrowserHub(profilesDirectory: nil, locate: { BrowserEngineStatus(engine: $0, agentBrowser: "/x/ab", browserExecutable: nil) },
                             makeDriver: { _ in driver })
        _ = try await hub.session(botID: UUID(), engine: .chrome)
        _ = try await hub.session(botID: UUID(), engine: .chrome)
        hub.terminateAllNow(timeout: 2)
        #expect(closed.value == 2)
        #expect(hub.existingSession(botID: setup.botID) == nil)
    }

    @Test func theCommandThatClosesAnAgentBrowserSessionIsRunAndWaitedFor() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbCloseNow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appending(path: "log")
        let script = folder.appending(path: "agent-browser")
        try "#!/bin/sh\nsleep 0.3\necho \"$@\" > '\(log.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let driver = AgentBrowserDriver(config: AgentBrowserConfig(executable: script.path, session: "orb-x-chrome", engine: .chrome))
        driver.closeSynchronously(timeout: 5)
        #expect(try String(contentsOf: log, encoding: .utf8) == "--session orb-x-chrome --json close\n", "it had finished when the call returned")

        // One that hangs is given up on.
        try "#!/bin/sh\nsleep 4\n".write(to: script, atomically: true, encoding: .utf8)
        let started = Date()
        driver.closeSynchronously(timeout: 0.4)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    // MARK: The real browsers

    @Test(.enabled(if: RealBrowsers.isReady(.chrome)), .timeLimit(.minutes(2))) func chromeLeavesNothingBehindWhenTheAppQuits() async throws { try await Self.quit(.chrome) }
    @Test(.enabled(if: RealBrowsers.isReady(.obscura)), .timeLimit(.minutes(2))) func obscuraLeavesNothingBehindWhenTheAppQuits() async throws { try await Self.quit(.obscura) }
    @Test(.enabled(if: RealBrowsers.isReady(.cloak)), .timeLimit(.minutes(2))) func cloakLeavesNothingBehindWhenTheAppQuits() async throws { try await Self.quit(.cloak) }

    /// Opens a page, "quits" (what `willTerminate` does) and looks for processes of the browser (`pgrep`).
    static func quit(_ engine: BrowserEngineKind) async throws {
        let scenario = try await RealBrowserScenario.make(engine)
        let session = try await scenario.session()
        _ = try await session.driver.open(scenario.server.url("/index.html"))
        let running = RealBrowserScenario.processes(under: RealBrowsers.root.path)
        #expect(!running.isEmpty, "the browser is running before the quit")
        let started = ContinuousClock.now
        scenario.hub.terminateAllNow()
        print("[\(engine.rawValue)] quit: \(started.duration(to: .now))")
        // `finish` waits for the processes to go, as the app's quit does not: what is left then is the answer.
        let left = await scenario.finish()
        #expect(left.isEmpty, "no browser process left: \(left)")
    }
}

/// A driver that only counts how many times it was closed without a task.
private final class ClosingDriver: BrowserDriver, @unchecked Sendable {
    let onClose: @Sendable () -> Void
    init(onClose: @escaping @Sendable () -> Void) { self.onClose = onClose }

    func closeSynchronously(timeout: TimeInterval) { onClose() }

    func open(_ url: String) async throws -> BrowserPage { BrowserPage(url: url, title: "") }
    func snapshot(interactive: Bool, selector: String?) async throws -> BrowserSnapshot { BrowserSnapshot(url: "", tree: "", refs: [:]) }
    func click(_ ref: String) async throws {}
    func fill(_ ref: String, text: String) async throws {}
    func select(_ ref: String, value: String) async throws {}
    func press(_ key: String) async throws {}
    func scroll(_ direction: BrowserScrollDirection, pixels: Int) async throws {}
    func read() async throws -> BrowserReadout { BrowserReadout(url: "", content: "") }
    func screenshot(to file: URL) async throws {}
    func back() async throws -> BrowserPage { BrowserPage(url: "", title: "") }
    func tabs() async throws -> [BrowserTab] { [] }
    func newTab(_ url: String?) async throws {}
    func selectTab(_ id: String) async throws {}
    func closeTab(_ id: String?) async throws {}
    func attribute(_ name: String, of ref: String) async throws -> String? { nil }
    func evaluate(_ script: String) async throws -> String { "" }
    func currentURL() async throws -> String? { nil }
    func setHeaded(_ headed: Bool) async throws -> BrowserPage { BrowserPage(url: "", title: "") }
    func close() async throws {}
}
