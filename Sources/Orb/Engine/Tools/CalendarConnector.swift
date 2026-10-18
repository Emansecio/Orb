import EventKit
import Foundation

// Google Agenda and Lembretes as local connectors. The Mac keeps the person's Google calendar in sync (the account is added in
// Ajustes do Sistema → Contas de Internet, where Apple does the login), and EventKit reads and writes it, so the Orb needs no
// Google app, no review and no server. What EventKit cannot do is said in the tool descriptions: no guests, no Meet link, no
// other people's availability.

// MARK: - What the backend knows

struct CalendarInfo: Sendable, Equatable {
    var id: String
    var title: String
    /// The account the calendar lives in ("Google", "iCloud", "No meu Mac").
    var account: String
    var isWritable: Bool

    /// Whether the calendar lives in a Google account, going by the name of the account.
    var isGoogle: Bool { Self.looksGoogle(account) }

    static func looksGoogle(_ account: String) -> Bool {
        let folded = account.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return ["google", "gmail"].contains { folded.contains($0) }
    }
}

struct EventInfo: Sendable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String
    var notes: String
    var calendar: String
    var isRecurring: Bool
    /// How many people are invited. Changing or deleting such an event makes the calendar tell them.
    var guests = 0
}

/// What a new or changed event holds; nil leaves it as it is (or the default, for a new one).
struct EventDraft: Sendable, Equatable {
    var title: String?
    var start: Date?
    var end: Date?
    var isAllDay: Bool?
    var location: String?
    var notes: String?
    var calendar: String?
}

struct ReminderListInfo: Sendable, Equatable {
    var id: String
    var title: String
    var account: String
}

struct ReminderInfo: Sendable, Equatable {
    var id: String
    var title: String
    var list: String
    var due: Date?
    /// False for a reminder of the whole day ("2026-10-12"), which has no time to show.
    var dueHasTime = true
    var isCompleted: Bool
    var notes: String
}

struct ReminderDraft: Sendable, Equatable {
    var title: String
    var list: String?
    var due: Date?
    var dueHasTime = true
    var notes: String?
}

enum CalendarEntity: Sendable { case events, reminders }

enum CalendarAccess: Sendable, Equatable {
    case granted, notDetermined, denied
    /// The Mac forbids it (a profile, Screen Time).
    case restricted
    /// The process has no `Info.plist` with the usage description (a bare `swift run`): macOS would end it if asked.
    case unsupported
}

/// The calendar database of the Mac. The app uses EventKit; tests use a fake.
protocol CalendarBackend: Sendable {
    func access(_ entity: CalendarEntity) -> CalendarAccess
    /// Shows the macOS permission dialog when it has never been answered.
    func requestAccess(_ entity: CalendarEntity) async -> CalendarAccess
    func calendars() async throws -> [CalendarInfo]
    func events(from: Date, to: Date, calendar: String?, query: String?, limit: Int) async throws -> [EventInfo]
    func event(id: String) async throws -> EventInfo
    func createEvent(_ draft: EventDraft) async throws -> EventInfo
    func updateEvent(id: String, _ draft: EventDraft) async throws -> EventInfo
    func deleteEvent(id: String) async throws -> EventInfo
    func reminderLists() async throws -> [ReminderListInfo]
    func reminders(list: String?, includeCompleted: Bool, limit: Int) async throws -> [ReminderInfo]
    func createReminder(_ draft: ReminderDraft) async throws -> ReminderInfo
}

// MARK: - Google Agenda

struct CalendarConnector: LocalConnector {
    let backend: any CalendarBackend

    /// Longest span one search covers.
    static let longestSearch: TimeInterval = 2 * 366 * 24 * 3600
    static let notesLimit = 400

