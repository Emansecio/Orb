import Foundation
import Testing
@testable import Orb

/// The welcome screen: which step it is in, what it says, which Orb the window chooses with and without Orbs, the Orb
/// it suggests (made in a temporary folder, never `~/Orbs`) and the line under a kept memory.
@Suite(.serialized) final class WelcomeTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbWelcome-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    /// A model with no Orbs at all (a data folder whose state has an empty list), in memory preferences.
    @MainActor private func emptyModel() throws -> AppModel {
        let folder = root.appending(path: "dados")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"bots":[]}"#.utf8).write(to: folder.appending(path: "state.json"))
        return AppModel(store: Store(directory: folder), runsBackgroundWork: false)
    }

    // MARK: The step

    @Test func withoutAModelTheCardConnectsOne() {
        #expect(WelcomeStage.resolve(providerReady: false, connectedName: nil, keptCount: 0) == .connect)
        #expect(WelcomeStage.resolve(providerReady: false, connectedName: nil, keptCount: 3) == .connect)
    }

    @Test func theCardStaysForTheReadyBeatOfAModelJustConnected() {
        #expect(WelcomeStage.resolve(providerReady: true, connectedName: "Claude Code", keptCount: 0) == .connect)
        #expect(WelcomeStage.resolve(providerReady: true, connectedName: nil, keptCount: 0) == .create)
    }

    @Test func keptMemoriesOnlyShowOnceAModelIsReady() {
        #expect(WelcomeStage.resolve(providerReady: true, connectedName: nil, keptCount: 1) == .createWithKept)
        #expect(WelcomeStage.resolve(providerReady: false, connectedName: nil, keptCount: 1) == .connect)
        #expect(WelcomeStage.createWithKept.showsConnectCard == false)
        #expect(WelcomeStage.connect.showsConnectCard)
    }

    @Test func untilTheConnectionsAreCheckedTheScreenOnlyKeepsThePlaceOfTheAction() {
        for ready in [true, false] {
            #expect(WelcomeStage.resolve(providerReady: ready, connectedName: nil, keptCount: 2, connectionsChecked: false) == .checking)
        }
        #expect(!WelcomeStage.checking.showsConnectCard)
        #expect(WelcomeStage.resolve(providerReady: true, connectedName: nil, keptCount: 0, connectionsChecked: true) == .create)
    }

    @Test func onlyAModelConnectedOnTheCardCelebrates() {
        #expect(WelcomeStage.celebrates(old: .connect, new: .create, viaCard: true))
        #expect(WelcomeStage.celebrates(old: .connect, new: .createWithKept, viaCard: true))
        // The first look at the connections found a model: no party, no announcement.
        #expect(!WelcomeStage.celebrates(old: .checking, new: .create, viaCard: false))
        #expect(!WelcomeStage.celebrates(old: .checking, new: .create, viaCard: true))
        #expect(!WelcomeStage.celebrates(old: .connect, new: .create, viaCard: false))
        #expect(!WelcomeStage.celebrates(old: .create, new: .createWithKept, viaCard: true))
        #expect(!WelcomeStage.celebrates(old: .connect, new: .connect, viaCard: true))
    }

    @Test @MainActor func aModelThatIsNotTheRunningAppNeverWaitsForTheConnections() throws {
        #expect(try emptyModel().hasCheckedConnections)
    }

    @Test func theKeptListIsReadAgainWhenAMemoryArrives() {
        #expect(WelcomeKeptKey(listIsEmpty: true, keptVersion: 0) != WelcomeKeptKey(listIsEmpty: true, keptVersion: 1))
        #expect(WelcomeKeptKey(listIsEmpty: true, keptVersion: 0) != WelcomeKeptKey(listIsEmpty: false, keptVersion: 0))
        #expect(WelcomeKeptKey(listIsEmpty: true, keptVersion: 2) == WelcomeKeptKey(listIsEmpty: true, keptVersion: 2))
    }

    @Test @MainActor func deletingTheLastOrbWithItsMemoryBumpsTheVersionOnceItIsKept() async throws {
        let model = try emptyModel()
        let bot = model.createBot(name: "Nina", role: "Cuida da agenda", orb: OrbConfig(), model: "", mode: .ask, folder: .home)
        await model.memory.bank(for: bot.id).ensureIdentity(notes: "Seja gentil.", interview: false)
        let before = model.keptMemoriesVersion
        let keeping = try #require(model.deleteBot(bot.id, keepMemory: true))
        _ = await keeping.value
        for _ in 0..<200 where model.keptMemoriesVersion == before { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.keptMemoriesVersion == before + 1)
        #expect(KeptMemories.list(in: model.memory.root).map(\.name) == ["Nina"])
    }

    @Test @MainActor func orbsFromAnEarlierVersionCountAsHavingMadeOne() throws {
        let folder = root.appending(path: "antigo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel(store: Store(directory: folder), runsBackgroundWork: false)
        #expect(!model.botIDs.isEmpty) // the first run's Atlas
        #expect(model.welcomeCopy == .returning)
    }

    // MARK: What it says

    @Test func theTitleDiffersBetweenFirstUseAndAnEmptiedList() {
        #expect(WelcomeCopy.firstUse.title == "Olá! Este é o Orb.")
        #expect(WelcomeCopy.returning.title == "Hora de um Orb novo")
        #expect(WelcomeCopy.firstUse.subtitle == WelcomeCopy.returning.subtitle)
        #expect(WelcomeCopy.firstUse.createTitle == "Criar meu primeiro Orb")
        #expect(WelcomeCopy.returning.createTitle != WelcomeCopy.firstUse.createTitle)
        #expect(WelcomeCopy.firstUse.invitationTitle == "Criar seu primeiro Orb")
        #expect(WelcomeCopy.returning.invitationTitle == "Criar um novo Orb")
    }

    @Test func thereAreThreePointsWithDistinctTitles() {
        #expect(WelcomeCopy.points.map(\.title) == ["Conversa e faz", "Pede antes de agir", "Lembra de você"])
        #expect(Set(WelcomeCopy.points.map(\.symbol)).count == 3)
    }

    @Test func theHeroLooksAreFixedAndDistinct() {
        #expect(WelcomeLooks.atlas == AppState.initial.bots[0].orb)
        #expect(Set([WelcomeLooks.atlas.color, WelcomeLooks.lia.color, WelcomeLooks.bento.color]).count == 3)
        #expect(WelcomeLooks.lia.temperament == .timido)
        #expect(WelcomeLooks.bento.temperament == .curioso)
    }

    @Test @MainActor func theFirstSentenceChangesAfterAnOrbWasMade() throws {
        let model = try emptyModel()
        #expect(model.welcomeCopy == .firstUse)
        model.createBot(name: "Lia", role: "", orb: OrbConfig(), model: "", mode: .ask, folder: .home)
        #expect(model.welcomeCopy == .returning)
    }

    @Test @MainActor func aDeveloperRunKeepsItInMemoryAndTheRunningAppUsesItsPreferences() throws {
        let model = try emptyModel()
        // `runsBackgroundWork: false` (tests) and developer runs never write the app's own preferences.
        #expect(model.welcomePreferences is InMemoryPreferences)
        let other = InMemoryPreferences()
        #expect(other.object(forKey: AppModel.createdOrbKey) == nil)
        other.set(true, forKey: AppModel.createdOrbKey)
        #expect(other.object(forKey: AppModel.createdOrbKey) as? Bool == true)
    }

    // MARK: The selection

    @Test func withOrbsNothingChosenBecomesTheFirstOrb() {
        let ids = [UUID(), UUID()]
        #expect(WelcomeSelection.resolved(nil, botIDs: ids) == .bot(ids[0]))
    }

    @Test func aDeletedOrbBecomesTheFirstOneLeft() {
        let ids = [UUID(), UUID()]
        #expect(WelcomeSelection.resolved(.bot(UUID()), botIDs: ids) == .bot(ids[0]))
        #expect(WelcomeSelection.resolved(.bot(ids[1]), botIDs: ids) == .bot(ids[1]))
    }

    @Test func theWorkspacePagesStayWhereTheyAre() {
        let ids = [UUID()]
        for page in [SidebarItem.routines, .connectors, .skills] {
            #expect(WelcomeSelection.resolved(page, botIDs: ids) == page)
            #expect(WelcomeSelection.resolved(page, botIDs: []) == page)
        }
    }

    @Test func withoutOrbsAnOrbsChatBecomesTheWelcomeScreen() {
        #expect(WelcomeSelection.resolved(.bot(UUID()), botIDs: []) == nil)
        #expect(WelcomeSelection.resolved(nil, botIDs: []) == nil)
    }

    @Test @MainActor func deletingTheLastOrbShowsTheWelcomeSelection() throws {
        let model = try emptyModel()
        let bot = model.createBot(name: "Lia", role: "", orb: OrbConfig(), model: "", mode: .ask, folder: .home)
        #expect(model.selection == .bot(bot.id))
        _ = model.deleteBot(bot.id)
        #expect(model.botIDs.isEmpty)
        #expect(WelcomeSelection.resolved(model.selection, botIDs: model.botIDs) == nil)
    }

    // MARK: The suggested Orb

    @Test @MainActor func theSuggestedOrbIsTheAtlasInAFolderOfItsOwn() throws {
        let model = try emptyModel()
        let base = root.appending(path: "Orbs")
        let bot = model.createSuggestedOrb(base: base)
        #expect(bot.name == "Atlas")
        #expect(bot.role == "Assistente do seu Mac")
        #expect(bot.orb == WelcomeLooks.atlas)
        #expect(bot.permissionMode == .ask)
        let folder = URL(filePath: bot.workingDirectory)
        #expect(folder.lastPathComponent == "Atlas")
        #expect(folder.deletingLastPathComponent().lastPathComponent == "Orbs")
        #expect(FileManager.default.fileExists(atPath: base.appending(path: "Atlas").path))
        #expect(model.selection == .bot(bot.id))
        #expect(model.botIDs == [bot.id])
    }

    @Test @MainActor func aSecondSuggestedOrbDoesNotShareTheFolder() throws {
        let model = try emptyModel()
        let base = root.appending(path: "Orbs")
        let first = model.createSuggestedOrb(base: base)
        let second = model.createSuggestedOrb(base: base)
        #expect(first.workingDirectory != second.workingDirectory)
    }

    @Test @MainActor func startingFromAMemoryOpensTheSheetWithIt() throws {
        let model = try emptyModel()
        let memory = KeptMemory(id: "Nina – 2026-10-08 12.30", url: root, name: "Nina", date: .now, pageCount: 3, profile: nil)
        model.startNewOrb(from: memory)
        #expect(model.showNewBot)
        #expect(model.newBotStart == memory)
        model.startNewOrb(from: nil)
        #expect(model.newBotStart == nil)
    }

    // MARK: A kept memory's line

    private func memory(role: String?, pages: Int, name: String = "Nina") -> KeptMemory {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12))!
        let profile = role.map { KeptProfile(name: name, role: $0, orb: OrbConfig()) }
        return KeptMemory(id: name, url: root, name: name, date: date, pageCount: pages, profile: profile)
    }

    @Test func theDetailHasRoleDayAndCount() {
        #expect(memory(role: "Cuida da minha agenda", pages: 12).shortDetail == "Cuida da minha agenda · 8 de out. · 12 lembranças")
    }

    @Test func withoutARoleTheDetailIsDayAndCount() {
        #expect(memory(role: nil, pages: 1).shortDetail == "8 de out. · 1 lembrança")
        #expect(memory(role: "  ", pages: 5).shortDetail == "8 de out. · 5 lembranças")
    }

    @Test func voiceOverReadsTheWholeMemory() {
        #expect(memory(role: "Cuida da minha agenda", pages: 12).spokenSummary
                == "Continuar com a memória de Nina, 12 lembranças, 8 de outubro")
    }

    // MARK: The entrance

    @Test @MainActor func theEntrancePlaysOnceUntilTheListHasOrbsAgain() {
        let ledger = WelcomeLedger()
        #expect(WelcomeLedger.plays(ledger))
        ledger.notePlayed()
        #expect(!WelcomeLedger.plays(ledger)) // back from Rotinas: it does not repeat
        ledger.reset() // the list got an Orb
        #expect(WelcomeLedger.plays(ledger)) // and was emptied again
        #expect(!WelcomeLedger.plays(nil)) // a snapshot has no entrance
    }

    @Test func theEntranceOrderIsTheSpecifiedOne() {
        #expect(WelcomeEntrance.lia.delay == 0.06)
        #expect(WelcomeEntrance.bento.delay == 0.10)
        #expect(WelcomeEntrance.title.delay == 0.16)
        #expect(WelcomeEntrance.subtitle.delay == 0.20)
        #expect(WelcomeEntrance.point(0).delay == 0.26)
        #expect(abs(WelcomeEntrance.point(1).delay - 0.295) < 0.0001)
        #expect(abs(WelcomeEntrance.point(2).delay - 0.33) < 0.0001)
        #expect(WelcomeEntrance.actions.delay == 0.40)
        #expect(WelcomeEntrance.keptCard.delay == 0.44)
    }

    @Test func underReduceMotionEverythingFadesTogether() {
        for style in [WelcomeEntrance.atlas, WelcomeEntrance.lia, WelcomeEntrance.title, WelcomeEntrance.point(2), WelcomeEntrance.keptCard] {
            let resolved = style.resolved(reduceMotion: true)
            #expect(resolved.distance == 0)
            #expect(resolved.scale == 1)
        }
    }

    // MARK: The first-run card on the welcome screen

    @Test func theCardSpeaksOfTheFirstModelAndKeepsItsLink() {
        #expect(FirstRunStyle.welcome.title == "Primeiro, conecte um modelo")
        #expect(FirstRunStyle.welcome.subtitle.contains("Ajustes"))
        #expect(FirstRunStyle.welcome.showsSettingsLink)
        #expect(FirstRunStyle.chat(botName: "Lia").showsSettingsLink)
        #expect(!FirstRunStyle.settings.showsSettingsLink)
    }
}

