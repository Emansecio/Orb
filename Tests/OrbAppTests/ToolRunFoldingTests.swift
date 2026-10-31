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
        // A request without an answer, nor a notice of how it ended: its actions one line per run.
        #expect(TranscriptFolding.rows(for: items) == [.single(ask), .tools([read] + runs), .single(items[5]), .single(lone)])
    }

    @Test func aFinishedRequestFoldsItsWorkAndKeepsItsAnswer() {
        let request = ask()
        let work = [tool("Lendo arquivo", .file), tool(), say("A fila trouxe 61 conversas."), tool(), tool()]
        let answer = say("Respondi os 12 leads pendentes.")
        let items = [request] + work + [answer]
        #expect(TranscriptFolding.rows(for: items) == [.single(request), .work(work, seconds: nil), .single(answer)])
        // While it runs the request is one activity block, with its progress and actions still available.
        #expect(TranscriptFolding.rows(for: items, liveTail: true)
                == [.single(request), .activity(work + [answer])])
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
        #expect(ToolTally.work(calls, seconds: 65) == "Trabalhou por 1 min 05 s · 12 ações")
        #expect(ToolTally.work(calls, seconds: nil) == "Trabalhou · 12 ações")
        // Actions all of one named kind say what they were.
        #expect(ToolTally.work(Array(calls.prefix(11)), seconds: nil) == "Trabalhou · rodou 11 comandos")
        #expect(ToolTally.work([call("Usando github", .connector)], seconds: nil) == "Trabalhou · 1 ação")
    }

    @Test func theWorkSaysHowTheRequestEnded() {
        let calls = [call("Rodando no Terminal"), call("Lendo arquivo", .file)]
        #expect(ToolTally.work(calls, seconds: 40, outcome: .appClosed) == "Interrompido após 40 s (app fechado) · 2 ações")
        #expect(ToolTally.work(calls, seconds: nil, outcome: .appClosed) == "Interrompido (app fechado) · 2 ações")
        #expect(ToolTally.work(calls, seconds: 40, outcome: .stopped) == "Você interrompeu após 40 s · 2 ações")
        #expect(ToolTally.work(calls, seconds: 40, outcome: .failed) == "Não deu certo após 40 s · 2 ações")
        #expect(ToolTally.work(calls, seconds: nil, outcome: .paused) == "Pausou · 2 ações")
        #expect(ToolTally.work([], seconds: 40, outcome: .failed) == "Não deu certo após 40 s")
    }

    @Test func aRunningActivityKeepsPendingCardsVisibleWithinItsSteps() {
        let request = ask()
        let work = [tool(), say("Preciso de permissão."), tool()]
        let waiting = card(nil)
        let last = tool()
        let rows = TranscriptFolding.rows(for: [request] + work + [waiting, last], liveTail: true)
        #expect(rows.first == .single(request))
        #expect(rows == [.single(request), .activity(work + [waiting, last])])
        let steps = TranscriptFolding.activityRows(for: work + [waiting])
        #expect(steps.contains(.single(waiting)), "a request for the user is never behind a disclosure")
        // Even a single run shares the activity block with the working line and the plan.
        let run = [tool(), tool()]
        #expect(TranscriptFolding.rows(for: [request] + run, liveTail: true) == [.single(request), .activity(run)])
    }

    @Test func progressAndItsActionsAreOneStepAndTheLatestWordsStayVisible() {
        let intro = say("Vou conferir a rotina ativa.")
        let first = tool("Lendo arquivo", .file), second = tool()
        let progress = say("A rotina já está em intervalos de 30 minutos.")
        let third = tool(), latest = say("Agora vou conferir os pagamentos.")
        let items = [intro, first, second, progress, third, latest]
        let steps = TranscriptFolding.activityRows(for: items)
        #expect(steps == [.tools([intro, first, second]), .tools([progress, third]), .single(latest)])
        #expect(TranscriptFolding.activityRows(for: items + [tool()]).first?.id == intro.id)
        #expect(steps.flatMap(\.items) == items, "the original text and every action remain available in order")
    }

    @Test func anActivityNeverTakesAnotherRequestOrCrossesACompaction() {
        let request = ask(), first = tool(), second = tool()
        let next = ask("Confira os pagamentos também", duringTask: true)
        let items = [request, first, next, second]
        #expect(TranscriptFolding.rows(for: items, liveTail: true)
                == [.single(request), .single(first), .single(next), .activity([second])])
        #expect(!TranscriptFolding.rows(for: [request, first, second], boundary: 2, liveTail: true)
            .contains { if case .activity = $0 { true } else { false } })
    }

    @Test func noticesAndBrowserCardsStayVisibleAndKeepTheirOrder() {
        let intro = say("Conferindo os pagamentos.")
        let browser = TranscriptItem(.browserView(BrowserViewItem(host: "example.com", startedAt: .now, actions: 1)))
        let notice = TranscriptItem(.notice("A conexão foi retomada."))
        let first = tool(), second = tool()
        let items = [intro, first, browser, notice, second]
        let steps = TranscriptFolding.activityRows(for: items)
        #expect(steps == [.tools([intro, first]), .single(browser), .single(notice), .tools([second])])
        #expect(steps.flatMap(\.items) == items)
    }

    @Test func aRunningBlockFoldsEarlierStepsAndKeepsTheLatestAndWhatMustNotHide() {
        let first = say("Um"), action = TranscriptItem(.tool(call("Lendo"))), notice = TranscriptItem(.notice("Aviso"))
        let second = say("Dois"), other = TranscriptItem(.tool(call("Buscando"))), third = say("Três"), last = TranscriptItem(.tool(call("Rodando")))
        let steps = TranscriptFolding.activityRows(for: [first, action, notice, second, other, third, last])
        let parts = TranscriptFolding.activityParts(steps)
        #expect(parts.earlier.flatMap(\.items).map(\.id) == [first, action, second, other].map(\.id))
        #expect(parts.current.flatMap(\.items).map(\.id) == [notice, third, last].map(\.id))
    }

    @Test func proposalsOneAfterAnotherShareARowAndALoneOneStays() {
        let one = TranscriptItem(.notice("Melhoria proposta para /a")), two = TranscriptItem(.notice("Skill proposta: /b — B"))
        let rows = TranscriptFolding.rows(for: [one, two, say("Oi"), TranscriptItem(.notice("Melhoria proposta para /c"))])
        #expect(rows.count == 3)
        if case .proposals(let items) = rows[0] { #expect(items.map(\.id) == [one.id, two.id]) } else { Issue.record("not joined") }
        if case .single = rows[2] {} else { Issue.record("a lone proposal keeps its button") }
    }

    @Test func aRunningBlockWithOneStepHasNothingToFold() {
        let steps = TranscriptFolding.activityRows(for: [say("Um"), TranscriptItem(.tool(call("Lendo")))])
        let parts = TranscriptFolding.activityParts(steps)
        #expect(parts.earlier.isEmpty)
        #expect(parts.current == steps)
    }

    @Test func aStepNamesItsPurposeAndDoesNotClaimAFailureSucceeded() {
        let intro = say("Vou revisar a rotina.")
        var action = call("Rodando no Terminal")
        action.intent = "Atualizar intervalo da rotina"
        let item = TranscriptItem(.tool(action))
        #expect(ToolTally.stepVariants([intro, item]) == ["Atualizou intervalo da rotina"])
        action.state = .running
        #expect(ToolTally.stepVariants([intro, TranscriptItem(.tool(action))]) == ["Atualizando intervalo da rotina"])
        action.state = .failed
        #expect(ToolTally.stepVariants([intro, TranscriptItem(.tool(action))]) == ["Falhou ao atualizar intervalo da rotina"])
        #expect(ToolTally.stepVariants([intro, tool()]) == ["Vou revisar a rotina"])
        #expect(ToolTally.stepVariants([tool()]) == ["Ações concluídas"])
    }

    @Test func aRequestThatEndedWithoutAnAnswerFoldsAndSaysHowItEnded() {
        let quit = TranscriptItem(.notice(BotSession.quitNotice))
        let work = [say("Rodando o sweep."), tool(), say("Lead quente: Glauciane."), tool()]
        let next = ask("respondeu todos?")
        // Not the chat's last item: the notice goes inside the work, whose line says it.
        let rows = TranscriptFolding.rows(for: [ask()] + work + [quit, next])
        #expect(rows.dropFirst().first == .work(work + [quit], seconds: nil, outcome: .appClosed))
        #expect(rows.last == .single(next))
        // The chat's last item: the notice stays in view after the line, with its "Continuar".
        let last = TranscriptFolding.rows(for: [ask()] + work + [quit])
        #expect(Array(last.suffix(2)) == [.work(work, seconds: nil, outcome: .appClosed), .single(quit)])
        // Opened, its items are drawn as they were: they do not fold into the line again.
        #expect(!TranscriptFolding.rows(for: work + [quit], foldsWork: false).contains { if case .work = $0 { true } else { false } })
        #expect(TranscriptFolding.rows(for: work + [quit]).contains { if case .work = $0 { true } else { false } },
                "what the flag guards against")
        // A notice that does not end a request (a memory kept along the way) keeps the request unfolded.
        let kept = TranscriptItem(.notice("\(NoticeAction.keptMemoryPrefix) prefere Pix"))
        #expect(!TranscriptFolding.rows(for: [ask()] + work + [kept]).contains { if case .work = $0 { true } else { false } })
        // Something done after the notice: not how the request ended.
        #expect(!TranscriptFolding.rows(for: [ask()] + work + [quit, tool()]).contains { if case .work = $0 { true } else { false } })
    }

    @Test func eachEndingNoticeSaysItsOutcome() {
        func outcome(_ text: String) -> WorkOutcome? { WorkOutcome(ending: TranscriptItem(.notice(text))) }
        #expect(outcome(BotSession.quitNotice) == .appClosed)
        #expect(outcome(BotSession.quitSideNotice) == .appClosed)
        #expect(outcome(BotSession.stoppedNotice) == .stopped)
        #expect(outcome(NoticeAction.failurePrefix + "o provedor caiu.") == .failed)
        #expect(outcome(AgentEngine.pausedNotice(after: 40)) == .paused)
        #expect(outcome("Compactei a conversa: os 2 primeiros pedidos viraram um resumo.") == nil)
        #expect(WorkOutcome(ending: say("Pronto.")) == nil)
    }

    @Test func anInterruptedRequestTakesTheTimeOfItsLastActionNotOfTheNotice() {
        let start = Date(timeIntervalSince1970: 1_000)
        var request = ask()
        request.date = start
        var first = tool()
        first.date = start.addingTimeInterval(5)
        var lastCall = call("Rodando no Terminal", .shell, .failed)
        lastCall.startedAt = start.addingTimeInterval(30)
        lastCall.finishedAt = start.addingTimeInterval(70)
        var last = TranscriptItem(.tool(lastCall))
        last.date = start.addingTimeInterval(30)
        var quit = TranscriptItem(.notice(BotSession.quitNotice))
        quit.date = start.addingTimeInterval(8 * 3_600) // written at the next launch
        var said = say("Lendo.")
        said.date = start.addingTimeInterval(20)
        let rows = TranscriptFolding.rows(for: [request, first, said, last, quit])
        #expect(rows[1] == .work([first, said, last], seconds: 70, outcome: .appClosed))
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
        // The run ended on an action that worked: the Orb got over it, so the mark is quiet. Ended on a failure: red.
        #expect(ToolTally.failures([second, first]) == ToolTally.Failures(text: "1 com erro", recovered: true))
        #expect(ToolTally.failures([first, second]) == ToolTally.Failures(text: "1 com erro", recovered: false))
        #expect(ToolTally.failures([second, second]) == ToolTally.Failures(text: "2 com erro", recovered: false))
        #expect(ToolTally.failures([second, call("Rodando no Terminal", .shell, .running)])?.recovered == true)
        #expect(ToolTally.failures([first]) == nil)
        #expect(ToolTally.span([first, second]) == 2.5)
        #expect(ToolTally.span([first, call("Rodando no Terminal", .shell, .running)]) == nil)
    }

    @Test func theSymbolIsTheActionsWhenTheyAreOfOneKind() {
        #expect(ToolTally.symbol([call("Rodando no Terminal"), call("Rodando no Terminal")]) == ToolCall.Kind.shell.symbol)
        #expect(ToolTally.symbol([call("Rodando no Terminal"), call("Lendo arquivo", .file)]) == "rectangle.stack")
    }
}
