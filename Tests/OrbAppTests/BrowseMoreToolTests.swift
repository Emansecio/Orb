import Foundation
import Testing
@testable import Orb

/// `browse_wait`, `browse_find`, `browse_dialog`, `browse_files`, `browse_page` and `browse_run`, and the new actions of the
/// first tools, against a fake browser.
struct BrowseMoreToolTests {
    private let setup = FakeBrowserSetup()

    private func run(_ tool: some AgentTool, _ arguments: [String: JSONValue] = [:], context: ToolContext? = nil) async throws -> String {
        try await tool.run(.object(arguments), context: context ?? setup.context())
    }

    private func message(_ tool: some AgentTool, _ arguments: [String: JSONValue] = [:], context: ToolContext? = nil) async -> String {
        do { return try await run(tool, arguments, context: context) } catch { return error.localizedDescription }
    }

    private func args(_ words: String...) -> JSONValue { .object(["args": .array(words.map { .string($0) })]) }

    // MARK: The first tools, with more to do

    @Test func clickDoesWhatActionSaysAndTheSafeOnesAreSafe() async throws {
        let click = BrowseClickTool()
        for action in ["hover", "focus", "scrollintoview"] {
            #expect(click.risk(.object(["ref": .string("e1"), "action": .string(action)])) == .safe, "\(action)")
        }
        for action in ["click", "dblclick", "check", "uncheck", "drag"] {
            #expect(click.risk(.object(["ref": .string("e1"), "action": .string(action)])) == .sensitive, "\(action)")
        }
        _ = try await run(click, ["ref": .string("e1"), "action": .string("dblclick")])
        _ = try await run(click, ["ref": .string("e1"), "action": .string("drag"), "to": .string("e2")])
        #expect(setup.driver.calls.filter { $0.hasPrefix("command") } == ["command dblclick @e1", "command drag @e1 @e2"])
        let refused = await message(click, ["ref": .string("e1"), "action": .string("explode")])
        #expect(refused.contains("`action` is one of"))
        let noTarget = await message(click, ["ref": .string("e1"), "action": .string("drag")])
        #expect(noTarget.contains("to"))
    }

    @Test func aDialogThatOpensIsReportedInsteadOfTheAddress() async throws {
        let dialog = "A JavaScript confirm dialog (“ok?”) is open and blocks the page: call browse_dialog to accept or dismiss it, then retry."
        let text = try await run(BrowseClickTool(), ["ref": .string("e1")])
        #expect(text.contains("Page: https://example.com/"))
        setup.driver.state.withLock { $0.failure = .failed(dialog) }
        // Every call fails now, including the click itself: the error is the sentence the model acts on.
        let failed = await message(BrowseClickTool(), ["ref": .string("e1")])
        #expect(failed.contains("browse_dialog"))
    }

    @Test func theErrorOfABlockingDialogBecomesTheSentenceTheModelActsOn() {
        let raw = "A JavaScript confirm dialog is blocking the page: \"ok?\". Resolve it with `dialog accept` or `dialog dismiss`."
        let sentence = AgentBrowserDriver.dialogBlocking(raw)
        #expect(sentence?.contains("confirm dialog (“ok?”)") == true && sentence?.contains("browse_dialog") == true)
        #expect(AgentBrowserDriver.dialogBlocking("Element not found") == nil)
        guard case .failed(let classified) = AgentBrowserDriver.classify(raw) else { Issue.record("not a failure"); return }
        #expect(classified.contains("browse_dialog"))
    }

