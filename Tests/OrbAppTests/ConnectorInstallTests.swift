import Foundation
import Testing
@testable import Orb

// `connector_install`: the Orb installs a connector itself (docs/MANUAL.md, Conectores), and the form reads a command
// written as in a terminal.

/// A server with `count` tools whose calls answer "ok:<tool>".
private func installableServer(count: Int = 2) throws -> URL {
    try testScript("""
    import json, sys
    def send(m): sys.stdout.write(json.dumps(m) + "\\n"); sys.stdout.flush()
    for line in sys.stdin:
        m = json.loads(line); method, id = m.get("method"), m.get("id")
        if method == "initialize":
            send({"jsonrpc":"2.0","id":id,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"f","version":"0"}}})
        elif method == "tools/list":
            send({"jsonrpc":"2.0","id":id,"result":{"tools":[{"name":"t%d" % i,"description":"Tool %d" % i,"inputSchema":{"type":"object"}} for i in range(\(count))]}})
        elif method == "tools/call":
            send({"jsonrpc":"2.0","id":id,"result":{"content":[{"type":"text","text":"ok:" + m["params"]["name"]}]}})
        elif id is not None:
            send({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"nope"}})
    """)
}

private func json(_ text: String) -> JSONValue { JSONValue.parse(text)! }

// MARK: - The call

struct ConnectorInstallRequestTests {
    private let noFiles: (String) -> Bool = { _ in false }

