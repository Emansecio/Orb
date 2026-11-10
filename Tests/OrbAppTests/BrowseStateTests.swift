import Foundation
import os
import Testing
@testable import Orb

// What an acting browse_* tool appends after it acted (the page's new state), so the model does not spend a trip asking for a
// snapshot: the page as browse_snapshot shows it, one sentence when nothing changed, the tabs, and the cases around them.

struct BrowseStateTests {
    private let setup = FakeBrowserSetup()

    private func page(_ items: [(ref: String, name: String)], url: String = "https://shop.test/") -> BrowserSnapshot {
        BrowserSnapshot(url: url, tree: items.map { "- button \"\($0.name)\" [ref=\($0.ref)]" }.joined(separator: "\n"),
                        refs: Dictionary(uniqueKeysWithValues: items.map { ($0.ref, BrowserRef(role: "button", name: $0.name)) }))
    }

    private func show(_ snapshot: BrowserSnapshot) { setup.driver.state.withLock { $0.snapshot = snapshot } }

    private func run(_ tool: some AgentTool, _ arguments: [String: JSONValue] = [:], context: ToolContext? = nil) async throws -> String {
        try await tool.run(.object(arguments), context: context ?? setup.context())
    }

    private var snapshotCalls: Int { setup.driver.calls.filter { $0.hasPrefix("snapshot") }.count }

    @Test func aClickThatChangedThePageBringsTheNewPageWithItsRefsAndTheWarning() async throws {
        show(page([("e1", "Comprar")]))
        _ = try await run(BrowseSnapshotTool())
        show(page([("e7", "Pagar"), ("e8", "Voltar")]))
        let text = try await run(BrowseClickTool(), ["ref": .string("e1")])
        #expect(text.hasPrefix("Clicked e1. Page: https://example.com/."))
        let state = try #require(text.range(of: BrowseSupport.stateMarker))
        let shown = String(text[state.upperBound...])
        #expect(shown.hasPrefix("URL: https://shop.test/\n\(BrowseSupport.untrusted)"))
        #expect(shown.contains("[ref=e7]") && shown.contains("[ref=e8]"))
        // The refs it shows are the session's now: the cards name them and the next snapshot pages the same read.
        #expect(setup.hub.label(ofRef: "e7", botID: setup.botID) == "Pagar")
        let again = try await run(BrowseClickTool(), ["ref": .string("e7")])
        #expect(again.contains("Page unchanged"), "what it was just shown is what it last saw")
    }

    @Test func aClickThatChangedNothingSaysSoInOneSentence() async throws {
        show(page([("e1", "Comprar")]))
        _ = try await run(BrowseSnapshotTool())
        let text = try await run(BrowseClickTool(), ["ref": .string("e1")])
        #expect(text.contains("Page unchanged since your last snapshot"))
        #expect(!text.contains("[ref=") && !text.contains(BrowseSupport.untrusted) && !text.contains(BrowseSupport.stateMarker))
    }

    @Test func withNothingSeenBeforeThePageIsShown() async throws {
        show(page([("e1", "Comprar")]))
        let text = try await run(BrowseClickTool(), ["ref": .string("e1")])
        #expect(text.contains("[ref=e1]") && text.contains(BrowseSupport.untrusted))
    }

    @Test func aPartialSnapshotIsNeverWhatUnchangedIsComparedWith() async throws {
        show(page([("e1", "Comprar")]))
        _ = try await run(BrowseSnapshotTool(), ["query": .string("Comprar")])
        let text = try await run(BrowseClickTool(), ["ref": .string("e1")])
        #expect(text.contains("[ref=e1]"), "the model saw only some lines: it gets the page")
    }

    @Test func hoverAndFocusAskForNoState() async throws {
        for action in ["hover", "focus", "scrollintoview"] {
            _ = try await run(BrowseClickTool(), ["ref": .string("e1"), "action": .string(action)])
        }
        #expect(snapshotCalls == 0)
    }

    @Test func aPageStillLoadingIsPhotographedOnceItSettles() async throws {
        let loading = page([("e1", "Carregando")]), done = page([("e2", "Pronto")])
        setup.driver.state.withLock { $0.snapshotScript = [loading, done, done] }
        let text = try await run(BrowseClickTool(), ["ref": .string("e1")])
        #expect(text.contains("[ref=e2]") && !text.contains("[ref=e1]"))
        #expect(!text.contains("still changing"))
        #expect(snapshotCalls == 3, "two equal ones in a row end the wait")
    }

    @Test func aPageThatNeverSettlesIsShownAsItIsWithAWarning() async throws {
        setup.driver.state.withLock { $0.snapshotScript = (0...30).map { page([("e\($0)", "Item \($0)")]) } }
        let text = try await run(BrowseClickTool(), ["ref": .string("e1")])
        #expect(text.contains("still changing"))
        #expect(snapshotCalls == 1 + BrowseSupport.settlePolls, "a short ceiling, not a loop")
    }

