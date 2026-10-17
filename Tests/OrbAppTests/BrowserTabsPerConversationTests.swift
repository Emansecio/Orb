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

    // MARK: Two conversations at once

    @Test func theSwitchAndTheCommandAfterItAreOneStepForTheOtherConversation() async throws {
        let labelB = TabBook.label(for: "chat-B")
        try await scroll("chat-A")
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                let (scope, pixels) = index.isMultiple(of: 2) ? ("chat-A", 101) : ("chat-B", 202)
                group.addTask {
                    _ = try? await BrowseScrollTool().run(.object(["direction": .string("down"), "amount": .number(Double(pixels))]),
                                                          context: self.context(scope))
                }
            }
        }
        // Walking the calls in order: every scroll of a conversation ran while its own tab was the current one.
        var current = "t1"
        var scrolls = 0
        for call in setup.driver.calls {
            if call.hasPrefix("command tab new --label ") { current = String(call.dropFirst("command tab new --label ".count)) }
            else if call.hasPrefix("command tab ") { current = String(call.dropFirst("command tab ".count)) }
            else if call == "scroll down 101" { #expect(current == "t1"); scrolls += 1 }
            else if call == "scroll down 202" { #expect(current == labelB); scrolls += 1 }
        }
        #expect(scrolls == 24)
    }

    // MARK: When a conversation ends

    @Test func aConversationThatEndsClosesItsTabAndTheFirstTabIsKeptForTheNext() async throws {
        let labelB = TabBook.label(for: "run-B")
        try await scroll("chat-A")
        try await scroll("run-B")
        await setup.hub.endScope(botID: setup.botID, scope: "run-B")
        #expect(tabCalls.last == "command tab close \(labelB)")
        // The first tab is never closed: a conversation that had it leaves it to the next one, which needs no new tab.
        await setup.hub.endScope(botID: setup.botID, scope: "chat-A")
        let before = tabCalls.count
        try await scroll("run-C")
        #expect(Array(tabCalls.dropFirst(before)) == ["command tab t1"])
        let c = try await setup.hub.session(botID: setup.botID, mode: .background, scope: "run-C")
        #expect(c.tabName == "t1")
    }

    @Test func withAProxyThatNeedsALoginTabsAreHandedOnNeverClosed() async throws {
        setup.hub.setProxy("http://u:pw@proxy.test:8080", botID: setup.botID)
        try await scroll("s0")
        for index in 1...8 { try await scroll("s\(index)") }
        #expect(!tabCalls.contains { $0.hasPrefix("command tab close") })
        #expect(tabCalls.filter { $0.hasPrefix("command tab new") }.count == TabBook.limit - 1)
        // The seventh conversation took the tab of the one used longest ago (s1: s0 keeps the first tab).
        let s7 = try await setup.hub.session(botID: setup.botID, mode: .background, scope: "s7")
        #expect(s7.tabName == TabBook.label(for: "s1"))
        await setup.hub.endScope(botID: setup.botID, scope: "s7")
        #expect(!tabCalls.contains { $0.hasPrefix("command tab close") })
        let before = tabCalls.count
        try await scroll("s9")
        #expect(Array(tabCalls.dropFirst(before)) == ["command tab \(TabBook.label(for: "s1"))"])
        // browse_tabs does not close one either.
        let refused = await errorText(BrowseTabsTool(), ["action": .string("close")], scope: "s9")
        #expect(refused.contains("proxy that needs a login"))
    }

    // MARK: A browser that starts over

    @Test func aBrowserThatStartedOverGivesItsPageToWhoeverCalledLast() async throws {
        try await scroll("chat-A")
        try await scroll("chat-B")
        // The browser went away and chat-B's `open` started a new one: its only tab is chat-B's page.
        setup.driver.state.withLock { $0.generation += 1 }
        let before = tabCalls.count
        try await scroll("chat-A")
        #expect(Array(tabCalls.dropFirst(before)) == ["command tab new --label \(TabBook.label(for: "chat-A"))"])
        try await scroll("chat-B")
        #expect(tabCalls.last == "command tab t1")
    }

    @Test func showingTheWindowGivesTheOtherConversationsTheirPagesBack() async throws {
        let labelB = TabBook.label(for: "chat-B")
        try await scroll("chat-A")
        try await scroll("chat-B")
        setup.driver.state.withLock {
            $0.tabs = [BrowserTab(id: "t1", title: "A", url: "https://a.test/", isActive: false),
                       BrowserTab(id: "t2", title: "B", url: "https://b.test/", isActive: true, label: labelB)]
        }
        _ = try await BrowseShowTool().run(.object([:]), context: context("chat-B"))
        let calls = setup.driver.calls
        let shown = try #require(calls.firstIndex(of: "setHeaded true"))
        // chat-B's page is the one the window reopened (the first tab); chat-A's comes back in a tab of its own.
        #expect(Array(calls.dropFirst(shown + 1).filter { $0.hasPrefix("command tab") })
                == ["command tab new --label \(TabBook.label(for: "chat-A")) https://a.test/", "command tab t1"])
        let a = try await setup.hub.session(botID: setup.botID, mode: .background, scope: "chat-A")
        let b = try await setup.hub.session(botID: setup.botID, mode: .background, scope: "chat-B")
        #expect(a.tabName == TabBook.label(for: "chat-A") && b.tabName == "t1")
    }

    // MARK: browse_tabs

    @Test func browseTabsShowsOnlyThisConversationsTabsAndCountsTheOthers() async throws {
        let labelB = TabBook.label(for: "chat-B")
        try await scroll("chat-A")
        try await scroll("chat-B")
        setup.driver.state.withLock {
            $0.tabs = [BrowserTab(id: "t1", title: "Banco", url: "https://bank.test/extrato", isActive: false),
                       BrowserTab(id: "t2", title: "Loja", url: "https://shop.test/", isActive: true, label: labelB)]
        }
        let list = try await BrowseTabsTool().run(.object([:]), context: context("chat-B"))
        #expect(list.contains("Loja") && list.contains("t2 *"))
        #expect(!list.contains("Banco") && !list.contains("bank.test") && list.contains("1 other tab of this Orb belongs to its other conversations"))
        let refused = await errorText(BrowseTabsTool(), ["action": .string("select"), "tab": .string("t1")], scope: "chat-B")
        #expect(refused.contains("No tab t1"))
        let closeOther = await errorText(BrowseTabsTool(), ["action": .string("close"), "tab": .string("t1")], scope: "chat-B")
        #expect(closeOther.contains("No tab t1"))
        #expect(!setup.driver.calls.contains("selectTab t1") && !setup.driver.calls.contains("closeTab t1"))
    }

    private func errorText(_ tool: some AgentTool, _ arguments: [String: JSONValue], scope: String) async -> String {
        do { return try await tool.run(.object(arguments), context: context(scope)) } catch { return error.localizedDescription }
    }

    @Test func theLabelOfATabIsAWordTheBrowserTakesAsAName() {
        #expect(TabBook.label(for: "B3F1C2D4-9A7E-4C55-8D21-0123456789AB") == "cb3f1c2d4")
        #expect(TabBook.label(for: "!!").hasPrefix("c"))
        #expect(!TabBook.label(for: "../x --y").contains(" ") && !TabBook.label(for: "../x --y").contains("-"))
    }
}
