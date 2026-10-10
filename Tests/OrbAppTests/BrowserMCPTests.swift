import Foundation
import Testing
@testable import Orb

// Claude Code gets the Orb's browser through the Orb's own tools server (`OrbToolsMCPServer`): which tools it lists per
// configuration, how the app tells the server what it needs, and how the permission rules reach those tools.

private let webSearch = ["web_search"]
private let browse = ToolBox.browseTools.map(\.spec.name)
private let prefix = ClaudeCodeTools.memoryPrefix

struct BrowserMCPToolListTests {
    private func names(mac: Bool = false, files: Bool = false, _ browser: BrowserAvailability) -> [String] {
        OrbToolsMCPServer.tools(mac: mac, files: files, browser: browser).map(\.spec.name)
    }

    @Test func theWebToolsComeWithNavegarNaWebAndTheBrowserToolsOnlyWithAnInstalledEngine() {
        let off = names(.off)
        #expect(Set(off).isDisjoint(with: webSearch + browse))
        #expect(names(.fetchOnly) == off + webSearch, "web_search alone: the simple engine, or one that is not installed")
        #expect(names(.browser) == off + webSearch + browse, "web_search, then the 13 browse_* tools, after memory and the Mac tools")
        #expect(browse.count == 13)
        // The Mac tools do not move them: the order is memory, schedule, Mac, web.
        let all = names(mac: true, files: true, .browser)
        #expect(all.prefix(ToolBox.memoryTools.count) == ToolBox.memoryTools.map(\.spec.name)[...])
        #expect(Array(all.suffix(webSearch.count + browse.count)) == webSearch + browse)
    }

    @Test func nothingChangesForAnOrbWithoutTheWebTools() {
        // The default is the list the server always had.
        #expect(OrbToolsMCPServer.tools(mac: true).map(\.spec.name) == OrbToolsMCPServer.tools(mac: true, browser: .off).map(\.spec.name))
        #expect(OrbToolsMCPServer.listedTools(mac: false, accessibilityGranted: true).map(\.spec.name)
                == OrbToolsMCPServer.listedTools(mac: false, accessibilityGranted: true, browser: .off).map(\.spec.name))
    }

    @Test func theListOverTheWireHasThemAndMarksTheOnesThatOnlyLookAsReadOnly() async throws {
        let setup = FakeBrowserSetup()
        let request = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/list")])
        let reply = try #require(await OrbToolsMCPServer.handle(request, context: setup.context(), browser: .browser))
        let tools = try #require(reply["result"]?["tools"]?.array)
        func hint(_ name: String) -> Bool? { tools.first { $0["name"]?.string == name }?["annotations"]?["readOnlyHint"]?.bool }
        #expect(hint("browse_snapshot") == true && hint("browse_read") == true && hint("browse_close") == true)
        #expect(hint("browse_click") == false && hint("browse_fill") == false && hint("browse_show") == false)
        #expect(hint("web_search") == false, "the query leaves the Mac")
        // Without the engine none of the browse_* tools is there.
        let plain = try #require(await OrbToolsMCPServer.handle(request, context: setup.context(), browser: .fetchOnly))
        let plainNames = (plain["result"]?["tools"]?.array ?? []).compactMap { $0["name"]?.string }
        #expect(plainNames.contains("web_search") && plainNames.allSatisfy { !$0.hasPrefix("browse_") })
    }

    @Test func aBrowserToolRunsInTheServerOnlyWhenItIsOffered() async throws {
        let setup = FakeBrowserSetup()
        let call = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("tools/call"),
                                     "params": .object(["name": .string("browse_close"), "arguments": .object([:])])])
        let served = try #require(await OrbToolsMCPServer.handle(call, context: setup.context(), browser: .browser))
        #expect(served["result"]?["isError"]?.bool == false)
        #expect(served["result"]?["content"]?.array?.first?["text"]?.string == "The browser was not open.")
        let refused = try #require(await OrbToolsMCPServer.handle(call, context: setup.context(), browser: .fetchOnly))
        #expect(refused["error"] != nil || refused["result"]?["isError"]?.bool == true)
    }
}

struct BrowserMCPConfigTests {
    private let directory = URL(fileURLWithPath: "/tmp/memoria")
    private let profiles = URL(fileURLWithPath: "/tmp/dados/navegador")
    private let orb = UUID()

    @Test func anOrbWithoutTheWebToolsKeepsTheOldCommandLine() {
        #expect(OrbToolsMCPServer.config(directory: directory).arguments == ["--tools-mcp", "/tmp/memoria"])
        let off = OrbToolsMCPServer.config(directory: directory, browser: .off, engine: .chrome, searchProvider: .google, tinyFishKey: "k")
        #expect(off.arguments == ["--tools-mcp", "/tmp/memoria"] && off.environment.isEmpty)
    }

