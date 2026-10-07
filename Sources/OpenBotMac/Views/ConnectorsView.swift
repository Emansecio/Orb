import SwiftUI

/// Connectors (MCP servers): the installed ones (enable, status, edit, delete) and the official registry.
struct ConnectorsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = CatalogTab.installed
    @State private var editing: ConnectorDraft?

    var body: some View {
        VStack(spacing: 0) {
            CatalogTabBar(tab: $tab, installedTitle: "Instalados", installedCount: model.connectors.count)
                .padding(.top, 16)
                .padding(.bottom, 4)
            switch tab {
            case .installed: InstalledConnectors(editing: $editing, explore: { tab = .explore })
            case .explore: ExploreConnectors(editing: $editing)
            }
        }
        .background(Palette.canvas)
        .navigationTitle("Conectores")
        .navigationSubtitle("Servidores MCP que dão novas ferramentas aos bots")
        .toolbar {
            Button("Reconectar", systemImage: "arrow.clockwise") { model.syncConnectors() }
                .help("Reconectar conectores com erro")
            Button("Adicionar manualmente", systemImage: "plus") {
                editing = ConnectorDraft(config: MCPServerConfig(name: ""))
            }
            .help("Adicionar um servidor MCP pelo comando ou URL")
        }
        .sheet(item: $editing) { draft in
            ConnectorEditor(draft: draft)
        }
    }
}

/// A connector being added or edited, plus what its registry entry asks the user to fill in.
struct ConnectorDraft: Identifiable {
    var config: MCPServerConfig
    var inputs: [RegistryServer.Input] = []
    var id: UUID { config.id }
}

// MARK: Installed

private struct InstalledConnectors: View {
    @Environment(AppModel.self) private var model
    @Binding var editing: ConnectorDraft?
    let explore: () -> Void
    @State private var deleting: MCPServerConfig?

    var body: some View {
        @Bindable var model = model
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                ForEach($model.connectors) { $connector in
                    ConnectorCard(connector: $connector, status: model.connectorStatus[connector.id]) {
                        editing = ConnectorDraft(config: connector)
                    } onDelete: {
                        deleting = connector
                    }
                }
            }
            .padding(24)
        }
        .overlay {
            if model.connectors.isEmpty {
                ContentUnavailableView {
                    Label("Nenhum conector", systemImage: "point.3.filled.connected.trianglepath.dotted")
                } description: {
                    Text("Conectores dão novas ferramentas aos bots que têm “Conectores” ativado no painel.")
                } actions: {
                    Button("Explorar catálogo", action: explore).buttonStyle(PrimaryPillStyle())
                }
            }
        }
        .confirmationDialog("Apagar o conector “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Apagar", role: .destructive) {
                if let id = deleting?.id { model.connectors.removeAll { $0.id == id } }
            }
        } message: {
            Text("As chaves e variáveis dele também serão apagadas.")
        }
    }
}

private struct ConnectorCard: View {
    @Binding var connector: MCPServerConfig
    let status: MCPStatus?
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                CatalogIcon(symbol: connector.isRemote ? "cloud" : "puzzlepiece.extension")
                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(connector.isRemote ? connector.url : ([connector.command] + connector.arguments).joined(separator: " "))
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Toggle("Ativo", isOn: $connector.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help(connector.isEnabled ? "Desativar (fica instalado, mas os bots não usam)" : "Ativar")
            }
            HStack(spacing: 6) {
                statusBadge
                if let source = connector.source {
                    CatalogBadge(text: source, symbol: "shippingbox")
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Editar…", action: onEdit)
                    Divider()
                    Button("Apagar…", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 22)
                        .contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(14)
        .card(radius: 14)
        .opacity(connector.isEnabled ? 1 : 0.55)
        .animation(.snappy(duration: 0.2), value: connector.isEnabled)
    }

    @ViewBuilder private var statusBadge: some View {
        switch status {
        case .ready(let count):
            CatalogBadge(text: count == 1 ? "1 ferramenta" : "\(count) ferramentas", symbol: "checkmark.circle.fill", tint: Palette.ok)
        case .failed(let message):
            CatalogBadge(text: "Erro", symbol: "exclamationmark.triangle.fill", tint: Palette.warn)
                .help(message)
        case .starting:
            CatalogBadge(text: "Conectando…", symbol: "hourglass")
        case .stopped, nil:
            CatalogBadge(text: "Desligado", symbol: "pause.circle")
        }
    }
}

// MARK: Explore

private struct ExploreConnectors: View {
    @Environment(AppModel.self) private var model
    @Binding var editing: ConnectorDraft?
    @State private var query = ""
    @State private var results: [RegistryServer] = []
    @State private var isLoading = false
    @State private var error: String?

