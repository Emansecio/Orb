import Foundation
import Testing
@testable import Orb

/// The history of what the models were used for: rows by hour × Orb × model × source, merged in batches, written by month,
/// read back tolerantly, and erased by "Redefinir o Orb". (The prices and the page are in `UsagePricingTests` and `UsageReportTests`.)

/// Dates in a fixed zone, so hours and months do not depend on the machine running the tests.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
}()

func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
}

struct UsageMonthTests {
    private let orb = UUID()
    private func key(_ hour: Int, model: String = "openai/gpt-5", source: UsageSource = .chat, orb: UUID? = nil) -> UsageKey {
        UsageKey(hour: utcDate(2026, 10, 9, hour), orb: orb ?? self.orb, model: model, source: source)
    }

    @Test func rowsOfTheSameHourOrbModelAndSourceAreAdded() {
        var month = UsageMonth()
        month.merge([key(10): UsageTotals(requests: 1, input: 100, cacheRead: 50, output: 10)], names: [orb: "Atlas"])
        month.merge([key(10): UsageTotals(requests: 2, input: 20, cacheWrite: 5, output: 4, reportedCost: 0.5)], names: [orb: "Atlas"])
        #expect(month.buckets.count == 1)
        #expect(month.buckets[0].totals == UsageTotals(requests: 3, input: 120, cacheRead: 50, cacheWrite: 5, output: 14, reportedCost: 0.5))
        #expect(month.orbNames == [orb.uuidString: "Atlas"])
    }

    @Test func anotherHourOrbModelOrSourceIsAnotherRow() {
        var month = UsageMonth()
        let totals = UsageTotals(requests: 1, input: 1)
        month.merge([key(10): totals, key(11): totals, key(10, model: "openai/gpt-5-mini"): totals, key(10, source: .routine): totals,
                     key(10, orb: UUID()): totals], names: [:])
        #expect(month.buckets.count == 5)
    }

    @Test func aNewNameReplacesTheOldOne() {
        var month = UsageMonth()
        month.merge([key(1): UsageTotals(requests: 1)], names: [orb: "Atlas"])
        month.merge([key(1): UsageTotals(requests: 1)], names: [orb: "Atlas 2"])
        #expect(month.orbNames[orb.uuidString] == "Atlas 2")
    }

    @Test func aMonthNeverGrowsPastItsLimit() {
        var month = UsageMonth()
        month.buckets = (0..<UsageMonth.maxBuckets).map {
            UsageBucket(key: UsageKey(hour: Date(timeIntervalSince1970: Double($0) * 3600), orb: orb, model: "x/y", source: .chat),
                        totals: UsageTotals(requests: 1))
        }
        month.merge([key(3): UsageTotals(requests: 1, input: 9)], names: [:])
        #expect(month.buckets.count == UsageMonth.maxBuckets && month.dropped == 1)
        // A row that already exists still grows.
        let existing = month.buckets[7].key
        month.merge([existing: UsageTotals(requests: 2)], names: [:])
        #expect(month.buckets[7].totals.requests == 3 && month.dropped == 1)
    }

    @Test func emptyUsesAreNotRows() {
        var month = UsageMonth()
        month.merge([key(1): UsageTotals()], names: [:])
        #expect(month.buckets.isEmpty)
    }

    @Test func aFileReadsBackWhatWasWrittenAndSkipsWhatItCannotRead() throws {
        var month = UsageMonth()
        month.merge([key(10): UsageTotals(requests: 1, input: 7, reportedCost: 0.25), key(11, source: .auxiliary): UsageTotals(requests: 1, output: 3)],
                    names: [orb: "Atlas"])
        let back = try JSONDecoder().decode(UsageMonth.self, from: JSONEncoder().encode(month))
        #expect(Set(back.buckets.map(\.key)) == Set(month.buckets.map(\.key)) && back.orbNames == month.orbNames)

        let id = orb.uuidString
        let json = """
        {"version": 7, "orbNames": {"\(id)": "Atlas"}, "futuro": true, "buckets": [
          {"hour": 1760000000, "orb": "\(id)", "model": "openai/gpt-5", "source": "chat", "requests": 2, "input": 10},
          {"hour": 1760003600, "orb": "\(id)", "model": "openai/gpt-5", "source": "de-uma-versao-nova", "requests": -4, "input": "muitos", "output": 5},
          {"hour": 1760007200, "orb": "não é um id", "model": "openai/gpt-5"},
          {"orb": "\(id)", "model": "openai/gpt-5"},
          {"hour": 1760010800, "orb": "\(id)", "model": "openai/gpt-5", "reportedCost": -3}
        ]}
        """
        let read = try DecodeLoss.measure { try JSONDecoder().decode(UsageMonth.self, from: Data(json.utf8)) }
        // Two rows cannot be placed; the unknown source counts as a loss too (the Store keeps a copy of a file that lost something).
        #expect(read.value.buckets.count == 3 && read.skipped == 3)
        #expect(read.value.buckets[0].totals == UsageTotals(requests: 2, input: 10))
        // A count that is not a number, or is negative, is zero; an unknown source reads as chat.
        #expect(read.value.buckets[1].totals == UsageTotals(output: 5) && read.value.buckets[1].key.source == .chat)
        #expect(read.value.buckets[2].totals.reportedCost == nil)
    }
}

