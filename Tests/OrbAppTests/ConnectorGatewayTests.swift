import Foundation
import Testing
@testable import Orb

private let hasPython = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

/// A connector with a catalog already on disk: `Store.saveConnectorCatalog`, then `MCPManager.sync` reads it, with no
/// server involved.
private struct CatalogFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "gateway-\(UUID().uuidString)")
    let store: Store
    let manager: MCPManager

    init() {
        store = Store(directory: root)
        manager = MCPManager(store: store)
    }

    func tearDown() { try? FileManager.default.removeItem(at: root) }

    static func tool(_ name: String, _ description: String = "", annotations: MCPToolAnnotations = .none,
                     schema: JSONValue = .schema(["id": .property("string")])) -> ConnectorCatalog.Tool {
        ConnectorCatalog.Tool(name: name, description: description, inputSchema: schema, annotations: annotations)
    }

    static func catalog(_ tools: [ConnectorCatalog.Tool]) -> ConnectorCatalog {
        var catalog = ConnectorCatalog(handshake: MCPHandshake(), specs: [], annotations: [:])
        catalog.tools = tools
        return catalog
    }

    /// Registers `connectors` in the manager, each with its catalog.
    func register(_ connectors: [(MCPServerConfig, ConnectorCatalog?)]) async {
        for (config, catalog) in connectors { if let catalog { store.saveConnectorCatalog(catalog, for: config.id) } }
        store.flush()
        await manager.sync(connectors.map(\.0))
    }
}

private func specChars(_ tools: [any AgentTool]) -> Int {
    tools.reduce(0) { $0 + $1.spec.description.count + $1.spec.parameters.jsonString.count }
}

// MARK: - The two tools and their index

struct ConnectorGatewayTests {
    private func config(_ name: String, summary: String? = nil) -> MCPServerConfig {
        var config = MCPServerConfig(name: name, command: "x")
        config.summary = summary
        return config
    }

    @Test func noConnectorsMeansNoTools() {
        #expect(ConnectorGateway.tools(for: [], manager: MCPManager()).isEmpty)
        let tools = ConnectorGateway.tools(for: [config("GitHub")], manager: MCPManager())
        #expect(tools.map(\.spec.name) == ["connector_tools", "connector_call"])
        #expect(tools.allSatisfy { $0.kind == .connector && $0.capability == .connectors && $0.risk(.null) == .safe })
    }

    @Test func theSpecsAreSmallAndGrowOnlyWithTheIndex() {
        let manager = MCPManager()
        let long = String(repeating: "descrição longa ", count: 20)
        let one = specChars(ConnectorGateway.tools(for: [config("GitHub", summary: long)], manager: manager))
        #expect(one <= 900 + 100)
        let twenty = (0..<20).map { config("Conector \($0) com nome comprido", summary: long) }
        let all = specChars(ConnectorGateway.tools(for: twenty, manager: manager))
        #expect(all <= 2_900, "\(all) characters")
        // Past twenty only the names are listed.
        let thirty = (0..<30).map { config("C\($0)", summary: long) }
        #expect(specChars(ConnectorGateway.tools(for: thirty, manager: manager)) <= 2_900)
    }

    @Test func theIndexIsSortedAndIdenticalByteForByte() {
        let configs = [config("Notion", summary: "Páginas."), config("github", summary: "Repositórios."), config("Arquivos")]
        let first = ConnectorGateway.index(for: configs)
        #expect(first == "- Arquivos\n- github: Repositórios\n- Notion: Páginas")
        #expect(ConnectorGateway.index(for: configs) == first)
        #expect(ConnectorGateway.index(for: configs.reversed()) == first)
        #expect(Array(first.utf8) == Array(ConnectorGateway.index(for: configs.shuffled()).utf8))
    }

    @Test func theSummaryIsTheFirstSentenceCutAtEightyCharacters() {
        let lines = ConnectorGateway.index(for: [
            config("A", summary: "Primeira frase. Segunda frase."),
            config("B", summary: String(repeating: "x", count: 200)),
            // A featured connector uses its catalog entry's text when it has none of its own.
            ConnectorTemplate.all.first { $0.id == "arquivos" }!.config,
        ]).split(separator: "\n").map(String.init)
        #expect(lines[0] == "- A: Primeira frase")
        #expect(lines[1] == "- Arquivos: Ler e organizar arquivos de uma pasta do Mac")
        #expect(lines[2] == "- B: " + String(repeating: "x", count: 79) + "…")
        #expect(lines.allSatisfy { $0.count <= ConnectorGateway.lineLimit })
    }

