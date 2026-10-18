import Foundation
import Testing
@testable import Orb

// The words and numbers of the context meter, when it shows and when the card for a long conversation does, and what the
// model hands the settings and the popover. (How it looks is reviewed with `--snapshot context-*`.)

private func conversation(turns: Int, characters: Int = 3_500) -> Conversation {
    var conversation = Conversation()
    for turn in 0..<turns {
        conversation.messages += [.user("pedido \(turn) " + String(repeating: "a", count: characters)),
                                  ChatMessage(role: .assistant, content: "resposta \(turn) " + String(repeating: "b", count: characters))]
        conversation.items += [TranscriptItem(.user(text: "pedido \(turn)", attachments: [])),
                               TranscriptItem(.bot(text: "resposta \(turn)", isStreaming: false))]
    }
    return conversation
}

private func input(_ conversation: Conversation, window: Int = 128_000, usage: TokenUsage? = nil) -> ContextInput {
    ContextInput(botID: UUID(), conversation: conversation, budget: ContextBudget(modelWindow: window),
                 windowIsStated: true, usage: usage, memory: .balanced)
}

struct ContextWordsTests {
    @Test func tokensAreSaidApproximately() {
        #expect(ContextWords.approx(0) == "0")
        #expect(ContextWords.approx(840) == "840")
        #expect(ContextWords.approx(999) == "1 mil")
        #expect(ContextWords.approx(3_540) == "3,5 mil")
        #expect(ContextWords.approx(4_000) == "4 mil")
        #expect(ContextWords.approx(9_990) == "10 mil")
        #expect(ContextWords.approx(41_870) == "42 mil")
        #expect(ContextWords.approx(128_000) == "128 mil")
        #expect(ContextWords.approx(999_700) == "1 milhão")
        #expect(ContextWords.approx(1_048_576) == "1 milhão")
        #expect(ContextWords.approx(1_500_000) == "1,5 milhão")
        #expect(ContextWords.approx(2_000_000) == "2 milhões")
        #expect(ContextWords.approx(-5) == "0")
    }

    @Test func usageAndCompactionSentences() {
        #expect(ContextWords.usage(used: 41_870, window: 128_000, windowIsStated: true) == "cerca de 42 mil de 128 mil tokens")
        #expect(ContextWords.usage(used: 41_870, window: 128_000, windowIsStated: false) == "cerca de 42 mil de uns 128 mil tokens")
        #expect(ContextWords.compaction(before: 60_000, after: 18_000) == "De ~60 mil para ~18 mil tokens")
        #expect(ContextWords.cache(0.82) == "82% veio do cache do provedor")
        #expect(ContextWords.cache(0) == "Nada veio do cache do provedor")
        #expect(ContextWords.wouldFree(requests: 1, alreadySummarized: false, tokens: 3_000)
                == "Compactar agora resumiria o primeiro pedido e liberaria cerca de 3 mil tokens.")
        #expect(ContextWords.wouldFree(requests: 5, alreadySummarized: false, tokens: 3_000).contains("os 5 primeiros pedidos e"))
        #expect(ContextWords.wouldFree(requests: 3, alreadySummarized: true, tokens: 3_000).contains("mais 3 pedidos e"))
    }

    @Test func nothingToFoldIsNotCalledShort() {
        #expect(!ContextWords.nothingToFold.contains("curta"))
    }

    @Test func whatIsKept() {
        #expect(ContextWords.kept(totalRequests: 12, foldedRequests: 0) == "Todos os 12 pedidos, palavra por palavra.")
        #expect(ContextWords.kept(totalRequests: 1, foldedRequests: 0) == "O pedido inteiro, palavra por palavra.")
        #expect(ContextWords.kept(totalRequests: 8, foldedRequests: 5) == "Um resumo dos 5 primeiros pedidos e os últimos 3, palavra por palavra.")
        #expect(ContextWords.kept(totalRequests: 5, foldedRequests: 4) == "Um resumo dos 4 primeiros pedidos e o último, palavra por palavra.")
        #expect(ContextWords.kept(totalRequests: 5, foldedRequests: 1) == "Um resumo do primeiro pedido e os últimos 4, palavra por palavra.")
    }
}

struct ContextReadingTests {
    /// The ring's slice: a few percent still drawn as a slice (not a hairline like a clock's hand), the rest as it is.
    @Test @MainActor func ringSliceHasAVisibleMinimum() {
        #expect(ContextRing.shown(0) == 0)
        #expect(ContextRing.shown(0.02) == ContextRing.minimumSlice)
        #expect(ContextRing.shown(0.5) == 0.5)
        #expect(ContextRing.shown(1.3) == 1)
    }

