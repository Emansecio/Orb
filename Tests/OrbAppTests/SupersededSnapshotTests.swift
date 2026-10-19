import Foundation
import Testing
@testable import Orb

// A browse_snapshot that a newer one (also no longer whole) replaced becomes one line; and the cache frost per provider.

private func snapshotStep(_ id: String, url: String, size: Int = 6_000, isError: Bool = false, name: String = "browse_snapshot") -> [ChatMessage] {
    let body = "URL: \(url)\n" + String(repeating: "e", count: size)
    return [ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: id, name: name, arguments: "{}")]),
            .tool(id, body, isError: isError)]
}

private func finished(_ request: String, _ steps: [ChatMessage]) -> [ChatMessage] {
    [.user(request)] + steps + [ChatMessage(role: .assistant, content: "ok")]
}

private func tools(_ messages: [ChatMessage]) -> [ChatMessage] { messages.filter { $0.role == .tool } }

struct SupersededSnapshotTests {
    private let budget = ContextBudget(tokens: 40_000)

    @Test func theOlderOfTwoSpentSnapshotsBecomesOneLine() {
        let history = finished("um", snapshotStep("a", url: "https://a.com")) + finished("dois", snapshotStep("b", url: "https://b.com"))
            + [.user("três")]
        var cut = ContextCut()
        let out = tools(ContextWindow.fit(history, budget: budget, cut: &cut).messages)
        #expect(out[0].content.hasPrefix("[Instantâneo antigo de https://a.com"))
        #expect(out[0].content.count < ContextCondensing.outputLimit)
        #expect(out[1].content.hasPrefix("URL: https://b.com") && out[1].content.count > 3_000)
    }

    @Test func aSpentSnapshotStaysAPreviewWhileTheNewerOneIsWhole() {
        let history = finished("um", snapshotStep("a", url: "https://a.com")) + [.user("dois")] + snapshotStep("b", url: "https://b.com")
        var cut = ContextCut()
        let out = tools(ContextWindow.fit(history, budget: budget, cut: &cut).messages)
        #expect(out[0].content.hasPrefix("URL: https://a.com"))
        #expect(out[1].content.count == 6_000 + "URL: https://b.com\n".count)
    }

    @Test func nothingBeforeTheNewStepMovesWhenTheTaskGrows() {
        let before = finished("um", snapshotStep("a", url: "https://a.com")) + finished("dois", snapshotStep("b", url: "https://b.com"))
            + [.user("três")]
        var cut = ContextCut()
        let first = ContextWindow.fit(before, budget: budget, cut: &cut).messages
        let after = before + snapshotStep("c", url: "https://c.com", size: 300)
        let second = ContextWindow.fit(after, budget: budget, cut: &cut).messages
        #expect(Array(second.prefix(first.count)) == first)
        // And again, with the cut remembered: same result.
        #expect(ContextWindow.fit(after, budget: budget, cut: &cut).messages == second)
    }

    @Test func anErrorAndOtherToolsAreLeftAlone() {
        let history = finished("um", snapshotStep("a", url: "https://a.com", isError: true))
            + finished("dois", snapshotStep("r", url: "https://r.com", name: "browse_read"))
            + finished("três", snapshotStep("b", url: "https://b.com")) + [.user("quatro")]
        var cut = ContextCut()
        let out = tools(ContextWindow.fit(history, budget: budget, cut: &cut).messages)
        #expect(!out.contains { $0.content.hasPrefix("[Instantâneo antigo") })
    }

    @Test func aShortSnapshotIsNotRewritten() {
        let history = finished("um", snapshotStep("a", url: "https://a.com", size: 500)) + finished("dois", snapshotStep("b", url: "https://b.com"))
            + [.user("três")]
        var cut = ContextCut()
        let out = tools(ContextWindow.fit(history, budget: budget, cut: &cut).messages)
        #expect(out[0].content.hasPrefix("URL: https://a.com"))
    }
}

struct ProviderCacheFrostTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func chat(ago: TimeInterval) -> Conversation {
        var chat = Conversation()
        chat.messages = [.user("oi"), ChatMessage(role: .assistant, content: "olá")]
        chat.lastModelCall = now.addingTimeInterval(-ago)
        return chat
    }

    @Test func claudeCodeKeepsItsCacheForAnHour() {
        let budget = ContextBudget(model: nil, provider: .claudeCode)
        #expect(chat(ago: 600).isCacheCold(now: now, after: budget.coldAfter) == false)
        #expect(chat(ago: 4_200).isCacheCold(now: now, after: budget.coldAfter))
    }

    @Test func otherProvidersGoColdAfterFiveMinutes() {
        let budget = ContextBudget(model: nil, provider: .anthropic)
        #expect(budget.coldAfter == ContextBudget.cacheColdAfter)
        #expect(chat(ago: 360).isCacheCold(now: now, after: budget.coldAfter))
    }
}
