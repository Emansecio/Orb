import Foundation
import Testing
@testable import Orb

// The Orb's actions one after another fold into one line of the chat ("Rodou 7 comandos e leu 1 arquivo"), which opens
// into their lines: which actions fold together, and the words of the line.

@MainActor
struct ToolRunFoldingTests {
    private func call(_ title: String, _ kind: ToolCall.Kind = .shell, _ state: ToolCall.State = .done) -> ToolCall {
        ToolCall(kind: kind, title: title, detail: "", state: state)
    }

    private func tool(_ title: String = "Rodando no Terminal", _ kind: ToolCall.Kind = .shell,
                      _ state: ToolCall.State = .done) -> TranscriptItem {
        TranscriptItem(.tool(call(title, kind, state)))
    }

    private func say(_ text: String) -> TranscriptItem { TranscriptItem(.bot(text: text, isStreaming: false)) }

    private func ask(_ text: String = "Levante os leads", duringTask: Bool = false) -> TranscriptItem {
        TranscriptItem(.user(text: text, attachments: []), duringTask: duringTask)
    }

    private func card(_ decision: ApprovalDecision?) -> TranscriptItem {
        TranscriptItem(.approval(ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "ls", reason: "",
                                                 decision: decision)))
    }

    @Test func actionsOneAfterAnotherFoldIntoOneRowAndALoneOneStaysALine() {
        let ask = ask()
        let read = tool("Lendo arquivo", .file)
        let runs = [tool(), tool(), tool()]
        let lone = tool()
        let items = [ask, read] + runs + [say("A fila trouxe 61 conversas."), lone]
        // The request still runs: what it did so far stays in view, its actions one line per run.
        #expect(TranscriptFolding.rows(for: items, liveTail: true) == [.single(ask), .tools([read] + runs), .single(items[5]), .single(lone)])
    }

    @Test func aFinishedRequestFoldsItsWorkAndKeepsItsAnswer() {
        let request = ask()
        let work = [tool("Lendo arquivo", .file), tool(), say("A fila trouxe 61 conversas."), tool(), tool()]
        let answer = say("Respondi os 12 leads pendentes.")
        let items = [request] + work + [answer]
        #expect(TranscriptFolding.rows(for: items) == [.single(request), .work(work, seconds: nil), .single(answer)])
        // While it runs, nothing folds into a work row.
        #expect(!TranscriptFolding.rows(for: items, liveTail: true).contains { if case .work = $0 { true } else { false } })
        // Only the last request is the running one.
        let next = ask("E os de ontem?")
        #expect(TranscriptFolding.rows(for: items + [next, tool()], liveTail: true)[1] == .work(work, seconds: nil))
    }

    @Test func aNoticeInTheWorkStaysInViewRightAfterIt() {
        let notice = TranscriptItem(.notice("O provedor não está reaproveitando o início das conversas (cache)."))
        let work = [tool(), say("Lendo em lotes."), notice, tool(), tool()]
        let answer = say("Pronto.")
        let rows = TranscriptFolding.rows(for: [ask()] + work + [answer])
        #expect(rows.dropFirst().first == .work([work[0], work[1], work[3], work[4]], seconds: nil))
        #expect(Array(rows.suffix(2)) == [.single(notice), .single(answer)])
    }

    @Test func whatMustStayInViewKeepsTheWorkUnfolded() {
        let answer = say("Pronto.")
        // A request that is one run of actions is one line already.
        let oneRun = [ask(), tool(), tool(), answer]
        #expect(TranscriptFolding.rows(for: oneRun) == [.single(oneRun[0]), .tools([oneRun[1], oneRun[2]]), .single(answer)])
        // Actions after the Orb's last words: no answer to keep below the fold.
        let unanswered = [ask(), tool(), say("Vou ver."), tool()]
        #expect(!TranscriptFolding.rows(for: unanswered).contains { if case .work = $0 { true } else { false } })
        // A card that waits for you never folds.
        let waiting = [ask(), tool(), say("Preciso de permissão."), tool(), card(nil), answer]
        #expect(!TranscriptFolding.rows(for: waiting).contains { if case .work = $0 { true } else { false } })
        // A message you sent during the task splits the request: it stays in view.
        let steered = ask("Inclua os de ontem", duringTask: true)
        let rows = TranscriptFolding.rows(for: [ask(), tool(), say("Lendo."), tool(), steered, tool(), say("Lendo mais."), tool(), answer])
        #expect(rows.contains(.single(steered)))
        #expect(rows.filter { if case .work = $0 { true } else { false } }.count == 1)
    }

    @Test func theWorkSaysHowLongTheRequestTook() {
        var request = ask()
        request.date = Date(timeIntervalSince1970: 1_000)
        var answer = say("Pronto.")
        answer.date = request.date.addingTimeInterval(65)
        let work = [tool(), say("Lendo."), tool()]
        #expect(TranscriptFolding.rows(for: [request] + work + [answer])[1] == .work(work, seconds: 65))
        let calls = Array(repeating: call("Rodando no Terminal"), count: 11) + [call("Lendo arquivo", .file)]
        #expect(ToolTally.work(calls, seconds: 65) == "Trabalhou por 1 min 05 s · rodou 11 comandos e leu 1 arquivo")
        #expect(ToolTally.work(calls, seconds: nil) == "Trabalhou · rodou 11 comandos e leu 1 arquivo")
    }

    @Test func anAnsweredCardGoesWithTheActionsAndOneThatWaitsEndsThem() {
        let answered = [tool(), card(.once), tool(), card(.deny)]
        #expect(TranscriptFolding.rows(for: answered) == [.tools(answered)])
        let first = tool(), waiting = card(nil), last = tool()
        #expect(TranscriptFolding.rows(for: [first, waiting, last]) == [.single(first), .single(waiting), .single(last)])
    }

    @Test func aNoticeOrACardThatNeedsYouEndsTheRun() {
        let first = [tool(), tool()]
        let notice = TranscriptItem(.notice("O provedor não está reaproveitando o início das conversas (cache)."))
        let second = [tool(), tool()]
        let items = first + [notice] + second
        #expect(TranscriptFolding.rows(for: items) == [.tools(first), .single(notice), .tools(second)])
    }

    @Test func aRunKeepsTheIDOfItsFirstActionWhileItGrows() {
        let first = tool()
        let two = TranscriptFolding.rows(for: [first, tool()])
        let three = TranscriptFolding.rows(for: [first, tool(), tool()])
        #expect(two.map(\.id) == [first.id] && three.map(\.id) == [first.id])
        // A single action turning into a run keeps its id too: the row it was stays the row.
        #expect(TranscriptFolding.rows(for: [first]).map(\.id) == [first.id])
    }

    @Test func aRunEndsWhereACompactionFoldEnds() {
        let items = [tool(), tool(), tool(), tool()]
        #expect(TranscriptFolding.rows(for: items, boundary: 2) == [.tools(Array(items[..<2])), .tools(Array(items[2...]))])
        #expect(TranscriptFolding.rows(for: items, boundary: 3) == [.tools(Array(items[..<3])), .single(items[3])])
    }

    @Test func aChatWhereNothingFoldsHasNoRows() {
        #expect(OrbTranscript(items: [tool(), say("oi"), tool()]).rows == nil)
        #expect(OrbTranscript(items: [tool(), tool()]).rows?.count == 1)
    }

    // MARK: The words of the line

    @Test func theLineCountsWhatWasDoneInTheOrderItWasFirstDone() {
        let calls = [call("Lendo arquivo", .file)] + Array(repeating: call("Rodando no Terminal"), count: 7)
            + [call("Procurando arquivos", .search), call("Buscando no conteúdo", .search)]
        #expect(ToolTally.summary(calls) == "Leu 1 arquivo, rodou 7 comandos e fez 2 buscas")
        #expect(ToolTally.summary([call("Rodando no Terminal"), call("Rodando em segundo plano")]) == "Rodou 2 comandos")
    }

    @Test func kindsWithoutANameComeLastAndAFourthKindIsCountedAsMore() {
        let connector = call("Usando github", .connector)
        #expect(ToolTally.summary([connector, call("Rodando no Terminal")]) == "Rodou 1 comando e fez 1 outra ação")
        #expect(ToolTally.summary([connector, connector]) == "Fez 2 ações")
        let many = [call("Rodando no Terminal"), call("Lendo arquivo", .file), call("Editando arquivo", .file),
                    call("Listando pasta", .file), call("Lendo página", .browser), connector]
        #expect(ToolTally.summary(many) == "Rodou 1 comando, leu 1 arquivo, alterou 1 arquivo e mais 3 ações")
    }

    @Test func aRunInTheBrowserSaysTheSiteAndWhatWasDoneThere() {
        func browse(_ title: String, _ detail: String = "") -> ToolCall { ToolCall(kind: .browser, title: title, detail: detail, state: .done) }
        let calls = [browse("Abrindo página", "https://www.gympass.com/login"), browse("Olhando a página"),
                     browse("Preenchendo “CPF”", "123"), browse("Clicando em “Verificar”", "e5"), browse("Clicando na página", "e9")]
        #expect(ToolTally.line(calls) == "gympass.com · Abriu 1 página, preencheu 1 campo, clicou 2 vezes e mais 1 ação")
        // A run that opened no page, or of other tools, is only its count; a command titled like a click is not one.
        #expect(ToolTally.line(Array(calls.dropFirst())) == "Preencheu 1 campo, clicou 2 vezes e fez 1 outra ação")
        #expect(ToolTally.line([call("Clicando em Salvar", .computer)]) == "Fez 1 ação")
    }

    @Test func failuresAreSaidAndTheTimeIsTheWholeRunsOnceItEnds() {
        let start = Date(timeIntervalSince1970: 1_000)
        var first = call("Rodando no Terminal")
        first.startedAt = start
        first.finishedAt = start.addingTimeInterval(1)
        var second = call("Rodando no Terminal", .shell, .failed)
        second.startedAt = start.addingTimeInterval(0.5)
        second.finishedAt = start.addingTimeInterval(2.5)
        #expect(ToolTally.failures([first, second]) == "1 falhou")
        #expect(ToolTally.failures([second, second]) == "2 falharam")
        #expect(ToolTally.failures([first]) == nil)
        #expect(ToolTally.span([first, second]) == 2.5)
        #expect(ToolTally.span([first, call("Rodando no Terminal", .shell, .running)]) == nil)
    }

    @Test func theSymbolIsTheActionsWhenTheyAreOfOneKind() {
        #expect(ToolTally.symbol([call("Rodando no Terminal"), call("Rodando no Terminal")]) == ToolCall.Kind.shell.symbol)
        #expect(ToolTally.symbol([call("Rodando no Terminal"), call("Lendo arquivo", .file)]) == "rectangle.stack")
    }
}
