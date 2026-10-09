import Foundation
import Testing
@testable import Orb

/// The welcome screen: which step it is in, what it says, which Orb the window chooses with and without Orbs, the Orb
/// it suggests (made in a temporary folder, never `~/Orbs`) and the line under a kept memory.
@Suite(.serialized) final class WelcomeTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbWelcome-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

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
