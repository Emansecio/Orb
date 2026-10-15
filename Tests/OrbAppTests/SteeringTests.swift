import Foundation
import Testing
@testable import Orb

// Talking to an Orb while it works: the queue, the engine handing queued messages to the model between steps, and
// the app model showing them as queued, delivered, sent after the turn or given back.

private actor Seen {
    private(set) var calls: [[ChatMessage]] = []
    func record(_ messages: [ChatMessage]) { calls.append(messages) }
    var count: Int { calls.count }
}

/// Answers "resposta N" to every call, holding the first call until `gate` opens, and remembers what it was sent.
private struct HeldModel: LLMClient {
    var seen = Seen()
    var gate: TestGate?
    var failsFirst = false
    /// The first answer calls this tool (so the turn has a step boundary); later ones are text.
    var toolOnFirst = false

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await seen.record(messages)
                let number = await seen.count
                if number == 1 { await gate?.wait() }
                if number == 1, failsFirst {
                    continuation.finish(throwing: LLMError.notConfigured)
                    return
                }
                if number == 1, toolOnFirst {
                    continuation.yield(.toolCalls([ToolCallRequest(id: "c1", name: "look", arguments: "{}")]))
                    continuation.yield(.finished(.toolUse, nil))
                } else {
                    continuation.yield(.text("resposta \(number)"))
                    continuation.yield(.finished(.done, nil))
                }
                continuation.finish()
            }
        }
    }
}

private struct LookTool: AgentTool {
    var spec: ToolSpec { ToolSpec(name: "look", description: "Looks", parameters: .schema([:])) }
    var kind: ToolCall.Kind { .file }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Olhando", "") }
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String { "viu" }
}

private func steered(_ text: String) -> SteeredMessage { SteeredMessage(text: text, prompt: text) }

struct SteeringQueueTests {
    @Test func drainsInTheOrderOfSendingAndEmpties() {
        let queue = SteeringQueue()
        queue.push(steered("a"))
        queue.push(steered("b"))
        #expect(!queue.isEmpty)
        #expect(queue.drain().map(\.text) == ["a", "b"])
        #expect(queue.isEmpty && queue.drain().isEmpty)
    }

    @Test func aMessageTakenBackIsNotDelivered() throws {
        let queue = SteeringQueue()
        let first = steered("a"), second = steered("b")
        queue.push(first)
        queue.push(second)
        #expect(queue.remove(first.id)?.text == "a")
        #expect(queue.remove(first.id) == nil) // already gone
        #expect(queue.drain().map(\.text) == ["b"])
        #expect(queue.remove(second.id) == nil) // delivered: too late to change its mind
    }

    @Test func severalQueuedMessagesBecomeOne() throws {
        let file = URL(fileURLWithPath: "/tmp/a.txt")
        let merged = try #require(SteeredMessage.merged([
            SteeredMessage(text: "um", files: [file], prompt: "um+a"),
            SteeredMessage(text: "dois", files: [file, URL(fileURLWithPath: "/tmp/b.txt")], prompt: "dois+ab")]))
        #expect(merged.text == "um\n\ndois")
        #expect(merged.files.map(\.lastPathComponent) == ["a.txt", "b.txt"])
        #expect(SteeredMessage.merged([]) == nil)
        let single = steered("só")
        #expect(SteeredMessage.merged([single]) == single)
    }
}

struct SteeringEngineTests {
    private func request(_ client: HeldModel, steering: SteeringQueue?, tools: [any AgentTool] = [LookTool()]) -> TurnRequest {
        let bot = Bot(name: "Teste", role: "", orb: OrbConfig(), permissionMode: .auto)
        return TurnRequest(bot: bot, model: "fake", system: "sys", history: [], prompt: "oi", client: client, tools: tools,
                           context: ToolContext(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory())), steering: steering)
    }

    private func run(_ request: TurnRequest) async -> [TurnEvent] {
        var events: [TurnEvent] = []
        for await event in AgentEngine().run(request) { events.append(event) }
        return events
    }

    @Test func aMessageQueuedBeforeTheNextStepReachesTheModelAfterTheToolResults() async throws {
        let queue = SteeringQueue()
        let client = HeldModel(toolOnFirst: true)
        queue.push(steered("use a pasta X"))
        // Delivered at the first boundary it meets: before the very first call here (it was queued during setup).
        let events = await run(request(client, steering: queue))
        let calls = await client.seen.calls
        #expect(calls.count == 2)
        #expect(calls[0].last?.content == AgentEngine.steeringFrame + "\n\nuse a pasta X")
        #expect(events.contains { if case .steered = $0 { true } else { false } })
        #expect(queue.isEmpty)
    }

    @Test func aMessageQueuedDuringAStepGoesInBetweenSteps() async throws {
        let queue = SteeringQueue()
        let gate = TestGate()
        let client = HeldModel(gate: gate, toolOnFirst: true)
        let turn = Task { await run(request(client, steering: queue)) }
        await waitUntil("the first model call") { await client.seen.count >= 1 }
        queue.push(steered("não, use a pasta X")) // the model is mid-step
        await gate.open()
        let events = await turn.value

        let calls = await client.seen.calls
        #expect(calls.count == 2)
        // Second call: system, prompt, assistant's tool call, its result, then the steering message.
        #expect(calls[1].map(\.role) == [.system, .user, .assistant, .tool, .user])
        #expect(calls[1].last?.content == AgentEngine.steeringFrame + "\n\nnão, use a pasta X")
        let ids = events.compactMap { event -> UUID? in if case .steered(let id) = event { id } else { nil } }
        #expect(ids.count == 1)
    }

    @Test func aMessageQueuedWhileTheFinalAnswerIsWrittenKeepsTheTurnGoing() async throws {
        let queue = SteeringQueue()
        let gate = TestGate()
        let client = HeldModel(gate: gate) // answers in text at once: no tool step in this turn
        let turn = Task { await run(request(client, steering: queue)) }
        await waitUntil("the first model call") { await client.seen.count >= 1 }
        queue.push(steered("e depois?"))
        await gate.open()
        let events = await turn.value

        let calls = await client.seen.calls
        #expect(calls.count == 2) // not a new turn: one more call in this one
        #expect(calls[1].map(\.role) == [.system, .user, .assistant, .user])
        let said = events.compactMap { event -> String? in if case .message(let m) = event, m.role == .assistant { m.content } else { nil } }
        #expect(said == ["resposta 1", "resposta 2"])
    }

    @Test func withoutAQueueTheTurnEndsWithTheAnswer() async {
        let client = HeldModel()
        let events = await run(request(client, steering: nil))
        #expect(await client.seen.count == 1)
        #expect(!events.contains { if case .steered = $0 { true } else { false } })
    }
}