// MARK: - One click: Claude Code ready, the Atlas made

extension WelcomeTests {
    private func loggedIn(plan: String = "max") -> ClaudeCodeStatus {
        ClaudeCodeStatus(isInstalled: true, isLoggedIn: true, authMethod: "claude.ai", email: "ana@exemplo.com", plan: plan)
    }

    @MainActor private func addOllama(_ model: AppModel) {
        model.providers = []
        model.defaultModel = ""
        model.addProvider(.ollama)
        model.updateProvider(.ollama) { $0.models = [ProviderModel(id: "m0", name: "m0", format: .chat)] }
        model.defaultModel = ModelRef(provider: .ollama, model: "m0").text
    }

    @MainActor private func steps(for model: AppModel, claude: ClaudeCodeStatus? = nil) -> FirstRunModel {
        let steps = FirstRunModel(claude: claude)
        steps.attach(model)
        steps.readyDelay = .milliseconds(150)
        return steps
    }

    // MARK: Which action is the big one

    @Test func claudeCodeInstalledAndLoggedInIsOfferedAsTheOneButton() throws {
        let offer = try #require(FirstRunOffer.resolve(claude: loggedIn()))
        #expect(offer.account == "ana@exemplo.com · Claude Max")
        #expect(offer.createsAtlas)
        #expect(offer.buttonTitle == "Usar meu Claude Code e começar")
        #expect(offer.detail == "Você já está conectado como ana@exemplo.com · Claude Max. Um clique conecta e cria o Atlas, seu primeiro Orb.")
        #expect(offer.accessibilityHint.contains("Atlas"))
    }