    var tools: [LocalTool] {
        let when = "ISO 8601: 2026-10-12, 2026-10-12T09:00 (this Mac's time zone) or with an offset (2026-10-12T09:00:00-03:00)."
        return [
            .reading("list_calendars", "Lists the calendars on this Mac (Google, iCloud…) with the account each one belongs to and whether it can be changed."),
            .reading("search_events", "Finds events between two dates, in all calendars or one. Returns id, time, title, place and notes.",
                     .schema(["from": .property("string", when), "to": .property("string", "End of the period, same format; a date with no time includes that whole day (from and to both 2026-10-12 is that one day). At most two years after from."),
                              "query": .property("string", "Only events whose title, place or notes contain this text."),
                              "calendar": .property("string", "Calendar title or id from list_calendars."),
                              "limit": .property("integer", "Most events to return (default 50, at most 200).")],
                             required: ["from", "to"])),
            .reading("get_event", "Reads one event in full.", .schema(["id": .property("string")], required: ["id"])),
            .writing("create_event", "Creates an event on this Mac's calendar (it syncs to Google). Cannot add guests or a Meet link.",
                     .schema(["title": .property("string"), "start": .property("string", when),
                              "end": .property("string", "Defaults to one hour after start; for an all-day event, the last day."),
                              "all_day": .property("boolean"), "location": .property("string"), "notes": .property("string"),
                              "calendar": .property("string", "Calendar title or id; defaults to the Mac's default calendar.")],
                             required: ["title", "start"])),
            .writing("update_event", "Changes fields of an event (only the ones given). Does not change guests, but the calendar tells the event's guests about the change. Not for repeating events.",
                     .schema(["id": .property("string"), "title": .property("string"), "start": .property("string", when),
                              "end": .property("string"), "all_day": .property("boolean"), "location": .property("string"),
                              "notes": .property("string"), "calendar": .property("string", "Moves the event to this calendar.")],
                             required: ["id"]), destructive: true),
            .writing("delete_event", "Deletes an event; the calendar tells its guests it was cancelled. Not for repeating events.", .schema(["id": .property("string")], required: ["id"]), destructive: true),
        ]
    }

    func call(_ name: String, arguments: JSONValue) async throws -> String {
        switch name {
        case "list_calendars":
            let calendars = try await backend.calendars()
            guard !calendars.isEmpty else { return "Não há agendas neste Mac. Adicione a conta Google em Ajustes do Sistema → Contas de Internet." }
            return calendars.map { "\($0.title) — conta: \($0.account)\($0.isWritable ? "" : " (só leitura)") — id: \($0.id)" }.joined(separator: "\n")
        case "search_events":
            let from = try LocalDates.required(arguments, "from"), to = try LocalDates.requiredEnd(arguments, "to")
            guard to >= from else { throw ToolError("\"to\" vem antes de \"from\".") }
            guard to.timeIntervalSince(from) <= Self.longestSearch else { throw ToolError("O período passa de dois anos: busque em partes.") }
            let limit = arguments.integer("limit", default: 50, in: 1...200)
            let events = try await backend.events(from: from, to: to, calendar: arguments.nonEmptyString("calendar"),
                                                  query: arguments.nonEmptyString("query"), limit: limit)
            guard !events.isEmpty else { return "Nenhum evento entre \(LocalDates.text(from)) e \(LocalDates.text(to))." }
            return events.map { Self.describe($0) }.joined(separator: "\n\n")
        case "get_event":
            return Self.describe(try await backend.event(id: try arguments.requiredString("id")), full: true)
        case "create_event":
            let allDay = arguments.flag("all_day")
            let start = try LocalDates.required(arguments, "start")
            let end = try LocalDates.optional(arguments, "end")
            if let end, end < start { throw ToolError("\"end\" vem antes de \"start\".") }
            let draft = EventDraft(title: try arguments.requiredString("title"), start: start, end: end, isAllDay: allDay,
                                   location: arguments.nonEmptyString("location"), notes: arguments.nonEmptyString("notes"),
                                   calendar: arguments.nonEmptyString("calendar"))
            return "Evento criado.\n" + Self.describe(try await backend.createEvent(draft), full: true)
        case "update_event":
            let draft = EventDraft(title: arguments.nonEmptyString("title"), start: try LocalDates.optional(arguments, "start"),
                                   end: try LocalDates.optional(arguments, "end"), isAllDay: arguments["all_day"] == nil ? nil : arguments.flag("all_day"),
                                   location: arguments["location"]?.string, notes: arguments["notes"]?.string,
                                   calendar: arguments.nonEmptyString("calendar"))
            return "Evento alterado.\n" + Self.describe(try await backend.updateEvent(id: try arguments.requiredString("id"), draft), full: true)
        case "delete_event":
            return "Evento apagado: " + Self.describe(try await backend.deleteEvent(id: try arguments.requiredString("id")))
        default:
            throw ToolError("Ferramenta desconhecida: \(name).")
        }
    }