@Suite final class SteeringModelTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbSteering-\(UUID().uuidString)")

    init() { QuietNotifications.hold() }
    deinit {
        QuietNotifications.release()
        removeTestFolder(root)
    }

    @MainActor private func setUp(_ client: HeldModel) -> (AppModel, Bot) {
        var state = AppState.initial
        let own = root.appending(path: "pasta")
        try? FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        state.bots[0].workingDirectory = own.path
        let store = Store(directory: root)
        store.save(state)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = { client }
        return (model, model.bots[0])
    }

    @MainActor private func userTexts(_ model: AppModel, _ id: UUID) -> [String] {
        model.transcript(id).compactMap { if case .user(let text, _) = $0.kind { text } else { nil } }
    }

    @Test @MainActor func aMessageSentDuringATurnIsQueuedAndShownAsWaiting() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        #expect(model.submit("primeiro", to: bot.id))
        #expect(model.canSteer(bot.id))
        await waitUntil("the model call") { await client.seen.count >= 1 }

        model.setDraft("corrija isso", for: bot.id)
        #expect(model.submit("corrija isso", to: bot.id))
        let lane = model.composerLane(bot.id)
        #expect(lane.queued.map(\.text) == ["corrija isso"])
        #expect(model.drafts[bot.id] == "") // the composer is free for the next thought
        #expect(userTexts(model, bot.id) == ["primeiro"]) // not in the transcript yet
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func theQueuedMessageJoinsTheTranscriptWhenTheModelGetsIt() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.submit("segundo", to: bot.id)
        await gate.open()
        await waitUntilIdle(model, bot.id)

        #expect(userTexts(model, bot.id) == ["primeiro", "segundo"])
        #expect(model.composerLane(bot.id).queued.isEmpty)
        #expect(await client.seen.count == 2) // one turn, two model calls
        // The model saw it in the same conversation, after its own first answer.
        let second = await client.seen.calls[1]
        #expect(second.last?.content == AgentEngine.steeringFrame + "\n\nsegundo")
    }

    @Test @MainActor func lettingTheCommandGoSendsWhatWasQueuedForAfterTheTaskIntoIt() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        #expect(model.submit("depois", to: bot.id, delivery: .afterTask))

        model.sendCommandToBackground(of: bot.id)
        // Whoever lets the command go wants to talk now: the message goes into the task, not after it.
        #expect(model.composerLane(bot.id).queued.map(\.delivery) == [.steer])
        await gate.open()
        await waitUntilIdle(model, bot.id)
        #expect(userTexts(model, bot.id) == ["primeiro", "depois"])
        #expect(await client.seen.count == 2) // delivered inside the same turn
    }

    @Test @MainActor func aFileAloneIsSentAsAMessageWithTheDefaultRequest() async throws {
        let client = HeldModel()
        let (model, bot) = setUp(client)
        let file = root.appending(path: "relatorio.pdf")
        try Data("pdf".utf8).write(to: file)
        #expect(model.send("", attachments: [file], to: bot.id, fromUser: true))
        await waitUntilIdle(model, bot.id)
        let seen = try #require(await client.seen.calls.first?.last)
        #expect(seen.content.contains(AppModel.attachmentsOnlyPrompt))
        #expect(seen.content.contains("Attached files") && seen.content.contains(file.path))
        let attached = model.transcript(bot.id).compactMap { item -> [String]? in
            if case .user(_, let attachments) = item.kind { attachments } else { nil }
        }
        #expect(attached == [[file.path]])
    }

    @Test @MainActor func theTextOfAnAttachedFileGoesWithTheMessage() async throws {
        let client = HeldModel()
        let (model, bot) = setUp(client)
        let table = root.appending(path: "matriculas.csv")
        try Data("nome;matricula\nAna;1128938200\n- não é um arquivo\n".utf8).write(to: table)
        let archive = root.appending(path: "fotos.zip")
        try Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0xFF, 0x00]).write(to: archive)
        model.attach([table, archive], to: bot.id) // read in the background as they are attached
        #expect(model.send("confira", attachments: [table, archive], to: bot.id, fromUser: true))
        await waitUntilIdle(model, bot.id)
        let seen = try #require(await client.seen.calls.first?.last)
        #expect(seen.content.contains("Ana;1128938200"))
        #expect(seen.content.contains("<attached_file path=\"\(archive.path)\">\n(not read here: read it with your tools)"))
        // What the summaries take as the user's words: the request and the two names, not the lines of the table.
        #expect(TurnPreface.userWords(seen.content).hasPrefix("confira"))
        #expect(!TurnPreface.userWords(seen.content).contains("não é um arquivo"))
        #expect(TurnPreface.requestWords(seen.content) == "confira")
    }

    @Test @MainActor func aFileAloneIsQueuedWhileTheOrbWorks() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        let file = root.appending(path: "dados.csv")
        try Data("a,b".utf8).write(to: file)
        let lane = model.composerLane(bot.id)
        lane.files = [AttachedFile(url: file)]
        #expect(model.submit("", to: bot.id))
        #expect(lane.queued.count == 1 && lane.queued[0].files == [file])
        #expect(lane.files.isEmpty)
        await gate.open()
        await waitUntilIdle(model, bot.id)
        #expect(await client.seen.count == 2)
        #expect(await client.seen.calls[1].last?.content.contains(file.path) == true)
    }

    @Test @MainActor func quittingKeepsTheQueueTheDraftAndTheirFilesForTheNextLaunch() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        let file = root.appending(path: "nota.txt")
        try Data("nota".utf8).write(to: file)
        let gone = root.appending(path: "some.txt")
        try Data("x".utf8).write(to: gone)
        model.composerLane(bot.id).files = [AttachedFile(url: file)]
        #expect(model.submit("depois disso, gere o PDF", to: bot.id)) // queued, with the file
        model.setDraft("ainda escrevendo", for: bot.id)
        model.composerLane(bot.id).files = [AttachedFile(url: gone)] // attached to the draft, deleted before the next launch

        model.stopTurnsForQuit() // gives the queue back to the composer
        model.saveNow()
        try FileManager.default.removeItem(at: gone)
        await gate.open()

        let next = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        #expect(next.drafts[bot.id] == "depois disso, gere o PDF\n\nainda escrevendo")
        #expect(next.composerLane(bot.id).files.map(\.url) == [file], "the queued message's file comes back, the deleted one does not")
        // Sent or cleared, the next save leaves nothing behind.
        next.setDraft("", for: bot.id)
        next.composerLane(bot.id).files = []
        next.saveNow()
        let again = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        #expect(again.drafts[bot.id] == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: Store.draftsFileName).path))
    }

    @Test @MainActor func takingAMessageBackReturnsItToTheDraft() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.submit("esqueça", to: bot.id)
        let id = try #require(model.composerLane(bot.id).queued.first?.id)

        model.unqueue(id, botID: bot.id)
        #expect(model.composerLane(bot.id).queued.isEmpty)
        #expect(model.drafts[bot.id] == "esqueça")
        await gate.open()
        await waitUntilIdle(model, bot.id)
        #expect(userTexts(model, bot.id) == ["primeiro"]) // it never reached the model
        #expect(await client.seen.count == 1)
    }

    @Test @MainActor func stoppingGivesWhatWasQueuedBackToTheDraft() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.submit("fica na fila", to: bot.id)
        model.setDraft("rascunho", for: bot.id)

        model.stop(bot.id)
        #expect(!model.isWorking(bot.id))
        #expect(model.composerLane(bot.id).queued.isEmpty)
        #expect(model.drafts[bot.id] == "fica na fila\n\nrascunho")
        await gate.open()
    }

    @Test @MainActor func stoppingKeepsWhatWasQueuedAndItsAttachmentsInTheComposer() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        let file = root.appending(path: "nota.txt")
        try "oi".write(to: file, atomically: true, encoding: .utf8)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        let lane = model.composerLane(bot.id)
        lane.files = [AttachedFile(url: file)]
        model.submit("analise isso também", to: bot.id)
        #expect(lane.queued.count == 1 && lane.files.isEmpty)

        model.stop(bot.id) // the queued message goes back to the composer
        #expect(!model.isWorking(bot.id))
        #expect(model.drafts[bot.id] == "analise isso também") // the text is not lost with its attachment
        #expect(lane.files.map(\.url) == [file])
        #expect(lane.queued.isEmpty)
        await gate.open()
    }

    @Test @MainActor func theCompactCommandTypedDuringATurnIsNotQueuedForTheModel() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.setDraft("/compactar foco X", for: bot.id)

        #expect(!model.submit("/compactar foco X", to: bot.id))
        #expect(model.composerLane(bot.id).queued.isEmpty)
        #expect(model.drafts[bot.id] == "/compactar foco X") // kept in the composer for when the turn ends
        let notices = model.transcript(bot.id).compactMap { item -> String? in if case .notice(let text) = item.kind { text } else { nil } }
        #expect(notices == [AppModel.compactionBusyMessage])

        // "Parar e enviar" with it typed only stops: the command is not sent to the model as a message.
        model.stopAndSend(bot.id, draft: "/compactar")
        #expect(!model.isWorking(bot.id))
        #expect(userTexts(model, bot.id) == ["primeiro"])
        await gate.open()
        #expect(await client.seen.count == 1)
    }

    @Test @MainActor func stopAndSendEndsTheTurnAndSendsTheQueuedMessageNow() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.submit("mude de rumo", to: bot.id)

        model.stopAndSend(bot.id)
        #expect(model.composerLane(bot.id).queued.isEmpty)
        #expect(userTexts(model, bot.id) == ["primeiro", "mude de rumo"])
        await gate.open()
        await waitUntilIdle(model, bot.id)
        #expect(await client.seen.count == 2)
        #expect(model.drafts[bot.id, default: ""] == "")
    }

    @Test @MainActor func quittingMidTaskSaysTheAppClosedAndOffersToContinue() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.stopTurnsForQuit()
        let notices = model.transcript(bot.id).compactMap { if case .notice(let text) = $0.kind { text } else { nil } }
        #expect(notices.last == BotSession.quitNotice) // not "Você interrompeu": you did not
        #expect(NoticeAction.actions(for: BotSession.quitNotice) == [.continueTurn])
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func quittingMidRoutineRunAsksToCheckBeforeRepeatingAndOffersNoContinue() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        let routine = Routine(name: "R", botID: bot.id, prompt: "faça", schedule: .everyHours(1))
        model.routines = [routine]
        model.runRoutine(routine.id)
        await model.routineStarted()
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.stopTurnsForQuit()
        await waitUntil("the run to be recorded") { model.routines.first?.runs.count == 1 }
        let run = try #require(model.routines.first?.runs.first)
        #expect(!run.succeeded && run.summary == BotSession.quitSideNotice)
        #expect(NoticeAction.actions(for: BotSession.quitSideNotice).isEmpty)
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func stopAndSendGoesBeforeARoutineWaitingForTheOrb() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        let routine = Routine(name: "R", botID: bot.id, prompt: "faça", schedule: .everyHours(1))
        model.routines = [routine]
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.runRoutine(routine.id)
        await model.routineStarted()
        #expect(model.isRoutineQueued(routine.id)) // the Orb is busy with your chat
        model.submit("corrija", to: bot.id)

        model.stopAndSend(bot.id)
        // The correction took the Orb, not the routine that was next in line.
        #expect(model.session(bot.id).routineID == nil)
        #expect(userTexts(model, bot.id) == ["primeiro", "corrija"])
        #expect(model.isRoutineQueued(routine.id) && model.composerLane(bot.id).queued.isEmpty)
        #expect(model.drafts[bot.id, default: ""] == "")
        await gate.open()
        // It runs once that turn is over, as it always did.
        await waitUntil("the routine to run after the correction") { model.routines.first?.runs.count == 1 }
        await waitUntilIdle(model, bot.id)
        #expect(!model.isRoutineQueued(routine.id))
    }

    @Test @MainActor func stopAndSendWithNothingToSendLetsTheQueuedRoutineStart() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        let routine = Routine(name: "R", botID: bot.id, prompt: "faça", schedule: .everyHours(1))
        model.routines = [routine]
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.runRoutine(routine.id)
        await model.routineStarted()

        model.stopAndSend(bot.id) // nothing queued, nothing typed: it is just a stop
        await model.routineStarted()
        #expect(model.session(bot.id).routineID == routine.id)
        await gate.open()
        await waitUntil("the routine to run") { model.routines.first?.runs.count == 1 }
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func stopAndSendRightAfterTheMessageEnteredTheTaskSendsItAsTheNewRequest() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.submit("roda novamente", to: bot.id)
        // The engine hands it to the model at the next step, a moment before the click.
        let queued = try #require(model.composerLane(bot.id).queued.first)
        var copy = ChatMessage.user(queued.prompt)
        copy.itemID = queued.id
        model.apply(.message(copy), to: bot.id)
        model.apply(.steered(queued.id), to: bot.id)
        #expect(model.composerLane(bot.id).queued.isEmpty)

        model.stopAndSend(bot.id)
        // It left the stopped task and went as the request that follows, once, not as a message during the task.
        #expect(userTexts(model, bot.id) == ["primeiro", "roda novamente"])
        let last = try #require(model.transcript(bot.id).last { if case .user = $0.kind { true } else { false } })
        #expect(last.duringTask != true)
        #expect(model.isWorking(bot.id))
        await gate.open()
        await waitUntilIdle(model, bot.id)
        // The model has it once too: the copy delivered into the stopped task left with its bubble.
        let conversation = try #require(model.conversations[bot.id])
        #expect(conversation.messages.filter { $0.role == .user && $0.content.contains("roda novamente") }.count == 1)
    }

    @Test @MainActor func aMessageTheOrbAlreadyActedOnIsNotSentAgain() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.submit("olha também o README", to: bot.id)
        let queued = try #require(model.composerLane(bot.id).queued.first)
        model.apply(.steered(queued.id), to: bot.id)
        model.append(.tool(ToolCall(kind: .file, title: "Lendo arquivo", detail: "README.md", state: .done)), to: bot.id)

        model.stopAndSend(bot.id) // nothing waits, and what was delivered was read: just a stop
        #expect(!model.isWorking(bot.id))
        #expect(userTexts(model, bot.id) == ["primeiro", "olha também o README"])
        await gate.open()
    }

    @Test @MainActor func stopAndSendTakesWhatIsTypedToo() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.stopAndSend(bot.id, draft: "agora, outra coisa")
        #expect(userTexts(model, bot.id) == ["primeiro", "agora, outra coisa"])
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func theQueueBubblesStopAndSendLeavesTheComposerAlone() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.submit("mude de rumo", to: bot.id) // queued
        model.setDraft("olha esta foto", for: bot.id)
        let picture = ImageAttachment(path: "/tmp/orb-test-foto.png", mediaType: "image/png", width: 1, height: 1)
        model.composerLane(bot.id).pictures = [picture]

        model.stopAndSend(bot.id) // as the bubble calls it: no draft

        #expect(model.drafts[bot.id] == "olha esta foto")
        #expect(model.composerLane(bot.id).pictures == [picture])
        #expect(userTexts(model, bot.id) == ["primeiro", "mude de rumo"])
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }

    @Test func theQueueBubbleCannotInterruptWhileAPictureIsStillOnItsWay() {
        #expect(QueuedMessages.canInterrupt(canSteer: true, pendingPictures: 0))
        #expect(!QueuedMessages.canInterrupt(canSteer: true, pendingPictures: 1))
        #expect(!QueuedMessages.canInterrupt(canSteer: false, pendingPictures: 0))
    }

    @Test @MainActor func aFailedTurnDoesNotSendWhatWasQueuedByItself() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate, failsFirst: true)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.submit("depois", to: bot.id)
        await gate.open()
        await waitUntilIdle(model, bot.id)

        #expect(model.drafts[bot.id] == "depois")
        #expect(await client.seen.count == 1) // no second turn started on its own
    }

    @Test @MainActor func anIdleOrbSendsInsteadOfQueuing() async throws {
        let client = HeldModel()
        let (model, bot) = setUp(client)
        #expect(!model.canSteer(bot.id))
        #expect(model.submit("oi", to: bot.id))
        #expect(model.composerLane(bot.id).queued.isEmpty)
        #expect(model.isWorking(bot.id))
        await waitUntilIdle(model, bot.id)
        #expect(userTexts(model, bot.id) == ["oi"])
    }

    @Test @MainActor func attachmentsStayWithTheOrbAndGoWithTheMessage() async throws {
        let client = HeldModel()
        let (model, bot) = setUp(client)
        let file = root.appending(path: "nota.txt")
        try "oi".write(to: file, atomically: true, encoding: .utf8)
        let lane = model.composerLane(bot.id)
        lane.files = [AttachedFile(url: file)]
        #expect(lane.files[0].size == 2 && lane.files[0].symbol == "doc.text")
        #expect(model.composerLane(bot.id) === lane) // the same object when the composer is rebuilt

        #expect(model.submit("veja", to: bot.id))
        #expect(lane.files.isEmpty)
        await waitUntilIdle(model, bot.id)
        let calls = await client.seen.calls
        let sent = try #require(calls.first).last?.content ?? "" // a timed-out wait must fail here, not crash the run
        #expect(sent.contains(file.path))
    }

    @Test @MainActor func queuingScrollsTheChatToTheWaitingBubble() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        let before = model.live(bot.id).scrollNudge, jumps = model.live(bot.id).poke
        model.submit("segundo", to: bot.id)
        #expect(model.live(bot.id).scrollNudge > before) // the queued bubble changes no transcript revision; the nudge follows it
        #expect(model.live(bot.id).poke == jumps) // ...and the Orb does not jump for it
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func deliveringAQueuedMessageDoesNotPullTheChatToTheEnd() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.submit("segundo", to: bot.id)
        let queued = try #require(model.composerLane(bot.id).queued.first)
        let nudges = model.live(bot.id).scrollNudge
        model.deliverSteered(queued.id, to: bot.id) // minutes later, maybe, with you reading further up
        #expect(model.live(bot.id).scrollNudge == nudges)
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func aSkillInAQueuedMessageCountsOnceWhicheverWayItIsDelivered() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.skills = [Skill(slug: "resumir", name: "Resumir", summary: "", instructions: "resuma")]
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.submit("/resumir isto", to: bot.id)
        #expect(model.skills[0].uses == 0) // queued is not used yet
        model.stopAndSend(bot.id) // delivered by sending it as the next message
        #expect(model.skills[0].uses == 1)
        await gate.open()
        await waitUntilIdle(model, bot.id)

        // Delivered between steps instead.
        let gate2 = TestGate()
        let (model2, bot2) = setUp(HeldModel(gate: gate2))
        model2.skills = [Skill(slug: "resumir", name: "Resumir", summary: "", instructions: "resuma")]
        model2.submit("primeiro", to: bot2.id)
        await waitUntil("the turn to start") { model2.turns[bot2.id] != nil }
        model2.submit("/resumir isto", to: bot2.id)
        await gate2.open()
        await waitUntilIdle(model2, bot2.id)
        #expect(model2.skills[0].uses == 1)
    }

    @Test @MainActor func askingToRememberMidTurnTellsTheModelToSave() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.submit("lembre que prefiro pt-BR", to: bot.id)
        model.submit("só um comentário", to: bot.id)
        let prompts = model.composerLane(bot.id).queued.map(\.prompt)
        #expect(prompts[0].contains("remember tool"))
        #expect(!prompts[1].contains("remember tool"))
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func whatWasQueuedIsSentAfterAGoodEndingAndGivenBackAfterABadOne() async throws {
        let client = HeldModel()
        let (model, bot) = setUp(client)
        let lane = model.composerLane(bot.id)
        lane.enqueue(steered("depois"))
        model.settleSteering(bot.id, succeeded: false)
        #expect(model.drafts[bot.id] == "depois" && lane.queued.isEmpty && !model.isWorking(bot.id))

        lane.enqueue(steered("um"))
        lane.enqueue(steered("dois"))
        model.settleSteering(bot.id, succeeded: true) // Claude Code's way: the next message, right after the turn
        #expect(lane.queued.isEmpty)
        #expect(userTexts(model, bot.id) == ["um\n\ndois"])
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func nothingIsSentWhileAPictureIsStillBeingPrepared() async throws {
        let client = HeldModel()
        let (model, bot) = setUp(client)
        let lane = model.composerLane(bot.id)
        lane.pendingPictures = 1
        #expect(!model.submit("o que tem nesta tela?", to: bot.id))
        #expect(!model.isWorking(bot.id) && userTexts(model, bot.id).isEmpty)
        lane.pendingPictures = 0 // the picture arrived
        #expect(model.submit("o que tem nesta tela?", to: bot.id))
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func aMessageIsNotQueuedWhileAPictureIsStillBeingPrepared() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        let lane = model.composerLane(bot.id)
        lane.pendingPictures = 1
        #expect(!model.submit("e isto", to: bot.id) && lane.queued.isEmpty)
        lane.pendingPictures = 0
        #expect(model.submit("e isto", to: bot.id) && lane.queued.count == 1)
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func aMessageFromThePanelIsQueuedWithoutTouchingTheComposer() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        #expect(!model.queueOutsideComposer("cedo demais", to: bot.id)) // the Orb is free: nothing to queue behind
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        let lane = model.composerLane(bot.id)
        let file = root.appending(path: "nota.txt")
        lane.files = [AttachedFile(url: file)]
        model.setDraft("rascunho no app", for: bot.id)
        #expect(model.queueOutsideComposer("  me lembra de ligar pro João  ", to: bot.id))
        #expect(!model.queueOutsideComposer("   ", to: bot.id))
        #expect(lane.queued.map(\.text) == ["me lembra de ligar pro João"])
        #expect(lane.queued[0].files.isEmpty) // the composer's attachment is not the panel's
        #expect(model.drafts[bot.id] == "rascunho no app" && lane.files.map(\.url) == [file])
        await gate.open()
        await waitUntilIdle(model, bot.id)
        #expect(userTexts(model, bot.id).contains("me lembra de ligar pro João"))
    }

    @Test @MainActor func theRunningRoutineIsNamedForTheComposer() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        #expect(model.runningRoutineName(bot.id) == nil)
        let routine = Routine(name: "Resumo diário", botID: bot.id, prompt: "faça", schedule: .everyHours(1))
        model.routines = [routine]
        model.runRoutine(routine.id)
        // The routine's conversation is read off the main thread before it starts.
        await waitUntil("the routine starts") { model.runningRoutineName(bot.id) == "Resumo diário" }
        await gate.open()
        await waitUntilIdle(model, bot.id)
        #expect(model.runningRoutineName(bot.id) == nil)
    }

    @Test @MainActor func aRoutineRunCannotTakeYourMessages() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        let routine = Routine(name: "R", botID: bot.id, prompt: "faça", schedule: .everyHours(1))
        model.routines = [routine]
        model.runRoutine(routine.id)
        await model.routineStarted()
        #expect(model.isWorking(bot.id))
        #expect(!model.canSteer(bot.id))
        model.setDraft("oi", for: bot.id)
        #expect(!model.queueMessage("oi", to: bot.id))
        #expect(model.composerLane(bot.id).queued.isEmpty)
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }
}

