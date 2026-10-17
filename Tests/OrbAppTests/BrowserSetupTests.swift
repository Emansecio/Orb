import Foundation
import os
import Testing
@testable import Orb

/// What the driver learned from running against the real browsers, and the settings model of Ajustes → Navegador.
struct BrowserDriverRealityTests {
    private func make(listsSession: Bool = true, reply: @escaping @Sendable ([String]) -> String)
        -> (driver: AgentBrowserDriver, calls: OSAllocatedUnfairLock<[[String]]>) {
        let calls = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        let name = "orb-test-chrome"
        let run: BrowserCommandRunner = { _, arguments, _, _ in
            calls.withLock { $0.append(arguments) }
            // The session is running, as far as `session list` goes (the driver asks before any command but `open`).
            let answer = listsSession && arguments.contains("session") && arguments.contains("list")
                ? "{\"success\":true,\"data\":{\"sessions\":[\"\(name)\"]},\"error\":null}" : reply(arguments)
            return ProcessOutput(status: 0, signal: nil, output: answer, timedOut: false)
        }
        let config = AgentBrowserConfig(executable: "/x/agent-browser", session: name)
        return (AgentBrowserDriver(config: config, environment: { nil }, run: run), calls)
    }

    private func ok(_ data: String) -> String { "{\"success\":true,\"data\":\(data),\"error\":null}" }

    // The command line takes an argument that is exactly one of its options for the option.

    @Test func textThatLooksLikeAnOptionGoesThroughBatchQuoted() async throws {
        let (driver, calls) = make { _ in "[{\"command\":[\"fill\"],\"error\":null,\"result\":{\"filled\":\"@e1\"},\"success\":true}]" }
        try await driver.fill("e1", text: "--json")
        try await driver.fill("e1", text: "-it's x")
        try await driver.fill("e1", text: "olá")
        // (Without the `session list` the driver asks first.)
        let commands = calls.withLock { $0.map { Array($0.dropFirst(3)) }.filter { $0.first != "session" } }
        #expect(commands[0] == ["batch", "'fill' '@e1' '--json'"])
        #expect(commands[1] == ["batch", "'fill' '@e1' '-it'\\''s x'"], "an apostrophe is closed, escaped and opened again")
        #expect(commands[2] == ["fill", "@e1", "olá"], "ordinary text does not need it")
        #expect(AgentBrowserDriver.shellLine(["a b", "$HOME", "`x`"]) == "'a b' '$HOME' '`x`'")
    }

