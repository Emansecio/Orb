import Foundation
import Testing
@testable import Orb

/// Each conversation of an Orb (a chat, a routine run, a group turn) works in a tab of its own in the Orb's one browser.
struct BrowserTabsPerConversationTests {
    private let setup = FakeBrowserSetup()

    private func context(_ scope: String?) -> ToolContext {
        var context = setup.context()
        context.browser.scope = scope
        return context
    }

    private var tabCalls: [String] { setup.driver.calls.filter { $0.hasPrefix("command tab") } }

    private func scroll(_ scope: String?) async throws {
        _ = try await BrowseScrollTool().run(.object(["direction": .string("down")]), context: context(scope))
    }

    @Test func oneConversationAloneNeverSwitchesTabs() async throws {
        try await scroll("chat-A")
        try await scroll("chat-A")
        try await scroll("chat-A")
        #expect(tabCalls.isEmpty)
        #expect(setup.driver.calls.filter { $0.hasPrefix("scroll") }.count == 3)
    }

    @Test func aSecondConversationGetsATabAndEachCallGoesToItsOwn() async throws {
        let label = TabBook.label(for: "chat-B")
        try await scroll("chat-A")
        try await scroll("chat-B")
        #expect(tabCalls == ["command tab new --label \(label)"])
        try await scroll("chat-B")
        #expect(tabCalls.count == 1)
        try await scroll("chat-A")
        try await scroll("chat-B")
        #expect(tabCalls == ["command tab new --label \(label)", "command tab t1", "command tab \(label)"])
        // The switch comes before the page action.
        let calls = setup.driver.calls
        let switchIndex = calls.lastIndex(of: "command tab \(label)")!
        #expect(calls[switchIndex + 1].hasPrefix("scroll"))
    }

    @Test func theViewsOfOneBrowserShareTheDriverButNotWhatTheyRemember() async throws {
        let a = try await setup.hub.session(botID: setup.botID, mode: .background, scope: "A")
        let b = try await setup.hub.session(botID: setup.botID, mode: .background, scope: "B")
        let again = try await setup.hub.session(botID: setup.botID, mode: .background, scope: "A")
        let whole = try await setup.hub.session(botID: setup.botID, mode: .background, scope: nil)
        #expect(a === again && a !== b && whole.scope == nil && a.base === whole && b.base === whole)
        a.remember(BrowserSnapshot(url: "https://x.test/", tree: "t", refs: ["e1": BrowserRef(role: "link", name: "X")]), text: "t")
        #expect(a.ref("e1") != nil && b.ref("e1") == nil)
        #expect(setup.configs.withLock { $0.count } == 1)
    }

    @Test func aClosedBrowserStartsOverWithTheFirstTabForWhoeverCallsNext() async throws {
        try await scroll("chat-A")
        try await scroll("chat-B")
        setup.driver.state.withLock { $0.failure = .noPage }
        _ = try? await BrowseScrollTool().run(.object(["direction": .string("down")]), context: context("chat-A"))
        let a = try await setup.hub.session(botID: setup.botID, mode: .background, scope: "chat-A")
        #expect(a.tabName == "t1")
    }

    @Test func aTabThatIsGoneGetsReplacedNotReused() async throws {
        try await scroll("chat-A")
        try await scroll("chat-B")
        let b = try await setup.hub.session(botID: setup.botID, mode: .background, scope: "chat-B")
        #expect(b.tabName == TabBook.label(for: "chat-B"))
        setup.driver.state.withLock { $0.failure = .failed("No tab with label") }
        _ = try? await BrowseScrollTool().run(.object(["direction": .string("down")]), context: context("chat-A"))
        #expect(b.tabName == TabBook.label(for: "chat-B"))
    }

    @Test func moreThanSixTabsCloseTheOneUsedLongestAgoButNeverTheFirst() async throws {
        try await scroll("s0")
        for index in 1...6 { try await scroll("s\(index)") }
        let closes = tabCalls.filter { $0.hasPrefix("command tab close") }
        #expect(closes == ["command tab close \(TabBook.label(for: "s1"))"])
        // The conversation that lost its tab gets a new one when it comes back.
        let before = tabCalls.count
        try await scroll("s1")
        #expect(tabCalls.dropFirst(before).first == "command tab new --label \(TabBook.label(for: "s1"))")
    }

    @Test func theTabTheOrbSelectsWithBrowseTabsBecomesItsTab() async throws {
        try await scroll("chat-A")
        let a = try await setup.hub.session(botID: setup.botID, mode: .background, scope: "chat-A")
        setup.driver.state.withLock {
            $0.tabs = [BrowserTab(id: "t1", title: "One", url: "https://one.test/", isActive: false),
                       BrowserTab(id: "t3", title: "Three", url: "https://three.test/", isActive: true)]
        }
        _ = try await BrowseTabsTool().run(.object(["action": .string("select"), "tab": .string("t3")]), context: context("chat-A"))
        #expect(a.tabName == "t3")
        // A plain list leaves the book alone.
        setup.driver.state.withLock { $0.tabs = [BrowserTab(id: "t1", title: "One", url: "https://one.test/", isActive: true)] }
        _ = try await BrowseTabsTool().run(.object([:]), context: context("chat-A"))
        #expect(a.tabName == "t3")
    }

    @Test func withoutAScopeTheBrowserIsUsedAsItIs() async throws {
        try await scroll(nil)
        try await scroll("chat-A")
        try await scroll(nil)
        #expect(tabCalls.isEmpty)
    }

    @Test func theLabelOfATabIsAWordTheBrowserTakesAsAName() {
        #expect(TabBook.label(for: "B3F1C2D4-9A7E-4C55-8D21-0123456789AB") == "cb3f1c2d4")
        #expect(TabBook.label(for: "!!").hasPrefix("c"))
        #expect(!TabBook.label(for: "../x --y").contains(" ") && !TabBook.label(for: "../x --y").contains("-"))
    }
}
