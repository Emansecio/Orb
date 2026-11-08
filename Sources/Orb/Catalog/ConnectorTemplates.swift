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

/// A step-by-step guide the connector sheet shows before it asks for the key.
enum ConnectorGuide: Equatable, Sendable {
    /// Slack: create the app from a manifest, install it, then sign in with its Client ID (or paste the User OAuth Token) (`SlackApp`).
    case slack
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
    /// A guide the sheet shows before the keys, for a service that needs more than a token.
    var guide: ConnectorGuide?
    /// A caution shown with the key (what the connector starts with, what it can do).
    var note: String?

    var needsKey: Bool { inputs.contains { $0.isRequired && $0.isSecret } }
    var isRemote: Bool { config.isRemote }
    /// Enters with the person's account (a login in the browser) instead of a key.
    var usesLogin: Bool { config.oauth != nil }

    /// What the card says it needs: "Pede 1 chave", "Não precisa de chave" or "Remoto". Only secrets are "chaves": an ID or a
    /// region is just something to fill in.
    var badges: [String] {
        let keys = inputs.filter { $0.isRequired && $0.isSecret }.count
        return [usesLogin ? "Entra com sua conta" : keys == 0 ? "Não precisa de chave" : keys == 1 ? "Pede 1 chave" : "Pede \(keys) chaves"] + (isRemote ? ["Remoto"] : [])
    }

    func matches(_ category: ConnectorCategory?) -> Bool { category == nil || self.category == category }

    /// A hosted server that lets the Orb register itself (OAuth with dynamic registration): one click, sign in with the account.
    private static func loginTemplate(_ id: String, name: String, url: String, category: ConnectorCategory, summary: String) -> ConnectorTemplate {
        var config = MCPServerConfig(name: name, url: url)
        config.oauth = MCPOAuthSettings()
        return ConnectorTemplate(id: id, config: config, summary: summary, category: category)
    }

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
            inputs: [.init(name: "Authorization", summary: "Token de acesso pessoal do GitHub.",
                           isSecret: true, isRequired: true, prefix: "Bearer ")],
            helpURL: URL(string: "https://github.com/settings/tokens")),
        ConnectorTemplate(
            id: "slack-oficial", config: {
                // Signs in with the Client ID of the person's own app (PKCE, no token to copy); the token pasted by hand is the other way.
                var config = MCPServerConfig(name: "Slack", url: SlackApp.serverURL)
                config.oauth = MCPOAuthSettings(scopes: SlackApp.scopes(.readOnly).joined(separator: " "), redirect: SlackApp.redirectURL)
                config.headers["Authorization"] = ""
                config.secretKeys = ["Authorization"]
                return config
            }(),
            summary: "Buscar e ler mensagens e canais do Slack e, se você liberar, enviar mensagens. Usa o servidor oficial do Slack.",
            category: .chat,
            inputs: [.init(name: "Authorization", summary: "User OAuth Token do app do Slack que você cria no passo a passo (começa com xoxp-).",
                           isSecret: true, isRequired: true, prefix: "Bearer ")],
            helpURL: SlackApp.appsURL, guide: .slack),
        loginTemplate("notion-oficial", name: "Notion", url: "https://mcp.notion.com/mcp", category: .notes,
                      summary: "Buscar e editar páginas e bancos de dados do Notion. Você entra com a sua conta."),
        loginTemplate("linear", name: "Linear", url: "https://mcp.linear.app/mcp", category: .code,
                      summary: "Ver e atualizar issues, projetos e ciclos do Linear. Você entra com a sua conta."),
        loginTemplate("atlassian", name: "Atlassian", url: "https://mcp.atlassian.com/v2/mcp", category: .code,
                      summary: "Buscar e editar issues do Jira e páginas do Confluence. Você entra com a sua conta."),
        loginTemplate("sentry", name: "Sentry", url: "https://mcp.sentry.dev/mcp", category: .code,
                      summary: "Ver erros, issues e projetos do Sentry. Você entra com a sua conta."),
        ConnectorTemplate(
            id: "supabase", config: {
                // Read-only until the person decides otherwise: the server runs queries with the permissions of the token.
                var config = MCPServerConfig(name: "Supabase", url: "https://mcp.supabase.com/mcp?read_only=true")
                config.headers["Authorization"] = ""
                config.secretKeys = ["Authorization"]
                return config
            }(),
            summary: "Consultar os projetos e as tabelas do seu Supabase. Começa só em leitura.",
            category: .data,
            inputs: [.init(name: "Authorization", summary: "Token de acesso pessoal do Supabase (Account → Access Tokens).",
                           isSecret: true, isRequired: true, prefix: "Bearer ")],
            helpURL: URL(string: "https://supabase.com/dashboard/account/tokens"),
            note: "Vem com read_only=true na URL: o Orb só lê. Para deixar escrever, tire isso da URL em Avançado. Dados dos seus bancos podem trazer instruções escondidas: deixe o Orb perguntar antes de agir."),
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
    /// Models the gallery no longer offers because the package behind them is archived or unmaintained (Slack's
    /// `server-slack`, Notion's npm server). Connectors installed from them keep working and keep their guided form;
    /// nothing is deleted from the person's data.
    static let retired: [ConnectorTemplate] = [
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
    ]

    /// The template an installed connector came from (same name and same server), so that editing it keeps the guided
    /// form. Retired models count: a connector installed from one is still edited with its form.
    /// A remote one is known by its address, whatever the connector was renamed to, and the query of the address does not
    /// count (`?read_only=true` is something the person may take out); a local one by its command and package (the first two
    /// arguments, "-y pkg": what follows, like the folder of Arquivos, is the person's), or by its name and command. A local
    /// server renamed, or installed by the Orb under another name, is still the template's.
    static func matching(_ config: MCPServerConfig) -> ConnectorTemplate? {
        func address(_ url: String) -> Substring { url.prefix { $0 != "?" } }
        func samePackage(_ template: MCPServerConfig) -> Bool {
            let package = template.arguments.prefix(2)
            return !package.isEmpty && config.arguments.starts(with: package)
        }
        return (all + retired).first {
            $0.config.command == config.command && address($0.config.url) == address(config.url)
                && (config.isRemote || $0.config.name == config.name || samePackage($0.config))
        }
    }
}

