import Foundation
import Testing
@testable import Orb

/// Which browser the Orb finds on this Mac, how it is launched in each mode, and how Orbs saved before the modes load.
struct BrowserLocatorTests {
    private let home = URL(fileURLWithPath: "/Users/fulano")
    private let chromeApp = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    private let braveApp = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"

    /// A Mac whose files are exactly `files`; `directories` maps a folder to what it holds; `versions` is what each browser says.
    private func locator(path: [String] = ["/opt/homebrew/bin"], files: Set<String> = [], directories: [String: [String]] = [:],
                         versions: [String: String] = [:], managedRoot: URL? = nil) -> BrowserLocator {
        BrowserLocator(searchPath: path, home: home, isExecutable: { files.contains($0) }, directoryContents: { directories[$0] ?? [] },
                       exists: { files.contains($0) }, bundleVersion: { versions[$0] }, managedRoot: managedRoot)
    }

    // MARK: Detection

    @Test func withoutAnythingInstalledItSaysWhatIsMissingAndWhereToInstallIt() {
        let status = locator().status()
        #expect(!status.isReady)
        #expect(status.missing.map(\.name) == ["agent-browser", "Chrome"])
        #expect(status.modelNote?.contains("Ajustes") == true && status.userMessage?.contains("Ajustes") == true)
        #expect(status.modelNote?.contains("brew") == false && status.userMessage?.contains("brew") == false, "no Homebrew needed")
    }

    @Test func aMacWithChromeOnlyNeedsAgentBrowser() {
        let status = locator(files: [chromeApp], versions: [chromeApp: "155.0.7632.46"]).status()
        #expect(status.missing.map(\.name) == ["agent-browser"])
        #expect(status.program == BrowserProgram(kind: .chrome, executable: chromeApp, major: 155))
        #expect(status.program?.label == "Google Chrome 155")
    }

    @Test func chromeComesFirstThenBraveAndTheCopyInTheUsersOwnApplicationsLast() {
        let own = home.appending(path: "Applications").path + "/Google Chrome.app/Contents/MacOS/Google Chrome"
        #expect(locator(files: [braveApp, chromeApp]).program()?.kind == .chrome)
        #expect(locator(files: [braveApp]).program()?.kind == .brave)
        #expect(locator(files: [own]).program()?.executable == own)
        #expect(locator(files: [chromeApp, own]).program()?.executable == chromeApp)
    }

    @Test func chromeForTestingIsTheFallbackAndOnlyWhenThereIsNoBrowser() {
        let cache = home.appending(path: ".agent-browser/browsers").path
        let testing = cache + "/chrome-131.0/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        let downloaded = locator(files: [testing], directories: [cache: ["chrome-131.0", ".DS_Store"]])
        #expect(downloaded.program()?.kind == .testing && downloaded.program()?.executable == testing)
        #expect(!downloaded.hasInstalledBrowser())

        let inner = cache + "/chrome-131.0/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        #expect(locator(files: [inner], directories: [cache: ["chrome-131.0"]]).program()?.executable == inner)

        // A Chrome on the Mac wins over the download, and makes the download unnecessary.
        let both = locator(files: [testing, chromeApp], directories: [cache: ["chrome-131.0"]])
        #expect(both.program()?.kind == .chrome && both.hasInstalledBrowser())
    }

    @Test func theChromeTheAppInstalledIsFoundInItsOwnFolderAndTheNewestVersionWins() {
        let root = URL(fileURLWithPath: "/data/navegador")
        let layout = BrowserInstallLayout(root: root)
        let app = "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        let old = layout.chromeDirectory.appending(path: "chrome-9.0.1/" + app).path
        let new = layout.chromeDirectory.appending(path: "chrome-155.0.7632.46/" + app).path
        let found = locator(files: [old, new], directories: [layout.chromeDirectory.path: ["chrome-9.0.1", "chrome-155.0.7632.46"]],
                            managedRoot: root)
        // 155 is newer than 9, which a comparison of the text gets wrong.
        #expect(found.program()?.executable == new)
    }

