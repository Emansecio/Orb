import Foundation

/// A service in the gallery of the Conectores page: a card with a name, a line about it and one button. The icon is the
/// brand's logo when there is one (`BrandMarks`, embedded in the source: nothing is downloaded), else a SF Symbol or a
/// letter on the brand's colour.
struct ServiceMark: Sendable, Equatable {
    var symbol: String?
    var monogram: String
    /// The brand's colour, as 0xRRGGBB.
    var color: UInt32
    /// The brand's key in `BrandMarks` (its Simple Icons slug); nil for Apple's apps and the generic tools, which keep
    /// their symbol.
    var brand: String?

    /// The logo to draw, when the brand has one.
    var logo: BrandMark? { brand.flatMap(BrandMarks.mark) }

    /// The colour of the mark on the dark tile: the brand's own (or the generic connector's), or nil (white) when that
    /// would not be read there.
    var inkHex: UInt32? {
        let hex = logo?.hex ?? color
        return BrandMark.readsOnDarkTile(hex) ? hex : nil
    }
}

struct ConnectorService: Identifiable, Sendable {
    enum Source: Sendable, Equatable {
        /// A ready-made server (`ConnectorTemplate.id`).
        case template(String)
        /// A connector that runs on this Mac.
        case local(LocalConnectorKind)
        /// Not available yet.
        case soon
    }

    let id: String
    let name: String
    let summary: String
    let mark: ServiceMark
    let source: Source
    let access: Access

    /// How it connects, in two or three words: "Pelo Mac", "Chave de acesso", "Não precisa de chave".
    var how: String { access.label }

    enum Access: Sendable, Equatable {
        case onThisMac, loginWithApp, loginWithAccount, key, noKey

        var label: String {
            switch self {
            case .onThisMac: "Pelo Mac"
            case .loginWithApp: "Login com seu app"
            case .loginWithAccount: "Login com a conta"
            case .key: "Chave de acesso"
            case .noKey: "Não precisa de chave"
            }
        }

