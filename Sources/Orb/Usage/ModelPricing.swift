import Foundation

// What a use of a model costs: the price per million tokens (corrected by the user, read live from a provider's list, or
// from the table below), how the model is paid for (by use, by a plan, on this Mac) and the arithmetic.

/// US dollars per million tokens.
struct ModelPrice: Codable, Hashable, Sendable {
    var input: Double
    /// nil: the provider lists no price for cached input, so it is charged as input (the safe side).
    var cacheRead: Double?
    /// nil: charged as input (OpenAI and most gateways do not charge for writing the cache).
    var cacheWrite: Double?
    /// Writing the cache for an hour instead of five minutes (Anthropic: twice the input). nil: same as `cacheWrite`.
    var cacheWrite1h: Double?
    var output: Double

    /// A Claude price: Anthropic charges 1.25 times the input to write the cache for five minutes and twice for an hour.
    static func claude(input: Double, cacheRead: Double, output: Double) -> ModelPrice {
        ModelPrice(input: input, cacheRead: cacheRead, cacheWrite: input * 1.25, cacheWrite1h: input * 2, output: output)
    }

    /// Every figure times `factor` (a price that changes with the hour or the date).
    func scaled(by factor: Double) -> ModelPrice {
        ModelPrice(input: input * factor, cacheRead: cacheRead.map { $0 * factor }, cacheWrite: cacheWrite.map { $0 * factor },
                   cacheWrite1h: cacheWrite1h.map { $0 * factor }, output: output * factor)
    }

    /// The most a price the user types may be (per million tokens): a slip of the finger is not a price.
    static let highestAllowed = 10_000.0

    var isValid: Bool {
        [input, cacheRead ?? 0, cacheWrite ?? 0, cacheWrite1h ?? 0, output].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= Self.highestAllowed }
    }

    /// Dollars for `totals`' tokens.
    func cost(of totals: UsageTotals) -> Double {
        let hourLong = min(totals.cacheWrite1h, totals.cacheWrite)
        let fiveMinutes = totals.cacheWrite - hourLong
        let write = cacheWrite ?? input
        return (Double(totals.input) * input + Double(totals.cacheRead) * (cacheRead ?? input)
            + Double(fiveMinutes) * write + Double(hourLong) * (cacheWrite1h ?? write) + Double(totals.output) * output) / 1_000_000
    }
}

extension ModelPrice {
    /// Prices must be numbers from zero up; a damaged one is not a price.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func price(_ key: CodingKeys) throws -> Double? {
            guard let value = try c.decodeIfPresent(Double.self, forKey: key) else { return nil }
            guard value.isFinite, value >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "not a price")
            }
            return value
        }
        guard let input = try price(.input), let output = try price(.output) else {
            throw DecodingError.dataCorruptedError(forKey: .input, in: c, debugDescription: "no price")
        }
        self.init(input: input, cacheRead: try price(.cacheRead), cacheWrite: try price(.cacheWrite), cacheWrite1h: try price(.cacheWrite1h),
                  output: output)
    }
}

/// How the tokens of a model are paid for.
enum UsageBilling: Equatable, Sendable {
    /// By use: the provider bills the tokens (API keys, gateways, OpenRouter).
    case metered
    /// By a subscription (the ChatGPT or Claude plan, an OpenCode Go plan): the use is included up to the plan's limits.
    case plan
    /// On this Mac (Ollama, LM Studio, a gateway on localhost): nothing is billed.
    case local

    static func of(_ provider: ProviderKind, account: ProviderAccount?) -> UsageBilling {
        switch provider {
        case .chatgpt, .claudeCode, .opencodeGo: return .plan
        case .ollama, .lmstudio: return .local
        case .custom:
            let host = account.flatMap { URL(string: $0.baseURL)?.host?.lowercased() }
            return host.map { ["localhost", "127.0.0.1", "::1", "[::1]"].contains($0) || $0.hasSuffix(".localhost") } == true ? .local : .metered
        default: return .metered
        }
    }
}

/// Public prices of the models the providers the app supports are most used with, per million tokens. A table, not a
/// service: the app never asks anyone for a price. A model whose provider lists its own prices live (OpenRouter, OpenCode)
/// uses those instead; the user can correct any of them on the Uso page.
enum PriceTable {
    /// The day the official pages below were read, `yyyy-MM-dd`. Shown on the page ("preços públicos de …").
    static let consultedOn = "2026-10-09"

