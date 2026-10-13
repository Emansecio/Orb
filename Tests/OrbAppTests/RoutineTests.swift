import Foundation
import Testing
@testable import Orb

/// Opens when told to; until then `wait()` suspends.
private actor Gate {
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

/// What the stub model was sent, one entry per model call.
private actor Calls {
    private(set) var received: [[ChatMessage]] = []
    func record(_ messages: [ChatMessage]) { received.append(messages) }
    var count: Int { received.count }
}

/// A model that answers `reply` (after the gate opens, when there is one) and remembers what it was sent.
private struct StubModel: LLMClient {
    var reply = "Tudo em ordem.\nNada mais a relatar."
    var calls = Calls()
    var gate: Gate?
    /// Instead of `gate`, for every model call after the first (the routine's, when a question came first).
    var laterGate: Gate?
    var failure: Error?

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await calls.record(messages)
                let number = await calls.count
                await (number > 1 && laterGate != nil ? laterGate : gate)?.wait()
                if let failure { continuation.finish(throwing: failure); return }
                continuation.yield(.text(reply))
                continuation.yield(.finished(.done, nil))
                continuation.finish()
            }
        }
    }
}

/// Returns when the stub model has been asked `count` times, i.e. the turn is under way and parked at its gate.
private func waitForModelCalls(_ stub: StubModel, _ count: Int = 1) async {
    await waitUntil("the model to be called \(count) time(s)") { await stub.calls.count >= count }
}

