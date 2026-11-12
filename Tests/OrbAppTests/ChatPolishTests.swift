import Foundation
import Testing
@testable import Orb

@Suite struct WorkAnswerTests {
    private func tool() -> TranscriptItem { TranscriptItem(.tool(ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "ls", state: .done))) }
    private func asked(_ text: String) -> TranscriptItem { TranscriptItem(.user(text: text, attachments: [])) }

    @Test func theWorksCardSaysWhenItsAnswerCameAndWhatItUsed() throws {
        var answer = TranscriptItem(.bot(text: "Pronto.", isStreaming: false))
        answer.spend = ReplySpend(tokens: 38_400, dollars: 0.12)
        func said(_ text: String) -> TranscriptItem { TranscriptItem(.bot(text: text, isStreaming: false)) }
        let items = [asked("publica"), tool(), TranscriptItem(.notice("Cache do provedor desligado")), tool(), said("Achei a fila."), tool(), answer,
                     asked("de novo"), tool(), said("Vou conferir."), tool(), said("Feito.")]
        let rows = TranscriptFolding.rows(for: items)
        let works = rows.filter { if case .work = $0 { true } else { false } }
        try #require(works.count == 2)
        let answers = TranscriptFolding.workAnswers(in: rows)
        // Past the notice the request left between its work and its answer.
        #expect(answers[works[0].id] == WorkAnswer(date: answer.date, spend: answer.spend))
        #expect(answers[works[1].id]?.spend == nil && answers[works[1].id]?.date == items[11].date)
        #expect(answers[works[0].id]?.text.hasSuffix(" · " + UsageFormat.dollars(0.12)) == true)
    }

    @Test func aRequestWithNoAnswerYetHasNothingToSay() {
        // Work that ended on your next message, not on an answer: the answer of the next request is not this one's.
        let rows: [TranscriptRowModel] = [.single(asked("a")), .work([tool(), tool()], seconds: 3), .single(asked("b")),
                                          .single(TranscriptItem(.bot(text: "oi", isStreaming: false)))]
        #expect(TranscriptFolding.workAnswers(in: rows).isEmpty)
        #expect(TranscriptFolding.workAnswers(in: [.work([tool()], seconds: nil)]).isEmpty)
    }

    @Test func theSpendReadsAsDollarsWhenThePriceIsKnownAndAsTokensOtherwise() {
        #expect(ReplySpend(tokens: 38_400, dollars: 0.12).text == UsageFormat.dollars(0.12))
        #expect(ReplySpend(tokens: 38_400, dollars: nil).text == UsageFormat.tokens(38_400))
        #expect(ReplySpend(tokens: 38_400, dollars: 0).text == UsageFormat.tokens(38_400))
        #expect(ReplySpend(tokens: 0, dollars: nil).text == nil)
    }

    @Test func aLineFromBeforeTheSpendWasKeptStillReads() throws {
        var item = TranscriptItem(.bot(text: "ok", isStreaming: false))
        #expect(try JSONDecoder().decode(TranscriptItem.self, from: JSONEncoder().encode(item)).spend == nil)
        item.spend = ReplySpend(tokens: 10, dollars: 0.5)
        #expect(try JSONDecoder().decode(TranscriptItem.self, from: JSONEncoder().encode(item)).spend == item.spend)
    }

    @Test func theBrowsersLineHasAShorterFormForANarrowCard() {
        var view = BrowserViewItem(host: "checkout.acessosfit.com.br", startedAt: Date(timeIntervalSince1970: 0), actions: 14)
        view.endedAt = Date(timeIntervalSince1970: 60)
        view.lastPath = "/pagamentos"
        view.outcome = .done
        #expect(LiveScreenText.closingLine(view).hasSuffix("terminou em /pagamentos"))
        #expect(LiveScreenText.closingLine(view, short: true) == "Usou o navegador · checkout.acessosfit.com.br · 1 min · 14 ações")
    }
}

@Suite(.serialized) final class ReplySpendFlowTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbSpend-\(UUID().uuidString)")
    init() { QuietNotifications.hold() }
    deinit { QuietNotifications.release(); removeTestFolder(root) }

    @Test @MainActor func whatATurnUsedStaysOnTheAnswerItEndedWith() async throws {
        let store = Store(directory: root)
        store.save(AppState.initial)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.homeFolder = root
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        let recall: [LLMEvent] = [.toolCalls([ToolCallRequest(id: "1", name: "recall", arguments: #"{"query":"x"}"#)]),
                                  .finished(.toolUse, TokenUsage(input: 1_000, output: 20))]
        let script = CallScript([recall, [.text("Pronto."), .finished(.done, TokenUsage(input: 1_200, output: 30))],
                                 [.text("oi"), .finished(.done, nil)]])
        model.clientOverride = { CallScriptModel(script: script) }
        let botID = model.bots[0].id
        #expect(model.send("faz", to: botID))
        await waitUntilIdle(model, botID)
        let answer = try #require(model.transcript(botID).last { if case .bot = $0.kind { true } else { false } })
        #expect(answer.spend?.tokens == 2_250, "both calls of the turn, input and output")
        // A turn whose provider reported nothing keeps nothing, and the earlier answer keeps its own.
        #expect(model.send("oi", to: botID))
        await waitUntilIdle(model, botID)
        let replies = model.transcript(botID).filter { if case .bot = $0.kind { true } else { false } }
        #expect(replies.last?.spend == nil && replies.first?.spend?.tokens == 2_250)
    }
}