        /// The badge's symbol, kept here so the card does not guess it from `label`; nil where nothing is asked of the person.
        var symbol: String? {
            switch self {
            case .onThisMac: "desktopcomputer"
            case .loginWithApp, .loginWithAccount: "person.crop.circle"
            case .key: "key"
            case .noKey: nil
            }
        }
    }

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
                         mark: ServiceMark(symbol: "envelope.fill", monogram: "G", color: 0xEA4335, brand: "gmail"), source: .local(.gmail), access: .onThisMac),
        ConnectorService(id: "agenda", name: "Google Agenda", summary: LocalConnectorKind.agenda.summary,
                         mark: ServiceMark(symbol: "calendar", monogram: "A", color: 0x4285F4, brand: "googlecalendar"), source: .local(.agenda), access: .onThisMac),
        ConnectorService(id: "slack", name: "Slack", summary: "Buscar e ler mensagens e canais e, se você liberar, enviar. Servidor oficial do Slack.",
                         mark: ServiceMark(symbol: "number", monogram: "S", color: 0x611F69, brand: "slack"), source: .template("slack-oficial"), access: .loginWithApp),
        ConnectorService(id: "notion", name: "Notion", summary: "Buscar e editar páginas e bancos de dados. Você entra com a sua conta.",
                         mark: ServiceMark(symbol: nil, monogram: "N", color: 0x2F3437, brand: "notion"), source: .template("notion-oficial"), access: .loginWithAccount),
        ConnectorService(id: "github", name: "GitHub", summary: "Ler repositórios, issues e pull requests do GitHub.",
                         mark: ServiceMark(symbol: "chevron.left.forwardslash.chevron.right", monogram: "G", color: 0x30363D, brand: "github"),
                         source: .template("github"), access: .key),
        ConnectorService(id: "supabase", name: "Supabase", summary: "Consultar os projetos e as tabelas do seu Supabase, em leitura.",
                         mark: ServiceMark(symbol: "bolt.fill", monogram: "S", color: 0x1E9E6A, brand: "supabase"), source: .template("supabase"), access: .key),
        ConnectorService(id: "linear", name: "Linear", summary: "Ver e atualizar issues e projetos. Você entra com a sua conta.",
                         mark: ServiceMark(symbol: nil, monogram: "L", color: 0x5E6AD2, brand: "linear"), source: .template("linear"), access: .loginWithAccount),
        ConnectorService(id: "atlassian", name: "Atlassian", summary: "Buscar e editar issues do Jira e páginas do Confluence. Você entra com a sua conta.",
                         mark: ServiceMark(symbol: nil, monogram: "A", color: 0x0052CC, brand: "atlassian"), source: .template("atlassian"), access: .loginWithAccount),
        ConnectorService(id: "sentry", name: "Sentry", summary: "Ver erros, issues e projetos do Sentry. Você entra com a sua conta.",
                         mark: ServiceMark(symbol: nil, monogram: "S", color: 0x362D59, brand: "sentry"), source: .template("sentry"), access: .loginWithAccount),
        ConnectorService(id: "lembretes", name: "Lembretes", summary: LocalConnectorKind.lembretes.summary,
                         mark: ServiceMark(symbol: "checklist", monogram: "L", color: 0xFF9500), source: .local(.lembretes), access: .onThisMac),
        ConnectorService(id: "arquivos", name: "Arquivos", summary: "Ler e organizar arquivos de uma pasta do Mac. Você escolhe qual pasta fica liberada.",
                         mark: ServiceMark(symbol: "folder.fill", monogram: "A", color: 0x636366), source: .template("arquivos"), access: .noKey),
        ConnectorService(id: "memoria", name: "Memória (grafo)", summary: "Guarda fatos e as relações entre eles para os Orbs consultarem depois.",
                         mark: ServiceMark(symbol: "brain", monogram: "M", color: 0x7D5BE6), source: .template("memoria"), access: .noKey),
        ConnectorService(id: "pensamento", name: "Pensamento em etapas", summary: "Ajuda o Orb a pensar passo a passo em problemas difíceis.",
                         mark: ServiceMark(symbol: "lightbulb.fill", monogram: "P", color: 0xC98A00), source: .template("pensamento"), access: .noKey),
        ConnectorService(id: "fetch", name: "Busca na web (Fetch)", summary: "Baixa uma página da web e converte em texto. O Orb já lê páginas sozinho.",
                         mark: ServiceMark(symbol: "globe", monogram: "F", color: 0x0A84FF), source: .template("fetch"), access: .noKey),
    ]

    /// The installed connector a service stands for, if any.
    static func installed(_ service: ConnectorService, in connectors: [MCPServerConfig]) -> MCPServerConfig? {
        switch service.source {
        case .local(let kind): connectors.first { $0.local == kind.rawValue }
        case .template(let id): connectors.first { ConnectorTemplate.matching($0)?.id == id }
        case .soon: nil
        }
    }

    /// The gallery card an installed connector stands for, if any: a connector of this Mac by its kind, a ready-made server
    /// by the template it came from (the retired Notion and Slack models stand for today's cards), whatever it was renamed
    /// to. A custom or registry connector has none.
    static func service(for connector: MCPServerConfig) -> ConnectorService? {
        if let local = connector.local { return services.first { $0.localKind?.rawValue == local } }
        guard let template = ConnectorTemplate.matching(connector)?.id else { return nil }
        let id = retiredTemplates[template] ?? template
        return services.first { $0.source == .template(id) }
    }

    /// Models the gallery no longer offers (`ConnectorTemplate.retired`) and the template of the card that replaced each.
    private static let retiredTemplates = ["notion": "notion-oficial", "slack": "slack-oficial"]

    /// What the card says. A failed connection and a local connector that lacks a permission or an account both ask for
    /// attention; one that is only closed (Mail not open) does not.
    static func status(of service: ConnectorService, connectors: [MCPServerConfig], statuses: [UUID: MCPStatus],
                       local: [LocalConnectorKind: LocalConnectorState]) -> ServiceStatus {
        if case .soon = service.source { return .soon }
        guard let connector = installed(service, in: connectors) else { return .available }
        guard connector.isEnabled else { return .off }
        switch statuses[connector.id] {
        case .failed(let message)?: return .needsAttention(ConnectorStatusText.shortError(message, limit: 90))
        case .needsSignIn(let expired)?: return .needsAttention(expired ?? "Falta entrar com a sua conta.")
        case .needsMorePermission?: return .needsAttention("Precisa de mais permissão.")
        default: break
        }
        if let kind = service.localKind, let state = local[kind], state.needsAttention { return .needsAttention(state.message) }
        return .connected
    }
}
