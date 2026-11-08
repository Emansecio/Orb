import Foundation
import Testing
@testable import Orb

// The pulse: an Orb waking by itself. A scripted model, an injected clock and a data folder of the test's own.

private actor PulseLog {
    private(set) var seen: [(who: String, user: String, tools: [String], toolResult: String?)] = []
    func record(_ who: String, _ user: String, _ tools: [String], _ toolResult: String?) { seen.append((who, user, tools, toolResult)) }
    func calls(by who: String) -> [(user: String, tools: [String])] { seen.filter { $0.who == who }.map { ($0.user, $0.tools) } }
    var count: Int { seen.count }
    func count(by who: String) -> Int { seen.filter { $0.who == who }.count }
}

private struct PulseBrain: LLMClient {
    let log: PulseLog
    let names: [String]
    /// Tokens every model call reports (input plus output).
    let tokens: Int
    let rule: @Sendable (_ who: String, _ user: String, _ toolResult: String?) async -> [LLMEvent]

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        let system = messages.first { $0.role == .system }?.content ?? ""
        let who = names.first { system.contains("You are \($0),") } ?? "?"
        let user = messages.last { $0.role == .user }?.content ?? ""
        let result = messages.last?.role == .tool ? messages.last?.content : nil
        let names = tools.map(\.name)
        let tokens = tokens
        return AsyncThrowingStream { continuation in
            Task {
                await log.record(who, user, names, result)
                let events = await rule(who, user, result)
                for event in events { continuation.yield(event) }
                let calls = events.contains { if case .toolCalls = $0 { true } else { false } }
                continuation.yield(.finished(calls ? .toolUse : .done, TokenUsage(input: tokens / 2, output: tokens - tokens / 2)))
                continuation.finish()
            }
        }
    }
}

private func say(_ text: String) -> [LLMEvent] { [.text(text)] }

private func ask(_ target: String, _ message: String) -> [LLMEvent] {
    let arguments = JSONValue.object(["action": .string("ask"), "to": .string(target), "message": .string(message)]).jsonString
    return [.toolCalls([ToolCallRequest(id: "c1", name: "orbs", arguments: arguments)])]
}

@MainActor
private final class PulseWorld {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbPulse-\(UUID().uuidString)")
    let suite = "OrbPulse-\(UUID().uuidString)"
    let model: AppModel
    let log = PulseLog()
    var bots: [Bot]
    /// The start of the injected clock: eight in the morning today, so the hours the tests add never cross midnight.
    let t0 = Calendar.current.startOfDay(for: .now).addingTimeInterval(8 * 3_600)

    init(names: [String] = ["Atlas", "Pesquisador", "Revisor"], tokens: Int = 1_000,
         rule: @escaping @Sendable (String, String, String?) async -> [LLMEvent]) {
        QuietNotifications.hold()
        let root = self.root
        bots = names.map { name in
            var bot = Bot(name: name, role: "Papel de \(name)", orb: OrbConfig())
            bot.permissionMode = .ask
            bot.workingDirectory = root.appending(path: "pasta-\(name)").path
            try? FileManager.default.createDirectory(atPath: bot.workingDirectory, withIntermediateDirectories: true)
            return bot
        }
        var state = AppState.initial
        state.bots = bots
        state.routines = []
        let store = Store(directory: root)
        store.save(state)
        for bot in bots { store.save(Conversation(), for: bot.id) }
        store.flush()
        model = AppModel(store: store, runsBackgroundWork: false)
        model.preferences = UserDefaults(suiteName: suite) ?? .standard
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = { [log] in PulseBrain(log: log, names: names, tokens: tokens, rule: rule) }
        model.pulseNow = { [t0 = t0] in t0 }
    }

    deinit { QuietNotifications.release() }