    /// Pages read on that day:
    /// - Anthropic: platform.claude.com/docs/en/about-claude/pricing (cache writes at 1.25 times the input for five
    ///   minutes and twice for an hour; the API says which in `usage.cache_creation`, and `UsageTotals.cacheWrite1h` keeps it)
    /// - OpenAI: developers.openai.com/api/docs/pricing (Standard tier, prompts up to 272K tokens)
    /// - Google: ai.google.dev/gemini-api/docs/pricing (paid tier, prompts up to 200K tokens)
    /// - DeepSeek: api-docs.deepseek.com/quick_start/pricing (peak-hours rate; see `adjustments`)
    /// - xAI: docs.x.ai/docs/models (prompts under 200K tokens)
    /// - GLM, Kimi, MiniMax, Qwen: opencode.ai/docs/zen (what the gateway charges for them)
    ///
    /// Models with a price above a prompt size are priced at the usual (smaller) size: the usage the app keeps is summed by
    /// the hour, so the size of each prompt is gone.
    private static let entries: [(id: String, price: ModelPrice)] = [
        // Anthropic
        ("claude-fable-5.1", .claude(input: 10, cacheRead: 0.25, output: 50)),
        ("claude-fable-5", .claude(input: 10, cacheRead: 1, output: 50)),
        ("claude-opus-5.5", .claude(input: 4, cacheRead: 0.2, output: 20)),
        ("claude-opus-5", .claude(input: 5, cacheRead: 0.5, output: 25)),
        ("claude-opus-4.8", .claude(input: 5, cacheRead: 0.5, output: 25)),
        ("claude-opus-4.7", .claude(input: 5, cacheRead: 0.5, output: 25)),
        ("claude-opus-4.6", .claude(input: 5, cacheRead: 0.5, output: 25)),
        ("claude-opus-4.5", .claude(input: 5, cacheRead: 0.5, output: 25)),
        ("claude-opus-4.1", .claude(input: 15, cacheRead: 1.5, output: 75)),
        ("claude-opus-4", .claude(input: 15, cacheRead: 1.5, output: 75)),
        ("claude-sonnet-5.5", .claude(input: 2, cacheRead: 0.1, output: 10)),
        ("claude-sonnet-5", .claude(input: 2, cacheRead: 0.2, output: 10)),
        ("claude-sonnet-4.6", .claude(input: 3, cacheRead: 0.3, output: 15)),
        ("claude-sonnet-4.5", .claude(input: 3, cacheRead: 0.3, output: 15)),
        ("claude-sonnet-4", .claude(input: 3, cacheRead: 0.3, output: 15)),
        ("claude-haiku-5.5", .claude(input: 0.1, cacheRead: 0.01, output: 0.5)),
        ("claude-haiku-4.5", .claude(input: 1, cacheRead: 0.1, output: 5)),
        ("claude-haiku-3.5", .claude(input: 0.8, cacheRead: 0.08, output: 4)),
        // OpenAI
        ("gpt-6-astra", .init(input: 10, cacheRead: 1, output: 50)),
        ("gpt-6.1-sol", .init(input: 2, cacheRead: 0.1, output: 10)),
        ("gpt-6-sol", .init(input: 2, cacheRead: 0.2, output: 10)),
        ("gpt-6-luna", .init(input: 0.1, cacheRead: 0.01, output: 0.5)),
        ("gpt-5.6-sol", .init(input: 4, cacheRead: 0.4, output: 20)),
        ("gpt-5.6-terra", .init(input: 2, cacheRead: 0.2, output: 12)),
        ("gpt-5.6-luna", .init(input: 0.2, cacheRead: 0.02, output: 1.2)),
        ("gpt-5.5", .init(input: 5, cacheRead: 0.5, output: 30)),
        ("gpt-5.5-pro", .init(input: 30, output: 180)),
        ("gpt-5.4", .init(input: 2.5, cacheRead: 0.25, output: 15)),
        ("gpt-5.4-mini", .init(input: 0.75, cacheRead: 0.075, output: 4.5)),
        ("gpt-5.4-nano", .init(input: 0.2, cacheRead: 0.02, output: 1.25)),
        ("gpt-5.4-pro", .init(input: 30, output: 180)),
        ("gpt-5.3-codex", .init(input: 1.75, cacheRead: 0.175, output: 14)),
        ("gpt-5.2", .init(input: 1.75, cacheRead: 0.175, output: 14)),
        ("gpt-5.2-pro", .init(input: 21, output: 168)),
        ("gpt-5.1", .init(input: 1.25, cacheRead: 0.125, output: 10)),
        ("gpt-5.1-codex-mini", .init(input: 0.25, cacheRead: 0.025, output: 2)), // OpenCode's table: OpenAI's page omits it
        ("gpt-5", .init(input: 1.25, cacheRead: 0.125, output: 10)),
        ("gpt-5-mini", .init(input: 0.25, cacheRead: 0.025, output: 2)),
        ("gpt-5-nano", .init(input: 0.05, cacheRead: 0.005, output: 0.4)),
        ("gpt-5-pro", .init(input: 15, output: 120)),
        ("gpt-4.1", .init(input: 2, cacheRead: 0.5, output: 8)),
        ("gpt-4.1-mini", .init(input: 0.4, cacheRead: 0.1, output: 1.6)),
        ("gpt-4.1-nano", .init(input: 0.1, cacheRead: 0.025, output: 0.4)),
        ("gpt-4o", .init(input: 2.5, cacheRead: 1.25, output: 10)),
        ("gpt-4o-2024-05-13", .init(input: 5, output: 15)), // the one dated model with its own price: the date is kept for it
        ("gpt-4o-mini", .init(input: 0.15, cacheRead: 0.075, output: 0.6)),
        ("o1", .init(input: 15, cacheRead: 7.5, output: 60)),
        ("o1-pro", .init(input: 150, output: 600)),
        ("o3", .init(input: 2, cacheRead: 0.5, output: 8)),
        ("o3-pro", .init(input: 20, output: 80)),
        ("o3-mini", .init(input: 1.1, cacheRead: 0.55, output: 4.4)),
        ("o4-mini", .init(input: 1.1, cacheRead: 0.275, output: 4.4)),
        // Google. The three Flash below are cheaper only through 2026-12-31 (see `adjustments`).
        ("gemini-3.8-flash", .init(input: 0.75, cacheRead: 0.075, output: 3.75)),
        ("gemini-3.7-flash", .init(input: 0.75, cacheRead: 0.075, output: 3.75)),
        ("gemini-3.6-flash", .init(input: 0.75, cacheRead: 0.075, output: 3.75)),
        ("gemini-3.5-flash", .init(input: 1.5, cacheRead: 0.15, output: 9)),
        ("gemini-3.5-flash-lite", .init(input: 0.3, cacheRead: 0.03, output: 2.5)),
        ("gemini-3.1-flash-lite", .init(input: 0.25, cacheRead: 0.025, output: 1.5)),
        ("gemini-3.1-pro", .init(input: 2, cacheRead: 0.2, output: 12)),
        ("gemini-3-flash", .init(input: 0.5, cacheRead: 0.05, output: 3)),
        ("gemini-2.5-pro", .init(input: 1.25, cacheRead: 0.125, output: 10)),
        ("gemini-2.5-flash", .init(input: 0.3, cacheRead: 0.03, output: 2.5)),
        ("gemini-2.5-flash-lite", .init(input: 0.1, cacheRead: 0.01, output: 0.4)),
        // DeepSeek at the peak-hours rate, half outside it (see `adjustments`); the older names are billed at the Flash price
        ("deepseek-flash", .init(input: 0.3, cacheRead: 0.006, output: 1.2)),
        ("deepseek-v4.1-flash", .init(input: 0.3, cacheRead: 0.006, output: 1.2)),
        ("deepseek-v4-flash", .init(input: 0.3, cacheRead: 0.006, output: 1.2)),
        ("deepseek-v4-pro", .init(input: 1.32, cacheRead: 0.044, output: 3.96)),
        // xAI
        ("grok-4.7", .init(input: 2, cacheRead: 0.5, output: 6)),
        ("grok-4.6", .init(input: 2, cacheRead: 0.5, output: 6)),
        ("grok-4.5", .init(input: 2, cacheRead: 0.3, output: 6)),
        ("grok-4.3", .init(input: 1.25, cacheRead: 0.2, output: 2.5)),
        ("grok-4.20-0309-reasoning", .init(input: 1.25, cacheRead: 0.2, output: 2.5)),
        ("grok-4.20-0309-non-reasoning", .init(input: 1.25, cacheRead: 0.2, output: 2.5)),
        ("grok-4.20-multi-agent-0309", .init(input: 1.25, cacheRead: 0.2, output: 2.5)),
        ("grok-build-0.1", .init(input: 1, cacheRead: 0.2, output: 2)),
        // Open models, as OpenCode Zen charges for them
        ("glm-5.3-flash", .init(input: 0.15, cacheRead: 0.03, output: 0.5)),
        ("glm-5.3", .init(input: 1.4, cacheRead: 0.26, output: 4.4)),
        ("glm-5.2", .init(input: 1.4, cacheRead: 0.26, output: 4.4)),
        ("glm-5.1", .init(input: 1.4, cacheRead: 0.26, output: 4.4)),
        ("glm-5", .init(input: 1, cacheRead: 0.2, output: 3.2)),
        ("kimi-k3", .init(input: 3, cacheRead: 0.3, output: 15)),
        ("kimi-k2.7-code", .init(input: 0.95, cacheRead: 0.19, output: 4)),
        ("kimi-k2.6", .init(input: 0.95, cacheRead: 0.16, output: 4)),
        ("kimi-k2.5", .init(input: 0.6, cacheRead: 0.1, output: 3)),
        ("minimax-m3", .init(input: 0.3, cacheRead: 0.06, output: 1.2)),
        ("minimax-m2.7", .init(input: 0.3, cacheRead: 0.06, output: 1.2)),
        ("minimax-m2.5", .init(input: 0.3, cacheRead: 0.06, output: 1.2)),
        ("qwen3.8-max", .init(input: 2, cacheRead: 0.25, cacheWrite: 2.5, output: 6)),
        ("qwen3.8-flash", .init(input: 0.15, cacheRead: 0.016, cacheWrite: 0.2, output: 0.47)),
        ("qwen3.7-max", .init(input: 2.5, cacheRead: 0.5, cacheWrite: 3.125, output: 7.5)),
        ("qwen3.7-plus", .init(input: 0.4, cacheRead: 0.04, cacheWrite: 0.5, output: 1.6)),
        ("qwen3.6-plus", .init(input: 0.5, cacheRead: 0.05, cacheWrite: 0.625, output: 3)),
        ("qwen3.5-plus", .init(input: 0.2, cacheRead: 0.02, cacheWrite: 0.25, output: 1.2)),
    ]

