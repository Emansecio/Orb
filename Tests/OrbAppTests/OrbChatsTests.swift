import Foundation
import Testing
@testable import Orb

// An Orb's conversations (`OrbChats`): each one has its own history and file, the memory is the Orb's, and opening another
// one while the Orb works lets the turn end in its own (`BotSession.workingChatID`), with what you write waiting for it.

private actor Calls {
    private(set) var seen: [[ChatMessage]] = []
    func record(_ messages: [ChatMessage]) { seen.append(messages) }
    var count: Int { seen.count }
}

/// Answers "resposta N" to every call, holding the first one until `gate` opens, and remembers what it was sent.
private struct Model: LLMClient {
    var calls = Calls()
    var gate: TestGate?

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await calls.record(messages)
                let number = await calls.count
                if number == 1 { await gate?.wait() }
                continuation.yield(.text("resposta \(number)"))
                continuation.yield(.finished(.done, nil))
                continuation.finish()
            }
        }
    }
}

struct OrbChatsListTests {
    @Test func aNewConversationGoesOnTopAndOnlyItsFirstMessageNamesIt() {
        let orb = UUID(), new = UUID()
        var chats = OrbChats(first: orb, updated: .distantPast)
        chats.add(new, at: .now)
        #expect(chats.active == new)
        #expect(chats.list.map(\.title) == [OrbChats.newTitle, OrbChats.firstTitle])

        chats.wrote("Analise a campanha de ontem\ncom detalhes", in: new, at: .now)
        #expect(chats.title(of: new) == "Analise a campanha de ontem com detalhes")
        chats.wrote("Outra coisa", in: new, at: .now)
        #expect(chats.title(of: new) == "Analise a campanha de ontem com detalhes")
        chats.wrote("oi", in: orb, at: .now)
        #expect(chats.list.map(\.id) == [orb, new], "the one you wrote in goes to the top")
        #expect(chats.title(of: orb) == OrbChats.firstTitle)
    }

    @Test func aLongFirstMessageIsCutAndABlankNameKeepsTheOldOne() {
        let orb = UUID(), new = UUID()
        var chats = OrbChats(first: orb, updated: .now)
        chats.add(new, at: .now)
        chats.wrote(String(repeating: "palavra ", count: 30), in: new, at: .now)
        let title = chats.title(of: new) ?? ""
        #expect(title.count <= OrbChats.titleLength && title.hasPrefix("palavra"))
        chats.rename(new, to: "   ")
        #expect(chats.title(of: new) == title)
        chats.rename(new, to: "  Orçamento  ")
        #expect(chats.title(of: new) == "Orçamento")
    }

    @Test func removingTheOneOnShowShowsTheNewestLeftAndTheLastOneStays() {
        let orb = UUID(), a = UUID(), b = UUID()
        var chats = OrbChats(first: orb, updated: .distantPast)
        chats.add(a, at: .now)
        chats.add(b, at: .now)
        chats.remove(b)
        #expect(chats.active == a)
        chats.remove(a)
        #expect(chats.isOnlyFirst(of: orb))
        chats.remove(orb)
        #expect(chats.list.map(\.id) == [orb], "the last one is never removed")
    }

    @Test func theSidebarShowsTheNewestThreeTheOneOnShowAndTheUnreadOnes() {
        let orb = UUID()
        var chats = OrbChats(first: orb, updated: .distantPast)
        let ids = (0..<6).map { _ in UUID() }
        for id in ids { chats.add(id, at: .now) } // newest first: 5, 4, 3, 2, 1, 0, then the Orb's first
        chats.active = orb
        #expect(SidebarChatList.visible(chats, showsAll: false).map(\.id) == [ids[5], ids[4], ids[3], orb])
        #expect(SidebarChatList.visible(chats, showsAll: true).count == 7)
        chats.markUnread(ids[1])
        #expect(SidebarChatList.visible(chats, showsAll: false).map(\.id) == [ids[5], ids[4], ids[3], ids[1], orb])
        chats.remove(ids[0]) // "1 mais…" would hide a single one: all show
        #expect(SidebarChatList.visible(chats, showsAll: false).count == 6)
    }

