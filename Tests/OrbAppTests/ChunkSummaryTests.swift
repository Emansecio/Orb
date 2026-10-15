import Foundation
import Testing
@testable import Orb

// The model's note on the stretch the next fold will take (`ChunkSummary`): what is summarized and when, what is sent,
// which model writes it, how the summary and the memory page carry it, and what happens when there is none.

/// `turns` turns of about `characters` characters each: the request (with `first` as the first one) and the answer.
private func conversation(turns: Int, characters: Int = 3_500, first: String? = nil) -> Conversation {
    var chat = Conversation()
    for turn in 0..<turns {
        let request = turn == 0 ? (first ?? "Construa o app Atlas com SQLite") : "pedido \(turn) do projeto"
        chat.messages += [.user(request + " " + String(repeating: "a", count: characters / 2)),
                          ChatMessage(role: .assistant, content: "resposta \(turn) " + String(repeating: "b", count: characters / 2))]
    }
    return chat
}

/// 20,000 tokens of history = 70,000 characters.
private let budget = ContextBudget(tokens: 20_000)

struct ChunkPlanTests {
    @Test func nothingIsAskedBelowSixtyPercentOfTheBudget() {
        // 11 turns of 3,500 characters: about 55% of the budget.
        #expect(ChunkSummarizer.plan(for: conversation(turns: 11), budget: budget) == nil)
        #expect(ChunkSummarizer.plan(for: Conversation(), budget: budget) == nil)
    }

    @Test func theNoteIsDueFromTheShareWhereAColdCacheFolds() throws {
        // A user who answers after more than five minutes has the history folded from this share: the note comes first.
        #expect(ChunkSummarizer.startsAt == ContextBudget.coldFoldShare)
        // 12 turns: 60% of the budget.
        let plan = try #require(ChunkSummarizer.plan(for: conversation(turns: 12), budget: budget))
        #expect(plan.range.lowerBound == 0 && plan.range.upperBound > 2)
    }

    @Test func fromSixtyPercentTheNextFoldIsPlanned() throws {
        // 14 turns: 70% of the budget.
        let chat = conversation(turns: 14)
        let plan = try #require(ChunkSummarizer.plan(for: chat, budget: budget))
        #expect(plan.range.lowerBound == 0)
        // A fold made now brings the history from 70% down to the low-water mark (50%): 14,000 characters, plus the room
        // of the summary and up to a turn more (turns are folded whole).
        let taken = chat.messages[plan.range].reduce(0) { $0 + $1.contextCharacters }
        #expect(taken >= 14_000 && taken <= 14_000 + 3_600 + ContextSummary.reserve)
        // Whole turns: the stretch ends where a request starts, and the latest turn is not in it.
        #expect(chat.messages[plan.range.upperBound].role == .user)
        #expect(plan.range.upperBound < chat.messages.count - 2)
        #expect(plan.input.contains("User: Construa o app Atlas"))
    }

    @Test func theSamePlanComesOutOfTheSameConversation() {
        let chat = conversation(turns: 16)
        #expect(ChunkSummarizer.plan(for: chat, budget: budget) == ChunkSummarizer.plan(for: chat, budget: budget))
    }