// MARK: - Two modes: steer the task, or wait for its end

private func afterTask(_ text: String) -> SteeredMessage { SteeredMessage(text: text, prompt: text, delivery: .afterTask) }

struct SteeringModesTests {
    @Test func theQueueHandsOverOnlyWhatIsMeantForTheTask() {
        let queue = SteeringQueue()
        queue.push(steered("a"))
        queue.push(afterTask("b"))
        queue.push(steered("c"))
        queue.push(afterTask("d"))
        #expect(queue.hasSteering)
        #expect(queue.drainSteering().map(\.text) == ["a", "c"])
        #expect(!queue.hasSteering && !queue.isEmpty)
        #expect(queue.drainSteering().isEmpty)
        #expect(queue.messages.map(\.text) == ["b", "d"]) // still waiting, in the order of sending
        #expect(queue.drain().map(\.text) == ["b", "d"])
    }

    @Test func aMessageChangesModeOnlyWhileItWaits() {
        let queue = SteeringQueue()
        let first = steered("a"), second = afterTask("b")
        queue.push(first)
        queue.push(second)
        #expect(queue.setDelivery(first.id, to: .afterTask) && !queue.hasSteering)
        #expect(queue.setDelivery(second.id, to: .steer) && queue.hasSteering)
        #expect(queue.messages.map(\.text) == ["a", "b"]) // its place in the order does not change
        #expect(queue.drainSteering().map(\.text) == ["b"])
        #expect(!queue.setDelivery(second.id, to: .afterTask)) // delivered: too late
        #expect(!queue.setDelivery(UUID(), to: .steer))
    }