    /// A price that moves with the time: the factor to apply to the table's price of these models at an instant.
    private struct Adjustment: Sendable {
        let ids: Set<String>
        let factor: @Sendable (Date) -> Double
    }

    private static let adjustments: [Adjustment] = [
        // DeepSeek charges half outside the peak hours. Chinese public holidays are off-peak too; the app does not know them
        // and counts those days as peak (the estimate errs high).
        Adjustment(ids: Set(["deepseek-flash", "deepseek-v4.1-flash", "deepseek-v4-flash", "deepseek-v4-pro"].map { normalized($0) }),
                   factor: { isDeepSeekPeak($0) ? 1 : 0.5 }),
        // Google doubles these three on 2027-01-01.
        Adjustment(ids: Set(["gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash"].map { normalized($0) }),
                   factor: { $0 >= geminiRaise ? 2 : 1 }),
    ]

    /// 2027-01-01 00:00 UTC.
    private static let geminiRaise = Date(timeIntervalSince1970: 1_798_761_600)

    /// DeepSeek's peak hours: 01:00-04:00 and 06:00-10:00 UTC, Monday to Friday.
    static func isDeepSeekPeak(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, (2...6).contains(weekday) else { return false }
        return (1..<4).contains(hour) || (6..<10).contains(hour)
    }