    @Test func nothingReadyKeepsTheCard() {
        #expect(FirstRunOffer.resolve(claude: nil) == nil, "still looking")
        #expect(FirstRunOffer.resolve(claude: ClaudeCodeStatus()) == nil, "not installed")
        #expect(FirstRunOffer.resolve(claude: ClaudeCodeStatus(isInstalled: true)) == nil, "installed, not logged in: the card's row opens the browser")
        #expect(FirstRunOffer.resolve(claude: ClaudeCodeStatus(isInstalled: false, isLoggedIn: true)) == nil)
    }

    @Test func keptMemoriesMakeTheClickOnlyConnect() throws {
        let offer = try #require(FirstRunOffer.resolve(claude: loggedIn(), keptCount: 2))
        #expect(!offer.createsAtlas, "the screen moves on to the memories that can start the new Orb")
        #expect(offer.buttonTitle == "Usar meu Claude Code")
        #expect(!offer.detail.contains("Atlas"))
        #expect(!offer.accessibilityHint.contains("Atlas"))
    }

    @Test @MainActor func theOfferIsDecidedByTheLookAndNotByTheConnectionRereadingTheStatus() {
        let given = FirstRunModel(claude: loggedIn())
        #expect(given.hasDetected)
        #expect(given.offer(keptCount: 0)?.createsAtlas == true)
        #expect(given.offer(keptCount: 1)?.createsAtlas == false)
        let waiting = FirstRunModel()
        #expect(!waiting.hasDetected, "the welcome screen keeps the place of its action until the look is over")
        #expect(waiting.offer(keptCount: 0) == nil)
        let notReady = FirstRunModel(claude: ClaudeCodeStatus(isInstalled: true))
        #expect(notReady.hasDetected && notReady.offer(keptCount: 0) == nil)
    }

