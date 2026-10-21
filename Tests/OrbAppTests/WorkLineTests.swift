import Foundation
import Observation
import SwiftUI
import Testing
@testable import Orb

/// What the Orb says it is doing while a turn runs: the phrase for each tool, the minimum time each phrase stays, the
/// count of actions, and when VoiceOver hears it.
struct WorkPhraseTests {
    @Test func onlyARunningCommandBreathes() {
        #expect(WorkLine(verb: "Rodando", target: "swift build", style: .code).runsCommand)
        #expect(WorkLine(verb: "Rodando em segundo plano", target: "npm run dev", style: .code).runsCommand)
        #expect(!WorkLine(verb: "Lendo", target: "README.md", style: .code).runsCommand)
        #expect(!WorkLine(verb: "Rodando", target: "rm -rf build", style: .code, tone: .waiting).runsCommand)
    }

    private func line(_ title: String, _ detail: String, kind: ToolCall.Kind = .shell) -> WorkLine {
        WorkPhrase.line(for: ToolCall(kind: kind, title: title, detail: detail))
    }

    @Test func aCommandIsRunWithWhatItDoesAsTheTarget() {
        let run = line("Rodando no Terminal", "swift build --jobs 6 | tail -5")
        #expect(run.verb == "Rodando" && run.target == "swift build" && run.style == .code)
        #expect(run.text == "Rodando swift build")
        let background = line("Rodando em segundo plano", "npm run dev")
        #expect(background.verb == "Rodando em segundo plano" && background.target == "npm run dev")
    }

    @Test func theHeadlineSaysACommandWithoutWritingItOut() {
        #expect(line("Rodando no Terminal", "docker exec app python -c \"x\"").headline == "Rodando um comando")
        #expect(line("Rodando em segundo plano", "npm run dev").headline == "Rodando um comando em segundo plano")
        #expect(line("Lendo arquivo", "/Users/x/README.md", kind: .file).headline == "Lendo README.md")
        #expect(WorkLine(verb: "Pensando").headline == "Pensando…")
        var routine = line("Rodando no Terminal", "swift build")
        routine.routine = "Rodada WhatsApp"
        #expect(routine.headline == "Rotina “Rodada WhatsApp” · Rodando um comando")
        #expect(routine.text == "Rotina “Rodada WhatsApp”: Rodando swift build", "the working line still writes it out")
        let request = WorkLine(verb: "Lendo", target: "README.md", style: .code, prefix: "Pedido de Atlas")
        #expect(request.headline == "Pedido de Atlas · Lendo README.md")
    }

    @Test func onlyTheFirstLineOfTheDetailCountsAndItsWhiteSpaceIsCollapsed() {
        #expect(line("Rodando no Terminal", "git log   --oneline\n  | head -5\nmais").target == "git log")
        #expect(line("Rodando no Terminal", "\n\n   make\ttest  \n").target == "make test")
        // The note a command run elsewhere carries is not the target.
        #expect(line("Rodando no Terminal", "ls -la\n\nem ~/Projetos").target == "ls")
        #expect(WorkPhrase.firstLine(of: "x".padding(toLength: 300, withPad: "x", startingAt: 0))?.count == WorkPhrase.targetLimit + 1)
    }

    @Test func aLongTargetLosesItsMiddle() {
        let query = "swift build jobs configuration release product Orb scratch path build directory with a long name"
        let long = line("Pesquisando na web", query, kind: .search)
        let shown = long.shownTarget ?? ""
        #expect(shown.hasPrefix("“swift build jobs configurat") && shown.hasSuffix("ctory with a long name”") && shown.contains("…"))
        #expect(long.target == WorkPhrase.firstLine(of: query), "the value itself is whole")
        #expect(line("Rodando no Terminal", "ls").shownTarget == "ls")
    }