struct UsageStoreTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "OrbUsage-\(UUID().uuidString)")
    private let orb = UUID()

    private func store() -> Store { Store(directory: root) }

    @Test func rowsGoToTheFileOfTheirMonthAndAreAddedInOrder() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store()
        let lastOfOctober = UsageKey(hour: utcDate(2026, 10, 31, 23), orb: orb, model: "openai/gpt-5", source: .chat)
        let firstOfNovember = UsageKey(hour: utcDate(2026, 11, 1, 0), orb: orb, model: "openai/gpt-5", source: .chat)
        store.addUsage([lastOfOctober: UsageTotals(requests: 1, input: 10), firstOfNovember: UsageTotals(requests: 1, input: 20)],
                       names: [orb: "Atlas"], calendar: utc)
        store.addUsage([lastOfOctober: UsageTotals(requests: 1, input: 5)], names: [orb: "Atlas"], calendar: utc)
        store.flush()

        let october = try JSONDecoder().decode(UsageMonth.self, from: Data(contentsOf: root.appending(path: "uso/2026-10.json")))
        let november = try JSONDecoder().decode(UsageMonth.self, from: Data(contentsOf: root.appending(path: "uso/2026-11.json")))
        #expect(october.buckets.map(\.totals.input) == [15] && november.buckets.map(\.totals.input) == [20])

        // Read back across the turn of the month, oldest first, with the names.
        let read = await store.readUsage(from: utcDate(2026, 10, 30), to: utcDate(2026, 11, 2), calendar: utc)
        #expect(read.buckets.map(\.totals.input) == [15, 20] && read.names == [orb: "Atlas"] && read.notices.isEmpty)
        // A range that touches only November reads only November.
        let later = await store.readUsage(from: utcDate(2026, 11, 1), to: utcDate(2026, 11, 20), calendar: utc)
        #expect(later.buckets.map(\.totals.input) == [20])
    }

    @Test func monthIDsCoverTheRangeIncludingTheTurnOfTheYear() {
        #expect(Store.usageMonths(from: utcDate(2026, 12, 20), to: utcDate(2027, 2, 3), calendar: utc) == ["2026-12", "2027-01", "2027-02"])
        #expect(Store.usageMonths(from: utcDate(2026, 10, 9), to: utcDate(2026, 10, 9, 23), calendar: utc) == ["2026-10"])
    }

    @Test func aFileThatCannotBeDecodedIsSetAsideAndTheHistoryStartsAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store()
        let file = root.appending(path: "uso/2026-10.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("isto não é json".utf8).write(to: file)

        let read = await store.readUsage(from: utcDate(2026, 10, 1), to: utcDate(2026, 10, 2), calendar: utc)
        #expect(read.buckets.isEmpty && read.notices.count == 1)
        let key = UsageKey(hour: utcDate(2026, 10, 9, 10), orb: orb, model: "openai/gpt-5", source: .chat)
        store.addUsage([key: UsageTotals(requests: 1, input: 3)], names: [:], calendar: utc)
        store.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "uso").path)
        #expect(names.contains { $0.hasPrefix("2026-10.json.corrupt-") } && names.contains("2026-10.json"))
        let month = try JSONDecoder().decode(UsageMonth.self, from: Data(contentsOf: file))
        #expect(month.buckets.map(\.totals.input) == [3])
    }
}

