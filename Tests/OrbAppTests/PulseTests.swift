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
    /// What a rule answers for the provider to fail.
    static let failure: [LLMEvent] = [.text("<<provider fails>>")]

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
                if events == PulseBrain.failure { continuation.finish(throwing: LLMError.notConfigured); return }
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

    /// `demand`: every Orb starts with a plan dropped half way, the demand that makes a pulse worth its tokens.
    init(names: [String] = ["Atlas", "Pesquisador", "Revisor"], tokens: Int = 1_000, demand: Bool = true,
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
        if demand { for bot in bots { plant(bot.name, tag: 0) } }
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
    }

    /// The Orb has a plan with two of three steps left, untouched for an hour. A new `tag` is a new plan (a new demand).
    func plant(_ name: String, tag: Int) {
        var conversation = Conversation()
        var plan = TaskPlan(goal: "Entregar o relatório \(tag)", steps: [TaskPlan.Step(text: "Reunir dados", state: .done),
                                                                      TaskPlan.Step(text: "Escrever"), TaskPlan.Step(text: "Revisar")])
        plan.updatedAt = t0.addingTimeInterval(-3_600)
        conversation.taskPlan = plan
        model.session(bot(name).id).conversation = conversation
    }

    /// Something changes in the Orb's memory folder (files change; that alone is no demand).
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

        // The others have their demand; Atlas gets a new plan, which is a new demand.
        await model.pulseTick(now: world.at(minutes: 122))
        await world.settle()
        await model.pulseTick(now: world.at(minutes: 183))
        await world.settle()
        world.plant("Atlas", tag: 1)
        await model.pulseTick(now: world.at(minutes: 244))
        await world.settle()
        let order = await world.log.seen.map { $0.who }
        #expect(order == ["Atlas", "Pesquisador", "Revisor", "Atlas"])
        // Each run took up the plan in its own conversation, and a run that found nothing to do left no trace there.
        let chat = model.transcript(world.bot("Atlas").id)
        #expect(!chat.contains { if case .bot(let text, _) = $0.kind { text == "NOTHING" } else { false } })
        #expect(world.events("Atlas").isEmpty)
        #expect(model.sessions[world.bot("Atlas").id]?.routineID == nil && model.sessions[world.bot("Atlas").id]?.pulseInChat == nil)
    }

    @Test func withNoDemandItNeverAsksTheModelEvenWithFilesChanging() async throws {
        let world = PulseWorld(demand: false, rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model
        for name in ["Atlas", "Pesquisador", "Revisor"] { try world.changeMemory(of: name) }
        model.send("oi", to: world.bot("Atlas").id, fromUser: true) // the person talking is no demand either
        await world.settle()
        let before = await world.log.count
        await world.startInterval()
        try world.changeMemory(of: "Atlas")
        await model.pulseTick(now: world.at(minutes: 61))
        #expect(await world.log.count == before)
        #expect(model.pulseState.skipped == 3)
        #expect(model.pulseState.lastPulse == world.at(minutes: 61), "a pass that found nothing spends the window")
        // A demand wakes only the Orb that has it, and the model is told which.
        world.plant("Revisor", tag: 7)
        await model.pulseTick(now: world.at(minutes: 122))
        await world.settle()
        let calls = await world.log.calls(by: "Revisor").filter { $0.user.contains("[Pulse]") }
        #expect(calls.count == 1 && calls[0].user.contains("Unfinished plan \"Entregar o relatório 7\": 1/3 done, next \"Escrever\"."))
        #expect(await world.log.seen.map { $0.who }.filter { $0 != "Atlas" } == ["Revisor"])
    }

    @Test func theSameDemandIsHandedOnlyOnceAndAChangedOneAgain() async throws {
        let world = PulseWorld(names: ["Atlas", "Pesquisador"], rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        await world.settle()
        await model.pulseTick(now: world.at(minutes: 122))
        await world.settle()
        #expect(await world.log.seen.map { $0.who } == ["Atlas", "Pesquisador"])
        await model.pulseTick(now: world.at(minutes: 183)) // both already handed their demand
        await world.settle()
        #expect(await world.log.count == 2 && model.pulseState.skipped >= 2)
        // The plan moves on (one step fewer): another key.
        var conversation = try #require(model.sessions[world.bot("Atlas").id]?.conversation)
        conversation.taskPlan?.steps[1].state = .done
        model.session(world.bot("Atlas").id).conversation = conversation
        await model.pulseTick(now: world.at(minutes: 244))
        await world.settle()
        let atlas = await world.log.calls(by: "Atlas")
        #expect(atlas.count == 2 && atlas[1].user.contains("2/3 done, next \"Revisar\""))
    }

    @Test func aRoutineThatFailedIsADemandAndItsLineIsInThePrompt() async throws {
        let world = PulseWorld(demand: false, rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model
        var routine = Routine(name: "Faturas", botID: world.bot("Revisor").id, prompt: "x", schedule: .everyHours(4))
        routine.runs = [RoutineRun(date: world.t0.addingTimeInterval(-3_600), succeeded: false, summary: "Sem acesso ao banco")]
        model.routines = [routine]
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        await world.settle()
        let call = try #require(await world.log.calls(by: "Revisor").first)
        #expect(call.user.contains("- Routine \"Faturas\" failed: Sem acesso ao banco."))
        #expect(model.pulseState.delivered[world.bot("Revisor").id.uuidString]?.first?.hasPrefix("routine:") == true)
    }

    // MARK: What counts as a demand (pure)

    @Test func eachSignalIsADemandAndTheOthersAreNot() {
        let me = UUID(), other = UUID(), now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func demands(plan: TaskPlan? = nil, routines: [Routine] = [], requests: [DelegationRequest] = [], groups: [OrbGroup] = [],
                     chains: Set<UUID> = []) -> [PulseDemand] {
            let plans = PulsePlan(plan, chat: me, paused: false).map { [$0] } ?? []
            return Pulse.demands(for: me, plans: plans, routines: routines, requests: requests, groups: groups, pulseChains: chains, now: now)
        }
        // Plan: steps left and untouched for a while.
        var plan = TaskPlan(goal: "Meta", steps: [TaskPlan.Step(text: "A", state: .done), TaskPlan.Step(text: "B")])
        plan.updatedAt = now.addingTimeInterval(-Pulse.planIdle - 1)
        #expect(demands(plan: plan).count == 1 && demands(plan: plan)[0].line == "Unfinished plan \"Meta\": 1/2 done, next \"B\".")
        #expect(demands(plan: plan)[0].key.contains(":1:") && demands(plan: plan)[0].chat == me)
        var fresh = plan
        fresh.updatedAt = now.addingTimeInterval(-60)
        #expect(demands(plan: fresh).isEmpty, "the person may be about to answer")
        var waiting = plan
        waiting.steps[1].state = .blocked
        #expect(demands(plan: waiting).isEmpty, "a blocked step waits for the person")
        var finished = plan
        finished.steps[1].state = .done
        #expect(demands(plan: finished).isEmpty && demands().isEmpty)

        // Routine: this Orb's, enabled, newest run failed or asks attention, recent; a stop is not a failure.
        func routine(_ run: RoutineRun, bot: UUID? = nil, enabled: Bool = true) -> Routine {
            var routine = Routine(name: "R", botID: bot ?? me, prompt: "x", schedule: .everyHours(1))
            routine.isEnabled = enabled
            routine.runs = [run]
            return routine
        }
        let failed = RoutineRun(date: now.addingTimeInterval(-60), succeeded: false, summary: "Deu erro")
        let found = demands(routines: [routine(failed)])
        #expect(found.count == 1 && found[0].key.hasPrefix("routine:") && found[0].key.contains(failed.id.uuidString))
        #expect(demands(routines: [routine(failed, bot: other)]).isEmpty && demands(routines: [routine(failed, enabled: false)]).isEmpty)
        let stopped = RoutineRun(date: now, succeeded: false, summary: BotSession.stoppedNotice)
        let ok = RoutineRun(date: now, succeeded: true, summary: "Tudo certo")
        let old = RoutineRun(date: now.addingTimeInterval(-Pulse.runFreshness - 1), succeeded: false, summary: "Antigo")
        #expect(demands(routines: [routine(stopped), routine(ok), routine(old)]).isEmpty)
        var attention = RoutineRun(date: now, succeeded: true, summary: "Feito")
        attention.check = GoalCheck(progress: 10, status: .attention, note: "Atrasada")
        #expect(demands(routines: [routine(attention)]).first?.line == "Routine \"R\" needs attention: Atrasada.")

        // Requests: mine that failed; a group turn that failed in a group I orchestrate; not cancelled, not replies, not the pulse's own chains.
        func request(from: UUID, to: UUID, state: DelegationRequest.State = .failed, group: UUID? = nil, kind: OrbEnvelope.Kind = .ask,
                     chain: UUID = UUID()) -> DelegationRequest {
            var envelope = OrbEnvelope(chainID: chain, kind: kind, from: OrbRef(id: from, name: "De"), to: OrbRef(id: to, name: "Para"), text: "Faça isso")
            envelope.groupID = group
            return DelegationRequest(envelope: envelope, state: state)
        }
        let mine = request(from: me, to: other)
        #expect(demands(requests: [mine]).map(\.line) == ["Your request to Para failed: \"Faça isso\"."])
        #expect(demands(requests: [mine]).first?.key == "request:\(mine.envelope.id.uuidString)")
        #expect(demands(requests: [request(from: other, to: me), request(from: me, to: other, state: .cancelled),
                                   request(from: me, to: other, state: .replied), request(from: me, to: other, kind: .reply)]).isEmpty)
        let pulseChain = UUID()
        #expect(demands(requests: [request(from: me, to: other, chain: pulseChain)], chains: [pulseChain]).isEmpty)
        let group = OrbGroup(name: "Time", memberIDs: [me, other], orchestratorID: me)
        let turn = request(from: UUID(), to: other, group: group.id)
        #expect(demands(requests: [turn], groups: [group]).map(\.line) == ["In group \"Time\" the turn of Para failed: \"Faça isso\"."])
        var theirs = group
        theirs.orchestratorID = other
        #expect(demands(requests: [turn], groups: [theirs]).isEmpty && demands(requests: [turn]).isEmpty)
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
        #expect(call.user.contains("[Pulse] Nobody asked for this run, and nobody reads it while it works. Open work you could move forward:\n- Unfinished plan"))
        #expect(call.user.hasSuffix("reply only NOTHING."))
        for tool in ["orbs", "group_create", "group_edit", "orb_propose", "orb_delete"] { #expect(call.tools.contains(tool), "\(tool)") }
        #expect(!call.tools.contains("ask_user") && !call.tools.contains("request_access"), "nobody is there to answer")
        #expect(Pulse.prompt(for: [PulseDemand(key: "k", line: "l")]).count < 320, "the prompt goes in every pulse")
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
        await waitUntil("the pulse to run") { model.sessions[world.bot("Atlas").id]?.pulseInChat != nil }
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
        let damaged = try JSONDecoder().decode(PulseState.self, from: Data(#"{"lastPulse":"x","skipped":"many","tokensToday":-5,"delivered":"no","future":1}"#.utf8))
        #expect(damaged.skipped == 0 && damaged.tokensToday == 0 && damaged.lastPulse == nil && damaged.delivered.isEmpty)
        // A state saved before demands (with the old fingerprints) still reads, and the old map is dropped.
        let old = try JSONDecoder().decode(PulseState.self, from: Data(#"{"skipped":3,"fingerprints":{"a":"b"},"day":"2026-11-08","tokensToday":9}"#.utf8))
        #expect(old.skipped == 3 && old.tokensToday == 9 && old.delivered.isEmpty)
        let state = PulseState(lastPulse: .now, lastOrb: UUID(), delivered: ["x": ["plan:1:2"]], lastSummary: "ok", lastReason: "r", skipped: 2, day: "2026-11-08", tokensToday: 7)
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

// MARK: - The lineage: every way the pulse's work goes on stays on its budget

@Suite @MainActor struct PulseLineageTests {
    private static func nothing(_ who: String, _ user: String, _ result: String?) async -> [LLMEvent] { say("NOTHING") }

    /// The pulse asks a teammate, and the teammate, serving that request, asks a group it is in: the group's turns are the
    /// pulse's work too.
    @Test func aGroupATeammateAsksForThePulseCountsAgainstTheBudget() async throws {
        let world = PulseWorld { who, user, result in
            switch who {
            case "Atlas":
                if user.contains("<orb_reply") { return say("Pronto.") }
                if result != nil { return say("Pedi ao Pesquisador.") }
                return ask("Pesquisador", "Veja o que falta.")
            case "Pesquisador":
                if user.contains("<orb_reply") { return say("O time terminou.") }
                if result != nil { return say("Pedi ao time.") }
                return ask("Time", "Revisem o texto.")
            default: return say("Revisado.")
            }
        }
        defer { world.cleanUp() }
        let model = world.model
        let group = try #require(model.createGroup(name: "Time", members: [world.bot("Pesquisador").id, world.bot("Revisor").id],
                                                   orchestrator: world.bot("Revisor").id))
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        await world.settle()
        #expect(await world.log.count(by: "Revisor") >= 1, "the group worked")
        let calls = await world.log.count
        #expect(model.pulseState.tokensToday == calls * 1_000, "every call of the chain, the group's included")
        #expect(model.delegation.chainStates.values.contains { $0.groupID == group.id && $0.origin.isPulse })
    }

    /// The pulse's answer wakes the chat, and the chat asks a group: still the pulse's.
    @Test func aGroupTheChatAnAnswerWokeAsksIsChargedToo() async throws {
        let world = PulseWorld { who, user, result in
            switch who {
            case "Atlas":
                if user.contains("Revisado") { return say("O time revisou.") }
                if user.contains("<orb_reply") { return result == nil ? ask("Time", "Revisem o relatório.") : say("Pedi ao time.") }
                if result != nil { return say("Pedi ao Pesquisador.") }
                return ask("Pesquisador", "Veja o que falta.")
            case "Pesquisador": return say("Falta revisar.")
            default: return say("Revisado.")
            }
        }
        defer { world.cleanUp() }
        let model = world.model
        let group = try #require(model.createGroup(name: "Time", members: [world.bot("Atlas").id, world.bot("Revisor").id],
                                                   orchestrator: world.bot("Revisor").id))
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        await world.settle()
        await waitUntil("the group's answer to wake the chat") { await world.log.calls(by: "Atlas").contains { $0.user.contains("Revisado") } }
        await world.settle()
        #expect(await world.log.count(by: "Revisor") >= 1)
        let calls = await world.log.count
        #expect(model.pulseState.tokensToday == calls * 1_000)
        #expect(model.delegation.chainStates.values.contains { $0.groupID == group.id && $0.origin.isPulse })
    }

    /// A request the pulse paid for, redone after the app closed, is still the pulse's.
    @Test func aRequestRedoneAfterAClosedAppStaysOnThePulsesBudget() async throws {
        let world = PulseWorld(demand: false, rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model
        var envelope = OrbEnvelope(kind: .ask, from: OrbRef(world.bot("Atlas")), to: OrbRef(world.bot("Pesquisador")), text: "Veja.")
        envelope.pulseRun = UUID()
        #expect(model.delegation.resubmit(envelope))
        #expect(model.delegation.chainStates[envelope.chainID]?.origin.pulseRun == envelope.pulseRun)
        await world.settle()
        #expect(await world.log.count(by: "Pesquisador") == 1)
        // The Pesquisador's turn and the turn of Atlas' chat its answer woke.
        let calls = await world.log.count
        #expect(calls == 2 && model.pulseState.tokensToday == calls * 1_000)
    }

    /// With the day's budget spent, the work the pulse pays for asks for nothing more; the person's own work is never refused.
    @Test func aSpentBudgetRefusesNewWorkOnlyInThePulsesLineage() async throws {
        let world = PulseWorld(demand: false, rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model
        let atlas = world.bot("Atlas").id
        model.pulseDailyTokens = 10_000
        model.pulseState.day = PulseState.dayKey(world.t0)
        model.pulseState.tokensToday = 10_000
        let chain = UUID()
        model.delegation.seedChain(chain, pulseRun: UUID(), originBot: atlas, groupID: nil)
        model.session(atlas).usageChain = chain
        #expect(model.pulseLineage(of: atlas) != nil)
        #expect(throws: DelegationRefusal.pulseBudget) {
            try model.delegation.submit(from: atlas, to: "Pesquisador", text: "Mais uma coisa", kind: .ask, messageID: UUID(), groupID: nil)
        }
        #expect(model.delegation.requests.isEmpty)
        model.session(atlas).usageChain = nil
        #expect(model.pulseLineage(of: atlas) == nil)
        _ = try model.delegation.submit(from: atlas, to: "Pesquisador", text: "Pedido meu", kind: .ask, messageID: UUID(), groupID: nil)
        await world.settle()
        #expect(model.pulseState.tokensToday == 10_000, "the person's request is not the pulse's")
    }

    /// A failure in a chain the pulse paid for never wakes a pulse, even once the chain's state is forgotten.
    @Test func aFailureOfThePulsesOwnWorkIsNeverADemand() {
        let me = UUID(), other = UUID()
        var envelope = OrbEnvelope(kind: .ask, from: OrbRef(id: me, name: "Eu"), to: OrbRef(id: other, name: "Outro"), text: "Faça")
        envelope.pulseRun = UUID()
        let failed = DelegationRequest(envelope: envelope, state: .failed)
        #expect(Pulse.demands(for: me, plans: [], routines: [], requests: [failed], groups: [], pulseChains: [], now: .now).isEmpty)
    }

    /// The chat an answer of the pulse's chain woke stops at the budget too (no request holds it, so no chain stopped it).
    @Test func theChatAnAnswerWokeStopsAtTheBudget() async throws {
        let secondStep = TestGate(), gate = TestGate()
        let world = PulseWorld(tokens: 3_000) { who, user, result in
            switch who {
            case "Atlas":
                if user.contains("<orb_reply") {
                    guard result != nil else { return ask("Revisor", "E agora?") }
                    await secondStep.open()
                    await gate.wait()
                    return say("Continuei.")
                }
                if result != nil { return say("Pedi ao Pesquisador.") }
                return ask("Pesquisador", "Veja o que falta.")
            default: return say("Falta revisar.")
            }
        }
        defer { world.cleanUp() }
        let model = world.model
        model.pulseDailyTokens = 10_000
        let atlas = world.bot("Atlas").id
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        // 3k + 3k (pulse) + 3k (Pesquisador) + 3k (the woken chat's first step): over the 10k while the chat still works. It
        // stops then, or at the latest while its second step waits (the gate keeps that one from ending by itself).
        await waitUntil("the woken chat to begin") { await world.log.calls(by: "Atlas").contains { $0.user.contains("<orb_reply") } }
        await waitUntil("the budget to stop the woken chat") { model.sessions[atlas]?.turnTask == nil }
        await secondStep.open()
        await gate.open()
        await world.settle()
        let texts = model.transcript(atlas).compactMap { item -> String? in if case .bot(let text, _) = item.kind { text } else { nil } }
        #expect(!texts.contains("Continuei."))
        #expect(world.events("Atlas").contains { $0.kind == .pulseStopped })
    }
}

// MARK: Demands that are not lost or repeated

@Suite @MainActor struct PulseDemandTests {
    private static func nothing(_ who: String, _ user: String, _ result: String?) async -> [LLMEvent] { say("NOTHING") }

    private func plan(_ goal: String, at date: Date) -> Conversation {
        var conversation = Conversation()
        var plan = TaskPlan(goal: goal, steps: [TaskPlan.Step(text: "Ler", state: .done), TaskPlan.Step(text: "Escrever")])
        plan.updatedAt = date
        conversation.taskPlan = plan
        return conversation
    }

    @Test func aPlanOfAConversationOffScreenOrAfterReopeningIsADemand() {
        let world = PulseWorld(demand: false, rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model, atlas = world.bot("Atlas").id, other = UUID()
        var conversation = plan("Migrar o banco", at: world.t0.addingTimeInterval(-3_600))
        model.notePlan(conversation, chat: other, of: atlas)
        let found = model.newPulseDemands(for: atlas, now: world.t0)
        #expect(found.count == 1 && found.first?.chat == other)
        #expect(found.first?.line == "Unfinished plan \"Migrar o banco\": 1/2 done, next \"Escrever\".")
        // The app reopened: the plan is read back with the rest of the pulse's state.
        model.pulseState = model.loadPulseState()
        #expect(model.newPulseDemands(for: atlas, now: world.t0).map(\.key) == found.map(\.key))
        // Paused to wait for the person: no work for the pulse.
        conversation.taskPaused = true
        model.notePlan(conversation, chat: other, of: atlas)
        #expect(model.newPulseDemands(for: atlas, now: world.t0).isEmpty)
        // The newest plans are kept, a few per Orb.
        for index in 0..<5 {
            model.notePlan(plan("Meta \(index)", at: world.t0.addingTimeInterval(Double(index - 3_600))), chat: UUID(), of: atlas)
        }
        #expect(model.pulseState.plans[atlas.uuidString]?.map(\.goal) == ["Meta 4", "Meta 3", "Meta 2"])
        model.forgetPulse(of: atlas)
        #expect(model.pulseState.plans[atlas.uuidString] == nil && model.newPulseDemands(for: atlas, now: world.t0).isEmpty)
    }

    @Test func aDeletedConversationTakesItsPlanAndNoticesAlong() {
        let world = PulseWorld(demand: false, rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model, atlas = world.bot("Atlas").id, chat = UUID(), kept = UUID()
        model.notePlan(plan("Some", at: world.t0.addingTimeInterval(-3_600)), chat: chat, of: atlas)
        model.notePlan(plan("Fica", at: world.t0.addingTimeInterval(-3_600)), chat: kept, of: atlas)
        model.forgetPulse(of: atlas, chat: chat)
        #expect(model.pulseState.plans[atlas.uuidString]?.map(\.chat) == [kept])
    }

    @Test func aFailedPulseTriesItsDemandOnceMoreAndAlwaysLeavesALine() async throws {
        let world = PulseWorld(names: ["Atlas", "Revisor"], demand: false) { _, _, _ in PulseBrain.failure }
        defer { world.cleanUp() }
        let model = world.model, atlas = world.bot("Atlas").id
        world.plant("Atlas", tag: 0)
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        await world.settle()
        #expect(await world.log.count(by: "Atlas") == 1)
        let line = try #require(world.events("Atlas").first { $0.kind == .pulseRan })
        #expect(line.outcome == .failed && line.note?.hasPrefix("não deu certo: ") == true)
        #expect(model.pulseState.delivered[atlas.uuidString] == nil, "a failure does not use the demand up")
        await model.pulseTick(now: world.at(minutes: 122))
        await world.settle()
        #expect(await world.log.count(by: "Atlas") == 2)
        #expect(model.pulseState.delivered[atlas.uuidString]?.count == 1, "after the second failure it is handed over")
        await model.pulseTick(now: world.at(minutes: 183))
        await world.settle()
        #expect(await world.log.count(by: "Atlas") == 2)
        #expect(world.events("Atlas").filter { $0.kind == .pulseRan }.count == 2)
    }

    @Test func aRoutineFailingTheSameWayRunAfterRunIsOneDemand() {
        let me = UUID(), now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var routine = Routine(name: "Faturas", botID: me, prompt: "x", schedule: .everyHours(1))
        func key(_ runs: [RoutineRun]) -> String? {
            routine.runs = runs
            return Pulse.demands(for: me, plans: [], routines: [routine], requests: [], groups: [], pulseChains: [], now: now).first?.key
        }
        let first = RoutineRun(date: now.addingTimeInterval(-7_200), succeeded: false, summary: "Erro 503 às 10:01")
        let again = RoutineRun(date: now.addingTimeInterval(-3_600), succeeded: false, summary: "Erro 503 às 11:02")
        let other = RoutineRun(date: now.addingTimeInterval(-60), succeeded: false, summary: "Senha recusada")
        let ok = RoutineRun(date: now.addingTimeInterval(-1_800), succeeded: true, summary: "Tudo certo")
        let once = key([first])
        #expect(once != nil && key([again, first]) == once, "the same trouble with other numbers is the same demand")
        #expect(key([other, again, first]) != once, "new words are new work")
        #expect(key([again, ok, first]) != once, "a run that went well starts a new streak")
    }

    @Test func aNoticeNobodyReadWakesTheOrbAfterHalfAnHourButNotAPulsesOwn() async throws {
        let world = PulseWorld(demand: false, rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model, revisor = world.bot("Revisor").id
        _ = try await model.delegation.handleTool(.object(["action": .string("tell"), "to": .string("Revisor"),
                                                           "message": .string("O contrato chegou.")]), orb: world.bot("Atlas").id)
        let notices = model.pulseState.notices[revisor.uuidString] ?? []
        #expect(notices.count == 1 && notices.first?.from == "Atlas" && notices.first?.at == world.t0)
        #expect(model.newPulseDemands(for: revisor, now: world.t0.addingTimeInterval(29 * 60)).isEmpty, "its chat may read it soon")
        let woken = model.newPulseDemands(for: revisor, now: world.t0.addingTimeInterval(31 * 60))
        #expect(woken.map(\.line) == ["Unread notice from Atlas: \"O contrato chegou.\"."])
        // The chat was handed it: it no longer waits.
        model.forgetPulseNotices(of: revisor, chat: try #require(notices.first?.chat))
        #expect(model.newPulseDemands(for: revisor, now: world.t0.addingTimeInterval(31 * 60)).isEmpty)
        // A notice of the pulse's own work is never a demand: pulses would wake one another.
        var envelope = OrbEnvelope(kind: .tell, from: OrbRef(world.bot("Atlas")), to: OrbRef(world.bot("Revisor")), text: "Feito.")
        envelope.pulseRun = UUID()
        model.notePulseNotice(envelope, chat: UUID())
        #expect(model.pulseState.notices[revisor.uuidString] == nil)
    }

    @Test func manyDemandsHandedOverNeverComeBackAndGoneOnesAreForgotten() {
        let world = PulseWorld(demand: false, rule: Self.nothing)
        defer { world.cleanUp() }
        let model = world.model, atlas = world.bot("Atlas").id
        model.routines = (0..<45).map { index in
            var routine = Routine(name: "R\(index)", botID: atlas, prompt: "x", schedule: .everyHours(1))
            routine.runs = [RoutineRun(date: world.t0.addingTimeInterval(-60), succeeded: false, summary: "Falhou \(index)")]
            return routine
        }
        let all = model.newPulseDemands(for: atlas, now: world.t0)
        #expect(all.count == 45)
        model.pulseState.delivered[atlas.uuidString] = all.map(\.key)
        #expect(model.newPulseDemands(for: atlas, now: world.t0).isEmpty)
        model.routines.removeFirst()
        _ = model.newPulseDemands(for: atlas, now: world.t0)
        #expect(model.pulseState.delivered[atlas.uuidString]?.count == 44)
    }
}

// MARK: The pulse in the plan's chat, and answers that resume the pulse

@Suite @MainActor struct PulseInChatTests {
    @Test func aDroppedPlanIsTakenUpInItsOwnChatUnattendedAndPaidByThePulse() async throws {
        let world = PulseWorld(names: ["Atlas", "Revisor"], demand: false) { who, _, _ in
            say(who == "Atlas" ? "Retomei: escrevi a seção 2." : "NOTHING")
        }
        defer { world.cleanUp() }
        let model = world.model, atlas = world.bot("Atlas").id
        world.plant("Atlas", tag: 0)
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        await world.settle()
        let call = try #require(await world.log.calls(by: "Atlas").first)
        #expect(call.user.contains("This is the conversation of the plan") && call.user.contains("Unfinished plan"))
        #expect(!call.tools.contains("ask_user") && !call.tools.contains("request_access"), "nobody is there to answer")
        let chat = model.transcript(atlas)
        #expect(!chat.contains { if case .user = $0.kind { true } else { false } }, "nobody wrote it: no bubble")
        #expect(chat.contains { if case .bot(let text, _) = $0.kind { text == "Retomei: escrevi a seção 2." } else { false } })
        let kinds = world.events("Atlas").map(\.kind)
        #expect(kinds == [.pulseResumed, .pulseRan])
        #expect(world.events("Atlas").first?.sentence == "Atlas retomou sozinho o plano “Entregar o relatório 0”")
        #expect(model.pulseState.tokensToday == 1_000 && model.sessions[atlas]?.pulseInChat == nil)
        #expect(!model.workJournal.entries.contains { $0.botID == atlas }, "a quit drops it, as any pulse")
        #expect(model.pulseState.delivered[atlas.uuidString]?.count == 1)
    }

    @Test func anAnswerToThePulsesAskResumesThePulseNotTheChat() async throws {
        let world = PulseWorld(names: ["Atlas", "Revisor"], demand: false) { who, user, result in
            if who == "Revisor" { return say("Conferido.") }
            if user.contains("<orb_reply") { return say("O Revisor conferiu a rotina.") }
            return result == nil ? ask("Revisor", "Confira a rotina Faturas.") : say("Pedi ao Revisor.")
        }
        defer { world.cleanUp() }
        let model = world.model, atlas = world.bot("Atlas").id
        var routine = Routine(name: "Faturas", botID: atlas, prompt: "x", schedule: .everyHours(4))
        routine.runs = [RoutineRun(date: world.t0.addingTimeInterval(-3_600), succeeded: false, summary: "Sem acesso")]
        model.routines = [routine]
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        await world.settle()
        let atlasCalls = await world.log.calls(by: "Atlas")
        #expect(atlasCalls.count == 3)
        #expect(atlasCalls.last?.user.contains("Continue the pulse's work") == true)
        // One line for the whole run, with what it came to; the chat had no turn of its own.
        let lines = world.events("Atlas").filter { $0.kind == .pulseRan }
        #expect(lines.count == 1 && lines.first?.note == "O Revisor conferiu a rotina.")
        #expect(!model.transcript(atlas).contains { if case .bot = $0.kind { true } else { false } })
        #expect(!model.delegation.hasWaitingPulse(of: atlas))
        #expect(model.pulseState.tokensToday == 4_000, "the pulse's three calls and the Revisor's")
        let saved = try #require(model.store.readSideConversation(prefix: Store.pulsoPrefix, id: atlas, for: atlas).value)
        #expect(saved.items.contains { if case .bot(let text, _) = $0.kind { text == "O Revisor conferiu a rotina." } else { false } })
    }

    @Test func aPulseWaitingForAnAnswerHoldsTheOrbFromAnotherPulse() async throws {
        let gate = TestGate()
        let world = PulseWorld(names: ["Atlas", "Revisor"], demand: false) { who, user, result in
            if who == "Revisor" { await gate.wait(); return say("Conferido.") }
            if user.contains("<orb_reply") { return say("Feito.") }
            return result == nil ? ask("Revisor", "Confira.") : say("Pedi.")
        }
        defer { world.cleanUp() }
        let model = world.model, atlas = world.bot("Atlas").id
        var routine = Routine(name: "Faturas", botID: atlas, prompt: "x", schedule: .everyHours(4))
        routine.runs = [RoutineRun(date: world.t0.addingTimeInterval(-3_600), succeeded: false, summary: "Sem acesso")]
        model.routines = [routine]
        await world.startInterval()
        await model.pulseTick(now: world.at(minutes: 61))
        await waitUntil("the pulse to wait") { model.delegation.hasWaitingPulse(of: atlas) }
        world.plant("Atlas", tag: 1)
        await model.pulseTick(now: world.at(minutes: 122))
        #expect(await world.log.count(by: "Atlas") == 2, "no second pulse while one waits")
        await gate.open()
        await world.settle()
        #expect(!model.delegation.hasWaitingPulse(of: atlas))
    }
}

