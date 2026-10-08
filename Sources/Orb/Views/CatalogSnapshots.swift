import SwiftUI

/// `Orb --snapshot <mode> out.png` screens of the catalogs' sheets (see `Snapshot` in OrbApp.swift).
@MainActor
enum CatalogSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
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

    private static func template(_ id: String, phase: ConnectorEditor.Phase = .form) -> AnyView? {
        guard let template = ConnectorTemplate.all.first(where: { $0.id == id }) else { return nil }
        return AnyView(ConnectorEditor(draft: ConnectorDraft(template: template), initialPhase: phase))
    }
}
