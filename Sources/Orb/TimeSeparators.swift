import Foundation

/// Where a conversation that never ends marks the time: above its first row, above the first row of each new day and
/// above the first row after a pause (`pause`). A row of the chat (a run of actions, a request's work) is one: a
/// separator never cuts it.
enum TimeSeparators {
    /// A silence this long between two rows reads as a new moment of the conversation.
    static let pause: TimeInterval = 15 * 60

    /// The rows a separator goes above, by the id of each, with the time it shows (when its row began). `spans`: each
    /// row's id, its first item's date and its latest one (what the chat has at hand for every row), in order.
    static func breaks(spans: [(id: UUID, start: Date, end: Date)], startingAfter initialLast: Date? = nil,
                       calendar: Calendar = .current) -> [UUID: Date] {
        var breaks: [UUID: Date] = [:]
        var last: Date? = initialLast
        var dayStart: Date? = initialLast.map { calendar.startOfDay(for: $0) }
        var dayEnd: Date? = dayStart.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
        for row in spans {
            let sameDay: Bool
            if let last, row.start.timeIntervalSince(last) < pause {
                if let start = dayStart, let end = dayEnd, row.start >= start, row.start < end {
                    sameDay = true
                } else {
                    sameDay = calendar.isDate(row.start, inSameDayAs: last)
                }
            } else {
                sameDay = false
            }
            if !sameDay { breaks[row.id] = row.start }
            let nextLast = max(row.end, last ?? row.end)
            if nextLast != last {
                last = nextLast
                if dayStart == nil || dayEnd == nil || nextLast < dayStart! || nextLast >= dayEnd! {
                    let start = calendar.startOfDay(for: nextLast)
                    dayStart = start
                    dayEnd = calendar.date(byAdding: .day, value: 1, to: start)
                }
            }
        }
        return breaks
    }

    /// The separator's words: "Hoje, 14:05", "Ontem, 09:12", "Segunda-feira, 10:00" within the week, then the date
    /// ("3 de outubro, 14:05", with the year when it is not this one).
    static func label(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = format("HH:mm", date)
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Hoje"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            day = "Ontem"
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
                  (2...6).contains(days) {
            let weekday = format("EEEE", date)
            day = weekday.prefix(1).uppercased() + weekday.dropFirst()
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            day = format("d 'de' MMMM", date)
        } else {
            day = format("d 'de' MMMM 'de' yyyy", date)
        }
        return "\(day), \(time)"
    }

    /// In the Mac's time zone.
    private static func format(_ pattern: String, _ date: Date) -> String {
        formatters[pattern]?.string(from: date) ?? ""
    }

    /// Made once and never changed (formatting with them is safe from any thread): a separator is drawn again with
    /// every change of the chat.
    private static let formatters: [String: DateFormatter] = Dictionary(uniqueKeysWithValues: [
        "HH:mm", "EEEE", "d 'de' MMMM", "d 'de' MMMM 'de' yyyy",
    ].map { pattern in
        (pattern, DateFormatter.make(locale: "pt_BR", format: pattern))
    })
}

extension DateFormatter {
    /// A formatter for `format` in the locale `locale` (an identifier such as "pt_BR" or "en_US_POSIX"); calendar and
    /// time zone stay the system's.
    static func make(locale: String, format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.dateFormat = format
        return formatter
    }
}