@MainActor
struct UsageRecorderTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "OrbUsageRecorder-\(UUID().uuidString)")
    private let orb = UUID()

    @Test func manyUsesInAnHourAreOneRowWrittenInOneBatch() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        var clock = utcDate(2026, 10, 9, 14, 5)
        let recorder = UsageRecorder(store: store, now: { clock }, calendar: utc)
        for _ in 0..<20 { recorder.record(UsageTotals(requests: 1, input: 100, output: 10), orb: orb, name: "Atlas", model: "openai/gpt-5", source: .chat) }
        clock = utcDate(2026, 10, 9, 14, 59)
        recorder.record(UsageTotals(requests: 1, input: 1), orb: orb, name: "Atlas", model: "openai/gpt-5", source: .chat)
        clock = utcDate(2026, 10, 9, 15, 0)
        recorder.record(UsageTotals(requests: 1, input: 2), orb: orb, name: "Atlas", model: "openai/gpt-5", source: .routine)
        // Nothing is on disk until the batch goes out.
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "uso").path))
        #expect(recorder.hasPending)

        recorder.flush()
        store.flush()
        #expect(!recorder.hasPending)
        let read = await store.readUsage(from: utcDate(2026, 10, 9), to: utcDate(2026, 10, 10), calendar: utc)
        #expect(read.buckets.count == 2)
        let fourteen = try #require(read.buckets.first { $0.key.hour == utcDate(2026, 10, 9, 14) })
        #expect(fourteen.totals == UsageTotals(requests: 21, input: 2_001, output: 200))
        let fifteen = try #require(read.buckets.first { $0.key.hour == utcDate(2026, 10, 9, 15) })
        #expect(fifteen.key.source == .routine && fifteen.totals.input == 2)
    }

    @Test func theBatchGoesOutOnItsOwnAfterTheDelay() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        let recorder = UsageRecorder(store: store, calendar: utc)
        recorder.record(UsageTotals(requests: 1, input: 4), orb: orb, name: "Atlas", model: "openai/gpt-5", source: .chat)
        #expect(recorder.hasPending)
        // The delay is ten seconds: do not wait for it, only check that a timer is armed by flushing in its place.
        recorder.flush()
        store.flush()
        let read = await store.readUsage(from: .now.addingTimeInterval(-86_400 * 40), to: .now.addingTimeInterval(86_400), calendar: utc)
        #expect(read.buckets.map(\.totals.input) == [4])
    }

    @Test func nothingIsKeptAfterTheHistoryIsClosed() {
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = UsageRecorder(store: Store(directory: root), calendar: utc)
        recorder.record(UsageTotals(requests: 1, input: 4), orb: orb, name: "Atlas", model: "openai/gpt-5", source: .chat)
        recorder.close()
        #expect(!recorder.hasPending)
        recorder.record(UsageTotals(requests: 1, input: 4), orb: orb, name: "Atlas", model: "openai/gpt-5", source: .chat)
        #expect(!recorder.hasPending)
    }
}

@MainActor
struct UsageEventsTests {
    private func makeModel() -> (AppModel, UUID, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbUsageEvents-\(UUID().uuidString)")
        let store = Store(directory: root)
        let state = AppState.initial
        store.save(state)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        var account = ProviderAccount(kind: .openai)
        account.models = [ProviderModel(id: "gpt-5", name: "GPT-5", format: .responses)]
        model.providers = [account]
        model.defaultModel = "openai/gpt-5"
        return (model, state.bots[0].id, root)
    }

    private func rows(_ model: AppModel, root: URL) async -> [UsageBucket] {
        model.usageLog.flush()
        model.store.flush()
        return await model.store.readUsage(from: .now.addingTimeInterval(-86_400 * 40), to: .now.addingTimeInterval(86_400)).buckets
    }

