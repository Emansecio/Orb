import Foundation
import Testing
@testable import Orb

@Suite struct InicioHistoryTests {
    @Test func recordsEachOriginOnceAndOrdersBySequenceEvenWhenClockMovesBack() {
        let bot = UUID(), chat = UUID(), first = UUID(), second = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var history = InicioHistory()
        history.append(id: first, date: now, origin: .chat(bot: bot, chat: chat, item: first), outcome: .completed, summary: "Primeira", now: now)
        history.append(id: first, date: now, origin: .chat(bot: bot, chat: chat, item: first), outcome: .completed, summary: "Repetida", now: now)
        history.append(id: second, date: now.addingTimeInterval(-30), origin: .chat(bot: bot, chat: chat, item: second), outcome: .failed, summary: "Interrompida", now: now)
        #expect(history.entries.map(\.id) == [first, second])
        #expect(history.entries.map(\.sequence) == [1, 2])
        #expect(history.entries.last?.outcome == .failed)
    }

    @Test func cursorOnlyAdvancesThroughPresentedEntriesAndRoundTrips() throws {
        var history = InicioHistory()
        let bot = UUID(), routine = UUID(), run = UUID()
        history.append(id: run, date: .now, origin: .routine(bot: bot, routine: routine, run: run), outcome: .attention, summary: "Precisa conferir")
        history.finishVisit(through: 1)
        let second = UUID()
        history.append(id: second, date: .now, origin: .routine(bot: bot, routine: routine, run: second), outcome: .completed, summary: "Terminou")
        let restored = try JSONDecoder().decode(InicioHistory.self, from: JSONEncoder().encode(history))
        #expect(restored.lastVisit == 1)
        #expect(restored.entries.last?.sequence == 2)
        #expect(restored == history)
    }

    @Test func retentionKeepsSourcesIndependentAndLimitBounded() {
        let now = Date(timeIntervalSince1970: 1_800_000_000), bot = UUID(), chat = UUID()
        var history = InicioHistory()
        for _ in 0..<(InicioHistory.limit + 2) {
            let id = UUID()
            history.append(id: id, date: now, origin: .chat(bot: bot, chat: chat, item: id), outcome: .completed, summary: "Ok", now: now)
        }
        #expect(history.entries.count == InicioHistory.limit)
        #expect(history.entries.first?.sequence == 3)
        let id = UUID()
        history.append(id: id, date: now.addingTimeInterval(InicioHistory.retention + 1), origin: .chat(bot: bot, chat: chat, item: id),
                       outcome: .completed, summary: "Novo", now: now.addingTimeInterval(InicioHistory.retention + 1))
        #expect(history.entries.map(\.id) == [id])
    }

