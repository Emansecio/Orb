import Foundation
import Testing
@testable import Orb

/// The sums behind the Uso page: periods, hour, day, Orb and model, the turn of the month, a routine's use, plans and local
/// models beside billed ones, and what is said when nothing was billed.
struct UsageReportTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private let atlas = UUID(), luna = UUID()
    private let sonnet = "anthropic/claude-sonnet-5-5" // US$ 2 in, 0.10 cached, 10 out per million
    private let gpt = "openai/gpt-5.4" // 2.50 in, 0.25 cached, 15 out

    private func bucket(_ date: Date, orb: UUID, model: String, source: UsageSource = .chat, _ totals: UsageTotals) -> UsageBucket {
        UsageBucket(key: UsageKey(hour: date, orb: orb, model: model, source: source), totals: totals)
    }

    private func report(_ buckets: [UsageBucket], _ period: UsagePeriod, now: Date = utcDate(2026, 10, 9, 15, 30),
                        book: PriceBook = PriceBook()) -> UsageReport {
        UsageReport.make(buckets: buckets, period: period, now: now, calendar: utc, book: book,
                         orbNames: [atlas: "Atlas", luna: "Luna"])
    }

    // MARK: Periods

    @Test func theFourPeriodsStartWhereTheirNamesSay() {
        let now = utcDate(2026, 10, 9, 15, 30)
        #expect(UsagePeriod.today.interval(now: now, calendar: utc).start == utcDate(2026, 10, 9))
        #expect(UsagePeriod.week.interval(now: now, calendar: utc).start == utcDate(2026, 10, 3)) // today and the six days before
        #expect(UsagePeriod.month30.interval(now: now, calendar: utc).start == utcDate(2026, 9, 10))
        #expect(UsagePeriod.thisMonth.interval(now: now, calendar: utc).start == utcDate(2026, 10, 1))
        #expect(UsagePeriod.thisMonth.interval(now: utcDate(2026, 11, 1, 0, 5), calendar: utc).start == utcDate(2026, 11, 1))
        #expect(UsagePeriod.allCases.map(\.title) == ["Hoje", "7 dias", "30 dias", "Este mês"])
        #expect(UsagePeriod.today.barUnit == .hour && UsagePeriod.week.barUnit == .day)
    }

    @Test func onlyTheHoursInsideThePeriodCount() {
        let total = UsageTotals(requests: 1, input: 1_000_000)
        let rows = [bucket(utcDate(2026, 10, 8, 23), orb: atlas, model: sonnet, total),   // yesterday
                    bucket(utcDate(2026, 10, 9, 0), orb: atlas, model: sonnet, total),    // today
                    bucket(utcDate(2026, 10, 9, 15), orb: atlas, model: sonnet, total),   // this hour
                    bucket(utcDate(2026, 10, 9, 16), orb: atlas, model: sonnet, total)]   // the future (a clock set back)
        #expect(report(rows, .today).totalRequests == 2)
        #expect(report(rows, .week).totalRequests == 3)
    }

    @Test func theTurnOfTheMonthIsOnePeriodForThirtyDaysAndTwoForThisMonth() {
        let total = UsageTotals(requests: 1, input: 1_000_000)
        let rows = [bucket(utcDate(2026, 9, 30, 23), orb: atlas, model: sonnet, total),
                    bucket(utcDate(2026, 10, 1, 0), orb: atlas, model: sonnet, total)]
        let now = utcDate(2026, 10, 2, 9)
        #expect(report(rows, .month30, now: now).totalRequests == 2)
        #expect(report(rows, .thisMonth, now: now).totalRequests == 1)
        // Two days, two bars.
        #expect(Set(report(rows, .month30, now: now).orbPoints.map(\.date)) == [utcDate(2026, 9, 30), utcDate(2026, 10, 1)])
    }

    // MARK: Sums

    @Test func costsAreSummedByOrbAndByModelAndRankedByCost() throws {
        let rows = [bucket(utcDate(2026, 10, 9, 10), orb: atlas, model: sonnet, UsageTotals(requests: 2, input: 1_000_000, output: 100_000)), // 2 + 1
                    bucket(utcDate(2026, 10, 9, 11), orb: luna, model: sonnet, UsageTotals(requests: 1, cacheRead: 10_000_000)),             // 1
                    bucket(utcDate(2026, 10, 9, 11), orb: luna, model: gpt, UsageTotals(requests: 4, input: 2_000_000))]                      // 5
        let report = report(rows, .today)
        #expect(abs(report.totalCost - 9) < 1e-9 && report.totalRequests == 7 && report.measure == .cost)
        #expect(report.totalTokens == 1_000_000 + 100_000 + 10_000_000 + 2_000_000)
        #expect(report.orbRows.map(\.name) == ["Luna", "Atlas"])
        #expect(abs(report.orbRows[0].cost - 6) < 1e-9 && abs(report.orbRows[1].cost - 3) < 1e-9)
        #expect(report.modelRows.map(\.id) == [gpt, sonnet])
        #expect(abs(report.modelRows[1].cost - 4) < 1e-9 && report.modelRows[1].requests == 3)
        // Shares of the total.
        #expect(abs(try #require(report.orbRows[0].share) - 6.0 / 9) < 1e-9)
        #expect(abs(report.orbRows.compactMap(\.share).reduce(0, +) - 1) < 1e-9)
        #expect(report.modelRows[0].detail == "OpenAI")
    }

    @Test func theHourOfTheDayAddsTokensAcrossDays() {
        let total = UsageTotals(requests: 1, input: 100)
        let rows = [bucket(utcDate(2026, 10, 9, 14), orb: atlas, model: sonnet, total),
                    bucket(utcDate(2026, 10, 8, 14), orb: atlas, model: sonnet, total),
                    bucket(utcDate(2026, 10, 7, 14), orb: luna, model: gpt, total),
                    bucket(utcDate(2026, 10, 7, 9), orb: luna, model: gpt, UsageTotals(requests: 1, output: 40))]
        let report = report(rows, .week)
        #expect(report.hourly[14] == 300 && report.hourly[9] == 40 && report.hourly.reduce(0, +) == 340)
    }

    @Test func theChartHasABarPerDayOrPerHourAndKeepsTheBiggestSeries() {
        let total = UsageTotals(requests: 1, input: 1_000_000)
        let rows = [bucket(utcDate(2026, 10, 9, 10), orb: atlas, model: sonnet, total),
                    bucket(utcDate(2026, 10, 9, 14), orb: atlas, model: sonnet, total),
                    bucket(utcDate(2026, 10, 8, 14), orb: luna, model: sonnet, total)]
        let week = report(rows, .week)
        #expect(Set(week.orbPoints.map(\.date)) == [utcDate(2026, 10, 8), utcDate(2026, 10, 9)])
        #expect(week.orbPoints.first { $0.date == utcDate(2026, 10, 9) }?.value == 4) // two hours of the same day, one bar
        let today = report(rows, .today)
        #expect(Set(today.orbPoints.map(\.date)) == [utcDate(2026, 10, 9, 10), utcDate(2026, 10, 9, 14)])
        // More series than colors: the smallest are one "Outros".
        let many = (0..<8).map { bucket(utcDate(2026, 10, 9, 10), orb: UUID(), model: sonnet, UsageTotals(requests: 1, input: 1_000_000 * ($0 + 1))) }
        let crowded = report(many, .today)
        #expect(crowded.orbSeries.count == UsageReport.seriesLimit + 1 && crowded.orbSeries.last?.id == UsageReport.othersID)
        #expect(abs(crowded.orbPoints.reduce(0) { $0 + $1.value } - crowded.totalCost) < 1e-9)
    }

    @Test func aRoutinesUseCountsLikeAnyOther() {
        let rows = [bucket(utcDate(2026, 10, 9, 8), orb: atlas, model: sonnet, source: .routine, UsageTotals(requests: 1, input: 1_000_000)),
                    bucket(utcDate(2026, 10, 9, 8), orb: atlas, model: sonnet, source: .chat, UsageTotals(requests: 1, input: 1_000_000)),
                    bucket(utcDate(2026, 10, 9, 8), orb: atlas, model: sonnet, source: .auxiliary, UsageTotals(requests: 1, input: 1_000_000))]
        let report = report(rows, .today)
        #expect(report.totalRequests == 3 && report.orbRows.count == 1 && report.orbRows[0].requests == 3)
        #expect(abs(report.totalCost - 6) < 1e-9)
    }

    // MARK: Plans, local models, no price

    @Test func plansAndLocalModelsAreNotInTheTotalButAreInTheLists() throws {
        var local = ProviderAccount(kind: .ollama)
        local.models = [ProviderModel(id: "qwen3", name: "Qwen3", format: .chat)]
        var cli = UsageTotals(requests: 1, input: 500_000, output: 50_000)
        cli.reportedCost = 0.8
        let rows = [bucket(utcDate(2026, 10, 9, 10), orb: atlas, model: sonnet, UsageTotals(requests: 1, input: 1_000_000)),
                    bucket(utcDate(2026, 10, 9, 10), orb: atlas, model: "claudeCode/sonnet", cli),
                    bucket(utcDate(2026, 10, 9, 10), orb: luna, model: "ollama/qwen3", UsageTotals(requests: 9, input: 9_000_000))]
        let report = report(rows, .today, book: PriceBook(accounts: [local]))
        #expect(abs(report.totalCost - 2) < 1e-9 && abs(report.totalEquivalent - 0.8) < 1e-9 && !report.hasUnpriced)
        let states = Dictionary(uniqueKeysWithValues: report.modelRows.map { ($0.id, $0.state) })
        #expect(states == [sonnet: .billed, "claudeCode/sonnet": .included, "ollama/qwen3": .free])
        #expect(report.modelRows.first { $0.id == "ollama/qwen3" }?.name == "Qwen3")
        #expect(report.orbRows.first { $0.name == "Luna" }?.state == .free)
    }

    @Test func aModelWithoutAPriceKeepsItsTokensAndFlagsThePage() throws {
        let rows = [bucket(utcDate(2026, 10, 9, 10), orb: atlas, model: "openrouter/acme/novo", UsageTotals(requests: 3, input: 3_000_000)),
                    bucket(utcDate(2026, 10, 9, 10), orb: atlas, model: sonnet, UsageTotals(requests: 1, input: 1_000_000))]
        let report = report(rows, .today)
        #expect(report.hasUnpriced && abs(report.totalCost - 2) < 1e-9 && report.totalTokens == 4_000_000)
        #expect(report.modelRows.first { $0.id == "openrouter/acme/novo" }?.state == .unpriced)
        #expect(report.orbRows[0].hasUnpriced && report.orbRows[0].state == .billed)
        // The user's correction prices it, and the row says so.
        let fixed = self.report(rows, .today, book: PriceBook(corrections: ["openrouter/acme/novo": ModelPrice(input: 1, output: 1)]))
        #expect(!fixed.hasUnpriced && abs(fixed.totalCost - 5) < 1e-9)
        #expect(fixed.modelRows.first { $0.id == "openrouter/acme/novo" }?.isCorrected == true)
    }

    @Test func whenNothingWasBilledTheListsAreInTokens() throws {
        let rows = [bucket(utcDate(2026, 10, 9, 10), orb: atlas, model: "claudeCode/sonnet", UsageTotals(requests: 2, input: 3_000)),
                    bucket(utcDate(2026, 10, 9, 10), orb: luna, model: "claudeCode/sonnet", UsageTotals(requests: 1, input: 1_000))]
        let report = report(rows, .today)
        #expect(report.measure == .tokens && report.totalCost == 0 && !report.isEmpty)
        #expect(abs(try #require(report.orbRows.first?.share) - 0.75) < 1e-9)
        #expect(report.orbPoints.reduce(0) { $0 + $1.value } == 4_000)
    }

    @Test func aDeletedOrbKeepsTheNameTheHistoryRemembers() {
        let gone = UUID()
        let rows = [bucket(utcDate(2026, 10, 9, 10), orb: gone, model: sonnet, UsageTotals(requests: 1, input: 1_000_000)),
                    bucket(utcDate(2026, 10, 9, 10), orb: UUID(), model: sonnet, UsageTotals(requests: 1, input: 1_000_000))]
        let named = UsageReport.make(buckets: rows, period: .today, now: utcDate(2026, 10, 9, 15), calendar: utc, book: PriceBook(),
                                     orbNames: [:], rememberedNames: [gone: "Orb antigo"])
        #expect(Set(named.orbRows.map(\.name)) == ["Orb antigo", "Orb apagado"])
    }

    @Test func nothingUsedIsAnEmptyReport() {
        #expect(report([], .week).isEmpty)
        #expect(report([bucket(utcDate(2026, 8, 1, 10), orb: atlas, model: sonnet, UsageTotals(requests: 1, input: 5))], .week).isEmpty)
    }

    // MARK: Words

    @Test func theNumbersAreSaidInPortuguese() {
        #expect(UsageFormat.dollars(12.4) == "US$ 12,40")
        #expect(UsageFormat.dollars(0) == "US$ 0,00")
        #expect(UsageFormat.dollars(0.001) == "< US$ 0,01")
        #expect(UsageFormat.dollars(1234.5).hasPrefix("US$ 1"))
        #expect(UsageFormat.share(0.42) == "42%" && UsageFormat.share(0.001) == "< 1%")
        #expect(UsageFormat.requests(1) == "1 pedido" && UsageFormat.requests(48) == "48 pedidos")
        #expect(UsageFormat.tokens(3_540) == "3,5 mil tokens" && UsageFormat.tokens(1_800_000) == "1,8 milhão de tokens")
        #expect(UsageFormat.tokens(2_000_000) == "2 milhões de tokens" && UsageFormat.tokens(400) == "400 tokens")
        #expect(UsageFormat.parsePrice("2,5") == 2.5 && UsageFormat.parsePrice(" 2.5 ") == 2.5)
        #expect(UsageFormat.parsePrice("") == nil && UsageFormat.parsePrice("abc") == nil && UsageFormat.parsePrice("-1") == nil)
        #expect(UsageFormat.parsePrice("999999") == nil)
        #expect(UsageFormat.priceText(0.075) == "0,075" && UsageFormat.priceText(15) == "15" && UsageFormat.priceText(nil) == "")
    }
}

@MainActor
struct UsagePageModelTests {
    @Test func thePageReadsWhatTheTurnsJustUsed() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbUsagePage-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let store = Store(directory: root)
        store.save(AppState.initial)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        let id = try #require(model.bots.first?.id)
        var account = ProviderAccount(kind: .openai)
        account.models = [ProviderModel(id: "gpt-5.4", name: "GPT-5.4", format: .responses)]
        model.providers = [account]
        model.defaultModel = "openai/gpt-5.4"
        model.apply(.requestUsage(TokenUsage(input: 1_000_000, output: 100_000)), to: id)

        let page = UsageModel()
        #expect(page.report == nil)
        await page.reload(model: model, period: .today, animation: nil)
        let report = try #require(page.report)
        // 1M in at 2.50 and 0.1M out at 15, still pending in the recorder when the page asked.
        #expect(report.totalRequests == 1 && abs(report.totalCost - 4) < 1e-9)
        #expect(report.orbRows.map(\.name) == [model.bots[0].name] && report.modelRows.map(\.name) == ["GPT-5.4"])

        #expect(SettingsTab.usage.title == "Uso" && SettingsTab.usage.symbol == "chart.bar")
    }
}