    @Test func pressTypesTextWithRealKeystrokesButNotIntoASecretField() async throws {
        setup.driver.state.withLock { $0.evaluation = #"{"tag":"input","type":"text","name":"q"}"# }
        let typed = try await run(BrowsePressTool(), ["text": .string("hello"), "insert": .bool(true)])
        #expect(typed.contains("Typed 5 characters"))
        #expect(setup.driver.calls.contains("command keyboard inserttext hello (text)"))
        setup.driver.state.withLock { $0.evaluation = #"{"tag":"input","type":"password","name":"pw"}"# }
        let refused = await message(BrowsePressTool(), ["text": .string("hunter2")])
        #expect(refused.lowercased().contains("password") || refused.contains("Typing is refused"))
        #expect(!setup.driver.calls.contains { $0.contains("hunter2") })
    }

    @Test func scrollCanBringAnElementIntoView() async throws {
        let text = try await run(BrowseScrollTool(), ["ref": .string("e1")])
        #expect(text.contains("e1") && setup.driver.calls.contains("command scrollintoview @e1"))
    }

    // MARK: Wait

    @Test func waitTakesExactlyOneConditionAndIsSafe() async throws {
        let wait = BrowseWaitTool()
        #expect(wait.risk(.object([:])) == .safe)
        _ = try await run(wait, ["text": .string("Done"), "timeout": .number(5_000)])
        _ = try await run(wait, ["url": .string("**/ok")])
        _ = try await run(wait, ["load": .string("networkidle")])
        _ = try await run(wait, ["ms": .number(300)])
        _ = try await run(wait, ["ref": .string("e1")])
        #expect(setup.driver.calls.filter { $0.hasPrefix("command") } == [
            "command wait --text Done --timeout 5000", "command wait --url **/ok --timeout 10000",
            "command wait --load networkidle --timeout 10000", "command wait 300", "command wait @e1 --timeout 10000",
        ])
        #expect(await message(wait, [:]).contains("exactly one"))
        #expect(await message(wait, ["text": .string("a"), "ms": .number(5)]).contains("exactly one"))
        #expect(await message(wait, ["text": .string("--evil")]).contains("cannot start"))
    }

    // MARK: Find

    @Test func findReadsByDefaultAndActsOnRequest() async throws {
        let find = BrowseFindTool()
        #expect(find.risk(.object(["by": .string("text"), "value": .string("x")])) == .safe)
        #expect(find.risk(.object(["by": .string("text"), "value": .string("x"), "do": .string("click")])) == .sensitive)
        setup.driver.state.withLock { $0.commandReply = .object(["text": .string("Aceito")]) }
        let read = try await run(find, ["by": .string("label"), "value": .string("Email")])
        #expect(read.contains("untrusted") && read.contains("Aceito"))
        _ = try await run(find, ["by": .string("role"), "value": .string("button"), "name": .string("Alvo"), "do": .string("click")])
        _ = try await run(find, ["by": .string("placeholder"), "value": .string("Nome"), "do": .string("fill"), "text": .string("Ana")])
        let calls = setup.driver.calls.filter { $0.hasPrefix("command") }
        #expect(calls.contains("command find label Email text"))
        #expect(calls.contains("command find role button click --name Alvo"))
        #expect(calls.contains("command find placeholder Nome fill Ana"))
    }

    @Test func findNeverFillsAPasswordOrAnOptionLookingValue() async {
        let password = await message(BrowseFindTool(), ["by": .string("label"), "value": .string("Senha"), "do": .string("fill"), "text": .string("x")])
        #expect(!password.isEmpty && !setup.driver.calls.contains { $0.hasPrefix("command find") })
        let option = await message(BrowseFindTool(), ["by": .string("text"), "value": .string("--headed")])
        #expect(option.contains("cannot start"))
        let unknown = await message(BrowseFindTool(), ["by": .string("css"), "value": .string("#a")])
        #expect(unknown.contains("`by` is one of"))
    }

    @Test func aNameThatIsNotARoleDoesNotHideAPasswordField() async {
        let label = await message(BrowseFindTool(), ["by": .string("label"), "value": .string("Senha"), "do": .string("fill"), "text": .string("x"), "name": .string("campo")])
        #expect(label.lowercased().contains("password"))
        let placeholder = await message(BrowseFindTool(), ["by": .string("placeholder"), "value": .string("Password"), "do": .string("fill"), "text": .string("x"), "name": .string("x")])
        #expect(placeholder.lowercased().contains("password"))
        #expect(!setup.driver.calls.contains { $0.hasPrefix("command find") })
    }

