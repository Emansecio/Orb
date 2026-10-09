import Foundation

/// A service in the gallery of the Conectores page: a card with a name, a line about it and one button. The icon is a SF
/// Symbol or a letter on the brand's colour (no logo is downloaded or bundled).
struct ServiceMark: Sendable, Equatable {
    var symbol: String?
    var monogram: String
    /// The brand's colour, as 0xRRGGBB.
    var color: UInt32
}

struct ConnectorService: Identifiable, Sendable {
    enum Source: Sendable, Equatable {
        /// A ready-made server (`ConnectorTemplate.id`).
        case template(String)
        /// A connector that runs on this Mac.
        case local(LocalConnectorKind)
        /// Needs a sign-in the Orb does not do yet; the next batch brings it.
        case soon
    }

    let id: String
    let name: String
    let summary: String
    let mark: ServiceMark
    let source: Source
    /// How it connects, in two or three words: "Pelo Mac", "Chave de acesso", "Sem chave".
    let how: String

    /// The ready-made server behind the card.
    var template: ConnectorTemplate? {
        if case .template(let id) = source { ConnectorTemplate.all.first { $0.id == id } } else { nil }
    }

    var localKind: LocalConnectorKind? { if case .local(let kind) = source { kind } else { nil } }
}

/// Where a service stands for this person: what the card's button says.
enum ServiceStatus: Equatable, Sendable {
    case available
    case connected
    /// Installed but switched off.
    case off
    /// Installed, and something needs the person: the line says what.
    case needsAttention(String)
    case soon
}

enum ConnectorGallery {
    /// The gallery, in the order the page shows it: the services people ask for first.
    static let services: [ConnectorService] = [
        ConnectorService(id: "gmail", name: "Gmail", summary: LocalConnectorKind.gmail.summary,
                         mark: ServiceMark(symbol: "envelope.fill", monogram: "G", color: 0xEA4335), source: .local(.gmail), how: "Pelo Mac"),
        ConnectorService(id: "agenda", name: "Google Agenda", summary: LocalConnectorKind.agenda.summary,
                         mark: ServiceMark(symbol: "calendar", monogram: "A", color: 0x4285F4), source: .local(.agenda), how: "Pelo Mac"),
        ConnectorService(id: "slack", name: "Slack", summary: "Buscar e ler mensagens e canais e, se você liberar, enviar. Servidor oficial do Slack.",
                         mark: ServiceMark(symbol: "number", monogram: "S", color: 0x611F69), source: .template("slack-oficial"), how: "App seu no Slack"),
        ConnectorService(id: "notion", name: "Notion", summary: "Buscar e editar páginas e bancos de dados. Entra com a sua conta, em breve.",
                         mark: ServiceMark(symbol: nil, monogram: "N", color: 0x2F3437), source: .soon, how: "Login com a conta"),
        ConnectorService(id: "github", name: "GitHub", summary: "Ler repositórios, issues e pull requests do GitHub.",
                         mark: ServiceMark(symbol: "chevron.left.forwardslash.chevron.right", monogram: "G", color: 0x30363D),
                         source: .template("github"), how: "Chave de acesso"),
        ConnectorService(id: "supabase", name: "Supabase", summary: "Consultar os projetos e as tabelas do seu Supabase, em leitura.",
                         mark: ServiceMark(symbol: "bolt.fill", monogram: "S", color: 0x1E9E6A), source: .template("supabase"), how: "Chave de acesso"),
        ConnectorService(id: "linear", name: "Linear", summary: "Ver e atualizar issues e projetos. Entra com a sua conta, em breve.",
                         mark: ServiceMark(symbol: nil, monogram: "L", color: 0x5E6AD2), source: .soon, how: "Login com a conta"),
        ConnectorService(id: "lembretes", name: "Lembretes", summary: LocalConnectorKind.lembretes.summary,
                         mark: ServiceMark(symbol: "checklist", monogram: "L", color: 0xFF9500), source: .local(.lembretes), how: "Pelo Mac"),
        ConnectorService(id: "arquivos", name: "Arquivos", summary: "Ler e organizar arquivos de uma pasta do Mac. Você escolhe qual pasta fica liberada.",
                         mark: ServiceMark(symbol: "folder.fill", monogram: "A", color: 0x636366), source: .template("arquivos"), how: "Sem chave"),
        ConnectorService(id: "memoria", name: "Memória (grafo)", summary: "Guarda fatos e as relações entre eles para os Orbs consultarem depois.",
                         mark: ServiceMark(symbol: "brain", monogram: "M", color: 0x7D5BE6), source: .template("memoria"), how: "Sem chave"),
        ConnectorService(id: "pensamento", name: "Pensamento em etapas", summary: "Ajuda o Orb a pensar passo a passo em problemas difíceis.",
                         mark: ServiceMark(symbol: "lightbulb.fill", monogram: "P", color: 0xC98A00), source: .template("pensamento"), how: "Sem chave"),
        ConnectorService(id: "fetch", name: "Busca na web (Fetch)", summary: "Baixa uma página da web e converte em texto. O Orb já lê páginas sozinho.",
                         mark: ServiceMark(symbol: "globe", monogram: "F", color: 0x0A84FF), source: .template("fetch"), how: "Sem chave"),
    ]

    /// The installed connector a service stands for, if any.
    static func installed(_ service: ConnectorService, in connectors: [MCPServerConfig]) -> MCPServerConfig? {
        switch service.source {
        case .local(let kind): connectors.first { $0.local == kind.rawValue }
        case .template(let id): connectors.first { ConnectorTemplate.matching($0)?.id == id }
        case .soon: nil
        }
    }

    /// What the card says. A failed connection and a local connector that lacks a permission or an account both ask for
    /// attention; one that is only closed (Mail not open) does not.
    static func status(of service: ConnectorService, connectors: [MCPServerConfig], statuses: [UUID: MCPStatus],
                       local: [LocalConnectorKind: LocalConnectorState]) -> ServiceStatus {
        if case .soon = service.source { return .soon }
        guard let connector = installed(service, in: connectors) else { return .available }
        guard connector.isEnabled else { return .off }
        if case .failed(let message)? = statuses[connector.id] { return .needsAttention(ConnectorStatusText.shortError(message, limit: 90)) }
        if let kind = service.localKind, let state = local[kind], state.needsAttention { return .needsAttention(state.message) }
        return .connected
    }
}