    private static let suggestions = ["github", "slack", "notion", "google", "postgres", "filesystem", "browser",
                                      "linear", "figma", "stripe"]

    private var isSearching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CatalogSearchHeader(query: $query, prompt: "Buscar no registro oficial do MCP", suggestions: Self.suggestions)
                if !isSearching {
                    Text("Em destaque")
                        .font(.system(size: 13, weight: .semibold))
                    grid(MCPServerConfig.templates.map { ConnectorDraft(config: $0.withNewID()) }) { draft in
                        FeaturedConnectorCard(config: draft.config) { editing = draft }
                    }
                    Text("A busca usa o registro oficial do MCP (registry.modelcontextprotocol.io). O nome de cada servidor é verificado pelo registro, mas o código é de quem publicou.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.faint)
                } else if isLoading || error != nil || results.isEmpty {
                    CatalogStateView(isLoading: isLoading, error: error, isEmpty: results.isEmpty,
                                     slowHint: "O registro às vezes demora até um minuto…", retry: { Task { await search() } })
                } else {
                    grid(results) { server in
                        RegistryServerCard(server: server, isInstalled: model.installedConnector(server.id) != nil) {
                            editing = ConnectorDraft(config: server.config.withNewID(), inputs: server.inputs)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    private func grid<Item: Identifiable, Card: View>(_ items: [Item], @ViewBuilder card: @escaping (Item) -> Card) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12)], spacing: 12) {
            ForEach(items) { card($0) }
        }
    }

    private func search() async {
        guard isSearching else { results = []; return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let found = try await MCPRegistry.shared.search(query.trimmingCharacters(in: .whitespaces))
            if !Task.isCancelled { results = found }
        } catch {
            // A newer search cancels this one; only real failures are shown.
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

private struct RegistryServerCard: View {
    let server: RegistryServer
    let isInstalled: Bool
    let onAdd: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onAdd) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    CatalogIcon(symbol: server.config.isRemote ? "cloud" : "puzzlepiece.extension")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(server.id)
                            .font(.system(size: 11).monospaced())
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if isInstalled {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok).help("Instalado")
                    }
                }
                Text(server.summary.isEmpty ? "Sem descrição." : server.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(3, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if server.isOfficial {
                        CatalogBadge(text: "Oficial", symbol: "checkmark.seal.fill", tint: Palette.accentText)
                    }
                    CatalogBadge(text: server.kindLabel, symbol: server.config.isRemote ? "cloud" : "desktopcomputer")
                    let required = server.inputs.filter(\.isRequired).count
                    if required > 0 {
                        CatalogBadge(text: required == 1 ? "Pede 1 chave" : "Pede \(required) chaves", symbol: "key")
                    }
                }
            }
            .padding(14)
            .card(radius: 14, fill: isHovering ? Palette.raised : Palette.surface,
                  stroke: isHovering ? Palette.lineStrong : Palette.line)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct FeaturedConnectorCard: View {
    let config: MCPServerConfig
    let onAdd: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: 12) {
                CatalogIcon(symbol: "puzzlepiece.extension")
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(([config.command] + config.arguments.prefix(2)).joined(separator: " "))
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle")
                    .foregroundStyle(Palette.muted)
            }
            .padding(14)
            .card(radius: 14, fill: isHovering ? Palette.raised : Palette.surface,
                  stroke: isHovering ? Palette.lineStrong : Palette.line)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: Editor

/// Add/edit a connector. Registry entries arrive pre-filled; the user only fills in keys and variables.
private struct ConnectorEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: ConnectorDraft

    @State private var config = MCPServerConfig(name: "")
    @State private var isRemote = false
    @State private var arguments = ""
    @State private var values: [KeyValueRow] = []