    @Test func aMessageSavedWithoutAModeOpensAsSteering() throws {
        let old = #"{"id":"6F4A8F0E-2D1B-4C53-9E8A-0B7D3F2A1C11","text":"oi","files":[],"pictures":[],"prompt":"oi"}"#
        let message = try JSONDecoder().decode(SteeredMessage.self, from: Data(old.utf8))
        #expect(message.delivery == .steer && message.text == "oi")
        let unknown = old.replacingOccurrences(of: #""prompt":"oi""#, with: #""prompt":"oi","delivery":"daqui-a-pouco""#)
        #expect(try JSONDecoder().decode(SteeredMessage.self, from: Data(unknown.utf8)).delivery == .steer)
        let back = try JSONDecoder().decode(SteeredMessage.self, from: JSONEncoder().encode(afterTask("depois")))
        #expect(back.delivery == .afterTask && back.text == "depois")
    }

    @Test func aDraftsFileFromBeforeTheModesStillOpens() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbDrafts-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let old = #"{"\#(id.uuidString)":{"text":"rascunho","files":["/tmp/a.txt"],"pictures":[]}}"#
        try Data(old.utf8).write(to: root.appending(path: Store.draftsFileName))
        let drafts = Store(directory: root).readDrafts()
        #expect(drafts[id]?.text == "rascunho" && drafts[id]?.files == ["/tmp/a.txt"])
    }

