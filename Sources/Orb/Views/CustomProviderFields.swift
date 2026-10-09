import SwiftUI

/// Extra setup for the custom "Gateway próprio" provider, after its address: which wire format the gateway speaks,
/// the key (optional, drawn by the caller), its headers, and manual model ids (many gateways have no /models).
/// This is the sanctioned way to run the Orb engine against your own Claude/Max subscription: a gateway you run
/// holds the token; the app only talks to it.
struct CustomProviderFields<KeyRow: View>: View {
    @Environment(AppModel.self) private var model
    let account: ProviderAccount
    let health: ProviderHealth
    @ViewBuilder let keyRow: KeyRow

    @State private var headersText = ""
    @State private var newModel = ""
    @State private var isListingAll = false

    /// More models than this are not all shown as chips.
    private var chipsShown: Int { 8 }

    private var isClaudeGateway: Bool { account.format == .messages }
    private var parsedHeaders: GatewayForm.Headers { GatewayForm.parseHeaders(headersText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Formato", selection: Binding(
                get: { account.format },
                set: { format in
                    model.updateProvider(.custom) {
                        $0.format = format
                        for index in $0.models.indices { $0.models[index].format = format }
                    }
                }
            )) {
                Text("Chat (OpenAI)").tag(APIFormat.chat)
                Text("Responses (OpenAI)").tag(APIFormat.responses)
                Text("Messages (Anthropic / Claude)").tag(APIFormat.messages)
            }
            .help(Tip.gatewayFormat)
            Text(GatewayForm.formatSubtitle(account.format))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if isClaudeGateway {
            Label("Para usar sua assinatura (inclusive Max) no Orb, rode um gateway (um servidor intermediário) que faça o login da sua conta e aponte a URL acima para ele. O token fica nesse servidor, não no Orb.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        keyRow

        VStack(alignment: .leading, spacing: 4) {
            Text("Cabeçalhos (opcional)")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Saved from what is typed, not from every change of the text: loading the saved headers into the field must
            // not write them back (an old header the stricter parser flags would be dropped just by opening the row).
            PlaceholderTextEditor(placeholder: "Um por linha, assim:  x-api-key: abc123",
                                  text: Binding(get: { headersText }, set: { headersText = $0; saveHeaders() }), minHeight: 56)
            if let warning = GatewayForm.headerWarning(parsedHeaders) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.warn)
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Modelos")
                .font(.caption)
                .foregroundStyle(.secondary)
            if account.models.isEmpty {
                if GatewayForm.urlState(account.baseURL) == .valid {
                    Text("Nenhum modelo ainda. Use “Atualizar modelos” ou adicione os ids à mão.")
                        .font(.caption)
                        .foregroundStyle(Palette.faint)
                }
            } else {
                // A gateway can list hundreds of models: past eight only the first are chips here (the Form builds
                // them all at once), and the rest are in a list that builds what is on screen.
                ModelChips(models: Array(account.models.prefix(chipsShown)), remove: remove)
                if account.models.count > chipsShown {
                    Button("Ver todos os \(account.models.count) modelos…", systemImage: "list.bullet") { isListingAll = true }
                        .buttonStyle(.borderless)
                        .help(Tip.listAllModels)
                }
            }
            HStack {
                TextField("Adicionar modelo pelo id", text: $newModel, prompt: Text("ex.: claude-fable-5-1"))
                    .onSubmit(addModel)
                Button("Adicionar", action: addModel).disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(Tip.addModelByID)
            }
        }
        .task(id: account.kind) { headersText = serialize(account.headers) }
        .sheet(isPresented: $isListingAll) {
            AllModelsSheet(models: account.models, remove: remove)
        }
    }

    private func serialize(_ headers: [String: String]) -> String {
        headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    /// Only well-formed lines are kept; a malformed one is flagged and waits to be fixed.
    private func saveHeaders() {
        let parsed = parsedHeaders.values
        if parsed != account.headers { model.updateProvider(.custom) { $0.headers = parsed } }
    }

    private func addModel() {
        let id = newModel.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        model.addManualModel(id)
        health.record(nil, for: .custom)
        newModel = ""
    }

    private func remove(_ item: ProviderModel) {
        model.updateProvider(.custom) { $0.models.removeAll { $0.id == item.id } }
    }
}

/// Model ids as removable chips that wrap onto lines.
private struct ModelChips: View {
    let models: [ProviderModel]
    let remove: (ProviderModel) -> Void

    var body: some View {
        WrappingLayout(spacing: 6) {
            ForEach(models) { item in
                HStack(spacing: 4) {
                    Text(item.id).font(.system(size: 11, design: .monospaced))
                    Button("Remover \(item.id)", systemImage: "xmark", action: { remove(item) })
                        .labelStyle(.iconOnly)
                        .font(.system(size: 9, weight: .bold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.muted)
                        .help(Tip.removeModelFromList)
                }
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .padding(.vertical, 3)
                .background(Palette.raised, in: .capsule)
            }
        }
    }
}

/// Lays children left to right and wraps to a new line when a row is full.
struct WrappingLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement = arrange(bounds.width, subviews)
        for (subview, point) in zip(subviews, placement.points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), points)
    }
}

private struct ModelIDRow: View {
    let item: ProviderModel
    let remove: () -> Void

    var body: some View {
        HStack {
            Text(item.id).font(.caption.monospaced())
            Spacer()
            Button("Remover", systemImage: "minus.circle", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.muted)
                .help(Tip.removeModelFromList)
        }
    }
}

/// Every model of the gateway, searchable, built as it scrolls.
private struct AllModelsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let models: [ProviderModel]
    let remove: (ProviderModel) -> Void
    @State private var query = ""

    var body: some View {
        let shown = models.filter { ModelSearch.matches($0, query) }
        VStack(spacing: 0) {
            HStack {
                TextField("Buscar modelo", text: $query)
                    .textFieldStyle(.roundedBorder)
                Text(shown.count == models.count ? "\(models.count) modelos" : "\(shown.count) de \(models.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { item in
                        ModelIDRow(item: item) { remove(item) }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                    }
                }
            }
            .frame(minHeight: 260, idealHeight: 330, maxHeight: .infinity)
        }
        .orbSheet("Modelos do gateway", subtitle: "\(models.count) modelos · remova os que não usa", size: .small) {
            HStack {
                Spacer()
                // Esc closes; Return does too, as the old "OK" did.
                Button("Fechar") { dismiss() }
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.cancelAction)
                    .background {
                        Button("Fechar") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                            .frame(width: 0, height: 0)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Divider().opacity(0.6) }
        }
    }
}