    private static let byID: [String: ModelPrice] = Dictionary(
        entries.map { (normalized($0.id, stripDate: false), $0.price) }, uniquingKeysWith: { first, _ in first })
    /// Longest first, so the most specific entry wins a prefix match.
    private static let idsByLength = byID.keys.sorted { ($0.count, $0) > ($1.count, $1) }

    /// The id as the table spells it: lowercase, without the provider's prefix (`anthropic/`), a suffix after `:`
    /// (`:thinking`), a date (`-20250929`, `-2025-09-29`, unless `stripDate` is off) or `-latest`, and dots as dashes
    /// (`claude-sonnet-4.5` = `claude-sonnet-4-5`).
    static func normalized(_ id: String, stripDate: Bool = true) -> String {
        var text = id.lowercased()
        if let slash = text.lastIndex(of: "/") { text = String(text[text.index(after: slash)...]) }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        text = text.replacingOccurrences(of: ".", with: "-")
        if text.hasSuffix("-latest") { text = String(text.dropLast("-latest".count)) }
        if stripDate, let range = text.range(of: #"-(\d{8}|\d{4}-\d{2}-\d{2})$"#, options: .regularExpression) { text.removeSubrange(range) }
        return text
    }

    /// What a name may add to a listed model's id and still cost the same (`gpt-5.4-codex`, `gemini-2.5-flash-preview-05-20`).
    /// Anything else (`-pro`, `-deep-research`, `-mini`, `-image`) is another price and is left unpriced.
    private static let sameFamilySuffixes: Set<String> = ["codex", "preview", "customtools", "chat", "thinking", "max"]

    /// The key of `byID` that prices a model id: the id itself (dated or not), else the longest entry it extends by a
    /// same-family suffix, never by a version (`claude-opus-4.9` is not `claude-opus-4`).
    private static func key(forModel id: String) -> String? {
        if byID[normalized(id, stripDate: false)] != nil { return normalized(id, stripDate: false) }
        let id = normalized(id)
        if byID[id] != nil { return id }
        for key in idsByLength where id.hasPrefix(key + "-") {
            let parts = id.dropFirst(key.count + 1).split(separator: "-").map(String.init)
            let isNumber: (String) -> Bool = { $0.allSatisfy(\.isNumber) }
            if parts.contains(where: { !isNumber($0) }), parts.allSatisfy({ sameFamilySuffixes.contains($0) || isNumber($0) }) { return key }
        }
        return nil
    }

    /// The table's price for a model id, at the hour `date` when the model's price depends on it (nil: the table's usual price).
    static func price(forModel id: String, at date: Date? = nil) -> ModelPrice? {
        guard let key = key(forModel: id), let base = byID[key] else { return nil }
        guard let date, let adjustment = adjustments.first(where: { $0.ids.contains(key) }) else { return base }
        let factor = adjustment.factor(date)
        return factor == 1 ? base : base.scaled(by: factor)
    }

    /// "9 de outubro de 2026" (the day the prices were read).
    static var consultedText: String {
        guard let date = try? Date(consultedOn, strategy: .iso8601.year().month().day()) else { return consultedOn }
        return date.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: Locale(identifier: "pt_BR"), timeZone: .gmt))
    }
}