    @Test func theScreenWaitsForTheLookBeforeShowingWhatStays() {
        // No model: the card (or the one button) comes only once Claude Code and the servers have been looked for.
        #expect(WelcomeStage.resolve(providerReady: false, connectedName: nil, keptCount: 0, detected: false) == .checking)
        #expect(WelcomeStage.resolve(providerReady: false, connectedName: nil, keptCount: 0, detected: true) == .connect)
        // A model that is already ready needs nothing from the look.
        #expect(WelcomeStage.resolve(providerReady: true, connectedName: nil, keptCount: 0, detected: false) == .create)
        // The connections come first, as before.
        #expect(WelcomeStage.resolve(providerReady: false, connectedName: nil, keptCount: 0, connectionsChecked: false, detected: true) == .checking)
    }

    @Test func theCardStaysWhileTheClickIsMakingTheAtlas() {
        #expect(WelcomeStage.resolve(providerReady: true, connectedName: nil, keptCount: 0, starting: true) == .connect)
        #expect(WelcomeStage.resolve(providerReady: true, connectedName: nil, keptCount: 0, starting: false) == .create)
        #expect(!WelcomeStage.celebrates(old: .connect, new: .create, viaCard: false), "the click never celebrates: the chat opens")
    }

    // MARK: The click

    @Test @MainActor func theClickConnectsAndMakesTheAtlasWithoutThePronto() async throws {
        let model = try emptyModel()
        let steps = steps(for: model, claude: loggedIn())
        let base = root.appending(path: "Orbs")
        let connecting = steps.connect(.claudeCode, kind: .ollama, name: "Claude Code", showsReady: false) { self.addOllama(model) }
        let started = steps.startingAtlas(after: connecting, model: model, base: base)
        #expect(steps.isStarting)
        #expect(await started.value)
        #expect(steps.connectedName == nil, "no beat of 'Pronto': it goes straight to the chat")
        #expect(!steps.isStarting && steps.working == nil)
        let atlas = try #require(model.bots.first)
        #expect(model.botIDs.count == 1 && atlas.name == "Atlas")
        #expect(model.selection == .bot(atlas.id), "it lands in the Atlas's chat")
        #expect(FileManager.default.fileExists(atPath: base.appending(path: "Atlas").path))
    }

