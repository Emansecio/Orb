import Foundation
import Testing
@testable import Orb
import AppKit
import SwiftUI

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

@Suite struct ReasoningDisplayTests {
    @Test func reasoningTextExtractsReadablePartsAndIgnoresOpaqueBlobs() {
        let trace = ReasoningTrace(format: .messages, provider: "anthropic", model: "claude",
                                   parts: [ReasoningPart(kind: .redactedThinking, text: "", data: "opaque"),
                                           ReasoningPart(kind: .thinking, text: "  Analisando o arquivo.  ", signature: "sig"),
                                           ReasoningPart(kind: .encrypted, text: "Verificando testes.", data: "enc")])
        #expect(ReasoningText.extract(from: trace) == "Analisando o arquivo.\n\nVerificando testes.")
        let empty = ReasoningTrace(format: .responses, provider: "openai", model: "o3",
                                   parts: [ReasoningPart(kind: .encrypted, text: "   ", data: "enc")])
        #expect(ReasoningText.extract(from: empty) == nil)
        #expect(ReasoningText.extract(from: nil) == nil)
    }

    @Test func transcriptItemDecodesReasoningTolerantly() throws {
        var item = TranscriptItem(.bot(text: "Pronto.", isStreaming: false))
        #expect(try JSONDecoder().decode(TranscriptItem.self, from: JSONEncoder().encode(item)).reasoning == nil)
        item.reasoning = "Passo 1"
        #expect(try JSONDecoder().decode(TranscriptItem.self, from: JSONEncoder().encode(item)).reasoning == "Passo 1")
    }
}

// MARK: - ColumnSizingTests

/// `ColumnSizing.TrimView` clears `sizingOptions` on column hosting views while leaving the window's root hosting view alone.
@MainActor
struct ColumnSizingTests {
    @Test func trimsColumnHostingViewsWithoutTouchingTheWindowRoot() async {
        let root = NSHostingView(rootView: Text("Janela").padding().frame(width: 400, height: 300))
        let column = NSHostingView(rootView: Text("Coluna").padding().frame(width: 120))
        let trimmer = ColumnSizing.TrimView()
        root.addSubview(column)
        root.addSubview(trimmer)
        #expect(!root.sizingOptions.isEmpty && !column.sizingOptions.isEmpty)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer {
            window.contentView = NSView()
            window.close()
        }

        await waitUntil("the column hosting view's sizingOptions to be trimmed") { column.sizingOptions.isEmpty }
        #expect(!root.sizingOptions.isEmpty)
    }
}

// MARK: - ApprovalHintsTests

/// The shortcut hints of the approval and question cards, the VoiceOver line of a failed tool, and which Orb's side
/// work a chat presents.
@Suite("Dicas das permissões e acessibilidade") struct ApprovalHintsTests {
    @Test func theKeyIsOnlyPromisedWhereItAnswersTheCard() {
        #expect(ApprovalHints.accessibilityHint("Esc", showsKeys: true) == "Atalho: Esc")
        #expect(ApprovalHints.accessibilityHint("Esc", showsKeys: false) == "")
        #expect(ApprovalHints.help("Recusa o pedido", key: "Esc", showsKeys: true) == "Recusa o pedido (Esc)")
        #expect(ApprovalHints.help("Recusa o pedido", key: "Esc", showsKeys: false) == "Recusa o pedido")
    }

    @Test func theRecordOfAnAnsweredCardSaysWhatTheClickDoesInItsState() {
        #expect(ApprovalHints.toggleRequest(isOpen: false) == "Mostra o pedido")
        #expect(ApprovalHints.toggleRequest(isOpen: true) == "Esconde o pedido")
    }

