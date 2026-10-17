import Foundation
import Testing
@testable import Orb

/// No browser outlives what asked for it: the app quitting, an Orb changing mode, the browser being removed.
@Suite(.serialized) struct BrowserCleanupTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbCleanup-\(UUID().uuidString)")

    @MainActor @Test func changingTheModeOrTurningTheSwitchOffClosesTheOpenBrowser() async throws {
        defer { removeTestFolder(root) }
        var state = AppState.initial
        let botID = state.bots[0].id
        state.bots[0].browserMode = .background
        Store(directory: root).save(state)
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        let setup = FakeBrowserSetup()
        model.browserHub = setup.hub
        _ = try await setup.hub.session(botID: botID, mode: .background)
        #expect(setup.hub.existingSession(botID: botID) != nil)

        model.update(botID) { $0.name = "Outro nome" }
        try await Task.sleep(for: .milliseconds(100))
        #expect(setup.hub.existingSession(botID: botID) != nil, "a change that is not about the browser leaves it open")

        model.update(botID) { $0.browserMode = .visible }
        for _ in 0..<50 where setup.hub.existingSession(botID: botID) != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(setup.hub.existingSession(botID: botID) == nil && setup.driver.calls.contains("close"), "the old mode's browser is closed now")

        _ = try await setup.hub.session(botID: botID, mode: .visible)
        model.update(botID) { $0.capabilities.remove(.browser) }
        for _ in 0..<50 where setup.hub.existingSession(botID: botID) != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(setup.hub.existingSession(botID: botID) == nil, "without \"Navegar na web\" there is no browser")
    }

    @Test func quittingClosesEveryBrowserTheHubStartedWithoutWaitingForATask() async throws {
        let setup = FakeBrowserSetup()
        _ = try await setup.hub.session(botID: setup.botID, mode: .background)
        let closed = LockedBox(0)
        let driver = ClosingDriver { closed.value += 1 }
        let hub = BrowserHub(profilesDirectory: nil, locate: { BrowserStatus(agentBrowser: "/x/ab") },
                             makeDriver: { _ in driver })
        _ = try await hub.session(botID: UUID(), mode: .background)
        _ = try await hub.session(botID: UUID(), mode: .background)
        hub.terminateAllNow(timeout: 2)
        #expect(closed.value == 2)
        #expect(hub.existingSession(botID: setup.botID) == nil)
    }

    // MARK: Browsers another process started (the tools server of a Claude Code turn)

    // Each turn of the Claude Code engine starts a tools server with a hub of its own, new and empty; the browser it opens is a
    // background process of `agent-browser` that outlives it, under the session name of the Orb. The app's hub holds none of
    // those, so everything that closes browsers has to close by name.

    private func sessions(_ world: FakeBrowserWorld, orb: UUID, other: UUID) -> (chrome: String, cloak: String, otherChrome: String, personal: String) {
        let names = (AgentBrowserConfig.sessionName(botID: orb), AgentBrowserConfig.botPrefix(orb) + "cloak",
                     AgentBrowserConfig.sessionName(botID: other), "default")
        for name in [names.0, names.1, names.2, names.3] { world.start(name) }
        return names
    }

    @Test func quittingAlsoClosesTheBrowsersOfClaudeCodeTurnsAndOnlyTheOrbsOnes() async throws {
        let world = FakeBrowserWorld()
        let hub = world.hub()
        let held = UUID(), mcpOrb = UUID(), mcpOther = UUID()
        _ = try await hub.session(botID: held, mode: .background)
        world.start(AgentBrowserConfig.sessionName(botID: held))
        let started = sessions(world, orb: mcpOrb, other: mcpOther)
        hub.terminateAllNow(timeout: 2)
        let heldName = AgentBrowserConfig.sessionName(botID: held)
        #expect(Set(world.closedSynchronously) == [heldName, started.chrome, started.cloak, started.otherChrome],
                "the held one and every one the tools servers started: \(world.closedSynchronously)")
        #expect(world.running == [started.personal], "the person's own agent-browser session is not ours to close")
        #expect(hub.existingSession(botID: held) == nil)
    }

    @Test func quittingClosesOnlyTheSessionsOfTheOrbsThisAppHasWhenItKnowsThem() async {
        // Another build of the app on the same Mac (a dev build, say) has Orbs of its own, and browsers that are theirs.
        let world = FakeBrowserWorld()
        let hub = world.hub()
        let mine = UUID(), theirs = UUID()
        let myChrome = AgentBrowserConfig.sessionName(botID: mine)
        let myObscura = AgentBrowserConfig.botPrefix(mine) + "obscura"
        let theirChrome = AgentBrowserConfig.sessionName(botID: theirs)
        for name in [myChrome, myObscura, theirChrome] { world.start(name) }
        _ = await hub.status() // (the app asks long before it quits)
        hub.terminateAllNow(timeout: 2, orbs: [mine])
        #expect(Set(world.closedSynchronously) == [myChrome, myObscura])
        #expect(world.running == [theirChrome])
    }

    @Test func quittingFindsAgentBrowserEvenIfThisHubNeverAskedWhereItIs() {
        // The app quit before any tool asked for a browser: the hub never resolved `agent-browser`. It is in the app's own folder.
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbQuit-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let layout = BrowserInstallLayout(root: root)
        try? FileManager.default.createDirectory(at: layout.binDirectory, withIntermediateDirectories: true)
        try? Data("#!/bin/sh\n".utf8).write(to: layout.agentBrowser)
        try? layout.agentBrowser.makeExecutable()
        let world = FakeBrowserWorld()
        let hub = BrowserHub(profilesDirectory: root, locate: { BrowserStatus() }, makeDriver: world.makeDriver)
        let name = AgentBrowserConfig.botPrefix(UUID()) + "obscura"
        world.start(name)
        hub.terminateAllNow(timeout: 2)
        #expect(world.closedSynchronously == [name])
        #expect(world.configs.allSatisfy { $0.executable == layout.agentBrowser.path })
    }

    @Test func closingAnOrbsBrowserClosesWhatAnotherProcessStartedForItWhateverTheOldEngineWas() async {
        let world = FakeBrowserWorld()
        let hub = world.hub()
        let orb = UUID(), other = UUID()
        let started = sessions(world, orb: orb, other: other)
        #expect(await hub.close(botID: orb))
        #expect(Set(world.closed) == [started.chrome, started.cloak])
        #expect(world.running == [started.otherChrome, started.personal])
        // Nothing of the Orb is running any more: the tool can tell it was not open.
        #expect(await hub.close(botID: orb) == false)
    }

    @Test func deletingTheOrbWaitsForItsBrowsersBeforeTheProfileGoes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbDelete-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let world = FakeBrowserWorld()
        world.lingers = 3 // the background process takes a few listings to go
        let hub = world.hub(profiles: root)
        let orb = UUID()
        let profile = root.appending(path: "\(orb.uuidString)/chrome")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        world.start(AgentBrowserConfig.sessionName(botID: orb)) // started by a Claude Code turn
        await hub.deleteData(botID: orb)
        #expect(world.closed == [AgentBrowserConfig.sessionName(botID: orb)])
        #expect(world.listings >= 4, "it kept asking until the browser was gone (\(world.listings) listings)")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: orb.uuidString).path))
    }

    @Test func browseCloseClosesTheBrowserEvenWhenThisHubNeverOpenedIt() async throws {
        let world = FakeBrowserWorld()
        let hub = world.hub()
        let orb = UUID()
        var context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory, botID: orb)
        context.browser = BrowserAccess(hub: hub, available: true, mode: .background)
        // An earlier turn opened it, from a tools server that is gone now.
        world.start(AgentBrowserConfig.sessionName(botID: orb))
        #expect(try await BrowseCloseTool().run(.object([:]), context: context) == "Browser closed.")
        #expect(world.running.isEmpty)
        #expect(try await BrowseCloseTool().run(.object([:]), context: context) == "The browser was not open.")
    }

    @MainActor @Test func turningOffNavegarNaWebClosesTheBrowserATurnOfClaudeCodeStarted() async throws {
        defer { removeTestFolder(root) }
        var state = AppState.initial
        let botID = state.bots[0].id
        state.bots[0].browserMode = .background
        Store(directory: root).save(state)
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        let world = FakeBrowserWorld()
        model.browserHub = world.hub()
        let name = AgentBrowserConfig.sessionName(botID: botID)
        world.start(name) // the hub of the app holds nothing
        model.update(botID) { $0.capabilities.remove(.browser) }
        for _ in 0..<100 where !world.running.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(world.closed == [name])
    }

    @MainActor @Test func removingOrUpdatingAComponentFromAjustesClosesTheBrowsersAClaudeCodeTurnStarted() async throws {
        defer { removeTestFolder(root) }
        Store(directory: root).save(AppState.initial)
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        let world = FakeBrowserWorld()
        model.browserHub = world.hub()
        let orb = UUID()
        let chrome = AgentBrowserConfig.sessionName(botID: orb)
        let obscura = AgentBrowserConfig.botPrefix(orb) + "obscura"
        world.start(chrome)
        world.start(obscura)
        model.browserSetup.remove(.chrome)
        for _ in 0..<100 where world.running.contains(chrome) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(Set(world.closed) == [chrome, obscura], "the binaries are not replaced or deleted under a running browser, whichever engine it was")
        #expect(world.running.isEmpty)
    }

    @Test func theCommandThatClosesAnAgentBrowserSessionIsRunAndWaitedFor() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbCloseNow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appending(path: "log")
        let script = folder.appending(path: "agent-browser")
        try writeExecutable("#!/bin/sh\nsleep 0.3\necho \"$@\" > '\(log.path)'\n", to: script)
        let driver = AgentBrowserDriver(config: AgentBrowserConfig(executable: script.path, session: "orb-x-chrome"))
        driver.closeSynchronously(timeout: 5)
        #expect(try String(contentsOf: log, encoding: .utf8) == "--session orb-x-chrome --json close\n", "it had finished when the call returned")

        // One that hangs is given up on.
        try "#!/bin/sh\nsleep 4\n".write(to: script, atomically: true, encoding: .utf8)
        let started = Date()
        driver.closeSynchronously(timeout: 0.4)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    // MARK: The real browsers

    @Test(.enabled(if: RealBrowsers.isReady), .timeLimit(.minutes(2))) func theBrowserLeavesNothingBehindWhenTheAppQuits() async throws { try await Self.quit() }

    /// Opens a page, "quits" (what `willTerminate` does) and looks for processes of the browser (`pgrep`).
    static func quit() async throws {
        let scenario = try await RealBrowserScenario.make()
        let session = try await scenario.session()
        _ = try await session.driver.open(scenario.server.url("/index.html"))
        let running = RealBrowserScenario.processes(under: scenario.profiles.path)
        #expect(!running.isEmpty, "the browser is running before the quit")
        let started = ContinuousClock.now
        // As `willTerminate` does it, but off the cooperative pool: it blocks until the browsers are closed.
        let hub = scenario.hub
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                hub.terminateAllNow()
                continuation.resume()
            }
        }
        print("quit: \(started.duration(to: .now))")
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