    @Test @MainActor func aFailedConnectionMakesNoOrbAndLeavesTheButtonToTryAgain() async throws {
        let model = try emptyModel()
        model.providers = []
        model.defaultModel = ""
        let steps = steps(for: model, claude: loggedIn())
        let connecting = steps.connect(.claudeCode, kind: .claudeCode, name: "Claude Code", showsReady: false) {}
        let started = steps.startingAtlas(after: connecting, model: model, base: root.appending(path: "Orbs"))
        #expect(await started.value == false)
        #expect(model.botIDs.isEmpty)
        #expect(!steps.isStarting)
        #expect(steps.failure?.choice == .claudeCode)
        #expect(steps.offer(keptCount: 0) != nil, "the button is still there")
    }

    @Test @MainActor func anotherPathStartedMeanwhileTakesOverFromTheClick() async throws {
        let model = try emptyModel()
        let steps = steps(for: model, claude: loggedIn())
        let connecting = steps.connect(.claudeCode, kind: .ollama, name: "Claude Code", showsReady: false) {
            try await Task.sleep(for: .milliseconds(100))
            self.addOllama(model)
        }
        let started = steps.startingAtlas(after: connecting, model: model, base: root.appending(path: "Orbs"))
        let other = steps.connect(.local(.lmstudio), kind: .lmstudio, name: "LM Studio") { throw URLError(.cannotConnectToHost) }
        #expect(!steps.isStarting, "the latest path wins")
        #expect(await started.value == false)
        _ = await other.value
        #expect(model.botIDs.isEmpty, "the Atlas is made only by the click that is still the latest")
    }

