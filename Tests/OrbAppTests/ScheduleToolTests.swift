import Foundation
import Testing
@testable import Orb

// Tasks the Orb schedules itself: the interval schedule, the `schedule` tool (checking, results, limits, only the
// Orb's own), its permissions in each mode and in both engines, and the mailbox Claude Code's server uses.

private func call(_ action: String, name: String? = nil, prompt: String? = nil, when: JSONValue? = nil,
                  goal: String? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
    var object: [String: JSONValue] = extra.merging(["action": .string(action)]) { $1 }
    if let name { object["name"] = .string(name) }
    if let prompt { object["prompt"] = .string(prompt) }
    if let when { object["when"] = when }
    if let goal { object["goal"] = .string(goal) }
    return .object(object)
}

private func every(minutes: Int) -> JSONValue { .object(["kind": .string("every_minutes"), "n": .number(Double(minutes))]) }
private let daily9: JSONValue = .object(["kind": .string("daily"), "hour": .number(9)])

// MARK: - The schedule

struct OnceAndCronScheduleTests {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }

    @Test func aCronLineFindsItsNextTimeInItsTimeZone() {
        let friday = date("2026-10-16T09:00:00Z")
        #expect(Schedule.cron(expression: "30 8 * * 1-5", timeZone: nil).next(after: friday, calendar: utc) == date("2026-10-19T08:30:00Z"))
        // 9:00 in São Paulo is 12:00 UTC.
        #expect(Schedule.cron(expression: "0 9 * * *", timeZone: "America/Sao_Paulo").next(after: date("2026-10-13T00:00:00Z"), calendar: utc)
                == date("2026-10-13T12:00:00Z"))
        // Day of the month and of the week both restricted: either one, here the Monday before the 1st.
        #expect(Schedule.cron(expression: "0 0 1 * 1", timeZone: nil).next(after: date("2026-10-13T10:00:00Z"), calendar: utc)
                == date("2026-10-19T00:00:00Z"))
        // A step in the day field still counts as "any": every other day, not every day (as cron does it).
        #expect(Schedule.cron(expression: "0 9 */2 * *", timeZone: nil).next(after: date("2026-10-13T10:00:00Z"), calendar: utc)
                == date("2026-10-15T09:00:00Z"))
    }

    @Test func aCronLineOnASpringForwardDayRunsInOrderAndOnlyOnce() throws {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08: 02:00-03:00 does not exist in New York. 00:30 and 01:30 are standard time, from 03:00 on daylight time.
        let cron = try CronExpression("0,30 2,3 * * *")
        var runs: [Date] = []
        var cursor = date("2026-03-08T04:00:00Z") // 23:00 on the 7th
        for _ in 0..<5 {
            guard let next = cron.next(after: cursor, calendar: ny) else { break }
            runs.append(next)
            cursor = next
        }
        #expect(runs.count == 5)
        #expect(runs == runs.sorted() && Set(runs).count == runs.count) // in order, nothing twice
        // Whatever the skipped times become, nothing may be lost or run after a later real time: the last real ones are 03:00 and 03:30.
        #expect(runs.contains(date("2026-03-08T07:00:00Z")) && runs.contains(date("2026-03-08T07:30:00Z")))
        // The earliest candidate after a reference is returned, not the first one the loop meets.
        for reference in [date("2026-03-08T06:30:00Z"), date("2026-03-08T07:00:00Z")] {
            let next = try #require(cron.next(after: reference, calendar: ny))
            let candidates = [(2, 0), (2, 30), (3, 0), (3, 30)].compactMap { hour, minute -> Date? in
                var parts = DateComponents(year: 2026, month: 3, day: 8, hour: hour, minute: minute)
                parts.calendar = ny
                return ny.date(from: parts)
            }.filter { $0 > reference }
            #expect(next == candidates.min())
        }
    }

    @Test func theWeeklyDescriptionIsPortugueseWhateverTheMacLanguage() {
        #expect(Calendar.app.locale?.identifier == "pt_BR")
        #expect(Calendar.app.weekdaySymbols.first == "domingo")
        #expect(Schedule.weekly(weekday: 1, hour: 9, minute: 0).label == "Todo domingo às 09:00")
        #expect(Schedule.weekly(weekday: 2, hour: 18, minute: 30).label == "Toda segunda-feira às 18:30")
        #expect(Locale.app.identifier == "pt_BR")
        #expect(1234.5.formatted(.number.precision(.fractionLength(1)).locale(.app)) == "1.234,5")
    }

    @Test func aCronLineReadsListsRangesStepsAndNames() throws {
        let cron = try CronExpression("*/20 9-17/4 * jan,JUL mon-fri")
        #expect(cron.minutes == [0, 20, 40] && cron.hours == [9, 13, 17])
        #expect(cron.months == [1, 7] && cron.weekdays == [2, 3, 4, 5, 6])
        #expect(try CronExpression("0 9 * * 7").weekdays == [1]) // 7 is Sunday too
        #expect(try CronExpression("5/30 * * * *").minutes == [5, 35])
    }

    @Test func aBadOrTooFrequentCronLineIsRefusedAndNeverRuns() {
        for bad in ["* * * * *", "0,10 * * * *", "0 9 * *", "60 9 * * *", "0 9 * * 8", "0 9-8 * * *", "*/0 * * * *", "0 9 * * xyz"] {
            #expect(throws: CronExpression.Invalid.self, "\(bad)") { try CronExpression(bad) }
            #expect(Schedule.cron(expression: bad, timeZone: nil).problem() != nil, "\(bad)")
        }
        let never = Schedule.cron(expression: "0 0 30 2 *", timeZone: nil)
        #expect(never.next(after: .now) == .distantFuture && never.problem() != nil)
        #expect(Schedule.cron(expression: "0 9 * * *", timeZone: "Marte/Base").problem()?.hasPrefix("Fuso desconhecido") == true)
        #expect(Schedule.cron(expression: "0 9 * * *", timeZone: "America/Sao_Paulo").problem() == nil)
    }

    @Test func aOneTimeScheduleRunsAtItsMomentAndThenNeverAgain() throws {
        let moment = date("2026-10-14T09:00:00Z")
        #expect(Schedule.once(moment).next(after: moment.addingTimeInterval(-60)) == moment)
        #expect(Schedule.once(moment).next(after: moment) == .distantFuture)
        #expect(Schedule.once(moment).problem(now: moment.addingTimeInterval(1)) != nil)
        #expect(RoutineText.preview(nextRun: .distantFuture).hasPrefix("Nenhuma execução"))
        for schedule in [Schedule.once(moment), .cron(expression: "0 9 * * 1-5", timeZone: "America/Sao_Paulo")] {
            #expect(try JSONDecoder().decode(Schedule.self, from: JSONEncoder().encode(schedule)) == schedule)
        }
    }

    @Test func theToolCreatesOneTimeAndCronTasks() throws {
        func when(_ fields: [String: JSONValue]) throws -> Schedule {
            guard case .create(_, _, let schedule, _, _, _) = try ScheduleCommand(call("create", prompt: "x", when: .object(fields))) else { throw ToolError("") }
            return schedule
        }
        let local = try #require(ScheduleCommand.moment("2099-01-02T09:00"))
        #expect(Calendar.current.dateComponents([.year, .hour, .minute], from: local) == DateComponents(year: 2099, hour: 9, minute: 0))
        #expect(ScheduleCommand.moment("2099-01-02T09:00:00-03:00") == date("2099-01-02T12:00:00Z"))
        #expect(try when(["kind": .string("once"), "at": .string("2099-01-02T09:00")]) == .once(local))
        #expect(try when(["kind": .string("cron"), "expression": .string(" 0 9 * * 1-5 "), "time_zone": .string("America/Sao_Paulo")])
                == .cron(expression: "0 9 * * 1-5", timeZone: "America/Sao_Paulo"))
        #expect(try when(["kind": .string("cron"), "expression": .string("0 9 * * *")]) == .cron(expression: "0 9 * * *", timeZone: nil))
        for bad: [String: JSONValue] in [
            ["kind": .string("once"), "at": .string("2000-01-01T09:00")],
            ["kind": .string("once"), "at": .string("amanhã")],
            ["kind": .string("once")],
            ["kind": .string("cron"), "expression": .string("* * * * *")],
            ["kind": .string("cron"), "expression": .string("0 9 * * *"), "time_zone": .string("Marte/Base")],
        ] {
            #expect(throws: ToolError.self) { try when(bad) }
        }
    }
}

