import Foundation

/// One row of a chat as the folding draws it. A chat without Orbs' exchanges has only `.single` rows, which are its items.
enum TranscriptRowModel: Identifiable, Equatable {
    /// One item, drawn as it is.
    case single(TranscriptItem)
    /// Consecutive events of one kind (and of one actor): "Atlas criou 3 Orbs: A, B e C".
    case events(OrbEvent.Kind, [TranscriptItem])
    /// Messages between Orbs of one exchange, in order (two or more): "3 mensagens com Revisor".
    case exchange([TranscriptItem])
    /// The Orb's actions one after another, with nothing said between them (two or more): "Rodou 7 comandos e leu 1
    /// arquivo", which opens into their lines. A permission card already answered goes with them.
    case tools([TranscriptItem])
    /// The work of a finished request before its answer: what the Orb said while it worked and its actions, on one line
    /// ("Trabalhou por 1 min 05 s · rodou 11 comandos e leu 1 arquivo"), with how long the request took (whole seconds).
    case work([TranscriptItem], seconds: Int?)

    /// The id of the first item: it stays the same while the row grows, so its expanded state survives.
    var id: UUID { items[0].id }

    /// The items the row holds, in order.
    var items: [TranscriptItem] {
        switch self {
        case .single(let item): [item]
        case .events(_, let items), .exchange(let items), .tools(let items), .work(let items, _): items
        }
    }
}

/// Folds a chat's Orb lines (exchanges between Orbs, events) into rows (`TranscriptFolding.rows`). Pure: the same items
/// always fold the same way, so the rules are tested without a view.
enum TranscriptFolding {
    /// The rows of a chat, nil when every row would be one item as it is (the list then draws the items themselves).
    /// Only a chat with an action or a line between Orbs can fold, so the others are not walked twice.
    static func foldedRows(_ items: [TranscriptItem], boundary: Int, liveTail: Bool) -> [TranscriptRowModel]? {
        guard items.contains(where: { switch $0.kind { case .tool, .orbMessage, .event: true; default: false } }) else { return nil }
        let rows = rows(for: items, boundary: boundary, liveTail: liveTail)
        return rows.count == items.count ? nil : rows
    }

    /// The rows of a chat. Rules (see docs/MULTI-ORBS.md, 5):
    /// - adjacent events of one kind (and one actor, when they have one) become one row; the kinds that fold are the ones
    ///   that repeat (creation, joining and leaving a group, routines);
    /// - adjacent messages between Orbs (`orbMessage`, and `delegationReceived`) become one exchange; a tool line between two
    ///   of them does not break it: it comes after the exchange's row;
    /// - adjacent actions (`.tool`, and the permission cards already answered among them) become one row of actions;
    ///   anything else between them (a word of the Orb, a card that needs you, a notice) ends it, and so does `boundary`
    ///   (the end of what a compaction folded: a row is all folded or not);
    /// - a finished request's work before its answer becomes one row (`workStretches`); the notices in it come right after
    ///   that row, so none is hidden. `liveTail`: the last request is still running, and stays as it is;
    /// - a lone item stays as it is.
    static func rows(for items: [TranscriptItem], boundary: Int = 0, liveTail: Bool = false) -> [TranscriptRowModel] {
        var rows: [TranscriptRowModel] = []
        rows.reserveCapacity(items.count)
        let stretches = workStretches(items, boundary: boundary, liveTail: liveTail)
        var index = 0
        while index < items.count {
            if let stretch = stretches[index] {
                let inside = items[stretch.range]
                rows.append(.work(inside.filter { !isNotice($0) }, seconds: stretch.seconds))
                rows += inside.filter(isNotice).map { TranscriptRowModel.single($0) }
                index = stretch.range.upperBound
                continue
            }
            let item = items[index]
            if isExchangeLine(item) {
                var messages = [item]
                var between: [TranscriptItem] = []
                var pendingTools: [TranscriptItem] = []
                var last = index
                var next = index + 1
                scan: while next < items.count {
                    let candidate = items[next]
                    if isExchangeLine(candidate) {
                        messages.append(candidate)
                        between += pendingTools
                        pendingTools = []
                        last = next
                    } else if case .tool = candidate.kind {
                        pendingTools.append(candidate)
                    } else {
                        break scan
                    }
                    next += 1
                }
                // Only what was joined is consumed: the tool lines after the last message are read again as lone items.
                index = last + 1
                if messages.count > 1 { rows.append(.exchange(messages)) } else { rows.append(.single(item)) }
                rows += between.map { TranscriptRowModel.single($0) }
                continue
            }
            if let kind = foldableEventKind(of: item) {
                var group = [item]
                var next = index + 1
                while next < items.count, foldableEventKind(of: items[next]) == kind, sameFoldKey(items[next], item) {
                    group.append(items[next])
                    next += 1
                }
                index = next
                rows.append(group.count > 1 ? .events(kind, group) : .single(item))
                continue
            }
            if isToolLine(item) {
                var next = index + 1
                while next < items.count, next != boundary, stretches[next] == nil, joinsToolRun(items[next]) { next += 1 }
                rows.append(next - index > 1 ? .tools(Array(items[index..<next])) : .single(item))
                index = next
                continue
            }
            rows.append(.single(item))
            index += 1
        }
        return rows
    }