    @Test @MainActor func anOrbMadeMeanwhileByAnotherWayIsNotFollowedByASecondOne() async throws {
        let model = try emptyModel()
        let steps = steps(for: model, claude: loggedIn())
        let connecting = steps.connect(.claudeCode, kind: .ollama, name: "Claude Code", showsReady: false) {
            self.addOllama(model)
            _ = model.createBot(name: "Lia", role: "", orb: OrbConfig(), model: "", mode: .ask, folder: .home)
        }
        #expect(await steps.startingAtlas(after: connecting, model: model, base: root.appending(path: "Orbs")).value == false)
        #expect(model.bots.map(\.name) == ["Lia"])
    }

    @Test @MainActor func withoutTheClickTheReadyBeatStaysForTheOtherPaths() async throws {
        let model = try emptyModel()
        let steps = steps(for: model)
        let task = steps.connect(.local(.ollama), kind: .ollama, name: "Ollama") { self.addOllama(model) }
        for _ in 0..<200 where steps.connectedName == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(steps.connectedName == "Ollama")
        #expect(await task.value)
    }
}

// MARK: - Routines with no Orb

extension WelcomeTests {
    @Test func theRoutineStartFollowsWhatTheAppHas() {
        #expect(RoutineStart.resolve(hasOrbs: true, isProviderReady: false) == .ready, "an Orb is all it takes")
        #expect(RoutineStart.resolve(hasOrbs: true, isProviderReady: true) == .ready)
        #expect(RoutineStart.resolve(hasOrbs: false, isProviderReady: true) == .createsAtlas)
        #expect(RoutineStart.resolve(hasOrbs: false, isProviderReady: false) == .needsModel)
        #expect(RoutineStart.resolve(hasOrbs: false, isProviderReady: false, connectionsChecked: false) == .waiting)
        #expect(RoutineStart.resolve(hasOrbs: true, isProviderReady: false, connectionsChecked: false) == .ready)
    }