struct IntervalScheduleTests {
    @Test func nextRunIsTheIntervalAfterTheLastRun() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Schedule.everyMinutes(30).next(after: start) == start.addingTimeInterval(30 * 60))
        #expect(Schedule.everyMinutes(15).next(after: start) == start.addingTimeInterval(15 * 60))
    }

    @Test func anIntervalUnderTheMinimumNeverRunsMoreOften() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Schedule.minuteRange.lowerBound == 15)
        #expect(Schedule.everyMinutes(1).next(after: start) == start.addingTimeInterval(15 * 60))
        #expect(Schedule.everyMinutes(-5).next(after: start) == start.addingTimeInterval(15 * 60))
        #expect(Schedule.everyMinutes(1).label == "A cada 15 minutos")
        #expect(Schedule.everyMinutes(100_000).label == "A cada 720 minutos")
    }

    @Test func theLabelIsInPortuguese() {
        #expect(Schedule.everyMinutes(30).label == "A cada 30 minutos")
        #expect(Schedule.everyHours(1).label == "A cada hora")
    }

    @Test func theScheduleIsWrittenAndReadBackAndAFileEditedByHandIsKept() throws {
        let data = try JSONEncoder().encode(Schedule.everyMinutes(45))
        #expect(try JSONDecoder().decode(Schedule.self, from: data) == .everyMinutes(45))
        // A routine file from this version, with an interval nobody should have written, still loads; it runs at the minimum.
        let json = #"{"botID":"\#(UUID().uuidString)","schedule":{"everyMinutes":{"_0":2}}}"#
        let routine = try JSONDecoder().decode(Routine.self, from: Data(json.utf8))
        #expect(routine.schedule.label == "A cada 15 minutos")
        #expect(routine.nextRun == routine.createdAt.addingTimeInterval(15 * 60))
    }
}

// MARK: - Checking a call

