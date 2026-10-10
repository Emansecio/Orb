import Foundation
import Testing
@testable import Orb

/// The `browse_*` tools against a fake browser: what they return, what they refuse and what they ask for.
struct BrowseToolTests {
    private let setup = FakeBrowserSetup()

    private func run(_ tool: some AgentTool, _ arguments: [String: JSONValue] = [:], context: ToolContext? = nil) async throws -> String {
        try await tool.run(.object(arguments), context: context ?? setup.context())
    }

    private func message(_ tool: some AgentTool, _ arguments: [String: JSONValue] = [:], context: ToolContext? = nil) async -> String {
        do { return try await run(tool, arguments, context: context) } catch { return error.localizedDescription }
    }

    // MARK: Opening and reading

    @Test func openGivesTheFinalAddressAndTitleAndWhatToDoNext() async throws {
        let text = try await run(BrowseOpenTool(), ["url": .string("example.com/docs")])
        #expect(text.contains("Opened https://example.com/docs") && text.contains("“Example”") && text.contains("browse_snapshot"))
        #expect(setup.driver.calls == ["open https://example.com/docs"])
    }

    @Test func onlyWebAddressesAreOpened() async {
        for address in ["file:///etc/passwd", "javascript:alert(1)", "ftp://x.test/", "not an address", ""] {
            let text = await message(BrowseOpenTool(), ["url": .string(address)])
            #expect(text.contains("inválido") || text.contains("url"), "\(address)")
        }
        #expect(setup.driver.calls.isEmpty)
    }

    @Test func aPageThatNeedsThePersonSendsTheModelToBrowseShow() async throws {
        setup.driver.state.withLock { $0.title = "Just a moment..." }
        let challenge = try await run(BrowseOpenTool(), ["url": .string("https://site.test/")])
        #expect(challenge.contains("NOTE") && challenge.contains("bot check") && challenge.contains("browse_show") && challenge.contains("stop"))

        setup.driver.state.withLock { $0.title = "Entrar" }
        let login = try await run(BrowseOpenTool(), ["url": .string("https://site.test/login")])
        #expect(login.contains("login page") && login.contains("Do not enter credentials"))

        setup.driver.state.withLock { $0.title = "Home" }
        let fine = try await run(BrowseOpenTool(), ["url": .string("https://site.test/")])
        #expect(!fine.contains("NOTE"))
    }

    @Test func aBrowserWithoutAWindowSaysSoInsteadOfBrowseShow() async throws {
        let obscura = FakeBrowserSetup(engine: .obscura)
        obscura.driver.state.withLock { $0.title = "Verify you are human" }
        let text = try await BrowseOpenTool().run(.object(["url": .string("https://site.test/")]), context: obscura.context())
        #expect(text.contains("no window") && !text.contains("call browse_show"))
    }

    @Test func theSnapshotListsElementsAndNamesThemForTheApprovalCard() async throws {
        setup.driver.state.withLock {
            $0.snapshot = BrowserSnapshot(url: "https://shop.test/", tree: "- button \"Comprar\" [ref=e7]\n- link \"Ajuda\" [ref=e8]",
                                          refs: ["e7": BrowserRef(role: "button", name: "Comprar"), "e8": BrowserRef(role: "link", name: "Ajuda")])
        }
        let context = setup.context()
        let text = try await BrowseSnapshotTool().run(.object([:]), context: context)
        #expect(text.contains("URL: https://shop.test/") && text.contains("[ref=e7]") && text.contains("untrusted"))
        #expect(setup.driver.calls == ["snapshot interactive=true selector=-"])
        #expect(setup.hub.label(ofRef: "e7", botID: setup.botID) == "Comprar")

        // The card names what is clicked, by what the snapshot said it was.
        let click = BrowseClickTool()
        #expect(click.summary(.object(["ref": .string("e7")]), context: context).title == "Clicando em “Comprar”")
        #expect(click.summary(.object(["ref": .string("@e7")]), context: context).detail == "e7")
        #expect(click.summary(.object(["ref": .string("e99")]), context: context).title == "Clicando na página")
        #expect(BrowseFillTool().summary(.object(["ref": .string("e8"), "text": .string("oi")]), context: context).title == "Preenchendo “Ajuda”")

        _ = try await BrowseSnapshotTool().run(.object(["full": .bool(true), "selector": .string("#main")]), context: context)
        #expect(setup.driver.calls.last == "snapshot interactive=false selector=#main")
    }

