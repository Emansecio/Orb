import Foundation
import Observation
import Testing
@testable import Orb

// Each Orb's running machinery lives in its own `BotSession`: two Orbs' turns run side by side without touching each
// other, a stopped turn cannot reach the one that replaced it, routines wait only for their own Orb, a conversation is
// read and written per Orb, and a deleted Orb's session takes its pending work with it.

/// Model calls held until the test opens the gate named in the request (a `PEDIDO-…` token in the last user message).
private actor Gates {
    private var opened: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var calls: [String] = []

    func record(_ key: String) { calls.append(key) }

    func wait(_ key: String) async {
        if opened.contains(key) { return }
        await withCheckedContinuation { waiting[key, default: []].append($0) }
    }

    func open(_ key: String) {
        opened.insert(key)
        waiting.removeValue(forKey: key)?.forEach { $0.resume() }
    }

    func openAll(_ keys: [String]) { keys.forEach(open) }

    /// The `PEDIDO-…` token of a request ("" when there is none: such a call is not held). The last one: context blocks
    /// that quote the chat (a routine's `RoutineBackground`) come before the request's own words.
    nonisolated static func key(in text: String) -> String {
        guard let match = text.matches(of: /PEDIDO-[A-Z0-9]+/).last else { return "" }
        return String(match.output)
    }
}

private let allKeys = ["PEDIDO-A", "PEDIDO-B", "PEDIDO-1", "PEDIDO-2", "PEDIDO-RA", "PEDIDO-RB"]

/// Answers "resposta <token>" once the request's gate opens.
private struct GatedModel: LLMClient {
    let gates: Gates

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let key = Gates.key(in: messages.last { $0.role == .user }?.content ?? "")
                await gates.record(key)
                if !key.isEmpty { await gates.wait(key) }
                continuation.yield(.text("resposta \(key)"))
                continuation.yield(.finished(.done, nil))
                continuation.finish()
            }
        }
    }
}

/// Asks to write a file outside the Orb's folder (which needs permission), then reports once the tool answered.
private struct WritingModel: LLMClient {
    let path: String

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            if messages.last?.role == .tool {
                continuation.yield(.text("anotei"))
            } else {
                let arguments = JSONValue.object(["path": .string(path), "content": .string("oi")]).jsonString
                continuation.yield(.toolCalls([ToolCallRequest(id: "w", name: "write_file", arguments: arguments)]))
            }
            continuation.yield(.finished(.done, nil))
            continuation.finish()
        }
    }
}