    @Test func pastTwentyConnectorsOnlyTheNamesFollow() {
        let configs = (0..<23).map { config(String(format: "C%02d", $0), summary: "Faz coisas.") }
        let lines = ConnectorGateway.index(for: configs).split(separator: "\n").map(String.init)
        #expect(lines.count == 21)
        #expect(lines[19] == "- C19: Faz coisas")
        #expect(lines[20] == "+3: C20, C21, C22")
    }

    @Test func theIndexDoesNotDependOnWhatTheServersOffer() async {
        let small = CatalogFixture(), big = CatalogFixture()
        defer { small.tearDown(); big.tearDown() }
        let github = config("GitHub", summary: "Repositórios.")
        await small.register([(github, CatalogFixture.catalog([CatalogFixture.tool("a")]))])
        await big.register([(github, CatalogFixture.catalog((0..<40).map { CatalogFixture.tool("t\($0)", "novo") }))])
        // The server now offers other tools: the model's tool list is the same, so the provider's cache still applies.
        let before = ConnectorGateway.tools(for: [github], manager: small.manager).map(\.spec)
        #expect(ConnectorGateway.tools(for: [github], manager: big.manager).map(\.spec) == before)

        // It changes only when a connector comes or goes.
        let notion = config("Notion")
        #expect(ConnectorGateway.tools(for: [github, notion], manager: small.manager).map(\.spec) != before)
        #expect(ConnectorGateway.tools(for: [notion], manager: small.manager).map(\.spec) != before)
    }

    // MARK: Listing

    @Test func theListingGivesNameDescriptionAndArguments() async throws {
        let fixture = CatalogFixture()
        defer { fixture.tearDown() }
        let github = config("GitHub")
        await fixture.register([(github, CatalogFixture.catalog([
            CatalogFixture.tool("create_issue", "Opens an issue.\nSecond line", schema: .schema(["title": .property("string")], required: ["title"])),
            CatalogFixture.tool("list_issues", String(repeating: "d", count: 400)),
        ]))])
        let tool = ConnectorToolsTool(connectors: [github], manager: fixture.manager)
        let context = ToolContext(workingDirectory: fixture.root)

        let all = try await tool.run(.object(["connector": .string("github")]), context: context)
        let blocks = all.components(separatedBy: "\n\n")
        #expect(blocks[0] == "create_issue — Opens an issue. Second line\nargs: " + CatalogFixture.tool("x", schema: .schema(["title": .property("string")], required: ["title"])).inputSchema.jsonString)
        #expect(blocks[1].hasPrefix("list_issues — " + String(repeating: "d", count: 299) + "…\nargs: "))

        let some = try await tool.run(.object(["connector": .string("GitHub"), "tools": .array([.string("list_issues"), .string("nope")])]), context: context)
        #expect(some.hasPrefix("list_issues — ") && !some.contains("create_issue") && some.hasSuffix("GitHub não tem: nope."))
        // It read the catalog: no server was started.
        #expect(await !fixture.manager.isRunning(github.id))
    }

    @Test func aHugeListingFallsBackToShorterAndAsksForTheArguments() {
        func tools(_ count: Int) -> ConnectorCatalog {
            CatalogFixture.catalog((0..<count).map {
                CatalogFixture.tool("tool_\($0)", String(repeating: "descrição ", count: 30),
                                    schema: .schema(["x": .property("string", String(repeating: "y", count: 80))]))
            })
        }
        let ask = "chame de novo com tools:[…] para ver os argumentos das que quiser."
        // Too much with arguments: a line each, no schemas.
        let lines = ConnectorGateway.render(tools(120), connector: "Grande")
        #expect(lines.count <= ToolOutputBudget.pageCharacters && !lines.contains("args:"))
        #expect(lines.contains("tool_119 — descrição descrição") && lines.hasSuffix(ask))
        // Far too much: the names.
        let names = ConnectorGateway.render(tools(400), connector: "Grande")
        #expect(names.count <= ToolOutputBudget.pageCharacters && names.contains("tool_399") && !names.contains("—") && names.hasSuffix(ask))
        // Asking for a few gives their arguments.
        let few = ConnectorGateway.render(tools(400), connector: "Grande", only: ["tool_3"])
        #expect(few.contains("args: ") && !few.contains("tool_4"))
        #expect(ConnectorGateway.render(CatalogFixture.catalog([]), connector: "Vazio") == "Vazio não oferece ferramentas.")
    }

