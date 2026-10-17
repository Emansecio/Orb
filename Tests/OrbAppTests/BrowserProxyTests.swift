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

    @Test func theLaunchCarriesTheProxyInItsEnvironmentAndTheFingerprintOnlyAHashOfIt() {
        var config = AgentBrowserConfig(executable: "/x/agent-browser", session: "orb-1-chrome")
        let direct = config.launchFingerprint
        #expect(config.extraEnvironment[AgentBrowserConfig.proxyVariable] == nil)
        config.proxy = "socks5://u:s3cretpw@127.0.0.1:1080"
        // Not an argument (the list of processes shows those) and not in the file the fingerprint is written to.
        #expect(!config.launchArguments.contains { $0.contains("1080") || $0 == "--proxy" })
        #expect(config.extraEnvironment[AgentBrowserConfig.proxyVariable] == "socks5://u:s3cretpw@127.0.0.1:1080")
        #expect(config.environment(base: ["AGENT_BROWSER_PROXY": "http://evil:1"])[AgentBrowserConfig.proxyVariable] == config.proxy)
        #expect(config.launchFingerprint != direct && !config.launchFingerprint.contains("s3cretpw") && !config.launchFingerprint.contains("1080"))
        let other = { var copy = config; copy.proxy = "socks5://u:other@127.0.0.1:1080"; return copy.launchFingerprint }()
        #expect(other != config.launchFingerprint)
    }

    @Test func thePasswordIsSplitOffForTheKeychainAndPutBack() {
        let (address, password) = BrowserProxy.split("http://user:p%40ss@host.test:3128")
        #expect(address == "http://user@host.test:3128" && password == "p%40ss")
        #expect(BrowserProxy.joined(address, password: password) == "http://user:p%40ss@host.test:3128")
        #expect(BrowserProxy.split("socks5://127.0.0.1:1080") == ("socks5://127.0.0.1:1080", nil))
        #expect(BrowserProxy.joined("socks5://127.0.0.1:1080", password: "x") == "socks5://127.0.0.1:1080")
        #expect(BrowserProxy.joined(address, password: nil) == address)
        #expect(BrowserProxy.hasUser(address) && !BrowserProxy.hasUser("socks5://127.0.0.1:1080") && !BrowserProxy.hasUser(nil))
        let said = BrowserProxy.redacting("proxy http://user:p%40ss@host.test:3128 refused p@ss and p%40ss", proxy: "http://user:p%40ss@host.test:3128")
        #expect(!said.contains("p%40ss") && !said.contains("p@ss") && said.contains("host.test:3128"))
    }

    @Test func theBrowserWordsNeverCarryThePassword() async throws {
        setup.hub.setProxy("http://u:s3cretpw@h.test:80", botID: setup.botID)
        setup.driver.state.withLock { $0.readContent = "407 for http://u:s3cretpw@h.test:80 (s3cretpw)" }
        let message: String
        do { message = try await run(["action": .string("set"), "proxy": .string("http://u:0therpw@h.test:81")]) } catch { message = error.localizedDescription }
        #expect(message.contains("could not load pages") && !message.contains("0therpw") && !message.contains("s3cretpw"))
        let driver = AgentBrowserDriver(config: AgentBrowserConfig(executable: "/x/agent-browser", session: "orb-1-chrome", proxy: "http://u:s3cretpw@h.test:80"),
                                        environment: { [:] }, run: { _, _, _, _ in
            ProcessOutput(status: 1, output: #"{"success":false,"error":"proxy http://u:s3cretpw@h.test:80 said no"}"#, timedOut: false)
        })
        do {
            _ = try await driver.send(["get", "title"], needsSession: false)
            Issue.record("the command should fail")
        } catch {
            #expect(!error.localizedDescription.contains("s3cretpw") && error.localizedDescription.contains("h.test:80"))
        }
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

    @Test func theOtherConversationsGetTheirPagesBackThroughTheProxy() async throws {
        let labelB = TabBook.label(for: "chat-B")
        for scope in ["chat-A", "chat-B"] {
            var context = context()
            context.browser.scope = scope
            _ = try await BrowseScrollTool().run(.object([:]), context: context)
        }
        setup.driver.state.withLock {
            $0.readContent = "203.0.113.7"
            $0.url = "https://b.test/cart"
            $0.tabs = [BrowserTab(id: "t1", title: "A", url: "https://a.test/inbox", isActive: false),
                       BrowserTab(id: "t2", title: "B", url: "https://b.test/cart", isActive: true, label: labelB)]
        }
        var context = context()
        context.browser.scope = "chat-B"
        let text = try await BrowseProxyTool().run(.object(["action": .string("set"), "proxy": .string("socks5://127.0.0.1:1080")]), context: context)
        #expect(text.contains("Reopened https://b.test/cart"))
        let calls = setup.driver.calls
        let check = try #require(calls.firstIndex(of: "open \(BrowserProxy.ipCheckURL)"))
        #expect(Array(calls.dropFirst(check)).filter { $0.hasPrefix("open") || $0.hasPrefix("command tab") }
                == ["open \(BrowserProxy.ipCheckURL)", "open https://b.test/cart",
                    "command tab new --label \(TabBook.label(for: "chat-A")) https://a.test/inbox", "command tab t1"])
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

    @Test @MainActor func thePasswordOfTheProxyGoesToTheKeychainNotToTheFile() async throws {
        let (model, botID) = model()
        let vault = try #require(model.secretVault as? MemoryVault)
        let setup = FakeBrowserSetup()
        model.browserHub = setup.hub
        let account = BrowserProxy.keychainAccount(botID: botID)
        // What `browse_proxy` saves: the browser already goes through it (the hub has it, password and all).
        setup.hub.setProxy("http://u:s3cretpw@h.test:8080", botID: botID)
        model.saveBrowserProxy("http://u:s3cretpw@h.test:8080", for: botID)
        let bot = try #require(model.bot(botID))
        #expect(bot.browserProxy == "http://u@h.test:8080" && vault.get(account) == "s3cretpw")
        #expect(!String(decoding: try JSONEncoder().encode(model.bots), as: UTF8.self).contains("s3cretpw"))
        #expect(AppModel.browserProxy(of: bot, vault: vault) == "http://u:s3cretpw@h.test:8080")
        // The browser that went through it is not closed by saving it.
        try await Task.sleep(for: .milliseconds(200))
        #expect(!setup.driver.calls.contains("close"))
        // Removing it removes the password too; one with no user never touches the Keychain.
        model.removeBrowserProxy(for: botID)
        #expect(vault.get(account) == nil && model.bot(botID)?.browserProxy == nil)
        model.saveBrowserProxy("socks5://127.0.0.1:1080", for: botID)
        #expect(vault.accounts.isEmpty && model.bot(botID)?.browserProxy == "socks5://127.0.0.1:1080")
        // The reset takes the password of a proxy that names a user.
        var withUser = bot
        withUser.browserProxy = "http://u@h.test:8080"
        let plan = ResetPlan.make(bots: [withUser], connectors: [], providers: [], defaultModel: "", learnedContexts: [:],
                                  options: ResetOptions(memories: .keep, leavesProviders: false))
        #expect(plan.secretAccounts == [account])
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
