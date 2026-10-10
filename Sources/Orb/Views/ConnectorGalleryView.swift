import SwiftUI

/// The gallery of the Conectores page: one card per service, one click to connect. A card says what the service does and how it
/// connects, and its button says where it stands: Conectar, Conectado, Desligado, Resolver (something needs the person) or Em breve.
struct ConnectorGalleryView: View {
    @Environment(AppModel.self) private var model
    @Binding var editing: ConnectorDraft?
    @Binding var settingUp: LocalConnectorKind?
    let explore: () -> Void

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
            .padding(24)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .task { await model.refreshLocalStates() }
    }

    private func status(of service: ConnectorService) -> ServiceStatus {
        ConnectorGallery.status(of: service, connectors: model.connectors, statuses: model.connectorStatus, local: model.localStates)
    }

    /// A new service opens its setup; one that is installed opens it to edit (and, if it needs attention, to fix).
    private func open(_ service: ConnectorService, status: ServiceStatus) {
        if status == .soon { return }
        let installed = ConnectorGallery.installed(service, in: model.connectors)
        if let kind = service.localKind {
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

/// The icon of a service: the brand's logo when `BrandMarks` has it, else a symbol or a letter on the brand's colour.
struct ServiceTile: View {
    let mark: ServiceMark
    var size: CGFloat = 36

    var body: some View {
        if let logo = mark.logo, let glyph = BrandMarks.glyph(logo.slug) {
            BrandTile(logo: logo, glyph: glyph, size: size)
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Group {
            if let symbol = mark.symbol {
                Image(systemName: symbol).font(.system(size: size * 0.44, weight: .semibold))
            } else {
                Text(mark.monogram).font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(Color(hex: mark.color), in: .rect(cornerRadius: size * 0.28))
        .accessibilityHidden(true)
    }
}

/// A brand mark on a rounded tile: in the brand's colour on the dark surface, or white (on the dark surface for a
/// near-black brand, on a tile of the brand's colour for a dark one). The name sits beside it, so it is hidden from
/// VoiceOver.
struct BrandTile: View {
    let logo: BrandMark
    let glyph: BrandGlyph
    var size: CGFloat = 36

    /// The share of the tile the mark's longer side takes.
    private static let fill: CGFloat = 0.5

    var body: some View {
        let treatment = logo.treatment
        let corner = size * 0.28
        BrandShape(glyph: glyph, fill: Self.fill)
            .fill(treatment == .brandOnDark ? Color(hex: logo.hex) : Palette.ink)
            .frame(width: size, height: size)
            .background(treatment == .whiteOnBrand ? Color(hex: logo.hex) : Palette.raised, in: .rect(cornerRadius: corner))
            .overlay { RoundedRectangle(cornerRadius: corner).strokeBorder(Palette.line, lineWidth: treatment == .whiteOnBrand ? 0 : 1) }
            .accessibilityHidden(true)
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

/// The icon of an installed connector: its service's logo (or tile) when the gallery knows it as a brand, else the
/// generic symbol for where it runs.
struct ConnectorIcon: View {
    let connector: MCPServerConfig

    var body: some View {
        if let mark = ConnectorGallery.service(for: connector)?.mark.ifBranded {
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
                    CatalogBadge(text: service.how, symbol: service.localKind != nil ? "desktopcomputer" : service.how.hasPrefix("Login") ? "person.crop.circle" : service.how == "Sem chave" ? nil : "key")
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
        .accessibilityHint(status == .soon ? "" : status == .available ? "Abre a conexão" : "Abre os ajustes")
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
            Text("Conectar")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.onInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Palette.ink, in: .capsule)
        case .connected:
            CatalogBadge(text: "Conectado", symbol: "checkmark.circle.fill", tint: Palette.ok)
        case .off:
            CatalogBadge(text: "Desligado", symbol: "pause.circle")
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
        case .connected, .off: "Abre \(service.name) para editar ou mudar os Orbs que o usam"
        case .needsAttention: "Abre \(service.name) para resolver o que falta"
        case .soon: "\(service.name) ainda não está disponível"
        }
    }

    private var spoken: String {
        switch status {
        case .available: "Não conectado."
        case .connected: "Conectado."
        case .off: "Desligado."
        case .needsAttention(let message): "Precisa de atenção: \(message)"
        case .soon: "Em breve."
        }
    }
}
