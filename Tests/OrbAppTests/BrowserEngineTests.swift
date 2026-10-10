import Foundation
import Testing
@testable import Orb

/// Which engines are installed, how each is launched, and how Orbs saved before the engines existed load.
struct BrowserEngineTests {
    private let home = URL(fileURLWithPath: "/Users/fulano")

    /// A Mac whose files are exactly `files`; `directories` maps a folder to what it holds.
    private func locator(path: [String] = ["/opt/homebrew/bin"], files: Set<String> = [], directories: [String: [String]] = [:],
                         environment: [String: String] = [:]) -> BrowserEngineLocator {
        BrowserEngineLocator(searchPath: path, home: home, environment: environment,
                             isExecutable: { files.contains($0) }, directoryContents: { directories[$0] ?? [] },
                             exists: { files.contains($0) })
    }

    // MARK: Detection

    @Test func theSimpleEngineNeedsNothing() {
        let status = locator().status(for: .simple)
        #expect(status.isReady && status.missing.isEmpty && status.modelNote == nil && status.userMessage == nil)
    }

    @Test func withoutAgentBrowserEveryEngineSaysHowToInstallIt() {
        for engine in [BrowserEngineKind.chrome, .obscura, .cloak] {
            let status = locator().status(for: engine)
            #expect(!status.isReady, "\(engine)")
            #expect(status.installCommands.first == "brew install agent-browser", "\(engine)")
            #expect(status.modelNote?.contains("brew install agent-browser") == true)
            #expect(status.userMessage?.contains("agent-browser") == true)
        }
    }

    @Test func chromeNeedsAgentBrowserAndAChromeToo() {
        let nothing = locator().status(for: .chrome)
        #expect(nothing.installCommands == ["brew install agent-browser", "agent-browser install"])

        let onlyTheCommand = locator(files: ["/opt/homebrew/bin/agent-browser"]).status(for: .chrome)
        #expect(onlyTheCommand.agentBrowser == "/opt/homebrew/bin/agent-browser")
        #expect(onlyTheCommand.installCommands == ["agent-browser install"])
        #expect(onlyTheCommand.modelNote?.contains("agent-browser install") == true)
    }