struct ScheduleCommandTests {
    @Test func aCreateNeedsAPromptAndAWhen() throws {
        #expect(try ScheduleCommand(call("create", name: "E-mails", prompt: "veja meus e-mails", when: every(minutes: 30)))
                == .create(name: "E-mails", prompt: "veja meus e-mails", schedule: .everyMinutes(30)))
        #expect(throws: ToolError.self) { try ScheduleCommand(call("create", when: daily9)) }
        #expect(throws: ToolError.self) { try ScheduleCommand(call("create", prompt: "oi")) }
        #expect(throws: ToolError.self) { try ScheduleCommand(call("create", prompt: "   ", when: daily9)) }
        #expect(throws: ToolError.self) { try ScheduleCommand(call("create", prompt: String(repeating: "a", count: 4_001), when: daily9)) }
        #expect(throws: ToolError.self) { try ScheduleCommand(call("explode")) }
        #expect(throws: ToolError.self) { try ScheduleCommand(.object([:])) }
    }

    @Test func theNameDefaultsToTheStartOfThePromptAndIsKeptShort() throws {
        guard case .create(let name, _, _, _, _, _) = try ScheduleCommand(call("create", prompt: "Resuma meus e-mails novos de hoje", when: daily9)) else {
            Issue.record("not a create"); return
        }
        #expect(name == "Resuma meus e-mails novos…")
        guard case .create(let long, _, _, _, _, _) = try ScheduleCommand(call("create", name: String(repeating: "n", count: 200), prompt: "x", when: daily9)) else {
            Issue.record("not a create"); return
        }
        #expect(long.count == ScheduleCommand.nameLimit)
    }

    @Test func eachKindOfWhenIsReadAndItsLimitsAreEnforced() throws {
        func when(_ fields: [String: JSONValue]) throws -> Schedule {
            guard case .create(_, _, let schedule, _, _, _) = try ScheduleCommand(call("create", prompt: "x", when: .object(fields))) else { throw ToolError("") }
            return schedule
        }
        #expect(try when(["kind": .string("daily"), "hour": .number(9), "minute": .number(30)]) == .daily(hour: 9, minute: 30))
        #expect(try when(["kind": .string("daily"), "hour": .string("7")]) == .daily(hour: 7, minute: 0)) // numbers as text, minute 0
        #expect(try when(["kind": .string("weekly"), "weekday": .number(2), "hour": .number(8)]) == .weekly(weekday: 2, hour: 8, minute: 0))
        #expect(try when(["kind": .string("every_hours"), "n": .number(6)]) == .everyHours(6))
        #expect(try when(["kind": .string("every_minutes"), "n": .number(15)]) == .everyMinutes(15))
        for bad: [String: JSONValue] in [
            ["kind": .string("daily"), "hour": .number(24)],
            ["kind": .string("daily")],
            ["kind": .string("weekly"), "hour": .number(8)],
            ["kind": .string("weekly"), "weekday": .number(8), "hour": .number(8)],
            ["kind": .string("every_hours"), "n": .number(0)],
            ["kind": .string("every_hours"), "n": .number(25)],
            ["kind": .string("every_minutes"), "n": .number(14)],
            ["kind": .string("every_minutes"), "n": .number(721)],
            ["kind": .string("every_minutes")],
            ["kind": .string("monthly")],
            ["hour": .number(9)],
        ] {
            #expect(throws: ToolError.self, "\(bad)") { try when(bad) }
        }
    }

    @Test func theWordsAreReadWhateverTheCaseAndANameIsOneLine() throws {
        #expect(try ScheduleCommand(.object(["action": .string("LIST")])) == .list)
        let when: JSONValue = .object(["kind": .string("Every_Hours"), "n": .number(2)])
        #expect(try ScheduleCommand(call("create", name: "Duas\nlinhas", prompt: "x", when: when))
                == .create(name: "Duas linhas", prompt: "x", schedule: .everyHours(2)))
    }

    @Test func tooShortAnIntervalIsRefusedWithTheReason() {
        do {
            _ = try ScheduleCommand(call("create", prompt: "x", when: every(minutes: 5)))
            Issue.record("accepted 5 minutes")
        } catch {
            #expect(error.localizedDescription.contains("15 minutos"))
        }
    }

    @Test func theOtherActionsTakeANameExceptList() throws {
        #expect(try ScheduleCommand(call("list")) == .list)
        #expect(try ScheduleCommand(call("pause", name: "A")) == .setEnabled("A", false))
        #expect(try ScheduleCommand(call("resume", name: "A")) == .setEnabled("A", true))
        #expect(try ScheduleCommand(call("delete", name: "A")) == .delete("A"))
        for action in ["pause", "resume", "delete", "run", "update"] { #expect(throws: ToolError.self) { try ScheduleCommand(call(action)) } }
        #expect(try ScheduleCommand(call("run", name: "A")) == .run("A"))
    }

    @Test func aCreateCanStartPausedOrRunAtOnce() throws {
        #expect(try ScheduleCommand(call("create", name: "A", prompt: "x", when: daily9, extra: ["enabled": .bool(false)]))
                == .create(name: "A", prompt: "x", schedule: .daily(hour: 9, minute: 0), enabled: false))
        #expect(try ScheduleCommand(call("create", name: "A", prompt: "x", when: daily9, extra: ["run_now": .bool(true)]))
                == .create(name: "A", prompt: "x", schedule: .daily(hour: 9, minute: 0), runNow: true))
        // Paused and run now at once contradict each other.
        #expect(throws: ToolError.self) {
            try ScheduleCommand(call("create", name: "A", prompt: "x", when: daily9, extra: ["enabled": .bool(false), "run_now": .bool(true)]))
        }
    }

    @Test func anUpdateChangesOnlyWhatItGives() throws {
        #expect(try ScheduleCommand(call("update", name: "A", when: every(minutes: 30))) == .update(name: "A", schedule: .everyMinutes(30)))
        #expect(try ScheduleCommand(call("update", name: "A", prompt: "  novo  ", goal: "")) == .update(name: "A", prompt: "novo", goal: ""))
        #expect(throws: ToolError.self) { try ScheduleCommand(call("update", name: "A")) } // nothing to change
        #expect(throws: ToolError.self) { try ScheduleCommand(call("update", name: "A", prompt: "  ")) }
    }
}

