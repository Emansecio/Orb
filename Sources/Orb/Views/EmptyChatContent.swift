import Foundation

// What an empty chat says: who the Orb is, where it works and what it can do, and prompts that fit that. Pure
// functions of the Orb's settings (no disk reads), so the view can call them while it draws.

struct EmptyChatSuggestion: Equatable, Identifiable {
    /// What a click does: send a message, or open the routine editor filled in from a template (it never creates a
    /// routine by itself: you read it and save it).
    enum Action: Equatable {
        case send(String)
        case openEditor(RoutineTemplate)
    }

    var symbol: String
    var text: String
    var action: Action
    var id: String { text }

    /// A message idea sends its own text unless told otherwise.
    init(symbol: String, text: String, action: Action? = nil) {
        self.symbol = symbol
        self.text = text
        self.action = action ?? .send(text)
    }

    /// The trailing words of an idea that makes something: "Cria uma rotina", "Cria uma meta"; nil for a message.
    var caption: String? {
        guard case .openEditor(let template) = action else { return nil }
        return template.goal == nil ? "Cria uma rotina" : "Cria uma meta"
    }
}

enum EmptyChatContent {
    /// The most prompts shown (the interview offer and the routine ideas count).
    static let limit = 4

    /// What "Me conheça" and the greeting's "Me entreviste" send: the Orb's first conversation is its interview.
    static let interviewRequest = "Oi! Antes de começarmos, me faça algumas perguntas para entender como você pode me ajudar."

    /// Prompts for what this Orb can do and where it works. A folder of its own or a chosen folder gets prompts about
    /// that folder; the home folder gets the everyday ones; a capability that is off offers nothing that needs it. An
    /// Orb with no routine yet (`offersRoutines`) also gets an idea or two of what it could do on its own, last.
    static func suggestions(for bot: Bot, interviewPending: Bool, offersRoutines: Bool = false) -> [EmptyChatSuggestion] {
        var lists: [[EmptyChatSuggestion]] = []
        if bot.capabilities.contains(.terminal) {
            lists.append(bot.workingDirectory.isEmpty ? homeFiles : ownFolder)
        }
        if bot.capabilities.contains(.browser) { lists.append(web) }
        if bot.capabilities.contains(.computerUse) { lists.append(macApps) }
        // Two with the interview offer would leave a single prompt to talk about: one then.
        let ideas = offersRoutines ? Array(routineIdeas(for: bot).prefix(interviewPending ? 1 : 2)) : []
        let room = limit - ideas.count

        var result: [EmptyChatSuggestion] = []
        if interviewPending {
            result.append(EmptyChatSuggestion(symbol: "questionmark.bubble",
                                              text: "Me conheça: faça perguntas para entender como me ajudar",
                                              action: .send(interviewRequest)))
        }
        // One from each list in turn, so a few capabilities give a few different kinds of prompt.
        var round = 0
        while result.count < room, lists.contains(where: { round < $0.count }) {
            for list in lists where round < list.count && result.count < room { result.append(list[round]) }
            round += 1
        }
        if result.isEmpty || (result.count == 1 && interviewPending) {
            result += general.prefix(room - result.count)
        }
        return result + ideas
    }

    /// What this Orb could do on its own: the goal needs files (Terminal), the morning summary only connectors.
    private static func routineIdeas(for bot: Bot) -> [EmptyChatSuggestion] {
        var ideas: [EmptyChatSuggestion] = []
        if bot.capabilities.contains(.terminal) {
            ideas.append(EmptyChatSuggestion(symbol: "target", text: "Mesa em ordem, aos poucos",
                                             action: .openEditor(RoutineTemplate.desktopGoal)))
        }
        ideas.append(EmptyChatSuggestion(symbol: "sun.max", text: "Um resumo da agenda toda manhã",
                                         action: .openEditor(RoutineTemplate.morningSummary)))
        return ideas
    }

    /// "Trabalha em ~/Orbs/Atlas" or the home folder; nil for an Orb without "Terminal e arquivos", which uses no folder.
    static func folderText(for bot: Bot) -> String? {
        guard bot.capabilities.contains(.terminal) else { return nil }
        return bot.workingDirectory.isEmpty ? "Trabalha na pasta pessoal" : "Trabalha em \(OrbFolder.display(bot.workingURL))"
    }

    /// What the Orb is allowed to use, in the app's words ("Terminal e arquivos · Navegar na web").
    static func capabilityNames(for bot: Bot) -> [String] {
        Capability.allCases.filter(bot.capabilities.contains).map(\.label)
    }

    private static let homeFiles = [
        EmptyChatSuggestion(symbol: "folder", text: "Organize minha pasta Downloads"),
        EmptyChatSuggestion(symbol: "doc.text", text: "Resuma o arquivo mais recente da minha Mesa"),
        EmptyChatSuggestion(symbol: "internaldrive", text: "Quanto espaço livre tenho no disco?"),
    ]

    private static let ownFolder = [
        EmptyChatSuggestion(symbol: "folder", text: "O que tem na sua pasta? Me dê um resumo"),
        EmptyChatSuggestion(symbol: "doc.badge.plus", text: "Crie um NOTAS.md com o que devo lembrar aqui"),
        EmptyChatSuggestion(symbol: "magnifyingglass", text: "Procure arquivos grandes ou repetidos na sua pasta"),
    ]

    private static let web = [
        EmptyChatSuggestion(symbol: "globe", text: "Pesquise as notícias de hoje e resuma em 5 tópicos"),
    ]

    private static let macApps = [
        EmptyChatSuggestion(symbol: "calendar", text: "O que tenho na agenda hoje?"),
        EmptyChatSuggestion(symbol: "bell", text: "Crie um lembrete para amanhã às 9h"),
    ]

    private static let general = [
        EmptyChatSuggestion(symbol: "lightbulb", text: "Me ajude a pensar em ideias para um projeto"),
        EmptyChatSuggestion(symbol: "text.alignleft", text: "Me ajude a escrever uma mensagem difícil"),
        EmptyChatSuggestion(symbol: "book", text: "Explique um assunto de forma simples"),
    ]
}

/// What a new Orb says first, in its own voice and with its own name, and the three ways to answer. Written by the app,
/// so it costs no model call; the temperament only tints the tone.
enum OrbGreeting {
    static func text(name: String, temperament: OrbTemperament, returning: Bool) -> String {
        if returning { return "Que bom te ver de novo! Já sei algumas coisas sobre você. Como posso ajudar hoje?" }
        switch temperament {
        case .calmo: return "Oi, eu sou \(name). Sem pressa: estou à sua disposição. Como prefere começar?"
        case .equilibrado: return "Oi! Eu sou \(name). Estou à sua disposição. Como prefere começar?"
        case .animado: return "Oi, oi! Eu sou \(name) e estou à sua disposição. Como vamos começar?"
        case .timido: return "Oi… eu sou \(name). Estou à sua disposição, se quiser. Como prefere começar?"
        case .curioso: return "Oi! Eu sou \(name) e quero saber como posso ajudar. Como prefere começar?"
        }
    }

    enum Reply: CaseIterable {
        case tell, interview, abilities

        var title: String {
            switch self {
            case .tell: "Vou te contar o que preciso"
            case .interview: "Me entreviste"
            case .abilities: "O que você sabe fazer?"
            }
        }

        var symbol: String {
            switch self {
            case .tell: "text.cursor"
            case .interview: "questionmark.bubble"
            case .abilities: "sparkles"
            }
        }
    }

    /// Where "Vou te contar o que preciso" starts the message box.
    static let draft = "Quero que você me ajude com "
}