    @Test func aLocalServerAsAReadmeWritesIt() throws {
        let request = try ConnectorInstallRequest(json(#"{"name":"  football   docs ","command":"npx -y football-docs"}"#), fileExists: noFiles)
        #expect(request.name == "football docs")
        #expect(request.command == "npx" && request.arguments == ["-y", "football-docs"])
        #expect(!request.isRemote && !request.allOrbs && request.summary == nil)
    }

    @Test func argsAndEnvironmentAreKeptAsGiven() throws {
        let request = try ConnectorInstallRequest(json(#"""
        {"name":"Notion","command":"npx","args":["-y","@notionhq/notion-mcp-server"],
         "env":{"NOTION_TOKEN":"ntn_x","PORT":3000,"DEBUG":true},"summary":"Páginas\ndo Notion.","all_orbs":true}
        """#), fileExists: noFiles)
        #expect(request.arguments == ["-y", "@notionhq/notion-mcp-server"])
        #expect(request.environment == ["NOTION_TOKEN": "ntn_x", "PORT": "3000", "DEBUG": "true"])
        #expect(request.summary == "Páginas do Notion." && request.allOrbs)
    }

    @Test func aRemoteServerTakesAnAddressAndHeaders() throws {
        let request = try ConnectorInstallRequest(json(#"{"name":"Linear","url":" https://mcp.linear.app/mcp ","headers":{"Authorization":"Bearer x"}}"#))
        #expect(request.isRemote && request.url == "https://mcp.linear.app/mcp" && request.command.isEmpty)
        #expect(request.headers == ["Authorization": "Bearer x"])
    }

    @Test func whatIsWrongIsSaidBeforeAnythingIsSaved() {
        for bad in [#"{"command":"npx x"}"#,                                   // no name
                    #"{"name":"X"}"#,                                          // neither command nor url
                    #"{"name":"X","command":"npx","url":"https://a.b/mcp"}"#,  // both
                    #"{"name":"X","url":"ftp://a.b/mcp"}"#,                    // not http(s)
                    #"{"name":"X","url":"mcp.linear.app"}"#,                   // not a full address
                    #"{"name":"X","command":"npx","env":["A"]}"#,              // env not an object
                    #"{"name":"X","command":"npx","env":{"A B":"1"}}"#,        // a name no variable has
                    #"{"name":"X","command":"npx","env":{"A":{"b":1}}}"#] {    // a value that is no text
            #expect(throws: ToolError.self, Comment(rawValue: bad)) { try ConnectorInstallRequest(json(bad), fileExists: noFiles) }
        }
    }

    @Test func longTextIsCut() throws {
        let long = String(repeating: "a", count: 300)
        let request = try ConnectorInstallRequest(json(#"{"name":"\#(long)","command":"x","summary":"\#(long)"}"#), fileExists: noFiles)
        #expect(request.name.count == ConnectorGateway.nameLimit && request.summary?.count == 200)
    }

    @Test func theSameServerIsRecognized() throws {
        let local = try ConnectorInstallRequest(json(#"{"name":"Outro nome","command":"npx -y football-docs"}"#), fileExists: noFiles)
        #expect(local.isSameServer(as: MCPServerConfig(name: "football-docs", command: "npx", arguments: ["-y", "football-docs"])))
        #expect(!local.isSameServer(as: MCPServerConfig(name: "f", command: "npx", arguments: ["-y", "football-docs@2"])))
        #expect(!local.isSameServer(as: MCPServerConfig(name: "f", url: "https://a.b/mcp")))
        let remote = try ConnectorInstallRequest(json(#"{"name":"L","url":"https://MCP.linear.app/mcp"}"#))
        #expect(remote.isSameServer(as: MCPServerConfig(name: "Linear", url: "https://mcp.linear.app/mcp ")))
        #expect(!remote.isSameServer(as: MCPServerConfig(name: "Linear", command: "npx")))
    }
}

// MARK: - The form's arguments

struct ConnectorArgumentsParseTests {
    @Test func aCommandLineIsSplitAsTheTerminalWould() {
        let parsed = ConnectorArguments.parse(command: "npx -y football-docs", arguments: [], fileExists: { _ in false })
        #expect(parsed.command == "npx" && parsed.arguments == ["-y", "football-docs"])
        // Pasted into Argumentos, in one line.
        let pasted = ConnectorArguments.parse(command: "npx", arguments: ["-y football-docs", ""], fileExists: { _ in false })
        #expect(pasted.arguments == ["-y", "football-docs"])
    }

    @Test func aPathWithSpacesStaysOneArgument() {
        let path = "/Users/eu/Meus Servidores/server.js"
        let parsed = ConnectorArguments.parse(command: "node", arguments: [path], fileExists: { _ in false })
        #expect(parsed.command == "node" && parsed.arguments == [path])
        // A program whose path has a space is not split.
        let program = "/Applications/Meu App/server"
        #expect(ConnectorArguments.parse(command: program, arguments: [], fileExists: { $0 == program }).command == program)
    }

    @Test func quotesAndBackslashesWorkAsInTheShell() {
        #expect(ConnectorArguments.shellWords(#"--dir "/a b/c" --name 'x y' plain\ word"#)
            == ["--dir", "/a b/c", "--name", "x y", "plain word"])
        #expect(ConnectorArguments.shellWords("   ").isEmpty)
        #expect(ConnectorArguments.shellWords(#"--empty "" end"#) == ["--empty", "", "end"])
    }
}

// MARK: - Offered, and always asked

struct ConnectorInstallPolicyTests {
    private func verdict(_ arguments: String, mode: PermissionMode) -> PermissionVerdict {
        let call = PermissionPolicy.call(for: ConnectorInstallTool(), arguments: json(arguments),
                                         context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory))
        return PermissionPolicy.evaluate(mode: mode, call: call, rules: [], workspace: nil)
    }

    @Test func itAsksEvenInAutomatic() {
        guard case .ask(.dangerous(let reason)) = verdict(#"{"name":"X","command":"npx x"}"#, mode: .auto) else {
            Issue.record("expected a card"); return
        }
        #expect(reason.contains("programa da internet"))
        guard case .ask(.dangerous(let remote)) = verdict(#"{"name":"X","url":"https://a.b/mcp"}"#, mode: .ask) else {
            Issue.record("expected a card"); return
        }
        #expect(remote.contains("servidor novo"))
        #expect(verdict(#"{"name":"X","command":"npx x"}"#, mode: .bypass) == .allow)
        guard case .deny = verdict(#"{"name":"X","command":"npx x"}"#, mode: .readOnly) else { Issue.record("expected a refusal"); return }
    }

    @Test func offeredToEveryOrbButNotWhereNobodyWatches() {
        let names = { (multi: MultiOrbOffering) in
            ToolBox.offered(for: [], accessibilityGranted: true, multi: multi).map(\.spec.name)
        }
        #expect(names(MultiOrbOffering()).contains(ConnectorInstallTool.name))
        #expect(!names(MultiOrbOffering(sideRun: true)).contains(ConnectorInstallTool.name))
    }

    @Test func theCardSaysWhatRuns() {
        let tool = ConnectorInstallTool()
        #expect(tool.summary(json(#"{"name":"football-docs","command":"npx","args":["-y","football-docs"]}"#))
            == ("Instalando o conector football-docs", "npx -y football-docs"))
        #expect(tool.summary(json(#"{"name":"L","url":"https://a.b/mcp"}"#)).detail == "https://a.b/mcp")
        #expect(tool.summary(json(#"{"name":"L","url":"https://a.b/mcp","all_orbs":true}"#)).detail.contains("todos os Orbs"))
        #expect(MCPConnection.initializeTimeout(for: MCPServerConfig(name: "n", command: "npx")) > .seconds(30))
        #expect(MCPConnection.initializeTimeout(for: MCPServerConfig(name: "n", url: "https://a.b/mcp")) == .seconds(30))
        // What goes with it is named, never shown.
        let withEnv = tool.summary(json(#"{"name":"N","command":"npx -y n","env":{"TOKEN":"segredo","A":"1"}}"#)).detail
        #expect(withEnv == "npx -y n · env: A, TOKEN" && !withEnv.contains("segredo"))
        #expect(tool.summary(json(#"{"name":"L","url":"https://a.b/mcp","headers":{"Authorization":"x"}}"#)).detail
            == "https://a.b/mcp · headers: Authorization")
    }

    @Test func withoutTheAppItSaysSo() async {
        await #expect(throws: ToolError.self) {
            try await ConnectorInstallTool().run(json(#"{"name":"X","command":"x"}"#),
                                                 context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory))
        }
    }

    @Test func theRosterReplacesTheSameConnector() {
        var config = MCPServerConfig(name: "A", command: "x")
        let roster = ConnectorRoster([config])
        config.name = "B"
        roster.add(config)
        roster.add(MCPServerConfig(name: "C", command: "y"))
        #expect(roster.connectors.map(\.name) == ["B", "C"])
    }
}

// MARK: - The app installs it

@Suite(.enabled(if: hasPython)) final class ConnectorInstallAppTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbInstall-\(UUID().uuidString)")
    deinit { removeTestFolder(root) }

    @MainActor private func model() -> AppModel {
        AppModel(store: Store(directory: root), runsBackgroundWork: false, secretVault: MemoryVault())
    }

    @Test @MainActor func itAppearsOnThePageStartsAndListsItsTools() async throws {
        let model = model(), bot = try #require(model.bots.first), server = try installableServer()
        model.bots[0].capabilities.remove(.connectors)
        let result = try await model.installConnector(json(#"""
        {"name":"Futebol","command":"/usr/bin/python3","args":["\#(server.path)"],"env":{"API_KEY":"k1","LEVEL":"2"},"summary":"Dados."}
        """#), orb: bot.id, usableNow: false)
        let installed = try #require(model.connectors.first)
        #expect(model.connectors.count == 1 && installed.name == "Futebol" && installed.summary == "Dados.")
        #expect(installed.orbIDs == [bot.id] && installed.isEnabled)
        #expect(installed.secretKeys == ["API_KEY"])
        #expect(model.bots[0].capabilities.contains(.connectors))
        #expect(result.config?.id == installed.id)
        #expect(result.text.contains("Installed connector Futebol") && result.text.contains("t1 — Tool 1"))
        #expect(result.text.contains("next message"))
        await waitUntil("the card to show it up") { model.connectorStatus[installed.id] == .ready(toolCount: 2) }
    }

    @Test @MainActor func theSameServerIsNotInstalledTwice() async throws {
        let model = model(), server = try installableServer()
        let first = try #require(model.bots.first)
        let second = model.createBot(name: "Segundo", role: "", orb: OrbConfig(), model: "", mode: .ask, interview: false, folder: .home).id
        let call = json(#"{"name":"Futebol","command":"/usr/bin/python3","args":["\#(server.path)"]}"#)
        _ = try await model.installConnector(call, orb: first.id, usableNow: true)
        let again = try await model.installConnector(call, orb: second, usableNow: true)
        #expect(model.connectors.count == 1)
        #expect(model.connectors[0].orbIDs == [first.id, second])
        #expect(again.text.contains("already installed") && again.text.contains("Use it now"))
    }

    @Test @MainActor func switchOffIsNotTurnedOnWhenItWouldExposeOtherConnectors() async throws {
        let model = model(), bot = try #require(model.bots.first), server = try installableServer()
        model.connectors.append(MCPServerConfig(name: "Gmail", command: "x")) // applies to every Orb
        model.bots[0].capabilities.remove(.connectors)
        await #expect(throws: ToolError.self) {
            try await model.installConnector(json(#"{"name":"Futebol","command":"/usr/bin/python3","args":["\#(server.path)"]}"#),
                                             orb: bot.id, usableNow: false)
        }
        #expect(!model.bots[0].capabilities.contains(.connectors) && model.connectors.map(\.name) == ["Gmail"])
    }

    @Test @MainActor func reinstallingKeepsThePersonsKeysAndScope() async throws {
        let model = model(), server = try installableServer()
        let first = try #require(model.bots.first)
        let second = model.createBot(name: "Segundo", role: "", orb: OrbConfig(), model: "", mode: .ask, interview: false, folder: .home).id
        let path = server.path
        _ = try await model.installConnector(json(#"{"name":"F","command":"/usr/bin/python3","args":["\#(path)"],"env":{"API_KEY":"meu"}}"#),
                                             orb: first.id, usableNow: true)
        _ = try await model.installConnector(json(#"{"name":"F","command":"/usr/bin/python3","args":["\#(path)"],"env":{"API_KEY":"outro","NEW":"1"},"all_orbs":true}"#),
                                             orb: second, usableNow: true)
        #expect(model.connectors.count == 1)
        #expect(model.connectors[0].environment == ["API_KEY": "meu", "NEW": "1"])
        #expect(model.connectors[0].orbIDs == [first.id, second])
    }

    @Test @MainActor func renamingMovesTheAlwaysAllowRules() throws {
        let model = model()
        model.bots[0].permissionRules = [.connector("GitHub__create_issue"), .shell("git")]
        model.migrateConnectorRules(from: "GitHub", to: "Meu GitHub")
        #expect(model.bots[0].permissionRules == [.connector("meu_github__create_issue"), .shell("git")])
    }

    @Test @MainActor func oneThatDoesNotStartLeavesNothingBehind() async throws {
        let model = model(), bot = try #require(model.bots.first)
        await #expect(throws: ToolError.self) {
            try await model.installConnector(json(#"{"name":"Quebrado","command":"orb-no-such-command-xyz"}"#), orb: bot.id, usableNow: true)
        }
        #expect(model.connectors.isEmpty)
    }

    @Test @MainActor func theKeyGoesToTheKeychain() async throws {
        let vault = MemoryVault()
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false, secretVault: vault)
        let bot = try #require(model.bots.first), server = try installableServer()
        _ = try await model.installConnector(json(#"""
        {"name":"Futebol","command":"/usr/bin/python3","args":["\#(server.path)"],"env":{"FOOTBALL_TOKEN":"segredo-123"}}
        """#), orb: bot.id, usableNow: true)
        model.saveNow()
        let file = try String(contentsOf: root.appending(path: "state.json"), encoding: .utf8)
        #expect(!file.contains("segredo-123") && file.contains(ConnectorSecrets.marker))
    }
}

// MARK: - In a turn

@Suite(.enabled(if: hasPython)) struct ConnectorInstallEngineTests {
    @Test func installedMidTurnItIsCallableBeforeTheTurnEnds() async throws {
        let manager = MCPManager()
        let config = MCPServerConfig(name: "Futebol", command: "/usr/bin/python3", arguments: [try installableServer().path])
        let roster = ConnectorRoster([])
        let installs = LockedBox(0)
        var context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        context.connectorRoster = roster
        context.installConnector = { _ in
            installs.withLock { $0 += 1 }
            await manager.sync([config])
            _ = try await manager.test(config.id)
            return ConnectorInstallResult(text: "Installed connector Futebol.", config: config)
        }
        let script = CallScript([
            [.toolCalls([ToolCallRequest(id: "i1", name: ConnectorInstallTool.name,
                                         arguments: #"{"name":"Futebol","command":"/usr/bin/python3"}"#)])],
            [.toolCalls([ToolCallRequest(id: "c1", name: ConnectorGateway.callName,
                                         arguments: #"{"connector":"Futebol","tool":"t0","arguments":{}}"#)])],
            [.text("Pronto")],
        ], whenExhausted: .fim)
        let bot = Bot(name: "Teste", role: "", orb: OrbConfig(), permissionMode: .auto)
        let request = TurnRequest(bot: bot, model: "fake", system: "sys", history: [], prompt: "instala",
                                  client: CallScriptModel(script: script),
                                  tools: ConnectorGateway.tools(for: [], manager: manager, roster: roster) + [ConnectorInstallTool()],
                                  context: context)
        let engine = AgentEngine()
        var approvals: [ApprovalRequest] = [], results: [String] = []
        for await event in engine.run(request) {
            if case .approval(let approval) = event {
                approvals.append(approval)
                await engine.gate.resolve(approvalID: approval.id, decision: .once)
            }
            if case .message(let message) = event, message.role == .tool { results.append(message.content) }
        }
        #expect(approvals.count == 1) // the install; the connector's tool then runs as "Automático" lets it
        #expect(installs.withLock { $0 } == 1)
        #expect(results.contains { $0.contains("ok:t0") })
        await manager.sync([])
    }
}
