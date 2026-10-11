import Foundation
import os

/// What a tool of an Orb needs to reach its browser: the hub that keeps the browsers, and the Orb's settings. Part of the
/// `ToolContext`; without a hub (tests, the Claude Code engine for now) the `browse_*` tools say the browser is not there.
struct BrowserAccess: Sendable {
    var hub: BrowserHub?
    var engine: BrowserEngineKind = .simple
    var searchProvider: SearchProvider = .duckduckgo
    /// The keys of the providers that need one (TinyFish), read when a search needs them.
    var searchKeys: SearchKeys?

    /// Whether the Orb has a browser to drive (not `simple`, and a hub that can start it).
    var drivesABrowser: Bool { hub != nil && engine.drivesABrowser }
}

/// Which browser tools an Orb is offered right now (see `ToolBox.offered`).
enum BrowserAvailability: Sendable, Equatable {
    /// "Navegar na web" is off: no web tools at all.
    case off
    /// `web_fetch` and `web_search` over plain HTTP: the engine `simple`, or the one chosen is not installed.
    case fetchOnly
    /// The chosen engine is installed: the `browse_*` tools too.
    case browser

    init(capabilities: Set<Capability>, engine: BrowserEngineKind, status: BrowserEngineStatus?) {
        if !capabilities.contains(.browser) { self = .off }
        else if engine.drivesABrowser, status?.isReady == true { self = .browser }
        else { self = .fetchOnly }
    }
}

/// Serializes the commands sent to one browser: tools that only look run at the same time in a turn, and two commands
/// racing in one page would answer each other's questions.
actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if locked {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            locked = true
        }
    }

    func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}

/// One Orb's open browser, and what the tools remember about it between calls: the elements of the last snapshot (to know what
/// a ref is before acting on it) and the last text read (so `offset` continues it).
final class BrowserSession: @unchecked Sendable {
    let botID: UUID
    let engine: BrowserEngineKind
    let driver: any BrowserDriver
    private let mutex = AsyncMutex()
    private let memory = OSAllocatedUnfairLock(initialState: Memory())

    struct Memory {
        var refs: [String: BrowserRef] = [:]
        var snapshotText = ""
        var snapshotURL = ""
        var readText = ""
        var readURL = ""
        /// The window is open for the person (see `browse_show`).
        var showingWindow = false
    }

    init(botID: UUID, engine: BrowserEngineKind, driver: any BrowserDriver) {
        self.botID = botID
        self.engine = engine
        self.driver = driver
    }

    /// Runs `work` alone on this browser.
    func exclusive<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        await mutex.lock()
        do {
            let result = try await work()
            await mutex.unlock()
            return result
        } catch {
            await mutex.unlock()
            throw error
        }
    }

    var snapshotMemory: (text: String, url: String) { memory.withLock { ($0.snapshotText, $0.snapshotURL) } }
    var readMemory: (text: String, url: String) { memory.withLock { ($0.readText, $0.readURL) } }
    var isShowingWindow: Bool { memory.withLock { $0.showingWindow } }

    func remember(_ snapshot: BrowserSnapshot, text: String) {
        memory.withLock {
            $0.refs = snapshot.refs
            $0.snapshotText = text
            $0.snapshotURL = snapshot.url
        }
    }

    func rememberRead(text: String, url: String) {
        memory.withLock {
            $0.readText = text
            $0.readURL = url
        }
    }

    func setShowingWindow(_ showing: Bool) { memory.withLock { $0.showingWindow = showing } }

    func ref(_ id: String) -> BrowserRef? { memory.withLock { $0.refs[id] } }

    /// The page changed in place (a click, a key): the cached texts no longer describe it. The refs of elements that are still
    /// there stay valid in the browser, so what they were called is kept.
    func pageChanged() {
        memory.withLock {
            $0.snapshotText = ""
            $0.readText = ""
        }
    }

    /// Another page: refs and the cached texts no longer describe it.
    func forgetPage() {
        memory.withLock {
            $0.refs = [:]
            $0.snapshotText = ""
            $0.readText = ""
        }
    }
}