    @Test func aFailedToolLineDoesNotSayItFailedTwice() {
        #expect(TranscriptSpeech.tool(title: "Falhou", detail: "swift build", state: .failed) == "Falhou swift build")
        #expect(TranscriptSpeech.tool(title: "Falhou ao ler", detail: "a.txt", state: .failed) == "Falhou ao ler a.txt")
        #expect(TranscriptSpeech.tool(title: "Rodou", detail: "ls", state: .failed) == "Rodou ls, falhou")
        #expect(TranscriptSpeech.tool(title: "Falhou", detail: "ls", state: .done) == "Falhou ls")
    }

    @Test func aChatPresentsOnlyTheSideWorkOfItsOwnOrb() {
        let mine = UUID(), other = UUID()
        let target = SideWorkTarget(botID: mine, requestID: UUID())
        #expect(SideWorkTarget.shown(target, for: mine) == target)
        #expect(SideWorkTarget.shown(target, for: other) == nil)
        #expect(SideWorkTarget.shown(nil, for: mine) == nil)
    }
}

// MARK: - ProseWidthTests

@Suite struct ProseWidthTests {
    @Test func atRestTheWidthIsExact() {
        #expect(ProseWidth.layoutWidth(517.5, moving: false) == 517.5)
    }

    @Test func movingStepsDownAndNeverAbove() {
        for width in stride(from: CGFloat(17), through: 900, by: 3.7) {
            let stepped = ProseWidth.layoutWidth(width, moving: true)
            #expect(stepped <= width)
            #expect(width - stepped < ProseWidth.step)
            #expect(stepped.truncatingRemainder(dividingBy: ProseWidth.step) == 0)
        }
        #expect(ProseWidth.layoutWidth(10, moving: true) == 10)
    }

    @Test func motionStartsAfterSeveralFramesOfChangeAndSettlesAfterTheDelay() {
        var motion = ProseWidth.Motion()
        func note(_ width: CGFloat, _ time: TimeInterval) -> Bool { motion.note(width, at: time) }
        #expect(!note(500, 1))
        #expect(!note(500, 1.5))
        #expect(!note(490, 2))              // a change, or several widths in one pass: not yet movement
        #expect(!note(480, 2.0001))
        #expect(!note(470, 2.0002))
        #expect(!note(460, 2.02))           // second frame
        #expect(note(450, 2.04))            // third frame: moving
        #expect(note(450, 2.04 + ProseWidth.settle / 2))
        #expect(!note(450, 2.04 + ProseWidth.settle + 0.01))   // still long enough: exact again
        #expect(!note(440, 3))              // starts over
    }
}

// MARK: - MessageQuoteTests

/// Quoting a reply: the quote at the start of the draft, how a message's quote is read back, and the reply it came from.
struct MessageQuoteTests {
    @Test func aSelectionBecomesAQuoteBlockAtTheStartOfTheDraft() {
        #expect(MessageQuote.block("  Mover os PDFs\n\n  para Contratos/ ") == "> Mover os PDFs\n> para Contratos/")
        #expect(MessageQuote.draft(quoting: "Apagar as duplicadas", before: "  por quê? ") == "> Apagar as duplicadas\n\npor quê?")
        #expect(MessageQuote.draft(quoting: "Apagar", before: "") == "> Apagar\n\n")
        #expect(MessageQuote.draft(quoting: " \n ", before: "oi") == "oi")
        // A second passage joins the first block instead of breaking it.
        let twice = MessageQuote.draft(quoting: "Segundo trecho", before: "> Primeiro trecho\n\npor quê?")
        #expect(twice == "> Primeiro trecho\n> Segundo trecho\n\npor quê?")
        #expect(MessageQuote.split(twice).quote == "Primeiro trecho\nSegundo trecho")
        let long = MessageQuote.block(String(repeating: "a", count: 2_000))
        #expect(long.hasSuffix("…") && long.count <= MessageQuote.limit + 3)
    }