    @Test func aLongSnapshotIsPagedAndTheOffsetContinuesTheSameOne() async throws {
        let lines = (1...3_000).map { "- link \"Item número \($0)\" [ref=e\($0)]" }
        setup.driver.state.withLock { $0.snapshot = BrowserSnapshot(url: "https://list.test/", tree: lines.joined(separator: "\n"), refs: [:]) }
        let first = try await BrowseSnapshotTool().run(.object([:]), context: setup.context())
        #expect(first.count < ToolOutputBudget.webPageDefault + 600)
        let next = try #require(first.range(of: "use offset=").map { first[$0.upperBound...] })
        let offset = try #require(Int(next.prefix { $0.isNumber }))
        #expect(first.contains("mais ") && offset > 10_000)

        let second = try await BrowseSnapshotTool().run(.object(["offset": .number(Double(offset))]), context: setup.context())
        #expect(second.contains("caracteres \(offset + 1)–"))
        let snapshots = setup.driver.calls.filter { $0.hasPrefix("snapshot") }
        #expect(snapshots.count == 1, "the second piece comes from the first snapshot, not a new one")

        let bigger = try await BrowseSnapshotTool().run(.object(["max_chars": .number(24_000)]), context: setup.context())
        #expect(bigger.count > first.count && bigger.count < 24_800)
    }

    @Test func anEmptyPageSaysWhatToTryInsteadOfReturningNothing() async throws {
        setup.driver.state.withLock { $0.snapshot = BrowserSnapshot(url: "https://empty.test/", tree: "", refs: [:]) }
        let text = try await BrowseSnapshotTool().run(.object([:]), context: setup.context())
        #expect(text.contains("Nothing to list") && text.contains("browse_read"))
    }

    @Test func aLoginFormInTheSnapshotIsAHandoff() async throws {
        setup.driver.state.withLock {
            $0.snapshot = BrowserSnapshot(url: "https://app.test/", tree: "- textbox \"E-mail\" [ref=e1]\n- textbox \"Senha\" [ref=e2]\n- button \"Entrar\" [ref=e3]", refs: [:])
        }
        let text = try await BrowseSnapshotTool().run(.object([:]), context: setup.context())
        #expect(text.contains("login form") && text.contains("browse_show"))
    }

    @Test func readPagesTheTextAndMarksItAsData() async throws {
        let long = (1...2_000).map { "Linha \($0) com algum texto." }.joined(separator: "\n")
        setup.driver.state.withLock { $0.readContent = long }
        let first = try await BrowseReadTool().run(.object([:]), context: setup.context())
        #expect(first.hasPrefix("URL: https://example.com/") && first.contains("untrusted") && first.contains("use offset="))
        let next = try #require(first.range(of: "use offset=").map { first[$0.upperBound...] })
        let offset = try #require(Int(next.prefix { $0.isNumber }))
        let second = try await BrowseReadTool().run(.object(["offset": .number(Double(offset))]), context: setup.context())
        #expect(second.contains("caracteres \(offset + 1)–"))
        #expect(setup.driver.calls.filter { $0 == "read" }.count == 1)

        setup.driver.state.withLock { $0.readContent = "" }
        let empty = try await BrowseReadTool().run(.object([:]), context: setup.context())
        #expect(empty.contains("sem texto"))
    }

    // MARK: Acting

