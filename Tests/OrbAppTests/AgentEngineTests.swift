import Foundation
import Testing
@testable import Orb

/// Like `TouchTool`, and queues a message for the model when it runs (the user wrote during the step).
private struct SteeringTouchTool: AgentTool {
    let queue: SteeringQueue
    var spec: ToolSpec { ToolSpec(name: "touch", description: "Touches a file", parameters: .schema([:])) }
    var kind: ToolCall.Kind { .file }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Tocando", "arquivo") }
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        if queue.isEmpty { queue.push(SteeredMessage(text: "use a pasta X", prompt: "use a pasta X")) }
        return "ok"
    }
}

/// A command the user let go on in the background while it ran (`CommandRelease`): it tells the turn's release so.
private struct LetGoTool: AgentTool {
    var spec: ToolSpec { ToolSpec(name: "letgo", description: "Runs and is let go", parameters: .schema([:])) }
    var kind: ToolCall.Kind { .shell }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Rodando", "") }
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        context.release?.released()
        return "foi para segundo plano"
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// A sensitive tool that counts its runs.
private struct TouchTool: AgentTool {
    let runs: Counter
    var spec: ToolSpec { ToolSpec(name: "touch", description: "Touches a file", parameters: .schema([:])) }
    var kind: ToolCall.Kind { .file }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Tocando", "arquivo") }
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        await runs.increment()
        return "ok"
    }
}

/// A tool that takes a `description` of what it does for the person watching, like `run_command`.
private struct DescribedTool: AgentTool {
    var spec: ToolSpec { ToolSpec(name: "describe", description: "Described", parameters: .schema(["description": .property("string")])) }
    var kind: ToolCall.Kind { .shell }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }
    func intent(_ arguments: JSONValue) -> String? { ToolIntent.normalize(arguments["description"]?.string) }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Rodando no Terminal", "python3 - <<'EOF'") }
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String { "ok" }
}

/// A read-only tool that takes `ms` to run and, with `together`, waits until that many runs are in progress at once
/// (so overlapping runs are seen however the machine schedules them, not by hoping the sleeps overlap).
private struct LookTool: AgentTool {
    let gauge: Gauge
    var spec: ToolSpec { ToolSpec(name: "look", description: "Looks", parameters: .schema([:])) }
    var kind: ToolCall.Kind { .file }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Olhando", "arquivo") }
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        await gauge.enter()
        do {
            if let peers = arguments["together"]?.int { await gauge.waitForPeers(peers) }
            try await Task.sleep(for: .milliseconds(arguments["ms"]?.int ?? 0))
        } catch {
            await gauge.leave()
            throw error
        }
        await gauge.leave()
        return "viu \(arguments["name"]?.string ?? "?")"
    }
}