    @Test func anUnknownConnectorListsTheOnesThatExist() async {
        let tool = ConnectorToolsTool(connectors: [config("GitHub"), config("Notion")], manager: MCPManager())
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        await #expect(throws: ToolError("Não existe o conector \"Slack\". Os disponíveis são: GitHub, Notion.")) {
            try await tool.run(.object(["connector": .string("Slack")]), context: context)
        }
        await #expect(throws: ToolError("Faltou o argumento \"connector\".")) { try await tool.run(.object([:]), context: context) }
    }

    // MARK: Resolving

    @Test func aCallBecomesTheRealToolWithTheInnerArguments() async throws {
        let fixture = CatalogFixture()
        defer { fixture.tearDown() }
        let github = config("GitHub")
        await fixture.register([(github, CatalogFixture.catalog([
            CatalogFixture.tool("create_issue", "Opens an issue.", annotations: MCPToolAnnotations(destructive: false)),
            CatalogFixture.tool("wipe", annotations: MCPToolAnnotations(destructive: true)),
        ]))])
        let gateway = ConnectorCallTool(connectors: [github], manager: fixture.manager)

        let call = JSONValue.object(["connector": .string("github"), "tool": .string("create_issue"),
                                     "arguments": .object(["title": .string("Oi")])])
        let resolved = try await gateway.resolve(call)
        #expect(resolved.tool.spec.name == "GitHub__create_issue" && resolved.tool.toolName == "create_issue")
        #expect(resolved.arguments == .object(["title": .string("Oi")]))
        #expect(resolved.tool.summary(resolved.arguments) == (title: "Usando GitHub", detail: #"create_issue {"title":"Oi"}"#))
        #expect(resolved.tool.serverID == github.id)
        // Arguments sent as JSON text, or left out, still work.
        let text = try await gateway.resolve(.object(["connector": .string("GitHub"), "tool": .string("create_issue"),
                                                      "arguments": .string(#"{"title":"A"}"#)]))
        #expect(text.arguments == .object(["title": .string("A")]))
        let none = try await gateway.resolve(.object(["connector": .string("GitHub"), "tool": .string("create_issue")]))
        #expect(none.arguments == .object([:]))
        // The tool's own annotations decide the risk, as for any connector tool.
        let wipe = try await gateway.resolve(.object(["connector": .string("GitHub"), "tool": .string("wipe")]))
        #expect(wipe.tool.danger(.null) != nil)
    }

    @Test func anUnknownToolOrConnectorComesBackWithTheWayOut() async throws {
        let fixture = CatalogFixture()
        defer { fixture.tearDown() }
        let github = config("GitHub"), fresh = config("Novo")
        await fixture.register([(github, CatalogFixture.catalog([CatalogFixture.tool("a")])), (fresh, nil)])
        let gateway = ConnectorCallTool(connectors: [github, fresh], manager: fixture.manager)
        let hint = ToolError("GitHub não tem a ferramenta b. Chame connector_tools(connector: \"GitHub\") para ver a lista.")
        await #expect(throws: hint) {
            try await gateway.resolve(.object(["connector": .string("GitHub"), "tool": .string("b"), "arguments": .object([:])]))
        }
        // Never listed (no catalog yet): the tool may exist, so it does not say it does not.
        await #expect(throws: ToolError("Ainda não sei as ferramentas de Novo. Chame connector_tools(connector: \"Novo\") primeiro.")) {
            try await gateway.resolve(.object(["connector": .string("Novo"), "tool": .string("a")]))
        }
        await #expect(throws: ToolError("Não existe o conector \"Slack\". Os disponíveis são: GitHub, Novo.")) {
            try await gateway.resolve(.object(["connector": .string("Slack"), "tool": .string("a")]))
        }
        await #expect(throws: ToolError("Faltou o argumento \"tool\".")) {
            try await gateway.resolve(.object(["connector": .string("GitHub")]))
        }
        // The tool itself never runs the call (it would skip the permission policy): it only says what is wrong.
        let context = ToolContext(workingDirectory: fixture.root)
        await #expect(throws: hint) {
            try await gateway.run(.object(["connector": .string("GitHub"), "tool": .string("b")]), context: context)
        }
        await #expect(throws: ToolError.self) {
            try await gateway.run(.object(["connector": .string("GitHub"), "tool": .string("a")]), context: context)
        }
    }
}

// MARK: - What the model is sent

