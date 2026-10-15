import Foundation
import Testing
@testable import Orb

/// What the audit of the compaction found lost or repeated, kept now.
struct CompactionAuditTests {
    private func text(_ messages: [ChatMessage]) -> String { messages.map(\.content).joined(separator: "\n") }

    @Test func aSteeringConstraintStaysInTheDigest() {
        let marker = "NUNCA_PUBLIQUE_ARQUIVO_ZYX"
        var messages: [ChatMessage] = [.user("Investigue o projeto inteiro e continue até concluir a tarefa")]
        var steering: [Int] = []
        for i in 0..<80 {
            messages += [assistant(calls: [call("step-\(i)", "read_file", "{\"path\":\"/p/file\(i).swift\"}")]),
                         .tool("step-\(i)", String(repeating: "x", count: 3_000))]
            if i == 0 { steering.append(messages.count); messages.append(.user(marker)) }
        }
        var cut = ContextCut()
        let fit = ContextWindow.fit(messages, budget: ContextBudget(tokens: 8_000), cut: &cut, steering: steering)
        #expect(fit.skippedSteps > 24)
        #expect(text(fit.messages).contains(marker))
        #expect(fit.messages.contains { $0.content.contains("linhas anteriores") })
    }

    @Test func theDigestKeepsTheNewestStepsBesideTheUserLines() {
        var messages: [ChatMessage] = []
        for i in 0..<40 {
            messages += [.user("pedido \(i)"), assistant(calls: [call("c\(i)", "read_file", "{\"path\":\"/f\(i)\"}")]), .tool("c\(i)", "ok")]
        }
        let lines = ToolDigest.lines(for: messages)
        #expect(lines.count == ToolDigest.maxLines)
        #expect(lines.filter { $0.hasPrefix("[usuário]") }.count == ToolDigest.maxLines / 2)
        #expect(lines.last?.contains("/f39") == true)
        #expect(lines.first == "(+\(80 - ToolDigest.maxLines + 1) linhas anteriores)")
    }

    @Test func aStepsNoteFoldedWithItsRequestBecomesALedgerNote() throws {
        var c = Conversation()
        c.messages = [.user("Faça a migração completa deste projeto e rode os testes")]
        for i in 0..<60 {
            c.messages += [assistant(calls: [call("phase-\(i)", "read_file", "{\"path\":\"/p/file\(i).swift\"}")]),
                           .tool("phase-\(i)", String(repeating: "x", count: 3_000))]
        }
        c.messages.append(assistant("quase lá"))
        let budget = ContextBudget(tokens: 8_000)
        let history = c.prepareHistory(budget: budget).history
        let steps = try #require(ContextSummary.inherited(in: history)?.stepsNote)
        let line = try #require(steps.components(separatedBy: "\n").first { $0.contains("read_file /p/file") })
        let path = try #require(line.split(separator: " ").first { $0.hasPrefix("/p/file") })
        var cut = ContextCut()
        let fit = ContextWindow.fit(history + [.user("agora ajuste o login " + String(repeating: "contexto ", count: 1_600))],
                                    budget: budget, cut: &cut)
        #expect(fit.summary != nil)
        #expect(fit.ledger?.digests.first?.contains(String(path)) == true)
        #expect(text(fit.messages).contains(String(path)))
        #expect(!text(fit.messages).contains(ContextSummary.stepsNoteTitle)) // the note is no longer about "this request"
        #expect(fit.messages.contextCharacters <= budget.characters)
    }

    @Test func theEndOfALongFirstRequestStaysInTheSummary() throws {
        let marker = "NUNCA_PUBLIQUE_SEM_APROVACAO_ABC"
        var c = Conversation()
        c.messages = [.user("Investigue o projeto e prepare uma proposta. " + String(repeating: "Detalhes do trabalho. ", count: 120) + marker),
                      assistant("Entendido"), .user("continue a investigação"), assistant("ok")]
        let history = c.prepareHistory(budget: ContextBudget(tokens: 500)).history
        #expect(c.coveredMessageCount == 2)
        #expect(text(history).contains(marker))
        let original = try #require(c.ledger?.original)
        #expect(original.hasPrefix("Investigue o projeto e prepare uma proposta."))
        #expect(original.count <= ConversationLedger.originalLimit)
        #expect(!text(history).contains("Objetivo atual")) // the goal is still recognized as the start of the original
    }

    @Test func anEnglishStandingRuleOutlastsLaterRequests() {
        var l = ConversationLedger().absorbing([.user("Investigate the repository and prepare a report."), assistant("ok")])
        let rule = "Do not publish until I approve."
        l.absorb([.user(rule), assistant("understood")])
        #expect(ConversationLedger.looksLikeDecision(rule))
        for i in 0..<30 { l.absorb([.user("Inspect module number \(i)"), assistant("checked")]) }
        #expect(l.render().contains(rule))
        #expect(!ConversationLedger.looksLikeDecision("Inspect module number 3"))
    }

