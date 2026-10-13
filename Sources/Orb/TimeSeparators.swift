import Foundation

/// Where a conversation that never ends marks the time: above its first row, above the first row of each new day and
/// above the first row after a pause (`pause`). A row of the chat (a run of actions, a request's work) is one: a
/// separator never cuts it.
enum TimeSeparators {
    /// A silence this long between two rows reads as a new moment of the conversation.
    static let pause: TimeInterval = 15 * 60

    /// The rows a separator goes above, by the id of each, with the time it shows (when its row began). `rows`: each
    /// row's id and its items' dates, in order.
    static func breaks(_ rows: [(id: UUID, dates: [Date])], calendar: Calendar = .current) -> [UUID: Date] {
        var breaks: [UUID: Date] = [:]
        var last: Date?
        for row in rows {
            guard let start = row.dates.first else { continue }
            if let last, start.timeIntervalSince(last) < pause, calendar.isDate(start, inSameDayAs: last) {
                // Same moment: nothing between them.
            } else {
                breaks[row.id] = start
            }
            last = row.dates.max().map { max($0, last ?? $0) } ?? last
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = pattern
        return (pattern, formatter)
    })
}
