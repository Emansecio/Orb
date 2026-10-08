import Foundation
import Testing
@testable import Orb

/// What the provider's prompt cache did, per request and per turn.
struct CacheMetricsTests {
    // MARK: TokenUsage

    @Test func theWholePromptIsInputPlusWhatTheCacheServedAndStored() {
        #expect(TokenUsage(input: 120, output: 5, cacheRead: 8_000, cacheWrite: 300).promptTokens == 8_420)
        #expect(TokenUsage(input: 100).promptTokens == 100)
        #expect(TokenUsage(cacheRead: 50).promptTokens == 50)
        #expect(TokenUsage(output: 7).promptTokens == nil)
        #expect(TokenUsage().promptTokens == nil)
    }

    @Test func theHitRatioIsTheShareOfThePromptServedFromTheCache() throws {
        let hit = try #require(TokenUsage(input: 100, output: 5, cacheRead: 900, cacheWrite: 0).cacheHitRatio)
        #expect(hit == 0.9)
        // First request of a conversation: everything written, nothing read.
        #expect(TokenUsage(input: 0, cacheRead: 0, cacheWrite: 8_000).cacheHitRatio == 0)
        // A provider that has a cache and missed says 0 read: a ratio of 0, not "unknown".
        #expect(TokenUsage(input: 5_000, cacheRead: 0).cacheHitRatio == 0)
        #expect(TokenUsage(input: 5_000, cacheRead: 0).reportsCache)
    }

    @Test func noRatioWithoutACacheReportOrWithoutAPrompt() {
        // A local server reports no cache at all.
        #expect(TokenUsage(input: 5_000, output: 20).cacheHitRatio == nil)
        #expect(!TokenUsage(input: 5_000, output: 20).reportsCache)
        #expect(TokenUsage(input: 0, cacheRead: 0, cacheWrite: 0).cacheHitRatio == nil)
        #expect(TokenUsage().cacheHitRatio == nil)
    }

    @Test func aTurnsRatioIsTheRatioOfItsSum() throws {
        var total = TokenUsage()
        total.add(TokenUsage(input: 0, output: 10, cacheRead: 0, cacheWrite: 8_000))
        total.add(TokenUsage(input: 500, output: 10, cacheRead: 8_000, cacheWrite: 0))
        total.add(TokenUsage(input: 600, output: 10, cacheRead: 8_500, cacheWrite: 0))
        #expect(total.promptTokens == 25_600)
        let ratio = try #require(total.cacheHitRatio)
        #expect(abs(ratio - 16_500.0 / 25_600.0) < 0.0001)
    }

    // MARK: Judging a turn

    private func turn(requests: Int, prompt: Int, read: Int, reports: Bool = true) -> (TokenUsage, Int) {
        var total = TokenUsage()
        for index in 0..<requests {
            let served = index == 0 ? 0 : read
            total.add(reports ? TokenUsage(input: prompt - served, output: 10, cacheRead: served, cacheWrite: 0)
                      : TokenUsage(input: prompt, output: 10))
        }
        return (total, requests)
    }

    @Test func aTurnWhoseCacheNeverHitsIsFailing() {
        let (total, requests) = turn(requests: 4, prompt: 9_000, read: 0)
        #expect(CacheHealth.isFailing(total, requests: requests))
    }

    @Test func aTurnWhoseCacheWorksIsNotFailing() {
        let (total, requests) = turn(requests: 4, prompt: 9_000, read: 8_500)
        #expect(!CacheHealth.isFailing(total, requests: requests))
    }

    @Test func nothingIsJudgedTooEarlyTooSmallOrWithoutAReport() {
        // Two requests: the first one always misses.
        var (total, requests) = turn(requests: 2, prompt: 9_000, read: 0)
        #expect(!CacheHealth.isFailing(total, requests: requests))
        // Prompts too small for any provider to cache.
        (total, requests) = turn(requests: 5, prompt: 900, read: 0)
        #expect(!CacheHealth.isFailing(total, requests: requests))
        // A server that does not report a cache (local models) has nothing to warn about.
        (total, requests) = turn(requests: 5, prompt: 9_000, read: 0, reports: false)
        #expect(!CacheHealth.isFailing(total, requests: requests))
    }

