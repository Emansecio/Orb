import Foundation
import CoreGraphics
import Testing
@testable import Orb

// The turn without a step limit (docs/REVISAO-TURNO-2026-10-16.md): what the person sees of a turn that runs long or goes
// wrong by itself, and what each failure leaves behind.

private func said(_ text: String) -> [LLMEvent] { [.text(text), .finished(.done, nil)] }

private func call(_ name: String, _ arguments: String, usage: TokenUsage? = nil) -> [LLMEvent] {
    [.toolCalls([ToolCallRequest(id: UUID().uuidString, name: name, arguments: arguments)]), .finished(.toolUse, usage)]
}

/// Streams `text`, then nothing until the call is cancelled (a reply you stop while it is being written).
private struct HangsAfterText: LLMClient {
    var text: String
    var arrangesPromptCache: Bool { false }
    var forShortReply: any LLMClient { self }
    func markingStable(upTo toolCallID: String?) -> any LLMClient { self }

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.text(text))
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                continuation.finish(throwing: CancellationError())
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite(.serialized) final class TurnReliabilityTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbTurnReliability-\(UUID().uuidString)")

    init() { QuietNotifications.hold() }

    deinit {
        QuietNotifications.release()
        removeTestFolder(root)
    }

    @MainActor func setUp(_ client: @escaping @MainActor () -> any LLMClient, mode: PermissionMode = .ask,
                          conversation: Conversation? = nil) -> (AppModel, UUID) {
        var state = AppState.initial
        let folder = root.appending(path: "pasta-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        state.bots[0].workingDirectory = folder.path
        state.bots[0].permissionMode = mode
        let store = Store(directory: root.appending(path: "dados-\(UUID().uuidString.prefix(6))"))
        store.save(state)
        if let conversation { store.save(conversation, for: state.bots[0].id) }
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.homeFolder = root
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = client
        let suite = UserDefaults(suiteName: "OrbTurnReliability-\(UUID().uuidString)")!
        suite.set(false, forKey: SkillReview.settingKey)
        model.preferences = suite
        return (model, state.bots[0].id)
    }

    @MainActor func setUp(_ script: CallScript, mode: PermissionMode = .ask, conversation: Conversation? = nil) -> (AppModel, UUID) {
        setUp({ CallScriptModel(script: script) }, mode: mode, conversation: conversation)
    }

    // MARK: P0-1: what the turn spent, and a turn going in circles

    @Test func theMeterSaysWhatTheTurnSpentOnceItMatters() {
        #expect(TurnSpend(tokens: 49_999).text == nil)
        #expect(TurnSpend(tokens: 180_000).text == "180 mil tokens")
        #expect(TurnSpend(tokens: 2_100_000, dollars: 3.1).text == "2,1 milhões de tokens · US$ 3,10")
        #expect(TurnSpend(tokens: 60_000, dollars: 0).text == "60 mil tokens") // a plan or a free model: no price to say
        // Cache reads are left out (REVISAO-TOKENS-CONTAGEM P3-2): six steps rereading a 48 thousand history are not a turn
        // that costs 300 thousand tokens.
        #expect(TurnSpend(TokenUsage(input: 40_000, output: 2_000, cacheRead: 10_000, cacheWrite: 500)).tokens == 42_500)
        #expect(TurnSpend(TokenUsage(input: 600, output: 3_000, cacheRead: 280_000, cacheWrite: 12_000)).text == nil)
        #expect(WorkMeter.text(elapsed: "4 min", actions: 30, spend: TurnSpend(tokens: 75_000)) == "4 min · 30 ações · 75 mil tokens")
        #expect(WorkMeter.text(elapsed: "4 s", actions: 1, spend: TurnSpend(tokens: 900)) == "4 s")
    }

    @Test @MainActor func theRunningTotalReachesTheWorkingLineAndLeavesWithTheTurn() async {
        let script = CallScript([call("recall", #"{"query": "a"}"#, usage: TokenUsage(input: 40_000, output: 500)),
                                 call("recall", #"{"query": "b"}"#, usage: TokenUsage(input: 41_000, output: 500)),
                                 said("fim")], holdsCall: 3)
        let (model, botID) = setUp(script)
        #expect(model.send("procura", to: botID))
        await waitUntil("the third call") { await script.calls.count == 3 }
        await waitUntil("the spend of the first two calls") { model.live(botID).turnSpend?.tokens == 82_000 }
        #expect(model.live(botID).turnSpend?.text == "82 mil tokens")
        await script.release()
        await waitUntilIdle(model, botID)
        #expect(model.live(botID).turnSpend == nil)
    }

    @Test @MainActor func aTurnGoingInCirclesTellsThePersonOnceAndGoesOn() async {
        let script = CallScript((0..<30).map { _ in call("recall", #"{"query": "deploy"}"#) } + [said("fim")])
        let (model, botID) = setUp(script)
        #expect(model.send("acha o deploy", to: botID))
        await waitUntilIdle(model, botID)
        #expect(await script.calls.count == 31) // told, not stopped
        #expect(model.notices(botID).filter { $0 == LoopWatch.userNotice }.count == 1)
    }

    @Test @MainActor func aTurnThatOnlyRepeatsAFewTimesSaysNothing() async {
        let script = CallScript((0..<8).map { _ in call("recall", #"{"query": "deploy"}"#) } + [said("fim")])
        let (model, botID) = setUp(script)
        #expect(model.send("acha o deploy", to: botID))
        await waitUntilIdle(model, botID)
        #expect(!model.notices(botID).contains(LoopWatch.userNotice))
    }

    @Test func theStopBannerRoutesToStoppingThatOrb() {
        let id = UUID()
        #expect(ApprovalNotifications.route(actionIdentifier: ApprovalNotifications.stopAction,
                                            userInfo: [ApprovalNotifications.botKey: id.uuidString]) == .stop(botID: id))
        #expect(ApprovalNotifications.route(actionIdentifier: ApprovalNotifications.stopAction, userInfo: [:]) == .ignore)
    }

    @Test @MainActor func theStopBannerStopsTheTurn() async {
        let script = CallScript([said("fim")], holdsCall: 1)
        let (model, botID) = setUp(script)
        #expect(model.send("oi", to: botID))
        await waitUntil("the call") { await script.calls.count == 1 }
        model.handle(.stop(botID: botID))
        await waitUntilIdle(model, botID)
        #expect(model.notices(botID).contains(BotSession.stoppedNotice))
        await script.release()
    }

    // MARK: P1-1: a provider that only sends keep-alives

    private func drain(_ client: some LLMClient, timeout: TimeInterval) async -> (events: [LLMEvent], error: (any Error)?) {
        await ProviderTransport.$contentTimeoutOverride.withValue(timeout) {
            var events: [LLMEvent] = []
            do {
                for try await event in client.stream(model: "m", messages: [.user("oi")], tools: [], toolChoice: .auto) { events.append(event) }
                return (events, nil)
            } catch {
                return (events, error)
            }
        }
    }

    @Test func aStreamOfKeepAlivesOnlyIsGivenUpOn() async throws {
        let server = try await TrickleServer(script: [], forever: .init(after: .milliseconds(50), text: ": keep-alive\n\n"))
        let started = ContinuousClock.now
        let (_, error) = await drain(OpenAIClient(baseURL: server.baseURL, apiKey: nil), timeout: 0.5)
        #expect(started.duration(to: .now) < .seconds(5))
        guard case LLMError.stream(let type, _)? = error as? LLMError else { Issue.record("no stall: \(String(describing: error))"); return }
        #expect(type == LLMError.stalledType)
        #expect(Retry.isRetryable(error!))
        #expect(error!.localizedDescription.hasPrefix("O provedor parou de responder"))
    }

    @Test func pingEventsAreKeepAlivesToo() async throws {
        let ping = "event: ping\ndata: {\"type\": \"ping\"}\n\n"
        let server = try await TrickleServer(script: [], forever: .init(after: .milliseconds(50), text: ping))
        let (_, error) = await drain(OpenAIClient(baseURL: server.baseURL, apiKey: nil), timeout: 0.5)
        guard case LLMError.stream(let type, _)? = error as? LLMError else { Issue.record("no stall: \(String(describing: error))"); return }
        #expect(type == LLMError.stalledType)
    }

    @Test func aSlowButLiveResponseIsNeverCutOff() async throws {
        // Each real event comes well inside the window (150 ms in 1.2 s, so a loaded runner has a second to spare),
        // the whole response (1.8 s) well past it.
        let words = (0..<12).map { _ in TrickleServer.Piece(after: .milliseconds(150), text: #"data: {"choices":[{"delta":{"content":"a "}}]}"# + "\n\n") }
        let server = try await TrickleServer(script: words + [.init(after: .zero, text: "data: [DONE]\n\n")])
        let (events, error) = await drain(OpenAIClient(baseURL: server.baseURL, apiKey: nil), timeout: 1.2)
        #expect(error == nil)
        #expect(events.filter { if case .text = $0 { true } else { false } }.count == 12)
    }

    @Test func aQuietProviderIsTriedOnceMoreNotThreeTimes() async {
        #expect(Retry.attemptLimit(for: ProviderTransport.stalled(after: 600), maxAttempts: 4) == 2)
        #expect(Retry.attemptLimit(for: LLMError.network(code: URLError.timedOut.rawValue, message: "x"), maxAttempts: 4) == 2)
        #expect(Retry.attemptLimit(for: LLMError.http(status: 503, message: "x"), maxAttempts: 4) == 4)
        let tries = LockedBox(0)
        let error = await { () async -> (any Error)? in
            do {
                _ = try await withRetries(sleep: { _ in }) { () async throws -> Int in
                    tries.withLock { $0 += 1 }
                    throw ProviderTransport.stalled(after: 600)
                }
                return nil
            } catch { return error }
        }()
        #expect(tries.value == 2)
        #expect(error != nil)
        #expect(Retry.waitStatus(seconds: 2, after: ProviderTransport.stalled(after: 600)).hasPrefix("Provedor sem resposta"))
    }

    // MARK: P1-2: a usage limit waits long enough to pass

    private func engineRequest(_ script: CallScript) -> TurnRequest {
        TurnRequest(bot: Bot(name: "Teste", role: "", orb: OrbConfig(), permissionMode: .ask), model: "fake", system: "sys",
                    history: [], prompt: "oi", client: CallScriptModel(script: script), tools: [],
                    context: ToolContext(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory())), maxSteps: .max)
    }

    @Test func aUsageLimitWaitsAboutAMinuteAndOnlyThenGivesUp() async {
        let limited = LLMError.http(status: 429, message: "Rate limit reached")
        let sleeps = LockedBox<[TimeInterval]>([])
        let tries = LockedBox(0)
        do {
            _ = try await withRetries(sleep: { sleeps.append($0) }, jitter: { 1 }) { () async throws -> Int in
                tries.withLock { $0 += 1 }
                throw limited
            }
        } catch {}
        #expect(tries.value == Retry.rateLimitAttempts)
        #expect(sleeps.value == [5, 15, 30, 60])
        // An overloaded provider waits the same; a server error and a spent balance do not.
        #expect(Retry.isRateLimit(LLMError.stream(type: "overloaded_error", message: "")))
        #expect(Retry.isRateLimit(LLMError.http(status: 529, message: "")))
        #expect(!Retry.isRateLimit(LLMError.http(status: 503, message: "")))
        #expect(!Retry.isRateLimit(LLMError.http(status: 429, message: "insufficient_quota")))
        #expect(Retry.attemptLimit(for: LLMError.http(status: 503, message: "")) == 4)
        #expect(Retry.delay(afterAttempt: 2, retryAfter: nil, jitter: 0, rateLimited: true) == 7.5)
        #expect(Retry.delay(afterAttempt: 9, retryAfter: nil, jitter: 1, rateLimited: true) == 60)
        // The provider's own wait still wins.
        #expect(Retry.delay(afterAttempt: 1, retryAfter: 2, jitter: 1, rateLimited: true) == 2)
    }

    @Test func aLongTaskSurvivesAUsageLimitInTheMiddle() async {
        let limited = LLMError.http(status: 429, message: "Rate limit reached")
        let script = CallScript(replies: [ModelReply(call("recall", #"{"query": "a"}"#)),
                                          .failing(limited), .failing(limited), .failing(limited),
                                          ModelReply(said("pronto"))])
        let waits = LockedBox<[TimeInterval]>([])
        var events: [TurnEvent] = []
        for await event in AgentEngine(retrySleep: { waits.append($0) }).run(engineRequest(script)) { events.append(event) }
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
        #expect(await script.calls.count == 5)
        #expect(waits.value.count == 3)
        #expect(waits.value.allSatisfy { $0 >= 2.5 })
    }

    // MARK: P1-3: the history is worked out away from the main thread

    @Test @MainActor func aLongConversationIsFoldedWithoutHoldingTheWindow() async throws {
        let script = CallScript([said("fim")], holdsCall: 1)
        var conversation = Conversation()
        for index in 0..<320 {
            conversation.messages += [.user("pedido \(index)"), ChatMessage(role: .assistant, content: "resposta \(index) " + String(repeating: "texto ", count: 400))]
            conversation.items += [TranscriptItem(.user(text: "pedido \(index)", attachments: [])),
                                   TranscriptItem(.bot(text: "resposta \(index)", isStreaming: false))]
        }
        let (model, botID) = setUp(script, conversation: conversation)
        model.learnContextWindow(32_000, of: "custom/modelo")
        let bot = try #require(model.bot(botID))
        let budget = try #require(model.contextBudget(for: bot))
        // What sending folded before, worked out here on a copy.
        var expected = conversation
        let clock = ContinuousClock()
        var history: [ChatMessage] = []
        let direct = clock.measure {
            history = expected.prepareHistory(budget: budget, reserving: "resume".count + AppModel.prefaceAllowance, now: .now).history
        }
        let sending = try clock.measure { #expect(model.send("resume", to: botID)); _ = try #require(model.conversations[botID]) }
        #expect(sending < max(direct / 3, .milliseconds(20)), "send held the main thread \(sending) (the fold takes \(direct))")
        await waitUntil("the call") { await script.calls.count == 1 }
        let sent = try #require(await script.calls.first).messages
        let kept = try #require(model.conversations[botID])
        #expect(kept.summary == expected.summary)
        #expect(kept.summaryCoveredCount == expected.summaryCoveredCount)
        #expect(kept.compactions == 1)
        #expect(sent.dropLast().map(\.content) == history.map(\.content)) // what was sent before, then the message
        #expect(model.notices(botID).filter { $0.hasPrefix("Compactei a conversa:") }.count == 1)
        await script.release()
        await waitUntilIdle(model, botID)
    }

    // MARK: P2-1, P2-2, P3-6: what was said survives a stop and a cut

    @Test @MainActor func stoppingMidReplyKeepsWhatYouReadForTheNextTurn() async throws {
        let next = CallScript([said("ok")])
        let turns = LockedBox(0)
        let (model, botID) = setUp {
            turns.withLock { $0 += 1 }
            return turns.value == 1 ? HangsAfterText(text: "Primeira parte da explicação") : CallScriptModel(script: next)
        }
        #expect(model.send("explica", to: botID))
        await waitUntil("the reply on screen") {
            model.transcript(botID).contains { if case .bot(let text, _) = $0.kind { text.contains("Primeira parte") } else { false } }
        }
        model.stop(botID)
        await waitUntilIdle(model, botID)
        let last = try #require(model.conversations[botID]?.messages.last)
        #expect(last.role == .assistant && last.content == "Primeira parte da explicação" + AgentEngine.interruptedMarker)
        #expect(model.send("continua", to: botID))
        await waitUntilIdle(model, botID)
        let sent = try #require(await next.calls.first).messages
        #expect(sent.contains { $0.role == .assistant && $0.content.hasPrefix("Primeira parte da explicação") })
    }

    @Test @MainActor func stoppingAfterTheReplyWasRecordedAddsNothing() async throws {
        let script = CallScript([said("Resposta inteira.")], holdsCall: 2)
        let (model, botID) = setUp(script)
        #expect(model.send("oi", to: botID))
        await waitUntilIdle(model, botID)
        let before = try #require(model.conversations[botID]).messages.count
        #expect(model.send("de novo", to: botID))
        await waitUntil("the second call") { await script.calls.count == 2 }
        model.stop(botID)
        await waitUntilIdle(model, botID)
        let messages = try #require(model.conversations[botID]).messages
        #expect(messages.count == before + 1) // the message, and no reply that was never written
        await script.release()
    }

    private static let dropped = LLMError.network(code: URLError.networkConnectionLost.rawValue, message: "The network connection was lost.")

    @Test @MainActor func aReplyCutMidwayGoesOnOnceFromWhereItStopped() async throws {
        let script = CallScript(replies: [.failing(Self.dropped, after: [.text("Começo da resposta")]), .say(" e o resto.")])
        let (model, botID) = setUp(script)
        #expect(model.send("explica", to: botID))
        await waitUntilIdle(model, botID)
        #expect(await script.calls.count == 2)
        #expect(!model.notices(botID).contains { $0.hasPrefix("Não deu certo") })
        let second = try #require(await script.calls.last).messages
        #expect(second.suffix(2).map(\.content) == ["Começo da resposta" + AgentEngine.interruptedMarker, AgentEngine.continueNudge])
        let messages = try #require(model.conversations[botID]).messages
        #expect(messages.contains { $0.role == .assistant && $0.content.hasPrefix("Começo da resposta") })
        #expect(messages.last?.content == " e o resto.")
        #expect(!messages.contains { $0.content == AgentEngine.continueNudge }) // it steered the turn, it is nobody's message
    }

    @Test @MainActor func aSecondCutEndsTheTurnBlamingTheProviderNotTheNetwork() async throws {
        let script = CallScript(replies: [.failing(Self.dropped, after: [.text("Começo")]), .failing(Self.dropped, after: [.text("Meio")]),
                                          .say("nunca")])
        let (model, botID) = setUp(script)
        #expect(model.send("explica", to: botID))
        await waitUntilIdle(model, botID)
        #expect(await script.calls.count == 2)
        let failure = try #require(model.notices(botID).first { $0.hasPrefix("Não deu certo") })
        #expect(failure.hasPrefix("Não deu certo: O provedor cortou a resposta no meio"))
        #expect(!failure.contains("Sem conexão"))
        let messages = try #require(model.conversations[botID]).messages
        #expect(messages.filter { $0.content.hasSuffix(AgentEngine.interruptedMarker) }.count == 2)
    }

    // MARK: P2-3: the files a long task changed stay in sight

    private func writing(_ index: Int, fails: Bool = false) -> [ChatMessage] {
        let id = "w\(index)"
        return [ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: id, name: index.isMultiple(of: 2) ? "write_file" : "edit_file",
                                                                                       arguments: #"{"path":"/projeto/arquivo\#(index).swift"}"#)]),
                .tool(id, fails ? "Erro: sem permissão" : "Gravado. " + String(repeating: "x", count: 1_500), isError: fails)]
    }

    @Test func theStepsNoteNamesTheFilesTheTaskChangedBeyondItsLines() throws {
        var conversation = Conversation()
        conversation.messages = [.user("Refatore o projeto inteiro")]
        for index in 0..<200 { conversation.messages += writing(index, fails: index == 150) }
        conversation.messages.append(ChatMessage(role: .assistant, content: "quase lá"))
        let history = conversation.prepareHistory(budget: ContextBudget(tokens: 8_000)).history
        let note = try #require(ContextSummary.inherited(in: history)?.stepsNote)
        let lines = note.components(separatedBy: "\n")
        let filesLine = try #require(lines.last)
        let files = ToolDigest.files(inLine: filesLine)
        #expect(files.count == ToolDigest.maxFiles())
        #expect(filesLine.contains("antes)")) // the older ones are counted
        // The files line goes past the digest's own lines: it names files whose steps the digest no longer shows.
        let digested = lines.filter { $0.hasPrefix("[passo") }.compactMap { $0.split(separator: " ").dropFirst(2).first.map(String.init) }
        #expect(files.contains { !digested.contains($0) })
        #expect(!files.contains("/projeto/arquivo150.swift")) // a write that failed changed nothing
        // The newest steps are in the window itself, not in the note.
        let shown = history.dropFirst(2).flatMap(\.toolCalls).compactMap { JSONValue.parse($0.arguments)?["path"]?.string }
        #expect(Set(shown).isDisjoint(with: files))
    }

    @Test func twoNotesMergeIntoOneFilesLine() {
        let earlier = ContextSummary.stepsNote(writing(1) + writing(2))
        let later = ContextSummary.stepsNote(writing(2) + writing(3))
        let merged = ContextSummary.mergedNotes(earlier, later).components(separatedBy: "\n")
        #expect(merged.filter { $0.hasPrefix(ToolDigest.filesTitle) }.count == 1)
        #expect(ToolDigest.files(inLine: merged.last ?? "") == ["/projeto/arquivo1.swift", "/projeto/arquivo2.swift", "/projeto/arquivo3.swift"])
        #expect(!ContextSummary.stepsNote(writing(5).map { var m = $0; m.toolCalls = m.toolCalls.map { var c = $0; c.name = "read_file"; return c }; return m })
            .contains(ToolDigest.filesTitle))
    }

    // MARK: P2-4: a routine that fails says so outside the app

    @MainActor private func routineSetUp(_ script: CallScript) -> (AppModel, UUID, UUID) {
        let (model, botID) = setUp(script)
        let routine = Routine(name: "Resumo da manhã", botID: botID, prompt: "resuma os arquivos novos", schedule: .everyHours(1))
        model.routines = [routine]
        return (model, botID, routine.id)
    }

    @Test @MainActor func aRoutineThatFailsSendsABannerWithWhy() async {
        let script = CallScript(replies: [.failing(LLMError.http(status: 400, message: "modelo desconhecido"))])
        let (model, botID, routineID) = routineSetUp(script)
        model.runRoutine(routineID)
        await model.routineStarted()
        await waitUntilIdle(model, botID)
        let banner = model.lastBanner
        #expect(banner?.title == model.bot(botID)?.name)
        #expect(banner?.body.hasPrefix("A rotina “Resumo da manhã” não terminou: ") == true)
        #expect(banner?.body.contains("Não deu certo") == false)
        #expect(banner?.body.contains("modelo desconhecido") == true)
    }

    @Test @MainActor func aRoutineYouStopSendsNoBanner() async {
        let script = CallScript([said("fim")], holdsCall: 1)
        let (model, botID, routineID) = routineSetUp(script)
        model.runRoutine(routineID)
        await model.routineStarted()
        await waitUntil("the call") { await script.calls.count == 1 }
        model.stop(botID)
        await waitUntilIdle(model, botID)
        #expect(model.lastBanner == nil)
        await script.release()
    }

    // MARK: P2-5: ⌘. reaches the tools, and the tools have a time limit

    /// Waits for `seconds` without ever looking at cancellation (a framework that never answers).
    private static func deaf(_ seconds: Double) async -> Int {
        let ends = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < ends { await withUnsafeContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { c.resume() } } }
        return 1
    }

    @Test func aDeadlineGivesUpOnWorkThatNeverAnswers() async throws {
        #expect(try await withDeadline(5, "a conta") { 42 } == 42)
        let started = ContinuousClock.now
        do {
            _ = try await withDeadline(0.2, "a captura da janela") { await Self.deaf(5) }
            Issue.record("no deadline")
        } catch let error as DeadlineExceeded {
            #expect(error.localizedDescription == "A captura da janela passou de 0 s e foi abandonada.")
        } catch { Issue.record("\(error)") }
        #expect(started.duration(to: .now) < .seconds(2))
        #expect(CaptureFallbackPolicy.shouldFallBack(after: DeadlineExceeded(seconds: 10, what: "x"))) // a stuck SCK falls back
    }

    @Test func stoppingStopsWaitingForWorkThatIgnoresIt() async {
        let started = ContinuousClock.now
        // The type's name, not `Self`: the dynamic `Self` of a class in a `Task` is more than Swift 6.3's isolation checker can check.
        let waiting = Task { try await cancellably { await TurnReliabilityTests.deaf(5) } }
        try? await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        let result = await waiting.result
        #expect(started.duration(to: .now) < .seconds(2))
        guard case .failure(let error) = result else { Issue.record("not cancelled"); return }
        #expect(error is CancellationError)
    }

    @Test func stoppingAConnectorThatTakesForeverToStartReturnsAtOnce() async throws {
        let manager = MCPManager()
        let server = MCPServerConfig(name: "Lento", command: "/bin/sleep", arguments: ["30"])
        await manager.sync([server])
        let starting = Task { try await manager.ensureStarted(server.id) }
        try await Task.sleep(for: .milliseconds(500))
        let stopped = ContinuousClock.now
        starting.cancel()
        _ = await starting.result
        #expect(stopped.duration(to: .now) < .seconds(2))
        await manager.sync([])
    }

    private static func pdf(pages: Int) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        return data as Data
    }

    @Test func aPDFBeingReadStopsBetweenPages() async {
        let data = Self.pdf(pages: 3)
        #expect((try? DocumentReader.pdfText(data, pages: nil))?.hasPrefix("PDF com 3 páginas") == true)
        let read = await Task { () throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try DocumentReader.pdfText(data, pages: nil)
        }.result
        guard case .failure(let error) = read else { Issue.record("read on after ⌘."); return }
        #expect(error is CancellationError)
        let all = await Task { () throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try DocumentReader.allPDFText(data)
        }.result
        guard case .failure = all else { Issue.record("read on after ⌘."); return }
    }

    @Test func aDownloadThatDragsOnIsGivenUpWithNothingLeftBehind() async throws {
        let chunk = String(repeating: "x", count: 2_048)
        let server = try await TrickleServer(script: [], forever: .init(after: .milliseconds(20), text: chunk))
        let folder = root.appending(path: "baixar-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (bytes, _) = try await URLSession.shared.bytes(from: server.baseURL)
        let started = ContinuousClock.now
        do {
            _ = try await WebFetchTool.download(bytes, to: folder.appending(path: "arquivo.bin"), deadline: .milliseconds(400))
            Issue.record("no deadline")
        } catch let error as ToolError {
            #expect(error.message.hasPrefix("O download passou de 0 min"))
        }
        #expect(started.duration(to: .now) < .seconds(3))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    /// A server that sends a byte now and then never reaches the next multiple of 1,024 bytes: the deadline is the clock's, not the count's.
    @Test func aDownloadTrickingInAByteAtATimeIsGivenUpAtTheDeadline() async throws {
        let server = try await TrickleServer(script: [], forever: .init(after: .milliseconds(50), text: "x"))
        let folder = root.appending(path: "gotejar-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (bytes, _) = try await URLSession.shared.bytes(from: server.baseURL)
        let started = ContinuousClock.now
        do {
            _ = try await WebFetchTool.download(bytes, to: folder.appending(path: "arquivo.bin"), deadline: .milliseconds(400))
            Issue.record("no deadline")
        } catch let error as ToolError {
            #expect(error.message.hasPrefix("O download passou de 0 min"))
        }
        #expect(started.duration(to: .now) < .seconds(5))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func aSearchThatRanOutOfTimeSaysTheListMayBeIncomplete() throws {
        let partial = ProcessOutput(status: 15, signal: 15, output: "/Users/a/um.txt\n/Users/a/dois.txt", timedOut: true)
        let answer = try SearchFilesTool.answer(partial, limit: 50)
        #expect(answer.hasPrefix("/Users/a/um.txt\n/Users/a/dois.txt\n"))
        #expect(answer.contains("a lista pode estar incompleta"))
        let none = try SearchFilesTool.answer(ProcessOutput(status: 15, signal: 15, output: "", timedOut: true), limit: 50)
        #expect(none.hasPrefix("Nenhum arquivo encontrado antes do fim do prazo."))
        let whole = try SearchFilesTool.answer(ProcessOutput(status: 0, output: "/Users/a/um.txt", timedOut: false), limit: 50)
        #expect(whole == "/Users/a/um.txt")
    }

    @Test func connectorArgumentsThatAreNoJSONObjectAreRefused() throws {
        #expect(try ConnectorGateway.passedArguments(.string(#"{"repo": "orb"}"#)) == .object(["repo": .string("orb")]))
        #expect(try ConnectorGateway.passedArguments(.object(["a": .number(1)])) == .object(["a": .number(1)]))
        #expect(try ConnectorGateway.passedArguments(nil) == .object([:]))
        #expect(try ConnectorGateway.passedArguments(.string("  ")) == .object([:]))
        #expect(throws: ToolError.self) { try ConnectorGateway.passedArguments(.string("{repo: orb")) }
        #expect(throws: ToolError.self) { try ConnectorGateway.passedArguments(.string("[1, 2]")) }
        #expect(throws: ToolError.self) { try ConnectorGateway.passedArguments(.array([.number(1)])) }
    }

    // MARK: P3-1: the message that opens a turn is on disk at once

    @Test @MainActor func theMessageThatOpensATurnIsWrittenAtOnceAndACrashSaysSo() async throws {
        let script = CallScript([said("fim")], holdsCall: 1)
        let (model, botID) = setUp(script)
        #expect(model.send("organize a pasta de fotos", to: botID))
        await waitUntil("the message on disk") {
            model.store.flush()
            return model.store.readConversation(botID).value?.items.contains { $0.kind == .user(text: "organize a pasta de fotos", attachments: []) } == true
        }
        let onDisk = try #require(model.store.readConversation(botID).value)
        #expect(onDisk.turnOpen == true)
        // Read back after a crash: the chat says the turn was cut off.
        let reopened = onDisk.closingInterruptedTurn(notice: BotSession.quitNotice)
        #expect(reopened.items.last?.kind == .notice(BotSession.quitNotice))
        #expect(reopened.turnOpen == nil)
        await script.release()
        await waitUntilIdle(model, botID)
        model.store.flush()
        #expect(model.store.readConversation(botID).value?.turnOpen == nil)
    }

    @Test func aTurnCaughtAtAQuietMomentStillReadsAsCutOff() {
        var conversation = Conversation()
        conversation.items = [TranscriptItem(.user(text: "faça", attachments: [])), TranscriptItem(.bot(text: "Vou começar.", isStreaming: false))]
        #expect(conversation.closingInterruptedTurn(notice: BotSession.quitNotice).items.count == 2) // a finished turn: nothing to say
        conversation.turnOpen = true
        #expect(conversation.closingInterruptedTurn(notice: BotSession.quitNotice).items.last?.kind == .notice(BotSession.quitNotice))
    }
}