    @Test func refsAreTakenInTheShapesAModelWritesThem() throws {
        #expect(try BrowseSupport.ref(.object(["ref": .string("e12")])) == "e12")
        #expect(try BrowseSupport.ref(.object(["ref": .string("@e12")])) == "e12")
        #expect(try BrowseSupport.ref(.object(["ref": .string("12")])) == "e12")
        for bad in ["", "button", "e", "e1x", "#submit", "@@e1"] {
            #expect(throws: ToolError.self) { try BrowseSupport.ref(.object(["ref": .string(bad)])) }
        }
    }

    @Test func clickFillSelectAndPressReachTheBrowser() async throws {
        #expect(try await run(BrowseClickTool(), ["ref": .string("@e1")]).contains("Clicked e1"))
        #expect(try await run(BrowseFillTool(), ["ref": .string("e1"), "text": .string("olá")]) == "Filled e1.")
        let submitted = try await run(BrowseFillTool(), ["ref": .string("e1"), "text": .string("busca"), "submit": .bool(true)])
        #expect(submitted.contains("pressed Enter"))
        #expect(try await run(BrowseSelectTool(), ["ref": .string("e1"), "value": .string("BR")]).contains("BR"))
        #expect(try await run(BrowsePressTool(), ["key": .string("ArrowDown")]).contains("Pressed ArrowDown"))
        let calls = setup.driver.calls
        #expect(calls.contains("click e1") && calls.contains("fill e1 olá") && calls.contains("fill e1 busca") && calls.contains("press Enter"))
        #expect(calls.contains("select e1 BR") && calls.contains("press ArrowDown"))
        #expect(await message(BrowsePressTool(), ["key": .string("two words")]).contains("`key` is one of"))
    }

    @Test func aStaleRefGetsTheAdviceToSnapshotAgain() async {
        setup.driver.state.withLock { $0.failure = .failed("Element @e9 not found") }
        let text = await message(BrowseClickTool(), ["ref": .string("e9")])
        #expect(text.contains("not found") && text.contains("fresh browse_snapshot"))
    }