/// The browsers of the app, one per Orb: finds the engines on the Mac, starts the driver of an Orb's engine on first use and
/// keeps it, so the tools of the Orb's next turns find the same page open. It never installs anything (that is `BrowserInstaller`,
/// from Ajustes) and closes every browser it started when the app quits.
final class BrowserHub: Sendable {
    /// `<data folder>/navegador`: a folder per Orb (and engine) for what the browser keeps, logins included, and `bin`, `chrome`,
    /// `cloak` for what the installer put there (`BrowserInstallLayout`).
    let profilesDirectory: URL?
    private let locate: @Sendable (BrowserEngineKind) async -> BrowserEngineStatus
    private let makeDriver: @Sendable (AgentBrowserConfig) -> any BrowserDriver
    private let sessions = OSAllocatedUnfairLock<[UUID: BrowserSession]>(initialState: [:])
    /// What the tools say a ref is ("Entrar" for e3), by Orb, readable without waiting (the approval card shows it).
    private let labels = OSAllocatedUnfairLock<[UUID: [String: String]]>(initialState: [:])

    init(profilesDirectory: URL?,
         locate: (@Sendable (BrowserEngineKind) async -> BrowserEngineStatus)? = nil,
         makeDriver: @escaping @Sendable (AgentBrowserConfig) -> any BrowserDriver = { AgentBrowserDriver(config: $0) }) {
        self.profilesDirectory = profilesDirectory
        self.locate = locate ?? BrowserHub.liveStatus(root: profilesDirectory)
        self.makeDriver = makeDriver
    }

    /// The hub of the app, with its folder in the data folder (`Store.directory`).
    static func live(dataFolder: URL) -> BrowserHub { BrowserHub(profilesDirectory: dataFolder.appending(path: "navegador")) }

    /// The engines as they are on this Mac now: what the app installed first, then the user's own PATH.
    static func liveStatus(root: URL?) -> @Sendable (BrowserEngineKind) async -> BrowserEngineStatus {
        { engine in
            let path = await ShellEnvironment.shared.resolved().environment["PATH"]
            return BrowserEngineLocator.live(path: path, managedRoot: root).status(for: engine)
        }
    }

    func status(for engine: BrowserEngineKind) async -> BrowserEngineStatus {
        let status = await locate(engine)
        remember(status)
        return status
    }

    /// The `agent-browser` last seen, for closing browsers at quit, which cannot ask where it is.
    private let knownAgentBrowser = OSAllocatedUnfairLock<String?>(initialState: nil)

    private func remember(_ status: BrowserEngineStatus) {
        if let path = status.agentBrowser, path.hasPrefix("/") { knownAgentBrowser.withLock { $0 = path } }
    }

    /// How the Orb's browser is launched for this engine and status.
    func configuration(botID: UUID, engine: BrowserEngineKind, status: BrowserEngineStatus) -> AgentBrowserConfig {
        remember(status)
        let profile = engine.keepsProfile
            ? profilesDirectory?.appending(path: botID.uuidString).appending(path: engine.rawValue) : nil
        var config = AgentBrowserConfig(executable: status.agentBrowser ?? "agent-browser",
                                        session: AgentBrowserConfig.sessionName(botID: botID, engine: engine), engine: engine,
                                        browserExecutable: status.browserExecutable, profile: profile, stateDirectory: profilesDirectory)
        // Written once (atomically, see `CloakSeed`): two callers at the same time get the same seed.
        if engine == .cloak, let profile { config.cloakSeed = CloakSeed.seed(inProfile: profile) }
        return config
    }

    /// The Orb's browser, started on first use. Throws what is missing when the engine is not installed.
    func session(botID: UUID, engine: BrowserEngineKind) async throws -> BrowserSession {
        if let existing = sessions.withLock({ $0[botID] }), existing.engine == engine { return existing }
        let status = await status(for: engine)
        guard status.isReady else { throw BrowserDriverError.notInstalled(status.modelNote ?? "The browser is not installed.") }
        // Two calls for the same Orb can both get here (the tools of one turn run at the same time, and the lookup above waited):
        // the check and the installing of the session are one step, so the second finds the first one's and uses it.
        let (session, replaced) = sessions.withLock { sessions -> (BrowserSession, BrowserSession?) in
            if let existing = sessions[botID], existing.engine == engine { return (existing, nil) }
            let session = BrowserSession(botID: botID, engine: engine, driver: makeDriver(configuration(botID: botID, engine: engine, status: status)))
            return (session, sessions.updateValue(session, forKey: botID))
        }
        // Another engine is another browser: the old one is closed (best effort).
        if let replaced, replaced !== session { try? await replaced.driver.close() }
        return session
    }

