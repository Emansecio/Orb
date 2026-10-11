import Foundation
import Testing
@testable import Orb

/// What a new Orb says first: the words, when it is made, what each quick reply does, and that the model never sees it.
@Suite(.serialized) final class GreetingTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbGreeting-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    /// A model with a usable provider (no address: a turn fails before any network call) and a new Orb made the way the sheet makes it.
    @MainActor private func model() -> (AppModel, Bot) {
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        let bot = model.createBot(name: "Lia", role: "", orb: OrbConfig(), model: "", mode: .ask, folder: .home)
        model.saveNow() // no save timer left pending when the folder goes
        return (model, bot)
    }

    @MainActor private func items(_ model: AppModel, _ bot: Bot) -> [TranscriptItem.Kind] {
        (model.loadedConversation(bot.id)?.items ?? []).map(\.kind)
    }

    // MARK: The words

    @Test func itSpeaksWithTheOrbsNameAndTheTemperamentTintsTheTone() {
        let texts = OrbTemperament.allCases.map { OrbGreeting.text(name: "Lia", temperament: $0, returning: false) }
        #expect(texts.allSatisfy { $0.contains("Lia") })
        #expect(Set(texts).count == texts.count)
    }

    @Test func aKeptMemoryIsGreetedAsSomeoneWhoKnowsYou() {
        let text = OrbGreeting.text(name: "Lia", temperament: .animado, returning: true)
        #expect(text.hasPrefix("Que bom te ver de novo!"))
        #expect(text == OrbGreeting.text(name: "Lia", temperament: .calmo, returning: true))
    }

    // MARK: When it appears

    @Test @MainActor func aNewOrbHasOnlyItsGreetingAndTheModelNeverSeesIt() {
        let (model, bot) = model()
        let conversation = model.loadedConversation(bot.id)
        #expect(conversation?.items.count == 1)
        #expect(conversation?.items.first?.kind == .greeting(OrbGreeting.text(name: "Lia", temperament: .equilibrado, returning: false)))
        #expect(conversation?.messages.isEmpty == true)
        #expect(conversation?.hasUserMessages == false) // so it is never archived on its own
        #expect(SessionSummary.page(from: conversation?.items ?? []) == nil) // nor does it become a memory page
    }

    @Test @MainActor func theGreetingIsSavedWithTheConversation() throws {
        let (model, bot) = model()
        let saved = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(try #require(model.loadedConversation(bot.id))))
        #expect(saved.items.count == 1 && saved.items[0].kind == model.loadedConversation(bot.id)?.items[0].kind)
    }

    @Test func onlyTheOrbsOwnWordsCarryTheLivingAvatar() {
        #expect(TranscriptItem.Kind.greeting("Oi").isReply)
        #expect(TranscriptItem.Kind.bot(text: "Oi", isStreaming: false).isReply)
        #expect(!TranscriptItem.Kind.notice("Oi").isReply)
    }

    // MARK: The replies

    @Test @MainActor func tellingYourselfOnlyStartsTheMessageAndFocusesTheField() {
        let (model, bot) = model()
        model.answerGreeting(.tell, for: bot.id)
        #expect(model.drafts[bot.id] == "Quero que você me ajude com ")
        #expect(model.takeChatRequest(.focusComposer, of: bot.id))
        #expect(items(model, bot).count == 1) // nothing was sent
    }

    @Test @MainActor func theInterviewReplySendsTheSameRequestAsTheEmptyChatShortcut() async {
        let (model, bot) = model()
        model.answerGreeting(.interview, for: bot.id)
        #expect(items(model, bot).contains(.user(text: EmptyChatContent.interviewRequest, attachments: [])))
        await waitUntil("the turn to end") { !model.isWorking(bot.id) }
    }

    @Test @MainActor func theAbilitiesReplySendsItsQuestionAsTheUsersMessage() async {
        let (model, bot) = model()
        model.answerGreeting(.abilities, for: bot.id)
        #expect(items(model, bot).contains(.user(text: "O que você sabe fazer?", attachments: [])))
        await waitUntil("the turn to end") { !model.isWorking(bot.id) }
    }

    @Test @MainActor func withoutAModelARepliesPulsesTheConnectCardAndLeavesTheChatAsItWas() {
        let (model, bot) = model()
        model.providers = []
        let nudges = model.setupNudge
        model.answerGreeting(.abilities, for: bot.id)
        #expect(model.setupNudge == nudges + 1)
        #expect(items(model, bot).count == 1) // the greeting is still the last item: its replies stay
    }
}