    @Test func aPasswordFieldIsNeverFilledWhateverTheLanguage() async throws {
        let names = ["Senha", "Password", "Confirm your password", "Contraseña", "Passwort", "Mot de passe"]
        for (index, name) in names.enumerated() {
            let ref = "e\(index + 1)"
            let fake = FakeBrowserSetup()
            fake.driver.state.withLock { $0.snapshot = BrowserSnapshot(url: "https://a.test/", tree: "- textbox \"\(name)\" [ref=\(ref)]", refs: [ref: BrowserRef(role: "textbox", name: name)]) }
            let context = fake.context()
            _ = try await BrowseSnapshotTool().run(.object([:]), context: context)
            await #expect(throws: ToolError.self, "\(name)") {
                try await BrowseFillTool().run(.object(["ref": .string(ref), "text": .string("hunter2")]), context: context)
            }
            #expect(!fake.driver.calls.contains { $0.hasPrefix("fill") }, "\(name): nothing was typed")
        }
    }

    @Test func aFieldIsRefusedByItsTypeEvenWhenItsNameGivesNothingAway() async throws {
        setup.driver.state.withLock {
            $0.snapshot = BrowserSnapshot(url: "https://a.test/", tree: "- textbox \"Código\" [ref=e4]", refs: ["e4": BrowserRef(role: "textbox", name: "Código")])
            $0.attributes["e4.type"] = "password"
        }
        let context = setup.context()
        _ = try await BrowseSnapshotTool().run(.object([:]), context: context)
        let refused = await message(BrowseFillTool(), ["ref": .string("e4"), "text": .string("x")], context: context)
        #expect(refused.contains("Refused") && refused.contains("password field") && refused.contains("browse_show"))

        setup.driver.state.withLock { $0.attributes = ["e4.autocomplete": "current-password"] }
        #expect(await message(BrowseFillTool(), ["ref": .string("e4"), "text": .string("x")], context: context).contains("Refused"))
        setup.driver.state.withLock { $0.attributes = ["e4.autocomplete": "cc-number"] }
        #expect(await message(BrowseFillTool(), ["ref": .string("e4"), "text": .string("x")], context: context).contains("card field"))
        #expect(!setup.driver.calls.contains { $0.hasPrefix("fill") })

        setup.driver.state.withLock { $0.attributes = ["e4.type": "text"] }
        #expect(try await BrowseFillTool().run(.object(["ref": .string("e4"), "text": .string("ok")]), context: context) == "Filled e4.")
    }

    @Test func cardNumbersAreRefusedToo() async {
        for name in ["Número do cartão", "Card number", "CVV", "Código de segurança"] {
            #expect(SecretField.reason(role: "textbox", name: name) != nil, "\(name)")
        }
        #expect(SecretField.reason(role: "textbox", name: "E-mail") == nil)
        #expect(SecretField.reason(role: "textbox", name: "Buscar") == nil)
    }

    @Test func scrollBackAndTabsWork() async throws {
        #expect(try await run(BrowseScrollTool(), ["direction": .string("up"), "amount": .number(250)]) == "Scrolled up 250 px.")
        #expect(try await run(BrowseScrollTool()).contains("down 600"))
        #expect(await message(BrowseScrollTool(), ["direction": .string("sideways")]).contains("up, down, left or right"))
        #expect(try await run(BrowseBackTool()).contains("Back at https://example.com/"))

        let list = try await run(BrowseTabsTool())
        #expect(list.contains("t1 *") && list.contains("“Example”"))
        _ = try await run(BrowseTabsTool(), ["action": .string("new"), "url": .string("https://b.test/")])
        _ = try await run(BrowseTabsTool(), ["action": .string("select"), "tab": .string("t2")])
        _ = try await run(BrowseTabsTool(), ["action": .string("close"), "tab": .string("t2")])
        let calls = setup.driver.calls
        #expect(calls.contains("newTab https://b.test/") && calls.contains("selectTab t2") && calls.contains("closeTab t2"))
        #expect(await message(BrowseTabsTool(), ["action": .string("explode")]).contains("one of"))
    }

    @Test func aScreenshotComesBackAsAPictureTheModelCanSee() async throws {
        let png = try Fixtures.png(text: "Olá")
        setup.driver.state.withLock { $0.screenshotBytes = png }
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbBrowseShots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var context = setup.context()
        context.imageStore = ImageStore(directory: folder)
        context.acceptsImages = true
        let result = try await BrowseScreenshotTool().runWithImages(.object([:]), context: context)
        #expect(result.images.count == 1 && result.text.contains("Screenshot of https://example.com/"))
        #expect(FileManager.default.fileExists(atPath: result.images[0].path))

        // A model that cannot see gets the text on the picture instead.
        context.acceptsImages = false
        let text = try await BrowseScreenshotTool().run(.object([:]), context: context)
        #expect(text.contains("OCR") && text.contains("Ol"))
    }

    // MARK: Window and closing

    @Test func showOpensTheWindowAndTellsTheModelToStopUntilTheUserAnswers() async throws {
        let text = try await run(BrowseShowTool())
        #expect(setup.driver.calls.contains("setHeaded true"))
        #expect(text.contains("STOP") && text.contains("tell the user") && text.contains("reply"))
        let session = try await setup.hub.session(botID: setup.botID, engine: .chrome)
        #expect(session.isShowingWindow)

        let hidden = try await run(BrowseShowTool(), ["hide": .bool(true)])
        #expect(setup.driver.calls.contains("setHeaded false") && hidden.contains("background") && !session.isShowingWindow)
    }

    @Test func stoppingWhileTheWindowIsOpenHidesItFromATaskOfItsOwn() async throws {
        let fake = FakeBrowserSetup()
        var context = fake.context()
        // The card waits like an approval does: until the person answers, or the task is cancelled (Parar).
        context.handoff = { _ in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return false
        }
        let task = Task { try await BrowseShowTool().run(.object([:]), context: context) }
        await waitUntil("the window to open") { fake.driver.calls.contains("setHeaded true") }
        try await Task.sleep(for: .milliseconds(30)) // the call is waiting on the card now
        task.cancel()
        await #expect(throws: ToolError.self) { _ = try await task.value }
        // The cancelled task cannot run the commands that close the window: a task of the tool's own does.
        await waitUntil("the window to be hidden") { fake.driver.calls.contains("setHeaded false") }
        let session = try await fake.hub.session(botID: fake.botID, engine: .chrome)
        await waitUntil("the Orb to know it is hidden") { !session.isShowingWindow }
    }

    @Test func cancelarHidesTheWindowInTheCallItself() async throws {
        let fake = FakeBrowserSetup()
        var context = fake.context()
        context.handoff = { _ in false } // Cancelar: not a stopped task
        _ = await message(BrowseShowTool(), context: context)
        #expect(fake.driver.calls == ["setHeaded true", "setHeaded false"])
    }

    // MARK: Keys

    @Test func browsePressTakesNamedKeysAndNothingThatTypes() async throws {
        let named = [("Enter", "Enter"), ("return", "Enter"), ("tab", "Tab"), ("Shift+Tab", "Shift+Tab"), ("ArrowDown", "ArrowDown"), ("up", "ArrowUp"),
                     ("esc", "Escape"), ("Escape", "Escape"), ("PageUp", "PageUp"), ("pagedown", "PageDown"), ("Home", "Home"), ("End", "End"),
                     ("Backspace", "Backspace"), ("delete", "Delete"), ("Space", "Space")]
        for (given, sent) in named {
            let fake = FakeBrowserSetup()
            let text = try await run(BrowsePressTool(), ["key": .string(given)], context: fake.context())
            #expect(fake.driver.calls.contains("press \(sent)") && text.contains("Pressed \(sent)"), "\(given)")
        }
        // A key that types a character, or pastes what the clipboard holds, is a way around the rule that passwords are the person's.
        for refused in ["a", "S", "1", "-", "Control+v", "Meta+v", "Control+Shift+v", "Shift+Insert", "Control+a", "Alt+x", "Control+Alt+Delete", "F5", "", "Enter Enter"] {
            let fake = FakeBrowserSetup()
            let text = await message(BrowsePressTool(), ["key": .string(refused)], context: fake.context())
            #expect(text.contains("`key` is one of") || text.contains("key"), "\(refused)")
            #expect(!fake.driver.calls.contains { $0.hasPrefix("press") }, "\(refused) must not reach the browser: \(fake.driver.calls)")
        }
    }

    @Test func browsePressIsRefusedWhileAPasswordOrCardFieldHasTheFocus() async throws {
        func focus(_ type: String, _ autocomplete: String = "", _ label: String = "x") -> String {
            "{\"type\":\"\(type)\",\"autocomplete\":\"\(autocomplete)\",\"label\":\"\(label)\"}"
        }
        let secret = [focus("password"), focus("text", "current-password"), focus("text", "new-password"), focus("text", "cc-number"),
                      focus("text", "cc-csc"), focus("text", "", "Senha"), focus("text", "", "Número do cartão"), focus("text", "", "CVV")]
        for focused in secret {
            let fake = FakeBrowserSetup()
            fake.driver.state.withLock { $0.evaluation = focused }
            for key in ["Space", "Backspace", "Enter"] {
                let text = await message(BrowsePressTool(), ["key": .string(key)], context: fake.context())
                #expect(text.contains("Refused") && text.contains("browse_show"), "\(focused) \(key): \(text)")
            }
            #expect(!fake.driver.calls.contains { $0.hasPrefix("press") }, "\(focused)")
        }
        // An ordinary field, or nothing focused, is fine.
        for focused in [focus("text", "email", "Email"), focus("search"), "{}", ""] {
            let fake = FakeBrowserSetup()
            fake.driver.state.withLock { $0.evaluation = focused }
            _ = try await run(BrowsePressTool(), ["key": .string("Space")], context: fake.context())
            #expect(fake.driver.calls.contains("press Space"), "\(focused)")
        }
        // The script that asks the page is the one the tool runs, and it reads the focused element.
        #expect(BrowsePressTool.focusScript.contains("document.activeElement"))
    }

    @Test func browseTabsCountsAsNotReadOnlyForAClientThatOnlySeesTheNameAndSchema() {
        // With no arguments it lists, and `new` with a `url` goes to a site.
        #expect(BrowseTabsTool().risk(.object([:])) == .safe)
        #expect(BrowseTabsTool().announcedReadOnly == false)
        #expect(BrowseSnapshotTool().announcedReadOnly == false && BrowseReadTool().announcedReadOnly == false, "they read a live page")
        #expect(BrowseCloseTool().announcedReadOnly == true)
        #expect(WebSearchTool().announcedReadOnly == false && BrowseClickTool().announcedReadOnly == false)
    }

    @Test func obscuraHasNoWindowToShow() async {
        let obscura = FakeBrowserSetup(engine: .obscura)
        let text = await message(BrowseShowTool(), context: obscura.context())
        #expect(text.contains("no window") && text.contains("Chrome"))
        #expect(!obscura.driver.calls.contains { $0.hasPrefix("setHeaded") })
    }

    @Test func closeClosesTheBrowserOnce() async throws {
        #expect(try await run(BrowseCloseTool()) == "The browser was not open.")
        _ = try await run(BrowseOpenTool(), ["url": .string("https://a.test/")])
        #expect(try await run(BrowseCloseTool()) == "Browser closed.")
        #expect(setup.driver.calls.contains("close"))
        #expect(setup.hub.existingSession(botID: setup.botID) == nil)
    }

    @Test func withoutABrowserTheToolsSayWhatToUseInstead() async {
        let none = ToolContext(workingDirectory: FileManager.default.temporaryDirectory, botID: UUID())
        #expect(await message(BrowseOpenTool(), ["url": .string("https://a.test/")], context: none).contains("web_fetch"))
        var simple = setup.context()
        simple.browser.engine = .simple
        #expect(await message(BrowseSnapshotTool(), context: simple).contains("not available"))
    }

    @Test func aMissingInstallIsToldInsteadOfStartingAnything() async {
        let missing = FakeBrowserSetup(ready: false)
        let text = await message(BrowseOpenTool(), ["url": .string("https://a.test/")], context: missing.context())
        #expect(text.contains("Ajustes") && text.contains("Chrome"))
        #expect(missing.driver.calls.isEmpty && missing.configs.withLock { $0.isEmpty })
    }

    @Test func theCommandsOfOneBrowserNeverRunAtTheSameTime() async throws {
        let session = try await setup.hub.session(botID: setup.botID, engine: .chrome)
        let running = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    _ = try? await session.exclusive {
                        await running.enter()
                        try await Task.sleep(for: .milliseconds(5))
                        await running.leave()
                    }
                }
            }
        }
        #expect(await running.maximum == 1)
    }

    @Test func theHubKeepsTheBrowserOfAnOrbAndReplacesItWhenTheEngineChanges() async throws {
        let first = try await setup.hub.session(botID: setup.botID, engine: .chrome)
        #expect(try await setup.hub.session(botID: setup.botID, engine: .chrome) === first)
        let other = try await setup.hub.session(botID: setup.botID, engine: .cloak)
        #expect(other !== first && other.engine == .cloak)
        #expect(setup.driver.calls == ["close"], "the old browser was closed")
        #expect(setup.configs.withLock { $0.map(\.engine) } == [.chrome, .cloak])
    }

    @Test func deletingTheOrbDeletesWhatItsBrowserKept() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbBrowserData-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = FakeBrowserSetup(profiles: folder)
        let profile = folder.appending(path: fake.botID.uuidString).appending(path: "chrome")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        _ = try await fake.hub.session(botID: fake.botID, engine: .chrome)
        await fake.hub.deleteData(botID: fake.botID)
        #expect(!FileManager.default.fileExists(atPath: profile.path))
        #expect(fake.driver.calls.contains("close"))
    }
}

