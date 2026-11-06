import Foundation
import Testing
@testable import Orb

/// A cron line in words for the screen (`plainText`, `Schedule.plainLabel`); `Schedule.label`, which goes to the model, is untouched.
struct CronPlainTextTests {
    private func plain(_ line: String) throws -> String? { try CronExpression(line).plainText() }

    @Test func everyDayAtAnHour() throws {
        #expect(try plain("0 9 * * *") == "Todo dia às 9h")
        #expect(try plain("0 18 * * *") == "Todo dia às 18h")
        // Every weekday written out is every day.
        #expect(try plain("0 9 * * 0-6") == "Todo dia às 9h")
        #expect(try plain("0 9 * * 1-7") == "Todo dia às 9h")
        #expect(try plain("0 9 * 1-12 *") == "Todo dia às 9h")
    }

    @Test func weekdays() throws {
        #expect(try plain("30 9 * * 1-5") == "De segunda a sexta às 9h30")
        #expect(try plain("0 9 * * mon-fri") == "De segunda a sexta às 9h")
    }

    @Test func weekends() throws {
        #expect(try plain("0 18 * * 0,6") == "Aos fins de semana às 18h")
        #expect(try plain("0 18 * * 6,7") == "Aos fins de semana às 18h")
        #expect(try plain("0 18 * * sat,sun") == "Aos fins de semana às 18h")
    }

    @Test func minuteZeroIsLeftOutAndOtherMinutesKeepTheirZero() throws {
        #expect(try plain("0 9 * * *") == "Todo dia às 9h")
        #expect(try plain("5 9 * * *") == "Todo dia às 9h05")
        #expect(try plain("45 17 * * *") == "Todo dia às 17h45")
    }

    @Test func midnightAndOneOClockTakeTheSingularArticle() throws {
        #expect(try plain("0 0 * * *") == "Todo dia à 0h")
        #expect(try plain("15 1 * * *") == "Todo dia à 1h15")
        #expect(try plain("0 2 * * *") == "Todo dia às 2h")
    }

    @Test func evenStepsReadAsRepetitionsWithTheirWindow() throws {
        // The line of the report: every half hour from 8h to the last run, 23h30.
        #expect(try plain("*/30 8-23 * * *") == "A cada 30 min, das 8h às 23h30")
        #expect(try plain("0,30 8-23 * * *") == "A cada 30 min, das 8h às 23h30")
        #expect(try plain("*/15 * * * *") == "A cada 15 min")
        #expect(try plain("15,45 9-17 * * 1-5") == "De segunda a sexta, a cada 30 min, das 9h15 às 17h45")
        #expect(try plain("*/20 0-5 * * *") == "A cada 20 min, da 0h às 5h40")
        #expect(try plain("0 * * * *") == "A cada hora")
        #expect(try plain("0 */2 * * *") == "A cada 2 horas")
        #expect(try plain("30 */6 * * 0,6") == "Aos fins de semana, a cada 6 horas, no minuto 30")
        #expect(try plain("0 8-18 * * *") == "A cada hora, das 8h às 18h")
        #expect(try plain("0 8-20/4 * * 1-5") == "De segunda a sexta, a cada 4 horas, das 8h às 20h")
    }

    @Test func linesWithoutAPlainReadingGiveNil() throws {
        #expect(try plain("0 9,18 * * *") == nil) // two hours, nine apart: not an even step of the day
        #expect(try plain("0,20 9 * * *") == nil) // two minutes that do not repeat across the hour
        #expect(try plain("*/30 8,10,11 * * *") == nil) // a step in the minute over hours with a gap
        #expect(try plain("0 1,2,4 * * *") == nil) // an uneven list of hours
        #expect(try plain("*/30 */2 * * *") == nil) // steps in both
        #expect(try plain("0 9 * * 1") == nil) // one weekday
        #expect(try plain("0 9 * * 1,3,5") == nil) // a list of weekdays
        #expect(try plain("0 9 * * */2") == nil) // a step in the weekday
        #expect(try plain("0 9 1 * *") == nil) // a day of the month
        #expect(try plain("0 9 1-31 * 1-5") == nil) // a listed day of the month makes either field enough
        #expect(try plain("0 9 */2 * *") == nil)
        #expect(try plain("0 9 * 1,6 *") == nil) // some months
        #expect(try plain("0 9 * jan *") == nil)
    }

    @Test func plainLabelUsesWordsOnlyForCommonCronLines() {
        #expect(Schedule.cron(expression: "30 9 * * 1-5", timeZone: nil).plainLabel == "De segunda a sexta às 9h30")
        // The Mac's own time zone goes without saying; another is named by its city.
        #expect(Schedule.cron(expression: "0 9 * * *", timeZone: TimeZone.current.identifier).plainLabel == "Todo dia às 9h")
        let other = TimeZone.current.identifier == "America/New_York" ? ("Europe/Lisbon", "Lisbon") : ("America/New_York", "New York")
        #expect(Schedule.cron(expression: "0 9 * * *", timeZone: other.0).plainLabel == "Todo dia às 9h (fuso de \(other.1))")
        // No plain reading, or a line that does not parse: the label as it is.
        let hard = Schedule.cron(expression: "0 1,2,4 * * *", timeZone: nil)
        #expect(hard.plainLabel == hard.label)
        let broken = Schedule.cron(expression: "banana", timeZone: nil)
        #expect(broken.plainLabel == broken.label)
        let daily = Schedule.daily(hour: 9, minute: 0)
        #expect(daily.plainLabel == daily.label)
    }

    @Test func theLabelThatGoesToTheModelDoesNotChange() {
        #expect(Schedule.cron(expression: "30 9 * * 1-5", timeZone: nil).label == "Cron “30 9 * * 1-5”")
        #expect(Schedule.cron(expression: "0 9 * * *", timeZone: "America/Sao_Paulo").label == "Cron “0 9 * * *” (fuso America/Sao_Paulo)")
    }

    @Test func theTimeZoneProblemIsTheSameInTheFieldAndInTheFooter() {
        let message = Schedule.zoneProblem("Marte/Olympus")
        #expect(message == "Fuso desconhecido: “Marte/Olympus”. Use um nome como America/Sao_Paulo.")
        #expect(Schedule.zoneProblem("America/Sao_Paulo") == nil)
        #expect(Schedule.cron(expression: "0 9 * * *", timeZone: "Marte/Olympus").problem() == message)
    }
}

/// The "Ver mais" of the last run in the Orb's panel shows only when there is more to see.
struct RoutineLastRunMoreTests {
    private func run(_ summary: String, report: String? = nil) -> RoutineRun {
        RoutineRun(date: .now, succeeded: true, summary: summary, report: report)
    }

    @Test func moreOnlyWhenThereIsMore() {
        #expect(!RoutineText.hasMore(run("Nenhuma mensagem nova.")))
        #expect(!RoutineText.hasMore(run("Nenhuma mensagem nova.", report: " Nenhuma mensagem nova.\n")))
        #expect(RoutineText.hasMore(run("Respondi 3.", report: "Respondi 3.\n\nBruno, Glauber e Letícia.")))
        #expect(RoutineText.hasMore(run(String(repeating: "Respondi Bruno Santos, ", count: 5))))
    }
}