    @Test func theEngineTheProviderAndTheProfilesFolderTravelInTheFlags() throws {
        let config = OrbToolsMCPServer.config(directory: directory, orb: orb, browser: .browser, engine: .cloak, searchProvider: .google,
                                              browserProfiles: profiles)
        #expect(config.arguments.suffix(6) == ["--browser", "cloak", "--search", "google", "--browser-profiles", "/tmp/dados/navegador"])
        let options = try #require(OrbToolsMCPServer.Options(arguments: config.arguments, environment: [:]))
        #expect(options.browser == .browser && options.browserEngine == .cloak && options.searchProvider == .google)
        #expect(options.browserProfiles == profiles && options.orb == nil, "the Orb id comes with the schedule mailbox")
        // The same configuration is the same arguments every time.
        let again = OrbToolsMCPServer.config(directory: directory, orb: orb, browser: .browser, engine: .cloak, searchProvider: .google,
                                             browserProfiles: profiles)
        #expect(again.arguments == config.arguments && again.environment == config.environment)
    }

    @Test func withoutAnEngineReadyOnlyTheSearchIsServed() throws {
        let config = OrbToolsMCPServer.config(directory: directory, browser: .fetchOnly, engine: .chrome, searchProvider: .duckduckgo,
                                              browserProfiles: profiles)
        #expect(config.arguments.contains("--web") && !config.arguments.contains("--browser") && !config.arguments.contains("--browser-profiles"))
        let options = try #require(OrbToolsMCPServer.Options(arguments: config.arguments, environment: [:]))
        #expect(options.browser == .fetchOnly && options.browserEngine == .simple && options.web)
        #expect(options.context.browser.hub != nil && !options.context.browser.drivesABrowser)
    }

    @Test func anEngineTheServerDoesNotKnowIsTheSimpleOne() throws {
        let options = try #require(OrbToolsMCPServer.Options(arguments: ["Orb", "--tools-mcp", "/tmp/m", "--browser", "firefox", "--search", "bing"], environment: [:]))
        #expect(options.browserEngine == .simple && options.searchProvider == .duckduckgo && options.browser == .off)
    }

    @Test func theTinyFishKeyRidesInTheEnvironmentNeverOnTheCommandLine() throws {
        let config = OrbToolsMCPServer.config(directory: directory, browser: .browser, engine: .chrome, searchProvider: .tinyfish, tinyFishKey: "tf-secret")
        #expect(config.environment == [OrbToolsMCPServer.tinyFishKeyVariable: "tf-secret"])
        #expect(!config.arguments.joined(separator: " ").contains("tf-secret"))
        // Another provider gets no key, even when the app has one.
        let google = OrbToolsMCPServer.config(directory: directory, browser: .browser, engine: .chrome, searchProvider: .google, tinyFishKey: "tf-secret")
        #expect(google.environment.isEmpty)

        // The server reads it from its own environment, with no Keychain involved.
        let options = try #require(OrbToolsMCPServer.Options(arguments: config.arguments,
                                                             environment: [OrbToolsMCPServer.tinyFishKeyVariable: "tf-secret"]))
        #expect(options.tinyFishKey == "tf-secret" && options.context.browser.searchKeys?.tinyFish == "tf-secret")
        #expect(options.context.browser.searchProvider == .tinyfish)
        // Without it a TinyFish search falls back to DuckDuckGo (the tool says so), as in the app.
        let missing = try #require(OrbToolsMCPServer.Options(arguments: config.arguments, environment: [:]))
        #expect(missing.tinyFishKey == nil && missing.context.browser.searchKeys?.tinyFish == nil)
    }

    @Test func theServersContextReachesTheOrbsBrowser() throws {
        let config = OrbToolsMCPServer.config(directory: directory, scheduleMailbox: URL(fileURLWithPath: "/tmp/caixa"), orb: orb, browser: .browser,
                                              engine: .obscura, searchProvider: .duckduckgo, browserProfiles: profiles)
        let options = try #require(OrbToolsMCPServer.Options(arguments: config.arguments, environment: [:]))
        let context = options.context
        #expect(context.botID == orb, "the session is named for the Orb, so it is the one the app has")
        #expect(context.browser.hub?.profilesDirectory == profiles && context.browser.engine == .obscura && context.browser.drivesABrowser)
        #expect(context.acceptsImages && context.imageStore != nil, "browse_screenshot goes back as a picture")
        // No web tools: no hub.
        let plain = try #require(OrbToolsMCPServer.Options(arguments: ["Orb", "--tools-mcp", "/tmp/m"], environment: [:]))
        #expect(plain.context.browser.hub == nil && plain.browser == .off)
    }
}

