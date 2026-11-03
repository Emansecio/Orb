import Foundation

/// A bounded index of results. Conversations and routine runs remain the authoritative records.
struct InicioEntry: Codable, Equatable, Sendable, Identifiable {
    enum Origin: Codable, Equatable, Sendable {
        case chat(bot: UUID, chat: UUID, item: UUID)
        case routine(bot: UUID, routine: UUID, run: UUID)
    }

    enum Outcome: String, Codable, Sendable {
        case completed, failed, attention, skipped, recorded
    }

    /// The item or run id is stable across a retry or reconstruction of the index.
    var id: UUID
    var sequence: Int64
    var date: Date
    var origin: Origin
    var outcome: Outcome
    var summary: String

    var botID: UUID {
        switch origin {
        case .chat(let bot, _, _), .routine(let bot, _, _): bot
        }
    }
}

/// A row of Novidades: an entry, and how many runs of its routine it stands for.
struct InicioNews: Identifiable {
    var entry: InicioEntry
    var runs = 1
    var id: UUID { entry.id }

    /// Runs that went as planned fold into the newest of their routine (`entries` newest first): one every 30 minutes would
    /// otherwise fill the page with runs that found nothing. A failure or a run that asks for attention keeps its own row.
    static func folded(_ entries: [InicioEntry]) -> [InicioNews] {
        var result: [InicioNews] = []
        var rowOfRoutine: [UUID: Int] = [:]
        for entry in entries {
            guard case .routine(_, let routine, _) = entry.origin, entry.outcome == .completed || entry.outcome == .skipped else {
                result.append(InicioNews(entry: entry))
                continue
            }
            if let row = rowOfRoutine[routine] {
                result[row].runs += 1
            } else {
                rowOfRoutine[routine] = result.count
                result.append(InicioNews(entry: entry))
            }
        }
        return result
    }
}

/// Saved together with the visit cursor, so a cursor never overtakes its entries in the writer queue.
struct InicioHistory: Codable, Equatable, Sendable {
    var entries: [InicioEntry] = []
    var nextSequence: Int64 = 1
    /// nil means this version has not been visited yet.
    var lastVisit: Int64?

    static let limit = 500
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    mutating func append(id: UUID, date: Date, origin: InicioEntry.Origin, outcome: InicioEntry.Outcome,
                         summary: String, now: Date = .now) {
        guard !entries.contains(where: { $0.id == id }) else { return }
        // Keep the index bounded and keep an explicit sequence even if the clock moves backwards.
        guard nextSequence < Int64.max else { return }
        let text = RoutineRun.preview(of: summary, limit: 300)
        entries.append(InicioEntry(id: id, sequence: nextSequence, date: date, origin: origin, outcome: outcome, summary: text))
        nextSequence += 1
        prune(now: now)
    }

    mutating func prune(now: Date = .now) {
        entries.removeAll { $0.date < now.addingTimeInterval(-Self.retention) }
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// Restore only events newer than the durable state. Older journal entries may have been intentionally evicted.
    /// Keep their original sequence: the durable visit cursor must never accidentally consume a recovered event.
    mutating func recover(from journal: InicioHistory, accepts: (InicioEntry) -> Bool, now: Date = .now) {
        let floor = nextSequence
        var known = Set(entries.map(\.id))
        var usedSequences = Set(entries.map(\.sequence))
        for entry in journal.entries.sorted(by: { $0.sequence < $1.sequence }) {
            guard entry.sequence >= floor, entry.sequence < Int64.max,
                  entry.date >= now.addingTimeInterval(-Self.retention), accepts(entry),
                  known.insert(entry.id).inserted, usedSequences.insert(entry.sequence).inserted else { continue }
            entries.append(entry)
            nextSequence = max(nextSequence, entry.sequence + 1)
        }
        prune(now: now)
    }

    /// Capture the last row actually presented; later events remain new even when clocks have equal timestamps.
    mutating func finishVisit(through sequence: Int64?) {
        guard let sequence else {
            if lastVisit == nil { lastVisit = 0 }
            return
        }
        lastVisit = max(lastVisit ?? 0, sequence)
    }
}

extension InicioHistory {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.lossyArray(.entries)
        let stored = (try? c.decodeIfPresent(Int64.self, forKey: .nextSequence)) ?? nil
        let highest = entries.map(\.sequence).max() ?? 0
        nextSequence = max(stored ?? 1, highest < Int64.max ? highest + 1 : Int64.max, 1)
        let visit = (try? c.decodeIfPresent(Int64.self, forKey: .lastVisit)) ?? nil
        lastVisit = visit.map { min(max($0, 0), nextSequence - 1) }
    }
}