    @Test func chromeIsFoundWhereAgentBrowserInstallsItOrInApplications() {
        let cache = home.appending(path: ".agent-browser/browsers").path
        let downloaded = locator(files: ["/opt/homebrew/bin/agent-browser",
                                         cache + "/chrome-131.0/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"],
                                 directories: [cache: ["chrome-131.0", ".DS_Store"]])
        #expect(downloaded.status(for: .chrome).isReady)

        let inner = locator(files: ["/opt/homebrew/bin/agent-browser",
                                    cache + "/chrome-131.0/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"],
                            directories: [cache: ["chrome-131.0"]])
        #expect(inner.status(for: .chrome).isReady)

        let system = locator(files: ["/opt/homebrew/bin/agent-browser", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"])
        #expect(system.status(for: .chrome).isReady)
    }

    @Test func commandsAreSearchedInTheUsersPathFirstThenWhereHomebrewAndNpmPutThem() {
        let found = BrowserEngineLocator.live(path: "/custom/bin:/usr/bin", home: home)
        #expect(Array(found.searchPath.prefix(2)) == ["/custom/bin", "/usr/bin"])
        #expect(found.searchPath.contains("/opt/homebrew/bin") && found.searchPath.contains(home.path + "/.local/bin"))
        #expect(found.searchPath.count == Set(found.searchPath).count, "no directory twice")

        let own = locator(path: ["/custom/bin", "/opt/homebrew/bin"], files: ["/custom/bin/agent-browser", "/opt/homebrew/bin/agent-browser"])
        #expect(own.agentBrowser() == "/custom/bin/agent-browser")
    }

    @Test func obscuraIsItsBinaryOnThePath() {
        let missing = locator(files: ["/opt/homebrew/bin/agent-browser"]).status(for: .obscura)
        #expect(missing.installCommands == ["brew install obscura"])
        let there = locator(files: ["/opt/homebrew/bin/agent-browser", "/opt/homebrew/bin/obscura"]).status(for: .obscura)
        #expect(there.isReady && there.browserExecutable == "/opt/homebrew/bin/obscura")
    }

    @Test func cloakIsTheNewestChromiumInItsCache() {
        let cache = home.appending(path: ".cloakbrowser").path
        func chromium(_ version: String) -> String { cache + "/chromium-\(version)/Chromium.app/Contents/MacOS/Chromium" }
        let files: Set<String> = ["/opt/homebrew/bin/agent-browser", chromium("145.0.7632.109.2"), chromium("145.0.7632.109.10"), chromium("9.0.1")]
        let found = locator(files: files, directories: [cache: ["chromium-145.0.7632.109.2", "chromium-145.0.7632.109.10", "chromium-9.0.1"]])
        // 10 is newer than 2 and 145 newer than 9, which a comparison of the text gets wrong.
        #expect(found.status(for: .cloak).browserExecutable == chromium("145.0.7632.109.10"))

        let missing = locator(files: ["/opt/homebrew/bin/agent-browser"]).status(for: .cloak)
        #expect(missing.installCommands == ["pip3 install cloakbrowser && python3 -m cloakbrowser install"])
    }

    @Test func cloakHonoursItsOwnVariables() {
        let own = "/opt/cloak/chrome"
        let set = locator(files: ["/opt/homebrew/bin/agent-browser", own], environment: ["CLOAKBROWSER_BINARY_PATH": own])
        #expect(set.cloakChromium() == own)
        let broken = locator(environment: ["CLOAKBROWSER_BINARY_PATH": "/nowhere"])
        #expect(broken.cloakChromium() == nil)

        let cache = "/elsewhere/cache"
        let moved = locator(files: [cache + "/chromium-1.2.3/Chromium.app/Contents/MacOS/Chromium"],
                            directories: [cache: ["chromium-1.2.3"]], environment: ["CLOAKBROWSER_CACHE_DIR": cache])
        #expect(moved.cloakChromium() == cache + "/chromium-1.2.3/Chromium.app/Contents/MacOS/Chromium")
    }

    // MARK: Availability

    @Test func theBrowserToolsComeOnlyWithAnInstalledEngine() {
        let ready = BrowserEngineStatus(engine: .chrome, agentBrowser: "/x/agent-browser")
        var missing = ready
        missing.missing = [.init(name: "Chrome", command: "agent-browser install")]
        let on: Set<Capability> = [.browser]
        #expect(BrowserAvailability(capabilities: on, engine: .chrome, status: ready) == .browser)
        #expect(BrowserAvailability(capabilities: on, engine: .chrome, status: missing) == .fetchOnly)
        #expect(BrowserAvailability(capabilities: on, engine: .chrome, status: nil) == .fetchOnly)
        #expect(BrowserAvailability(capabilities: on, engine: .simple, status: ready) == .fetchOnly)
        #expect(BrowserAvailability(capabilities: [.terminal], engine: .chrome, status: ready) == .off)
    }

    @Test func theToolListFollowsTheSwitchAndTheEngine() {
        func names(_ capabilities: Set<Capability>, _ availability: BrowserAvailability) -> Set<String> {
            Set(ToolBox.offered(for: capabilities, accessibilityGranted: false, browser: availability).map(\.spec.name))
        }
        let browse = ToolBox.browseToolNames
        #expect(browse.contains("browse_open") && browse.contains("browse_show") && browse.count == 13)

        let withBrowser = names([.browser], .browser)
        #expect(browse.isSubset(of: withBrowser) && withBrowser.contains("web_fetch") && withBrowser.contains("web_search"))

        let fetchOnly = names([.browser], .fetchOnly)
        #expect(fetchOnly.isDisjoint(with: browse) && fetchOnly.contains("web_fetch") && fetchOnly.contains("web_search"))
        // Not installed (the default): the same as the simple engine.
        let byDefault = Set(ToolBox.offered(for: [.browser], accessibilityGranted: false).map(\.spec.name))
        #expect(byDefault == fetchOnly)

        // Without "Navegar na web" there is no web tool at all, whatever the engine says.
        let off = names([.terminal, .computerUse], .browser)
        #expect(off.isDisjoint(with: browse) && !off.contains("web_search") && !off.contains("web_fetch"))
    }

    @Test func thePromptTellsAboutAMissingBrowserOnceAndTheBrowserWhenItIsThere() {
        var bot = Bot(name: "Atlas", role: "", orb: OrbConfig())
        bot.browserEngine = .chrome
        var missing = BrowserEngineStatus(engine: .chrome)
        missing.missing = [.init(name: "agent-browser", command: "brew install agent-browser"), .init(name: "Chrome", command: "agent-browser install")]
        let note = BrowserPrompt.section(bot: bot, availability: .fetchOnly, status: missing)
        #expect(note.contains("brew install agent-browser ; agent-browser install") && note.contains("only web_fetch and web_search"))
        #expect(!note.contains("\n"), "one short line")

        #expect(BrowserPrompt.section(bot: bot, availability: .off, status: nil).isEmpty)
        #expect(BrowserPrompt.section(bot: bot, availability: .fetchOnly, status: nil).isEmpty, "the simple engine has nothing to say")

        let section = BrowserPrompt.section(bot: bot, availability: .browser, status: BrowserEngineStatus(engine: .chrome))
        #expect(section.contains("browse_show") && section.contains("never type a password") && section.contains("captcha"))
        #expect(section.contains("keeps the user's logins"))

        bot.browserEngine = .obscura
        let headless = BrowserPrompt.section(bot: bot, availability: .browser, status: BrowserEngineStatus(engine: .obscura))
        #expect(headless.contains("no window") && !headless.contains("keeps the user's logins") && !headless.contains("Call browse_show"))
    }

    // MARK: Launch arguments

    private func config(_ engine: BrowserEngineKind, headed: Bool = false) -> AgentBrowserConfig {
        AgentBrowserConfig(executable: "/x/agent-browser", session: "orb-1234abcd-\(engine.rawValue)", engine: engine,
                           browserExecutable: engine == .chrome ? nil : "/bin/\(engine.rawValue)",
                           profile: engine.keepsProfile ? URL(fileURLWithPath: "/data/navegador/orb/\(engine.rawValue)") : nil,
                           headed: headed, cloakSeed: 31_337)
    }

    @Test func everyCommandNamesTheSessionAndAsksForJSON() {
        #expect(config(.chrome).globalArguments == ["--session", "orb-1234abcd-chrome", "--json"])
    }

    @Test func chromeLaunchesWithTheOrbsProfileAndNoWindow() {
        #expect(config(.chrome).launchArguments == ["--profile", "/data/navegador/orb/chrome"])
        #expect(config(.chrome, headed: true).launchArguments == ["--profile", "/data/navegador/orb/chrome", "--headed"])
    }

    @Test func obscuraIsChosenByEngineAndHasNeitherProfileNorWindow() {
        let arguments = config(.obscura).launchArguments
        #expect(arguments == ["--engine", "obscura", "--executable-path", "/bin/obscura"])
        // agent-browser rejects both with Obscura: they are never passed, even if asked.
        #expect(config(.obscura, headed: true).launchArguments == arguments)
        #expect(!arguments.contains("--profile") && !arguments.contains("--headed"))
    }

    @Test func cloakLaunchesItsChromiumWithTheFingerprintFlagsOfItsOwnWrapper() {
        #expect(config(.cloak).launchArguments == [
            "--executable-path", "/bin/cloak",
            "--args", "--no-sandbox,--fingerprint=31337,--fingerprint-platform=macos",
            "--profile", "/data/navegador/orb/cloak",
        ])
        #expect(config(.cloak, headed: true).launchArguments.last == "--headed")
    }

