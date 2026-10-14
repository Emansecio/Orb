import Foundation
import Testing
@testable import Orb

// Conversation history sent to the model: budget, trimming, summary, output cap and overflow recovery.

// MARK: - Helpers

/// One finished turn: the request, `steps` tool rounds with `output`-sized results, and a final answer.
private func turn(_ request: String, steps: Int = 1, output: Int = 100, tag: String = "t") -> [ChatMessage] {
    var messages: [ChatMessage] = [.user(request)]
    for step in 0..<steps {
        let id = "\(tag)-\(step)"
        messages.append(ChatMessage(role: .assistant, content: "", toolCalls: [call(id, "read_file", #"{"path":"/tmp/\#(tag).txt"}"#)]))
        messages.append(.tool(id, String(repeating: "x", count: output)))
    }
    messages.append(ChatMessage(role: .assistant, content: "Resposta de \(request)"))
    return messages
}

private func engineRequest(_ recorder: Recorder, history: [ChatMessage] = [], budget: ContextBudget, toolSize: Int = 100,
                           bot: Bot = Bot(name: "Teste", role: "", orb: OrbConfig(), permissionMode: .bypass)) -> TurnRequest {
    TurnRequest(bot: bot, model: "fake", system: "sys", history: history, prompt: "oi", client: ReplayLLM(recorder: recorder),
                tools: [OutputTool(size: toolSize)], context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory),
                budget: budget)
}

private func collect(_ request: TurnRequest) async -> [TurnEvent] {
    var events: [TurnEvent] = []
    for await event in AgentEngine().run(request) { events.append(event) }
    return events
}

private func failures(_ events: [TurnEvent]) -> [String] {
    events.compactMap { if case .failed(let message) = $0 { message } else { nil } }
}

// MARK: - Budget

struct ContextBudgetTests {
    @Test func historyIsTheWindowMinusWhatEveryRequestCarriesEstimatedAtThreePointFiveCharactersPerToken() {
        // 90% of 100,000, minus the typical system prompt and tool specs (8,000) and room for the reply (4,000).
        let budget = ContextBudget(modelWindow: 100_000)
        #expect(budget.tokens == 78_000)
        #expect(budget.characters == 273_000)
    }

    @Test func aHugeWindowIsNotFilledJustBecauseItExists() {
        #expect(ContextBudget(modelWindow: 1_000_000).tokens == 80_000)
        #expect(ContextBudget(modelWindow: 1_000_000, level: .economical).tokens == 40_000)
        // "Ampla" takes up to 60% of the window.
        #expect(ContextBudget(modelWindow: 1_000_000, level: .wide).tokens == 600_000)
        // ...and never less than "Equilibrado": in a 100k window that is all that is free (78,000), not 60%.
        #expect(ContextBudget(modelWindow: 100_000, level: .wide).tokens == 78_000)
        #expect(ContextBudget(modelWindow: 128_000, level: .wide).tokens == 80_000)
        // ...but never more than what is free after the fixed part.
        #expect(ContextBudget(modelWindow: 30_000, level: .wide).tokens == 15_250)
    }

    @Test func anAbsurdWindowFromACatalogDoesNotOverflowTheBudget() {
        for window in [9_000_000_000_000_000_000, Int.max] {
            let model = ProviderModel(id: "x", name: "x", format: .chat, contextLength: window)
            let wide = ContextBudget(model: model, provider: .custom, level: .wide)
            #expect(wide.tokens == Int(Double(ContextBudget.largestWindow) * ContextBudget.wideShare))
            #expect(wide.characters > 0)
            #expect(ContextBudget(model: model, provider: .custom).resized(window: window).characters > 0)
        }
        #expect(ContextBudget(tokens: Int.max / 2).characters > 0)
    }

    @Test func absurdTokenCountsFromAServerSaturateInsteadOfOverflowing() {
        var usage = TokenUsage(input: Int.max - 1)
        usage.add(TokenUsage(input: 10))
        #expect(usage.input == Int.max)
        #expect(TokenUsage(input: Int.max, cacheRead: 5, cacheWrite: 7).promptTokens == Int.max)
        #expect(TokenUsage(input: 100, cacheRead: 5).promptTokens == 105)
    }

    @Test func aWiderLevelNeverGivesLessHistory() {
        for window in [16_000, 32_000, 64_000, 100_000, 128_000, 131_072, 200_000, 1_000_000] {
            let economical = ContextBudget(modelWindow: window, level: .economical).tokens
            let balanced = ContextBudget(modelWindow: window, level: .balanced).tokens
            let wide = ContextBudget(modelWindow: window, level: .wide).tokens
            #expect(economical <= balanced && balanced <= wide, "window \(window)")
        }
    }

    @Test func aSmallWindowKeepsRoomForThePromptToolsAndReply() {
        // 16k window: 14,400 usable - 8,000 fixed - 2,000 reply (an eighth of the window at most).
        #expect(ContextBudget(modelWindow: 16_000).tokens == 4_400)
        // It never goes below the minimum, whatever the window.
        #expect(ContextBudget(modelWindow: 8_000).tokens == ContextBudget.minimumTokens)
        #expect(ContextBudget(modelWindow: 4_000).tokens == ContextBudget.minimumTokens)
    }

    @Test func theRealOverheadReplacesTheTypicalOne() {
        let typical = ContextBudget(modelWindow: 100_000)
        #expect(typical.tokens == 78_000)
        // 90,000 - 30,000 (a lot of connector tools) - 4,000
        let heavy = typical.refined(overheadTokens: 30_000)
        #expect(heavy.tokens == 56_000)
        #expect(heavy.overheadTokens == 30_000)
        // Less overhead never lifts the cap of the memory level.
        #expect(ContextBudget(modelWindow: 400_000).refined(overheadTokens: 500).tokens == 80_000)
        // A budget of plain tokens has no window to refine against.
        #expect(ContextBudget(tokens: 5_000).refined(overheadTokens: 20_000).tokens == 5_000)
    }

    @Test func knownContextLengthWins() {
        let model = ProviderModel(id: "m", name: "m", format: .chat, contextLength: 32_000)
        // 28,800 - 8,000 - 4,000
        #expect(ContextBudget(model: model, provider: .openai).tokens == 16_800)
        #expect(ContextBudget(model: model, provider: .ollama).tokens == 16_800)
    }

    @Test func unknownContextLengthFallsBackPerWireFormat() {
        func tokens(_ format: APIFormat, _ provider: ProviderKind) -> Int {
            ContextBudget(model: ProviderModel(id: "m", name: "m", format: format), provider: provider).tokens
        }
        #expect(tokens(.chat, .openrouter) == 80_000)
        #expect(tokens(.responses, .openai) == 80_000)
        #expect(tokens(.messages, .anthropic) == 80_000)
        #expect(tokens(.chat, .ollama) == 4_400)
        #expect(tokens(.chat, .lmstudio) == 4_400)
        #expect(ContextBudget(model: nil, provider: .xai).tokens == 80_000)
        #expect(ContextBudget(model: nil, provider: .xai).window == 128_000)
        #expect(ContextBudget(model: nil, provider: .anthropic).window == 200_000)
    }

    @Test func aModelMissingFromTheCatalogFollowsTheProvidersWireFormat() {
        #expect(ContextBudget(model: nil, provider: .anthropic).window == 200_000)
        #expect(ContextBudget(model: nil, provider: .custom, format: .messages).window == 200_000)
        #expect(ContextBudget(model: nil, provider: .custom, format: .chat).window == 128_000)
        #expect(ContextBudget(model: nil, provider: .ollama, format: .chat).tokens == 4_400)
    }

    @Test func anthropicKeepsRoomForItsLargerReply() {
        let messages = ContextBudget(model: ProviderModel(id: "m", name: "m", format: .messages, contextLength: 40_000), provider: .anthropic)
        let chat = ContextBudget(model: ProviderModel(id: "m", name: "m", format: .chat, contextLength: 40_000), provider: .openai)
        #expect(messages.replyTokens == 5_000)   // an eighth of a small window
        #expect(chat.replyTokens == 4_000)
        let big = ContextBudget(model: ProviderModel(id: "m", name: "m", format: .messages, contextLength: 400_000), provider: .anthropic)
        #expect(big.replyTokens == 16_000)
    }

    @Test func aLearnedWindowWinsOnlyWhenSmaller() {
        let model = ProviderModel(id: "m", name: "m", format: .chat, contextLength: 128_000)
        #expect(ContextBudget(model: model, provider: .openai, learnedWindow: 32_000).window == 32_000)
        #expect(ContextBudget(model: model, provider: .openai, learnedWindow: 500_000).window == 128_000)
        #expect(ContextBudget(model: nil, provider: .ollama, learnedWindow: 4_096).window == 4_096)
        #expect(ContextBudget(model: model, provider: .openai, learnedWindow: nil).window == 128_000)
    }

    @Test func theLowWaterMarkIsHigherForSmallBudgets() {
        #expect(ContextBudget(modelWindow: 128_000).lowWater == 0.5)
        #expect(ContextBudget(modelWindow: 16_000).lowWater == 0.75)
        var manual = ContextBudget(modelWindow: 128_000)
        manual.lowWaterShare = 0.3
        #expect(manual.lowWater == 0.3)
    }

    @Test func scalingAndResizingKeepTheRest() {
        let budget = ContextBudget(modelWindow: 128_000)
        let half = budget.scaled(by: 0.5)
        #expect(half.tokens == 40_000 && half.window == 128_000)
        let learned = budget.resized(window: 32_000)
        #expect(learned.window == 32_000)
        #expect(learned.tokens == 16_800)
        #expect(learned.overheadTokens == budget.overheadTokens)
    }

    @Test func overheadIsEstimatedFromThePromptAndSpecs() {
        let spec = ToolSpec(name: "read_file", description: String(repeating: "d", count: 100), parameters: .schema(["path": .property("string", "p")]))
        let tokens = ContextBudget.overheadTokens(system: String(repeating: "s", count: 350), specs: [spec])
        let characters = 350 + "read_file".count + 100 + spec.parameters.jsonString.count
        #expect(tokens == Int((Double(characters) / 3.5).rounded(.up)))
    }
}

struct ContextMemoryLevelTests {
    @Test func unknownLevelsDecodeAsBalanced() throws {
        let level = try JSONDecoder().decode(ContextMemoryLevel.self, from: Data(#""enorme""#.utf8))
        #expect(level == .balanced)
        let known = try JSONDecoder().decode(ContextMemoryLevel.self, from: Data(#""wide""#.utf8))
        #expect(known == .wide)
    }

    @Test func everyLevelHasALabelAndASummary() {
        for level in ContextMemoryLevel.allCases {
            #expect(!level.label.isEmpty && !level.summary.isEmpty)
        }
    }
}

// MARK: - Window

struct ContextWindowTests {
    @Test func aHistoryThatFitsIsSentAsIs() {
        let history = turn("a") + turn("b")
        #expect(history.modelContext() == history)
    }

    @Test func aSixtyOneMessageTurnKeepsTheRequestAtTheStart() {
        let history: [ChatMessage] = turn("faça tudo", steps: 30, output: 2_000)
        #expect(history.count == 62)
        let sent = Array(history.dropLast()).modelContext()   // 61 messages: the user request and 30 tool rounds
        #expect(sent.count == 61)
        #expect(sent.first == .user("faça tudo"))
        #expect(isValidConversation(sent))
    }

    @Test func theRequestSurvivesEvenWhenTheTurnAloneExceedsTheBudget() {
        var messages = [ChatMessage.user("pedido original")]
        for step in 0..<30 {
            messages.append(ChatMessage(role: .assistant, content: "", toolCalls: [call("c\(step)", "read_file", #"{"path":"/tmp/f\#(step).txt"}"#)]))
            messages.append(.tool("c\(step)", String(repeating: "z", count: 3_000)))
        }
        let budget = ContextBudget(tokens: 3_000)
        let window = ContextWindow.fit(messages, budget: budget)
        #expect(isValidConversation(window.messages))
        #expect(window.messages.contains { $0.content == "pedido original" })
        #expect(characters(window.messages) <= budget.characters + ContextSummary.reserve)
        // The newest step is still there.
        #expect(window.messages.last?.toolCallID == "c29")
    }

    @Test func theWindowNeverStartsWithAnAssistantOrToolMessage() {
        var history: [ChatMessage] = []
        for index in 0..<12 { history += turn("pedido \(index)", steps: 3, output: 3_000, tag: "k\(index)") }
        for tokens in [500, 1_000, 2_000, 5_000, 20_000] {
            let sent = history.modelContext(budget: ContextBudget(tokens: tokens))
            #expect(sent.first?.role == .user)
            #expect(isValidConversation(sent))
        }
        // A slice that starts in the middle of a turn also starts at a user message.
        let slice = Array(history[2...])
        #expect(slice.modelContext().first?.role == .user)
    }

    @Test func theNewestOutputsOfATaskInProgressStayWholeAndTheOldestBecomePreviewsTogether() {
        var messages = [ChatMessage.user("pedido")]
        for step in 0..<8 {
            messages.append(ChatMessage(role: .assistant, content: "", toolCalls: [call("c\(step)")]))
            messages.append(.tool("c\(step)", String(repeating: "o", count: 10_000)))
        }
        // Room for all eight whole: none is touched.
        #expect(messages.modelContext().filter { $0.role == .tool }.allSatisfy { $0.content.count == 10_000 })
        // 8 x 10,000 characters is more than 40% of this budget (60,000 characters), and there are 3 more than the
        // newest three: the oldest five become previews at once.
        let sent = messages.modelContext(budget: ContextBudget(tokens: 17_000))
        let outputs = sent.filter { $0.role == .tool }.map(\.content.count)
        #expect(outputs.prefix(5).allSatisfy { $0 < 5_000 })
        #expect(outputs.suffix(3).allSatisfy { $0 == 10_000 })
    }

    @Test func hugeOutputsOfTheLastFinishedTurnAreShortenedAtTheRealCallSite() {
        // What AppModel.send passes: the stored messages, without the new prompt.
        let stored = turn("leia o arquivo", steps: 1, output: 200_000)
        let sent = stored.modelContext()
        #expect(sent.count == stored.count)
        let output = sent.first { $0.role == .tool }
        #expect((output?.content.count ?? Int.max) < 5_000)
        #expect(output?.content.contains("omitted") == true)
        #expect(output?.content.hasPrefix("xxxx") == true)
        #expect(output?.content.hasSuffix("xxxx") == true)
    }

    @Test func longStringArgumentsOfOlderCallsAreShortenedKeepingValidJSON() throws {
        let big = String(repeating: "L", count: 50_000)
        let arguments = JSONValue.object(["path": .string("/tmp/a.txt"), "content": .string(big)]).jsonString
        var history = [ChatMessage.user("escreva"), ChatMessage(role: .assistant, content: "", toolCalls: [call("w1", "write_file", arguments)]),
                       .tool("w1", "ok"), ChatMessage(role: .assistant, content: "feito")]
        history += turn("depois")
        let sent = history.modelContext()
        let shortened = try #require(sent[1].toolCalls.first?.arguments)
        let parsed = try #require(JSONValue.parse(shortened))
        #expect(parsed["path"]?.string == "/tmp/a.txt")
        let content = try #require(parsed["content"]?.string)
        #expect(content.count < 1_200)
        #expect(content.hasPrefix("LLLL"))
        #expect(content.contains("omitted"))
    }

    @Test func fittingTwiceGivesTheSameResult() throws {
        let big = String(repeating: "L", count: 50_000)
        let arguments = JSONValue.object(["path": .string("/tmp/a.txt"), "content": .string(big)]).jsonString
        var history = [ChatMessage.user("escreva"), ChatMessage(role: .assistant, content: "", toolCalls: [call("w1", "write_file", arguments)]),
                       .tool("w1", String(repeating: "S", count: 20_000)), ChatMessage(role: .assistant, content: "feito")]
        history += turn("depois", steps: 2, output: 10_000)
        for tokens in [500, 3_000, 128_000] {
            let budget = ContextBudget(tokens: tokens)
            let once = ContextWindow.fit(history, budget: budget).messages
            let twice = ContextWindow.fit(once, budget: budget).messages
            #expect(once == twice)
        }
        let once = ContextWindow.fit(history, budget: ContextBudget(tokens: 128_000)).messages
        let stored = try #require(once[1].toolCalls.first?.arguments)
        let content = try #require(JSONValue.parse(stored)?["content"]?.string)
        #expect(content.hasSuffix("[49000 more characters omitted]"))
    }

    @Test func cuttingAnAlreadyCutArgumentAddsToTheOmittedCount() throws {
        let arguments = JSONValue.object(["content": .string(String(repeating: "L", count: 5_000))]).jsonString
        let first = ContextText.shortenArguments(arguments, stringLimit: 1_000)
        let second = ContextText.shortenArguments(first, stringLimit: 300)
        let content = try #require(JSONValue.parse(second)?["content"]?.string)
        #expect(content.hasPrefix(String(repeating: "L", count: 300) + "…"))
        #expect(content.hasSuffix("[4700 more characters omitted]"))
    }

    @Test func aStepsOnlySummaryDoesNotClaimEarlierTurnsWereDropped() throws {
        var messages = [ChatMessage.user("pedido original")]
        for step in 0..<30 {
            messages.append(ChatMessage(role: .assistant, content: "", toolCalls: [call("c\(step)", "read_file", #"{"path":"/tmp/f\#(step).txt"}"#)]))
            messages.append(.tool("c\(step)", String(repeating: "z", count: 3_000)))
        }
        let window = ContextWindow.fit(messages, budget: ContextBudget(tokens: 3_000))
        #expect(window.summary == nil)
        let header = try #require(window.messages.first)
        #expect(header.content.hasPrefix(ContextSummary.marker))
        #expect(header.content.contains("primeiros passos deste pedido"))
        #expect(!header.content.contains("começo desta conversa foi compactado"))
    }

    @Test func argumentsThatAreNotJSONAreWrappedWhenTheyMustBeCut() throws {
        let broken = "{\"content\": \"" + String(repeating: "q", count: 5_000)
        let result = ContextText.shortenArguments(broken, stringLimit: 1_000)
        let parsed = try #require(JSONValue.parse(result))
        #expect(parsed["truncated_arguments"]?.string?.count ?? .max < 1_200)
    }

    @Test func droppedTurnsBecomeASummaryPairInsteadOfBeingLost() throws {
        var history = turn("organize a pasta Fotos em /Users/ana/Fotos", steps: 2, output: 20_000, tag: "a")
        for index in 0..<8 { history += turn("pedido \(index)", steps: 2, output: 20_000, tag: "b\(index)") }
        let budget = ContextBudget(tokens: 8_000)
        let window = ContextWindow.fit(history, budget: budget)

        #expect(window.droppedCount > 0)
        let summary = try #require(window.summary)
        #expect(summary.contains("Pedido original: organize a pasta Fotos"))
        #expect(summary.contains("Arquivos e links lidos"))
        #expect(summary.contains("/tmp/a.txt"))
        #expect(window.messages[0].role == .user)
        #expect(window.messages[0].content.hasPrefix("[Resumo do começo desta conversa]"))
        #expect(window.messages[1].role == .assistant)
        #expect(window.messages[2].role == .user)
        #expect(isValidConversation(window.messages))
        #expect(characters(window.messages) <= budget.characters)
        // The last turn is intact.
        #expect(window.messages.last == ChatMessage(role: .assistant, content: "Resposta de pedido 7"))
    }

    @Test func aPreviousSummaryIsKeptAndExtendedWithoutNesting() throws {
        var history: [ChatMessage] = []
        for index in 0..<6 { history += turn("pedido \(index)", output: 30_000, tag: "p\(index)") }
        let budget = ContextBudget(tokens: 3_000)
        let first = ContextWindow.fit(history, budget: budget)
        #expect(first.droppedCount > 0)
        let kept = Array(history[first.droppedCount...])
        let second = ContextWindow.fit(kept + turn("novo", output: 30_000, tag: "n"), budget: budget, summary: first.summary, ledger: first.ledger)
        let summary = try #require(second.summary)
        #expect(!summary.contains("Resumo anterior"))
        #expect(summary.contains("pedido 0"))
        #expect(summary.contains("pedido 3"))
        #expect(second.droppedCount > 0)
        #expect(isValidConversation(second.messages))
    }

    @Test func aSummaryWrittenByAnEarlierVersionIsCarriedOnceAsText() throws {
        let old = "Pedidos do usuário:\n- pedido antigo sobre o Atlas\nResumo anterior: Pedidos do usuário:\n- mais antigo ainda"
        var history: [ChatMessage] = []
        for index in 0..<6 { history += turn("pedido \(index)", output: 30_000, tag: "p\(index)") }
        let window = ContextWindow.fit(history, budget: ContextBudget(tokens: 3_000), summary: old)
        let summary = try #require(window.summary)
        #expect(summary.contains("Resumo anterior (formato antigo): Pedidos do usuário: - pedido antigo sobre o Atlas"))
        #expect(!summary.contains("mais antigo ainda"))
        #expect(summary.components(separatedBy: "Resumo anterior").count == 2)
        // Extending it again does not nest it.
        let again = ContextWindow.fit(Array(history[window.droppedCount...]) + turn("novo", output: 30_000, tag: "n"),
                                      budget: ContextBudget(tokens: 3_000), summary: window.summary, ledger: window.ledger)
        #expect(again.summary?.components(separatedBy: "Resumo anterior").count == 2)
    }

    @Test func aSummaryPairAlreadyAtTheStartIsRecognizedAndNotDuplicated() {
        let pair = ContextSummary.pair("Pedidos do usuário:\n- antigo")
        #expect(ContextSummary.leading(in: pair + turn("novo"))?.contains("antigo") == true)
        let sent = (pair + turn("novo")).modelContext()
        #expect(sent.filter { $0.content.hasPrefix(ContextSummary.marker) }.count == 1)
        #expect(sent.count == pair.count + 4)
    }

    @Test func unansweredCallsStillGetAResultAfterTrimming() {
        var history = turn("a", steps: 2, output: 500, tag: "x")
        history += [.user("b"), ChatMessage(role: .assistant, content: "", toolCalls: [call("dangling")])]
        let sent = history.modelContext()
        #expect(sent.last?.role == .tool)
        #expect(sent.last?.toolCallID == "dangling")
    }
}

// MARK: - Conversation

struct ConversationCompactionTests {
    private func longConversation() -> Conversation {
        var conversation = Conversation()
        for index in 0..<10 { conversation.messages += turn("pedido \(index)", steps: 2, output: 25_000, tag: "q\(index)") }
        return conversation
    }

    @Test func compactingStoresTheSummaryAndAnnouncesItOnlyTheFirstTime() throws {
        var conversation = longConversation()
        let before = conversation.messages
        let budget = ContextBudget(tokens: 5_000)

        let first = conversation.prepareHistory(budget: budget)
        #expect(first.firstCompaction)
        #expect(first.history[0].content.hasPrefix(ContextSummary.marker))
        let covered = try #require(conversation.summaryCoveredCount)
        #expect(covered > 0)
        #expect(conversation.summary?.contains("- pedido ") == true)
        #expect(conversation.messages == before)

        conversation.messages += turn("pedido 10", steps: 2, output: 25_000, tag: "q10")
        let second = conversation.prepareHistory(budget: budget)
        #expect(!second.firstCompaction)
        #expect((conversation.summaryCoveredCount ?? 0) >= covered)
        #expect(isValidConversation(second.history))
        #expect(second.history.filter { $0.content.hasPrefix(ContextSummary.marker) }.count == 1)
    }

    @Test func aShortConversationIsNeverCompacted() {
        var conversation = Conversation()
        conversation.messages = turn("oi") + turn("tchau")
        let prepared = conversation.prepareHistory(budget: .fallback)
        #expect(!prepared.firstCompaction)
        #expect(conversation.summary == nil)
        #expect(conversation.summaryCoveredCount == nil)
        #expect(prepared.history == conversation.messages)
    }

    @Test func conversationsSavedBeforeTheSummaryExistedStillDecode() throws {
        let old = #"{"items":[],"messages":[{"role":"user","content":"oi","toolCalls":[]}]}"#
        let decoded = try JSONDecoder().decode(Conversation.self, from: Data(old.utf8))
        #expect(decoded.summary == nil)
        #expect(decoded.summaryCoveredCount == nil)
        #expect(decoded.messages.count == 1)

        var conversation = longConversation()
        _ = conversation.prepareHistory(budget: ContextBudget(tokens: 10_000))
        let again = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        #expect(again.summary == conversation.summary)
        #expect(again.summaryCoveredCount == conversation.summaryCoveredCount)
    }

    @Test func aCoveredCountBeyondTheMessagesIsClamped() {
        var conversation = Conversation()
        conversation.messages = turn("oi")
        conversation.summary = "algo"
        conversation.summaryCoveredCount = 999
        let prepared = conversation.prepareHistory(budget: .fallback)
        #expect(prepared.history.first?.content.hasPrefix(ContextSummary.marker) == true)
    }
}

// MARK: - Big tool outputs

struct ToolOutputCapTests {
    private func savedFiles(in directory: URL, _ botID: UUID) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory.appending(path: botID.uuidString), includingPropertiesForKeys: nil)
    }

    @Test func aBigOutputGoesToAFileAndTheModelGetsHeadAndTail() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "orb-teste-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let botID = UUID()
        let output = "INICIO" + String(repeating: "m", count: 100_000) + "FIM"

        let capped = ToolOutputCap.apply(output, botID: botID, callID: "call_1/../x", directory: directory)

        #expect(capped.count < 16_000)
        #expect(capped.hasPrefix("INICIO"))
        #expect(capped.contains("FIM"))
        #expect(capped.contains("full output saved at"))
        #expect(capped.contains("read_file"))
        let files = try savedFiles(in: directory, botID)
        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.lastPathComponent.hasPrefix("call_1____x-"))
        #expect(capped.contains(file.lastPathComponent))
        #expect(try String(contentsOf: file, encoding: .utf8) == output)
    }

    @Test func outputsOfCallsWithTheSameIDDoNotOverwriteEachOther() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "orb-teste-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let botID = UUID()
        let first = "PRIMEIRO" + String(repeating: "a", count: 60_000)
        let second = "SEGUNDO" + String(repeating: "b", count: 60_000)

        let cappedFirst = ToolOutputCap.apply(first, botID: botID, callID: "call_0", directory: directory)
        let cappedSecond = ToolOutputCap.apply(second, botID: botID, callID: "call_0", directory: directory)

        let files = try savedFiles(in: directory, botID)
        #expect(files.count == 2)
        let contents = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(contents.contains(first) && contents.contains(second))
        let pathOfFirst = try #require(files.first { cappedFirst.contains($0.lastPathComponent) })
        #expect(try String(contentsOf: pathOfFirst, encoding: .utf8) == first)
        #expect(!cappedSecond.contains(pathOfFirst.lastPathComponent))
    }

    @Test func theSavedPathSurvivesWhenTheOutputAgesIntoAPreview() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "orb-teste-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let botID = UUID()
        let capped = ToolOutputCap.apply(String(repeating: "m", count: 100_000), botID: botID, callID: "c1", directory: directory)
        let file = try #require(try savedFiles(in: directory, botID).first)
        let messages: [ChatMessage] = [.user("rode"), ChatMessage(role: .assistant, content: "", toolCalls: [call("c1", "run_command")]),
                                       .tool("c1", capped), ChatMessage(role: .assistant, content: "pronto"), .user("e agora?")]

        let seen = messages.modelContext()
        let aged = try #require(seen.first { $0.role == .tool })

        #expect(aged.content.count < capped.count)
        #expect(aged.content.contains(file.lastPathComponent))
        // The count of omitted characters keeps adding up across the two cuts.
        let omitted = aged.content.split(separator: "[… ").dropFirst().first.flatMap { Int($0.prefix { $0.isNumber }) }
        #expect((omitted ?? 0) > 85_000)
        #expect(aged.content.components(separatedBy: "characters omitted from the middle").count == 2)
    }

    @Test func anOutputThatCannotBeAskedForAgainIsKeptWholeWithACopyForWhenItAges() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "orb-teste-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let botID = UUID()
        let output = "INICIO" + String(repeating: "m", count: 9_000) + "MEIO" + String(repeating: "m", count: 9_000) + "FIM"

        let kept = ToolOutputCap.apply(output, botID: botID, callID: "c1", directory: directory, keepsCopy: true)
        #expect(kept.hasPrefix(output)) // whole: only the note is added
        let file = try #require(try savedFiles(in: directory, botID).first)
        #expect(try String(contentsOf: file, encoding: .utf8) == output)

        // Later the conversation shortens it: the middle is gone from the window, not from reach.
        let messages: [ChatMessage] = [.user("rode"), ChatMessage(role: .assistant, content: "", toolCalls: [call("c1", "run_command")]),
                                       .tool("c1", kept), ChatMessage(role: .assistant, content: "pronto"), .user("e agora?")]
        let aged = try #require(messages.modelContext().first { $0.role == .tool })
        #expect(!aged.content.contains("MEIO"))
        #expect(aged.content.contains(file.lastPathComponent))

        // Short ones, those a tool saved already (`run_command`) and file reads (`keepsCopy: false`) are left alone.
        let short = String(repeating: "s", count: ToolOutputCap.copiedFrom)
        #expect(ToolOutputCap.apply(short, botID: botID, callID: "c2", directory: directory, keepsCopy: true) == short)
        let spilled = output + ContextText.savedNoteOpen + "/tmp/x.txt; read it]"
        #expect(ToolOutputCap.apply(spilled, botID: botID, callID: "c3", directory: directory, keepsCopy: true) == spilled)
        #expect(ToolOutputCap.apply(output, botID: botID, callID: "c4", directory: directory) == output)
        #expect(try savedFiles(in: directory, botID).count == 1)
    }

    @Test func withoutFileToolsALongPageStaysInlineAndNothingIsSaved() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "orb-teste-" + UUID().uuidString)
        let page = String(repeating: "p", count: 30_300)   // web_fetch: 30,000 characters plus its header
        #expect(ToolOutputCap.apply(page, botID: UUID(), callID: "w", toolNames: ["web_fetch"], directory: directory) == page)

        let huge = "INICIO" + String(repeating: "p", count: 100_000) + "FIM"
        let capped = ToolOutputCap.apply(huge, botID: UUID(), callID: "w", toolNames: ["web_fetch"], directory: directory)
        #expect(capped.hasPrefix("INICIO"))
        #expect(capped.contains("FIM"))
        #expect(!capped.contains("read_file"))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func theNoteOnlyNamesToolsTheBotHas() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "orb-teste-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = String(repeating: "m", count: 50_000)
        let onlyRead = ToolOutputCap.apply(output, botID: UUID(), callID: "a", toolNames: ["read_file"], directory: directory)
        #expect(onlyRead.contains("read_file") && !onlyRead.contains("run_command"))
        let onlyShell = ToolOutputCap.apply(output, botID: UUID(), callID: "b", toolNames: ["run_command"], directory: directory)
        #expect(onlyShell.contains("run_command") && !onlyShell.contains("read_file"))
        let both = ToolOutputCap.apply(output, botID: UUID(), callID: "c", directory: directory)
        #expect(both.contains("head -c"))
    }

    @Test func anOutputWithinTheCapIsUntouchedAndWritesNothing() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "orb-teste-" + UUID().uuidString)
        let output = String(repeating: "a", count: ToolOutputCap.limit)
        #expect(ToolOutputCap.apply(output, botID: UUID(), callID: "c", directory: directory) == output)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func theEngineCapsToolResultsBeforeTheyReachTheModel() async throws {
        let botID = UUID()
        var bot = Bot(name: "Teste", role: "", orb: OrbConfig(), permissionMode: .bypass)
        bot.id = botID
        let folder = ToolOutputCap.defaultDirectory.appending(path: botID.uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = Recorder([[.toolCalls([call("big-1")])], [.text("pronto")]])

        let events = await collect(engineRequest(recorder, budget: .fallback, toolSize: 120_000, bot: bot))

        let result = events.compactMap { event -> ChatMessage? in
            if case .message(let message) = event, message.role == .tool { message } else { nil }
        }.first
        let content = try #require(result?.content)
        #expect(content.count < 16_000)
        #expect(content.contains(folder.path))
        let file = try #require(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        #expect(file.lastPathComponent.hasPrefix("big-1-"))
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved.count == 120_000)
        let seen = await recorder.received[1].last
        #expect(seen?.content == content)
    }
}

// MARK: - Engine

struct ContextEngineTests {
    @Test func theTurnIsTrimmedBeforeEveryModelCallAndKeepsTheRequest() async throws {
        let rounds = (0..<12).map { LLMEvent.toolCalls([call("s\($0)")]) }
        let recorder = Recorder(rounds.map { [$0] } + [[.text("fim")]])
        let budget = ContextBudget(tokens: 3_000)   // ≈ 10,500 characters of history
        let events = await collect(engineRequest(recorder, budget: budget, toolSize: 6_000))

        #expect(failures(events).isEmpty)
        let received = await recorder.received
        #expect(received.count == 13)
        for sent in received {
            #expect(sent.first?.role == .system)
            #expect(sent.dropFirst().first?.role == .user)
            #expect(sent.contains { $0.content == "oi" })
            #expect(isValidConversation(Array(sent.dropFirst())))
        }
        let last = try #require(received.last)
        #expect(characters(Array(last.dropFirst())) <= budget.characters + ContextSummary.reserve)
        // The conversation recorded for the transcript is not trimmed.
        let recorded: [ChatMessage] = events.compactMap { if case .message(let message) = $0 { message } else { nil } }
        let expected = 26   // the request, 12 tool rounds of two messages, the final answer
        #expect(recorded.count == expected)
    }

    @Test func aWindowOverflowErrorIsRetriedOnceWithHalfTheBudget() async {
        var history: [ChatMessage] = []
        for index in 0..<30 { history += turn("pedido \(index)", steps: 1, output: 600, tag: "h\(index)") }
        let overflow = LLMError.http(status: 400, message: "This model's maximum context length is 128000 tokens")
        let recorder = Recorder([[.text("ok")]], failures: [overflow])
        let events = await collect(engineRequest(recorder, history: history, budget: ContextBudget(tokens: 6_000)))

        let received = await recorder.received
        #expect(received.count == 2)
        #expect(characters(received[1]) < characters(received[0]))
        #expect(failures(events).isEmpty)
        #expect(events.contains { if case .message(let message) = $0 { message.content == "ok" } else { false } })
    }

    @Test func aTurnThatSetsStepsAsideAnnouncesItOnceWithNumbers() async {
        let rounds = (0..<8).map { LLMEvent.toolCalls([call("s\($0)")]) }
        let recorder = Recorder(rounds.map { [$0] } + [[.text("fim")]])
        let events = await collect(engineRequest(recorder, budget: ContextBudget(tokens: 1_500), toolSize: 3_000))
        let reports = events.compactMap { if case .compacted(let report) = $0 { report } else { nil } }
        #expect(reports.count == 1)
        let report = reports.first
        #expect(report?.kind == .steps)
        #expect((report?.foldedMessages ?? 0) > 0)
        #expect(report?.fold == nil)   // steps of the request in progress are not kept for the next turn
        #expect(report?.notice.hasPrefix("Neste pedido, resumi ") == true)
        #expect(report?.notice.contains("tokens)") == true)
        #expect(!events.contains { if case .notice = $0 { true } else { false } })
    }

    @Test func olderTurnsFoldedInsideATurnAreReportedWithTheSummaryToKeep() async throws {
        var history: [ChatMessage] = []
        for index in 0..<8 { history += turn("pedido número \(index) do projeto", steps: 1, output: 3_000, tag: "h\(index)") }
        let rounds = (0..<4).map { LLMEvent.toolCalls([call("s\($0)")]) }
        let recorder = Recorder(rounds.map { [$0] } + [[.text("fim")]])
        let events = await collect(engineRequest(recorder, history: history, budget: ContextBudget(tokens: 4_000), toolSize: 3_000))
        let folds = events.compactMap { event -> CompactionReport? in
            if case .compacted(let report) = event, report.kind == .turns { report } else { nil }
        }
        #expect(!folds.isEmpty)
        // Each fold is reported once, with how many more messages it covers and the summary after it.
        let total = folds.reduce(0) { $0 + $1.foldedMessages }
        let last = try #require(folds.last?.fold)
        #expect(last.summary.contains("Pedido original: pedido número 0 do projeto"))
        #expect(last.ledger?.original == "pedido número 0 do projeto")
        let received = await recorder.received
        #expect(total > 0 && total <= history.count)
        #expect(received.count == 5)
    }

    @Test func aShortTurnAnnouncesNothing() async {
        let recorder = Recorder([[.text("oi")]])
        let events = await collect(engineRequest(recorder, budget: .fallback))
        #expect(!events.contains { if case .notice = $0 { true } else { false } })
    }

    @Test func anOverflowReportedInsideTheStreamIsRetriedToo() async {
        var history: [ChatMessage] = []
        for index in 0..<8 { history += turn("pedido \(index)", steps: 1, output: 3_000, tag: "h\(index)") }
        let recorder = Recorder([[.text("ok")]], failures: [LLMError.invalidResponse("Your input exceeds the context window of this model")])
        let events = await collect(engineRequest(recorder, history: history, budget: ContextBudget(tokens: 4_000)))
        #expect(await recorder.received.count == 2)
        #expect(failures(events).isEmpty)
    }

    @Test func aSecondOverflowIsReportedInsteadOfLooping() async {
        let overflow = LLMError.http(status: 400, message: "prompt is too long: 300000 tokens > 200000 maximum")
        let recorder = Recorder([], failures: [overflow, overflow])
        let events = await collect(engineRequest(recorder, history: longHistory(), budget: .fallback))
        #expect(await recorder.received.count == 2)
        #expect(failures(events).count == 1)
    }

    @Test func aWindowTheInstructionsAndToolsFillIsSaidSo() async throws {
        // 90% of 2,000 tokens, less the reply's room and the request's own overhead, is under the history's minimum.
        #expect(ContextBudget(modelWindow: 2_000).refined(overheadTokens: 100).isCrowded)
        #expect(!ContextBudget(modelWindow: 16_000).refined(overheadTokens: 8_000).isCrowded)
        #expect(!ContextBudget.fallback.isCrowded)
        let overflow = LLMError.http(status: 400, message: "maximum context length is 2000 tokens")
        let recorder = Recorder([], failures: [overflow, overflow])
        let events = await collect(engineRequest(recorder, budget: ContextBudget(modelWindow: 2_000)))
        let failure = try #require(failures(events).first)
        #expect(failure.contains("quase enchem a janela de 2 mil tokens"))
    }

    @Test func otherErrorsAreNotRetried() async {
        let recorder = Recorder([], failures: [LLMError.http(status: 401, message: "invalid api key")])
        let events = await collect(engineRequest(recorder, budget: .fallback))
        #expect(await recorder.received.count == 1)
        #expect(failures(events).count == 1)
    }

    @Test func overflowDetection() {
        #expect(ContextOverflow.matches(LLMError.http(status: 400, message: "maximum context length is 8192 tokens")))
        #expect(ContextOverflow.matches(LLMError.http(status: 400, message: "prompt is too long: 250000 tokens")))
        #expect(ContextOverflow.matches(LLMError.http(status: 400, message: "Input is too long for requested model")))
        #expect(!ContextOverflow.matches(LLMError.http(status: 400, message: "invalid tool schema")))
        #expect(!ContextOverflow.matches(LLMError.http(status: 500, message: "context length exceeded")))
        #expect(ContextOverflow.matches(LLMError.invalidResponse("prompt is too long")))
        #expect(!ContextOverflow.matches(LLMError.invalidResponse("lista de modelos ausente")))
        #expect(!ContextOverflow.matches(LLMError.notConfigured))
    }
}