    @Test func aStretchIsSummarizedOnce() throws {
        var chat = conversation(turns: 16)
        let plan = try #require(ChunkSummarizer.plan(for: chat, budget: budget))
        chat.keep(ChunkSummary(start: plan.range.lowerBound, end: plan.range.upperBound, text: "Nota."))
        #expect(chat.noteFrontier == plan.range.upperBound)
        #expect(ChunkSummarizer.plan(for: chat, budget: budget) == nil)
        // Once the fold took it, the next stretch is planned, from where the summary stands.
        chat.summary = "Pedido original: x"
        chat.summaryCoveredCount = plan.range.upperBound
        #expect(chat.noteFrontier == plan.range.upperBound)
        if let next = ChunkSummarizer.plan(for: chat, budget: budget) { #expect(next.range.lowerBound == plan.range.upperBound) }
    }

    @Test func aConversationThatKeepsClimbingGetsANoteOnTheNextStretchToo() throws {
        var chat = conversation(turns: 16)
        let first = try #require(ChunkSummarizer.plan(for: chat, budget: budget))
        chat.keep(ChunkSummary(start: first.range.lowerBound, end: first.range.upperBound, text: "Primeira."))
        // A little more history is not worth another call.
        chat.messages += conversation(turns: 2).messages
        #expect(ChunkSummarizer.plan(for: chat, budget: budget) == nil)
        // A fifth of the budget more is: the stretch starts where the first note ends, and is not summarized twice.
        chat.messages += conversation(turns: 4).messages
        let second = try #require(ChunkSummarizer.plan(for: chat, budget: budget))
        #expect(second.range.lowerBound == first.range.upperBound)
        #expect(chat.messages[second.range.upperBound].role == .user)
        let size = chat.messages[second.range].reduce(0) { $0 + $1.contextCharacters }
        #expect(Double(size) >= Double(budget.characters) * ChunkSummarizer.laterStretchShare)
        // The fold that takes both carries both notes, oldest first.
        chat.keep(ChunkSummary(start: second.range.lowerBound, end: second.range.upperBound, text: "Segunda."))
        var folding = chat
        let report = folding.prepareHistory(budget: budget).compaction
        #expect(report?.digests == ["Primeira.", "Segunda."])
    }

    @Test func aFoldMadeNowIsWhatTheFirstNoteIsPlannedFor() throws {
        // At 65% a cold cache folds down to 50%: that is the stretch, not the (larger) one a fold at 100% would take.
        let chat = conversation(turns: 13)
        let plan = try #require(ChunkSummarizer.plan(for: chat, budget: budget))
        var folding = chat
        folding.lastModelCall = Date.now.addingTimeInterval(-600)
        _ = folding.prepareHistory(budget: budget, now: .now)
        #expect(folding.coveredMessageCount >= plan.range.upperBound)
        #expect(folding.coveredMessageCount - plan.range.upperBound <= 4)
    }

    @Test func aSingleHugeTurnHasNothingToFold() {
        #expect(ChunkSummarizer.plan(for: conversation(turns: 1, characters: 120_000), budget: budget) == nil)
    }

    @Test func aStretchIsKeptOnlyForMessagesThatExist() {
        var chat = conversation(turns: 3)
        chat.keep(ChunkSummary(start: 0, end: 99, text: "Além do fim."))
        chat.keep(ChunkSummary(start: 4, end: 4, text: "Vazio."))
        #expect(chat.chunkSummaries == nil)
        chat.keep(ChunkSummary(start: 0, end: 4, text: "Dentro."))
        #expect(chat.chunkSummaries?.count == 1)
        // A fold that went past a note leaves it out when the next one is kept.
        chat.summary = "x"
        chat.summaryCoveredCount = 4
        chat.keep(ChunkSummary(start: 4, end: 6, text: "Depois."))
        #expect(chat.chunkSummaries?.map(\.text) == ["Depois."])
    }

    @Test func aBiggerBudgetAfterANoteDoesNotPlanBeforeTheNoteEnds() throws {
        // The note was planned for a fold at 20,000 tokens; the window has grown since (another model, a higher memory
        // level, less overhead), so a fold made now would stop before where the note ends: no stretch, and no crash.
        var chat = conversation(turns: 16)
        let first = try #require(ChunkSummarizer.plan(for: chat, budget: budget))
        chat.keep(ChunkSummary(start: first.range.lowerBound, end: first.range.upperBound, text: "Nota."))
        #expect(ChunkSummarizer.plan(for: chat, budget: ContextBudget(tokens: 22_000)) == nil)
        #expect(ChunkSummarizer.plan(for: chat, budget: ContextBudget(tokens: 40_000)) == nil)
    }

    @Test func aNoteOnMessagesThatAreGoneIsLeftOut() {
        var chat = conversation(turns: 16)
        chat.chunkSummaries = [ChunkSummary(start: 0, end: 60, text: "De mensagens que saíram.")]
        #expect(chat.noteFrontier == 0)
        #expect(chat.pendingChunks(after: 0).isEmpty)
        // The frontier never passes the messages there are, and a plan from it is made as for a conversation without notes.
        chat.chunkSummaries = [ChunkSummary(start: 0, end: 30, text: "Quase tudo.")]
        #expect(chat.noteFrontier <= chat.messages.count)
        chat.messages.removeLast(6)
        #expect(chat.noteFrontier == chat.messages.count || chat.pendingChunks(after: 0).isEmpty)
        #expect(ChunkSummarizer.plan(for: chat, budget: budget)?.range.upperBound ?? 0 <= chat.messages.count)
    }

    @Test func theNoteIsDueWhenTheFoldWouldBeNotOnlyWhenTheRawHistoryReachesTheShare() throws {
        // 11 turns of 3,700 characters: 40,700, under 60% of the budget (42,000) but over 60% of the room the fold has
        // (the budget less the message and its preface), which is where a cold cache folds.
        let chat = conversation(turns: 11, characters: 3_700)
        let room = budget.leavingRoom(forCharacters: AppModel.prefaceAllowance)
        #expect(Double(room.characters) * ChunkSummarizer.startsAt < 40_700)
        #expect(ChunkSummarizer.plan(for: chat, budget: budget) != nil)
        // Under that room nothing is asked.
        #expect(ChunkSummarizer.plan(for: conversation(turns: 11, characters: 3_400), budget: budget) == nil)
    }

    @Test func notesAreHandedToTheFitInTheIndexesOfTheSlice() {
        var chat = conversation(turns: 6)
        chat.chunkSummaries = [ChunkSummary(start: 0, end: 4, text: "Velha."), ChunkSummary(start: 4, end: 8, text: "Nova.")]
        let pending = chat.pendingChunks(after: 4)
        #expect(pending == [ChunkSummary(start: 0, end: 4, text: "Nova.")])
    }
}

struct ChunkTranscriptTests {
    @Test func theStretchIsWrittenAsPlainTextWithoutTheAppsAdditions() {
        let preface = "<orb_context>\nNow: 2026-10-07 10:00\nFolder: /Users/x/proj\n</orb_context>\n\n"
        let messages: [ChatMessage] = [
            .user(preface + "Leia o arquivo Pagamentos.swift"),
            ChatMessage(role: .assistant, content: "Vou ler.", toolCalls: [ToolCallRequest(id: "c1", name: "read_file", arguments: #"{"path":"/p/Pagamentos.swift"}"#)]),
            .tool("c1", String(repeating: "x", count: 5_000)),
            ChatMessage(role: .assistant, content: "Pronto: lido."),
            .user(ContextSummary.marker + "\nresumo antigo"),
        ]
        let text = ChunkSummarizer.transcript(of: messages[...])
        #expect(text.contains("User: Leia o arquivo Pagamentos.swift"))
        #expect(!text.contains("orb_context") && !text.contains("Folder:"))
        #expect(text.contains("Assistant used read_file"))
        #expect(text.contains("Result of read_file: "))
        // A tool output keeps a start and an end, like in an old request.
        #expect(text.count < 3_000)
        #expect(text.contains("Assistant: Pronto: lido."))
        #expect(!text.contains("resumo antigo"))
    }

    @Test func aFailedResultIsSaidSo() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: "c1", name: "run_command", arguments: #"{"command":"swift test"}"#)]),
            .tool("c1", "Código de saída: 1", isError: true),
        ]
        #expect(ChunkSummarizer.transcript(of: messages[...]).contains("Result of run_command (failed): Código de saída: 1"))
    }

    @Test func theInputHasACeiling() {
        let long = (0..<60).map { ChatMessage.user("pedido \($0) " + String(repeating: "z", count: 2_900)) }
        let text = ChunkSummarizer.transcript(of: long[...])
        #expect(text.count <= Int(Double(ChunkSummarizer.inputTokens) * ContextBudget.charactersPerToken) + 120)
        #expect(text.contains("characters omitted"))
        #expect(text.hasPrefix("User: pedido 0"))
    }
}

struct ChunkModelChoiceTests {
    private func account(_ kind: ProviderKind, _ ids: [String], contextLength: Int? = nil, prices: [String: Double] = [:]) -> ProviderAccount {
        var account = ProviderAccount(kind: kind)
        account.models = ids.map { ProviderModel(id: $0, name: $0, format: .chat, contextLength: contextLength, price: prices[$0].map { ModelPrice(input: $0, output: $0) }) }
        return account
    }

