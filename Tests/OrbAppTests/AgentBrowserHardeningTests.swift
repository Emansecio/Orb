import Foundation
import os
import Testing
@testable import Orb

// What the driver does so that a command never reaches a browser that is not the Orb's: no command but `open` starts one, a running
// session that was launched with other flags is not reused, nothing of the user's own agent-browser setup applies, and nothing
// a model writes becomes an option of the command line.

private func ok(_ data: String) -> String { "{\"success\":true,\"data\":\(data),\"error\":null}" }

/// A made-up command line: `sessions` is what `session list` says is running; every other command is answered by `reply` and
/// written down.
private final class FakeCommandLine: @unchecked Sendable {
    let sessions = OSAllocatedUnfairLock<[String]>(initialState: [])
    let log = OSAllocatedUnfairLock<[[String]]>(initialState: [])
    let reply: @Sendable ([String]) -> String

    init(sessions: [String] = [], reply: @escaping @Sendable ([String]) -> String = { _ in ok(#"{"url":"https://a.test/","title":"A"}"#) }) {
        self.sessions.withLock { $0 = sessions }
        self.reply = reply
    }

    var runner: BrowserCommandRunner {
        { [self] _, arguments, _, _ in
            log.withLock { $0.append(arguments) }
            if arguments.contains("close") { sessions.withLock { $0 = [] } }
            let answer = arguments.contains("session") && arguments.contains("list")
                ? ok("{\"sessions\":\(JSONValue.array(sessions.withLock { $0 }.map { .string($0) }).jsonString)}") : reply(arguments)
            return ProcessOutput(status: 0, signal: nil, output: answer, timedOut: false)
        }
    }

    /// The commands (the words after the flags) in the order they were sent.
    var commands: [[String]] {
        log.withLock { $0 }.map { arguments in
            var rest = arguments[...]
            while let first = rest.first, first.hasPrefix("--") {
                rest = rest.dropFirst(["--json", "--headed", "--allow-file-access"].contains(first) ? 1 : 2)
            }
            return Array(rest)
        }
    }

    var words: [String] { commands.compactMap(\.first) }
}

struct AgentBrowserSessionGuardTests {
    private func config(state: URL? = nil, profile: String = "/p", browser: BrowserProgram? = nil) -> AgentBrowserConfig {
        AgentBrowserConfig(executable: "/x/agent-browser", session: "orb-test-chrome", browser: browser,
                           profile: URL(fileURLWithPath: profile), stateDirectory: state)
    }

    private func stateFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbDriverState-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: Finding 1: nothing but `open` starts a browser

    @Test func noCommandButOpenIsSentToASessionWithNoBackgroundProcess() async throws {
        let line = FakeCommandLine(sessions: ["another-session"])
        let driver = AgentBrowserDriver(config: config(), environment: { nil }, run: line.runner)
        let attempts: [(String, () async throws -> Void)] = [
            ("snapshot", { _ = try await driver.snapshot(interactive: true, selector: nil) }),
            ("read", { _ = try await driver.read() }),
            ("click", { try await driver.click("e1") }),
            ("fill", { try await driver.fill("e1", text: "x") }),
            ("select", { try await driver.select("e1", value: "x") }),
            ("press", { try await driver.press("Enter") }),
            ("scroll", { try await driver.scroll(.down, pixels: 100) }),
            ("screenshot", { try await driver.screenshot(to: FileManager.default.temporaryDirectory.appending(path: "x-\(UUID().uuidString).png")) }),
            ("back", { _ = try await driver.back() }),
            ("tabs", { _ = try await driver.tabs() }),
            ("newTab", { try await driver.newTab("https://a.test/") }),
            ("selectTab", { try await driver.selectTab("t1") }),
            ("closeTab", { try await driver.closeTab(nil) }),
            ("attribute", { _ = try await driver.attribute("type", of: "e1") }),
            ("evaluate", { _ = try await driver.evaluate("1") }),
        ]
        for (name, attempt) in attempts {
            await #expect(throws: BrowserDriverError.noPage, "\(name)") { try await attempt() }
        }
        // The address of a page that is not there is nil, not an error, and not a command that would start a browser.
        #expect(try await driver.currentURL() == nil)
        #expect(Set(line.words) == ["session"], "only `session list` was sent, never a command a browser would start for: \(line.commands)")
    }

    @Test func afterTheBackgroundProcessDiesTheNextCommandSaysNoPageInsteadOfLaunchingTheDefaultBrowser() async throws {
        let line = FakeCommandLine(sessions: ["orb-test-chrome"])
        let driver = AgentBrowserDriver(config: config(), environment: { nil }, run: line.runner)
        _ = try await driver.open("https://a.test/")
        _ = try await driver.read()
        // Half an hour idle, `browse_close` from another process, a mode change in the middle of a Claude Code turn…
        line.sessions.withLock { $0 = [] }
        try await Task.sleep(for: AgentBrowserDriver.aliveWindow + .milliseconds(200))
        await #expect(throws: BrowserDriverError.noPage) { _ = try await driver.read() }
        await #expect(throws: BrowserDriverError.noPage) { _ = try await driver.snapshot(interactive: true, selector: nil) }
        #expect(line.words.filter { $0 == "read" }.count == 1, "the second read never left")
        // Opening again launches with the full flags of the Orb.
        _ = try await driver.open("https://b.test/")
        let open = try #require(line.log.withLock { $0.last })
        #expect(open.contains("--args") && open.contains("--profile") && open.suffix(2) == ["open", "https://b.test/"])
    }

    @Test func aCommandThatStartedABrowserOfItsOwnClosesItAndSaysNoPage() async throws {
        // The process went between the check and the command: the reply says the command launched a browser.
        let line = FakeCommandLine(sessions: ["orb-test-chrome"]) { arguments in
            arguments.contains("snapshot")
                ? ok(#"{"snapshot":"","origin":"about:blank","refs":{},"lifecycle":{"launched":true,"reused":false}}"#) : ok(#"{"closed":true}"#)
        }
        let driver = AgentBrowserDriver(config: config(), environment: { nil }, run: line.runner)
        await #expect(throws: BrowserDriverError.noPage) { _ = try await driver.snapshot(interactive: true, selector: nil) }
        #expect(line.words == ["session", "snapshot", "close"], "\(line.commands)")
        // And it stays closed: the next command is not sent either.
        await #expect(throws: BrowserDriverError.noPage) { _ = try await driver.read() }
        #expect(!line.words.contains("read"))
    }

    @Test func commandsInARowAskForTheSessionOnce() async throws {
        let line = FakeCommandLine(sessions: ["orb-test-chrome"])
        let driver = AgentBrowserDriver(config: config(), environment: { nil }, run: line.runner)
        _ = try await driver.open("https://a.test/")
        for _ in 0..<5 { try await driver.scroll(.down, pixels: 10) }
        #expect(line.words.filter { $0 == "session" }.isEmpty, "a browser that just answered is there: \(line.words)")
    }

    // MARK: Finding 1 (second half): a running session with other flags is not reused

    @Test func aRunningSessionLaunchedWithOtherFlagsIsClosedBeforeTheOrbsPageOpens() async throws {
        let state = stateFolder()
        defer { try? FileManager.default.removeItem(at: state) }
        let line = FakeCommandLine(sessions: [])
        let first = AgentBrowserDriver(config: config(state: state), environment: { nil }, run: line.runner)
        _ = try await first.open("https://a.test/")
        #expect(line.words == ["session", "open"], "nothing running: it just opens (after asking)")
        #expect(first.config.recordedFingerprint() == first.config.launchFingerprint)

        // Another process (the tools server of a Claude Code turn) meets the same session with the same flags: it is reused.
        line.sessions.withLock { $0 = ["orb-test-chrome"] }
        line.log.withLock { $0 = [] }
        let same = AgentBrowserDriver(config: config(state: state), environment: { nil }, run: line.runner)
        _ = try await same.open("https://b.test/")
        #expect(line.words == ["session", "open"], "\(line.commands)")

        // The Orb's profile is somewhere else now (or the program changed): the running browser is the wrong one.
        line.log.withLock { $0 = [] }
        let moved = AgentBrowserDriver(config: config(state: state, profile: "/elsewhere"), environment: { nil }, run: line.runner)
        _ = try await moved.open("https://c.test/")
        let words = line.words
        let close = try #require(words.firstIndex(of: "close"), "\(line.commands)")
        let open = try #require(words.firstIndex(of: "open"))
        #expect(close < open, "closed first, then opened with the new profile: \(line.commands)")
        #expect(try #require(line.log.withLock { $0.last }).contains("/elsewhere"))
        #expect(moved.config.recordedFingerprint() == moved.config.launchFingerprint)
    }

    @Test func aRunningSessionNobodyWroteDownIsNotTrustedEither() async throws {
        let state = stateFolder()
        defer { try? FileManager.default.removeItem(at: state) }
        // (Left by an older version of the app, which wrote nothing down.)
        let line = FakeCommandLine(sessions: ["orb-test-chrome"])
        let driver = AgentBrowserDriver(config: config(state: state), environment: { nil }, run: line.runner)
        _ = try await driver.open("https://a.test/")
        #expect(line.words.contains("close"), "\(line.commands)")
        #expect(try #require(line.words.firstIndex(of: "close")) < (try #require(line.words.firstIndex(of: "open"))))
        // Without the app's folder there is nothing to compare, and a running session is used as it is.
        let bare = FakeCommandLine(sessions: ["orb-test-chrome"])
        _ = try await AgentBrowserDriver(config: config(), environment: { nil }, run: bare.runner).open("https://a.test/")
        #expect(bare.words == ["open"])
    }

    @Test func showingTheWindowDoesNotMakeTheLaunchDifferent() {
        var shown = config(state: URL(fileURLWithPath: "/s"))
        let hidden = shown.launchFingerprint
        shown.headed = true
        #expect(shown.launchFingerprint == hidden, "an `open` must not close the window the person is using")
        var other = shown
        other.browser = BrowserProgram(kind: .brave, executable: "/another/chrome", major: nil)
        #expect(other.launchFingerprint != hidden)
    }

    // MARK: Finding 10: nothing of the user's agent-browser setup applies

    @Test func theCommandsRunWithTheAppsOwnConfigAndFolder() async throws {
        let state = stateFolder()
        defer { try? FileManager.default.removeItem(at: state) }
        let line = FakeCommandLine(sessions: ["orb-test-chrome"])
        let driver = AgentBrowserDriver(config: config(state: state), environment: { nil }, run: line.runner)
        _ = try await driver.open("https://a.test/")
        let arguments = try #require(line.log.withLock { $0.first })
        #expect(arguments.starts(with: ["--session", "orb-test-chrome", "--json", "--config", state.appending(path: "agent-browser.json").path]))
        #expect(try String(contentsOf: state.appending(path: "agent-browser.json"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
        #expect(config(state: state).workingDirectory == state)
        #expect(!config().workingDirectory.path.hasPrefix(NSHomeDirectory()), "never the home folder, where `agent-browser.json` would be read")
    }

    @Test func theLoginShellsAgentBrowserSettingsAreStrippedAndProxiesKept() {
        let shell = ["PATH": "/usr/bin", "AGENT_BROWSER_PROFILE": "/Users/me/Chrome", "AGENT_BROWSER_EXECUTABLE_PATH": "/Applications/Brave",
                     "agent_browser_args": "--no-sandbox", "AGENT_BROWSER_CONFIG": "/Users/me/ab.json",
                     "HTTPS_PROXY": "http://proxy:3128", "NO_PROXY": "localhost", "HOME": "/Users/me"]
        let cleaned = AgentBrowserConfig.sanitized(shell)
        #expect(Set(cleaned.keys) == ["PATH", "HTTPS_PROXY", "NO_PROXY", "HOME"])
        let environment = config().environment(base: shell)
        #expect(environment["AGENT_BROWSER_PROFILE"] == nil && environment["AGENT_BROWSER_CONFIG"] == nil)
        #expect(environment["AGENT_BROWSER_IDLE_TIMEOUT_MS"] == "1800000", "what the app sets stays")
        #expect(environment["HTTPS_PROXY"] == "http://proxy:3128")
    }

    @Test func theRealProcessRunsInTheAppsFolderWithoutTheUsersAgentBrowserVariables() async throws {
        let state = stateFolder()
        defer { try? FileManager.default.removeItem(at: state) }
        let script = state.appending(path: "agent-browser")
        let log = state.appending(path: "seen.txt")
        try """
        #!/bin/sh
        { pwd -P; env | grep -E '^(AGENT_BROWSER_|ORB_|HTTPS_PROXY)' | sort; echo "args: $*"; } >> '\(log.path)'
        case "$*" in
          *"session list"*) echo '{"success":true,"data":{"sessions":[]},"error":null}' ;;
          *) echo '{"success":true,"data":{"url":"https://a.test/","title":"A"},"error":null}' ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try script.makeExecutable()
        let shell = ["PATH": "/usr/bin:/bin", "AGENT_BROWSER_PROFILE": "/Users/me/Chrome", "HTTPS_PROXY": "http://proxy:3128"]
        let configuration = AgentBrowserConfig(executable: script.path, session: "orb-real", stateDirectory: state)
        let driver = AgentBrowserDriver(config: configuration, environment: { shell })
        _ = try await driver.open("https://a.test/")
        _ = try await driver.read()
        let seen = try String(contentsOf: log, encoding: .utf8)
        #expect(seen.contains(state.resolvingSymlinksInPath().path), "ran in the app's folder: \(seen)")
        #expect(!seen.contains("AGENT_BROWSER_PROFILE"), "\(seen)")
        #expect(seen.contains("AGENT_BROWSER_IDLE_TIMEOUT_MS=1800000") && seen.contains("HTTPS_PROXY=http://proxy:3128"))
        #expect(seen.contains("--config \(state.appending(path: "agent-browser.json").path)"))
    }

    // MARK: Finding 9: nothing a model writes becomes an option

    @Test func aSelectorOrATabIdThatLooksLikeAnOptionNeverReachesTheCommandLine() async throws {
        let line = FakeCommandLine(sessions: ["orb-test-chrome"]) { _ in ok(#"{"snapshot":"","origin":"","refs":{},"tabs":[]}"#) }
        let driver = AgentBrowserDriver(config: config(), environment: { nil }, run: line.runner)
        for selector in ["--json", "-x", " --headed", "--config=/etc/passwd"] {
            await #expect(throws: BrowserDriverError.self, "\(selector)") { _ = try await driver.snapshot(interactive: true, selector: selector) }
        }
        for tab in ["--json", "-1", "t1 --headed", "docs", "", "t", "../1"] {
            await #expect(throws: BrowserDriverError.self, "\(tab)") { try await driver.selectTab(tab) }
            await #expect(throws: BrowserDriverError.self, "\(tab)") { try await driver.closeTab(tab) }
        }
        #expect(line.words.isEmpty || line.words == ["session"], "nothing was sent: \(line.commands)")
        // What is meant still works.
        _ = try await driver.snapshot(interactive: true, selector: "main > #content")
        try await driver.selectTab("t2")
        try await driver.selectTab("3")
        try await driver.closeTab("t4")
        let sent = line.commands
        #expect(sent.contains(["snapshot", "--interactive", "--urls", "--compact", "--selector", "main > #content"]))
        #expect(sent.contains(["tab", "t2"]) && sent.contains(["tab", "3"]) && sent.contains(["tab", "close", "t4"]))
        #expect(AgentBrowserDriver.isTabID("t12") && AgentBrowserDriver.isTabID("7") && !AgentBrowserDriver.isTabID("-7") && !AgentBrowserDriver.isTabID("t1\n"))
    }

    // MARK: One launcher

    @Test func twoCallersAtTheSameTimeEndWithTheSameWholeLauncher() throws {
        for _ in 0..<5 {
            let state = stateFolder()
            defer { try? FileManager.default.removeItem(at: state) }
            let program = BrowserProgram(kind: .chrome, executable: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", major: 155)
            let config = config(state: state, browser: program)
            DispatchQueue.concurrentPerform(iterations: 24) { _ in config.prepareState() }
            let launcher = try #require(config.launcherURL)
            #expect(try String(contentsOf: launcher, encoding: .utf8) == config.launcherScript)
            #expect(FileManager.default.isExecutableFile(atPath: launcher.path))
            let folder = launcher.deletingLastPathComponent().path
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.filter { $0 != launcher.lastPathComponent } ?? []
            #expect(leftovers.isEmpty, "no drafts left behind: \(leftovers)")
        }
    }

    @Test func theHubStartsOneSessionForTwoToolsThatAskAtTheSameTime() async throws {
        let configs = OSAllocatedUnfairLock<Int>(initialState: 0)
        let hub = BrowserHub(profilesDirectory: nil, locate: {
            try? await Task.sleep(for: .milliseconds(30)) // the lookup is where the second caller catches up
            return BrowserStatus(agentBrowser: "/fake/agent-browser", program: BrowserProgram(kind: .chrome, executable: "/fake/chrome", major: 155))
        }, makeDriver: { _ in
            configs.withLock { $0 += 1 }
            return FakeBrowserDriver()
        })
        let botID = UUID()
        let sessions = try await withThrowingTaskGroup(of: BrowserSession.self) { group in
            for _ in 0..<12 { group.addTask { try await hub.session(botID: botID, mode: .background) } }
            var all: [BrowserSession] = []
            for try await session in group { all.append(session) }
            return all
        }
        #expect(sessions.allSatisfy { $0 === sessions[0] }, "one session for the Orb, so one lock for its commands")
        #expect(configs.withLock { $0 } == 1)
    }
}