    static func isToolLine(_ item: TranscriptItem) -> Bool {
        if case .tool = item.kind { true } else { false }
    }

    /// An action, or a permission card already answered (never one that waits for you, nor an Orb's proposal).
    static func joinsToolRun(_ item: TranscriptItem) -> Bool {
        switch item.kind {
        case .tool: true
        case .approval(let request): request.decision != nil && request.proposal == nil
        default: false
        }
    }

    private static func isNotice(_ item: TranscriptItem) -> Bool {
        if case .notice = item.kind { true } else { false }
    }

    /// The work of one finished request, from the item after your message to the one before the Orb's answer.
    struct WorkStretch: Equatable {
        var range: Range<Int>
        var seconds: Int?
    }

    /// The stretches that fold into a work row, by their first index. A request (what follows a message of yours, to
    /// the next one) folds its work when:
    /// - it ended with the Orb's answer (its last words, with no action after them), and is not `liveTail`'s;
    /// - its work holds only words of the Orb, actions, answered cards and notices (an exchange with other Orbs, a card
    ///   that waits, a message of yours stay in view, and a message you sent during the task splits the request);
    /// - it would otherwise take two rows or more (a single run of actions is one line already);
    /// - it does not cross `boundary`.
    static func workStretches(_ items: [TranscriptItem], boundary: Int, liveTail: Bool) -> [Int: WorkStretch] {
        var stretches: [Int: WorkStretch] = [:]
        var start = 0
        while start < items.count {
            let end = items[start...].firstIndex { if case .user = $0.kind { true } else { false } } ?? items.count
            defer { start = end + 1 }
            guard !(end == items.count && liveTail),
                  let answer = items[start..<end].lastIndex(where: { if case .bot = $0.kind { true } else { false } }),
                  answer > start,
                  !items[(answer + 1)..<end].contains(where: isToolLine),
                  !(start < boundary && boundary < answer) else { continue }
            let work = items[start..<answer]
            guard work.contains(where: isToolLine), work.allSatisfy(foldsIntoWork) else { continue }
            let shown = work.filter { !isNotice($0) }
            guard rows(for: shown).count >= 2 else { continue }
            let began = start > 0 ? items[start - 1].date : items[start].date
            let seconds = Int(items[answer].date.timeIntervalSince(began).rounded())
            stretches[start] = WorkStretch(range: start..<answer, seconds: seconds > 0 ? seconds : nil)
        }
        return stretches
    }

    private static func foldsIntoWork(_ item: TranscriptItem) -> Bool {
        switch item.kind {
        case .bot, .tool, .notice: true
        case .approval: joinsToolRun(item)
        default: false
        }
    }

    /// `orbMessage`, and the event that says an Orb asked this chat's Orb for help: both are lines of an exchange.
    static func isExchangeLine(_ item: TranscriptItem) -> Bool {
        switch item.kind {
        case .orbMessage: true
        case .event(let event): event.kind == .delegationReceived
        default: false
        }
    }

    /// The kind of an event that folds with its neighbours, nil for one that stands alone.
    static func foldableEventKind(of item: TranscriptItem) -> OrbEvent.Kind? {
        guard case .event(let event) = item.kind else { return nil }
        switch event.kind {
        case .orbCreated, .joinedGroup, .leftGroup, .routineCreated: return event.kind
        default: return nil
        }
    }