struct BrowserMCPPermissionTests {
    private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) -> PermissionCall {
        PermissionPolicy.call(claudeCodeTool: prefix + name, input: .object(arguments), workspace: FileManager.default.temporaryDirectory)
    }

    private func verdict(_ name: String, _ arguments: [String: JSONValue] = [:], mode: PermissionMode = .ask,
                         rules: [PermissionRule] = []) -> PermissionVerdict {
        PermissionPolicy.evaluate(mode: mode, call: call(name, arguments), rules: rules, workspace: nil)
    }

    @Test func theToolsOfTheServerAreFoundByTheNameClaudeCodeGivesThem() {
        for name in browse + webSearch {
            #expect(OrbToolsMCPServer.tool(claudeCodeName: prefix + name)?.spec.name == name, Comment(rawValue: name))
            #expect(ClaudeCodeTools.kind(prefix + name) == .browser, Comment(rawValue: name))
        }
        #expect(ClaudeCodeTools.summary(prefix + "browse_open", .object(["url": .string("https://a.test/")])).title == "Abrindo página")
        #expect(ClaudeCodeTools.summary(prefix + "web_search", .object(["query": .string("café")])) == ("Pesquisando na web", "café"))
        #expect(ClaudeCodeTools.summary(prefix + "browse_show", .object([:])).title == "Mostrando o navegador para você")
    }

    @Test func clickingAndTypingKeepTheirOwnFamilyAndRules() {
        for name in ["browse_click", "browse_fill", "browse_select", "browse_press", "browse_show"] {
            #expect(call(name).family == .browserPage, Comment(rawValue: name))
            #expect(verdict(name) == .ask(.needsPermission), Comment(rawValue: name))
            #expect(verdict(name, mode: .auto) == .allow && verdict(name, mode: .bypass) == .allow, Comment(rawValue: name))
            #expect(verdict(name, mode: .readOnly) == .deny(PermissionPolicy.readOnlyDenial), Comment(rawValue: name))
            #expect(verdict(name, rules: [PermissionRule(family: .browserPage)]) == .allow, Comment(rawValue: name))
            #expect(verdict(name, rules: [.host("a.test"), PermissionRule(family: .web, scope: .search)]) == .ask(.needsPermission), Comment(rawValue: name))
        }
    }

    @Test func openingAPageAsksLikeWebFetchAndIsCoveredBySiteRules() {
        let open: [String: JSONValue] = ["url": .string("https://docs.a.test/x")]
        #expect(call("browse_open", open).family == .web && call("browse_open", open).host == "docs.a.test")
        #expect(verdict("browse_open", open) == .ask(.needsPermission))
        #expect(verdict("browse_open", open, rules: [.host("a.test")]) == .allow)
        #expect(verdict("browse_open", open, rules: [.host("b.test")]) == .ask(.needsPermission))
        #expect(verdict("browse_open", open, mode: .readOnly) == .deny(PermissionPolicy.readOnlyDenial))
    }

    @Test func theSearchOfTheServerIsAskedAndGrantedLikeWebSearch() {
        let search: [String: JSONValue] = ["query": .string("tempo em Lisboa")]
        #expect(PermissionPolicy.isSearch(call("web_search", search)))
        #expect(verdict("web_search", search) == .ask(.needsPermission))
        #expect(verdict("web_search", search, rules: [PermissionRule(family: .web, scope: .search)]) == .allow)
        #expect(verdict("web_search", search, rules: [.host("a.test")]) == .ask(.needsPermission))
        #expect(PermissionPolicy.suggestions(for: call("web_search", search)) == [PermissionRule(family: .web, scope: .search)])
    }

    @Test func lookingAtThePageAlreadyOpenAsksNothingButReadOnlyRefusesIt() {
        for name in ["browse_snapshot", "browse_read", "browse_screenshot"] {
            #expect(verdict(name) == .allow && verdict(name, mode: .auto) == .allow, Comment(rawValue: name))
            #expect(verdict(name, mode: .readOnly) == .deny(PermissionPolicy.readOnlyDenial), Comment(rawValue: name))
        }
    }

    @Test func aGrantFromTheNativeEngineIsTheSameGrant() {
        // The rules are the Orb's, not the engine's: "Clicar e preencher páginas" granted in a native turn covers Claude Code's.
        let rule = PermissionRule(family: .browserPage)
        #expect(PermissionPolicy.isCovered(call("browse_click"), by: [rule]))
        #expect(PermissionPolicy.legacyRule(forToolName: prefix + "browse_click") == PermissionPolicy.legacyRule(forToolName: "browse_click"))
    }
}

struct BrowserMCPPromptTests {
    private func bot(_ engine: BrowserEngineKind) -> Bot {
        var bot = Bot(name: "Atlas", role: "", orb: OrbConfig())
        bot.browserEngine = engine
        return bot
    }

