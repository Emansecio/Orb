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

    @Test func actionsOneAfterAnotherFoldIntoOneRowAndALoneOneStaysALine() {
        let ask = TranscriptItem(.user(text: "Levante os leads", attachments: []))
        let read = tool("Lendo arquivo", .file)
        let runs = [tool(), tool(), tool()]
        let lone = tool()
        let items = [ask, read] + runs + [say("A fila trouxe 61 conversas."), lone, say("Pronto.")]
        #expect(TranscriptFolding.rows(for: items) == [
            .single(ask), .tools([read] + runs), .single(items[5]), .single(lone), .single(items[7]),
        ])
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

    @Test func onlyTwoActionsInARowMakeAChatFold() {
        #expect(!TranscriptFolding.hasFoldableItems([tool(), say("oi"), tool()]))
        #expect(TranscriptFolding.hasFoldableItems([say("oi"), tool(), tool()]))
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
