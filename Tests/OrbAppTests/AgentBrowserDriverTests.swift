import Foundation
import os
import Testing
@testable import Orb

/// A stand-in for the `agent-browser` command line: a script that writes down its arguments and answers the way the real
/// one does with `--json` (one JSON object per command; a note on the error stream first).
private enum FakeAgentBrowser {
    static let script = #"""
    #!/usr/bin/env python3
    import json, os, sys
    args = sys.argv[1:]
    with open(os.environ["FAKE_AB_LOG"], "a") as log:
        log.write(json.dumps(args) + "\n")
    VALUE_FLAGS = {"--session", "--profile", "--engine", "--executable-path", "--args", "--config"}
    rest, i, session = [], 0, ""
    while i < len(args):
        if args[i] == "--session": session = args[i + 1]
        if args[i] in VALUE_FLAGS: i += 2; continue
        if args[i].startswith("--"): i += 1; continue
        rest.append(args[i]); i += 1
    cmd = rest[0] if rest else ""
    def ok(data): print(json.dumps({"success": True, "data": data, "error": None}))
    def fail(message): print(json.dumps({"success": False, "data": None, "error": message}))
    print("Warning: a note on the stream that is not JSON", file=sys.stderr, flush=True)
    mode = os.environ.get("FAKE_AB_MODE", "")
    # The driver asks which sessions run before any command that is not `open`: this one always has its own.
    if cmd == "session" and mode not in ("silent",): ok({"sessions": [session]}); sys.exit(0)
    if mode == "silent": sys.exit(3)
    if mode == "hang": import time; time.sleep(30)
    if mode == "unlaunched" and cmd != "open": fail("Browser not launched"); sys.exit(1)
    if mode == "nochrome": fail("Chrome not found. Run `agent-browser install` to download it."); sys.exit(1)
    if cmd == "open": ok({"url": rest[1] if len(rest) > 1 else "about:blank", "title": "Fake page"})
    elif cmd == "snapshot": ok({"snapshot": '- button "Go" [ref=e1]\n- textbox "Email" [ref=e2]', "origin": "https://fake.test/",
                                "refs": {"e1": {"role": "button", "name": "Go"}, "e2": {"role": "textbox", "name": "Email"}}, "removedRefs": []})
    elif cmd == "read": ok({"url": "https://fake.test/", "finalUrl": "https://fake.test/", "source": "active-tab-html", "content": "# Fake\nText"})
    elif cmd == "get" and rest[1] == "url": ok({"url": "https://fake.test/"})
    elif cmd == "get" and rest[1] == "title": ok({"title": "Fake page"})
    elif cmd == "get" and rest[1] == "attr": ok({"value": "password" if rest[2] == "@e2" and rest[3] == "type" else None})
    elif cmd == "tab" and len(rest) == 1: ok({"tabs": [{"tabId": "t1", "label": None, "title": "Fake", "url": "https://fake.test/", "active": True},
                                                       {"tabId": "t2", "label": "docs", "title": "", "url": "about:blank", "active": False}]})
    elif cmd == "eval": ok({"result": "<html>x</html>", "origin": "https://fake.test/"})
    elif cmd == "screenshot": open(rest[1], "wb").write(b"png"); ok({"path": rest[1]})
    elif cmd == "back": ok({"url": "https://fake.test/back"})
    elif cmd == "close": ok({"closed": True})
    else: ok({})
    """#

    /// The script as an executable file in a folder of its own.
    static func install() throws -> (executable: URL, log: URL, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbFakeAgentBrowser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appending(path: "agent-browser")
        try script.trimmingCharacters(in: .whitespaces).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (executable, folder.appending(path: "log.jsonl"), folder)
    }

    static func commands(in log: URL) -> [[String]] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
            (JSONValue.parse(String(line))?.array)?.compactMap(\.string)
        }
    }
}

private func abOK(_ data: String) -> String { "{\"success\":true,\"data\":\(data),\"error\":null}" }

struct AgentBrowserReplyTests {
    @Test func theReplyIsTheLastJSONLineOfTheOutput() throws {
        let output = "Warning: Chrome cache directory exists\n{\"success\":true,\"data\":{\"url\":\"https://a.test/\"},\"error\":null}\n"
        let reply = try #require(AgentBrowserReply.parse(output))
        #expect(reply.success && reply.data?["url"] == .string("https://a.test/") && reply.error == nil)

        let failed = try #require(AgentBrowserReply.parse("{\"success\":false,\"data\":null,\"error\":\"Browser not launched\"}"))
        #expect(!failed.success && failed.error == "Browser not launched")

        #expect(AgentBrowserReply.parse("") == nil)
        #expect(AgentBrowserReply.parse("not json at all\n{broken") == nil)
        // An object without "success" is not a reply (a page's own JSON in a note, say).
        #expect(AgentBrowserReply.parse("{\"hello\":1}") == nil)
    }

    @Test func errorsAreToldApart() {
        #expect(AgentBrowserDriver.classify("Browser not launched") == .noPage)
        if case .notInstalled(let message) = AgentBrowserDriver.classify("Chrome not found. Run agent-browser install") {
            #expect(message.contains("agent-browser install"))
        } else {
            Issue.record("a missing Chrome is a missing install")
        }
        #expect(AgentBrowserDriver.classify("Element @e9 not found") == .failed("Element @e9 not found"))
    }
}

/// The driver against a fake command line: the arguments it builds, and how it reads the replies.
struct AgentBrowserDriverTests {
    private func recorder(_ reply: @escaping @Sendable ([String]) -> String) -> (run: BrowserCommandRunner, calls: OSAllocatedUnfairLock<[[String]]>) {
        let calls = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        let run: BrowserCommandRunner = { _, arguments, _, _ in
            calls.withLock { $0.append(arguments) }
            return ProcessOutput(status: 0, signal: nil, output: reply(arguments), timedOut: false)
        }
        return (run, calls)
    }

    private func make(_ engine: BrowserEngineKind = .chrome, headed: Bool = false, listsSession: Bool = true, reply: @escaping @Sendable ([String]) -> String)
        -> (driver: AgentBrowserDriver, calls: OSAllocatedUnfairLock<[[String]]>) {
        let name = "orb-test-\(engine.rawValue)"
        // The session is running, as far as `session list` goes (the driver asks before any command but `open`).
        let (run, calls) = recorder { arguments in
            listsSession && arguments.contains("session") && arguments.contains("list") ? abOK("{\"sessions\":[\"\(name)\"]}") : reply(arguments)
        }
        let config = AgentBrowserConfig(executable: "/x/agent-browser", session: "orb-test-\(engine.rawValue)", engine: engine,
                                        browserExecutable: engine == .chrome ? nil : "/bin/\(engine.rawValue)",
                                        profile: engine.keepsProfile ? URL(fileURLWithPath: "/p") : nil, headed: headed, cloakSeed: 20_000)
        return (AgentBrowserDriver(config: config, environment: { nil }, run: run), calls)
    }


    @Test func openCarriesTheLaunchFlagsAndOtherCommandsDoNot() async throws {
        let (driver, calls) = make { _ in abOK(#"{"url":"https://a.test/","title":"A","clicked":"@e1"}"#) }
        let page = try await driver.open("https://a.test/")
        #expect(page == BrowserPage(url: "https://a.test/", title: "A"))
        try await driver.click("e1")
        let all = calls.withLock { $0 }
        #expect(all[0] == ["--session", "orb-test-chrome", "--json", "--args", "--disable-blink-features=AutomationControlled", "--profile", "/p", "open", "https://a.test/"])
        #expect(all[1] == ["--session", "orb-test-chrome", "--json", "click", "@e1"])
    }

    @Test func theEnginesLaunchWithTheirOwnFlags() async throws {
        for engine in [BrowserEngineKind.obscura, .cloak] {
            let (driver, calls) = make(engine) { _ in abOK(#"{"url":"https://a.test/","title":"A"}"#) }
            _ = try await driver.open("https://a.test/")
            let arguments = try #require(calls.withLock { $0.first })
            #expect(arguments.starts(with: ["--session", "orb-test-\(engine.rawValue)", "--json"]))
            #expect(arguments.contains("--executable-path") && arguments.contains("/bin/\(engine.rawValue)"))
            #expect(arguments.suffix(2) == ["open", "https://a.test/"])
            #expect(arguments.contains("--engine") == (engine == .obscura))
            #expect(arguments.contains("--args") == (engine == .cloak))
        }
    }

    @Test func everyCommandBuildsTheArgumentsOfTheCommandLine() async throws {
        let (driver, calls) = make { arguments in
            if arguments.contains("snapshot") { return abOK(#"{"snapshot":"- link \"x\" [ref=e1]","origin":"https://a.test/","refs":{"e1":{"role":"link","name":"x"}}}"#) }
            if arguments.contains("tab") && arguments.count == 4 { return abOK(#"{"tabs":[]}"#) }
            if arguments.contains("session") { return abOK(#"{"sessions":["orb-test-chrome"]}"#) }
            return abOK(#"{"title":"T","url":"https://a.test/","value":"password","result":"r","content":"c"}"#)
        }
        _ = try await driver.snapshot(interactive: true, selector: nil)
        _ = try await driver.snapshot(interactive: false, selector: "#main")
        try await driver.fill("e2", text: "olá mundo")
        try await driver.select("e3", value: "BR")
        try await driver.press("Control+a")
        try await driver.scroll(.down, pixels: 600)
        _ = try await driver.read()
        _ = try await driver.back()
        _ = try await driver.tabs()
        try await driver.newTab("https://b.test/")
        try await driver.selectTab("t2")
        try await driver.closeTab("t2")
        try await driver.closeTab(nil)
        _ = try await driver.attribute("type", of: "e2")
        _ = try await driver.evaluate("1+1")
        _ = try await driver.currentURL()
        let commands = calls.withLock { $0.map { Array($0.dropFirst(3)) } }
        #expect(commands.contains(["snapshot", "--interactive", "--urls", "--compact"]))
        #expect(commands.contains(["snapshot", "--compact", "--selector", "#main"]))
        #expect(commands.contains(["fill", "@e2", "olá mundo"]))
        #expect(commands.contains(["select", "@e3", "BR"]))
        #expect(commands.contains(["press", "Control+a"]))
        #expect(commands.contains(["scroll", "down", "600"]))
        #expect(commands.contains(["read"]) && commands.contains(["back"]) && commands.contains(["tab"]))
        #expect(commands.contains(["tab", "new", "https://b.test/"]))
        #expect(commands.contains(["tab", "t2"]) && commands.contains(["tab", "close", "t2"]) && commands.contains(["tab", "close"]))
        #expect(commands.contains(["get", "attr", "@e2", "type"]))
        #expect(commands.contains(["eval", "1+1"]) && commands.contains(["get", "url"]))
    }

    @Test func snapshotsTabsAndReadsAreParsed() async throws {
        let (driver, _) = make { arguments in
            if arguments.contains("snapshot") {
                return abOK(#"{"snapshot":"- button \"Go\" [ref=e1]\n- textbox \"Senha\" [ref=e2]","origin":"https://a.test/x","refs":{"e1":{"role":"button","name":"Go"},"e2":{"role":"textbox","name":"Senha"}},"removedRefs":["@e9"]}"#)
            }
            if arguments.contains("tab") {
                return abOK(#"{"tabs":[{"tabId":"t1","label":null,"title":"Um","url":"https://a.test/","active":true},{"tabId":"t2","label":"docs","title":"Dois","url":"https://b.test/","active":false}]}"#)
            }
            return abOK(##"{"url":"https://a.test/","finalUrl":"https://a.test/final","content":"# Título\nTexto","result":{"a":1}}"##)
        }
        let snapshot = try await driver.snapshot(interactive: true, selector: nil)
        #expect(snapshot.url == "https://a.test/x" && snapshot.tree.contains("[ref=e2]"))
        #expect(snapshot.refs == ["e1": BrowserRef(role: "button", name: "Go"), "e2": BrowserRef(role: "textbox", name: "Senha")])
        let tabs = try await driver.tabs()
        #expect(tabs == [BrowserTab(id: "t1", title: "Um", url: "https://a.test/", isActive: true),
                         BrowserTab(id: "t2", title: "Dois", url: "https://b.test/", isActive: false)])
        let page = try await driver.read()
        #expect(page == BrowserReadout(url: "https://a.test/final", content: "# Título\nTexto"))
        // A script's result that is not text comes back as JSON.
        #expect(try await driver.evaluate("x") == #"{"a":1}"#)
    }

    @Test func aWindowIsAReopenOfTheSamePageWithTheSameProfile() async throws {
        let lists = OSAllocatedUnfairLock(initialState: 0)
        let (driver, calls) = make(listsSession: false) { arguments in
            // The session is there when asked first, and gone when the driver waits for the close to finish.
            if arguments.contains("session") { return lists.withLock { $0 += 1; return $0 } == 1 ? abOK(#"{"sessions":["orb-test-chrome"]}"#) : abOK(#"{"sessions":[]}"#) }
            return arguments.contains("url") ? abOK(#"{"url":"https://a.test/login"}"#) : abOK(#"{"url":"https://a.test/login","title":"Entrar","closed":true}"#)
        }
        let page = try await driver.setHeaded(true)
        #expect(page.url == "https://a.test/login")
        #expect(driver.config.headed)
        let commands = calls.withLock { $0.map { Array($0.dropFirst(3)) } }
        #expect(commands == [["session", "list"], ["get", "url"], ["close"], ["session", "list"],
                             ["--args", "--disable-blink-features=AutomationControlled", "--profile", "/p", "--headed", "open", "https://a.test/login"]])
        _ = try await driver.setHeaded(false)
        #expect(!driver.config.headed)
        try await driver.close()
        #expect(!driver.config.headed)
    }

    @Test func errorsAreThrownAsWhatTheyAre() async throws {
        let (driver, _) = make { _ in #"{"success":false,"data":null,"error":"Browser not launched"}"# }
        await #expect(throws: BrowserDriverError.noPage) { _ = try await driver.snapshot(interactive: true, selector: nil) }
        #expect(try await driver.currentURL() == nil)
        try await driver.close() // already closed is not a failure

        let (broken, _) = make { _ in "\u{1B}[31msegmentation fault" }
        await #expect(throws: BrowserDriverError.self) { try await broken.click("e1") }
    }

    // MARK: The real process

    @Test(.enabled(if: hasPython)) func theCommandLineIsRunForRealAndItsNoiseIgnored() async throws {
        let fake = try FakeAgentBrowser.install()
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let base = ProcessInfo.processInfo.environment
        let config = AgentBrowserConfig(executable: fake.executable.path, session: "orb-real", engine: .chrome, profile: URL(fileURLWithPath: "/p"))
        let driver = AgentBrowserDriver(config: config, environment: { base.merging(["FAKE_AB_LOG": fake.log.path]) { $1 } })

        let page = try await driver.open("https://fake.test/start")
        #expect(page == BrowserPage(url: "https://fake.test/start", title: "Fake page"))
        let snapshot = try await driver.snapshot(interactive: true, selector: nil)
        #expect(snapshot.refs["e2"] == BrowserRef(role: "textbox", name: "Email"))
        #expect(try await driver.attribute("type", of: "e2") == "password")
        #expect(try await driver.attribute("type", of: "e1") == nil)
        #expect(try await driver.read().content == "# Fake\nText")
        #expect(try await driver.tabs().map(\.id) == ["t1", "t2"])
        let shot = fake.folder.appending(path: "shots/page.png")
        try await driver.screenshot(to: shot)
        #expect(FileManager.default.fileExists(atPath: shot.path))
        try await driver.close()

        let logged = FakeAgentBrowser.commands(in: fake.log)
        #expect(logged.first == ["--session", "orb-real", "--json", "--args", "--disable-blink-features=AutomationControlled",
                                 "--profile", "/p", "open", "https://fake.test/start"])
        #expect(logged.last == ["--session", "orb-real", "--json", "close"])
    }

    @Test(.enabled(if: hasPython)) func theRealProcessFailuresAreTold() async throws {
        let fake = try FakeAgentBrowser.install()
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        func driver(mode: String) -> AgentBrowserDriver {
            let base = ProcessInfo.processInfo.environment
            return AgentBrowserDriver(config: AgentBrowserConfig(executable: fake.executable.path, session: "orb-real", engine: .chrome),
                                      environment: { base.merging(["FAKE_AB_LOG": fake.log.path, "FAKE_AB_MODE": mode]) { $1 } })
        }
        await #expect(throws: BrowserDriverError.noPage) { _ = try await driver(mode: "unlaunched").snapshot(interactive: true, selector: nil) }
        await #expect(throws: BrowserDriverError.self) { _ = try await driver(mode: "silent").read() }
        do {
            _ = try await driver(mode: "nochrome").open("https://a.test/")
            Issue.record("a missing Chrome must not look like a page")
        } catch BrowserDriverError.notInstalled(let message) {
            #expect(message.contains("agent-browser install"))
        }
        // An executable that is not there.
        let missing = AgentBrowserDriver(config: AgentBrowserConfig(executable: "/nonexistent/agent-browser", session: "s", engine: .chrome),
                                         environment: { nil })
        do {
            _ = try await missing.open("https://a.test/")
            Issue.record("a missing command must fail")
        } catch BrowserDriverError.notInstalled {
        }
    }

    @Test(.enabled(if: hasPython)) func aCommandThatNeverAnswersIsGivenUpOn() async throws {
        let fake = try FakeAgentBrowser.install()
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let base = ProcessInfo.processInfo.environment
        let run: BrowserCommandRunner = { executable, arguments, environment, _ in
            // (Only the command that hangs is given the short time: the question whether the session runs is answered at once, but
            // a machine under load can take longer than that to start a script.)
            try await ProcessRunner.run(executable, arguments, environment: environment, timeout: arguments.contains("session") && arguments.contains("list") ? .seconds(20) : .milliseconds(400))
        }
        let driver = AgentBrowserDriver(config: AgentBrowserConfig(executable: fake.executable.path, session: "s", engine: .chrome),
                                        environment: { base.merging(["FAKE_AB_LOG": fake.log.path, "FAKE_AB_MODE": "hang"]) { $1 } }, run: run)
        await #expect(throws: BrowserDriverError.timedOut("read")) { _ = try await driver.read() }
    }
}
