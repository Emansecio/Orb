import Foundation
import os

/// What a tool of an Orb needs to reach its browser: the hub that keeps the browsers, and the Orb's settings. Part of the
/// `ToolContext`; without a hub (tests) the `browse_*` tools say the browser is not there.
struct BrowserAccess: Sendable {
    var hub: BrowserHub?
    /// The Orb has "Navegar na web" and its browser is installed.
    var available = false
    /// Background or visible (the Orb's own setting).
    var mode: BrowserMode = .background
    var searchProvider: SearchProvider = .duckduckgo
    /// The keys of the providers that need one (TinyFish), read when a search needs them.
    var searchKeys: SearchKeys?
    /// The Orb's proxy as saved (nil: direct), and how `browse_proxy` saves a new one in the Orb.
    var proxy: String?
    var saveProxy: (@Sendable (String?) async -> Void)?
    /// What the Orb is doing this browser work for (a chat, a routine run, a group turn): each gets a tab of its own, so two of them
    /// at once on the same Orb do not take the page from each other. Nil: the browser's current tab, as it is.
    var scope: String?

    /// Whether the Orb has a browser to drive (installed, and a hub that can start it).
    var drivesABrowser: Bool { hub != nil && available }
}

/// Which browser tools an Orb is offered right now (see `ToolBox.offered`).
enum BrowserAvailability: Sendable, Equatable {
    /// "Navegar na web" is off: no web tools at all.
    case off
    /// `web_fetch` and `web_search` over plain HTTP: the browser is not installed.
    case fetchOnly
    /// The browser is installed: the `browse_*` tools too.
    case browser

