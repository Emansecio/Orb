import Foundation

/// `browse_proxy`: the Orb decides where its browser's traffic goes (a local SOCKS port of a VPN client it runs, a proxy service) and
/// the app does the rest: reopens the browser with `--proxy` keeping the profile and the logins, proves it by reading the address the
/// web sees, and keeps the choice for the Orb. Starting the tunnel itself is the Orb's work; the app manages none.
struct BrowseProxyTool: BrowseTool {
    let spec = ToolSpec(
        name: "browse_proxy",
        description: """
        Where your browser's traffic goes. `set` with `proxy` (socks5://127.0.0.1:1080, http://host:port) reopens the browser \
        through it (logins stay), returns the address sites see, and keeps it for you; `clear` goes direct; `status` shows it. \
        Start the tunnel yourself first. Tell the user what you set.
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

    /// Reopens the browser with the new proxy and reads the address from the web; with a proxy that does not work, goes back to the
    /// one it had and says so.
    private func apply(_ proxy: String?, replacing old: String?, hub: BrowserHub, botID: UUID, context: ToolContext) async throws -> String {
        let before = hub.existingSession(botID: botID)
        let returnTo = before == nil ? nil : (try? await before?.driver.currentURL()).flatMap { $0 }
        hub.setProxy(proxy, botID: botID)
        let session = try await hub.session(botID: botID, mode: context.browser.mode)
        let address: String
        do {
            address = try await session.exclusive {
                _ = try await session.driver.open(BrowserProxy.ipCheckURL)
                let readout = try await session.driver.read()
                guard let found = BrowserProxy.address(in: readout.content) else {
                    throw ToolError("the page that tells the exit address answered with something else: “\(readout.content.clipped(to: 120))”")
                }
                return found
            }
        } catch {
            hub.setProxy(old, botID: botID)
            let restored = try? await hub.session(botID: botID, mode: context.browser.mode)
            restored?.forgetPage()
            if let restored, let returnTo { _ = try? await restored.driver.open(returnTo) }
            let why = (error as? ToolError)?.message ?? error.localizedDescription
            throw ToolError("The browser could not load pages through \(proxy.map(BrowserProxy.display) ?? "a direct connection"): \(why). "
                + "It is back to \(old.map(BrowserProxy.display) ?? "direct"). Check that the tunnel or proxy is up, then try again.")
        }
        session.forgetPage()
        if let returnTo, returnTo.hasPrefix("http") { _ = try? await session.driver.open(returnTo) }
        await context.browser.saveProxy?(proxy)
        let route = proxy.map { "goes through \(BrowserProxy.display($0))" } ?? "goes direct again"
        return "Your browser \(route). Sites see the address \(address). Logins and cookies stayed. "
            + (returnTo.map { "Reopened \($0). " } ?? "") + "Tell the user what you set and the address."
    }
}