// MARK: - The tool

struct ScheduleToolSpecTests {
    private let tool = ScheduleTool()

    @Test func listingIsSafeAndEverythingElseChangesWhatTheOrbDoesLater() {
        #expect(tool.risk(call("list")) == .safe)
        for action in ["create", "pause", "resume", "delete"] {
            #expect(tool.risk(call(action, name: "A", prompt: "x", when: daily9)) == .sensitive, "\(action)")
        }
        // The tool as a whole (Claude Code's readOnlyHint, asked without an action) is not read-only.
        #expect(tool.risk(.object([:])) == .sensitive)
    }

    @Test func aCallThatWillBeRefusedAsksNothingOfYou() {
        // It changes nothing, so there is no card to approve just to be told no.
        #expect(tool.risk(call("create", name: "E-mails", prompt: "x", when: every(minutes: 5))) == .safe)
        #expect(tool.risk(call("create", prompt: "x")) == .safe)
        #expect(tool.risk(call("pause")) == .safe)
        #expect(tool.risk(call("explode")) == .safe)
    }

    @Test func theCardSaysWhatWillRunAndWhen() {
        let card = tool.summary(call("create", name: "E-mails", prompt: "Veja meus e-mails e me avise dos urgentes.", when: every(minutes: 30)))
        #expect(card.title == "Agendando tarefa")
        #expect(card.detail == "“E-mails” · A cada 30 minutos · Veja meus e-mails e me avise dos urgentes.")
        // One line, whatever the prompt has in it.
        #expect(!tool.summary(call("create", name: "N", prompt: "a\n\nb\n- c", when: daily9)).detail.contains("\n"))
        #expect(tool.summary(call("pause", name: "E-mails")) == ("Pausando tarefa agendada", "E-mails"))
        #expect(tool.summary(call("resume", name: "E-mails")) == ("Retomando tarefa agendada", "E-mails"))
        #expect(tool.summary(call("delete", name: "E-mails")) == ("Apagando tarefa agendada", "E-mails"))
        #expect(tool.summary(call("list")).title == "Listando tarefas agendadas")
        // A call that will be refused still gets a card that says nothing false.
        #expect(tool.summary(call("create", prompt: "x")).detail == "")
    }

    @Test func aLongPromptIsShortenedOnTheCardOnly() {
        let prompt = String(repeating: "a", count: 900)
        let detail = tool.summary(call("create", name: "N", prompt: prompt, when: daily9)).detail
        #expect(detail.hasSuffix("…") && detail.count < 450)
    }

    @Test func theToolIsOfferedUnderOneNameAndKindAndNeedsNoCapability() {
        #expect(ToolBox.all.contains { $0.spec.name == "schedule" })
        #expect(tool.kind == .schedule && tool.capability == nil)
        #expect(tool.summary(call("delete", name: "A")).title == "Apagando tarefa agendada")
    }

    @Test func withoutTheAppBehindItTheToolSaysSo() async {
        await #expect(throws: ToolError.self) { try await tool.run(call("list"), context: ToolContext(workingDirectory: .temporaryDirectory)) }
    }
}

// MARK: - Permissions

struct SchedulePermissionTests {
    private let tool = ScheduleTool()
    private let home = URL(fileURLWithPath: "/Users/teste")

    private func verdict(_ mode: PermissionMode, _ action: String, rules: [PermissionRule] = []) -> PermissionVerdict {
        let arguments = call(action, name: "A", prompt: "x", when: daily9)
        let permission = PermissionPolicy.call(for: tool, arguments: arguments, context: ToolContext(workingDirectory: home), home: home)
        return PermissionPolicy.evaluate(mode: mode, call: permission, rules: rules, workspace: nil, home: home)
    }

    @Test func eachModeDecidesLikeItDoesForAnyChangeThatStays() {
        for action in ["create", "pause", "resume", "delete"] {
            #expect(verdict(.ask, action) == .ask(.needsPermission), "\(action)")
            #expect(verdict(.auto, action) == .allow, "\(action)")
            #expect(verdict(.bypass, action) == .allow, "\(action)")
            #expect(verdict(.readOnly, action) == .deny(PermissionPolicy.readOnlyDenial), "\(action)")
        }
        // Looking is not changing: it runs even in read-only.
        for mode in PermissionMode.allCases { #expect(verdict(mode, "list") == .allow, "\(mode)") }
    }

    @Test func aStandingGrantOfTheirOwnCoversThemAndNothingElseDoes() {
        let rule = PermissionRule(family: .schedule)
        #expect(verdict(.ask, "create", rules: [rule]) == .allow)
        #expect(verdict(.ask, "create", rules: [PermissionRule(family: .jobs), PermissionRule(family: .memory)]) == .ask(.needsPermission))
        #expect(rule.title == "Gerenciar as tarefas agendadas")
        let call = PermissionPolicy.call(for: tool, arguments: call("create", prompt: "x", when: daily9), context: ToolContext(workingDirectory: home), home: home)
        #expect(PermissionPolicy.suggestions(for: call) == [rule])
    }
}

// MARK: - What the app does

@Suite final class ScheduledTasksTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbSchedule-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    /// A model with two Orbs, Atlas (the one asking) and Lia.
    @MainActor private func setUp() -> (AppModel, Bot, Bot) {
        var state = AppState.initial
        state.bots.append(Bot(name: "Lia", role: "Outra", orb: OrbConfig(color: "rosa", eyes: "pilulas", mouth: "sorriso", accessories: [])))
        Store(directory: root).save(state)
        Store(directory: root).flush()
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        return (model, model.bots[0], model.bots[1])
    }

