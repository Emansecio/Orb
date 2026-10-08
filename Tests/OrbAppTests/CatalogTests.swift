import Foundation
import Testing
@testable import Orb

struct CatalogTests {
    @Test func parsesSkillFrontmatter() {
        let text = """
        ---
        name: pdf
        description: "Use this skill for PDFs: merge, split."
        license: Proprietary
        notes: >
          folded line one
          line two
        ---

        # PDF Guide
        Body here.
        """
        let parsed = SkillCatalog.parse(text)
        #expect(parsed.fields["name"] == "pdf")
        #expect(parsed.fields["description"] == "Use this skill for PDFs: merge, split.")
        #expect(parsed.fields["notes"] == "folded line one line two")
        #expect(parsed.body == "# PDF Guide\nBody here.")
    }

    @Test func markdownWithoutFrontmatterIsAllBody() {
        let parsed = SkillCatalog.parse("# Só instruções\n")
        #expect(parsed.fields.isEmpty)
        #expect(parsed.body == "# Só instruções")
    }

    @Test func registryNpmPackageBecomesALocalConnector() throws {
        let json = try #require(JSONValue.parse("""
        {"name": "io.github.acme/notes", "title": "Notes", "description": "Notes MCP", "version": "1.2.0",
         "packages": [{"registryType": "npm", "identifier": "@acme/notes-mcp", "version": "1.2.0",
                       "transport": {"type": "stdio"},
                       "packageArguments": [{"type": "named", "name": "--mode", "value": "safe"},
                                            {"type": "positional", "value": "{root}"}],
                       "environmentVariables": [{"name": "NOTES_TOKEN", "isSecret": true, "isRequired": true,
                                                 "description": "API token"}]}]}
        """))
        let server = try #require(MCPRegistry.server(from: json))
        #expect(server.config.command == "npx")
        #expect(server.config.arguments == ["-y", "@acme/notes-mcp@1.2.0", "--mode", "safe"])
        #expect(server.config.environment == ["NOTES_TOKEN": ""])
        #expect(server.inputs == [RegistryServer.Input(name: "NOTES_TOKEN", summary: "API token", isSecret: true, isRequired: true)])
        #expect(server.config.source == "io.github.acme/notes")
        #expect(server.kindLabel == "Local · npx")
    }

    @Test func registryRemotePrefersStreamableHTTP() throws {
        let json = try #require(JSONValue.parse("""
        {"name": "com.example/remote",
         "remotes": [{"type": "sse", "url": "https://example.com/sse"},
                     {"type": "streamable-http", "url": "https://example.com/mcp",
                      "headers": [{"name": "Authorization", "value": "Bearer {token}", "isSecret": true, "isRequired": true}]}]}
        """))
        let server = try #require(MCPRegistry.server(from: json))
        #expect(server.config.url == "https://example.com/mcp")
        #expect(server.config.headers == ["Authorization": ""])
        #expect(server.title == "remote")
    }

    @Test func unsupportedRegistryEntriesAreSkipped() throws {
        let json = try #require(JSONValue.parse("""
        {"name": "com.example/nuget", "packages": [{"registryType": "nuget", "identifier": "X"}]}
        """))
        #expect(MCPRegistry.server(from: json) == nil)
    }

    @Test func olderSkillsAndConnectorsStillDecode() throws {
        let skill = try JSONDecoder().decode(Skill.self, from: Data(#"{"slug":"resumir","name":"Resumir","instructions":"x"}"#.utf8))
        #expect(skill.isEnabled)
        #expect(skill.source == nil)
        let connector = try JSONDecoder().decode(MCPServerConfig.self,
                                                 from: Data(#"{"name":"Arquivos","command":"npx","arguments":["-y"]}"#.utf8))
        #expect(!connector.isRemote)
        #expect(connector.isEnabled)
    }

    @Test func installCountsReadNaturally() {
        #expect(206_559.installsLabel == "207 mil instalações")
        #expect(1.installsLabel == "1 instalação")
        #expect(1_250_000.installsLabel.hasPrefix("1,2") || 1_250_000.installsLabel.hasPrefix("1.2"))
    }
}

/// Hits the real catalogs: `ORB_LIVE_TESTS=1 swift test --filter LiveCatalogTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ORB_LIVE_TESTS"] != nil))
struct LiveCatalogTests {
    @Test func searchesSkillsAndReadsSkillMarkdown() async throws {
        let results = try await SkillCatalog().search("pdf")
        let official = try #require(results.first { $0.repo == "anthropics/skills" && $0.skillId == "pdf" })
        let document = try await SkillCatalog().document(for: official)
        #expect(document.name == "pdf")
        #expect(!document.description.isEmpty)
        #expect(document.instructions.count > 200)
    }

    @Test func connectsToAPublicRemoteServer() async throws {
        let connection = MCPConnection(config: MCPServerConfig(name: "DeepWiki", url: "https://mcp.deepwiki.com/mcp"))
        let tools = try await connection.start()
        #expect(!tools.isEmpty)
        await connection.stop()
    }

    @Test(arguments: [ProviderKind.commandCode, .opencodeZen, .opencodeGo])
    func listsProviderModelsLive(_ kind: ProviderKind) async throws {
        let models = try await ModelCatalog.fetch(ProviderAccount(kind: kind), token: nil)
        #expect(models.count > 5)
        #expect(Set(models.map(\.format)).count >= 2, "esperava modelos em mais de um formato")
    }

    @Test func searchesTheMCPRegistry() async throws {
        let servers = try await MCPRegistry.shared.search("github")
        #expect(!servers.isEmpty)
        #expect(servers.allSatisfy { $0.config.isRemote || !$0.config.command.isEmpty })
    }
}