    @Test func oldStateLoadsWithoutAHomeHistory() throws {
        let original = AppState.initial
        let data = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "inicio")
        let restored = try JSONDecoder().decode(AppState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.inicio.entries.isEmpty)
        #expect(restored.inicio.lastVisit == nil)
    }

    @Test func resetIncludesTheHomeJournalAndItsDamagedCopies() {
        #expect(ResetGuard.removes(entry: Store.inicioJournalFileName))
        #expect(ResetGuard.removes(entry: Store.inicioJournalFileName + ".corrupt-20261029"))
        #expect(!ResetGuard.removes(entry: "inicio-journal-notes.txt"))
    }

    @Test func malformedHistoryEntriesAreSkippedWithoutLosingValidOnes() throws {
        var history = InicioHistory()
        let bot = UUID(), chat = UUID(), item = UUID()
        history.append(id: item, date: .now, origin: .chat(bot: bot, chat: chat, item: item), outcome: .completed, summary: "Pronto")
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        var entries = try #require(encoded["entries"] as? [[String: Any]])
        entries.append(["invalid": true])
        encoded["entries"] = entries
        let restored = try JSONDecoder().decode(InicioHistory.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(restored.entries.map(\.id) == [item])
        #expect(restored.nextSequence == 2)
    }

    @Test func recoveryDoesNotResurrectEvictedEntriesOrAdvanceTheVisitCursor() {
        let bot = UUID(), chat = UUID(), old = UUID(), new = UUID()
        var durable = InicioHistory()
        durable.nextSequence = 20
        durable.lastVisit = 19
        var journal = InicioHistory()
        journal.nextSequence = 18
        journal.append(id: old, date: .now, origin: .chat(bot: bot, chat: chat, item: old), outcome: .completed, summary: "Antigo")
        journal.nextSequence = 20
        journal.append(id: new, date: .now, origin: .chat(bot: bot, chat: chat, item: new), outcome: .failed, summary: "Novo")
        durable.recover(from: journal, accepts: { _ in true })
        #expect(durable.entries.map(\.id) == [new])
        #expect(durable.entries.first?.sequence == 20)
        #expect(durable.lastVisit == 19)
        #expect(durable.nextSequence == 21)
        durable.recover(from: journal, accepts: { _ in true })
        #expect(durable.entries.map(\.id) == [new])
    }

    @Test @MainActor func restartRecoversAResultWhenTheJournalWasSavedButStateWasNot() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbInicio-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let store = Store(directory: root)
        var state = AppState.initial
        state.inicio.lastVisit = 0
        let bot = try #require(state.bots.first)
        let answer = TranscriptItem(.bot(text: "Resultado recuperado", isStreaming: false))
        store.save(state)
        store.save(Conversation(items: [answer]), for: bot.id, chat: bot.id)
        var journal = state.inicio
        journal.append(id: answer.id, date: .now, origin: .chat(bot: bot.id, chat: bot.id, item: answer.id),
                       outcome: .completed, summary: "Resultado recuperado")
        store.saveInicioJournal(journal)
        store.flush()
        let restored = AppModel(store: store, runsBackgroundWork: false)
        #expect(restored.inicio.entries.map(\.id) == [answer.id])
        #expect(restored.inicio.lastVisit == 0)
        #expect(restored.inicio.nextSequence == 2)
        restored.saveNow()
        let reopened = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        #expect(reopened.inicio.entries.map(\.id) == [answer.id])
    }

    @Test @MainActor func recoveryDoesNotRestoreDeletedOrUnknownOrigins() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbInicio-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let store = Store(directory: root)
        var state = AppState.initial
        state.inicio.lastVisit = 0
        let bot = try #require(state.bots.first)
        store.save(state)
        var journal = InicioHistory()
        let removedChat = UUID(), chatItem = UUID(), removedRoutine = UUID(), run = UUID()
        journal.append(id: chatItem, date: .now, origin: .chat(bot: bot.id, chat: removedChat, item: chatItem), outcome: .completed, summary: "Apagado")
        journal.append(id: run, date: .now, origin: .routine(bot: bot.id, routine: removedRoutine, run: run), outcome: .completed, summary: "Apagada")
        store.saveInicioJournal(journal)
        store.flush()
        let restored = AppModel(store: store, runsBackgroundWork: false)
        #expect(restored.inicio.entries.isEmpty)
        #expect(restored.inicio.lastVisit == 0)
    }

    @Test func recoveryJournalDoesNotGetAheadOfAnUnwritableConversation() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbInicio-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("bloqueio".utf8).write(to: root.appending(path: "conversations"))
        let bot = UUID(), answer = TranscriptItem(.bot(text: "Resposta", isStreaming: false))
        var journal = InicioHistory()
        journal.append(id: answer.id, date: .now, origin: .chat(bot: bot, chat: bot, item: answer.id), outcome: .completed, summary: "Resposta")
        let store = Store(directory: root)
        store.saveInicioJournal(journal, after: Conversation(items: [answer]), bot: bot, chat: bot)
        store.flush()
        #expect(store.readInicioJournal().value == nil)
    }

    @Test func aBurstKeepsTheLastBoundedJournalInWriterOrder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbInicio-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let store = Store(directory: root), bot = UUID()
        var history = InicioHistory()
        for _ in 0..<(InicioHistory.limit + 10) {
            let item = UUID()
            history.append(id: item, date: .now, origin: .chat(bot: bot, chat: bot, item: item), outcome: .completed, summary: "Pronto")
            store.saveInicioJournal(history)
        }
        store.flush()
        let saved = try #require(store.readInicioJournal().value)
        #expect(saved.entries.count == InicioHistory.limit)
        #expect(saved.entries.map(\.id) == history.entries.map(\.id))
        #expect(saved.nextSequence == history.nextSequence)
    }

    @Test @MainActor func visitAndEventsSurviveSavingAndReopeningTheAppState() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbInicio-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let store = Store(directory: root)
        store.save(.initial)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        let bot = try #require(model.bots.first)
        let first = UUID(), second = UUID()
        model.recordInicioChat(bot: bot.id, chat: bot.id, item: first, date: .now, text: "Primeiro", succeeded: true)
        model.selection = .inicio
        model.inicioDidPresent(1)
        model.selection = .routines
        model.recordInicioChat(bot: bot.id, chat: bot.id, item: second, date: .now, text: "Segundo", succeeded: true)
        model.saveNow()
        store.flush()
        let reopened = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        #expect(reopened.inicio.lastVisit == 1)
        #expect(reopened.inicio.entries.map(\.id) == [first, second])
        #expect(reopened.inicio.entries.last?.sequence == 2)
    }

    @Test @MainActor func failedSaveKeepsTheLastDurableCursorAndCanBeRetried() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbInicio-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let folder = root.appending(path: "dados")
        let backup = root.appending(path: "dados-guardados")
        let store = Store(directory: folder)
        store.save(.initial)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        let bot = try #require(model.bots.first), item = UUID()
        model.recordInicioChat(bot: bot.id, chat: bot.id, item: item, date: .now, text: "Resultado", succeeded: true)
        model.saveNow()
        try FileManager.default.moveItem(at: folder, to: backup)
        try Data("bloqueio".utf8).write(to: folder)
        model.selection = .inicio
        model.inicioDidPresent(1)
        model.selection = .routines
        model.saveNow()
        let previous = Store(directory: backup).readState().value
        #expect(previous?.inicio.lastVisit == nil)
        #expect(model.inicio.lastVisit == 1)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: backup, to: folder)
        model.saveNow()
        let recovered = Store(directory: folder).readState().value
        #expect(recovered?.inicio.lastVisit == 1)
        #expect(recovered?.inicio.entries.map(\.id) == [item])
    }

    @Test @MainActor func visitingHomeDoesNotMarkChatsReadAndKeepsThePreviousCursor() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbInicio-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let store = Store(directory: root)
        let state = AppState.initial
        store.save(state)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        let bot = try #require(model.bots.first)
        model.live(bot.id).setUnread(3)
        let first = UUID()
        model.recordInicioChat(bot: bot.id, chat: bot.id, item: first, date: .now, text: "Primeiro", succeeded: true)
        model.selection = .inicio
        #expect(model.live(bot.id).unread == 3)
        #expect(model.inicioVisitBase == nil)
        model.inicioDidPresent(1)
        let second = UUID()
        model.recordInicioChat(bot: bot.id, chat: bot.id, item: second, date: .now, text: "Segundo", succeeded: true)
        model.selection = .routines
        #expect(model.inicio.lastVisit == 1)
        #expect(model.live(bot.id).unread == 3)
        model.selection = .inicio
        #expect(model.inicioVisitBase == 1)
        #expect(model.inicio.entries.filter { $0.sequence > (model.inicioVisitBase ?? 0) }.map(\.id) == [second])
    }

    @Test @MainActor func homeRouteChecksConversationAndCancelsWhenAnotherOrbIsSelected() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbInicio-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let store = Store(directory: root)
        var state = AppState.initial
        state.bots.append(Bot(name: "Outro", role: "", orb: OrbConfig()))
        store.save(state)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        let first = try #require(model.bots.first), second = try #require(model.bots.last)
        model.selection = .inicio
        #expect(!model.openInicioChat(bot: first.id, chat: UUID(), item: UUID()))
        #expect(model.openInicioChat(bot: first.id, chat: first.id, item: UUID()))
        #expect(model.inicioJump?.chat == first.id)
        model.selection = .bot(second.id)
        #expect(model.inicioJump == nil)
        model.isResetting = true
        #expect(!model.openInicioChat(bot: first.id, chat: first.id, item: UUID()))
        #expect(model.inicioJump == nil)
    }

    @Test @MainActor func choosingAnotherConversationCancelsThePendingHomeRoute() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbInicio-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let store = Store(directory: root)
        store.save(.initial)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        let bot = try #require(model.bots.first)
        let other = UUID()
        var chats = OrbChats(first: bot.id, updated: .now)
        chats.add(other, at: .now)
        model.setChats(chats, for: bot.id)
        model.selection = .inicio
        #expect(model.openInicioChat(bot: bot.id, chat: other, item: UUID()))
        #expect(model.inicioJump != nil)
        model.openChat(bot.id, of: bot.id)
        #expect(model.inicioJump == nil)
    }
}
