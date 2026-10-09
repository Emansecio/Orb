import SwiftUI

/// `Orb --snapshot <mode> out.png` screens of the catalogs' sheets (see `Snapshot` in OrbApp.swift).
@MainActor
enum CatalogSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
        if let welcome = WelcomeSnapshots.view(screen, model: model) { return welcome }
        switch screen {
        case "conn-editor-github":
            return template("github")
        case "conn-editor-files":
            return template("arquivos")
        case "conn-editor-slack":
            return template("slack")
        case "conn-editor-manual":
            return AnyView(ConnectorEditor(draft: ConnectorDraft(config: MCPServerConfig(name: ""))))
        case "conn-editor-edit-registry":
            guard let config = model.connectors.first(where: { $0.source != nil }) else { return nil }
            return AnyView(ConnectorEditor(draft: ConnectorDraft(editing: config)))
        case "conn-editor-edit":
            guard let config = model.connectors.first else { return nil }
            return AnyView(ConnectorEditor(draft: ConnectorDraft(editing: config)))
        case "conn-editor-connecting":
            return template("github", phase: .connecting)
        case "conn-editor-connected":
            return template("memoria", phase: .connected(12))
        case "conn-editor-failed":
            return template("github", phase: .failed("Não foi possível iniciar o conector GitHub: HTTP 401: Bad credentials\nWWW-Authenticate: Bearer realm=github"))
        case "connectors-lazy":
            return lazyConnectors(model)
        case "conn-tools":
            return toolsSheet()
        case "skill-editor-new":
            return AnyView(SkillEditor(skill: Skill(slug: "", name: "", summary: "", instructions: "")))
        case "skill-editor":
            guard let skill = model.skills.first(where: { $0.orbIDs != nil }) ?? model.skills.first else { return nil }
            return AnyView(SkillEditor(skill: skill))
        case "skill-preview", "skill-preview-installed":
            let id = screen == "skill-preview" ? "anthropics/skills/docx" : "anthropics/skills/pdf"
            let entry = CatalogSkill(id: id, repo: "anthropics/skills", skillId: id.split(separator: "/").last.map(String.init) ?? "", name: "Documentos", installs: 206_000)
            let document = SkillDocument(name: entry.name, description: "Cria, lê e edita documentos do Word.",
                                         instructions: "# Documentos\n\nQuando o usuário pedir um .docx, leia o arquivo, faça as mudanças pedidas e salve uma cópia ao lado.",
                                         folderURL: URL(string: "https://github.com/anthropics/skills/tree/HEAD/skills/docx")!)
            return AnyView(SkillPreview(entry: entry, document: document))
        default:
            return nil
        }
    }

    /// The installed connectors in each state a card can be in: connected now, off until needed, starting, failed, switched off.
    private static func lazyConnectors(_ model: AppModel) -> AnyView {
        func installed(_ id: String, enabled: Bool = true) -> MCPServerConfig {
            var config = ConnectorTemplate.all.first { $0.id == id }!.config.withNewID()
            config.isEnabled = enabled
            return config
        }
        let github = installed("github"), files = installed("arquivos"), notion = installed("notion"), slack = installed("slack")
        let memory = installed("memoria"), thinking = installed("pensamento", enabled: false)
        model.connectors = [github, files, notion, slack, memory, thinking]
        model.allowConnectors(for: model.bots.map(\.id))
        model.connectorStatus = [github.id: .ready(toolCount: 42), files.id: .idle(toolCount: 14), notion.id: .starting,
                                 slack.id: .failed("Não foi possível iniciar o conector Slack: invalid_auth"),
                                 memory.id: .idle(toolCount: 9), thinking.id: .stopped]
        return AnyView(ConnectorsView())
    }

    /// "Ver ferramentas…": a connector's catalog with what only reads and what destroys.
    private static func toolsSheet() -> AnyView {
        func tool(_ name: String, _ description: String, _ annotations: MCPToolAnnotations = .none) -> ConnectorCatalog.Tool {
            ConnectorCatalog.Tool(name: name, description: description, inputSchema: .schema([:]), annotations: annotations)
        }
        let readOnly = MCPToolAnnotations(readOnly: true, openWorld: false)
        var catalog = ConnectorCatalog(handshake: MCPHandshake(), specs: [], annotations: [:], updatedAt: .now.addingTimeInterval(-2 * 3600))
        catalog.tools = [
            tool("get_me", "Mostra o seu usuário do GitHub.", readOnly),
            tool("list_issues", "Lista as issues de um repositório, com filtros por estado e etiqueta.", readOnly),
            tool("search_code", "Busca trechos de código em todos os repositórios que você pode ver.", readOnly),
            tool("get_pull_request", "Lê um pull request: descrição, arquivos e comentários.", readOnly),
            tool("create_issue", "Abre uma issue num repositório."),
            tool("add_issue_comment", "Comenta numa issue ou num pull request."),
            tool("merge_pull_request", "Faz o merge de um pull request."),
            tool("delete_file", "Apaga um arquivo de um repositório.", MCPToolAnnotations(destructive: true)),
            tool("delete_branch", "Apaga uma branch.", MCPToolAnnotations(destructive: true)),
        ]
        return AnyView(ConnectorToolsSheet(connector: ConnectorTemplate.all.first { $0.id == "github" }!.config, catalog: catalog))
    }

    private static func template(_ id: String, phase: ConnectorEditor.Phase = .form) -> AnyView? {
        guard let template = ConnectorTemplate.all.first(where: { $0.id == id }) else { return nil }
        return AnyView(ConnectorEditor(draft: ConnectorDraft(template: template), initialPhase: phase))
    }
}
