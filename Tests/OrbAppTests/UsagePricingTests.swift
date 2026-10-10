import Foundation
import Testing
@testable import Orb

/// What a use of a model costs: the arithmetic (cheap cache, plans, local models, models without a price), the table and how
/// an id finds its entry, the providers' own lists, and the corrections the user types.
struct UsagePricingTests {
    private let sonnet = ModelPrice(input: 2, cacheRead: 0.1, cacheWrite: 2.5, output: 10)

    // MARK: Arithmetic

    @Test func cachedTokensCostWhatTheirPriceSays() {
        let totals = UsageTotals(requests: 3, input: 1_000_000, cacheRead: 1_000_000, cacheWrite: 200_000, output: 100_000)
        // 1M × 2 + 1M × 0.1 + 0.2M × 2.5 + 0.1M × 10
        #expect(abs(sonnet.cost(of: totals) - 3.6) < 1e-9)
        // The same tokens without the cache would cost far more: 2.2M × 2 + 0.1M × 10.
        #expect(ModelPrice(input: 2, output: 10).cost(of: totals) > sonnet.cost(of: totals))
    }

    @Test func aPriceWithoutACachePriceChargesTheCacheAsInput() {
        let price = ModelPrice(input: 4, output: 8)
        #expect(abs(price.cost(of: UsageTotals(input: 500_000, cacheRead: 500_000, cacheWrite: 500_000)) - 6) < 1e-9)
        #expect(price.cost(of: UsageTotals()) == 0)
    }