    @Test func theWarningIsInPortugueseAndPointsToTheCost() {
        #expect(CacheHealth.notice.contains("cache"))
        #expect(CacheHealth.notice.contains("encarece"))
    }

    @Test func theDebugLineShowsTheRatioPerRequest() {
        #expect(CacheHealth.logLine(step: 3, usage: TokenUsage(input: 100, output: 45, cacheRead: 7_900, cacheWrite: 0))
                == "step 3: prompt 8000, cache read 7900 write 0 (99%), out 45")
        #expect(CacheHealth.logLine(step: 1, usage: TokenUsage(input: 5_000, output: 9)) == "step 1: prompt 5000, cache not reported, out 9")
    }
}

// MARK: - The engine reports each request

private actor Replies {
    private var queue: [[LLMEvent]]
    init(_ queue: [[LLMEvent]]) { self.queue = queue }
    func next() -> [LLMEvent] { queue.isEmpty ? [.text("fim")] : queue.removeFirst() }
}

private struct ReplyingLLM: LLMClient {
    let replies: Replies
    var arrangesPromptCache = true
    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for event in await replies.next() { continuation.yield(event) }
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
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String { "visto" }
}

struct EngineCacheReportTests {
    private let lookCall = LLMEvent.toolCalls([ToolCallRequest(id: "c1", name: "look", arguments: "{}")])

    private func events(_ replies: [[LLMEvent]], arrangesCache: Bool = true) async -> [TurnEvent] {
        let bot = Bot(name: "Teste", role: "", orb: OrbConfig(), permissionMode: .auto)
        let request = TurnRequest(bot: bot, model: "fake", system: "sys", history: [], prompt: "oi",
                                  client: ReplyingLLM(replies: Replies(replies), arrangesPromptCache: arrangesCache), tools: [LookTool()],
                                  context: ToolContext(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory())))
        var collected: [TurnEvent] = []
        for await event in AgentEngine().run(request) { collected.append(event) }
        return collected
    }

    private func requestUsages(_ events: [TurnEvent]) -> [TokenUsage] {
        events.compactMap { if case .requestUsage(let usage) = $0 { usage } else { nil } }
    }

    private func totals(_ events: [TurnEvent]) -> [TokenUsage] {
        events.compactMap { if case .usage(let usage) = $0 { usage } else { nil } }
    }

    private func notices(_ events: [TurnEvent]) -> [String] {
        events.compactMap { if case .notice(let text) = $0 { text } else { nil } }
    }

    @Test func eachRequestIsReportedAloneBeforeTheTurnsRunningTotal() async throws {
        let first = TokenUsage(input: 0, output: 10, cacheRead: 0, cacheWrite: 8_000)
        let second = TokenUsage(input: 300, output: 20, cacheRead: 8_000, cacheWrite: 0)
        let all = await events([[lookCall, .finished(.toolUse, first)], [.text("ok"), .finished(.done, second)]])
        #expect(requestUsages(all) == [first, second])
        #expect(totals(all).count == 2)
        #expect(totals(all).last?.cacheRead == 8_000 && totals(all).last?.cacheWrite == 8_000)
        // The order in the stream: the request, then the total that includes it.
        let tags = all.compactMap { event -> String? in
            switch event {
            case .requestUsage: "request"
            case .usage: "total"
            default: nil
            }
        }
        #expect(tags == ["request", "total", "request", "total"])
        #expect(try #require(requestUsages(all).last?.cacheHitRatio) > 0.9)
    }

    @Test func aProviderThatReportsNothingEmitsNoUsage() async {
        let all = await events([[.text("oi"), .finished(.done, nil)]])
        #expect(requestUsages(all).isEmpty && totals(all).isEmpty)
    }

    @Test func aCacheThatNeverHitsIsSaidOncePerTurn() async {
        let miss = TokenUsage(input: 9_000, output: 10, cacheRead: 0, cacheWrite: 0)
        let all = await events([[lookCall, .finished(.toolUse, miss)], [lookCall, .finished(.toolUse, miss)],
                                [lookCall, .finished(.toolUse, miss)], [lookCall, .finished(.toolUse, miss)],
                                [.text("pronto"), .finished(.done, miss)]])
        #expect(notices(all) == [CacheHealth.notice])
    }

    @Test func aClientThatNeverAsksForACacheIsNotBlamedForMissingIt() async {
        let miss = TokenUsage(input: 9_000, output: 10, cacheRead: 0, cacheWrite: 0)
        let all = await events([[lookCall, .finished(.toolUse, miss)], [lookCall, .finished(.toolUse, miss)],
                                [lookCall, .finished(.toolUse, miss)], [lookCall, .finished(.toolUse, miss)],
                                [.text("pronto"), .finished(.done, miss)]], arrangesCache: false)
        #expect(notices(all).isEmpty)
    }

    @Test func onlyTheClientsThatArrangeACacheAreHeldToIt() throws {
        let key = "k"
        let openAI = try #require(URL(string: "https://api.openai.com/v1"))
        let router = try #require(URL(string: "https://openrouter.ai/api/v1"))
        let local = try #require(URL(string: "http://localhost:11434/v1"))
        #expect(OpenAIClient(baseURL: openAI, apiKey: key).arrangesPromptCache)
        #expect(!OpenAIClient(baseURL: router, apiKey: key).arrangesPromptCache)
        #expect(!OpenAIClient(baseURL: local, apiKey: key).arrangesPromptCache)
        #expect(ResponsesClient(baseURL: openAI, apiKey: key).arrangesPromptCache)
        #expect(!ResponsesClient(baseURL: router, apiKey: key).arrangesPromptCache)
        #expect(AnthropicClient(baseURL: try #require(URL(string: "https://api.anthropic.com/v1")), apiKey: key).arrangesPromptCache)
    }

    @Test func aWorkingCacheSaysNothing() async {
        let write = TokenUsage(input: 0, output: 10, cacheRead: 0, cacheWrite: 9_000)
        let hit = TokenUsage(input: 200, output: 10, cacheRead: 9_000, cacheWrite: 0)
        let all = await events([[lookCall, .finished(.toolUse, write)], [lookCall, .finished(.toolUse, hit)],
                                [lookCall, .finished(.toolUse, hit)], [.text("pronto"), .finished(.done, hit)]])
        #expect(notices(all).isEmpty)
    }

    @Test func aServerWithoutACacheReportSaysNothing() async {
        let plain = TokenUsage(input: 9_000, output: 10)
        let all = await events([[lookCall, .finished(.toolUse, plain)], [lookCall, .finished(.toolUse, plain)],
                                [lookCall, .finished(.toolUse, plain)], [.text("pronto"), .finished(.done, plain)]])
        #expect(notices(all).isEmpty)
    }
}