    @Test func fileAccessIsOffUnlessAskedFor() {
        #expect(!config(.chrome).launchArguments.contains("--allow-file-access"))
        var allowed = config(.chrome)
        allowed.allowFileAccess = true
        #expect(allowed.launchArguments.last == "--allow-file-access")
    }

    @Test func eachOrbAndEngineHasItsOwnSession() {
        let one = UUID(), other = UUID()
        let name = AgentBrowserConfig.sessionName(botID: one, engine: .chrome)
        #expect(name.hasPrefix("orb-") && name.hasSuffix("-chrome") && name.lowercased() == name)
        #expect(name != AgentBrowserConfig.sessionName(botID: one, engine: .cloak))
        #expect(name != AgentBrowserConfig.sessionName(botID: other, engine: .chrome))
        #expect(name == AgentBrowserConfig.sessionName(botID: one, engine: .chrome))
    }

    @Test func theHubGivesEachOrbAndEngineItsOwnProfileFolder() async throws {
        let folder = URL(fileURLWithPath: "/data/navegador")
        let setup = FakeBrowserSetup(engine: .chrome, profiles: folder)
        var status = BrowserEngineStatus(engine: .chrome, agentBrowser: "/x/agent-browser")
        let chrome = setup.hub.configuration(botID: setup.botID, engine: .chrome, status: status)
        #expect(chrome.profile?.path == "/data/navegador/\(setup.botID.uuidString)/chrome")
        #expect(chrome.executable == "/x/agent-browser" && !chrome.headed)

        status.engine = .obscura
        status.browserExecutable = "/bin/obscura"
        let obscura = setup.hub.configuration(botID: setup.botID, engine: .obscura, status: status)
        #expect(obscura.profile == nil && obscura.browserExecutable == "/bin/obscura")

        let noFolder = FakeBrowserSetup(profiles: nil).hub.configuration(botID: UUID(), engine: .chrome, status: status)
        #expect(noFolder.profile == nil)
    }

