import Foundation
import Testing
@testable import Orb

/// The words and groupings of the routines page and the conversations menu (see AppModel+RoutinesUI.swift).
struct RoutinesUITests {
    private let calendar = utcCalendar

    /// Thursday, 8 October 2026, 12:00 UTC.
    private var now: Date { date(2026, 10, 8, 12, 0) }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: Names

    @Test func aRoutineWithoutANameTakesTheFirstWordsOfItsPrompt() {
        #expect(RoutineText.defaultName(fromPrompt: "resuma meus e-mails não lidos de hoje") == "Resuma meus e-mails não…")
        #expect(RoutineText.defaultName(fromPrompt: "  Organize os Downloads. ") == "Organize os Downloads")
        #expect(RoutineText.defaultName(fromPrompt: "   ") == "Rotina")
        #expect(RoutineText.resolvedName("  Meu resumo ", prompt: "x") == "Meu resumo")
        #expect(RoutineText.resolvedName("", prompt: "Faça o backup") == "Faça o backup")
    }

    @Test func aOneTimeRoutineWhoseMomentPassedCannotBeTurnedBackOn() {
        let past = Routine(name: "Uma vez", botID: UUID(), prompt: "x", schedule: .once(now.addingTimeInterval(-3600)), isEnabled: false,
                           createdAt: now.addingTimeInterval(-86_400))
        #expect(!past.canBeEnabled(now: now))
        let ahead = Routine(name: "Uma vez", botID: UUID(), prompt: "x", schedule: .once(now.addingTimeInterval(3600)), isEnabled: false,
                            createdAt: now.addingTimeInterval(-86_400))
        #expect(ahead.canBeEnabled(now: now))
        let daily = Routine(name: "Todo dia", botID: UUID(), prompt: "x", schedule: .daily(hour: 9, minute: 0), isEnabled: false)
        #expect(daily.canBeEnabled(now: now))
        // One that is on already has nothing to turn on.
        #expect(Routine(name: "Ligada", botID: UUID(), prompt: "x", schedule: .once(now.addingTimeInterval(-3600))).canBeEnabled(now: now))
    }

    @Test func aNameThatPromisesARhythmTheScheduleDoesNotKeepIsFlagged() {
        func mismatch(_ name: String, _ schedule: Schedule) -> String? {
            RoutineText.nameMismatch(of: Routine(name: name, botID: UUID(), prompt: "x", schedule: schedule))
        }
        #expect(mismatch("Checar anúncios AcessosFit (4h)", .once(now)) != nil)
        #expect(mismatch("Relatório diário", .once(now)) != nil)
        #expect(mismatch("Checar anúncios (4h)", .everyHours(6)) == "O nome diz 4 h, mas ela roda a cada 6 h.")
        #expect(mismatch("Checar anúncios (4h)", .everyHours(4)) == nil)
        // "a cada Nh" is the common way to write it: "a cada" must not hide the hours.
        #expect(mismatch("Checar anúncios a cada 4h", .everyHours(6)) == "O nome diz 4 h, mas ela roda a cada 6 h.")
        #expect(mismatch("Checar anúncios a cada 4h", .everyHours(4)) == nil)
        #expect(mismatch("Resumo às 9h", .once(now)) == nil) // a time of day is not a rhythm
    }

    @Test func aTaskForOneMomentThatRanIsConcludedNotPaused() {
        var routine = Routine(name: "Uma vez", botID: UUID(), prompt: "x", schedule: .once(now))
        routine.createdAt = now.addingTimeInterval(-60)
        routine.isEnabled = false
        #expect(!RoutineText.isConcluded(routine)) // switched off before its moment: paused
        routine.lastRun = now.addingTimeInterval(60)
        #expect(RoutineText.isConcluded(routine))
        routine.schedule = .everyHours(4)
        #expect(!RoutineText.isConcluded(routine))
    }

    // MARK: Time in words

    @Test func timeUntilTheNextRunIsInWords() {
        #expect(RoutineText.relative(until: now.addingTimeInterval(20), now: now) == "em instantes")
        #expect(RoutineText.relative(until: now.addingTimeInterval(-500), now: now) == "em instantes")
        #expect(RoutineText.relative(until: now.addingTimeInterval(25 * 60), now: now) == "em 25 min")
        #expect(RoutineText.relative(until: now.addingTimeInterval(3 * 3600), now: now) == "em 3 h")
        #expect(RoutineText.relative(until: now.addingTimeInterval(4 * 3600 + 37 * 60), now: now) == "em 4 h 37 min")
        #expect(RoutineText.relative(until: now.addingTimeInterval(26 * 3600), now: now) == "em 1 dia")
        #expect(RoutineText.relative(until: now.addingTimeInterval(3 * 86_400 + 600), now: now) == "em 3 dias")
    }