    @Test func somethingThatLandsUnseenMarksAConversationUntilItIsOpened() {
        let orb = UUID(), other = UUID()
        var chats = OrbChats(first: orb, updated: .distantPast)
        chats.add(other, at: .now)
        chats.markUnread(other)
        #expect(chats.list[0].unread == nil, "the one on show is being read")
        chats.active = orb
        chats.markUnread(other)
        #expect(chats.list[0].unread == true)
        chats.active = other
        #expect(chats.list[0].unread == nil)
        chats.markUnread(orb)
        chats.remove(other) // the one on show goes: the newest left is opened, and read
        #expect(chats.list[0].unread == nil)
    }

    @Test func theStripSaysWhichConversationTheOrbWorksOn() {
        #expect(ComposerAction.elsewhereStrip(chatTitle: "Análise", needsYou: false) == "Trabalhando em “Análise” · o que você escrever vai depois")
        #expect(ComposerAction.elsewhereStrip(chatTitle: "Análise", needsYou: true) == "“Análise” precisa de você")
        let long = ComposerAction.elsewhereStrip(chatTitle: String(repeating: "a", count: 80), needsYou: true)
        #expect(long == "“" + String(repeating: "a", count: ComposerAction.maxRoutineNameLength - 1) + "…” precisa de você")
        #expect(ComposerAction.queue.help(isRoutine: false, elsewhere: true) == "Enviar quando a outra conversa terminar (↩)")
    }
}

@Suite final class OrbChatsStoreTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbChatsStore-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    private func texts(_ read: StoreRead<Conversation>) -> [String] {
        (read.value?.items ?? []).compactMap { if case .user(let text, _) = $0.kind { text } else { nil } }
    }

    private func conversation(_ text: String) -> Conversation {
        var conversation = Conversation()
        conversation.items = [TranscriptItem(.user(text: text, attachments: []))]
        return conversation
    }

    @Test func eachConversationIsAFileOfItsOwnThatTheArchiveMergeLeavesAlone() {
        let store = Store(directory: root)
        let orb = UUID(), other = UUID(), second = conversation("segunda")
        store.save(conversation("primeira"), for: orb)
        store.save(second, for: orb, chat: other)
        store.mergeArchive(of: orb) // folds back the old set-aside chats only
        store.flush()
        #expect(texts(store.readConversation(orb)) == ["primeira"])
        #expect(texts(store.readConversation(orb, chat: orb)) == ["primeira"], "the first one's id is the Orb's")
        #expect(texts(store.readConversation(orb, chat: other)) == ["segunda"])
        #expect(store.readMeta(orb, chat: other)?.matches(second) == true, "the note beside it is its own")
        #expect(Store.isSideConversationName("conversa-\(other.uuidString).json"))

        store.deleteConversation(orb, chat: other)
        store.flush()
        #expect(store.readConversation(orb, chat: other).value == nil)
        #expect(texts(store.readConversation(orb)) == ["primeira"])
    }

    @Test func aConversationNotInMemoryChangesInItsFileAfterTheWritesQueuedForIt() throws {
        let store = Store(directory: root)
        let orb = UUID(), other = UUID(), missing = UUID()
        store.save(conversation("antes"), for: orb, chat: other)
        store.amend(orb, chat: other) { $0.items.append(TranscriptItem(.user(text: "depois", attachments: []))) }
        let read = store.readConversation(orb, chat: other) // waits for both
        #expect(texts(read) == ["antes", "depois"])
        #expect(store.readMeta(orb, chat: other)?.matches(try #require(read.value)) == true, "the note follows the file")

        store.amend(orb, chat: missing) { $0.items.append(TranscriptItem(.user(text: "nova", attachments: []))) }
        #expect(texts(store.readConversation(orb, chat: missing)) == ["nova"])
    }

    @Test @MainActor func theListsAreSavedWithTheStateAndADamagedOneIsDroppedAlone() throws {
        let store = Store(directory: root)
        var state = AppState.initial
        state.bots.append(Bot(name: "Outro", role: "", orb: OrbConfig()))
        let (first, second) = (state.bots[0].id, state.bots[1].id)
        var chats = OrbChats(first: first, updated: .now)
        chats.add(UUID(), at: .now)
        state.chats = [first.uuidString: chats, second.uuidString: chats]
        store.save(state)
        store.flush()
        #expect(store.readState().value?.chats[first.uuidString] == chats)

        let url = root.appending(path: "state.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var lists = try #require(json["chats"] as? [String: Any])
        lists[second.uuidString] = ["active": "não é um id"]
        json["chats"] = lists
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let read = try #require(store.readState().value)
        #expect(read.chats.keys.sorted() == [first.uuidString])
        #expect(read.bots.count == 2)
    }
}