    @Test func findRefusesAFieldThatIsAPasswordByItsTypeEvenWhenTheLocatorSaysNothing() async {
        setup.driver.state.withLock { $0.evaluation = #"{"type":"password","autocomplete":"","label":"x"}"# }
        let text = await message(BrowseFindTool(), ["by": .string("placeholder"), "value": .string("Digite aqui"), "do": .string("fill"), "text": .string("segredo")])
        #expect(text.contains("Refused") && text.contains("browse_show"), "\(text)")
        #expect(!setup.driver.calls.contains("command find placeholder Digite aqui fill segredo"))
        setup.driver.state.withLock { $0.evaluation = #"{"type":"text","autocomplete":"","label":"Nome"}"# }
        _ = try? await run(BrowseFindTool(), ["by": .string("placeholder"), "value": .string("Digite aqui"), "do": .string("fill"), "text": .string("Ana")])
        #expect(setup.driver.calls.contains("command find placeholder Digite aqui fill Ana"))
    }

    // MARK: Dialog

    @Test func dialogSaysWhatIsOpenAndAnswersIt() async throws {
        let dialog = BrowseDialogTool()
        #expect(dialog.risk(.object([:])) == .safe && dialog.risk(.object(["action": .string("accept")])) == .sensitive)
        setup.driver.state.withLock { $0.commandReply = .object(["hasDialog": .bool(true), "type": .string("confirm"), "message": .string("ok?")]) }
        let status = try await run(dialog)
        #expect(status.contains("confirm") && status.contains("ok?") && status.contains("accept or dismiss"))
        setup.driver.state.withLock { $0.commandReply = .object(["hasDialog": .bool(false)]) }
        #expect(try await run(dialog).contains("No dialog is open"))
        _ = try await run(dialog, ["action": .string("accept"), "text": .string("Ana")])
        _ = try await run(dialog, ["action": .string("dismiss")])
        #expect(setup.driver.calls.contains("command dialog accept Ana (text)"))
        #expect(setup.driver.calls.contains("command dialog dismiss (text)"))
    }

    // MARK: Files

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "orb-browse-more-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func filesNeedTheTerminalCapabilityAndRefuseSecrets() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "hi".write(to: directory.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        var off = setup.context(directory: directory)
        off.canSaveFiles = false
        let blocked = await message(BrowseFilesTool(), ["action": .string("upload"), "ref": .string("e1"), "path": .string("a.txt")], context: off)
        #expect(blocked.contains("Terminal"))

        let context = setup.context(directory: directory)
        let text = try await run(BrowseFilesTool(), ["action": .string("upload"), "ref": .string("e1"), "path": .string("a.txt")], context: context)
        #expect(text.contains("Uploaded a.txt"))
        #expect(setup.driver.calls.contains("command upload @e1 \(directory.appending(path: "a.txt").resolvingLinkChain.path)"))

        let key = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/id_ed25519").path
        let tool = BrowseFilesTool()
        let arguments: JSONValue = .object(["action": .string("upload"), "ref": .string("e1"), "path": .string(key)])
        #expect(tool.danger(arguments, context: context) != nil)
        let missing = await message(tool, ["action": .string("upload"), "ref": .string("e1"), "path": .string("nope.txt")], context: context)
        #expect(missing.contains("is not a file"))
    }

    @Test func aDownloadNeedsTheFileToAppear() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = setup.context(directory: directory)
        let text = await message(BrowseFilesTool(), ["action": .string("download"), "ref": .string("e1"), "path": .string("out/oi.txt")], context: context)
        #expect(text.contains("did not hand over a new file"))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "out").path))
    }

