import Foundation
import Testing
@testable import Orb

/// "Nova conversa" archives instead of deleting: where the archive lives, how it is listed (a damaged file never
/// breaks the list), what reopening keeps, and what deleting an Orb removes.
@Suite final class ConversationHistoryTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbHistory-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

    private var store: Store { Store(directory: root) }

    private func currentURL(_ botID: UUID) -> URL { root.appending(path: "conversations/\(botID.uuidString).json") }
    private func archiveFolder(_ botID: UUID) -> URL { root.appending(path: "conversations/\(botID.uuidString)") }

    private func put(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func conversation(_ said: String..., reply: String = "certo", at start: Date = .now) -> Conversation {
        var items: [TranscriptItem] = []
        var messages: [ChatMessage] = []
        for (index, text) in said.enumerated() {
            var user = TranscriptItem(.user(text: text, attachments: []))
            user.date = start.addingTimeInterval(Double(index) * 60)
            var bot = TranscriptItem(.bot(text: reply, isStreaming: false))
            bot.date = start.addingTimeInterval(Double(index) * 60 + 30)
            items += [user, bot]
            messages += [.user(text), ChatMessage(role: .assistant, content: reply)]
        }
        return Conversation(items: items, messages: messages)
    }

    /// A model whose only Orb already has `current` as its conversation.
    @MainActor private func model(current: Conversation? = nil) -> (AppModel, UUID) {
        let state = AppState.initial
        let botID = state.bots[0].id
        store.save(state)
        if let current { store.save(current, for: botID) }
        store.flush()
        return (AppModel(store: store, runsBackgroundWork: false), botID)
    }

    // MARK: Layout and migration

    @Test @MainActor func theSingleFileLayoutOfOlderVersionsLoadsAsTheCurrentConversation() {
        let (model, botID) = model(current: conversation("oi"))
        #expect(model.transcript(botID).count == 2)
        #expect(store.readArchive(botID).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: archiveFolder(botID).path)) // nothing was created for it
    }

    @Test @MainActor func theCurrentConversationStaysWhereItAlwaysWas() async {
        let (model, botID) = model(current: conversation("primeira"))
        model.newConversation(botID)
        model.saveNow()
        #expect(FileManager.default.fileExists(atPath: currentURL(botID).path))
        #expect(store.loadConversation(botID)?.items.isEmpty == true)
        #expect(store.readArchive(botID).count == 1)
    }

    // MARK: Archiving

    @Test @MainActor func newConversationArchivesTheCurrentOneAndStartsEmpty() async throws {
        let (model, botID) = model(current: conversation("Resuma o relatório de vendas", "e agora o de março"))
        model.newConversation(botID)

        #expect(model.transcript(botID).isEmpty)
        let list = store.readArchive(botID)
        let entry = try #require(list.first)
        #expect(list.count == 1)
        #expect(entry.title == "Resuma o relatório de vendas")
        #expect(entry.messageCount == 4)
        let archived = try #require(store.readArchived(entry.id, for: botID).value)
        #expect(archived.items.count == 4 && archived.messages.count == 4)
    }

    @Test @MainActor func aConversationWithoutUserMessagesIsNotKept() {
        var empty = Conversation()
        empty.items = [TranscriptItem(.notice("Conversa compactada"))]
        let (model, botID) = model(current: empty)
        model.newConversation(botID)
        model.newConversation(botID)
        #expect(store.readArchive(botID).isEmpty)
    }

    @Test @MainActor func theArchiveListsNewestFirstAndTheArchivedCurrentOneJoinsIt() async throws {
        let (model, botID) = model(current: conversation("c", at: Date(timeIntervalSinceNow: -60)))
        store.archive(conversation("a", at: Date(timeIntervalSinceNow: -7_200)), for: botID)
        store.archive(conversation("b", at: Date(timeIntervalSinceNow: -3_600)), for: botID)

        await model.loadArchive(botID)
        #expect(model.archives[botID]?.map(\.title) == ["b", "a"])

        model.newConversation(botID)
        #expect(model.archives[botID]?.map(\.title) == ["c", "b", "a"]) // the loaded list follows
        #expect(store.readArchive(botID).map(\.title) == ["c", "b", "a"])
    }

    @Test func theTitleIsTheFirstUserMessageOnOneLineAndShort() {
        let long = "Faça   um\nresumo   " + String(repeating: "muito longo ", count: 20)
        let title = conversation(long).archiveTitle
        #expect(title.count <= ConversationSummary.titleLimit)
        #expect(title.hasSuffix("…") && !title.contains("\n") && !title.contains("  "))
        #expect(title.hasPrefix("Faça um resumo muito longo"))
        #expect(Conversation().archiveTitle == "Conversa sem título")
        let attachmentOnly = Conversation(items: [TranscriptItem(.user(text: " ", attachments: ["nota.pdf"]))])
        #expect(attachmentOnly.archiveTitle == "nota.pdf")
    }

    @Test @MainActor func theMemoryOfAnArchivedConversationIsSavedOnceAndTheMarkTravelsWithIt() throws {
        let (model, botID) = model(current: conversation("lembre disso", "e disso"))
        model.newConversation(botID)
        let entry = try #require(store.readArchive(botID).first)
        let archived = try #require(store.readArchived(entry.id, for: botID).value)
        #expect(archived.memorySavedCount == archived.items.count)
    }

    // MARK: Reopening

    @Test @MainActor func reopeningSwapsTheCurrentConversationAndTheArchivedOne() async throws {
        let (model, botID) = model(current: conversation("segunda"))
        let first = store.archive(conversation("primeira"), for: botID)

        #expect(model.reopenConversation(first.id, of: botID))

        #expect(model.transcript(botID).first.map { if case .user(let text, _) = $0.kind { text } else { "" } } == "primeira")
        #expect(store.readArchive(botID).map(\.title) == ["segunda"]) // the reopened one left, the one it replaced joined
        model.saveNow()
        #expect(store.loadConversation(botID)?.archiveTitle == "primeira")
    }

    @Test @MainActor func theReopenedConversationIsWrittenBeforeItsArchivedCopyIsDeleted() async throws {
        let (model, botID) = model(current: conversation("segunda"))
        let first = store.archive(conversation("primeira"), for: botID)
        #expect(model.reopenConversation(first.id, of: botID))
        store.flush() // the queue as it stands right after the call, no save of the model's own in between
        #expect(store.loadConversation(botID)?.archiveTitle == "primeira")
        #expect(store.readArchived(first.id, for: botID).value == nil)
    }

    @Test @MainActor func reopeningWhenTheCurrentOneIsEmptyArchivesNothing() throws {
        let (model, botID) = model(current: conversation("primeira"))
        model.newConversation(botID)
        let first = try #require(store.readArchive(botID).first)
        #expect(model.reopenConversation(first.id, of: botID))
        #expect(store.readArchive(botID).isEmpty)
        #expect(model.transcript(botID).count == 2)
    }

    @Test @MainActor func reopeningKeepsTheClaudeCodeSessionAndTheMemoryBookkeeping() throws {
        var original = conversation("um", "dois")
        original.claudeSessionID = "sessao-abc"
        original.claudeSessionFolder = "/tmp/pasta"
        original.claudeSeenCount = 4
        original.memorySavedCount = 4
        original.summary = "resumo"
        let (model, botID) = model(current: original)
        model.newConversation(botID)
        let entry = try #require(store.readArchive(botID).first)

        #expect(model.reopenConversation(entry.id, of: botID))
        let reopened = try #require(model.conversations[botID])
        #expect(reopened.claudeSessionID == "sessao-abc" && reopened.claudeSessionFolder == "/tmp/pasta")
        #expect(reopened.claudeSeenCount == 4 && reopened.summary == "resumo")
        #expect(reopened.memorySavedCount == 4) // all of it was saved already: leaving again saves nothing new

        model.newConversation(botID)
        let again = try #require(store.readArchive(botID).first)
        #expect(store.readArchived(again.id, for: botID).value?.memorySavedCount == 4)
    }

    @Test @MainActor func reopeningAConversationThatCannotBeReadChangesNothingAndSaysSo() throws {
        let (model, botID) = model(current: conversation("atual"))
        let broken = UUID()
        try put("{ not json", at: archiveFolder(botID).appending(path: "\(broken.uuidString).json"))

        #expect(model.reopenConversation(broken, of: botID) == false)

        #expect(model.transcript(botID).count == 2)
        #expect(model.dataNotices.count == 1)
        #expect(store.readArchive(botID).isEmpty)
    }

    // MARK: Deleting

    @Test @MainActor func deletingAnArchivedConversationRemovesItForGood() throws {
        let (model, botID) = model(current: conversation("apagar"))
        model.newConversation(botID)
        let entry = try #require(store.readArchive(botID).first)
        let file = archiveFolder(botID).appending(path: "\(entry.id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: file.path))

        model.deleteArchivedConversation(entry.id, of: botID)

        #expect(store.readArchive(botID).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test @MainActor func deletingAnOrbDeletesItsArchiveAndItsRoutinesConversations() throws {
        var state = AppState.initial
        state.bots.append(Bot(name: "Luna", role: "", orb: OrbConfig()))
        let (kept, doomed) = (state.bots[0].id, state.bots[1].id)
        store.save(state)
        for id in [kept, doomed] {
            store.save(conversation("atual"), for: id)
            store.archive(conversation("antiga"), for: id)
            store.saveRoutineConversation(conversation("rotina"), routine: UUID(), for: id)
        }
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)

        model.deleteBot(doomed)
        store.flush()

        #expect(!FileManager.default.fileExists(atPath: archiveFolder(doomed).path))
        #expect(!FileManager.default.fileExists(atPath: currentURL(doomed).path))
        #expect(store.readArchive(kept).count == 1) // the other Orb is untouched
        #expect(FileManager.default.fileExists(atPath: archiveFolder(kept).path))
    }

    // MARK: Listing damaged archives

    @Test func aCorruptArchiveFileIsSkippedAndTheOthersStillList() throws {
        let botID = UUID()
        let good = store.archive(conversation("boa"), for: botID)
        let bad = UUID()
        try put("{ not json", at: archiveFolder(botID).appending(path: "\(bad.uuidString).json"))
        try put("", at: archiveFolder(botID).appending(path: "\(UUID().uuidString).json"))

        let list = store.readArchive(botID)

        #expect(list.map(\.id) == [good.id])
        // Left alone for whoever wants to look at it.
        #expect(FileManager.default.fileExists(atPath: archiveFolder(botID).appending(path: "\(bad.uuidString).json").path))
    }

    @Test func aLostOrDamagedIndexIsRebuiltFromTheFiles() throws {
        let botID = UUID()
        let one = store.archive(conversation("um", at: Date(timeIntervalSinceNow: -100)), for: botID)
        let two = store.archive(conversation("dois", at: Date(timeIntervalSinceNow: -50)), for: botID)
        _ = store.readArchive(botID)
        let index = archiveFolder(botID).appending(path: "index.json")

        try FileManager.default.removeItem(at: index)
        #expect(store.readArchive(botID).map(\.id) == [two.id, one.id])
        #expect(FileManager.default.fileExists(atPath: index.path)) // written back

        try put("garbage", at: index)
        #expect(store.readArchive(botID).map(\.title) == ["dois", "um"])
        #expect((try? JSONDecoder().decode(ConversationIndex.self, from: Data(contentsOf: index)))?.entries.count == 2)
    }

    @Test func anIndexEntryWhoseFileIsGoneIsDropped() throws {
        let botID = UUID()
        let one = store.archive(conversation("um"), for: botID)
        let two = store.archive(conversation("dois"), for: botID)
        _ = store.readArchive(botID)
        try FileManager.default.removeItem(at: archiveFolder(botID).appending(path: "\(one.id.uuidString).json"))
        #expect(store.readArchive(botID).map(\.id) == [two.id])
    }

    @Test func routineConversationsAreNeverListedAsConversations() {
        let botID = UUID()
        store.saveRoutineConversation(conversation("rotina"), routine: UUID(), for: botID)
        let archived = store.archive(conversation("conversa"), for: botID)
        #expect(store.readArchive(botID).map(\.id) == [archived.id])
    }

    @Test func theArchivedFilesKeepOnlyAShortenedCopyOfOldToolOutputs() throws {
        let botID = UUID()
        var call = ToolCall(kind: .shell, title: "ls", detail: "")
        call.state = .done
        call.output = String(repeating: "x", count: 20_000)
        var long = conversation("um", "dois", "três")
        long.items.insert(TranscriptItem(.tool(call)), at: 1)
        let entry = store.archive(long, for: botID)
        let archived = try #require(store.readArchived(entry.id, for: botID).value)
        guard case .tool(let saved) = archived.items[1].kind else { Issue.record("no tool row"); return }
        #expect((saved.output?.count ?? 0) < 5_000)
    }

    @Test func theIndexAndSummariesToleratePartialData() throws {
        let id = UUID()
        let json = #"{"entries":[{"id":"\#(id.uuidString)"},{"bogus":true}]}"#
        let index = try JSONDecoder().decode(ConversationIndex.self, from: Data(json.utf8))
        #expect(index.entries.map(\.id) == [id])
        #expect(index.entries[0].title == "Conversa" && index.entries[0].messageCount == 0)
    }

    @Test @MainActor func theArchiveIsThereAfterRelaunch() async throws {
        let (model, botID) = model(current: conversation("de ontem"))
        model.newConversation(botID)
        model.saveNow()

        let relaunched = AppModel(store: store, runsBackgroundWork: false)
        await relaunched.loadArchive(botID)
        #expect(relaunched.archives[botID]?.map(\.title) == ["de ontem"])
    }
}
