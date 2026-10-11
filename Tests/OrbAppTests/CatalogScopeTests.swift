import Foundation
import Testing
@testable import Orb

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
    let path = try testScript(script)
    return MCPServerConfig(name: name, command: "/usr/bin/python3", arguments: [path.path], environment: environment)
}

// MARK: - Per-Orb scope

struct OrbScopeModelTests {
    @Test func aConnectorKeepsItsSummaryAndOlderFilesHaveNone() throws {
        var connector = MCPServerConfig(name: "Meu", command: "x")
        #expect(connector.summary == nil)
        connector.summary = "Faz coisas."
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: JSONEncoder().encode(connector))
        #expect(decoded.summary == "Faz coisas.")
        #expect(try JSONDecoder().decode(MCPServerConfig.self, from: Data(#"{"name":"Antigo","command":"npx"}"#.utf8)).summary == nil)
        // It says nothing about how the server runs, so a new description does not restart it.
        #expect(connector.runsSameServer(as: MCPServerConfig(id: connector.id, name: "Meu", command: "x")))
    }

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
    deinit { removeTestFolder(root) }

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

    @Test @MainActor func thePanelCountsOnlyTheConnectorsInTheOrbsScope() {
        let model = model()
        let (atlas, lia) = (model.bots[0].id, model.bots[1].id)
        model.bots[0].capabilities.insert(.connectors)
        model.connectors = [MCPServerConfig(name: "A", command: "x"),
                            MCPServerConfig(name: "B", command: "x", orbIDs: [lia]),
                            MCPServerConfig(name: "C", command: "x", isEnabled: false, orbIDs: [atlas])]
        // Atlas gets A; B is kept for Lia only (it does not count for Atlas); C is Atlas's but off.
        #expect(model.connectorCounts(for: atlas) == (enabled: 1, total: 2))
        #expect(model.connectorCounts(for: lia) == (enabled: 0, total: 2)) // Lia's switch is off: she gets none
        // Connectors exist but all are kept for Lia: Atlas sees none in its scope (and the panel says so, not "none installed").
        model.connectors = [MCPServerConfig(name: "B", command: "x", orbIDs: [lia])]
        #expect(model.connectorCounts(for: atlas) == (enabled: 0, total: 0))
        #expect(!model.connectors.isEmpty)
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

// MARK: - Which connectors an Orb reaches

@Suite(.enabled(if: hasPython))
struct ConnectorToolFilteringTests {
    @Test func changingTheScopeDoesNotRestartTheServer() async throws {
        let manager = MCPManager()
        var config = try fakeServer(name: "Alfa", count: 1)
        await manager.sync([config])
        let before = try await manager.ensureStarted(config.id)
        config.orbIDs = [UUID()]
        await manager.sync([config])
        #expect(try await manager.ensureStarted(config.id) === before)
        config.environment["X"] = "1"
        await manager.sync([config])
        // Edited: the old server is stopped, and the connector starts again (new) when something needs it.
        #expect(await manager.status()[config.id] == .idle(toolCount: nil))
        #expect(try await manager.ensureStarted(config.id) !== before)
    }

    @Test @MainActor func connectAndWaitReportsTheOutcome() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbScope-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        let good = try fakeServer(name: "Bom", count: 4)
        let broken = MCPServerConfig(name: "Quebrado", command: "orb-no-such-command-xyz")
        model.connectors = [good, broken]
        #expect(await model.connectAndWait(good.id) == .ready(toolCount: 4))
        guard case .failed? = await model.connectAndWait(broken.id) else { Issue.record("expected failure"); return }
    }

    @Test @MainActor func startingOneConnectorLeavesTheOthersOff() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbScope-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        let one = try fakeServer(name: "Um", count: 1), two = try fakeServer(name: "Dois", count: 2)
        model.connectors = [one, two]
        #expect(await model.connectAndWait(one.id) == .ready(toolCount: 1))
        await waitUntil("the screen to hear the statuses") { model.connectorStatus[one.id] == .ready(toolCount: 1) }
        #expect(model.connectorStatus[two.id] == .idle(toolCount: nil))
    }
}

struct ConnectorTextTests {
    @Test func errorsReadShort() {
        #expect(ConnectorStatusText.shortError("Não foi possível iniciar o conector GitHub: HTTP 401\nmais detalhe") == "HTTP 401")
        #expect(ConnectorStatusText.shortError("Não foi possível conectar ao conector Slack: Could not connect") == "Could not connect")
        #expect(ConnectorStatusText.shortError("   \n ") == "Sem detalhes.")
        let long = ConnectorStatusText.shortError(String(repeating: "a", count: 300), limit: 50)
        #expect(long.count == 51 && long.hasSuffix("…"))
        #expect(ConnectorStatusText.toolsAvailable(12) == "12 ferramentas disponíveis")
        #expect(ConnectorStatusText.toolsAvailable(1) == "1 ferramenta disponível")
        #expect(ConnectorStatusText.toolsAvailable(0).contains("não oferece"))
        #expect(ConnectorStatusText.tested(tools: 12, seconds: 0.84) == "Conectou: 12 ferramentas em 0,8 s")
        #expect(ConnectorStatusText.tested(tools: 1, seconds: 2) == "Conectou: 1 ferramenta em 2,0 s")
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
        let slack = try #require(ConnectorTemplate.retired.first { $0.id == "slack" })
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
        #expect(MCPServerConfig.templates.count == all.count)
    }

    @Test func theGalleryNoLongerOffersTheAbandonedPackages() throws {
        // Slack's archived `server-slack` and Notion's unmaintained npm server are not offered...
        #expect(!ConnectorTemplate.all.contains { $0.config.arguments.contains { $0.contains("server-slack") || $0.contains("notion-mcp-server") } })
        #expect(!ConnectorTemplate.all.contains { ["slack", "notion"].contains($0.id) && !$0.isRemote })
        // ...but a connector already installed from them is still recognized: it keeps its guided form and its summary.
        let old = try #require(ConnectorTemplate.retired.first { $0.id == "slack" })
        let installed = old.config.withNewID()
        #expect(ConnectorTemplate.matching(installed)?.id == "slack")
        let draft = ConnectorDraft(editing: installed)
        #expect(draft.isGuided && draft.inputs.map(\.name) == ["SLACK_BOT_TOKEN", "SLACK_TEAM_ID"])
        #expect(Set(ConnectorTemplate.retired.map(\.id)).isDisjoint(with: Set(ConnectorTemplate.all.map(\.id))))
    }

    @Test func categoriesFilter() {
        let code = ConnectorTemplate.all.filter { $0.matches(.code) }
        #expect(code.map(\.id) == ["github", "linear", "atlassian", "sentry"])
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
    deinit { removeTestFolder(root) }

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