    @Test func cloakKeepsOneFingerprintPerProfileInTheFileItsWrappersUse() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbCloakSeed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = CloakSeed.seed(inProfile: folder)
        #expect(CloakSeed.range.contains(first))
        #expect(CloakSeed.seed(inProfile: folder) == first)
        #expect(try String(contentsOf: folder.appending(path: ".cloakbrowser-seed"), encoding: .utf8) == "\(first)\n")
        // A seed written by the Python wrapper is kept; a damaged file gets a new one.
        try "54321\n".write(to: folder.appending(path: ".cloakbrowser-seed"), atomically: true, encoding: .utf8)
        #expect(CloakSeed.seed(inProfile: folder) == 54_321)
        try "not a number".write(to: folder.appending(path: ".cloakbrowser-seed"), atomically: true, encoding: .utf8)
        #expect(CloakSeed.range.contains(CloakSeed.seed(inProfile: folder)))
    }

    // MARK: Orbs saved before

    private func decode(_ json: String) throws -> Bot {
        try JSONDecoder().decode(Bot.self, from: Data(json.utf8))
    }

    @Test func anOrbSavedBeforeTheEnginesGetsChromeAndDuckDuckGo() throws {
        let bot = try decode(#"{"id":"\#(UUID().uuidString)","name":"Atlas","capabilities":["terminal","browser"]}"#)
        #expect(bot.capabilities.contains(.browser))
        #expect(bot.browserEngine == .chrome && bot.searchProvider == .duckduckgo)
        #expect(BrowserEngineKind.default == .chrome)
    }

    @Test func theChoicesAreKeptAndAnUnknownOneFallsBack() throws {
        let id = UUID().uuidString
        let chosen = try decode(#"{"id":"\#(id)","name":"A","browserEngine":"cloak","searchProvider":"tinyfish"}"#)
        #expect(chosen.browserEngine == .cloak && chosen.searchProvider == .tinyfish)
        let later = try decode(#"{"id":"\#(id)","name":"A","browserEngine":"firefox2030","searchProvider":"bing"}"#)
        #expect(later.browserEngine == .chrome && later.searchProvider == .duckduckgo)
        let wrongType = try decode(#"{"id":"\#(id)","name":"A","browserEngine":7,"searchProvider":null}"#)
        #expect(wrongType.browserEngine == .chrome && wrongType.searchProvider == .duckduckgo)

        var bot = chosen
        bot.browserEngine = .obscura
        bot.searchProvider = .google
        let again = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot))
        #expect(again.browserEngine == .obscura && again.searchProvider == .google)
    }

    @Test func aNewOrbUsesChromeAndDuckDuckGo() {
        let bot = Bot(name: "Novo", role: "", orb: OrbConfig())
        #expect(bot.browserEngine == .chrome && bot.searchProvider == .duckduckgo)
        #expect(bot.capabilities.contains(.browser))
    }

    @Test func onlyTheEnginesWithAProfileKeepLoginsAndOnlyTheseCanShowAWindow() {
        #expect(BrowserEngineKind.allCases.filter(\.keepsProfile) == [.chrome, .cloak])
        #expect(BrowserEngineKind.allCases.filter(\.canShowWindow) == [.chrome, .cloak])
        #expect(!BrowserEngineKind.simple.drivesABrowser && BrowserEngineKind.obscura.drivesABrowser)
    }
}