    init(capabilities: Set<Capability>, status: BrowserStatus?) {
        if !capabilities.contains(.browser) { self = .off }
        else if status?.isReady == true { self = .browser }
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

/// Which tabs belong to which conversation in one Orb's browser, and which conversation called last (its tab is the browser's
/// current one). A conversation gets a tab on its first call after another one used the browser; the first one keeps the tab the
/// browser started with. A tab is switched to only when the conversation that calls is not the one that called last, so one
/// conversation alone costs nothing extra. Every call of a conversation runs under the browser's lock right after its tab is made
/// current (`BrowserSession.exclusive`), so the switch and the command are one step for the other conversations.
///
/// Tabs are named by the label the book gave them (`c` and the first letters of the conversation's id) or by the browser's own id
/// (`t1`, and `t3` for one the conversation opened or chose with `browse_tabs`).
final class TabBook: @unchecked Sendable {
    /// More than this many tabs of conversations: the ones of the conversation used longest ago are closed (with a proxy that
    /// needs a login, where closing a tab breaks agent-browser 0.39.1, its tab is handed to the new conversation instead).
    static let limit = 6

    private struct State {
        /// The conversation that called last.
        var current: String?
        /// The tabs of each conversation; the first is the one it works in.
        var tabs: [String: [String]] = [:]
        /// Conversations, the one used last at the end.
        var order: [String] = []
        /// Tabs no conversation has any more (the first tab, or any when tabs are not closed): a new conversation takes one of
        /// these before opening a tab.
        var spare: [String] = []
        /// The browser these tabs are in (`BrowserDriver.generation`): another one has none of them.
        var generation = 0

        var count: Int { tabs.values.reduce(0) { $0 + $1.count } + spare.count }

        mutating func touch(_ scope: String) {
            order.removeAll { $0 == scope }
            order.append(scope)
        }

        mutating func take(_ tab: String, for scope: String) {
            spare.removeAll { $0 == tab }
            for (other, list) in tabs where other != scope && list.contains(tab) {
                let rest = list.filter { $0 != tab }
                tabs[other] = rest.isEmpty ? nil : rest
                if rest.isEmpty { order.removeAll { $0 == other } }
            }
            tabs[scope] = [tab] + (tabs[scope] ?? []).filter { $0 != tab }
            current = scope
            touch(scope)
        }

        /// The browser started again (closed and opened, shown in a window, or gone): the only page left is the one open now, which
        /// the conversation that called last opened.
        mutating func restart(generation: Int) {
            let owner = current
            self = State(generation: generation)
            if let owner { take("t1", for: owner) }
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The tab a conversation works in.
    func tab(for scope: String) -> String? { state.withLock { $0.tabs[scope]?.first } }

    /// Every tab a conversation has, the one it works in first.
    func tabs(of scope: String) -> [String] { state.withLock { $0.tabs[scope] ?? [] } }

    /// Every tab some conversation has.
    var ownedTabs: Set<String> { state.withLock { Set($0.tabs.values.joined()) } }

    /// The tab is this conversation's, and the one it works in.
    func adopt(_ tab: String, for scope: String) { state.withLock { $0.take(tab, for: scope) } }

    /// The tab was closed.
    func forget(_ tab: String) {
        state.withLock { state in
            state.spare.removeAll { $0 == tab }
            for (scope, list) in state.tabs where list.contains(tab) {
                let rest = list.filter { $0 != tab }
                state.tabs[scope] = rest.isEmpty ? nil : rest
                if list.first == tab, state.current == scope { state.current = nil }
            }
        }
    }

    /// The name a conversation's tab gets (a label, so the browser finds it by name however the tabs are numbered).
    static func label(for scope: String) -> String {
        "c" + String(scope.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
    }

    private enum Step {
        case stay
        case switchTo(String)
        case reuse(String)
        case takeFrom(scope: String, tab: String)
        case open
    }

    /// Makes `scope`'s tab the current one. A failure here is not the call's: it goes on in the tab the browser has. `closesTabs`:
    /// whether a tab may be closed in this browser (see `limit`).
    func activate(_ scope: String, driver: any BrowserDriver, closesTabs: Bool = true) async {
        let generation = driver.generation
        let step = state.withLock { state -> Step in
            if state.generation != generation { state.restart(generation: generation) }
            state.touch(scope)
            if state.current == scope { return .stay }
            if let known = state.tabs[scope]?.first { return .switchTo(known) }
            return Self.fresh(&state, for: scope, closesTabs: closesTabs)
        }
        await perform(step, for: scope, driver: driver, closesTabs: closesTabs)
    }

    /// What a conversation with no tab gets: the browser's own first tab when nothing is open yet, a spare one, the tab of the
    /// conversation used longest ago when no tab may be closed and there are enough, or a new one.
    private static func fresh(_ state: inout State, for scope: String, closesTabs: Bool) -> Step {
        if let spare = state.spare.first { return .reuse(spare) }
        if state.tabs.isEmpty, state.current == nil {
            // The browser's own first tab (it is not even open yet when the first call is the `open`).
            state.take("t1", for: scope)
            return .stay
        }
        if !closesTabs, state.count >= limit, let old = state.order.first(where: { $0 != scope && state.tabs[$0] != nil }),
           let tab = state.tabs[old]?.first {
            return .takeFrom(scope: old, tab: tab)
        }
        return .open
    }

    private func perform(_ step: Step, for scope: String, driver: any BrowserDriver, closesTabs: Bool) async {
        switch step {
        case .stay:
            return
        case .switchTo(let tab), .reuse(let tab), .takeFrom(_, let tab):
            do {
                _ = try await driver.command(["tab", tab])
                adopt(tab, for: scope)
                return
            } catch BrowserDriverError.noPage {
                restartEmpty(for: scope, driver: driver)
                return
            } catch {
                // That tab is gone (closed by the page or by hand): another one below.
                forget(tab)
            }
            let next = state.withLock { Self.fresh(&$0, for: scope, closesTabs: closesTabs) }
            if case .open = next { await openTab(for: scope, driver: driver, closesTabs: closesTabs) }
            else if case .stay = next { return }
            else { await perform(next, for: scope, driver: driver, closesTabs: closesTabs) }
        case .open:
            await openTab(for: scope, driver: driver, closesTabs: closesTabs)
        }
    }

    private func openTab(for scope: String, driver: any BrowserDriver, closesTabs: Bool) async {
        let label = Self.label(for: scope)
        do {
            _ = try await driver.command(["tab", "new", "--label", label])
            adopt(label, for: scope)
            if closesTabs { await trim(keeping: scope, driver: driver) }
        } catch BrowserDriverError.noPage {
            restartEmpty(for: scope, driver: driver)
        } catch {
            // The call goes on in the current tab, which is what there was before tabs of their own.
        }
    }

    /// No browser is open (it was closed, or it went away): the next `open` starts one, and its first tab is this conversation's.
    private func restartEmpty(for scope: String, driver: any BrowserDriver) {
        state.withLock { state in
            state = State(generation: driver.generation)
            state.take("t1", for: scope)
        }
    }

    private func trim(keeping scope: String, driver: any BrowserDriver) async {
        let victims = state.withLock { state -> [String] in
            guard state.count > Self.limit,
                  let old = state.order.first(where: { $0 != scope && state.tabs[$0]?.contains("t1") == false }),
                  let tabs = state.tabs.removeValue(forKey: old) else { return [] }
            state.order.removeAll { $0 == old }
            return tabs
        }
        for tab in victims { _ = try? await driver.command(["tab", "close", tab]) }
    }

    /// The conversation is over: its tabs are closed, or kept as spares when this browser may not close one (and the first tab,
    /// which is never closed, is always kept).
    func end(_ scope: String, driver: any BrowserDriver, closesTabs: Bool) async {
        let tabs = state.withLock { state -> [String] in
            guard state.generation == driver.generation, let tabs = state.tabs.removeValue(forKey: scope) else {
                state.tabs[scope] = nil
                state.order.removeAll { $0 == scope }
                return []
            }
            state.order.removeAll { $0 == scope }
            if state.current == scope { state.current = nil }
            return tabs
        }
        for tab in tabs {
            if closesTabs, tab != "t1", (try? await driver.command(["tab", "close", tab])) != nil { continue }
            state.withLock { if !$0.spare.contains(tab) { $0.spare.append(tab) } }
        }
    }

    /// The pages the conversations other than `keeping` have open (one per conversation: the tab it works in), to open again
    /// after the browser starts over (`restore`). Only web pages.
    func pages(excluding keeping: String?, driver: any BrowserDriver) async -> [(scope: String, url: String)] {
        let mapping = state.withLock { state in state.tabs.compactMapValues(\.first).filter { $0.key != keeping } }
        guard !mapping.isEmpty, let list = try? await driver.tabs() else { return [] }
        let order = state.withLock { $0.order }
        return order.reversed().compactMap { scope in
            guard let tab = mapping[scope], let found = list.first(where: { $0.id == tab || $0.label == tab }),
                  found.url.hasPrefix("http") else { return nil }
            return (scope, found.url)
        }
    }

    /// After the browser started over (a proxy, the window shown or hidden): the page open now is `owner`'s, and the other
    /// conversations get their pages back, each in a tab of its own, at most `limit` in all.
    func restore(_ pages: [(scope: String, url: String)], owner: String?, driver: any BrowserDriver) async {
        state.withLock { state in
            state = State(generation: driver.generation)
            if let owner { state.take("t1", for: owner) }
        }
        var opened = false
        for page in pages.prefix(Self.limit - 1) where page.scope != owner {
            let label = Self.label(for: page.scope)
            guard (try? await driver.command(["tab", "new", "--label", label, page.url])) != nil else { continue }
            opened = true
            state.withLock { state in
                state.tabs[page.scope] = [label]
                state.order.insert(page.scope, at: 0)
            }
        }
        guard opened else { return }
        // The tab that was current goes back to the front.
        if owner != nil, (try? await driver.command(["tab", "t1"])) != nil { return }
        state.withLock { $0.current = nil }
    }
}

/// One Orb's open browser, and what the tools remember about it between calls: the elements of the last snapshot (to know what
/// a ref is before acting on it) and the last text read (so `offset` continues it).
final class BrowserSession: @unchecked Sendable {
    let botID: UUID
    let mode: BrowserMode
    /// The proxy this browser was started with.
    let proxy: String?
    let driver: any BrowserDriver
    /// The conversation this view of the browser is for (nil: the browser as a whole, which has no tab of its own).
    let scope: String?
    /// The browser as a whole that a scoped view was made from.
    let base: BrowserSession?
    private let mutex: AsyncMutex
    private let tabs: TabBook
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

    init(botID: UUID, mode: BrowserMode, proxy: String? = nil, driver: any BrowserDriver) {
        self.botID = botID
        self.mode = mode
        self.proxy = proxy
        self.driver = driver
        scope = nil
        base = nil
        mutex = AsyncMutex()
        tabs = TabBook()
    }

    private init(sharing other: BrowserSession, scope: String) {
        botID = other.botID
        mode = other.mode
        proxy = other.proxy
        driver = other.driver
        mutex = other.mutex
        tabs = other.tabs
        base = other
        self.scope = scope
    }

    /// The same browser seen from one conversation: the same driver and the same one-at-a-time lock, its own tab, its own memory of
    /// the elements it saw (a ref belongs to the tab it was read in).
    func scoped(_ scope: String) -> BrowserSession { BrowserSession(sharing: self, scope: scope) }

    /// Runs `work` alone on this browser, in this conversation's tab.
    func exclusive<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        await mutex.lock()
        do {
            if let scope { await tabs.activate(scope, driver: driver, closesTabs: closesTabs) }
            let result = try await work()
            await mutex.unlock()
            return result
        } catch {
            await mutex.unlock()
            throw error
        }
    }

    /// Whether a tab may be closed in this browser: not when its proxy needs a login, where agent-browser 0.39.1 loses the
    /// browser on `tab close` ("Failed to install browser network controls", measured), so tabs are reused instead.
    var closesTabs: Bool { !BrowserProxy.hasUser(proxy) }

    /// The tab the person or the Orb just made current (`browse_tabs`) is this conversation's from now on.
    func adoptCurrentTab() async {
        guard let scope, let list = try? await driver.tabs(), let active = list.first(where: \.isActive) else { return }
        tabs.adopt(active.label ?? active.id, for: scope)
    }

    /// The tab this conversation works in, if it has one yet (for tests and the tab list).
    var tabName: String? { scope.flatMap { tabs.tab(for: $0) } }

    /// The tabs of the browser this conversation may see and use: its own, and the current one when it is nobody's (a page the
    /// conversation's own click opened). How many tabs other conversations of the Orb have is all it learns of them.
    func visibleTabs() async throws -> (mine: [BrowserTab], others: Int) {
        let list = try await driver.tabs()
        guard let scope else { return (list, 0) }
        let mine = Set(tabs.tabs(of: scope)), owned = tabs.ownedTabs
        let visible = list.filter { tab in
            mine.contains(tab.id) || tab.label.map(mine.contains) == true
                || (tab.isActive && !owned.contains(tab.id) && tab.label.map(owned.contains) != true)
        }
        return (visible, list.count - visible.count)
    }

    /// The tab was closed (`browse_tabs close`).
    func forgetTab(_ tab: BrowserTab) {
        tabs.forget(tab.id)
        if let label = tab.label { tabs.forget(label) }
    }

    /// The conversation is over: its tabs go (see `TabBook.end`). Under the browser's lock, without making any tab current.
    func endScope(_ scope: String) async {
        let root = base ?? self
        _ = try? await root.exclusive { await root.tabs.end(scope, driver: root.driver, closesTabs: root.closesTabs) }
    }

    /// The pages of the other conversations, read before the browser starts over (`restoreTabs`). Inside `exclusive`.
    func pagesOfOtherConversations() async -> [(scope: String, url: String)] {
        await tabs.pages(excluding: scope, driver: driver)
    }

    /// The browser started over with this conversation's page in its first tab: the other conversations get theirs back. Inside
    /// `exclusive`.
    func restoreTabs(_ pages: [(scope: String, url: String)]) async {
        await tabs.restore(pages, owner: scope, driver: driver)
    }

    /// Runs `relaunch` (`setHeaded`, which closes the browser and opens this conversation's page again) and gives the other
    /// conversations their pages back. Inside `exclusive`.
    func relaunchKeepingTabs<T: Sendable>(_ relaunch: @Sendable () async throws -> T) async throws -> T {
        let pages = await pagesOfOtherConversations()
        let result = try await relaunch()
        await restoreTabs(pages)
        return result
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

/// The browsers of the app, one per Orb: finds the browser on the Mac, starts the driver of an Orb's browser on first use and
/// keeps it, so the tools of the Orb's next turns find the same page open. It never installs anything (that is `BrowserInstaller`,
/// from Ajustes) and closes every browser it started when the app quits.
final class BrowserHub: Sendable {
    /// `<data folder>/navegador`: a folder per Orb for what the browser keeps, logins included, and `bin`, `chrome` for what the
    /// installer put there (`BrowserInstallLayout`).
    let profilesDirectory: URL?
    private let locate: @Sendable () async -> BrowserStatus
    private let makeDriver: @Sendable (AgentBrowserConfig) -> any BrowserDriver
    private let sessions = OSAllocatedUnfairLock<[UUID: BrowserSession]>(initialState: [:])
    /// What the tools say a ref is ("Entrar" for e3), by Orb and conversation (a ref belongs to the tab it was read in), readable
    /// without waiting (the approval card shows it).
    private let labels = OSAllocatedUnfairLock<[LabelKey: [String: String]]>(initialState: [:])
    private struct LabelKey: Hashable { let botID: UUID; let scope: String? }
    private let proxies = OSAllocatedUnfairLock<[UUID: String]>(initialState: [:])
    /// The close of the browser an Orb's session replaced, until it is done.
    private let closings = OSAllocatedUnfairLock<[UUID: Task<Void, Never>]>(initialState: [:])
    private let scoped = OSAllocatedUnfairLock<[UUID: [String: BrowserSession]]>(initialState: [:])
    /// The Orbs whose profile caches are being emptied now (`cleanCachesIfDue`): their browser waits.
    private let cleaning = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    init(profilesDirectory: URL?,
         locate: (@Sendable () async -> BrowserStatus)? = nil,
         makeDriver: @escaping @Sendable (AgentBrowserConfig) -> any BrowserDriver = { AgentBrowserDriver(config: $0) }) {
        self.profilesDirectory = profilesDirectory
        self.locate = locate ?? BrowserHub.liveStatus(root: profilesDirectory)
        self.makeDriver = makeDriver
    }

    /// The hub of the app, with its folder in the data folder (`Store.directory`).
    static func live(dataFolder: URL) -> BrowserHub { BrowserHub(profilesDirectory: dataFolder.appending(path: "navegador")) }

    /// The browser as it is on this Mac now: what the app installed first, then the user's own PATH.
    static func liveStatus(root: URL?) -> @Sendable () async -> BrowserStatus {
        {
            let path = await ShellEnvironment.shared.resolved().environment["PATH"]
            return BrowserLocator.live(path: path, managedRoot: root).status()
        }
    }

    func status() async -> BrowserStatus {
        let status = await locate()
        remember(status)
        return status
    }

    /// The `agent-browser` last seen, for closing browsers at quit, which cannot ask where it is.
    private let knownAgentBrowser = OSAllocatedUnfairLock<String?>(initialState: nil)

    private func remember(_ status: BrowserStatus) {
        if let path = status.agentBrowser, path.hasPrefix("/") { knownAgentBrowser.withLock { $0 = path } }
    }

    /// The folder of the Orb's profile (`<navegador>/<orb id>/chrome`, the name the first versions gave it: logins made then stay).
    func profileFolder(botID: UUID) -> URL? {
        profilesDirectory?.appending(path: botID.uuidString).appending(path: "chrome")
    }

    /// Where the Orb keeps the cookies and storage it saved by name (`browse_page state_save`), next to its profile.
    func stateFolder(botID: UUID) -> URL? {
        profilesDirectory?.appending(path: botID.uuidString).appending(path: "estado")
    }

    /// How the Orb's browser is launched for this mode and status.
    func configuration(botID: UUID, mode: BrowserMode, status: BrowserStatus, proxy: String? = nil) -> AgentBrowserConfig {
        remember(status)
        Self.adoptOldProfile(for: botID, in: profilesDirectory)
        var config = AgentBrowserConfig(executable: status.agentBrowser ?? "agent-browser", session: AgentBrowserConfig.sessionName(botID: botID),
                                        browser: status.program, profile: profileFolder(botID: botID), stateDirectory: profilesDirectory)
        config.headed = mode == .visible
        config.visibleByDefault = mode == .visible
        config.proxy = proxy
        return config
    }

    /// An Orb that used CloakBrowser has its logins in `<orb id>/cloak`, an older Chromium profile that Chrome opens as it is: with no
    /// `chrome` folder yet, the folder is renamed to it. The seed file is not needed. If both folders exist the Chrome one wins and the other is left alone.
    static func adoptOldProfile(for botID: UUID, in directory: URL?) {
        guard let orbFolder = directory?.appending(path: botID.uuidString) else { return }
        let fileManager = FileManager.default
        let chrome = orbFolder.appending(path: "chrome"), cloak = orbFolder.appending(path: "cloak")
        if !fileManager.fileExists(atPath: chrome.path), fileManager.fileExists(atPath: cloak.path) {
            try? fileManager.moveItem(at: cloak, to: chrome)
            try? fileManager.removeItem(at: chrome.appending(path: ".cloakbrowser-seed"))
        }
    }

    /// The Orb's browser as one conversation sees it (its own tab). Without a scope, the browser as a whole.
    func session(botID: UUID, mode: BrowserMode, scope: String?) async throws -> BrowserSession {
        let root = try await session(botID: botID, mode: mode)
        guard let scope else { return root }
        return scoped.withLock { views -> BrowserSession in
            if let existing = views[botID]?[scope], existing.base === root {
                return existing
            }
            let view = root.scoped(scope)
            views[botID, default: [:]][scope] = view
            return view
        }
    }

    /// The Orb's browser, started on first use. Throws what is missing when it is not installed.
    func session(botID: UUID, mode: BrowserMode) async throws -> BrowserSession {
        // The profile's caches are being emptied (a moment): the browser opens after, not on top of it.
        while cleaning.withLock({ $0.contains(botID) }) { try await Task.sleep(for: .milliseconds(100)) }
        if let existing = sessions.withLock({ $0[botID] }), existing.mode == mode, existing.proxy == proxy(botID: botID) {
            await settleClosing(botID: botID)
            return existing
        }
        let status = await status()
        guard status.isReady else { throw BrowserDriverError.notInstalled(status.modelNote ?? "The browser is not installed.") }
        // Two calls for the same Orb can both get here (the tools of one turn run at the same time, and the lookup above waited):
        // the check and the installing of the session are one step, so the second finds the first one's and uses it.
        let session = sessions.withLock { sessions -> BrowserSession in
            let wanted = proxy(botID: botID)
            if let existing = sessions[botID], existing.mode == mode, existing.proxy == wanted { return existing }
            let session = BrowserSession(botID: botID, mode: mode, proxy: wanted,
                                         driver: makeDriver(configuration(botID: botID, mode: mode, status: status, proxy: wanted)))
            // Another mode is another browser (a running one keeps the flags it was launched with): the old one is closed (best
            // effort). Both browsers have the same session name, so a call that finds the new session in the meantime must not open
            // a page before that close is done, or the close would take the new browser too (`settleClosing`).
            if let replaced = sessions.updateValue(session, forKey: botID) {
                scheduleClose(botID: botID, driver: replaced.driver)
            }
            return session
        }
        await settleClosing(botID: botID)
        return session
    }

    /// Starts the close of a browser the Orb no longer holds and records it in `closings`, so a call that opens the next one waits for it
    /// (`settleClosing`). A close still going on (a second one right after the first) is waited for, so the closes do not overlap.
    private func scheduleClose(botID: UUID, driver: any BrowserDriver) {
        closings.withLock { closings in
            let before = closings[botID]
            closings[botID] = Task<Void, Never> {
                await before?.value
                try? await driver.close()
            }
        }
    }

    /// Waits for the close of the browser the Orb's session replaced, if one is going on.
    private func settleClosing(botID: UUID) async {
        guard let closing = closings.withLock({ $0[botID] }) else { return }
        await closing.value
        closings.withLock { if $0[botID] == closing { $0[botID] = nil } }
    }

    /// The proxy of the Orb's next browser. The Orb's own setting is copied here when a turn starts and when `browse_proxy` changes it;
    /// a session started with another one is closed by the next `session` call.
    func setProxy(_ proxy: String?, botID: UUID) {
        proxies.withLock { if let proxy { $0[botID] = proxy } else { $0.removeValue(forKey: botID) } }
    }

    func proxy(botID: UUID) -> String? { proxies.withLock { $0[botID] } }

    func existingSession(botID: UUID) -> BrowserSession? { sessions.withLock { $0[botID] } }

    /// A conversation of the Orb is over (a routine's run, a request from another Orb): its tab is closed and its view forgotten.
    func endScope(botID: UUID, scope: String) async {
        scoped.withLock { _ = $0[botID]?.removeValue(forKey: scope) }
        await existingSession(botID: botID)?.endScope(scope)
    }

    // MARK: Labels

    func setLabels(_ refs: [String: BrowserRef], botID: UUID, scope: String? = nil) {
        labels.withLock { $0[LabelKey(botID: botID, scope: scope)] = refs.mapValues { Self.label(of: $0) } }
    }

    /// Forgets the names of one conversation's refs.
    func clearLabels(botID: UUID, scope: String?) { labels.withLock { _ = $0.removeValue(forKey: LabelKey(botID: botID, scope: scope)) } }

    /// Forgets the names of every conversation's refs (the Orb's browser closed).
    func clearLabels(botID: UUID) { labels.withLock { labels in labels = labels.filter { $0.key.botID != botID } } }

    func label(ofRef ref: String, botID: UUID, scope: String? = nil) -> String? { labels.withLock { $0[LabelKey(botID: botID, scope: scope)]?[ref] } }

    private static func label(of ref: BrowserRef) -> String {
        let name = ref.name.split(whereSeparator: \.isWhitespace).joined(separator: " ").clipped(to: 60)
        return name.isEmpty ? ref.role : name
    }

    // MARK: Closing

    // A browser outlives the process that started it: its background process (`agent-browser`) keeps it, and one left by an earlier
    // run of the app is not held here. Sessions are named after the Orb (`AgentBrowserConfig.sessionName`), so
    // everything below that closes a browser closes it by name too: the sessions `agent-browser` reports running that are the Orb's,
    // whoever started them.

    /// The `agent-browser` to ask which sessions run: the one found now.
    private func agentBrowserPath() async -> String? { await status().agentBrowser }

    /// The same when nothing can be awaited (the app is quitting): the last one seen, or the one the app installed, or one in the
    /// usual places of a Mac (the login shell's PATH cannot be asked now).
    private func agentBrowserPathNow() -> String? {
        if let known = knownAgentBrowser.withLock({ $0 }) { return known }
        return BrowserLocator.live(path: nil, managedRoot: profilesDirectory).agentBrowser()
    }

    /// A driver for a session by name, to ask or close it.
    private func driver(forSession name: String, executable: String) -> any BrowserDriver {
        makeDriver(AgentBrowserConfig(executable: executable, session: name, stateDirectory: profilesDirectory))
    }

    /// The Orb's sessions running now (`orb-<id>-chrome`) that `matches`, whoever started them.
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

    /// Closes the browser this hub holds for the Orb (and forgets it); the session it held, if any.
    private func closeHeld(botID: UUID) async -> BrowserSession? {
        // Leaving `sessions` and being recorded in `closings` is one step: a `session` call in between would open a browser with the
        // same name that this close then takes.
        let held = sessions.withLock { sessions -> BrowserSession? in
            let held = sessions.removeValue(forKey: botID)
            if let held { scheduleClose(botID: botID, driver: held.driver) }
            return held
        }
        if held != nil { await settleClosing(botID: botID) }
        return held
    }

    private static func name(of session: BrowserSession) -> String { AgentBrowserConfig.sessionName(botID: session.botID) }

    /// Closes the Orb's browser, whoever started it (and forgets it). The profile stays: logins survive.
    /// True when one was open.
    @discardableResult
    func close(botID: UUID) async -> Bool {
        clearLabels(botID: botID)
        let held = await closeHeld(botID: botID)
        let prefix = AgentBrowserConfig.botPrefix(botID)
        let others = await closeRunning(where: { $0.hasPrefix(prefix) }, skipping: held.map { [Self.name(of: $0)] } ?? [])
        return held != nil || others
    }

    /// Empties the caches of the Orb's profile when a week has passed since the last time (see `BrowserProfileCache`): logins, cookies
    /// and storage stay. Never while the Orb's browser is running: not held here, no session of the Orb in agent-browser's list,
    /// and no browser holding the profile's own lock (`BrowserProfileCache.isInUse`). Returns the bytes freed.
    @discardableResult
    func cleanCachesIfDue(botID: UUID, worth: Int64 = BrowserProfileCache.worthIt) async -> Int64 {
        guard let profile = profileFolder(botID: botID), BrowserProfileCache.due(profile: profile),
              existingSession(botID: botID) == nil else { return 0 }
        if let executable = await agentBrowserPath() {
            let prefix = AgentBrowserConfig.botPrefix(botID)
            guard await runningSessions(executable: executable, where: { $0.hasPrefix(prefix) }).isEmpty else { return 0 }
        }
        // The browser may have been opened while the question was asked; from here until the end, none opens (`session` waits).
        let started = cleaning.withLock { $0.insert(botID).inserted }
        guard started else { return 0 }
        defer { cleaning.withLock { _ = $0.remove(botID) } }
        guard existingSession(botID: botID) == nil else { return 0 }
        return BrowserProfileCache.cleanIfDue(profile: profile, worth: worth)
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
