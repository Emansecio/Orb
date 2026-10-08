import Foundation

// What an empty chat says: who the Orb is, where it works and what it can do, and prompts that fit that. Pure
// functions of the Orb's settings (no disk reads), so the view can call them while it draws.

struct EmptyChatSuggestion: Equatable, Identifiable {
    var symbol: String
    var text: String
    var id: String { text }
}

enum EmptyChatContent {
    /// The most prompts shown (the interview offer counts).
    static let limit = 4

    /// Prompts for what this Orb can do and where it works. A folder of its own or a chosen folder gets prompts about
    /// that folder; the home folder gets the everyday ones; a capability that is off offers nothing that needs it.
    static func suggestions(for bot: Bot, interviewPending: Bool) -> [EmptyChatSuggestion] {
        var lists: [[EmptyChatSuggestion]] = []
        if bot.capabilities.contains(.terminal) {
            lists.append(bot.workingDirectory.isEmpty ? homeFiles : ownFolder)
        }
        if bot.capabilities.contains(.browser) { lists.append(web) }
        if bot.capabilities.contains(.computerUse) { lists.append(macApps) }

        var result: [EmptyChatSuggestion] = []
        if interviewPending {
            result.append(EmptyChatSuggestion(symbol: "questionmark.bubble",
                                              text: "Me conheça: faça perguntas para entender como me ajudar"))
        }
        // One from each list in turn, so a few capabilities give a few different kinds of prompt.
        var round = 0
        while result.count < limit, lists.contains(where: { round < $0.count }) {
            for list in lists where round < list.count && result.count < limit { result.append(list[round]) }
            round += 1
        }
        if result.isEmpty || (result.count == 1 && interviewPending) {
            result += general.prefix(limit - result.count)
        }
        return result
    }

    /// "Trabalha em ~/Orbs/Atlas" or the home folder; nil for an Orb without "Terminal e arquivos", which uses no folder.
    static func folderText(for bot: Bot) -> String? {
        guard bot.capabilities.contains(.terminal) else { return nil }
        return bot.workingDirectory.isEmpty ? "Trabalha na pasta pessoal" : "Trabalha em \(OrbFolder.display(bot.workingURL))"
    }

    /// What the Orb is allowed to use, in the app's words ("Terminal e arquivos · Navegar na web").
    static func capabilityNames(for bot: Bot) -> [String] {
        Capability.allCases.filter(bot.capabilities.contains).map(capabilityName)
    }

    static func capabilityName(_ capability: Capability) -> String { capability.label }

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
