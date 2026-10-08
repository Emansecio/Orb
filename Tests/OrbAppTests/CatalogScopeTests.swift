import Foundation
import Testing
@testable import Orb

private let hasPython = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

/// A server with `count` tools, written to a temporary folder.
private func fakeServer(name: String, count: Int, environment: [String: String] = [:], delay: Int = 0) throws -> MCPServerConfig {
    let script = """
    import json, sys, time
    def send(m): sys.stdout.write(json.dumps(m) + "\\n"); sys.stdout.flush()
    for line in sys.stdin:
        m = json.loads(line); method, id = m.get("method"), m.get("id")
        if method == "initialize":
            time.sleep(\(delay))
            send({"jsonrpc":"2.0","id":id,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"f","version":"0"}}})
        elif method == "tools/list":
            send({"jsonrpc":"2.0","id":id,"result":{"tools":[{"name":"t%d" % i,"inputSchema":{"type":"object"}} for i in range(\(count))]}})
        elif id is not None:
            send({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"nope"}})
    """
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scope-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("server.py")
    try script.write(to: path, atomically: true, encoding: .utf8)
    return MCPServerConfig(name: name, command: "/usr/bin/python3", arguments: [path.path], environment: environment)
}

// MARK: - Per-Orb scope

struct OrbScopeModelTests {
    @Test func olderFilesMeanEveryOrb() throws {
        let connector = try JSONDecoder().decode(MCPServerConfig.self, from: Data(#"{"name":"Antigo","command":"npx"}"#.utf8))
        #expect(connector.orbIDs == nil && connector.isForAllOrbs && connector.secretKeys.isEmpty)
        #expect(connector.isAvailable(to: UUID()))
        let skill = try JSONDecoder().decode(Skill.self, from: Data(#"{"slug":"a","name":"A","instructions":"x"}"#.utf8))
        #expect(skill.orbIDs == nil && skill.isAvailable(to: UUID()))
    }

    @Test func scopeSurvivesEncoding() throws {
        let (a, b) = (UUID(), UUID())
        var connector = MCPServerConfig(name: "GitHub", url: "https://x")
        connector.orbIDs = [a]
        connector.secretKeys = ["Authorization"]
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: JSONEncoder().encode(connector))
        #expect(decoded == connector)
        #expect(decoded.isAvailable(to: a) && !decoded.isAvailable(to: b))

        var skill = Skill(slug: "s", name: "S", summary: "", instructions: "i")
        skill.orbIDs = [b]
        let again = try JSONDecoder().decode(Skill.self, from: JSONEncoder().encode(skill))
        #expect(again.orbIDs == [b])
        // Everyone is nil, which is not written at all.
        skill.orbIDs = nil
        #expect(!String(decoding: try JSONEncoder().encode(skill), as: UTF8.self).contains("orbIDs"))
    }

    @Test func aBadScopeFallsBackToEveryOrb() throws {
        let connector = try JSONDecoder().decode(MCPServerConfig.self, from: Data(#"{"name":"X","orbIDs":"não é lista"}"#.utf8))
        #expect(connector.orbIDs == nil)
    }

    @Test func togglingOneOrbOutOfEveryone() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        let all = [a, b, c]
        #expect(AppModel.toggled(nil, botID: b, on: false, allBots: all) == [a, c])
        #expect(AppModel.toggled(nil, botID: b, on: true, allBots: all) == nil)
        #expect(AppModel.toggled([a], botID: c, on: true, allBots: all) == [a, c])
        #expect(AppModel.toggled([a, c], botID: a, on: false, allBots: all) == [c])
    }

    @Test func scopeReadsInPortuguese() {
        let lia = Bot(name: "Lia", role: "", orb: OrbConfig()), atlas = Bot(name: "Atlas", role: "", orb: OrbConfig())
        let rex = Bot(name: "Rex", role: "", orb: OrbConfig())
        let bots = [atlas, lia, rex]
        #expect(OrbScopeText.summary(orbIDs: nil, bots: bots) == "Todos os Orbs")
        #expect(OrbScopeText.summary(orbIDs: [lia.id], bots: bots) == "Só Lia")
        #expect(OrbScopeText.summary(orbIDs: [lia.id, atlas.id], bots: bots) == "Só Atlas e Lia")
        #expect(OrbScopeText.summary(orbIDs: [UUID()], bots: bots) == "Nenhum Orb")
        #expect(OrbScopeText.list(["Atlas", "Lia", "Rex"]) == "Atlas, Lia e mais 1")
        #expect(OrbScopeText.list(["Atlas"]) == "Atlas")
    }
}

@Suite final class OrbScopeAppTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbScope-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: root) }

    @MainActor private func model(vault: any SecretVault = MemoryVault()) -> AppModel {
        var state = AppState.initial
        state.bots.append(Bot(name: "Lia", role: "", orb: OrbConfig()))
        Store(directory: root).save(state)
        return AppModel(store: Store(directory: root), runsBackgroundWork: false, secretVault: vault)
    }

    @Test @MainActor func skillsAndConnectorsFollowTheScope() {
        let model = model()
        let (atlas, lia) = (model.bots[0].id, model.bots[1].id)
        model.skills = [Skill(slug: "todos", name: "Todos", summary: "", instructions: "i"),
                        Skill(slug: "so-lia", name: "Só Lia", summary: "", instructions: "i", orbIDs: [lia]),
                        Skill(slug: "off", name: "Off", summary: "", instructions: "i", isEnabled: false)]
        #expect(model.skills(for: atlas).map(\.slug) == ["todos"])
        #expect(model.skills(for: lia).map(\.slug) == ["todos", "so-lia"])

        model.connectors = [MCPServerConfig(name: "A", command: "x"),
                            MCPServerConfig(name: "B", command: "x", isEnabled: true, orbIDs: [atlas]),
                            MCPServerConfig(name: "C", command: "x", isEnabled: false)]
        #expect(model.connectors(for: atlas).map(\.name) == ["A", "B"])
        #expect(model.connectors(for: lia).map(\.name) == ["A"])
    }

    @Test @MainActor func connectorNamesNeedTheOrbsSwitch() {
        let model = model()
        let atlas = model.bots[0].id
        model.connectors = [MCPServerConfig(name: "GitHub", command: "x")]
        model.bots[0].capabilities.remove(.connectors)
        #expect(model.connectorNames(for: atlas).isEmpty)
        model.bots[0].capabilities.insert(.connectors)
        #expect(model.connectorNames(for: atlas) == ["GitHub"])
        #expect(model.orbsUsing(model.connectors[0]).map(\.name) == ["Atlas"])
        model.connectors[0].isEnabled = false
        #expect(model.orbsUsing(model.connectors[0]).isEmpty)
    }

    @Test @MainActor func choosingAnOrbTurnsItsConnectorsSwitchOn() {
        let model = model()
        let lia = model.bots[1].id
        model.connectors = [MCPServerConfig(name: "GitHub", command: "x", orbIDs: [model.bots[0].id])]
        #expect(!model.bots[1].capabilities.contains(.connectors))
        model.setConnector(model.connectors[0].id, enabled: true, for: lia)
        #expect(model.connectors[0].orbIDs == [model.bots[0].id, lia])
        #expect(model.bots[1].capabilities.contains(.connectors))
        model.setConnector(model.connectors[0].id, enabled: false, for: lia)
        #expect(model.connectors[0].orbIDs == [model.bots[0].id])
    }

    @Test @MainActor func claudeCodeGetsOnlyTheOrbsConnectors() {
        let model = model()
        let (atlas, lia) = (model.bots[0], model.bots[1])
        model.connectors = [MCPServerConfig(name: "Para todos", command: "x"),
                            MCPServerConfig(name: "Só Atlas", command: "x", orbIDs: [atlas.id]),
                            MCPServerConfig(name: "Desligado", command: "x", isEnabled: false)]
        model.bots[0].capabilities.insert(.connectors)
        model.bots[1].capabilities.insert(.connectors)
        #expect(model.connectorServers(for: model.bots[0]).map(\.name) == ["Para todos", "Só Atlas"])
        #expect(model.connectorServers(for: model.bots[1]).map(\.name) == ["Para todos"])
        // What `--mcp-config` carries for Lia has no trace of Atlas's connector.
        let json = ClaudeCodeTurn.mcpConfig(model.connectorServers(for: model.bots[1]))?.jsonString ?? ""
        #expect(json.contains("para-todos") && !json.contains("so-atlas") && !json.contains("desligado"))
        // With the Orb's switch off it gets none.
        model.bots[1].capabilities.remove(.connectors)
        #expect(model.connectorServers(for: model.bots[1]).isEmpty)
        #expect(lia.id == model.bots[1].id && atlas.id == model.bots[0].id)
    }

    @Test @MainActor func aNewConnectorNeverDefaultsToADeletedOrb() {
        let model = model()
        let (atlas, lia) = (model.bots[0].id, model.bots[1].id)
        model.selection = .bot(lia)
        #expect(model.defaultScopeForNewConnector() == [lia])
        model.selection = .connectors
        model.deleteBot(lia)
        #expect(model.lastSelectedBotID == nil)
        #expect(model.defaultScopeForNewConnector() == nil)
        model.selection = .bot(atlas)
        #expect(model.defaultScopeForNewConnector() == [atlas])
    }

    @Test @MainActor func turningOnAnOrbWarnsAboutTheOtherConnectorsItGains() {
        let model = model()
        let (atlas, lia) = (model.bots[0].id, model.bots[1].id)
        model.bots[0].capabilities.insert(.connectors)
        model.bots[1].capabilities.remove(.connectors)
        let github = MCPServerConfig(name: "GitHub", url: "https://x", orbIDs: [lia])
        model.connectors = [MCPServerConfig(name: "Arquivos", command: "x"), MCPServerConfig(name: "Memória", command: "x"),
                            MCPServerConfig(name: "Desligado", command: "x", isEnabled: false), github]
        let extra = model.extraConnectorAccess(ifEnabledFor: [lia], besides: github.id)
        #expect(extra.map(\.bot.name) == ["Lia"] && extra.first?.connectors == ["Arquivos", "Memória"])
        #expect(OrbScopeText.extraAccess(extra) == "“Conectores” está desligado em Lia. Ao ligar, o Orb também passa a usar Arquivos e Memória, que já estão instalados.")
        // Atlas already has the switch on: nothing changes for it. No other connector: no warning.
        #expect(model.extraConnectorAccess(ifEnabledFor: [atlas], besides: github.id).isEmpty)
        model.connectors = [github]
        #expect(model.extraConnectorAccess(ifEnabledFor: [lia], besides: github.id).isEmpty)
        #expect(OrbScopeText.extraAccess([]) == nil)
    }

    @Test @MainActor func usingASkillOpensTheChatWithTheShortcut() {
        let model = model()
        let lia = model.bots[1].id
        let skill = Skill(slug: "resumir", name: "Resumir", summary: "", instructions: "i")
        model.selection = .bot(lia)
        model.selection = .skills
        #expect(model.preferredBot(for: skill)?.id == lia)
        model.drafts[lia] = "o texto abaixo"
        model.useSkill(skill, with: lia)
        #expect(model.drafts[lia] == "/resumir o texto abaixo")
        #expect(model.selection == .bot(lia))
        // Only an Orb that may use the skill is offered.
        var scoped = skill
        scoped.orbIDs = [model.bots[0].id]
        #expect(model.preferredBot(for: scoped) == nil)
    }

    @Test func draftReplacesAShortcutAlreadyThere() {
        #expect(AppModel.draft(inserting: "resumir", into: "") == "/resumir ")
        #expect(AppModel.draft(inserting: "resumir", into: "  oi  ") == "/resumir oi")
        #expect(AppModel.draft(inserting: "resumir", into: "/organizar a pasta") == "/resumir a pasta")
    }

    @Test @MainActor func sendOffersOnlyTheOrbsOwnSkills() {
        let model = model()
        let (atlas, lia) = (model.bots[0].id, model.bots[1].id)
        model.skills = [Skill(slug: "so-lia", name: "Só Lia", summary: "", instructions: "Faça X", orbIDs: [lia])]
        #expect(SystemPrompt.expandSkill(in: "/so-lia oi", skills: model.skills(for: lia)) != nil)
        #expect(SystemPrompt.expandSkill(in: "/so-lia oi", skills: model.skills(for: atlas)) == nil)
    }
}

// MARK: - Which connector tools an Orb gets

@Suite(.enabled(if: hasPython))
struct ConnectorToolFilteringTests {
    @Test func managerOffersOnlyTheAllowedServers() async throws {
        let manager = MCPManager()
        let a = try fakeServer(name: "Alfa", count: 2), b = try fakeServer(name: "Beta", count: 3)
        await manager.sync([a, b])
        #expect(await manager.tools().count == 5)
        let onlyA = await manager.tools(allowing: [a.id]).compactMap { $0 as? MCPTool }
        #expect(onlyA.count == 2 && onlyA.allSatisfy { $0.serverID == a.id })
        #expect(await manager.tools(allowing: []).isEmpty)
    }

