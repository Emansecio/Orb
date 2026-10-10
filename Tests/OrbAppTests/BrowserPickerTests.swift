import Foundation
import Testing
@testable import Orb

// The pickers under "Navegar na web" in the Orb's panel: when they show, what they say about what is installed, and what a change
// of engine does to the browser the Orb has open.

struct BrowserPickerCopyTests {
    private func missing(_ engine: BrowserEngineKind, _ names: String...) -> BrowserEngineStatus {
        var status = BrowserEngineStatus(engine: engine, agentBrowser: "/fake/agent-browser")
        status.missing = names.map { .init(name: $0, command: "instala \($0)") }
        return status
    }

    @Test func thePickersShowOnlyWhileTheOrbCanBrowseTheWeb() {
        #expect(BrowserPickerCopy.showsPickers([.terminal, .browser]))
        #expect(!BrowserPickerCopy.showsPickers([.terminal, .computerUse, .connectors]))
        #expect(!BrowserPickerCopy.showsPickers([]))
    }

    @Test func theEnginesAndProvidersAreNamedAndSummarizedForThePicker() {
        #expect(BrowserEngineKind.allCases.map(\.label) == ["Leitura simples", "Chrome", "Obscura", "CloakBrowser"])
        #expect(SearchProvider.allCases.map(\.label) == ["DuckDuckGo", "Google", "TinyFish"])
        for engine in BrowserEngineKind.allCases { #expect(!engine.summary.isEmpty && !engine.summary.hasSuffix("\n")) }
        for provider in SearchProvider.allCases { #expect(!BrowserPickerCopy.searchSummary(provider).isEmpty) }
        // The default is the one a new Orb gets.
        #expect(BrowserEngineKind.default == .chrome && Bot(name: "A", role: "", orb: OrbConfig()).searchProvider == .duckduckgo)
    }

    @Test func anInstalledEngineIsReadyAndTheSimpleOneNeedsNothing() {
        let ready = BrowserPickerCopy.engineLine(.chrome, status: BrowserEngineStatus(engine: .chrome, agentBrowser: "/fake/agent-browser"))
        #expect(ready == BrowserPickerCopy.Line(text: "Pronto", tone: .ready))
        let simple = BrowserPickerCopy.engineLine(.simple, status: nil)
        #expect(simple.tone == .ready && simple.action == nil && simple.text.contains("nada"))
    }

    @Test func aMissingEngineSaysWhatIsMissingAndSendsToAjustes() {
        let line = BrowserPickerCopy.engineLine(.chrome, status: missing(.chrome, "agent-browser", "Chrome"))
        #expect(line.tone == .warning && line.action == .installEngine)
        #expect(line.text.hasPrefix("Não instalado") && line.text.contains("agent-browser e Chrome") && line.text.contains("só lê"))
        #expect(BrowserPickerCopy.Action.installEngine.title == "Instalar em Ajustes")
        #expect(line.symbol == "exclamationmark.triangle.fill")
        // While it is being looked for there is no verdict yet.
        let checking = BrowserPickerCopy.engineLine(.cloak, status: nil)
        #expect(checking.tone == .neutral && checking.action == nil)
    }

    @Test func tinyFishWithoutAKeySaysSoAndSendsToAjustes() {
        let none = BrowserPickerCopy.searchLine(.tinyfish, engine: .chrome, browserIsReady: true, hasKey: false)
        #expect(none?.tone == .warning && none?.action == .addSearchKey && none?.text.contains("Sem chave") == true)
        #expect(none?.text.contains("DuckDuckGo") == true, "says where the search goes meanwhile")
        #expect(BrowserPickerCopy.Action.addSearchKey.title == "Adicionar em Ajustes")
        #expect(BrowserPickerCopy.searchLine(.tinyfish, engine: .chrome, browserIsReady: true, hasKey: true)?.tone == .ready)
        #expect(BrowserPickerCopy.searchLine(.tinyfish, engine: .chrome, browserIsReady: true, hasKey: nil) == nil, "still being read")
    }

    @Test func googleNeedsTheOrbsBrowserAndDuckDuckGoNeedsNothing() {
        #expect(BrowserPickerCopy.searchLine(.duckduckgo, engine: .simple, browserIsReady: nil, hasKey: nil) == nil)
        #expect(BrowserPickerCopy.searchLine(.google, engine: .chrome, browserIsReady: true, hasKey: nil) == nil)
        #expect(BrowserPickerCopy.searchLine(.google, engine: .chrome, browserIsReady: nil, hasKey: nil) == nil, "not known yet")
        let notInstalled = BrowserPickerCopy.searchLine(.google, engine: .chrome, browserIsReady: false, hasKey: nil)
        #expect(notInstalled?.action == .installEngine && notInstalled?.text.contains("DuckDuckGo") == true)
        // With the simple engine there is nothing to install: the line only explains.
        let simple = BrowserPickerCopy.searchLine(.google, engine: .simple, browserIsReady: true, hasKey: nil)
        #expect(simple?.tone == .warning && simple?.action == nil)
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
    deinit { try? FileManager.default.removeItem(at: root) }

    @MainActor private func model(vault: (any SecretVault)? = nil) -> (AppModel, UUID) {
        var state = AppState.initial
        state.bots.append(Bot(name: "Atlas", role: "", orb: OrbConfig()))
        Store(directory: root).save(state)
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false, secretVault: vault ?? MemoryVault())
        return (model, model.bots[0].id)
    }

    @Test @MainActor func changingTheEngineSavesItAndClosesTheBrowserTheOrbHadOpen() async throws {
        let (model, botID) = model()
        let setup = FakeBrowserSetup(engine: .chrome)
        model.browserHub = setup.hub
        _ = try await setup.hub.session(botID: botID, engine: .chrome)
        #expect(model.bot(botID)?.browserEngine == .chrome)

        model.setBrowserEngine(.cloak, for: botID)
        #expect(model.bot(botID)?.browserEngine == .cloak)
        await waitUntil("the old browser to close") { setup.driver.calls.contains("close") }
        #expect(setup.hub.existingSession(botID: botID) == nil)
    }

    @Test @MainActor func choosingTheSameEngineAgainLeavesTheBrowserAlone() async throws {
        let (model, botID) = model()
        let setup = FakeBrowserSetup(engine: .chrome)
        model.browserHub = setup.hub
        _ = try await setup.hub.session(botID: botID, engine: .chrome)
        model.setBrowserEngine(.chrome, for: botID)
        try await Task.sleep(for: .milliseconds(50))
        #expect(setup.driver.calls.isEmpty && setup.hub.existingSession(botID: botID) != nil)
    }

    /// The browser may have been started by another process (the tools server of a Claude Code turn): the app holds no session
    /// for it, but the engine it leaves is closed all the same, through the session name the two share.
    @Test func leavingAnEngineClosesTheBrowserAnotherProcessStarted() async {
        let setup = FakeBrowserSetup(engine: .chrome)
        let botID = UUID()
        await setup.hub.close(botID: botID, leaving: .chrome)
        #expect(setup.driver.calls == ["close"])
        #expect(setup.configs.withLock { $0.map(\.session) } == [AgentBrowserConfig.sessionName(botID: botID, engine: .chrome)])
        // The simple engine has no browser to close.
        let none = FakeBrowserSetup(engine: .chrome)
        await none.hub.close(botID: botID, leaving: .simple)
        #expect(none.driver.calls.isEmpty)
    }

    @Test func theSessionOfAnotherEngineIsNotClosedByMistake() async throws {
        let setup = FakeBrowserSetup(engine: .obscura)
        let botID = UUID()
        _ = try await setup.hub.session(botID: botID, engine: .obscura)
        await setup.hub.close(botID: botID, leaving: .cloak) // asks for the cloak session by name, not the obscura one
        #expect(setup.hub.existingSession(botID: botID)?.engine == .obscura)
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
