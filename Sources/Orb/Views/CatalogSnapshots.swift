#if DEBUG || ORB_DEV_TOOLS
import SwiftUI

/// `Orb --snapshot <mode> out.png` screens of the catalogs' sheets (see `Snapshot` in OrbApp.swift).
@MainActor
enum CatalogSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
        if let welcome = WelcomeSnapshots.view(screen) { return welcome }
        switch screen {
        case "conn-editor-github":
            return template("github")
        case "conn-editor-files":
            return template("arquivos")
        case "conn-editor-slack":
            return template("slack-oficial")
        case "conn-editor-supabase":
            return template("supabase")
        case "conn-editor-retired-slack":
            return template("slack")
        case "connectors-gallery":
            return gallery(model)
        case "conn-google-intro":
            return AnyView(LocalConnectorSheet(kind: .agenda))
        case "conn-google-account":
            return AnyView(LocalConnectorSheet(kind: .gmail, initialPhase: .attention(.noAccount)))
        case "conn-google-account-agenda":
            return AnyView(LocalConnectorSheet(kind: .agenda, initialPhase: .attention(.noAccount)))
        case "conn-google-denied":
            return AnyView(LocalConnectorSheet(kind: .agenda, initialPhase: .attention(.denied)))
        case "conn-google-done":
            return AnyView(LocalConnectorSheet(kind: .gmail, initialPhase: .done(5)))
        case "conn-google-working":
            return AnyView(LocalConnectorSheet(kind: .agenda, initialPhase: .working))
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
        case "conn-editor-notion":
            return template("notion-oficial")
        case "conn-signin":
            return template("notion-oficial", phase: .signingIn)
        case "conn-needs-signin":
            return needsSignIn(model)
        case "conn-tools":
            return toolsSheet()
        case "skill-editor-new":
            return AnyView(SkillEditor(skill: Skill(slug: "", name: "", summary: "", instructions: "")))
        case "skill-editor":
            guard let skill = model.skills.first(where: { $0.orbIDs != nil }) ?? model.skills.first else { return nil }
            return AnyView(SkillEditor(skill: skill))
        case "skill-proposal", "skill-proposal-update":
            guard let bot = model.bots.first, let draft = SkillSnapshots.draft(of: bot, update: screen.hasSuffix("update")) else { return nil }
            return AnyView(SkillEditor(skill: draft.skill, proposal: draft))
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
            var config = (ConnectorTemplate.all + ConnectorTemplate.retired).first { $0.id == id }!.config.withNewID()
            config.isEnabled = enabled
            return config
        }
        let github = installed("github"), files = installed("arquivos"), notion = installed("notion"), slack = installed("slack")
        let memory = installed("memoria"), thinking = installed("pensamento", enabled: false)
        var agenda = LocalConnectorKind.agenda.config
        agenda.orbIDs = nil
        model.connectors = [github, files, notion, slack, memory, thinking, agenda]
        model.allowConnectors(for: model.bots.map(\.id))
        model.connectorStatus = [github.id: .ready(toolCount: 42), files.id: .idle(toolCount: 14), notion.id: .starting,
                                 slack.id: .failed("Não foi possível iniciar o conector Slack: invalid_auth"),
                                 memory.id: .idle(toolCount: 9), thinking.id: .stopped, agenda.id: .idle(toolCount: 6)]
        model.localStates = [.agenda: .noAccount]
        return AnyView(ConnectorsView(tab: .installed))
    }

    /// Connectors that sign in with the account, in the three states that ask for something: no login yet, the login ended, more
    /// permission wanted. A fourth one is signed in, for contrast.
    private static func needsSignIn(_ model: AppModel) -> AnyView {
        func installed(_ id: String) -> MCPServerConfig { ConnectorTemplate.all.first { $0.id == id }!.config.withNewID() }
        let notion = installed("notion-oficial"), linear = installed("linear"), slack = installed("slack-oficial"), sentry = installed("sentry")
        model.connectors = [notion, linear, slack, sentry]
        model.allowConnectors(for: model.bots.map(\.id))
        model.connectorStatus = [notion.id: .needsSignIn(nil), linear.id: .needsSignIn("A sessão do Linear expirou. Entre de novo."),
                                 slack.id: .needsMorePermission("chat:write"), sentry.id: .ready(toolCount: 16)]
        return AnyView(ConnectorsView(tab: .installed))
    }

    /// The gallery with a bit of everything: connected, needing attention, switched off, available and coming soon.
    private static func gallery(_ model: AppModel) -> AnyView {
        var gmail = LocalConnectorKind.gmail.config, agenda = LocalConnectorKind.agenda.config
        gmail.orbIDs = nil
        agenda.orbIDs = nil
        let github = ConnectorTemplate.all.first { $0.id == "github" }!.config.withNewID()
        var memory = ConnectorTemplate.all.first { $0.id == "memoria" }!.config.withNewID()
        memory.isEnabled = false
        model.connectors = [gmail, agenda, github, memory]
        model.allowConnectors(for: model.bots.map(\.id))
        model.connectorStatus = [gmail.id: .idle(toolCount: 5), agenda.id: .idle(toolCount: 6), github.id: .ready(toolCount: 42), memory.id: .stopped]
        model.localStates = [.gmail: .ready, .agenda: .noAccount]
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
        guard let template = (ConnectorTemplate.all + ConnectorTemplate.retired).first(where: { $0.id == id }) else { return nil }
        return AnyView(ConnectorEditor(draft: ConnectorDraft(template: template), initialPhase: phase))
    }
}

/// The skill the proposal scenes (`--snapshot skill-proposal`, `transcript-skill-proposal`) show.
enum SkillSnapshots {
    static let proposal = """
        ---
        name: publicar-site
        description: Publica o site em produção com testes antes e conferência depois; use quando pedirem para publicar ou subir o site.
        ---

        ## Quando usar
        Quando a usuária pedir para publicar, subir ou fazer deploy do site, em qualquer branch.

        ## Passos
        1. Rode `swift test --jobs 4` e pare se algum teste falhar.
        2. Confirme que a branch é `main` com `git branch --show-current` e que `git status` está limpo.
        3. Rode `./scripts/deploy.sh --prod` e acompanhe a saída até a linha "Deploy concluído".
        4. Abra a URL de produção e confira a versão no rodapé.

        ## Armadilhas
        - Nunca rode o deploy com arquivos modificados: o script publica a pasta, não o commit.
        - O script lê `.env.production` da pasta atual; rodar de outro lugar publica com as chaves erradas.

        ## Como verificar
        Abra o site e confira se a versão no rodapé é a do último commit (`git rev-parse --short HEAD`).
        """

    /// The proposal as the editor gets it: new, or, with `update`, replacing a skill of the same command.
    static func draft(of bot: Bot, update: Bool) -> SkillDraft? {
        guard case .success(let parsed) = SkillProposal.validate(proposal, among: []) else { return nil }
        let skill = Skill(slug: parsed.slug, name: update ? "Publicar o site" : parsed.name, summary: parsed.summary,
                          instructions: parsed.instructions, source: Skill.learnedSource, orbIDs: [bot.id], learnedBy: bot.id)
        return SkillDraft(skill: skill, slug: parsed.slug, botID: bot.id, orbName: bot.name, isUpdate: update)
    }
}
#endif