    func cleanUp() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        removeTestFolder(root)
    }

    func at(minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func bot(_ name: String) -> Bot { bots.first { $0.name == name }! }

    /// Every turn is over, no request or answer is open, and the pulses' new baselines are written.
    func settle() async {
        await waitUntil("every turn to end") {
            let hub = self.model.delegation
            return self.bots.allSatisfy { self.model.sessions[$0.id]?.turnTask == nil && !hub.isStarting($0.id) }
                && !hub.requests.values.contains { DelegationHub.isOpen($0.state) } && hub.inbox.isEmpty
                && self.model.pulseRuns.isEmpty && self.model.pulseTask == nil
        }
        // The baseline of a pulse that just ended is read off the main thread. (It is not compared with the files now: the
        // answers of the Orbs it asked arrive after it and rightly change what the Orb sees.)
        for bot in bots where model.pulseState.lastRunByOrb[bot.id.uuidString] != nil {
            await waitUntil("the baseline of \(bot.name)") { self.model.pulseState.fingerprints[bot.id.uuidString] != nil }
        }
    }

    /// Something changes in the Orb's memory folder: its fingerprint no longer matches the last pulse's.
    func changeMemory(of name: String) throws {
        let folder = model.memory.bank(for: bot(name).id).directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "nota \(UUID().uuidString)".write(to: folder.appending(path: "nota-\(UUID().uuidString).md"), atomically: true, encoding: .utf8)
    }

    func events(_ name: String) -> [OrbEvent] {
        model.transcript(bot(name).id).compactMap { if case .event(let event) = $0.kind { event } else { nil } }
    }

    /// Opens the first window, then the one that makes a pulse due.
    func startInterval() async {
        await model.pulseTick(now: t0)
    }
}

@Suite @MainActor struct PulseTests {
    private static func nothing(_ who: String, _ user: String, _ result: String?) async -> [LLMEvent] { say("NOTHING") }

    // MARK: When

    @Test func theFirstLookOnlyOpensTheWindow() async {
        let world = PulseWorld(rule: Self.nothing)
        defer { world.cleanUp() }
        await world.startInterval()
        await world.model.pulseTick(now: world.at(minutes: 30))
        #expect(world.model.pulseState.lastPulse == world.t0)
        #expect(await world.log.count == 0)
    }

