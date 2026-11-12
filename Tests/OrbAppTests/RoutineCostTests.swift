import Foundation
import Testing
@testable import Orb

@Suite struct RoutineCostTests {
    private func prices() -> PriceBook {
        var account = ProviderAccount(kind: .custom)
        account.models = [("opus", 15.0), ("sonnet", 3.0), ("haiku", 1.0), ("sem-preco", nil)].map { id, input in
            var model = ProviderModel(id: id, name: id.capitalized, format: .chat)
            model.price = input.map { ModelPrice(input: $0, output: $0 * 5) }
            return model
        }
        return PriceBook(accounts: [account])
    }

    @Test func howOftenAScheduleRunsInADay() {
        #expect(RoutineCost.runsPerDay(.daily(hour: 9, minute: 0)) == 1)
        #expect(RoutineCost.runsPerDay(.everyHours(4)) == 6 && RoutineCost.runsPerDay(.everyMinutes(30)) == 48)
        #expect(RoutineCost.runsPerDay(.once(.now)) == 0 && RoutineCost.runsPerDay(.weekly(weekday: 2, hour: 9, minute: 0)) < 1)
        // "*/30 8-23": 32 slots a day, whatever the hour it is asked at.
        let cron = Schedule.cron(expression: "*/30 8-23 * * *", timeZone: "America/Sao_Paulo")
        #expect(RoutineCost.runsPerDay(cron, now: Date(timeIntervalSince1970: 1_800_000_000)) == 32)
        #expect(RoutineCost.runsPerDay(.cron(expression: "*/15 * * * *", timeZone: nil), limit: 50) == 50, "a walk is bounded")
    }

    @Test func aFrequentRoutineOnADearModelIsOfferedTheNextTierDown() throws {
        let advice = try #require(RoutineCost.advice(schedule: .everyMinutes(30), model: "custom/opus", prices: prices()))
        #expect(advice == RoutineCost.Advice(runsPerDay: 48, current: "custom/opus", cheaper: "custom/sonnet", cheaperName: "Sonnet", times: 5))
        // From the middle tier, the one below it.
        #expect(RoutineCost.advice(schedule: .everyMinutes(30), model: "custom/sonnet", prices: prices())?.cheaper == "custom/haiku")
    }

    @Test func noAdviceWhenItRunsSeldomIsAlreadyCheapOrThePriceIsUnknown() {
        let prices = prices()
        #expect(RoutineCost.advice(schedule: .daily(hour: 9, minute: 0), model: "custom/opus", prices: prices) == nil)
        #expect(RoutineCost.advice(schedule: .everyHours(5), model: "custom/opus", prices: prices) == nil, "under six runs a day")
        #expect(RoutineCost.advice(schedule: .everyMinutes(30), model: "custom/haiku", prices: prices) == nil)
        #expect(RoutineCost.advice(schedule: .everyMinutes(30), model: "custom/sem-preco", prices: prices) == nil)
        #expect(RoutineCost.advice(schedule: .everyMinutes(30), model: "custom/outro", prices: prices) == nil)
        #expect(RoutineCost.advice(schedule: .everyMinutes(30), model: "", prices: prices) == nil)
    }

    @Test func theEditorSavesTheRoutinesOwnContextAndModel() {
        // Saving applies only what the editor changed: a field it shows and `merged` forgets is silently dropped.
        let original = Routine(name: "Leads", botID: UUID(), prompt: "confere", schedule: .everyHours(1))
        var edited = original
        edited.contextMemory = .wide
        edited.model = "custom/sonnet"
        let saved = Routine.merged(edited: edited, original: original, current: original)
        #expect(saved.contextMemory == .wide && saved.model == "custom/sonnet")
        // Untouched in the editor: what the routine has now stays.
        var current = original
        current.model = "custom/haiku"
        #expect(Routine.merged(edited: original, original: original, current: current).model == "custom/haiku")
    }
}

@Suite(.serialized) final class RoutineModelTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbRoutineModel-\(UUID().uuidString)")
    init() { QuietNotifications.hold() }
    deinit { QuietNotifications.release(); removeTestFolder(root) }

    @Test @MainActor func aRunUsesTheRoutinesModelAndTheChatKeepsTheOrbs() async throws {
        let store = Store(directory: root)
        store.save(AppState.initial)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.homeFolder = root
        var account = ProviderAccount(kind: .custom)
        account.models = ["grande", "pequeno"].map { ProviderModel(id: $0, name: $0, format: .chat) }
        model.providers = [account]
        model.defaultModel = "custom/grande"
        let bot = model.bots[0]
        var routine = Routine(name: "Leads", botID: bot.id, prompt: "confere", schedule: .everyHours(1))
        routine.model = "custom/pequeno"
        model.routines = [routine]

        #expect(model.modelRef(for: bot)?.text == "custom/grande")
        // A real run: every call of it goes to the routine's model, and the chat's next message to the Orb's.
        let script = CallScript([[.text("feito"), .finished(.done, nil)], [.text("oi"), .finished(.done, nil)]])
        model.clientOverride = { CallScriptModel(script: script) }
        model.runRoutine(routine.id)
        await waitUntil("the run") { await script.calls.count == 1 }
        await waitUntilIdle(model, bot.id)
        #expect(await script.calls[0].model == "pequeno")
        await waitUntil("the Orb back in its chat") { model.session(bot.id).routineID == nil }
        #expect(model.send("oi", to: bot.id))
        await waitUntilIdle(model, bot.id)
        #expect(await script.calls.last?.model == "grande")
        model.session(bot.id).routineID = routine.id
        #expect(model.modelRef(for: bot)?.text == "custom/pequeno")
        // A model the provider no longer has, or a routine that is gone: the Orb's own.
        model.routines[0].model = "custom/sumiu"
        #expect(model.modelRef(for: bot)?.text == "custom/grande")
        model.routines[0].model = "openai/gpt"
        #expect(model.modelRef(for: bot)?.text == "custom/grande")
        model.routines = []
        #expect(model.modelRef(for: bot)?.text == "custom/grande")
    }
}
