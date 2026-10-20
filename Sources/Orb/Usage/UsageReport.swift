import Foundation

// What the Uso page shows, worked out from the rows of the history: pure and `Sendable`, so the page makes it off the main
// thread and the tests make it from rows written by hand.

/// The stretch of time the page covers.
enum UsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case today, week, month30, thisMonth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Hoje"
        case .week: "7 dias"
        case .month30: "30 dias"
        case .thisMonth: "Este mês"
        }
    }

    /// From the start of its first day to `now`.
    func interval(now: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let start: Date
        switch self {
        case .today: start = today
        case .week: start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month30: start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .thisMonth: start = calendar.dateInterval(of: .month, for: now)?.start ?? today
        }
        return DateInterval(start: start, end: max(now, start))
    }

    /// The chart has a bar per hour for today, per day otherwise.
    var barUnit: Calendar.Component { self == .today ? .hour : .day }
}

/// What the lists and the chart are measured in: dollars, or tokens while nothing was billed (a plan, a local model).
enum UsageMeasure: Sendable {
    case cost, tokens
}

/// How a model's use is told in a row.
enum UsageRowState: Equatable, Sendable {
    /// Billed by the provider.
    case billed
    /// Covered by a plan; `equivalent` is what it would have cost at API prices (nil: no price to say).
    case included
    /// On this Mac.
    case free
    /// Tokens and no price.
    case unpriced
}

/// A line of "Por Orb" or "Por modelo".
struct UsageRow: Identifiable, Equatable, Sendable {
    /// The Orb's id, or "provider/model".
    var id: String
    var name: String
    /// The provider of a model (nil for an Orb).
    var detail: String?
    var state: UsageRowState
    /// Dollars billed.
    var cost = 0.0
    /// Dollars the plan's use would have cost at API prices.
    var equivalent = 0.0
    /// New tokens: charged in full, written to the cache, and the reply (`UsageTotals.budgetTokens`).
    var tokens = 0
    /// Tokens reread from the cache, at a tenth of the price: kept apart so they do not pass for new content.
    var cached = 0
    var requests = 0
    /// Share of the page's total in its measure, 0...1 (nil when there is no total).
    var share: Double?
    /// Whether the line has a model nobody could price (an Orb that used one).
    var hasUnpriced = false
    /// Whether the user's correction sets the price (models only).
    var isCorrected = false
}

/// One bar segment of the chart.
struct UsagePoint: Identifiable, Equatable, Sendable {
    var date: Date
    var series: String
    var value: Double
    var id: String { "\(date.timeIntervalSince1970)|\(series)" }
}

struct UsageSeries: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
}

struct UsageReport: Equatable, Sendable {
    var period: UsagePeriod
    var interval: DateInterval
    var measure: UsageMeasure = .cost
    /// Dollars billed in the period.
    var totalCost = 0.0
    /// Dollars the plans' use would have cost at API prices.
    var totalEquivalent = 0.0
    /// New tokens (see `UsageRow.tokens`) and the ones read back from the cache.
    var totalTokens = 0
    var totalCached = 0
    var totalRequests = 0
    /// Some of the use has a model nobody could price.
    var hasUnpriced = false
    var orbRows: [UsageRow] = []
    var modelRows: [UsageRow] = []
    /// The chart, once by Orb and once by model: the few biggest series, the rest together as "Outros".
    var orbSeries: [UsageSeries] = []
    var modelSeries: [UsageSeries] = []
    var orbPoints: [UsagePoint] = []
    var modelPoints: [UsagePoint] = []
    /// Tokens used in each hour of the day (0...23), summed over the period.
    var hourly = [Int](repeating: 0, count: 24)

    var isEmpty: Bool { totalRequests == 0 && totalTokens == 0 && totalCached == 0 && totalCost == 0 }

    /// Series kept apart in the chart; the rest are "Outros".
    static let seriesLimit = 5
    static let othersID = "outros"