    @Test func aPriceThatIsNotANumberFromZeroUpIsNotAPrice() throws {
        #expect(ModelPrice(input: 1, output: 2).isValid)
        #expect(!ModelPrice(input: -1, output: 2).isValid)
        #expect(!ModelPrice(input: .nan, output: 2).isValid)
        #expect(!ModelPrice(input: 1, cacheRead: .infinity, output: 2).isValid)
        #expect(!ModelPrice(input: 1, output: ModelPrice.highestAllowed + 1).isValid)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ModelPrice.self, from: Data(#"{"input": -3, "output": 1}"#.utf8)) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ModelPrice.self, from: Data(#"{"input": 3}"#.utf8)) }
        let ok = try JSONDecoder().decode(ModelPrice.self, from: Data(#"{"input": 3, "output": 1, "cacheRead": 0.3}"#.utf8))
        #expect(ok == ModelPrice(input: 3, cacheRead: 0.3, output: 1))
    }

    // MARK: How a model is paid for

    private func account(_ kind: ProviderKind, url: String? = nil) -> ProviderAccount {
        var account = ProviderAccount(kind: kind)
        if let url { account.baseURL = url }
        return account
    }

    @Test func subscriptionsAreIncludedLocalModelsAreFreeTheRestIsMetered() {
        #expect(UsageBilling.of(.chatgpt, account: nil) == .plan)
        #expect(UsageBilling.of(.claudeCode, account: nil) == .plan)
        #expect(UsageBilling.of(.opencodeGo, account: nil) == .plan)
        #expect(UsageBilling.of(.ollama, account: nil) == .local)
        #expect(UsageBilling.of(.lmstudio, account: nil) == .local)
        for kind: ProviderKind in [.openai, .anthropic, .opencodeZen, .commandCode, .xai, .openrouter] {
            #expect(UsageBilling.of(kind, account: nil) == .metered)
        }
        // A gateway of your own is local only when it answers on this Mac.
        #expect(UsageBilling.of(.custom, account: account(.custom, url: "http://localhost:8891/v1")) == .local)
        #expect(UsageBilling.of(.custom, account: account(.custom, url: "http://127.0.0.1:8891/v1")) == .local)
        #expect(UsageBilling.of(.custom, account: account(.custom, url: "https://gateway.example.com/v1")) == .metered)
        #expect(UsageBilling.of(.custom, account: nil) == .metered)
    }

    // MARK: The price book

    private func book(corrections: [String: ModelPrice] = [:], accounts: [ProviderAccount] = []) -> PriceBook {
        PriceBook(corrections: corrections, accounts: accounts)
    }

    @Test func aMeteredModelWithAPriceIsPaid() {
        let totals = UsageTotals(requests: 2, input: 1_000_000, cacheRead: 4_000_000, output: 100_000)
        // claude-sonnet-5.5: 2 + 4 × 0.1 + 0.1 × 10
        guard case .paid(let cost) = book().cost(of: totals, model: "anthropic/claude-sonnet-5-5") else { Issue.record("not paid"); return }
        #expect(abs(cost - 3.4) < 1e-9)
    }

    @Test func aSubscriptionIsIncludedAndSaysWhatItWouldCost() {
        let totals = UsageTotals(requests: 1, input: 1_000_000, output: 100_000)
        // Worked out from the table (ChatGPT's login).
        #expect(book().cost(of: totals, model: "chatgpt/gpt-5.4") == .included(equivalent: 2.5 + 1.5))
        // The CLI's own figure wins when it gave one (Claude Code).
        var reported = totals
        reported.reportedCost = 0.42
        #expect(book().cost(of: reported, model: "claudeCode/sonnet") == .included(equivalent: 0.42))
        // No figure and no price: included, nothing to compare with.
        #expect(book().cost(of: totals, model: "claudeCode/sonnet") == .included(equivalent: nil))
    }

    @Test func aLocalModelIsFree() {
        let totals = UsageTotals(requests: 5, input: 9_000_000, output: 1_000_000)
        #expect(book(accounts: [account(.ollama)]).cost(of: totals, model: "ollama/qwen3") == .free)
        // Even when the name is one of a priced model.
        #expect(book(accounts: [account(.ollama)]).cost(of: totals, model: "ollama/gpt-5") == .free)
    }

    @Test func aModelNobodyKnowsShowsTokensButNoPrice() {
        #expect(book().cost(of: UsageTotals(requests: 1, input: 100), model: "openrouter/acme/modelo-novo") == .unpriced)
        #expect(book().cost(of: UsageTotals(requests: 1, input: 100), model: "isto-nao-e-uma-referencia") == .unpriced)
        // Nothing used, nothing to price.
        #expect(book().cost(of: UsageTotals(), model: "openrouter/acme/modelo-novo") == .paid(0))
    }

    @Test func aCorrectedPriceWinsOverEverythingElse() {
        let totals = UsageTotals(requests: 1, input: 1_000_000)
        let corrected = ModelPrice(input: 7, output: 1)
        var listed = account(.openrouter)
        listed.models = [ProviderModel(id: "acme/modelo", name: "x", format: .chat, price: ModelPrice(input: 3, output: 1))]
        let found = book(corrections: ["openrouter/acme/modelo": corrected], accounts: [listed])
        #expect(found.price(for: "openrouter/acme/modelo")?.source == .corrected)
        #expect(found.cost(of: totals, model: "openrouter/acme/modelo") == .paid(7))
        // It also prices what had no price at all, and the equivalent of a plan.
        #expect(book(corrections: ["openrouter/novo": corrected]).cost(of: totals, model: "openrouter/novo") == .paid(7))
        #expect(book(corrections: ["chatgpt/novo": corrected]).cost(of: totals, model: "chatgpt/novo") == .included(equivalent: 7))
    }

    @Test func theProvidersOwnListComesBeforeTheTable() {
        var listed = account(.openrouter)
        listed.models = [ProviderModel(id: "openai/gpt-5", name: "x", format: .chat, price: ModelPrice(input: 9, output: 1))]
        let found = book(accounts: [listed])
        #expect(found.price(for: "openrouter/openai/gpt-5")?.source == .catalog)
        #expect(found.price(for: "openrouter/openai/gpt-5")?.price.input == 9)
        // Without it, the table answers through the model's name.
        #expect(book().price(for: "openrouter/openai/gpt-5")?.source == .table)
        #expect(book().price(for: "openrouter/openai/gpt-5")?.price.input == 1.25)
    }

    // MARK: The table

    @Test func anIdFindsItsEntryWhateverItsPrefixDateOrDots() {
        let direct = PriceTable.price(forModel: "claude-sonnet-4-5")
        #expect(direct == ModelPrice(input: 3, cacheRead: 0.3, cacheWrite: 3.75, cacheWrite1h: 6, output: 15))
        for spelling in ["claude-sonnet-4.5", "anthropic/claude-sonnet-4.5", "Claude-Sonnet-4-5-20250929", "claude-sonnet-4-5-latest",
                         "anthropic/claude-sonnet-4.5:thinking", "claude-sonnet-4-5-2025-09-29"] {
            #expect(PriceTable.price(forModel: spelling) == direct, "\(spelling)")
        }
    }

    @Test func aVariantByNameFindsItsFamilyButANewVersionDoesNot() {
        #expect(PriceTable.price(forModel: "gpt-5.4-codex") == PriceTable.price(forModel: "gpt-5.4"))
        #expect(PriceTable.price(forModel: "gemini-3-flash-preview") == PriceTable.price(forModel: "gemini-3-flash"))
        // The longest entry wins: the mini is not the full model.
        #expect(PriceTable.price(forModel: "gpt-5.4-mini")?.input == 0.75)
        #expect(PriceTable.price(forModel: "gpt-5.1-codex-mini")?.input == 0.25)
        // A version the table lacks is not guessed from the one before it.
        #expect(PriceTable.price(forModel: "claude-opus-4.9") == nil)
        #expect(PriceTable.price(forModel: "gpt-5.7") == nil)
        #expect(PriceTable.price(forModel: "modelo-qualquer") == nil)
    }

    @Test func theTableHoldsSanePricesAndSaysWhenItWasRead() {
        #expect(PriceTable.consultedOn == "2026-10-09")
        #expect(PriceTable.consultedText == "9 de outubro de 2026")
        for id in ["claude-opus-5.5", "claude-haiku-5.5", "gpt-6-luna", "gemini-3.5-flash", "deepseek-v4-pro", "grok-4.7", "glm-5", "kimi-k3", "qwen3.7-plus"] {
            guard let price = PriceTable.price(forModel: id) else { Issue.record("\(id) is missing"); continue }
            #expect(price.isValid && price.input > 0 && price.output >= price.input, "\(id)")
            // A cache read is never dearer than reading the prompt in full.
            #expect((price.cacheRead ?? price.input) <= price.input, "\(id)")
        }
    }

    // MARK: The providers' lists

    @Test func openRouterPricesAreDollarsPerTokenAsText() throws {
        let entry = try #require(JSONValue.parse(#"""
        {"id": "acme/modelo", "pricing": {"prompt": "0.000003", "completion": "0.000015", "input_cache_read": "0.0000003"}}
        """#))
        let price = try #require(ModelCatalog.openRouterPrice(entry["pricing"]))
        #expect(abs(price.input - 3) < 1e-9 && abs(price.output - 15) < 1e-9 && abs((price.cacheRead ?? 0) - 0.3) < 1e-9 && price.cacheWrite == nil)
        // The routers say -1; a free model says 0.
        #expect(ModelCatalog.openRouterPrice(JSONValue.parse(#"{"prompt": "-1", "completion": "-1"}"#)) == nil)
        #expect(ModelCatalog.openRouterPrice(JSONValue.parse(#"{"prompt": "0", "completion": "0"}"#)) == ModelPrice(input: 0, output: 0))
        #expect(ModelCatalog.openRouterPrice(nil) == nil)
        let models = ModelCatalog.openRouterModels([entry])
        #expect(models.first?.price == price)
    }

    @Test func modelsDevPricesAreAlreadyPerMillionTokens() throws {
        let cost = JSONValue.parse(#"{"input": 0.6, "output": 3, "cache_read": 0.1, "cache_write": 0.75}"#)
        #expect(ModelCatalog.modelsDevPrice(cost) == ModelPrice(input: 0.6, cacheRead: 0.1, cacheWrite: 0.75, output: 3))
        #expect(ModelCatalog.modelsDevPrice(JSONValue.parse(#"{"input": 0.6}"#)) == nil)
        let metadata = JSONValue.parse(#"{"kimi-k3": {"name": "Kimi", "tool_call": true, "cost": {"input": 0.6, "output": 3}}}"#)
        let models = ModelCatalog.openCodeModels(live: ["kimi-k3"], metadata: metadata)
        #expect(models.first?.price == ModelPrice(input: 0.6, output: 3))
    }

    @Test func aSavedModelWithoutAPriceStillReadsAndAPriceSurvivesTheFile() throws {
        let old = try JSONDecoder().decode(ProviderModel.self, from: Data(#"{"id": "a", "name": "A", "format": "chat"}"#.utf8))
        #expect(old.price == nil)
        let damaged = try JSONDecoder().decode(ProviderModel.self, from: Data(#"{"id": "a", "name": "A", "format": "chat", "price": {"input": -1, "output": 2}}"#.utf8))
        #expect(damaged.price == nil)
        let priced = ProviderModel(id: "a", name: "A", format: .chat, price: ModelPrice(input: 1, cacheRead: 0.1, output: 2))
        #expect(try JSONDecoder().decode(ProviderModel.self, from: JSONEncoder().encode(priced)) == priced)
    }

    @Test func correctedPricesAreSavedWithTheSettingsAndADamagedOneLosesOnlyItself() throws {
        var state = AppState.initial
        state.priceCorrections = ["openai/gpt-5": ModelPrice(input: 1, output: 2), "openai/gpt-6": ModelPrice(input: 3, cacheWrite1h: 5, output: 4)]
        let json = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(AppState.self, from: json).priceCorrections == state.priceCorrections)
        var object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        var corrections = try #require(object["priceCorrections"] as? [String: Any])
        corrections["openai/gpt-5"] = ["input": "caro"]
        corrections["openai/gpt-7"] = ["input": -1, "output": 2]
        object["priceCorrections"] = corrections
        let damaged = try JSONDecoder().decode(AppState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(damaged.priceCorrections == ["openai/gpt-6": state.priceCorrections["openai/gpt-6"]!])
        #expect(damaged.bots == state.bots)
        // Not even a dictionary: nothing, and the rest of the file is read.
        object["priceCorrections"] = "estragado"
        #expect(try JSONDecoder().decode(AppState.self, from: JSONSerialization.data(withJSONObject: object)).priceCorrections.isEmpty)
    }

    // MARK: Cache writes of an hour

    @Test func anHourLongCacheWriteCostsTwiceTheInputAndFiveMinutesOneAndAQuarter() throws {
        let sonnet = try #require(PriceTable.price(forModel: "claude-sonnet-4.5"))
        #expect(sonnet.cacheWrite == 3.75 && sonnet.cacheWrite1h == 6)
        // 0.4M five-minute writes at 3.75 + 0.6M hour-long at 6.
        let totals = UsageTotals(cacheWrite: 1_000_000, cacheWrite1h: 600_000)
        #expect(abs(sonnet.cost(of: totals) - 5.1) < 1e-9)
        // Without the split everything is the five-minute price; a price with no hour figure charges the hour as the rest.
        #expect(abs(sonnet.cost(of: UsageTotals(cacheWrite: 1_000_000)) - 3.75) < 1e-9)
        #expect(abs(ModelPrice(input: 2, cacheWrite: 3, output: 1).cost(of: totals) - 3) < 1e-9)
        // The hour-long part is a part: it never exceeds the whole.
        #expect(UsageTotals(cacheWrite: 10, cacheWrite1h: 99).cacheWrite1h == 10)
    }

    @Test func everyClaudeEntryFollowsAnthropicsCacheMultipliers() {
        for id in ["claude-fable-5.1", "claude-opus-5.5", "claude-opus-4.1", "claude-sonnet-5.5", "claude-sonnet-4.6", "claude-haiku-5.5", "claude-haiku-3.5"] {
            guard let price = PriceTable.price(forModel: id) else { Issue.record("\(id) is missing"); continue }
            #expect(abs((price.cacheWrite ?? 0) - price.input * 1.25) < 1e-9, "\(id)")
            #expect(abs((price.cacheWrite1h ?? 0) - price.input * 2) < 1e-9, "\(id)")
        }
    }

    @Test func theAnthropicStreamReportsHowMuchWasWrittenForAnHour() throws {
        var assembler = AnthropicStreamAssembler()
        let start = #"{"type":"message_start","message":{"id":"m","usage":{"input_tokens":25,"cache_creation_input_tokens":300,"cache_read_input_tokens":1200,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200}}}}"#
        _ = try assembler.ingest(try #require(JSONValue.parse(start)))
        #expect(assembler.usage?.cacheWrite == 300 && assembler.usage?.cacheWrite1h == 200)
        let totals = UsageTotals(try #require(assembler.usage))
        #expect(totals.cacheWrite == 300 && totals.cacheWrite1h == 200 && totals.tokens == 1525)
    }

    // MARK: Variants and dated ids

    @Test func aVariantWithAnotherPriceIsNotPricedAsItsBase() {
        #expect(PriceTable.price(forModel: "o1-pro")?.input == 150)
        #expect(PriceTable.price(forModel: "o1-pro")?.output == 600)
        #expect(PriceTable.price(forModel: "o1-pro-2025-03-19")?.input == 150)
        #expect(PriceTable.price(forModel: "o1")?.input == 15)
        // Priced by nobody: unpriced rather than wrong.
        #expect(PriceTable.price(forModel: "o3-deep-research") == nil)
        #expect(PriceTable.price(forModel: "o4-mini-deep-research") == nil)
        #expect(PriceTable.price(forModel: "gpt-5-codex-mini") == nil)
        #expect(PriceTable.price(forModel: "gemini-2.5-flash-image") == nil)
        // The names that do not change the price still find their model.
        #expect(PriceTable.price(forModel: "gpt-5.1-codex-max") == PriceTable.price(forModel: "gpt-5.1"))
        #expect(PriceTable.price(forModel: "gemini-2.5-flash-preview-05-20") == PriceTable.price(forModel: "gemini-2.5-flash"))
        #expect(PriceTable.price(forModel: "gemini-3.1-pro-preview-customtools") == PriceTable.price(forModel: "gemini-3.1-pro"))
    }

    @Test func aDateIsKeptOnlyForTheOneModelWhoseDatedVersionHasItsOwnPrice() {
        #expect(PriceTable.price(forModel: "gpt-4o-2024-05-13")?.input == 5)
        #expect(PriceTable.price(forModel: "gpt-4o-2024-05-13")?.output == 15)
        #expect(PriceTable.price(forModel: "gpt-4o-2024-08-06")?.input == 2.5)
        #expect(PriceTable.price(forModel: "openai/gpt-4o")?.input == 2.5)
    }

    // MARK: Prices that move with the hour

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test func deepSeekChargesHalfOutsideItsPeakHours() throws {
        // 2026-10-07 is a Wednesday, 2026-10-10 a Saturday.
        let peaks = [1, 2, 3, 6, 7, 8, 9], offPeaks = [0, 4, 5, 10, 15, 23]
        for hour in peaks { #expect(PriceTable.isDeepSeekPeak(utc(2026, 10, 7, hour)), "\(hour)h") }
        for hour in offPeaks { #expect(!PriceTable.isDeepSeekPeak(utc(2026, 10, 7, hour)), "\(hour)h") }
        for hour in 0..<24 { #expect(!PriceTable.isDeepSeekPeak(utc(2026, 10, 10, hour)), "weekend \(hour)h") }
        let peak = try #require(PriceTable.price(forModel: "deepseek-flash", at: utc(2026, 10, 7, 2)))
        let off = try #require(PriceTable.price(forModel: "deepseek-flash", at: utc(2026, 10, 7, 15)))
        #expect(peak == ModelPrice(input: 0.3, cacheRead: 0.006, output: 1.2))
        #expect(abs(off.input - 0.15) < 1e-12 && abs((off.cacheRead ?? 0) - 0.003) < 1e-12 && abs(off.output - 0.6) < 1e-12)
        let pro = try #require(PriceTable.price(forModel: "deepseek/deepseek-v4-pro", at: utc(2026, 10, 10, 8)))
        #expect(abs(pro.input - 0.66) < 1e-12 && abs(pro.output - 1.98) < 1e-12)
        // Another model's price does not move, and with no hour the usual (peak) price is the answer.
        #expect(PriceTable.price(forModel: "gpt-5", at: utc(2026, 10, 10, 8)) == PriceTable.price(forModel: "gpt-5"))
        #expect(PriceTable.price(forModel: "deepseek-flash") == peak)
    }

    @Test func theCostOfARowFollowsItsHour() {
        let totals = UsageTotals(requests: 1, input: 1_000_000, output: 1_000_000)
        let peak = book().cost(of: totals, model: "commandCode/deepseek-flash", at: utc(2026, 10, 7, 2))
        let off = book().cost(of: totals, model: "commandCode/deepseek-flash", at: utc(2026, 10, 7, 12))
        guard case .paid(let high) = peak, case .paid(let low) = off else { Issue.record("not paid"); return }
        #expect(abs(high - 1.5) < 1e-9 && abs(low - 0.75) < 1e-9)
    }

    @Test func theGeminiFlashesDoubleOnTheFirstOfJanuary2027() throws {
        let before = try #require(PriceTable.price(forModel: "gemini-3.8-flash", at: utc(2026, 12, 31, 23)))
        let after = try #require(PriceTable.price(forModel: "gemini-3.8-flash", at: utc(2027, 1, 1, 0)))
        #expect(before == ModelPrice(input: 0.75, cacheRead: 0.075, output: 3.75))
        #expect(abs(after.input - 1.5) < 1e-12 && abs((after.cacheRead ?? 0) - 0.15) < 1e-12 && abs(after.output - 7.5) < 1e-12)
        #expect(PriceTable.price(forModel: "gemini-3.5-flash", at: utc(2027, 6, 1)) == PriceTable.price(forModel: "gemini-3.5-flash"))
    }

    // MARK: The editor

    @Test func savingThePriceWithoutChangingAnythingKeepsEveryPart() throws {
        for id in ["claude-sonnet-5.5", "claude-haiku-3.5", "qwen3.7-max", "gpt-5.4", "o1-pro", "deepseek-v4-pro"] {
            let was = try #require(PriceTable.price(forModel: id))
            let back = try #require(PriceDraft(was).price(replacing: was))
            #expect(abs(back.input - was.input) < 1e-9 && abs(back.output - was.output) < 1e-9, "\(id)")
            #expect(abs((back.cacheRead ?? -1) - (was.cacheRead ?? -1)) < 1e-9, "\(id)")
            #expect(abs((back.cacheWrite ?? -1) - (was.cacheWrite ?? -1)) < 1e-9, "\(id)")
            #expect(abs((back.cacheWrite1h ?? -1) - (was.cacheWrite1h ?? -1)) < 1e-9, "\(id)")
        }
    }

    @Test func correctingOnlyTheInputOfSonnetKeepsItsCacheWrite() throws {
        let was = try #require(PriceTable.price(forModel: "claude-sonnet-5.5"))
        var draft = PriceDraft(was)
        draft.input = "2,4"
        let corrected = try #require(draft.price(replacing: was))
        #expect(corrected.input == 2.4 && corrected.cacheWrite == 2.5 && corrected.cacheRead == 0.1 && corrected.output == 10)
        // 1M five-minute writes still cost 2.5, not the input.
        #expect(abs(corrected.cost(of: UsageTotals(cacheWrite: 1_000_000)) - 2.5) < 1e-9)
        // Emptying a cache field says "same as the input"; a field that is not a number is no price.
        draft.cacheWrite = ""
        #expect(draft.price(replacing: was)?.cacheWrite == nil)
        draft.cacheWrite = "abc"
        #expect(draft.price(replacing: was) == nil)
    }

    @Test func aCorrectionOfAPlanModelWinsOverTheCLIsFigure() {
        var reported = UsageTotals(requests: 1, input: 1_000_000)
        reported.reportedCost = 0.42
        let corrected = book(corrections: ["claudeCode/sonnet": ModelPrice(input: 6, output: 1)])
        #expect(corrected.cost(of: reported, model: "claudeCode/sonnet") == .included(equivalent: 6))
        #expect(book().cost(of: reported, model: "claudeCode/sonnet") == .included(equivalent: 0.42))
    }
}

@MainActor
struct UsagePriceCorrectionTests {
    @Test func correctingAPriceSavesItAndRestoringRemovesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbPriceFix-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let store = Store(directory: root)
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.correctPrice(of: "openai/gpt-5", to: ModelPrice(input: 1, output: 2))
        model.correctPrice(of: "openai/gpt-6", to: ModelPrice(input: -4, output: 2)) // not a price
        #expect(model.priceCorrections == ["openai/gpt-5": ModelPrice(input: 1, output: 2)])
        #expect(model.priceBook.price(for: "openai/gpt-5")?.source == .corrected)
        model.saveNow()
        let again = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        #expect(again.priceCorrections.keys.sorted() == ["openai/gpt-5"])
        again.correctPrice(of: "openai/gpt-5", to: nil)
        #expect(again.priceCorrections.isEmpty)
    }
}
