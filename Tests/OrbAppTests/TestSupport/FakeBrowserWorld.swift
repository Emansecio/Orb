import Foundation
import os
@testable import Orb

/// The sessions `agent-browser` has running on a made-up Mac, shared by every driver a hub makes: a session started by "another
/// process" (the tools server of a Claude Code turn) is in `running` though no hub holds it, and a driver closes it by name.
final class FakeBrowserWorld: @unchecked Sendable {
    private struct State {
        var running: Set<String> = []
        var closed: [String] = []
        var closedSynchronously: [String] = []
        var configs: [AgentBrowserConfig] = []
        /// Sessions that were closed and still show in the list for a few more listings (a background process takes a moment to go).
        var lingering: [String: Int] = [:]
        var listings = 0
    }

    /// How many listings a closed session stays in, as the real one does for a moment.
    var lingers = 0

    private let state = OSAllocatedUnfairLock(initialState: State())

    var running: Set<String> { state.withLock { $0.running } }
    /// Session names in the order they were closed (by a task).
    var closed: [String] { state.withLock { $0.closed } }
    /// Session names in the order they were closed without a task (the app quitting).
    var closedSynchronously: [String] { state.withLock { $0.closedSynchronously } }
    var configs: [AgentBrowserConfig] { state.withLock { $0.configs } }

    func start(_ session: String) { state.withLock { _ = $0.running.insert(session) } }

    /// How many times the sessions were listed.
    var listings: Int { state.withLock { $0.listings } }

    /// What `session list` says: the running ones and the ones closed that are still leaving.
    fileprivate func list() -> [String] {
        state.withLock { state in
            state.listings += 1
            let names = state.running.union(state.lingering.keys).sorted()
            for (name, left) in state.lingering { if left <= 1 { state.lingering[name] = nil } else { state.lingering[name] = left - 1 } }
            return names
        }
    }

    fileprivate func stop(_ session: String, synchronously: Bool) {
        state.withLock { state in
            state.running.remove(session)
            if lingers > 0 { state.lingering[session] = lingers }
            if synchronously { state.closedSynchronously.append(session) } else { state.closed.append(session) }
        }
    }

    fileprivate func note(_ config: AgentBrowserConfig) { state.withLock { $0.configs.append(config) } }

    /// The `makeDriver` of a hub in this world.
    var makeDriver: @Sendable (AgentBrowserConfig) -> any BrowserDriver {
        { [self] config in
            note(config)
            return FakeWorldDriver(world: self, session: config.session)
        }
    }

    /// A hub whose `agent-browser` is found (an engine is ready), in this world.
    func hub(profiles: URL? = nil) -> BrowserHub {
        BrowserHub(profilesDirectory: profiles, locate: {
            BrowserStatus(agentBrowser: "/fake/agent-browser", program: BrowserProgram(kind: .chrome, executable: "/fake/chrome", major: 155))
        }, makeDriver: makeDriver)
    }
}

private final class FakeWorldDriver: BrowserDriver, @unchecked Sendable {
    let world: FakeBrowserWorld
    let session: String

    init(world: FakeBrowserWorld, session: String) {
        self.world = world
        self.session = session
    }

    func open(_ url: String) async throws -> BrowserPage {
        world.start(session)
        return BrowserPage(url: url, title: "")
    }

    func close() async throws { world.stop(session, synchronously: false) }
    func closeSynchronously(timeout: TimeInterval) { world.stop(session, synchronously: true) }
    func runningSessions() async -> [String] { world.list() }
    func runningSessionsSynchronously(timeout: TimeInterval) -> [String] { world.list() }

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
    func currentURL() async throws -> String? { world.running.contains(session) ? "about:blank" : nil }
    func setHeaded(_ headed: Bool) async throws -> BrowserPage { BrowserPage(url: "", title: "") }
}
