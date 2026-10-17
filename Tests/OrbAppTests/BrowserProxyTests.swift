import Foundation
import Testing
@testable import Orb

/// `browse_proxy`: the address the Orb picks, how the browser is reopened through it and what is kept.
struct BrowserProxyTests {
    private let setup = FakeBrowserSetup()
    private let saved = SavedProxy()

    final class SavedProxy: @unchecked Sendable {
        let values = NSLock()
        private var list: [String?] = []
        func add(_ proxy: String?) { values.withLock { list.append(proxy) } }
        var all: [String?] { values.withLock { list } }
    }

    private func context() -> ToolContext {
        var context = setup.context()
        let saved = saved
        context.browser.saveProxy = { saved.add($0) }
        return context
    }

    private func run(_ arguments: [String: JSONValue]) async throws -> String {
        try await BrowseProxyTool().run(.object(arguments), context: context())
    }

    // MARK: The address

    @Test func theAddressIsNormalizedOrRefusedWithTheExpectedShape() throws {
        #expect(try BrowserProxy.normalized("socks5://127.0.0.1:1080").get() == "socks5://127.0.0.1:1080")
        #expect(try BrowserProxy.normalized("  HTTP://Proxy.Example:8080/ ").get() == "http://Proxy.Example:8080")
        #expect(try BrowserProxy.normalized("http://user:p%40ss@host.test:3128").get() == "http://user:p%40ss@host.test:3128")
        for bad in ["", "127.0.0.1:1080", "ftp://x.test:21", "socks5://127.0.0.1", "socks5://:1080", "socks5://h:99999", "http://h:80/path",
                    "http://h:80?x=1", "socks5://a b:1", "--proxy", "file:///etc/passwd"] {
            #expect(throws: ToolError.self, "\(bad)") { try BrowserProxy.normalized(bad).get() }
        }
    }

    @Test func thePasswordNeverShowsAndAnAddressIsRecognized() {
        #expect(BrowserProxy.display("http://user:secret@host.test:3128") == "http://user:•••@host.test:3128")
        #expect(BrowserProxy.display("socks5://127.0.0.1:1080") == "socks5://127.0.0.1:1080")
        #expect(BrowserProxy.address(in: " 203.0.113.7\n") == "203.0.113.7")
        #expect(BrowserProxy.address(in: "2001:db8::1") == "2001:db8::1")
        #expect(BrowserProxy.address(in: "<html>Blocked</html>") == nil && BrowserProxy.address(in: "") == nil && BrowserProxy.address(in: "12") == nil)
    }

    @Test func theLaunchCarriesTheProxyAndItChangesTheFingerprint() {
        var config = AgentBrowserConfig(executable: "/x/agent-browser", session: "orb-1-chrome")
        let direct = config.launchFingerprint
        #expect(!config.launchArguments.contains("--proxy"))
        config.proxy = "socks5://127.0.0.1:1080"
        #expect(config.launchArguments.suffix(2) == ["--proxy", "socks5://127.0.0.1:1080"])
        #expect(config.launchFingerprint != direct)
    }

    // MARK: The tool

    @Test func statusSaysWhereTheBrowserGoesAndIsSafe() async throws {
        #expect(BrowseProxyTool().risk(.object([:])) == .safe)
        #expect(BrowseProxyTool().risk(.object(["action": .string("set")])) == .sensitive)
        #expect(BrowseProxyTool().risk(.object(["action": .string("clear")])) == .sensitive)
        #expect(try await run([:]).contains("direct"))
        setup.hub.setProxy("http://u:pw@h.test:80", botID: setup.botID)
        let text = try await run(["action": .string("status")])
        #expect(text.contains("http://u:•••@h.test:80") && !text.contains("pw@"))
    }

    @Test func setReopensThroughTheProxyReadsTheAddressAndKeepsIt() async throws {
        setup.driver.state.withLock { $0.readContent = "203.0.113.7" }
        let text = try await run(["action": .string("set"), "proxy": .string("socks5://127.0.0.1:1080")])
        #expect(text.contains("203.0.113.7") && text.contains("socks5://127.0.0.1:1080") && text.contains("Tell the user"))
        #expect(setup.driver.calls.contains("open \(BrowserProxy.ipCheckURL)"))
        #expect(saved.all == ["socks5://127.0.0.1:1080"])
        #expect(setup.hub.proxy(botID: setup.botID) == "socks5://127.0.0.1:1080")
        #expect(setup.configs.withLock { $0.last?.proxy } == "socks5://127.0.0.1:1080")
        // The next call of any tool keeps the same browser.
        let again = try await setup.hub.session(botID: setup.botID, mode: .background)
        #expect(again.proxy == "socks5://127.0.0.1:1080")
        #expect(setup.configs.withLock { $0.count } == 1)
    }