    @Test func changingTheScopeDoesNotRestartTheServer() async throws {
        let manager = MCPManager()
        var config = try fakeServer(name: "Alfa", count: 1)
        await manager.sync([config])
        let before = try #require(await manager.tools().first as? MCPTool).connection
        config.orbIDs = [UUID()]
        await manager.sync([config])
        #expect(try #require(await manager.tools().first as? MCPTool).connection === before)
        config.environment["X"] = "1"
        await manager.sync([config])
        #expect(try #require(await manager.tools().first as? MCPTool).connection !== before)
    }

    @Test @MainActor func connectAndWaitReportsTheOutcome() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbScope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        let good = try fakeServer(name: "Bom", count: 4)
        let broken = MCPServerConfig(name: "Quebrado", command: "orb-no-such-command-xyz")
        model.connectors = [good, broken]
        #expect(await model.connectAndWait(good.id) == .ready(toolCount: 4))
        guard case .failed? = await model.connectAndWait(broken.id) else { Issue.record("expected failure"); return }
    }

    /// The CLI starts its own connections, so a connector the app's own failed to list (or has not finished starting)
    /// must come out as "unverified" rather than as "nothing destructive".
    @Test @MainActor func connectorsTheAppCouldNotListAreUnverifiedForClaudeCode() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbScope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        let good = try fakeServer(name: "Bom", count: 2)
        let broken = MCPServerConfig(name: "Calendário", command: "orb-no-such-command-xyz")
        let slow = try fakeServer(name: "Lento", count: 1, delay: 5)
        model.connectors = [good, broken, slow]
        let names = ClaudeCodeTurn.mcpNames([good, broken, slow])
        // The quick ones have settled (listed, failed); only the slow one is still starting when the turn asks.
        #expect(await model.connectAndWait(good.id) == .ready(toolCount: 2))
        guard case .failed? = await model.connectAndWait(broken.id) else { Issue.record("expected failure"); return }
        let found = await model.connectorAnnotations(for: [good.id, broken.id, slow.id], cliNames: names, timeout: .seconds(1))
        #expect(found.unverified == ["calend_rio__", "lento__"])
        #expect(found.destructive.isEmpty)
        #expect(await model.connectorAnnotations(for: [], cliNames: names).unverified.isEmpty)
    }

    @Test @MainActor func connectAndWaitDoesNotWaitForASlowNeighbour() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbScope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        let slow = try fakeServer(name: "Lento", count: 1, delay: 5)
        let quick = try fakeServer(name: "Rápido", count: 2)
        model.connectors = [slow, quick]
        let start = ContinuousClock.now
        #expect(await model.connectAndWait(quick.id) == .ready(toolCount: 2))
        #expect(ContinuousClock.now - start < .seconds(4), "the quick connector waited for the slow one")
        if case .ready? = model.connectorStatus[slow.id] { Issue.record("the slow one should still be starting") }
    }
}