    func existingSession(botID: UUID) -> BrowserSession? { sessions.withLock { $0[botID] } }

    // MARK: Labels

    func setLabels(_ refs: [String: BrowserRef], botID: UUID) {
        labels.withLock { $0[botID] = refs.mapValues { Self.label(of: $0) } }
    }

    func clearLabels(botID: UUID) { labels.withLock { _ = $0.removeValue(forKey: botID) } }

    func label(ofRef ref: String, botID: UUID) -> String? { labels.withLock { $0[botID]?[ref] } }

    private static func label(of ref: BrowserRef) -> String {
        let name = ref.name.split(whereSeparator: \.isWhitespace).joined(separator: " ").clipped(to: 60)
        return name.isEmpty ? ref.role : name
    }

    // MARK: Closing

    // A browser outlives the process that started it: its background process (`agent-browser`) keeps it, and one left by an earlier
    // run of the app is not held here. Sessions are named after the Orb and the engine (`AgentBrowserConfig.sessionName`), so
    // everything below that closes a browser closes it by name too: the sessions `agent-browser` reports running that are the Orb's,
    // whoever started them.

    private static let driven: [BrowserEngineKind] = [.chrome, .obscura, .cloak]

    /// The `agent-browser` to ask which sessions run: the one the engines resolve to now.
    private func agentBrowserPath() async -> String? {
        for engine in Self.driven {
            if let path = await status(for: engine).agentBrowser { return path }
        }
        return nil
    }

    /// The same when nothing can be awaited (the app is quitting): the last one seen, or the one the app installed, or one in the
    /// usual places of a Mac (the login shell's PATH cannot be asked now).
    private func agentBrowserPathNow() -> String? {
        if let known = knownAgentBrowser.withLock({ $0 }) { return known }
        return BrowserEngineLocator.live(path: nil, managedRoot: profilesDirectory).agentBrowser()
    }

    /// A driver for a session by name, to ask or close it.
    private func driver(forSession name: String, executable: String) -> any BrowserDriver {
        makeDriver(AgentBrowserConfig(executable: executable, session: name, engine: AgentBrowserConfig.engine(ofSession: name) ?? .chrome,
                                      stateDirectory: profilesDirectory))
    }

    /// The Orb's sessions running now (`orb-<id>-<engine>`) that `matches`, whoever started them.
    private func runningSessions(executable: String, where matches: (String) -> Bool) async -> [String] {
        await driver(forSession: "orb-sessions", executable: executable).runningSessions()
            .filter { $0.hasPrefix(AgentBrowserConfig.sessionPrefix) && matches($0) }
    }

    /// Closes by name the sessions running now that `matches`, except `skipping` (the ones just closed). True when there was one.
    @discardableResult
    private func closeRunning(where matches: (String) -> Bool, skipping: Set<String> = []) async -> Bool {
        guard let executable = await agentBrowserPath() else { return false }
        let names = await runningSessions(executable: executable, where: matches).filter { !skipping.contains($0) }
        for name in names { try? await driver(forSession: name, executable: executable).close() }
        return !names.isEmpty
    }

    /// Closes the browser this hub holds for the Orb (and forgets it); true when there was one.
    private func closeHeld(botID: UUID, engine: BrowserEngineKind? = nil) async -> BrowserSession? {
        let held = sessions.withLock { sessions -> BrowserSession? in
            guard let session = sessions[botID], engine == nil || session.engine == engine else { return nil }
            return sessions.removeValue(forKey: botID)
        }
        if let held { try? await held.driver.close() }
        return held
    }

    private static func name(of session: BrowserSession) -> String { AgentBrowserConfig.sessionName(botID: session.botID, engine: session.engine) }

