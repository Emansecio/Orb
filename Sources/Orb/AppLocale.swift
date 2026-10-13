import Foundation

/// The app speaks Brazilian Portuguese whatever language the Mac is set to: every word and number the user reads comes
/// from here, so a Mac in English never shows "Todo Sunday" or "2 hours ago" next to Portuguese text.
extension Locale {
    static let app = Locale(identifier: "pt_BR")
}

extension Calendar {
    /// The Mac's calendar (time zone, first weekday) with the app's language, for names of days and months.
    static var app: Calendar {
        var calendar = Calendar.current
        calendar.locale = .app
        return calendar
    }
}
