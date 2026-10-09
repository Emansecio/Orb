import Foundation
import Testing
@testable import Orb

// A conversation whose provider cache went cold is folded early, because the next request pays for the whole history
// anyway: `Conversation.isCacheCold` and what `prepareHistory(now:)` does with it.

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// `turns` turns of `characters` characters each (a request and an answer), the model's last call `ago` seconds before `now`.
private func conversation(turns: Int, characters: Int = 3_500, ago: TimeInterval? = nil) -> Conversation {
    var chat = Conversation()
    for turn in 0..<turns {
        chat.messages += [.user("pedido \(turn) " + String(repeating: "a", count: characters / 2)),
                          ChatMessage(role: .assistant, content: "resposta \(turn) " + String(repeating: "b", count: characters / 2))]
    }
    chat.lastModelCall = ago.map { now.addingTimeInterval(-$0) }
    return chat
}

struct ColdFoldTests {
    // 20,000 tokens of history = 70,000 characters.
    private let budget = ContextBudget(tokens: 20_000)

    @Test func theCacheIsColdFiveMinutesAfterTheLastCall() {
        #expect(conversation(turns: 1, ago: 299).isCacheCold(now: now) == false)
        #expect(conversation(turns: 1, ago: ContextBudget.cacheColdAfter).isCacheCold(now: now))
        #expect(conversation(turns: 1, ago: 3_600).isCacheCold(now: now))
        // Nothing recorded (a conversation from before it was): not known to be cold.
        #expect(conversation(turns: 1).isCacheCold(now: now) == false)
    }

    @Test func aColdCacheFoldsAHistoryPastSixtyPercentWithoutWaitingForTheBudget() {
        var cold = conversation(turns: 14, ago: 600) // about 70% of the budget
        let share = Double(cold.messages.reduce(0) { $0 + $1.contextCharacters }) / Double(budget.characters)
        #expect(share > ContextBudget.coldFoldShare && share < 1)
        let prepared = cold.prepareHistory(budget: budget, now: now)
        #expect(prepared.compaction != nil)
        #expect(cold.coveredMessageCount > 0)
        // Down to the low-water mark, as when the budget is passed.
        let left = cold.messages[cold.coveredMessageCount...].reduce(0) { $0 + $1.contextCharacters }
        #expect(Double(left) <= Double(budget.characters) * budget.lowWater)
    }

    @Test func aWarmCacheKeepsTheStartUntilTheBudgetIsPassed() {
        var warm = conversation(turns: 14, ago: 60)
        let prepared = warm.prepareHistory(budget: budget, now: now)
        #expect(prepared.compaction == nil)
        #expect(warm.coveredMessageCount == 0)
        #expect(prepared.history.count == warm.messages.count)
    }

    @Test func aColdCacheDoesNotFoldAShortHistory() {
        var short = conversation(turns: 9, ago: 3_600) // about 45% of the budget
        let prepared = short.prepareHistory(budget: budget, now: now)
        #expect(prepared.compaction == nil)
        #expect(short.coveredMessageCount == 0)
    }

    @Test func withoutNowNothingIsFoldedEarly() {
        // "Compactar agora" and the like call without a clock: the cache is not their business.
        var cold = conversation(turns: 14, ago: 600)
        #expect(cold.prepareHistory(budget: budget).compaction == nil)
    }

    @Test func theMomentOfTheLastCallIsReadBackFromAnOldFile() throws {
        var chat = conversation(turns: 1, ago: 10)
        let data = try JSONEncoder().encode(chat)
        #expect(try JSONDecoder().decode(Conversation.self, from: data).lastModelCall == chat.lastModelCall)
        // A file from before the field, or one with an unreadable value, still loads.
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["lastModelCall"] = "ontem de manhã"
        let broken = try JSONSerialization.data(withJSONObject: object)
        chat = try JSONDecoder().decode(Conversation.self, from: broken)
        #expect(chat.lastModelCall == nil && chat.messages.count == 2)
        object["lastModelCall"] = nil
        #expect(try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object)).lastModelCall == nil)
    }
}

@MainActor
struct LastModelCallTests {
    @Test func anAnswerOfTheModelRecordsWhenItCame() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbLastCall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState.initial
        let store = Store(directory: root)
        store.save(state)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        let id = state.bots[0].id
        model.seedConversation(Conversation(), for: id)
        let before = Date.now
        // Your own message is no call of the model.
        model.apply(.message(.user("oi")), to: id)
        #expect(model.conversations[id]?.lastModelCall == nil)
        model.apply(.message(ChatMessage(role: .assistant, content: "olá")), to: id)
        let recorded = try #require(model.conversations[id]?.lastModelCall)
        #expect(recorded >= before && recorded <= .now)
    }
}
