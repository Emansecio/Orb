import Foundation
import Testing
@testable import Orb

/// An Orb has one conversation: the ones an older version set aside ("Nova conversa") come back into it, oldest first,
/// once, without losing the bookkeeping that points into its messages.
@Suite final class ConversationMergeTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbMerge-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    private func exchange(_ text: String, at date: Date) -> Conversation {
        var conversation = Conversation()
        var user = TranscriptItem(.user(text: text, attachments: []))
        user.date = date
        var answer = TranscriptItem(.bot(text: "resposta a \(text)", isStreaming: false))
        answer.date = date.addingTimeInterval(5)
        conversation.items = [user, answer]
        conversation.messages = [.user(text), ChatMessage(role: .assistant, content: "resposta a \(text)")]
        return conversation
    }

    private func greeting() -> Conversation {
        var conversation = Conversation()
        conversation.items = [TranscriptItem(.bot(text: "Oi! Em que posso ajudar?", isStreaming: false))]
        return conversation
    }

    private func texts(_ conversation: Conversation) -> [String] {
        conversation.items.compactMap { if case .user(let text, _) = $0.kind { text } else { nil } }
    }

    private let day: TimeInterval = 86_400
    private var start: Date { Date(timeIntervalSince1970: 1_790_000_000) }

    // MARK: The merge

    @Test func theSetAsideOnesComeFirstOldestFirst() {
        let older = exchange("segunda", at: start.addingTimeInterval(day))
        let oldest = exchange("primeira", at: start)
        let current = exchange("terceira", at: start.addingTimeInterval(2 * day))
        let merged = Conversation.merging([older, oldest], into: current)
        #expect(texts(merged) == ["primeira", "segunda", "terceira"])
        #expect(merged.messages.map(\.content) == ["primeira", "resposta a primeira", "segunda", "resposta a segunda",
                                                   "terceira", "resposta a terceira"])
        // What was set aside had been saved to memory; the current one's own mark moves along.
        #expect(merged.memorySavedCount == 4)
    }

    @Test func theIndexesIntoTheMessagesMoveWithThem() {
        let old = exchange("antiga", at: start)
        var current = exchange("atual", at: start.addingTimeInterval(day))
        current.messages += [.user("mais"), ChatMessage(role: .assistant, content: "ok")]
        current.summary = "resumo"
        current.summaryCoveredCount = 2
        current.condensedCount = 1
        current.chunkSummaries = [ChunkSummary(start: 0, end: 2, text: "trecho")]
        current.memorySavedCount = 1
        current.compactions = 1
        let merged = Conversation.merging([old], into: current)
        #expect(merged.messages.count == 6)
        #expect(merged.summary == "resumo" && merged.compactions == 1)
        #expect(merged.summaryCoveredCount == 4)
        #expect(merged.condensedCount == 3)
        #expect(merged.chunkSummaries == [ChunkSummary(start: 2, end: 4, text: "trecho")])
        #expect(merged.memorySavedCount == 3)
    }

    @Test func aChatWithOnlyTheGreetingGivesWayToTheNewestSetAsideOne() {
        let oldest = exchange("primeira", at: start)
        var newest = exchange("segunda", at: start.addingTimeInterval(day))
        newest.summaryCoveredCount = 1
        newest.summary = "resumo"
        let merged = Conversation.merging([newest, oldest], into: greeting())
        #expect(texts(merged) == ["primeira", "segunda"])
        #expect(!merged.items.contains { if case .bot(let text, _) = $0.kind { text.hasPrefix("Oi!") } else { false } })
        #expect(merged.summaryCoveredCount == 3) // the newest one carries on, its summary still over its own start
        // No chat file at all: the same.
        #expect(texts(Conversation.merging([oldest], into: nil)) == ["primeira"])
        // Nothing set aside: the chat stays as it is, greeting and all.
        #expect(Conversation.merging([], into: greeting()).items.count == 1)
        #expect(Conversation.merging([], into: nil).items.isEmpty)
    }

    @Test func whatWasInterruptedIsClosedAndUnansweredCallsGetAResult() {
        var old = exchange("antiga", at: start)
        old.items.append(TranscriptItem(.bot(text: "pela met", isStreaming: true)))
        old.messages.append(ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: "c1", name: "ler", arguments: "{}")]))
        let merged = Conversation.merging([old], into: exchange("atual", at: start.addingTimeInterval(day)))
        #expect(!merged.items.contains { if case .bot(_, true) = $0.kind { true } else { false } })
        let index = merged.messages.firstIndex { $0.toolCalls.first?.id == "c1" }
        #expect(index.map { merged.messages[$0 + 1].toolCallID } == "c1")
        #expect(index.map { merged.messages[$0 + 2].content } == "atual")
    }

    @Test func oneAlreadyMergedIsNotAddedTwice() {
        let old = exchange("antiga", at: start)
        let first = Conversation.merging([old], into: exchange("atual", at: start.addingTimeInterval(day)))
        let again = Conversation.merging([old], into: first)
        #expect(texts(again) == ["antiga", "atual"])
        #expect(again.messages.count == first.messages.count)
    }

    // MARK: On disk

    private func folder(_ botID: UUID) -> URL { root.appending(path: "conversations/\(botID.uuidString)") }

    private func setAside(_ conversation: Conversation, for botID: UUID, named name: String = UUID().uuidString) throws {
        try FileManager.default.createDirectory(at: folder(botID), withIntermediateDirectories: true)
        try JSONEncoder().encode(conversation).write(to: folder(botID).appending(path: "\(name).json"))
    }

    private func files(_ botID: UUID) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder(botID).path)) ?? [])
    }

    @Test func theStoreMergesOnceAndLeavesTheRoutinesAlone() throws {
        let store = Store(directory: root)
        let botID = UUID(), routineID = UUID()
        store.save(exchange("atual", at: start.addingTimeInterval(2 * day)), for: botID)
        store.flush()
        try setAside(exchange("primeira", at: start), for: botID)
        try setAside(exchange("segunda", at: start.addingTimeInterval(day)), for: botID)
        try Data("{\"entries\":[]}".utf8).write(to: folder(botID).appending(path: "index.json"))
        try setAside(exchange("rotina", at: start), for: botID, named: "routine-\(routineID.uuidString)")
        try setAside(exchange("pedido", at: start), for: botID, named: "\(Store.pedidoPrefix)-\(UUID().uuidString)")

        store.mergeArchive(of: botID)
        let merged = try #require(store.readConversation(botID).value)
        #expect(texts(merged) == ["primeira", "segunda", "atual"])
        // The set-aside files and their list are gone; the routine's and the request's stay.
        #expect(files(botID).count == 2)
        #expect(files(botID).contains("routine-\(routineID.uuidString).json"))
        // A second launch finds nothing to do.
        store.mergeArchive(of: botID)
        #expect(texts(try #require(store.readConversation(botID).value)) == ["primeira", "segunda", "atual"])
    }

    @Test func anUnreadableChatIsLeftAsItIs() throws {
        let store = Store(directory: root)
        let botID = UUID()
        let chat = root.appending(path: "conversations/\(botID.uuidString).json")
        try FileManager.default.createDirectory(at: chat.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("não é json".utf8).write(to: chat)
        try setAside(exchange("antiga", at: start), for: botID)
        store.mergeArchive(of: botID)
        store.flush()
        #expect(try Data(contentsOf: chat) == Data("não é json".utf8))
        #expect(files(botID).count == 1) // the set-aside one waits too
    }

    @Test @MainActor func theAppOpensWithTheEarlierConversationsInTheChat() async throws {
        let store = Store(directory: root)
        let state = AppState.initial
        store.save(state)
        let botID = try #require(state.bots.first?.id)
        store.save(greeting(), for: botID)
        store.flush()
        try setAside(exchange("de ontem", at: start), for: botID)

        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false, asyncLoading: true)
        await model.loadedConversation(botID)
        #expect(texts(Conversation(items: model.transcript(botID))) == ["de ontem"])
        #expect(files(botID).isEmpty)
    }
}

private extension Conversation {
    init(items: [TranscriptItem]) {
        self.init()
        self.items = items
    }
}
