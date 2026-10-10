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

    func status(for engine: BrowserEngineKind) async -> BrowserEngineStatus { await locate(engine) }

    /// How the Orb's browser is launched for this engine and status.
    func configuration(botID: UUID, engine: BrowserEngineKind, status: BrowserEngineStatus) -> AgentBrowserConfig {
        let profile = engine.keepsProfile
            ? profilesDirectory?.appending(path: botID.uuidString).appending(path: engine.rawValue) : nil
        var config = AgentBrowserConfig(executable: status.agentBrowser ?? "agent-browser",
                                        session: AgentBrowserConfig.sessionName(botID: botID, engine: engine), engine: engine,
                                        browserExecutable: status.browserExecutable, profile: profile)
        if engine == .cloak, let profile { config.cloakSeed = CloakSeed.seed(inProfile: profile) }
        return config
    }

    /// The Orb's browser, started on first use. Throws what is missing when the engine is not installed.
    func session(botID: UUID, engine: BrowserEngineKind) async throws -> BrowserSession {
        if let existing = sessions.withLock({ $0[botID] }), existing.engine == engine { return existing }
        let status = await locate(engine)
        guard status.isReady else { throw BrowserDriverError.notInstalled(status.modelNote ?? "The browser is not installed.") }
        // Another engine is another browser: the old one is closed (best effort) before the new one takes its place.
        if let old = sessions.withLock({ $0.removeValue(forKey: botID) }) { try? await old.driver.close() }
        let session = BrowserSession(botID: botID, engine: engine, driver: makeDriver(configuration(botID: botID, engine: engine, status: status)))
        sessions.withLock { $0[botID] = session }
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

    /// Closes the Orb's browser (and forgets it). The profile stays: logins survive.
    func close(botID: UUID) async {
        clearLabels(botID: botID)
        guard let session = sessions.withLock({ $0.removeValue(forKey: botID) }) else { return }
        try? await session.driver.close()
    }

    /// Closes the browsers of every Orb that uses `engine` (before its files are removed or replaced).
    func close(engine: BrowserEngineKind) async {
        let ids = sessions.withLock { $0.filter { $0.value.engine == engine }.map(\.key) }
        for id in ids { await close(botID: id) }
    }

    /// Closes every browser at once, without waiting for a task: for `willTerminate`, which cannot wait for one. A browser left
    /// behind would keep running (and keep its profile locked) after the app is gone. Gives up after `timeout` seconds.
    func terminateAllNow(timeout: TimeInterval = 4) {
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
    }

    func closeAll() async {
        let all = sessions.withLock { sessions -> [BrowserSession] in
            defer { sessions = [:] }
            return Array(sessions.values)
        }
        labels.withLock { $0 = [:] }
        for session in all { try? await session.driver.close() }
    }

    /// Deletes what the Orb's browser kept (profile folders), when the Orb is deleted.
    func deleteData(botID: UUID) async {
        await close(botID: botID)
        if let folder = profilesDirectory?.appending(path: botID.uuidString) { try? FileManager.default.removeItem(at: folder) }
    }
}