    /// Two events fold only when they come from the same Orb and, for the group lines, about the same group.
    private static func sameFoldKey(_ lhs: TranscriptItem, _ rhs: TranscriptItem) -> Bool {
        guard case .event(let a) = lhs.kind, case .event(let b) = rhs.kind else { return false }
        guard a.actor?.id == b.actor?.id else { return false }
        if a.kind == .joinedGroup || a.kind == .leftGroup { return a.detail == b.detail }
        return true
    }

    // MARK: Words of a folded row

    /// The events of a folded row, in one line: "Atlas criou 3 Orbs: A, B e C", "A, B e C entraram no grupo Lançamento",
    /// "Atlas criou 2 rotinas". Only the kinds `foldableEventKind(of:)` accepts reach it.
    static func eventsTitle(_ kind: OrbEvent.Kind, _ items: [TranscriptItem]) -> String {
        let events = items.compactMap { item -> OrbEvent? in
            if case .event(let event) = item.kind { return event }
            return nil
        }
        guard let first = events.first else { return "" }
        let count = events.count
        let who = events.allSatisfy({ $0.actor?.id == first.actor?.id }) ? first.actor?.name : nil
        let names = PortugueseList.join(events.map { ($0.subject ?? $0.actor)?.name ?? "Um Orb" })
        let group = first.detail ?? ""
        switch kind {
        case .orbCreated:
            if let who { return "\(who) criou \(count) Orbs: \(names)" }
            return "\(count) Orbs criados: \(names)"
        case .joinedGroup:
            return "\(names) \(count == 1 ? "entrou" : "entraram") no grupo \(group)"
        case .leftGroup:
            return "\(names) \(count == 1 ? "saiu" : "saíram") do grupo \(group)"
        case .routineCreated:
            if let who { return "\(who) criou \(count) rotinas" }
            return "\(count) rotinas criadas"
        default:
            return "\(count) eventos"
        }
    }

    /// The header of a folded exchange: "3 mensagens com Revisor", "3 mensagens com 2 Orbs", or, when all of them are
    /// asks, "Pediu ajuda a 2 Orbs". `botID` is the Orb whose chat it is: the others are the partners.
    static func exchangeTitle(_ items: [TranscriptItem], botID: UUID) -> String {
        let partners = partners(of: items, botID: botID)
        let onlyAsks = items.allSatisfy { item in
            if case .orbMessage(let message) = item.kind { return message.direction == .sent }
            return false
        }
        let count = items.count
        if partners.count >= 2, onlyAsks { return "Pediu ajuda a \(partners.count) Orbs" }
        if partners.count >= 2 { return "\(count) mensagens com \(partners.count) Orbs" }
        if let partner = partners.first { return "\(count) mensagens com \(partner.name)" }
        return "\(count) mensagens"
    }

    /// The Orbs a folded exchange speaks with, in the order they first appear (the avatars stacked in its line).
    static func partners(of items: [TranscriptItem], botID: UUID) -> [OrbRef] {
        var partners: [OrbRef] = []
        for item in items {
            let refs: [OrbRef]
            switch item.kind {
            case .orbMessage(let message): refs = [message.from, message.to].compactMap { $0 }
            case .event(let event): refs = [event.actor, event.subject].compactMap { $0 }
            default: refs = []
            }
            for ref in refs where ref.id != botID && !partners.contains(where: { $0.id == ref.id }) {
                partners.append(ref)
            }
        }
        return partners
    }
}

/// The sentences of one message between Orbs, as the chat's line reads them ("Atlas pediu ajuda ao Revisor").
enum ExchangeWords {
    /// The line of a message: what it is, from whom and to whom.
    static func line(for message: OrbMessageItem) -> String {
        let from = message.from.name
        let to = message.to?.name ?? "outro Orb"
        switch message.kind {
        case .ask: return "\(from) pediu ajuda \(PortugueseArticle.contraction(for: to)) \(to)"
        case .tell: return "\(from) avisou \(PortugueseArticle.article(for: to)) \(to)"
        case .reply: return "\(from) respondeu \(preposition(for: to)) \(to)"
        }
    }

    /// "a" or "à", for the verbs that take "a" (respondeu a Atlas, respondeu à Lia).
    static func preposition(for name: String) -> String {
        PortugueseArticle.contraction(for: name) == "à" ? "à" : "a"
    }
}

/// Portuguese listing: "A", "A e B", "A, B e C".
enum PortugueseList {
    static func join(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " e " + names[names.count - 1]
        }
    }
}
