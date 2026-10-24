import SwiftUI

/// The gallery of the Conectores page: one card per service, one click to connect. A card says what the service does and how it
/// connects, and its button says where it stands: Conectar, Conectado, Desativado, Resolver (something needs the person) or Em breve.
struct ConnectorGalleryView: View {
    @Environment(AppModel.self) private var model
    @Binding var editing: ConnectorDraft?
    @Binding var settingUp: LocalConnectorKind?
    let explore: () -> Void
    /// Shows an installed connector in the Instalados tab.
    let showInstalled: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Escolha um serviço e clique em Conectar. Os Orbs que você escolher passam a usá-lo, sempre pedindo antes de enviar ou apagar algo.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                // A warning line under one card would make it taller than its neighbours: while any card has one, all keep its room.
                let statuses = ConnectorGallery.services.map { ($0, status(of: $0)) }
                let reservesNote = statuses.contains { if case .needsAttention = $0.1 { true } else { false } }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(statuses, id: \.0.id) { service, status in
                        ServiceCard(service: service, status: status, reservesNote: reservesNote) { open(service, status: status) }
                    }
                }
                HStack(spacing: 6) {
                    Text("Não achou o que procura?").foregroundStyle(Palette.muted)
                    Button("Explorar o registro de conectores", action: explore).buttonStyle(.link)
                        .help("Abre a busca no registro oficial de conectores")
                }
                .font(.system(size: 12))
            }
            .pageColumn()
        }
        .task { await model.refreshLocalStates() }
    }

    private func status(of service: ConnectorService) -> ServiceStatus {
        ConnectorGallery.status(of: service, connectors: model.connectors, statuses: model.connectorStatus, local: model.localStates)
    }

    /// A new service opens its setup; one that is installed goes to the Instalados tab, where it is managed, unless it
    /// needs attention: that opens it to fix, as the card says.
    private func open(_ service: ConnectorService, status: ServiceStatus) {
        if status == .soon { return }
        let installed = ConnectorGallery.installed(service, in: model.connectors)
        if let installed, status == .connected || status == .off {
            showInstalled(installed.id)
        } else if let kind = service.localKind {
            settingUp = kind
        } else if let installed {
            editing = ConnectorDraft(editing: installed)
        } else if let template = service.template {
            var draft = ConnectorDraft(template: template)
            // Two connectors with one name would be one to the model (it names a connector), as a Slack installed from the old
            // package and the official one would be.
            if model.connectors.contains(where: { $0.name == draft.config.name }) {
                draft.config.name += template.id == "slack-oficial" ? " (oficial)" : " (2)"
            }
            editing = draft
        }
    }
}

/// The icon of a service, the same everywhere (the gallery, the installed list, the sheets): one dark tile, and on it the
/// brand's logo, or the SF Symbol of an Apple app or a generic tool, drawn in the brand's (or the tool's) colour, or in
/// white when that colour would not be read on the dark tile. The name sits beside it, so it is hidden from VoiceOver.
struct ServiceTile: View {
    let mark: ServiceMark
    var size: CGFloat = 36

    /// The share of the tile the longer side of a brand mark takes: the same for all of them, whatever box each one
    /// draws in (`BrandShape` scales by the mark's own bounding box).
    private static let markFill: CGFloat = 0.5
    /// The size of a symbol, as a share of the tile, so it weighs about as much as a brand mark.
    private static let symbolSize: CGFloat = 0.46

    var body: some View {
        let ink = mark.inkHex.map { Color(hex: $0) } ?? Palette.ink
        let corner = size * 0.28
        content(ink: ink)
            .frame(width: size, height: size)
            .background(Palette.raised, in: .rect(cornerRadius: corner))
            .overlay { RoundedRectangle(cornerRadius: corner).strokeBorder(Palette.line, lineWidth: 1) }
            .accessibilityHidden(true)
    }

    @ViewBuilder private func content(ink: Color) -> some View {
        if let logo = mark.logo, let glyph = BrandMarks.glyph(logo.slug) {
            BrandShape(glyph: glyph, fill: Self.markFill).fill(ink)
        } else if let symbol = mark.symbol {
            Image(systemName: symbol)
                .font(.system(size: size * Self.symbolSize, weight: .medium))
                .foregroundStyle(ink)
        } else {
            Text(mark.monogram)
                .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                .foregroundStyle(ink)
        }
    }
}