    /// An event as the model reads it.
    static func describe(_ event: EventInfo, full: Bool = false) -> String {
        let when = event.isAllDay
            ? "dia inteiro, \(LocalDates.text(event.start, allDay: true))" + (Calendar.current.isDate(event.start, inSameDayAs: event.end) ? "" : " a \(LocalDates.text(event.end, allDay: true))")
            : "\(LocalDates.text(event.start)) a \(Calendar.current.isDate(event.start, inSameDayAs: event.end) ? String(LocalDates.text(event.end).suffix(5)) : LocalDates.text(event.end))"
        var lines = ["\(event.title.isEmpty ? "(sem título)" : event.title) — \(when)"]
        if !event.location.isEmpty { lines.append("  onde: \(event.location)") }
        lines.append("  agenda: \(event.calendar)" + (event.isRecurring ? " (evento repetido)" : ""))
        if event.guests > 0 { lines.append("  convidados: \(event.guests) (mudar ou apagar avisa os convidados)") }
        if !event.notes.isEmpty {
            let flat = event.notes.split(whereSeparator: \.isNewline).joined(separator: " ")
            lines.append("  notas: " + (full || flat.count <= 160 ? String(flat.prefix(notesLimit)) : String(flat.prefix(160)) + "…"))
        }
        lines.append("  id: \(event.id)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Lembretes

struct RemindersConnector: LocalConnector {
    let backend: any CalendarBackend

    var tools: [LocalTool] {
        [
            .reading("list_reminder_lists", "Lists the reminder lists."),
            .reading("list_reminders", "Lists reminders, open ones by default.",
                     .schema(["list": .property("string", "List title or id."), "include_completed": .property("boolean"),
                              "limit": .property("integer", "Default 50, at most 200.")])),
            .writing("create_reminder", "Creates a reminder.",
                     .schema(["title": .property("string"), "list": .property("string", "List title or id; defaults to the Mac's default list."),
                              "due": .property("string", "ISO 8601: 2026-10-12 or 2026-10-12T09:00 (this Mac's time zone)."),
                              "notes": .property("string")], required: ["title"])),
        ]
    }

    func call(_ name: String, arguments: JSONValue) async throws -> String {
        switch name {
        case "list_reminder_lists":
            let lists = try await backend.reminderLists()
            return lists.isEmpty ? "Não há listas de lembretes." : lists.map { "\($0.title) — conta: \($0.account) — id: \($0.id)" }.joined(separator: "\n")
        case "list_reminders":
            let reminders = try await backend.reminders(list: arguments.nonEmptyString("list"), includeCompleted: arguments.flag("include_completed"),
                                                        limit: arguments.integer("limit", default: 50, in: 1...200))
            return reminders.isEmpty ? "Nenhum lembrete." : reminders.map(Self.describe).joined(separator: "\n")
        case "create_reminder":
            let draft = ReminderDraft(title: try arguments.requiredString("title"), list: arguments.nonEmptyString("list"),
                                      due: try LocalDates.optional(arguments, "due"),
                                      dueHasTime: LocalDates.hasTime(arguments.nonEmptyString("due") ?? ""), notes: arguments.nonEmptyString("notes"))
            return "Lembrete criado: " + Self.describe(try await backend.createReminder(draft))
        default:
            throw ToolError("Ferramenta desconhecida: \(name).")
        }
    }

    static func describe(_ reminder: ReminderInfo) -> String {
        var text = "\(reminder.isCompleted ? "[feito]" : "[ ]") \(reminder.title) — lista: \(reminder.list)"
        if let due = reminder.due { text += " — para: \(LocalDates.text(due, allDay: !reminder.dueHasTime))" }
        if !reminder.notes.isEmpty { text += " — notas: " + String(reminder.notes.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(160)) }
        return text + " — id: \(reminder.id)"
    }
}

// MARK: - EventKit

/// The Mac's calendars through EventKit. Nothing here asks for permission by itself: `requestAccess` is the one call that
/// does, and the person starts it with "Conectar".
final class EventKitBackend: CalendarBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var made: EKEventStore?

    /// Made on first use: an `EKEventStore` connects to the calendar daemon, which the app (and every Claude Code
    /// subprocess, Gmail's included) should not do until a calendar tool actually runs.
    private var store: EKEventStore {
        lock.withLock {
            if let made { return made }
            let store = EKEventStore()
            made = store
            return store
        }
    }

    private static func usageKey(_ entity: CalendarEntity) -> String {
        entity == .events ? "NSCalendarsFullAccessUsageDescription" : "NSRemindersFullAccessUsageDescription"
    }

    func access(_ entity: CalendarEntity) -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: entity == .events ? .event : .reminder) {
        case .fullAccess, .authorized: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        // "Só gravar" can add events but not read them: the same as no access for what the Orb does.
        case .denied, .writeOnly: .denied
        @unknown default: .denied
        }
    }