    @Test func setComesBackToThePageThatWasOpen() async throws {
        setup.driver.state.withLock { $0.readContent = "203.0.113.7"; $0.url = "https://site.test/cart" }
        _ = try await setup.hub.session(botID: setup.botID, mode: .background)
        let text = try await run(["action": .string("set"), "proxy": .string("socks5://127.0.0.1:1080")])
        #expect(text.contains("Reopened https://site.test/cart"))
    }

    @Test func aProxyThatDoesNotWorkIsUndoneAndSaysWhy() async throws {
        setup.hub.setProxy("socks5://127.0.0.1:1111", botID: setup.botID)
        setup.driver.state.withLock { $0.readContent = "<html>no route</html>" }
        let message: String
        do { message = try await run(["action": .string("set"), "proxy": .string("socks5://127.0.0.1:1080")]) } catch { message = error.localizedDescription }
        #expect(message.contains("could not load pages") && message.contains("back to socks5://127.0.0.1:1111"))
        #expect(setup.hub.proxy(botID: setup.botID) == "socks5://127.0.0.1:1111")
        #expect(saved.all.isEmpty)
    }

    @Test func clearGoesDirectAndAlreadyDirectDoesNothing() async throws {
        #expect(try await run(["action": .string("clear")]).contains("already goes direct"))
        #expect(setup.driver.calls.isEmpty)
        setup.hub.setProxy("socks5://127.0.0.1:1080", botID: setup.botID)
        setup.driver.state.withLock { $0.readContent = "198.51.100.2" }
        let text = try await run(["action": .string("clear")])
        #expect(text.contains("direct again") && text.contains("198.51.100.2"))
        #expect(saved.all == [nil] && setup.hub.proxy(botID: setup.botID) == nil)
    }

    @Test func anAddressThatIsNotAProxyIsRefusedBeforeAnythingOpens() async {
        let message: String
        do { message = try await run(["action": .string("set"), "proxy": .string("not a proxy")]) } catch { message = error.localizedDescription }
        #expect(message.contains("`proxy` is an address"))
        #expect(setup.driver.calls.isEmpty)
    }

    @Test func theToolAsksLikeTheOtherPageTools() {
        #expect(PermissionPolicy.family(ofTool: "browse_proxy", kind: .browser) == .browserPage)
        #expect(ToolBox.browseToolNames.contains("browse_proxy"))
    }

    // MARK: What is kept

    @Test func anOrbKeepsItsProxyAndOneSavedBeforeHasNone() throws {
        var bot = Bot(name: "A", role: "", orb: OrbConfig())
        #expect(bot.browserProxy == nil)
        bot.browserProxy = "socks5://127.0.0.1:1080"
        let back = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot))
        #expect(back.browserProxy == "socks5://127.0.0.1:1080")
        let old = try JSONDecoder().decode(Bot.self, from: Data(#"{"id":"\#(UUID())","name":"A","browserProxy":7}"#.utf8))
        #expect(old.browserProxy == nil)
    }
}

@Suite final class BrowserProxyModelTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbProxy-\(UUID().uuidString)")
    deinit { removeTestFolder(root) }

    @MainActor private func model() -> (AppModel, UUID) {
        var state = AppState.initial
        state.bots[0].browserProxy = "socks5://127.0.0.1:1080"
        Store(directory: root).save(state)
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false, secretVault: MemoryVault())
        return (model, model.bots[0].id)
    }

    @Test @MainActor func removingTheProxyClosesTheBrowserAndGoesDirect() async throws {
        let (model, botID) = model()
        let setup = FakeBrowserSetup()
        model.browserHub = setup.hub
        setup.hub.setProxy("socks5://127.0.0.1:1080", botID: botID)
        _ = try await setup.hub.session(botID: botID, mode: .background)
        #expect(model.bot(botID)?.browserProxy == "socks5://127.0.0.1:1080")

        model.removeBrowserProxy(for: botID)
        #expect(model.bot(botID)?.browserProxy == nil)
        #expect(setup.hub.proxy(botID: botID) == nil)
        await waitUntil("the browser to close") { setup.driver.calls.contains("close") }
    }

    @Test @MainActor func theOrbSettingAfterTheToolChangedItDoesNotCloseTheNewBrowser() async throws {
        let (model, botID) = model()
        let setup = FakeBrowserSetup()
        model.browserHub = setup.hub
        // `browse_proxy` already reopened the browser through the new proxy: the hub has it before the Orb's setting is saved.
        setup.hub.setProxy("http://h.test:8080", botID: botID)
        model.update(botID) { $0.browserProxy = "http://h.test:8080" }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!setup.driver.calls.contains("close"))
        #expect(model.bot(botID)?.browserProxy == "http://h.test:8080")
    }
}