    @Test func filesAreNamedByTheirLastComponent() {
        #expect(line("Lendo arquivo", "/Users/x/Projetos/Orb/README.md", kind: .file).text == "Lendo README.md")
        #expect(line("Lendo caderno", "analise.ipynb", kind: .file).text == "Lendo analise.ipynb")
        #expect(line("Editando arquivo", "Sources/Orb/ChatView.swift\nTodas as ocorrências\n- a\n+ b", kind: .file).text == "Editando ChatView.swift")
        #expect(line("Gravando arquivo", "/tmp/notas.md\nNovo arquivo\n\nconteúdo", kind: .file).text == "Gravando notas.md")
        #expect(line("Lendo arquivo", "/Users/x/README.md", kind: .file).style == .code)
    }

    @Test func foldersAreNamedAndTheHomeFolderIsATilde() {
        #expect(line("Listando pasta", "/Users/x/Projetos/Orb/", kind: .file).text == "Abrindo a pasta Orb")
        #expect(line("Listando pasta", NSHomeDirectory(), kind: .file).text == "Abrindo a pasta ~")
        #expect(line("Listando pasta", "~", kind: .file).text == "Abrindo a pasta ~")
        #expect(line("Listando pasta", "", kind: .file).text == "Abrindo a pasta…")
    }

    @Test func searchesQuoteTextAndKeepPatternsAsCode() {
        let glob = line("Procurando arquivos", "**/*.swift", kind: .search)
        #expect(glob.text == "Procurando **/*.swift" && glob.style == .code)
        // A Spotlight query in words is a phrase, not code; a bare name or a pattern stays code.
        let query = line("Procurando arquivos", "relatório de vendas", kind: .search)
        #expect(query.text == "Procurando “relatório de vendas”" && query.style == .quoted)
        #expect(line("Procurando arquivos", "Package.swift", kind: .search).style == .code)
        #expect(line("Procurando arquivos", "src/*.swift test", kind: .search).style == .code)
        let grep = line("Buscando no conteúdo", "TODO", kind: .search)
        #expect(grep.text == "Procurando “TODO”" && grep.style == .quoted && grep.target == "TODO")
    }

    @Test func theWebIsNamedByItsHostOrItsQuery() {
        #expect(line("Lendo página", "https://www.github.com/x/y?tab=readme", kind: .browser).text == "Abrindo github.com")
        #expect(line("Abrindo página", "https://www.gympass.com/login", kind: .browser).text == "Abrindo gympass.com")
        #expect(line("Abrindo uma aba", "https://example.com/a", kind: .browser).text == "Abrindo example.com")
        #expect(line("Baixando arquivo", "https://example.com/a.zip\n→ ~/Downloads", kind: .browser).text == "Baixando de example.com")
        #expect(line("Pesquisando na web", "swiftui shimmer", kind: .browser).text == "Pesquisando “swiftui shimmer”")
        #expect(line("Delegando a um subagente", "revisar o diff", kind: .computer).text == "Delegando “revisar o diff”")
        // What is not a URL stays as it is.
        #expect(WorkPhrase.host(of: "não é endereço") == "não é endereço")
    }

    @Test func theTodoListSaysTheStepUnderWay() {
        let step = line("Atualizando a lista de tarefas", "Rodando os testes", kind: .computer)
        #expect(step.verb == "Rodando os testes" && step.target == nil && step.text == "Rodando os testes…")
        #expect(line("Atualizando a lista de tarefas", "", kind: .computer).text == "Atualizando a lista de tarefas…")
    }

    @Test func aToolThatNamesItsOwnTargetOrIsUnknownSaysItsTitle() {
        #expect(line("Clicando em Salvar", "botão", kind: .computer).text == "Clicando em Salvar…")
        #expect(line("Usando github", "list_issues {}", kind: .connector).text == "Usando github…")
        #expect(line("Guardando na memória (preferência)", "gosta de café", kind: .memory).target == nil)
    }

    @Test func aMissingTargetIsJustTheVerb() {
        let empty = line("Rodando no Terminal", "")
        #expect(empty.target == nil && empty.text == "Rodando…")
        #expect(line("Lendo arquivo", "   \n", kind: .file).text == "Lendo…")
    }

