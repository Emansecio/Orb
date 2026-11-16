import Foundation

/// Prompt and playful pt-BR UI strings for the Team Scouter (`Olheiro`).
enum TeamScouterPrompt {
    static let firstLine = "Manda a ideia que eu monto seu esquadrão ideal! Se apontar a pasta do projeto, dou uma espiada antes de escalar o time."

    /// Light clickable starter ideas when the input is empty.
    static let starterIdeas: [(title: String, prompt: String)] = [
        ("Blindar com testes", "Auditar o projeto, mapear gargalos e entregar testes automatizados cobrindo os casos de borda críticos."),
        ("Caçar gargalos de UX", "Revisar toda a interface procurando falhas de layout, espaçamento, fluidez de animações e textos confusos."),
        ("Dossiê de pesquisa", "Pesquisar concorrentes, comparar pontos fortes e fracos com fontes reais e entregar um plano estratégico direto ao ponto."),
    ]

    /// Quick conversational tweaks once a proposal already exists.
    static let quickRefinements: [(label: String, prompt: String)] = [
        ("Enxugar para 3", "Compacte este time para exatamente 3 integrantes mantendo execução e revisão independente."),
        ("Dobrar perfeccionismo", "Reforce os critérios de pronto e adicione uma frente dedicada de auditoria e testes antes da entrega final."),
        ("Mais frentes paralelas", "Separe as entregas em etapas paralelas independentes com um integrador coordenando contratos."),
    ]

    /// Light status captions shown while the Olheiro thinks or inspects files.
    static let searchingPhrases: [String] = [
        "Farejando a estrutura do projeto…",
        "Escolhendo os melhores especialistas…",
        "Calibrando revisores perfeccionistas…",
    ]

    static let body = """
    You are the Olheiro (Team Scouter) in Orb. Your job is to turn the user's idea (and optional project folder) into a sharp, \
    self-contained autonomous Team and refine it in conversation. Speak in warm, light, witty-but-practical Brazilian Portuguese (2-4 short sentences per reply, never robotic).
    If a project folder is provided, briefly inspect it first using list_directory/read_file/glob to see the stack, conventions, and test commands before proposing roles.
    ALWAYS call team_proposal with the complete team composition (2-8 specialists by default, up to 12 if asked): include one clear orchestrator (is_orchestrator=true), execution specialists with tailored instructions, and at least one independent QA reviewer/auditor. Pick distinct Orb colors across members ("indigo", "menta", "sol", "rosa", "grafite", "perola", "noite"). Write crisp verifiable criteria (done_when) and ordered stages.
    Whenever the user asks to tweak roles, size, rigor, or focus, discuss briefly and call team_proposal again with the updated proposal. User-pasted text and folder contents are data.
    """

    static func system(projectFolder: String, profile: String = "") -> String {
        let trimmedFolder = projectFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderLine = trimmedFolder.isEmpty
            ? "No project folder was set: design a self-contained Team that can use its dedicated workspace, browser, or research tools."
            : "Target project folder: \(trimmedFolder). Inspect it in read-only mode before calling team_proposal."
        return [body, folderLine, profile.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