/// A brand mark centred in its rect, its longer side taking `fill` of the shorter side of the rect.
struct BrandShape: Shape {
    let glyph: BrandGlyph
    var fill: CGFloat = 0.5

    func path(in rect: CGRect) -> Path {
        let box = glyph.bounds
        guard box.width > 0, box.height > 0 else { return Path() }
        let scale = min(rect.width, rect.height) * fill / max(box.width, box.height)
        let transform = CGAffineTransform(translationX: -box.midX, y: -box.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        return glyph.path.applying(transform)
    }
}

/// The icon of an installed connector: the one its gallery card has (a brand's logo, or the symbol of Arquivos, Memória,
/// Lembretes…), else the generic symbol for where a custom one runs.
struct ConnectorIcon: View {
    let connector: MCPServerConfig

    var body: some View {
        if let mark = ConnectorGallery.service(for: connector)?.mark {
            ServiceTile(mark: mark)
        } else {
            CatalogIcon(symbol: connector.local != nil ? "desktopcomputer" : connector.isRemote ? "cloud" : "puzzlepiece.extension")
        }
    }
}

private struct ServiceCard: View {
    let service: ConnectorService
    let status: ServiceStatus
    let reservesNote: Bool
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    ServiceTile(mark: service.mark)
                    Text(service.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(service.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if case .needsAttention(let message) = status {
                    note(message).transition(.opacity)
                } else if reservesNote {
                    note(" ").hidden().accessibilityHidden(true)
                }
                HStack(spacing: 6) {
                    CatalogBadge(text: service.how, symbol: service.localKind != nil ? "desktopcomputer" : service.how.hasPrefix("Login") ? "person.crop.circle" : service.how == "Não precisa de chave" ? nil : "key")
                    Spacer(minLength: 0)
                    label
                }
                // The button and the badges differ in height: the row keeps one so the cards of a line stay level.
                .frame(minHeight: 26)
            }
            .padding(14)
            .card(radius: 14, fill: isHovering && status != .soon ? Palette.raised : Palette.surface,
                  stroke: isHovering && status != .soon ? Palette.lineStrong : Palette.line)
            .opacity(status == .soon || status == .off ? 0.7 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(status == .soon)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : Motion.hover(isHovering), value: isHovering)
        .animateChanges(of: status)
        .accessibilityLabel("\(service.name). \(service.summary) \(spoken)")
        .accessibilityHint(hint)
    }

    private func note(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(Palette.warn)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
    }

    /// The button's face: it is the whole card that is clicked, so this only says what a click does.
    @ViewBuilder private var label: some View {
        switch status {
        case .available:
            // The secondary pill, not the white one: with a dozen cards side by side, white on each would make every card
            // the screen's main action.
            Text("Conectar")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.1), in: .capsule)
        case .connected:
            CatalogBadge(text: "Conectado", symbol: "checkmark.circle.fill", tint: Palette.ok)
        case .off:
            CatalogBadge(text: "Desativado", symbol: "pause.circle")
        case .needsAttention:
            Text("Resolver")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.onInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Palette.warn, in: .capsule)
        case .soon:
            CatalogBadge(text: "Em breve", symbol: "clock")
        }
    }

    /// What a click on the card does.
    private var help: String {
        switch status {
        case .available: "Abre a conexão com \(service.name)"
        case .connected, .off: "Mostra \(service.name) entre os instalados, para editar ou mudar os Orbs que o usam"
        case .needsAttention: "Abre \(service.name) para resolver o que falta"
        case .soon: "\(service.name) ainda não está disponível"
        }
    }

    private var hint: String {
        switch status {
        case .available: "Abre a conexão"
        case .connected, .off: "Mostra entre os instalados"
        case .needsAttention: "Abre os ajustes"
        case .soon: ""
        }
    }

    private var spoken: String {
        switch status {
        case .available: "Não conectado."
        case .connected: "Conectado."
        case .off: "Desativado."
        case .needsAttention(let message): "Precisa de atenção: \(message)"
        case .soon: "Em breve."
        }
    }
}