    @Test func aJavaScriptDialogIsReportedAsBeforeAndNothingElseIsAsked() async throws {
        let dialog = "A JavaScript confirm dialog (“ok?”) is open and blocks the page: call browse_dialog to accept or dismiss it, then retry."
        setup.driver.state.withLock { $0.urlFailure = .failed(dialog) }
        let text = try await run(BrowseClickTool(), ["ref": .string("e1")])
        #expect(text.contains("browse_dialog") && !text.contains(BrowseSupport.stateMarker))
        #expect(snapshotCalls == 0)
    }

    @Test func aSnapshotThatFailsLeavesTheActionsOwnAnswerAndTheOldAdvice() async throws {
        setup.driver.state.withLock { $0.snapshotFailure = .failed("the page is gone") }
        let text = try await run(BrowseClickTool(), ["ref": .string("e1")])
        #expect(text.contains("Clicked e1") && text.contains("take a new browse_snapshot"))
    }

    @Test func stoppingEndsTheWaitForThePageToSettle() async throws {
        setup.cancelsPauses.withLock { $0 = true }
        await #expect(throws: CancellationError.self) { _ = try await run(BrowseClickTool(), ["ref": .string("e1")]) }
    }

    @Test func fillBringsTheStateOnlyWhenItSubmits() async throws {
        let plain = try await run(BrowseFillTool(), ["ref": .string("e1"), "text": .string("oi")])
        #expect(plain == "Filled e1." && snapshotCalls == 0)
        let sent = try await run(BrowseFillTool(), ["ref": .string("e1"), "text": .string("oi"), "submit": .bool(true)])
        #expect(sent.contains("pressed Enter") && sent.contains(BrowseSupport.stateMarker) && snapshotCalls > 0)
    }

    @Test func aSecretFieldIsStillRefusedAndNothingIsPhotographed() async throws {
        setup.driver.state.withLock { $0.attributes = ["e2.type": "password"] }
        await #expect(throws: ToolError.self) { _ = try await run(BrowseFillTool(), ["ref": .string("e2"), "text": .string("x"), "submit": .bool(true)]) }
        #expect(snapshotCalls == 0)
    }

    @Test func pressScrollAndBackBringTheStateToo() async throws {
        let press = try await run(BrowsePressTool(), ["key": .string("Enter")])
        #expect(press.hasPrefix("Pressed Enter.") && press.contains(BrowseSupport.stateMarker))
        let scroll = try await run(BrowseScrollTool(), ["amount": .number(400)])
        #expect(scroll.hasPrefix("Scrolled down 400 px.") && scroll.contains("Page unchanged"))
        let back = try await run(BrowseBackTool())
        #expect(back.hasPrefix("Back at https://example.com/") && back.contains("Page unchanged"))
        let typed = try await run(BrowsePressTool(), ["text": .string("oi")])
        #expect(typed.hasPrefix("Typed 2 characters") && !typed.contains(BrowseSupport.stateMarker), "typing text changes little: no snapshot")
    }

    @Test func aLoginPageInTheStateStillTellsTheModelToHandOff() async throws {
        show(BrowserSnapshot(url: "https://app.test/", tree: "- textbox \"E-mail\" [ref=e1]\n- textbox \"Senha\" [ref=e2]", refs: [:]))
        let text = try await run(BrowseClickTool(), ["ref": .string("e9")])
        #expect(text.contains("browse_show"))
        #expect(setup.hub.pageLooksSensitive(botID: setup.botID))
    }

    // MARK: Tabs

    private func tabs(_ list: [(String, String, Bool)]) {
        setup.driver.state.withLock {
            $0.tabs = list.map { BrowserTab(id: $0.0, title: $0.1, url: "https://\($0.1.lowercased()).test/pagina", isActive: $0.2) }
        }
    }

    @Test func aSnapshotListsTheTabsOnlyWhenThereIsMoreThanOne() async throws {
        show(page([("e1", "Comprar")]))
        let one = try await run(BrowseSnapshotTool())
        #expect(!one.contains("Tabs ("))
        tabs([("t1", "Loja", true), ("t2", "Docs", false)])
        let two = try await run(BrowseSnapshotTool())
        #expect(two.hasPrefix("URL: https://shop.test/\nTabs (* is current): t1* “Loja” https://loja.test/pagina · t2 “Docs” https://docs.test/pagina\n"))
    }

    @Test func aTabTheActionOpenedIsSaidOutRight() async throws {
        show(page([("e1", "Abrir")]))
        _ = try await run(BrowseSnapshotTool())
        tabs([("t1", "Loja", false), ("t2", "Docs", true)])
        show(page([("e5", "Índice")], url: "https://docs.test/"))
        let text = try await run(BrowseClickTool(), ["ref": .string("e1")])
        #expect(text.contains("opened a new tab (t2)") && text.contains("Tabs (* is current)"))
        let next = try await run(BrowseClickTool(), ["ref": .string("e5")])
        #expect(!next.contains("opened a new tab"), "said once")
    }