    /// Closes the Orb's browsers, whichever engine and whoever started them (and forgets them). The profile stays: logins survive.
    /// True when one was open.
    @discardableResult
    func close(botID: UUID) async -> Bool {
        clearLabels(botID: botID)
        let held = await closeHeld(botID: botID)
        let prefix = AgentBrowserConfig.botPrefix(botID)
        let others = await closeRunning(where: { $0.hasPrefix(prefix) }, skipping: held.map { [Self.name(of: $0)] } ?? [])
        return held != nil || others
    }

    /// Closes the browsers of every Orb that uses `engine` (before its files are removed or replaced), the ones other processes
    /// started included.
    func close(engine: BrowserEngineKind) async {
        let ids = sessions.withLock { $0.filter { $0.value.engine == engine }.map(\.key) }
        var held: Set<String> = []
        for id in ids {
            clearLabels(botID: id)
            if let session = await closeHeld(botID: id, engine: engine) { held.insert(Self.name(of: session)) }
        }
        let suffix = "-" + engine.rawValue
        await closeRunning(where: { $0.hasSuffix(suffix) }, skipping: held)
    }

    /// Closes every browser at once, without waiting for a task: for `willTerminate`, which cannot wait for one. A browser left
    /// behind would keep running (and keep its profile locked) after the app is gone. That includes the ones an earlier run of
    /// the app left: every running session named for an Orb is closed. `orbs`: the
    /// Orbs of this app, when the caller knows them; only their sessions are closed then (another build of the app on the same Mac
    /// has Orbs of its own, and its browsers are not ours to close). Gives up after `timeout` seconds.
    func terminateAllNow(timeout: TimeInterval = 4, orbs: Set<UUID>? = nil) {
        let all = sessions.withLock { sessions -> [BrowserSession] in
            defer { sessions = [:] }
            return Array(sessions.values)
        }
        let group = DispatchGroup()
        for session in all {
            group.enter()
            DispatchQueue.global().async {
                session.driver.closeSynchronously(timeout: timeout)
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout + 1)
        guard let executable = agentBrowserPathNow() else { return }
        let held = Set(all.map(Self.name(of:)))
        let lister = driver(forSession: "orb-sessions", executable: executable)
        let prefixes = orbs.map { $0.map(AgentBrowserConfig.botPrefix) }
        let others = lister.runningSessionsSynchronously(timeout: timeout).filter { name in
            name.hasPrefix(AgentBrowserConfig.sessionPrefix) && !held.contains(name) && (prefixes?.contains { name.hasPrefix($0) } ?? true)
        }
        for name in others {
            group.enter()
            DispatchQueue.global().async { [self] in
                driver(forSession: name, executable: executable).closeSynchronously(timeout: timeout)
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout + 1)
    }

    /// The Orb left `engine` for another: closes the browser it had open with it. The session may have been started by another
    /// process (an earlier run of the app), so when this hub
    /// holds none the session is closed by name; it does nothing when no browser is running. The profile stays.
    func close(botID: UUID, leaving engine: BrowserEngineKind) async {
        clearLabels(botID: botID)
        if await closeHeld(botID: botID, engine: engine) != nil { return }
        guard engine.drivesABrowser else { return }
        let name = AgentBrowserConfig.sessionName(botID: botID, engine: engine)
        await closeRunning(where: { $0 == name })
    }

    func closeAll() async {
        let all = sessions.withLock { sessions -> [BrowserSession] in
            defer { sessions = [:] }
            return Array(sessions.values)
        }
        labels.withLock { $0 = [:] }
        for session in all { try? await session.driver.close() }
        await closeRunning(where: { _ in true }, skipping: Set(all.map(Self.name(of:))))
    }

    /// Deletes what the Orb's browser kept (profile folders), when the Orb is deleted. Its browsers are closed first, and waited
    /// for: a Chrome still running would write into a folder that is gone.
    func deleteData(botID: UUID) async {
        await close(botID: botID)
        if let executable = await agentBrowserPath() {
            let prefix = AgentBrowserConfig.botPrefix(botID)
            for _ in 0..<50 where !(await runningSessions(executable: executable, where: { $0.hasPrefix(prefix) })).isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
            }
            // The browser itself may outlive its background process by a moment.
            try? await Task.sleep(for: .milliseconds(300))
        }
        if let folder = profilesDirectory?.appending(path: botID.uuidString) { try? FileManager.default.removeItem(at: folder) }
    }
}