    @Test func aHaikuWritesForAnAnthropicOrb() {
        let list = account(.anthropic, ["claude-opus-4-1", "claude-sonnet-4", "claude-haiku-4-5", "claude-3-5-haiku"])
        #expect(ChunkSummarizer.model(in: list, orb: "claude-sonnet-4")?.id == "claude-haiku-4-5")
    }

    @Test func aMiniWritesForAnOpenAIOrbAndOnlyAModelForText() {
        let list = account(.openai, ["gpt-5", "gpt-4o-mini", "gpt-5-mini", "gpt-4o-mini-transcribe", "gpt-5-mini-tts", "o3"])
        #expect(ChunkSummarizer.model(in: list, orb: "gpt-5")?.id == "gpt-5-mini")
    }

    @Test func theReasoningSeriesOfOpenAIIsNeverTheCheapChoice() {
        // The real list keeps every id that starts with "o": "o4-mini" sorts after "gpt-5-mini" but reasons, and costs far more.
        let list = account(.openai, ["gpt-5", "gpt-5-mini", "gpt-5-mini-2025-08-07", "o4-mini", "o4-mini-2025-04-16", "o3-mini"])
        #expect(ChunkSummarizer.model(in: list, orb: "gpt-5")?.id == "gpt-5-mini-2025-08-07")
        #expect(ChunkSummarizer.model(in: account(.openai, ["o3", "o4-mini"]), orb: "o3") == nil)
        // An Orb on o3 still gets the GPT mini, not another o.
        #expect(ChunkSummarizer.model(in: account(.openai, ["o3", "o4-mini", "gpt-5-mini"]), orb: "o3")?.id == "gpt-5-mini")
    }

