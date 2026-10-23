import Foundation

/// What a turn is told of what happened outside its conversation: a turn of the chat, what happened since its last turn
/// (`SinceLastTurn`); a request from another Orb, where its Orb stands (`RequestBackground`); a routine's run, what its chat did
/// just before (`RoutineBackground`). Worked out when the turn is sent (from the chat's lines) and read when its message is
/// written (the files of the requests, off the main thread).
struct OutsideContext: Sendable {
    enum Kind: Sendable {
        case none
        case chat([SinceLastTurn.Source])
        case request(RequestBackground.Plan)
        case routine([String])
    }

    var kind = Kind.none
    /// Characters the turn sets aside of its history for it.
    var room = 0
}

extension AppModel {
    func outsideContext(of session: BotSession, itemsBefore: Int, origin: SendOrigin) -> OutsideContext {
        if session.routineID == nil, let chat = session.conversation {
            let sources = SinceLastTurn.pending(in: Array(chat.items.prefix(itemsBefore)), since: chat.contextHandedAt)
            return sources.isEmpty ? OutsideContext() : OutsideContext(kind: .chat(sources), room: SinceLastTurn.room(for: sources))
        }
        if session.sideKind == .delegation, case .orb(let envelope) = origin, envelope.kind == .ask, let chat = session.parkedChat {
            let background = RequestBackground.plan(chat: chat, asker: envelope.from, current: envelope.id)
            return background.isEmpty ? OutsideContext() : OutsideContext(kind: .request(background), room: RequestBackground.room)
        }
        // A routine's run, once at its start (the answers that resume it come as they are).
        if session.routineID != nil, session.sideKind == nil || session.sideKind == .routine, origin.isUser, let chat = session.parkedChat {
            let lines = RoutineBackground.lines(chat: chat)
            return lines.isEmpty ? OutsideContext() : OutsideContext(kind: .routine(lines), room: RoutineBackground.room)
        }
        return OutsideContext()
    }

    func outsideText(_ context: OutsideContext, of botID: UUID) async -> String? {
        switch context.kind {
        case .none:
            return nil
        case .chat(let sources):
            return SinceLastTurn.text(await entries(sources, of: botID))
        case .request(let plan):
            var earlier: [SinceLastTurn.Handled] = []
            for id in plan.earlier { if let item = await handledRequest(id, of: botID) { earlier.append(item) } }
            return RequestBackground.text(plan, earlier: earlier, notices: plan.notices.filter { bot($0.from.id) != nil })
        case .routine(let lines):
            return RoutineBackground.text(lines)
        }
    }

    private func entries(_ sources: [SinceLastTurn.Source], of botID: UUID) async -> [SinceLastTurn.Entry] {
        var entries: [SinceLastTurn.Entry] = []
        for source in sources {
            switch source {
            case .request(let id):
                if let item = await handledRequest(id, of: botID) { entries.append(.request(item)) }
            case .routine(let event):
                // The run's report, from the routine's history; a line from before the run was named, or of a routine
                // since deleted, says its note.
                let run = event.runID.flatMap { id in routines.lazy.flatMap(\.runs).first { $0.id == id } }
                let report = run?.report ?? run?.summary ?? event.note ?? ""
                entries.append(.routine(name: event.detail ?? "", outcome: (event.outcome ?? .finished).rawValue, report: report,
                                        file: event.file))
            case .group(let event):
                if let work = event.context, !work.isEmpty { entries.append(.group(name: event.detail ?? "", work: work)) }
            case .notice(let message):
                if bot(message.from.id) != nil { entries.append(.notice(from: message.from.name, text: message.text)) }
            }
        }
        return entries
    }

    /// A request the Orb handled, read from its own conversation; nil when it cannot be read (an old one pruned from the folder).
    private func handledRequest(_ id: UUID, of botID: UUID) async -> SinceLastTurn.Handled? {
        let read = await store.readSideConversationAsync(prefix: Store.pedidoPrefix, id: id, for: botID)
        return read.value.flatMap { SinceLastTurn.handled($0, request: id) }
    }
}
