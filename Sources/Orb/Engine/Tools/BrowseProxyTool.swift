import Foundation

/// `browse_proxy`: the Orb decides where its browser's traffic goes (a local SOCKS port of a VPN client it runs, a proxy service) and
/// the app does the rest: reopens the browser through it (`AGENT_BROWSER_PROXY`) keeping the profile and the logins, proves it by reading the address the
/// web sees, and keeps the choice for the Orb. Starting the tunnel itself is the Orb's work; the app manages none.
struct BrowseProxyTool: BrowseTool {
    let spec = ToolSpec(
        name: "browse_proxy",
        description: """
        Where your browser's traffic goes, for a site that blocks your address: `set` a `proxy` (socks5://127.0.0.1:1080, \
        http://host:port) reopens the browser through it (logins stay), says the address sites see and keeps it; `clear` goes \
        direct; `status` shows it. Start the tunnel first; tell the user what you set.
        """,
        parameters: .schema(["action": BrowseSupport.choice(["status", "set", "clear"]), "proxy": .property("string")]))

    private func action(_ arguments: JSONValue) -> String { arguments.nonEmptyString("action")?.lowercased() ?? "status" }

    func risk(_ arguments: JSONValue) -> ToolRisk { action(arguments) == "status" ? .safe : .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        switch action(arguments) {
        case "set": ("Trocando o proxy do navegador", BrowserProxy.display(arguments["proxy"]?.string ?? ""))
        case "clear": ("Tirando o proxy do navegador", "")
        default: ("Vendo o proxy do navegador", "")
        }
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard context.browser.drivesABrowser, let hub = context.browser.hub, let botID = context.botID else {
            throw ToolError("The Orb's browser is not available here.")
        }
        let current = hub.proxy(botID: botID)
        switch action(arguments) {
        case "status":
            return current.map { "Your browser goes through \(BrowserProxy.display($0))." } ?? "Your browser goes direct (no proxy)."
        case "set":
            let proxy = try BrowserProxy.normalized(try arguments.requiredString("proxy")).get()
            return try await apply(proxy, replacing: current, hub: hub, botID: botID, context: context)
        case "clear":
            guard current != nil else { return "Your browser already goes direct (no proxy)." }
            return try await apply(nil, replacing: current, hub: hub, botID: botID, context: context)
        default:
            throw ToolError("`action` is status, set or clear.")
        }
    }

    /// The longest the page that tells the exit address is waited for: a proxy that swallows the connection fails here, not after
    /// the browser's own timeouts.
    static let checkTimeout: TimeInterval = 40

    /// Reopens the browser with the new proxy and reads the address from the web; with a proxy that does not work, goes back to the
    /// one it had and says so. Every page is opened and read under the browser's lock, in this conversation's tab.
    private func apply(_ proxy: String?, replacing old: String?, hub: BrowserHub, botID: UUID, context: ToolContext) async throws -> String {
        let scope = context.browser.scope, mode = context.browser.mode
        let (returnTo, others) = await Self.openPages(hub: hub, botID: botID, mode: mode, scope: scope)
        hub.setProxy(proxy, botID: botID)
        let address: String
        do {
            let session = try await hub.session(botID: botID, mode: mode, scope: scope)
            address = try await withDeadline(Self.checkTimeout, "the page that tells the exit address") {
                try await session.exclusive {
                    session.forgetPage()
                    _ = try await session.driver.open(BrowserProxy.ipCheckURL)
                    let readout = try await session.driver.read()
                    guard let found = BrowserProxy.address(in: readout.content) else {
                        throw ToolError("the page that tells the exit address answered with something else: “\(readout.content.clipped(to: 120))”")
                    }
                    return found
                }
            }
        } catch {
            hub.setProxy(old, botID: botID)
            if let restored = try? await hub.session(botID: botID, mode: mode, scope: scope) {
                await Self.reopen(returnTo, others: others, in: restored)
            }
            if error is CancellationError { throw error }
            let why = error is DeadlineExceeded ? "it did not answer in \(Int(Self.checkTimeout)) s"
                : (error as? ToolError)?.message ?? error.localizedDescription
            throw ToolError("The browser could not load pages through \(proxy.map(BrowserProxy.display) ?? "a direct connection"): "
                + "\(BrowserProxy.redacting(BrowserProxy.redacting(why, proxy: proxy), proxy: old)). It is back to \(old.map(BrowserProxy.display) ?? "direct"). "
                + "Check that the tunnel or proxy is up, then try again.")
        }
        await Self.reopen(returnTo, others: others, in: try await hub.session(botID: botID, mode: mode, scope: scope))
        await context.browser.saveProxy?(proxy)
        let route = proxy.map { "goes through \(BrowserProxy.display($0))" } ?? "goes direct again"
        return "Your browser \(route). Sites see the address \(address). Logins and cookies stayed. "
            + (returnTo.map { "Reopened \($0). " } ?? "") + "Tell the user what you set and the address."
    }

    /// The page this conversation had open, read in its own tab, and the pages of the Orb's other conversations, which the browser
    /// that opens through the proxy gives back to them (nil and none: no browser running).
    private static func openPages(hub: BrowserHub, botID: UUID, mode: BrowserMode, scope: String?) async
        -> (mine: String?, others: [(scope: String, url: String)]) {
        guard hub.existingSession(botID: botID) != nil, let session = try? await hub.session(botID: botID, mode: mode, scope: scope),
              let found = try? await session.exclusive({ (try await session.driver.currentURL(), await session.pagesOfOtherConversations()) })
        else { return (nil, []) }
        return (found.0.flatMap { $0.hasPrefix("http") ? $0 : nil }, found.1)
    }

    /// This conversation's page again in the browser that just started (its first tab), and the other conversations' in tabs of
    /// their own.
    private static func reopen(_ page: String?, others: [(scope: String, url: String)], in session: BrowserSession) async {
        session.forgetPage()
        _ = try? await session.exclusive {
            if let page { _ = try? await session.driver.open(page) }
            await session.restoreTabs(others)
        }
    }
}