    @MainActor private func run(_ model: AppModel, _ bot: Bot, _ arguments: JSONValue) throws -> String {
        try model.schedule(arguments, orb: bot.id)
    }

    @Test @MainActor func aTaskIsCreatedAsARoutineOfTheOrbInItsOwnMode() throws {
        let (model, atlas, _) = setUp()
        let said = try run(model, atlas, call("create", name: "E-mails", prompt: "veja meus e-mails", when: every(minutes: 30)))

        let routine = try #require(model.routines.first)
        #expect(model.routines.count == 1)
        #expect(routine.name == "E-mails" && routine.botID == atlas.id && routine.prompt == "veja meus e-mails")
        #expect(routine.schedule == .everyMinutes(30) && routine.isEnabled)
        #expect(routine.permissionMode == nil) // never more permissive than the Orb: it uses the Orb's
        #expect(said.hasPrefix("Agendei “E-mails”: a cada 30 minutos. Próxima execução: "))
        #expect(said.contains("aba Rotinas"))
    }

    @Test @MainActor func aTaskCanWorkTowardAGoal() throws {
        let (model, atlas, _) = setUp()
        model.update(atlas.id) { $0.permissionMode = .auto }
        let said = try run(model, atlas, call("create", name: "Downloads", prompt: "arrume um pouco", when: daily9,
                                              goal: "  Downloads\nsem arquivos antigos  "))
        #expect(model.routines.first?.goal == RoutineGoal(target: "Downloads sem arquivos antigos"))
        #expect(said.contains("progresso da meta"))
        #expect(try run(model, atlas, call("list")).contains("Meta: Downloads sem arquivos antigos"))

        // Without one (or with only blanks) it is a plain task.
        _ = try run(model, atlas, call("create", name: "Outra", prompt: "x", when: daily9, goal: "   "))
        #expect(model.routines.last?.goal == nil)
        #expect(try ScheduleCommand(call("create", name: "A", prompt: "x", when: daily9))
                == .create(name: "A", prompt: "x", schedule: .daily(hour: 9, minute: 0), goal: nil))
        let summary = ScheduleTool().summary(call("create", name: "A", prompt: "x", when: daily9, goal: "Caixa zerada"))
        #expect(summary.detail.hasSuffix("· Meta: Caixa zerada"))
    }

    @Test @MainActor func inAskModeTheResultWarnsThatEachRunWaitsForYou() throws {
        let (model, atlas, _) = setUp()
        model.update(atlas.id) { $0.permissionMode = .ask }
        #expect(try run(model, atlas, call("create", name: "A", prompt: "x", when: daily9)).contains("espera a sua aprovação"))
        model.update(atlas.id) { $0.permissionMode = .auto }
        #expect(!(try run(model, atlas, call("create", name: "B", prompt: "x", when: daily9)).contains("aprovação")))
    }

    @Test @MainActor func aDailyTaskSaysWhenItRunsInWords() throws {
        let (model, atlas, _) = setUp()
        let said = try run(model, atlas, call("create", name: "Notícias", prompt: "resuma as notícias",
                                              when: .object(["kind": .string("daily"), "hour": .number(9)])))
        #expect(said.hasPrefix("Agendei “Notícias”: todo dia às 09:00. Próxima execução: "))
    }

    @Test @MainActor func theRowIsHighlightedAndThePanelOpensOnItsTab() throws {
        let (model, atlas, _) = setUp()
        model.selection = .bot(atlas.id)
        model.showInspector = true
        model.freshDuration = .seconds(60) // no fading under the test's feet
        _ = try run(model, atlas, call("create", prompt: "x", when: daily9))
        #expect(model.freshRoutine == model.routines[0].id)
        #expect(model.takeTabRequest(of: atlas.id) == .routines)

        // With the panel closed nothing is asked of it and nothing is marked: no row to highlight, no tap to feel.
        model.freshRoutine = nil
        model.showInspector = false
        _ = try run(model, atlas, call("create", name: "Outra", prompt: "y", when: daily9))
        #expect(model.takeTabRequest(of: atlas.id) == nil && model.freshRoutine == nil)
    }

    @Test @MainActor func theChatOfAnotherOrbIsNotSwitchedAway() throws {
        let (model, atlas, lia) = setUp()
        model.selection = .bot(lia.id)
        model.showInspector = true
        _ = try run(model, atlas, call("create", prompt: "x", when: daily9))
        #expect(model.selectedBotID == lia.id && model.pendingChatRequest == nil)
        #expect(model.freshRoutine == nil && model.takeTabRequest(of: lia.id) == nil) // no tap in Lia's panel for Atlas's task
    }

    @Test @MainActor func listShowsTheOrbsTasksAndOnlyThoseOfTheOrb() throws {
        let (model, atlas, lia) = setUp()
        #expect(try run(model, atlas, call("list")) == "Nenhuma tarefa agendada.")
        _ = try run(model, atlas, call("create", name: "Manhã", prompt: "resuma", when: daily9))
        _ = try run(model, lia, call("create", name: "Da Lia", prompt: "outra", when: daily9))
        _ = try run(model, atlas, call("pause", name: "Manhã"))

        let list = try run(model, atlas, call("list"))
        #expect(list.contains("“Manhã”") && list.contains("todo dia às 09:00") && list.contains("pausada") && list.contains("Faz: resuma"))
        #expect(!list.contains("Da Lia"))
    }

    @Test @MainActor func pauseAndResumeSwitchTheRoutineAndCountFromNow() throws {
        let (model, atlas, _) = setUp()
        _ = try run(model, atlas, call("create", name: "Manhã", prompt: "resuma", when: every(minutes: 30)))
        #expect(try run(model, atlas, call("pause", name: "manhã")).hasPrefix("Pausei “Manhã”"))
        // The model copies the name the way the results show it, quotes and all.
        #expect(try run(model, atlas, call("resume", name: "“Manhã”")).hasPrefix("Retomei “Manhã”"))
        _ = try run(model, atlas, call("pause", name: "\"Manhã\""))
        #expect(!model.routines[0].isEnabled)
        #expect(try run(model, atlas, call("pause", name: "Manhã")) == "“Manhã” já estava pausada.")

        let said = try run(model, atlas, call("resume", name: "MANHA"))
        #expect(said.hasPrefix("Retomei “Manhã”. Próxima execução: "))
        #expect(model.routines[0].isEnabled)
        // Switching it back on counts from now: its old last run must not make it due at once.
        #expect(model.routines[0].nextRun > Date.now.addingTimeInterval(29 * 60))
        #expect(try run(model, atlas, call("resume", name: "Manhã")) == "“Manhã” já estava ativa.")
    }

    @Test @MainActor func deleteRemovesTheRoutineAndItsConversation() throws {
        let (model, atlas, _) = setUp()
        _ = try run(model, atlas, call("create", name: "Manhã", prompt: "resuma", when: daily9))
        let id = model.routines[0].id
        model.store.saveRoutineConversation(Conversation(), routine: id, for: atlas.id)
        model.store.flush()

        #expect(try run(model, atlas, call("delete", name: "Manhã")) == "Apaguei “Manhã”.")
        model.store.flush()
        #expect(model.routines.isEmpty)
        #expect(model.store.readRoutineConversation(routine: id, for: atlas.id).value == nil)
    }

    @Test @MainActor func anOrbNeverTouchesAnotherOrbsTasks() throws {
        let (model, atlas, lia) = setUp()
        _ = try run(model, lia, call("create", name: "Da Lia", prompt: "x", when: daily9))
        for action in ["pause", "resume", "delete"] {
            #expect(throws: ToolError.self, "\(action)") { try run(model, atlas, call(action, name: "Da Lia")) }
        }
        #expect(model.routines.count == 1 && model.routines[0].isEnabled)
    }

    @Test @MainActor func aNameIsMatchedWhateverTheCaseAndAccentsButNeverGuessed() throws {
        let (model, atlas, _) = setUp()
        _ = try run(model, atlas, call("create", name: "Resumo de e-mails", prompt: "x", when: daily9))
        _ = try run(model, atlas, call("create", name: "Notícias", prompt: "y", when: daily9))
        #expect(try run(model, atlas, call("pause", name: "  noticias ")).contains("Notícias"))
        for wrong in ["Resumo", "notic", "inexistente"] {
            do {
                _ = try run(model, atlas, call("delete", name: wrong))
                Issue.record("deleted “\(wrong)”")
            } catch {
                // It says which names there are, so the Orb can try again with one of them.
                #expect(error.localizedDescription.contains("Resumo de e-mails") && error.localizedDescription.contains("Notícias"))
            }
        }
        #expect(model.routines.count == 2)
        #expect(throws: ToolError.self) { try ScheduleCommand(call("delete", name: "   ")) }
    }

    @Test @MainActor func twoTasksDoNotShareAName() throws {
        let (model, atlas, lia) = setUp()
        _ = try run(model, atlas, call("create", name: "Manhã", prompt: "x", when: daily9))
        #expect(throws: ToolError.self) { try run(model, atlas, call("create", name: "manhã", prompt: "y", when: daily9)) }
        _ = try run(model, lia, call("create", name: "Manhã", prompt: "z", when: daily9)) // another Orb's namespace
        #expect(model.routines.count == 2)
    }

    @Test @MainActor func anOrbHasAtMostTwentyTasks() throws {
        let (model, atlas, lia) = setUp()
        for number in 1...AppModel.scheduledTaskLimit {
            _ = try run(model, atlas, call("create", name: "Tarefa \(number)", prompt: "x", when: daily9))
        }
        #expect(throws: ToolError.self) { try run(model, atlas, call("create", name: "A 21ª", prompt: "x", when: daily9)) }
        #expect(model.routines.count == AppModel.scheduledTaskLimit)
        _ = try run(model, lia, call("create", name: "Da Lia", prompt: "x", when: daily9)) // the limit is per Orb
        _ = try run(model, atlas, call("delete", name: "Tarefa 3"))
        _ = try run(model, atlas, call("create", name: "A 21ª", prompt: "x", when: daily9))
    }

    @Test @MainActor func aRunOfATaskCannotCreateMoreTasksButCanStillLookAndPause() throws {
        let (model, atlas, _) = setUp()
        _ = try run(model, atlas, call("create", name: "Manhã", prompt: "x", when: daily9))
        model.session(atlas.id).routineID = model.routines[0].id // as during its run
        #expect(throws: ToolError.self) { try run(model, atlas, call("create", name: "Outra", prompt: "y", when: daily9)) }
        #expect(model.routines.count == 1)
        _ = try run(model, atlas, call("list"))
        _ = try run(model, atlas, call("pause", name: "Manhã"))
    }

    @Test @MainActor func aTaskCanBeCreatedPaused() throws {
        let (model, atlas, _) = setUp()
        let said = try run(model, atlas, call("create", name: "Depois", prompt: "x", when: daily9, extra: ["enabled": .bool(false)]))
        #expect(model.routines.first?.isEnabled == false)
        #expect(said.contains("criada pausada") && !said.contains("Próxima execução"))
    }

    @Test @MainActor func anUpdateKeepsWhatItDoesNotChangeAndCountsANewScheduleFromNow() throws {
        let (model, atlas, _) = setUp()
        _ = try run(model, atlas, call("create", name: "Manhã", prompt: "resuma", when: daily9, goal: "Caixa zerada"))
        let id = model.routines[0].id
        model.routines[0].goal?.check = GoalCheck(progress: 50, status: .onTrack, note: "metade")
        model.routines[0].lastRun = Date.now.addingTimeInterval(-3_600)
        model.routines[0].runs = [RoutineRun(date: .now, succeeded: true, summary: "ok")]

        _ = try run(model, atlas, call("update", name: "manha", prompt: "resuma e arquive"))
        #expect(model.routines[0].prompt == "resuma e arquive" && model.routines[0].goal?.check != nil && model.routines[0].runs.count == 1)
        #expect(model.routines[0].schedule == .daily(hour: 9, minute: 0) && model.routines[0].lastRun != nil)

        let said = try run(model, atlas, call("update", name: "Manhã", when: every(minutes: 30), goal: "Caixa com 10"))
        #expect(model.routines[0].id == id && model.routines[0].schedule == .everyMinutes(30) && model.routines[0].lastRun == nil)
        #expect(model.routines[0].nextRun > Date.now.addingTimeInterval(29 * 60))
        #expect(model.routines[0].goal == RoutineGoal(target: "Caixa com 10")) // a new goal starts unmeasured
        #expect(said.hasPrefix("Alterei “Manhã”: a cada 30 minutos, próxima execução: ") && said.contains("Meta: Caixa com 10"))

        _ = try run(model, atlas, call("update", name: "Manhã", goal: ""))
        #expect(model.routines[0].goal == nil)
        #expect(throws: ToolError.self) { try run(model, atlas, call("update", name: "Outra", prompt: "y")) }
    }

    @Test @MainActor func aRunOfATaskCannotChangeOrStartTasks() throws {
        let (model, atlas, _) = setUp()
        _ = try run(model, atlas, call("create", name: "Manhã", prompt: "x", when: daily9))
        model.session(atlas.id).routineID = model.routines[0].id // as during its run
        #expect(throws: ToolError.self) { try run(model, atlas, call("update", name: "Manhã", prompt: "outra coisa")) }
        #expect(throws: ToolError.self) { try run(model, atlas, call("run", name: "Manhã")) }
        _ = try run(model, atlas, call("pause", name: "Manhã")) // stopping is fine
        #expect(throws: ToolError.self) { try run(model, atlas, call("resume", name: "Manhã")) }
        #expect(throws: ToolError.self) { try run(model, atlas, call("delete", name: "Manhã")) }
        #expect(model.routines[0].prompt == "x" && !model.routines[0].isEnabled)
    }

    @Test @MainActor func anOrbThatIsGoneCannotSchedule() {
        let (model, _, _) = setUp()
        #expect(throws: ToolError.self) { try model.schedule(call("list"), orb: UUID()) }
    }

    @Test @MainActor func theNativeToolReachesTheModelThroughItsHandler() async throws {
        let (model, atlas, _) = setUp()
        var context = ToolContext(workingDirectory: root, botID: atlas.id)
        context.schedule = model.scheduleHandler(for: atlas.id)
        let said = try await ScheduleTool().run(call("create", name: "Manhã", prompt: "x", when: daily9), context: context)
        #expect(said.hasPrefix("Agendei “Manhã”") && model.routines.count == 1)
        await #expect(throws: ToolError.self) { try await ScheduleTool().run(call("create", name: "Manhã", prompt: "x", when: daily9), context: context) }
    }

    // The panel's own words and actions, which the tool shares with it.

    @Test func theRowSaysWhenAnIntervalTaskRunsNextAndNothingWhilePaused() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var routine = Routine(name: "E-mails", botID: UUID(), prompt: "x", schedule: .everyMinutes(30), createdAt: start)
        #expect(RoutineText.nextRun(of: routine, now: start)?.hasSuffix("· em 30 min") == true)
        #expect(RoutineText.nextRun(of: routine, now: start.addingTimeInterval(20 * 60))?.hasSuffix("· em 10 min") == true)
        routine.isEnabled = false
        #expect(RoutineText.nextRun(of: routine, now: start) == nil) // the row says "Pausada" instead
    }

    @Test @MainActor func theToggleAndTheTrashButtonDoWhatTheToolDoes() throws {
        let (model, atlas, _) = setUp()
        _ = try run(model, atlas, call("create", name: "Manhã", prompt: "x", when: every(minutes: 30)))
        let id = model.routines[0].id
        model.setRoutineEnabled(id, false)
        #expect(!model.routines[0].isEnabled)
        model.setRoutineEnabled(id, true)
        #expect(model.routines[0].isEnabled && model.routines[0].nextRun > .now.addingTimeInterval(29 * 60))
        model.setRoutineEnabled(UUID(), false) // a row that was deleted meanwhile
        model.deleteRoutine(id)
        #expect(model.routines.isEmpty)
        #expect(try run(model, atlas, call("list")) == "Nenhuma tarefa agendada.")
    }

    @Test @MainActor func theHighlightGoesAwayByItself() async throws {
        let (model, atlas, _) = setUp()
        model.selection = .bot(atlas.id)
        model.showInspector = true
        model.freshDuration = .milliseconds(50)
        _ = try run(model, atlas, call("create", prompt: "x", when: daily9))
        #expect(model.freshRoutine != nil)
        await waitUntil("the highlight to fade") { model.freshRoutine == nil }
    }
}

