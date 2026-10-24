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

    @Test func linesWithoutAPlainReadingGiveNil() throws {
        #expect(try plain("0 9,18 * * *") == nil) // two hours
        #expect(try plain("0,30 9 * * *") == nil) // two minutes
        #expect(try plain("*/30 9 * * *") == nil) // a step in the minute
        #expect(try plain("0 */2 * * *") == nil) // a step in the hour
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
        #expect(Schedule.cron(expression: "0 9 * * *", timeZone: "America/Sao_Paulo").plainLabel
                == "Todo dia às 9h (fuso America/Sao_Paulo)")
        // No plain reading, or a line that does not parse: the label as it is.
        let hard = Schedule.cron(expression: "*/30 9 * * *", timeZone: nil)
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