struct ConnectorToolEconomyTests {
    @Test func threeBigConnectorsAddAFewHundredCharacters() async {
        let fixture = CatalogFixture()
        defer { fixture.tearDown() }
        let configs = ["GitHub", "Notion", "Slack"].map { MCPServerConfig(name: $0, command: "x") }
        let tools = (0..<40).map { CatalogFixture.tool("tool_\($0)", String(repeating: "Does something. ", count: 12)) }
        await fixture.register(configs.map { ($0, CatalogFixture.catalog(tools)) })
        let capabilities: Set<Capability> = [.terminal, .browser, .connectors]
        let base = ToolBox.offered(for: capabilities, accessibilityGranted: true)
        let turn = base + ConnectorGateway.tools(for: configs, manager: fixture.manager)
        #expect(specChars(turn) <= specChars(base) + 2_000)
        #expect(!turn.contains { $0.spec.name.contains("__") })
        // The built-in list is as before: the gateway is not in it, whatever the Orb can do.
        #expect(!ToolBox.all.contains { $0.spec.name.hasPrefix("connector_") })
    }
}

// MARK: - The permission policy sees the real tool

private actor Steps {
    private var steps: [[LLMEvent]]
    private(set) var toolLists: [[String]] = []
    init(_ steps: [[LLMEvent]]) { self.steps = steps }
    func next(_ tools: [ToolSpec]) -> [LLMEvent] {
        toolLists.append(tools.map(\.name))
        return steps.isEmpty ? [.text("fim")] : steps.removeFirst()
    }
}