/// Counts how many runs overlap.
private actor Gauge {
    private var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }

    /// Returns once `count` runs have been in progress together (a latch: the first to be released may leave before
    /// the others look), or after a generous wait, so a missing overlap fails the test on `peak` instead of hanging it.
    func waitForPeers(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while peak < count, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

private struct BrokenTool: AgentTool {
    var spec: ToolSpec { ToolSpec(name: "broken", description: "Always fails", parameters: .schema([:])) }
    var kind: ToolCall.Kind { .file }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Quebrando", "") }
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String { throw ToolError("não deu") }
}

/// Runs, but reports a failure the way `run_command` does for a non-zero exit: a result, not a thrown error.
private struct SadTool: AgentTool {
    var spec: ToolSpec { ToolSpec(name: "sad", description: "Ends badly", parameters: .schema([:])) }
    var kind: ToolCall.Kind { .file }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Falhando", "") }
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String { "" }
    func runWithImages(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        ToolResult(text: "Código de saída: 2", failed: true)
    }
}

/// Plays `run_command` for a build or test: passes or fails as its arguments say.
private struct CheckTool: AgentTool {
    var spec: ToolSpec { ToolSpec(name: "run_command", description: "Runs", parameters: .schema([:])) }
    var kind: ToolCall.Kind { .shell }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Rodando", "") }
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String { "" }
    func runWithImages(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let passes = arguments["ok"]?.bool == true
        return ToolResult(text: "Código de saída: \(passes ? 0 : 1)\n", failed: !passes)
    }
}

struct AgentEngineTests {
    @Test func aCommandLetGoEndsTheStepWithoutRunningTheCallsAfterIt() async throws {
        let runs = Counter()
        let script = CallScript([
            [.toolCalls([ToolCallRequest(id: "c1", name: "letgo", arguments: "{}"),
                         ToolCallRequest(id: "c2", name: "touch", arguments: "{}"),
                         ToolCallRequest(id: "c3", name: "touch", arguments: "{}")])],
            [.text("pronto")],
        ], whenExhausted: .fim)
        var turn = request(script, mode: .auto, runs: runs, tools: [LetGoTool(), TouchTool(runs: runs)])
        turn.context.release = CommandRelease(steering: nil)
        _ = await run(AgentEngine(), turn)

        #expect(await runs.value == 0)
        let second = await script.received[1]
        let results = second.filter { $0.role == .tool }
        #expect(results.map(\.toolCallID) == ["c1", "c2", "c3"])
        #expect(results[1].content == AgentEngine.skippedAfterRelease && results[2].content == AgentEngine.skippedAfterRelease)
    }

    @Test func withoutACommandLetGoEveryCallOfTheStepRuns() async throws {
        let runs = Counter()
        let script = CallScript([
            [.toolCalls([ToolCallRequest(id: "c1", name: "touch", arguments: "{}"),
                         ToolCallRequest(id: "c2", name: "touch", arguments: "{}")])],
            [.text("pronto")],
        ], whenExhausted: .fim)
        var turn = request(script, mode: .auto, runs: runs)
        turn.context.release = CommandRelease(steering: nil)
        _ = await run(AgentEngine(), turn)
        #expect(await runs.value == 2)
    }
    /// What "Sempre permitir" on the `touch` test tool (a file tool) used to be, now a rule for its family.
    private let touchRule = PermissionRule(family: .writeFiles)

    private func request(_ script: CallScript, mode: PermissionMode, allowed: [PermissionRule] = [], runs: Counter,
                         tools: [any AgentTool]? = nil, maxSteps: Int = AgentEngine.defaultMaxSteps, history: [ChatMessage] = []) -> TurnRequest {
        var bot = Bot(name: "Teste", role: "", orb: OrbConfig(), permissionMode: mode)
        bot.permissionRules = allowed
        return TurnRequest(bot: bot, model: "fake", system: "sys", history: history, prompt: "oi",
                           client: CallScriptModel(script: script), tools: tools ?? [TouchTool(runs: runs)],
                           context: ToolContext(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory())),
                           maxSteps: maxSteps)
    }

    private let touchCall = LLMEvent.toolCalls([ToolCallRequest(id: "c1", name: "touch", arguments: "{}")])

    /// Collects events; approves (or denies) every approval request with `decision`.
    private func run(_ engine: AgentEngine, _ request: TurnRequest, decision: ApprovalDecision = .once) async -> [TurnEvent] {
        var events: [TurnEvent] = []
        for await event in engine.run(request) {
            events.append(event)
            if case .approval(let approval) = event {
                await engine.gate.resolve(approvalID: approval.id, decision: decision)
            }
        }
        return events
    }

    private func messages(_ events: [TurnEvent]) -> [ChatMessage] {
        events.compactMap { if case .message(let message) = $0 { message } else { nil } }
    }

    @Test func textOnlyTurnRecordsUserAndAssistant() async {
        let script = CallScript([[.text("Olá"), .text("!")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .ask, runs: Counter()))
        #expect(messages(events).map(\.role) == [.user, .assistant])
        #expect(messages(events).last?.content == "Olá!")
    }

    @Test func theRecordedRequestCarriesTheRowOfTheChatItCameFrom() async {
        let row = UUID()
        var turn = request(CallScript([[.text("Olá")]], whenExhausted: .fim), mode: .ask, runs: Counter())
        turn.requestItem = row
        let recorded = messages(await run(AgentEngine(), turn))
        #expect(recorded.first?.itemID == row && recorded.last?.itemID == nil) // the reply is no request
        // What the model is sent is the same message (the link is not part of the request).
        let withoutLink = messages(await run(AgentEngine(), request(CallScript([[.text("Olá")]], whenExhausted: .fim), mode: .ask, runs: Counter())))
        #expect(withoutLink.first?.content == recorded.first?.content && withoutLink.first?.itemID == nil)
    }

    @Test func aMessageSteeredIntoTheTaskIsRecordedWithTheIdOfItsQueuedBubble() async {
        let queue = SteeringQueue()
        let queued = SteeredMessage(text: "e o rodapé", prompt: "e o rodapé")
        queue.push(queued)
        var history = [ChatMessage.user("pedido")]
        var events: [TurnEvent] = []
        let stream = AsyncStream<TurnEvent> { continuation in
            AgentEngine.deliverSteering(queue, into: &history, out: continuation)
            continuation.finish()
        }
        for await event in stream { events.append(event) }
        #expect(history.last?.itemID == queued.id && history.last?.content == "e o rodapé")
        #expect(messages(events).first?.itemID == queued.id)
    }

    @Test func autoModeRunsToolAndFeedsResultBack() async {
        let runs = Counter()
        let script = CallScript([[touchCall], [.text("Feito")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .auto, runs: runs))
        #expect(await runs.value == 1)
        #expect(messages(events).map(\.role) == [.user, .assistant, .tool, .assistant])
        let secondCall = await script.received[1]
        #expect(secondCall.first?.role == .system)
        #expect(secondCall.last == .tool("c1", "ok"))
    }

    @Test func askModeDenialSkipsTheTool() async {
        let runs = Counter()
        let script = CallScript([[touchCall], [.text("Tudo bem")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .ask, runs: runs), decision: .deny)
        #expect(await runs.value == 0)
        #expect(events.contains { if case .approval = $0 { true } else { false } })
        #expect(messages(events)[2].content.contains("denied"))
    }

    @Test func alwaysAllowStopsAskingForThatTool() async {
        let runs = Counter()
        let script = CallScript([[touchCall], [touchCall], [.text("Pronto")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .ask, runs: runs), decision: .always)
        let approvals = events.filter { if case .approval = $0 { true } else { false } }
        #expect(approvals.count == 1)
        #expect(await runs.value == 2)
    }

    @Test func previouslyAllowedToolRunsWithoutAsking() async {
        let runs = Counter()
        let script = CallScript([[touchCall], [.text("Pronto")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .ask, allowed: [touchRule], runs: runs))
        #expect(!events.contains { if case .approval = $0 { true } else { false } })
        #expect(await runs.value == 1)
    }

    @Test func readOnlyBlocksSensitiveTools() async {
        let runs = Counter()
        let script = CallScript([[touchCall], [.text("Ok")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .readOnly, runs: runs))
        #expect(await runs.value == 0)
        #expect(messages(events)[2].content.contains("read-only"))
    }

    @Test func aTurnLimitedToSomeToolsRefusesTheOthersWithoutAskingOrRunningThem() async {
        let runs = Counter()
        let calls = LLMEvent.toolCalls([ToolCallRequest(id: "c1", name: "touch", arguments: "{}"),
                                        ToolCallRequest(id: "c2", name: "look", arguments: "{}")])
        let script = CallScript([[calls], [.text("Nothing to save.")]], whenExhausted: .fim)
        var limited = request(script, mode: .ask, runs: runs, tools: [TouchTool(runs: runs), LookTool(gauge: Gauge())])
        limited.onlyTools = ["look"]
        let events = await run(AgentEngine(), limited)
        #expect(await runs.value == 0)
        #expect(approvals(events).isEmpty)
        let results = messages(events).filter { $0.role == .tool }
        #expect(results.map(\.toolCallID) == ["c1", "c2"])
        #expect(results[0].content == "Not available in this review." && results[0].isError)
        #expect(results[1].content == "viu ?" && !results[1].isError)
        #expect(events.filter { if case .toolStarted = $0 { true } else { false } }.count == 1)
    }

    @Test func aTurnLimitedToSomeToolsDoesNotOpenACardForOneThatWouldAsk() async {
        let runs = Counter()
        let script = CallScript([[touchCall], [.text("Nothing to save.")]], whenExhausted: .fim)
        var limited = request(script, mode: .ask, runs: runs)
        limited.onlyTools = ["touch"]
        let events = await run(AgentEngine(), limited)
        #expect(await runs.value == 0)
        #expect(approvals(events).isEmpty)
        let result = messages(events).first { $0.role == .tool }
        #expect(result?.isError == true && result?.content.contains("This review only proposes skills") == true)
    }

    private let dangerousCall = LLMEvent.toolCalls([ToolCallRequest(id: "c1", name: "touch", arguments: #"{"command":"rm -rf ~/Projetos"}"#)])

    private func approvals(_ events: [TurnEvent]) -> [ApprovalRequest] {
        events.compactMap { if case .approval(let approval) = $0 { approval } else { nil } }
    }

    @Test func bypassNeverAsksEvenForDestructiveCommands() async {
        let runs = Counter()
        let events = await run(AgentEngine(), request(CallScript([[dangerousCall], [.text("Ok")]], whenExhausted: .fim), mode: .bypass, runs: runs))
        #expect(approvals(events).isEmpty)
        #expect(await runs.value == 1)
    }

    @Test func automaticAsksOnlyForDestructiveCommands() async {
        let runs = Counter()
        let events = await run(AgentEngine(), request(CallScript([[dangerousCall], [.text("Ok")]], whenExhausted: .fim), mode: .auto, runs: runs), decision: .deny)
        #expect(approvals(events).first?.reason.hasPrefix("Comando arriscado") == true)
        #expect(await runs.value == 0)
    }

    @Test func alwaysAllowDoesNotCoverDestructiveCommands() async {
        let events = await run(AgentEngine(), request(CallScript([[dangerousCall], [.text("Ok")]], whenExhausted: .fim), mode: .ask, allowed: [touchRule],
                                                      runs: Counter()), decision: .deny)
        #expect(approvals(events).count == 1)
    }

    @Test func readOnlyWinsOverAlwaysAllow() async {
        let runs = Counter()
        let script = CallScript([[touchCall], [.text("Ok")]], whenExhausted: .fim)
        _ = await run(AgentEngine(), request(script, mode: .readOnly, allowed: [touchRule], runs: runs))
        #expect(await runs.value == 0)
    }

    @Test func unknownToolAndBadArgumentsAreReportedToTheModel() async {
        let script = CallScript([[.toolCalls([ToolCallRequest(id: "a", name: "nope", arguments: "{}"),
                                          ToolCallRequest(id: "b", name: "touch", arguments: "{bad")])],
                             [.text("Ok")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .auto, runs: Counter()))
        let results = messages(events).filter { $0.role == .tool }.map(\.content)
        #expect(results.count == 2)
        #expect(results[0].contains("unknown tool"))
        #expect(results[1].contains("not valid JSON"))
    }
}

extension AgentEngineTests {
    private func lookCall(_ id: String, ms: Int = 0, name: String = "x", together: Int? = nil) -> ToolCallRequest {
        ToolCallRequest(id: id, name: "look", arguments: #"{"ms":\#(ms),"name":"\#(name)"\#(together.map { ",\"together\":\($0)" } ?? "")}"#)
    }

    private func statuses(_ events: [TurnEvent]) -> [String] {
        events.compactMap { if case .status(let text) = $0 { text } else { nil } }
    }

    private func failures(_ events: [TurnEvent]) -> [String] {
        events.compactMap { if case .failed(let text) = $0 { text } else { nil } }
    }

    /// An engine that does not really wait between retries, and the waits it was asked for.
    private func quickEngine() -> (AgentEngine, Counter) {
        let waits = Counter()
        return (AgentEngine(retrySleep: { _ in await waits.increment() }), waits)
    }

    @Test func theDescriptionOfACallReachesItsActivityLine() async {
        let described = LLMEvent.toolCalls([ToolCallRequest(id: "d1", name: "describe",
                                                            arguments: #"{"description":"  Conferir se a vaga do Marcus já saiu.\n"}"#),
                                            ToolCallRequest(id: "d2", name: "describe", arguments: "{}")])
        let script = CallScript([[described], [.text("Pronto.")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .auto, runs: Counter(), tools: [DescribedTool()]))
        let started = events.compactMap { event -> ToolCall? in if case .toolStarted(let call) = event { call } else { nil } }
        #expect(started.map(\.intent) == ["Conferir se a vaga do Marcus já saiu", nil])
    }

    // MARK: Retries

    @Test func aTransientFailureBeforeAnyOutputIsRetried() async {
        let (engine, waits) = quickEngine()
        let script = CallScript(replies: [ModelReply([], failure: LLMError.http(status: 529, message: "Overloaded")),
                                        ModelReply([.text("Oi!")])], whenExhausted: .fim)
        let events = await run(engine, request(script, mode: .ask, runs: Counter()))
        #expect(await script.received.count == 2)
        #expect(await waits.value == 1)
        #expect(statuses(events).contains { $0.hasPrefix("Provedor ocupado, tentando de novo em ") })
        #expect(failures(events).isEmpty)
        #expect(messages(events).map(\.role) == [.user, .assistant])
        #expect(messages(events).last?.content == "Oi!")
    }

    @Test func aResponseCutOffBeforeAnyOutputIsRetried() async {
        let (engine, waits) = quickEngine()
        let script = CallScript(replies: [ModelReply([.finished(.incomplete, nil)]), ModelReply([.text("Oi!")])], whenExhausted: .fim)
        let events = await run(engine, request(script, mode: .ask, runs: Counter()))
        #expect(await script.received.count == 2)
        #expect(await waits.value == 1)
        #expect(failures(events).isEmpty)
        #expect(messages(events).last?.content == "Oi!")
    }

    @Test func aResponseCutOffOnEveryAttemptIsReportedAsCutOff() async {
        let (engine, _) = quickEngine()
        let cut = ModelReply([.finished(.incomplete, TokenUsage(input: 10))])
        let script = CallScript(replies: [cut, cut, cut, cut], whenExhausted: .fim)
        let events = await run(engine, request(script, mode: .ask, runs: Counter()))
        #expect(await script.received.count == 4)
        #expect(failures(events) == ["A resposta foi interrompida: o provedor encerrou antes do fim."])
        #expect(messages(events).map(\.role) == [.user])
        let requests = events.compactMap { event -> TokenUsage? in if case .requestUsage(let used) = event { used } else { nil } }
        #expect(requests.count == 4) // each attempt's use is counted once
    }

    @Test func aDroppedConnectionIsNotBlamedOnTheProvider() async {
        let (engine, _) = quickEngine()
        let script = CallScript(replies: [ModelReply([], failure: LLMError.network(code: URLError.timedOut.rawValue, message: "timeout")),
                                        ModelReply([.text("Oi!")])], whenExhausted: .fim)
        let events = await run(engine, request(script, mode: .ask, runs: Counter()))
        #expect(statuses(events).contains { $0.hasPrefix("Conexão caiu, tentando de novo em ") })
        #expect(!statuses(events).contains { $0.hasPrefix("Provedor ocupado") })
    }

    @Test func anOverflowReportedAsATransientErrorSkipsTheRetries() async {
        let (engine, waits) = quickEngine()
        let script = CallScript(replies: [ModelReply([], failure: LLMError.stream(type: "overloaded_error", message: "prompt is too long")),
                                        ModelReply([.text("ok")])], whenExhausted: .fim)
        let events = await run(engine, request(script, mode: .ask, runs: Counter(), history: longHistory()))
        #expect(await waits.value == 0)
        #expect(await script.received.count == 2)
        #expect(failures(events).isEmpty)
        #expect(messages(events).last?.content == "ok")
    }

    @Test func aFailureAfterTextWasShownIsNotRetriedButGoesOnFromTheText() async {
        // The same response is not asked again (it would repeat the text): the text is kept and the turn goes on from it.
        let (engine, waits) = quickEngine()
        let script = CallScript(replies: [ModelReply([.text("Vou começar")], failure: LLMError.http(status: 529, message: "Overloaded")),
                                        ModelReply([.text("e continuo")])], whenExhausted: .fim)
        let events = await run(engine, request(script, mode: .ask, runs: Counter()))
        #expect(await script.received.count == 2)
        #expect(await waits.value == 0)
        #expect(failures(events).isEmpty)
        let recorded = messages(events)
        #expect(recorded.map(\.role) == [.user, .assistant, .assistant])
        #expect(recorded[1].content == "Vou começar\n\n[resposta interrompida]")
        #expect(recorded.last?.content == "e continuo")
    }

    @Test func whatABrokenOffRequestUsedIsStillCounted() async {
        let script = CallScript(replies: [ModelReply([.text("Vou começar"), .finished(.incomplete, TokenUsage(input: 100, output: 3))],
                                                 failure: URLError(.networkConnectionLost))], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .ask, runs: Counter()))
        #expect(failures(events).isEmpty) // gone on once from the text (the next call says "fim")
        let requests = events.compactMap { event -> TokenUsage? in if case .requestUsage(let used) = event { used } else { nil } }
        #expect(requests == [TokenUsage(input: 100, output: 3)])
        let totals = events.compactMap { event -> TokenUsage? in if case .usage(let total) = event { total } else { nil } }
        #expect(totals.last == TokenUsage(input: 100, output: 3))
    }

    @Test func whatTheProviderReportsAheadOfTheAnswerIsAnnouncedButCountedOnce() async {
        let final = TokenUsage(input: 150_000, output: 4)
        let script = CallScript([[.usage(TokenUsage(input: 150_000, output: 1)), .text("oi"), .finished(.done, final)]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .ask, runs: Counter()))
        let pending = events.compactMap { event -> TokenUsage? in if case .pendingUsage(let used) = event { used } else { nil } }
        #expect(pending == [TokenUsage(input: 150_000, output: 1)])
        let requests = events.compactMap { event -> TokenUsage? in if case .requestUsage(let used) = event { used } else { nil } }
        #expect(requests == [final])
    }

    @Test func eachAttemptThatBrokeOffAfterReportingItsUseIsCounted() async {
        let (engine, _) = quickEngine()
        let script = CallScript(replies: [
            ModelReply([.finished(.incomplete, TokenUsage(input: 40))], failure: LLMError.http(status: 529, message: "Overloaded")),
            ModelReply([.text("ok"), .finished(.done, TokenUsage(input: 60, output: 5))]),
        ], whenExhausted: .fim)
        let events = await run(engine, request(script, mode: .ask, runs: Counter()))
        #expect(failures(events).isEmpty)
        let requests = events.compactMap { event -> TokenUsage? in if case .requestUsage(let used) = event { used } else { nil } }
        #expect(requests == [TokenUsage(input: 40), TokenUsage(input: 60, output: 5)]) // the one lost, then the answered one
        let totals = events.compactMap { event -> TokenUsage? in if case .usage(let total) = event { total } else { nil } }
        #expect(totals.last == TokenUsage(input: 100, output: 5))
    }

    @Test func aFailureThatCannotBeRetriedEndsTheTurn() async {
        let (engine, waits) = quickEngine()
        let script = CallScript(replies: [ModelReply([], failure: LLMError.http(status: 401, message: "no"))], whenExhausted: .fim)
        let events = await run(engine, request(script, mode: .ask, runs: Counter()))
        #expect(await script.received.count == 1)
        #expect(await waits.value == 0)
        #expect(failures(events).count == 1)
        #expect(messages(events).map(\.role) == [.user])
    }

    @Test func retriesGiveUpAfterTheLastAttempt() async {
        let (engine, waits) = quickEngine()
        let down = ModelReply([], failure: LLMError.http(status: 503, message: "down"))
        let script = CallScript(replies: [down, down, down, down, down], whenExhausted: .fim)
        let events = await run(engine, request(script, mode: .ask, runs: Counter()))
        #expect(await script.received.count == 4)
        #expect(await waits.value == 3)
        #expect(failures(events).count == 1)
    }

    @Test func aContextOverflowStillRetriesWithLessHistory() async {
        let (engine, waits) = quickEngine()
        let script = CallScript(replies: [ModelReply([], failure: LLMError.contextExceeded("too long")),
                                        ModelReply([.text("ok")])], whenExhausted: .fim)
        let events = await run(engine, request(script, mode: .ask, runs: Counter(), history: longHistory()))
        #expect(await script.received.count == 2)
        #expect(await waits.value == 0) // not a transient failure: no waiting
        #expect(failures(events).isEmpty)
        #expect(messages(events).last?.content == "ok")
    }

    // MARK: Stop reasons

    @Test func aCutOffToolCallIsNotRunAndTheModelIsToldToSplitTheWork() async {
        let runs = Counter()
        let script = CallScript([[touchCall, .finished(.maxTokens, nil)], [.text("Dividi"), .finished(.done, nil)]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .bypass, runs: runs))
        #expect(await runs.value == 0)
        let result = messages(events).first { $0.role == .tool }
        #expect(result?.toolCallID == "c1")
        #expect(result?.isError == true)
        #expect(result?.content.contains("NOT run") == true)
        #expect(result?.content.contains("append") == true)
        #expect(await script.received[1].last?.role == .tool)
        #expect(failures(events).isEmpty)
        #expect(messages(events).last?.content == "Dividi")
    }

    @Test func aReplyCutOffInTextContinuesOnceWithoutShowingTheNudge() async {
        let script = CallScript([[.text("primeira parte"), .finished(.maxTokens, nil)], [.text(" e o resto"), .finished(.done, nil)]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .ask, runs: Counter()))
        #expect(await script.received.count == 2)
        #expect(await script.received[1].last == .user(AgentEngine.continueNudge))
        #expect(messages(events).map(\.role) == [.user, .assistant, .assistant])
        #expect(!messages(events).contains { $0.content == AgentEngine.continueNudge })
        #expect(failures(events).isEmpty)
    }

    @Test func aTurnThatWorkedAndEndsOnAPromiseIsAskedToKeepIt() async {
        let runs = Counter()
        let script = CallScript([[touchCall], [.text("Li o arquivo. Vou adaptar o script agora.")], [touchCall], [.text("Vou conferir de novo.")],
                             [touchCall], [.text("Vou rodar mais uma vez.")], [.text("nunca pedido")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .bypass, runs: runs))
        #expect(await script.received[2].last == .user(AgentEngine.promiseNudge))
        #expect(await script.received[4].last == .user(AgentEngine.promiseNudge), "it worked since the first reminder")
        #expect(await runs.value == 3, "each promised step ran")
        #expect(await script.received.count == 6, "\(AgentEngine.reminderLimit(unattended: false)) reminders a turn at most")
        #expect(!messages(events).contains { $0.content == AgentEngine.promiseNudge })
    }

    private func checkCall(_ id: String, passes: Bool) -> LLMEvent {
        .toolCalls([ToolCallRequest(id: id, name: "run_command", arguments: #"{"command":"swift test","ok":\#(passes)}"#)])
    }

    @Test func aTestThatFailedLastIsNotReportedAsPassing() async {
        let script = CallScript([[checkCall("t1", passes: false)], [.text("Pronto, os testes passaram.")],
                             [checkCall("t2", passes: true)], [.text("Corrigido, tudo passando.")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .bypass, runs: Counter(), tools: [CheckTool()]))
        let reminder = await script.received[2].last
        #expect(reminder?.role == .user && reminder?.content.hasPrefix("Before you finish: the last check you ran (`swift test`)") == true)
        #expect(await script.received.count == 4, "the test passed again: the turn ends")
        #expect(!messages(events).contains { $0.content.hasPrefix("Before you finish") })
    }

    @Test func aFailureTheReplyOwnsUpToOrAPassingTestEndsTheTurn() async {
        let honest = CallScript([[checkCall("t1", passes: false)], [.text("Pronto, mas 2 testes ainda falham: X e Y.")]], whenExhausted: .fim)
        _ = await run(AgentEngine(), request(honest, mode: .bypass, runs: Counter(), tools: [CheckTool()]))
        #expect(await honest.received.count == 2)
        let green = CallScript([[checkCall("t1", passes: false)], [checkCall("t2", passes: true)], [.text("Pronto, tudo passando.")]], whenExhausted: .fim)
        _ = await run(AgentEngine(), request(green, mode: .bypass, runs: Counter(), tools: [CheckTool()]))
        #expect(await green.received.count == 3)
    }

    @Test func aReminderNotActedOnIsNotRepeated() async {
        let script = CallScript([[touchCall], [.text("Vou adaptar o script agora.")], [.text("Vou adaptar, sim.")], [.text("nunca pedido")]], whenExhausted: .fim)
        _ = await run(AgentEngine(), request(script, mode: .bypass, runs: Counter()))
        #expect(await script.received.count == 3)
    }

    @Test func aFirstAnswerThatPromisesToStartNowIsAskedToDoIt() async {
        let runs = Counter()
        let script = CallScript([[.text("Deixa eu olhar os arquivos primeiro.")], [touchCall], [.text("Pronto.")]], whenExhausted: .fim)
        _ = await run(AgentEngine(), request(script, mode: .bypass, runs: runs))
        #expect(await script.received[1].last == .user(AgentEngine.promiseNudge))
        #expect(await runs.value == 1)
    }

    @Test func anUnattendedRunIsNotLeftOnAQuestion() async {
        var unattended = request(CallScript([], whenExhausted: .fim), mode: .bypass, runs: Counter())
        let script = CallScript([[touchCall], [.text("Achei 3 arquivos. Quer que eu apague?")],
                             [.text("Achei 3 arquivos antigos. Sugestão: apagá-los.")]], whenExhausted: .fim)
        unattended.client = CallScriptModel(script: script)
        unattended.unattended = true
        _ = await run(AgentEngine(), unattended)
        #expect(await script.received[2].last == .user(AgentEngine.unattendedNudge))
        #expect(AgentEngine.unattendedNudge.contains("suggestion")) // what was not asked for is only suggested
        #expect(await script.received.count == 3)
        // In a chat the same question is the user's to answer.
        let attended = CallScript([[touchCall], [.text("Achei 3 arquivos. Quer que eu apague?")]], whenExhausted: .fim)
        _ = await run(AgentEngine(), request(attended, mode: .bypass, runs: Counter()))
        #expect(await attended.received.count == 2)
    }

    @Test func aPromiseBeforeAnyWorkOrAQuestionEndsTheTurn() async {
        // The first answer of a turn: nothing was done yet, so "vou" is a reply ("Entendido, vou ignorar a carta").
        let first = CallScript([[.text("Entendido, vou ignorar essa parte.")]], whenExhausted: .fim)
        _ = await run(AgentEngine(), request(first, mode: .bypass, runs: Counter()))
        #expect(await first.received.count == 1)
        #expect(AgentEngine.stopReminder("Entendido, vou seguir estas regras:\n- A\n- B", workedBefore: false, unattended: false) == nil)
        #expect(AgentEngine.stopReminder("Deixa eu ver os logs:", workedBefore: false, unattended: false) == AgentEngine.promiseNudge)
        let asks = CallScript([[touchCall], [.text("Vou publicar agora, pode ser?")]], whenExhausted: .fim)
        _ = await run(AgentEngine(), request(asks, mode: .bypass, runs: Counter()))
        #expect(await asks.received.count == 2)
    }

    @Test func tellsAPromiseFromAStatement() {
        // Endings of real turns: the first three stopped with the work undone, the others are answers.
        for promise in ["Vou adaptar a captura do token para o navegador alternativo.",
                        "Feito o diagnóstico.\n\nVou precisar diagnosticar como o site inicializa o reCAPTCHA, em vez de repetir o teste.",
                        "Em seguida respondo todas as conversas acionáveis.", "Let me check the logs.", "Li o arquivo. Agora vou rodar o build.",
                        "I’ll run it now.", "Deixa eu verificar os logs:", "Vou fazer assim:\n- rodar o build\n- publicar",
                        "I'm going to rebuild it."] {
            #expect(AgentEngine.endsOnPromise(promise), "\(promise)")
        }
        for answer in ["Guardei na memória, então não vou iniciá-la sem o seu sim.", "Não vou inventar resultado.",
                       "Quer que eu revise o nginx.conf agora?", "Vou subir o site, pode ser?", "O site está no ar.",
                       "Vou fazer isso.\n\nPronto: o site está no ar.", "", "Let me know if you need anything.",
                       "Rodei os testes e em seguida corrigi o erro.", "Se você aprovar, vou publicar.",
                       "Os passos a seguir:\n- rodar o build\n- publicar", "Vou rodar o build. Pronto, passou.",
                       "Vou aguardar sua resposta.", "A partir de agora vou responder em português.",
                       "Vou publicar depois que você aprovar.", "Vou te avisar quando o build terminar.",
                       "Caso queira, vou também limpar o cache.", "I'll merge it once you approve."] {
            #expect(!AgentEngine.endsOnPromise(answer), "\(answer)")
        }
    }

    // MARK: Going in circles

    @Test func theThirdCallWithTheSameResultTellsTheModelToChangeCourse() async throws {
        let script = CallScript([[touchCall], [touchCall], [touchCall], [.text("Mudei de caminho")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .bypass, runs: Counter()))
        let results = messages(events).filter { $0.role == .tool }.map(\.content)
        #expect(results == ["ok", "ok", "ok\n\n" + LoopWatch.repeatingNote])
        // The working line says so while the model reads it (the whole call, not "Pensando"), and only then.
        let lines = statuses(events)
        let changing = try #require(lines.firstIndex(of: AgentEngine.changingCourse), "\(lines)")
        #expect(lines[..<changing].filter { $0 == "Tocando" }.count == 3)
        #expect(!lines[changing...].contains("Pensando"), "\(lines)")
    }

    @Test func threeFailuresInARowTellTheModelToStopRetrying() async {
        let calls = (1...3).map { LLMEvent.toolCalls([ToolCallRequest(id: "b\($0)", name: "broken", arguments: #"{"n":\#($0)}"#)]) }
        let script = CallScript(calls.map { [$0] } + [[.text("Não consegui: falta acesso")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .bypass, runs: Counter(), tools: [BrokenTool()]))
        let results = messages(events).filter { $0.role == .tool }.map(\.content)
        #expect(results.count == 3)
        #expect(!results[1].contains("[Orb:"))
        #expect(results[2].hasSuffix(LoopWatch.failingNote))
    }

    @Test func onScreenTheSameWordsAreNoLoopButFailuresStillAre() {
        let scroll = ToolCallRequest(id: "s", name: "browse_scroll", arguments: "{}")
        var watch = LoopWatch()
        for _ in 1...6 { watch.record(scroll, result: "Scrolled down 600 px.", failed: false, live: true) }
        #expect(watch.note() == nil)
        for _ in 1...3 { watch.record(scroll, result: "Error", failed: true, live: true) }
        #expect(watch.note() == LoopWatch.failingNote)
        #expect(watch.note() == nil, "told once")
        // A success in between starts the count of failures over.
        let read = ToolCallRequest(id: "r", name: "read_file", arguments: #"{"path":"a"}"#)
        watch.record(read, result: "x", failed: true)
        watch.record(read, result: "y", failed: false)
        watch.record(read, result: "x", failed: true)
        #expect(watch.note() == nil)
    }

    @Test func theSameOutputAtAnotherMomentIsStillTheSameResult() {
        let run = ToolCallRequest(id: "c", name: "run_command", arguments: #"{"command":"make"}"#)
        var watch = LoopWatch()
        for (second, file) in [(1, "a1b2c3d4"), (7, "e5f6a7b8"), (9, "0c0d0e0f")] {
            watch.record(run, result: """
                Código de saída: 2
                2026-10-12T14:0\(second):11Z build took 1.\(second)s, request_id: r-\(second)
                [full output saved at /tmp/orb-saidas/x/comando-\(file).txt (900 lines, 40 KB); read it with read_file]
                """, failed: false)
        }
        #expect(watch.note() == LoopWatch.repeatingNote)
        // A job being waited on is not a loop, even when a quiet log reads the same for a minute; a page fetched again is.
        #expect(LoopWatch.isLive("job_output", kind: .shell) && LoopWatch.isLive("browse_scroll", kind: .browser))
        #expect(!LoopWatch.isLive("web_fetch", kind: .browser) && !LoopWatch.isLive("run_command", kind: .shell))
        let poll = ToolCallRequest(id: "j", name: "job_output", arguments: #"{"id":"1"}"#)
        for _ in 1...3 { watch.record(poll, result: "Processo 1 (rodando há 2 min): make\n…", failed: false, live: true) }
        #expect(watch.note() == nil)
    }

    @Test func aMessageSentDuringTheTurnReachesTheModelFramedAndTheChatAsWritten() async {
        let queue = SteeringQueue()
        var bot = Bot(name: "Teste", role: "", orb: OrbConfig(), permissionMode: .bypass)
        bot.permissionRules = []
        let script = CallScript([[touchCall], [.text("Feito, na pasta X")]], whenExhausted: .fim)
        let steered = TurnRequest(bot: bot, model: "fake", system: "sys", history: [], prompt: "oi",
                                  client: CallScriptModel(script: script), tools: [SteeringTouchTool(queue: queue)],
                                  context: ToolContext(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory())),
                                  maxSteps: 5, steering: queue)
        let events = await run(AgentEngine(), steered)
        let sent = await script.received[1].filter { $0.role == .user }.map(\.content)
        #expect(sent == ["oi", AgentEngine.steeringFrame + "\n\nuse a pasta X"])
        #expect(messages(events).filter { $0.role == .user }.map(\.content) == ["oi", "use a pasta X"])
    }

    @Test func aCutOffWithNoTextRecordsNoEmptyAssistantMessage() async {
        let script = CallScript([[.finished(.maxTokens, nil)], [.text("ok"), .finished(.done, nil)]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .ask, runs: Counter()))
        #expect(await script.received.count == 2)
        #expect(await script.received[1].last == .user(AgentEngine.continueNudge))
        #expect(!messages(events).contains { $0.role == .assistant && $0.content.isEmpty && $0.toolCalls.isEmpty })
        #expect(messages(events).map(\.role) == [.user, .assistant])
        #expect(failures(events).isEmpty)
    }

    @Test func aCutOffToolCallOnTheWarningStepStillCarriesTheWarning() async {
        let script = CallScript([[touchCall, .finished(.maxTokens, nil)], [.text("Dividi"), .finished(.done, nil)]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .bypass, runs: Counter(), maxSteps: 4))
        let result = messages(events).first { $0.role == .tool }
        #expect(result?.content.hasSuffix(AgentEngine.stepWarning(remaining: 3)) == true)
        #expect(result?.content.hasPrefix(AgentEngine.cutOffResult) == true)
    }

    @Test func aCutOffPastTheLimitEndsWithANotice() async {
        let cut = [LLMEvent.text("texto"), .finished(.maxTokens, nil)]
        let script = CallScript([cut, cut, cut, cut], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .ask, runs: Counter()))
        #expect(await script.received.count == AgentEngine.cutContinueLimit + 1)
        #expect(events.notices.count == 1)
        #expect(failures(events).isEmpty)
    }

    @Test func aRefusalEndsAsAFailure() async {
        let script = CallScript([[.text("Não posso ajudar com isso."), .finished(.refusal, nil)]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .ask, runs: Counter()))
        #expect(failures(events).first?.hasPrefix("O modelo recusou") == true)
        #expect(messages(events).last?.content == "Não posso ajudar com isso.")
    }

    @Test func aSecondEmptyReplyIsAFailureNotASuccess() async {
        for reply in [[LLMEvent.finished(.done, nil)], [.text("  \n"), .finished(.done, nil)], []] {
            let script = CallScript([reply, reply], whenExhausted: .fim)
            let events = await run(AgentEngine(), request(script, mode: .ask, runs: Counter()))
            #expect(failures(events) == [AgentEngine.silenceFailure])
            #expect(messages(events).map(\.role) == [.user])
            #expect(await script.received.count == 2)
        }
    }

    @Test func anEmptyReplyGetsOneMoreTryToldWhy() async {
        let script = CallScript([[touchCall], [.finished(.done, nil)], [.text("Pronto")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .auto, runs: Counter()))
        #expect(failures(events).isEmpty)
        #expect(await script.received[2].last?.content == AgentEngine.silenceNudge)
        // The nudge steers the turn only: the chat keeps what the user and the model said.
        #expect(messages(events).map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(messages(events).last?.content == "Pronto")
    }

    @Test func anIncompleteReplyIsAFailureThatKeepsWhatWasShown() async {
        let script = CallScript([[.text("quase"), .finished(.incomplete, nil)]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .ask, runs: Counter()))
        #expect(failures(events).count == 1)
        #expect(messages(events).last?.content == "quase" + AgentEngine.interruptedMarker)
    }

    @Test func aContextLimitStopWithNothingShownRetriesWithLessHistory() async {
        let script = CallScript([[.finished(.contextExceeded, nil)], [.text("ok"), .finished(.done, nil)]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .ask, runs: Counter(), history: longHistory()))
        #expect(await script.received.count == 2)
        #expect(failures(events).isEmpty)
    }

    // MARK: Usage

    @Test func usageIsSummedOverTheTurn() async {
        let script = CallScript([[touchCall, .finished(.toolUse, TokenUsage(input: 100, output: 10, cacheRead: nil, cacheWrite: 5))],
                             [.text("ok"), .finished(.done, TokenUsage(input: 20, output: 7, cacheRead: 100, cacheWrite: nil))]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .auto, runs: Counter()))
        let reported = events.compactMap { if case .usage(let usage) = $0 { usage } else { nil } }
        #expect(reported.count == 2)
        #expect(reported.last == TokenUsage(input: 120, output: 17, cacheRead: 100, cacheWrite: 5))
    }

    @Test func noUsageEventWhenTheProviderReportsNone() async {
        let events = await run(AgentEngine(), request(CallScript([[.text("oi")]], whenExhausted: .fim), mode: .ask, runs: Counter()))
        #expect(!events.contains { if case .usage = $0 { true } else { false } })
    }

    // MARK: Step budget

    @Test func theModelIsWarnedWhenThreeStepsRemainAndTheLastStepHasNoTools() async {
        let looks = [LLMEvent.toolCalls([lookCall("a")])]
        let script = CallScript([looks, looks, looks, looks, [.text("Resumo"), .finished(.done, nil)]], whenExhausted: .fim)
        let tools: [any AgentTool] = [LookTool(gauge: Gauge())]
        let events = await run(AgentEngine(), request(script, mode: .ask, runs: Counter(), tools: tools, maxSteps: 5))
        #expect(await script.calls.map(\.toolChoice) == [.auto, .auto, .auto, .auto, .none])
        let results = messages(events).filter { $0.role == .tool }.map(\.content)
        #expect(results.count == 4)
        let warning = AgentEngine.stepWarning(remaining: 3)
        #expect(warning.hasPrefix("[Orb: restam 3 passos neste turno;"))
        // Only the result of the step after which 3 remain carries it, at the end.
        #expect(results.map { $0.hasSuffix(warning) } == [false, true, false, false])
        #expect(results[1] == "viu x\n\n" + warning)
        #expect(events.notices == [AgentEngine.pausedNotice(after: 5)])
        #expect(failures(events).isEmpty)
    }

    @Test func toolCallsOnTheLastStepAreNotRunAndTheTurnPauses() async {
        let runs = Counter()
        let script = CallScript([[touchCall], [touchCall], [touchCall]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .bypass, runs: runs, maxSteps: 3))
        #expect(await runs.value == 2)
        #expect(await script.calls.map(\.toolChoice).last == ToolChoice.none)
        #expect(events.notices == [AgentEngine.pausedNotice(after: 3)])
        #expect(failures(events).isEmpty)
        // No call is left without an answer in the history.
        #expect(messages(events).filter { $0.role == .tool }.count == 2)
        // The task leaves a record of where it stands for the "continua" that follows (roles keep alternating).
        let last = messages(events).last
        #expect(last?.role == .assistant)
        #expect(last?.content.hasPrefix(ProgressRecord.marker) == true)
        #expect(last?.content.contains("[passo 1] touch") == true)
    }

    @Test func theProgressRecordKeepsTheStepsBeforeAMessageQueuedDuringTheTurn() async {
        let queue = SteeringQueue()
        var bot = Bot(name: "Teste", role: "", orb: OrbConfig(), permissionMode: .bypass)
        bot.permissionRules = []
        let script = CallScript([[touchCall], [touchCall], [touchCall]], whenExhausted: .fim)
        let steered = TurnRequest(bot: bot, model: "fake", system: "sys", history: [], prompt: "oi",
                                  client: CallScriptModel(script: script), tools: [SteeringTouchTool(queue: queue)],
                                  context: ToolContext(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory())),
                                  maxSteps: 3, steering: queue)
        let events = await run(AgentEngine(), steered)
        let last = messages(events).last
        #expect(last?.content.hasPrefix(ProgressRecord.marker) == true)
        // The message "use a pasta X" came after step 1; both steps belong to the same task.
        #expect(last?.content.contains("[passo 1] touch") == true)
        #expect(last?.content.contains("[passo 2] touch") == true)
    }

    @Test func aTurnThatFinishesEarlyNeverSeesTheLimit() async {
        let script = CallScript([[touchCall], [.text("Feito")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .auto, runs: Counter(), maxSteps: 5))
        #expect(await script.calls.map(\.toolChoice) == [.auto, .auto])
        #expect(events.notices.isEmpty)
        #expect(!messages(events).contains { $0.content.contains("[Orb:") })
    }

    // MARK: Task plan

    private func planCall(_ id: String, _ json: String) -> LLMEvent {
        .toolCalls([ToolCallRequest(id: id, name: TaskPlanTool.name, arguments: json)])
    }

    private func touch(_ step: Int) -> LLMEvent {
        .toolCalls([ToolCallRequest(id: "t\(step)", name: "touch", arguments: #"{"n": \#(step)}"#)])
    }

    private var plannedSteps: TaskPlan {
        TaskPlan(goal: "Publicar o site", steps: [TaskPlan.Step(text: "Gerar o build"), TaskPlan.Step(text: "Subir")], next: "gerar o build")
    }

    @Test func theModelMakesAPlanUpdatesItAndIsSentItAsItIsNow() async {
        let script = CallScript([
            [planCall("p1", #"{"action": "set", "goal": "Publicar o site", "steps": ["Gerar o build", "Subir"]}"#)],
            [planCall("p2", #"{"action": "update", "updates": [{"step": 1, "state": "done"}], "next": "subir"}"#)],
            [.text("Build feito; falta subir.")],
        ], whenExhausted: .fim)
        var turn = request(script, mode: .ask, runs: Counter(), tools: [TaskPlanTool(), TouchTool(runs: Counter())])
        let board = TaskPlanBoard()
        turn.context.taskPlan = board
        let events = await run(AgentEngine(), turn)
        // Safe: no approval was asked for, even with the Orb asking before everything.
        #expect(!events.contains { if case .approval = $0 { true } else { false } })
        let received = await script.received
        // The 4th request: "Subir" is still open when the reply ends the task, so the model is reminded once (`PlanReminder`).
        #expect(received.count == 4)
        #expect(received[3].last == .user(PlanReminder.text(open: [2])))
        #expect(received[1].last?.content.contains("1. [ ] Gerar o build") == true)
        let sent = received[2].last?.content ?? ""
        #expect(sent.contains("1. [feita] Gerar o build"))
        #expect(sent.contains("2. [ ] Subir"))
        #expect(sent.contains("Próximo passo: subir"))
        #expect(board.plan?.steps.map(\.state) == [.done, .pending])
        // The conversation keeps the same plan from the messages the turn recorded.
        var chat = Conversation()
        for message in messages(events) { chat.absorb(message) }
        #expect(chat.taskPlan?.steps == board.plan?.steps)
        #expect(chat.taskPlan?.next == "subir")
    }

    @Test func anOpenPlanIsRecitedWhenTheModelHasNotSeenItForAWhile() async {
        let interval = AgentEngine.planRecitalInterval
        let script = CallScript((1...interval + 1).map { [touch($0)] } + [[.text("Pronto")]], whenExhausted: .fim)
        var turn = request(script, mode: .bypass, runs: Counter())
        turn.context.taskPlan = TaskPlanBoard(plannedSteps)
        _ = await run(AgentEngine(), turn)
        let received = await script.received
        // The results of step `interval` end with the plan; the steps before it do not carry it.
        #expect(received[interval].last?.content.hasSuffix(plannedSteps.compact()) == true)
        #expect(!received[1...(interval - 1)].contains { $0.last?.content.contains(TaskPlan.heading) == true })
        #expect(received[interval + 1].last?.content.contains(TaskPlan.heading) == false)
    }

    @Test func aFinishedPlanIsNeverRecited() async {
        var finished = plannedSteps
        for index in finished.steps.indices { finished.steps[index].state = .done }
        let interval = AgentEngine.planRecitalInterval
        let script = CallScript((1...interval + 1).map { [touch($0)] } + [[.text("Pronto")]], whenExhausted: .fim)
        var turn = request(script, mode: .bypass, runs: Counter())
        turn.context.taskPlan = TaskPlanBoard(finished)
        _ = await run(AgentEngine(), turn)
        #expect(!(await script.received).contains { $0.contains { $0.content.contains(TaskPlan.heading) } })
    }

    @Test func aTurnPausedAtTheStepLimitWritesThePlanInItsRecord() async {
        let script = CallScript([[touch(1)], [touch(2)], [touch(3)]], whenExhausted: .fim)
        var turn = request(script, mode: .bypass, runs: Counter(), maxSteps: 3)
        turn.context.taskPlan = TaskPlanBoard(plannedSteps)
        let events = await run(AgentEngine(), turn)
        let record = messages(events).last?.content ?? ""
        #expect(record.hasPrefix(ProgressRecord.marker + "\n" + plannedSteps.compact()))
        #expect(record.contains("Próximo passo: gerar o build"))
        #expect(record.contains("[passo 1] touch"))
    }

    // MARK: Parallel tools

    @Test func readOnlyCallsRunAtTheSameTimeAndKeepTheirOrder() async {
        let gauge = Gauge()
        let calls = [lookCall("a", ms: 300, name: "A", together: 3), lookCall("b", ms: 200, name: "B", together: 3),
                     lookCall("c", ms: 100, name: "C", together: 3)]
        let script = CallScript([[.toolCalls(calls)], [.text("Pronto")]], whenExhausted: .fim)
        let tools: [any AgentTool] = [LookTool(gauge: gauge)]
        let events = await run(AgentEngine(), request(script, mode: .ask, runs: Counter(), tools: tools))
        #expect(await gauge.peak == 3)
        let results = messages(events).filter { $0.role == .tool }
        #expect(results.map(\.toolCallID) == ["a", "b", "c"])
        #expect(results.map(\.content) == ["viu A", "viu B", "viu C"])
        #expect(approvals(events).isEmpty)
    }

    @Test func aReplyWithManyReadsRunsAFewAtATime() async {
        let gauge = Gauge()
        let count = AgentEngine.parallelTools * 2 + 3
        // The first ones wait until a full share runs together; with no cap, the rest would join them.
        let calls = (0..<count).map { lookCall("r\($0)", ms: 50, name: "\($0)", together: $0 < AgentEngine.parallelTools ? AgentEngine.parallelTools : nil) }
        let script = CallScript([[.toolCalls(calls)], [.text("Pronto")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), request(script, mode: .ask, runs: Counter(), tools: [LookTool(gauge: gauge)]))
        #expect(await gauge.peak == AgentEngine.parallelTools)
        #expect(messages(events).filter { $0.role == .tool }.map(\.toolCallID) == calls.map(\.id))
    }

    @Test func callsThatChangeThingsStayInOrderBetweenParallelReads() async {
        let gauge = Gauge()
        let runs = Counter()
        let calls = [lookCall("a", ms: 100, together: 2), lookCall("b", ms: 100, together: 2), ToolCallRequest(id: "c", name: "touch", arguments: "{}"),
                     lookCall("d", ms: 100)]
        let script = CallScript([[.toolCalls(calls)], [.text("Pronto")]], whenExhausted: .fim)
        let tools: [any AgentTool] = [LookTool(gauge: gauge), TouchTool(runs: runs)]
        let events = await run(AgentEngine(), request(script, mode: .auto, runs: runs, tools: tools))
        #expect(await gauge.peak == 2) // a and b together; d waits for the touch
        #expect(await runs.value == 1)
        #expect(messages(events).filter { $0.role == .tool }.map(\.toolCallID) == ["a", "b", "c", "d"])
    }

    // MARK: Errors flagged

    @Test func failedToolCallsAreFlaggedAsErrors() async {
        let calls = [ToolCallRequest(id: "a", name: "nope", arguments: "{}"),
                     ToolCallRequest(id: "b", name: "broken", arguments: "{bad"),
                     ToolCallRequest(id: "c", name: "broken", arguments: "{}"),
                     ToolCallRequest(id: "d", name: "look", arguments: "{}"),
                     ToolCallRequest(id: "e", name: "sad", arguments: "{}")]
        let script = CallScript([[.toolCalls(calls)], [.text("Ok")]], whenExhausted: .fim)
        let tools: [any AgentTool] = [BrokenTool(), LookTool(gauge: Gauge()), SadTool()]
        let events = await run(AgentEngine(), request(script, mode: .auto, runs: Counter(), tools: tools))
        let results = messages(events).filter { $0.role == .tool }
        #expect(results.map(\.isError) == [true, true, true, false, true])
        #expect(results[2].content == "Error: não deu")
    }

    @Test func aDeniedOrBlockedCallIsFlaggedAsAnError() async {
        let denied = await run(AgentEngine(), request(CallScript([[touchCall], [.text("ok")]], whenExhausted: .fim), mode: .ask, runs: Counter()), decision: .deny)
        #expect(messages(denied).first { $0.role == .tool }?.isError == true)
        let blocked = await run(AgentEngine(), request(CallScript([[touchCall], [.text("ok")]], whenExhausted: .fim), mode: .readOnly, runs: Counter()))
        #expect(messages(blocked).first { $0.role == .tool }?.isError == true)
        let ran = await run(AgentEngine(), request(CallScript([[touchCall], [.text("ok")]], whenExhausted: .fim), mode: .auto, runs: Counter()))
        #expect(messages(ran).first { $0.role == .tool }?.isError == false)
    }
}

/// Mode and rules the way the app keeps them: changed from outside while a turn runs.
private actor PermissionBox {
    private(set) var state: PermissionState
    init(mode: PermissionMode, rules: [PermissionRule] = []) { state = PermissionState(mode: mode, rules: rules) }
    func set(mode: PermissionMode) { state.mode = mode }
    func set(rules: [PermissionRule]) { state.rules = rules }
    func add(_ rule: PermissionRule) { state.rules.append(rule) }
}

struct AgentEngineGatingTests {
    private let touchRule = PermissionRule(family: .writeFiles)
    private let touchCall = LLMEvent.toolCalls([ToolCallRequest(id: "c1", name: "touch", arguments: "{}")])
    private let dangerousCall = LLMEvent.toolCalls([ToolCallRequest(id: "c1", name: "touch", arguments: #"{"command":"rm -rf ~/Projetos"}"#)])

    private func request(_ client: any LLMClient, box: PermissionBox, tools: [any AgentTool], mode: PermissionMode = .ask,
                         directory: URL = URL(fileURLWithPath: NSTemporaryDirectory()), grants: [PermissionRule] = []) -> TurnRequest {
        let bot = Bot(name: "Teste", role: "", orb: OrbConfig(), permissionMode: mode)
        return TurnRequest(bot: bot, model: "fake", system: "sys", history: [], prompt: "oi", client: client, tools: tools,
                           context: ToolContext(workingDirectory: directory), turnGrants: grants, permissions: { await box.state })
    }

    /// Collects the events; `onApproval` plays the user (or the app).
    private func drive(_ engine: AgentEngine, _ request: TurnRequest,
                       onApproval: @Sendable (ApprovalRequest) async -> Void) async -> [TurnEvent] {
        var events: [TurnEvent] = []
        for await event in engine.run(request) {
            events.append(event)
            if case .approval(let approval) = event { await onApproval(approval) }
        }
        return events
    }

    private func approvals(_ events: [TurnEvent]) -> [ApprovalRequest] {
        events.compactMap { if case .approval(let approval) = $0 { approval } else { nil } }
    }

    private func toolMessages(_ events: [TurnEvent]) -> [String] {
        events.compactMap { if case .message(let message) = $0, message.role == .tool { message.content } else { nil } }
    }

    @Test func aReadOnlyBlockStartsAndFinishesTheToolRow() async {
        let runs = Counter()
        let box = PermissionBox(mode: .readOnly)
        let events = await drive(AgentEngine(), request(CallScriptModel(script: CallScript([[touchCall], [.text("Ok")]], whenExhausted: .fim)), box: box,
                                                        tools: [TouchTool(runs: runs)]), onApproval: { _ in })
        var started: [UUID] = [], finished: [(UUID, ToolCall.State)] = []
        for event in events {
            if case .toolStarted(let call) = event { started.append(call.id) }
            if case .toolFinished(let id, let state, _, _) = event { finished.append((id, state)) }
        }
        #expect(started.count == 1 && finished.count == 1)
        #expect(finished.first?.0 == started.first && finished.first?.1 == .failed)
        #expect(await runs.value == 0)
        #expect(toolMessages(events).first?.contains("read-only") == true)
    }

    @Test func switchingToReadOnlyWhileACardIsOpenDeniesIt() async {
        let runs = Counter()
        let box = PermissionBox(mode: .ask)
        let engine = AgentEngine()
        let req = request(CallScriptModel(script: CallScript([[touchCall], [.text("Ok")]], whenExhausted: .fim)), box: box, tools: [TouchTool(runs: runs)])
        let events = await drive(engine, req) { approval in
            await box.set(mode: .readOnly)
            let answered = await engine.gate.applyModeChange(to: .readOnly, for: req.bot.id)
            #expect(answered.map(\.approvalID) == [approval.id] && answered.map(\.decision) == [.deny])
        }
        #expect(await runs.value == 0)
        #expect(toolMessages(events).first?.contains("read-only") == true)
        #expect(events.contains { if case .toolFinished(_, .failed, let output, _) = $0 { output?.contains("Só leitura") == true } else { false } })
    }

    @Test func switchingToNoQuestionsWhileACardIsOpenAllowsIt() async {
        let runs = Counter()
        let box = PermissionBox(mode: .ask)
        let engine = AgentEngine()
        let req = request(CallScriptModel(script: CallScript([[touchCall], [.text("Ok")]], whenExhausted: .fim)), box: box, tools: [TouchTool(runs: runs)])
        _ = await drive(engine, req) { _ in
            await box.set(mode: .bypass)
            await engine.gate.applyModeChange(to: .bypass, for: req.bot.id)
        }
        #expect(await runs.value == 1)
    }

    @Test func automaticLeavesDangerousCardsOpenAndAnswersTheOthers() async {
        let engine = AgentEngine()
        let box = PermissionBox(mode: .ask)

        let dangerRuns = Counter()
        let dangerReq = request(CallScriptModel(script: CallScript([[dangerousCall], [.text("Ok")]], whenExhausted: .fim)), box: box, tools: [TouchTool(runs: dangerRuns)])
        _ = await drive(engine, dangerReq) { approval in
            await box.set(mode: .auto)
            let answered = await engine.gate.applyModeChange(to: .auto, for: dangerReq.bot.id)
            #expect(answered.isEmpty)
            #expect(await engine.gate.openIDs(for: dangerReq.bot.id) == [approval.id])
            await engine.gate.resolve(approvalID: approval.id, decision: .deny)
        }
        #expect(await dangerRuns.value == 0)

        let runs = Counter()
        let plain = request(CallScriptModel(script: CallScript([[touchCall], [.text("Ok")]], whenExhausted: .fim)), box: PermissionBox(mode: .ask), tools: [TouchTool(runs: runs)])
        _ = await drive(engine, plain) { _ in await engine.gate.applyModeChange(to: .auto, for: plain.bot.id) }
        #expect(await runs.value == 1)
    }

    @Test func aModeChangeBetweenStepsAppliesToTheNextCall() async {
        let runs = Counter()
        let box = PermissionBox(mode: .auto)
        let client = CallScriptModel(script: CallScript([[touchCall], [touchCall], [.text("Pronto")]], whenExhausted: .fim) { index in
            if index == 1 { await box.set(mode: .readOnly) }
        })
        let events = await drive(AgentEngine(), request(client, box: box, tools: [TouchTool(runs: runs)]), onApproval: { _ in })
        #expect(await runs.value == 1)
        #expect(toolMessages(events).count == 2 && toolMessages(events)[1].contains("read-only"))
    }

    @Test func aRevokedGrantAsksAgainOnTheNextCall() async {
        let runs = Counter()
        let box = PermissionBox(mode: .ask, rules: [touchRule])
        let client = CallScriptModel(script: CallScript([[touchCall], [touchCall], [.text("Pronto")]], whenExhausted: .fim) { index in
            if index == 1 { await box.set(rules: []) }
        })
        let engine = AgentEngine()
        let events = await drive(engine, request(client, box: box, tools: [TouchTool(runs: runs)])) { approval in
            await engine.gate.resolve(approvalID: approval.id, decision: .deny)
        }
        #expect(approvals(events).count == 1)
        #expect(await runs.value == 1)
    }

    @Test func onlyThisTaskCoversTheRestOfTheTurnAndNoMore() async {
        let runs = Counter()
        let engine = AgentEngine()
        let box = PermissionBox(mode: .ask)
        let first = request(CallScriptModel(script: CallScript([[touchCall], [touchCall], [.text("Pronto")]], whenExhausted: .fim)), box: box, tools: [TouchTool(runs: runs)])
        let events = await drive(engine, first) { approval in
            #expect(approval.suggestions == [touchRule])
            await engine.gate.resolve(approvalID: approval.id, decision: .task)
        }
        #expect(approvals(events).count == 1)
        #expect(await runs.value == 2)
        // The next turn starts from the saved rules again.
        let second = request(CallScriptModel(script: CallScript([[touchCall], [.text("Pronto")]], whenExhausted: .fim)), box: box, tools: [TouchTool(runs: runs)])
        let again = await drive(engine, second) { approval in await engine.gate.resolve(approvalID: approval.id, decision: .deny) }
        #expect(approvals(again).count == 1)
        #expect(await runs.value == 2)
    }

    @Test func aTaskGrantNeverCoversADangerousCall() async {
        let runs = Counter()
        let engine = AgentEngine()
        let req = request(CallScriptModel(script: CallScript([[dangerousCall], [dangerousCall], [.text("Pronto")]], whenExhausted: .fim)), box: PermissionBox(mode: .ask),
                          tools: [TouchTool(runs: runs)], grants: [touchRule])
        let events = await drive(engine, req) { approval in
            #expect(approval.suggestions.isEmpty)
            #expect(approval.reason.hasPrefix("Comando arriscado"))
            await engine.gate.resolve(approvalID: approval.id, decision: .task)
        }
        #expect(approvals(events).count == 2)
        #expect(await runs.value == 2)
    }

    @Test func alwaysSavesTheChosenRuleWhereTheEngineReadsIt() async {
        let runs = Counter()
        let engine = AgentEngine()
        let box = PermissionBox(mode: .ask)
        let req = request(CallScriptModel(script: CallScript([[touchCall], [touchCall], [.text("Pronto")]], whenExhausted: .fim)), box: box, tools: [TouchTool(runs: runs)])
        let events = await drive(engine, req) { approval in
            // What `AppModel.decide` does: save the rule, then answer.
            await box.add(touchRule)
            await engine.gate.resolve(approvalID: approval.id, answer: ApprovalAnswer(decision: .always, rule: touchRule))
        }
        #expect(approvals(events).count == 1)
        #expect(await runs.value == 2)
    }

    @Test func grantsGivenWithTheRequestSkipTheCardForThatTurn() async {
        let runs = Counter()
        let req = request(CallScriptModel(script: CallScript([[touchCall], [.text("Pronto")]], whenExhausted: .fim)), box: PermissionBox(mode: .ask),
                          tools: [TouchTool(runs: runs)], grants: [touchRule])
        let events = await drive(AgentEngine(), req, onApproval: { _ in })
        #expect(approvals(events).isEmpty)
        #expect(await runs.value == 1)
    }

    @Test func stoppingTheTurnWhileACardIsOpenEndsTheWait() async {
        let runs = Counter()
        let engine = AgentEngine()
        let req = request(CallScriptModel(script: CallScript([[touchCall], [.text("Ok")]], whenExhausted: .fim)), box: PermissionBox(mode: .ask), tools: [TouchTool(runs: runs)])
        let consumer = Task {
            for await event in engine.run(req) {
                if case .approval = event { return true }
            }
            return false
        }
        #expect(await consumer.value)
        // Leaving the stream cancels the turn; its wait must not stay behind.
        await waitUntil("the stopped turn's wait to close") { await engine.gate.openIDs(for: req.bot.id).isEmpty }
        #expect(await engine.gate.openIDs(for: req.bot.id).isEmpty)
        #expect(await runs.value == 0)
    }

    @Test func writesInsideTheOrbsFolderRunWithoutACardOutsideItAsk() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbGate-\(UUID().uuidString)")
        let other = FileManager.default.temporaryDirectory.appending(path: "OrbGateOther-\(UUID().uuidString)")
        for url in [folder, other] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: other) }
        let engine = AgentEngine()
        func call(_ path: String) -> LLMEvent {
            .toolCalls([ToolCallRequest(id: "w", name: "write_file", arguments: JSONValue.object(["path": .string(path), "content": .string("oi")]).jsonString)])
        }

        let inside = request(CallScriptModel(script: CallScript([[call("nota.txt")], [.text("Ok")]], whenExhausted: .fim)), box: PermissionBox(mode: .ask),
                             tools: [WriteFileTool()], directory: folder)
        let insideEvents = await drive(engine, inside, onApproval: { _ in })
        #expect(approvals(insideEvents).isEmpty)
        #expect(try String(contentsOf: folder.appending(path: "nota.txt"), encoding: .utf8) == "oi")

        let outside = request(CallScriptModel(script: CallScript([[call(other.appending(path: "x.txt").path)], [.text("Ok")]], whenExhausted: .fim)), box: PermissionBox(mode: .ask),
                              tools: [WriteFileTool()], directory: folder)
        let outsideEvents = await drive(engine, outside) { approval in await engine.gate.resolve(approvalID: approval.id, decision: .deny) }
        #expect(approvals(outsideEvents).count == 1)
        #expect(!FileManager.default.fileExists(atPath: other.appending(path: "x.txt").path))
    }
}

struct ApprovalGateTests {
    @Test func anAnswerBeforeTheWaitIsKept() async {
        let gate = ApprovalGate()
        let id = UUID(), bot = UUID()
        await gate.open(id, botID: bot)
        await gate.resolve(approvalID: id, decision: .once)
        #expect(await gate.wait(for: id) == .once)
        // A card is answered once, then it is gone.
        await gate.resolve(approvalID: id, decision: .deny)
        #expect(await gate.wait(for: id) == .deny)
    }

    @Test func aWaitEndsWhenTheTaskIsCancelled() async {
        let gate = ApprovalGate()
        let id = UUID()
        await gate.open(id, botID: UUID())
        let waiter = Task { await gate.wait(for: id) }
        // Cancelled while it is really suspended in the wait (the other order is the next test).
        await waitUntil("the waiter to be suspended in the gate") { await gate.isWaiting(for: id) }
        waiter.cancel()
        #expect(await waiter.value == .deny)
    }

    @Test func aTaskCancelledBeforeWaitingDoesNotHang() async {
        let gate = ApprovalGate()
        let id = UUID()
        await gate.open(id, botID: UUID())
        let waiter = Task {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return await gate.wait(for: id)
        }
        waiter.cancel()
        #expect(await waiter.value == .deny)
    }

    @Test func stoppingAnOrbDeniesOnlyItsCards() async {
        let gate = ApprovalGate()
        let mine = UUID(), theirs = UUID(), botA = UUID(), botB = UUID()
        await gate.open(mine, botID: botA)
        await gate.open(theirs, botID: botB)
        let waiting = Task { await gate.wait(for: mine) }
        await gate.cancelApprovals(for: botA)
        #expect(await waiting.value == .deny)
        #expect(await gate.openIDs(for: botB) == [theirs])
    }

    @Test func modeChangesAnswerWhatTheNewModeWouldNotAsk() async {
        let gate = ApprovalGate()
        let bot = UUID(), plain = UUID(), risky = UUID()
        await gate.open(plain, botID: bot)
        await gate.open(risky, botID: bot, alwaysAsks: true)
        #expect(await gate.applyModeChange(to: .ask, for: bot).isEmpty)
        let auto = await gate.applyModeChange(to: .auto, for: bot)
        #expect(auto.map(\.approvalID) == [plain] && auto.map(\.decision) == [.once])
        #expect(await gate.openIDs(for: bot) == [risky])
        let bypass = await gate.applyModeChange(to: .bypass, for: bot)
        #expect(bypass.map(\.approvalID) == [risky])
        await gate.open(plain, botID: bot)
        #expect(await gate.applyModeChange(to: .readOnly, for: bot).map(\.decision) == [.deny])
    }

}

struct ModelTests {
    @Test func unansweredToolCallsGetAResult() {
        let call = ToolCallRequest(id: "c1", name: "touch", arguments: "{}")
        let history: [ChatMessage] = [.user("oi"), ChatMessage(role: .assistant, content: "", toolCalls: [call]), .user("de novo")]
        let repaired = history.answeringDanglingToolCalls()
        #expect(repaired.map(\.role) == [.user, .assistant, .tool, .user])
        #expect(repaired[2].toolCallID == "c1")
        #expect(repaired.answeringDanglingToolCalls() == repaired)
    }

    /// The real call site (`AppModel.send`) passes the history WITHOUT the new prompt, so the last turn of the
    /// history is a finished one: its outputs are shortened too.
    @Test func modelContextShortensOutputsOfTheLastFinishedTurn() {
        let call = ToolCallRequest(id: "c1", name: "touch", arguments: "{}")
        let history: [ChatMessage] = [
            .user("velho"), ChatMessage(role: .assistant, content: "", toolCalls: [call]),
            .tool("c1", String(repeating: "x", count: 10_000)), ChatMessage(role: .assistant, content: "ok"),
        ]
        let sent = history.modelContext()
        #expect(sent.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(sent[2].content.count < 5000)
        #expect(sent[0] == .user("velho"))
    }

    @Test func reopeningClosesAnInterruptedTurn() {
        var conversation = Conversation()
        conversation.items = [
            TranscriptItem(.bot(text: "meio", isStreaming: true)),
            TranscriptItem(.tool(ToolCall(kind: .shell, title: "t", detail: "d"))),
            TranscriptItem(.approval(ApprovalRequest(toolName: "touch", title: "t", command: "c", reason: ""))),
        ]
        let closed = conversation.closingInterruptedTurn().items.map(\.kind)
        guard case .bot(_, false) = closed[0], case .tool(let call) = closed[1], case .approval(let request) = closed[2] else {
            Issue.record("unexpected kinds")
            return
        }
        #expect(call.state == .failed)
        #expect(request.decision == .deny)
    }

    @Test func reopeningAfterACrashSaysWhereTheTaskWasCutOffOnce() {
        let notice = BotSession.quitNotice
        var running = Conversation()
        running.items = [TranscriptItem(.user(text: "faça", attachments: [])), TranscriptItem(.bot(text: "meio", isStreaming: true))]
        let closed = running.closingInterruptedTurn(notice: notice)
        guard case .notice(notice) = closed.items.last?.kind else { Issue.record("no notice"); return }
        // Read again at the next launch, nothing is running anymore: no second notice.
        #expect(closed.closingInterruptedTurn(notice: notice).items.count == closed.items.count)

        var unanswered = Conversation()
        unanswered.items = [TranscriptItem(.user(text: "faça", attachments: []))]
        #expect(unanswered.closingInterruptedTurn(notice: notice).items.count == 2) // your message got no answer

        var finished = Conversation()
        finished.items = [TranscriptItem(.user(text: "faça", attachments: [])), TranscriptItem(.bot(text: "feito", isStreaming: false))]
        #expect(finished.closingInterruptedTurn(notice: notice).items.count == 2)
    }

    @Test func skillExpansion() throws {
        let skills = Skill.starters
        let expanded = try #require(SystemPrompt.expandSkill(in: "/resumir ~/notas.txt", skills: skills))
        #expect(expanded.skill.slug == "resumir")
        #expect(expanded.prompt.contains("User request: ~/notas.txt"))
        #expect(SystemPrompt.expandSkill(in: "/inexistente oi", skills: skills) == nil)
        #expect(SystemPrompt.expandSkill(in: "sem barra", skills: skills) == nil)
    }

    @Test func aSkillIsExpandedWhenALineBreakOrTabFollowsTheSlug() throws {
        let skills = Skill.starters
        for separator in ["\n", "\t"] {
            let expanded = try #require(SystemPrompt.expandSkill(in: "/resumir" + separator + "texto longo", skills: skills))
            #expect(expanded.skill.slug == "resumir")
            #expect(expanded.prompt.contains("User request: texto longo"))
        }
        #expect(try #require(SystemPrompt.expandSkill(in: "/resumir\n", skills: skills)).prompt.contains("User request: (none)"))
    }

    @Test func scheduleNextRun() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let monday9 = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9)))
        let daily = Schedule.daily(hour: 8, minute: 30).next(after: monday9, calendar: calendar)
        #expect(calendar.dateComponents([.day, .hour, .minute], from: daily) == DateComponents(day: 6, hour: 8, minute: 30))
        let weekly = Schedule.weekly(weekday: 6, hour: 18, minute: 0).next(after: monday9, calendar: calendar)
        #expect(calendar.dateComponents([.day, .hour], from: weekly) == DateComponents(day: 9, hour: 18))
        #expect(Schedule.everyHours(3).next(after: monday9) == monday9.addingTimeInterval(3 * 3600))
    }

    @Test func aScheduleOutOfRangeNeverComesDueAgainRightAway() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9)))
        for schedule in [Schedule.weekly(weekday: 9, hour: 10, minute: 0), .weekly(weekday: -7, hour: 10, minute: 0),
                         .daily(hour: 24, minute: 0), .daily(hour: 10, minute: 75)] {
            #expect(schedule.next(after: now, calendar: calendar) > now)
        }
        // Its label cannot trap on a weekday outside 1...7.
        for weekday in [-7, -1, 0, 8, 9, 100] {
            #expect(!Schedule.weekly(weekday: weekday, hour: 10, minute: 0).label.isEmpty)
        }
        // From a file edited by hand, as a routine: it is not due at the moment it was last run.
        let json = #"{"botID":"\#(UUID().uuidString)","schedule":{"weekly":{"weekday":9,"hour":30,"minute":0}}}"#
        var routine = try JSONDecoder().decode(Routine.self, from: Data(json.utf8))
        routine.lastRun = now
        #expect(routine.nextRun > now)
    }

    @Test func oldBotFilesStillDecode() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"Velho"}"#
        let bot = try JSONDecoder().decode(Bot.self, from: Data(json.utf8))
        #expect(bot.name == "Velho")
        #expect(bot.permissionMode == .ask)
        #expect(bot.capabilities == [.terminal, .browser])
    }

    @Test func storeRoundTrip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { removeTestFolder(directory) }
        let store = Store(directory: directory)
        var state = AppState.initial
        state.defaultModel = "xai/grok-4"
        store.save(state)
        store.flush()
        #expect(store.loadState()?.bots.map(\.name) == ["Atlas"])
        #expect(store.loadState()?.defaultModel == "xai/grok-4")

        let botID = state.bots[0].id
        let conversation = Conversation(items: [TranscriptItem(.user(text: "oi", attachments: []))], messages: [.user("oi")])
        store.save(conversation, for: botID)
        #expect(store.loadConversation(botID)?.messages == [.user("oi")])
    }
}

struct TurnTypesTests {
    @Test func toolErrorFlagRoundTripsAndOldMessagesDecodeAsNotErrors() throws {
        let failed = ChatMessage.tool("c1", "Error: x", isError: true)
        #expect(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(failed)) == failed)
        let old = try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"role":"tool","content":"ok","toolCallID":"c1"}"#.utf8))
        #expect(old.isError == false)
        let wrongType = try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"role":"tool","content":"ok","isError":null}"#.utf8))
        #expect(wrongType.isError == false)
    }

    @Test func usageAddsWhatWasReportedAndKeepsTheRestUnknown() {
        var total = TokenUsage(input: 10, output: nil, cacheRead: nil, cacheWrite: 1)
        total.add(TokenUsage(input: 5, output: 2, cacheRead: nil, cacheWrite: nil))
        #expect(total == TokenUsage(input: 15, output: 2, cacheRead: nil, cacheWrite: 1))
    }

    @Test func theDefaultToolChoiceIsAuto() async throws {
        let script = CallScript([[.text("oi")]], whenExhausted: .fim)
        for try await _ in CallScriptModel(script: script).stream(model: "m", messages: [], tools: []) {}
        #expect(await script.calls.map(\.toolChoice) == [.auto])
    }
}

/// How `AppModel` tells a stopped turn from the one that replaced it.
@MainActor
struct TurnOrchestrationTests {
    private func modelWithAProvider() -> (AppModel, Bot, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        // A gateway without an address is "usable" but has no client: the turn fails before any network call.
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        return (model, model.bots[0], root)
    }

    @Test func aStoppedTurnCannotCloseTheNextOne() throws {
        let (model, bot, root) = modelWithAProvider()
        defer { removeTestFolder(root) }
        #expect(model.send("um", to: bot.id))
        let first = try #require(model.turnIDs[bot.id])
        model.stop(bot.id)
        #expect(model.turnIDs[bot.id] == nil)

        #expect(model.send("dois", to: bot.id))
        let second = try #require(model.turnIDs[bot.id])
        #expect(first != second)

        // The first turn's task finishing late (its setup, its last events) must not touch the second turn.
        model.live(bot.id).hasFailed = false // the first stop flashed it
        model.finishTurn(bot.id, turn: first, succeeded: false)
        #expect(model.turnIDs[bot.id] == second)
        #expect(model.isWorking(bot.id))
        #expect(!model.live(bot.id).hasFailed)

        model.finishTurn(bot.id, turn: second)
        #expect(model.turnIDs[bot.id] == nil)
        #expect(!model.isWorking(bot.id))
    }

    @Test func stoppingWhileThePromptIsBeingPreparedReportsNoFailure() async throws {
        let (model, bot, root) = modelWithAProvider()
        defer { removeTestFolder(root) }
        // Stop at different moments of the setup (before it starts, while it runs, after it failed on its own).
        for yields in 0..<4 {
            model.session(bot.id).conversation = Conversation() // a clean chat for each moment
            #expect(model.send("oi", to: bot.id))
            for _ in 0..<yields { await Task.yield() }
            let task = model.turns[bot.id] // nil when the setup already failed on its own
            model.stop(bot.id)
            // The cancelled setup has really ended, so a failure it would still report has been reported.
            await task?.value
            let notices = model.transcript(bot.id).compactMap { item -> String? in
                if case .notice(let text) = item.kind { text } else { nil }
            }
            // Either the user's stop or the turn's own failure, never the failure of a stopped turn on top of the stop.
            #expect(notices.count == 1, "\(notices)")
            #expect(model.turnIDs[bot.id] == nil)
        }
    }

    @Test func aTurnThatCannotStartFailsOnce() async throws {
        let (model, bot, root) = modelWithAProvider()
        defer { removeTestFolder(root) }
        #expect(model.send("oi", to: bot.id))
        let task = try #require(model.turns[bot.id])
        // Setup runs (and fails) in the turn's task; it finishing is the signal that the one notice is there.
        await task.value
        await waitUntil("the failed turn to be closed") { !model.isWorking(bot.id) }
        let notices = model.transcript(bot.id).compactMap { item -> String? in
            if case .notice(let text) = item.kind { text } else { nil }
        }
        #expect(notices.count == 1 && notices[0].hasPrefix("Não deu certo"))
        #expect(!model.isWorking(bot.id))
        #expect(model.turnIDs[bot.id] == nil)
    }
}

/// A sensitive file tool whose result and card say which file it was for, so order and grouping can be seen.
private struct StampTool: AgentTool {
    let runs: Counter
    /// Runs after the first stamp is done (the user changing something while the step is under way).
    var afterFirst: (@Sendable () async -> Void)?
    var spec: ToolSpec { ToolSpec(name: "stamp", description: "Stamps a file", parameters: .schema([:])) }
    var kind: ToolCall.Kind { .file }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Gravando", arguments["name"]?.string ?? "?") }
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        await runs.increment()
        if await runs.value == 1 { await afterFirst?() }
        return "did \(arguments["name"]?.string ?? "?")"
    }
}

/// One card for several actions of the same step.
struct ApprovalBatchTests {
    private func stamp(_ name: String, id: String? = nil) -> ToolCallRequest {
        ToolCallRequest(id: id ?? "s-\(name)", name: "stamp", arguments: #"{"name":"\#(name)"}"#)
    }

    private func look(_ id: String = "look") -> ToolCallRequest {
        ToolCallRequest(id: id, name: "look", arguments: #"{"ms":0,"name":"x"}"#)
    }

    /// `touch` with a destructive command: always its own card.
    private func risky(_ id: String) -> ToolCallRequest {
        ToolCallRequest(id: id, name: "touch", arguments: #"{"command":"rm -rf ~/Projetos"}"#)
    }

    private func request(_ script: CallScript, mode: PermissionMode = .ask, box: PermissionBox? = nil, runs: Counter,
                         grants: [PermissionRule] = [], afterFirstStamp: (@Sendable () async -> Void)? = nil) -> TurnRequest {
        let bot = Bot(name: "Teste", role: "", orb: OrbConfig(), permissionMode: mode)
        let tools: [any AgentTool] = [StampTool(runs: runs, afterFirst: afterFirstStamp), TouchTool(runs: runs), LookTool(gauge: Gauge())]
        var turn = TurnRequest(bot: bot, model: "fake", system: "sys", history: [], prompt: "oi", client: CallScriptModel(script: script),
                               tools: tools, context: ToolContext(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory())),
                               turnGrants: grants)
        if let box { turn.permissions = { await box.state } }
        return turn
    }

    /// Plays the user: `answer` decides each card.
    private func drive(_ engine: AgentEngine, _ request: TurnRequest,
                       answer: @Sendable (ApprovalRequest) -> ApprovalAnswer) async -> [TurnEvent] {
        var events: [TurnEvent] = []
        for await event in engine.run(request) {
            events.append(event)
            if case .approval(let approval) = event { await engine.gate.resolve(approvalID: approval.id, answer: answer(approval)) }
        }
        return events
    }

    private func approvals(_ events: [TurnEvent]) -> [ApprovalRequest] {
        events.compactMap { if case .approval(let approval) = $0 { approval } else { nil } }
    }

    private func results(_ events: [TurnEvent]) -> [ChatMessage] {
        events.compactMap { if case .message(let message) = $0, message.role == .tool { message } else { nil } }
    }

    @Test func twoSensitiveCallsAndASafeOneMakeOneCardAndTheSafeOneRuns() async {
        let runs = Counter()
        let script = CallScript([[.toolCalls([stamp("a"), look(), stamp("b")])], [.text("Pronto")]], whenExhausted: .fim)
        let events = await drive(AgentEngine(), request(script, runs: runs)) { _ in .once }
        let cards = approvals(events)
        #expect(cards.count == 1)
        #expect(cards[0].isBatch && cards[0].items.map(\.command) == ["a", "b"] && cards[0].items.map(\.toolName) == ["stamp", "stamp"])
        #expect(await runs.value == 2)
        // Results go back in the order of the calls.
        #expect(results(events).map(\.content) == ["did a", "viu x", "did b"])
        #expect(results(events).map(\.isError) == [false, false, false])
    }

    @Test func aSingleSensitiveCallIsNotGrouped() async {
        let runs = Counter()
        let events = await drive(AgentEngine(), request(CallScript([[.toolCalls([stamp("a"), look()])], [.text("Pronto")]], whenExhausted: .fim), runs: runs)) { _ in .once }
        #expect(approvals(events).count == 1 && !approvals(events)[0].isBatch && approvals(events)[0].items.isEmpty)
        #expect(await runs.value == 1)
    }

    @Test func denyingTheGroupRefusesEveryCallInItAndTheSafeOneStillRuns() async {
        let runs = Counter()
        let script = CallScript([[.toolCalls([stamp("a"), look(), stamp("b")])], [.text("Ok")]], whenExhausted: .fim)
        let events = await drive(AgentEngine(), request(script, runs: runs)) { _ in .deny }
        #expect(approvals(events).count == 1)
        #expect(await runs.value == 0)
        let shown = results(events)
        #expect(shown.map(\.isError) == [true, false, true])
        #expect(shown[0].content == PermissionPolicy.userDenial && shown[2].content == PermissionPolicy.userDenial)
        #expect(shown[1].content == "viu x")
    }

    @Test func theNoteOnADenialReachesTheModel() async {
        let runs = Counter()
        let script = CallScript([[.toolCalls([stamp("a"), stamp("b")])], [.text("Ok")]], whenExhausted: .fim)
        let events = await drive(AgentEngine(), request(script, runs: runs)) { _ in ApprovalAnswer(decision: .deny, note: "  use a pasta tmp  ") }
        let expected = PermissionPolicy.userDenial + " The user said: use a pasta tmp"
        #expect(results(events).map(\.content) == [expected, expected])
        // The same for a card about one action.
        let single = await drive(AgentEngine(), request(CallScript([[.toolCalls([stamp("a")])], [.text("Ok")]], whenExhausted: .fim), runs: runs)) { _ in
            ApprovalAnswer(decision: .deny, note: "não")
        }
        #expect(results(single).first?.content == PermissionPolicy.userDenial + " The user said: não")
        // Nothing to say leaves the usual text.
        let silent = await drive(AgentEngine(), request(CallScript([[.toolCalls([stamp("a")])], [.text("Ok")]], whenExhausted: .fim), runs: runs)) { _ in
            ApprovalAnswer(decision: .deny, note: "   ")
        }
        #expect(results(silent).first?.content == PermissionPolicy.userDenial)
    }

    @Test func dangerousCallsNeverJoinTheGroup() async {
        let runs = Counter()
        let script = CallScript([[.toolCalls([risky("r1"), stamp("a"), stamp("b"), risky("r2")])], [.text("Ok")]], whenExhausted: .fim)
        let events = await drive(AgentEngine(), request(script, runs: runs)) { _ in .once }
        let cards = approvals(events)
        // The group of two comes first (asked before anything runs); each destructive call asks for itself.
        #expect(cards.count == 3)
        #expect(cards[0].isBatch && cards[0].items.count == 2)
        #expect(cards.dropFirst().allSatisfy { !$0.isBatch && $0.isDangerous && $0.suggestions.isEmpty })
        #expect(await runs.value == 4)
        #expect(results(events).map(\.content) == ["ok", "did a", "did b", "ok"])
    }

    @Test func onlyDangerousCallsMeanOneCardEach() async {
        let runs = Counter()
        let script = CallScript([[.toolCalls([risky("r1"), risky("r2"), stamp("a")])], [.text("Ok")]], whenExhausted: .fim)
        let events = await drive(AgentEngine(), request(script, runs: runs)) { _ in .deny }
        #expect(approvals(events).count == 3)
        #expect(approvals(events).allSatisfy { !$0.isBatch })
    }

    @Test func reviewingOneByOneAsksForEachCall() async {
        let runs = Counter()
        let script = CallScript([[.toolCalls([stamp("a"), stamp("b")])], [.text("Ok")]], whenExhausted: .fim)
        let events = await drive(AgentEngine(), request(script, runs: runs)) { card in
            card.isBatch ? ApprovalAnswer(decision: .review) : (card.command == "a" ? .once : .deny)
        }
        let cards = approvals(events)
        #expect(cards.count == 3 && cards[0].isBatch && cards[1].command == "a" && cards[2].command == "b")
        #expect(results(events).map(\.content) == ["did a", PermissionPolicy.userDenial])
        #expect(await runs.value == 1)
    }

    @Test func onlyThisTaskOnAGroupGrantsEverythingItOffered() async {
        let runs = Counter()
        // A third call in the next step is covered by what the group granted.
        let script = CallScript([[.toolCalls([stamp("a"), stamp("b")])], [.toolCalls([stamp("c")])], [.text("Ok")]], whenExhausted: .fim)
        let events = await drive(AgentEngine(), request(script, runs: runs)) { _ in ApprovalAnswer(decision: .task) }
        #expect(approvals(events).count == 1)
        #expect(await runs.value == 3)
    }

    @Test func switchingToReadOnlyWhileTheGroupIsOpenBlocksEachCall() async {
        let runs = Counter()
        let box = PermissionBox(mode: .ask)
        let engine = AgentEngine()
        let req = request(CallScript([[.toolCalls([stamp("a"), stamp("b")])], [.text("Ok")]], whenExhausted: .fim), box: box, runs: runs)
        var events: [TurnEvent] = []
        for await event in engine.run(req) {
            events.append(event)
            if case .approval = event {
                await box.set(mode: .readOnly)
                await engine.gate.applyModeChange(to: .readOnly, for: req.bot.id)
            }
        }
        #expect(approvals(events).count == 1)
        #expect(await runs.value == 0)
        #expect(results(events).allSatisfy { $0.isError && $0.content == PermissionPolicy.readOnlyDenial })
    }

    @Test func switchingToReadOnlyAfterTheGroupWasApprovedBlocksTheCallsThatHaveNotRunYet() async {
        let runs = Counter()
        let box = PermissionBox(mode: .ask)
        let script = CallScript([[.toolCalls([stamp("a"), stamp("b"), stamp("c")])], [.text("Ok")]], whenExhausted: .fim)
        // The user taps "Permitir as 3"; while the first one runs they switch the Orb to read-only.
        let req = request(script, box: box, runs: runs, afterFirstStamp: { await box.set(mode: .readOnly) })
        let events = await drive(AgentEngine(), req) { _ in .once }
        #expect(approvals(events).count == 1)
        #expect(await runs.value == 1)
        #expect(results(events).map(\.content) == ["did a", PermissionPolicy.readOnlyDenial, PermissionPolicy.readOnlyDenial])
        #expect(results(events).map(\.isError) == [false, true, true])
    }

    @Test func alwaysOnAGroupSavesTheChosenRuleAndEveryCallRuns() async {
        let runs = Counter()
        let box = PermissionBox(mode: .ask)
        let rule = PermissionRule(family: .writeFiles)
        // The next step's call is covered by the saved rule: no second card.
        let script = CallScript([[.toolCalls([stamp("a"), stamp("b")])], [.toolCalls([stamp("c")])], [.text("Ok")]], whenExhausted: .fim)
        let engine = AgentEngine()
        var events: [TurnEvent] = []
        for await event in engine.run(request(script, box: box, runs: runs)) {
            events.append(event)
            if case .approval(let card) = event {
                await box.add(rule) // what the app does before answering the engine
                await engine.gate.resolve(approvalID: card.id, answer: ApprovalAnswer(decision: .always, rule: rule))
            }
        }
        #expect(approvals(events).count == 1 && approvals(events)[0].isBatch)
        #expect(await box.state.rules == [rule])
        #expect(await runs.value == 3)
        #expect(results(events).map(\.content) == ["did a", "did b", "did c"])
    }

    @Test func alwaysOnAGroupWithoutALiveSourceIsKeptForTheTurn() async {
        let runs = Counter()
        let rule = PermissionRule(family: .writeFiles)
        let script = CallScript([[.toolCalls([stamp("a"), stamp("b")])], [.toolCalls([stamp("c")])], [.text("Ok")]], whenExhausted: .fim)
        let events = await drive(AgentEngine(), request(script, runs: runs)) { _ in ApprovalAnswer(decision: .always, rule: rule) }
        #expect(approvals(events).count == 1)
        #expect(await runs.value == 3)
    }

    @Test func grantsAlreadyHeldKeepACallOutOfTheGroup() async {
        let runs = Counter()
        let script = CallScript([[.toolCalls([stamp("a"), stamp("b")])], [.text("Ok")]], whenExhausted: .fim)
        let events = await drive(AgentEngine(), request(script, runs: runs, grants: [PermissionRule(family: .writeFiles)])) { _ in .once }
        #expect(approvals(events).isEmpty)
        #expect(await runs.value == 2)
    }

    @Test func theGroupedCardOffersTheUnionOfTheRulesWithoutRepeats() {
        let calls = [
            ToolCallRequest(id: "1", name: "run_command", arguments: #"{"command":"git fetch"}"#),
            ToolCallRequest(id: "2", name: "run_command", arguments: #"{"command":"git push"}"#),
            ToolCallRequest(id: "3", name: "run_command", arguments: #"{"command":"npm run build"}"#),
            ToolCallRequest(id: "4", name: "run_command", arguments: #"{"command":"swift test"}"#),
        ]
        let context = ToolContext(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        let batch = ApprovalBatch.plan(calls: calls, tools: [RunCommandTool()], context: context,
                                       state: PermissionState(mode: .ask, rules: []), grants: [])
        let rules = batch?.suggestions ?? []
        #expect(batch?.members.count == 4)
        #expect(rules.count == 3 && Set(rules).count == 3)
        let all = (batch?.members ?? []).flatMap { $0.suggestions }
        #expect(rules == Array(PermissionPolicy.unique(all).prefix(3)))
        // What a rule already covers is left out of the offer.
        let covered = ApprovalBatch.plan(calls: calls, tools: [RunCommandTool()], context: context,
                                         state: PermissionState(mode: .ask, rules: [.shell("git")]), grants: [])
        #expect(covered?.members.count == 2)
        #expect(covered?.suggestions.contains(.shell("git")) == false)
    }

    @Test func aGroupNeedsAtLeastTwoCalls() {
        let context = ToolContext(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        let tools: [any AgentTool] = [StampTool(runs: Counter())]
        #expect(ApprovalBatch.plan(calls: [stamp("a")], tools: tools, context: context, state: PermissionState(mode: .ask, rules: []), grants: []) == nil)
        #expect(ApprovalBatch.plan(calls: [stamp("a"), stamp("b")], tools: tools, context: context, state: PermissionState(mode: .auto, rules: []), grants: []) == nil)
        #expect(ApprovalBatch.plan(calls: [stamp("a"), stamp("b")], tools: tools, context: context, state: PermissionState(mode: .ask, rules: []), grants: []) != nil)
    }
}

// MARK: - The plan at the end of a turn (`PlanReminder`) and the step limit

/// `touch`, which on its `at`-th run queues a message of the user (written during that step).
private struct SayingTouchTool: AgentTool {
    let queue: SteeringQueue
    let text: String
    let at: Int
    let runs: Counter
    var spec: ToolSpec { ToolSpec(name: "touch", description: "Touches a file", parameters: .schema([:])) }
    var kind: ToolCall.Kind { .file }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Tocando", "arquivo") }
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        await runs.increment()
        if await runs.value == at { queue.push(SteeredMessage(text: text, prompt: text)) }
        return "ok"
    }
}

/// Whether the consumer of a turn saw the event it waits for.
private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

extension AgentEngineTests {
    private var setPlan: LLMEvent {
        planCall("p0", #"{"action": "set", "goal": "Publicar o site", "steps": ["Gerar o build", "Subir"]}"#)
    }

    /// One `task_plan` update of one step.
    private func mark(_ step: Int, _ state: String = "done", id: String? = nil) -> LLMEvent {
        planCall(id ?? "u\(step)\(state)", #"{"action": "update", "updates": [{"step": \#(step), "state": "\#(state)"}]}"#)
    }

    private func steps(_ count: Int) -> TaskPlan {
        TaskPlan(goal: "Publicar o site", steps: (1...count).map { TaskPlan.Step(text: "Etapa \($0)") }, next: "etapa 1")
    }

    /// A turn with the plan tool and `touch`, nothing to approve and the plan already on the board (or none).
    private func planTurn(_ script: CallScript, plan: TaskPlan? = nil, maxSteps: Int = AgentEngine.defaultMaxSteps,
                          tools: [any AgentTool] = [TouchTool(runs: Counter())]) -> TurnRequest {
        var turn = request(script, mode: .bypass, runs: Counter(), tools: [TaskPlanTool()] + tools, maxSteps: maxSteps)
        turn.context.taskPlan = TaskPlanBoard(plan)
        return turn
    }

    private func planNotices(_ events: [TurnEvent]) -> [String] {
        events.compactMap { if case .notice(let text) = $0 { text } else { nil } }
    }

    private func pauses(_ events: [TurnEvent]) -> Int {
        events.filter { if case .taskPaused = $0 { true } else { false } }.count
    }

    private func sawPlanReminder(_ script: CallScript) async -> Bool {
        await script.received.contains { $0.contains { $0.role == .user && $0.content.hasPrefix("Before you finish: step") } }
    }

    // MARK: Closing with steps open

    @Test func aReplyThatEndsWithStepsOpenIsRemindedOnceAndTheSecondEndsTheTurn() async {
        let script = CallScript([[setPlan], [touch(1)], [mark(1)], [.text("Build feito.")], [.text("Paro aqui: subir fica para depois.")],
                             [.text("nunca pedido")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), planTurn(script))
        let received = await script.received
        #expect(received.count == 5)
        #expect(received[4].last == .user(PlanReminder.text(open: [2])))
        #expect(!messages(events).contains { $0.content.hasPrefix("Before you finish") }, "the chat never shows it")
        #expect(messages(events).last?.content == "Paro aqui: subir fica para depois.")
    }

    @Test func theReminderListsEveryOpenStepByNumber() {
        #expect(PlanReminder.text(open: [2]).hasPrefix("Before you finish: step 2 of your task plan is still open."))
        let many = PlanReminder.text(open: [1, 3])
        #expect(many.hasPrefix("Before you finish: steps 1, 3 of your task plan are still open."))
        #expect(many.contains("blocked") && many.contains("tell the user"))
    }

    @Test func aReplyThatAsksTheUserSomethingIsNotReminded() async {
        let script = CallScript([[setPlan], [touch(1)], [.text("Subo para produção ou para homologação?")], [.text("nunca pedido")]], whenExhausted: .fim)
        _ = await run(AgentEngine(), planTurn(script))
        #expect(await script.received.count == 3)
    }

    @Test func aPlanLeftDoneOrBlockedIsNotReminded() async {
        let both = planCall("u", #"{"action": "update", "updates": [{"step": 1, "state": "done"}, {"step": 2, "state": "blocked", "reason": "falta a senha do servidor"}]}"#)
        let script = CallScript([[setPlan], [touch(1)], [both], [.text("Build feito; subir ficou bloqueado sem a senha.")], [.text("nunca pedido")]], whenExhausted: .fim)
        _ = await run(AgentEngine(), planTurn(script))
        #expect(await script.received.count == 4)
    }

    @Test func aPlanLeftFromAnEarlierTaskIsNotReminded() async {
        let script = CallScript([[.text("Olá.")], [.text("nunca pedido")]], whenExhausted: .fim)
        _ = await run(AgentEngine(), planTurn(script, plan: plannedSteps))
        #expect(await script.received.count == 1)
    }

    @Test func theLastStepIsNotReminded() async {
        let script = CallScript([[setPlan], [touch(1)], [.text("Parei no limite.")], [.text("nunca pedido")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), planTurn(script, maxSteps: 3))
        #expect(await script.received.count == 3)
        #expect(!(await sawPlanReminder(script)))
        #expect(pauses(events) == 1)
    }

    @Test func aMessageAskingToStopHoldsTheReminderBack() async {
        let queue = SteeringQueue()
        var turn = planTurn(CallScript([], whenExhausted: .fim), tools: [SayingTouchTool(queue: queue, text: "pode parar", at: 1, runs: Counter())])
        let script = CallScript([[setPlan], [touch(1)], [.text("Parei, como pediu.")], [.text("nunca pedido")]], whenExhausted: .fim)
        turn.client = CallScriptModel(script: script)
        turn.steering = queue
        _ = await run(AgentEngine(), turn)
        #expect(await script.received.count == 3)
        #expect(PlanReminder.asksToStop("Pode parar.") && PlanReminder.asksToStop("chega") && PlanReminder.asksToStop("não continue")
                && PlanReminder.asksToStop("para\n\n[anexo]"))
        #expect(!PlanReminder.asksToStop("para a pasta X, use Y") && !PlanReminder.asksToStop("parar o servidor antes de subir"))
    }

    @Test func thePlanReminderSharesTheAllowanceOfTheOtherReminders() async {
        // Two promises use the allowance: the plan's reminder does not come on top.
        let promises = CallScript([[setPlan], [touch(1)], [.text("Vou adaptar o script agora.")], [touch(2)], [.text("Vou conferir de novo.")],
                               [touch(3)], [.text("Parei por aqui.")], [.text("nunca pedido")]], whenExhausted: .fim)
        _ = await run(AgentEngine(), planTurn(promises))
        #expect(await promises.received.count == 7)
        #expect(await promises.received[3].last == .user(AgentEngine.promiseNudge))
        #expect(await promises.received[5].last == .user(AgentEngine.promiseNudge))
        #expect(!(await sawPlanReminder(promises)))
        // The plan's reminder uses one: a single promise reminder is left after it.
        let plan = CallScript([[setPlan], [touch(1)], [.text("Parei.")], [touch(2)], [.text("Vou conferir de novo.")], [touch(3)],
                           [.text("Vou rodar mais uma vez.")], [.text("nunca pedido")]], whenExhausted: .fim)
        _ = await run(AgentEngine(), planTurn(plan))
        #expect(await plan.received.count == 7)
        #expect(await plan.received[3].last == .user(PlanReminder.text(open: [1, 2])))
        #expect(await plan.received[5].last == .user(AgentEngine.promiseNudge))
    }

    // MARK: The step limit, for a caller that sets one

    @Test func theStepLimitPausesWithItsNotice() async {
        let script = CallScript([[touch(1)], [touch(2)], [touch(3)], [.text("nunca pedido")]], whenExhausted: .fim)
        let events = await run(AgentEngine(), planTurn(script, maxSteps: 3))
        #expect(await script.received.count == 3)
        #expect(planNotices(events) == [AgentEngine.pausedNotice(after: 3)])
        #expect(pauses(events) == 1)
    }

    @Test func aMovingPlanStillPausesAtTheStepLimit() async {
        let script = CallScript([[touch(1)], [mark(1)], [touch(2)], [.text("Build feito; falta subir.")], [.text("nunca pedido")]],
                                whenExhausted: .fim)
        let events = await run(AgentEngine(), planTurn(script, plan: plannedSteps, maxSteps: 4))
        #expect(await script.received.count == 4)
        #expect(pauses(events) == 1)
        #expect(planNotices(events) == [AgentEngine.pausedNotice(after: 4)])
        #expect(messages(events).first { $0.role == .tool }?.content.hasSuffix(AgentEngine.stepWarning(remaining: 3)) == true)
    }
}