/// Routines run in a conversation of their own, unattended, one at a time per Orb.
@Suite final class RoutineTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbRoutines-\(UUID().uuidString)")

    init() { QuietNotifications.hold() } // no banner from the test process

    deinit {
        QuietNotifications.release()
        removeTestFolder(root)
    }

    private var store: Store { Store(directory: root) }

    private func chatWith(_ said: String = "oi") -> Conversation {
        Conversation(items: [TranscriptItem(.user(text: said, attachments: [])), TranscriptItem(.bot(text: "olá", isStreaming: false))],
                     messages: [.user(said), ChatMessage(role: .assistant, content: "olá")])
    }

    /// A model with one Orb (with `chat` as its conversation and a folder of its own, a temporary one unless `folder`
    /// says otherwise: the Orb must not read the real home folder in every test) and one routine, using the stub model.
    @MainActor private func setUp(_ stub: StubModel = StubModel(), folder: URL? = nil, mode: PermissionMode? = nil,
                                  chat: Conversation? = nil) -> (AppModel, Bot, Routine) {
        var state = AppState.initial
        let own = folder ?? root.appending(path: "pasta-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        state.bots[0].workingDirectory = own.path
        let routine = Routine(name: "Resumo da manhã", botID: state.bots[0].id, prompt: "resuma os arquivos novos",
                              schedule: .everyHours(1), permissionMode: mode)
        state.routines = [routine]
        store.save(state)
        store.save(chat ?? chatWith(), for: state.bots[0].id)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = { stub }
        return (model, model.bots[0], routine)
    }

    /// Returns when the Orb has no turn: closing a turn starts the next queued routine in the same step, so there
    /// is no moment in between where it looks idle.
    private func notices(_ items: [TranscriptItem]) -> [String] {
        items.compactMap { if case .notice(let text) = $0.kind { text } else { nil } }
    }

    private func text(_ message: ChatMessage) -> String { message.content }

    // MARK: Its own conversation

    // Covers the contract `poke` (the avatar jumps) is not `scrollNudge` (the chat scrolls); ChatView listens only to the latter.
    @Test @MainActor func aRoutineStartingDoesNotScrollTheChatYouAreReading() async throws {
        let (model, bot, routine) = setUp()
        let live = model.live(bot.id)
        let nudges = live.scrollNudge, jumps = live.poke
        model.runRoutine(routine.id)
        await model.routineStarted()
        #expect(live.poke > jumps) // the Orb still gets to work...
        #expect(live.scrollNudge == nudges) // ...but the chat stays where you left it
        await waitUntilIdle(model, bot.id)
        #expect(live.scrollNudge == nudges)

        model.send("oi", to: bot.id, fromUser: true) // what you send does scroll
        #expect(live.scrollNudge == nudges + 1)
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func aRoutineRunsInItsOwnConversationNotInYourChat() async throws {
        let (model, bot, routine) = setUp()
        let before = model.transcript(bot.id)

        model.runRoutine(routine.id)
        await model.routineStarted()
        #expect(model.isWorking(bot.id))
        #expect(model.transcript(bot.id).count == before.count) // the chat shows your conversation while it runs
        await waitUntilIdle(model, bot.id)

        // Your chat: what it had, plus one line.
        let chat = model.transcript(bot.id)
        #expect(chat.count == before.count + 1)
        let line = try #require(notices(chat).last)
        #expect(line.hasPrefix("Rotina “Resumo da manhã” terminou: Tudo em ordem. (relatório em Rotinas/"))
        #expect(!line.contains("\n") && !line.contains("Nada mais a relatar"))
        for item in chat { if case .tool = item.kind { Issue.record("a tool row reached the chat") } }

        // The routine's conversation: the task and the report.
        let saved = try #require(store.readRoutineConversation(routine: routine.id, for: bot.id).value)
        let kinds = saved.items.map { item -> String in
            switch item.kind {
            case .user(let text, _): "user:\(text)"
            case .bot(let text, _): "bot:\(text)"
            case .notice(let text): text.hasPrefix(Conversation.routineRunMarker) ? "run" : "notice"
            default: "other"
            }
        }
        #expect(kinds == ["run", "user:resuma os arquivos novos", "bot:Tudo em ordem.\nNada mais a relatar."])
        // The chat file still holds only your conversation.
        model.saveNow()
        let onDisk = try #require(store.loadConversation(bot.id))
        #expect(onDisk.messages.count == 2 && onDisk.messages.first?.content == "oi")
    }

    /// The `schedule` tool's run and run_now start the same run as the Rotinas page's button.
    @Test @MainActor func theOrbCanRunATaskNowOrCreateOneThatRunsAtOnce() async throws {
        let (model, bot, routine) = setUp()
        let said = try model.schedule(.object(["action": .string("run"), "name": .string("Resumo da manhã")]), orb: bot.id)
        #expect(said.hasPrefix("Pedi para rodar “Resumo da manhã” agora."))
        await model.routineStarted()
        #expect(model.isRoutineRunning(routine.id))
        await waitUntilIdle(model, bot.id)
        #expect(model.routines[0].runs.count == 1)

        _ = try model.schedule(.object(["action": .string("create"), "name": .string("Já"), "prompt": .string("resuma"),
                                        "when": .object(["kind": .string("daily"), "hour": .number(9)]), "run_now": .bool(true)]), orb: bot.id)
        let created = try #require(model.routines.last)
        await model.routineStarted()
        #expect(model.isRoutineRunning(created.id))
        await waitUntilIdle(model, bot.id)
        #expect(model.routines.last?.runs.count == 1 && model.routines.last?.isEnabled == true)
    }

    @Test @MainActor func theRunIsRecordedInTheRoutinesHistory() async throws {
        let (model, bot, routine) = setUp()
        model.runRoutine(routine.id)
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)

        let saved = try #require(model.routines.first)
        let run = try #require(saved.runs.first)
        #expect(saved.runs.count == 1 && run.succeeded)
        #expect(run.summary == "Tudo em ordem.")
        #expect(run.report == "Tudo em ordem.\nNada mais a relatar.")
        #expect(run.reportFile != nil) // the Orb has a folder of its own
        #expect(saved.lastRun != nil && saved.lastResult?.hasPrefix("Tudo em ordem.") == true)
    }

    // MARK: A goal

    @Test @MainActor func aGoalsRunIsAskedForTheLineAndItsCheckGoesIntoTheGoalAndTheHistory() async throws {
        let stub = StubModel(reply: "Movi 14 arquivos.\nProgresso: 35% · em dia · faltam 26")
        let (model, bot, routine) = setUp(stub)
        model.routines[0].goal = RoutineGoal(target: "Downloads em ordem")
        model.runRoutine(routine.id)
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)

        let prompt = try #require(await stub.calls.received.first?.last { $0.role == .user }).content
        #expect(prompt.contains("Goal of this routine") && prompt.contains("Downloads em ordem"))
        let saved = try #require(model.routines.first)
        let check = GoalCheck(progress: 35, status: .onTrack, note: "faltam 26")
        #expect(saved.goal?.check == check && saved.runs.first?.check == check)
        #expect(saved.isEnabled)
        #expect(notices(model.transcript(bot.id)).last?.hasPrefix("Rotina “Resumo da manhã” terminou: Movi 14 arquivos.") == true)
    }

    @Test @MainActor func aGoalReachedPausesTheRoutineAndTheChatSaysSo() async throws {
        let (model, bot, routine) = setUp(StubModel(reply: "Tudo em pastas.\nProgresso: 100% · concluída · nada solto"))
        model.routines[0].goal = RoutineGoal(target: "Downloads em ordem")
        model.runRoutine(routine.id)
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)

        #expect(model.routines[0].goal?.check?.status == .done)
        #expect(!model.routines[0].isEnabled)
        let line = try #require(notices(model.transcript(bot.id)).last)
        #expect(line.hasPrefix("Rotina “Resumo da manhã” alcançou a meta e foi pausada: Tudo em pastas."))
    }

    @Test @MainActor func theHistoryKeepsTheLastRunsAndEachRunStartsFromScratch() async throws {
        let stub = StubModel()
        let (model, bot, routine) = setUp(stub)
        for _ in 0..<(Routine.keptRuns + 2) {
            model.runRoutine(routine.id)
            await model.routineStarted()
            await waitUntilIdle(model, bot.id)
        }
        #expect(model.routines[0].runs.count == Routine.keptRuns)

        // Every call carries just that run's task: earlier runs are not in the model's context.
        let received = await stub.calls.received
        #expect(received.count == Routine.keptRuns + 2)
        for messages in received { #expect(messages.filter { $0.role == .user }.count == 1) }
        // The previous run's report is handed over so the routine can compare.
        #expect(received.last?.contains { text($0).contains("Report of the previous run") } == true)
        #expect(received.first?.contains { text($0).contains("Report of the previous run") } == false)

        // The transcript keeps the last runs only, cut at a run boundary.
        let saved = try #require(store.readRoutineConversation(routine: routine.id, for: bot.id).value)
        let runs = saved.items.filter { if case .notice(let t) = $0.kind { t.hasPrefix(Conversation.routineRunMarker) } else { false } }
        #expect(runs.count == Routine.keptRuns)
    }

    // MARK: Unattended

    @Test @MainActor func theModelIsToldNobodyIsThere() async throws {
        let stub = StubModel()
        let (model, bot, routine) = setUp(stub)
        model.runRoutine(routine.id)
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)

        let sent = try #require(await stub.calls.received.first)
        let prompt = try #require(sent.last { $0.role == .user }).content
        #expect(prompt.contains("[Automatic run]"))
        #expect(prompt.contains("The user is not here"))
        #expect(prompt.contains("do not ask questions"))
        #expect(prompt.contains("do not wait for answers"))
        #expect(prompt.contains("short report"))
        #expect(prompt.contains("resuma os arquivos novos"))
        #expect(prompt.contains("Resumo da manhã"))
        // The conversation shows the task as written, not the preamble.
        let saved = try #require(store.readRoutineConversation(routine: routine.id, for: bot.id).value)
        #expect(saved.items.contains { if case .user(let t, _) = $0.kind { t == "resuma os arquivos novos" } else { false } })
    }

    @Test @MainActor func aRoutineDoesNotGetTheGettingToKnowYouInterview() async throws {
        let stub = StubModel()
        let (model, bot, routine) = setUp(stub)
        await model.memory.bank(for: bot.id).ensureIdentity(notes: "", interview: true)

        // Control: the same Orb in a chat does get it (the text rides in the first model call's messages).
        #expect(model.send("oi de novo", to: bot.id))
        await waitUntilIdle(model, bot.id)
        let chatCall = try #require(await stub.calls.received.first)
        #expect(chatCall.contains { text($0).contains("Getting to know the user") })

        model.runRoutine(routine.id)
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)
        let routineCall = try #require(await stub.calls.received.last)
        #expect(!routineCall.contains { text($0).contains("Getting to know the user") })
    }

    @Test func thePreambleHoldsForAnyPromptAndNamesThePreviousReport() {
        let previous = RoutineRun(date: Date(timeIntervalSince1970: 1_800_000_000), succeeded: true, summary: "x",
                                  report: "Tinha 3 arquivos.")
        let text = RoutinePrompt.unattended("faça X", routine: "Diária", previous: previous)
        #expect(text.hasSuffix("Task:\nfaça X"))
        #expect(text.contains("Tinha 3 arquivos."))
        #expect(!RoutinePrompt.unattended("faça X", routine: "Diária").contains("previous run"))
    }

    // MARK: Permission mode

    @Test @MainActor func aRoutinesOwnModeAppliesToItsRunOnly() async throws {
        let (model, bot, routine) = setUp(mode: .readOnly)
        #expect(model.bot(bot.id)?.permissionMode == .ask)
        #expect(model.permissionState(of: bot.id)?.mode == .ask)

        model.runRoutine(routine.id)
        await model.routineStarted()
        #expect(model.permissionState(of: bot.id)?.mode == .readOnly) // what the engine reads at every tool call
        await waitUntilIdle(model, bot.id)

        #expect(model.permissionState(of: bot.id)?.mode == .ask)
        #expect(model.bot(bot.id)?.permissionMode == .ask) // the Orb's own setting never changed
    }

    @Test @MainActor func withoutAnOverrideTheRoutineUsesTheOrbsMode() async throws {
        let (model, bot, routine) = setUp()
        model.update(bot.id) { $0.permissionMode = .auto }
        model.runRoutine(routine.id)
        await model.routineStarted()
        #expect(model.permissionState(of: bot.id)?.mode == .auto)
        await waitUntilIdle(model, bot.id)
    }

    @Test func routinesWrittenBeforeTheseFieldsExistStillLoad() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"Velha","botID":"\#(UUID().uuidString)","prompt":"p","schedule":{"everyHours":{"_0":2}},"isEnabled":true,"createdAt":0}"#
        let routine = try JSONDecoder().decode(Routine.self, from: Data(json.utf8))
        #expect(routine.permissionMode == nil && routine.runs.isEmpty)

        var withRuns = routine
        withRuns.permissionMode = .readOnly
        withRuns.runs = [RoutineRun(date: .now, succeeded: false, summary: "falhou")]
        let back = try JSONDecoder().decode(Routine.self, from: JSONEncoder().encode(withRuns))
        #expect(back.permissionMode == .readOnly && back.runs.map(\.summary) == ["falhou"])
    }

    // MARK: A busy Orb

    @Test @MainActor func aRoutineDueWhileTheOrbIsBusyWaitsAndThenRunsOnce() async throws {
        let gate = Gate()
        let stub = StubModel(gate: gate)
        let (model, bot, routine) = setUp(stub)
        #expect(model.send("pergunta", to: bot.id))

        model.runRoutine(routine.id)
        await model.routineStarted()
        model.runRoutine(routine.id) // due again on the next check: still one
        await model.routineStarted()
        #expect(model.queuedRoutines == [routine.id])
        #expect(model.isRoutineQueued(routine.id) && !model.isRoutineRunning(routine.id))
        #expect(model.routines[0].runs.isEmpty)

        await gate.open()
        await waitUntilIdle(model, bot.id)

        #expect(model.queuedRoutines.isEmpty)
        #expect(model.routines[0].runs.count == 1)
        #expect(await stub.calls.count == 2) // your question, once; the routine, once
        // Your answer is in your chat, the routine's report is not.
        let chat = model.transcript(bot.id)
        #expect(chat.contains { if case .bot(let t, _) = $0.kind { t.hasPrefix("Tudo em ordem") } else { false } })
        #expect(notices(chat).last?.hasPrefix("Rotina “Resumo da manhã” terminou") == true)
    }

    @Test @MainActor func anIntervalRoutineIsDueOnceAndNeverPilesUp() async throws {
        let gate = Gate()
        let (model, bot, routine) = setUp(StubModel(gate: gate))
        model.routines[0].schedule = .everyMinutes(15)
        model.routines[0].lastRun = .now.addingTimeInterval(-16 * 60)
        #expect(model.routines[0].nextRun < .now)

        model.runRoutine(routine.id)
        await model.routineStarted()
        // Started: the next one counts from the start, so the scheduler's checks while it runs find nothing due.
        #expect(model.routines[0].nextRun > .now.addingTimeInterval(14 * 60))
        model.runRoutine(routine.id) // a check during the run
        #expect(!model.isRoutineQueued(routine.id))

        // The run outlasts its slot: the next starts 15 minutes after this one ends, not at once.
        model.routines[0].lastRun = .now.addingTimeInterval(-20 * 60)
        await gate.open()
        await waitUntilIdle(model, bot.id)
        #expect(model.routines[0].runs.count == 1)
        #expect(model.routines[0].nextRun > .now.addingTimeInterval(14 * 60))
    }

    @Test @MainActor func aOneTimeRoutineSwitchesItselfOffAfterItsRunButNotAfterATestRun() async throws {
        let (model, bot, routine) = setUp()
        let moment = Date.now.addingTimeInterval(3600)
        model.routines[0].schedule = .once(moment)
        model.routines[0].createdAt = .now
        model.runRoutine(routine.id) // "Rodar agora", before its moment
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)
        #expect(model.routines[0].isEnabled && model.routines[0].nextRun == moment)

        model.routines[0].lastRun = moment.addingTimeInterval(-60) // its moment came
        model.routines[0].schedule = .once(.now.addingTimeInterval(-1))
        model.runRoutine(routine.id)
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)
        #expect(!model.routines[0].isEnabled && model.routines[0].runs.count == 2)
        #expect(RoutineText.nextRun(of: model.routines[0]) == nil)
    }

    @Test @MainActor func aTestRunStillGoingWhenTheMomentComesLeavesTheMomentDue() async throws {
        let gate = Gate()
        let (model, bot, routine) = setUp(StubModel(gate: gate))
        model.routines[0].schedule = .once(.now.addingTimeInterval(3600))
        model.routines[0].createdAt = .now
        model.runRoutine(routine.id) // "Rodar agora", before its moment
        await model.routineStarted()
        let started = try #require(model.routines[0].lastRun)
        let moment = started.addingTimeInterval(0.001) // the moment comes while it runs
        model.routines[0].schedule = .once(moment)
        await gate.open()
        await waitUntilIdle(model, bot.id)
        #expect(model.routines[0].isEnabled && model.routines[0].nextRun == moment)
    }

    @Test @MainActor func aRoutineDueWhileTheMacSleptWaitsForTheNetworkAfterWaking() async throws {
        let (model, bot, routine) = setUp()
        model.routines[0].lastRun = .now.addingTimeInterval(-3 * 3600)
        let woke = Date.now
        model.systemDidWake(at: woke)

        model.runDueRoutines(now: woke.addingTimeInterval(5)) // the timer fires at once: no network yet
        #expect(!model.isStartingRoutine && !model.isWorking(bot.id))
        #expect(model.routines[0].runs.isEmpty)

        model.runDueRoutines(now: woke.addingTimeInterval(AppModel.wakeSettleTime + 1))
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)
        #expect(model.routines[0].runs.count == 1)
        _ = routine
    }

    @Test @MainActor func aRoutineWaitsEvenIfTheTimerBeatsTheWakeNotification() async throws {
        let (model, bot, _) = setUp()
        model.routines[0].lastRun = .now.addingTimeInterval(-3 * 3600)
        let start = Date.now

        // The Mac announced it was going to sleep; the timer resumes before `didWake` is delivered.
        model.systemWillSleep()
        model.runDueRoutines(now: start.addingTimeInterval(3600))
        #expect(!model.isStartingRoutine && !model.isWorking(bot.id))
        #expect(model.routines[0].runs.isEmpty)

        model.systemDidWake(at: start.addingTimeInterval(3601))
        model.runDueRoutines(now: start.addingTimeInterval(3601 + AppModel.wakeSettleTime + 1))
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)
        #expect(model.routines[0].runs.count == 1)
    }

    @Test @MainActor func aSleepWhoseWakeNeverComesDoesNotHoldTheRoutinesForGood() async throws {
        let (model, bot, _) = setUp()
        model.routines[0].lastRun = .now.addingTimeInterval(-3 * 3600)
        let start = Date.now

        // "Going to sleep" arrives, the Mac stays up (a dark wake, a cancelled sleep) and `didWake` never does.
        model.systemWillSleep(at: start)
        model.runDueRoutines(now: start.addingTimeInterval(30))
        #expect(model.routines[0].runs.isEmpty)
        model.runDueRoutines(now: start.addingTimeInterval(AppModel.sleepHold + 30)) // counts as a wake: waits for the network
        #expect(!model.isStartingRoutine && !model.isWorking(bot.id))

        model.runDueRoutines(now: start.addingTimeInterval(AppModel.sleepHold + 30 + AppModel.wakeSettleTime + 1))
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)
        #expect(model.routines[0].runs.count == 1)
    }

    @Test @MainActor func aLongGapBetweenPassesCountsAsWakingEvenWithoutAnyNotification() async throws {
        let (model, bot, _) = setUp()
        model.routines[0].lastRun = .now.addingTimeInterval(-3 * 3600)
        let start = Date.now
        model.routines[0].isEnabled = false
        model.runDueRoutines(now: start) // a normal pass before the lid closed
        model.routines[0].isEnabled = true

        model.runDueRoutines(now: start.addingTimeInterval(3600)) // the timer, with no notification yet
        #expect(!model.isStartingRoutine && !model.isWorking(bot.id))
        #expect(model.routines[0].runs.isEmpty)

        model.runDueRoutines(now: start.addingTimeInterval(3600 + AppModel.wakeSettleTime + 1))
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)
        #expect(model.routines[0].runs.count == 1)
    }

    @Test @MainActor func aRunThatEndsInsideItsSlotKeepsItsStartAsTheCount() async throws {
        let (model, bot, routine) = setUp()
        model.routines[0].schedule = .everyHours(2)
        model.runRoutine(routine.id)
        await model.routineStarted()
        let started = try #require(model.routines[0].lastRun)
        await waitUntilIdle(model, bot.id)
        #expect(model.routines[0].lastRun == started)
    }

    @Test @MainActor func twoRoutinesOfTheSameOrbTakeTurns() async throws {
        let (model, bot, first) = setUp()
        let second = Routine(name: "Outra", botID: bot.id, prompt: "faça outra coisa", schedule: .daily(hour: 8, minute: 0))
        model.routines.append(second)

        model.runRoutine(first.id)
        await model.routineStarted()
        model.runRoutine(second.id)
        await model.routineStarted()
        #expect(model.queuedRoutines == [second.id])
        await waitUntilIdle(model, bot.id)

        #expect(model.routines.map(\.runs.count) == [1, 1])
        #expect(model.queuedRoutines.isEmpty)
    }

    @Test @MainActor func aRoutineQueuedForAnOrbThatIsDeletedNeverRuns() async throws {
        let gate = Gate()
        let (model, bot, routine) = setUp(StubModel(gate: gate))
        #expect(model.send("pergunta", to: bot.id))
        let question = try #require(model.turns[bot.id])
        model.runRoutine(routine.id)
        await model.routineStarted()
        #expect(model.queuedRoutines.count == 1)

        model.deleteBot(bot.id)
        await gate.open()
        await question.value // the question's turn is over: nothing is left that could start the routine
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.queuedRoutines.isEmpty && model.routines.isEmpty)
    }

    @Test @MainActor func deletingARoutineRemovesItFromTheQueueAndItsConversation() async throws {
        let (model, bot, routine) = setUp()
        model.runRoutine(routine.id)
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)
        #expect(store.readRoutineConversation(routine: routine.id, for: bot.id).value != nil)

        model.deleteRoutine(routine.id)
        #expect(model.routines.isEmpty)
        #expect(store.readRoutineConversation(routine: routine.id, for: bot.id).value == nil)
    }

    // MARK: Reading its conversation

    /// Holds the writer with a save of the routine's conversation behind it, so reading that conversation has to wait.
    @MainActor private func holdRoutineConversation(_ model: AppModel, _ bot: Bot, _ routine: Routine) -> DispatchSemaphore {
        let release = DispatchSemaphore(value: 0)
        store.stallWriter(until: release)
        store.saveRoutineConversation(chatWith("antiga"), routine: routine.id, for: bot.id)
        return release
    }

    @Test @MainActor func aRoutineWaitsForItsConversationWithoutBlockingTheMainThread() async throws {
        let gate = Gate()
        let (model, bot, routine) = setUp(StubModel(gate: gate))
        let release = holdRoutineConversation(model, bot, routine)
        defer { release.signal() }

        model.runRoutine(routine.id)
        try await Task.sleep(for: .milliseconds(100)) // the main thread kept running while the read waited
        #expect(model.isStartingRoutine && !model.isWorking(bot.id) && model.session(bot.id).routineID == nil)
        // A message sent meanwhile gets the Orb; the routine, as one that came due while it was busy, waits for it.
        #expect(model.send("pergunta", to: bot.id))
        release.signal()
        await model.routineStarted()
        #expect(model.isRoutineQueued(routine.id) && !model.isRoutineRunning(routine.id))
        #expect(model.session(bot.id).routineID == nil)

        await gate.open()
        await waitUntilIdle(model, bot.id)
        #expect(model.routines[0].runs.count == 1 && model.queuedRoutines.isEmpty)
    }

    @Test @MainActor func aRoutineAskedTwiceWhileItsConversationIsReadRunsOnce() async throws {
        let stub = StubModel()
        let (model, bot, routine) = setUp(stub)
        let release = holdRoutineConversation(model, bot, routine)
        defer { release.signal() }

        model.runRoutine(routine.id)
        model.runRoutine(routine.id) // "Rodar agora" twice
        #expect(model.queuedRoutines.isEmpty)
        release.signal()
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)
        #expect(model.routines[0].runs.count == 1)
        #expect(await stub.calls.count == 1)
    }

    @Test @MainActor func aRoutineDeletedWhileItsConversationIsReadNeverRuns() async throws {
        let stub = StubModel()
        let (model, bot, routine) = setUp(stub)
        let release = holdRoutineConversation(model, bot, routine)
        defer { release.signal() }

        model.runRoutine(routine.id)
        model.deleteRoutine(routine.id)
        release.signal()
        await model.routineStarted()
        #expect(model.routines.isEmpty && !model.isWorking(bot.id) && model.session(bot.id).routineID == nil)
        #expect(model.session(bot.id).parkedChat == nil)
        #expect(await stub.calls.count == 0)
    }

    // MARK: Your chat is safe

    @Test @MainActor func stoppingARoutineGivesTheChatBackAndRecordsAFailedRun() async throws {
        let gate = Gate()
        let stub = StubModel(gate: gate)
        let (model, bot, routine) = setUp(stub)
        model.runRoutine(routine.id)
        await model.routineStarted()
        #expect(model.isRoutineRunning(routine.id))
        await waitForModelCalls(stub)

        model.stop(bot.id)

        #expect(!model.isWorking(bot.id) && !model.isRoutineRunning(routine.id))
        let chat = model.transcript(bot.id)
        #expect(chat.count == 3) // your two items and the line about the routine
        #expect(notices(chat).last?.hasPrefix("Rotina “Resumo da manhã” não terminou") == true)
        let run = try #require(model.routines[0].runs.first)
        #expect(!run.succeeded)
        await gate.open()
    }

    @Test @MainActor func aRoutineThatFailsIsReportedWithItsReason() async throws {
        let (model, bot, routine) = setUp(StubModel(failure: LLMError.notConfigured))
        model.runRoutine(routine.id)
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)

        let run = try #require(model.routines[0].runs.first)
        #expect(!run.succeeded && run.summary.hasPrefix("Não deu certo"))
        #expect(model.routines[0].lastResult == "Não terminou: veja a conversa.")
        #expect(model.transcript(bot.id).count == 3)
    }

    @Test @MainActor func aRoutineStoppedAtTheStepLimitIsAFailedRunThatSaysWhy() async throws {
        let gate = Gate()
        let stub = StubModel(gate: gate)
        let (model, bot, routine) = setUp(stub)
        model.runRoutine(routine.id)
        await waitForModelCalls(stub)
        // The engine ran out of steps: it says so and marks the task paused.
        let paused = AgentEngine.pausedNotice(after: 100)
        model.apply(.notice(paused), to: bot.id)
        model.apply(.taskPaused, to: bot.id)
        await gate.open()
        await waitUntilIdle(model, bot.id)

        let run = try #require(model.routines[0].runs.first)
        // The reason, once, without the "continua" only the chat can act on.
        let why = paused.replacing(AgentEngine.continueHint, with: "")
        #expect(!run.succeeded && run.summary == why)
        #expect(notices(model.transcript(bot.id)).last?.hasSuffix(why) == true)
    }

    @Test @MainActor func aRoutineWithoutAModelDoesNotRunAndLeavesTheChatAlone() async throws {
        let (model, bot, routine) = setUp()
        model.providers = []
        model.defaultModel = ""
        let before = model.transcript(bot.id)

        model.runRoutine(routine.id)
        await model.routineStarted()

        #expect(!model.isWorking(bot.id) && model.turns[bot.id] == nil)
        #expect(model.transcript(bot.id).count == before.count)
        let run = try #require(model.routines[0].runs.first)
        #expect(!run.succeeded && run.summary == "Não rodou: conecte um modelo em Ajustes.")
        #expect(model.routines[0].lastRun != nil) // not retried every 30 seconds
        #expect(model.queuedRoutines.isEmpty)
    }

    @Test @MainActor func aRoutineThatDoesNotRunLetsTheNextOneInTheQueueGo() async throws {
        let (model, bot, routine) = setUp()
        let empty = Routine(name: "Sem instruções", botID: bot.id, prompt: "  ", schedule: .everyHours(1))
        model.routines.insert(empty, at: 0)
        model.runRoutine(empty.id)
        model.runRoutine(routine.id) // the Orb is being taken by the first: this one waits
        #expect(model.queuedRoutines == [routine.id])
        await waitUntil("the second routine ran") { model.routines.first { $0.id == routine.id }?.runs.isEmpty == false }
        await waitUntilIdle(model, bot.id)
        #expect(model.routines.first { $0.id == empty.id }?.runs.first?.summary == "Não rodou: a rotina está sem instruções.")
        #expect(model.routines.first { $0.id == routine.id }?.runs.first?.succeeded == true)
        #expect(model.queuedRoutines.isEmpty)
    }

    @Test @MainActor func theMacIsKeptAwakeOnlyWhileARoutineRuns() async throws {
        let gate = Gate()
        let stub = StubModel(gate: gate)
        let (model, bot, routine) = setUp(stub)
        let activity = FakeActivity()
        model.activity = activity
        model.keepsAwakeForRoutines = true
        model.syncActivities()
        // A routine is switched on: the app is kept out of App Nap, the Mac may still sleep.
        #expect(activity.open.map(\.level) == [.waiting])

        model.runRoutine(routine.id)
        await model.routineStarted()
        await waitForModelCalls(stub)
        #expect(activity.open.map(\.level).sorted { "\($0)" < "\($1)" } == [.running, .waiting])
        #expect(activity.open.first { $0.level == .running }?.reason.contains("Resumo da manhã") == true)

        await gate.open()
        await waitUntilIdle(model, bot.id)
        #expect(activity.open.map(\.level) == [.waiting]) // the run is over: nothing holds the Mac awake
        model.routines[0].isEnabled = false
        #expect(activity.open.isEmpty)
        #expect(activity.began.count == activity.ended)
    }

    @Test @MainActor func aRoutineStoppedAtAnApprovalCardLetsTheMacSleep() async throws {
        let gate = Gate()
        let stub = StubModel(gate: gate)
        let (model, bot, routine) = setUp(stub)
        let activity = FakeActivity()
        model.activity = activity
        model.keepsAwakeForRoutines = true
        model.syncActivities()
        model.runRoutine(routine.id)
        await model.routineStarted()
        await waitForModelCalls(stub)
        #expect(activity.open.contains { $0.level == .running })

        // Waiting for you is not work: nobody is there to answer at 3 a.m., and the Mac may sleep meanwhile.
        model.setAwaitingApproval(true, of: bot.id)
        #expect(activity.open.map(\.level) == [.waiting])
        model.setAwaitingApproval(false, of: bot.id)
        #expect(activity.open.contains { $0.level == .running })

        await gate.open()
        await waitUntilIdle(model, bot.id)
        #expect(activity.open.map(\.level) == [.waiting])
        model.routines[0].isEnabled = false
        #expect(activity.began.count == activity.ended)
    }

    @Test @MainActor func aRoutineConversationThatCouldNotBeWrittenIsWrittenAgainOnQuit() async throws {
        let (model, bot, routine) = setUp()
        // A plain file where the Orb's folder of run conversations goes: the write fails with no full disk needed.
        let file = root.appending(path: "conversations/\(bot.id.uuidString)")
        try Data("x".utf8).write(to: file)
        model.runRoutine(routine.id)
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)
        model.store.flush()
        // The chat is back, so it is not the one to write again; the run's conversation is kept for that.
        await waitUntil("the run's conversation to be kept") { model.unsavedRoutineConversations[routine.id] != nil }
        #expect(!model.dataNotices.isEmpty)

        try FileManager.default.removeItem(at: file)
        model.saveNow()
        let saved = try #require(model.store.readRoutineConversation(routine: routine.id, for: bot.id).value)
        #expect(!saved.items.isEmpty)
        #expect(model.unsavedRoutineConversations.isEmpty)
    }

    @Test @MainActor func aRoutineThatDidNotRunHoldsNothing() async throws {
        let (model, _, routine) = setUp(StubModel())
        model.providers = [] // no model connected: the routine does not happen
        let activity = FakeActivity()
        model.activity = activity
        model.runRoutine(routine.id)
        await model.routineStarted()
        #expect(activity.open.isEmpty)
        #expect(activity.began.count == activity.ended)
    }

    @Test @MainActor func whileARoutineRunsTheChatOnDiskIsNotTouched() async throws {
        let gate = Gate()
        let stub = StubModel(gate: gate)
        let (model, bot, routine) = setUp(stub)
        model.runRoutine(routine.id)
        await model.routineStarted()
        await waitForModelCalls(stub)
        model.saveNow() // as on quit
        store.flush()

        let chatFile = try #require(store.loadConversation(bot.id))
        #expect(chatFile.messages.first?.content == "oi")
        #expect(!chatFile.items.contains { if case .user(let t, _) = $0.kind { t == "resuma os arquivos novos" } else { false } })
        let routineFile = try #require(store.readRoutineConversation(routine: routine.id, for: bot.id).value)
        #expect(routineFile.items.contains { if case .user(let t, _) = $0.kind { t == "resuma os arquivos novos" } else { false } })
        await gate.open()
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func yourChatIsOnDiskWhenAQueuedRoutineStartsRightAfterItsTurn() async throws {
        let first = Gate(), later = Gate()
        let (model, bot, routine) = setUp(StubModel(gate: first, laterGate: later))
        #expect(model.send("pergunta do usuário", to: bot.id))
        model.runRoutine(routine.id)
        await model.routineStarted()
        await first.open()
        await waitUntil("the routine to take the Orb") { model.isRoutineRunning(routine.id) }
        #expect(model.isRoutineRunning(routine.id)) // the routine took the Orb the moment the question was answered

        model.saveNow() // as on quit, in the middle of the run
        let chatFile = try #require(store.loadConversation(bot.id))
        #expect(chatFile.items.contains { if case .user(let t, _) = $0.kind { t == "pergunta do usuário" } else { false } })
        #expect(chatFile.items.contains { if case .bot(let t, _) = $0.kind { t.hasPrefix("Tudo em ordem") } else { false } })
        #expect(!chatFile.items.contains { if case .user(let t, _) = $0.kind { t == "resuma os arquivos novos" } else { false } })
        await later.open()
        await waitUntilIdle(model, bot.id)
    }

    @Test @MainActor func aRunStartsFromTheConversationThatCouldNotBeWrittenNotFromTheOlderFile() async throws {
        let (model, bot, routine) = setUp()
        var earlier = Conversation().startingRoutineRun(at: .now.addingTimeInterval(-3_600))
        earlier.items.append(TranscriptItem(.bot(text: "rodada anterior", isStreaming: false)))
        model.unsavedRoutineConversations[routine.id] = (bot.id, earlier)
        model.runRoutine(routine.id)
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)
        model.saveNow()
        let saved = try #require(model.store.readRoutineConversation(routine: routine.id, for: bot.id).value)
        #expect(saved.items.contains { if case .bot(let t, _) = $0.kind { t == "rodada anterior" } else { false } })
        #expect(model.unsavedRoutineConversations.isEmpty)
    }

    @Test @MainActor func aQueuedRoutineMovedToAnotherOrbRunsWhenThatOrbIsFree() async throws {
        let gate = Gate()
        let stub = StubModel(gate: gate)
        let (model, bot, routine) = setUp(stub)
        let folder = root.appending(path: "pasta-outro")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var other = Bot(name: "Outro", role: "", orb: OrbConfig())
        other.workingDirectory = folder.path
        model.bots.append(other)
        #expect(model.send("pergunta", to: bot.id))
        model.runRoutine(routine.id)
        await model.routineStarted()
        #expect(model.queuedRoutines == [routine.id])

        model.routines[0].botID = other.id
        await waitUntil("the moved routine to start on its new Orb") { model.isRoutineRunning(routine.id) }
        #expect(model.isRoutineRunning(routine.id) && model.queuedRoutines.isEmpty)

        await gate.open()
        await waitUntilIdle(model, bot.id)
        await waitUntilIdle(model, other.id)
        #expect(model.routines[0].runs.count == 1)
        #expect(await stub.calls.count == 2) // the question and one run: the old Orb finishing does not start it again
    }

    @Test @MainActor func aQueuedRoutineThatIsSwitchedOffDoesNotRun() async throws {
        let gate = Gate()
        let stub = StubModel(gate: gate)
        let (model, bot, routine) = setUp(stub)
        #expect(model.send("pergunta", to: bot.id))
        model.runRoutine(routine.id)
        await model.routineStarted()
        #expect(model.isRoutineQueued(routine.id))

        model.routines[0].setEnabled(false)
        #expect(model.queuedRoutines.isEmpty)
        await gate.open()
        await waitUntilIdle(model, bot.id)
        try await Task.sleep(for: .milliseconds(20)) // finishing the question is what would have started it, and that is synchronous
        #expect(model.routines[0].runs.isEmpty)
        #expect(await stub.calls.count == 1)
    }

    // MARK: Report file

    @Test @MainActor func theReportIsSavedInTheOrbsOwnFolderAndTheNoticeSaysWhere() async throws {
        let folder = root.appending(path: "pasta do orb")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (model, bot, routine) = setUp(folder: folder)

        model.runRoutine(routine.id)
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)

        let run = try #require(model.routines[0].runs.first)
        let path = try #require(run.reportFile)
        #expect(path.hasPrefix("Rotinas/Resumo da manhã/") && path.hasSuffix(".md"))
        let stamp = RoutineReport.stamp(run.date)
        #expect(path == "Rotinas/Resumo da manhã/\(stamp).md")
        let saved = try String(contentsOf: folder.appending(path: path), encoding: .utf8)
        #expect(saved.contains("Tudo em ordem.\nNada mais a relatar."))
        #expect(saved.hasPrefix("# Resumo da manhã"))
        let line = try #require(notices(model.transcript(bot.id)).last)
        #expect(line.contains(path))
    }

    @Test @MainActor func thereIsNoReportFileWhenTheOrbWorksInTheHomeFolder() async throws {
        // A temporary folder stands in for the home folder: the test never reads or writes the real one.
        let home = root.appending(path: "casa")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let (model, bot, routine) = setUp(folder: home)
        model.homeFolder = home

        model.runRoutine(routine.id)
        await model.routineStarted()
        await waitUntilIdle(model, bot.id)

        #expect(model.routines[0].runs.first?.succeeded == true)
        #expect(model.routines[0].runs.first?.reportFile == nil)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "Rotinas").path))
        #expect(notices(model.transcript(bot.id)).last?.contains("relatório") == false)
    }

    @Test func aSecondReportInTheSameMinuteGetsANumberAndNamesAreMadeSafe() throws {
        let folder = root.appending(path: "orb")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let one = try #require(RoutineReport.write("a", routine: "Diária", orb: "Atlas", date: date, in: folder))
        let two = try #require(RoutineReport.write("b", routine: "Diária", orb: "Atlas", date: date, in: folder))
        #expect(one != two && two.hasSuffix(" (2).md"))
        #expect(try String(contentsOf: folder.appending(path: one), encoding: .utf8).contains("a"))

        #expect(RoutineReport.safeName("../../etc/passwd") == "-..-etc-passwd")
        #expect(!RoutineReport.safeName("a/b:c").contains("/") && !RoutineReport.safeName("a/b:c").contains(":"))
        #expect(RoutineReport.safeName("   ") == "Rotina" && RoutineReport.safeName("...") == "Rotina")
        #expect(RoutineReport.safeName(String(repeating: "n", count: 200)).count == 60)
    }

    // MARK: Pieces

    @Test func theFirstLineOfAReportLosesItsMarkdownAndIsShort() {
        #expect(RoutineRun.firstLine(of: "\n\n## Resumo\nresto") == "Resumo")
        #expect(RoutineRun.firstLine(of: "**Tudo certo** hoje\nmais") == "Tudo certo hoje")
        #expect(RoutineRun.firstLine(of: "   \n\n") == nil && RoutineRun.firstLine(of: nil) == nil)
        #expect((RoutineRun.firstLine(of: String(repeating: "a", count: 500))?.count ?? 0) <= RoutineRun.summaryLimit)
    }

    @Test func aBannerShowsTheStartOfAReplyOnOneLineWithoutMarkdown() {
        #expect(RoutineRun.preview(of: "## Resumo\n\n**Tudo certo** hoje\n- item um") == "Resumo Tudo certo hoje item um")
        #expect(RoutineRun.preview(of: "Feito.") == "Feito.")
        let long = RoutineRun.preview(of: String(repeating: "palavra ", count: 100))
        #expect(long.count <= 180 && long.hasSuffix("…") && !long.contains("\n"))
    }

    @Test func aNewRunKeepsTheTranscriptButStartsTheModelFromScratch() {
        var old = Conversation()
        old.messages = [.user("antiga")]
        old.summary = "resumo"
        old.summaryCoveredCount = 1
        old.workspaceHash = "h"
        old.memorySavedCount = 3
        old.items = [TranscriptItem(.notice(Conversation.routineRunMarker + "ontem")), TranscriptItem(.user(text: "p", attachments: []))]

        let next = old.startingRoutineRun(at: .now)
        #expect(next.messages.isEmpty && next.summary == nil && next.summaryCoveredCount == nil)
        #expect(next.workspaceHash == nil && next.memorySavedCount == nil)
        #expect(next.items.count == 3) // what was there, and the marker of this run
    }

    @Test func olderRunsAreCutAtARunBoundary() {
        var conversation = Conversation()
        for run in 0..<5 {
            conversation.items.append(TranscriptItem(.notice(Conversation.routineRunMarker + "\(run)")))
            conversation.items.append(TranscriptItem(.user(text: "p\(run)", attachments: [])))
        }
        let next = conversation.startingRoutineRun(at: .now, keepingRuns: 2)
        let marked = next.items.compactMap { item -> String? in
            if case .notice(let text) = item.kind, text.hasPrefix(Conversation.routineRunMarker) { text } else { nil }
        }
        #expect(marked.count == 3) // the last two and the new one
        #expect(marked[0].hasSuffix("3") && marked[1].hasSuffix("4"))
        if case .user(let text, _) = next.items[1].kind { #expect(text == "p3") } else { Issue.record("cut in the middle of a run") }
    }
}

/// Counts what the app asked of macOS instead of asking it.
@MainActor private final class FakeActivity: ActivityAsserting {
    final class Token: NSObject {
        let level: ActivityLevel
        let reason: String
        init(_ level: ActivityLevel, _ reason: String) {
            self.level = level
            self.reason = reason
        }
    }

    private(set) var began: [Token] = []
    private(set) var ended = 0
    var open: [Token] { began.filter { token in !finished.contains { $0 === token } } }
    private var finished: [Token] = []

    func begin(_ level: ActivityLevel, reason: String) -> any NSObjectProtocol {
        let token = Token(level, reason)
        began.append(token)
        return token
    }

    func end(_ token: any NSObjectProtocol) {
        ended += 1
        if let token = token as? Token { finished.append(token) }
    }
}