    @Test func aMessagesLeadingQuoteIsReadApartFromWhatFollows() {
        let parts = MessageQuote.split("> Mover os PDFs\n>para Contratos/\n\nPor que não 2024?")
        #expect(parts.quote == "Mover os PDFs\npara Contratos/")
        #expect(parts.body == "Por que não 2024?")
        #expect(MessageQuote.split("Sem citação\n> no meio").quote == nil)
        #expect(MessageQuote.split("> só a citação").body.isEmpty)
        #expect(MessageQuote.split(">\n> \ntexto").quote == nil) // marks without words are no quote
    }

    @Test func theQuoteIsFoundInTheNearestReplyThatHoldsItsStart() {
        let older = TranscriptItem(.bot(text: "1. **Mover** os PDFs para `Contratos/`\n2. Apagar", isStreaming: false))
        let other = TranscriptItem(.bot(text: "Outra coisa.", isStreaming: false))
        let newer = TranscriptItem(.bot(text: "Vou mover os PDFs para Contratos/ agora.", isStreaming: false))
        let message = TranscriptItem(.user(text: "> 1. Mover os PDFs para Contratos/\n\nok", attachments: []))
        let items = [older, other, message, newer]
        // A list item's marker and the Markdown marks do not matter; a reply after the message is not where it came from.
        #expect(MessageQuote.source(of: "1. Mover os PDFs para Contratos/", before: 2, in: items) == older.id)
        #expect(MessageQuote.source(of: "Nada disso foi dito", before: 2, in: items) == nil)
        #expect(MessageQuote.probe("• Mover   os\nPDFs") == "Mover os")
    }

    @MainActor @Test func revealingAQuoteMarksTheReplyForAMomentWithTheBarClosed() async throws {
        let find = ConversationFind(flashDuration: .milliseconds(20))
        let reply = UUID()
        find.reveal(quoteOf: reply, words: "Mover os PDFs")
        #expect(find.jump?.itemID == reply)
        #expect(find.focus == FindFocus(itemID: reply, query: "Mover os PDFs", isFlashing: true))
        #expect(find.pausesFollowing)
        // The wash ends after the flash (waited for, as long as a busy test run needs).
        for _ in 0..<250 where find.focus != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(find.focus == nil && find.jump == nil && !find.pausesFollowing)
    }
}

// MARK: - TimeSeparatorsTests

/// The time above a new moment of the conversation: which rows get one and what it says.
struct TimeSeparatorsTests {
    private let calendar = Calendar.current

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func theFirstRowANewDayAndAPauseBeginAMoment() {
        let ids = (0..<6).map { _ in UUID() }
        let rows: [(id: UUID, start: Date, end: Date)] = [
            (ids[0], date(12, 9, 0), date(12, 9, 0)),
            (ids[1], date(12, 9, 5), date(12, 9, 5)),                   // five minutes later: same moment
            (ids[2], date(12, 9, 10), date(12, 9, 40)), // a run of actions that lasted half an hour
            (ids[3], date(12, 9, 50), date(12, 9, 50)),                  // ten minutes after the run ended: same moment
            (ids[4], date(12, 10, 10), date(12, 10, 10)),                 // twenty minutes of silence
            (ids[5], date(13, 0, 2), date(13, 0, 2)),                   // past midnight, however close
        ]
        let breaks = TimeSeparators.breaks(spans: rows, calendar: calendar)
        #expect(Set(breaks.keys) == [ids[0], ids[4], ids[5]])
        #expect(breaks[ids[4]] == date(12, 10, 10))
        #expect(TimeSeparators.breaks(spans: [], calendar: calendar).isEmpty)
    }

    @Test func theLabelSaysTheDayAsAPersonWould() {
        let now = date(13, 15) // a Tuesday
        #expect(TimeSeparators.label(date(13, 14, 5), now: now, calendar: calendar) == "Hoje, 14:05")
        #expect(TimeSeparators.label(date(12, 9, 12), now: now, calendar: calendar) == "Ontem, 09:12")
        #expect(TimeSeparators.label(date(8, 10), now: now, calendar: calendar) == "Quinta-feira, 10:00")
        #expect(TimeSeparators.label(date(3, 14, 5), now: now, calendar: calendar) == "3 de outubro, 14:05")
        #expect(TimeSeparators.label(date(3, 14, 5, year: 2025), now: now, calendar: calendar) == "3 de outubro de 2025, 14:05")
    }