struct ConnectorLoadTests {
    private func bot(_ name: String, connectors: Bool = true) -> Bot {
        var bot = Bot(name: name, role: "", orb: OrbConfig())
        if connectors { bot.capabilities.insert(.connectors) }
        return bot
    }

    @Test func countsOnlyWhatTheOrbReceives() {
        let atlas = bot("Atlas"), lia = bot("Lia", connectors: false)
        let big = MCPServerConfig(name: "Grande", command: "x")
        var mine = MCPServerConfig(name: "Meu", command: "x")
        mine.orbIDs = [lia.id]
        var off = MCPServerConfig(name: "Off", command: "x")
        off.isEnabled = false
        let status: [UUID: MCPStatus] = [big.id: .ready(toolCount: 30), mine.id: .ready(toolCount: 20), off.id: .ready(toolCount: 9)]
        let configs = [big, mine, off]
        #expect(ConnectorLoad.toolCount(for: atlas, connectors: configs, status: status) == 30)
        #expect(ConnectorLoad.toolCount(for: lia, connectors: configs, status: status) == 0)
        #expect(ConnectorLoad.heaviest(bots: [atlas, lia], connectors: configs, status: status) == nil)

        var more = big
        more.id = UUID()
        let heavy = ConnectorLoad.heaviest(bots: [atlas, lia], connectors: configs + [more], status: status.merging([more.id: .ready(toolCount: 15)]) { $1 })
        #expect(heavy?.bot.name == "Atlas" && heavy?.count == 45)
        #expect(heavy.map(ConnectorLoad.warning)?.contains("45 ferramentas") == true)
    }

