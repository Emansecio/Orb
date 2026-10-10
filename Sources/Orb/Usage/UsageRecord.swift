import Foundation

// What the app keeps of the use of models: one small row per hour × Orb × model × source, with the tokens the providers
// reported. Nothing about the conversations. The rows of a month live in `uso/yyyy-MM.json` (see `UsageStore.swift`);
// the cost is not stored, it is worked out when the page is opened (`ModelPricing.swift`), so a corrected price also
// fixes the past. The one exception is the cost the Claude Code CLI itself reports.

/// Where a use of a model came from.
enum UsageSource: String, Codable, Sendable, CaseIterable {
    /// A turn of the chat (or of the menu bar's quick ask).
    case chat
    /// A turn of a routine, run by the scheduler.
    case routine
    /// A call the app makes for itself, outside any turn (see `AppModel.recordAuxiliaryUsage`).
    case auxiliary
    /// A turn an Orb ran for a request from another Orb.
    case delegation
    /// A turn an Orb ran in a group.
    case group
    /// The "Criar conversando" assistant.
    case creation

    /// A source from a newer build reads as chat.
    init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .chat) }
}

/// What one row is about.
struct UsageKey: Hashable, Codable, Sendable {
    /// The start of the local hour.
    var hour: Date
    var orb: UUID
    /// "provider/model" (`ModelRef.text`).
    var model: String
    var source: UsageSource
}

/// What was used in it.
struct UsageTotals: Codable, Equatable, Sendable {
    /// Calls to the model (one per turn for Claude Code, whose CLI reports the turn as a whole).
    var requests = 0
    /// A count is kept within 0...TokenUsage.maxCount: one absurd number (a damaged file, a broken server) never overflows a sum.
    private static func capped(_ count: Int) -> Int { min(max(0, count), TokenUsage.maxCount) }

    /// Prompt tokens charged in full, read from the cache, written to it, and tokens written by the model.
    var input = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// Of `cacheWrite`, the tokens written for an hour (Anthropic charges twice the input for them, 1.25 for five minutes).
    var cacheWrite1h = 0
    var output = 0
    /// The cost the provider's own tool reported, in dollars (Claude Code's `total_cost_usd`); nil when none did.
    var reportedCost: Double?

    var tokens: Int { input + cacheRead + cacheWrite + output }
    var isEmpty: Bool { requests == 0 && tokens == 0 && reportedCost == nil }

    init(requests: Int = 0, input: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int = 0, output: Int = 0,
         reportedCost: Double? = nil) {
        self.requests = Self.capped(requests)
        self.input = Self.capped(input)
        self.cacheRead = Self.capped(cacheRead)
        self.cacheWrite = Self.capped(cacheWrite)
        self.cacheWrite1h = min(Self.capped(cacheWrite1h), self.cacheWrite)
        self.output = Self.capped(output)
        self.reportedCost = reportedCost
    }

    init(_ usage: TokenUsage, requests: Int = 1, reportedCost: Double? = nil) {
        self.init(requests: requests, input: max(0, usage.input ?? 0), cacheRead: max(0, usage.cacheRead ?? 0),
                  cacheWrite: max(0, usage.cacheWrite ?? 0), cacheWrite1h: max(0, usage.cacheWrite1h ?? 0), output: max(0, usage.output ?? 0),
                  reportedCost: reportedCost)
    }

    mutating func add(_ other: UsageTotals) {
        requests = Self.capped(requests + other.requests)
        input = Self.capped(input + other.input)
        cacheRead = Self.capped(cacheRead + other.cacheRead)
        cacheWrite = Self.capped(cacheWrite + other.cacheWrite)
        cacheWrite1h = min(Self.capped(cacheWrite1h + other.cacheWrite1h), cacheWrite)
        output = Self.capped(output + other.output)
        if let cost = other.reportedCost { reportedCost = (reportedCost ?? 0) + cost }
    }

    /// A count that is missing, negative or not a number reads as zero, so one damaged row never breaks a sum.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) -> Int { Self.capped((try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0) }
        requests = count(.requests)
        input = count(.input)
        cacheRead = count(.cacheRead)
        cacheWrite = count(.cacheWrite)
        cacheWrite1h = min(count(.cacheWrite1h), cacheWrite)
        output = count(.output)
        let cost = (try? c.decodeIfPresent(Double.self, forKey: .reportedCost)) ?? nil
        reportedCost = cost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

/// A row of a month file: the key and the totals side by side, so the file reads like a table.
struct UsageBucket: Codable, Equatable, Sendable {
    var key: UsageKey
    var totals: UsageTotals

    private enum CodingKeys: String, CodingKey { case hour, orb, model, source }

    init(key: UsageKey, totals: UsageTotals) {
        self.key = key
        self.totals = totals
    }

    /// The hour is whole seconds since 1970; a row without hour, Orb or model cannot be placed and is skipped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let seconds = try c.decode(Int.self, forKey: .hour)
        guard let orb = UUID(uuidString: try c.decode(String.self, forKey: .orb)) else {
            throw DecodingError.dataCorruptedError(forKey: .orb, in: c, debugDescription: "not an id")
        }
        let model = try c.decode(String.self, forKey: .model)
        let source = (try? c.decodeIfPresent(UsageSource.self, forKey: .source)) ?? .chat
        key = UsageKey(hour: Date(timeIntervalSince1970: TimeInterval(seconds)), orb: orb, model: model, source: source)
        totals = try UsageTotals(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Int(key.hour.timeIntervalSince1970), forKey: .hour)
        try c.encode(key.orb.uuidString, forKey: .orb)
        try c.encode(key.model, forKey: .model)
        try c.encode(key.source, forKey: .source)
        try totals.encode(to: encoder)
    }
}

/// One month of rows, plus the names the Orbs had when they were used (an Orb deleted or renamed since is still named).
struct UsageMonth: Codable, Equatable, Sendable {
    /// A month file never holds more rows than this: a hour × Orb × model × source row is a few hundred bytes, and a real
    /// month has some thousands at most. Past it new rows are counted in `dropped` instead of growing the file.
    static let maxBuckets = 20_000

    var version = 1
    var orbNames: [String: String] = [:]
    var buckets: [UsageBucket] = []
    /// Rows that did not fit.
    var dropped = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.value(.version, default: 1)
        orbNames = (try? c.decodeIfPresent([String: String].self, forKey: .orbNames)) ?? [:]
        buckets = try c.lossyArray(.buckets)
        dropped = max(0, (try? c.decodeIfPresent(Int.self, forKey: .dropped)) ?? 0)
    }

    /// Adds `entries` (merging into the rows that already exist) and the Orbs' names.
    mutating func merge(_ entries: [UsageKey: UsageTotals], names: [UUID: String]) {
        var index: [UsageKey: Int] = [:]
        for (position, bucket) in buckets.enumerated() { index[bucket.key] = position }
        for (key, totals) in entries.sorted(by: { $0.key.hour < $1.key.hour }) where !totals.isEmpty {
            if let position = index[key] {
                buckets[position].totals.add(totals)
            } else if buckets.count < Self.maxBuckets {
                index[key] = buckets.count
                buckets.append(UsageBucket(key: key, totals: totals))
            } else {
                dropped += 1
            }
        }
        for (id, name) in names { orbNames[id.uuidString] = name }
    }
}
