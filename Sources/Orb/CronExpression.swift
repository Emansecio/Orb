import Foundation

/// A five-field cron line, "30 8 * * 1-5": minute, hour, day of the month, month, day of the week (0 or 7 = domingo).
/// Each field takes `*`, a number, a range (`1-5`), a list (`1,15`), a step (`*/30`, `8-18/2`) and, for months and days of
/// the week, English names (`jan`, `mon-fri`). When both the day of the month and of the week are restricted, either one
/// is enough, as in every cron.
struct CronExpression: Hashable, Sendable {
    struct Invalid: Error, Equatable { let reason: String }

    let minutes: [Int], hours: [Int]
    let days: Set<Int>, months: Set<Int>, weekdays: Set<Int>
    let anyDay: Bool, anyWeekday: Bool

    /// How far ahead `next` looks for a time that matches (a 29 de fevereiro on a Monday can take years).
    static let searchYears = 8

    init(_ text: String) throws {
        let fields = text.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
        guard fields.count == 5 else {
            throw Invalid(reason: "A expressão cron precisa de 5 campos: minuto, hora, dia do mês, mês e dia da semana.")
        }
        minutes = try Self.values(fields[0], 0...59, "minuto").sorted()
        hours = try Self.values(fields[1], 0...23, "hora").sorted()
        days = try Self.values(fields[2], 1...31, "dia do mês")
        months = try Self.values(fields[3], 1...12, "mês", names: Self.monthNames)
        // 7 is Sunday too; kept as Calendar numbering (1 = domingo).
        weekdays = Set(try Self.values(fields[4], 0...7, "dia da semana", names: Self.weekdayNames).map { $0 % 7 + 1 })
        anyDay = fields[2].hasPrefix("*")
        anyWeekday = fields[4].hasPrefix("*")
        // Two runs of a day never come closer than this, counted over the times the hours and minutes make together
        // (so "0,50 8 * * *" is two runs 50 minutes apart, not 10), and from the last one to the first of the next day.
        let times = hours.flatMap { hour in minutes.map { hour * 60 + $0 } }
        let gaps = zip(times, times.dropFirst() + [times[0] + 24 * 60]).map { $1 - $0 }
        guard gaps.allSatisfy({ $0 >= Schedule.minuteRange.lowerBound }) else {
            throw Invalid(reason: "Não agendo tarefas com intervalo menor que \(Schedule.minuteRange.lowerBound) minutos.")
        }
    }

    /// The first time after `date` that matches, in `calendar`'s time zone; nil when none does in `searchYears`.
    func next(after date: Date, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: date)
        for offset in 0..<(Self.searchYears * 366) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            guard let month = parts.month, months.contains(month), matches(day: parts.day, weekday: parts.weekday) else { continue }
            // Daylight saving can move a skipped time forward past a later one, so the loop order is not the time order:
            // take the earliest real instant of the day (two times landing on the same instant count once).
            var earliest: Date?
            for hour in hours {
                for minute in minutes {
                    var time = parts
                    time.weekday = nil
                    time.hour = hour
                    time.minute = minute
                    // A time skipped by daylight saving comes out moved forward, which is still a run that day.
                    guard let candidate = calendar.date(from: time), candidate > date else { continue }
                    if earliest.map({ candidate < $0 }) ?? true { earliest = candidate }
                }
            }
            if let earliest { return earliest }
        }
        return nil
    }

    /// A field that starts with `*` (`*`, `*/2`) still holds its values; it only makes the two fields both count, as in
    /// Vixie cron.
    private func matches(day: Int?, weekday: Int?) -> Bool {
        let byDay = day.map(days.contains) ?? false
        let byWeekday = weekday.map(weekdays.contains) ?? false
        return anyDay || anyWeekday ? byDay && byWeekday : byDay || byWeekday
    }

    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    private static func values(_ field: String, _ range: ClosedRange<Int>, _ what: String, names: [String] = []) throws -> Set<Int> {
        let invalid = Invalid(reason: "Campo de \(what) inválido: “\(field)” (aceito de \(range.lowerBound) a \(range.upperBound)).")
        func number(_ text: Substring) throws -> Int {
            if let index = names.firstIndex(of: String(text)) { return index + (range.lowerBound == 1 ? 1 : 0) }
            guard let value = Int(text), range.contains(value) else { throw invalid }
            return value
        }
        var result: Set<Int> = []
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(pieces.count) else { throw invalid }
            var step = 1
            if pieces.count == 2 {
                guard let given = Int(pieces[1]), given > 0 else { throw invalid }
                step = given
            }
            let bounds: ClosedRange<Int>
            if pieces[0] == "*" {
                bounds = range
            } else {
                let ends = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
                guard (1...2).contains(ends.count) else { throw invalid }
                let low = try number(ends[0])
                // "5/15" runs from 5 to the end of the field, as in every cron.
                var high = pieces.count == 2 ? range.upperBound : low
                if ends.count == 2 { high = try number(ends[1]) }
                guard low <= high else { throw invalid }
                bounds = low...high
            }
            result.formUnion(stride(from: bounds.lowerBound, through: bounds.upperBound, by: step))
        }
        return result
    }
}