    func requestAccess(_ entity: CalendarEntity) async -> CalendarAccess {
        let current = access(entity)
        guard current == .notDetermined else { return current }
        // Without the description in Info.plist (a bare `swift run`) macOS ends the process instead of asking.
        guard Bundle.main.object(forInfoDictionaryKey: Self.usageKey(entity)) != nil else { return .unsupported }
        _ = try? await (entity == .events ? store.requestFullAccessToEvents() : store.requestFullAccessToReminders())
        return access(entity)
    }

    private func requireAccess(_ entity: CalendarEntity) throws {
        switch access(entity) {
        case .granted: return
        case .notDetermined: throw ToolError("O Orb ainda não tem permissão para \(entity == .events ? "a Agenda" : "os Lembretes"). Peça para a pessoa abrir Conectores e clicar em Conectar.")
        case .restricted: throw ToolError("O macOS não deixa o Orb usar \(entity == .events ? "a Agenda" : "os Lembretes") (restrição do Mac).")
        default: throw ToolError("O Orb está sem permissão para \(entity == .events ? "Calendários" : "Lembretes"). Ela se liga em Ajustes do Sistema → Privacidade e Segurança → \(entity == .events ? "Calendários" : "Lembretes").")
        }
    }

    // MARK: Calendars and events

    func calendars() async throws -> [CalendarInfo] {
        try requireAccess(.events)
        return store.calendars(for: .event).map(Self.info).sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    private static func info(_ calendar: EKCalendar) -> CalendarInfo {
        CalendarInfo(id: calendar.calendarIdentifier, title: calendar.title, account: calendar.source?.title ?? "", isWritable: calendar.allowsContentModifications)
    }

    private static func info(_ event: EKEvent) -> EventInfo {
        EventInfo(id: event.eventIdentifier ?? "", title: event.title ?? "", start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                  location: event.location ?? "", notes: event.notes ?? "", calendar: event.calendar?.title ?? "", isRecurring: event.hasRecurrenceRules,
                  guests: event.attendees?.count ?? 0)
    }

    /// The calendar named by title or id among `calendars`.
    private func calendar(_ name: String, among calendars: [EKCalendar]) throws -> EKCalendar {
        let wanted = Self.fold(name)
        if let found = calendars.first(where: { $0.calendarIdentifier == name }) ?? calendars.first(where: { Self.fold($0.title) == wanted }) { return found }
        throw ToolError("Não achei a agenda \"\(name)\". As que existem: \(calendars.map(\.title).joined(separator: ", ")).")
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    func events(from: Date, to: Date, calendar name: String?, query: String?, limit: Int) async throws -> [EventInfo] {
        try requireAccess(.events)
        let all = store.calendars(for: .event)
        let scope = try name.map { [try calendar($0, among: all)] }
        let found = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: scope))
        let wanted = query.map(Self.fold)
        return found.filter { event in
            guard let wanted else { return true }
            return [event.title, event.location, event.notes].contains { Self.fold($0 ?? "").contains(wanted) }
        }
        .sorted { $0.startDate < $1.startDate }
        .prefix(limit).map(Self.info)
    }

    private func existing(_ id: String) throws -> EKEvent {
        try requireAccess(.events)
        guard let event = store.event(withIdentifier: id) else { throw ToolError("Não achei o evento \(id). Busque de novo com search_events.") }
        return event
    }

    func event(id: String) async throws -> EventInfo { Self.info(try existing(id)) }

    func createEvent(_ draft: EventDraft) async throws -> EventInfo {
        try requireAccess(.events)
        let event = EKEvent(eventStore: store)
        let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
        if let name = draft.calendar {
            event.calendar = try calendar(name, among: writable)
        } else if let standard = store.defaultCalendarForNewEvents {
            event.calendar = standard
        } else {
            throw ToolError("Não há agenda que aceite eventos novos neste Mac.")
        }
        try Self.apply(draft, to: event, creating: true)
        try store.save(event, span: .thisEvent, commit: true)
        return Self.info(event)
    }