    @Test func theDuringTaskMarkIsSavedAndReadAndOldConversationsStillOpen() throws {
        let marked = TranscriptItem(.user(text: "só o Engine", attachments: []), duringTask: true)
        let plain = TranscriptItem(.user(text: "oi", attachments: []))
        #expect(marked.duringTask == true && plain.duringTask == nil)
        let conversation = Conversation(items: [plain, marked], messages: [.user("oi")])
        let back = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        #expect(back.items.map(\.duringTask) == [nil, true])
        // Nothing is written for an item without the mark: the file is the one older versions read.
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("duringTask"))
        // An item written before the mark existed.
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(marked)) as? [String: Any])
        json.removeValue(forKey: "duringTask")
        let old = try JSONDecoder().decode(TranscriptItem.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.duringTask == nil && old.kind == marked.kind)
        // A mark that cannot be read does not lose the message.
        json["duringTask"] = "sim"
        let odd = try JSONDecoder().decode(TranscriptItem.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(odd.duringTask == nil && odd.kind == marked.kind)
    }
}

struct SteeringModesEngineTests {
    private func request(_ client: HeldModel, steering: SteeringQueue?) -> TurnRequest {
        let bot = Bot(name: "Teste", role: "", orb: OrbConfig(), permissionMode: .auto)
        return TurnRequest(bot: bot, model: "fake", system: "sys", history: [], prompt: "oi", client: client, tools: [LookTool()],
                           context: ToolContext(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory())), steering: steering)
    }

    private func run(_ request: TurnRequest) async -> [TurnEvent] {
        var events: [TurnEvent] = []
        for await event in AgentEngine().run(request) { events.append(event) }
        return events
    }

    @Test func theEngineDeliversTheSteeredOnesInTheMiddleAndLeavesTheOthers() async throws {
        let queue = SteeringQueue()
        let gate = TestGate()
        let client = HeldModel(gate: gate, toolOnFirst: true)
        let turn = Task { await run(request(client, steering: queue)) }
        await waitUntil("the first model call") { await client.seen.count >= 1 }
        queue.push(afterTask("depois de tudo"))
        let steer = steered("use a pasta X")
        queue.push(steer)
        await gate.open()
        let events = await turn.value

        let calls = await client.seen.calls
        #expect(calls.count == 2)
        #expect(calls[1].last?.content == AgentEngine.steeringFrame + "\n\nuse a pasta X") // the other one is nowhere in what the model saw
        #expect(!calls[1].contains { $0.content == "depois de tudo" })
        let ids = events.compactMap { event -> UUID? in if case .steered(let id) = event { id } else { nil } }
        #expect(ids == [steer.id])
        #expect(queue.messages.map(\.text) == ["depois de tudo"]) // waits for the end of the task
    }

    @Test func aMessageForAfterTheTaskDoesNotKeepTheTurnGoing() async throws {
        let queue = SteeringQueue()
        let gate = TestGate()
        let client = HeldModel(gate: gate) // answers in text at once
        let turn = Task { await run(request(client, steering: queue)) }
        await waitUntil("the first model call") { await client.seen.count >= 1 }
        queue.push(afterTask("e depois?"))
        await gate.open()
        let events = await turn.value

        #expect(await client.seen.count == 1) // the answer ended the turn: no empty extra step for a message that waits
        #expect(!events.contains { if case .steered = $0 { true } else { false } })
        #expect(queue.messages.map(\.text) == ["e depois?"])
    }
}

