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

/// Routines run in a conversation of their own, unattended, one at a time per Orb.
@Suite final class RoutineTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbRoutines-\(UUID().uuidString)")
    private var savedNotify: Any?

    init() {
        // No banner from the test process.
        savedNotify = UserDefaults.standard.object(forKey: "notifyWhenDone")
        UserDefaults.standard.set(false, forKey: "notifyWhenDone")
    }

    deinit {
        if let savedNotify { UserDefaults.standard.set(savedNotify, forKey: "notifyWhenDone") }
        else { UserDefaults.standard.removeObject(forKey: "notifyWhenDone") }
        try? FileManager.default.removeItem(at: root)
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

    @MainActor private func waitUntilIdle(_ model: AppModel, _ botID: UUID) async {
        try? await Task.sleep(for: .milliseconds(20))
        for _ in 0..<400 where model.isWorking(botID) || model.turns[botID] != nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func notices(_ items: [TranscriptItem]) -> [String] {
        items.compactMap { if case .notice(let text) = $0.kind { text } else { nil } }
    }

    private func text(_ message: ChatMessage) -> String { message.content }

    // MARK: Its own conversation

    @Test @MainActor func aRoutineRunsInItsOwnConversationNotInYourChat() async throws {
        let (model, bot, routine) = setUp()
        let before = model.transcript(bot.id)

        model.runRoutine(routine.id)
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

    @Test @MainActor func theRunIsRecordedInTheRoutinesHistory() async throws {
        let (model, bot, routine) = setUp()
        model.runRoutine(routine.id)
        await waitUntilIdle(model, bot.id)

        let saved = try #require(model.routines.first)
        let run = try #require(saved.runs.first)
        #expect(saved.runs.count == 1 && run.succeeded)
        #expect(run.summary == "Tudo em ordem.")
        #expect(run.report == "Tudo em ordem.\nNada mais a relatar.")
        #expect(run.reportFile != nil) // the Orb has a folder of its own
        #expect(saved.lastRun != nil && saved.lastResult?.hasPrefix("Tudo em ordem.") == true)
    }

    @Test @MainActor func theHistoryKeepsTheLastRunsAndEachRunStartsFromScratch() async throws {
        let stub = StubModel()
        let (model, bot, routine) = setUp(stub)
        for _ in 0..<(Routine.keptRuns + 2) {
            model.runRoutine(routine.id)
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
        #expect(model.permissionState(of: bot.id)?.mode == .readOnly) // what the engine reads at every tool call
        await waitUntilIdle(model, bot.id)

        #expect(model.permissionState(of: bot.id)?.mode == .ask)
        #expect(model.bot(bot.id)?.permissionMode == .ask) // the Orb's own setting never changed
    }

    @Test @MainActor func withoutAnOverrideTheRoutineUsesTheOrbsMode() async throws {
        let (model, bot, routine) = setUp()
        model.update(bot.id) { $0.permissionMode = .auto }
        model.runRoutine(routine.id)
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
        model.runRoutine(routine.id) // due again on the next check: still one
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

    @Test @MainActor func twoRoutinesOfTheSameOrbTakeTurns() async throws {
        let (model, bot, first) = setUp()
        let second = Routine(name: "Outra", botID: bot.id, prompt: "faça outra coisa", schedule: .daily(hour: 8, minute: 0))
        model.routines.append(second)

        model.runRoutine(first.id)
        model.runRoutine(second.id)
        #expect(model.queuedRoutines == [second.id])
        await waitUntilIdle(model, bot.id)

        #expect(model.routines.map(\.runs.count) == [1, 1])
        #expect(model.queuedRoutines.isEmpty)
    }

    @Test @MainActor func aRoutineQueuedForAnOrbThatIsDeletedNeverRuns() async throws {
        let gate = Gate()
        let (model, bot, routine) = setUp(StubModel(gate: gate))
        #expect(model.send("pergunta", to: bot.id))
        model.runRoutine(routine.id)
        #expect(model.queuedRoutines.count == 1)

        model.deleteBot(bot.id)
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.queuedRoutines.isEmpty && model.routines.isEmpty)
    }

    @Test @MainActor func deletingARoutineRemovesItFromTheQueueAndItsConversation() async throws {
        let (model, bot, routine) = setUp()
        model.runRoutine(routine.id)
        await waitUntilIdle(model, bot.id)
        #expect(store.readRoutineConversation(routine: routine.id, for: bot.id).value != nil)

        model.deleteRoutine(routine.id)
        #expect(model.routines.isEmpty)
        #expect(store.readRoutineConversation(routine: routine.id, for: bot.id).value == nil)
    }

    // MARK: Your chat is safe

    @Test @MainActor func stoppingARoutineGivesTheChatBackAndRecordsAFailedRun() async throws {
        let gate = Gate()
        let (model, bot, routine) = setUp(StubModel(gate: gate))
        model.runRoutine(routine.id)
        #expect(model.isRoutineRunning(routine.id))
        try await Task.sleep(for: .milliseconds(50))

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
        await waitUntilIdle(model, bot.id)

        let run = try #require(model.routines[0].runs.first)
        #expect(!run.succeeded && run.summary.hasPrefix("Não deu certo"))
        #expect(model.routines[0].lastResult == "Não terminou: veja a conversa.")
        #expect(model.transcript(bot.id).count == 3)
    }

    @Test @MainActor func aRoutineWithoutAModelDoesNotRunAndLeavesTheChatAlone() throws {
        let (model, bot, routine) = setUp()
        model.providers = []
        model.defaultModel = ""
        let before = model.transcript(bot.id)

        model.runRoutine(routine.id)

        #expect(!model.isWorking(bot.id) && model.turns[bot.id] == nil)
        #expect(model.transcript(bot.id).count == before.count)
        let run = try #require(model.routines[0].runs.first)
        #expect(!run.succeeded && run.summary == "Não rodou: conecte um modelo em Ajustes.")
        #expect(model.routines[0].lastRun != nil) // not retried every 30 seconds
        #expect(model.queuedRoutines.isEmpty)
    }

    @Test @MainActor func newConversationDuringARoutineArchivesTheChatAndLetsTheRoutineFinish() async throws {
        let gate = Gate()
        let (model, bot, routine) = setUp(StubModel(gate: gate))
        model.runRoutine(routine.id)
        try await Task.sleep(for: .milliseconds(50))

        model.newConversation(bot.id)
        #expect(model.isRoutineRunning(routine.id)) // not stopped
        #expect(model.transcript(bot.id).isEmpty)
        #expect(store.readArchive(bot.id).map(\.title) == ["oi"])

        await gate.open()
        await waitUntilIdle(model, bot.id)
        #expect(model.routines[0].runs.first?.succeeded == true)
        #expect(notices(model.transcript(bot.id)).count == 1) // the new chat has the line, not the old one
        model.saveNow()
        #expect(store.loadConversation(bot.id)?.archiveTitle == "Conversa sem título") // the file holds the new chat
    }

    @Test @MainActor func whileARoutineRunsTheChatOnDiskIsNotTouched() async throws {
        let gate = Gate()
        let (model, bot, routine) = setUp(StubModel(gate: gate))
        model.runRoutine(routine.id)
        try await Task.sleep(for: .milliseconds(80))
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
        await first.open()
        for _ in 0..<200 where !model.isRoutineRunning(routine.id) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.isRoutineRunning(routine.id)) // the routine took the Orb the moment the question was answered

        model.saveNow() // as on quit, in the middle of the run
        let chatFile = try #require(store.loadConversation(bot.id))
        #expect(chatFile.items.contains { if case .user(let t, _) = $0.kind { t == "pergunta do usuário" } else { false } })
        #expect(chatFile.items.contains { if case .bot(let t, _) = $0.kind { t.hasPrefix("Tudo em ordem") } else { false } })
        #expect(!chatFile.items.contains { if case .user(let t, _) = $0.kind { t == "resuma os arquivos novos" } else { false } })
        await later.open()
        await waitUntilIdle(model, bot.id)
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
        #expect(model.queuedRoutines == [routine.id])

        model.routines[0].botID = other.id
        for _ in 0..<200 where !model.isRoutineRunning(routine.id) { try await Task.sleep(for: .milliseconds(10)) }
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
        #expect(model.isRoutineQueued(routine.id))

        model.routines[0].setEnabled(false)
        #expect(model.queuedRoutines.isEmpty)
        await gate.open()
        await waitUntilIdle(model, bot.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.routines[0].runs.isEmpty)
        #expect(await stub.calls.count == 1)
    }

    // MARK: Report file

    @Test @MainActor func theReportIsSavedInTheOrbsOwnFolderAndTheNoticeSaysWhere() async throws {
        let folder = root.appending(path: "pasta do orb")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (model, bot, routine) = setUp(folder: folder)

        model.runRoutine(routine.id)
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

    @Test func aNewRunKeepsTheTranscriptButStartsTheModelFromScratch() {
        var old = Conversation()
        old.messages = [.user("antiga")]
        old.summary = "resumo"
        old.summaryCoveredCount = 1
        old.claudeSessionID = "abc"
        old.workspaceHash = "h"
        old.memorySavedCount = 3
        old.items = [TranscriptItem(.notice(Conversation.routineRunMarker + "ontem")), TranscriptItem(.user(text: "p", attachments: []))]

        let next = old.startingRoutineRun(at: .now)
        #expect(next.messages.isEmpty && next.summary == nil && next.summaryCoveredCount == nil)
        #expect(next.claudeSessionID == nil && next.workspaceHash == nil && next.memorySavedCount == nil)
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