    @Test func claudeCodeIsToldToPreferTheOrbsBrowserForPagesThatNeedOneAndKeepsItsOwnWebTools() {
        let note = BrowserPrompt.section(bot: bot(.chrome), availability: .browser, status: BrowserEngineStatus(engine: .chrome), claudeCode: true)
        #expect(note.contains(prefix + "browse_open") && note.contains(prefix + "browse_snapshot") && note.contains(prefix + "browse_show"))
        #expect(note.contains("Prefer these tools to WebFetch and WebSearch") && note.contains("logged-in"))
        #expect(!note.contains("(browse_*)"), "the names are the server's")
        // The native engine's text names the tools plainly, and does not talk about Claude Code's.
        let native = BrowserPrompt.section(bot: bot(.chrome), availability: .browser, status: BrowserEngineStatus(engine: .chrome))
        #expect(native.contains("browse_open") && !native.contains(prefix) && !native.contains("WebFetch"))

        let system = ClaudeCodePrompt.withBrowserNote("base", bot: bot(.chrome), availability: .browser, status: BrowserEngineStatus(engine: .chrome))
        #expect(system.hasPrefix("base\n\n## Your browser"))
        #expect(ClaudeCodePrompt.withBrowserNote("base", bot: bot(.chrome), availability: .off, status: nil) == "base")
        #expect(ClaudeCodePrompt.withBrowserNote("base", bot: bot(.simple), availability: .fetchOnly, status: nil) == "base")
    }

    @Test func aMissingEngineIsToldOnceInClaudeCodesWords() {
        var status = BrowserEngineStatus(engine: .chrome)
        status.missing = [.init(name: "Chrome")]
        let note = BrowserPrompt.section(bot: bot(.chrome), availability: .fetchOnly, status: status, claudeCode: true)
        #expect(note.contains("Ajustes") && note.contains("missing: Chrome") && note.contains("WebFetch and \(prefix)web_search") && !note.contains("web_fetch"))
    }

    @Test func theWebToolsOfClaudeCodeStayAvailableWithTheBrowser() {
        var withWeb = bot(.chrome)
        withWeb.capabilities = [.terminal, .browser]
        let on = ClaudeCodeTurn(bot: withWeb, executable: URL(fileURLWithPath: "/bin/claude"), model: "default", system: "x", prompt: "oi")
            .arguments(newSessionID: "s", mcpConfig: nil).first { $0.hasPrefix("--disallowedTools=") } ?? ""
        #expect(!on.contains("WebFetch") && !on.contains("WebSearch") && !on.contains("browse_"))
        withWeb.capabilities = [.terminal]
        let off = ClaudeCodeTurn(bot: withWeb, executable: URL(fileURLWithPath: "/bin/claude"), model: "default", system: "x", prompt: "oi")
            .arguments(newSessionID: "s", mcpConfig: nil).first { $0.hasPrefix("--disallowedTools=") } ?? ""
        #expect(off.contains("WebFetch") && off.contains("WebSearch"))
    }
}

struct BrowserMCPStabilityTests {
    @Test func theListAndTheConfigAreTheSameBytesEveryTimeForEachConfiguration() async throws {
        let setup = FakeBrowserSetup()
        let request = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/list")])
        for browser in [BrowserAvailability.off, .fetchOnly, .browser] {
            for mac in [true, false] {
                let first = try #require(await OrbToolsMCPServer.handle(request, context: setup.context(), mac: mac, accessibilityGranted: true,
                                                                        browser: browser)).jsonString
                for _ in 0..<5 {
                    #expect(try #require(await OrbToolsMCPServer.handle(request, context: setup.context(), mac: mac, accessibilityGranted: true,
                                                                        browser: browser)).jsonString == first)
                }
                let names = try #require(JSONValue.parse(first)?["result"]?["tools"]?.array).compactMap { $0["name"]?.string }
                #expect(names == OrbToolsMCPServer.tools(mac: mac, browser: browser).map(\.spec.name))
            }
        }
        let servers = (0..<10).map { _ in
            OrbToolsMCPServer.config(directory: URL(fileURLWithPath: "/tmp/m"), mac: true, orb: UUID(uuidString: "0B5E5E5E-0000-4000-8000-00000000C0DE"),
                                     browser: .browser, engine: .chrome, searchProvider: .tinyfish,
                                     browserProfiles: URL(fileURLWithPath: "/tmp/nav"), tinyFishKey: "k")
        }
        let configs = servers.compactMap { ClaudeCodeTurn.mcpConfig([$0])?.jsonString }
        #expect(configs.count == 10 && Set(configs).count == 1)
    }
}