    @Test func everyModelCallOfAChatTurnIsCountedWithItsOrbAndModel() async {
        let (model, id, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.apply(.requestUsage(TokenUsage(input: 100, output: 10, cacheRead: 4_000, cacheWrite: 0)), to: id)
        model.apply(.usage(TokenUsage(input: 100, output: 10, cacheRead: 4_000, cacheWrite: 0)), to: id)
        model.apply(.requestUsage(TokenUsage(input: 50, output: 20, cacheRead: 4_100, cacheWrite: 30)), to: id)
        let found = await rows(model, root: root)
        #expect(found.count == 1)
        #expect(found.first?.key.orb == id && found.first?.key.model == "openai/gpt-5" && found.first?.key.source == .chat)
        // `.usage` is the turn's sum, already counted call by call: it is not added again.
        #expect(found.first?.totals == UsageTotals(requests: 2, input: 150, cacheRead: 8_100, cacheWrite: 30, output: 30))
    }

    @Test func theBatchIsWrittenWhenTheTurnEnds() {
        let (model, id, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let turn = model.session(id).beginTurn()
        model.session(id).turnTask = Task {}
        model.apply(.requestUsage(TokenUsage(input: 10, output: 1)), to: id)
        #expect(model.usageLog.hasPending)
        model.finishTurn(id, turn: turn)
        #expect(!model.usageLog.hasPending)
    }

    @Test func aRoutinesTurnIsMarkedAsOne() async {
        let (model, id, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.session(id).routineID = UUID()
        model.apply(.requestUsage(TokenUsage(input: 10, output: 1)), to: id)
        model.session(id).routineID = nil
        model.apply(.requestUsage(TokenUsage(input: 5, output: 1)), to: id)
        let found = await rows(model, root: root)
        #expect(Set(found.map(\.key.source)) == [.routine, .chat])
        #expect(found.first { $0.key.source == .routine }?.totals.input == 10)
    }

    @Test func aClaudeCodeTurnIsCountedOnceWithTheCostTheCLIReported() async {
        let (model, id, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.session(id).isClaudeTurn = true
        model.session(id).turnModel = "claudeCode/sonnet"
        model.apply(.usage(TokenUsage(input: 12, output: 340, cacheRead: 9_000, cacheWrite: 150)), to: id)
        model.apply(.reportedCost(0.0421), to: id)
        let found = await rows(model, root: root)
        #expect(found.count == 1 && found.first?.key.model == "claudeCode/sonnet")
        #expect(found.first?.totals == UsageTotals(requests: 1, input: 12, cacheRead: 9_000, cacheWrite: 150, output: 340, reportedCost: 0.0421))
    }

    @Test func theCLIsCostFollowsItsUsageInTheTurnsEvents() {
        var transcript = ClaudeCodeTranscript(isResuming: false)
        _ = transcript.apply(.started(sessionID: "s"))
        let events = transcript.apply(.result(ClaudeCodeResult(isError: false, message: "Oi", sessionID: "s",
                                                               usage: TokenUsage(input: 1, output: 2), costUSD: 0.5)))
        let kinds = events.prefix(2).map { event -> String in
            switch event {
            case .usage: "usage"
            case .reportedCost(let cost): "cost \(cost)"
            default: "other"
            }
        }
        #expect(kinds == ["usage", "cost 0.5"])
    }

    @Test func callsTheAppMakesForItselfAreMarkedAuxiliary() async {
        let (model, id, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.recordAuxiliaryUsage(TokenUsage(input: 800, output: 200), botID: id, model: "openai/gpt-5")
        let found = await rows(model, root: root)
        #expect(found.count == 1 && found.first?.key.source == .auxiliary && found.first?.totals == UsageTotals(requests: 1, input: 800, output: 200))
    }

    @Test func nothingIsRecordedForAnOrbThatDoesNotExistOrWhileResetting() async {
        let (model, id, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.recordUsage(UsageTotals(requests: 1, input: 1), botID: UUID(), model: "openai/gpt-5", source: .chat)
        model.isResetting = true
        model.recordUsage(UsageTotals(requests: 1, input: 1), botID: id, model: "openai/gpt-5", source: .chat)
        model.isResetting = false
        let found = await rows(model, root: root)
        #expect(found.isEmpty)
    }

    @Test func theResetRemovesTheHistoryAndKeepsNoPendingRow() async throws {
        let (model, id, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.apply(.requestUsage(TokenUsage(input: 10, output: 1)), to: id)
        model.usageLog.flush()
        model.store.flush()
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "uso").path))
        model.apply(.requestUsage(TokenUsage(input: 10, output: 1)), to: id) // pending, not yet written
        #expect(model.usageLog.hasPending)

        model.resetEnvironment = .inert
        model.resetEnvironment.arguments = []
        model.resetEnvironment.home = root.deletingLastPathComponent().appending(path: "casa-\(UUID().uuidString)")
        model.resetEnvironment.standardFolder = root
        _ = await model.resetEverything(ResetOptions(memories: .erase, leavesProviders: true))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "uso").path))
        #expect(!model.usageLog.hasPending)
    }
}