    @Test func statusesWithoutAToolAreWorkingExceptTheWaits() {
        let thinking = WorkPhrase.line(status: "Pensando")
        #expect(thinking.text == "Pensando…" && thinking.shimmers && thinking.tone == .working)
        #expect(WorkPhrase.line(status: "Escrevendo").text == "Escrevendo…")
        let waiting = WorkPhrase.line(status: "Esperando sua resposta")
        #expect(waiting.tone == .waiting && waiting.text == "Esperando sua resposta" && !waiting.shimmers)
    }

    @Test func aWaitBeforeTryingAgainCountsDownFromTheSeconds() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        for (error, cause) in [(LLMError.network(code: -1009, message: "x") as Error, "Conexão caiu"),
                               (LLMError.http(status: 429, message: "") as Error, "Limite do provedor"),
                               (LLMError.http(status: 503, message: "") as Error, "Provedor ocupado")] {
            let status = Retry.waitStatus(seconds: 8, after: error)
            let parsed = try #require(Retry.parseWaitStatus(status))
            #expect(parsed.cause == cause && parsed.seconds == 8)
            let line = WorkPhrase.line(status: status, now: now)
            #expect(line.text == "\(cause) · tentando de novo" && !line.shimmers)
            #expect(line.tone == .retrying(until: now.addingTimeInterval(8)))
        }
        #expect(Retry.parseWaitStatus("Pensando") == nil)
        #expect(Retry.parseWaitStatus("Conexão caiu, tentando de novo em x s") == nil)
    }

    @Test func aRoutinePutsItsNameInFrontOfThePhrase() {
        var line = WorkPhrase.line(status: "Pensando")
        line.routine = "Resumo diário"
        #expect(line.text == "Rotina “Resumo diário”: Pensando…" && line.phrase == "Pensando…")
    }

    @Test func thePhraseKeyIgnoresWhatDoesNotChangeTheWords() {
        let base = WorkLine(verb: "Lendo", target: "a.swift", style: .code)
        var counted = base
        counted.actions = 4
        counted.routine = "x"
        #expect(base.phraseKey == counted.phraseKey)
        #expect(base.phraseKey != WorkLine(verb: "Lendo", target: "b.swift", style: .code).phraseKey)
        let later = Date(timeIntervalSinceReferenceDate: 50)
        #expect(WorkLine(verb: "Sem rede", tone: .retrying(until: later)).phraseKey
                == WorkLine(verb: "Sem rede", tone: .retrying(until: later.addingTimeInterval(8))).phraseKey)
    }

    @Test func theMeterShowsTheClockAndFromTheSecondActionTheCount() {
        #expect(WorkMeter.text(elapsed: "", actions: 0) == "")
        #expect(WorkMeter.text(elapsed: "16 s", actions: 0) == "16 s")
        #expect(WorkMeter.text(elapsed: "16 s", actions: 1) == "16 s")
        #expect(WorkMeter.text(elapsed: "16 s", actions: 3) == "16 s · 3 ações")
        #expect(WorkMeter.text(elapsed: "", actions: 2) == "2 ações")
        let now = Date(timeIntervalSinceReferenceDate: 100)
        #expect(WorkMeter.countdown(until: now.addingTimeInterval(7.2), now: now) == "em 8 s")
        #expect(WorkMeter.countdown(until: now.addingTimeInterval(-1), now: now) == "")
    }
}

struct StatusDwellTests {
    private let start = ContinuousClock.now
    private func line(_ verb: String) -> WorkLine { WorkLine(verb: verb) }

    @Test func theFirstPhraseOfATurnShowsAtOnce() {
        var dwell = StatusDwell(minDwell: .milliseconds(700))
        let verdict = dwell.offer(line("Pensando"), at: start)
        #expect(verdict == .now)
        #expect(dwell.shown == line("Pensando") && dwell.due == nil)
    }

    @Test func aPhraseThatComesTooSoonWaitsForTheTimeOfTheOneOnScreen() {
        var dwell = StatusDwell(minDwell: .milliseconds(700))
        _ = dwell.offer(line("Pensando"), at: start)
        let ready = start + .milliseconds(700)
        let early = dwell.offer(line("Lendo"), at: start + .milliseconds(100))
        #expect(early == .at(ready))
        #expect(dwell.shown == line("Pensando") && dwell.due == ready)
        let tooSoon = dwell.release(at: start + .milliseconds(699))
        #expect(tooSoon == nil)
        let released = dwell.release(at: ready)
        #expect(released == line("Lendo"))
        #expect(dwell.shown == line("Lendo") && dwell.due == nil)
        // The new phrase's own time starts when it came in.
        let next = dwell.offer(line("Procurando"), at: ready + .milliseconds(100))
        #expect(next == .at(ready + .milliseconds(700)))
    }