    @Test func nothingToShowWithoutHistoryOrModel() {
        #expect(ContextReading.make(input(Conversation())) == nil)
        var noModel = input(conversation(turns: 2))
        noModel.budget = nil
        #expect(ContextReading.make(noModel) == nil)
    }

    @Test func aCancelledMeasurementDoesNotWalkTheHistory() async throws {
        let measured = input(conversation(turns: 8))
        #expect(ContextReading.make(measured) != nil)
        // The driver cancels the task of a measurement a newer signal replaced: it stops with nothing.
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return ContextReading.make(measured)
        }
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test func aMeasurementCancelledHalfwayStopsBeforeTheNextWalkOfTheHistory() throws {
        let long = conversation(turns: 8)
        let budget = ContextBudget(modelWindow: 16_000)
        // Never cancelled: every step runs (the check is asked before each of the walks that follow the first).
        var asked = 0
        let whole = ContextMeter.fill(of: long, budget: budget, isCancelled: { asked += 1; return false })
        #expect(whole == ContextMeter.fill(of: long, budget: budget))
        #expect(asked >= 3)
        // Cancelled while the first walk is done: nothing more is measured, and no number comes out.
        var calls = 0
        let stopped = ContextMeter.fill(of: long, budget: budget, isCancelled: { calls += 1; return calls >= 2 })
        #expect(stopped == nil)
        #expect(calls == 2)
    }

    @Test func aShortConversationIsCalmAndHasNothingToCompact() throws {
        let reading = try #require(ContextReading.make(input(conversation(turns: 1, characters: 300))))
        #expect(reading.percent >= 1 && reading.percent < 20)
        #expect(reading.tone == .calm)
        #expect(!reading.canCompact)
        #expect(reading.usageWords.hasPrefix("cerca de"))
    }

    @Test func aLongConversationOffersToCompact() throws {
        // A small window: the history budget is what fills first.
        let reading = try #require(ContextReading.make(input(conversation(turns: 8), window: 16_000)))
        #expect(reading.fill.budgetFraction >= 0.85)
        #expect(reading.tone == ContextTone(share: reading.fraction))
        #expect(reading.canCompact)
    }

    @Test func aBigWindowFillsTheMemoryBudgetBeforeTheWindow() throws {
        // 24 messages of about 1,000 tokens in a 1M window: 2% of the window, but 30% of the 80k budget.
        let reading = try #require(ContextReading.make(input(conversation(turns: 12), window: 1_000_000)))
        #expect(reading.percent <= 5)
        #expect(reading.fill.budgetFraction > reading.fraction)
        // Close to the budget: the next compaction is near, whatever the window.
        let heavy = try #require(ContextReading.make(input(conversation(turns: 12, characters: 10_000), window: 1_000_000)))
        #expect(heavy.fill.budgetFraction >= 0.85)
        // The ring says the window's share and is coloured by it: calm at a few percent.
        #expect(heavy.percent < 85)
        #expect(heavy.tone == .calm)
    }

    @Test func toneFollowsTheShareOfTheWindow() {
        #expect(ContextTone(share: 0.3) == .calm)
        #expect(ContextTone(share: 0.7) == .warming)
        #expect(ContextTone(share: 0.84) == .warming)
        #expect(ContextTone(share: 0.85) == .full)
        #expect(ContextTone(share: 2) == .full)
    }

    /// Below 70% the bar shows the ring alone, unless someone points at it; from there on the number stays.
    @Test func thePercentageShowsWhenItIsWorthReading() {
        #expect(!ContextTone.calm.showsPercent(pointing: false))
        #expect(ContextTone.calm.showsPercent(pointing: true))
        #expect(ContextTone.warming.showsPercent(pointing: false))
        #expect(ContextTone.full.showsPercent(pointing: false))
    }

    @Test func cacheHitComesFromTheLastRequest() throws {
        let hit = TokenUsage(input: 1_800, output: 100, cacheRead: 8_200, cacheWrite: 0)
        let withCache = try #require(ContextReading.make(input(conversation(turns: 2), usage: hit)))
        #expect(withCache.cacheHit == 0.82)
        let withoutCache = try #require(ContextReading.make(input(conversation(turns: 2), usage: TokenUsage(input: 100))))
        #expect(withoutCache.cacheHit == nil)
    }

