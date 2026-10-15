#if DEBUG || ORB_DEV_TOOLS
import SwiftUI

/// `Orb --snapshot settings-usage | settings-usage-empty out.png`: the Uso tab of Ajustes, with a month of made-up use (three Orbs,
/// models paid by use, by plan and on this Mac, one without a price) written into the data folder (a fresh temporary one, or the
/// one `ORB_DATA_DIR` names; see `DevRun`), or with none at all. `-usagePeriod today|week|month30|thisMonth` and
/// `-usageChartBy model` on the command line pick another view without saving anything.
@MainActor
enum UsageSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
        guard screen == "settings-usage" || screen == "settings-usage-empty" else { return nil }
        if screen == "settings-usage" { seed(model) }
        return AnyView(UsageSettings()
            .frame(width: 640, height: ProcessInfo.processInfo.environment["ORB_SNAPSHOT_HEIGHT"].flatMap(Double.init).map { CGFloat($0) } ?? SettingsTab.usage.height)
            .background(Palette.chrome)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    }

    private static let models: [(ref: String, name: String, provider: ProviderKind, id: String, weight: Int)] = [
        ("anthropic/claude-sonnet-5-5", "Claude Sonnet 5.5", .anthropic, "claude-sonnet-5-5", 5),
        ("openai/gpt-5.4", "GPT-5.4", .openai, "gpt-5.4", 3),
        ("claudeCode/sonnet", "Sonnet", .claudeCode, "sonnet", 4),
        ("ollama/qwen3", "Qwen3", .ollama, "qwen3", 2),
        ("openrouter/acme/modelo-novo", "acme/modelo-novo", .openrouter, "acme/modelo-novo", 1),
    ]

    /// Three Orbs, five models and the last 32 days, always the same numbers.
    private static func seed(_ model: AppModel) {
        model.providers = Dictionary(grouping: models, by: \.provider).map { kind, entries in
            var account = ProviderAccount(kind: kind)
            account.models = entries.map { ProviderModel(id: $0.id, name: $0.name, format: .chat) }
            return account
        }
        let atlas = model.bots[0].id
        let luna = Bot(name: "Luna", role: "Cuida da agenda", orb: OrbConfig(color: "rosa"))
        let theo = Bot(name: "Theo", role: "Revisa o código", orb: OrbConfig(color: "menta"))
        let known = Dictionary(model.bots.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        if known["Luna"] == nil { model.bots += [luna, theo] }
        let orbs = [atlas, known["Luna"] ?? luna.id, known["Theo"] ?? theo.id]
        var state: UInt64 = 20_261_009
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var rows: [UsageKey: UsageTotals] = [:]
        for back in 0..<32 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            // Quiet weekends; a heavier day now and then.
            if calendar.isDateInWeekend(day), next(3) != 0 { continue }
            for hour in [9, 10, 11, 14, 15, 16, 17, 21] where next(100) < (hour == 21 ? 25 : 70) {
                guard let start = calendar.date(byAdding: .hour, value: hour, to: day), start <= .now else { continue }
                for entry in models where next(10) < entry.weight + 1 {
                    let orb = orbs[(next(10) < 6) ? 0 : 1 + next(2)]
                    let isPlan = entry.provider == .claudeCode
                    let requests = isPlan ? 1 + next(2) : 2 + next(9)
                    let usage = TokenUsage(input: requests * (800 + next(2_400)), output: requests * (200 + next(1_200)),
                                           cacheRead: requests * (6_000 + next(20_000)), cacheWrite: next(3) == 0 ? 4_000 + next(8_000) : 0)
                    var totals = UsageTotals(usage, requests: requests)
                    if entry.provider == .anthropic { totals.cacheWrite1h = totals.cacheWrite / 2 }
                    if isPlan { totals.reportedCost = Double(totals.tokens) / 1_000_000 * 0.9 }
                    if entry.provider == .ollama { totals.cacheRead = 0; totals.cacheWrite = 0 }
                    let source: UsageSource = next(8) == 0 ? .routine : .chat
                    rows[UsageKey(hour: start, orb: orb, model: entry.ref, source: source), default: UsageTotals()].add(totals)
                }
            }
        }
        model.store.addUsage(rows, names: Dictionary(uniqueKeysWithValues: model.bots.map { ($0.id, $0.name) }))
        model.store.flush()
    }
}
#endif