private struct StepLLM: LLMClient {
    let steps: Steps
    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for event in await steps.next(tools) { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
    func models() async throws -> [String] { ["fake"] }
}

/// A server whose tools declare what they do, and that answers with what it was asked.
private let gatewayServer = #"""
import json, sys

tools = [
    {"name": "read", "description": "Reads a thing", "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}}},
     "annotations": {"readOnlyHint": True, "openWorldHint": False}},
    {"name": "write", "description": "Writes a thing", "inputSchema": {"type": "object"}},
    {"name": "wipe", "description": "Wipes everything", "inputSchema": {"type": "object"}, "annotations": {"destructiveHint": True}},
    {"name": "slow", "description": "Takes a while", "inputSchema": {"type": "object"}, "annotations": {"readOnlyHint": True}},
    {"name": "grow", "description": "Adds a tool", "inputSchema": {"type": "object"}},
    {"name": "die", "description": "Exits", "inputSchema": {"type": "object"}},
]

def send(message):
    sys.stdout.write(json.dumps(message) + "\n"); sys.stdout.flush()

for line in sys.stdin:
    message = json.loads(line)
    method, id = message.get("method"), message.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": id, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
              "serverInfo": {"name": "gh-fake", "version": "9"}, "instructions": "Use com cuidado."}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": id, "result": {"tools": tools}})
    elif method == "tools/call":
        name, args = message["params"]["name"], message["params"]["arguments"]
        if name == "die":
            sys.exit(3)
        if name == "slow":
            import time; time.sleep(1.2)
        if name == "grow":
            tools.append({"name": "extra", "description": "New", "inputSchema": {"type": "object"}})
        send({"jsonrpc": "2.0", "id": id, "result": {"content": [{"type": "text", "text": "ran:%s:%s" % (name, json.dumps(args, sort_keys=True))}]}})
        if name == "grow":
            send({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
    elif id is not None:
        send({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "nope"}})
"""#

private func gatewayConfig(name: String = "GitHub") throws -> MCPServerConfig {
    let directory = FileManager.default.temporaryDirectory.appending(path: "gateway-server-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appending(path: "server.py")
    try gatewayServer.write(to: script, atomically: true, encoding: .utf8)
    return MCPServerConfig(name: name, command: "/usr/bin/python3", arguments: [script.path])
}

@Suite(.enabled(if: hasPython))
struct ConnectorGatewayEngineTests {
    private func run(_ steps: [[LLMEvent]], mode: PermissionMode = .ask, rules: [PermissionRule] = [], config: MCPServerConfig,
                     manager: MCPManager, decision: ApprovalDecision = .once) async -> (events: [TurnEvent], steps: Steps) {
        await manager.sync([config])
        let script = Steps(steps)
        var bot = Bot(name: "Teste", role: "", orb: OrbConfig(), permissionMode: mode)
        bot.permissionRules = rules
        let request = TurnRequest(bot: bot, model: "fake", system: "sys", history: [], prompt: "oi",
                                  client: StepLLM(steps: script), tools: ConnectorGateway.tools(for: [config], manager: manager),
                                  context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory))
        let engine = AgentEngine()
        var events: [TurnEvent] = []
        for await event in engine.run(request) {
            events.append(event)
            if case .approval(let approval) = event { await engine.gate.resolve(approvalID: approval.id, decision: decision) }
        }
        return (events, script)
    }

    private func call(_ tool: String, _ arguments: String = "{}", connector: String = "GitHub") -> LLMEvent {
        .toolCalls([ToolCallRequest(id: "c1", name: "connector_call", arguments:
            #"{"connector":"\#(connector)","tool":"\#(tool)","arguments":\#(arguments)}"#)])
    }

    private func approvals(_ events: [TurnEvent]) -> [ApprovalRequest] {
        events.compactMap { if case .approval(let approval) = $0 { approval } else { nil } }
    }

    private func results(_ events: [TurnEvent]) -> [ChatMessage] {
        events.compactMap { if case .message(let message) = $0, message.role == .tool { message } else { nil } }
    }

    /// Lists the connector first, as the model is told to, so the catalog exists.
    private func listing(_ config: MCPServerConfig) -> LLMEvent {
        .toolCalls([ToolCallRequest(id: "l1", name: "connector_tools", arguments: #"{"connector":"\#(config.name)"}"#)])
    }

    @Test func aCallAsksAndRunsLikeTheDirectToolWouldHave() async throws {
        let manager = MCPManager(), config = try gatewayConfig()
        let (events, _) = await run([[listing(config)], [call("write", #"{"id":"7"}"#)], [.text("Feito")]], config: config, manager: manager)
        let cards = approvals(events)
        #expect(cards.count == 1 && cards[0].title == "Usando GitHub" && cards[0].command == #"write {"id":"7"}"#)
        let tool = results(events)
        #expect(tool.count == 2 && tool[1].content == #"ran:write:{"id": "7"}"#)
        // The history keeps the call the model made, not the one the engine ran.
        let assistant = events.compactMap { if case .message(let message) = $0, message.role == .assistant { message } else { nil } }
        #expect(assistant.flatMap(\.toolCalls).map(\.name) == ["connector_tools", "connector_call"])
        await manager.sync([])
    }

    @Test func theListingStartsTheServerAndSaysSo() async throws {
        let manager = MCPManager(), config = try gatewayConfig()
        let (events, _) = await run([[listing(config)], [.text("Ok")]], config: config, manager: manager)
        let statuses = events.compactMap { if case .status(let text) = $0 { text } else { nil } }
        // The line goes back to the tool's title once the server is up.
        let connecting = try #require(statuses.firstIndex(of: "Conectando a GitHub…"))
        #expect(statuses[(connecting + 1)...].first == "Vendo as ferramentas de GitHub")
        let listed = try #require(results(events).first?.content)
        #expect(listed.contains("read — Reads a thing\nargs: ") && listed.contains("wipe — Wipes everything"))
        #expect(await manager.catalog(config.id)?.instructions == "Use com cuidado.")
        // Asked again, the server is already there: no "Conectando".
        let second = await run([[listing(config)], [.text("Ok")]], config: config, manager: manager)
        #expect(!second.events.contains { if case .status(let text) = $0 { text.hasPrefix("Conectando") } else { false } })
        await manager.sync([])
    }

    @Test func aRuleSavedForTheDirectToolStillCoversTheCall() async throws {
        let manager = MCPManager(), config = try gatewayConfig()
        // "Usar write (github)", as a card of the direct tool offered it.
        let (events, _) = await run([[listing(config)], [call("write")], [.text("Ok")]],
                                    rules: [.connector("GitHub__write")], config: config, manager: manager)
        #expect(approvals(events).isEmpty)
        #expect(results(events).last?.content == "ran:write:{}")
        await manager.sync([])
    }

    @Test func aReadOnlyToolNeverAsksAndADestructiveOneAsksEvenInAutomatic() async throws {
        let manager = MCPManager(), config = try gatewayConfig()
        let reading = await run([[listing(config)], [call("read", #"{"id":"1"}"#)], [.text("Ok")]], config: config, manager: manager)
        #expect(approvals(reading.events).isEmpty && results(reading.events).last?.content == #"ran:read:{"id": "1"}"#)

        let wiping = await run([[call("wipe")], [.text("Ok")]], mode: .auto, config: config, manager: manager, decision: .deny)
        let card = try #require(approvals(wiping.events).first)
        #expect(card.isDangerous && card.reason.contains("destrutiva"))
        #expect(results(wiping.events).first?.isError == true)
        // "Sempre permitir" on the family does not cover it either.
        let covered = await run([[call("wipe")], [.text("Ok")]], mode: .ask, rules: [PermissionRule(family: .connector)],
                                config: config, manager: manager, decision: .deny)
        #expect(approvals(covered.events).count == 1)
        await manager.sync([])
    }

    @Test func aWrongCallComesBackAsAnErrorWithTheHint() async throws {
        let manager = MCPManager(), config = try gatewayConfig()
        let (events, _) = await run([[listing(config)], [call("nope")], [.text("Ok")]], config: config, manager: manager)
        let answer = try #require(results(events).last)
        #expect(answer.isError)
        #expect(answer.content.contains("GitHub não tem a ferramenta nope. Chame connector_tools(connector: \"GitHub\") para ver a lista."))
        #expect(approvals(events).isEmpty)
        await manager.sync([])
    }

    @Test func theToolListNeverChangesDuringTheTurn() async throws {
        let manager = MCPManager(), config = try gatewayConfig()
        let (_, script) = await run([[listing(config)], [call("read")], [.text("Ok")]], config: config, manager: manager)
        let lists = await script.toolLists
        #expect(lists.count == 3 && Set(lists).count == 1)
        #expect(lists[0] == ["connector_tools", "connector_call"])
        await manager.sync([])
    }
}

// MARK: - In the app: the Orb is offered the two tools, never the connector's own

@MainActor
@Suite(.enabled(if: hasPython))
struct ConnectorTurnTests {
    @Test func aSendOffersOnlyTheTwoFixedToolsAtEveryStep() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "gateway-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        let config = try gatewayConfig()
        model.connectors = [config]
        model.bots[0].capabilities = [.connectors]
        model.bots[0].workingDirectory = root.path
        let steps = Steps([[.toolCalls([ToolCallRequest(id: "a", name: "connector_tools", arguments: #"{"connector":"GitHub"}"#)])],
                           [.toolCalls([ToolCallRequest(id: "b", name: "connector_call", arguments: #"{"connector":"GitHub","tool":"read","arguments":{}}"#)])],
                           [.text("pronto")]])
        model.clientOverride = { StepLLM(steps: steps) }
        let bot = model.bots[0]
        #expect(model.send("oi", to: bot.id))
        await waitUntil("the turn to end") { await steps.toolLists.count >= 3 && !model.isWorking(bot.id) }

        let lists = await steps.toolLists
        #expect(lists.count == 3 && Set(lists).count == 1)
        #expect(lists[0].contains("connector_tools") && lists[0].contains("connector_call"))
        #expect(!lists.joined().contains { $0.contains("GitHub__") })
        // The index is in the description of the first one.
        let withoutConnectors = ToolBox.offered(for: [.connectors], accessibilityGranted: true).map(\.spec.name)
        #expect(Set(lists[0]) == Set(withoutConnectors + ["connector_tools", "connector_call"]))
        await model.mcp.sync([])
    }

    @Test func aConnectorSwitchedOffAtLaunchStillKnowsItsToolsWhenSwitchedOn() async throws {
        let fixture = CatalogFixture()
        defer { fixture.tearDown() }
        var github = MCPServerConfig(name: "GitHub", command: "x")
        github.isEnabled = false
        await fixture.register([(github, CatalogFixture.catalog([CatalogFixture.tool("a"), CatalogFixture.tool("b")]))])
        #expect(await fixture.manager.status() == [github.id: .stopped])
        #expect(await fixture.manager.catalog(github.id)?.tools.count == 2)
        github.isEnabled = true
        await fixture.manager.sync([github])
        #expect(await fixture.manager.status() == [github.id: .idle(toolCount: 2)])
    }

    @Test func claudeCodeReadsTheCatalogAndStartsNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "gateway-cc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        let github = MCPServerConfig(name: "GitHub", command: "orb-no-such-command-xyz"), new = MCPServerConfig(name: "Novo", command: "x")
        store.saveConnectorCatalog(CatalogFixture.catalog([
            CatalogFixture.tool("wipe", annotations: MCPToolAnnotations(destructive: true)),
            CatalogFixture.tool("read", annotations: MCPToolAnnotations(readOnly: true)),
        ]), for: github.id)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.connectors = [github, new]
        await waitUntil("the connectors to be registered") { await model.mcp.status().count == 2 }
        let names = ClaudeCodeTurn.mcpNames([github, new])
        let found = await model.connectorAnnotations(for: [github.id, new.id], cliNames: names)
        #expect(found.destructive == ["github__wipe": "o conector marcou esta ferramenta como destrutiva"])
        // A connector that never ran has no known tool, so every tool of it asks, as before.
        #expect(found.prefixes == ["github__", "novo__"])
        #expect(found.known == ["github__wipe", "github__read"])
        #expect(await model.mcp.status() == [github.id: .idle(toolCount: 2), new.id: .idle(toolCount: nil)])
    }
}

// MARK: - Servers that start when used and stop when idle

private actor StatusLog {
    private(set) var seen: [MCPStatus] = []
    func add(_ status: MCPStatus?) { if let status { seen.append(status) } }
}

@Suite(.enabled(if: hasPython))
struct MCPLazyTests {
    private func manager(store: Store? = nil, idle: Duration = .seconds(600)) -> MCPManager {
        MCPManager(store: store, idleLimit: idle, sweepInterval: .milliseconds(40))
    }

    @Test func syncStartsNothingAndTheFirstCallStartsTheServer() async throws {
        let manager = manager(), config = try gatewayConfig()
        await manager.sync([config])
        #expect(await manager.status() == [config.id: .idle(toolCount: nil)])
        #expect(await !manager.isRunning(config.id))

        #expect(try await manager.call(config.id, tool: "read", arguments: .object(["id": .string("1")])) == #"ran:read:{"id": "1"}"#)
        #expect(await manager.isRunning(config.id))
        #expect(await manager.status() == [config.id: .ready(toolCount: 6)])
        await manager.sync([])
    }

    @Test func callsThatArriveTogetherShareOneStart() async throws {
        let manager = manager(), config = try gatewayConfig()
        await manager.sync([config])
        let connections = try await withThrowingTaskGroup(of: MCPConnection.self) { group in
            for _ in 0..<4 { group.addTask { try await manager.ensureStarted(config.id) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(connections.count == 4 && connections.allSatisfy { $0 === connections[0] })
        await manager.sync([])
    }

    @Test func theSweeperStopsAServerNobodyUsesAndTheNextCallStartsItAgain() async throws {
        let manager = manager(idle: .milliseconds(250)), config = try gatewayConfig()
        let log = StatusLog()
        await manager.observe { statuses in Task { await log.add(statuses.values.first) } }
        await manager.sync([config])
        _ = try await manager.call(config.id, tool: "read", arguments: .null)
        let first = try await manager.ensureStarted(config.id)
        await waitUntil("the idle server to be stopped") { await manager.status()[config.id] == .idle(toolCount: 6) }
        #expect(await !manager.isRunning(config.id))
        #expect(await !first.isRunning)

        #expect(try await manager.call(config.id, tool: "read", arguments: .null) == "ran:read:{}")
        #expect(try await manager.ensureStarted(config.id) !== first)
        // idle → starting → ready → idle → starting → ready.
        await waitUntil("the statuses to be heard") { await log.seen.contains(.ready(toolCount: 6)) }
        // The log hears each change through its own task, so the order it records is not the order of the changes:
        // what matters is that the server went through each state.
        let seen = await log.seen
        #expect(seen.contains(.idle(toolCount: nil)) && seen.contains(.starting))
        #expect(seen.contains(.ready(toolCount: 6)) && seen.contains(.idle(toolCount: 6)))
        await manager.sync([])
    }

    @Test func aServerWithACallInFlightIsNeverStopped() async throws {
        let manager = manager(idle: .milliseconds(150)), config = try gatewayConfig()
        await manager.sync([config])
        // "slow" takes over a second: several sweeps and the whole idle limit pass meanwhile.
        let slow = Task { try await manager.call(config.id, tool: "slow", arguments: .null) }
        try await Task.sleep(for: .milliseconds(700))
        #expect(await manager.isRunning(config.id))
        #expect(try await slow.value == "ran:slow:{}")
        await waitUntil("the server to be stopped once the call is over") { await !manager.isRunning(config.id) }
        await manager.sync([])
    }

    @Test func aServerThatDiesIsStartedAgainByTheNextCall() async throws {
        let manager = manager(), config = try gatewayConfig()
        await manager.sync([config])
        await #expect(throws: ToolError.self) { try await manager.call(config.id, tool: "die", arguments: .null) }
        await waitUntil("the manager to notice") { await manager.status()[config.id] == .idle(toolCount: 6) }
        #expect(try await manager.call(config.id, tool: "read", arguments: .null) == "ran:read:{}")
        await manager.sync([])
    }

    @Test func aChangeInTheServersToolsRefreshesTheCatalog() async throws {
        let manager = manager(), config = try gatewayConfig()
        await manager.sync([config])
        _ = try await manager.call(config.id, tool: "read", arguments: .null)
        #expect(await manager.catalog(config.id)?.tools.count == 6)
        _ = try await manager.call(config.id, tool: "grow", arguments: .null)
        await waitUntil("the catalog to follow the notification") { await manager.catalog(config.id)?.tools.count == 7 }
        #expect(await manager.status()[config.id] == .ready(toolCount: 7))
        await manager.sync([])
    }

    @Test func theCatalogIsWrittenReadAndForgotten() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lazy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root), config = try gatewayConfig()
        let first = manager(store: store)
        await first.sync([config])
        _ = try await first.test(config.id)
        store.flush()
        let file = root.appending(path: "conectores/\(config.id.uuidString).json")
        let json = try String(contentsOf: file, encoding: .utf8)
        #expect(json.contains("gh-fake") && json.contains("Use com cuidado.") && json.contains("destructiveHint") == false)
        #expect(!json.contains(config.command) && !json.contains(config.arguments[0]))

        // Another run of the app: the card knows the tools before anything starts.
        let second = manager(store: store)
        await second.sync([config])
        #expect(await second.status() == [config.id: .idle(toolCount: 6)])
        let catalog = try #require(await second.catalog(config.id))
        #expect(catalog.serverName == "gh-fake" && catalog.instructions == "Use com cuidado.")
        #expect(catalog.tools.first { $0.name == "wipe" }?.annotations.destructive == true)
        #expect(catalog.tools.first { $0.name == "read" }?.annotations == MCPToolAnnotations(readOnly: true, openWorld: false))

        // Switching it off keeps it; removing the connector deletes it.
        var off = config
        off.isEnabled = false
        await second.sync([off])
        store.flush()
        #expect(FileManager.default.fileExists(atPath: file.path))
        await second.sync([])
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        await first.sync([])
    }

    /// A call that ends after the connector was edited must not leave the new registration counting a call that is not
    /// there, or the sweeper would never stop its server.
    @Test func aCallThatEndsAfterAnEditDoesNotBlockTheSweeper() async throws {
        let manager = manager(idle: .milliseconds(150)), config = try gatewayConfig()
        await manager.sync([config])
        let slow = Task { try await manager.call(config.id, tool: "slow", arguments: .null) }
        try await Task.sleep(for: .milliseconds(300))
        var edited = config
        edited.environment["X"] = "1"
        await manager.sync([edited])
        _ = try? await slow.value
        _ = try await manager.ensureStarted(edited.id)
        await waitUntil("the new server to be stopped for being idle") { await !manager.isRunning(edited.id) }
        await manager.sync([])
    }

    @Test func anEditedConnectorIsStoppedAndForgotten() async throws {
        let manager = manager(), config = try gatewayConfig()
        await manager.sync([config])
        let connection = try await manager.ensureStarted(config.id)
        var edited = config
        edited.environment["X"] = "1"
        await manager.sync([edited])
        #expect(await !connection.isRunning)
        #expect(await manager.catalog(config.id) == nil)
        #expect(await manager.status() == [config.id: .idle(toolCount: nil)])
        await manager.sync([])
    }
}

// MARK: - Old catalogs are renewed in the background

@Suite(.enabled(if: hasPython))
struct CatalogRenewalTests {
    @Test @MainActor func aStaleCatalogIsListedAgainWithoutHoldingTheTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "renewal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root), config = try gatewayConfig()
        var old = CatalogFixture.catalog([CatalogFixture.tool("only")])
        old.updatedAt = .now.addingTimeInterval(-3 * 24 * 3600)
        store.saveConnectorCatalog(old, for: config.id)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.connectors = [config]
        await waitUntil("the connector to be registered") { await model.mcp.status().count == 1 }
        // Off in tests unless asked for.
        model.renewOldCatalogs(of: [config.id])
        try await Task.sleep(for: .milliseconds(200))
        #expect(await model.mcp.catalog(config.id)?.tools.count == 1)
        model.renewsCatalogs = true
        model.renewOldCatalogs(of: [config.id])
        await waitUntil("the catalog to be renewed") { await model.mcp.catalog(config.id)?.tools.count == 6 }
        await model.mcp.sync([])
    }

    @Test @MainActor func aFreshCatalogIsLeftAlone() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "renewal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root), config = try gatewayConfig()
        store.saveConnectorCatalog(CatalogFixture.catalog([CatalogFixture.tool("only")]), for: config.id)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.renewsCatalogs = true
        model.connectors = [config]
        await waitUntil("the connector to be registered") { await model.mcp.status().count == 1 }
        model.renewOldCatalogs(of: [config.id])
        try await Task.sleep(for: .milliseconds(300))
        #expect(await model.mcp.catalog(config.id)?.tools.count == 1)
        #expect(await !model.mcp.isRunning(config.id))
    }
}
