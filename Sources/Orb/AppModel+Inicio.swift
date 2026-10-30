import Foundation

struct InicioJump: Equatable, Sendable {
    var token = UUID()
    var bot: UUID
    var chat: UUID
    var item: UUID
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