    @Test func commandsAreSearchedInTheAppsFolderFirstThenTheUsersPathThenWhereHomebrewAndNpmPutThem() {
        let found = BrowserLocator.live(path: "/custom/bin:/usr/bin", home: home)
        #expect(Array(found.searchPath.prefix(2)) == ["/custom/bin", "/usr/bin"])
        #expect(found.searchPath.contains("/opt/homebrew/bin") && found.searchPath.contains(home.path + "/.local/bin"))
        #expect(found.searchPath.count == Set(found.searchPath).count, "no directory twice")

        let own = locator(path: ["/custom/bin", "/opt/homebrew/bin"], files: ["/custom/bin/agent-browser", "/opt/homebrew/bin/agent-browser"])
        #expect(own.agentBrowser() == "/custom/bin/agent-browser")

        let root = URL(fileURLWithPath: "/data/navegador")
        #expect(BrowserLocator.live(path: "/custom/bin", home: home, managedRoot: root).searchPath.first
                == BrowserInstallLayout(root: root).binDirectory.path)
    }

    // MARK: Availability

    @Test func theBrowserToolsComeOnlyWithAnInstalledBrowser() {
        let program = BrowserProgram(kind: .chrome, executable: chromeApp, major: 155)
        let ready = BrowserStatus(agentBrowser: "/x/agent-browser", program: program)
        var missing = ready
        missing.missing = [.init(name: "Chrome")]
        let on: Set<Capability> = [.browser]
        #expect(BrowserAvailability(capabilities: on, status: ready) == .browser)
        #expect(BrowserAvailability(capabilities: on, status: missing) == .fetchOnly)
        #expect(BrowserAvailability(capabilities: on, status: nil) == .fetchOnly)
        #expect(BrowserAvailability(capabilities: [.terminal], status: ready) == .off)
    }

    @Test func theToolListFollowsTheSwitchAndTheInstall() {
        func names(_ capabilities: Set<Capability>, _ availability: BrowserAvailability) -> Set<String> {
            Set(ToolBox.offered(for: capabilities, accessibilityGranted: false, browser: availability).map(\.spec.name))
        }
        let browse = ToolBox.browseToolNames
        #expect(browse.contains("browse_open") && browse.contains("browse_show") && browse.count == 19)

        let withBrowser = names([.browser], .browser)
        #expect(browse.isSubset(of: withBrowser) && withBrowser.contains("web_fetch") && withBrowser.contains("web_search"))

        let fetchOnly = names([.browser], .fetchOnly)
        #expect(fetchOnly.isDisjoint(with: browse) && fetchOnly.contains("web_fetch") && fetchOnly.contains("web_search"))
        // Not installed (the default): the same as fetch only.
        let byDefault = Set(ToolBox.offered(for: [.browser], accessibilityGranted: false).map(\.spec.name))
        #expect(byDefault == fetchOnly)

        // Without "Navegar na web" there is no web tool at all.
        let off = names([.terminal, .computerUse], .browser)
        #expect(off.isDisjoint(with: browse) && !off.contains("web_search") && !off.contains("web_fetch"))
    }

    @Test func thePromptTellsAboutAMissingBrowserOnceAndTheBrowserWhenItIsThere() {
        var bot = Bot(name: "Atlas", role: "", orb: OrbConfig())
        var missing = BrowserStatus()
        missing.missing = [.init(name: "agent-browser"), .init(name: "Chrome")]
        let note = BrowserPrompt.section(bot: bot, availability: .fetchOnly, status: missing)
        #expect(note.contains("missing: agent-browser, Chrome") && note.contains("Ajustes") && note.contains("only web_fetch and web_search"))
        #expect(!note.contains("\n"), "one short line")

        #expect(BrowserPrompt.section(bot: bot, availability: .off, status: nil).isEmpty)
        #expect(BrowserPrompt.section(bot: bot, availability: .fetchOnly, status: nil).isEmpty)

        let section = BrowserPrompt.section(bot: bot, availability: .browser, status: BrowserStatus())
        #expect(section.contains("browse_show") && section.contains("never type a password") && section.contains("captcha"))
        #expect(section.contains("in the background") && section.contains("keeps the user's logins"))

        bot.browserMode = .visible
        let visible = BrowserPrompt.section(bot: bot, availability: .browser, status: BrowserStatus())
        #expect(visible.contains("window is open on the user's screen") && !visible.contains("in the background"))
    }

    // MARK: Launch arguments

    private func config(headed: Bool = false, browser: BrowserProgram? = nil, state: URL? = nil) -> AgentBrowserConfig {
        AgentBrowserConfig(executable: "/x/agent-browser", session: "orb-1234abcd-chrome", browser: browser,
                           profile: URL(fileURLWithPath: "/data/navegador/orb/chrome"), headed: headed, stateDirectory: state)
    }

    @Test func everyCommandNamesTheSessionAndAsksForJSON() {
        #expect(config().globalArguments == ["--session", "orb-1234abcd-chrome", "--json"])
    }

    @Test func theBrowserLaunchesWithTheOrbsProfileAndNoWindowAndHidesTheAutomationSwitch() {
        let hidden = ["--args", "--disable-blink-features=AutomationControlled"]
        #expect(config().launchArguments == hidden + ["--profile", "/data/navegador/orb/chrome"])
        #expect(config(headed: true).launchArguments == hidden + ["--profile", "/data/navegador/orb/chrome", "--headed"])
        // Without the app's folder there is no launcher: the browser itself is named, so Brave or another is never picked by accident.
        let brave = BrowserProgram(kind: .brave, executable: braveApp, major: 140)
        #expect(config(browser: brave).launchArguments == ["--executable-path", braveApp] + hidden + ["--profile", "/data/navegador/orb/chrome"])
    }

    @Test func aLauncherScriptGivesTheBrowserTheUserAgentOfAWindowedChrome() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbLauncher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let program = BrowserProgram(kind: .chrome, executable: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", major: 155)
        let config = config(browser: program, state: folder)
        let launcher = try #require(config.launcherURL)
        #expect(launcher.path == folder.appending(path: "lancadores/chrome-155.sh").path)
        #expect(config.launchArguments.prefix(2) == ["--executable-path", launcher.path])

        let script = try #require(config.launcherScript)
        #expect(script == "#!/bin/sh\nexec '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \"$@\" "
                + "'--user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36'\n")
        #expect(!script.contains("Headless"))

        config.prepareState()
        #expect(try String(contentsOf: launcher, encoding: .utf8) == script)
        #expect(FileManager.default.isExecutableFile(atPath: launcher.path))

        // A path with a quote stays one word.
        var odd = program
        odd.executable = "/Apps/O'Neil/Chrome"
        #expect(AgentBrowserConfig(executable: "x", session: "s", browser: odd).launcherScript?.contains("'/Apps/O'\\''Neil/Chrome'") == true)
        // Without a version there is nothing to say in the user agent: no launcher.
        var unknown = program
        unknown.major = nil
        #expect(self.config(browser: unknown, state: folder).launcherURL == nil)
    }

    @Test func fileAccessIsOffUnlessAskedFor() {
        #expect(!config().launchArguments.contains("--allow-file-access"))
        var allowed = config()
        allowed.allowFileAccess = true
        #expect(allowed.launchArguments.last == "--allow-file-access")
    }

    @Test func everyBrowserClosesItselfWhenForgotten() {
        #expect(config().extraEnvironment["AGENT_BROWSER_IDLE_TIMEOUT_MS"] == "1800000")
    }

    @Test func eachOrbHasItsOwnSessionAndTheNameStaysTheOneEarlierVersionsUsed() {
        let one = UUID(), other = UUID()
        let name = AgentBrowserConfig.sessionName(botID: one)
        #expect(name.hasPrefix("orb-") && name.hasSuffix("-chrome") && name.lowercased() == name)
        #expect(name != AgentBrowserConfig.sessionName(botID: other))
        #expect(name == AgentBrowserConfig.sessionName(botID: one))
    }

    @Test func theModeIsNotPartOfTheLaunchFingerprintSoAnOpenNeverClosesTheWindowInUse() {
        #expect(config().launchFingerprint == config(headed: true).launchFingerprint)
        #expect(config().launchFingerprint != config(browser: BrowserProgram(kind: .brave, executable: braveApp, major: 140)).launchFingerprint)
    }

    @Test func theHubLaunchesEachOrbInItsModeWithItsOwnProfileFolder() {
        let folder = URL(fileURLWithPath: "/data/navegador")
        let setup = FakeBrowserSetup(profiles: folder)
        let status = BrowserStatus(agentBrowser: "/x/agent-browser", program: BrowserProgram(kind: .chrome, executable: chromeApp, major: 155))
        let background = setup.hub.configuration(botID: setup.botID, mode: .background, status: status)
        #expect(background.profile?.path == "/data/navegador/\(setup.botID.uuidString)/chrome")
        #expect(background.executable == "/x/agent-browser" && !background.headed && !background.visibleByDefault)

        let visible = setup.hub.configuration(botID: setup.botID, mode: .visible, status: status)
        #expect(visible.headed && visible.visibleByDefault && visible.profile == background.profile)

        let noFolder = FakeBrowserSetup(profiles: nil).hub.configuration(botID: UUID(), mode: .background, status: status)
        #expect(noFolder.profile == nil)
    }

    @Test func theLoginsOfAnOrbThatUsedCloakBrowserMoveToTheChromeFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbAdopt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let cloak = folder.appending(path: "\(id.uuidString)/cloak"), chrome = folder.appending(path: "\(id.uuidString)/chrome")
        try FileManager.default.createDirectory(at: cloak, withIntermediateDirectories: true)
        try "cookies".write(to: cloak.appending(path: "Cookies"), atomically: true, encoding: .utf8)
        try "1".write(to: cloak.appending(path: ".cloakbrowser-seed"), atomically: true, encoding: .utf8)

        BrowserHub.adoptOldProfile(for: id, in: folder)
        #expect(!FileManager.default.fileExists(atPath: cloak.path))
        #expect(try String(contentsOf: chrome.appending(path: "Cookies"), encoding: .utf8) == "cookies")
        #expect(!FileManager.default.fileExists(atPath: chrome.appending(path: ".cloakbrowser-seed").path))

        // With both folders the Chrome one wins and the other is left alone.
        try FileManager.default.createDirectory(at: cloak, withIntermediateDirectories: true)
        BrowserHub.adoptOldProfile(for: id, in: folder)
        #expect(FileManager.default.fileExists(atPath: cloak.path) && FileManager.default.fileExists(atPath: chrome.appending(path: "Cookies").path))
    }

    // MARK: Orbs saved before

    private func decode(_ json: String) throws -> Bot {
        try JSONDecoder().decode(Bot.self, from: Data(json.utf8))
    }

    @Test func anOrbSavedBeforeTheModesGetsTheBackgroundAndDuckDuckGo() throws {
        let bot = try decode(#"{"id":"\#(UUID().uuidString)","name":"Atlas","capabilities":["terminal","browser"]}"#)
        #expect(bot.capabilities.contains(.browser))
        #expect(bot.browserMode == .background && bot.searchProvider == .duckduckgo)
        #expect(BrowserMode.default == .background)
    }

    @Test func everyOldEngineLoadsWithoutErrorAndKeepsNavigatingTheWeb() throws {
        for engine in ["chrome", "cloak", "obscura", "simple", "firefox2030"] {
            let bot = try decode(#"{"id":"\#(UUID().uuidString)","name":"A","capabilities":["browser"],"browserEngine":"\#(engine)"}"#)
            #expect(bot.browserMode == .background && bot.capabilities.contains(.browser), "\(engine)")
        }
    }

    @Test func theModeAndTheProviderAreKeptAndAnUnknownOneFallsBack() throws {
        let id = UUID().uuidString
        let chosen = try decode(#"{"id":"\#(id)","name":"A","browserMode":"visible","searchProvider":"tinyfish"}"#)
        #expect(chosen.browserMode == .visible && chosen.searchProvider == .tinyfish)
        let later = try decode(#"{"id":"\#(id)","name":"A","browserMode":"hologram","searchProvider":"bing"}"#)
        #expect(later.browserMode == .background && later.searchProvider == .duckduckgo)
        let wrongType = try decode(#"{"id":"\#(id)","name":"A","browserMode":7,"searchProvider":null}"#)
        #expect(wrongType.browserMode == .background && wrongType.searchProvider == .duckduckgo)

        var bot = chosen
        bot.browserMode = .visible
        bot.searchProvider = .google
        let again = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot))
        #expect(again.browserMode == .visible && again.searchProvider == .google)
    }

    @Test func aNewOrbUsesTheBackgroundAndDuckDuckGo() {
        let bot = Bot(name: "Novo", role: "", orb: OrbConfig())
        #expect(bot.browserMode == .background && bot.searchProvider == .duckduckgo)
        #expect(bot.capabilities.contains(.browser))
    }
}