    @Test func ofSeveralThatComeTooSoonOnlyTheNewestComesIn() {
        var dwell = StatusDwell(minDwell: .milliseconds(700))
        _ = dwell.offer(line("Pensando"), at: start)
        for (index, verb) in ["Lendo", "Pensando 2", "Procurando"].enumerated() {
            _ = dwell.offer(line(verb), at: start + .milliseconds(100 * (index + 1)))
        }
        let released = dwell.release(at: start + .milliseconds(700))
        #expect(released == line("Procurando"))
        let again = dwell.release(at: start + .seconds(5))
        #expect(again == nil)
    }

    @Test func aPhraseAfterItsTimeShowsAtOnce() {
        var dwell = StatusDwell(minDwell: .milliseconds(700))
        _ = dwell.offer(line("Pensando"), at: start)
        let verdict = dwell.offer(line("Lendo"), at: start + .milliseconds(700))
        #expect(verdict == .now && dwell.shown == line("Lendo"))
    }

    @Test func theEndOfTheTurnAndTheWaitForYouDoNotWait() {
        var dwell = StatusDwell(minDwell: .seconds(10))
        _ = dwell.offer(line("Pensando"), at: start)
        let waiting = WorkLine(verb: "Esperando sua resposta", tone: .waiting)
        let wait = dwell.offer(waiting, at: start + .milliseconds(10))
        #expect(wait == .now && dwell.shown == waiting)
        // Leaving the wait is as quick: the answer was just given.
        let answered = dwell.offer(line("Rodando"), at: start + .milliseconds(20))
        #expect(answered == .now)
        let ended = dwell.offer(nil, at: start + .milliseconds(30))
        #expect(ended == .now && dwell.shown == nil && dwell.due == nil)
        // And the next turn's first phrase shows at once as well.
        let next = dwell.offer(line("Pensando"), at: start + .milliseconds(40))
        #expect(next == .now)
    }

    @Test func theSamePhraseDoesNothingAndCancelsAPendingOne() {
        var dwell = StatusDwell(minDwell: .milliseconds(700))
        _ = dwell.offer(line("Pensando"), at: start)
        let same = dwell.offer(line("Pensando"), at: start + .milliseconds(50))
        #expect(same == .unchanged)
        let ended = dwell.offer(nil, at: start)
        #expect(ended == .now)
        let nothing = dwell.offer(nil, at: start)
        #expect(nothing == .unchanged)
        _ = dwell.offer(line("Pensando"), at: start)
        _ = dwell.offer(line("Lendo"), at: start + .milliseconds(100))
        // Back to what is on screen before its time: nothing is left to show.
        let back = dwell.offer(line("Pensando"), at: start + .milliseconds(200))
        #expect(back == .unchanged && dwell.due == nil)
    }
}

struct WorkAnnouncerTests {
    private let start = ContinuousClock.now

    @Test func onlyPhrasesThatNameSomethingAreAnnounced() {
        var announcer = WorkAnnouncer()
        let thinking = announcer.shouldAnnounce(WorkPhrase.line(status: "Pensando"), at: start)
        let writing = announcer.shouldAnnounce(WorkPhrase.line(status: "Escrevendo"), at: start)
        let waiting = announcer.shouldAnnounce(WorkPhrase.line(status: "Esperando sua resposta"), at: start)
        let untargeted = announcer.shouldAnnounce(WorkLine(verb: "Usando github"), at: start)
        #expect(!thinking && !writing && !waiting && !untargeted)
        let named = announcer.shouldAnnounce(WorkLine(verb: "Rodando", target: "swift build", style: .code), at: start)
        #expect(named)
    }