    /// A routine whose time went by without its run (app closed, Mac asleep) is said as late, with the time it missed,
    /// not as "Próxima" with a date already gone; within a minute of its time it is still "em instantes".
    @Test func aLateRoutineIsSaidAsLate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 3, minute: 42))!
        let missed = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 18, minute: 0))!
        #expect(RoutineText.isLate(missed, now: now))
        #expect(!RoutineText.isLate(now.addingTimeInterval(-30), now: now))
        #expect(!RoutineText.isLate(.distantFuture, now: now))
        #expect(RoutineText.late(missed, now: now, calendar: calendar) == "Atrasada: era ontem às 18:00 · roda\u{A0}em\u{A0}instantes")
        var routine = Routine(name: "Mesa em ordem", botID: UUID(), prompt: "", schedule: .daily(hour: 18, minute: 0))
        routine.lastRun = Date.now.addingTimeInterval(-3 * 86_400) // its next time is two days gone
        #expect(RoutineText.nextRun(of: routine)?.hasPrefix("Atrasada: era ") == true)
    }

    @Test func daysAreTodayTomorrowTheWeekdayOrTheDate() {
        #expect(RoutineText.dayAndTime(date(2026, 10, 8, 18, 5), now: now, calendar: calendar) == "hoje às 18:05")
        #expect(RoutineText.dayAndTime(date(2026, 10, 9, 9, 0), now: now, calendar: calendar) == "amanhã às 09:00")
        #expect(RoutineText.dayAndTime(date(2026, 10, 11, 10, 0), now: now, calendar: calendar) == "domingo às 10:00")
        #expect(RoutineText.dayAndTime(date(2026, 10, 20, 7, 30), now: now, calendar: calendar) == "20 de out. às 07:30")
        #expect(RoutineText.dayAndTime(date(2027, 1, 5, 7, 30), now: now, calendar: calendar) == "5 de jan. de 2027 às 07:30")
    }

    @Test func aRunsDateIsRelativeToToday() {
        #expect(RoutineText.stamp(date(2026, 10, 8, 9, 0), now: now, calendar: calendar) == "hoje 09:00")
        #expect(RoutineText.stamp(date(2026, 10, 7, 23, 59), now: now, calendar: calendar) == "ontem 23:59")
        #expect(RoutineText.stamp(date(2026, 10, 5, 8, 30), now: now, calendar: calendar) == "seg 08:30")
        #expect(RoutineText.stamp(date(2026, 9, 29, 6, 5), now: now, calendar: calendar) == "29 de set. 06:05")
        #expect(RoutineText.stamp(date(2025, 12, 31, 6, 5), now: now, calendar: calendar) == "31 de dez. de 2025 06:05")
    }

    @Test func aRunsDurationIsShort() {
        func run(_ seconds: TimeInterval?) -> RoutineRun {
            RoutineRun(date: now, finishedAt: seconds.map { now.addingTimeInterval($0) }, succeeded: true, summary: "")
        }
        #expect(RoutineText.duration(of: run(nil)) == nil)
        #expect(RoutineText.duration(of: run(0.2)) == nil)
        #expect(RoutineText.duration(of: run(40)) == "40 s")
        #expect(RoutineText.duration(of: run(150)) == "2 min")
        #expect(RoutineText.duration(of: run(3600)) == "1 h")
        #expect(RoutineText.duration(of: run(3900)) == "1 h 5 min")
    }

    @Test func theCardSaysWhenTheNextRunIsOrThatItIsPaused() {
        var routine = Routine(name: "Resumo", botID: UUID(), prompt: "x", schedule: .everyHours(4))
        routine.createdAt = date(2026, 10, 7, 12, 0)
        routine.lastRun = date(2026, 10, 8, 11, 0)
        #expect(RoutineText.nextRun(of: routine, now: now, calendar: calendar) == "Próxima: hoje às 15:00 · em 3 h")
        routine.isEnabled = false
        #expect(RoutineText.nextRun(of: routine, now: now, calendar: calendar) == nil)
    }

    @Test func theEditorPreviewsTheNextRun() {
        #expect(RoutineText.preview(of: .daily(hour: 9, minute: 0), now: now, calendar: calendar)
                == "Próxima execução: amanhã às 09:00 (em 21 h)")
        #expect(RoutineText.preview(of: .everyHours(4), now: now, calendar: calendar)
                == "Próxima execução: hoje às 16:00 (em 4 h)")
        #expect(RoutineText.preview(of: .weekly(weekday: 1, hour: 10, minute: 0), now: now, calendar: calendar)
                == "Próxima execução: domingo às 10:00 (em 2 dias)")
    }

    // MARK: Permission warning

    @Test func aRoutineWaitsForAnAnswerOnlyWhenItWouldAsk() {
        #expect(RoutineText.waitsForAnswer(orbMode: .ask, routineMode: nil))
        #expect(!RoutineText.waitsForAnswer(orbMode: .ask, routineMode: .auto))
        #expect(!RoutineText.waitsForAnswer(orbMode: .ask, routineMode: .readOnly))
        #expect(!RoutineText.waitsForAnswer(orbMode: .auto, routineMode: nil))
        #expect(!RoutineText.waitsForAnswer(orbMode: .bypass, routineMode: nil))
    }

    // MARK: Templates

    @Test func templatesFillTheRoutineForTheChosenOrb() throws {
        let botID = UUID()
        #expect(RoutineTemplate.all.map(\.title) == ["Resumo da manhã", "Organizar arquivos", "Revisar a semana", "Mesa em ordem"])
        #expect(Set(RoutineTemplate.all.map(\.id)).count == RoutineTemplate.all.count)
        for template in RoutineTemplate.all {
            let routine = template.routine(for: botID)
            #expect(routine.botID == botID)
            #expect(routine.name == template.title)
            #expect(!routine.prompt.isEmpty)
            #expect(routine.schedule == template.schedule)
            #expect(routine.isEnabled)
        }
        let morning = try #require(RoutineTemplate.all.first)
        #expect(morning.schedule == .daily(hour: 8, minute: 30))
        #expect(morning.whenText == "Todo dia às 08:30")
        // A template never gives more permission than the Orb has: only a restriction is prefilled.
        #expect(RoutineTemplate.all.allSatisfy { $0.permissionMode == nil || $0.permissionMode == .readOnly })
    }

    @Test @MainActor func aNewRoutineStartsWithTheSelectedOrbOrTheFirst() throws {
        let model = AppModel(store: Store(directory: FileManager.default.temporaryDirectory.appending(path: "OrbRoutinesUI-\(UUID().uuidString)")),
                             runsBackgroundWork: false)
        let first = try #require(model.bots.first)
        let draft = try #require(model.draftRoutine())
        #expect(draft.botID == model.routineDefaultBot?.id)
        #expect(draft.name.isEmpty && draft.prompt.isEmpty)
        let other = try #require(model.draftRoutine(from: RoutineTemplate.all[1], botID: first.id))
        #expect(other.botID == first.id)
        #expect(other.name == "Organizar arquivos")
    }

    // MARK: Report

    @Test func aReportIsSplitIntoHeadingsBulletsAndParagraphs() {
        let report = "# Resumo\n\n**3 e-mails**\nimportantes\n\n- Contrato\n* Reunião às 15h\n• Fatura\n\nNada mais.\n"
        #expect(RoutineText.reportBlocks(report) == [
            .heading("Resumo"),
            .paragraph("**3 e-mails**\nimportantes"),
            .bullet("Contrato"), .bullet("Reunião às 15h"), .bullet("Fatura"),
            .paragraph("Nada mais."),
        ])
        #expect(RoutineText.reportBlocks("").isEmpty)
        #expect(RoutineText.reportBlocks("   \n\n").isEmpty)
    }
}

