import Foundation

/// An Orb's latest reply as its sidebar row shows it: one short line and when the turn ended. Saved with the app's
/// state (`AppState.replies`), so the list keeps saying how each Orb left things after a restart.
struct ReplyPreview: Codable, Equatable, Sendable {
    var text: String
    var date: Date

    /// The start of `reply` without Markdown decoration, on one line; nil when nothing readable is left (a reply of
    /// only a code fence, say), so the row keeps what it had.
    static func make(from reply: String, at date: Date = .now) -> ReplyPreview? {
        let text = RoutineRun.preview(of: reply, limit: 140)
        return text.isEmpty ? nil : ReplyPreview(text: text, date: date)
    }
}

/// The time at the right of an Orb's name in the sidebar: the hour today, "Ontem", the weekday within the last week,
/// then the date. Pure, with `now` and the calendar given, so it can be tested in a fixed time zone.
enum ReplyTime {
    /// Weekday abbreviations as a Portuguese chat list writes them, indexed by `Calendar.component(.weekday)` - 1.
    private static let weekdays = ["dom.", "seg.", "ter.", "qua.", "qui.", "sex.", "sáb."]

    static func label(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
        if days == 1 { return "Ontem" }
        if days <= 6 { return weekdays[(calendar.component(.weekday, from: date) - 1) % 7] }
        let parts = calendar.dateComponents([.day, .month], from: date)
        return String(format: "%02d/%02d", parts.day ?? 1, parts.month ?? 1)
    }
}
