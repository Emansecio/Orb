import Foundation
import os
import Testing
@testable import Orb

/// What the driver learned from running against the real browsers, and the settings model of Ajustes → Navegador.
struct BrowserDriverRealityTests {
    private func make(_ engine: BrowserEngineKind = .chrome, listsSession: Bool = true, reply: @escaping @Sendable ([String]) -> String)
        -> (driver: AgentBrowserDriver, calls: OSAllocatedUnfairLock<[[String]]>) {
        let calls = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        let name = "orb-test-\(engine.rawValue)"
        let run: BrowserCommandRunner = { _, arguments, _, _ in
            calls.withLock { $0.append(arguments) }
            // The session is running, as far as `session list` goes (the driver asks before any command but `open`).
            let answer = listsSession && arguments.contains("session") && arguments.contains("list")
                ? "{\"success\":true,\"data\":{\"sessions\":[\"\(name)\"]},\"error\":null}" : reply(arguments)
            return ProcessOutput(status: 0, signal: nil, output: answer, timedOut: false)
        }
        let config = AgentBrowserConfig(executable: "/x/agent-browser", session: name, engine: engine,
                                        browserExecutable: nil, profile: nil)
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
    @Test(.enabled(if: !RealBrowsers.skipped && RealBrowsers.status(.chrome).agentBrowser != nil))
    func theRealBatchReadsTheQuotedWordsBackAsTheyWere() async throws {
        let executable = try #require(RealBrowsers.status(.chrome).agentBrowser)
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

    @Test func obscuraClicksALinkInThePageWhenItsOwnClickCannotReadTheAnswer() async throws {
        let failure = "Failed to deserialize CDP response for DOM.getBoxModel: invalid type: floating point `91.25`, expected i64"
        let (driver, calls) = make(.obscura) { arguments in
            if arguments.contains("snapshot") { return ok(#"{"snapshot":"- link \"Ir\" [ref=e2]","origin":"http://a.test/","refs":{"e2":{"role":"link","name":"Ir"}}}"#) }
            if arguments.contains("click") { return "{\"success\":false,\"data\":null,\"error\":\"\(failure)\"}" }
            return ok(#"{"result":"clicked"}"#)
        }
        _ = try await driver.snapshot(interactive: true, selector: nil)
        try await driver.click("e2")
        let eval = try #require(calls.withLock { $0.last })
        #expect(eval.contains("eval") && eval.last?.contains("a[href]") == true && eval.last?.contains("\"Ir\"") == true)
        #expect(eval.last?.contains(".click()") == true)

        // Another failure is still a failure, and so is a link that is not on the page.
        let (other, _) = make(.obscura) { _ in "{\"success\":false,\"data\":null,\"error\":\"Unknown ref: e5\"}" }
        await #expect(throws: BrowserDriverError.failed("Unknown ref: e5")) { try await other.click("e5") }
        let (gone, _) = make(.obscura) { arguments in
            arguments.contains("click") ? "{\"success\":false,\"data\":null,\"error\":\"\(failure)\"}" : ok(#"{"result":false}"#)
        }
        await #expect(throws: BrowserDriverError.self) { try await gone.click("e2") }
        // Chrome does not get the workaround.
        let (chrome, _) = make(.chrome) { _ in "{\"success\":false,\"data\":null,\"error\":\"\(failure)\"}" }
        await #expect(throws: BrowserDriverError.failed(failure)) { try await chrome.click("e2") }
    }

    // MARK: Obscura's click in the page never guesses (finding 5)

    private static let boxModelFailure = "{\"success\":false,\"data\":null,\"error\":\"Failed to deserialize CDP response for DOM.getBoxModel: invalid type: floating point `1.5`, expected i64\"}"

    @Test func obscuraDoesNotClickWhenTheSnapshotHadTwoElementsAlike() async throws {
        let (driver, calls) = make(.obscura) { arguments in
            if arguments.contains("snapshot") {
                return ok(#"{"snapshot":"x","origin":"http://a.test/","refs":{"e1":{"role":"button","name":"Comprar"},"e2":{"role":"button","name":"Comprar"},"e3":{"role":"link","name":"Ajuda"}}}"#)
            }
            if arguments.contains("click") { return Self.boxModelFailure }
            return ok(#"{"result":"clicked"}"#)
        }
        _ = try await driver.snapshot(interactive: true, selector: nil)
        do {
            try await driver.click("e1")
            Issue.record("two buttons called Comprar: a click on the first one that matches could buy the wrong thing")
        } catch BrowserDriverError.failed(let message) {
            #expect(message.contains("more than one element is called “Comprar”"))
        }
        #expect(!calls.withLock { $0.contains { $0.contains("eval") } }, "the page was not even asked to click")
        // A name that is alone is clicked.
        try await driver.click("e3")
        #expect(calls.withLock { $0.contains { $0.contains("eval") } })
    }

    @Test func obscuraDoesNotClickWhenThePageHasTwoElementsAlikeEvenIfTheSnapshotHadOne() async throws {
        let (driver, _) = make(.obscura) { arguments in
            if arguments.contains("snapshot") { return ok(#"{"snapshot":"x","origin":"http://a.test/","refs":{"e1":{"role":"link","name":"Ver"}}}"#) }
            if arguments.contains("click") { return Self.boxModelFailure }
            return ok(#"{"result":"ambiguous"}"#)
        }
        _ = try await driver.snapshot(interactive: true, selector: nil)
        await #expect(throws: BrowserDriverError.failed(AgentBrowserDriver.ambiguousClick("Ver"))) { try await driver.click("e1") }
        // The script itself: it counts the elements and clicks only a single one.
        let script = AgentBrowserDriver.clickScript(role: "link", name: "Ver")
        #expect(script.contains("found.length > 1) return 'ambiguous'") && script.contains("if (!wanted) return 'none'"))
    }

    @Test func theClickScriptRunsInANodeLikeEngineAndKeepsToItsRules() throws {
        // Runs the script against a tiny stand-in document, if `node` is on the Mac: two equal links are ambiguous, one is clicked.
        let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let node else { return }
        func run(links: [String], name: String) throws -> String {
            let script = AgentBrowserDriver.clickScript(role: "link", name: name)
            let harness = """
            const clicked = [];
            const make = text => ({innerText: text, getAttribute: () => null, click() { clicked.push(text); }});
            const items = \(JSONValue.array(links.map { .string($0) }).jsonString).map(make);
            const document = {querySelectorAll: () => items};
            const result = \(script);
            console.log(result + ':' + clicked.length);
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = ["-e", harness]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(try run(links: ["Ver", "Ver", "Outro"], name: "Ver") == "ambiguous:0")
        #expect(try run(links: ["Ver", "Outro"], name: "Ver") == "clicked:1")
        #expect(try run(links: ["Ver tudo", "Outro"], name: "Ver") == "clicked:1", "one partial match is the one")
        #expect(try run(links: ["Ver tudo", "Ver mais"], name: "Ver") == "ambiguous:0")
        #expect(try run(links: ["Outro"], name: "Ver") == "none:0")
        #expect(try run(links: ["", "Outro"], name: "") == "none:0", "an empty name matches nothing")
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

    @Test func theCommandLineGetsTheEnvironmentOfTheEngine() async throws {
        let seen = OSAllocatedUnfairLock<[String: String]?>(initialState: nil)
        let run: BrowserCommandRunner = { _, _, environment, _ in
            seen.withLock { $0 = environment }
            return ProcessOutput(status: 0, signal: nil, output: "{\"success\":true,\"data\":{\"url\":\"u\",\"title\":\"t\"},\"error\":null}", timedOut: false)
        }
        let config = AgentBrowserConfig(executable: "/x/ab", session: "s", engine: .obscura, browserExecutable: "/x/obscura")
        let driver = AgentBrowserDriver(config: config, environment: { ["PATH": "/usr/bin"] }, run: run)
        _ = try await driver.open("https://a.test/")
        let environment = try #require(seen.withLock { $0 })
        #expect(environment["PATH"] == "/usr/bin" && environment["AGENT_BROWSER_OBSCURA_STEALTH"] == "1" && environment["AGENT_BROWSER_IDLE_TIMEOUT_MS"] == "1800000")
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

    private func installer() -> BrowserInstaller {
        BrowserInstaller(layout: BrowserInstallLayout(root: root), network: FakeInstallNetwork(), run: FakeInstallRunner { _, _ in nil }.runner,
                         freeSpace: { _ in nil }, findPython: { _ in "/usr/bin/python3" })
    }

    private func status(ready: Set<BrowserEngineKind>) -> @Sendable (BrowserEngineKind) async -> BrowserEngineStatus {
        { engine in
            var status = BrowserEngineStatus(engine: engine, agentBrowser: "/x/agent-browser")
            if !ready.contains(engine) { status.missing = [.init(name: engine.browserComponent?.name ?? "")] }
            return status
        }
    }

    @MainActor @Test func everyEngineThatNeedsInstallingHasARow() async {
        let setup = BrowserSetup(installer: installer(), status: status(ready: [.obscura]))
        #expect(setup.rows.map(\.engine) == [.chrome, .obscura, .cloak])
        await setup.refresh()
        #expect(setup.row(.chrome)?.phase == .notInstalled && setup.row(.chrome)?.canInstall == true && setup.row(.chrome)?.canRemove == false)
        // Found on the Mac but not put there by the app: usable, and not the app's to remove.
        #expect(setup.row(.obscura)?.phase == .installed(managed: false) && setup.row(.obscura)?.canInstall == false && setup.row(.obscura)?.canRemove == false)
        #expect(setup.row(.obscura)?.statusText == "Instalado fora do Orb")
        #expect(setup.row(.cloak)?.statusText == "Não instalado")
    }

    @MainActor @Test func beforeTheFirstLookEveryEngineIsCheckingWithNothingToInstallOrRemove() async {
        let setup = BrowserSetup(installer: installer(), status: status(ready: [.obscura]))
        for row in setup.rows {
            #expect(row.phase == .checking && row.statusText == "Conferindo…", "not \"Não instalado\" before anything was looked at")
            #expect(!row.canInstall && !row.canRemove && !row.canUpdate)
        }
        await setup.refresh()
        #expect(setup.rows.allSatisfy { $0.phase != .checking }, "the first look replaces it")
    }

    @MainActor @Test func anEngineTheAppInstalledShowsItsVersionsAndCanBeRemovedAndUpdated() async throws {
        let layout = BrowserInstallLayout(root: root)
        try FileManager.default.createDirectory(at: layout.binDirectory, withIntermediateDirectories: true)
        for file in [layout.agentBrowser, layout.obscura] {
            try Data("x".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let now = Date()
        let records: InstalledRecords = ["agentBrowser": InstalledComponent(version: "0.39.0", installedAt: now),
                                         "obscura": InstalledComponent(version: "0.2.4", installedAt: now, detail: "stealth")]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: layout.recordsFile)
        let setup = BrowserSetup(installer: installer(), status: status(ready: [.obscura]))
        await setup.refresh()
        let row = try #require(setup.row(.obscura))
        #expect(row.phase == .installed(managed: true) && row.canRemove && !row.canUpdate && row.versionText == "agent-browser 0.39.0 · Obscura 0.2.4")
        #expect(row.statusText == "Instalado · agent-browser 0.39.0 · Obscura 0.2.4")

        let withUpdate = BrowserEngineRow(engine: .obscura, phase: .installed(managed: true), updateAvailable: true)
        #expect(withUpdate.canUpdate)
        #expect(!BrowserEngineRow(engine: .obscura, phase: .installed(managed: false), updateAvailable: true).canUpdate, "only what the app installed is updated")
    }

    @Test func aRowInEachStateSaysWhatItIsAndWhatCanBeDone() {
        let progress = BrowserInstallProgress(component: .chrome, phase: .downloading, received: 42_000_000, total: 184_000_000, step: 2, steps: 2)
        let installing = BrowserEngineRow(engine: .chrome, phase: .installing(progress))
        #expect(installing.isInstalling && !installing.canInstall && !installing.canRemove)
        #expect(installing.statusText == "2/2 · Baixando o Chrome… 42 de 184 MB")
        #expect(progress.fraction == (1 + 42.0 / 184.0) / 2)

        let failed = BrowserEngineRow(engine: .cloak, phase: .failed("Sem conexão com a internet. Confira a rede e tente de novo."))
        #expect(failed.canInstall && failed.statusText.hasPrefix("Sem conexão"), "a failure can be tried again")

        var blocked = BrowserEngineRow(engine: .chrome, phase: .notInstalled)
        blocked.isBlocked = true
        #expect(!blocked.canInstall, "one install at a time")

        let bare = BrowserInstallProgress(component: .agentBrowser, phase: .resolving)
        #expect(bare.text == "Procurando a versão mais nova do agent-browser…" && bare.fraction == nil)
        #expect(BrowserInstallProgress(component: .obscura, phase: .downloading, received: 5_000_000).text == "Baixando o Obscura… 5 MB")
    }

    @MainActor @Test func installingShowsProgressThenTheResultOrTheFailure() async throws {
        let network = FakeInstallNetwork()
        network.offline = true
        let installer = BrowserInstaller(layout: BrowserInstallLayout(root: root), network: network, run: FakeInstallRunner { _, _ in nil }.runner,
                                         freeSpace: { _ in nil }, findPython: { _ in "/usr/bin/python3" })
        let setup = BrowserSetup(installer: installer, status: status(ready: []))
        await setup.refresh()
        setup.install(.chrome)
        #expect(setup.working == .chrome && setup.row(.chrome)?.isInstalling == true)
        #expect(setup.row(.obscura)?.isBlocked == true && setup.row(.obscura)?.canInstall == false)
        for _ in 0..<300 where setup.working != nil || setup.row(.chrome)?.isInstalling == true { try await Task.sleep(for: .milliseconds(20)) }
        #expect(setup.working == nil)
        guard case .failed(let message)? = setup.row(.chrome)?.phase else { Issue.record("\(String(describing: setup.row(.chrome)))"); return }
        #expect(message == BrowserInstallError.noNetwork.errorDescription)
        #expect(setup.row(.obscura)?.canInstall == true)
    }

    @MainActor @Test func cancellingStopsTheInstallWithoutAnError() async throws {
        let network = FakeInstallNetwork()
        network.serve(document: "https://api.github.com/repos/vercel-labs/agent-browser/releases/latest", FakeInstallNetwork.releaseJSON(
            tag: "v1.0.0", assets: [(BrowserPlatform.current.agentBrowserAsset, Data("x".utf8), true)]))
        let started = LockedBox(false)
        network.beforeDownload = { _ in
            started.value = true
            try await Task.sleep(for: .seconds(30))
        }
        let installer = BrowserInstaller(layout: BrowserInstallLayout(root: root), network: network, run: FakeInstallRunner { _, _ in nil }.runner,
                                         freeSpace: { _ in nil }, findPython: { _ in "/usr/bin/python3" })
        let setup = BrowserSetup(installer: installer, status: status(ready: []))
        setup.install(.obscura)
        while !started.value { try await Task.sleep(for: .milliseconds(10)) }
        setup.cancel()
        for _ in 0..<300 where setup.working != nil || setup.row(.obscura)?.isInstalling == true { try await Task.sleep(for: .milliseconds(20)) }
        #expect(setup.working == nil)
        #expect(setup.row(.obscura)?.phase == .notInstalled, "cancelled is not a failure")
    }
}