    @Test func aGatewayNeverSwitchesToAnotherMaker() {
        // An open model on a gateway stays on the open model, whatever cheap Claude the gateway also lists.
        let router = account(.openrouter, ["deepseek/deepseek-v4-pro", "anthropic/claude-haiku-4.5", "openai/gpt-5-mini", "google/gemini-2.5-flash"])
        #expect(ChunkSummarizer.model(in: router, orb: "deepseek/deepseek-v4-pro") == nil)
        // Its own maker's cheap one is fine, with or without the prefix.
        let own = account(.openrouter, ["anthropic/claude-sonnet-4", "anthropic/claude-haiku-4.5", "openai/gpt-5-mini"])
        #expect(ChunkSummarizer.model(in: own, orb: "anthropic/claude-sonnet-4")?.id == "anthropic/claude-haiku-4.5")
        let zen = account(.opencodeZen, ["glm-5.3", "glm-5.3-flash", "claude-haiku-5-5", "gpt-5-mini"])
        #expect(ChunkSummarizer.model(in: zen, orb: "glm-5.3")?.id == "glm-5.3-flash")
        #expect(ChunkSummarizer.model(in: zen, orb: "kimi-k3") == nil)
        #expect(ChunkSummarizer.model(in: zen, orb: "mistery/model") == nil)
    }

    @Test func theMakerIsReadFromTheId() {
        #expect(ChunkSummarizer.maker(of: "anthropic/claude-sonnet-4") == "anthropic")
        #expect(ChunkSummarizer.maker(of: "claude-haiku-4-5") == "anthropic")
        #expect(ChunkSummarizer.maker(of: "gpt-5-mini") == "openai" && ChunkSummarizer.maker(of: "o4-mini") == "openai")
        #expect(ChunkSummarizer.maker(of: "openai/gpt-5") == "openai" && ChunkSummarizer.maker(of: "chatgpt-4o-latest") == "openai")
        #expect(ChunkSummarizer.maker(of: "gemini-2.5-pro") == "google" && ChunkSummarizer.maker(of: "grok-4") == "x-ai")
        #expect(ChunkSummarizer.maker(of: "deepseek-v4-flash") == "deepseek")
        #expect(ChunkSummarizer.maker(of: "4o-something") == nil && ChunkSummarizer.maker(of: "") == nil)
    }

    @Test func aModelThePriceListSaysIsDearerIsNeverChosen() {
        let prices = ["big": 3.0, "big-mini": 4.0, "big-flash": 0.5, "big-lite": 0.2]
        let list = account(.custom, ["big", "big-mini", "big-flash", "big-lite"], prices: prices)
        // "mini" comes first by name but costs more than the Orb's model: out. Of the rest the better word wins.
        #expect(ChunkSummarizer.model(in: list, orb: "big")?.id == "big-flash")
        // The same price is no saving.
        #expect(ChunkSummarizer.model(in: account(.custom, ["big", "big-mini"], prices: ["big": 1, "big-mini": 1]), orb: "big") == nil)
        // Equal words: the lower price.
        let two = account(.custom, ["big", "big-mini-a", "big-mini-b"], prices: ["big": 3, "big-mini-a": 1, "big-mini-b": 0.5])
        #expect(ChunkSummarizer.model(in: two, orb: "big")?.id == "big-mini-b")
        // No price at all (most catalogs): the names decide.
        #expect(ChunkSummarizer.model(in: account(.custom, ["big", "big-mini"]), orb: "big")?.id == "big-mini")
    }