@Suite final class BotSessionTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbSession-\(UUID().uuidString)")

    init() { QuietNotifications.hold() } // no banner from the test process

    deinit {
        QuietNotifications.release()
        removeTestFolder(root)
    }

    private var store: Store { Store(directory: root) }

    /// Atlas and Luna, each with a folder of its own (the Orbs must not read the real home folder) and a routine, the
    /// gated model connected. Only Atlas's conversation is read at launch (`loadRemainingConversations` reads Luna's).
    @MainActor private func setUp(_ gates: Gates, lunaChat: Conversation? = nil) -> (AppModel, UUID, UUID, [Routine]) {
        var state = AppState.initial
        state.bots.append(Bot(name: "Luna", role: "Agenda", orb: OrbConfig()))
        for index in state.bots.indices {
            let folder = root.appending(path: "pasta-\(index)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            state.bots[index].workingDirectory = folder.path
        }
        let (a, b) = (state.bots[0].id, state.bots[1].id)
        state.routines = [Routine(name: "Rotina de Atlas", botID: a, prompt: "PEDIDO-RA", schedule: .everyHours(1)),
                          Routine(name: "Rotina de Luna", botID: b, prompt: "PEDIDO-RB", schedule: .everyHours(1))]
        store.save(state)
        if let lunaChat { store.save(lunaChat, for: b) }
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.homeFolder = root
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = { GatedModel(gates: gates) }
        return (model, a, b, state.routines)
    }

    @MainActor private func texts(_ model: AppModel, _ botID: UUID) -> (user: [String], bot: [String], notices: [String]) {
        var result: (user: [String], bot: [String], notices: [String]) = ([], [], [])
        for item in model.transcript(botID) {
            switch item.kind {
            case .user(let text, _): result.user.append(text)
            case .bot(let text, _): result.bot.append(text)
            case .notice(let text): result.notices.append(text)
            case .event(let event) where event.kind == .routineRun: result.notices.append(event.sentence)
            default: break
            }
        }
        return result
    }

    @MainActor private func modelCalls(_ gates: Gates, _ count: Int) async {
        await waitUntil("\(count) model call(s)") { await gates.calls.count >= count }
    }

    // MARK: Two Orbs at once

    @Test @MainActor func twoOrbsRunTheirTurnsSideBySideAndStopOnTheirOwn() async throws {
        let gates = Gates()
        let (model, a, b, _) = setUp(gates)
        await model.loadRemainingConversations()
        defer { Task { await gates.openAll(allKeys) } }
        #expect(model.send("PEDIDO-A", to: a))
        #expect(model.send("PEDIDO-B", to: b))
        await modelCalls(gates, 2)

        let turnA = try #require(model.session(a).turnID)
        let turnB = try #require(model.session(b).turnID)
        #expect(turnA != turnB)
        #expect(model.isWorking(a) && model.isWorking(b))
        #expect(Set(model.workingIDs) == [a, b])

        // Stopping one Orb leaves the other's turn as it was.
        let stopped = model.session(a).turnTask
        model.stop(a)
        #expect(!model.isWorking(a) && model.session(a).turnID == nil)
        #expect(model.isWorking(b) && model.session(b).turnID == turnB)
        #expect(!model.canSteer(a) && model.canSteer(b))
        #expect(model.workingIDs == [b])

        // A turn of A that finishes late cannot close B's.
        model.finishTurn(b, turn: turnA)
        #expect(model.session(b).turnID == turnB)

        await gates.open("PEDIDO-B")
        await waitUntilIdle(model, b)
        #expect(texts(model, b).bot == ["resposta PEDIDO-B"])
        #expect(texts(model, b).notices.isEmpty)

        // The stopped turn's call returns now; its task has ended, and nothing of it reached A.
        await gates.open("PEDIDO-A")
        await stopped?.value
        #expect(texts(model, a).user == ["PEDIDO-A"])
        #expect(texts(model, a).bot.isEmpty)
        #expect(texts(model, a).notices == ["Você interrompeu esta resposta"])
    }

    @Test @MainActor func eventsOfOneOrbChangeOnlyItsOwnSession() {
        let model = AppModel(store: Store(directory: root.appending(path: "eventos")), runsBackgroundWork: false)
        let a = model.bots[0].id
        let b = model.createBot(name: "Luna", role: "", orb: OrbConfig(), model: "", mode: .ask, interview: false,
                                folder: .existing(root)).id
        model.apply(.message(.user("só para Luna")), to: b)
        model.apply(.usage(TokenUsage(input: 10, output: 2, cacheRead: 0, cacheWrite: 0)), to: b)
        model.apply(.notice("aviso de Luna"), to: b)
        #expect(model.session(a).usage == nil && model.session(a).conversation?.messages.isEmpty != false)
        #expect(model.session(b).usage?.input == 10)
        #expect(model.session(b).conversation?.messages.count == 1)
        #expect(texts(model, a).notices.isEmpty)
        #expect(texts(model, b).notices == ["aviso de Luna"])
    }

    // MARK: A card nobody answers

    @Test @MainActor func aCardLeftADayStopsTheTaskAndSaysWhy() async throws {
        let gates = Gates()
        let (model, a, _, _) = setUp(gates)
        await model.loadRemainingConversations()
        defer { Task { await gates.openAll(allKeys) } }
        #expect(model.send("PEDIDO-A", to: a))
        await modelCalls(gates, 1)
        let card = ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "rm -rf build", reason: "")
        model.apply(.approval(card), to: a)
        #expect(model.isPending(card.id, of: a))

        model.giveUpWaiting(on: card.id, of: a)
        #expect(!model.isWorking(a) && !model.isPending(card.id, of: a))
        #expect(texts(model, a).notices == [ApprovalWait.gaveUpNotice])
        // Answered meanwhile (or already given up on): nothing more happens.
        model.giveUpWaiting(on: card.id, of: a)
        #expect(texts(model, a).notices == [ApprovalWait.gaveUpNotice])
        #expect(ApprovalWait.reminder(ApprovalWait.remindAfter) == "Esperando há 1 h · ")
        #expect(ApprovalWait.reminder(.seconds(30 * 60)) == "Esperando há 30 min · ")
    }

    @Test @MainActor func writingInTheMessageBoxAnswersTheOrbsOpenQuestion() async throws {
        let gates = Gates()
        let (model, a, _, _) = setUp(gates)
        await model.loadRemainingConversations()
        defer { Task { await gates.openAll(allKeys) } }
        #expect(model.send("PEDIDO-A", to: a))
        await modelCalls(gates, 1)
        let card = ApprovalRequest.question(OrbQuestion(text: "Qual pasta?", options: ["Downloads", "Mesa"]), botName: "Atlas")
        model.apply(.approval(card), to: a)
        #expect(model.openQuestion(of: a) == card.id)

        #expect(model.submit("  a da Mesa  ", to: a))
        #expect(model.openQuestion(of: a) == nil && !model.isPending(card.id, of: a))
        let answered = model.transcript(a).compactMap { item -> ApprovalRequest? in
            if case .approval(let request) = item.kind { request } else { nil }
        }
        #expect(answered.first?.question?.answer == "a da Mesa" && answered.first?.decision == .once)
        #expect(model.composerLane(a).queue.isEmpty) // an answer, not a message waiting for the task
        #expect(texts(model, a).user == ["PEDIDO-A"])

        // With a question open, a command or a message longer than an answer keeps is not taken as the answer.
        let second = ApprovalRequest.question(OrbQuestion(text: "E agora?"), botName: "Atlas")
        model.apply(.approval(second), to: a)
        #expect(!model.submit("/compactar", to: a))
        #expect(model.submit(String(repeating: "a", count: OrbQuestion.answerLimit + 1), to: a))
        #expect(model.openQuestion(of: a) == second.id && model.composerLane(a).queued.count == 1)
    }

    @Test @MainActor func citarPutsTheWordsAtTheStartOfTheDraft() async {
        let gates = Gates()
        let (model, a, _, _) = setUp(gates)
        model.setDraft("por quê?", for: a)
        model.quote("Apagar as duplicadas", for: a)
        #expect(model.draftText(a) == "> Apagar as duplicadas\n\npor quê?")
    }

    // MARK: Stop and send again

    @Test @MainActor func aStoppedTurnCannotReachTheTurnSentRightAfterIt() async throws {
        let gates = Gates()
        let (model, a, _, _) = setUp(gates)
        await model.loadRemainingConversations()
        defer { Task { await gates.openAll(allKeys) } }
        #expect(model.send("PEDIDO-1", to: a))
        await modelCalls(gates, 1)
        let first = model.session(a).turnTask
        model.stop(a)

        #expect(model.send("PEDIDO-2", to: a)) // at once: the stop closed the turn
        await modelCalls(gates, 2)
        let second = try #require(model.session(a).turnID)

        // The first call answers while the second turn runs: its task ends and the second turn is untouched.
        await gates.open("PEDIDO-1")
        await first?.value
        #expect(model.session(a).turnID == second)
        #expect(model.isWorking(a))
        #expect(texts(model, a).bot.isEmpty)

        await gates.open("PEDIDO-2")
        await waitUntilIdle(model, a)
        let shown = texts(model, a)
        #expect(shown.user == ["PEDIDO-1", "PEDIDO-2"])
        #expect(shown.bot == ["resposta PEDIDO-2"])
        #expect(shown.notices == ["Você interrompeu esta resposta"])
        // The model's history: the stopped turn left its message and nothing it did not finish.
        let messages = try #require(model.session(a).conversation?.messages)
        #expect(messages.filter { $0.role == .assistant }.map(\.content) == ["resposta PEDIDO-2"])
    }

    @Test @MainActor func stoppingLeavesNoToolRunning() async throws {
        let model = AppModel(store: Store(directory: root.appending(path: "ferramenta")), runsBackgroundWork: false)
        let botID = model.bots[0].id
        let session = model.session(botID)
        _ = session.beginTurn()
        session.turnTask = Task { try? await Task.sleep(for: .seconds(30)) }
        let running = ToolCall(kind: .shell, title: "Rodando um comando", detail: "sleep 60")
        var finished = ToolCall(kind: .file, title: "Lendo", detail: "a.txt")
        finished.state = .done
        finished.output = "ok"
        model.apply(.toolStarted(finished), to: botID)
        model.apply(.toolFinished(id: finished.id, state: .done, output: "ok"), to: botID)
        model.apply(.toolStarted(running), to: botID)

        model.stop(botID)
        let calls = model.transcript(botID).compactMap { item -> ToolCall? in if case .tool(let call) = item.kind { call } else { nil } }
        #expect(calls.map(\.state) == [.done, .failed]) // the one that finished is left as it was
        #expect(calls[1].output == "Interrompido." && calls[1].finishedAt != nil)
        #expect(calls[0].output == "ok")
        #expect(model.live(botID).runningTool == nil)
    }

    @Test @MainActor func eventsPlayedForATurnThatIsNoLongerCurrentAreDropped() async {
        let model = AppModel(store: Store(directory: root.appending(path: "tarde")), runsBackgroundWork: false)
        let session = model.session(model.bots[0].id)
        let current = session.beginTurn()
        session.turnTask = Task {}
        let (events, continuation) = AsyncStream<TurnEvent>.makeStream()
        continuation.yield(.status("Lendo"))
        continuation.yield(.text("tarde demais"))
        continuation.yield(.notice("não deve aparecer"))
        continuation.finish()

        await session.play(events, turn: UUID()) // a stopped turn still draining its stream
        #expect(session.turnID == current && session.turnTask != nil) // the running turn was not closed
        #expect(session.pendingText == nil && session.liveText == nil)
        #expect(model.live(session.id).status == nil)
        #expect(model.transcript(session.id).isEmpty)
    }

    // MARK: Routines

    @Test @MainActor func aRoutineWaitsOnlyForItsOwnOrb() async throws {
        let gates = Gates()
        let (model, a, b, routines) = setUp(gates)
        await model.loadRemainingConversations()
        defer { Task { await gates.openAll(allKeys) } }
        await gates.open("PEDIDO-RA") // Atlas's routine answers at once; Luna's when the test says
        let (ofA, ofB) = (routines[0].id, routines[1].id)

        #expect(model.send("PEDIDO-A", to: a))
        await modelCalls(gates, 1)
        model.runRoutine(ofA)
        await model.routineStarted()
        #expect(model.isRoutineQueued(ofA) && !model.isRoutineRunning(ofA)) // Atlas is busy

        model.runRoutine(ofB) // Luna is free: it runs now, not behind Atlas's routine
        await model.routineStarted()
        #expect(model.isRoutineRunning(ofB) && !model.isRoutineQueued(ofB))
        #expect(model.session(b).routineID == ofB && model.session(a).routineID == nil)
        await gates.open("PEDIDO-RB")
        await waitUntil("Luna's routine to finish") { model.routines.first { $0.id == ofB }?.runs.count == 1 }
        await waitUntilIdle(model, b)
        #expect(model.isRoutineQueued(ofA)) // still waiting for Atlas

        await gates.open("PEDIDO-A")
        await waitUntil("Atlas's routine to run after its turn") { model.routines.first { $0.id == ofA }?.runs.count == 1 }
        await waitUntilIdle(model, a)
        #expect(!model.isRoutineQueued(ofA) && !model.isRoutineRunning(ofA))

        // Atlas's chat: the conversation, then one line about the routine; the routine's own items stayed out.
        let chat = texts(model, a)
        #expect(chat.user == ["PEDIDO-A"])
        #expect(chat.bot == ["resposta PEDIDO-A"])
        #expect(chat.notices.count == 1 && chat.notices[0].hasPrefix("Rotina “Rotina de Atlas” terminou"))
        #expect(model.session(a).parkedChat == nil && model.session(a).routineID == nil)
        let ownRun = try #require(store.readRoutineConversation(routine: ofA, for: a).value)
        #expect(ownRun.messages.contains { $0.content == "resposta PEDIDO-RA" })
    }

    @Test @MainActor func aRoutineParksTheChatAndGivesItBackUnchanged() async throws {
        let gates = Gates()
        let (model, a, _, routines) = setUp(gates)
        await model.loadRemainingConversations()
        defer { Task { await gates.openAll(allKeys) } }
        model.editConversation(a) { $0.items.append(TranscriptItem(.user(text: "o que eu disse", attachments: []))) }
        let chat = try #require(model.session(a).conversation)

        model.runRoutine(routines[0].id)
        await model.routineStarted()
        await modelCalls(gates, 1)
        let session = model.session(a)
        #expect(session.parkedChat?.items == chat.items) // the chat waits, untouched
        #expect(session.conversation?.items != chat.items) // the routine works on its own conversation
        // The chat narrates the run after the chat's own lines: its marker, its request and what it does. Only then
        // the chat's items, in their order.
        let runItems = session.conversation?.items ?? []
        #expect(model.transcript(a).map(\.id) == chat.items.map(\.id) + runItems.map(\.id))
        #expect(!model.canSteer(a)) // a message cannot join a routine's run

        await gates.open("PEDIDO-RA")
        await waitUntilIdle(model, a)
        #expect(session.parkedChat == nil)
        #expect(Array(model.transcript(a).prefix(chat.items.count)).map(\.id) == chat.items.map(\.id))
    }

    @Test @MainActor func aMessageWrittenDuringARoutineWaitsForItsEndAndThenGoes() async throws {
        let gates = Gates()
        let (model, a, _, routines) = setUp(gates)
        await model.loadRemainingConversations()
        defer { Task { await gates.openAll(allKeys) } }

        model.runRoutine(routines[0].id)
        await model.routineStarted()
        await modelCalls(gates, 1)
        #expect(!model.canSteer(a) && model.canQueue(a)) // it cannot join the run, but it can wait for it
        #expect(model.submit("PEDIDO-A", to: a))
        #expect(model.composerLane(a).queued.map(\.delivery) == [.afterTask]) // never into the routine's task
        #expect(model.drafts[a, default: ""].isEmpty)

        await gates.open("PEDIDO-RA")
        await gates.open("PEDIDO-A")
        // Sent as the chat's next request once the run ended (the reply's token may be the run's, which the turn is told of).
        await waitUntil("the queued message to be answered in the chat") { texts(model, a).bot.count == 1 }
        await waitUntilIdle(model, a)
        #expect(model.composerLane(a).queued.isEmpty)
        #expect(texts(model, a).user == ["PEDIDO-A"])
        let ownRun = try #require(store.readRoutineConversation(routine: routines[0].id, for: a).value)
        #expect(!ownRun.messages.contains { $0.content.contains("PEDIDO-A") })
    }

    @Test @MainActor func stoppingARoutineGivesBackWhatWaitedForIt() async throws {
        let gates = Gates()
        let (model, a, _, routines) = setUp(gates)
        await model.loadRemainingConversations()
        defer { Task { await gates.openAll(allKeys) } }

        model.runRoutine(routines[0].id)
        await model.routineStarted()
        await modelCalls(gates, 1)
        #expect(model.submit("PEDIDO-A", to: a))
        model.stopTurn(a)
        await waitUntilIdle(model, a)
        #expect(model.composerLane(a).queued.isEmpty)
        #expect(model.drafts[a] == "PEDIDO-A") // back in the composer, not sent
        #expect(texts(model, a).user.isEmpty)
    }

    @Test @MainActor func aRoutineWaitingForPermissionCanBeAnsweredFromTheApp() async throws {
        let gates = Gates()
        let (model, a, _, routines) = setUp(gates)
        await model.loadRemainingConversations()
        let target = root.appending(path: "fora/nota.txt") // outside the Orb's folder: ask
        model.clientOverride = { WritingModel(path: target.path) }
        model.update(a) { $0.permissionMode = .ask }
        let routineID = routines[0].id

        model.runRoutine(routineID)
        await model.routineStarted()
        await waitUntil("the routine to wait for you") { model.live(a).needsYou }
        // The card is in the routine's conversation; the open chat (parked) has none, but the answer still finds it.
        let card = try #require(model.liveRoutineItems(routineID)?.compactMap { item -> ApprovalRequest? in
            if case .approval(let request) = item.kind, request.decision == nil { request } else { nil }
        }.first)
        #expect(model.pendingApprovals(of: a).map(\.id) == [card.id])
        #expect(model.isPending(card.id, of: a) && model.newestPendingApprovalID(of: a) == card.id)
        #expect(model.pendingApprovals.map(\.id) == [card.id]) // the menu bar lists it too
        // The chat only says it waits; "Ver pedido" and the banner lead to the routine's conversation, where the card is.
        #expect(model.routineWaitingForYou(a) == routineID)
        model.selection = .bot(a)
        model.showApprovalOwner(a)
        #expect(model.selection == .routines && model.routineToShow == routineID)

        #expect(model.unansweredWatchers[card.id]?.count == 2) // the reminder and the giving up wait for the answer
        model.decide(.once, approvalID: card.id, botID: a)
        #expect(model.unansweredWatchers[card.id] == nil) // answered: nothing sleeps for an hour or a day any more
        await waitUntil("the routine to finish") { !model.isRoutineRunning(routineID) && model.routines.first { $0.id == routineID }?.runs.count == 1 }
        #expect(model.routines.first { $0.id == routineID }?.runs.first?.succeeded == true)
        #expect(!model.live(a).needsYou && model.pendingApprovals.isEmpty && model.routineWaitingForYou(a) == nil)
        #expect(FileManager.default.fileExists(atPath: target.path))
        model.showApprovalOwner(a) // nothing waits for you any more: the banner opens the chat
        #expect(model.selection == .bot(a))
    }

    // MARK: Reading and writing the conversation

    @Test @MainActor func anOrbsConversationIsReadWhenFirstNeededAndWrittenBack() async throws {
        let said = Conversation(items: [TranscriptItem(.bot(text: "lembra disso", isStreaming: false))], messages: [ChatMessage(role: .assistant, content: "lembra disso")])
        let (model, a, b, _) = setUp(Gates(), lunaChat: said)
        let luna = model.session(b)
        #expect(luna.isUnloaded && luna.conversation == nil) // only the Orb on screen is read at launch
        #expect(model.session(a).conversation != nil)

        model.editConversation(b) { $0.items.append(TranscriptItem(.notice("anotado"))) }
        #expect(!luna.isUnloaded)
        #expect(luna.conversation?.items.count == 2) // read from its file first, never taken for an empty one
        #expect(luna.isDirty && !model.session(a).isDirty)

        model.saveNow()
        #expect(!luna.isDirty && luna.saveTask == nil)
        let written = try #require(Store(directory: root).readConversation(b).value)
        #expect(written.items.count == 2)
    }

    @Test @MainActor func aReadUnderWayIsLeftBehindWhenTheConversationIsNeededAtOnce() async throws {
        let said = Conversation(items: [TranscriptItem(.bot(text: "antes", isStreaming: false))], messages: [ChatMessage(role: .assistant, content: "antes")])
        let (model, _, b, _) = setUp(Gates(), lunaChat: said)
        let luna = model.session(b)
        let reading = try #require(luna.beginLoading())
        #expect(luna.isLoading && model.isLoadingConversation(b))

        model.editConversation(b) { $0.items.append(TranscriptItem(.notice("já"))) } // reads now, on the main thread
        #expect(!luna.isLoading)
        await reading.value // the older read arrives and is not installed over the newer change
        #expect(luna.conversation?.items.count == 2)
        #expect(!luna.isLoading && luna.loadTask == nil)
    }

    @Test @MainActor func aDeletedOrbsSessionGoesWithItsPendingWork() async {
        let model = AppModel(store: Store(directory: root.appending(path: "apagar")), runsBackgroundWork: false)
        let luna = model.createBot(name: "Luna", role: "", orb: OrbConfig(), model: "", mode: .ask, interview: false,
                                   folder: .existing(root)).id
        weak var session: BotSession?
        session = model.session(luna)
        model.apply(.text("começo de uma resposta"), to: luna) // a flush and a speaking watch are now pending
        #expect(session?.pendingText != nil)

        model.deleteBot(luna)
        #expect(model.sessions[luna] == nil)
        // Nothing holds it (but the greeting's cancelled save timer, until it ends): the pending flush cannot write a conversation for the deleted Orb
        #expect(await waitUntil("the session to be released") { session == nil })
        #expect(model.conversations[luna] == nil)
    }

    // MARK: Observation stays per Orb

    @Test @MainActor func aViewOfOneSessionIsNotNotifiedByAnotherOrbsEvents() {
        let model = AppModel(store: Store(directory: root.appending(path: "observar")), runsBackgroundWork: false)
        let a = model.bots[0].id
        let b = model.createBot(name: "Luna", role: "", orb: OrbConfig(), model: "", mode: .ask, interview: false,
                                folder: .existing(root)).id
        let mine = model.session(a)
        let flag = RaisedFlag()
        withObservationTracking {
            _ = (mine.conversation, mine.parkedChat, mine.isLoading, mine.routineID, mine.usage, mine.requestUsage,
                 mine.lastCompaction)
            _ = model.isLoadingConversation(a)
            _ = model.isRoutineRunning(UUID())
        } onChange: { flag.raise() }

        model.apply(.message(.user("para Luna")), to: b)
        model.apply(.usage(TokenUsage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0)), to: b)
        model.apply(.requestUsage(TokenUsage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0)), to: b)
        model.apply(.notice("de Luna"), to: b)
        #expect(!flag.isRaised)

        model.apply(.usage(TokenUsage(input: 2, output: 1, cacheRead: 0, cacheWrite: 0)), to: a)
        #expect(flag.isRaised)
    }
}