/// Where a price comes from, to say it on the page.
enum PriceSource: Equatable, Sendable {
    /// The user typed it.
    case corrected
    /// The provider's own list of models gave it (OpenRouter, OpenCode).
    case catalog
    /// The embedded table.
    case table
}

/// What the page needs to put a price on a model: the user's corrections, the providers' lists and which providers are set up.
struct PriceBook: Sendable {
    var corrections: [String: ModelPrice] = [:]
    var accounts: [ProviderAccount] = []

    /// The price of "provider/model" and where it came from. nil: nobody knows it.
    func price(for model: String, at date: Date? = nil) -> (price: ModelPrice, source: PriceSource)? {
        if let corrected = corrections[model] { return (corrected, .corrected) }
        guard let ref = ModelRef(model) else { return nil }
        if let listed = accounts.first(where: { $0.kind == ref.provider })?.models.first(where: { $0.id == ref.model })?.price {
            return (listed, .catalog)
        }
        return PriceTable.price(forModel: ref.model, at: date).map { ($0, .table) }
    }

    func billing(for model: String) -> UsageBilling {
        guard let ref = ModelRef(model) else { return .metered }
        return .of(ref.provider, account: accounts.first { $0.kind == ref.provider })
    }

    /// What `totals` of `model` used in the hour `hour` cost, and in which of the page's three ways to say it.
    func cost(of totals: UsageTotals, model: String, at hour: Date? = nil) -> UsageCost {
        switch billing(for: model) {
        case .local:
            return .free
        case .plan:
            // The plan covers it; the equivalent at API prices is the user's own price when they set one, else the CLI's figure, else worked out.
            if corrections[model] != nil { return .included(equivalent: price(for: model, at: hour)?.price.cost(of: totals)) }
            return .included(equivalent: totals.reportedCost ?? price(for: model, at: hour)?.price.cost(of: totals))
        case .metered:
            if let reported = totals.reportedCost { return .paid(reported) }
            if let found = price(for: model, at: hour) { return .paid(found.price.cost(of: totals)) }
            return totals.tokens == 0 ? .paid(0) : .unpriced
        }
    }
}

/// The cost of a use, as the page says it.
enum UsageCost: Equatable, Sendable {
    /// Billed by the provider: this many dollars.
    case paid(Double)
    /// Covered by a plan; the dollars are what it would cost at API prices (nil: no price to tell).
    case included(equivalent: Double?)
    /// On this Mac.
    case free
    /// Tokens known, no price: "sem preço".
    case unpriced
}
