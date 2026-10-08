import Foundation

/// Themes of the featured connectors (the chips on the Explorar page).
enum ConnectorCategory: String, CaseIterable, Identifiable, Sendable {
    case code, notes, chat, files, data

    var id: String { rawValue }

    var label: String {
        switch self {
        case .code: "Código"
        case .notes: "Notas"
        case .chat: "Chat"
        case .files: "Arquivos"
        case .data: "Dados"
        }
    }
}

/// A well-known server shown under "Em destaque": what it does in plain words and what it asks for, so the card
/// never has to show a command.
struct ConnectorTemplate: Identifiable, Sendable {
    let id: String
    let config: MCPServerConfig
    let summary: String
    let category: ConnectorCategory
    /// Keys or variables to fill in.
    var inputs: [RegistryServer.Input] = []
    /// Index in `config.arguments` of the folder the server may open (the filesystem server): the sheet lets you pick it.
    var folderArgumentIndex: Int?
    /// Where to get the key, shown in the sheet.
    var helpURL: URL?

    var needsKey: Bool { inputs.contains { $0.isRequired && $0.isSecret } }
    var isRemote: Bool { config.isRemote }

    /// What the card says it needs: "Pede 1 chave", "Sem chave" or "Remoto". Only secrets are "chaves": an ID or a
    /// region is just something to fill in.
    var badges: [String] {
        let keys = inputs.filter { $0.isRequired && $0.isSecret }.count
        return [keys == 0 ? "Sem chave" : keys == 1 ? "Pede 1 chave" : "Pede \(keys) chaves"] + (isRemote ? ["Remoto"] : [])
    }

    func matches(_ category: ConnectorCategory?) -> Bool { category == nil || self.category == category }

    static let all: [ConnectorTemplate] = [
        ConnectorTemplate(
            id: "arquivos", config: MCPServerConfig(name: "Arquivos", command: "npx",
                arguments: ["-y", "@modelcontextprotocol/server-filesystem", NSHomeDirectory()]),
            summary: "Ler e organizar arquivos de uma pasta do Mac. Você escolhe qual pasta fica liberada.",
            category: .files, folderArgumentIndex: 2),
        ConnectorTemplate(
            id: "github", config: {
                var config = MCPServerConfig(name: "GitHub", url: "https://api.githubcopilot.com/mcp/")
                config.headers["Authorization"] = ""
                config.secretKeys = ["Authorization"]
                return config
            }(),
            summary: "Ler repositórios, issues e pull requests do GitHub.",
            category: .code,
            inputs: [.init(name: "Authorization", summary: "Token de acesso pessoal do GitHub. Crie um em github.com/settings/tokens.",
                           isSecret: true, isRequired: true, prefix: "Bearer ")],
            helpURL: URL(string: "https://github.com/settings/tokens")),
        ConnectorTemplate(
            id: "notion", config: {
                var config = MCPServerConfig(name: "Notion", command: "npx", arguments: ["-y", "@notionhq/notion-mcp-server"])
                config.environment["NOTION_TOKEN"] = ""
                config.secretKeys = ["NOTION_TOKEN"]
                return config
            }(),
            summary: "Buscar e editar páginas e bancos de dados do Notion.",
            category: .notes,
            inputs: [.init(name: "NOTION_TOKEN", summary: "Token de uma integração do Notion. Compartilhe as páginas com ela depois.",
                           isSecret: true, isRequired: true)],
            helpURL: URL(string: "https://www.notion.so/profile/integrations")),
        ConnectorTemplate(
            id: "slack", config: {
                var config = MCPServerConfig(name: "Slack", command: "npx", arguments: ["-y", "@modelcontextprotocol/server-slack"])
                config.environment = ["SLACK_BOT_TOKEN": "", "SLACK_TEAM_ID": ""]
                config.secretKeys = ["SLACK_BOT_TOKEN"]
                return config
            }(),
            summary: "Ler canais e enviar mensagens no Slack.",
            category: .chat,
            inputs: [.init(name: "SLACK_BOT_TOKEN", summary: "Token do bot do seu app do Slack (começa com xoxb-).",
                           isSecret: true, isRequired: true),
                     .init(name: "SLACK_TEAM_ID", summary: "ID do workspace (começa com T).", isSecret: false, isRequired: true)]),
        ConnectorTemplate(
            id: "memoria", config: MCPServerConfig(name: "Memória (grafo)", command: "npx", arguments: ["-y", "@modelcontextprotocol/server-memory"]),
            summary: "Guarda fatos e as relações entre eles para os Orbs consultarem depois.",
            category: .notes),
        ConnectorTemplate(
            id: "fetch", config: MCPServerConfig(name: "Busca na web (Fetch)", command: "uvx", arguments: ["mcp-server-fetch"]),
            summary: "Baixa uma página da web e converte em texto. Não faz buscas, e o Orb já lê páginas sozinho com \"Navegar na web\".",
            category: .data),
        ConnectorTemplate(
            id: "pensamento", config: MCPServerConfig(name: "Pensamento em etapas", command: "npx",
                arguments: ["-y", "@modelcontextprotocol/server-sequential-thinking"]),
            summary: "Ajuda o Orb a pensar passo a passo em problemas difíceis.",
            category: .data),
    ]
}