    /// The quoting above only matters if the real `batch` reads it back as the words that were meant. Asks the real command line
    /// (no browser starts: the `fill` fails on an element that is not there, and its reply still says how the command was read).
    @Test(.enabled(if: !RealBrowsers.skipped && RealBrowsers.status().agentBrowser != nil))
    func theRealBatchReadsTheQuotedWordsBackAsTheyWere() async throws {
        let executable = try #require(RealBrowsers.status().agentBrowser)
        let sockets = "/tmp/orbab-\(UUID().uuidString.prefix(8))"
        let session = "orb-test-batch-\(UUID().uuidString.prefix(8).lowercased())"
        let environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "AGENT_BROWSER_SOCKET_DIR": sockets]
        defer { try? FileManager.default.removeItem(atPath: sockets) }
        let texts = ["--json", "-it's x", "$HOME `x` \"q\"", "a b", "--", "-", "'", "''", "\\", "\\'", "ação ✓ 日本", "#c ; ls", "*", "~", "{a}", "&& rm -rf x",
                     "--headed", "--session", "-p", "x\ty", "[\"fill\"]", "@e2"]
        for text in texts {
            let line = AgentBrowserDriver.shellLine(["fill", "@e1", text])
            let output = try await ProcessRunner.run(executable, ["--session", session, "--json", "batch", line], environment: environment, timeout: .seconds(30))
            let reply = try #require(JSONValue.parse(output.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""), "\(output.output)")
            let read = reply.array?.first?["command"]?.array?.compactMap(\.string)
            #expect(read == ["fill", "@e1", text], "\(text.debugDescription) was read as \(String(describing: read))")
        }
        // A line break is a word like any other; a command with many words keeps each one.
        let many = AgentBrowserDriver.shellLine(["fill", "@e1", "first line\nsecond line"])
        let output = try await ProcessRunner.run(executable, ["--session", session, "--json", "batch", many], environment: environment, timeout: .seconds(30))
        #expect(JSONValue.parse(output.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "")?.array?.first?["command"]?.array?.compactMap(\.string)
                == ["fill", "@e1", "first line\nsecond line"])
        _ = try? await ProcessRunner.run(executable, ["--session", session, "--json", "close"], environment: environment, timeout: .seconds(30))
    }

    @Test func aBatchAnswerIsAListWithTheResultOfTheCommand() throws {
        let reply = try #require(AgentBrowserReply.parse(#"[{"command":["fill","@e1","--json"],"error":null,"result":{"filled":"@e1"},"success":true}]"#))
        #expect(reply.success && reply.data?["filled"] == .string("@e1"))
        let failed = try #require(AgentBrowserReply.parse(#"[{"command":["click","@e9"],"error":"Unknown ref: e9","result":null,"success":false}]"#))
        #expect(!failed.success && failed.error == "Unknown ref: e9")
    }

    @Test func aCommandSentJustAfterCloseIsTriedAgain() async throws {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let (driver, _) = make { _ in
            let attempt = attempts.withLock { n -> Int in n += 1; return n }
            return attempt < 3 ? "{\"error\":\"Failed to connect: No such file or directory (os error 2)\",\"success\":false}"
                : "{\"success\":true,\"data\":{\"url\":\"https://a.test/\",\"title\":\"A\"},\"error\":null}"
        }
        let page = try await driver.open("https://a.test/")
        #expect(page.url == "https://a.test/" && attempts.withLock { $0 } == 3)
        #expect(AgentBrowserDriver.isStaleConnection("Failed to connect: No such file or directory (os error 2)"))
        #expect(!AgentBrowserDriver.isStaleConnection("Element not found") && !AgentBrowserDriver.isStaleConnection(nil))
    }

    @Test func aSessionNobodyOpenedIsNotStartedToAskItsAddress() async throws {
        // (The driver answers `noPage` from its own `session list`, never sending the command that would start a browser.)
        let (driver, calls) = make(listsSession: false) { arguments in
            arguments.contains("session") ? ok(#"{"sessions":["another"]}"#) : ok(#"{"url":"https://a.test/"}"#)
        }
        #expect(try await driver.currentURL() == nil)
        #expect(calls.withLock { $0.allSatisfy { !$0.contains("url") } }, "`get url` would have started a browser of its own choosing")
    }

    @Test func afterCloseNoPageCountsEvenWhileTheBackgroundProcessIsLeaving() async throws {
        let (driver, calls) = make(listsSession: false) { arguments in
            arguments.contains("session") ? ok(#"{"sessions":["orb-test-chrome"]}"#) : ok(#"{"url":"https://a.test/","title":"A","closed":true}"#)
        }
        _ = try await driver.open("https://a.test/")
        #expect(try await driver.currentURL() == "https://a.test/")
        try await driver.close()
        let before = calls.withLock { $0.count }
        #expect(try await driver.currentURL() == nil)
        #expect(calls.withLock { $0.count } == before, "not even asked")
        _ = try await driver.open("https://a.test/")
        #expect(try await driver.currentURL() == "https://a.test/")
    }

    @Test func theCommandLineGetsTheUsersEnvironmentWithoutTheirAgentBrowserSettings() async throws {
        let seen = OSAllocatedUnfairLock<[String: String]?>(initialState: nil)
        let run: BrowserCommandRunner = { _, _, environment, _ in
            seen.withLock { $0 = environment }
            return ProcessOutput(status: 0, signal: nil, output: "{\"success\":true,\"data\":{\"url\":\"u\",\"title\":\"t\"},\"error\":null}", timedOut: false)
        }
        let config = AgentBrowserConfig(executable: "/x/ab", session: "s")
        let driver = AgentBrowserDriver(config: config, environment: { ["PATH": "/usr/bin", "AGENT_BROWSER_PROXY": "x"] }, run: run)
        _ = try await driver.open("https://a.test/")
        let environment = try #require(seen.withLock { $0 })
        #expect(environment["PATH"] == "/usr/bin" && environment["AGENT_BROWSER_PROXY"] == nil && environment["AGENT_BROWSER_IDLE_TIMEOUT_MS"] == "1800000")
    }

    @Test func googleLinksAreFollowedToTheirRealAddress() async throws {
        #expect(GoogleRedirects.isRedirect("https://www.google.com/goto?url=CAES123") && GoogleRedirects.isRedirect("https://www.google.com.br/url?q=https://a.test/"))
        #expect(!GoogleRedirects.isRedirect("https://www.google.com/search?q=x") && !GoogleRedirects.isRedirect("https://a.test/goto?url=1"))
        #expect(GoogleRedirects.embeddedTarget("https://www.google.com/url?sa=t&q=https://a.test/x%3Fy%3D1&usg=z") == "https://a.test/x?y=1")
        #expect(GoogleRedirects.embeddedTarget("https://www.google.com/goto?url=CAES123") == nil)
    }
}

/// Ajustes → Navegador: what its rows say in each state.
@Suite(.serialized) struct BrowserSetupTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbSetup-\(UUID().uuidString)/navegador")

    private func installer(network: FakeInstallNetwork = FakeInstallNetwork()) -> BrowserInstaller {
        BrowserInstaller(layout: BrowserInstallLayout(root: root), network: network, run: FakeInstallRunner { _, _ in nil }.runner,
                         freeSpace: { _ in nil })
    }

    private static let chrome = BrowserProgram(kind: .chrome, executable: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", major: 155)

    /// What the Mac has: `agentBrowser` and a browser, each only when asked.
    private func status(agentBrowser: Bool = false, browser: BrowserProgram? = nil) -> @Sendable () async -> BrowserStatus {
        { BrowserStatus(agentBrowser: agentBrowser ? "/x/agent-browser" : nil, program: browser,
                        missing: (agentBrowser ? [] : [.init(name: "agent-browser")]) + (browser == nil ? [.init(name: "Chrome")] : [])) }
    }

    @MainActor @Test func theRowsAreAgentBrowserAndTheBrowserAndNothingElse() async {
        let setup = BrowserSetup(installer: installer(), status: status())
        #expect(setup.rows.map(\.component) == [.agentBrowser, .chrome])
        await setup.refresh()
        #expect(setup.row(.agentBrowser)?.phase == .notInstalled && setup.row(.agentBrowser)?.canInstall == true)
        #expect(setup.row(.agentBrowser)?.statusText == "Não instalado")
        #expect(setup.row(.chrome)?.statusText == "Nenhum navegador encontrado")
    }

    @MainActor @Test func aChromeFoundOnTheMacIsUsableAndNotTheAppsToRemove() async {
        let setup = BrowserSetup(installer: installer(), status: status(agentBrowser: true, browser: Self.chrome))
        await setup.refresh()
        let row = setup.row(.chrome)
        #expect(row?.phase == .installed(managed: false) && row?.canInstall == false && row?.canRemove == false)
        #expect(row?.statusText == "Usando Google Chrome 155")
    }

    @MainActor @Test func beforeTheFirstLookEveryRowIsCheckingWithNothingToInstallOrRemove() async {
        let setup = BrowserSetup(installer: installer(), status: status(agentBrowser: true, browser: Self.chrome))
        for row in setup.rows {
            #expect(row.phase == .checking && row.statusText == "Conferindo…", "not \"Não instalado\" before anything was looked at")
            #expect(!row.canInstall && !row.canRemove && !row.canUpdate)
        }
        await setup.refresh()
        #expect(setup.rows.allSatisfy { $0.phase != .checking }, "the first look replaces it")
    }

    @Test func aRowInEachStateSaysWhatItIsAndWhatCanBeDone() {
        let failed = BrowserComponentRow(component: .agentBrowser, phase: .failed("Sem conexão com a internet. Confira a rede e tente de novo."))
        #expect(failed.canInstall && failed.statusText.hasPrefix("Sem conexão"), "a failure can be tried again")

        var blocked = BrowserComponentRow(component: .chrome, phase: .notInstalled)
        blocked.isBlocked = true
        #expect(!blocked.canInstall, "one install at a time")

        var managed = BrowserComponentRow(component: .agentBrowser, phase: .installed(managed: true), versionText: "agent-browser 0.39.1")
        #expect(managed.statusText == "Instalado · agent-browser 0.39.1" && managed.canRemove && !managed.canUpdate)
        managed.updateAvailable = true
        #expect(managed.canUpdate)

        let bare = BrowserInstallProgress(component: .agentBrowser, phase: .resolving)
        #expect(bare.text == "Procurando a versão mais nova do agent-browser…" && bare.fraction == nil)
    }

    @MainActor @Test func installingShowsProgressThenTheResultOrTheFailure() async throws {
        let network = FakeInstallNetwork()
        network.offline = true
        let setup = BrowserSetup(installer: installer(network: network), status: status())
        await setup.refresh()
        setup.install(.agentBrowser)
        #expect(setup.working == .agentBrowser && setup.row(.agentBrowser)?.isInstalling == true)
        #expect(setup.row(.chrome)?.isBlocked == true && setup.row(.chrome)?.canInstall == false)
        await waitUntil("the failed install to settle") { setup.working == nil && setup.row(.agentBrowser)?.isInstalling != true }
        #expect(setup.working == nil)
        guard case .failed(let message)? = setup.row(.agentBrowser)?.phase else { Issue.record("\(String(describing: setup.row(.agentBrowser)))"); return }
        #expect(message == BrowserInstallError.noNetwork.errorDescription)
        #expect(setup.row(.chrome)?.canInstall == true)
    }

    @MainActor @Test func cancellingStopsTheInstallWithoutAnError() async throws {
        let network = FakeInstallNetwork()
        let started = LockedBox(false)
        network.beforeDownload = { _ in
            started.value = true
            try await Task.sleep(for: .seconds(30))
        }
        let setup = BrowserSetup(installer: installer(network: network), status: status())
        setup.install(.agentBrowser)
        defer { setup.cancel() }
        guard await waitUntil("the download to start", { started.value }) else { return }
        setup.cancel()
        await waitUntil("the cancelled install to settle") { setup.working == nil && setup.row(.agentBrowser)?.isInstalling != true }
        #expect(setup.working == nil)
        #expect(setup.row(.agentBrowser)?.phase == .notInstalled, "cancelled is not a failure")
    }
}
