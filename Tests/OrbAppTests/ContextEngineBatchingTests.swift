import Foundation
import Testing
@testable import Orb

// The engine side of context fitting: the cut that holds between steps, the real overhead of a request, the window
// learned from a refusal, the record left by a task that hit the step limit, the saved-outputs folder, and the
// pieces the app keeps (memory level, learned windows).

// MARK: - Helpers

private func turn(_ request: String, output: Int, tag: String) -> [ChatMessage] {
    [.user(request), ChatMessage(role: .assistant, content: "", toolCalls: [call(tag, "read_file", #"{"path":"/tmp/\#(tag).txt"}"#)]),
     .tool(tag, String(repeating: "x", count: output)), ChatMessage(role: .assistant, content: "Resposta de \(request)")]
}

private func engineRequest(_ recorder: Recorder, history: [ChatMessage] = [], budget: ContextBudget, toolSize: Int = 100,
                           system: String = "sys", maxSteps: Int = AgentEngine.defaultMaxSteps, prompt: String = "oi") -> TurnRequest {
    TurnRequest(bot: Bot(name: "Teste", role: "", orb: OrbConfig(), permissionMode: .bypass), model: "fake", system: system, history: history,
                prompt: prompt, client: ReplayLLM(recorder: recorder), tools: [OutputTool(size: toolSize)],
                context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory), budget: budget, maxSteps: maxSteps)
}

private func collect(_ request: TurnRequest) async -> [TurnEvent] {
    var events: [TurnEvent] = []
    for await event in AgentEngine().run(request) { events.append(event) }
    return events
}

private func recorded(_ events: [TurnEvent]) -> [ChatMessage] {
    events.compactMap { if case .message(let message) = $0 { message } else { nil } }
}

private func notices(_ events: [TurnEvent]) -> [String] {
    events.compactMap { if case .notice(let text) = $0 { text } else { nil } }
}

/// Collects what `onContextLearned` was called with.
private final class Learned: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    private var statedFlags: [Bool] = []
    func add(_ value: Int, stated: Bool = true) { lock.lock(); values.append(value); statedFlags.append(stated); lock.unlock() }
    var all: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    var stated: [Bool] { lock.lock(); defer { lock.unlock() }; return statedFlags }
}

// MARK: - The cut holds between steps

struct EngineCutTests {
    @Test func aLongTurnKeepsTheStartOfTheRequestBetweenCompactions() async throws {
        let rounds = (0..<40).map { LLMEvent.toolCalls([call("s\($0)", "read_file", #"{"path":"/tmp/f\#($0).txt"}"#)]) }
        let recorder = Recorder(rounds.map { [$0] } + [[.text("fim")]])
        let events = await collect(engineRequest(recorder, budget: ContextBudget(tokens: 6_000), toolSize: 1_500, maxSteps: 50))
        #expect(!events.contains { if case .failed = $0 { true } else { false } })

        let received = await recorder.received
        #expect(received.count == 41)
        var breaks = 0
        for (earlier, later) in zip(received, received.dropFirst()) where !extends(earlier, later) { breaks += 1 }
        // One break at every step once the window is full would be 30 or more.
        #expect(breaks < 16, "breaks: \(breaks)")
        for sent in received {
            #expect(sent.first?.role == .system)
            #expect(sent.contains { $0.content == "oi" })
            #expect(isValidConversation(Array(sent.dropFirst())))
        }
    }

    @Test func theRequestCarriesTheRealOverheadOfThePromptAndTheTools() async {
        var history: [ChatMessage] = []
        for index in 0..<40 { history += turn("pedido \(index)", output: 4_500, tag: "h\(index)") }
        // ~45,000 tokens of history in a 100,000-token window.
        let budget = ContextBudget(modelWindow: 100_000)
        let plain = Recorder([[.text("ok")]])
        _ = await collect(engineRequest(plain, history: history, budget: budget))
        let withPlain = await plain.received[0]
        #expect(!withPlain.contains { $0.content.hasPrefix(ContextSummary.marker) })

        // The same window, but a system prompt of ~43,000 tokens: the history has to make room for it.
        let heavy = Recorder([[.text("ok")]])
        _ = await collect(engineRequest(heavy, history: history, budget: budget, system: String(repeating: "s", count: 150_000)))
        let withHeavy = await heavy.received[0]
        #expect(withHeavy.contains { $0.content.hasPrefix(ContextSummary.marker) })
        #expect(characters(withHeavy.dropFirst().map { $0 }) < characters(withPlain.dropFirst().map { $0 }))
    }
}

// MARK: - What a refusal teaches

struct EngineLearningTests {
    private func history() -> [ChatMessage] {
        var history: [ChatMessage] = []
        for index in 0..<30 { history += turn("pedido \(index)", output: 600, tag: "h\(index)") }
        return history
    }

    private func run(window: Int?, failures: [Error], learned: Learned) async -> [TurnEvent] {
        let recorder = Recorder([[.text("ok")]], failures: failures)
        var request = engineRequest(recorder, history: longHistory(), budget: window.map { ContextBudget(modelWindow: $0) } ?? ContextBudget(tokens: 6_000))
        request.onContextLearned = { tokens, stated in learned.add(tokens, stated: stated) }
        return await collect(request)
    }

    @Test func aStatedWindowSetsTheBudgetAndIsReportedOnceTheRetryWorks() async {
        let learned = Learned()
        let overflow = LLMError.http(status: 400, message: "This model's maximum context length is 32768 tokens. However, your messages resulted in 90000 tokens.")
        let events = await run(window: 128_000, failures: [overflow], learned: learned)
        #expect(learned.all == [32_768])
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func aRefusalThatNamesNoWindowLowersTheGuess() async {
        let learned = Learned()
        let events = await run(window: 100_000, failures: [LLMError.contextExceeded("too long")], learned: learned)
        #expect(learned.all == [85_000])
        #expect(learned.stated == [false])
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func theRetryIsAlwaysSmallerEvenWhenTheMemoryLevelAlreadyCappedTheBudget() async {
        // An assumed window of 200,000 tokens is capped at 80,000 of history by the memory level; a refusal naming
        // 128,000 would resize to the same 80,000 and send the very same request again.
        var long: [ChatMessage] = []
        // About 60,000 tokens of plain conversation: under the 80,000 budget, over the half of it a retry gets.
        for index in 0..<70 { long += [.user("pedido \(index) " + String(repeating: "a", count: 1_500)), ChatMessage(role: .assistant, content: String(repeating: "b", count: 1_500))] }
        let budget = ContextBudget(model: nil, provider: .anthropic)
        #expect(budget.tokens == 80_000 && budget.resized(window: 128_000).tokens == 80_000)
        let learned = Learned()
        let overflow = LLMError.http(status: 400, message: "maximum context length is 128000 tokens")
        let recorder = Recorder([[.text("ok")]], failures: [overflow])
        var request = engineRequest(recorder, history: long, budget: budget)
        request.onContextLearned = { tokens, stated in learned.add(tokens, stated: stated) }
        let events = await collect(request)
        let received = await recorder.received
        #expect(received.count == 2)
        #expect(characters(received[1]) < characters(received[0]))
        #expect(learned.all == [128_000])
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func aStatedWindowNotSmallerThanTheOneAssumedIsRememberedAsAGuess() async {
        let learned = Learned()
        // The window is right; the estimate of the history was off. The retry halves the history, and the window is
        // lowered as a guess (not stated), so the next turns do not overflow at every cycle.
        let overflow = LLMError.http(status: 400, message: "This model's maximum context length is 65536 tokens, however you requested 70123.")
        let events = await run(window: 65_536, failures: [overflow], learned: learned)
        #expect(learned.all == [Int(Double(65_536) * AgentEngine.unstatedWindowShare)])
        #expect(learned.stated == [false])
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
        // A refusal that names a bigger window teaches the same guess.
        let bigger = Learned()
        let named = LLMError.http(status: 400, message: "prompt is too long: 213456 tokens > 200000 maximum")
        _ = await run(window: 100_000, failures: [named], learned: bigger)
        #expect(bigger.all == [85_000] && bigger.stated == [false])
    }

    @Test func nothingIsReportedWhenTheRetryFailsToo() async {
        let learned = Learned()
        let overflow = LLMError.http(status: 400, message: "maximum context length is 4096 tokens")
        let events = await run(window: 128_000, failures: [overflow, overflow], learned: learned)
        #expect(learned.all.isEmpty)
        #expect(events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func nothingIsReportedWithoutARefusal() async {
        let learned = Learned()
        _ = await run(window: 128_000, failures: [], learned: learned)
        #expect(learned.all.isEmpty)
    }

    @Test func aBudgetOfPlainTokensStillRetriesWithHalfTheHistory() async {
        let learned = Learned()
        let overflow = LLMError.http(status: 400, message: "maximum context length is 4096 tokens")
        let recorder = Recorder([[.text("ok")]], failures: [overflow])
        var request = engineRequest(recorder, history: history(), budget: ContextBudget(tokens: 6_000))
        request.onContextLearned = { tokens, stated in learned.add(tokens, stated: stated) }
        _ = await collect(request)
        let received = await recorder.received
        #expect(received.count == 2)
        #expect(characters(received[1]) < characters(received[0]))
        #expect(learned.all.isEmpty)   // no window to compare with
    }
}

// MARK: - The "continue" after a cut reply

/// The engine adds "continue" when a reply hits the output limit. It steers the turn and starts none: a fold inside the
/// turn never takes the request away from the model, and the record of a paused task covers the whole task.
struct EngineNudgeTests {
    private static let request = "PEDIDO ATUAL: migre o banco do app para SQLite " + String(repeating: "com cuidado ", count: 100)

    @Test func aFoldAfterTheContinueKeepsTheRequestInEveryWindow() async throws {
        var history: [ChatMessage] = []
        for index in 0..<6 { history += turn("pedido antigo \(index)", output: 3_000, tag: "h\(index)") }
        let cutReply: [LLMEvent] = [.text("primeira parte"), .finished(.maxTokens, nil)]
        let rounds = (0..<3).map { [LLMEvent.toolCalls([call("s\($0)", "read_file", #"{"path":"/tmp/g\#($0).txt"}"#)])] }
        let recorder = Recorder([cutReply] + rounds + [[.text("fim")]])
        let events = await collect(engineRequest(recorder, history: history, budget: ContextBudget(tokens: 6_000), toolSize: 9_000,
                                                 prompt: Self.request))
        #expect(!events.contains { if case .failed = $0 { true } else { false } })

        let received = await recorder.received
        #expect(received.count == 5)
        // The history was folded during the turn, after the "continue"…
        #expect(received.dropFirst(2).contains { $0.contains { $0.content.hasPrefix(ContextSummary.marker) } })
        // …and every window still holds the request, right after the summary pair when there is one.
        for sent in received {
            #expect(sent.contains { $0.content == Self.request })
            #expect(isValidConversation(Array(sent.dropFirst())))
        }
        // What was folded is the earlier turns only: the request is not in the summary, the "continue" is no turn.
        let folds = events.compactMap { if case .compacted(let report) = $0, report.kind == .turns { report.fold } else { nil } }
        #expect(!folds.isEmpty)
        for fold in folds {
            #expect(!fold.summary.contains("PEDIDO ATUAL"))
            #expect(fold.turns <= 6)
            #expect((fold.ledger?.foldedMessages ?? 0) <= history.count)
        }
    }

    @Test func aPausedTaskRecordsTheStepsBeforeTheContinueToo() async throws {
        let first = LLMEvent.toolCalls([call("s0", "read_file", #"{"path":"/tmp/f0.txt"}"#)])
        let second = LLMEvent.toolCalls([call("s1", "read_file", #"{"path":"/tmp/f1.txt"}"#)])
        let recorder = Recorder([[first], [.text("parte"), .finished(.maxTokens, nil)], [second], [.text("Fiz.")]])
        let events = await collect(engineRequest(recorder, budget: .fallback, maxSteps: 4))
        let last = try #require(recorded(events).last)
        #expect(last.content.hasPrefix("Fiz.\n\n" + ProgressRecord.marker))
        #expect(last.content.contains("read_file /tmp/f0.txt") && last.content.contains("read_file /tmp/f1.txt"))
        #expect(!last.content.contains(AgentEngine.continueNudge))
        #expect(events.contains { if case .taskPaused = $0 { true } else { false } })
    }

    @Test func theNudgeIsNoTurnStartForTheWindow() throws {
        var input: [ChatMessage] = []
        for index in 0..<6 { input += turn("pedido antigo \(index)", output: 3_000, tag: "w\(index)") }
        let start = input.count
        input += [.user(Self.request), ChatMessage(role: .assistant, content: "primeira parte"), .user(AgentEngine.continueNudge),
                  ChatMessage(role: .assistant, content: "", toolCalls: [call("n0", "read_file", #"{"path":"/tmp/n0.txt"}"#)]),
                  .tool("n0", String(repeating: "y", count: 12_000))]
        let budget = ContextBudget(tokens: 6_000)
        var plain = ContextCut()
        let unaware = ContextWindow.fit(input, budget: budget, cut: &plain)
        // Without knowing the nudge, the cut lands on it: the request leaves the window.
        #expect(!unaware.messages.contains { $0.content == Self.request })
        var cut = ContextCut()
        let window = ContextWindow.fit(input, budget: budget, cut: &cut, nudges: [start + 2])
        #expect(window.messages.contains { $0.content == Self.request })
        #expect(window.droppedCount <= start && cut.covered <= start)
        #expect(window.foldedCount == window.droppedCount)
    }

    @Test func aMessageSentDuringTheTaskKeepsItsOutputsWhole() throws {
        let path = #"{"path":"/tmp/grande.txt"}"#
        let input: [ChatMessage] = [.user("tarefa"), ChatMessage(role: .assistant, content: "", toolCalls: [call("g0", "read_file", path)]),
                                    .tool("g0", String(repeating: "z", count: 20_000)), .user("usa tabs")]
        var plain = ContextCut()
        let unaware = ContextWindow.fit(input, budget: .fallback, cut: &plain)
        #expect(unaware.messages.first { $0.role == .tool }?.content.count ?? 0 < 20_000)
        var cut = ContextCut()
        let window = ContextWindow.fit(input, budget: .fallback, cut: &cut, steering: [3])
        #expect(window.messages.first { $0.role == .tool }?.content.count == 20_000)
        #expect(window.messages.last?.content == "usa tabs")
    }

    @Test func aMessageSentDuringTheTaskIsNoTurnStartForTheWindow() throws {
        var input: [ChatMessage] = []
        for index in 0..<6 { input += turn("pedido antigo \(index)", output: 3_000, tag: "w\(index)") }
        let start = input.count
        input += [.user(Self.request), ChatMessage(role: .assistant, content: "", toolCalls: [call("n0", "read_file", #"{"path":"/tmp/n0.txt"}"#)]),
                  .tool("n0", String(repeating: "y", count: 6_000)), .user("usa tabs"),
                  ChatMessage(role: .assistant, content: "", toolCalls: [call("n1", "read_file", #"{"path":"/tmp/n1.txt"}"#)]),
                  .tool("n1", String(repeating: "y", count: 12_000))]
        let budget = ContextBudget(tokens: 6_000)
        var plain = ContextCut()
        #expect(!ContextWindow.fit(input, budget: budget, cut: &plain).messages.contains { $0.content == Self.request })
        var cut = ContextCut()
        let window = ContextWindow.fit(input, budget: budget, cut: &cut, steering: [start + 3])
        #expect(window.messages.contains { $0.content == Self.request })
        #expect(window.droppedCount <= start && cut.covered <= start)
    }

    @Test func aMessageSentDuringTheTurnKeepsTheOutputsWholeInTheNextRequest() async throws {
        let queue = SteeringQueue()
        let big = LLMEvent.toolCalls([call("s0", "read_file", #"{"path":"/tmp/g.txt"}"#)])
        let next = LLMEvent.toolCalls([call("s1", "read_file", #"{"path":"/tmp/h.txt"}"#)])
        let recorder = Recorder([[big], [next], [.text("fim")]])
        var request = engineRequest(recorder, budget: .fallback, toolSize: 9_000, prompt: "tarefa")
        request.steering = queue
        // The user speaks while the first tool runs: the message goes in at the next step boundary.
        request.tools = [OutputTool(size: 9_000, onRun: { queue.push(SteeredMessage(text: "usa tabs", prompt: "usa tabs")) })]
        let events = await collect(request)
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
        let received = await recorder.received
        #expect(received.count == 3)
        for window in received.dropFirst() {
            #expect(window.contains { $0.role == .tool && $0.content.count >= 9_000 })
            #expect(window.contains { $0.content == AgentEngine.steeringFrame + "\n\nusa tabs" })
        }
    }
}

// MARK: - Step limit

struct EngineStepLimitTests {
    @Test func theLastStepsClosingWordsCarryTheRecordOfTheTask() async throws {
        let rounds = (0..<2).map { LLMEvent.toolCalls([call("s\($0)", "read_file", #"{"path":"/tmp/f\#($0).txt"}"#)]) }
        let recorder = Recorder(rounds.map { [$0] } + [[.text("Fiz duas leituras.")]])
        let events = await collect(engineRequest(recorder, budget: .fallback, maxSteps: 3))
        let messages = recorded(events)
        let last = try #require(messages.last)
        #expect(last.role == .assistant)
        #expect(last.content.hasPrefix("Fiz duas leituras.\n\n" + ProgressRecord.marker))
        #expect(last.content.contains("[passo 1] read_file /tmp/f0.txt"))
        #expect(last.content.contains("[passo 2] read_file /tmp/f1.txt"))
        // The user sees what the model wrote, not the record.
        let shown = events.compactMap { if case .text(let delta) = $0 { delta } else { nil } }.joined()
        #expect(shown == "Fiz duas leituras.")
        #expect(notices(events) == [AgentEngine.pausedNotice(after: 3)])
        // Roles alternate: the assistant's closing words are one message.
        #expect(messages.map(\.role) == [.user, .assistant, .tool, .assistant, .tool, .assistant])
    }

    @Test func aLastStepThatOnlyCalledToolsLeavesTheRecordAsAMessageOfItsOwn() async throws {
        let rounds = (0..<3).map { LLMEvent.toolCalls([call("s\($0)", "read_file", #"{"path":"/tmp/f\#($0).txt"}"#)]) }
        let recorder = Recorder(rounds.map { [$0] })
        let events = await collect(engineRequest(recorder, budget: .fallback, maxSteps: 3))
        let messages = recorded(events)
        let last = try #require(messages.last)
        #expect(last.role == .assistant && last.toolCalls.isEmpty)
        #expect(last.content.hasPrefix(ProgressRecord.marker))
        #expect(messages.dropLast().last?.role == .tool)
        #expect(notices(events) == [AgentEngine.pausedNotice(after: 3)])
    }

    @Test func aTurnThatFinishesInTimeLeavesNoRecord() async {
        let recorder = Recorder([[.toolCalls([call("a")])], [.text("Pronto")]])
        let events = await collect(engineRequest(recorder, budget: .fallback, maxSteps: 5))
        #expect(!recorded(events).contains { $0.content.contains(ProgressRecord.marker) })
        #expect(!events.contains { if case .taskPaused = $0 { true } else { false } })
    }

    @Test func hittingTheLimitTellsTheAppTheTaskIsPaused() async {
        let rounds = (0..<3).map { LLMEvent.toolCalls([call("s\($0)", "read_file", #"{"path":"/tmp/f\#($0).txt"}"#)]) }
        let events = await collect(engineRequest(Recorder(rounds.map { [$0] }), budget: .fallback, maxSteps: 3))
        #expect(events.contains { if case .taskPaused = $0 { true } else { false } })
        let closing = await collect(engineRequest(Recorder(rounds.prefix(2).map { [$0] } + [[.text("Fiz.")]]), budget: .fallback, maxSteps: 3))
        #expect(closing.contains { if case .taskPaused = $0 { true } else { false } })
    }

    @Test func aReplyThatMerelyImitatesTheMarkerDoesNotPauseTheTask() async {
        // The model sees the marker in its own earlier message and may copy it: the engine's word is what counts.
        var conversation = Conversation()
        conversation.messages = [.user("a"), ChatMessage(role: .assistant, content: "Feito. " + ProgressRecord.marker + "\n- nada")]
        #expect(conversation.isTaskPaused)   // stored before the app tracked it: the marker decides
        conversation.taskPaused = false
        #expect(!conversation.isTaskPaused)
        conversation.taskPaused = true
        conversation.messages = [.user("a"), ChatMessage(role: .assistant, content: "ok")]
        #expect(conversation.isTaskPaused)
    }

    @Test func theNextTurnPicksUpWithTheLastOutputsStillWhole() async {
        let rounds = (0..<4).map { LLMEvent.toolCalls([call("s\($0)", "read_file", #"{"path":"/tmp/f\#($0).txt"}"#)]) }
        let first = Recorder(rounds.map { [$0] } + [[.text("Parei.")]])
        let firstEvents = await collect(engineRequest(first, budget: .fallback, toolSize: 20_000, maxSteps: 5))
        var conversation = Conversation()
        conversation.messages = recorded(firstEvents)
        #expect(conversation.isTaskPaused)

        let prepared = conversation.prepareHistory(budget: .fallback)
        let second = Recorder([[.text("Continuando.")]])
        _ = await collect(engineRequest(second, history: prepared.history, budget: .fallback, prompt: "continua"))
        let sent = await second.received[0]
        let outputs = sent.filter { $0.role == .tool }.map(\.content.count)
        #expect(outputs.count == 4)
        // 4 x 20,000 characters is nothing for this window: they stay as the model read them.
        #expect(outputs.allSatisfy { $0 >= 20_000 })   // (one of them also carries the warning about the steps left)

        // The same history without the record is a finished task: its outputs are old by now.
        var finished = recorded(firstEvents)
        finished[finished.count - 1].content = "Parei."
        var other = Conversation()
        other.messages = finished
        let third = Recorder([[.text("ok")]])
        _ = await collect(engineRequest(third, history: other.prepareHistory(budget: .fallback).history, budget: .fallback, prompt: "continua"))
        let oldSent = await third.received[0]
        #expect(oldSent.filter { $0.role == .tool }.allSatisfy { $0.content.count < 5_000 })
    }
}

// MARK: - Saved outputs

struct EngineSavedOutputsTests {
    @Test func bigOutputsGoToTheFolderTheRequestNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "orb-teste-guardadas-" + UUID().uuidString)
        defer { removeTestFolder(directory) }
        let recorder = Recorder([[.toolCalls([call("big-1")])], [.text("pronto")]])
        var request = engineRequest(recorder, budget: .fallback, toolSize: 120_000)
        request.outputsDirectory = directory
        let events = await collect(request)

        let result = try #require(recorded(events).first { $0.role == .tool })
        #expect(result.content.contains(directory.path))
        let folder = directory.appending(path: request.bot.id.uuidString)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        // ...and not to the system's temporary folder the default points at.
        #expect(!result.content.contains(ToolOutputCap.defaultDirectory.path))
    }

    @Test func theFolderLivesInTheDataFolder() {
        let data = URL(fileURLWithPath: "/tmp/orb-dados")
        #expect(ToolOutputCap.directory(inDataFolder: data).path == "/tmp/orb-dados/saidas")
    }
}

// MARK: - Cleaning the saved outputs

struct SavedOutputsCleanupTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "orb-limpeza-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ directory: URL, bot: String, name: String, bytes: Int, age: TimeInterval, now: Date) throws -> URL {
        let botFolder = directory.appending(path: bot)
        try FileManager.default.createDirectory(at: botFolder, withIntermediateDirectories: true)
        let file = botFolder.appending(path: name)
        try Data(repeating: 0x61, count: bytes).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
        return file
    }

    @Test func oldFilesGoAndRecentOnesStay() throws {
        let directory = try folder()
        defer { removeTestFolder(directory) }
        let now = Date.now
        let old = try write(directory, bot: "A", name: "old.txt", bytes: 10, age: 15 * 24 * 3_600, now: now)
        let recent = try write(directory, bot: "A", name: "recent.txt", bytes: 10, age: 2 * 24 * 3_600, now: now)
        let deleted = ToolOutputCap.cleanUp(directory: directory, now: now)
        #expect(deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
    }

    @Test func anOrbOverItsShareLosesItsOldestFirstAndOthersAreLeftAlone() throws {
        let directory = try folder()
        defer { removeTestFolder(directory) }
        let now = Date.now
        let oldest = try write(directory, bot: "A", name: "1.txt", bytes: 600, age: 3_000, now: now)
        let middle = try write(directory, bot: "A", name: "2.txt", bytes: 600, age: 2_000, now: now)
        let newest = try write(directory, bot: "A", name: "3.txt", bytes: 600, age: 1_000, now: now)
        let other = try write(directory, bot: "B", name: "1.txt", bytes: 600, age: 3_000, now: now)
        let deleted = ToolOutputCap.cleanUp(directory: directory, maxBytesPerOrb: 1_000, now: now)
        #expect(deleted == 2)
        #expect(!FileManager.default.fileExists(atPath: oldest.path) && !FileManager.default.fileExists(atPath: middle.path))
        #expect(FileManager.default.fileExists(atPath: newest.path) && FileManager.default.fileExists(atPath: other.path))
    }

    @Test func anEmptiedOrbFolderIsRemovedAndAMissingFolderIsFine() throws {
        let directory = try folder()
        defer { removeTestFolder(directory) }
        let now = Date.now
        try write(directory, bot: "A", name: "old.txt", bytes: 10, age: 30 * 24 * 3_600, now: now)
        #expect(ToolOutputCap.cleanUp(directory: directory, now: now) == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "A").path))
        #expect(ToolOutputCap.cleanUp(directory: directory.appending(path: "nao-existe"), now: now) == 0)
    }

    @Test func removingAnOrbTakesItsOutputsOnly() throws {
        let directory = try folder()
        defer { removeTestFolder(directory) }
        let mine = UUID(), theirs = UUID()
        let now = Date.now
        try write(directory, bot: mine.uuidString, name: "a.txt", bytes: 10, age: 10, now: now)
        let kept = try write(directory, bot: theirs.uuidString, name: "b.txt", bytes: 10, age: 10, now: now)
        ToolOutputCap.removeAll(for: mine, in: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: mine.uuidString).path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        ToolOutputCap.removeAll(for: UUID(), in: directory)   // nothing there: nothing happens
    }
}

// MARK: - Overflow messages

struct ReportedWindowTests {
    @Test func windowsAreReadFromTheWordingOfSeveralProviders() {
        func window(_ message: String) -> Int? { ContextOverflow.reportedWindow(in: message) }
        #expect(window("This model's maximum context length is 128000 tokens. However, your messages resulted in 150000 tokens.") == 128_000)
        #expect(window("prompt is too long: 213456 tokens > 200000 maximum") == 200_000)
        #expect(window("Maximum context length is 8,192 tokens") == 8_192)
        #expect(window("the context window of 32768 tokens was exceeded") == 32_768)
        #expect(window("context length: 4096") == 4_096)
        #expect(window("truncating input prompt n_ctx=2048") == 2_048)
        #expect(window("exceeds the limit of 131072 tokens") == 131_072)
    }

    @Test func messagesWithoutAWindowGiveNothing() {
        #expect(ContextOverflow.reportedWindow(in: "prompt too long") == nil)
        #expect(ContextOverflow.reportedWindow(in: "invalid tool schema") == nil)
        #expect(ContextOverflow.reportedWindow(in: "") == nil)
        // Numbers that cannot be a window.
        #expect(ContextOverflow.reportedWindow(in: "maximum context length is 12 tokens") == nil)
        #expect(ContextOverflow.reportedWindow(in: "maximum context length is 99999999999 tokens") == nil)
    }

    @Test func theNumberIsReadFromEveryKindOfRefusal() {
        #expect(ContextOverflow.reportedWindow(LLMError.http(status: 400, message: "maximum context length is 8192 tokens")) == 8_192)
        #expect(ContextOverflow.reportedWindow(LLMError.contextExceeded("prompt is too long: 3000000 tokens > 1000000 maximum")) == 1_000_000)
        #expect(ContextOverflow.reportedWindow(LLMError.invalidResponse("context window of 16000 tokens")) == 16_000)
        #expect(ContextOverflow.reportedWindow(LLMError.stream(type: "invalid_request_error", message: "prompt is too long: 9999 tokens > 8000 maximum")) == 8_000)
        #expect(ContextOverflow.reportedWindow(LLMError.notConfigured) == nil)
        #expect(ContextOverflow.reportedWindow(CancellationError()) == nil)
    }

    @Test func aLearnedWindowIsFreshForThreeWeeks() {
        let now = Date.now
        #expect(LearnedContext(tokens: 8_000, date: now.addingTimeInterval(-20 * 24 * 3_600)).isFresh(at: now))
        #expect(!LearnedContext(tokens: 8_000, date: now.addingTimeInterval(-22 * 24 * 3_600)).isFresh(at: now))
    }
}

// MARK: - What the app keeps

@MainActor
struct ContextSettingsTests {
    private func model() throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "orb-contexto-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        var account = ProviderAccount(kind: .custom)
        account.models = [ProviderModel(id: "modelo", name: "Modelo", format: .chat, contextLength: 128_000)]
        model.providers = [account]
        model.defaultModel = "custom/modelo"
        return (model, root)
    }

    @Test func theBudgetFollowsTheMemoryLevelAndWhatWasLearned() throws {
        let (model, root) = try model()
        defer { removeTestFolder(root) }
        let bot = model.bots[0]
        #expect(model.contextMemory == .balanced)
        #expect(model.contextBudget(for: bot)?.tokens == 80_000)
        model.contextMemory = .economical
        #expect(model.contextBudget(for: bot)?.tokens == 40_000)
        model.contextMemory = .balanced

        model.learnContextWindow(32_000, of: "custom/modelo")
        #expect(model.contextBudget(for: bot)?.window == 32_000)
        #expect(model.contextBudget(for: bot)?.tokens == 16_800)

        model.forgetLearnedContext(of: "custom/modelo")
        #expect(model.contextBudget(for: bot)?.window == 128_000)
        model.forgetLearnedContext(of: "custom/modelo")   // nothing to forget: nothing happens
    }

    @Test func aStaleLessonIsIgnored() throws {
        let (model, root) = try model()
        defer { removeTestFolder(root) }
        // (reaches into the same store the app reads at launch)
        var state = AppState.initial
        state.providers = model.providers
        state.defaultModel = "custom/modelo"
        state.learnedContexts = ["custom/modelo": LearnedContext(tokens: 4_000, date: Date.now.addingTimeInterval(-40 * 24 * 3_600))]
        Store(directory: root).save(state)
        Store(directory: root).flush()
        let again = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        #expect(again.learnedContexts["custom/modelo"]?.tokens == 4_000)
        #expect(again.contextBudget(for: again.bots[0])?.window == 128_000)
    }

    @Test func claudeCodeIsBudgetedByTheOrbLikeAnyModel() throws {
        let (model, root) = try model()
        defer { removeTestFolder(root) }
        model.providers = [ProviderAccount(kind: .claudeCode)]
        model.defaultModel = "claudeCode/opus"
        #expect(model.contextBudget(for: model.bots[0])?.window == 200_000)
        #expect(model.contextFill(for: model.bots[0].id) != nil)
    }

    @Test func theMeterIsReadFromTheOrbsConversation() throws {
        let (model, root) = try model()
        defer { removeTestFolder(root) }
        let bot = model.bots[0]
        let empty = try #require(model.contextFill(for: bot.id))
        #expect(empty.historyTokens == 0 && empty.windowTokens == 128_000)
        model.apply(.message(.user("oi")), to: bot.id)
        model.apply(.message(ChatMessage(role: .assistant, content: String(repeating: "a", count: 3_500))), to: bot.id)
        let fill = try #require(model.contextFill(for: bot.id))
        #expect(fill.historyTokens > 1_000)
        #expect(model.contextFill(for: UUID()) == nil)
    }

    @Test func theAppRecordsThePauseAndTheNextUserMessageClearsIt() throws {
        let (model, root) = try model()
        defer { removeTestFolder(root) }
        let id = model.bots[0].id
        model.apply(.message(.user("faça")), to: id)
        model.apply(.message(ChatMessage(role: .assistant, content: "Feito. " + ProgressRecord.marker + "\n- x")), to: id)
        // An ordinary reply that copies the marker: the app never heard `.taskPaused`.
        model.apply(.message(.user("outra")), to: id)
        #expect(model.conversations[id]?.taskPaused == false)
        #expect(model.conversations[id]?.isTaskPaused == false)
        model.apply(.taskPaused, to: id)
        #expect(model.conversations[id]?.isTaskPaused == true)
        model.apply(.message(.user("continua")), to: id)
        #expect(model.conversations[id]?.isTaskPaused == false)
    }

    @Test func theMeterAndTheHistoryAgreeOnAPausedTask() throws {
        var conversation = Conversation()
        conversation.messages = [.user("tarefa longa")]
        for index in 0..<6 {
            conversation.messages += [ChatMessage(role: .assistant, content: "", toolCalls: [call("p\(index)", "read_file", #"{"path":"/tmp/p\#(index).txt"}"#)]),
                                      .tool("p\(index)", String(repeating: "x", count: 8_000))]
        }
        conversation.messages.append(ChatMessage(role: .assistant, content: "Parei.\n\n" + ProgressRecord.marker + "\n- x"))
        conversation.taskPaused = true
        let budget = ContextBudget(tokens: 40_000)
        let fill = conversation.contextFill(budget: budget)
        var copy = conversation
        let prepared = copy.prepareHistory(budget: budget).history
        let tokens = ContextBudget.tokens(forCharacters: prepared.reduce(0) { $0 + $1.contextCharacters })
        #expect(abs(fill.historyTokens - tokens) <= tokens / 20)
    }

    @Test func theOverheadTheEngineMeasuredPlansTheNextHistory() throws {
        let (model, root) = try model()
        defer { removeTestFolder(root) }
        let bot = model.bots[0]
        let guessed = try #require(model.contextBudget(for: bot))
        #expect(guessed.overheadTokens == ContextBudget.typicalOverheadTokens)
        model.noteMeasuredOverhead(40_000, of: bot.id)
        let measured = try #require(model.contextBudget(for: bot))
        #expect(measured.overheadTokens == 40_000)
        #expect(measured.tokens < guessed.tokens)
        #expect(model.contextBudget(for: model.createBot(name: "Outro", role: "x", orb: OrbConfig(), model: "", mode: .ask, interview: false, folder: .home))?.overheadTokens == ContextBudget.typicalOverheadTokens)
    }

    @Test func theEngineReportsItsOverheadSoTheNextTurnPlansWithIt() async {
        let recorder = Recorder([[.text("ok")]])
        var request = engineRequest(recorder, budget: ContextBudget(modelWindow: 100_000), system: String(repeating: "s", count: 35_000))
        let measured = Learned()
        request.onOverheadMeasured = { measured.add($0) }
        _ = await collect(request)
        #expect(measured.all.count == 1)
        #expect((measured.all.first ?? 0) >= 10_000)
    }

    @Test func aGuessedWindowIsRememberedForLessThanAStatedOne() {
        let now = Date.now
        let when = now.addingTimeInterval(-10 * 24 * 3_600)
        #expect(!LearnedContext(tokens: 8_000, date: when, inferred: true).isFresh(at: now))
        #expect(LearnedContext(tokens: 8_000, date: when).isFresh(at: now))
    }

    @Test func theChoicesSurviveARestart() throws {
        let (model, root) = try model()
        defer { removeTestFolder(root) }
        model.contextMemory = .wide
        model.learnContextWindow(48_000, of: "custom/modelo")
        model.saveNow()
        let again = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        #expect(again.contextMemory == .wide)
        #expect(again.learnedContexts["custom/modelo"]?.tokens == 48_000)
    }

    @Test func savedOutputsLiveInTheDataFolder() throws {
        let (model, root) = try model()
        defer { removeTestFolder(root) }
        #expect(model.outputsDirectory == root.appending(path: "saidas"))
    }

    @Test func deletingAnOrbDeletesItsSavedOutputs() async throws {
        let (model, root) = try model()
        defer { removeTestFolder(root) }
        let doomed = model.createBot(name: "Segundo", role: "Teste", orb: OrbConfig(), model: "", mode: .ask, interview: false, folder: .home)
        let folder = model.outputsDirectory.appending(path: doomed.id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "x".write(to: folder.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        model.deleteBot(doomed.id)
        await waitUntil("the saved outputs to be deleted") { !FileManager.default.fileExists(atPath: folder.path) }
    }
}

struct AppStateContextTests {
    @Test func stateSavedBeforeTheseSettingsDecodesWithDefaults() throws {
        let old = #"{"bots":[],"routines":[],"skills":[],"connectors":[],"providers":[],"defaultModel":"x/y"}"#
        let state = try JSONDecoder().decode(AppState.self, from: Data(old.utf8))
        #expect(state.contextMemory == .balanced)
        #expect(state.learnedContexts.isEmpty)
    }

    @Test func aLevelThisVersionDoesNotKnowBecomesBalancedAndBadLessonsAreDropped() throws {
        let json = #"{"bots":[],"contextMemory":"infinita","learnedContexts":{"a/b":{"tokens":"muitos"}}}"#
        let state = try DecodeLoss.measure { try JSONDecoder().decode(AppState.self, from: Data(json.utf8)) }
        #expect(state.value.contextMemory == .balanced)
        #expect(state.value.learnedContexts.isEmpty)
        // The level that was replaced is counted, so the file keeps a copy of what it said.
        #expect(state.skipped >= 1)
    }

    @Test func theChoicesRoundTrip() throws {
        var state = AppState.initial
        state.contextMemory = .economical
        state.learnedContexts = ["openai/gpt": LearnedContext(tokens: 64_000, date: Date(timeIntervalSince1970: 1_790_000_000))]
        let again = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        #expect(again.contextMemory == .economical)
        #expect(again.learnedContexts == state.learnedContexts)
    }
}