    @Test func atMostOneEveryEightSeconds() {
        var announcer = WorkAnnouncer()
        let read = WorkLine(verb: "Lendo", target: "a.swift", style: .code)
        let first = announcer.shouldAnnounce(read, at: start)
        let soon = announcer.shouldAnnounce(read, at: start + .seconds(3))
        let almost = announcer.shouldAnnounce(read, at: start + .milliseconds(7999))
        let later = announcer.shouldAnnounce(read, at: start + .seconds(8))
        #expect(first && !soon && !almost && later)
        // A phrase that is not announced does not use the turn.
        let thinking = announcer.shouldAnnounce(WorkPhrase.line(status: "Pensando"), at: start + .seconds(9))
        #expect(!thinking)
        announcer.reset()
        let afterReset = announcer.shouldAnnounce(read, at: start + .seconds(9))
        #expect(afterReset)
    }
}

/// What the Orb's `BotLive` and session do with the phrases through a turn.
@Suite final class WorkLineFlowTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbWork-\(UUID().uuidString)")
    deinit { removeTestFolder(root) }

    @MainActor private func model() -> AppModel {
        var state = AppState.initial
        state.routines = [Routine(name: "Resumo diário", botID: state.bots[0].id, prompt: "x", schedule: .everyHours(1))]
        Store(directory: root).save(state)
        return AppModel(store: Store(directory: root), runsBackgroundWork: false)
    }

    private func shell(_ command: String) -> ToolCall { ToolCall(kind: .shell, title: "Rodando no Terminal", detail: command) }



    @Test @MainActor func aToolStartedAndItsStatusGiveOneStepWithItsTarget() {
        let model = model()
        let id = model.bots[0].id
        let live = model.live(id)
        model.apply(.status("Pensando"), to: id)
        #expect(live.work?.text == "Pensando…")
        live.setWorkDwell(.zero)
        model.apply(.toolStarted(shell("swift build")), to: id)
        model.apply(.status("Rodando no Terminal"), to: id)
        #expect(live.work?.verb == "Rodando" && live.work?.target == "swift build" && live.work?.actions == 1)
        #expect(live.status == "Rodando no Terminal") // the raw status is as it was
    }

    @Test @MainActor func aNewTurnStartsTheAnnouncerFromZero() {
        let model = model()
        let id = model.bots[0].id
        let read = WorkLine(verb: "Lendo", target: "a.swift", style: .code)
        let now = ContinuousClock.now
        let first = model.workAnnouncer.shouldAnnounce(read, at: now)
        let soon = model.workAnnouncer.shouldAnnounce(read, at: now + .seconds(1))
        _ = model.session(id).beginTurn()
        let afterBegin = model.workAnnouncer.shouldAnnounce(read, at: now + .seconds(2))
        #expect(first && !soon && afterBegin)
    }

    @Test @MainActor func aPhraseThatComesTooSoonWaitsAndOnlyTheNewestIsShown() async throws {
        let model = model()
        let id = model.bots[0].id
        let live = model.live(id)
        live.setWorkDwell(.milliseconds(60))
        // Events reach a loaded conversation, as in a real turn (send loads it first): a first load landing between
        // the steps would close the "turn" this test plays by hand.
        await model.loadedConversation(id)
        model.apply(.status("Pensando"), to: id)
        let first = shell("ls"), second = shell("grep x")
        model.apply(.toolStarted(first), to: id)
        model.apply(.toolFinished(id: first.id, state: .done, output: ""), to: id)
        model.apply(.status("Pensando"), to: id)
        model.apply(.toolStarted(second), to: id)
        #expect(live.work?.text == "Pensando…", "the first phrase stays its time")
        await waitUntil("the newest phrase") { live.work?.target == "grep x" }
        #expect(live.work?.actions == 2, "the count of actions comes with the phrase")
    }

    @Test @MainActor func theEndOfTheTurnClearsThePhraseAtOnceAndTheNextTurnStartsCounting() {
        let model = model()
        let id = model.bots[0].id
        model.providers = [ProviderAccount(kind: .custom)] // usable but without a client: the turn fails at once
        model.defaultModel = "custom/modelo"
        let live = model.live(id)
        live.setWorkDwell(.seconds(60))
        #expect(model.send("oi", to: id))
        #expect(live.work?.text == "Pensando…")
        model.apply(.toolStarted(shell("ls")), to: id)
        model.apply(.toolStarted(shell("pwd")), to: id)
        #expect(model.session(id).actionsThisTurn == 2 && live.work?.text == "Pensando…", "the phrase has its time")

        model.stop(id)
        #expect(live.work == nil && live.status == nil, "the end does not wait for the phrase on screen")
        #expect(model.session(id).actionsThisTurn == 0 && model.session(id).runningCalls.isEmpty)
        #expect(model.send("de novo", to: id))
        #expect(live.work?.actions == 0 && live.work?.text == "Pensando…")
    }

    @Test @MainActor func aWaitForYouShowsAtOnceAndIsNotAnAction() {
        let model = model()
        let id = model.bots[0].id
        let live = model.live(id)
        live.setWorkDwell(.seconds(60))
        model.apply(.status("Pensando"), to: id)
        model.apply(.status("Esperando sua resposta"), to: id)
        #expect(live.work?.tone == .waiting && live.work?.actions == 0)
        model.apply(.toolStarted(shell("rm x")), to: id)
        #expect(live.work?.target == "rm x" && live.work?.actions == 1, "the answer ends the wait at once")
    }

    @Test @MainActor func aRoutineRunsWithItsNameInTheText() {
        let model = model()
        let id = model.bots[0].id
        model.session(id).routineID = model.routines[0].id
        model.apply(.status("Pensando"), to: id)
        #expect(model.live(id).work?.routine == "Resumo diário")
        #expect(model.live(id).work?.text == "Rotina “Resumo diário”: Pensando…")
        #expect(model.live(id).status == "Rotina “Resumo diário”: Pensando")
    }

    @Test @MainActor func aBurstOfTextAndRepeatedStatusesNotifyNobodyWhoReadsThePhrase() {
        let model = model()
        let id = model.bots[0].id
        let live = model.live(id)
        model.apply(.status("Pensando"), to: id)
        let quiet = notifies(reading: { _ = live.work }, whenYouDo: {
            for _ in 0..<50 { model.apply(.text("palavra "), to: id) }
            model.apply(.status("Pensando"), to: id)
        })
        #expect(!quiet)
        // A step that changes the phrase does (here, after its time).
        live.setWorkDwell(.zero)
        let changed = notifies(reading: { _ = live.work }, whenYouDo: { model.apply(.status("Escrevendo"), to: id) })
        #expect(changed)
    }
}

