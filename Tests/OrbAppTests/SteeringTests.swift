import Foundation
import Testing
@testable import Orb

// Talking to an Orb while it works: the queue, the engine handing queued messages to the model between steps, and
// the app model showing them as queued, delivered, sent after the turn or given back.

private actor Latch {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

private actor Seen {
    private(set) var calls: [[ChatMessage]] = []
    func record(_ messages: [ChatMessage]) { calls.append(messages) }
    var count: Int { calls.count }
}

/// Answers "resposta N" to every call, holding the first call until `gate` opens, and remembers what it was sent.
private struct HeldModel: LLMClient {
    var seen = Seen()
    var gate: Latch?
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
        #expect(calls[0].last?.content == "use a pasta X")
        #expect(events.contains { if case .steered = $0 { true } else { false } })
        #expect(queue.isEmpty)
    }

    @Test func aMessageQueuedDuringAStepGoesInBetweenSteps() async throws {
        let queue = SteeringQueue()
        let gate = Latch()
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
        #expect(calls[1].last?.content == "não, use a pasta X")
        let ids = events.compactMap { event -> UUID? in if case .steered(let id) = event { id } else { nil } }
        #expect(ids.count == 1)
    }

    @Test func aMessageQueuedWhileTheFinalAnswerIsWrittenKeepsTheTurnGoing() async throws {
        let queue = SteeringQueue()
        let gate = Latch()
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
        try? FileManager.default.removeItem(at: root)
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

    @MainActor private func waitUntilIdle(_ model: AppModel, _ id: UUID) async {
        await waitUntil("the Orb to finish") { !model.isWorking(id) && model.turns[id] == nil }
    }

    @Test @MainActor func aMessageSentDuringATurnIsQueuedAndShownAsWaiting() async throws {
        let gate = Latch()
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
        #expect(model.steersMidTurn(bot.id))
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func theQueuedMessageJoinsTheTranscriptWhenTheModelGetsIt() async throws {
        let gate = Latch()
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
        #expect(second.last?.content == "segundo")
    }

    @Test @MainActor func takingAMessageBackReturnsItToTheDraft() async throws {
        let gate = Latch()
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
        let gate = Latch()
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

    @Test @MainActor func stopAndSendEndsTheTurnAndSendsTheQueuedMessageNow() async throws {
        let gate = Latch()
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

    @Test @MainActor func stopAndSendTakesWhatIsTypedToo() async throws {
        let gate = Latch()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        model.stopAndSend(bot.id, draft: "agora, outra coisa")
        #expect(userTexts(model, bot.id) == ["primeiro", "agora, outra coisa"])
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func aFailedTurnDoesNotSendWhatWasQueuedByItself() async throws {
        let gate = Latch()
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
        let sent = await client.seen.calls[0].last?.content ?? ""
        #expect(sent.contains(file.path))
    }

    @Test @MainActor func queuingScrollsTheChatToTheWaitingBubble() async throws {
        let gate = Latch()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        model.submit("primeiro", to: bot.id)
        await waitUntil("the model call") { await client.seen.count >= 1 }
        let before = model.live(bot.id).poke
        model.submit("segundo", to: bot.id)
        #expect(model.live(bot.id).poke > before) // the queued bubble changes no transcript revision; the poke follows it
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func aSkillInAQueuedMessageCountsOnceWhicheverWayItIsDelivered() async throws {
        let gate = Latch()
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
        let gate2 = Latch()
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
        let gate = Latch()
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

    @Test @MainActor func aRoutineRunCannotTakeYourMessages() async throws {
        let gate = Latch()
        let client = HeldModel(gate: gate)
        let (model, bot) = setUp(client)
        let routine = Routine(name: "R", botID: bot.id, prompt: "faça", schedule: .everyHours(1))
        model.routines = [routine]
        model.runRoutine(routine.id)
        #expect(model.isWorking(bot.id))
        #expect(!model.canSteer(bot.id))
        model.setDraft("oi", for: bot.id)
        #expect(!model.queueMessage("oi", to: bot.id))
        #expect(model.composerLane(bot.id).queued.isEmpty)
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }
}
