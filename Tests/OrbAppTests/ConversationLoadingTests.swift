import Foundation
import Testing
@testable import Orb

/// Conversations are read off the main thread (at launch and when you switch), shown as "loading" meanwhile, never
/// saved over while they are not in memory, and let go of again when nobody is looking at them.
@Suite final class ConversationLoadingTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbLoading-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    private func conversationURL(_ id: UUID) -> URL { root.appending(path: "conversations/\(id.uuidString).json") }

    private func put(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// Three Orbs with one saved exchange each (the first one has not been said "goodbye" to: nothing unsaved in memory).
    @MainActor private func orbs(count: Int = 3, unsaved: Bool = false, long: Bool = false, saved: Bool = true) throws -> [Bot] {
        var state = AppState.initial
        for index in 1..<count { state.bots.append(Bot(name: "Orb \(index)", role: "", orb: OrbConfig())) }
        let store = Store(directory: root)
        store.save(state)
        let old = Date.now.addingTimeInterval(-3 * 3600) // long enough ago for the memory to treat it as finished
        for (index, bot) in state.bots.enumerated() {
            var conversation = Conversation()
            for turn in 0..<(long ? 40 : 1) {
                var user = TranscriptItem(.user(text: "conversa \(index) pergunta \(turn)", attachments: []))
                user.date = old
                var answer = TranscriptItem(.bot(text: "resposta \(turn)", isStreaming: false))
                answer.date = old
                conversation.items += [user, answer]
                conversation.messages += [.user("conversa \(index) pergunta \(turn)"), ChatMessage(role: .assistant, content: "resposta \(turn)")]
            }
            conversation.memorySavedCount = unsaved ? 0 : (saved ? conversation.items.count : nil)
            store.save(conversation, for: bot.id)
        }
        store.flush()
        return state.bots
    }

    @MainActor private func launch(async asyncLoading: Bool) -> AppModel {
        AppModel(store: Store(directory: root), runsBackgroundWork: false, asyncLoading: asyncLoading)
    }

    // MARK: Launch and switching

    @Test @MainActor func theFirstConversationIsReadAfterInitAndTheChatSaysSo() async throws {
        let bots = try orbs()
        let model = launch(async: true)
        #expect(model.isLoadingConversation(bots[0].id))
        #expect(model.transcript(bots[0].id).isEmpty, "init did not wait for the file")

        await model.loadedConversation(bots[0].id)
        #expect(!model.isLoadingConversation(bots[0].id))
        #expect(model.transcript(bots[0].id).count == 2)
        #expect(model.conversations[bots[1].id] == nil, "only the Orb on screen is read at launch")
    }

    @Test @MainActor func switchingToAnUnreadOrbReturnsAtOnceAndFillsInLater() async throws {
        let bots = try orbs()
        let model = launch(async: true)
        await model.loadedConversation(bots[0].id)
        model.live(bots[1].id).setUnread(3)

        model.selection = .bot(bots[1].id)
        #expect(model.isLoadingConversation(bots[1].id))
        #expect(model.transcript(bots[1].id).isEmpty)
        #expect(model.live(bots[1].id).unread == 0)

        await model.loadedConversation(bots[1].id)
        #expect(!model.isLoadingConversation(bots[1].id))
        #expect(model.transcript(bots[1].id).count == 2)
    }

    @Test @MainActor func aMessageSentWhileTheConversationIsStillLoadingKeepsItsHistoryAndIsNotDuplicated() async throws {
        let bots = try orbs()
        let model = launch(async: true)
        #expect(model.isLoadingConversation(bots[0].id))

        // No model is set up, so the send is refused, but it adds a notice to the conversation: that needs the history.
        #expect(model.send("oi", to: bots[0].id) == false)
        #expect(model.transcript(bots[0].id).count == 3) // two from the file and the notice
        await model.loadedConversation(bots[0].id) // the read that was under way arrives and is dropped
        #expect(model.transcript(bots[0].id).count == 3)
        #expect(!model.isLoadingConversation(bots[0].id))
    }

    @Test @MainActor func aDamagedUsageFileDoesNotStopIdleConversationsFromBeingLetGoOf() async throws {
        let bots = try orbs()
        let model = launch(async: false)
        model.conversationKeepAlive = .zero
        // A month of usage that cannot be read is set aside when the recorder writes: news for the user, not a failed save.
        try put(Data(#"{"buckets":[{"#.utf8), at: root.appending(path: "uso/\(Store.usageMonthID(of: .now)).json"))
        model.usageLog.record(UsageTotals(requests: 1, input: 3), orb: bots[0].id, name: "Atlas", model: "openai/gpt-5", source: .chat)
        model.usageLog.flush()
        model.store.flush()
        for _ in 0..<500 where model.dataNotices.isEmpty { try await Task.sleep(for: .milliseconds(10)) } // the notice hops to the main actor
        #expect(model.dataNotices.count == 1)

        await model.loadRemainingConversations()
        Store(directory: root).flush()
        await model.unloadIdleConversations()
        #expect(model.conversations[bots[1].id] == nil)
    }

    @Test @MainActor func aConversationLoadedOnDemandAndLetGoOfIsReadAgainNotLeftEmpty() async throws {
        let bots = try orbs()
        let model = launch(async: false)
        model.conversationKeepAlive = .zero
        await model.loadRemainingConversations()
        Store(directory: root).flush()
        await model.unloadIdleConversations()
        #expect(model.conversations[bots[1].id] == nil)

        // Selected (a read starts) and then used before it arrives (the on-demand read wins); let go of; selected again.
        model.selection = .bot(bots[1].id)
        #expect(model.send("oi", to: bots[1].id) == false)
        #expect(!model.isLoadingConversation(bots[1].id))
        model.saveNow()
        model.selection = .bot(bots[0].id)
        Store(directory: root).flush()
        await model.unloadIdleConversations()
        model.selection = .bot(bots[1].id)
        await model.loadedConversation(bots[1].id)
        #expect(!model.isLoadingConversation(bots[1].id))
        #expect(model.transcript(bots[1].id).count == 3)
    }

    @Test @MainActor func quittingWhileAConversationIsLoadingNeverWritesItEmpty() async throws {
        let bots = try orbs()
        let original = try Data(contentsOf: conversationURL(bots[0].id))
        let sentinel = original + Data("\n".utf8) // the encoder would not write this: any rewrite shows
        try put(sentinel, at: conversationURL(bots[0].id))

        let model = launch(async: true)
        model.saveNow()
        model.selection = .bot(bots[1].id)
        model.saveNow()
        #expect(try Data(contentsOf: conversationURL(bots[0].id)) == sentinel)
        #expect(try Data(contentsOf: conversationURL(bots[1].id)).count > 10)
        await model.loadedConversation(bots[0].id)
        await model.loadedConversation(bots[1].id)
    }

    @Test @MainActor func aConversationThatLostItemsIsReportedOnceWhenReadInTheBackground() async throws {
        let bots = try orbs()
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: conversationURL(bots[1].id))) as? [String: Any])
        json["items"] = (json["items"] as? [Any] ?? []) + [["id": UUID().uuidString, "kind": ["hologram": [:]], "date": 0]]
        try put(JSONSerialization.data(withJSONObject: json), at: conversationURL(bots[1].id))

        let model = launch(async: true)
        model.selection = .bot(bots[1].id)
        await model.loadedConversation(bots[1].id)
        #expect(model.dataNotices.count == 1)
        #expect(model.dataNotices.first?.message.hasPrefix("Conversa de Orb 1: ") == true)
        #expect(model.transcript(bots[1].id).count == 2)
    }

    @Test func theChatAndARoutineRunOfAnOrbAreItsConversationFiles() {
        let store = Store(directory: root)
        let bot = UUID(), other = UUID(), routine = UUID()
        let folder = root.appending(path: "conversations/\(bot.uuidString)", directoryHint: .isDirectory)
        #expect(store.isConversationFile(root.appending(path: "conversations/\(bot.uuidString).json"), of: bot))
        #expect(store.isConversationFile(folder.appending(path: "routine-\(routine.uuidString).json"), of: bot))
        #expect(!store.isConversationFile(folder.appending(path: "routine-\(routine.uuidString).json"), of: other))
        #expect(!store.isConversationFile(root.appending(path: "state.json"), of: bot))
    }

    @Test @MainActor func aConversationThatFailedToSaveIsWrittenAgainOnQuit() async throws {
        let bots = try orbs(count: 1)
        let model = launch(async: false)
        let id = bots[0].id
        _ = await model.loadedConversation(id)

        // The folder cannot be written: a plain file sits where it should be.
        let folder = root.appending(path: "conversations")
        try FileManager.default.removeItem(at: folder)
        try Data().write(to: folder)

        model.append(.notice("última resposta"), to: id)
        model.sessions[id]?.scheduleSave(delay: 0)
        model.store.flush()
        await waitUntil("the save failure to be reported") { model.dataNotices.count == 1 }

        // Space is back; nothing else changed in the conversation.
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.saveNow()

        let saved = try #require(Store(directory: root).readConversation(id).value)
        #expect(saved.items.contains { if case .notice(let text) = $0.kind { text == "última resposta" } else { false } })
    }

    @Test @MainActor func aTurnInterruptedByAQuitIsClosedWhenTheConversationArrives() async throws {
        let bots = try orbs(count: 1)
        var conversation = Conversation()
        conversation.items = [TranscriptItem(.user(text: "oi", attachments: [])), TranscriptItem(.bot(text: "meio", isStreaming: true))]
        Store(directory: root).save(conversation, for: bots[0].id)
        Store(directory: root).flush()

        let model = launch(async: true)
        await model.loadedConversation(bots[0].id)
        guard case .bot(let text, let streaming) = model.transcript(bots[0].id).last?.kind else { Issue.record("no reply"); return }
        #expect(text == "meio" && !streaming)
    }

    @Test @MainActor func aDeletedOrbDoesNotLeaveALoadBehind() async throws {
        let bots = try orbs()
        let model = launch(async: true)
        model.selection = .bot(bots[1].id)
        model.deleteBot(bots[1].id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.conversations[bots[1].id] == nil)
        #expect(!model.isLoadingConversation(bots[1].id))
    }

    @Test @MainActor func sendWhenLoadedWaitsForTheHistoryWithoutBlocking() async throws {
        let bots = try orbs()
        let model = launch(async: false)
        #expect(model.conversations[bots[1].id] == nil)
        model.sendWhenLoaded("oi", to: bots[1].id)
        #expect(model.transcript(bots[1].id).isEmpty, "nothing happened on the main thread")
        for _ in 0..<200 where model.transcript(bots[1].id).count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.transcript(bots[1].id).count == 3) // the saved exchange and the "connect a model" notice
    }

    @Test @MainActor func aRoutineOfAnUnreadOrbWaitsForItsConversationThenRuns() async throws {
        let bots = try orbs()
        let model = launch(async: false)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        let routine = Routine(name: "Resumo", botID: bots[1].id, prompt: "resuma", schedule: .everyHours(1))
        model.routines = [routine]
        #expect(model.conversations[bots[1].id] == nil)

        model.runRoutine(routine.id)
        await model.routineStarted()
        #expect(!model.isWorking(bots[1].id))
        for _ in 0..<300 where model.conversations[bots[1].id] == nil || !model.isRoutineRunning(routine.id) && model.routines[0].runs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<300 where model.isWorking(bots[1].id) || model.turns[bots[1].id] != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.routines[0].runs.count == 1, "the run happened, and the chat's history was there for it")
        #expect(model.transcript(bots[1].id).count >= 3)
    }

    // MARK: Letting go

    @Test @MainActor func anIdleConversationIsLetGoOfAndReadAgainWhenNeeded() async throws {
        let bots = try orbs()
        let model = launch(async: false)
        model.conversationKeepAlive = .zero
        await model.loadRemainingConversations()
        Store(directory: root).flush()
        #expect(model.conversations.count == 3)

        await model.unloadIdleConversations()
        #expect(model.conversations[bots[0].id] != nil, "the one on screen stays")
        #expect(model.conversations[bots[1].id] == nil && model.conversations[bots[2].id] == nil)
        #expect(model.transcript(bots[1].id).isEmpty)

        model.selection = .bot(bots[1].id) // comes back from its file
        await model.loadedConversation(bots[1].id)
        #expect(model.transcript(bots[1].id).count == 2)
    }

    @Test @MainActor func aConversationUsedRecentlyStays() async throws {
        let bots = try orbs()
        let model = launch(async: false)
        await model.loadRemainingConversations()
        Store(directory: root).flush()
        await model.unloadIdleConversations() // the default keep-alive: five minutes
        #expect(model.conversations.count == 3)
        _ = bots
    }

    @Test @MainActor func aConversationWithUnsavedChangesIsNotLetGoOfUntilItIsWritten() async throws {
        let bots = try orbs()
        let model = launch(async: false)
        model.conversationKeepAlive = .zero
        await model.loadRemainingConversations()
        Store(directory: root).flush()

        #expect(model.send("oi", to: bots[1].id) == false) // adds a notice: changed, save pending
        await model.unloadIdleConversations()
        #expect(model.conversations[bots[1].id] != nil)
        #expect(model.transcript(bots[1].id).count == 3)

        model.saveNow()
        await model.unloadIdleConversations()
        #expect(model.conversations[bots[1].id] == nil)
        model.selection = .bot(bots[1].id)
        await model.loadedConversation(bots[1].id)
        #expect(model.transcript(bots[1].id).count == 3, "what was changed before it was let go of is on disk")
    }

    @Test @MainActor func aWorkingOrbIsNeverLetGoOf() async throws {
        let bots = try orbs()
        let model = launch(async: false)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.conversationKeepAlive = .zero
        await model.loadRemainingConversations()
        Store(directory: root).flush()
        #expect(model.send("oi", to: bots[1].id))
        #expect(model.isWorking(bots[1].id))
        await model.unloadIdleConversations()
        #expect(model.conversations[bots[1].id] != nil)
        model.stop(bots[1].id)
    }

    @Test @MainActor func nothingIsLetGoOfWhenTheNoteDoesNotMatchTheFile() async throws {
        let bots = try orbs()
        let model = launch(async: false)
        model.conversationKeepAlive = .zero
        await model.loadRemainingConversations()
        Store(directory: root).flush()
        // The file is replaced by something the note does not describe (an older build, a restore).
        try put(Data("{}".utf8), at: conversationURL(bots[1].id))
        await model.unloadIdleConversations()
        #expect(model.conversations[bots[1].id] != nil, "memory may be the only copy")
    }

    // MARK: Memory without reading everything

    @Test @MainActor func preparingMemoryDoesNotReadConversationsWithNothingToSave() async throws {
        let bots = try orbs() // saving leaves the notes a previous run would have
        let model = launch(async: false)
        await model.prepareMemory()
        #expect(model.conversations[bots[1].id] == nil && model.conversations[bots[2].id] == nil)
    }

    @Test @MainActor func preparingMemoryLetsGoOfConversationsItReadOnlyToCheck() async throws {
        let bots = try orbs()
        for bot in bots { try? FileManager.default.removeItem(at: root.appending(path: "conversations/\(bot.id.uuidString).meta.json")) }
        let model = launch(async: false)
        await model.prepareMemory() // no notes: every conversation had to be read to tell
        #expect(model.conversations[bots[1].id] == nil && model.conversations[bots[2].id] == nil)
        #expect(model.conversations[bots[0].id] != nil)
    }

    @Test @MainActor func preparingMemorySavesAFinishedStretchFromAConversationItHadToRead() async throws {
        let bots = try orbs(unsaved: true)
        let model = launch(async: false)
        await model.prepareMemory()
        try await Task.sleep(for: .milliseconds(100)) // the save the stretch asked for
        model.saveNow()
        // In memory or already back on disk, the mark says the stretch from three hours ago is in the Orb's memory.
        for bot in bots.dropFirst() {
            let marked = try #require(model.conversations[bot.id]?.memorySavedCount ?? Store(directory: root).readConversation(bot.id).value?.memorySavedCount)
            #expect(marked == 2)
        }
    }

    @Test @MainActor func aConversationFromBeforeNotesIsReadOnceToLearnWhatIsUnsaved() async throws {
        let bots = try orbs()
        for bot in bots { try? FileManager.default.removeItem(at: root.appending(path: "conversations/\(bot.id.uuidString).meta.json")) }
        let model = launch(async: false)
        let before = Store(directory: root).readMeta(bots[1].id)
        #expect(before == nil)
        await model.prepareMemory() // reads it, since nothing says whether it has an unsaved stretch
        Store(directory: root).flush()
        #expect(Store(directory: root).readMeta(bots[1].id)?.hasUnsavedStretch == false)
    }
}