    @Test func aFreeTierOrAPriceOfZeroOrLessIsNeverChosen() {
        // OpenRouter lists ":free" copies of models and routers priced -1: rate-limited or not a model at all.
        let prices = ["google/gemini-2.5-pro": 1.25, "google/gemini-2.0-flash-exp:free": 0, "google/gemini-2.5-flash": 0.3,
                      "google/gemini-flash-router": -1]
        let router = account(.openrouter, Array(prices.keys), prices: prices)
        #expect(ChunkSummarizer.model(in: router, orb: "google/gemini-2.5-pro")?.id == "google/gemini-2.5-flash")
        // A ":free" id without a price is left out as well.
        let named = account(.openrouter, ["google/gemini-2.5-pro", "google/gemini-2.0-flash-exp:free"])
        #expect(ChunkSummarizer.model(in: named, orb: "google/gemini-2.5-pro") == nil)
        // Only the free ones: the Orb's own model writes.
        let only = account(.openrouter, ["google/gemini-2.5-pro", "google/gemini-2.0-flash-exp:free", "google/gemini-flash-router"],
                           prices: ["google/gemini-2.5-pro": 1.25, "google/gemini-2.0-flash-exp:free": 0, "google/gemini-flash-router": -1])
        #expect(ChunkSummarizer.model(in: only, orb: "google/gemini-2.5-pro") == nil)
        // An Orb that is itself free has no price to compare with: the names decide.
        let free = account(.openrouter, ["google/gemini-2.5-pro:free", "google/gemini-2.5-flash"], prices: ["google/gemini-2.5-pro:free": 0])
        #expect(ChunkSummarizer.model(in: free, orb: "google/gemini-2.5-pro:free")?.id == "google/gemini-2.5-flash")
    }

    @Test func theNameGeminiIsNotAMini() {
        let list = account(.openrouter, ["google/gemini-2.5-pro", "anthropic/claude-sonnet-4"])
        #expect(ChunkSummarizer.model(in: list, orb: "anthropic/claude-sonnet-4") == nil)
    }

    @Test func theOrbsOwnModelWhenItIsCheapAlreadyOrNothingIsCheaper() {
        let list = account(.anthropic, ["claude-sonnet-4", "claude-haiku-4-5"])
        #expect(ChunkSummarizer.model(in: list, orb: "claude-haiku-4-5") == nil)
        #expect(ChunkSummarizer.model(in: account(.openai, ["gpt-5-nano", "gpt-5-mini"]), orb: "gpt-5-nano") == nil)
        #expect(ChunkSummarizer.model(in: account(.anthropic, ["claude-sonnet-4", "claude-opus-4-1"]), orb: "claude-sonnet-4") == nil)
        #expect(ChunkSummarizer.model(in: account(.anthropic, []), orb: "claude-sonnet-4") == nil)
    }

    @Test func aModelWithTooSmallAWindowIsLeftOut() {
        #expect(ChunkSummarizer.model(in: account(.openai, ["gpt-5", "gpt-5-mini"], contextLength: 16_000), orb: "gpt-5") == nil)
        #expect(ChunkSummarizer.model(in: account(.openai, ["gpt-5", "gpt-5-mini"], contextLength: 128_000), orb: "gpt-5")?.id == "gpt-5-mini")
    }

    @Test func aLocalServerKeepsItsModel() {
        #expect(ChunkSummarizer.model(in: account(.ollama, ["llama3", "llama3-mini"]), orb: "llama3") == nil)
        #expect(ChunkSummarizer.model(in: account(.lmstudio, ["llama3", "llama3-mini"]), orb: "llama3") == nil)
    }

    @Test func aFlashOfTheSameFamilyServesAGatewayThatHasNoHaikuOrMini() {
        let list = account(.custom, ["fast-pro", "fast-flash-2", "fast-flash-10"])
        #expect(ChunkSummarizer.model(in: list, orb: "fast-pro")?.id == "fast-flash-10")
    }