    @Test func summaryCountsAsFoldedMessages() throws {
        var folded = conversation(turns: 6)
        folded.summary = "Resumo do começo."
        folded.summaryCoveredCount = 6
        let reading = try #require(ContextReading.make(input(folded)))
        #expect(reading.foldedMessages == 6)
        // The words count your requests (one per two messages here), not the model's messages.
        #expect(reading.requestCount == 6 && reading.foldedRequests == 3)
        #expect(ContextWords.kept(totalRequests: reading.requestCount, foldedRequests: reading.foldedRequests)
                == "Um resumo dos 3 primeiros pedidos e os últimos 3, palavra por palavra.")
    }

    @Test func requestsAreCountedNotTheMessagesOfTheToolSteps() throws {
        var chat = conversation(turns: 2)
        chat.messages.insert(contentsOf: [ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: "c", name: "read_file", arguments: "{}")]),
                                          .tool("c", "ok")], at: 1)
        let reading = try #require(ContextReading.make(input(chat)))
        #expect(reading.messageCount == 6 && reading.requestCount == 2)
    }

    @Test func aSingleHugeRequestHasNothingToCompact() throws {
        let chat = conversation(turns: 1, characters: 12_000)
        let reading = try #require(ContextReading.make(input(chat, window: 16_000)))
        #expect(!reading.canCompact)
        #expect(reading.fill.compaction == nil)
    }

    /// The offer promises what the compaction really leaves, measured as the app measures it afterwards.
    @Test func theTokensItWouldFreeAreWhatCompactingFrees() throws {
        var chat = conversation(turns: 1)
        // The latest request is huge: 25 tool outputs of 4,000 characters.
        chat.messages.append(.user("agora leia tudo"))
        for index in 0..<25 {
            let id = "c\(index)"
            chat.messages += [ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: id, name: "read_file", arguments: #"{"path":"/p/a\#(index).txt"}"#)]),
                              .tool(id, String(repeating: "dado ", count: 800))]
        }
        chat.messages.append(ChatMessage(role: .assistant, content: "pronto"))
        let budget = ContextBudget(modelWindow: 128_000)
        let offered = try #require(chat.contextFill(budget: budget).compaction)
        let before = chat.contextFill(budget: budget).historyTokens
        let report = chat.compact(budget: budget)
        #expect(report != nil)
        let freed = before - chat.contextFill(budget: budget).historyTokens
        #expect(freed > 0)
        #expect(abs(Double(offered.tokensFreed - freed)) <= Double(freed) * 0.01 + 1, "\(offered.tokensFreed) vs \(freed)")
    }

    @Test func aCompactionThatFreesNothingIsNotOffered() throws {
        // One short request and one giant: summarizing the short one frees less than `minimumFreed`.
        var chat = Conversation()
        chat.messages = [.user("oi"), ChatMessage(role: .assistant, content: "olá"),
                         .user("pedido " + String(repeating: "x", count: 300_000)), ChatMessage(role: .assistant, content: "ok")]
        let fill = chat.contextFill(budget: ContextBudget(modelWindow: 128_000))
        #expect(fill.compaction == nil)
    }
}

@MainActor
struct ContextModelTests {
    private func makeModel() -> (AppModel, UUID, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbContextUI-\(UUID().uuidString)")
        let state = AppState.initial
        let store = Store(directory: root)
        store.save(state)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        var account = ProviderAccount(kind: .custom)
        account.models = [ProviderModel(id: "modelo", name: "Modelo", format: .chat, contextLength: 32_000)]
        model.providers = [account]
        model.defaultModel = "custom/modelo"
        return (model, state.bots[0].id, root)
    }

    @Test func inputCarriesTheChatAndTheStatedWindow() throws {
        let (model, id, root) = makeModel()
        defer { removeTestFolder(root) }
        model.seedConversation(conversation(turns: 2), for: id)
        let input = try #require(model.contextInput(for: id))
        #expect(input.windowIsStated)
        #expect(input.budget?.window == 32_000)
        #expect(ContextReading.make(input)?.messageCount == 4)
    }

    @Test func noModelMeansNoReading() throws {
        let (model, id, root) = makeModel()
        defer { removeTestFolder(root) }
        model.providers = []
        model.seedConversation(conversation(turns: 2), for: id)
        let input = try #require(model.contextInput(for: id))
        #expect(ContextReading.make(input) == nil)
    }