    @Test func errorsReadShort() {
        #expect(ConnectorStatusText.shortError("Não foi possível iniciar o conector GitHub: HTTP 401\nmais detalhe") == "HTTP 401")
        #expect(ConnectorStatusText.shortError("Não foi possível conectar ao conector Slack: Could not connect") == "Could not connect")
        #expect(ConnectorStatusText.shortError("   \n ") == "Sem detalhes.")
        let long = ConnectorStatusText.shortError(String(repeating: "a", count: 300), limit: 50)
        #expect(long.count == 51 && long.hasSuffix("…"))
        #expect(ConnectorStatusText.toolsAvailable(12) == "12 ferramentas disponíveis")
        #expect(ConnectorStatusText.toolsAvailable(1) == "1 ferramenta disponível")
        #expect(ConnectorStatusText.toolsAvailable(0).contains("não oferece"))
    }

    @Test func folderArgumentIsEdited() {
        let text = "-y\n@scope/server-filesystem\n/Users/x"
        #expect(ConnectorArguments.line(2, in: text) == "/Users/x")
        #expect(ConnectorArguments.replacing(line: 2, with: "/tmp/p", in: text) == "-y\n@scope/server-filesystem\n/tmp/p")
        #expect(ConnectorArguments.replacing(line: 1, with: "a", in: "") == "\na")
        #expect(ConnectorArguments.line(5, in: text) == "")
    }
}

