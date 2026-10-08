import Foundation

// What the routines page and the conversations menu say and show: templates, the next run in words, dates relative
// to today, the report split into blocks, the list of earlier conversations grouped by day. Pure functions of their
// inputs (the clock and the calendar are parameters), so they are tested without a window.

// MARK: - Templates

/// A routine ready to adjust: chosen on the empty routines page (or in the "Nova rotina" menu), it opens the editor
/// already filled in for the chosen Orb.
struct RoutineTemplate: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let prompt: String
    let schedule: Schedule
    /// Only where a restriction is safe whatever the Orb has: a template never asks for more permission than the Orb
    /// has (the editor says so when the Orb would wait for an answer).
    let permissionMode: PermissionMode?

    /// "Todo dia às 08:30"
    var whenText: String { schedule.label }

    func routine(for botID: UUID) -> Routine {
        Routine(name: title, botID: botID, prompt: prompt, schedule: schedule, permissionMode: permissionMode)
    }

    static let all: [RoutineTemplate] = [
        RoutineTemplate(
            id: "resumo-da-manha", title: "Resumo da manhã", symbol: "sun.max",
            prompt: "Faça um resumo da minha manhã usando os conectores de agenda e de e-mail, se eu tiver algum: o que está na minha agenda de hoje e os e-mails não lidos que parecem importantes. Se faltar um conector, diga qual e siga com o que der. Termine com o que eu deveria fazer primeiro, em até 5 tópicos curtos.",
            schedule: .daily(hour: 8, minute: 30), permissionMode: nil),
        RoutineTemplate(
            id: "organizar-arquivos", title: "Organizar arquivos", symbol: "tray.full",
            prompt: "Organize os arquivos da pasta de trabalho deste Orb: separe-os em pastas por tipo (imagens, documentos, outros), não apague nada e, no fim, liste o que ficou de fora e por quê.",
            schedule: .weekly(weekday: 1, hour: 10, minute: 0), permissionMode: nil),
        RoutineTemplate(
            id: "revisar-a-semana", title: "Revisar a semana", symbol: "calendar",
            prompt: "Revise a minha semana: o que mudou nesta pasta e nos relatórios das rotinas nos últimos 7 dias, o que parece pendente e três sugestões para a próxima semana.",
            schedule: .weekly(weekday: 6, hour: 17, minute: 0), permissionMode: .readOnly),
    ]
}

extension AppModel {
    /// The Orb a new routine starts with: the one you are looking at, or the first.
    var routineDefaultBot: Bot? { selectedBot ?? bots.first }

    /// A routine to open in the editor: blank, or from a template. nil when there is no Orb.
    func draftRoutine(from template: RoutineTemplate? = nil, botID: UUID? = nil) -> Routine? {
        guard let id = botID ?? routineDefaultBot?.id else { return nil }
        return template?.routine(for: id)
            ?? Routine(name: "", botID: id, prompt: "", schedule: .daily(hour: 9, minute: 0))
    }
}

// MARK: - Words

enum RoutineText {
    /// The name a routine gets when you leave it empty: the first words of what it does ("Resuma meus e-mails…").
    static func defaultName(fromPrompt prompt: String, words: Int = 4) -> String {
        let parts = prompt.split(whereSeparator: \.isWhitespace).prefix(words)
        guard !parts.isEmpty else { return "Rotina" }
        let trimmed = CharacterSet.punctuationCharacters.union(.whitespaces)
        var text = parts.joined(separator: " ").trimmingCharacters(in: trimmed)
        if prompt.split(whereSeparator: \.isWhitespace).count > words { text += "…" }
        guard let first = text.first else { return "Rotina" }
        return first.uppercased() + text.dropFirst()
    }

