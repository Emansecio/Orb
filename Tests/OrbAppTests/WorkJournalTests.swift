import Foundation
import Testing
@testable import Orb

// What the app was doing when it closed (`WorkJournal`): kept on disk while it is in flight, removed when it ends or the person stops
// it, left alone by a quit, and taken up again once at the next launch (`AppModel.resumeInterruptedWork`).

@Suite final class WorkJournalTests {
    private let root = TempFolder("OrbWorkJournal", creating: true)
    private let suite = "OrbWorkJournal-\(UUID().uuidString)"

    init() { QuietNotifications.hold() }

    deinit {
        store.flush() // the journal's own writes end before the folder goes
        QuietNotifications.release()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private var store: Store { Store(directory: root.url) }

    /// What is on disk now.
    private func onDisk() -> WorkJournalFile {
        store.flush()
        return store.readWorkJournal().value ?? WorkJournalFile()
    }

    private func writeState(bots names: [String]) {
        var state = AppState(bots: names.map { Bot(name: $0, role: "Papel de \($0)", orb: OrbConfig()) })
        state.bots = state.bots.map { bot in
            var bot = bot
            bot.workingDirectory = root.url.path
            return bot
        }
        store.save(state)
        store.flush()
    }

    /// An app over the folder, with a model that answers from `script`. A fresh one is "the next launch".
    @MainActor private func launch(_ script: CallScript) -> AppModel {
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.preferences = UserDefaults(suiteName: suite) ?? .standard
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = { CallScriptModel(script: script) }
        return model
    }

    /// The first call of the script waits until `release()`: the turn is in flight for as long as the test wants.
    private func held() -> CallScript {
        CallScript([[.text("Pronto."), .finished(.done, nil)]], holdsCall: 1)
    }

    @MainActor private func continuations(_ model: AppModel, _ bot: Bot) -> [String] {
        model.transcript(bot.id).compactMap { item in
            if case .user(let text, _) = item.kind, text.hasPrefix(NoticeAction.continueMessage) { text } else { nil }
        }
    }

    // MARK: The file

    @Test func theJournalRoundTripsAndReadsATolerantFile() throws {
        let envelope = OrbEnvelope(kind: .ask, from: OrbRef(id: UUID(), name: "Atlas"), to: OrbRef(id: UUID(), name: "Revisor"),
                                   text: "Revise o texto")
        let file = WorkJournalFile(entries: [
            WorkEntry(kind: .chatTask, startedAt: Date(timeIntervalSince1970: 100), botID: UUID(), chatID: UUID()),
            WorkEntry(kind: .groupRun, startedAt: Date(timeIntervalSince1970: 200), groupID: UUID(), runID: UUID(), text: "Lancem"),
            WorkEntry(kind: .request, startedAt: Date(timeIntervalSince1970: 300), envelope: envelope),
        ], lastLaunch: Date(timeIntervalSince1970: 400), cleanQuit: false, recentCrashLaunches: [Date(timeIntervalSince1970: 400)])
        let again = try JSONDecoder().decode(WorkJournalFile.self, from: JSONEncoder().encode(file))
        #expect(again == file)

        // A kind this version does not know, a broken entry and missing keys: the file still reads, the rest is kept.
        let id = UUID().uuidString
        let json = """
        {"entries":[{"id":"\(id)","kind":"viagem","startedAt":0},{"kind":"chatTask"},{"oops":1},
                    {"kind":"chatTask","botID":"\(UUID().uuidString)","chatID":"\(UUID().uuidString)","startedAt":5}]}
        """
        let tolerant = try JSONDecoder().decode(WorkJournalFile.self, from: Data(json.utf8))
        #expect(tolerant.cleanQuit && tolerant.lastLaunch == nil && tolerant.recentCrashLaunches.isEmpty)
        #expect(tolerant.entries.count == 4)
        #expect(tolerant.entries[0].kind == .unknown && tolerant.entries[0].resumes == 0)
        #expect(tolerant.entries[3].kind == .chatTask && tolerant.entries[3].botID != nil)
        #expect(try JSONDecoder().decode(WorkJournalFile.self, from: Data("{}".utf8)) == WorkJournalFile())
    }

    @Test @MainActor func aFileThatCannotBeReadStartsEmpty() throws {
        try Data("não é json".utf8).write(to: root.appending(Store.workJournalFileName))
        let journal = WorkJournal(store: store)
        #expect(journal.entries.isEmpty)
        #expect(journal.beginLaunch().isEmpty)
    }

    // MARK: The journal alone

    @Test @MainActor func requestsOfGroupsAndNestedOnesAreNotKept() {
        let journal = WorkJournal(store: store)
        let from = OrbRef(id: UUID(), name: "Atlas"), to = OrbRef(id: UUID(), name: "Revisor")
        var envelope = OrbEnvelope(kind: .ask, from: from, to: to, text: "a")
        journal.requestBegan(envelope)
        journal.requestBegan(envelope) // the same message twice is one entry
        #expect(journal.entries.count == 1)

        var grouped = OrbEnvelope(kind: .ask, from: from, to: to, text: "b")
        grouped.groupID = UUID()
        var nested = OrbEnvelope(kind: .ask, from: from, to: to, text: "c")
        nested.servingRequest = UUID()
        var inRoutine = OrbEnvelope(kind: .ask, from: from, to: to, text: "d")
        inRoutine.servingRoutine = UUID()
        envelope.kind = .tell
        for other in [grouped, nested, inRoutine, envelope] { journal.requestBegan(other) }
        #expect(journal.entries.count == 1)

        journal.syncRequests(open: [])
        #expect(journal.entries.isEmpty)
    }

    @Test @MainActor func aQuitFreezesTheJournalAndNotesTheLostJobs() {
        let journal = WorkJournal(store: store)
        let bot = UUID(), chat = UUID()
        journal.chatTaskBegan(bot: bot, chat: chat)
        journal.freeze(lostJobs: [bot: 2])
        journal.chatTaskEnded(bot: bot) // the turns that end while quitting
        journal.syncRequests(open: [])
        journal.syncGroupRuns([])
        #expect(journal.entries.count == 1 && journal.entries[0].lostJobs == 2)
        #expect(onDisk().entries.first?.lostJobs == 2)
        #expect(AppModel.resumeMessage(lostJobs: 2).contains("2 processo(s) em segundo plano"))
        #expect(AppModel.resumeMessage(lostJobs: 0) == NoticeAction.continueMessage(after: BotSession.quitNotice))
    }

    @Test @MainActor func aGroupRunWaitingToResumeSurvivesAnotherGroupOpeningFirst() {
        let now = Date(timeIntervalSince1970: 10_000)
        let a = OrbGroup(name: "A", memberIDs: [], orchestratorID: UUID()), b = OrbGroup(name: "B", memberIDs: [], orchestratorID: UUID())
        let oldA = GroupRun.new(group: a, request: "a", now: now), oldB = GroupRun.new(group: b, request: "b", now: now)
        store.saveWorkJournal(WorkJournalFile(entries: [
            WorkEntry(kind: .groupRun, startedAt: now, groupID: a.id, runID: oldA.id, text: "a"),
            WorkEntry(kind: .groupRun, startedAt: now, groupID: b.id, runID: oldB.id, text: "b")], lastLaunch: now, cleanQuit: true))
        store.flush()
        let journal = WorkJournal(store: store)
        #expect(journal.beginLaunch(now: now.addingTimeInterval(60)).count == 2)
        // The hub resumes group A first: B's entry (resumes == 1) must not be dropped by the sync.
        journal.syncGroupRuns([GroupRun.new(group: a, request: "a", now: now, id: oldA.id)])
        #expect(journal.entries.count == 2 && journal.entries.allSatisfy { $0.resumes == 1 })
        journal.syncGroupRuns([GroupRun.new(group: a, request: "a", now: now, id: oldA.id), GroupRun.new(group: b, request: "b", now: now, id: oldB.id)])
        #expect(journal.entries.count == 2 && journal.entries.allSatisfy { $0.resumes == 1 })
        // Once resumed, a group with no open run is over as before.
        journal.syncGroupRuns([GroupRun.new(group: a, request: "a", now: now, id: oldA.id)])
        #expect(journal.entries.count == 1)
    }

    // MARK: The guard against a loop of crashes

    @Test @MainActor func aSingleCrashStillResumesButTwoInTenMinutesDoNot() {
        let now = Date(timeIntervalSince1970: 10_000)
        func seed(crashes: [Date], clean: Bool) {
            let entry = WorkEntry(kind: .chatTask, startedAt: now, botID: UUID(), chatID: UUID())
            store.saveWorkJournal(WorkJournalFile(entries: [entry], lastLaunch: now.addingTimeInterval(-30), cleanQuit: clean,
                                                  recentCrashLaunches: crashes))
            store.flush()
        }
        seed(crashes: [], clean: true)
        #expect(WorkJournal(store: store).beginLaunch(now: now).count == 1)

        seed(crashes: [], clean: false) // one crash: this launch is the first one found
        #expect(WorkJournal(store: store).beginLaunch(now: now).count == 1)
        #expect(onDisk().recentCrashLaunches == [now])

        seed(crashes: [now.addingTimeInterval(-120)], clean: false) // the second within ten minutes
        let looping = WorkJournal(store: store)
        #expect(looping.beginLaunch(now: now).isEmpty)
        #expect(looping.entries.isEmpty && onDisk().entries.isEmpty)
        #expect(onDisk().recentCrashLaunches.count == 2)

        seed(crashes: [now.addingTimeInterval(-3_600)], clean: false) // the old one is out of the window
        #expect(WorkJournal(store: store).beginLaunch(now: now).count == 1)
    }

    @Test @MainActor func aCleanQuitIsRememberedAndAnEntryResumedOnceIsDropped() {
        let now = Date(timeIntervalSince1970: 10_000)
        let journal = WorkJournal(store: store)
        #expect(journal.beginLaunch(now: now).isEmpty)
        #expect(!onDisk().cleanQuit && onDisk().lastLaunch == now)
        journal.markCleanQuit()
        #expect(onDisk().cleanQuit)

        let spent = WorkEntry(kind: .chatTask, startedAt: now, resumes: 1, botID: UUID(), chatID: UUID())
        let unknown = WorkEntry(kind: .unknown, startedAt: now)
        store.saveWorkJournal(WorkJournalFile(entries: [spent, unknown], lastLaunch: now, cleanQuit: true))
        store.flush()
        let next = WorkJournal(store: store)
        #expect(next.beginLaunch(now: now.addingTimeInterval(60)).isEmpty)
        #expect(onDisk().entries.isEmpty)
    }

    // MARK: An Orb's own task

    @Test @MainActor func aTurnIsRecordedWhileItRunsAndForgottenWhenItEnds() async throws {
        writeState(bots: ["Atlas"])
        let script = held()
        let model = launch(script)
        let atlas = model.bots[0]
        #expect(model.send("faça isso", to: atlas.id))
        let entry = try #require(model.workJournal.entries.first)
        #expect(entry.kind == .chatTask && entry.botID == atlas.id && entry.chatID == atlas.id && entry.resumes == 0)
        #expect(onDisk().entries.map(\.id) == [entry.id])

        await script.release()
        await waitUntil("the turn to end") { model.session(atlas.id).turnTask == nil && !model.isWorking(atlas.id) }
        #expect(model.workJournal.entries.isEmpty)
        #expect(onDisk().entries.isEmpty)
    }

    @Test @MainActor func parandoAnEntryGoesAway() async throws {
        writeState(bots: ["Atlas"])
        let script = held()
        let model = launch(script)
        let atlas = model.bots[0]
        #expect(model.send("faça isso", to: atlas.id))
        #expect(model.workJournal.entries.count == 1)
        model.stop(atlas.id)
        #expect(model.workJournal.entries.isEmpty && onDisk().entries.isEmpty)
        await script.release()
    }

    @Test @MainActor func aRoutinesRunIsNotRecorded() async throws {
        writeState(bots: ["Atlas"])
        let script = CallScript([[.text("Feito."), .finished(.done, nil)]])
        let model = launch(script)
        let atlas = model.bots[0]
        model.session(atlas.id).startRoutineRun(UUID(), conversation: Conversation(), at: .now)
        #expect(model.send("rotina", to: atlas.id))
        #expect(model.workJournal.entries.isEmpty)
        await waitUntil("the run to end") { model.session(atlas.id).turnTask == nil }
    }

    @Test @MainActor func quittingKeepsTheTaskAndTheNextLaunchGoesOnWithItOnce() async throws {
        writeState(bots: ["Atlas"])
        let first = held()
        let before = launch(first)
        let atlas = before.bots[0]
        #expect(before.send("faça isso", to: atlas.id))
        before.stopTurnsForQuit()
        before.saveNow()
        #expect(before.workJournal.entries.count == 1)
        #expect(onDisk().entries.count == 1)
        await first.release()

        // The next launch: the conversation says the app closed, and the Orb goes on by itself.
        let second = CallScript([[.text("Continuei."), .finished(.done, nil)]], holdsCall: 1)
        let after = launch(second)
        let resumed = try #require(after.resumeInterruptedWork())
        await resumed.value
        await waitUntil("the continuation to reach the model") { await second.calls.count == 1 }
        #expect(continuations(after, atlas).count == 1)
        #expect(continuations(after, atlas).first?.contains("O app fechou no meio da tarefa") == true)
        #expect(after.workJournal.entries.first?.resumes == 1)

        // Quit again in the middle of the resumed turn: the entry stays, but it has been resumed already.
        after.stopTurnsForQuit()
        after.saveNow()
        await second.release()
        #expect(onDisk().entries.first?.resumes == 1)

        let third = CallScript([[.text("Não devia."), .finished(.done, nil)]])
        let last = launch(third)
        #expect(last.resumeInterruptedWork() == nil)
        #expect(last.workJournal.entries.isEmpty && onDisk().entries.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await third.calls.isEmpty)
        #expect(continuations(last, atlas).count == 1, "only the first resume wrote 'continua'; the notice's own button stays")
    }

    @Test @MainActor func aResumedTurnThatEndsLeavesNothingBehind() async throws {
        writeState(bots: ["Atlas"])
        let first = held()
        let before = launch(first)
        let atlas = before.bots[0]
        #expect(before.send("faça isso", to: atlas.id))
        before.stopTurnsForQuit()
        before.saveNow()
        await first.release()

        let second = CallScript([[.text("Continuei."), .finished(.done, nil)]])
        let after = launch(second)
        await after.resumeInterruptedWork()?.value
        await waitUntil("the resumed turn to end") { after.session(atlas.id).turnTask == nil && after.workJournal.entries.isEmpty }
        #expect(onDisk().entries.isEmpty)
    }

    @Test @MainActor func nobodyIsWokenWhenThePersonWroteAfterTheCut() async throws {
        writeState(bots: ["Atlas"])
        let first = held()
        let before = launch(first)
        let atlas = before.bots[0]
        #expect(before.send("faça isso", to: atlas.id))
        before.stopTurnsForQuit()
        before.saveNow()
        await first.release()

        // The person already answered in the chat (the conversation no longer ends on the cut): the task is not restarted.
        let answered = launch(CallScript([[.text("ok"), .finished(.done, nil)]]))
        answered.session(atlas.id).ensureLoaded()
        answered.session(atlas.id).append(.user(text: "deixa pra lá", attachments: []))
        await answered.resumeInterruptedWork()?.value
        #expect(continuations(answered, atlas).isEmpty)
        #expect(answered.workJournal.entries.isEmpty)
    }

    // MARK: A group's request

    @Test @MainActor func aGroupRequestIsKeptAndTheNextLaunchWakesTheOrchestrator() async throws {
        let world = GroupWorld()
        world.model.postUserMessage("Lancem o produto", to: world.groupID)
        let run = try #require(world.hub.activeRun(world.groupID))
        let entry = try #require(world.model.workJournal.entries.first)
        #expect(entry.kind == .groupRun && entry.groupID == world.groupID && entry.runID == run.id && entry.text == "Lancem o produto")
        // An assignment that was open when the app closed.
        world.session.append(.orbMessage(OrbMessageItem(direction: .post, kind: .ask, state: .open, from: OrbRef(world.atlas),
                                                        to: OrbRef(world.pesquisador), text: "Levante os preços", requestID: UUID(),
                                                        chainID: run.id, groupID: world.groupID)))
        world.model.stopTurnsForQuit()
        world.model.saveNow()
        #expect(world.model.workJournal.entries.count == 1, "quitting keeps the run")
        world.store.flush()

        // The next launch.
        let again = AppModel(store: world.store, runsBackgroundWork: false)
        let fake = FakeDelegationService()
        let hub = GroupHub(model: again, delegation: fake)
        hub.settle = .zero
        again.groupHub = hub
        for bot in again.bots { fake.names[bot.id] = bot.name }
        await again.resumeInterruptedWork()?.value

        let turn = try #require(fake.groupTurns.first)
        #expect(fake.groupTurns.count == 1 && turn.envelope.to.id == world.atlas.id, "the orchestrator is woken")
        #expect(turn.envelope.text.hasPrefix("The app closed during this request. Assignments marked lost: Pesquisador: Levante os preços."))
        #expect(turn.envelope.text.hasSuffix("Check what is already done, then reassign what is left."))
        let thread = again.groupSession(world.groupID)?.items ?? []
        #expect(thread.contains { if case .notice(let text) = $0.kind { text == AppModel.groupResumedNotice } else { false } })
        #expect(hub.activeRun(world.groupID)?.request == "Lancem o produto")
        let resumed = try #require(again.workJournal.entries.first)
        #expect(resumed.kind == .groupRun && resumed.resumes == 1)
        #expect(resumed.runID == hub.activeRun(world.groupID)?.id, "the entry follows the new run")
        #expect(hub.activeRun(world.groupID)?.id == run.id, "the resumed run keeps its id: each member finds its worktree again")

        // Stopping the group removes it.
        hub.stopGroup(world.groupID)
        #expect(again.workJournal.entries.isEmpty)
        again.saveNow()
        #expect(onDiskOf(world.store).entries.isEmpty)
    }

    @Test @MainActor func anAssignmentCancelledByTheCloseIsStillReportedAsLostOnResume() async throws {
        let world = GroupWorld()
        world.model.postUserMessage("Lancem o produto", to: world.groupID)
        let run = try #require(world.hub.activeRun(world.groupID))
        // `stopTurnsForQuit` cancels the chain, so the thread is saved with the assignment `.cancelled`, not `.open`.
        world.session.append(.orbMessage(OrbMessageItem(direction: .post, kind: .ask, state: .cancelled, from: OrbRef(world.atlas),
                                                        to: OrbRef(world.pesquisador), text: "Levante os preços", requestID: UUID(),
                                                        chainID: run.id, groupID: world.groupID)))
        world.model.stopTurnsForQuit()
        world.model.saveNow()
        world.store.flush()

        let again = AppModel(store: world.store, runsBackgroundWork: false)
        let fake = FakeDelegationService()
        let hub = GroupHub(model: again, delegation: fake)
        hub.settle = .zero
        again.groupHub = hub
        for bot in again.bots { fake.names[bot.id] = bot.name }
        await again.resumeInterruptedWork()?.value

        let turn = try #require(fake.groupTurns.first)
        #expect(turn.envelope.text.contains("Assignments marked lost: Pesquisador: Levante os preços."))
    }

    private func onDiskOf(_ store: Store) -> WorkJournalFile {
        store.flush()
        return store.readWorkJournal().value ?? WorkJournalFile()
    }

    @Test @MainActor func aGroupRequestThatEndsOrIsStoppedLeavesTheJournal() async throws {
        let world = GroupWorld()
        world.model.postUserMessage("Lancem", to: world.groupID)
        #expect(world.model.workJournal.entries.count == 1)
        world.hub.stopGroup(world.groupID)
        #expect(world.model.workJournal.entries.isEmpty)
        #expect(onDiskOf(world.store).entries.isEmpty)
    }

    // MARK: A request between Orbs

    @Test @MainActor func aRequestIsKeptAndSentAgainAfterTheCloseWithANote() async throws {
        writeState(bots: ["Atlas", "Pesquisador"])
        let before = launch(held())
        let atlas = before.bots[0], pesquisador = before.bots[1]
        let messageID = UUID()
        let sent = try before.delegation.submit(from: atlas.id, to: "Pesquisador", text: "Levante os preços", kind: .ask,
                                                messageID: messageID, groupID: nil)
        let entry = try #require(before.workJournal.entries.first)
        #expect(entry.kind == .request && entry.envelope?.id == sent.id && entry.envelope?.text == "Levante os preços")
        // Quit before the target begins: the entry stays.
        before.stopTurnsForQuit()
        before.saveNow()
        #expect(onDisk().entries.map(\.envelope?.id) == [sent.id])

        let script = CallScript([[.text("Preços levantados."), .finished(.done, nil)]], whenExhausted: .reply(.say("fim")))
        let after = launch(script)
        await after.resumeInterruptedWork()?.value
        await waitUntil("the request to be answered") { after.delegation.requests[sent.id]?.state == .replied }
        let calls = await script.calls
        let asked = calls.first?.messages.last { $0.role == .user }?.content ?? ""
        #expect(asked.contains("Resumed after the app closed: check what is already done"))
        #expect(asked.contains("Levante os preços"))
        #expect(after.delegation.requests[sent.id]?.envelope.to.id == pesquisador.id)
        // Answered, so over: nothing left to resume, and the asker's chat is woken by the answer as it always is.
        await waitUntil("the journal to empty") { after.workJournal.entries.isEmpty }
        #expect(onDisk().entries.isEmpty)
    }

    @Test(.enabled(if: WorkFolders.Git.make() != nil)) @MainActor func aRequestThatCannotBeResumedCleansUpItsWorktree() async throws {
        writeState(bots: ["Pesquisador"])
        let project = root.url.appending(path: "projeto")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "um\n".write(to: project.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let tool = try #require(WorkFolders.Git.make())
        let identity = ["-c", "user.name=Teste", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]
        for arguments in [["init", "-b", "main"], ["add", "-A"], ["commit", "-m", "primeiro"]] {
            #expect(await tool.run(identity + arguments, in: project).succeeded)
        }
        // The asker was deleted while the app was closed: the request cannot be sent again, and its worktree (made before the
        // close, already merged) would stay forever.
        var envelope = OrbEnvelope(kind: .ask, from: OrbRef(id: UUID(), name: "Apagado"), to: OrbRef(id: UUID(), name: "Pesquisador"),
                                   text: "Levante os preços")
        envelope.folder = project.path
        let made = await WorkFolders.prepare(project: project, member: "Pesquisador", run: envelope.id, root: WorkFolders.root(in: root.url))
        #expect(made.branch != nil && FileManager.default.fileExists(atPath: made.url.path))
        let now = Date(timeIntervalSince1970: 10_000)
        store.saveWorkJournal(WorkJournalFile(entries: [WorkEntry(kind: .request, startedAt: now, envelope: envelope)],
                                              lastLaunch: now, cleanQuit: true))
        store.flush()

        let after = launch(held())
        await after.resumeInterruptedWork()?.value
        await waitUntil("the worktree to go") { !FileManager.default.fileExists(atPath: made.url.path) }
        let branches = await tool.run(["branch", "--format=%(refname:short)"], in: project)
        #expect(!branches.text.contains("orb/"))
        #expect(after.workJournal.entries.isEmpty)
    }

    @Test @MainActor func stoppingTheChainOrAnAnswerRemovesTheRequest() async throws {
        writeState(bots: ["Atlas", "Pesquisador"])
        let model = launch(held())
        let atlas = model.bots[0]
        let sent = try model.delegation.submit(from: atlas.id, to: "Pesquisador", text: "Levante os preços", kind: .ask,
                                               messageID: UUID(), groupID: nil)
        #expect(model.workJournal.entries.count == 1)
        model.delegation.cancelChain(sent.chainID, by: .user)
        #expect(model.workJournal.entries.isEmpty)
        #expect(onDisk().entries.isEmpty)
    }

    @Test @MainActor func aRequestToAnOrbThatIsGoneIsDropped() async throws {
        writeState(bots: ["Atlas", "Pesquisador"])
        let before = launch(held())
        let atlas = before.bots[0]
        let sent = try before.delegation.submit(from: atlas.id, to: "Pesquisador", text: "Levante os preços", kind: .ask,
                                                messageID: UUID(), groupID: nil)
        before.stopTurnsForQuit()
        before.saveNow()

        var state = store.readState().value ?? AppState.initial
        state.bots.removeAll { $0.id == sent.to.id }
        store.save(state)
        store.flush()
        let after = launch(CallScript([[.text("x"), .finished(.done, nil)]]))
        await after.resumeInterruptedWork()?.value
        #expect(after.delegation.requests[sent.id] == nil)
        #expect(after.workJournal.entries.isEmpty)
    }
}
