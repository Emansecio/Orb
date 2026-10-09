import Foundation

// Where the use of models is written and read: `uso/yyyy-MM.json` in the data folder, one file per month, changed in
// batches on the store's own writer queue (never on the main thread), read on its concurrent queue.

extension Store {
    /// The folder of the month files.
    var usageFolder: URL { directory.appending(path: "uso", directoryHint: .isDirectory) }

    /// "2026-10", the file name of the month `date` falls in (in `calendar`).
    static func usageMonthID(of date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 1970, parts.month ?? 1)
    }

    private func usageURL(_ month: String) -> URL { usageFolder.appending(path: "\(month).json") }

    /// Adds rows to their months. Each month file is read, merged and written again on the writer queue, so batches
    /// from anywhere stay in order and a read waits for them (`FileGate`). A month file that cannot be decoded is set
    /// aside, as every data file is, and a new one starts.
    func addUsage(_ entries: [UsageKey: UsageTotals], names: [UUID: String], calendar: Calendar = .current) {
        let months = Dictionary(grouping: entries, by: { Self.usageMonthID(of: $0.key.hour, calendar: calendar) })
        for (month, rows) in months {
            let url = usageURL(month)
            let batch = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.value) })
            enqueue(touching: [url]) {
                // Blocked by an earlier read that could not open it: that was said once, and reading again would say it at
                // every flush.
                guard !Self.gate.isBlocked(url) else { return }
                let existing: StoreRead<UsageMonth> = read(UsageMonth.self, from: url, ifUnreadable: "o histórico do mês começou vazio")
                // What the read found (items left out, a file set aside) is news, not a failed write: the write below goes through.
                if let notice = existing.notice { onNotice?(notice) }
                // A file that exists but could not be read nor set aside is blocked for writes: the notice above said so,
                // and a write that fails by design would only report a save failure on top (which stops idle unloading).
                guard !Self.gate.isBlocked(url) else { return }
                var file = existing.value ?? UsageMonth()
                file.merge(batch, names: names)
                write(file, to: url)
            }
        }
    }

    /// The rows and Orb names of the months from `start` to `end`, read off the calling thread. A file that cannot be
    /// read comes back as a notice (and is set aside by the read itself).
    func readUsage(from start: Date, to end: Date, calendar: Calendar = .current) async -> (buckets: [UsageBucket], names: [UUID: String], notices: [StoreNotice]) {
        let ids = Self.usageMonths(from: start, to: end, calendar: calendar)
        return await withCheckedContinuation { continuation in
            Self.readQueue.async {
                var buckets: [UsageBucket] = [], names: [UUID: String] = [:], notices: [StoreNotice] = []
                for id in ids {
                    let url = usageURL(id)
                    let found = Self.gate.reading(url) { read(UsageMonth.self, from: url, ifUnreadable: "o histórico do mês foi ignorado") }
                    if let notice = found.notice { notices.append(notice) }
                    guard let month = found.value else { continue }
                    buckets += month.buckets
                    for (key, name) in month.orbNames { if let id = UUID(uuidString: key) { names[id] = name } }
                }
                continuation.resume(returning: (buckets, names, notices))
            }
        }
    }

    /// The ids of the months `start...end` touches, oldest first.
    static func usageMonths(from start: Date, to end: Date, calendar: Calendar = .current) -> [String] {
        var ids: [String] = []
        var cursor = calendar.dateInterval(of: .month, for: start)?.start ?? start
        while cursor <= end, ids.count < 600 {
            ids.append(usageMonthID(of: cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return ids
    }
}

/// Collects what the turns used and hands it to the store in batches: a turn of many steps is one write every few
/// seconds, not one per model call. Lives on the main actor because the events that carry the numbers do.
@MainActor
final class UsageRecorder {
    /// How long rows wait before they are written.
    static let flushDelay = Duration.seconds(10)

    private var store: Store
    private var pending: [UsageKey: UsageTotals] = [:]
    private var names: [UUID: String] = [:]
    private var flushTask: Task<Void, Never>?
    private let now: () -> Date
    private let calendar: Calendar
    /// After "Redefinir o Orb" nothing more is kept.
    private var isClosed = false

    init(store: Store, now: @escaping () -> Date = { .now }, calendar: Calendar = .current) {
        self.store = store
        self.now = now
        self.calendar = calendar
    }

    var hasPending: Bool { !pending.isEmpty }

    /// The store was copied into this recorder before the app wired its callbacks: take them from `other`.
    func adoptCallbacks(of other: Store) {
        store.onSaveFailure = other.onSaveFailure
        store.onNotice = other.onNotice
    }

    /// Counts a use of `model` by the Orb `orb`, in the hour it happened. Nothing is recorded for an empty use.
    func record(_ totals: UsageTotals, orb: UUID, name: String, model: String, source: UsageSource) {
        guard !isClosed, !totals.isEmpty else { return }
        let date = now()
        let hour = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        pending[UsageKey(hour: hour, orb: orb, model: model, source: source), default: UsageTotals()].add(totals)
        names[orb] = name
        if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: Self.flushDelay)
                if !Task.isCancelled { self?.flush() }
            }
        }
    }

    /// Hands what is pending to the store now (the app quitting, or the page about to read).
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return }
        store.addUsage(pending, names: names, calendar: calendar)
        pending = [:]
    }

    /// Forgets what is pending and keeps nothing more (the history is being erased).
    func close() {
        flushTask?.cancel()
        flushTask = nil
        pending = [:]
        isClosed = true
    }
}