/// "Nova rotina" with no Orb is not a dead end: what each start says (the paths that make the Atlas are in WelcomeTests).
struct RoutineStartTests {
    @Test func onlyTheStartsWithNoOrbExplainThemselves() {
        #expect(RoutineStart.ready.caption == nil)
        #expect(RoutineStart.waiting.caption == nil, "the first seconds say nothing that may change")
        #expect(RoutineStart.createsAtlas.caption?.contains("Atlas") == true)
        #expect(RoutineStart.needsModel.caption?.contains("modelo") == true)
        #expect(RoutineStart.needsModel.caption != RoutineStart.createsAtlas.caption)
    }

    @Test func theTipsFollowWhatTheClickWillDo() {
        for start in [RoutineStart.ready, .waiting] {
            #expect(Tip.newRoutine(for: start) == Tip.newRoutine)
            #expect(Tip.routineTemplate(for: start) == Tip.routineTemplate)
        }
        #expect(Tip.newRoutine(for: .createsAtlas) == Tip.newRoutineCreatingAtlas)
        #expect(Tip.routineTemplate(for: .createsAtlas) == Tip.routineTemplateCreatingAtlas)
        #expect(Tip.newRoutine(for: .needsModel) == Tip.newRoutineNeedingModel)
        #expect(Tip.routineTemplate(for: .needsModel) == Tip.newRoutineNeedingModel)
    }

    @Test func theAccessibilityHintOfATemplateSaysWhatWillHappen() {
        #expect(RoutineStart.ready.templateHint == "Abre o editor já preenchido")
        #expect(RoutineStart.createsAtlas.templateHint.contains("Cria o Atlas"))
        #expect(RoutineStart.needsModel.templateHint.contains("conectar um modelo"))
    }
}