extension ConnectorTemplate {
    /// The featured template an installed connector came from (same name and same server), so that editing it keeps
    /// the guided form.
    static func matching(_ config: MCPServerConfig) -> ConnectorTemplate? {
        all.first { $0.config.name == config.name && $0.config.command == config.command && $0.config.url == config.url }
    }
}

/// What the editor knows about a connector that is already installed.
enum ConnectorEditing {
    /// Fields for an installed registry connector, rebuilt from what it holds (the registry's own descriptions are not
    /// kept): every variable or header, secret when it is marked so or looks like a key, and a "Bearer " lead kept
    /// out of the field.
    static func inputs(for config: MCPServerConfig) -> [RegistryServer.Input] {
        let values = config.isRemote ? config.headers : config.environment
        return values.keys.sorted().map { name in
            let isSecret = config.secretKeys.contains(name) || ConnectorSecrets.looksSecret(name)
            let prefix = values[name]?.hasPrefix("Bearer ") == true ? "Bearer " : ""
            return RegistryServer.Input(name: name, summary: "", isSecret: isSecret, isRequired: false, prefix: prefix)
        }
    }
}

/// Shortcuts to the old list of bare configs.
extension MCPServerConfig {
    static var templates: [MCPServerConfig] { ConnectorTemplate.all.map(\.config) }

    func withNewID() -> MCPServerConfig {
        var copy = self
        copy.id = UUID()
        return copy
    }
}

/// Pure helpers for what the connector screens say.
enum ConnectorLoad {
    /// Above this many connector tools in one request the model gets slower and costlier (and picks worse tools).
    static let warningThreshold = 40

    /// The tools of connectors an Orb receives with each message: its "Conectores" switch on, connector enabled and
    /// allowed for it, and connected (`status`).
    static func toolCount(for bot: Bot, connectors: [MCPServerConfig], status: [UUID: MCPStatus]) -> Int {
        guard bot.capabilities.contains(.connectors) else { return 0 }
        return connectors.reduce(0) { total, connector in
            guard connector.isEnabled, connector.isAvailable(to: bot.id), case .ready(let count)? = status[connector.id] else { return total }
            return total + count
        }
    }

    /// The Orb that gets the most tools, when that is over the threshold.
    static func heaviest(bots: [Bot], connectors: [MCPServerConfig], status: [UUID: MCPStatus]) -> (bot: Bot, count: Int)? {
        bots.map { ($0, toolCount(for: $0, connectors: connectors, status: status)) }
            .filter { $0.1 > warningThreshold }
            .max { $0.1 < $1.1 }
            .map { (bot: $0.0, count: $0.1) }
    }

    static func warning(for heaviest: (bot: Bot, count: Int)) -> String {
        "\(heaviest.bot.name) recebe \(heaviest.count) ferramentas de conectores a cada mensagem. Muitas ferramentas ativas deixam as conversas mais lentas e caras: desative as que você não usa."
    }
}

enum ConnectorStatusText {
    /// A connection error in one or two short lines: the reason, without the "Não foi possível iniciar o conector X:" lead.
    static func shortError(_ message: String, limit: Int = 140) -> String {
        var text = message
        if let range = text.range(of: #"^Não foi possível (?:iniciar o|conectar ao) conector [^:]*: "#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        guard line.count > limit else { return line.isEmpty ? "Sem detalhes." : line }
        return String(line.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "12 ferramentas disponíveis".
    static func toolsAvailable(_ count: Int) -> String {
        count == 0 ? "Conectou, mas não oferece ferramentas." : count == 1 ? "1 ferramenta disponível" : "\(count) ferramentas disponíveis"
    }
}

/// Edits of the argument list the folder picker and the "Argumentos" box share.
enum ConnectorArguments {
    /// `text` (one argument per line) with line `index` replaced; short lists are padded so the index exists.
    static func replacing(line index: Int, with value: String, in text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.count <= index { lines.append("") }
        lines[index] = value
        return lines.joined(separator: "\n")
    }

    static func line(_ index: Int, in text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return index < lines.count ? String(lines[index]).trimmingCharacters(in: .whitespaces) : ""
    }
}