/// What the editor knows about a connector that is already installed.
enum ConnectorEditing {
    /// `values` without the optional variables or headers left blank: sent as `NAME=""` they would override the server's own
    /// default (and `docker -e NAME` would hand the container an empty value). Required ones and the person's own rows stay.
    static func droppingBlankOptional(_ values: [String: String], inputs: [String: RegistryServer.Input]) -> [String: String] {
        values.filter { name, value in
            guard let input = inputs[name], !input.isRequired else { return true }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

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

extension MCPServerConfig {
    func withNewID() -> MCPServerConfig {
        var copy = self
        copy.id = UUID()
        return copy
    }
}

/// How "Testar conexão" ended.
enum ConnectorTestOutcome: Equatable, Sendable {
    case connected(tools: Int, seconds: Double)
    case failed(String)
}

/// Pure helpers for what the connector screens say.
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

    /// "Conectou: 12 ferramentas em 0,8 s".
    static func tested(tools: Int, seconds: Double) -> String {
        let time = String(format: "%.1f", seconds).replacingOccurrences(of: ".", with: ",")
        return "Conectou: \(tools == 1 ? "1 ferramenta" : "\(tools) ferramentas") em \(time) s"
    }

    /// "12 ferramentas".
    static func toolCount(_ count: Int) -> String { count == 1 ? "1 ferramenta" : "\(count) ferramentas" }

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

    /// The program and its arguments as the server will run, from what was typed: one argument per line, but also the way a
    /// README writes it. A command with spaces ("npx -y football-docs") is split when it is not a file that exists, and a line
    /// that starts with a dash and has spaces ("-y football-docs", "--port 8080") is split too, quotes kept together as a
    /// shell does. Any other line stays whole, so a path with spaces in it ("/Users/ana/Meus Documentos") is one argument.
    /// `literalArguments`: the list is already an argv (the model sent a JSON array), so no line is split.
    static func parse(command: String, arguments: [String], literalArguments: Bool = false,
                      fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> (command: String, arguments: [String]) {
        var program = command.trimmingCharacters(in: .whitespacesAndNewlines)
        var leading: [String] = []
        if program.contains(where: \.isWhitespace), !fileExists((program as NSString).expandingTildeInPath) {
            let words = shellWords(program)
            program = words.first ?? ""
            leading = Array(words.dropFirst())
        }
        let rest = arguments.flatMap { line -> [String] in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return [] }
            // "--q=a b" is one option with a value that has a space; "--port 8080" is two words.
            let firstWord = trimmed.prefix { !$0.isWhitespace }
            let splits = !literalArguments && trimmed.hasPrefix("-") && trimmed.contains(where: \.isWhitespace) && !firstWord.contains("=")
            return splits ? shellWords(trimmed) : [trimmed]
        }
        return (program, leading + rest)
    }

    /// Words as a shell splits them: on spaces, with what is inside quotes kept whole and a backslash keeping the next character.
    static func shellWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var hasWord = false
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                hasWord = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                hasWord = true
            } else if character.isWhitespace {
                if hasWord { words.append(current) }
                current = ""
                hasWord = false
            } else {
                current.append(character)
                hasWord = true
            }
        }
        if hasWord { words.append(current) }
        return words
    }
}