    /// What goes in the routine's name: what you typed, or the default from its prompt.
    static func resolvedName(_ name: String, prompt: String) -> String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? defaultName(fromPrompt: prompt) : typed
    }

    /// "em instantes", "em 25 min", "em 3 h", "em 3 h 20 min", "em 2 dias".
    static func relative(until date: Date, now: Date = .now) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 { return "em instantes" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "em \(minutes) min" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "em \(hours) h" : "em \(hours) h \(rest) min"
        }
        let days = hours / 24
        return days == 1 ? "em 1 dia" : "em \(days) dias"
    }

    /// "hoje", "amanhã", "sexta" (within the week) or "12 de out.".
    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "hoje"
        case 1: return "amanhã"
        case 2...6: return weekdayName(date, calendar: calendar)
        default: return dayMonth(date, now: now, calendar: calendar)
        }
    }

    /// "amanhã às 09:00", "sexta às 18:30".
    static func dayAndTime(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        "\(day(date, now: now, calendar: calendar)) às \(time(date, calendar: calendar))"
    }

    /// The card's line: "Próxima: em 3 h · hoje às 09:00". nil while the routine is switched off.
    static func nextRun(of routine: Routine, now: Date = .now, calendar: Calendar = .current) -> String? {
        guard routine.isEnabled else { return nil }
        let date = routine.nextRun
        return "Próxima: \(relative(until: date, now: now)) · \(dayAndTime(date, now: now, calendar: calendar))"
    }

    /// The editor's preview of a schedule that has not been saved: "Próxima execução: amanhã às 09:00 (em 3 h)".
    static func preview(of schedule: Schedule, now: Date = .now, calendar: Calendar = .current) -> String {
        preview(nextRun: schedule.next(after: now, calendar: calendar), now: now, calendar: calendar)
    }

    static func preview(nextRun date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        "Próxima execução: \(dayAndTime(date, now: now, calendar: calendar)) (\(relative(until: date, now: now)))"
    }

    /// A run's date in the history: "hoje 09:00", "ontem 09:00", "seg 09:00", "5 de out. 09:00".
    static func stamp(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let when: String
        switch days {
        case ..<0: when = day(date, now: now, calendar: calendar) // clock a little off: still in the future
        case 0: when = "hoje"
        case 1: when = "ontem"
        case 2...6: when = weekdayName(date, calendar: calendar, short: true)
        default: when = dayMonth(date, now: now, calendar: calendar)
        }
        return "\(when) \(time(date, calendar: calendar))"
    }

    /// "40 s", "2 min", "1 h 5 min"; nil for a run that has no end or took under a second.
    static func duration(of run: RoutineRun) -> String? {
        guard let end = run.finishedAt else { return nil }
        let seconds = Int(end.timeIntervalSince(run.date).rounded())
        guard seconds >= 1 else { return nil }
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// True when a run would wait for an answer nobody is there to give: the routine uses the Orb's own mode and the
    /// Orb asks before acting.
    static func waitsForAnswer(orbMode: PermissionMode, routineMode: PermissionMode?) -> Bool {
        (routineMode ?? orbMode) == .ask
    }

    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private static func weekdayName(_ date: Date, calendar: Calendar, short: Bool = false) -> String {
        let index = calendar.component(.weekday, from: date) - 1
        let names = ["domingo", "segunda", "terça", "quarta", "quinta", "sexta", "sábado"]
        return short ? String(names[index].prefix(3)) : names[index]
    }

    private static let months = ["jan.", "fev.", "mar.", "abr.", "mai.", "jun.", "jul.", "ago.", "set.", "out.", "nov.", "dez."]

    /// "5 de out." (with the year when it is not this one: "5 de out. de 2025").
    private static func dayMonth(_ date: Date, now: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.day, .month, .year], from: date)
        var text = "\(parts.day ?? 1) de \(months[max(0, min(11, (parts.month ?? 1) - 1))])"
        if parts.year != calendar.component(.year, from: now) { text += " de \(parts.year ?? 0)" }
        return text
    }
}

// MARK: - A run's report

/// A report as the sheet draws it: lines grouped into paragraphs, headings and bullets (the text inside keeps its
/// inline Markdown).
enum ReportBlock: Equatable {
    case heading(String)
    case bullet(String)
    case paragraph(String)
}

extension RoutineText {
    static func reportBlocks(_ report: String) -> [ReportBlock] {
        var blocks: [ReportBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for raw in report.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if let bullet = ["- ", "* ", "• "].first(where: line.hasPrefix) {
                flush()
                blocks.append(.bullet(String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}

// MARK: - Earlier conversations

struct ConversationGroup: Identifiable, Equatable {
    let title: String
    var entries: [ConversationSummary]
    var id: String { title }
}

enum ConversationListing {
    /// A search field is worth its space from this many conversations on.
    static let searchFrom = 5

    /// The conversations whose title has `query` in it (accents and case aside); all of them for an empty query.
    static func filter(_ entries: [ConversationSummary], query: String) -> [ConversationSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.title.localizedStandardContains(needle) }
    }

    /// Newest first, under "Hoje", "Ontem", "Esta semana" (the last week) and "Mais antigas". Empty groups are left out.
    static func groups(_ entries: [ConversationSummary], now: Date = .now, calendar: Calendar = .current) -> [ConversationGroup] {
        let today = calendar.startOfDay(for: now)
        var buckets: [String: [ConversationSummary]] = [:]
        for entry in entries.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: entry.updatedAt), to: today).day ?? 0
            let title = switch days {
            case ..<1: "Hoje"
            case 1: "Ontem"
            case 2...6: "Esta semana"
            default: "Mais antigas"
            }
            buckets[title, default: []].append(entry)
        }
        return ["Hoje", "Ontem", "Esta semana", "Mais antigas"].compactMap { title in
            buckets[title].map { ConversationGroup(title: title, entries: $0) }
        }
    }

    /// "4 mensagens · ontem 14:32"
    static func subtitle(_ entry: ConversationSummary, now: Date = .now, calendar: Calendar = .current) -> String {
        let count = entry.messageCount
        let messages = "\(count) \(count == 1 ? "mensagem" : "mensagens")"
        return "\(messages) · \(RoutineText.stamp(entry.updatedAt, now: now, calendar: calendar))"
    }

    /// The row an arrow key goes to: nothing selected goes to the first (down) or last (up); the ends stay put.
    static func moved(_ selection: UUID?, by step: Int, in ids: [UUID]) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let selection, let index = ids.firstIndex(of: selection) else { return step >= 0 ? ids.first : ids.last }
        return ids[max(0, min(ids.count - 1, index + step))]
    }
}