    @Test func claudeCodeOrbsAreMeasuredLikeAnyOtherWithTheirOwnWindow() throws {
        let (model, id, root) = makeModel()
        defer { removeTestFolder(root) }
        model.providers = [ProviderAccount(kind: .claudeCode)]
        model.defaultModel = "claudeCode/sonnet"
        model.seedConversation(conversation(turns: 2), for: id)
        let input = try #require(model.contextInput(for: id))
        #expect(input.budget?.window == 200_000)
    }

    @Test func learnedWindowsAreListedAndForgotten() {
        let (model, id, root) = makeModel()
        defer { removeTestFolder(root) }
        _ = id
        #expect(model.learnedWindowRows().isEmpty)
        model.learnContextWindow(8_192, of: "custom/modelo")
        model.learnContextWindow(4_096, of: "custom/outro", stated: false)
        let rows = model.learnedWindowRows()
        #expect(rows.count == 2)
        #expect(rows.first { $0.id == "custom/modelo" }?.name == "Modelo")
        #expect(rows.first { $0.id == "custom/outro" }?.isEstimate == true)
        #expect(rows.first { $0.id == "custom/modelo" }?.words == "8,2 mil tokens")
        model.forgetLearnedContext(of: "custom/modelo")
        #expect(model.learnedWindowRows().map(\.id) == ["custom/outro"])
    }

    @Test func staleLessonsAreNotListed() {
        let (model, _, root) = makeModel()
        defer { removeTestFolder(root) }
        model.learnContextWindow(8_192, of: "custom/modelo")
        let future = Date.now.addingTimeInterval(LearnedContext.lifetime + 3_600)
        #expect(model.learnedWindowRows(now: future).isEmpty)
        #expect(LearnedWindowRow(id: "a", name: "a", tokens: 1, date: .now.addingTimeInterval(-3 * 86_400), isEstimate: false)
            .age() == "aprendida há 3 dias")
    }

    @Test func compactingAShortChatSaysThereIsNothingToDo() {
        let (model, id, root) = makeModel()
        defer { removeTestFolder(root) }
        model.seedConversation(conversation(turns: 1, characters: 100), for: id)
        let result = model.compactFromMeter(id, focus: "  ")
        #expect(result.status == .nothingToCompact)
        #expect(!result.didCompact)
        #expect(result.message == ContextWords.nothingToFold)
    }

    @Test func severalShortRequestsAreNotSaidToBeASingleOne() {
        let (model, id, root) = makeModel()
        defer { removeTestFolder(root) }
        model.seedConversation(conversation(turns: 3, characters: 100), for: id)
        let result = model.compactFromMeter(id, focus: nil)
        #expect(result.status == .nothingToCompact)
        #expect(result.message == ContextWords.nothingToCompact(requests: 3, alreadySummarized: false))
        #expect(!result.message.contains("um pedido"))
        #expect(ContextWords.nothingToCompact(requests: 1, alreadySummarized: false) == ContextWords.nothingToFold)
        #expect(!ContextWords.nothingToCompact(requests: 2, alreadySummarized: true).contains("um pedido"))
    }

    @Test func compactingALongChatFoldsItAndTellsTheNumbers() throws {
        let (model, id, root) = makeModel()
        defer { removeTestFolder(root) }
        model.seedConversation(conversation(turns: 10), for: id)
        let beforeInput = try #require(model.contextInput(for: id))
        let before = try #require(ContextReading.make(beforeInput))
        #expect(before.canCompact)
        let result = model.compactFromMeter(id, focus: "decisões")
        #expect(result.status == .compacted)
        #expect(result.tokensAfter < result.tokensBefore)
        let afterInput = try #require(model.contextInput(for: id))
        let after = try #require(ContextReading.make(afterInput))
        #expect(after.foldedMessages > 0)
        #expect(after.fill.usedTokens < before.fill.usedTokens)
    }

    @Test func theLatestRequestAndCompactionAreMirroredOnTheOrbsLiveState() {
        let (model, id, root) = makeModel()
        defer { removeTestFolder(root) }
        #expect(model.live(id).lastUsage == nil && model.live(id).compactedTo == nil)
        let used = TokenUsage(input: 1_000, output: 10, cacheRead: 3_000, cacheWrite: 0)
        model.apply(.requestUsage(used), to: id)
        #expect(model.live(id).lastUsage == used)
        model.apply(.compacted(CompactionReport(kind: .manual, foldedMessages: 0, tokensBefore: 9_000, tokensAfter: 2_000)), to: id)
        #expect(model.live(id).compactedTo == 2_000)
        #expect(model.contextInput(for: id)?.usage == used)
    }
}
