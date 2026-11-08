import Foundation

struct InicioJump: Equatable, Sendable {
    var token = UUID()
    var bot: UUID
    var chat: UUID
    var item: UUID
}

/// Novidades grouped by day for the home page: "Hoje", "Ontem", "Esta semana", then "Mais antigas". Pure, with `now` and
/// the calendar given, so a test can fix the clock.
enum InicioDays {
    struct Group: Identifiable {
        let title: String
        let items: [InicioNews]
        var id: String { title }
    }

    /// `news` is newest first (as `InicioNews.folded` returns it), so each group keeps that order and the groups come in
    /// the order their first item appears.
    static func group(_ news: [InicioNews], now: Date = .now, calendar: Calendar = .current) -> [Group] {
        var titles: [String] = []
        var buckets: [String: [InicioNews]] = [:]
        for item in news {
            let title = title(of: item.entry.date, now: now, calendar: calendar)
            if buckets[title] == nil { titles.append(title) }
            buckets[title, default: []].append(item)
        }
        return titles.map { Group(title: $0, items: buckets[$0] ?? []) }
    }

    static func title(of date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "Hoje" }
        if days == 1 { return "Ontem" }
        return days <= 6 ? "Esta semana" : "Mais antigas"
    }

    /// "Ver mais 9 itens": the link under a list cut short.
    static func moreLabel(hidden: Int) -> String { hidden == 1 ? "Ver mais 1 item" : "Ver mais \(hidden) itens" }
}

extension AppModel {
    func recordInicioChat(bot: UUID, chat: UUID, item: UUID, date: Date, text: String, succeeded: Bool,
                          source: Conversation? = nil) {
        let previous = inicio.nextSequence
        inicio.append(id: item, date: date, origin: .chat(bot: bot, chat: chat, item: item),
                      outcome: succeeded ? .completed : .failed, summary: text)
        if inicio.nextSequence != previous {
            if let source { store.saveInicioJournal(inicio, after: source, bot: bot, chat: chat) }
            else { store.saveInicioJournal(inicio) }
        }
    }

    /// A redo or an edit cut these items off the conversation: the home page must not keep listing their results.
    func forgetInicioChat(items: [TranscriptItem]) {
        if inicio.removeChatResults(of: Set(items.map(\.id))) { store.saveInicioJournal(inicio) }
    }

    /// An Orb, a conversation, a routine or some runs are gone: their rows leave the home page and the journal.
    func forgetInicio(where gone: (InicioEntry) -> Bool) {
        if inicio.removeEntries(where: gone) { store.saveInicioJournal(inicio) }
    }

    /// A pulse that did something: the row opens the line it left in the Orb's chat.
    func recordInicioPulse(bot: UUID, chat: UUID, item: UUID, summary: String, outcome: InicioEntry.Outcome) {
        let previous = inicio.nextSequence
        inicio.append(id: item, date: .now, origin: .pulse(bot: bot, chat: chat, item: item), outcome: outcome, summary: summary)
        if inicio.nextSequence != previous { store.saveInicioJournal(inicio) }
    }

    func recordInicioRoutine(bot: UUID, routine: UUID, run: RoutineRun, outcome: InicioEntry.Outcome, journal: Bool = true) {
        let previous = inicio.nextSequence
        inicio.append(id: run.id, date: run.finishedAt ?? run.date, origin: .routine(bot: bot, routine: routine, run: run.id),
                      outcome: outcome, summary: run.summary)
        if journal && inicio.nextSequence != previous { store.saveInicioJournal(inicio) }
    }

    /// Only entries published while the home page is visible advance its independent cursor.
    func inicioDidPresent(_ sequence: Int64?) {
        guard selection == .inicio, let sequence else { return }
        inicioVisitThrough = max(inicioVisitThrough ?? 0, sequence)
    }

    /// Selects the actual chat; a later request supersedes a pending scroll to an earlier item.
    func openInicioChat(bot: UUID, chat: UUID, item: UUID) -> Bool {
        guard !isResetting, self.bot(bot) != nil, isChat(chat, of: bot) else { return false }
        inicioJump = InicioJump(bot: bot, chat: chat, item: item)
        if live(bot).chats == nil {
            selection = .bot(bot)
        } else {
            openChat(chat, of: bot, preservingInicioJump: true)
        }
        return true
    }
}
