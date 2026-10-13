import Foundation
import Testing
@testable import Orb

/// Goals tracked by routines: the progress line a run ends with, what it does to the goal and the routine, the prompt
/// that asks for it, files from before goals existed, and the empty chat's ideas that open the editor.
struct RoutineGoalTests {
    // MARK: The progress line

    @Test func theProgressLineIsReadWhateverItsCaseAccentsAndSpacing() {
        #expect(GoalCheck.parse("Movi 3 arquivos.\nProgresso: 35% · em dia · faltam 26 arquivos")
                == GoalCheck(progress: 35, status: .onTrack, note: "faltam 26 arquivos"))
        #expect(GoalCheck.parse("**PROGRESSO:** 35 % - Atencao - duas faturas sem comprovante")
                == GoalCheck(progress: 35, status: .attention, note: "duas faturas sem comprovante"))
        #expect(GoalCheck.parse("- progresso: 60% | ATENÇÃO") == GoalCheck(progress: 60, status: .attention))
        #expect(GoalCheck.parse("Progresso 40 · Em  dia.") == GoalCheck(progress: 40, status: .onTrack))
        #expect(GoalCheck.parse("Progresso: 7% · em dia · `nota`  ") == GoalCheck(progress: 7, status: .onTrack, note: "nota"))
    }

    @Test func aGoalReachedIsAlwaysAHundredAndANumberOverAHundredIsCapped() {
        #expect(GoalCheck.parse("Progresso: 90% · concluída · pronto") == GoalCheck(progress: 100, status: .done, note: "pronto"))
        #expect(GoalCheck.parse("Progresso: 100% · Concluido")?.status == .done)
        #expect(GoalCheck.parse("Progresso: 140% · em dia")?.progress == 100)
    }

    @Test func onlyTheReportsOwnLastLineClosesTheGoal() {
        // A quote or a code block is an example, not the report's line.
        #expect(GoalCheck.parse("> Progresso: 100% · concluída · exemplo anterior\nAinda falta verificar a entrega.") == nil)
        #expect(GoalCheck.parse("```\nProgresso: 100% · concluída\n```\nNão executei a tarefa.") == nil)
        #expect(GoalCheck.parse("Progresso: 40% · em dia\n> Progresso: 100% · concluída") == GoalCheck(progress: 40, status: .onTrack))
        // "Concluída" with more said after it is not the end: an earlier line stands, or none.
        #expect(GoalCheck.parse("Progresso: 100% · concluída\nAinda falta verificar a entrega.") == nil)
        #expect(GoalCheck.parse("Progresso: 60% · em dia\nProgresso: 100% · concluída\nFalta um detalhe.")?.progress == 60)
        #expect(GoalCheck.parse("Tudo pronto.\n\nProgresso: 100% · concluída · feito\n\n")?.status == .done)
        // A code block never closed hides nothing; one kind of fence does not close the other.
        #expect(GoalCheck.parse("```bash\nls\nProgresso: 30% · em dia")?.progress == 30)
        #expect(GoalCheck.parse("~~~\n```\nProgresso: 100% · concluída\n~~~\nFalta.") == nil)
    }

    @Test func theLastLineThatHasTheShapeWinsAndAnythingElseIsNoLine() {
        #expect(GoalCheck.parse("Progresso: 10% · em dia\nmais texto\nProgresso: 20% · atenção\nfim.")?.progress == 20)
        #expect(GoalCheck.parse("Fiz o que deu, sem novidades.") == nil)
        #expect(GoalCheck.parse("O progresso foi bom hoje, uns 30%.") == nil)
        #expect(GoalCheck.parse("Progresso: 30%") == nil, "no status word")
        #expect(GoalCheck.parse("Progresso: muito · em dia") == nil, "no number")
        #expect(GoalCheck.parse(nil) == nil && GoalCheck.parse("") == nil)
        let long = GoalCheck.parse("Progresso: 5% · em dia · " + String(repeating: "a", count: 400))
        #expect((long?.note.count ?? 0) <= GoalCheck.noteLimit)
    }

    // MARK: After a run

    private func routine(goal: RoutineGoal?) -> Routine {
        Routine(name: "Downloads", botID: UUID(), prompt: "arrume", schedule: .daily(hour: 18, minute: 0), goal: goal)
    }

    @Test func aRunsLineMovesTheGoal() throws {
        var routine = routine(goal: RoutineGoal(target: "Downloads em ordem"))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let check = routine.recordGoalCheck(from: "Movi 14 arquivos.\nProgresso: 35% · em dia · faltam 26", at: date)
        #expect(check == GoalCheck(progress: 35, status: .onTrack, note: "faltam 26"))
        #expect(routine.goal?.check == check && routine.goal?.updatedAt == date)
        #expect(routine.isEnabled)
    }

    @Test func aRunWithoutTheLineLeavesTheGoalWhereItWas() {
        let before = GoalCheck(progress: 35, status: .onTrack, note: "faltam 26")
        var routine = routine(goal: RoutineGoal(target: "x", check: before, updatedAt: .distantPast))
        #expect(routine.recordGoalCheck(from: "Hoje não consegui conferir.", at: .now) == nil)
        #expect(routine.goal?.check == before && routine.goal?.updatedAt == .distantPast)
        #expect(routine.isEnabled)
    }

    @Test func aGoalReachedPausesTheRoutine() {
        var routine = routine(goal: RoutineGoal(target: "x"))
        #expect(routine.recordGoalCheck(from: "Progresso: 100% · concluída · tudo em pastas", at: .now)?.status == .done)
        #expect(!routine.isEnabled)
        #expect(routine.goal?.check?.progress == 100)
    }

    @Test func aRoutineWithoutAGoalIgnoresTheLine() {
        var plain = routine(goal: nil)
        #expect(plain.recordGoalCheck(from: "Progresso: 100% · concluída", at: .now) == nil)
        #expect(plain.goal == nil && plain.isEnabled)
    }

    // MARK: Files and prompt

    @Test func routinesAndRunsWrittenBeforeGoalsStillLoadAndAGoalIsKept() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"Velha","botID":"\#(UUID().uuidString)","prompt":"p","schedule":{"everyHours":{"_0":2}},"runs":[{"date":0,"succeeded":true,"summary":"ok"}]}"#
        let old = try JSONDecoder().decode(Routine.self, from: Data(json.utf8))
        #expect(old.goal == nil && old.runs.count == 1 && old.runs[0].check == nil)

        var withGoal = old
        withGoal.goal = RoutineGoal(target: "meta", check: GoalCheck(progress: 40, status: .attention, note: "n"), updatedAt: Date(timeIntervalSince1970: 5))
        withGoal.runs[0].check = GoalCheck(progress: 40, status: .attention, note: "n")
        let back = try JSONDecoder().decode(Routine.self, from: JSONEncoder().encode(withGoal))
        #expect(back.goal == withGoal.goal && back.runs[0].check == withGoal.runs[0].check)

        // A status from a newer version reads as on track; a goal that cannot be read leaves a plain routine.
        let newer = #"{"botID":"\#(UUID().uuidString)","schedule":{"everyHours":{"_0":2}},"goal":{"target":"t","check":{"progress":10,"status":"stalled"}}}"#
        #expect(try JSONDecoder().decode(Routine.self, from: Data(newer.utf8)).goal?.check?.status == .onTrack)
        let broken = #"{"botID":"\#(UUID().uuidString)","schedule":{"everyHours":{"_0":2}},"goal":"texto"}"#
        #expect(try JSONDecoder().decode(Routine.self, from: Data(broken.utf8)).goal == nil)
    }

    @Test func thePromptHasTheGoalSectionOnlyWhenThereIsAGoal() {
        let plain = RoutinePrompt.unattended("faça X", routine: "Diária")
        #expect(!plain.contains("Goal of this routine") && !plain.contains("Progresso:"))

        let first = RoutinePrompt.unattended("faça X", routine: "Diária", goal: RoutineGoal(target: "Caixa\nzerada"))
        #expect(first.contains("Goal of this routine (what success looks like, in the user's words): Caixa zerada"))
        #expect(first.contains("No check yet"))
        #expect(first.contains("Progresso: <0-100>% · <em dia | atenção | concluída> · <nota curta>"))
        #expect(first.contains("safe and can be undone"))
        #expect(first.hasSuffix("Task:\nfaça X"))

        let checked = RoutineGoal(target: "t", check: GoalCheck(progress: 35, status: .attention, note: "faltam 2"),
                                  updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let later = RoutinePrompt.unattended("faça X", routine: "Diária", goal: checked)
        #expect(later.contains("Last check (\(RoutineReport.stamp(Date(timeIntervalSince1970: 1_800_000_000)))): 35% · atenção · faltam 2"))
    }

    @Test func voiceOverHearsTheGoalInWords() {
        #expect(RoutineGoal(target: "t").spokenSummary == "Meta: ainda sem avaliação")
        #expect(RoutineGoal(target: "t", check: GoalCheck(progress: 35, status: .onTrack)).spokenSummary == "Meta: 35%, em dia")
        #expect(RoutineGoal(target: "t", check: GoalCheck(progress: 60, status: .attention, note: "faltam 2")).spokenSummary
                == "Meta: 60%, atenção. faltam 2")
    }

    // MARK: Templates and ideas

    @Test func theGoalTemplateOpensTheEditorWithItsGoal() {
        let template = RoutineTemplate.desktopGoal
        #expect(RoutineTemplate.all.contains(template))
        let routine = template.routine(for: UUID())
        #expect(routine.goal?.target == template.goal && routine.goal?.check == nil)
        #expect(RoutineTemplate.all.filter { $0.goal != nil } == [template])
        #expect(RoutineTemplate.morningSummary.routine(for: UUID()).goal == nil)
    }

    private func bot(_ capabilities: Set<Capability> = [.terminal, .browser, .computerUse]) -> Bot {
        var bot = Bot(name: "Atlas", role: "x", orb: OrbConfig())
        bot.capabilities = capabilities
        return bot
    }

    @Test func anOrbWithoutRoutinesGetsIdeasThatOpenTheEditorLast() {
        let list = EmptyChatContent.suggestions(for: bot(), interviewPending: false, offersRoutines: true)
        #expect(list.count == EmptyChatContent.limit)
        #expect(list.suffix(2).map(\.action) == [.openEditor(RoutineTemplate.desktopGoal), .openEditor(RoutineTemplate.morningSummary)])
        #expect(list.suffix(2).map(\.caption) == ["Cria uma meta", "Cria uma rotina"])
        #expect(list.prefix(2).allSatisfy { $0.caption == nil && $0.action == .send($0.text) })
    }

    @Test func ideasMakeRoomForTheInterviewAndFollowWhatTheOrbCanDo() {
        let interview = EmptyChatContent.suggestions(for: bot(), interviewPending: true, offersRoutines: true)
        #expect(interview.count == EmptyChatContent.limit)
        #expect(interview.first?.action == .send(EmptyChatContent.interviewRequest))
        #expect(interview.filter { $0.caption != nil }.count == 1)

        // No Terminal, no files to put in order: only the morning summary.
        let textOnly = EmptyChatContent.suggestions(for: bot([]), interviewPending: false, offersRoutines: true)
        #expect(textOnly.compactMap(\.caption) == ["Cria uma rotina"])
        #expect(textOnly.count == EmptyChatContent.limit)

        // An Orb that already has routines gets prompts only.
        #expect(EmptyChatContent.suggestions(for: bot(), interviewPending: false).allSatisfy { $0.caption == nil })
    }
}
