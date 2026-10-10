import Foundation

// What the `browse_*` tools need from a browser, independent of how it is driven. `AgentBrowserDriver` is the real one
// (the `agent-browser` command line); tests use a fake.

/// An element of the last snapshot, by its ref (`e5`).
struct BrowserRef: Sendable, Equatable {
    var role: String
    var name: String
}

struct BrowserPage: Sendable, Equatable {
    var url: String
    var title: String
}

/// An accessibility snapshot: the tree as text (one line per element, `- button "Entrar" [ref=e3]`) and the refs in it.
struct BrowserSnapshot: Sendable, Equatable {
    var url: String
    var tree: String
    var refs: [String: BrowserRef]
}

struct BrowserTab: Sendable, Equatable {
    var id: String
    var title: String
    var url: String
    var isActive: Bool
}

/// The readable text of the page the browser has open.
struct BrowserReadout: Sendable, Equatable {
    var url: String
    var content: String
}

enum BrowserScrollDirection: String, CaseIterable, Sendable {
    case up, down, left, right
}

enum BrowserDriverError: LocalizedError, Equatable {
    /// `agent-browser` (or a browser it needs) is not there.
    case notInstalled(String)
    /// There is no page open in the session (never opened, or it was closed or timed out).
    case noPage
    case timedOut(String)
    /// The browser answered with an error; its own words.
    case failed(String)
    /// The engine cannot do this (a window in Obscura).
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let message): message
        case .noPage: "No page is open in the browser: call browse_open with an address first."
        case .timedOut(let what): "The browser did not answer in time (\(what)). The page may be heavy or stuck; try browse_close and open it again."
        case .failed(let message): message
        case .unsupported(let message): message
        }
    }
}

protocol BrowserDriver: Sendable {
    /// Opens the address in the current tab (launching the browser if it is not running) and waits for the page to load.
    func open(_ url: String) async throws -> BrowserPage
    /// `interactive`: only links, buttons and fields (the default view). `selector`: a CSS selector to scope to.
    func snapshot(interactive: Bool, selector: String?) async throws -> BrowserSnapshot
    func click(_ ref: String) async throws
    func fill(_ ref: String, text: String) async throws
    func select(_ ref: String, value: String) async throws
    func press(_ key: String) async throws
    func scroll(_ direction: BrowserScrollDirection, pixels: Int) async throws
    func read() async throws -> BrowserReadout
    /// Saves a PNG of the viewport at `file`.
    func screenshot(to file: URL) async throws
    func back() async throws -> BrowserPage
    func tabs() async throws -> [BrowserTab]
    func newTab(_ url: String?) async throws
    func selectTab(_ id: String) async throws
    func closeTab(_ id: String?) async throws
    /// An attribute of an element (`type` of an input); nil when it has none or the browser cannot say.
    func attribute(_ name: String, of ref: String) async throws -> String?
    /// The result of a script in the page, as text.
    func evaluate(_ script: String) async throws -> String
    /// The address of the current page, nil when none is open.
    func currentURL() async throws -> String?
    /// Reopens the session at the same address with a visible window (`true`) or without one (`false`), keeping the
    /// profile (logins). The page is loaded again; what was typed and not sent is lost.
    func setHeaded(_ headed: Bool) async throws -> BrowserPage
    func close() async throws
}