@Suite final class OrbChatsModelTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbChats-\(UUID().uuidString)")

    init() { QuietNotifications.hold() }
    deinit {
        QuietNotifications.release()
        removeTestFolder(root)
    }

    @MainActor private func setUp(_ client: Model) -> (AppModel, UUID) {
        var state = AppState.initial
        let own = root.appending(path: "pasta")
        try? FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        state.bots[0].workingDirectory = own.path
        let store = Store(directory: root)
        store.save(state)
        store.flush()
        return (launch(client), state.bots[0].id)
    }

    @MainActor private func launch(_ client: Model) -> AppModel {
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = { client }
        return model
    }

    @MainActor private func userTexts(_ model: AppModel, _ id: UUID) -> [String] {
        model.transcript(id).compactMap { if case .user(let text, _) = $0.kind { text } else { nil } }
    }

    @Test @MainActor func aNewConversationStartsEmptyAndTheModelSeesNothingOfTheOther() async throws {
        let client = Model()
        let (model, orb) = setUp(client)
        #expect(model.send("primeiro assunto", to: orb, fromUser: true))
        await waitUntilIdle(model, orb)

        model.newChat(for: orb)
        let chats = try #require(model.live(orb).chats)
        #expect(chats.list.count == 2 && chats.active != orb)
        #expect(model.transcript(orb).isEmpty)
        model.newChat(for: orb) // the one on show is already new and empty
        #expect(model.live(orb).chats?.list.count == 2)

        #expect(model.send("segundo assunto", to: orb, fromUser: true))
        await waitUntilIdle(model, orb)
        let second = try #require(await client.calls.seen.last)
        #expect(second.filter { $0.role == .user }.count == 1)
        #expect(!second.contains { $0.role == .assistant }, "the other conversation's reply is not in its history")
        #expect(model.live(orb).chats?.title(of: chats.active) == "segundo assunto")

        model.openChat(orb, of: orb)
        await model.loadedConversation(orb)
        #expect(userTexts(model, orb) == ["primeiro assunto"])
        #expect(model.live(orb).chats?.active == orb)
    }

    @Test @MainActor func openingAnotherConversationDuringATurnLetsItEndInItsOwnAndWhatYouWriteWaits() async throws {
        let gate = TestGate()
        let client = Model(gate: gate)
        let (model, orb) = setUp(client)
        #expect(model.send("trabalho longo", to: orb, fromUser: true))
        await waitUntil("the model call") { await client.calls.count >= 1 }

        model.newChat(for: orb)
        let session = model.session(orb)
        let new = try #require(model.live(orb).chats?.active)
        #expect(session.workingChatID == orb)
        #expect(model.transcript(orb).isEmpty, "the new conversation is on show")
        #expect(model.workingChatTitle(orb) == OrbChats.firstTitle)
        #expect(!model.canSteer(orb) && model.canQueue(orb))
        #expect(model.submit("para a nova", to: orb))
        #expect(model.composerLane(orb).queued.map(\.delivery) == [.afterTask])

        await gate.open()
        await waitUntil("the waiting message's turn") { await client.calls.count >= 2 }
        await waitUntilIdle(model, orb)
        #expect(session.workingChatID == nil && session.chatID == new)
        #expect(userTexts(model, orb) == ["para a nova"])
        let second = try #require(await client.calls.seen.last)
        #expect(!second.contains { $0.role == .assistant }, "the waiting message starts the new conversation")
        model.store.flush()
        let first = model.store.readConversation(orb).value?.items ?? []
        #expect(first.contains { if case .bot(let text, _) = $0.kind { text == "resposta 1" } else { false } },
                "the turn ended in the conversation it began in")
    }

    @Test @MainActor func goingBackToTheConversationTheOrbWorksOnShowsItsTurn() async throws {
        let gate = TestGate()
        let client = Model(gate: gate)
        let (model, orb) = setUp(client)
        #expect(model.send("trabalho longo", to: orb, fromUser: true))
        await waitUntil("the model call") { await client.calls.count >= 1 }
        model.newChat(for: orb)
        model.openChat(orb, of: orb)
        #expect(model.session(orb).workingChatID == nil)
        #expect(model.canSteer(orb))
        #expect(userTexts(model, orb) == ["trabalho longo"])
        await gate.open()
        await waitUntilIdle(model, orb)
        #expect(model.session(orb).chatID == orb)
    }

    @Test @MainActor func anOldConversationOpenedDuringATurnIsReadOffTheMainThreadAndTheLastClickWins() async throws {
        let gate = TestGate()
        let client = Model(gate: gate)
        let (model, orb) = setUp(client)
        let session = model.session(orb)
        let (a, b) = (UUID(), UUID())
        var chats = OrbChats(first: orb, updated: .now)
        for (id, text) in [(a, "conversa a"), (b, "conversa b")] {
            chats.add(id, at: .now)
            var conversation = Conversation()
            conversation.items = [TranscriptItem(.user(text: text, attachments: []))]
            model.store.save(conversation, for: orb, chat: id)
        }
        chats.active = orb
        model.setChats(chats, for: orb)
        #expect(model.send("trabalho longo", to: orb, fromUser: true))
        await waitUntil("the model call") { await client.calls.count >= 1 }

        model.openChat(a, of: orb)
        #expect(session.chatID == orb && session.opening == a, "read first: the chat stays as it is meanwhile")
        model.openChat(b, of: orb) // a second click before the first read is back
        await waitUntil("the read") { session.chatID == b }
        #expect(session.workingChatID == orb)
        #expect(userTexts(model, orb) == ["conversa b"])
        #expect(model.live(orb).chats?.active == b)
        await gate.open()
        await waitUntilIdle(model, orb)
        #expect(session.chatID == b && session.workingChatID == nil)
        #expect(userTexts(model, orb) == ["conversa b"])
    }

    @Test @MainActor func theConversationOnShowComesBackAfterARelaunch() async throws {
        let client = Model()
        let (model, orb) = setUp(client)
        #expect(model.send("primeiro", to: orb, fromUser: true))
        await waitUntilIdle(model, orb)
        model.newChat(for: orb)
        #expect(model.send("na nova", to: orb, fromUser: true))
        await waitUntilIdle(model, orb)
        let new = try #require(model.live(orb).chats?.active)
        model.saveNow()

        let next = launch(client)
        #expect(next.live(orb).chats?.active == new)
        #expect(next.session(orb).chatID == new)
        await next.loadedConversation(orb)
        #expect(userTexts(next, orb) == ["na nova"])
    }

    @Test @MainActor func deletingTheConversationOnShowOpensTheNewestLeftAndDropsTheList() async throws {
        let client = Model()
        let (model, orb) = setUp(client)
        #expect(model.send("primeiro", to: orb, fromUser: true))
        await waitUntilIdle(model, orb)
        model.newChat(for: orb)
        #expect(model.send("na nova", to: orb, fromUser: true))
        await waitUntilIdle(model, orb)
        let new = try #require(model.live(orb).chats?.active)

        #expect(model.canDeleteChat(new, of: orb))
        model.deleteChat(new, of: orb)
        #expect(model.session(orb).chatID == orb)
        #expect(model.live(orb).chats == nil, "only the first one is left: no list")
        await model.loadedConversation(orb)
        #expect(userTexts(model, orb) == ["primeiro"])
        model.store.flush()
        #expect(model.store.readConversation(orb, chat: new).value == nil)
    }

    @Test @MainActor func theConversationATurnWorksOnCannotBeDeleted() async throws {
        let gate = TestGate()
        let client = Model(gate: gate)
        let (model, orb) = setUp(client)
        #expect(model.send("trabalho longo", to: orb, fromUser: true))
        await waitUntil("the model call") { await client.calls.count >= 1 }
        model.newChat(for: orb)
        #expect(!model.canDeleteChat(orb, of: orb), "the turn is still writing it")
        model.openChat(orb, of: orb)
        #expect(!model.canDeleteChat(orb, of: orb), "on show and working")
        await gate.open()
        await waitUntilIdle(model, orb)
        #expect(model.canDeleteChat(orb, of: orb))
    }

    @Test @MainActor func aLineForAConversationNotOnShowGoesToItsFileAndMarksIt() async throws {
        let (model, orb) = setUp(Model())
        let other = UUID()
        var chats = OrbChats(first: orb, updated: .now)
        chats.add(other, at: .now) // the latest
        chats.active = orb
        model.setChats(chats, for: orb)
        await model.loadedConversation(orb)
        func notices() -> [String] { model.transcript(orb).compactMap { if case .notice(let text) = $0.kind { text } else { nil } } }

        model.appendToChat(.notice("A rotina terminou."), of: orb) // not an answer to anything: the latest gets it
        #expect(notices().isEmpty)
        #expect(model.session(orb).amends == 1, "written to its file, not read here")
        #expect(model.live(orb).chats?.list.first?.unread == true)
        let read = await model.readChat(other, of: orb)
        #expect(read.value?.items.count == 1)

        model.appendToChat(.notice("Aqui."), of: orb, in: orb)
        #expect(notices() == ["Aqui."])
        #expect(model.live(orb).chats?.list.last?.unread == nil, "the one on show is being read")

        model.openChat(other, of: orb)
        await model.loadedConversation(orb)
        #expect(notices() == ["A rotina terminou."])
        #expect(model.live(orb).chats?.list.first?.unread == nil)
    }

    @Test @MainActor func onlyTheFirstConversationIsToldWhereYouLeftOff() async throws {
        let client = Model()
        let (model, orb) = setUp(client)
        await model.memory.bank(for: orb).saveSession(MemoryPage(
            path: "sessoes/antes.md", kind: .sessao, title: "Organizar a pasta Downloads",
            body: "## Pedidos\n- 10:00 — Organizar a pasta Downloads\n\n## Última resposta\nFeito.",
            created: .now.addingTimeInterval(-3600), updated: .now.addingTimeInterval(-3600), origin: .automatico))
        func told(_ call: [ChatMessage]) -> Bool { call.contains { $0.content.contains("Where you left off") } }

        #expect(model.send("oi", to: orb, fromUser: true))
        await waitUntilIdle(model, orb)
        #expect(told(try #require(await client.calls.seen.last)))

        model.newChat(for: orb)
        #expect(model.send("outra coisa", to: orb, fromUser: true))
        await waitUntilIdle(model, orb)
        #expect(!told(try #require(await client.calls.seen.last)), "a new conversation starts clean")
    }
}
