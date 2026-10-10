import Foundation
import Testing
@testable import Orb

/// "Nova conversa" archives instead of deleting: where the archive lives, how it is listed (a damaged file never
/// breaks the list), what reopening keeps, and what deleting an Orb removes.
@Suite final class ConversationHistoryTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbHistory-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

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
        await model.newConversation(botID)?.value
        model.saveNow()
        #expect(FileManager.default.fileExists(atPath: currentURL(botID).path))
        #expect(store.loadConversation(botID)?.items.isEmpty == true)
        #expect(store.readArchive(botID).count == 1)
    }

    // MARK: Archiving

    @Test @MainActor func newConversationArchivesTheCurrentOneAndStartsEmpty() async throws {
        let (model, botID) = model(current: conversation("Resuma o relatório de vendas", "e agora o de março"))
        await model.newConversation(botID)?.value

        #expect(model.transcript(botID).isEmpty)
        let list = store.readArchive(botID)
        let entry = try #require(list.first)
        #expect(list.count == 1)
        #expect(entry.title == "Resuma o relatório de vendas")
        #expect(entry.messageCount == 4)
        let archived = try #require(store.readArchived(entry.id, for: botID).value)
        #expect(archived.items.count == 4 && archived.messages.count == 4)
    }

    @Test @MainActor func aConversationWithoutUserMessagesIsNotKept() async {
        var empty = Conversation()
        empty.items = [TranscriptItem(.notice("Conversa compactada"))]
        let (model, botID) = model(current: empty)
        await model.newConversation(botID)?.value
        await model.newConversation(botID)?.value
        #expect(store.readArchive(botID).isEmpty)
    }

    @Test @MainActor func theArchiveListsNewestFirstAndTheArchivedCurrentOneJoinsIt() async throws {
        let (model, botID) = model(current: conversation("c", at: Date(timeIntervalSinceNow: -60)))
        store.archive(conversation("a", at: Date(timeIntervalSinceNow: -7_200)), for: botID)
        store.archive(conversation("b", at: Date(timeIntervalSinceNow: -3_600)), for: botID)

        await model.loadArchive(botID)
        #expect(model.archives[botID]?.map(\.title) == ["b", "a"])

        await model.newConversation(botID)?.value
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

    @Test @MainActor func theMemoryOfAnArchivedConversationIsSavedOnceAndTheMarkTravelsWithIt() async throws {
        let (model, botID) = model(current: conversation("lembre disso", "e disso"))
        await model.newConversation(botID)?.value
        let entry = try #require(store.readArchive(botID).first)
        let archived = try #require(store.readArchived(entry.id, for: botID).value)
        #expect(archived.memorySavedCount == archived.items.count)
    }

    // MARK: A full disk

    /// Takes away the right to create files in `folder` (a full disk fails the same way); false when that changes
    /// nothing (running as root), and the test has nothing to show.
    private func fillUp(_ folder: URL) throws -> Bool {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        return !FileManager.default.isWritableFile(atPath: folder.path)
    }

    private func makeRoom(_ folder: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    }

    @Test func anArchiveThatCouldNotBeWrittenIsNotListedAndIsReported() async throws {
        let botID = UUID()
        let folder = archiveFolder(botID)
        defer { makeRoom(folder) }
        guard try fillUp(folder) else { return }
        #expect(await store.archiveAndWait(conversation("importante"), for: botID) == nil)
        makeRoom(folder)
        #expect(store.readArchive(botID).isEmpty)
    }

    @Test @MainActor func aNewConversationKeepsTheCurrentOneOpenWhenItCannotBeArchived() async throws {
        let (model, botID) = model(current: conversation("importante"))
        let folder = archiveFolder(botID)
        defer { makeRoom(folder) }
        guard try fillUp(folder) else { return }
        await model.newConversation(botID)?.value
        makeRoom(folder)

        #expect(model.transcript(botID).count == 2) // still there, in memory
        #expect(store.loadConversation(botID)?.items.count == 2) // and on disk, not replaced by an empty one
        #expect(!model.dataNotices.isEmpty)
        // Once there is room again, the same request goes through.
        await model.newConversation(botID)?.value
        #expect(model.transcript(botID).isEmpty)
        #expect(store.readArchive(botID).map(\.title) == ["importante"])
    }

    @Test @MainActor func reopeningGivesUpAndKeepsTheArchivedCopyWhenTheChatCannotBeWritten() async throws {
        let (model, botID) = model(current: conversation("segunda"))
        let first = store.archive(conversation("primeira"), for: botID)
        store.flush()
        let folder = root.appending(path: "conversations") // where the current chat's file is replaced
        defer { makeRoom(folder) }
        guard try fillUp(folder) else { return }
        let reopened = await model.reopenConversation(first.id, of: botID)
        makeRoom(folder)

        #expect(!reopened)
        #expect(store.readArchived(first.id, for: botID).value != nil) // the only copy of it is still there
        #expect(model.transcript(botID).count == 2)
        #expect(!model.dataNotices.isEmpty)
        // The copy of the open chat made on the way is gone: nothing is listed twice.
        #expect(store.readArchive(botID).map(\.title) == ["primeira"])
        // Once there is room again, it opens.
        #expect(await model.reopenConversation(first.id, of: botID))
        #expect(store.readArchived(first.id, for: botID).value == nil)
        #expect(store.readArchive(botID).map(\.title) == ["segunda"])
    }

    @Test @MainActor func newConversationGivenUpBecauseTheChatChangedLeavesNoExtraArchivedCopy() async throws {
        let (model, botID) = model(current: conversation("primeira"))
        let task = model.newConversation(botID)
        // Said something before the archive was confirmed.
        model.session(botID).conversation?.items.append(TranscriptItem(.user(text: "mais uma", attachments: [])))
        await task?.value

        store.flush()
        #expect(store.readArchive(botID).isEmpty)
        #expect(model.transcript(botID).count == 3)
        #expect(!model.dataNotices.isEmpty)
    }

    /// Answers at once; only to see whether a send starts a turn.
    private struct QuickModel: LLMClient {
        func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.text("ok"))
                continuation.yield(.finished(.done, nil))
                continuation.finish()
            }
        }
    }

    @Test @MainActor func nothingIsSentWhileTheChatIsBeingArchivedAndTheDraftStays() async {
        let (model, botID) = model(current: conversation("primeira"))
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = { QuickModel() }
        let task = model.newConversation(botID)
        #expect(model.changingChat.contains(botID))
        // It would land in the chat about to be replaced, and undo the change.
        #expect(!model.send("assunto novo", to: botID, fromUser: true))
        #expect(model.transcript(botID).count == 2 && model.turns[botID] == nil)
        await task?.value
        store.flush()
        #expect(model.dataNotices.isEmpty)
        #expect(model.transcript(botID).isEmpty) // the new conversation did open
        #expect(!model.changingChat.contains(botID))
        #expect(model.send("assunto novo", to: botID, fromUser: true)) // and now it is sent
        #expect(store.readArchive(botID).count == 1)
    }

    @Test @MainActor func aQuickAskDuringTheChangeGoesBackToTheDraftInsteadOfBeingLost() async {
        let (model, botID) = model(current: conversation("primeira"))
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = { QuickModel() }
        let task = model.newConversation(botID)
        model.sendWhenLoaded("pergunta rápida", to: botID)
        #expect(model.drafts[botID] == "pergunta rápida")
        #expect(model.transcript(botID).count == 2)
        await task?.value
        store.flush()
        #expect(model.dataNotices.isEmpty)
    }

    @Test @MainActor func reopeningGivenUpBecauseTheChatChangedSaysSo() async throws {
        let (model, botID) = model(current: conversation("segunda"))
        let first = store.archive(conversation("primeira"), for: botID)
        store.flush()
        let release = DispatchSemaphore(value: 0)
        store.stallWriter(until: release)
        let reopening = Task { await model.reopenConversation(first.id, of: botID) }
        // The current chat's archive writes the Orb's archive index, and is registered with the store's gate the moment
        // it is queued (behind the stalled writer): the chat it leaves was looked at by then. The path carries the
        // test's folder because the first Orb has the same id in every test.
        await waitUntil("the current chat's archive to be queued") { Store.gate.queuedWrites(containing: "\(root.lastPathComponent)/conversations/\(botID.uuidString)/index.json") > 0 }
        model.session(botID).conversation?.items.append(TranscriptItem(.user(text: "mais uma", attachments: [])))
        release.signal()
        #expect(await reopening.value == false)
        #expect(!model.dataNotices.isEmpty)
    }

    @Test @MainActor func quittingRightAfterNewConversationLeavesTheChatOpenAndListedOnce() async throws {
        let (model, botID) = model(current: conversation("primeira"))
        let release = DispatchSemaphore(value: 0)
        store.stallWriter(until: release)
        let task = model.newConversation(botID)
        await waitUntil("the archive write to be queued") { model.hasQueuedChatArchive } // installing the empty chat has not run
        model.undoChatChangesForQuit() // what the quit notification does before saving
        release.signal()
        model.saveNow()
        await task?.value // the step that would have finished the change gives way

        let next = AppModel(store: store, runsBackgroundWork: false)
        #expect(next.transcript(botID).count == 2, "the conversation is still the open one")
        #expect(store.readArchive(botID).isEmpty, "and not also listed as an earlier one")
        #expect(model.transcript(botID).count == 2)
    }

    @Test @MainActor func quittingWhileAConversationIsBeingReopenedLeavesNoCopy() async throws {
        let (model, botID) = model(current: conversation("segunda"))
        let first = store.archive(conversation("primeira"), for: botID)
        store.flush()
        let release = DispatchSemaphore(value: 0)
        store.stallWriter(until: release) // the archive of the open chat waits in the queue
        let reopened = Task { await model.reopenConversation(first.id, of: botID) }
        await waitUntil("the archive write to be queued") { model.hasQueuedChatArchive }
        model.undoChatChangesForQuit()
        release.signal()
        model.saveNow()
        #expect(await reopened.value == false)

        let next = AppModel(store: store, runsBackgroundWork: false)
        #expect(next.transcript(botID).count == 2)
        #expect(next.session(botID).conversation?.archiveTitle == "segunda")
        #expect(store.readArchive(botID).map(\.title) == ["primeira"], "the chosen one is still only in the archive, once")
    }

    @Test func aSealedFolderAnswersWritesWithFailureInsteadOfNeverAnswering() async {
        let sealed = Store(directory: root)
        let botID = UUID()
        sealed.sealWrites()
        #expect(await sealed.saveAndWait(conversation("oi"), for: botID) == false)
        #expect(await sealed.archiveAndWait(conversation("oi"), for: botID) == nil)
    }

    // MARK: Reopening

    @Test @MainActor func reopeningSwapsTheCurrentConversationAndTheArchivedOne() async throws {
        let (model, botID) = model(current: conversation("segunda"))
        let first = store.archive(conversation("primeira"), for: botID)

        #expect(await model.reopenConversation(first.id, of: botID))

        #expect(model.transcript(botID).first.map { if case .user(let text, _) = $0.kind { text } else { "" } } == "primeira")
        #expect(store.readArchive(botID).map(\.title) == ["segunda"]) // the reopened one left, the one it replaced joined
        model.saveNow()
        #expect(store.loadConversation(botID)?.archiveTitle == "primeira")
    }

    @Test @MainActor func theReopenedConversationIsWrittenBeforeItsArchivedCopyIsDeleted() async throws {
        let (model, botID) = model(current: conversation("segunda"))
        let first = store.archive(conversation("primeira"), for: botID)
        #expect(await model.reopenConversation(first.id, of: botID))
        store.flush() // the queue as it stands right after the call, no save of the model's own in between
        #expect(store.loadConversation(botID)?.archiveTitle == "primeira")
        #expect(store.readArchived(first.id, for: botID).value == nil)
    }

    @Test @MainActor func reopeningReadsTheFileWithoutBlockingTheMainThread() async throws {
        let (model, botID) = model(current: conversation("primeira"))
        await model.loadArchive(botID)
        model.setDraft("rascunho", for: botID)

        // "Nova conversa" and, at once, back, with the writer busy: the reopened chat waits in its queue to be written.
        await model.newConversation(botID)?.value
        let entry = try #require(model.archives[botID]?.first)
        let release = DispatchSemaphore(value: 0)
        store.stallWriter(until: release)
        let reopened = Task { await model.reopenConversation(entry.id, of: botID) }
        try await Task.sleep(for: .milliseconds(100)) // the main thread kept running while the write waited
        #expect(model.transcript(botID).isEmpty) // nothing replaced yet: the chat is swapped once it is safe
        release.signal()

        #expect(await reopened.value)
        #expect(model.transcript(botID).count == 2 && model.drafts[botID] == "rascunho") // the draft stays with the Orb
    }

    @Test @MainActor func aConversationDeletedWhileItIsReadIsNotReopened() async throws {
        let (model, botID) = model(current: conversation("primeira"))
        await model.loadArchive(botID)
        await model.newConversation(botID)?.value
        let entry = try #require(model.archives[botID]?.first)
        let release = DispatchSemaphore(value: 0)
        store.stallWriter(until: release)

        let reopened = Task { await model.reopenConversation(entry.id, of: botID) }
        model.deleteArchivedConversation(entry.id, of: botID) // gone from the list before the read comes back
        release.signal()
        #expect(await reopened.value == false)
        #expect(model.transcript(botID).isEmpty) // the chat stayed as it was
    }

    @Test @MainActor func reopeningWhenTheCurrentOneIsEmptyArchivesNothing() async throws {
        let (model, botID) = model(current: conversation("primeira"))
        await model.newConversation(botID)?.value
        let first = try #require(store.readArchive(botID).first)
        #expect(await model.reopenConversation(first.id, of: botID))
        #expect(store.readArchive(botID).isEmpty)
        #expect(model.transcript(botID).count == 2)
    }

    @Test @MainActor func reopeningKeepsTheClaudeCodeSessionAndTheMemoryBookkeeping() async throws {
        var original = conversation("um", "dois")
        original.claudeSessionID = "sessao-abc"
        original.claudeSessionFolder = "/tmp/pasta"
        original.claudeSeenCount = 4
        original.memorySavedCount = 4
        original.summary = "resumo"
        let (model, botID) = model(current: original)
        await model.newConversation(botID)?.value
        let entry = try #require(store.readArchive(botID).first)

        #expect(await model.reopenConversation(entry.id, of: botID))
        let reopened = try #require(model.conversations[botID])
        #expect(reopened.claudeSessionID == "sessao-abc" && reopened.claudeSessionFolder == "/tmp/pasta")
        #expect(reopened.claudeSeenCount == 4 && reopened.summary == "resumo")
        #expect(reopened.memorySavedCount == 4) // all of it was saved already: leaving again saves nothing new

        await model.newConversation(botID)?.value
        let again = try #require(store.readArchive(botID).first)
        #expect(store.readArchived(again.id, for: botID).value?.memorySavedCount == 4)
    }

    @Test @MainActor func reopeningAConversationThatCannotBeReadChangesNothingAndSaysSo() async throws {
        let (model, botID) = model(current: conversation("atual"))
        let broken = UUID()
        try put("{ not json", at: archiveFolder(botID).appending(path: "\(broken.uuidString).json"))

        #expect(await model.reopenConversation(broken, of: botID) == false)

        #expect(model.transcript(botID).count == 2)
        #expect(model.dataNotices.count == 1)
        #expect(store.readArchive(botID).isEmpty)
    }

    // MARK: Deleting

    // MARK: Pictures of a deleted conversation

    /// A picture file in the Orb's `anexos/<id>/`, as `ImageStore` writes them.
    private func picture(for botID: UUID) throws -> ImageAttachment {
        let folder = root.appending(path: "anexos/\(botID.uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(UUID().uuidString).jpg")
        try Data("jpeg".utf8).write(to: file)
        return ImageAttachment(path: file.path, mediaType: "image/jpeg", width: 1, height: 1)
    }

    private func conversation(showing images: [ImageAttachment]) -> Conversation {
        var made = conversation("com imagem")
        made.messages.append(.user("olhe", images: images))
        return made
    }

    private func exists(_ image: ImageAttachment) -> Bool { FileManager.default.fileExists(atPath: image.path) }

    @Test @MainActor func deletingAnArchivedConversationRemovesItsPictures() throws {
        let (model, botID) = model(current: conversation("atual"))
        let mine = try picture(for: botID), alsoMine = try picture(for: botID), unrelated = try picture(for: botID)
        let archived = store.archive(conversation(showing: [mine, alsoMine]), for: botID)
        store.flush()

        model.deleteArchivedConversation(archived.id, of: botID)
        store.flush()

        #expect(!exists(mine) && !exists(alsoMine))
        #expect(exists(unrelated)) // nothing else points to it, but this conversation did not either
    }

    @Test @MainActor func aPictureAnotherConversationStillUsesStays() throws {
        let (model, botID) = model(current: conversation("atual"))
        let shared = try picture(for: botID), onlyHere = try picture(for: botID)
        let first = store.archive(conversation(showing: [shared, onlyHere]), for: botID)
        _ = store.archive(conversation(showing: [shared]), for: botID)
        store.flush()

        model.deleteArchivedConversation(first.id, of: botID)
        store.flush()

        #expect(exists(shared) && !exists(onlyHere))
    }

    @Test @MainActor func aPictureTheCurrentConversationUsesStaysWhetherSavedOrOnlyInMemory() throws {
        let (model, botID) = model(current: conversation("atual"))
        let onDisk = try picture(for: botID), inMemory = try picture(for: botID), attached = try picture(for: botID)
        let archived = store.archive(conversation(showing: [onDisk, inMemory, attached]), for: botID)
        store.save(conversation(showing: [onDisk]), for: botID) // the saved current conversation
        store.flush()
        model.session(botID).conversation = conversation(showing: [inMemory]) // newer than the file
        model.composerLane(botID).pictures = [attached] // typed, not sent yet

        model.deleteArchivedConversation(archived.id, of: botID)
        store.flush()

        #expect(exists(onDisk) && exists(inMemory) && exists(attached))
    }

    @Test @MainActor func aRoutinesConversationKeepsItsPicturesToo() throws {
        let (model, botID) = model(current: conversation("atual"))
        let shot = try picture(for: botID)
        let archived = store.archive(conversation(showing: [shot]), for: botID)
        store.saveRoutineConversation(conversation(showing: [shot]), routine: UUID(), for: botID)
        store.flush()

        model.deleteArchivedConversation(archived.id, of: botID)
        store.flush()

        #expect(exists(shot))
    }

    @Test @MainActor func picturesOfAnotherOrbAndFilesOutsideTheStoreAreNotTouched() throws {
        let (model, botID) = model(current: conversation("atual"))
        let other = try picture(for: UUID())
        let outside = root.appending(path: "foto-do-usuario.jpg")
        try Data("x".utf8).write(to: outside)
        let outsideImage = ImageAttachment(path: outside.path, mediaType: "image/jpeg", width: 1, height: 1)
        let archived = store.archive(conversation(showing: [other, outsideImage]), for: botID)
        store.flush()

        model.deleteArchivedConversation(archived.id, of: botID)
        store.flush()

        #expect(exists(other))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    /// The `.corrupt-<date>` copies the Store sets aside (to be recovered by hand) still count as pointing at a picture.
    @Test @MainActor func aPictureASetAsideCopyStillNamesStays() throws {
        let (model, botID) = model(current: conversation("atual"))
        let inCurrentCopy = try picture(for: botID), inArchiveCopy = try picture(for: botID), onlyHere = try picture(for: botID)
        let otherOrbsCopy = try picture(for: UUID())
        let archived = store.archive(conversation(showing: [inCurrentCopy, inArchiveCopy, onlyHere, otherOrbsCopy]), for: botID)
        store.flush()
        try put("{ broken \"path\":\"\(inCurrentCopy.path)\"",
                at: root.appending(path: "conversations/\(botID.uuidString).json.corrupt-20260101-120000"))
        try put("{ broken \"path\":\"\(inArchiveCopy.path)\"",
                at: archiveFolder(botID).appending(path: "\(UUID().uuidString).json.corrupt-20260101-120000"))
        // Another Orb's set-aside copy in the shared folder says nothing about this Orb.
        try put("{ broken \"path\":\"\(onlyHere.path)\"",
                at: root.appending(path: "conversations/\(UUID().uuidString).json.corrupt-20260101-120000"))

        model.deleteArchivedConversation(archived.id, of: botID)
        store.flush()

        #expect(exists(inCurrentCopy) && exists(inArchiveCopy))
        #expect(!exists(onlyHere))
        #expect(exists(otherOrbsCopy)) // another Orb's folder: never touched
    }

    @Test @MainActor func reopeningAConversationKeepsItsPictures() async throws {
        let (model, botID) = model(current: conversation("atual"))
        let shot = try picture(for: botID)
        let archived = store.archive(conversation(showing: [shot]), for: botID)
        store.flush()

        #expect(await model.reopenConversation(archived.id, of: botID))
        store.flush()

        #expect(exists(shot))
    }

    @Test func aDamagedArchiveFileStillGivesUpItsPictures() throws {
        let botID = UUID()
        let shot = try picture(for: botID)
        let id = UUID()
        try put(#"{ broken "path":"\#(shot.path)"#, at: archiveFolder(botID).appending(path: "\(id.uuidString).json"))

        store.deleteArchived(id, for: botID, removingPicturesUnlessUsedBy: [])
        store.flush()

        #expect(!exists(shot))
    }

    @Test @MainActor func deletingAnArchivedConversationRemovesItForGood() async throws {
        let (model, botID) = model(current: conversation("apagar"))
        await model.newConversation(botID)?.value
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
        await model.newConversation(botID)?.value
        model.saveNow()

        let relaunched = AppModel(store: store, runsBackgroundWork: false)
        await relaunched.loadArchive(botID)
        #expect(relaunched.archives[botID]?.map(\.title) == ["de ontem"])
    }
}