    /// `orbNames`: the Orbs the app has now, by id (a deleted Orb keeps the name the history remembers, `rememberedNames`).
    static func make(buckets: [UsageBucket], period: UsagePeriod, now: Date, calendar: Calendar = .current, book: PriceBook,
                     orbNames: [UUID: String], rememberedNames: [UUID: String] = [:]) -> UsageReport {
        let interval = period.interval(now: now, calendar: calendar)
        var report = UsageReport(period: period, interval: interval)

        struct Sum {
            var cost = 0.0, equivalent = 0.0, tokens = 0, cached = 0, requests = 0
            var hasUnpriced = false
            var hasPlan = false, hasLocal = false, hasBilled = false
        }
        var byOrb: [UUID: Sum] = [:], byModel: [String: Sum] = [:]
        var unitSums: [Date: [UUID: Sum]] = [:], unitModelSums: [Date: [String: Sum]] = [:]

        for bucket in buckets where bucket.key.hour >= interval.start && bucket.key.hour <= interval.end {
            let key = bucket.key, totals = bucket.totals
            var piece = Sum(tokens: totals.budgetTokens, cached: totals.cacheRead, requests: totals.requests)
            switch book.cost(of: totals, model: key.model, at: key.hour) {
            case .paid(let dollars): piece.cost = dollars; piece.hasBilled = true
            case .included(let equivalent): piece.equivalent = equivalent ?? 0; piece.hasPlan = true
            case .free: piece.hasLocal = true
            case .unpriced: piece.hasUnpriced = true
            }
            func add(_ sum: inout Sum) {
                sum.cost += piece.cost
                sum.equivalent += piece.equivalent
                sum.tokens += piece.tokens
                sum.cached += piece.cached
                sum.requests += piece.requests
                sum.hasUnpriced = sum.hasUnpriced || piece.hasUnpriced
                sum.hasPlan = sum.hasPlan || piece.hasPlan
                sum.hasLocal = sum.hasLocal || piece.hasLocal
                sum.hasBilled = sum.hasBilled || piece.hasBilled
            }
            add(&byOrb[key.orb, default: Sum()])
            add(&byModel[key.model, default: Sum()])
            let unit = calendar.dateInterval(of: period.barUnit, for: key.hour)?.start ?? key.hour
            add(&unitSums[unit, default: [:]][key.orb, default: Sum()])
            add(&unitModelSums[unit, default: [:]][key.model, default: Sum()])
            report.hourly[calendar.component(.hour, from: key.hour)] += piece.tokens
            report.totalCost += piece.cost
            report.totalEquivalent += piece.equivalent
            report.totalTokens += piece.tokens
            report.totalCached += piece.cached
            report.totalRequests += piece.requests
            report.hasUnpriced = report.hasUnpriced || piece.hasUnpriced
        }

        report.measure = report.totalCost > 0 ? .cost : .tokens
        func value(_ sum: Sum) -> Double { report.measure == .cost ? sum.cost : Double(sum.tokens) }
        let total = report.measure == .cost ? report.totalCost : Double(report.totalTokens)
        func state(_ sum: Sum) -> UsageRowState {
            if sum.hasBilled { return .billed }
            if sum.hasPlan { return .included }
            if sum.hasLocal { return .free }
            return sum.hasUnpriced ? .unpriced : .billed
        }
        func order(_ a: UsageRow, _ b: UsageRow) -> Bool {
            (a.cost, a.equivalent, Double(a.tokens), b.name) > (b.cost, b.equivalent, Double(b.tokens), a.name)
        }

        report.orbRows = byOrb.map { id, sum in
            UsageRow(id: id.uuidString, name: orbNames[id] ?? rememberedNames[id] ?? "Orb apagado", state: state(sum), cost: sum.cost,
                     equivalent: sum.equivalent, tokens: sum.tokens, cached: sum.cached, requests: sum.requests,
                     share: total > 0 ? value(sum) / total : nil, hasUnpriced: sum.hasUnpriced)
        }.sorted(by: order)
        report.modelRows = byModel.map { model, sum in
            UsageRow(id: model, name: book.displayName(for: model), detail: book.providerName(for: model), state: state(sum), cost: sum.cost,
                     equivalent: sum.equivalent, tokens: sum.tokens, cached: sum.cached, requests: sum.requests,
                     share: total > 0 ? value(sum) / total : nil, hasUnpriced: sum.hasUnpriced,
                     isCorrected: book.corrections[model] != nil)
        }.sorted(by: order)

        // The chart: the biggest series by name, the rest as one.
        func chart<Key: Hashable>(_ units: [Date: [Key: Sum]], rows: [UsageRow], id: (Key) -> String)
            -> (series: [UsageSeries], points: [UsagePoint]) {
            // Only what has something to draw (a plan's use is no dollars): the biggest few by name, the rest together.
            let drawn = rows.filter { (report.measure == .cost ? $0.cost : Double($0.tokens)) > 0 }
            let kept = Set(drawn.prefix(seriesLimit).map(\.id))
            var series = drawn.prefix(seriesLimit).map { UsageSeries(id: $0.id, name: $0.name) }
            if drawn.count > seriesLimit { series.append(UsageSeries(id: othersID, name: "Outros")) }
            var points: [UsagePoint] = []
            for (date, sums) in units.sorted(by: { $0.key < $1.key }) {
                var grouped: [String: Double] = [:]
                for (key, sum) in sums {
                    let name = id(key)
                    grouped[kept.contains(name) ? name : othersID, default: 0] += value(sum)
                }
                points += series.compactMap { s in grouped[s.id].flatMap { $0 > 0 ? UsagePoint(date: date, series: s.id, value: $0) : nil } }
            }
            return (series, points)
        }
        (report.orbSeries, report.orbPoints) = chart(unitSums, rows: report.orbRows, id: { $0.uuidString })
        (report.modelSeries, report.modelPoints) = chart(unitModelSums, rows: report.modelRows, id: { $0 })
        return report
    }
}

extension PriceBook {
    /// The model's name as its provider lists it, else the id.
    func displayName(for model: String) -> String {
        guard let ref = ModelRef(model) else { return model }
        return accounts.first { $0.kind == ref.provider }?.models.first { $0.id == ref.model }?.name ?? ref.model
    }

    /// "Claude Code", "OpenAI"…: who the model comes through.
    func providerName(for model: String) -> String? {
        ModelRef(model)?.provider.shortName
    }
}