    func updateEvent(id: String, _ draft: EventDraft) async throws -> EventInfo {
        let event = try existing(id)
        if event.hasRecurrenceRules { throw ToolError("Este evento se repete: o Orb não altera eventos repetidos para não mexer na ocorrência errada. Peça para a pessoa mudar no app Agenda.") }
        if let name = draft.calendar { event.calendar = try calendar(name, among: store.calendars(for: .event).filter(\.allowsContentModifications)) }
        try Self.apply(draft, to: event, creating: false)
        try store.save(event, span: .thisEvent, commit: true)
        return Self.info(event)
    }

    func deleteEvent(id: String) async throws -> EventInfo {
        let event = try existing(id)
        if event.hasRecurrenceRules { throw ToolError("Este evento se repete: o Orb não apaga eventos repetidos. Peça para a pessoa apagar no app Agenda.") }
        let gone = Self.info(event)
        try store.remove(event, span: .thisEvent, commit: true)
        return gone
    }

    static func apply(_ draft: EventDraft, to event: EKEvent, creating: Bool) throws {
        if let title = draft.title { event.title = title }
        if let location = draft.location { event.location = location }
        if let notes = draft.notes { event.notes = notes }
        if let allDay = draft.isAllDay { event.isAllDay = allDay }
        // Only a change to the time touches the time: a new title leaves a multi-day event as long as it was.
        guard creating || draft.start != nil || draft.end != nil || draft.isAllDay != nil else { return }
        let oldStart: Date? = event.startDate, oldEnd: Date? = event.endDate
        guard let given = draft.start ?? oldStart else { throw ToolError("Faltou a data de início.") }
        let calendar = Calendar.current
        func endOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date).addingTimeInterval(24 * 3600 - 1) }
        let start = event.isAllDay ? calendar.startOfDay(for: given) : given
        let end: Date
        if let finish = draft.end {
            end = event.isAllDay ? endOfDay(finish) : finish // an all-day event ends at the end of its last day
        } else if event.isAllDay {
            if !creating, let oldStart, let oldEnd {
                // moving the start (or confirming all_day) keeps the number of days the event spans
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: oldStart), to: calendar.startOfDay(for: oldEnd)).day ?? 0
                end = endOfDay(calendar.date(byAdding: .day, value: max(days, 0), to: start) ?? start)
            } else {
                end = endOfDay(start)
            }
        } else if !creating, let oldStart, let oldEnd {
            end = start.addingTimeInterval(max(oldEnd.timeIntervalSince(oldStart), 60)) // moving the start keeps the length
        } else {
            end = start.addingTimeInterval(3600)
        }
        guard end >= start else { throw ToolError("O fim do evento vem antes do início.") }
        event.startDate = start
        event.endDate = end
    }

    // MARK: Reminders

    func reminderLists() async throws -> [ReminderListInfo] {
        try requireAccess(.reminders)
        return store.calendars(for: .reminder).map { ReminderListInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "") }
    }

    func reminders(list name: String?, includeCompleted: Bool, limit: Int) async throws -> [ReminderInfo] {
        try requireAccess(.reminders)
        let all = store.calendars(for: .reminder)
        let scope = try name.map { [try calendar($0, among: all)] }
        let predicate = store.predicateForReminders(in: scope)
        let found: [ReminderInfo] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let infos = (reminders ?? []).filter { includeCompleted || !$0.isCompleted }.map(Self.info)
                continuation.resume(returning: infos)
            }
        }
        return Array(found.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.prefix(limit))
    }

    private static func info(_ reminder: EKReminder) -> ReminderInfo {
        ReminderInfo(id: reminder.calendarItemIdentifier, title: reminder.title ?? "", list: reminder.calendar?.title ?? "",
                     due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }, dueHasTime: reminder.dueDateComponents?.hour != nil,
                     isCompleted: reminder.isCompleted, notes: reminder.notes ?? "")
    }

    func createReminder(_ draft: ReminderDraft) async throws -> ReminderInfo {
        try requireAccess(.reminders)
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.notes = draft.notes
        if let name = draft.list {
            reminder.calendar = try calendar(name, among: store.calendars(for: .reminder).filter(\.allowsContentModifications))
        } else if let standard = store.defaultCalendarForNewReminders() {
            reminder.calendar = standard
        } else {
            throw ToolError("Não há lista de lembretes que aceite itens novos.")
        }
        if let due = draft.due {
            reminder.dueDateComponents = Calendar.current.dateComponents(draft.dueHasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: due)
        }
        try store.save(reminder, commit: true)
        return Self.info(reminder)
    }
}
