import Foundation
import Testing
@testable import Orb

/// The first seconds of a launch and the first use of a model: what the app says while the connections are still being
/// looked at, and which model a new connection makes the default. Nothing here reads the Keychain or the network.
@Suite(.serialized) final class FirstLaunchFlowTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbFirstLaunch-\(UUID().uuidString)")

    deinit { removeTestFolder(root, sealing: root.appending(path: "dados")) }

    @MainActor private func makeModel() -> AppModel {
        AppModel(store: Store(directory: root.appending(path: "dados")), runsBackgroundWork: false)
    }

    // MARK: Before the connections are known

    @Test func theSetupPromptWaitsForTheConnectionsAndForAnOrbWithoutAModel() {
        #expect(!SetupPrompt.shows(connectionsChecked: false, orbHasModel: false, connectedName: nil, hasItems: true))
        #expect(SetupPrompt.shows(connectionsChecked: true, orbHasModel: false, connectedName: nil, hasItems: true))
        #expect(!SetupPrompt.shows(connectionsChecked: true, orbHasModel: true, connectedName: nil, hasItems: true))
        #expect(!SetupPrompt.shows(connectionsChecked: true, orbHasModel: false, connectedName: nil, hasItems: false), "an empty chat has the card instead")
        // The "Pronto" beat and the snapshots show it regardless.
        #expect(SetupPrompt.shows(connectionsChecked: false, orbHasModel: true, connectedName: "Ollama", hasItems: false))
        #expect(SetupPrompt.shows(connectionsChecked: false, orbHasModel: true, connectedName: nil, hasItems: false, alwaysShown: true))
    }

    @Test @MainActor func anOrbWithAModelOfItsOwnDoesNotAskForOneBecauseTheDefaultIsDown() {
        let model = makeModel()
        model.providers = []
        model.addProvider(.chatgpt)
        model.addProvider(.ollama)
        model.defaultModel = "chatgpt/gpt-5" // signed out: not in `connected`
        let id = model.bots[0].id
        model.update(id) { $0.model = "ollama/qwen3" }
        #expect(!model.isProviderReady)
        #expect(model.hasUsableModel(id))
        #expect(!SetupPrompt.shows(connectionsChecked: model.hasCheckedConnections, orbHasModel: model.hasModelSetup(for: id),
                                   connectedName: nil, hasItems: true))
    }

    @Test @MainActor func anOrbWhoseOwnModelIsDownWhileTheDefaultWorksGetsNoCardButTheNotice() {
        let model = makeModel()
        model.providers = []
        model.addProvider(.ollama)
        model.addProvider(.chatgpt)
        model.defaultModel = "ollama/qwen3"
        let id = model.bots[0].id
        model.update(id) { $0.model = "chatgpt/gpt-5" } // signed out: not in `connected`
        #expect(model.isProviderReady)
        #expect(!model.hasUsableModel(id))
        #expect(model.hasModelSetup(for: id), "the card connects the default model, which already works")
        #expect(!SetupPrompt.shows(connectionsChecked: true, orbHasModel: model.hasModelSetup(for: id), connectedName: nil, hasItems: true))
        let before = model.setupNudge
        #expect(!model.send("oi", to: id, fromUser: true))
        #expect(model.setupNudge == before, "no card to pulse")
        #expect(model.orbTranscript(id).items.count == 1, "the notice says where to fix it")
        // With neither working, the card is offered again.
        model.defaultModel = "chatgpt/gpt-5"
        #expect(!model.hasModelSetup(for: id))
    }

    @Test @MainActor func sendingBeforeTheConnectionsAreKnownDoesNotNudgeNorWriteANotice() {
        let model = makeModel()
        model.providers = []
        model.defaultModel = "chatgpt/gpt-5"
        model.addProvider(.chatgpt)
        let id = model.bots[0].id
        model.beginConnectionCheck()
        let before = model.setupNudge
        #expect(!model.send("oi", to: id, fromUser: true))
        #expect(!model.send("oi", to: id))
        #expect(model.setupNudge == before)
        #expect(model.orbTranscript(id).items.isEmpty)
        // Once the look is over and nothing is connected, the nudge is back.
        model.publishConnections([])
        #expect(!model.send("oi", to: id, fromUser: true))
        #expect(model.setupNudge == before + 1)
    }

    @Test @MainActor func whoWaitsForTheConnectionsIsReleasedWhenTheLookEnds() async {
        let model = makeModel()
        model.beginConnectionCheck()
        let released = Task { @MainActor in
            await model.connectionsChecked()
            return model.hasCheckedConnections
        }
        for _ in 0..<500 where model.connectionWaiterCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(model.connectionWaiterCount == 1)
        model.publishConnections([.openai])
        #expect(await released.value)
        await model.connectionsChecked() // already checked: returns at once
    }

    // MARK: The default model of a new connection

    private func models(_ ids: String...) -> [ProviderModel] { ids.map { ProviderModel(id: $0, name: $0, format: .chat) } }

    @Test func aModelThatEmbedsIsNotChosenToTalkTo() {
        #expect(ModelCatalog.preferredDefault(models("all-minilm", "bge-m3", "qwen3:8b"))?.id == "qwen3:8b")
        #expect(ModelCatalog.preferredDefault(models("mxbai-embed-large", "nomic-embed-text"))?.id == "mxbai-embed-large", "none chats: the first")
        #expect(ModelCatalog.preferredDefault([]) == nil)
        #expect(!ModelCatalog.isChatModel("mxbai-embed-large"))
        #expect(!ModelCatalog.isChatModel("text-embedding-3-small"))
        #expect(!ModelCatalog.isChatModel("bge-reranker-v2"))
        #expect(ModelCatalog.isChatModel("llama3.1"))
        #expect(ModelCatalog.isChatModel("gpt-oss:20b"))
    }

    @Test @MainActor func connectingOllamaDoesNotMakeAnEmbeddingModelTheDefault() async throws {
        let model = makeModel()
        model.providers = []
        model.defaultModel = ""
        model.loadModels = { _ in self.models("bge-m3", "qwen3:8b") }
        model.addProvider(.ollama)
        try await model.refreshModels(.ollama)
        #expect(model.defaultModel == "ollama/qwen3:8b")
        #expect(model.account(.ollama)?.models.map(\.id) == ["bge-m3", "qwen3:8b"], "the list itself is kept")
    }

    @Test @MainActor func adoptingASignedOutDefaultSkipsTheEmbeddingModelToo() {
        let model = makeModel()
        model.providers = []
        model.addProvider(.xai)
        model.defaultModel = "xai/grok-4" // no key: unusable
        model.addProvider(.lmstudio)
        model.updateProvider(.lmstudio) { $0.models = self.models("text-embedding-nomic-embed-text-v1.5", "qwen2.5-7b") }
        #expect(model.adoptDefaultModel(from: .lmstudio))
        #expect(model.defaultModel == "lmstudio/qwen2.5-7b")
    }

    // MARK: Connecting from Ajustes

    @Test @MainActor func aGatewayModelAddedByHandBecomesTheDefaultWhenNothingElseWorks() {
        let model = makeModel()
        model.providers = []
        model.defaultModel = ""
        model.addProvider(.custom)
        #expect(!model.isProviderReady)
        model.addManualModel("  claude-sonnet  ")
        #expect(model.account(.custom)?.models.map(\.id) == ["claude-sonnet"])
        #expect(model.account(.custom)?.models.first?.isManual == true)
        #expect(model.defaultModel == "custom/claude-sonnet")
        #expect(model.isProviderReady)
        // The second one is only added: a default that works is left alone.
        model.addManualModel("outro")
        #expect(model.account(.custom)?.models.map(\.id) == ["claude-sonnet", "outro"])
        #expect(model.defaultModel == "custom/claude-sonnet")
        model.addManualModel("outro")
        #expect(model.account(.custom)?.models.count == 2)
    }

    @Test @MainActor func aRefreshAsksTheDefaultToGiveWayButNeverSwitchesAProviderBackOn() async throws {
        let model = makeModel()
        model.providers = []
        model.addProvider(.chatgpt)
        model.defaultModel = "chatgpt/gpt-5" // its login was revoked: not in `connected`
        model.loadModels = { _ in self.models("qwen3") }
        model.addProvider(.ollama)
        // Refreshing the list alone leaves the default as it is (a passing failure must not change the choice).
        try await model.refreshModels(.ollama)
        await model.refreshAllModels()
        #expect(model.defaultModel == "chatgpt/gpt-5")
        model.updateProvider(.ollama) { $0.isEnabled = false }
        #expect(!model.adoptDefaultModel(from: .ollama, turningOn: false))
        #expect(model.account(.ollama)?.isEnabled == false)
        model.updateProvider(.ollama) { $0.isEnabled = true }
        #expect(model.adoptDefaultModel(from: .ollama, turningOn: false))
        #expect(model.defaultModel == "ollama/qwen3")
    }

    // MARK: Trying ChatGPT again

    /// A browser login that works and a model list that fails the first `failures` times.
    @MainActor private func chatGPTRun(failures: Int) -> (model: AppModel, steps: FirstRunModel, counts: Counts) {
        let model = makeModel()
        model.providers = []
        model.defaultModel = ""
        model.connectionSources.keyedProviders = { [] }
        model.connectionSources.hasChatGPTCredential = { true } // the login is in the keychain
        let counts = Counts()
        model.loadModels = { _ in
            counts.lists += 1
            if counts.lists <= failures { throw URLError(.timedOut) }
            return self.models("gpt-5")
        }
        let steps = FirstRunModel()
        steps.attach(model)
        steps.readyDelay = .milliseconds(1)
        steps.signInChatGPT = { model in // like `AppModel.signIn`: the login, then the list
            counts.logins += 1
            model.addProvider(.chatgpt)
            await model.refreshConnections()
            try await model.refreshModels(.chatgpt)
        }
        return (model, steps, counts)
    }

    @MainActor private final class Counts { var logins = 0, lists = 0 }

    @MainActor private func retried(_ steps: FirstRunModel, _ model: AppModel) async {
        steps.retry(model: model)
        for _ in 0..<200 where steps.working != nil { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test @MainActor func tryingChatGPTAgainAfterAFailedListDoesNotAskForAnotherLogin() async {
        let (model, steps, counts) = chatGPTRun(failures: 1)
        #expect(await steps.connectChatGPT(model: model).value == false)
        #expect(steps.failure?.choice == .chatgpt)
        await retried(steps, model)
        #expect(counts.logins == 1)
        #expect(counts.lists == 2)
        #expect(model.defaultModel == "chatgpt/gpt-5")
    }

    @Test @MainActor func aLoginTheListKeepsRefusingIsSignedInAgainAfterOneRetry() async {
        let (model, steps, counts) = chatGPTRun(failures: 2)
        #expect(await steps.connectChatGPT(model: model).value == false)
        await retried(steps, model) // reuses the login once
        #expect(counts.logins == 1)
        #expect(steps.failure != nil)
        await retried(steps, model) // still refused: the browser again
        #expect(counts.logins == 2)
        #expect(model.defaultModel == "chatgpt/gpt-5")
    }

    @Test @MainActor func aLoginThatIsStillInTheKeychainFromBeforeStartsWithTheBrowser() async {
        let (model, steps, counts) = chatGPTRun(failures: 0)
        #expect(await steps.connectChatGPT(model: model).value)
        #expect(counts.logins == 1)
    }

    @Test @MainActor func withoutALoginChatGPTOpensTheBrowser() async {
        let model = makeModel()
        model.providers = []
        model.connectionSources.keyedProviders = { [] }
        model.connectionSources.hasChatGPTCredential = { false }
        let steps = FirstRunModel()
        steps.attach(model)
        var logins = 0
        steps.signInChatGPT = { _ in logins += 1; throw URLError(.cancelled) }
        _ = await steps.connectChatGPT(model: model).value
        #expect(logins == 1)
    }

    // MARK: The gateway's optional key

    @Test @MainActor func theGatewaysSavedKeyIsKnownWithoutMakingItNeedOne() async {
        let model = makeModel()
        model.providers = []
        model.addProvider(.custom)
        model.addProvider(.openai)
        model.connectionSources.hasChatGPTCredential = { false }
        model.connectionSources.keyedProviders = { [.custom] }
        await model.refreshConnections()
        #expect(model.storedKeys == [.custom])
        #expect(!model.connected.contains(.custom))
        #expect(model.account(.custom).map(model.isUsable) == true, "a gateway works without a key")
        #expect(model.account(.openai).map(model.isUsable) == false)
        model.connectionSources.keyedProviders = { Set(ProviderKind.allCases.filter(\.storesKey)) }
        await model.refreshConnections()
        #expect(model.storedKeys.contains(.custom) && model.storedKeys.contains(.openai))
        #expect(model.connected.contains(.openai) && !model.connected.contains(.custom))
        #expect(ProviderKind.custom.storesKey)
        #expect(!ProviderKind.ollama.storesKey)
        #expect(ProviderKind.openai.storesKey)
    }
}