    @Test @MainActor func withAnOrbTheRoutineOpensForIt() async throws {
        let model = try emptyModel()
        let lia = model.createBot(name: "Lia", role: "", orb: OrbConfig(), model: "", mode: .ask, folder: .home)
        model.selection = .routines
        let draft = try #require(await model.beginRoutine(from: RoutineTemplate.all[0], base: root.appending(path: "Orbs")))
        #expect(draft.botID == lia.id && draft.name == "Resumo da manhã")
        #expect(model.botIDs == [lia.id], "no Atlas is added to a list that has an Orb")
        #expect(model.selection == .routines)
    }

    @Test @MainActor func withAModelButNoOrbTheAtlasIsMadeAndTheEditorOpensForItOverRotinas() async throws {
        let model = try emptyModel()
        addOllama(model)
        model.selection = .routines
        #expect(model.routineStart == .createsAtlas)
        let base = root.appending(path: "Orbs")
        let draft = try #require(await model.beginRoutine(from: RoutineTemplate.all[1], base: base))
        let atlas = try #require(model.bots.first)
        #expect(model.botIDs.count == 1 && atlas.name == "Atlas")
        #expect(draft.botID == atlas.id)
        #expect(draft.name == "Organizar arquivos")
        #expect(model.selection == .routines, "the page stays: the sheet opens over Rotinas, not over a chat")
        #expect(FileManager.default.fileExists(atPath: base.appending(path: "Atlas").path))
        #expect(model.hasCreatedOrb)
        // A blank routine goes the same way, now that the Orb is there.
        let blank = try #require(await model.beginRoutine(base: base))
        #expect(blank.botID == atlas.id && blank.name.isEmpty)
        #expect(model.botIDs.count == 1, "only the first one makes the Atlas")
    }

    @Test @MainActor func withNoModelTheScreenForConnectingOpensWithAnExplanation() async throws {
        let model = try emptyModel()
        model.providers = []
        model.defaultModel = ""
        model.selection = .routines
        #expect(model.routineStart == .needsModel)
        let draft = await model.beginRoutine(from: RoutineTemplate.all[2], base: root.appending(path: "Orbs"))
        #expect(draft == nil)
        #expect(model.botIDs.isEmpty, "no Orb is made without a model to run it")
        #expect(model.selection == nil, "the welcome screen, with the card that connects a model")
        #expect(model.welcomeReason == .routine)
        #expect(WelcomeReason.routine.message == "Para criar uma rotina, primeiro conecte um modelo. Depois é só voltar em Rotinas.")
        // The note goes once an Orb exists.
        _ = model.createBot(name: "Lia", role: "", orb: OrbConfig(), model: "", mode: .ask, folder: .home)
        #expect(model.welcomeReason == nil)
    }

    @Test @MainActor func theRoutineWaitsForTheFirstLookAtTheConnections() async throws {
        let model = try emptyModel()
        addOllama(model)
        model.beginConnectionCheck()
        #expect(model.routineStart == .waiting)
        let base = root.appending(path: "Orbs")
        let pending = Task { await model.beginRoutine(base: base) }
        for _ in 0..<400 where model.connectionWaiterCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(model.botIDs.isEmpty, "nothing is decided before the answer")
        model.publishConnections([.ollama])
        let draft = await pending.value
        #expect(draft != nil)
        #expect(model.botIDs.count == 1)
    }
}

// MARK: - The sidebar's foot

extension WelcomeTests {
    @Test func theShortcutIsTheMenusCommandAndDoesNotNeedTheButton() {
        // ⌘N is the app menu's command (OrbApp), not a button of the list: its label stays in the catalog and the tips.
        #expect(AppShortcut.newBot.label == "⌘N")
        #expect(Tip.newBot().contains("⌘N"))
        #expect(Tip.createOrbSheet().contains("⌘N"))
    }
}
