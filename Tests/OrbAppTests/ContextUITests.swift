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

private func input(_ conversation: Conversation, window: Int = 128_000, claudeCode: Bool = false,
                   usage: TokenUsage? = nil) -> ContextInput {
    ContextInput(botID: UUID(), conversation: conversation, budget: claudeCode ? nil : ContextBudget(modelWindow: window),
                 isClaudeCode: claudeCode, windowIsStated: true, usage: usage, memory: .balanced)
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
        #expect(ContextWords.wouldFree(messages: 1, tokens: 3_000).contains("1 mensagem e"))
    }

    @Test func whatIsKept() {
        #expect(ContextWords.kept(totalMessages: 12, foldedMessages: 0) == "Todas as 12 mensagens, palavra por palavra.")
        #expect(ContextWords.kept(totalMessages: 1, foldedMessages: 0) == "A mensagem inteira, palavra por palavra.")
        #expect(ContextWords.kept(totalMessages: 30, foldedMessages: 24) == "Um resumo das 24 primeiras mensagens e as últimas 6, palavra por palavra.")
        #expect(ContextWords.kept(totalMessages: 5, foldedMessages: 4) == "Um resumo das 4 primeiras mensagens e a última, palavra por palavra.")
    }
}

struct ContextReadingTests {
    @Test func nothingToShowWithoutHistoryOrModel() {
        #expect(ContextReading.make(input(Conversation())) == nil)
        var noModel = input(conversation(turns: 2))
        noModel.budget = nil
        #expect(ContextReading.make(noModel) == nil)
    }

    @Test func aShortConversationIsCalmAndHasNothingToCompact() throws {
        let reading = try #require(ContextReading.make(input(conversation(turns: 1, characters: 300))))
        #expect(reading.percent >= 1 && reading.percent < 20)
        #expect(reading.tone == .calm)
        #expect(!reading.isGettingLong)
        #expect(!reading.canCompact)
        #expect(reading.conversationKey != nil)
        #expect(reading.usageWords?.hasPrefix("cerca de") == true)
    }

    @Test func aLongConversationWarnsAndOffersToCompact() throws {
        // A small window: the history budget is what fills first.
        let reading = try #require(ContextReading.make(input(conversation(turns: 8), window: 16_000)))
        #expect(reading.pressure >= ContextReading.suggestsCompactingAt)
        #expect(reading.isGettingLong)
        #expect(reading.tone == ContextTone(share: reading.fraction))
        #expect(reading.canCompact)
    }

    @Test func aBigWindowWarnsByTheMemoryBudgetBeforeTheWindowFills() throws {
        // 24 messages of about 1,000 tokens in a 1M window: 2% of the window, but 30% of the 80k budget.
        let reading = try #require(ContextReading.make(input(conversation(turns: 12), window: 1_000_000)))
        #expect(reading.percent <= 5)
        #expect(reading.pressure > reading.fraction)
        // More history than the budget: the next message starts a compaction, so the meter says so whatever the window.
        let heavy = try #require(ContextReading.make(input(conversation(turns: 12, characters: 10_000), window: 1_000_000)))
        #expect(heavy.isGettingLong)
        #expect(heavy.percent < 85)
        // The ring says the window's share and is coloured by it: calm at a few percent, even though the card is due.
        #expect(heavy.tone == .calm)
    }

    @Test func toneFollowsTheShareOfTheWindow() {
        #expect(ContextTone(share: 0.3) == .calm)
        #expect(ContextTone(share: 0.7) == .warming)
        #expect(ContextTone(share: 0.84) == .warming)
        #expect(ContextTone(share: 0.85) == .full)
        #expect(ContextTone(share: 2) == .full)
    }

    @Test func claudeCodeHasNoNumbersButCanStartOver() throws {
        let reading = try #require(ContextReading.make(input(conversation(turns: 2), claudeCode: true,
                                                              usage: TokenUsage(input: 1, cacheRead: 9))))
        #expect(reading.fill == nil)
        #expect(reading.isClaudeCode)
        #expect(reading.canCompact)
        #expect(!reading.isGettingLong)
        #expect(reading.cacheHit == nil)
        #expect(reading.spokenState.contains("Claude Code"))
        var single = Conversation()
        single.messages = [.user("oi")]
        let one = try #require(ContextReading.make(input(single, claudeCode: true)))
        #expect(one.canCompact == false)
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
        #expect(ContextWords.kept(totalMessages: reading.messageCount, foldedMessages: reading.foldedMessages).hasPrefix("Um resumo das 6 primeiras"))
    }
}

@MainActor
struct ContextNudgeTests {
    private func defaults() -> UserDefaults {
        let suite = "ContextNudgeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func showsOnceForALongConversation() throws {
        let store = ContextNudgeStore(defaults: defaults())
        let gauge = ContextGauge(nudges: store)
        let long = try #require(ContextReading.make(input(conversation(turns: 8), window: 16_000)))
        gauge.show(long)
        #expect(gauge.showsNudge)
        gauge.handleNudge()
        #expect(!gauge.showsNudge)
        // Still long, still the same conversation, and after a relaunch (a new gauge on the same preferences): not again.
        gauge.show(long)
        #expect(!gauge.showsNudge)
        let relaunched = ContextGauge(nudges: store)
        relaunched.show(long)
        #expect(!relaunched.showsNudge)
    }

