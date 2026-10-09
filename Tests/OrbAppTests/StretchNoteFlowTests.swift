import Foundation
import Testing
@testable import Orb

// The note on the stretch the next fold will take, through the app with the real engine and a fake model: it is asked
// for when a turn of the chat ends and the history is near its budget, in the background, never otherwise; the fold
// that takes the stretch carries it into the summary and into the memory page; without it everything works by rules.

/// What the fake model was asked: the turns of the Orb, and the requests for a note (told apart by their instructions).
private actor Asked {
    private(set) var turns = 0
    private(set) var notes: [(messages: [ChatMessage], tools: [ToolSpec], model: String)] = []
    func turn() { turns += 1 }
    func note(_ messages: [ChatMessage], _ tools: [ToolSpec], _ model: String) { notes.append((messages, tools, model)) }
}

private enum NoteAnswer {
    case text(String)
    case fails
    /// Never answers: the request stays open until the task that waits for it is cancelled.
    case hangs
}

private struct FakeModel: LLMClient {
    let asked: Asked
    var answer = NoteAnswer.text("O usuário construiu o Atlas; ficou decidido usar SQLite e a porta 4711.")
    /// A file the turn reads before it answers (a tool step that makes the history grow inside the turn).
    var reads: String?

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                guard messages.first?.content == ChunkSummarizer.instructions else {
                    await asked.turn()
                    if let reads, messages.last?.role != .tool {
                        continuation.yield(.toolCalls([ToolCallRequest(id: "leitura", name: "read_file", arguments: #"{"path":"\#(reads)"}"#)]))
                        continuation.yield(.finished(.toolUse, nil))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.text("ok"))
                    continuation.finish()
                    return
                }
                await asked.note(messages, tools, model)
                switch answer {
                case .text(let text):
                    continuation.yield(.text(text))
                    continuation.yield(.finished(.done, TokenUsage(input: 3_000, output: 60)))
                    continuation.finish()
                case .fails:
                    continuation.finish(throwing: LLMError.network(code: -1009, message: "offline"))
                case .hangs:
                    try? await Task.sleep(for: .seconds(60))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}

@MainActor
final class StretchNoteFlowTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbStretchNote-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

    /// An Orb on a model with a 32k window, with a short conversation. The notes are off until `armed`.
    private func setUp(answer: NoteAnswer = .text("O usuário construiu o Atlas; ficou decidido usar SQLite e a porta 4711."),
                       devRun: Bool = false, provider: ProviderKind = .custom) throws -> (AppModel, UUID, Asked) {
        let folder = root.appending(path: "pasta")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var conversation = Conversation()
        for index in 0..<2 {
            let request = index == 0 ? "Construa o app Atlas com SQLite e rode os testes a cada mudança" : "pedido \(index) do projeto"
            conversation.messages += [.user(request), ChatMessage(role: .assistant, content: "resposta \(index)")]
            conversation.items += [TranscriptItem(.user(text: request, attachments: [])), TranscriptItem(.bot(text: "resposta \(index)", isStreaming: false))]
        }
        var state = AppState.initial
        state.bots[0].workingDirectory = folder.path
        let store = Store(directory: root.appending(path: "dados"))
        store.save(state)
        store.save(conversation, for: state.bots[0].id)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false, devRun: devRun)
        model.providers = [ProviderAccount(kind: provider)]
        model.defaultModel = "\(provider.rawValue)/modelo"
        model.learnContextWindow(32_000, of: "\(provider.rawValue)/modelo")
        let asked = Asked()
        model.clientOverride = { FakeModel(asked: asked, answer: answer) }
        return (model, state.bots[0].id, asked)
    }

    /// Sends a message and waits for the turn to end.
    private func say(_ text: String, _ model: AppModel, _ botID: UUID) async {
        #expect(model.send(text, to: botID))
        await waitUntil("the turn to end") { !model.isWorking(botID) }
    }

    /// Adds long turns until the history takes `share` of the budget (the budget as the engine measured it).
    private func grow(to share: Double, _ model: AppModel, _ botID: UUID) throws {
        while try #require(model.contextFill(for: botID)).budgetFraction < share {
            model.editConversation(botID) { chat in
                let index = chat.messages.count
                chat.messages += [.user("pedido \(index) " + String(repeating: "a", count: 1_700)),
                                  ChatMessage(role: .assistant, content: "resposta \(index) " + String(repeating: "b", count: 1_700))]
                chat.items += [TranscriptItem(.user(text: "pedido \(index)", attachments: [])), TranscriptItem(.bot(text: "resposta \(index)", isStreaming: false))]
            }
        }
    }

    /// A first turn measures the real overhead of the prompt, so the budget the test grows to is the one the app uses.
    private func warmUp(_ model: AppModel, _ botID: UUID) async {
        await say("primeiro", model, botID)
    }

    @Test func aNoteIsAskedForWhenATurnEndsNearTheBudgetAndKeptWithoutAnyTrace() async throws {
        let (model, botID, asked) = try setUp()
        await warmUp(model, botID)
        try grow(to: 0.72, model, botID)
        model.writesStretchNotes = true

        await say("e agora?", model, botID)
        let itemsAtTheEnd = model.transcript(botID).count
        await waitUntil("the note") { model.conversations[botID]?.chunkSummaries?.count == 1 }

        let notes = await asked.notes
        #expect(notes.count == 1)
        #expect(await asked.turns == 2)
        // One plain request: the instructions, the stretch, no tools.
        let request = try #require(notes.first)
        #expect(request.messages.count == 2 && request.tools.isEmpty)
        #expect(request.messages[1].content.contains("User: Construa o app Atlas"))
        #expect(request.model == "modelo")
        let chunk = try #require(model.conversations[botID]?.chunkSummaries?.first)
        #expect(chunk.start == 0 && chunk.end > 2)
        #expect(chunk.text.contains("porta 4711"))
        // Nothing for the user to see, and the turn is over: the chat is as the turn left it.
        #expect(model.transcript(botID).count == itemsAtTheEnd)
        #expect(!model.transcript(botID).contains { if case .notice = $0.kind { true } else { false } })
        await waitUntil("the task to end") { model.session(botID).chunkTask == nil }

        // The same stretch is not asked about twice.
        await say("mais uma", model, botID)
        await waitUntil("the task to end") { model.session(botID).chunkTask == nil }
        #expect(await asked.notes.count == 1)
    }

    @Test func nothingIsAskedBelowSixtyPercentOfTheBudget() async throws {
        let (model, botID, asked) = try setUp()
        await warmUp(model, botID)
        try grow(to: 0.5, model, botID)
        model.writesStretchNotes = true

        await say("e agora?", model, botID)
        await waitUntil("the check to end") { model.session(botID).chunkTask == nil }
        #expect(await asked.notes.isEmpty)
        #expect(model.conversations[botID]?.chunkSummaries == nil)
    }

    @Test func nothingIsAskedForARoutineADeveloperRunADisabledSwitchOrClaudeCode() async throws {
        // The control: with everything in order a note starts.
        let (model, botID, asked) = try setUp()
        await warmUp(model, botID)
        try grow(to: 0.75, model, botID)
        model.writesStretchNotes = true
        model.writeStretchNote(of: botID)
        #expect(model.session(botID).chunkTask != nil)
        await waitUntil("the note") { model.conversations[botID]?.chunkSummaries?.count == 1 }
        #expect(await asked.notes.count == 1)

        func quiet(_ prepare: (AppModel, BotSession) -> Void, _ what: String) async throws {
            let (model, botID, asked) = try setUp()
            await warmUp(model, botID)
            try grow(to: 0.75, model, botID)
            model.writesStretchNotes = true
            prepare(model, model.session(botID))
            model.writeStretchNote(of: botID)
            #expect(model.session(botID).chunkTask == nil, "\(what)")
            #expect(await asked.notes.isEmpty, "\(what)")
        }
        try await quiet({ _, session in session.routineID = UUID() }, "a routine's run")
        try await quiet({ model, _ in model.writesStretchNotes = false }, "the switch off (tests, previews)")
        try await quiet({ model, _ in model.bots[0].model = "claudeCode/sonnet" }, "Claude Code")

        // A developer mode, even with the switch forced on.
        let (dev, devBot, devAsked) = try setUp(devRun: true)
        dev.writesStretchNotes = true
        try grow(to: 0.75, dev, devBot)
        dev.writeStretchNote(of: devBot)
        #expect(dev.session(devBot).chunkTask == nil)
        #expect(await devAsked.notes.isEmpty)
    }

    @Test func aFailureLeavesTheRulesAndIsTriedOneMoreTimeAtMost() async throws {
        let (model, botID, asked) = try setUp(answer: .fails)
        await warmUp(model, botID)
        try grow(to: 0.75, model, botID)
        model.writesStretchNotes = true

        for attempt in 1...3 {
            model.writeStretchNote(of: botID)
            await waitUntil("attempt \(attempt) to end") { model.session(botID).chunkTask == nil }
        }
        #expect(await asked.notes.count == ChunkSummarizer.maxAttempts)
        #expect(model.conversations[botID]?.chunkSummaries == nil)
        // Nothing waited for it and nothing broke: the fold at sending is the rules'.
        model.editConversation(botID) { $0.summary = nil }
        await say("e agora?", model, botID)
        #expect(!(model.conversations[botID]?.messages.isEmpty ?? true))
    }

    @Test func theNoteIsDroppedWhenTheConversationChangesOrTheOrbGoes() async throws {
        // A new conversation.
        let (model, botID, asked) = try setUp(answer: .hangs)
        await warmUp(model, botID)
        try grow(to: 0.75, model, botID)
        model.writesStretchNotes = true
        model.writeStretchNote(of: botID)
        await waitUntil("the request") { await asked.notes.count == 1 }
        let task = try #require(model.session(botID).chunkTask)
        model.newConversation(botID)
        #expect(model.session(botID).chunkTask == nil)
        await task.value // it ends: cancelled, nothing kept
        #expect(model.conversations[botID]?.chunkSummaries == nil)

        // The Orb deleted.
        let (other, otherBot, otherAsked) = try setUp(answer: .hangs)
        await warmUp(other, otherBot)
        try grow(to: 0.75, other, otherBot)
        other.writesStretchNotes = true
        other.writeStretchNote(of: otherBot)
        await waitUntil("the request") { await otherAsked.notes.count == 1 }
        let pending = try #require(other.session(otherBot).chunkTask)
        let session = other.session(otherBot)
        other.deleteBot(otherBot)
        await pending.value
        #expect(session.chunkTask == nil && session.conversation == nil)
    }

    @Test func theNoteIsDroppedWhenTheAppResets() async throws {
        let (model, botID, asked) = try setUp(answer: .hangs)
        await warmUp(model, botID)
        try grow(to: 0.75, model, botID)
        model.writesStretchNotes = true
        model.writeStretchNote(of: botID)
        await waitUntil("the request") { await asked.notes.count == 1 }
        let task = try #require(model.session(botID).chunkTask)
        await model.stopForReset(wait: .seconds(1))
        await task.value
        #expect(model.session(botID).chunkTask == nil)
        #expect(model.conversations[botID]?.chunkSummaries == nil)
    }

    @Test func theFoldThatTakesTheStretchCarriesTheNoteIntoTheSummaryAndTheMemoryPage() async throws {
        let (model, botID, asked) = try setUp()
        await warmUp(model, botID)
        try grow(to: 0.72, model, botID)
        model.writesStretchNotes = true
        await say("e agora?", model, botID)
        await waitUntil("the note") { model.conversations[botID]?.chunkSummaries?.count == 1 }
        await waitUntil("the task to end") { model.session(botID).chunkTask == nil }
        model.writesStretchNotes = false

        // The history grows past the budget: the next message folds the stretch.
        try grow(to: 1.05, model, botID)
        await say("continua", model, botID)
        let conversation = try #require(model.conversations[botID])
        #expect(conversation.compactions == 1)
        let summary = try #require(conversation.summary)
        #expect(summary.contains("Pedido original: Construa o app Atlas"))
        #expect(summary.contains("O usuário construiu o Atlas; ficou decidido usar SQLite e a porta 4711."))
        #expect(conversation.ledger?.digests.count == 1)
        // The memory page of that stretch, written before the messages left the window, has the same text.
        let bank = model.memory.bank(for: botID)
        await waitUntil("the session page") { await bank.snapshot().items.contains { $0.kind == .sessao && $0.body.contains("## Resumo") } }
        let page = try #require(await bank.snapshot().items.first { $0.kind == .sessao })
        #expect(SessionSummary.section("Resumo", in: page.body) == ["O usuário construiu o Atlas; ficou decidido usar SQLite e a porta 4711."])
        // And the model got the summary with the note in the request that followed.
        #expect(await asked.notes.count == 1)
    }

    @Test func theFoldWithoutANoteIsWhatItAlwaysWas() async throws {
        let (model, botID, asked) = try setUp()
        await warmUp(model, botID)
        try grow(to: 1.05, model, botID)
        await say("continua", model, botID)
        let conversation = try #require(model.conversations[botID])
        #expect(conversation.compactions == 1)
        #expect(conversation.summary?.contains("Pedido original: Construa o app Atlas") == true)
        #expect(conversation.summary?.contains("Notas automáticas") == false)
        #expect(await asked.notes.isEmpty)
    }

    // MARK: Slow talkers, local servers, routines

    @Test func aSlowTalkersConversationHasItsNoteBeforeTheColdFold() async throws {
        let (model, botID, asked) = try setUp()
        await warmUp(model, botID)
        // 65%: under the 70% a note once waited for, over the 60% where a cold cache folds.
        try grow(to: 0.65, model, botID)
        model.writesStretchNotes = true
        await say("e agora?", model, botID)
        await waitUntil("the note") { model.conversations[botID]?.chunkSummaries?.count == 1 }
        await waitUntil("the task to end") { model.session(botID).chunkTask == nil }
        model.writesStretchNotes = false
        #expect(model.conversations[botID]?.compactions == nil)

        // The user comes back after ten minutes: the provider's cache is cold, so the start is folded already (at 60%).
        model.editConversation(botID) { $0.lastModelCall = Date.now.addingTimeInterval(-600) }
        await say("voltei", model, botID)
        let conversation = try #require(model.conversations[botID])
        #expect(conversation.compactions == 1)
        #expect(conversation.summary?.contains("porta 4711") == true)
        #expect(conversation.ledger?.digests.count == 1)
        #expect(await asked.notes.count == 1)
    }

    @Test func aStretchSavedByRulesBeforeTheFoldStillGivesTheMemoryItsNoteOnce() async throws {
        let (model, botID, _) = try setUp()
        await warmUp(model, botID)
        try grow(to: 0.65, model, botID)
        model.writesStretchNotes = true
        await say("e agora?", model, botID)
        await waitUntil("the note") { model.conversations[botID]?.chunkSummaries?.count == 1 }
        await waitUntil("the task to end") { model.session(botID).chunkTask == nil }
        model.writesStretchNotes = false

        // Half an hour of silence saves the stretch by rules, before the note was used.
        let bank = model.memory.bank(for: botID)
        #expect(model.session(botID).saveMemory())
        await waitUntil("the page by rules") { await bank.snapshot().items.filter { $0.kind == .sessao }.count == 1 }
        // The user is back: the cold cache folds the stretch with the note.
        model.editConversation(botID) { $0.lastModelCall = Date.now.addingTimeInterval(-600) }
        await say("voltei", model, botID)
        #expect(model.conversations[botID]?.ledger?.digests.count == 1)
        await waitUntil("the note's page") { await bank.snapshot().items.filter { $0.kind == .sessao }.count == 2 }
        let pages = await bank.snapshot().items.filter { $0.kind == .sessao }
        #expect(pages.filter { $0.body.contains("porta 4711") }.count == 1)
        let withNote = try #require(pages.first { $0.body.contains("porta 4711") })
        #expect(SessionSummary.section("Resumo", in: withNote.body).count == 1)
        // A later message does not send it again.
        model.writesStretchNotes = false
        await say("mais uma", model, botID)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await bank.snapshot().items.filter { $0.kind == .sessao && $0.body.contains("porta 4711") }.count == 1)
    }

    @Test func onALocalServerTheNoteGivesWayToTheNextMessageAndIsNotCounted() async throws {
        let (model, botID, asked) = try setUp(answer: .hangs, provider: .ollama)
        model.localNoteDelay = 0.05
        await warmUp(model, botID)
        try grow(to: 0.75, model, botID)
        model.writesStretchNotes = true
        model.writeStretchNote(of: botID)
        await waitUntil("the request") { await asked.notes.count == 1 }
        let task = try #require(model.session(botID).chunkTask)
        model.writesStretchNotes = false

        await say("e agora?", model, botID)
        #expect(model.session(botID).chunkTask == nil)
        await task.value
        #expect(model.session(botID).chunkAttempts.isEmpty)
        #expect(model.conversations[botID]?.chunkSummaries == nil)
    }

    @Test func aLocalServerIsAskedOnlyAfterItWasLeftAloneUntilItsCacheWentCold() async throws {
        let (model, botID, asked) = try setUp(provider: .lmstudio)
        // The wait is the time the cache takes to go cold anyway.
        #expect(model.localNoteDelay == ContextBudget.cacheColdAfter)
        model.localNoteDelay = 2
        await warmUp(model, botID)
        try grow(to: 0.75, model, botID)
        model.writesStretchNotes = true
        model.writeStretchNote(of: botID)
        // Nothing is sent while the server's cache is warm...
        try await Task.sleep(for: .milliseconds(200))
        #expect(await asked.notes.isEmpty)
        #expect(model.session(botID).chunkTask != nil)
        // ...and once it has been left alone for the wait, the note is written.
        await waitUntil("the note") { model.conversations[botID]?.chunkSummaries?.count == 1 }
        #expect(await asked.notes.count == 1)
    }

    @Test func aLocalServersNoteKeepsTheConversationInMemoryUntilItIsWritten() async throws {
        let (model, botID, asked) = try setUp(provider: .ollama)
        model.localNoteDelay = 1
        await warmUp(model, botID)
        try grow(to: 0.75, model, botID)
        model.writesStretchNotes = true
        model.writeStretchNote(of: botID)
        model.selection = nil
        // The sweep after the keep-alive comes while the note still waits: the conversation stays, and the note is written.
        await model.unloadIdleConversations(now: .now + .seconds(301))
        #expect(model.session(botID).conversation != nil && model.session(botID).chunkTask != nil)
        await waitUntil("the note") { model.conversations[botID]?.chunkSummaries?.count == 1 }
        #expect(await asked.notes.count == 1)
    }

    @Test func aMessageSentWhileALocalServerWaitsForTheNoteCancelsItWithoutAsking() async throws {
        let (model, botID, asked) = try setUp(provider: .ollama)
        await warmUp(model, botID)
        try grow(to: 0.75, model, botID)
        model.writesStretchNotes = true
        model.writeStretchNote(of: botID)
        let task = try #require(model.session(botID).chunkTask)
        model.writesStretchNotes = false

        await say("e agora?", model, botID)
        #expect(model.session(botID).chunkTask == nil)
        await task.value
        #expect(await asked.notes.isEmpty)
        #expect(model.session(botID).chunkAttempts.isEmpty)
        #expect(model.conversations[botID]?.chunkSummaries == nil)
    }

    @Test func onAnyOtherProviderTheNoteRunsAlongsideTheNextMessage() async throws {
        let (model, botID, asked) = try setUp(answer: .hangs)
        await warmUp(model, botID)
        try grow(to: 0.75, model, botID)
        model.writesStretchNotes = true
        model.writeStretchNote(of: botID)
        await waitUntil("the request") { await asked.notes.count == 1 }
        let task = try #require(model.session(botID).chunkTask)
        model.writesStretchNotes = false

        await say("e agora?", model, botID)
        #expect(model.session(botID).chunkTask != nil)
        model.session(botID).cancelChunkNote()
        await task.value
    }

    @Test func aRoutineStartingDropsTheNoteOfTheChatItParks() async throws {
        let (model, botID, asked) = try setUp(answer: .hangs)
        await warmUp(model, botID)
        try grow(to: 0.75, model, botID)
        model.writesStretchNotes = true
        model.writeStretchNote(of: botID)
        await waitUntil("the request") { await asked.notes.count == 1 }
        let task = try #require(model.session(botID).chunkTask)

        let session = model.session(botID)
        session.startRoutineRun(UUID(), conversation: Conversation(), at: .now)
        #expect(session.chunkTask == nil)
        await task.value
        #expect(session.parkedChat?.chunkSummaries == nil && session.conversation?.chunkSummaries == nil)

        // A note that still arrives while the routine has the conversation is not kept in its file.
        let end = try #require(session.parkedChat?.messages.count)
        session.keepStretchNote(ChunkSummary(start: 0, end: 2, text: String(repeating: "n", count: 60)))
        #expect(session.conversation?.chunkSummaries == nil && end > 2)
    }

    @Test func aStretchThatWasAskedAboutTwiceIsNotPlannedAgain() async throws {
        let (model, botID, asked) = try setUp(answer: .fails)
        await warmUp(model, botID)
        try grow(to: 0.75, model, botID)
        model.writesStretchNotes = true
        for _ in 1...ChunkSummarizer.maxAttempts {
            model.writeStretchNote(of: botID)
            await waitUntil("the attempt to end") { model.session(botID).chunkTask == nil }
        }
        #expect(await asked.notes.count == ChunkSummarizer.maxAttempts)
        // Over: nothing starts at all, not even the (costly) plan.
        model.writeStretchNote(of: botID)
        #expect(model.session(botID).chunkTask == nil)
    }

    // MARK: A fold inside a turn

    @Test func aFoldInsideATurnCarriesTheNoteToTheSummaryAndTheMemoryPage() async throws {
        let (model, botID, asked) = try setUp()
        await warmUp(model, botID)
        try grow(to: 0.72, model, botID)
        model.writesStretchNotes = true
        await say("e agora?", model, botID)
        await waitUntil("the note") { model.conversations[botID]?.chunkSummaries?.count == 1 }
        await waitUntil("the task to end") { model.session(botID).chunkTask == nil }
        model.writesStretchNotes = false
        #expect(model.conversations[botID]?.compactions == nil)

        // A turn with a tool step that brings a big output: the history passes the budget inside the turn.
        let file = root.appending(path: "pasta/grande.txt")
        try String(repeating: "uma linha do arquivo grande\n", count: 1_200).write(to: file, atomically: true, encoding: .utf8)
        model.clientOverride = { FakeModel(asked: asked, reads: file.path) }
        await say("leia o arquivo grande", model, botID)

        let conversation = try #require(model.conversations[botID])
        #expect((conversation.compactions ?? 0) >= 1)
        #expect(conversation.summary?.contains("porta 4711") == true)
        #expect(conversation.ledger?.digests.count == 1)
        // The memory page written at the end of the turn has the same note, once.
        let bank = model.memory.bank(for: botID)
        await waitUntil("the page") { await bank.snapshot().items.contains { $0.kind == .sessao && $0.body.contains("## Resumo") } }
        let pages = await bank.snapshot().items.filter { $0.kind == .sessao && $0.body.contains("porta 4711") }
        #expect(pages.count == 1)
        #expect(await asked.notes.count == 1)
    }
}