// MARK: - The app keeps them

@MainActor
struct AppModelCacheReportTests {
    private func model() -> (AppModel, Bot, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        return (model, model.bots[0], root)
    }

    private func notices(_ model: AppModel, _ bot: Bot) -> [String] {
        model.transcript(bot.id).compactMap { if case .notice(let text) = $0.kind { text } else { nil } }
    }

    @Test func theLatestRequestAndTheTurnTotalAreKeptApart() {
        let (model, bot, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = TokenUsage(input: 100, output: 5, cacheRead: 7_900, cacheWrite: 0)
        let total = TokenUsage(input: 5_100, output: 25, cacheRead: 7_900, cacheWrite: 0)
        model.apply(.requestUsage(request), to: bot.id)
        model.apply(.usage(total), to: bot.id)
        #expect(model.requestUsage[bot.id] == request)
        #expect(model.usage[bot.id] == total)
        #expect(model.requestUsage[bot.id]?.promptTokens == 8_000)
    }

    @Test func theCacheWarningAppearsOncePerConversation() {
        let (model, bot, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        model.apply(.notice(CacheHealth.notice), to: bot.id)
        model.apply(.notice("Outro aviso"), to: bot.id)
        model.apply(.notice(CacheHealth.notice), to: bot.id)
        model.apply(.notice("Outro aviso"), to: bot.id)
        // Other notices are not collapsed; the cache one is.
        #expect(notices(model, bot) == [CacheHealth.notice, "Outro aviso", "Outro aviso"])
        // A new conversation can say it again.
        model.newConversation(bot.id)
        model.apply(.notice(CacheHealth.notice), to: bot.id)
        #expect(notices(model, bot) == [CacheHealth.notice])
    }
}