struct ConnectorEditingTests {
    @Test func editingATemplateConnectorKeepsItsGuidedForm() throws {
        var config = try #require(ConnectorTemplate.all.first { $0.id == "arquivos" }).config.withNewID()
        config.arguments[2] = "/Users/x/Projetos"
        let draft = ConnectorDraft(editing: config)
        #expect(draft.isGuided && draft.folderArgumentIndex == 2 && !draft.summary.isEmpty)
        #expect(draft.config.arguments[2] == "/Users/x/Projetos")

        var github = try #require(ConnectorTemplate.all.first { $0.id == "github" }).config.withNewID()
        github.headers["Authorization"] = "Bearer ghp_x"
        let guided = ConnectorDraft(editing: github)
        #expect(guided.inputs.map(\.name) == ["Authorization"] && guided.inputs.first?.prefix == "Bearer " && guided.helpURL != nil)
    }

    @Test func editingARegistryConnectorRebuildsItsFields() {
        var config = MCPServerConfig(name: "Exemplo", url: "https://example.com/mcp", headers: ["Authorization": "Bearer abc", "X-Region": "eu"])
        config.source = "io.modelcontextprotocol/example"
        config.secretKeys = ["Authorization"]
        let draft = ConnectorDraft(editing: config)
        #expect(draft.isGuided && draft.isOfficial)
        let byName = Dictionary(uniqueKeysWithValues: draft.inputs.map { ($0.name, $0) })
        #expect(byName["Authorization"]?.isSecret == true && byName["Authorization"]?.prefix == "Bearer ")
        #expect(byName["X-Region"]?.isSecret == false && byName["X-Region"]?.prefix == "")
    }