/// The phrase of the working line gives way to a narrow column instead of running past it (and pushing the
/// "Ver pedido" button out of sight).
struct WorkPhraseLayoutTests {
    @MainActor private func width(of line: WorkLine, offered: CGFloat) -> CGFloat {
        NSHostingController(rootView: WorkPhraseView(work: line)).sizeThatFits(in: CGSize(width: offered, height: 100)).width
    }

    @MainActor @Test func aLongRoutineNameAndAWaitingVerbAreCutToTheColumn() {
        let waiting = WorkLine(verb: "Esperando sua resposta", tone: .waiting, routine: String(repeating: "x", count: 80))
        #expect(width(of: waiting, offered: 240) <= 240)
        let plain = WorkLine(verb: "Esperando sua resposta", tone: .waiting)
        #expect(width(of: plain, offered: 80) <= 80)
    }

    @MainActor @Test func aPhraseThatFitsKeepsItsWords() {
        // Offered more than it needs, the phrase takes exactly its ideal width: nothing is cut or squeezed.
        let line = WorkLine(verb: "Lendo", target: "README.md")
        let ideal = width(of: line, offered: 4_000)
        #expect(width(of: line, offered: 400) == ideal)
        let waiting = WorkLine(verb: "Esperando sua resposta", tone: .waiting, routine: "Resumo")
        #expect(width(of: waiting, offered: 600) == width(of: waiting, offered: 4_000))
        // ...and given less than it needs, it gives way instead of overflowing.
        #expect(width(of: line, offered: ideal - 20) < ideal)
    }
}