// MARK: - From a chat message to a row in the panel

/// A model that asks for one `schedule` call and then says it is done.
private struct SchedulingModel: LLMClient {
    let arguments: JSONValue
    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        let answered = messages.contains { $0.role == .tool }
        return AsyncThrowingStream { continuation in
            if answered {
                continuation.yield(.text("Pronto."))
            } else {
                continuation.yield(.toolCalls([ToolCallRequest(id: "c1", name: "schedule", arguments: arguments.jsonString)]))
            }
            continuation.yield(.finished(answered ? .done : .toolUse, nil))
            continuation.finish()
        }
    }
}

extension ScheduledTasksTests {
    @MainActor private func chat(_ mode: PermissionMode) throws -> (AppModel, Bot) {
        let (model, atlas, _) = setUp()
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.update(atlas.id) { $0.permissionMode = mode }
        model.clientOverride = { SchedulingModel(arguments: call("create", name: "E-mails", prompt: "veja meus e-mails", when: every(minutes: 30))) }
        return (model, atlas)
    }

    @MainActor private func toolRows(_ model: AppModel, _ bot: Bot) -> [ToolCall] {
        model.transcript(bot.id).compactMap { if case .tool(let call) = $0.kind { call } else { nil } }
    }

    @Test @MainActor func askingInTheChatSchedulesATaskAndTheChatSaysSo() async throws {
        let (model, atlas) = try chat(.auto)
        #expect(model.send("verifique meus e-mails a cada 30 minutos", to: atlas.id))
        await waitUntil("the turn to end") { !model.isWorking(atlas.id) && model.routines.count == 1 }

        let row = try #require(toolRows(model, atlas).first)
        #expect(row.kind == .schedule && row.state == .done && row.title == "Agendando tarefa")
        #expect(row.output?.hasPrefix("Agendei “E-mails”: a cada 30 minutos.") == true)
        #expect(model.routines[0].botID == atlas.id && model.routines[0].permissionMode == nil)
    }