    @Test func theOrbsTakeTurnsOnePerInterval() async throws {
        let world = PulseWorld(rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        await world.settle()
        let atlasCalls = await world.log.count(by: "Atlas"), allCalls = await world.log.count
        #expect(atlasCalls == 1 && allCalls == 1)

        for name in ["Atlas", "Pesquisador", "Revisor"] { try world.changeMemory(of: name) }
        await model.pulseTick(now: world.at(minutes: 122))
        await world.settle()
        for name in ["Atlas", "Pesquisador", "Revisor"] { try world.changeMemory(of: name) }
        await model.pulseTick(now: world.at(minutes: 183))
        await world.settle()
        for name in ["Atlas", "Pesquisador", "Revisor"] { try world.changeMemory(of: name) }
        await model.pulseTick(now: world.at(minutes: 244))
        await world.settle()
        let order = await world.log.seen.map { $0.who }
        #expect(order == ["Atlas", "Pesquisador", "Revisor", "Atlas"])
        // Each run is in the Orb's own pulse conversation, and the chat came back untouched.
        let saved = try #require(model.store.readSideConversation(prefix: Store.pulsoPrefix, id: world.bot("Atlas").id, for: world.bot("Atlas").id).value)
        #expect(saved.items.contains { if case .bot(let text, _) = $0.kind { text == "NOTHING" } else { false } })
        #expect(model.sessions[world.bot("Atlas").id]?.routineID == nil && model.sessions[world.bot("Atlas").id]?.parkedChat == nil)
    }

    @Test func skipsWithoutAskingTheModelWhenNothingChanged() async throws {
        let world = PulseWorld(rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model
        for bot in world.bots { model.pulseState.fingerprints[bot.id.uuidString] = await model.pulseFingerprint(of: bot.id) }
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        #expect(await world.log.count == 0)
        #expect(model.pulseState.skipped == 3)
        #expect(model.pulseState.lastPulse == world.at(minutes: 61), "a pass that found nothing spends the window")
        // A change wakes only the Orb that can see it.
        try world.changeMemory(of: "Revisor")
        await model.pulseTick(now: world.at(minutes: 122))
        await world.settle()
        #expect(await world.log.seen.map { $0.who } == ["Revisor"])
    }

    @Test func aChangeInTheTeamIsSeenByEveryOrb() async {
        let world = PulseWorld(rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model
        let before = await model.pulseFingerprint(of: world.bot("Atlas").id)
        let group = OrbGroup(name: "Time", memberIDs: [world.bot("Atlas").id, world.bot("Revisor").id], orchestratorID: world.bot("Atlas").id)
        model.groups = [group]
        #expect(await model.pulseFingerprint(of: world.bot("Atlas").id) != before)
    }

    @Test func respectsTheInterval() async {
        let world = PulseWorld(rule: Self.nothing)
        defer { world.cleanUp() }
        world.model.pulseMinutes = 120
        await world.startInterval()
        await world.model.pulseTick(now: world.at(minutes: 100))
        #expect(await world.log.count == 0)
        await world.model.pulseTick(now: world.at(minutes: 121))
        await world.settle()
        #expect(await world.log.count == 1)
    }

    @Test func switchedOffItNeverRuns() async {
        let world = PulseWorld(rule: Self.nothing)
        defer { world.cleanUp() }
        world.model.pulseEnabled = false
        await world.startInterval()
        await world.model.pulseTick(now: world.at(minutes: 500))
        let calls = await world.log.count
        #expect(calls == 0 && world.model.pulseState.lastPulse == nil)
        // It adds no permission: without "Orbs agem por conta própria" there is nothing for it to do.
        world.model.pulseEnabled = true
        world.model.orbsActOnOwn = false
        await world.model.pulseTick(now: world.at(minutes: 600))
        #expect(await world.log.count == 0)
    }

    @Test func aSingleOrbHasNoOneToCoordinateWith() async {
        let world = PulseWorld(names: ["Atlas"], rule: Self.nothing)
        defer { world.cleanUp() }
        await world.startInterval()
        await world.model.pulseTick(now: world.at(minutes: 500))
        #expect(await world.log.count == 0)
    }

    @Test func holdsBackRightAfterTheMacWoke() async {
        let world = PulseWorld(rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model
        await world.startInterval()
        let woke = world.at(minutes: 70)
        model.systemDidWake(at: woke)
        model.runDueRoutines(now: woke.addingTimeInterval(10)) // within the settle time of the wake
        #expect(model.pulseTask == nil)
        model.runDueRoutines(now: woke.addingTimeInterval(AppModel.wakeSettleTime + 5))
        await waitUntil("the pass") { model.pulseTask == nil }
        await world.settle()
        #expect(await world.log.count == 1)
    }

    @Test func leavesABusyOrbAloneAndTakesTheNextOne() async throws {
        let gate = TestGate()
        let world = PulseWorld { who, user, _ in
            if who == "Atlas", !user.contains("[Pulse]") { await gate.wait() }
            return say("NOTHING")
        }
        defer { world.cleanUp() }
        let model = world.model
        model.send("trabalhe", to: world.bot("Atlas").id, fromUser: true)
        await waitUntil("Atlas to be at work") { await world.log.count(by: "Atlas") == 1 }
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        await gate.open()
        await world.settle()
        #expect(await world.log.seen.map { $0.who }.filter { $0 != "Atlas" } == ["Pesquisador"])
        #expect(await world.log.calls(by: "Atlas").allSatisfy { !$0.user.contains("[Pulse]") })
    }

    // MARK: The budget

    @Test func theDaysBudgetBlocksUntilTheNextDay() async throws {
        let world = PulseWorld(rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model
        model.pulseDailyTokens = 50_000
        await world.startInterval()
        model.pulseState.tokensToday = 50_000
        await model.pulseTick(now: world.at(minutes: 61))
        #expect(await world.log.count == 0, "the day's budget is spent")
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: world.t0))!.addingTimeInterval(3_600)
        await model.pulseTick(now: tomorrow)
        await world.settle()
        #expect(await world.log.count == 1)
    }

    @Test func theBudgetCountsThePulseAndTheWholeChainItStarts() async throws {
        let world = PulseWorld(tokens: 1_000) { who, user, result in
            switch who {
            case "Atlas":
                if user.contains("<orb_reply") { return say("O Pesquisador respondeu.") }
                if result != nil { return say("Pedi ao Pesquisador.") }
                return ask("Pesquisador", "Veja o que falta.")
            default: return say("Visto.")
            }
        }
        defer { world.cleanUp() }
        let model = world.model
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        await world.settle()
        // The pulse's two steps, the Pesquisador's turn and the turn the answer woke: four calls, all counted.
        let calls = await world.log.count
        #expect(calls == 4)
        #expect(model.pulseState.tokensToday == calls * 1_000)
        // A chat turn that no pulse started is not counted.
        model.send("oi", to: world.bot("Revisor").id, fromUser: true)
        await world.settle()
        #expect(model.pulseState.tokensToday == 4_000)
        #expect(model.delegation.chainStates.values.contains { $0.origin.isPulse })
    }

    @Test func aChainThatPassesTheBudgetIsStoppedAndSaysSo() async throws {
        let gate = TestGate(), reached = TestGate()
        let world = PulseWorld(tokens: 6_000) { who, user, result in
            switch who {
            case "Atlas":
                if user.contains("<orb_reply") { return say("Voltou.") }
                if result != nil {
                    await reached.wait() // the Pesquisador is at work when the budget runs out
                    return say("Pedi ao Pesquisador.")
                }
                return ask("Pesquisador", "Faça o trabalho longo.")
            default:
                await reached.open()
                await gate.wait()
                return say("Pronto.")
            }
        }
        defer { world.cleanUp() }
        let model = world.model
        model.pulseDailyTokens = 10_000
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        // Atlas' two steps are 12,000 tokens: over the 10,000 while the Pesquisador still works.
        await waitUntil("the chain to be stopped") { model.delegation.chainStates.values.contains { $0.origin.isPulse && $0.cancelled } }
        await gate.open()
        await world.settle()
        #expect(world.events("Atlas").contains { $0.kind == .pulseStopped && $0.sentence.contains("teto diário") })
        let request = try #require(model.delegation.requests.values.first)
        #expect(request.state == .cancelled)
        #expect(await world.log.calls(by: "Atlas").allSatisfy { !$0.user.contains("<orb_reply") }, "the answer of a stopped chain wakes nobody")
        // And nothing else starts today.
        await model.pulseTick(now: world.at(minutes: 200))
        #expect(await world.log.calls(by: "Pesquisador").count == 1)
    }

    // MARK: What it shows

    @Test func aPulseThatDidSomethingLeavesALineInTheChatAndOnTheHomePage() async throws {
        let world = PulseWorld { who, _, _ in say(who == "Atlas" ? "Combinei com o Revisor o próximo passo." : "NOTHING") }
        defer { world.cleanUp() }
        let model = world.model
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        await world.settle()
        let event = try #require(world.events("Atlas").first { $0.kind == .pulseRan })
        #expect(event.note == "Combinei com o Revisor o próximo passo.")
        #expect(event.sentence == "Atlas acordou sozinho: Combinei com o Revisor o próximo passo. · 1 mil tokens")
        let entry = try #require(model.inicio.entries.first)
        guard case .pulse(let bot, _, let item) = entry.origin else { Issue.record("not a pulse entry"); return }
        #expect(bot == world.bot("Atlas").id && entry.id == item && entry.outcome == .completed)
        #expect(entry.summary.contains("Combinei"))
        #expect(model.pulseState.lastSummary == "Combinei com o Revisor o próximo passo." && model.pulseState.lastActed != nil)
        // The home page's row opens that line.
        #expect(model.transcript(world.bot("Atlas").id).contains { $0.id == item })
    }

    @Test func aPulseThatAnswersNothingLeavesNoTrace() async {
        let world = PulseWorld(rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        await world.settle()
        #expect(world.events("Atlas").isEmpty && model.inicio.entries.isEmpty)
        #expect(model.pulseState.lastSummary == nil)
        #expect(model.live(world.bot("Atlas").id).lastReply == nil, "NOTHING is not the Orb's row text")
    }

    @Test func aPulseThatOnlyUsedToolsStillCounts() async throws {
        let world = PulseWorld { who, _, result in
            if who == "Atlas" { return result == nil ? ask("Revisor", "Confira.") : say("NOTHING") }
            return say("Ok.")
        }
        defer { world.cleanUp() }
        await world.startInterval()
        await world.model.pulseTick(now: world.at(minutes: 61))
        await world.settle()
        let event = try #require(world.events("Atlas").first { $0.kind == .pulseRan })
        #expect(event.note == "usou ferramentas")
    }

    // MARK: What it is handed

    @Test func theTurnIsAnUnattendedSideRunWithTheMultiOrbTools() async throws {
        let world = PulseWorld(rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        await world.settle()
        let call = try #require(await world.log.calls(by: "Atlas").first)
        #expect(call.user.contains("[Pulse] Nobody asked for this run."))
        for tool in ["orbs", "group_create", "group_edit", "orb_propose", "orb_delete"] { #expect(call.tools.contains(tool), "\(tool)") }
        #expect(!call.tools.contains("ask_user") && !call.tools.contains("request_access"), "nobody is there to answer")
        #expect(Pulse.prompt.count < 320, "the prompt goes in every pulse")
    }

    @Test func offeringForAPulseIsTheOneOfAnyOtherSideRun() {
        let world = PulseWorld(rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model
        let atlas = world.bot("Atlas").id
        let session = model.session(atlas)
        session.startRoutineRun(UUID(), conversation: Conversation(), at: .now, kind: .pulse)
        let offering = model.multiOrbOffering(for: atlas)
        #expect(offering.orbs && offering.propose && offering.groupCreate && offering.groupEdit && offering.orbDelete)
        #expect(offering.sideRun && !offering.askUser && !offering.access)
        session.endSideRun()
    }

    // MARK: Keeping and decoding

    @Test func theJournalHoldsARunningPulseAndLetsGoOfItAtTheEnd() async throws {
        let gate = TestGate()
        let world = PulseWorld { _, _, _ in
            await gate.wait()
            return say("NOTHING")
        }
        defer { world.cleanUp() }
        let model = world.model
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        await waitUntil("the pulse to run") { model.sessions[world.bot("Atlas").id]?.sideKind == .pulse }
        #expect(model.workJournal.entries.contains { $0.kind == .pulse && $0.botID == world.bot("Atlas").id })
        await gate.open()
        await world.settle()
        #expect(!model.workJournal.entries.contains { $0.kind == .pulse })
    }

    @Test func aPulseCutByAClosedAppIsDroppedNotResumed() async throws {
        let world = PulseWorld(rule: Self.nothing)
        defer { world.cleanUp() }
        let atlas = world.bot("Atlas").id
        world.model.store.saveWorkJournal(WorkJournalFile(entries: [WorkEntry(kind: .pulse, startedAt: .now, botID: atlas)], lastLaunch: .now, cleanQuit: false))
        world.model.store.flush()
        let again = AppModel(store: Store(directory: world.root), runsBackgroundWork: false)
        again.preferences = UserDefaults(suiteName: world.suite) ?? .standard
        await again.resumeInterruptedWork()?.value
        #expect(!again.workJournal.entries.contains { $0.kind == .pulse })
        #expect(await world.log.count == 0)
    }

    @Test func theStateAndTheNewKindsReadTolerantly() throws {
        let empty = try JSONDecoder().decode(PulseState.self, from: Data("{}".utf8))
        #expect(empty == PulseState())
        let damaged = try JSONDecoder().decode(PulseState.self, from: Data(#"{"lastPulse":"x","skipped":"many","tokensToday":-5,"fingerprints":{"a":"b"},"future":1}"#.utf8))
        #expect(damaged.skipped == 0 && damaged.tokensToday == 0 && damaged.lastPulse == nil && damaged.fingerprints == ["a": "b"])
        let state = PulseState(lastPulse: .now, lastOrb: UUID(), fingerprints: ["x": "y"], lastSummary: "ok", skipped: 2, day: "2026-11-08", tokensToday: 7)
        #expect(try JSONDecoder().decode(PulseState.self, from: JSONEncoder().encode(state)) == state)

        #expect(try JSONDecoder().decode(UsageSource.self, from: Data(#""pulse""#.utf8)) == .pulse)
        #expect(try JSONDecoder().decode(UsageSource.self, from: Data(#""from-the-future""#.utf8)) == .chat)
        let entry = try JSONDecoder().decode(WorkEntry.self, from: Data(#"{"kind":"pulse","botID":"\#(UUID().uuidString)"}"#.utf8))
        #expect(entry.kind == .pulse && entry.botID != nil)
        #expect(try JSONDecoder().decode(WorkEntry.self, from: Data(#"{"kind":"later"}"#.utf8)).kind == .unknown)
        let event = try JSONDecoder().decode(OrbEvent.self, from: Data(#"{"kind":"pulseRan","note":"fez","detail":"2500"}"#.utf8))
        #expect(event.kind == .pulseRan && event.sentence == "Um Orb acordou sozinho: fez · 3 mil tokens")
        #expect(OrbEvent(kind: .pulseStopped, detail: "300000").sentence == "O pulso parou: o teto diário de tokens (300 mil tokens por dia) foi atingido")
        let inicio = InicioEntry(id: UUID(), sequence: 1, date: .now, origin: .pulse(bot: UUID(), chat: UUID(), item: UUID()), outcome: .completed, summary: "x")
        #expect(try JSONDecoder().decode(InicioEntry.self, from: JSONEncoder().encode(inicio)) == inicio)
    }

    @Test func theSettingsKeepToTheirRange() {
        let world = PulseWorld(rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model
        #expect(model.pulseEnabled && model.pulseMinutes == 60 && model.pulseDailyTokens == 300_000)
        model.pulseMinutes = 1
        model.pulseDailyTokens = 5
        #expect(model.pulseMinutes == 15 && model.pulseDailyTokens == 10_000)
        model.pulseMinutes = 99_999
        #expect(model.pulseMinutes == 720)
    }

    @Test func nothingMeansNothingInAnyCaseOrWithPunctuation() {
        for reply in [nil, "", "NOTHING", "nothing.", "**Nothing**", " Nothing \n"] { #expect(Pulse.isNothing(reply), "\(reply ?? "nil")") }
        for reply in ["Nothing to report, but I asked the Revisor.", "Criei o grupo Time."] { #expect(!Pulse.isNothing(reply)) }
    }
}