    @Test func aNewConversationGetsItsOwnCard() throws {
        let gauge = ContextGauge(nudges: ContextNudgeStore(defaults: defaults()))
        let first = try #require(ContextReading.make(input(conversation(turns: 8), window: 16_000)))
        gauge.show(first)
        gauge.handleNudge()
        let second = try #require(ContextReading.make(input(conversation(turns: 8), window: 16_000)))
        gauge.show(second)
        #expect(gauge.showsNudge)
    }

    @Test func notShownForAShortConversationOrWhenCleared() throws {
        let gauge = ContextGauge(nudges: ContextNudgeStore(defaults: defaults()))
        let short = try #require(ContextReading.make(input(conversation(turns: 1, characters: 200))))
        gauge.show(short)
        #expect(!gauge.showsNudge)
        gauge.show(nil)
        #expect(gauge.reading == nil)
        #expect(!gauge.showsNudge)
    }

    @Test func theStoreKeepsTheNewestOnly() {
        let store = ContextNudgeStore(defaults: defaults())
        let ids = (0..<(ContextNudgeStore.limit + 5)).map { _ in UUID() }
        ids.forEach(store.insert)
        #expect(!store.contains(ids[0]))
        #expect(store.contains(ids[ids.count - 1]))
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
        defer { try? FileManager.default.removeItem(at: root) }
        model.seedConversation(conversation(turns: 2), for: id)
        let input = try #require(model.contextInput(for: id))
        #expect(input.windowIsStated)
        #expect(!input.isClaudeCode)
        #expect(input.budget?.window == 32_000)
        #expect(ContextReading.make(input)?.messageCount == 4)
    }

    @Test func noModelMeansNoReading() throws {
        let (model, id, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.providers = []
        model.seedConversation(conversation(turns: 2), for: id)
        let input = try #require(model.contextInput(for: id))
        #expect(ContextReading.make(input) == nil)
    }

    @Test func claudeCodeOrbsAreMeasuredWithoutABudget() throws {
        let (model, id, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.providers = [ProviderAccount(kind: .claudeCode)]
        model.defaultModel = "claudeCode/sonnet"
        model.seedConversation(conversation(turns: 2), for: id)
        let input = try #require(model.contextInput(for: id))
        #expect(input.isClaudeCode)
        #expect(input.budget == nil)
    }

    @Test func learnedWindowsAreListedAndForgotten() {
        let (model, id, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
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
        defer { try? FileManager.default.removeItem(at: root) }
        model.learnContextWindow(8_192, of: "custom/modelo")
        let future = Date.now.addingTimeInterval(LearnedContext.lifetime + 3_600)
        #expect(model.learnedWindowRows(now: future).isEmpty)
        #expect(LearnedWindowRow(id: "a", name: "a", tokens: 1, date: .now.addingTimeInterval(-3 * 86_400), isEstimate: false)
            .age() == "aprendida há 3 dias")
    }

    @Test func compactingAShortChatSaysThereIsNothingToDo() {
        let (model, id, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.seedConversation(conversation(turns: 1, characters: 100), for: id)
        let result = model.compactFromMeter(id, focus: "  ")
        #expect(result.status == .nothingToCompact)
        #expect(!result.didCompact)
    }

    @Test func compactingALongChatFoldsItAndTellsTheNumbers() throws {
        let (model, id, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
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
        #expect(after.fill?.usedTokens ?? .max < before.fill?.usedTokens ?? 0)
    }

    @Test func compactingAClaudeCodeChatRestartsItsSessionAndSaysSoInTheTranscript() throws {
        let (model, id, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.providers = [ProviderAccount(kind: .claudeCode)]
        model.defaultModel = "claudeCode/sonnet"
        model.seedConversation(conversation(turns: 3), for: id)
        let result = model.compactFromMeter(id, focus: "  decisões  ")
        #expect(result.status == .claudeSessionRestarted)
        #expect(result.didCompact)
        #expect(result.message.contains(AppModel.claudeRestartNote))
        let notices = model.conversations[id]?.items.compactMap { item -> String? in
            if case .notice(let text) = item.kind { text } else { nil }
        } ?? []
        #expect(notices.contains(AppModel.claudeRestartNote))
        #expect(notices.count == 2) // the compaction's own notice and the new-session one
    }

    @Test func theLatestRequestAndCompactionAreMirroredOnTheOrbsLiveState() {
        let (model, id, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.live(id).lastUsage == nil && model.live(id).compactedTo == nil)
        let used = TokenUsage(input: 1_000, output: 10, cacheRead: 3_000, cacheWrite: 0)
        model.apply(.requestUsage(used), to: id)
        #expect(model.live(id).lastUsage == used)
        model.apply(.compacted(CompactionReport(kind: .claudeCode, foldedMessages: 0, tokensBefore: 9_000, tokensAfter: 2_000, trigger: "auto")), to: id)
        #expect(model.live(id).compactedTo == 2_000)
        #expect(model.contextInput(for: id)?.usage == used)
    }
}