private actor Counter {
    private var current = 0
    private(set) var maximum = 0
    func enter() { current += 1; maximum = max(maximum, current) }
    func leave() { current -= 1 }
}

/// What each tool asks of the permission system.
struct BrowsePermissionTests {
    private let context = FakeBrowserSetup().context()

    private func verdict(_ name: String, _ arguments: [String: JSONValue] = [:], mode: PermissionMode = .ask,
                         rules: [PermissionRule] = []) throws -> PermissionVerdict {
        let tool = try #require((ToolBox.browseTools + ToolBox.searchTools + ToolBox.webTools).first { $0.spec.name == name })
        let call = PermissionPolicy.call(for: tool, arguments: .object(arguments), context: context)
        return PermissionPolicy.evaluate(mode: mode, call: call, rules: rules, workspace: nil)
    }

    private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) throws -> PermissionCall {
        let tool = try #require((ToolBox.browseTools + ToolBox.searchTools).first { $0.spec.name == name })
        return PermissionPolicy.call(for: tool, arguments: .object(arguments), context: context)
    }

    @Test func openingAndSearchingAskLikeFetchingDoes() throws {
        #expect(try verdict("browse_open", ["url": .string("https://a.test/x")]) == .ask(.needsPermission))
        #expect(try verdict("web_search", ["query": .string("x")]) == .ask(.needsPermission))
        #expect(try verdict("web_fetch", ["url": .string("https://a.test/x")]) == .ask(.needsPermission))
        #expect(try verdict("browse_tabs", ["action": .string("new"), "url": .string("https://a.test/")]) == .ask(.needsPermission))
    }

    @Test func aSiteOrSearchGrantCoversThem() throws {
        #expect(try verdict("browse_open", ["url": .string("https://docs.a.test/x")], rules: [.host("a.test")]) == .allow)
        #expect(try verdict("browse_open", ["url": .string("https://b.test/")], rules: [.host("a.test")]) == .ask(.needsPermission))
        #expect(try verdict("web_search", ["query": .string("x")], rules: [PermissionRule(family: .web, scope: .search)]) == .allow)
        #expect(try verdict("web_search", ["query": .string("x")], rules: [.host("a.test")]) == .ask(.needsPermission))
        let suggestions = try PermissionPolicy.suggestions(for: call("web_search", ["query": .string("x")]))
        #expect(suggestions == [PermissionRule(family: .web, scope: .search)])
    }

    @Test func clickingAndTypingFollowTheModeAndHaveAFamilyOfTheirOwn() throws {
        for name in ["browse_click", "browse_fill", "browse_select", "browse_press", "browse_show"] {
            let arguments: [String: JSONValue] = ["ref": .string("e1"), "text": .string("x"), "value": .string("v"), "key": .string("Enter")]
            #expect(try verdict(name, arguments) == .ask(.needsPermission), "\(name)")
            #expect(try verdict(name, arguments, mode: .auto) == .allow, "\(name)")
            #expect(try verdict(name, arguments, mode: .bypass) == .allow, "\(name)")
            #expect(try verdict(name, arguments, mode: .readOnly) == .deny(PermissionPolicy.readOnlyDenial), "\(name)")
            #expect(try verdict(name, arguments, rules: [PermissionRule(family: .browserPage)]) == .allow, "\(name)")
            // A grant to read sites never lets the Orb act inside them, and the other way round.
            #expect(try verdict(name, arguments, rules: [PermissionRule(family: .web)]) == .ask(.needsPermission), "\(name)")
            #expect(PermissionPolicy.family(ofTool: name, kind: .browser) == .browserPage)
        }
        #expect(try verdict("browse_open", ["url": .string("https://a.test/")], rules: [PermissionRule(family: .browserPage)]) == .ask(.needsPermission))
        #expect(try PermissionPolicy.suggestions(for: call("browse_click", ["ref": .string("e1")])) == [PermissionRule(family: .browserPage)])
        #expect(PermissionRule(family: .browserPage).title == "Clicar e preencher páginas no navegador do Orb")
        #expect(PermissionRule(family: .browserPage).menuTitle == "Sempre permitir clicar e preencher páginas no navegador do Orb")
    }

    @Test func lookingAtTheOpenPageAsksNothingButReadOnlyRefusesIt() throws {
        let looking = ["browse_snapshot", "browse_read", "browse_screenshot", "browse_scroll", "browse_back"]
        for name in looking {
            #expect(try verdict(name) == .allow, "\(name)")
            #expect(try verdict(name, mode: .auto) == .allow, "\(name)")
            #expect(try verdict(name, mode: .readOnly) == .deny(PermissionPolicy.readOnlyDenial), "\(name)")
        }
        for action in ["list", "select", "close"] {
            #expect(try verdict("browse_tabs", ["action": .string(action)]) == .allow)
            #expect(try verdict("browse_tabs", ["action": .string(action)], mode: .readOnly) == .deny(PermissionPolicy.readOnlyDenial))
        }
        #expect(try verdict("browse_tabs") == .allow, "list is the default")
    }

    @Test func readOnlyRefusesTheWebTools() throws {
        #expect(try verdict("browse_open", ["url": .string("https://a.test/")], mode: .readOnly) == .deny(PermissionPolicy.readOnlyDenial))
        #expect(try verdict("web_search", ["query": .string("x")], mode: .readOnly) == .deny(PermissionPolicy.readOnlyDenial))
        #expect(try verdict("web_fetch", ["url": .string("https://a.test/")], mode: .readOnly) == .deny(PermissionPolicy.readOnlyDenial))
        // Closing the browser only frees it.
        #expect(try verdict("browse_close", mode: .readOnly) == .allow)
    }

    @Test func everyBrowserToolThatAsksHasAFamilyAndTheCatalogIsWellFormed() {
        for tool in ToolBox.browseTools + ToolBox.searchTools {
            #expect(tool.kind == .browser && tool.capability == .browser, "\(tool.spec.name)")
            #expect(tool.spec.parameters["type"] == .string("object") && !tool.spec.description.isEmpty)
            for required in tool.spec.parameters["required"]?.array ?? [] {
                #expect(tool.spec.parameters["properties"]?[required.string ?? ""] != nil, "\(tool.spec.name)")
            }
            if tool.risk(.object(["action": .string("new")])) != .safe {
                #expect(PermissionPolicy.family(ofTool: tool.spec.name, kind: tool.kind) != nil, "\(tool.spec.name)")
            }
        }
        let names = ToolBox.all.map(\.spec.name)
        #expect(Set(names).count == names.count)
    }

    @Test func theDescriptionsKeepTheRulesAboutThePerson() throws {
        func text(_ name: String) throws -> String {
            let tool = try #require(ToolBox.all.first { $0.spec.name == name })
            return tool.spec.description + tool.spec.parameters.jsonString
        }
        for word in ["login", "2FA", "captcha", "browse_show"] { #expect(try text("browse_open").contains(word), "open: \(word)") }
        for word in ["passwords", "card", "browse_show"] { #expect(try text("browse_fill").contains(word), "fill: \(word)") }
        for word in ["Pronto", "Cancelar", "stop", "hide"] { #expect(try text("browse_show").contains(word), "show: \(word)") }
        for word in ["offset", "12,000", "24,000", "ref (e12)"] { #expect(try text("browse_snapshot").contains(word), "snapshot: \(word)") }
        for word in ["offset", "12,000", "24,000"] { #expect(try text("browse_read").contains(word), "read: \(word)") }
        for word in ["site", "news", "browse_show", "web_fetch"] { #expect(try text("web_search").contains(word), "search: \(word)") }
    }
}