extension SteeringModelTests {
    @MainActor private func items(_ model: AppModel, _ id: UUID) -> [(text: String, duringTask: Bool)] {
        model.transcript(id).compactMap { item in
            if case .user(let text, _) = item.kind { (text, item.duringTask == true) } else { nil }
        }
    }

    @Test @MainActor func theWaitingOnesBecomeTheNextRequestWhenTheTaskEndsInTheOrderOfSending() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        #expect(model.submit("segundo", to: bot.id, delivery: .afterTask))
        #expect(model.submit("terceiro", to: bot.id, delivery: .afterTask))
        let lane = model.composerLane(bot.id)
        #expect(lane.queued.map(\.delivery) == [.afterTask, .afterTask] && lane.queued.map(\.text) == ["segundo", "terceiro"])
        await gate.open()
        await waitUntilIdle(model, bot.id)

        // Not delivered in the middle (the first call's answer ended the task), sent together as the next request.
        #expect(items(model, bot.id).map(\.text) == ["primeiro", "segundo\n\nterceiro"])
        #expect(items(model, bot.id).allSatisfy { !$0.duringTask }) // it is a request of its own, not a mid-task one
        #expect(await client.seen.count == 2)
        #expect(await client.seen.calls[1].last?.content.contains("segundo\n\nterceiro") == true)
        #expect(lane.queued.isEmpty)
    }

    @Test @MainActor func theSteeredOneEntersTheTaskMarkedAndTheOtherFollowsAfterIt() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate, toolOnFirst: true)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.submit("depois da tarefa", to: bot.id, delivery: .afterTask)
        model.submit("não, só o Engine", to: bot.id)
        #expect(model.composerLane(bot.id).queued.map(\.delivery) == [.afterTask, .steer])
        await gate.open()
        await waitUntilIdle(model, bot.id)

        let shown = items(model, bot.id)
        #expect(shown.map(\.text) == ["primeiro", "não, só o Engine", "depois da tarefa"])
        #expect(shown.map(\.duringTask) == [false, true, false]) // only the one that entered the task is marked
        let calls = await client.seen.calls
        #expect(calls.count == 3) // the task (two calls), then the waiting message as a turn of its own
        #expect(calls[1].last?.content == AgentEngine.steeringFrame + "\n\nnão, só o Engine")
        #expect(!calls[1].contains { $0.content == "depois da tarefa" })
    }

    /// The user's message reached the running task (the engine took it at a step boundary) and the Orb has not acted on it.
    @MainActor private func deliverWhileWorking(_ text: String, model: AppModel, bot: Bot) throws -> UUID {
        model.submit(text, to: bot.id)
        let lane = model.composerLane(bot.id)
        let id = try #require(lane.queued.first?.id)
        _ = lane.queue.drain()
        model.deliverSteered(id, to: bot.id)
        return id
    }

    @Test @MainActor func stoppingGivesBackWhatReachedTheTaskUnanswered() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        let id = try deliverWhileWorking("roda novamente", model: model, bot: bot)
        model.submit("e depois isto", to: bot.id, delivery: .afterTask)
        #expect(model.unansweredSteered(of: bot.id) == [id]) // its bubble offers "Parar e enviar", and ⌘↩ works

        model.stopTurn(bot.id)
        #expect(!model.isWorking(bot.id))
        #expect(userTexts(model, bot.id) == ["primeiro"]) // not left in a task that will never answer it
        #expect(model.drafts[bot.id] == "roda novamente\n\ne depois isto") // in the order you wrote them
        #expect(model.unansweredSteered(of: bot.id).isEmpty)
        #expect(await client.seen.count == 1) // a stop sends nothing
        await gate.open()
    }

    @Test @MainActor func stopAndSendFromTheBubbleSendsWhatReachedTheTaskUnanswered() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        _ = try deliverWhileWorking("roda novamente", model: model, bot: bot)

        model.stopAndSend(bot.id)
        await gate.open()
        await waitUntilIdle(model, bot.id)
        #expect(userTexts(model, bot.id) == ["primeiro", "roda novamente"])
        let calls = await client.seen.calls
        // A request of its own (after the turn's context), not a steer.
        let sent = try #require(calls.count == 2 ? calls[1].last?.content : nil)
        #expect(sent.hasSuffix("\n\nroda novamente") && !sent.contains(AgentEngine.steeringFrame))
    }

    @Test func aMessageIsUnansweredUntilTheOrbDoesSomethingAfterIt() {
        let start = TranscriptItem(.user(text: "tarefa", attachments: []))
        let steered = TranscriptItem(.user(text: "use X", attachments: []), duringTask: true)
        let notice = TranscriptItem(.notice("aviso"))
        let picture = TranscriptItem(.user(text: "veja", attachments: ["/a.png"]), duringTask: true)
        let reply = TranscriptItem(.bot(text: "ok", isStreaming: true))
        #expect(TranscriptItem.unansweredSteered(in: [start, steered, notice]) == [steered.id])
        #expect(TranscriptItem.unansweredSteered(in: [start, steered, reply]).isEmpty) // the Orb started answering
        #expect(TranscriptItem.unansweredSteered(in: [start, steered, picture]).isEmpty) // one with attachments stays
        #expect(TranscriptItem.unansweredSteered(in: [start]).isEmpty) // the request itself is no steered message
    }

    @Test @MainActor func aWaitingMessageSwitchesModeUntilItIsDelivered() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate, toolOnFirst: true)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.submit("uma ideia", to: bot.id)
        let lane = model.composerLane(bot.id)
        let id = try #require(lane.queued.first?.id)

        model.switchDelivery(id, botID: bot.id)
        #expect(lane.queued[0].delivery == .afterTask && lane.queue.messages[0].delivery == .afterTask && !lane.queue.hasSteering)
        model.switchDelivery(id, botID: bot.id)
        #expect(lane.queued[0].delivery == .steer && lane.queue.hasSteering) // and back

        model.deliverSteered(id, to: bot.id) // reached the model meanwhile (the engine took it from `queue` first)
        _ = lane.queue.drain()
        model.switchDelivery(id, botID: bot.id)
        #expect(lane.queued.isEmpty && lane.queue.isEmpty) // too late: nothing comes back to life
        #expect(!lane.setDelivery(id, to: .afterTask))
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func aMessageSwitchedToAfterTheTaskIsNotDeliveredInTheMiddle() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate, toolOnFirst: true)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.submit("mudei de ideia", to: bot.id)
        model.switchDelivery(try #require(model.composerLane(bot.id).queued.first?.id), botID: bot.id)
        await gate.open()
        await waitUntilIdle(model, bot.id)
        let calls = await client.seen.calls
        #expect(!calls[1].contains { $0.content == "mudei de ideia" }) // the task went on without it
        #expect(items(model, bot.id).map(\.text) == ["primeiro", "mudei de ideia"])
        #expect(items(model, bot.id).allSatisfy { !$0.duringTask })
    }

    @Test @MainActor func aFailedOrStoppedTaskGivesBackBothModesToTheField() async throws {
        let client = HeldModel()
        let (model, bot) = setUp(client)
        let lane = model.composerLane(bot.id)
        lane.enqueue(steered("um"))
        lane.enqueue(afterTask("dois"))
        model.settleSteering(bot.id, succeeded: false)
        #expect(model.drafts[bot.id] == "um\n\ndois" && lane.queued.isEmpty && lane.queue.isEmpty)
    }

    @Test @MainActor func aSteeredOneNeverDeliveredFollowsAsTheNextRequestWithTheOthers() async throws {
        let client = HeldModel()
        let (model, bot) = setUp(client)
        let lane = model.composerLane(bot.id)
        lane.enqueue(afterTask("a"))
        lane.enqueue(steered("b")) // the model answered without more steps: it was never taken
        model.settleSteering(bot.id, succeeded: true)
        #expect(items(model, bot.id).map(\.text) == ["a\n\nb"])
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func stopAndSendTakesBothModes() async throws {
        let gate = TestGate()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.submit("passo", to: bot.id)
        model.submit("fila", to: bot.id, delivery: .afterTask)
        model.stopAndSend(bot.id)
        #expect(items(model, bot.id).map(\.text) == ["primeiro", "passo\n\nfila"])
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }
}
