import Foundation
import Testing
@testable import Orb

// Compaction cases that cross the pieces: a fold inside a turn whose history already had steps set aside, a history
// that starts with a steps note only, the steady state of a long conversation, the "/compactar" command, and the
// numbers of Claude Code's manual compaction.

private let firstRequest = "Construa o app Atlas com SQLite e rode os testes a cada mudança"

/// A request, `steps` tool steps each answered by `output` characters, and a reply.
private func work(_ request: String, steps: Int, output: Int = 100, reply: String = "feito", tag: String) -> [ChatMessage] {
    var messages: [ChatMessage] = [.user(request)]
    for step in 0..<steps {
        let id = "\(tag)-\(step)"
        messages.append(ChatMessage(role: .assistant, content: "", toolCalls: [call(id, "read_file", #"{"path":"/p/\#(tag)\#(step).swift"}"#)]))
        messages.append(.tool(id, String(repeating: "x", count: output)))
    }
    messages.append(ChatMessage(role: .assistant, content: reply))
    return messages
}

/// Whole turns (user messages) among the first `count` messages of `messages`.
private func turns(in messages: [ChatMessage], first count: Int) -> Int {
    messages.prefix(count).filter { $0.role == .user && !$0.content.hasPrefix(ContextSummary.marker) }.count
}

// MARK: - Window

/// The low-water mark is `ContextWindow.fit`'s (see `ContextBudget.lowWater`); here, that the summary rides on it.
struct FoldLowWaterTests {
    private func turns(_ count: Int, output: Int) -> [ChatMessage] {
        (0..<count).flatMap { work($0 == 0 ? firstRequest : "pedido \($0) do projeto", steps: 1, output: output, reply: "resposta \($0)", tag: "t\($0)") }
    }

    @Test func aFoldGoesBelowTheLimitSoTheNextMessagesHaveRoom() throws {
        let budget = ContextBudget(tokens: 20_000)   // 70,000 characters
        let input = turns(28, output: 3_000)          // about 90,000
        let window = ContextWindow.fit(input, budget: budget)
        let folded = Self.turnsFolded(window, input)
        #expect(folded > 0)
        #expect(Double(window.charactersAfter) <= Double(budget.characters) * budget.lowWater)
        #expect(window.summary?.contains("Pedido original: " + firstRequest) == true)
        // Folding only what must go leaves it at the limit.
        var tight = budget
        tight.lowWaterShare = 1
        let close = ContextWindow.fit(input, budget: tight)
        #expect(close.charactersAfter > window.charactersAfter && close.charactersAfter <= budget.characters)
        #expect(Self.turnsFolded(close, input) < folded)
    }

    private static func turnsFolded(_ window: ContextWindow, _ input: [ChatMessage]) -> Int {
        input.prefix(window.droppedCount).filter { $0.role == .user }.count
    }

    @Test func nothingIsFoldedWhileTheHistoryFits() {
        let window = ContextWindow.fit(turns(4, output: 500), budget: ContextBudget(tokens: 10_000))
        #expect(window.droppedCount == 0 && window.ledger == nil && window.summary == nil)
    }

    @Test func aLongConversationIsCompactedOnlyEveryFewMessages() {
        var conversation = Conversation()
        let budget = ContextBudget(modelWindow: 32_000)   // 16,800 tokens of history
        var folds = 0, summaries = Set<String>()
        for index in 0..<200 {
            conversation.messages += work(index == 0 ? firstRequest : "pedido número \(index) do projeto", steps: 2, output: 1_500,
                                          reply: "resposta \(index)", tag: "s\(index)")
            let prepared = conversation.prepareHistory(budget: budget)
            if prepared.compaction != nil { folds += 1 }
            if let summary = conversation.summary { summaries.insert(summary) }
        }
        #expect(folds >= 10)
        // Folding only what must go would fold at nearly every message.
        #expect(folds <= 200 / 3)
        #expect(summaries.count <= folds)
        #expect(conversation.compactions == folds)
        #expect(conversation.summary?.contains("Pedido original: " + firstRequest) == true)
    }
}

struct ReserveTests {
    @Test func theRoomForTheNewMessageIsLeftOutOfTheHistory() {
        var conversation = Conversation()
        // Long answers: old outputs alone would be condensed instead of folded.
        conversation.messages = (0..<30).flatMap {
            work("pedido \($0) do projeto", steps: 2, output: 2_000, reply: String(repeating: "resposta ", count: 300), tag: "r\($0)")
        }
        let budget = ContextBudget(tokens: 30_000)
        var plain = conversation, reserving = conversation
        let without = plain.prepareHistory(budget: budget)
        let with = reserving.prepareHistory(budget: budget, reserving: 40_000)
        let size = { (history: [ChatMessage]) in history.reduce(0) { $0 + $1.contextCharacters } }
        #expect(size(with.history) + 40_000 <= budget.characters)
        #expect(size(with.history) < size(without.history))
        #expect(reserving.coveredMessageCount > plain.coveredMessageCount)
    }

    /// A summary that stops in the middle of a turn (saved so by an earlier version): the messages before the next
    /// request are left out of the window, not summarized, and the notice does not count them.
    @Test func theNoticeCountsOnlyTheMessagesThatWentIntoTheSummary() throws {
        var conversation = Conversation()
        conversation.messages = (0..<30).flatMap {
            work("pedido \($0) do projeto", steps: 2, output: 2_000, reply: String(repeating: "resposta ", count: 300), tag: "m\($0)")
        }
        conversation.summary = "Pedido original: " + firstRequest
        conversation.summaryCoveredCount = 2   // the first turn's tool output and what follows it are orphans
        let orphans = try #require(conversation.messages.dropFirst(2).firstIndex { $0.role == .user }) - 2
        #expect(orphans > 0)
        let ledgerBefore = try #require(conversation.currentLedger)
        let report = try #require(conversation.prepareHistory(budget: ContextBudget(tokens: 30_000)).compaction)
        let covered = conversation.coveredMessageCount
        #expect(report.foldedMessages == covered - 2 - orphans)
        #expect(conversation.ledger?.foldedMessages == ledgerBefore.foldedMessages + report.foldedMessages)
    }

    @Test func aReserveNeverTakesMoreThanHalfTheBudget() {
        let budget = ContextBudget(tokens: 10_000)
        #expect(budget.leavingRoom(forCharacters: 0) == budget)
        #expect(budget.leavingRoom(forCharacters: 3_500).tokens == 9_000)
        #expect(budget.leavingRoom(forCharacters: 1_000_000).tokens == 5_000)
    }
}

// MARK: - A fold of turns inside a turn

struct InTurnFoldTests {
    /// The new message with what is put before it (snapshot, notes) is what pushes the history over the budget.
    static let bigMessage = "e agora, o que falta? " + String(repeating: "contexto ", count: 2_400)

    /// Turn 1 is short; turn 2 has 30 steps of 3,000 characters and alone does not fit.
    static func conversationWithAHeavySecondTurn() -> Conversation {
        var conversation = Conversation()
        conversation.messages = work(firstRequest, steps: 1, reply: "pronto", tag: "a")
            + work("agora faça a migração completa do banco de dados", steps: 30, output: 3_000, reply: "migrado", tag: "b")
        return conversation
    }

    /// What the engine reports when it fits the prepared history and the new message.
    static func engineReport(_ history: [ChatMessage], ledger: ConversationLedger?, budget: ContextBudget) -> [CompactionReport] {
        let input = history + [.user(bigMessage)]
        var cut = ContextCut(ledger: ledger)
        let window = ContextWindow.fit(input, budget: budget, cut: &cut)
        var announced = AgentEngine.Announced()
        let reports = announced.reports(after: window, cut: cut, input: input[...])
        // Fitted again at the next step: nothing new.
        let again = ContextWindow.fit(input, budget: budget, cut: &cut)
        #expect(announced.reports(after: again, cut: cut, input: input[...]).isEmpty)
        return reports
    }

    @Test func theEnginesFoldIsCountedInTurnsNotInMessages() throws {
        var conversation = Self.conversationWithAHeavySecondTurn()
        let budget = ContextBudget(tokens: 8_000)
        let prepared = conversation.prepareHistory(budget: budget)
        #expect(prepared.compaction != nil)
        // The history has steps of turn 2 set aside: it is shorter than the messages it stands for.
        #expect(prepared.history.count < conversation.messages.count - conversation.coveredMessageCount + 2)

        // The next message arrives and the engine fits history + that message.
        let reports = Self.engineReport(prepared.history, ledger: conversation.currentLedger, budget: budget)
        let fold = try #require(reports.first { $0.kind == .turns }?.fold)
        #expect(fold.turns == 1)
        #expect(fold.ledger?.original == firstRequest)
        #expect(fold.summary.contains("agora faça a migração completa"))
    }

    @Test @MainActor func theFoldKeepsTheBoundaryAtTheStartOfTheCurrentTurnAndNothingIsFoldedTwice() throws {
        var conversation = Self.conversationWithAHeavySecondTurn()
        let budget = ContextBudget(tokens: 8_000)
        let prepared = conversation.prepareHistory(budget: budget)
        let coveredByThen = conversation.coveredMessageCount
        let ledger = conversation.currentLedger
        conversation.messages.append(.user(Self.bigMessage))
        let report = try #require(Self.engineReport(prepared.history, ledger: ledger, budget: budget).first { $0.kind == .turns })
        #expect(report.foldedMessages != conversation.messages.count - 1 - coveredByThen)   // the two views really differ

        let harness = AppHarness(conversation)
        harness.model.apply(.compacted(report), to: harness.botID)
        let kept = try #require(harness.model.conversations[harness.botID])
        // Everything before the new message is covered, exactly: the cut is the start of the turn in progress.
        #expect(kept.summaryCoveredCount == conversation.messages.count - 1)
        #expect(kept.ledger?.foldedMessages ?? .max <= conversation.messages.count - 1)
        // The notice counts your requests in the conversation, not the engine's messages.
        let requests = kept.requestCount(in: 0..<kept.coveredMessageCount)
        #expect(harness.notices(startingWith: "Compactei a conversa: os \(requests) primeiros pedidos").count == 1)

        // The next message starts from that summary: nothing is folded a second time.
        var next = kept
        next.messages.append(.user("mais uma pergunta"))
        let again = next.prepareHistory(budget: budget)
        #expect(again.compaction == nil)
        #expect(next.compactions == 2)   // the send and the engine's fold, once each
        #expect(next.ledger?.foldedMessages == kept.ledger?.foldedMessages)
    }

    @Test @MainActor func aFoldIsCarriedOverInWholeTurns() throws {
        var conversation = Conversation()
        conversation.messages = (0..<10).flatMap { work("pedido número \($0) do projeto", steps: 1, tag: "f\($0)") }
        let harness = AppHarness(conversation)
        harness.model.apply(.compacted(CompactionReport(kind: .turns, foldedMessages: 7, tokensBefore: 1, tokensAfter: 1,
                                                        fold: .init(summary: "resumo", ledger: nil, turns: 2))), to: harness.botID)
        #expect(harness.model.conversations[harness.botID]?.summaryCoveredCount == 8)
        harness.model.apply(.compacted(CompactionReport(kind: .turns, foldedMessages: 1, tokensBefore: 1, tokensAfter: 1,
                                                        fold: .init(summary: "resumo", ledger: nil, turns: 3))), to: harness.botID)
        #expect(harness.model.conversations[harness.botID]?.summaryCoveredCount == 20)
        harness.model.apply(.compacted(CompactionReport(kind: .turns, foldedMessages: 1, tokensBefore: 1, tokensAfter: 1,
                                                        fold: .init(summary: "resumo", ledger: nil, turns: 99))), to: harness.botID)
        // Never past the turn in progress (the last one starts at message 36).
        #expect(harness.model.conversations[harness.botID]?.summaryCoveredCount == 36)
        // A fold that adds nothing (already at the turn in progress) is not announced.
        let before = harness.notices().count
        harness.model.apply(.compacted(CompactionReport(kind: .turns, foldedMessages: 4, tokensBefore: 1, tokensAfter: 1,
                                                        fold: .init(summary: "resumo", ledger: nil, turns: 1))), to: harness.botID)
        #expect(harness.notices().count == before)
        #expect(harness.model.conversations[harness.botID]?.compactions == 3)
    }
}

// MARK: - A steps note is not a summary

struct StepsNoteTests {
    /// One long first request of 60 heavy steps, alone over the budget even with its outputs at their shortest: its first
    /// steps are set aside, nothing is folded.
    private func heavyFirstTurn() -> Conversation {
        var conversation = Conversation()
        conversation.messages = work(firstRequest, steps: 60, output: 3_000, reply: "quase lá", tag: "h")
        return conversation
    }

    @Test func foldingTurnsAfterAStepsNoteStillPinsTheOriginalRequest() throws {
        var conversation = heavyFirstTurn()
        let budget = ContextBudget(tokens: 8_000)
        let prepared = conversation.prepareHistory(budget: budget)
        #expect(prepared.compaction == nil && conversation.summary == nil)
        let inherited = try #require(ContextSummary.inherited(in: prepared.history))
        #expect(inherited.summary == nil && inherited.stepsNote?.hasPrefix(ContextSummary.stepsNoteTitle) == true)

        // The user writes again and the engine has to fold the first turn.
        let next = ChatMessage.user("agora ajuste o módulo de login " + String(repeating: "contexto ", count: 1_600))
        let engine = ContextWindow.fit(prepared.history + [next], budget: budget, ledger: conversation.currentLedger)
        #expect(turns(in: prepared.history + [next], first: engine.droppedCount) == 1)
        let ledger = try #require(engine.ledger)
        #expect(ledger.legacy == nil)
        #expect(ledger.original == firstRequest)
        let summary = try #require(engine.summary)
        #expect(summary.contains("Pedido original: " + firstRequest))
        #expect(!summary.contains("formato antigo") && !summary.contains("Neste pedido"))
        // The next request goes on pinning nothing else: the original stays the first one.
        let extended = ledger.absorbing([.user("outra coisa bem diferente para fazer agora")])
        #expect(extended.original == firstRequest)
    }

    @Test func theNoteStaysForAsLongAsItsRequestIsInTheWindow() throws {
        var conversation = heavyFirstTurn()
        let budget = ContextBudget(tokens: 8_000)
        let history = conversation.prepareHistory(budget: budget).history
        // The engine fits the history again at every step, with the pair at its start.
        let again = ContextWindow.fit(history, budget: budget)
        let kept = try #require(ContextSummary.inherited(in: again.messages))
        #expect(kept.stepsNote?.hasPrefix(ContextSummary.stepsNoteTitle) == true)
        #expect(kept.stepsNote?.components(separatedBy: ContextSummary.stepsNoteTitle).count == 2)
        #expect(again.summary == nil)
    }

    @Test func aPairHoldsTheSummaryAndTheNoteApart() throws {
        let pair = ContextSummary.pair("Pedido original: algo\nPedidos e decisões:\n- x\n" + ContextSummary.stepsNoteTitle + "\nFerramentas usadas: read_file (3).")
        let inherited = try #require(ContextSummary.inherited(in: pair))
        #expect(inherited.summary == "Pedido original: algo\nPedidos e decisões:\n- x")
        #expect(inherited.stepsNote == ContextSummary.stepsNoteTitle + "\nFerramentas usadas: read_file (3).")
        #expect(ContextSummary.leading(in: pair) == inherited.summary)
        #expect(ContextSummary.inherited(in: [.user("oi")]) == nil)
    }
}

// MARK: - The app

@MainActor private struct AppHarness {
    let model: AppModel
    let botID: UUID
    let root: URL

    init(_ conversation: Conversation, claudeCode: Bool = false) {
        var conversation = conversation
        root = FileManager.default.temporaryDirectory.appending(path: "OrbCompactionReview-\(UUID().uuidString)")
        conversation.items = conversation.messages.compactMap { message in
            switch message.role {
            case .user where !message.content.hasPrefix(ContextSummary.marker): TranscriptItem(.user(text: message.content, attachments: []))
            case .assistant where !message.content.isEmpty: TranscriptItem(.bot(text: message.content, isStreaming: false))
            default: nil
            }
        }
        let store = Store(directory: root)
        let state = AppState.initial
        botID = state.bots[0].id
        store.save(state)
        store.save(conversation, for: botID)
        store.flush()
        model = AppModel(store: store, runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .custom)] // no address: a turn fails before any network call
        model.defaultModel = claudeCode ? "claudeCode/sonnet" : "custom/modelo"
    }

    func notices(startingWith prefix: String? = nil) -> [String] {
        model.transcript(botID).compactMap { item in
            if case .notice(let text) = item.kind, prefix.map(text.hasPrefix) ?? true { text } else { nil }
        }
    }
}

@Suite final class CompactionReviewAppTests {
    private var harnesses: [AppHarness] = []

    deinit { for harness in harnesses { removeTestFolder(harness.root) } }

    @MainActor private func harness(_ conversation: Conversation, claudeCode: Bool = false) -> AppHarness {
        let made = AppHarness(conversation, claudeCode: claudeCode)
        harnesses.append(made)
        return made
    }

    @Test @MainActor func aLongChatAnnouncesAndSavesToMemoryOnlyOnceInAWhile() async throws {
        var seeded = Conversation()
        seeded.messages = [.user(firstRequest + " " + String(repeating: "texto ", count: 3_000)), ChatMessage(role: .assistant, content: "ok")]
        let app = harness(seeded)
        let messages = 40
        for index in 0..<messages {
            #expect(app.model.send("pedido \(index) do projeto", to: app.botID))
            await waitUntil("the turn \(index) to end") { !app.model.isWorking(app.botID) }
            // What the engine would have recorded for the turn: the message and a long answer.
            app.model.apply(.message(.user("pedido \(index) do projeto")), to: app.botID)
            app.model.apply(.message(ChatMessage(role: .assistant, content: String(repeating: "resposta ", count: 2_500))), to: app.botID)
        }
        let announced = app.notices(startingWith: "Compactei a conversa:").count
        let conversation = try #require(app.model.conversations[app.botID])
        #expect(announced >= 3)
        #expect(announced <= messages / 3)
        #expect(conversation.compactions == announced)
        // One session page per announcement, not per message.
        let bank = app.model.memory.bank(for: app.botID)
        await waitUntil("the session pages") { await bank.snapshot().items.filter { $0.kind == .sessao }.count == announced }
    }

    @Test @MainActor func theSlashCommandCompactsInsteadOfGoingToTheModel() async throws {
        var seeded = Conversation()
        seeded.messages = (0..<24).flatMap { work($0 == 0 ? firstRequest : "pedido número \($0) do projeto", steps: 1, output: 20_000, reply: "resposta \($0)", tag: "c\($0)") }
        let app = harness(seeded)
        app.model.drafts[app.botID] = "/compactar o login"
        let itemsBefore = app.model.transcript(app.botID).count
        #expect(app.model.send("/compactar o login", to: app.botID, fromUser: true))
        #expect(!app.model.isWorking(app.botID))
        #expect(app.model.drafts[app.botID] == "")
        let conversation = try #require(app.model.conversations[app.botID])
        #expect(conversation.summary?.contains("Dar atenção a: o login") == true)
        #expect(conversation.messages.count == 24 * 4)   // no message was sent
        let items = app.model.transcript(app.botID)
        #expect(items.count == itemsBefore + 1)
        #expect(!items.contains { if case .user(let text, _) = $0.kind { text.hasPrefix("/compactar") } else { false } })
        #expect(app.notices(startingWith: "Compactei a conversa:").count == 1)
    }

    @Test @MainActor func theSlashCommandOnAShortChatSaysThereIsNothingToCompact() {
        var seeded = Conversation()
        seeded.messages = work(firstRequest, steps: 1, tag: "d")
        let app = harness(seeded)
        #expect(app.model.send("/compactar", to: app.botID, fromUser: true))
        #expect(app.notices().last == ContextWords.nothingToFold)
        #expect(app.model.conversations[app.botID]?.summary == nil)
    }

    @Test @MainActor func outsideTheComposerTheCommandIsAnOrdinaryMessage() async throws {
        var seeded = Conversation()
        seeded.messages = work(firstRequest, steps: 1, tag: "e")
        let app = harness(seeded)
        #expect(app.model.send("/compactar", to: app.botID))   // a routine or quick ask, not typed by the user
        await waitUntil("the turn to end") { !app.model.isWorking(app.botID) }
        #expect(app.model.transcript(app.botID).contains { if case .user(let text, _) = $0.kind { text == "/compactar" } else { false } })
    }

    @Test @MainActor func claudeCodesManualCompactionReportsEstimatedNumbersLikeAnyOther() throws {
        var seeded = Conversation()
        seeded.messages = (0..<24).flatMap { work($0 == 0 ? firstRequest : "pedido número \($0) do projeto", steps: 1, output: 20_000, reply: "resposta \($0)", tag: "g\($0)") }
        let app = harness(seeded, claudeCode: true)
        let result = app.model.compactNow(botID: app.botID)
        #expect(result.status == .compacted)
        #expect(result.tokensBefore > result.tokensAfter && result.tokensAfter > 0)
        #expect(app.notices(startingWith: "Compactei a conversa:").first?.contains("tokens)") == true)
    }
}