    @Test func theCatalogsPricesAreReadWhenTheyHaveThem() throws {
        let router = try #require(JSONValue.parse(#"{"data":[{"id":"anthropic/claude-haiku-4.5","pricing":{"prompt":"0.000001","completion":"0.000005"}},{"id":"x/y"}]}"#))
        let models = ModelCatalog.openRouterModels(router["data"]?.array ?? [])
        #expect(models.first { $0.id == "anthropic/claude-haiku-4.5" }?.inputPrice == 1.0)
        #expect(models.first { $0.id == "x/y" }?.inputPrice == nil)
        let metadata = try #require(JSONValue.parse(#"{"claude-haiku-4-5":{"name":"Haiku","cost":{"input":1,"output":5},"limit":{"context":200000}}}"#))
        let zen = ModelCatalog.openCodeModels(live: ["claude-haiku-4-5"], metadata: metadata)
        #expect(zen.first?.inputPrice == 1)
    }
}

struct ChunkCallTests {
    private let plan = ChunkSummarizer.Plan(range: 0..<10, input: "User: oi\nAssistant: olá")

    @Test func oneRequestWithTheInstructionsAndNoTools() async throws {
        let writer = CallScriptModel(always: [.text("O usuário pediu "), .text("um app e o Orb o criou. Decidiu-se usar SQLite."),
                                     .finished(.done, TokenUsage(input: 900, output: 40))])
        let note = await ChunkSummarizer.write(plan, client: writer, model: "modelo")
        #expect(note.text == "O usuário pediu um app e o Orb o criou. Decidiu-se usar SQLite.")
        #expect(note.usage?.output == 40)
        let calls = await writer.script.calls
        #expect(calls.count == 1)
        let request = try #require(calls.first)
        #expect(request.sent.first?.content == ChunkSummarizer.instructions)
        #expect(request.sent.last?.content.hasSuffix(plan.input) == true)
        #expect(request.tools.isEmpty && request.toolChoice == .none)
        // The instructions ask for the conversation's language and for text, not for orders to be followed.
        #expect(ChunkSummarizer.instructions.contains("language the conversation is in"))
        #expect(ChunkSummarizer.instructions.contains("not instructions"))
    }

    @Test func aNoteIsFlatAndHasACeiling() async throws {
        let long = String(repeating: "palavra ", count: 700)
        let writer = CallScriptModel(always: [.text("# Título\n\n- um\n- dois\n" + long), .finished(.done, nil)])
        let text = try #require(await ChunkSummarizer.write(plan, client: writer, model: "m").text)
        #expect(!text.contains("\n"))
        #expect(text.count <= ChunkSummary.maxLength)
    }

    @Test func aReplyTooShortOrAFailureMakesNoNoteButKeepsWhatItCost() async throws {
        let short = await ChunkSummarizer.write(plan, client: CallScriptModel(always: [.text("ok"), .finished(.done, TokenUsage(input: 900, output: 1))]), model: "m")
        #expect(short.text == nil && short.usage == TokenUsage(input: 900, output: 1))
        let failed = await ChunkSummarizer.write(plan, client: CallScriptModel(failure: LLMError.network(code: -1009, message: "offline")), model: "m")
        #expect(failed.text == nil && failed.usage == nil)
        // The input the provider reported first is kept when the reply is cut before its end.
        let long = String(repeating: "palavra ", count: 700)
        let cut = await ChunkSummarizer.write(plan, client: CallScriptModel(always: [.usage(TokenUsage(input: 800, output: 0)), .text(long)]), model: "m")
        #expect(cut.text != nil && cut.usage == TokenUsage(input: 800, output: 0))
        // A final report without numbers does not erase the ones already given.
        let unsaid = await ChunkSummarizer.write(plan, client: CallScriptModel(always: [.usage(TokenUsage(input: 700, output: 0)), .text("ok"), .finished(.done, nil)]), model: "m")
        #expect(unsaid.usage == TokenUsage(input: 700, output: 0))
    }
}

struct ChunkDecodingTests {
    private func decoded(_ json: String) throws -> Conversation {
        try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
    }