    /// A gateway with a 40k window: the reply the request asks for is the room the history left for it.
    @Test func theMessagesFormatAsksForTheReplyTheBudgetLeft() throws {
        var account = ProviderAccount(kind: .custom)
        account.baseURL = "http://127.0.0.1:8080/v1"
        account.format = .messages
        account.models = [ProviderModel(id: "small", name: "Small", format: .messages, contextLength: 40_000)]
        let budget = ContextBudget(model: account.models[0], provider: .custom)
        #expect(budget.replyTokens == 5_000)
        let client = try #require(account.client(for: account.models[0], credentials: { _ in nil }, conversationID: "c",
                                                 replyTokens: budget.replyTokens) as? AnthropicClient)
        #expect(client.maxTokens == budget.replyTokens)
        let unbudgeted = try #require(account.client(for: account.models[0], credentials: { _ in nil }, conversationID: "c") as? AnthropicClient)
        #expect(unbudgeted.maxTokens == 16_000)
    }

    @Test func theHistoryIsMeasuredOnceAsTheMeterDoes() {
        var c = Conversation()
        c.messages = longHistory()
        let budget = ContextBudget(tokens: 20_000)
        #expect(ContextMeter.historyTokens(of: c) == c.contextFill(budget: budget).historyTokens)
        let report = c.compact(budget: budget)
        #expect(report?.tokensAfter == c.contextFill(budget: budget).historyTokens)
        #expect(ContextMeter.historyTokens(of: c) == c.contextFill(budget: budget).historyTokens) // with a summary too
    }

    @Test func aMessageThatCannotBeReadMovesTheCountsBack() throws {
        let data = Data(#"{"items":[],"summary":"Pedido original: o começo da tarefa","summaryCoveredCount":2,"condensedCount":3,"chunkSummaries":[{"start":0,"end":2,"text":"a"},{"start":1,"end":2,"text":"b"}],"messages":[{"role":"user","content":"pedido original antigo"},{"role":"future-role","content":"old incompatible message"},{"role":"user","content":"NAO_REMOVA_O_BANCO_4711"},{"role":"assistant","content":"entendido"}]}"#.utf8)
        var c = try JSONDecoder().decode(Conversation.self, from: data)
        #expect(c.messages.count == 3)
        #expect(c.coveredMessageCount == 1)
        #expect(c.condensedCount == 2)
        #expect(c.chunkSummaries == [ChunkSummary(start: 0, end: 1, text: "a")]) // "b" only covered the lost message
        #expect(text(c.prepareHistory(budget: ContextBudget(tokens: 10_000)).history).contains("NAO_REMOVA_O_BANCO_4711"))
    }

    @Test func aToolResultWhoseCallCannotBeReadGoesWithIt() throws {
        let data = Data(#"{"items":[],"messages":[{"role":"user","content":"Leia o arquivo de configuração"},{"role":"future-role","content":"","toolCalls":[{"id":"c1","name":"read_file","arguments":"{}"}]},{"role":"tool","content":"conteúdo recuperável","toolCallID":"c1"},{"role":"user","content":"continue"}]}"#.utf8)
        let c = try JSONDecoder().decode(Conversation.self, from: data)
        #expect(!c.messages.contains { $0.role == .tool })
        var cut = ContextCut()
        #expect(isValidConversation(ContextWindow.fit(c.messages, budget: ContextBudget(tokens: 10_000), cut: &cut).messages))
    }

    @Test func aReadableConversationDecodesAsItWasSaved() throws {
        var c = Conversation()
        c.messages = [.user("a"), assistant(calls: [call("c1", "read_file", "{}")]), .tool("c1", "ok"), assistant("pronto")]
        c.summary = "resumo"
        c.summaryCoveredCount = 3
        c.condensedCount = 2
        c.memorySavedCount = 0
        let decoded = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(c))
        #expect(decoded.messages == c.messages)
        #expect((decoded.summaryCoveredCount, decoded.condensedCount, decoded.memorySavedCount) == (3, 2, 0))
    }

    @Test func aRefusedNoteIsNoNote() async {
        let recorder = CallScript([[.text("Não posso resumir este conteúdo. Envie outra solicitação para continuar."),
                                  .finished(.refusal, TokenUsage(input: 900, output: 20))]], whenExhausted: .fim)
        let note = await ChunkSummarizer.write(.init(range: 0..<2, input: "transcript"), client: CallScriptModel(script: recorder), model: "fake")
        #expect(note.text == nil)
        #expect(note.usage == TokenUsage(input: 900, output: 20)) // billed all the same
    }

    @Test func aRequestThatCannotShrinkIsNotSentTwice() async throws {
        let recorder = CallScript([], failures: [LLMError.contextExceeded("too long"), LLMError.contextExceeded("too long")], whenExhausted: .fim)
        let request = TurnRequest(bot: Bot(name: "Audit", role: "", orb: OrbConfig(), permissionMode: .bypass), model: "fake",
                                  system: "sys", history: [], prompt: String(repeating: "u", count: 20_000), client: CallScriptModel(script: recorder),
                                  tools: [], context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory),
                                  budget: ContextBudget(tokens: 1_000))
        var failures: [String] = []
        for await event in AgentEngine().run(request) { if case .failed(let message) = event { failures.append(message) } }
        #expect(await recorder.received.count == 1)
        #expect(failures == [AgentEngine.doesNotFit])
    }
}