    @Test func aHandMadeConnectorStaysManual() {
        let draft = ConnectorDraft(editing: MCPServerConfig(name: "Meu", command: "/bin/servidor"))
        #expect(!draft.isGuided && draft.inputs.isEmpty)
    }

    @Test func onlySecretsCountAsKeys() throws {
        let slack = try #require(ConnectorTemplate.all.first { $0.id == "slack" })
        #expect(slack.badges == ["Pede 1 chave"] && slack.needsKey)
        #expect(slack.inputs.filter { !$0.isSecret }.map(\.name) == ["SLACK_TEAM_ID"])
    }
}

struct ConnectorTemplateTests {
    @Test func everyTemplateIsConsistent() {
        let all = ConnectorTemplate.all
        #expect(Set(all.map(\.id)).count == all.count)
        for template in all {
            #expect(!template.summary.isEmpty)
            let values = Set(template.config.environment.keys).union(template.config.headers.keys)
            for input in template.inputs {
                #expect(values.contains(input.name), "\(template.id): \(input.name) has no slot")
                if input.isSecret { #expect(template.config.secretKeys.contains(input.name)) }
            }
            if let index = template.folderArgumentIndex { #expect(index < template.config.arguments.count) }
        }
        #expect(all.first { $0.id == "arquivos" }?.folderArgumentIndex == 2)
        #expect(all.first { $0.id == "arquivos" }?.badges == ["Sem chave"])
        #expect(all.first { $0.id == "github" }?.badges == ["Pede 1 chave", "Remoto"])
        #expect(all.first { $0.id == "slack" }?.badges == ["Pede 1 chave"])
        #expect(MCPServerConfig.templates.count == all.count)
    }

    @Test func categoriesFilter() {
        let code = ConnectorTemplate.all.filter { $0.matches(.code) }
        #expect(code.map(\.id) == ["github"])
        #expect(ConnectorTemplate.all.filter { $0.matches(nil) }.count == ConnectorTemplate.all.count)
    }

    @Test func registryHeadersKeepTheirPrefixAndSecrecy() throws {
        let json = try #require(JSONValue.parse("""
        {"name": "com.example/remote",
         "remotes": [{"type": "streamable-http", "url": "https://example.com/mcp",
                      "headers": [{"name": "Authorization", "value": "Bearer {token}", "isSecret": true, "isRequired": true},
                                  {"name": "X-Region", "value": "eu"}]}]}
        """))
        let server = try #require(MCPRegistry.server(from: json))
        #expect(server.inputs.first?.prefix == "Bearer ")
        #expect(server.inputs.last?.prefix == "")
        #expect(server.config.secretKeys == ["Authorization"])
    }
}

struct SkillSlugTests {
    @Test func cleanSlugTrimsAndCollapses() {
        #expect(Skill.cleanSlug("Resumir texto!") == "resumir-texto")
        #expect(Skill.cleanSlug("  Revisão — rápida  ") == "revisao-rapida")
        #expect(Skill.cleanSlug("!!!") == "")
        #expect(Skill.cleanSlug("a".padding(toLength: 40, withPad: "a", startingAt: 0)).count == 32)
    }

    @Test func slugFollowsTheNameUntilEdited() {
        #expect(Skill.suggestedSlug(forName: "Planejar a semana", current: "", edited: false) == "planejar-a-semana")
        #expect(Skill.suggestedSlug(forName: "Planejar a semana", current: "agenda", edited: true) == "agenda")
        #expect(Skill.suggestedSlug(forName: "", current: "x", edited: false) == "")
    }
}

// MARK: - Secrets in the Keychain

@MainActor
struct ConnectorSecretsTests {
    private func github(token: String = "ghp_segredo") -> MCPServerConfig {
        var config = MCPServerConfig(name: "GitHub", url: "https://x/mcp", headers: ["Authorization": "Bearer \(token)", "X-Region": "eu"])
        config.secretKeys = ["Authorization"]
        return config
    }

    @Test func detectsSecretNames() {
        for name in ["GITHUB_TOKEN", "api_key", "Authorization", "X-Api-Key", "DB_PASSWORD", "CLIENT_SECRET", "Cookie"] {
            #expect(ConnectorSecrets.looksSecret(name), "\(name)")
        }
        for name in ["SLACK_TEAM_ID", "PATH", "X-Region", "LANG"] { #expect(!ConnectorSecrets.looksSecret(name), "\(name)") }
        var config = MCPServerConfig(name: "x", command: "c", environment: ["SLACK_TEAM_ID": "T1", "ZETA": "v"])
        config.secretKeys = ["ZETA"]
        #expect(ConnectorSecrets.secretNames(of: config) == ["ZETA"])
    }

    @Test func redactMovesSecretsToTheVaultAndResolveBringsThemBack() {
        let vault = MemoryVault()
        let secrets = ConnectorSecrets(vault: vault)
        let config = github()
        let saved = secrets.redact([config])
        #expect(saved[0].headers["Authorization"] == ConnectorSecrets.marker)
        #expect(saved[0].headers["X-Region"] == "eu")
        #expect(vault.get(ConnectorSecrets.account(id: config.id, name: "Authorization")) == "Bearer ghp_segredo")
        let encoded = String(decoding: try! JSONEncoder().encode(saved), as: UTF8.self)
        #expect(!encoded.contains("ghp_segredo"))

        let fresh = ConnectorSecrets(vault: vault) // as after a relaunch
        #expect(fresh.resolve(saved)[0].headers["Authorization"] == "Bearer ghp_segredo")
    }

    @Test func plainTextFromOlderFilesIsMovedAndSaysSo() {
        let vault = MemoryVault()
        let secrets = ConnectorSecrets(vault: vault)
        let old = github()
        #expect(secrets.hasUnprotectedSecrets([old]))
        let saved = secrets.redact([old])
        #expect(saved[0].headers["Authorization"] == ConnectorSecrets.marker)
        #expect(!secrets.hasUnprotectedSecrets([old]))
    }

    @Test func aRefusedWriteKeepsTheSecretInTheFile() {
        let vault = MemoryVault()
        vault.rejectsWrites = true
        let secrets = ConnectorSecrets(vault: vault)
        let saved = secrets.redact([github()])
        #expect(saved[0].headers["Authorization"] == "Bearer ghp_segredo") // nothing lost
        #expect(vault.accounts.isEmpty)
        vault.rejectsWrites = false
        #expect(secrets.redact(saved)[0].headers["Authorization"] == ConnectorSecrets.marker)
    }

    @Test func aMissingItemIsNeverWrittenOverOrWiped() {
        let vault = MemoryVault()
        let config = github()
        let saved = ConnectorSecrets(vault: vault).redact([config])
        let account = ConnectorSecrets.account(id: config.id, name: "Authorization")
        vault.remove(account) // the Keychain could not be read

        let secrets = ConnectorSecrets(vault: vault)
        let resolved = secrets.resolve(saved)
        #expect(resolved[0].headers["Authorization"] == "") // asks the user again, never the marker as a token
        // Saving meanwhile keeps the reference instead of dropping it.
        #expect(secrets.redact(resolved)[0].headers["Authorization"] == ConnectorSecrets.marker)
        // A new value replaces it.
        var typed = resolved[0]
        typed.headers["Authorization"] = "Bearer novo"
        #expect(secrets.redact([typed])[0].headers["Authorization"] == ConnectorSecrets.marker)
        #expect(vault.get(account) == "Bearer novo")
    }

    @Test func removedConnectorsAndClearedValuesLeaveNoItems() {
        let vault = MemoryVault()
        let secrets = ConnectorSecrets(vault: vault)
        let one = github(), two = github(token: "outro")
        _ = secrets.redact([one, two])
        #expect(vault.accounts.count == 2)
        _ = secrets.redact([one])
        #expect(vault.accounts == [ConnectorSecrets.account(id: one.id, name: "Authorization")])
        var cleared = one
        cleared.headers["Authorization"] = ""
        #expect(secrets.redact([cleared])[0].headers["Authorization"] == "")
        #expect(vault.accounts.isEmpty)
    }

    @Test func environmentSecretsToo() {
        let vault = MemoryVault()
        let secrets = ConnectorSecrets(vault: vault)
        let config = MCPServerConfig(name: "Notion", command: "npx", environment: ["NOTION_TOKEN": "ntn_x", "LANG": "pt"])
        let saved = secrets.redact([config])
        #expect(saved[0].environment == ["NOTION_TOKEN": ConnectorSecrets.marker, "LANG": "pt"])
        #expect(ConnectorSecrets(vault: vault).resolve(saved)[0].environment == config.environment)
    }
}

@Suite final class ConnectorSecretsAppTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbSecrets-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: root) }

    @Test @MainActor func theDataFileNeverHoldsTheToken() throws {
        let vault = MemoryVault()
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false, secretVault: vault)
        let config = MCPServerConfig(name: "Notion", command: "/usr/bin/true", environment: ["NOTION_TOKEN": "ntn_segredo"], isEnabled: false)
        model.connectors = [config]
        model.saveNow()
        let file = try String(contentsOf: root.appending(path: "state.json"), encoding: .utf8)
        #expect(!file.contains("ntn_segredo") && file.contains(ConnectorSecrets.marker))

        let reopened = AppModel(store: Store(directory: root), runsBackgroundWork: false, secretVault: vault)
        #expect(reopened.connectors.first?.environment["NOTION_TOKEN"] == "ntn_segredo")
    }

    @Test @MainActor func aTokenLeftInPlainTextMigratesOnTheNextSave() throws {
        var state = AppState.initial
        state.connectors = [MCPServerConfig(name: "Notion", command: "/usr/bin/true", environment: ["NOTION_TOKEN": "ntn_antigo"], isEnabled: false)]
        Store(directory: root).save(state)
        let vault = MemoryVault()
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false, secretVault: vault)
        #expect(model.connectors.first?.environment["NOTION_TOKEN"] == "ntn_antigo")
        model.saveNow()
        let file = try String(contentsOf: root.appending(path: "state.json"), encoding: .utf8)
        #expect(!file.contains("ntn_antigo"))
        #expect(vault.accounts.count == 1)
    }
}