    @Test func theLabelReadsOnlyTheDayOfNow() {
        // The separator's timeline gives today's midnight as "now".
        #expect(TimeSeparators.label(date(13, 14, 5), now: date(13, 0), calendar: calendar) == "Hoje, 14:05")
    }

    @MainActor @Test func theTranscriptMarksTheRowsThatBeginAMoment() {
        var first = TranscriptItem(.user(text: "oi", attachments: []))
        first.date = date(12, 9)
        var reply = TranscriptItem(.bot(text: "olá", isStreaming: false))
        reply.date = date(12, 9, 1)
        var later = TranscriptItem(.user(text: "voltei", attachments: []))
        later.date = date(12, 18)
        let transcript = OrbTranscript(items: [first, reply, later])
        #expect(transcript.timeBreaks == [first.id: first.date, later.id: later.date])
    }
}

// MARK: - ConversationExportTests

@Suite struct ConversationExportTests {
    @Test func theFileReadsAsTheChatDoesWithoutWhatTheActionsReturned() throws {
        var failed = ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "npm test\necho fim", state: .failed)
        failed.output = "SEGREDO DA SAÍDA"
        let items = [
            TranscriptItem(.greeting("Oi! Sou o Atlas.")),
            TranscriptItem(.user(text: "Publica o site", attachments: ["/Users/ana/notas finais.pdf"])),
            TranscriptItem(.tool(ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "./deploy.sh --prod", state: .done))),
            TranscriptItem(.tool(failed)),
            TranscriptItem(.bot(text: "Publicado.\n\n| a | b |\n|---|---|\n| 1 | 2 |", isStreaming: false)),
            TranscriptItem(.notice("Conversa compactada.")),
            TranscriptItem(.bot(text: "   ", isStreaming: false)),
        ]
        let text = try #require(ConversationExport.markdown(items, orb: "Atlas", person: "Ana"))
        #expect(text.hasPrefix("# Conversa com Atlas\n\nExportada em "))
        #expect(text.contains("**Atlas** · ") && text.contains("Oi! Sou o Atlas."))
        #expect(text.contains("Publica o site\n- Anexo: notas finais.pdf"))
        #expect(text.contains("- Rodando no Terminal `./deploy.sh --prod`\n- Rodando no Terminal `npm test` (falhou)"))
        #expect(text.contains("| 1 | 2 |") && text.contains("> Conversa compactada."))
        #expect(!text.contains("SEGREDO") && !text.contains("echo fim") && !text.contains("/Users/ana"))
        #expect(text.components(separatedBy: "**Atlas** · ").count == 3, "an empty reply is not a turn")
    }

    @Test func aConversationWithNothingSaidHasNoFile() {
        #expect(ConversationExport.markdown([], orb: "Atlas", person: "Ana") == nil)
        #expect(ConversationExport.markdown([TranscriptItem(.notice("oi"))], orb: "Atlas", person: "Ana") == nil)
    }

    @Test @MainActor func exportingAnEmptyConversationSaysSoInsteadOfOpeningAPanel() {
        let folder = TempFolder()
        let model = AppModel(store: Store(directory: folder.url), runsBackgroundWork: false)
        let botID = model.bots[0].id
        model.exportConversation(botID)
        #expect(model.notices(botID).last == "Ainda não há o que exportar nesta conversa.")
    }

    @Test func theFileNameIsSafeInAnyFolder() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let name = ConversationExport.fileName(orb: "A/B: C", now: day)
        #expect(name.hasPrefix("Conversa com A B  C ") && name.hasSuffix(".md") && !name.contains("/") && !name.contains(":"))
        #expect(ConversationExport.fileName(orb: " ", now: day).hasPrefix("Conversa com Orb "))
    }
}