    private var isNew: Bool { !model.connectors.contains { $0.id == draft.config.id } }
    private var inputsByName: [String: RegistryServer.Input] {
        Dictionary(draft.inputs.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }
    private var missingRequired: [String] {
        draft.inputs.filter(\.isRequired).map(\.name).filter { name in
            values.first { $0.key == name }?.value.trimmingCharacters(in: .whitespaces).isEmpty ?? true
        }
    }
    private var canSave: Bool {
        !config.name.trimmingCharacters(in: .whitespaces).isEmpty && missingRequired.isEmpty
            && !(isRemote ? config.url : config.command).trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Nome", text: $config.name)
                    if config.source == nil {
                        Picker("Tipo", selection: $isRemote) {
                            Text("Local (comando)").tag(false)
                            Text("Remoto (URL)").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    if isRemote {
                        TextField("URL", text: $config.url, prompt: Text("https://exemplo.com/mcp"))
                    } else {
                        TextField("Comando", text: $config.command, prompt: Text("npx, uvx, docker, /caminho/do/servidor"))
                    }
                } footer: {
                    if let source = config.source { Text("Do registro: \(source)") }
                }
                if !isRemote {
                    Section("Argumentos (um por linha)") {
                        TextEditor(text: $arguments).font(.body.monospaced()).frame(minHeight: 54)
                    }
                }
                Section {
                    ForEach($values) { $row in
                        KeyValueField(row: $row, input: inputsByName[row.key]) {
                            values.removeAll { $0.id == row.id }
                        }
                    }
                    Button(isRemote ? "Adicionar cabeçalho" : "Adicionar variável", systemImage: "plus") {
                        values.append(KeyValueRow(key: "", value: ""))
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text(isRemote ? "Cabeçalhos HTTP" : "Variáveis de ambiente")
                } footer: {
                    Text(isRemote
                         ? "Enviados só para a URL acima. Ficam no arquivo de dados do app, sem criptografia."
                         : "O comando roda com o PATH do seu shell de login. Os valores ficam no arquivo de dados do app, sem criptografia.")
                }
            }
            .formStyle(.grouped)
            HStack {
                if !missingRequired.isEmpty {
                    Label("Preencha \(missingRequired.joined(separator: ", "))", systemImage: "key")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.warn)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Adicionar conector" : "Salvar", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 540, height: 600)
        .onAppear(perform: load)
    }

    private func load() {
        config = draft.config
        isRemote = draft.config.isRemote
        arguments = draft.config.arguments.joined(separator: "\n")
        let dictionary = isRemote ? draft.config.headers : draft.config.environment
        // Registry inputs first, in the publisher's order; then anything else.
        let ordered = draft.inputs.map(\.name) + dictionary.keys.sorted().filter { inputsByName[$0] == nil }
        values = ordered.map { KeyValueRow(key: $0, value: dictionary[$0] ?? "") }
    }

    private func save() {
        let pairs = values.map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) }.filter { !$0.0.isEmpty }
        let dictionary = Dictionary(pairs, uniquingKeysWith: { _, last in last })
        if isRemote {
            config.command = ""
            config.arguments = []
            config.environment = [:]
            config.headers = dictionary
        } else {
            config.url = ""
            config.headers = [:]
            config.arguments = arguments.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            config.environment = dictionary
        }
        if let index = model.connectors.firstIndex(where: { $0.id == config.id }) {
            model.connectors[index] = config
        } else {
            model.connectors.append(config)
        }
        dismiss()
    }
}

private struct KeyValueRow: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

/// One variable/header: the name (fixed when it comes from the registry), its value and what it is for.
private struct KeyValueField: View {
    @Binding var row: KeyValueRow
    let input: RegistryServer.Input?
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if input != nil {
                    Text(row.key)
                        .font(.system(size: 12).monospaced())
                        .frame(width: 170, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    TextField("NOME", text: $row.key)
                        .font(.system(size: 12).monospaced())
                        .frame(width: 170)
                }
                Group {
                    if input?.isSecret == true {
                        SecureField("valor", text: $row.value)
                    } else {
                        TextField("valor", text: $row.value)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                if input == nil {
                    Button("Remover", systemImage: "minus.circle", action: onRemove)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            if let input, !input.summary.isEmpty || input.isRequired {
                Text((input.isRequired ? "Obrigatório. " : "") + input.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
                    .lineLimit(2)
            }
        }
    }
}

extension MCPServerConfig {
    /// Well-known servers shown under "Em destaque".
    static let templates: [MCPServerConfig] = [
        MCPServerConfig(name: "Arquivos", command: "npx",
                        arguments: ["-y", "@modelcontextprotocol/server-filesystem", NSHomeDirectory()]),
        MCPServerConfig(name: "Memória (grafo)", command: "npx", arguments: ["-y", "@modelcontextprotocol/server-memory"]),
        MCPServerConfig(name: "Busca na web (Fetch)", command: "uvx", arguments: ["mcp-server-fetch"]),
        MCPServerConfig(name: "Pensamento em etapas", command: "npx",
                        arguments: ["-y", "@modelcontextprotocol/server-sequential-thinking"]),
    ]

    func withNewID() -> MCPServerConfig {
        var copy = self
        copy.id = UUID()
        return copy
    }
}
