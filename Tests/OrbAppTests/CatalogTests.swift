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

    @Test func theOfficialSealNeedsTheWholeNamespace() {
        #expect(RegistryServer.isOfficial("io.modelcontextprotocol/filesystem"))
        #expect(RegistryServer.isOfficial("io.github.modelcontextprotocol/servers"))
        #expect(RegistryServer.isOfficial("io.modelcontextprotocol.anything/x"))
        #expect(!RegistryServer.isOfficial("io.github.modelcontextprotocol-evil/x"))
        #expect(!RegistryServer.isOfficial("io.modelcontextprotocolx.app/x"))
        #expect(!RegistryServer.isOfficial("io.github.someone/modelcontextprotocol"))
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

    @Test func theSlowHintOnlyComesFromAWaitThatRanToTheEnd() async {
        #expect(await SlowHint.arrives(after: .milliseconds(1)))
        let cancelled = Task { await SlowHint.arrives(after: .seconds(30)) }
        cancelled.cancel()
        #expect(await cancelled.value == false, "a search that ended or was replaced must not leave the hint armed")
    }

    @Test func installCountsReadNaturally() {
        #expect(206_559.installsLabel == "207 mil instalações")
        #expect(1.installsLabel == "1 instalação")
        #expect(999_700.installsLabel == "1 mi instalações", "never \"1.000 mil\"")
        #expect(999_499.installsLabel == "999 mil instalações")
        #expect(1_250_000.installsLabel.hasPrefix("1,2") || 1_250_000.installsLabel.hasPrefix("1.2"))
    }
}

/// A repository on a stub network: SKILL.md files by path, and how often each address was asked for.
private final class StubRepository: @unchecked Sendable {
    let files: [String: String]
    var listingStatus = 200
    private let lock = NSLock()
    private var asked: [String: Int] = [:]

    init(_ files: [String: String]) { self.files = files }

    func count(_ fragment: String) -> Int { lock.withLock { asked.filter { $0.key.contains(fragment) }.map(\.value).reduce(0, +) } }

    func fetch(_ request: URLRequest) -> (Data, Int) {
        let url = request.url?.absoluteString ?? ""
        lock.withLock { asked[url, default: 0] += 1 }
        if url.contains("/git/trees/") {
            guard listingStatus == 200 else { return (Data(), listingStatus) }
            let tree = files.keys.sorted().map { "{\"path\":\"\($0)\"}" }.joined(separator: ",")
            return (Data("{\"tree\":[\(tree)]}".utf8), 200)
        }
        let path = url.components(separatedBy: "/HEAD/").last ?? ""
        return files[path].map { (Data($0.utf8), 200) } ?? (Data("404".utf8), 404)
    }
}

struct SkillLocatingTests {
    private func skill(_ id: String) -> CatalogSkill {
        CatalogSkill(id: "o/r/\(id)", repo: "o/r", skillId: id, name: id, installs: 0)
    }

    private func markdown(_ name: String, _ description: String) -> String {
        "---\nname: \(name)\ndescription: \(description)\n---\n# \(name)\nFaça assim."
    }

    @Test func aSkillIsFoundByTheNameItsFileDeclares() async throws {
        let repo = StubRepository([
            ".cursor/skills/taste-skill/SKILL.md": markdown("design-taste-frontend", "cópia de outra ferramenta"),
            "skills/taste-skill/SKILL.md": markdown("design-taste-frontend", "Frontend com gosto."),
            "skills/brandkit/SKILL.md": markdown("brandkit", "Marca."),
        ])
        let catalog = SkillCatalog { (repo.fetch($0)) }
        let document = try await catalog.document(for: skill("design-taste-frontend"))
        #expect(document.description == "Frontend com gosto.") // the repository's own copy, not a tool's mirror
        #expect(document.folderURL.absoluteString.hasSuffix("o/r/tree/HEAD/skills/taste-skill"))
        // Another card of the same repository: the listing is not asked for again.
        _ = try await catalog.document(for: skill("brandkit"))
        #expect(repo.count("/git/trees/") == 1)
    }

    @Test func aPluginsSkillIsFoundByItsOwnName() async throws {
        let repo = StubRepository(["plugins/stitch-design/skills/extract-design-md/SKILL.md": markdown("extract-design-md", "Extrai.")])
        let catalog = SkillCatalog { (repo.fetch($0)) }
        #expect(try await catalog.document(for: skill("stitch::extract-design-md")).description == "Extrai.")
    }

    @Test func oneThatIsGoneSaysSoInsteadOfWaiting() async throws {
        let repo = StubRepository(["skills/impeccable/SKILL.md": markdown("impeccable", "Design.")])
        let catalog = SkillCatalog { (repo.fetch($0)) }
        await #expect(throws: CatalogError.self) { try await catalog.document(for: skill("frontend-design")) }
        do { _ = try await catalog.document(for: skill("frontend-design")) } catch {
            #expect(CatalogError.cardText(for: error).contains("renomeada ou removida"))
        }
    }

    @Test func aRefusedListingIsTriedAgainLater() async throws {
        let repo = StubRepository(["skills/taste-skill/SKILL.md": markdown("design-taste-frontend", "Frontend.")])
        repo.listingStatus = 403
        let catalog = SkillCatalog { (repo.fetch($0)) }
        do {
            _ = try await catalog.document(for: skill("design-taste-frontend"))
            Issue.record("the refused listing must fail")
        } catch {
            #expect(CatalogError.cardText(for: error).contains("limitou"))
        }
        repo.listingStatus = 200
        #expect(try await catalog.document(for: skill("design-taste-frontend")).description == "Frontend.")
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

    @Test func findsASkillWhoseFolderHasAnotherName() async throws {
        let skill = CatalogSkill(id: "leonxlnx/taste-skill/design-taste-frontend", repo: "leonxlnx/taste-skill",
                                 skillId: "design-taste-frontend", name: "design-taste-frontend", installs: 0)
        let document = try await SkillCatalog().document(for: skill)
        #expect(document.name == "design-taste-frontend")
        #expect(!document.description.isEmpty)
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