    @Test func aConversationFromBeforeTheNotesLoads() throws {
        let chat = try decoded(#"{"items":[],"messages":[{"role":"user","content":"oi"}]}"#)
        #expect(chat.chunkSummaries == nil && chat.messages.count == 1)
    }

    @Test func notesRoundTripAndBrokenOnesDoNotCostTheConversation() throws {
        var chat = conversation(turns: 2)
        chat.chunkSummaries = [ChunkSummary(start: 0, end: 2, text: "Nota.")]
        let data = try JSONEncoder().encode(chat)
        #expect(try JSONDecoder().decode(Conversation.self, from: data).chunkSummaries == chat.chunkSummaries)
        let broken = try decoded(#"{"messages":[{"role":"user","content":"oi"}],"chunkSummaries":"lixo"}"#)
        #expect(broken.chunkSummaries == nil && broken.messages.count == 1)
        // A note missing its fields is read as an empty one and never used.
        let partial = try decoded(#"{"messages":[],"chunkSummaries":[{"end":5}]}"#)
        #expect(partial.chunkSummaries == [ChunkSummary(start: 0, end: 5, text: "")])
        #expect(partial.pendingChunks(after: 0).isEmpty)
    }
}

struct ChunkIndexesTests {
    @Test func theEnginesInputStartsWithTheSummaryPairWhenThereIsOne() throws {
        var chat = conversation(turns: 6)
        chat.chunkSummaries = [ChunkSummary(start: 0, end: 4, text: "Velha."), ChunkSummary(start: 4, end: 8, text: "Nova.")]
        // Nothing folded: the history is the messages themselves.
        #expect(chat.chunks(inHistory: chat.messages).map(\.text) == ["Velha.", "Nova."])
        #expect(chat.chunks(inHistory: chat.messages).map(\.end) == [4, 8])
        // Folded up to 4: the history starts with the pair, so the note on 4..<8 is at 2..<6 of the engine's input.
        chat.summary = "Pedido original: x"
        chat.summaryCoveredCount = 4
        let history = ContextSummary.pair("Pedido original: x", foldedTurns: true) + Array(chat.messages[4...])
        let shifted = chat.chunks(inHistory: history)
        #expect(shifted == [ChunkSummary(start: 2, end: 6, text: "Nova.")])
        #expect(history[shifted[0].end].role == .user && history[shifted[0].start].role == .user)
    }
}

struct ShortReplyClientTests {
    private let url = URL(string: "https://api.anthropic.com/v1")!
    private let messages: [ChatMessage] = [.system("instruções"), .user("trecho")]

    private func hasTailMarker(_ body: JSONValue) -> Bool {
        let last = body["messages"]?.array?.last?["content"]?.array?.last
        return last?["cache_control"] != nil
    }

    @Test func anAnthropicNoteIsCappedAndWritesNoCacheForItsTail() throws {
        let client = AnthropicClient(baseURL: url, apiKey: "k")
        #expect(client.maxTokens == 16_000 && client.marksTail)
        let short = try #require(client.forShortReply as? AnthropicClient)
        #expect(short.maxTokens == 1_200 && !short.marksTail)
        let body = AnthropicClient.requestBody(model: "m", messages: messages, tools: [], maxTokens: short.maxTokens, marksTail: short.marksTail)
        #expect(body["max_tokens"]?.number == 1_200)
        #expect(!hasTailMarker(body))
        // The turn's own requests are what they were.
        #expect(hasTailMarker(AnthropicClient.requestBody(model: "m", messages: messages, tools: [], maxTokens: 16_000)))
    }

    @Test func aResponsesNoteIsCappedOnlyWhereTheApiTakesTheField() throws {
        let openAI = ResponsesClient(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "k")
        let short = try #require(openAI.forShortReply as? ResponsesClient)
        #expect(short.maxOutputTokens == 4_000)
        #expect(ResponsesClient.requestBody(model: "m", messages: messages, tools: [], maxOutputTokens: 4_000)["max_output_tokens"]?.number == 4_000)
        #expect(ResponsesClient.requestBody(model: "m", messages: messages, tools: [])["max_output_tokens"] == nil)
        // The ChatGPT sign-in and other gateways get the request as always.
        for host in ["https://chatgpt.com/backend-api/codex", "https://gateway.example.com/v1"] {
            let other = ResponsesClient(baseURL: URL(string: host)!, apiKey: "k")
            #expect((other.forShortReply as? ResponsesClient)?.maxOutputTokens == nil)
        }
    }

    @Test func otherClientsAreLeftAsTheyAre() {
        let chat = OpenAIClient(baseURL: URL(string: "https://openrouter.ai/api/v1")!, apiKey: "k")
        #expect(chat.forShortReply is OpenAIClient)
    }
}