    @Test func withOneTabNothingAboutTabsIsSaid() async throws {
        show(page([("e1", "Comprar")]))
        _ = try await run(BrowseSnapshotTool())
        show(page([("e2", "Pagar")]))
        let text = try await run(BrowseClickTool(), ["ref": .string("e1")])
        #expect(!text.contains("Tabs (") && !text.contains("new tab"))
    }

    // MARK: Opening

    @Test func openBringsThePageAndWaitsForTheTextItWasToldTo() async throws {
        show(page([("e1", "Entrar")]))
        let text = try await run(BrowseOpenTool(), ["url": .string("https://shop.test/"), "wait_text": .string("Bem-vindo")])
        let calls = setup.driver.calls
        let wait = try #require(calls.firstIndex(of: "command wait --text Bem-vindo --timeout 10000"))
        #expect(wait > calls.firstIndex(of: "open https://shop.test/")! && wait < calls.firstIndex { $0.hasPrefix("snapshot") }!)
        #expect(text.contains("appeared") && text.contains("[ref=e1]"))
    }

    @Test func aTextThatNeverComesIsToldAndThePageIsStillGiven() async throws {
        show(page([("e1", "Entrar")]))
        setup.driver.state.withLock { $0.failingCommands["wait --text Nunca --timeout 10000"] = .failed("Timeout 10000ms exceeded") }
        let text = try await run(BrowseOpenTool(), ["url": .string("https://shop.test/"), "wait_text": .string("Nunca")])
        #expect(text.contains("did not appear within 10 s") && text.contains("[ref=e1]"))
    }

    @Test func aWaitTextThatLooksLikeAnOptionIsRefused() async throws {
        await #expect(throws: ToolError.self) { _ = try await run(BrowseOpenTool(), ["url": .string("https://shop.test/"), "wait_text": .string("--help")]) }
        #expect(setup.driver.calls.isEmpty)
    }

    @Test func openWithoutWaitTextAsksForNoWait() async throws {
        _ = try await run(BrowseOpenTool(), ["url": .string("https://shop.test/")])
        #expect(!setup.driver.calls.contains { $0.hasPrefix("command wait") })
    }
}

struct BrowseStateHistoryTests {
    private let budget = ContextBudget(tokens: 40_000)

    private func step(_ id: String, _ name: String, _ body: String) -> [ChatMessage] {
        [ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: id, name: name, arguments: "{}")]), .tool(id, body)]
    }

    private func finished(_ request: String, _ steps: [ChatMessage]) -> [ChatMessage] {
        [.user(request)] + steps + [ChatMessage(role: .assistant, content: "ok")]
    }

    private func acted(_ url: String) -> String {
        "Clicked e1. Page: \(url)." + BrowseSupport.stateMarker + "URL: \(url)\n" + String(repeating: "e", count: 6_000)
    }

    @Test func anOldPageAppendedToAnActionGoesWhenANewerOneReplacesItButWhatTheActionSaidStays() {
        let history = finished("um", step("a", "browse_click", acted("https://a.com")))
            + finished("dois", step("b", "browse_snapshot", "URL: https://b.com\n" + String(repeating: "e", count: 6_000)))
            + [.user("três")]
        var cut = ContextCut()
        let out = ContextWindow.fit(history, budget: budget, cut: &cut).messages.filter { $0.role == .tool }
        #expect(out[0].content.hasPrefix("Clicked e1. Page: https://a.com."))
        #expect(out[0].content.contains("substituído por um mais novo") && out[0].content.count < 400)
        #expect(out[1].content.hasPrefix("URL: https://b.com") && out[1].content.count > 3_000)
    }

    @Test func aStateThatSaidUnchangedIsNotASnapshotAndReplacesNothing() {
        let history = finished("um", step("a", "browse_snapshot", "URL: https://a.com\n" + String(repeating: "e", count: 6_000)))
            + finished("dois", step("b", "browse_click", "Clicked e1. Page: https://a.com.\nPage unchanged since your last snapshot; its refs still work."))
            + [.user("três")]
        var cut = ContextCut()
        let out = ContextWindow.fit(history, budget: budget, cut: &cut).messages.filter { $0.role == .tool }
        #expect(out[0].content.hasPrefix("URL: https://a.com") && out[0].content.count > 3_000)
        #expect(out[1].content.contains("Page unchanged"))
    }

    @Test func theNewestPageStaysWhetherItCameFromAnActionOrASnapshot() {
        let history = finished("um", step("a", "browse_snapshot", "URL: https://a.com\n" + String(repeating: "e", count: 6_000)))
            + finished("dois", step("b", "browse_open", acted("https://b.com")))
            + [.user("três")]
        var cut = ContextCut()
        let out = ContextWindow.fit(history, budget: budget, cut: &cut).messages.filter { $0.role == .tool }
        #expect(out[0].content.hasPrefix("[Instantâneo antigo de https://a.com"))
        #expect(out[1].content.contains(BrowseSupport.stateMarker) && out[1].content.count > 3_000)
    }
}