    @Test @MainActor func inAskModeTheCardSaysWhatWillRunAndWhenAndNothingExistsUntilYouAllow() async throws {
        let (model, atlas) = try chat(.ask)
        #expect(model.send("verifique meus e-mails a cada 30 minutos", to: atlas.id))
        await waitUntil("the card") { !model.pendingApprovals(of: atlas.id).isEmpty }
        let card = try #require(model.pendingApprovals(of: atlas.id).first)
        #expect(card.title == "Agendando tarefa")
        #expect(card.command == "“E-mails” · A cada 30 minutos · veja meus e-mails")
        #expect(card.suggestions == [PermissionRule(family: .schedule)])
        #expect(model.routines.isEmpty)

        model.decide(.once, approvalID: card.id, botID: atlas.id)
        await waitUntil("the task") { model.routines.count == 1 }
        await waitUntil("the turn to end") { !model.isWorking(atlas.id) }
    }

    @Test @MainActor func inAskModeACallThatWillBeRefusedShowsNoCardAndTheChatSaysWhy() async throws {
        let (model, atlas) = try chat(.ask)
        model.clientOverride = { SchedulingModel(arguments: call("create", name: "E-mails", prompt: "veja", when: every(minutes: 5))) }
        #expect(model.send("verifique meus e-mails a cada 5 minutos", to: atlas.id))
        await waitUntil("the turn to end") { !model.isWorking(atlas.id) && !toolRows(model, atlas).isEmpty }
        #expect(model.pendingApprovals(of: atlas.id).isEmpty && model.routines.isEmpty)
        let row = try #require(toolRows(model, atlas).first)
        #expect(row.state == .failed && row.output?.contains("15 a 720") == true)
    }

    @Test @MainActor func denyingTheCardSchedulesNothing() async throws {
        let (model, atlas) = try chat(.ask)
        #expect(model.send("verifique meus e-mails a cada 30 minutos", to: atlas.id))
        await waitUntil("the card") { !model.pendingApprovals(of: atlas.id).isEmpty }
        model.decide(.deny, approvalID: model.pendingApprovals(of: atlas.id)[0].id, botID: atlas.id)
        await waitUntil("the turn to end") { !model.isWorking(atlas.id) }
        #expect(model.routines.isEmpty)
    }

    @Test @MainActor func readOnlyRefusesToScheduleButCanStillList() async throws {
        let (model, atlas) = try chat(.readOnly)
        #expect(model.send("verifique meus e-mails a cada 30 minutos", to: atlas.id))
        await waitUntil("the turn to end") { !model.isWorking(atlas.id) && !toolRows(model, atlas).isEmpty }
        #expect(model.routines.isEmpty)
        #expect(toolRows(model, atlas).first?.state == .failed)
    }
}