    @Test func anOldFileIsNotADownloadNorAPDF() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = setup.context(directory: directory)
        try Data("velho".utf8).write(to: directory.appending(path: "old.bin"))
        let download = await message(BrowseFilesTool(), ["action": .string("download"), "ref": .string("e1"), "path": .string("old.bin")], context: context)
        #expect(download.contains("did not hand over a new file"))
        let pdf = await message(BrowsePageTool(), ["action": .string("pdf"), "path": .string("old.bin")], context: context)
        #expect(pdf.contains("no new file was written"))
    }

    // MARK: Page

    @Test func pageActionsAndTheirRisk() async throws {
        let page = BrowsePageTool()
        for action in ["frame", "state_save", "mouse_move", "mouse_wheel"] { #expect(page.risk(.object(["action": .string(action)])) == .safe, "\(action)") }
        for action in ["pdf", "state_load", "mouse_down", "mouse_up"] { #expect(page.risk(.object(["action": .string(action)])) == .sensitive, "\(action)") }
        _ = try await run(page, ["action": .string("frame"), "ref": .string("e4")])
        _ = try await run(page, ["action": .string("frame"), "ref": .string("main")])
        _ = try await run(page, ["action": .string("mouse_move"), "x": .number(10), "y": .number(20.4)])
        _ = try await run(page, ["action": .string("mouse_wheel"), "dy": .number(300)])
        _ = try await run(page, ["action": .string("mouse_down"), "button": .string("right")])
        let calls = setup.driver.calls.filter { $0.hasPrefix("command") }
        #expect(calls == ["command frame @e4", "command frame main", "command mouse move 10 20", "command mouse wheel 300", "command mouse down right"])
        #expect(await message(page, ["action": .string("mouse_move"), "x": .string("abc")]).contains("number"))
        #expect(await message(page, ["action": .string("mouse_down"), "button": .string("laser")]).contains("left, right or middle"))
        #expect(await message(page, ["action": .string("fly")]).contains("`action` is one of"))
    }

    @Test func savedStateLivesInTheOrbsOwnFolderUnderASafeName() async throws {
        let profiles = try folder()
        defer { try? FileManager.default.removeItem(at: profiles) }
        let local = FakeBrowserSetup(profiles: profiles)
        let page = BrowsePageTool()
        let saved = try await page.run(.object(["action": .string("state_save"), "name": .string("work")]), context: local.context())
        #expect(saved.contains("“work”"))
        let expected = profiles.appending(path: local.botID.uuidString).appending(path: "estado").appending(path: "work.json").path
        #expect(local.driver.calls.contains("command state save \(expected)"))
        let restored = await message(page, ["action": .string("state_load"), "name": .string("../evil")], context: local.context())
        #expect(restored.contains("up to 40 letters"))
        let none = await message(page, ["action": .string("state_load"), "name": .string("ghost")], context: local.context())
        #expect(none.contains("No saved state"))
    }

    @Test func pdfIsWrittenWhereTheRulesAllowOnly() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = setup.context(directory: directory)
        let text = await message(BrowsePageTool(), ["action": .string("pdf"), "path": .string("p.pdf")], context: context)
        #expect(text.contains("no new file was written"))
        let bad: JSONValue = .object(["action": .string("pdf"), "path": .string("~/.zshrc")])
        #expect(BrowsePageTool().danger(bad, context: context) != nil)
    }

    // MARK: Run

    @Test func runRefusesWhatWouldChangeTheBrowserItself() async {
        for words in [["connect", "9222"], ["open", "https://x.test"], ["close"], ["session", "list"], ["install"], ["dashboard"],
                      ["get", "title", "--cdp", "9222"], ["snapshot", "--profile=/tmp/x"], ["click", "@e1", "--headed"],
                      ["tab", "list", "--session", "other"], ["eval", "1", "--executable-path", "/bin/sh"], ["get", "title", "--args", "x"],
                      ["close", "--all"], ["mcp"], ["stream", "enable"], ["chat", "hi"], ["inspect"], ["plugin", "list"], ["upgrade"],
                      // An option in front would hide the command behind it; `batch` runs commands this check would not see.
                      ["--debug", "connect", "9222"], ["--json", "session"], ["batch", "connect 9222"], ["BATCH", "session list"],
                      ["CONNECT", "9222"], ["get", "url", "--SESSION", "x"], ["get", "title", "--namespace", "other"],
                      ["get", "title", "--pin-tab"], ["screenshot", "--screenshot-dir", "/tmp"], ["click", "@e1", "--download-path", "/tmp"],
                      ["get", "title", "--state", "/tmp/s.json"], ["get", "title", "--init-script", "/tmp/x.js"], ["cookies", "clear", "--ALL"],
                      ["tab"], ["tab", "list"], ["tab", "t2"], ["profiles"], ["clipboard", "read"], ["doctor", "--fix"],
                      ["state", "list"], ["state", "clean", "--older-than", "1"], ["state", "show", "x.json"], ["state"],
                      ["webmcp", "invoke", "tool", "--params", "@/etc/passwd"]] {
            let reason = BrowseRunRules.refusal(words)
            #expect(reason != nil, "\(words)")
            let text = await message(BrowseRunTool(), ["args": .array(words.map { .string($0) })])
            #expect(text == reason, "\(words)")
        }
        #expect(!setup.driver.calls.contains { $0.hasPrefix("command") })
    }

    @Test func runRiskIsSafeOnlyForWhatJustLooks() {
        let tool = BrowseRunTool()
        for words in [["get", "title"], ["is", "visible", "@e1"], ["snapshot", "-i"], ["cookies"], ["cookies", "get"],
                      ["console"], ["errors"], ["network", "requests"]] {
            #expect(tool.risk(.object(["args": .array(words.map { .string($0) })])) == .safe, "\(words)")
        }
        for words in [["cookies", "set", "a", "b"], ["eval", "alert(1)"], ["tab", "new"], ["storage", "local", "clear"], ["screenshot", "x.png"],
                      ["network", "route", "x"], ["click", "@e1"]] {
            #expect(tool.risk(.object(["args": .array(words.map { .string($0) })])) == .sensitive, "\(words)")
        }
        #expect(tool.risk(.object(["manual": .string("wait")])) == .safe)
        // A script for every page the browser opens from now on asks even in "Automático"; a script in this page is a sensitive call.
        let context = setup.context()
        #expect(tool.danger(.object(["args": .array([.string("addinitscript"), .string("1")])]), context: context) != nil)
        #expect(tool.danger(.object(["args": .array([.string("eval"), .string("1")])]), context: context) == nil)
        #expect(BrowseRunRules.refusal(["state", "save", "a.json"]) == nil && BrowseRunRules.refusal(["webmcp", "invoke", "t", "--params", "{}"]) == nil)
        #expect(tool.risk(.object(["args": .string("not a list")])) == .sensitive)
    }

    @Test func runSendsTheCommandAndMarksTheAnswerAsUntrusted() async throws {
        setup.driver.state.withLock { $0.commandReply = .object(["title": .string("Example")]) }
        let text = try await run(BrowseRunTool(), ["args": .array([.string("get"), .string("title")])])
        #expect(text.contains("untrusted") && text.contains("Example"))
        #expect(setup.driver.calls.last == "command get title")
        setup.driver.state.withLock { $0.commandReply = .null }
        #expect(try await run(BrowseRunTool(), ["args": .array([.string("scroll"), .string("down"), .number(300)])]).contains("Done."))
        #expect(setup.driver.calls.last == "command scroll down 300")
    }

    @Test func aHugeNumberInTheArgsIsTextNotACrash() {
        #expect(BrowseRunRules.words(.object(["args": .array([.string("scroll"), .number(1e30)])])) == ["scroll", "1e+30"])
        #expect(BrowseRunRules.words(.object(["args": .array([.number(300), .number(1.5), .number(-2)])])) == ["300", "1.5", "-2"])
        #expect(BrowseRunRules.words(.object(["args": .array([.number(.infinity)])])) == ["inf"])
    }

    @Test func runJudgesFilesLikeTheToolsThatTouchThem() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = setup.context(directory: directory)
        let tool = BrowseRunTool()
        #expect(BrowseRunRules.files(["screenshot", "--full", "shot.png"]).map(\.index) == [2])
        #expect(BrowseRunRules.files(["screenshot", "@e3", "out/shot.png"]).map(\.index) == [2])
        #expect(BrowseRunRules.files(["screenshot", "div.card"]).isEmpty && BrowseRunRules.files(["screenshot", "@e3"]).isEmpty)
        #expect(BrowseRunRules.files(["download", "@e1", "x.bin"]).first?.access == .write)
        #expect(BrowseRunRules.files(["upload", "@e1", "a.txt"]).first?.access == .read)
        #expect(BrowseRunRules.files(["get", "title"]).isEmpty)
        let key = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/id_ed25519").path
        #expect(tool.danger(.object(["args": .array([.string("upload"), .string("@e1"), .string(key)])]), context: context) != nil)
        #expect(tool.danger(.object(["args": .array([.string("screenshot"), .string("a.png")])]), context: context) == nil)
        var off = context
        off.canSaveFiles = false
        let blocked = await message(tool, ["args": .array([.string("pdf"), .string("a.pdf")])], context: off)
        #expect(blocked.contains("Terminal"))
        // The path the browser gets is the one in the Orb's folder, not the bare word.
        _ = try await run(tool, ["args": .array([.string("pdf"), .string("a.pdf")])], context: context)
        #expect(setup.driver.calls.last == "command pdf \(directory.appending(path: "a.pdf").resolvingLinkChain.path)")
    }

    // MARK: The manual

    @Test func theManualIsOnDemandAndLeavesOutWhatIsRefused() async throws {
        let text = try await run(BrowseRunTool(), ["manual": .string("")])
        #expect(text.contains("get title") && !text.contains("stream enable") && !text.contains("Snapshot Options"))
        #expect(text.contains("browse_run"))
        let topic = try await run(BrowseRunTool(), ["manual": .string("wait")])
        #expect(!topic.isEmpty)
        // Asking for `skills get core --full`, as the description promises, gives the same manual.
        let skills = try await run(BrowseRunTool(), ["args": .array([.string("skills"), .string("get"), .string("core"), .string("--full")])])
        #expect(skills.contains("get title"))
        #expect(setup.driver.calls.filter { $0.hasPrefix("manual") } == ["manual -", "manual wait", "manual -"])
        let neither = await message(BrowseRunTool(), [:])
        #expect(neither.contains("`args`"))
    }

    // MARK: Permission and offer

    @Test func theNewToolsActInsideThePagesSoTheyAskLikeTheOthers() {
        for name in ["browse_find", "browse_dialog", "browse_page", "browse_proxy"] {
            #expect(PermissionPolicy.family(ofTool: name, kind: .browser) == .browserPage, "\(name)")
        }
        // Any command (a script, a file) and a file handed to a site are not covered by "Clicar e preencher": each one asks.
        for name in ["browse_run", "browse_files"] {
            #expect(PermissionPolicy.family(ofTool: name, kind: .browser) == nil, "\(name)")
            let call = PermissionPolicy.call(for: name == "browse_run" ? BrowseRunTool() : BrowseFilesTool(),
                                             arguments: .object(["args": .array([.string("eval"), .string("1")]), "action": .string("upload"),
                                                                 "ref": .string("e1"), "path": .string("a.txt")]),
                                             context: setup.context())
            #expect(PermissionPolicy.suggestions(for: call).isEmpty, "\(name)")
        }
        #expect(PermissionPolicy.family(ofTool: "browse_wait", kind: .browser) == .web)
        #expect(ToolBox.browseToolNames.isSuperset(of: ["browse_wait", "browse_find", "browse_dialog", "browse_files", "browse_page", "browse_run"]))
    }
}
