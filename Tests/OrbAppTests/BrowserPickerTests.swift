import Foundation
import Testing
@testable import Orb

// The pickers under "Navegar na web" in the Orb's panel: when they show, what they say about what is installed, and what a change
// of engine does to the browser the Orb has open.

struct BrowserPickerCopyTests {
    private func missing(_ names: String...) -> BrowserStatus {
        var status = BrowserStatus(agentBrowser: "/fake/agent-browser")
        status.missing = names.map { .init(name: $0) }
        return status
    }

    @Test func thePickersShowOnlyWhileTheOrbCanBrowseTheWeb() {
        #expect(BrowserPickerCopy.showsPickers([.terminal, .browser]))
        #expect(!BrowserPickerCopy.showsPickers([.terminal, .computerUse, .connectors]))
        #expect(!BrowserPickerCopy.showsPickers([]))
    }

    @Test func theModesAndProvidersAreNamedAndSummarizedForThePicker() {
        #expect(BrowserMode.allCases.map(\.label) == ["Segundo plano", "Visível"])
        #expect(SearchProvider.allCases.map(\.label) == ["DuckDuckGo", "Google", "TinyFish"])
        for mode in BrowserMode.allCases { #expect(!mode.summary.isEmpty && !mode.summary.hasSuffix("\n")) }
        for provider in SearchProvider.allCases { #expect(!BrowserPickerCopy.searchSummary(provider).isEmpty) }
        // The default is the one a new Orb gets.
        #expect(BrowserMode.default == .background && Bot(name: "A", role: "", orb: OrbConfig()).searchProvider == .duckduckgo)
    }

    @Test func anInstalledBrowserIsReadyAndSaysWhichOne() {
        let program = BrowserProgram(kind: .chrome, executable: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", major: 155)
        let ready = BrowserPickerCopy.browserLine(status: BrowserStatus(agentBrowser: "/fake/agent-browser", program: program))
        #expect(ready == BrowserPickerCopy.Line(text: "Pronto · usa o Google Chrome 155", tone: .ready))
        let noName = BrowserPickerCopy.browserLine(status: BrowserStatus(agentBrowser: "/fake/agent-browser"))
        #expect(noName == BrowserPickerCopy.Line(text: "Pronto", tone: .ready))
    }

    @Test func aMissingBrowserSaysWhatIsMissingAndSendsToAjustes() {
        let line = BrowserPickerCopy.browserLine(status: missing("agent-browser", "Chrome"))
        #expect(line.tone == .warning && line.action == .installBrowser)
        #expect(line.text.hasPrefix("Não instalado") && line.text.contains("agent-browser e Chrome") && line.text.contains("só lê"))
        #expect(BrowserPickerCopy.Action.installBrowser.title == "Instalar em Ajustes")
        #expect(line.symbol == "exclamationmark.triangle.fill")
        // While it is being looked for there is no verdict yet.
        let checking = BrowserPickerCopy.browserLine(status: nil)
        #expect(checking.tone == .neutral && checking.action == nil)
    }

    @Test func tinyFishWithoutAKeySaysSoAndSendsToAjustes() {
        let none = BrowserPickerCopy.searchLine(.tinyfish, browserIsReady: true, hasKey: false)
        #expect(none?.tone == .warning && none?.action == .addSearchKey && none?.text.contains("Sem chave") == true)
        #expect(none?.text.contains("DuckDuckGo") == true, "says where the search goes meanwhile")
        #expect(BrowserPickerCopy.Action.addSearchKey.title == "Adicionar em Ajustes")
        #expect(BrowserPickerCopy.searchLine(.tinyfish, browserIsReady: true, hasKey: true)?.tone == .ready)
        #expect(BrowserPickerCopy.searchLine(.tinyfish, browserIsReady: true, hasKey: nil) == nil, "still being read")
    }

    @Test func googleNeedsTheOrbsBrowserAndDuckDuckGoNeedsNothing() {
        #expect(BrowserPickerCopy.searchLine(.duckduckgo, browserIsReady: nil, hasKey: nil) == nil)
        #expect(BrowserPickerCopy.searchLine(.google, browserIsReady: true, hasKey: nil) == nil)
        #expect(BrowserPickerCopy.searchLine(.google, browserIsReady: nil, hasKey: nil) == nil, "not known yet")
        let notInstalled = BrowserPickerCopy.searchLine(.google, browserIsReady: false, hasKey: nil)
        #expect(notInstalled?.action == .installBrowser && notInstalled?.text.contains("DuckDuckGo") == true)
    }

    @Test func theLinkOpensTheNavegadorTabOfAjustes() {
        let suite = "OrbPickerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsRouter.requestBrowser(defaults: defaults)
        #expect(defaults.string(forKey: SettingsRouter.requestKey) == SettingsRouter.browserTab)
        #expect(SettingsRouter.browserTab == "browser")
    }
}

@Suite final class BrowserPickerModelTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbPickers-\(UUID().uuidString)")
    deinit { removeTestFolder(root) }

    @MainActor private func model(vault: (any SecretVault)? = nil) -> (AppModel, UUID) {
        var state = AppState.initial
        state.bots.append(Bot(name: "Atlas", role: "", orb: OrbConfig()))
        Store(directory: root).save(state)
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false, secretVault: vault ?? MemoryVault())
        return (model, model.bots[0].id)
    }

    @Test @MainActor func changingTheModeSavesItAndClosesTheBrowserTheOrbHadOpen() async throws {
        let (model, botID) = model()
        let setup = FakeBrowserSetup()
        model.browserHub = setup.hub
        _ = try await setup.hub.session(botID: botID, mode: .background)
        #expect(model.bot(botID)?.browserMode == .background)

        model.setBrowserMode(.visible, for: botID)
        #expect(model.bot(botID)?.browserMode == .visible)
        await waitUntil("the old browser to close") { setup.driver.calls.contains("close") }
        #expect(setup.hub.existingSession(botID: botID) == nil)
    }

    @Test @MainActor func choosingTheSameModeAgainLeavesTheBrowserAlone() async throws {
        let (model, botID) = model()
        let setup = FakeBrowserSetup()
        model.browserHub = setup.hub
        _ = try await setup.hub.session(botID: botID, mode: .background)
        model.setBrowserMode(.background, for: botID)
        try await Task.sleep(for: .milliseconds(50))
        #expect(setup.driver.calls.isEmpty && setup.hub.existingSession(botID: botID) != nil)
    }

    /// The browser may have been started by another process (the tools server of a Claude Code turn): the app holds no session
    /// for it, but it is closed all the same, through the session name the two share, and only the Orb's own.
    @Test func closingTheOrbsBrowserClosesTheOneAnotherProcessStarted() async {
        let world = FakeBrowserWorld()
        let hub = world.hub()
        let botID = UUID(), otherOrb = UUID()
        let mine = AgentBrowserConfig.sessionName(botID: botID)
        let others = AgentBrowserConfig.sessionName(botID: otherOrb)
        for name in [mine, others, "default"] { world.start(name) }
        #expect(await hub.close(botID: botID))
        #expect(world.closed == [mine], "only the Orb's session")
        #expect(world.running == [others, "default"])
        // Nothing running by that name: nothing is closed (no command is sent for a browser that is not there).
        #expect(await hub.close(botID: botID) == false)
        #expect(world.closed == [mine])
    }

    @Test @MainActor func theSearchProviderIsPerOrb() {
        let (model, botID) = model()
        model.setSearchProvider(.tinyfish, for: botID)
        #expect(model.bot(botID)?.searchProvider == .tinyfish)
    }

    @Test @MainActor func theKeyOfTinyFishIsReadFromTheVaultOnlyForTinyFish() async {
        let vault = MemoryVault()
        let (model, _) = model(vault: vault)
        #expect(await model.hasSearchKey(for: .tinyfish) == false)
        #expect(await model.hasSearchKey(for: .google), "nothing to read for the others")
        SearchKeys(vault: vault).setTinyFish("tf-123")
        #expect(await model.hasSearchKey(for: .tinyfish))
    }
}
