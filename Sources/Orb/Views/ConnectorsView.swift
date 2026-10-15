import SwiftUI

/// Connectors: the gallery of services (one click to connect), the installed ones (enable, status, edit, delete) and the
/// official MCP registry for everything else.
struct ConnectorsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: CatalogTab
    @State private var editing: ConnectorDraft?
    /// The connector of this Mac whose "Conectar" sheet is open.
    @State private var settingUp: LocalConnectorKind?

    init(tab: CatalogTab = .gallery) {
        _tab = State(initialValue: tab)
    }

    private var hasProblem: Bool {
        model.connectorStatus.values.contains { if case .failed = $0 { true } else { false } }
    }

    var body: some View {
        VStack(spacing: 0) {
            CatalogTabBar(tab: $tab, installedTitle: "Instalados", installedCount: model.connectors.count, galleryTitle: "Galeria")
                .padding(.top, 16)
                .padding(.bottom, 4)
            CatalogTabContent(tab: tab) {
                switch tab {
                case .gallery: ConnectorGalleryView(editing: $editing, settingUp: $settingUp, explore: { tab = .explore })
                case .installed: InstalledConnectors(editing: $editing, settingUp: $settingUp, explore: { tab = .gallery })
                case .explore: ExploreConnectors(editing: $editing)
                }
            }
        }
        .background(Palette.canvas)
        .navigationTitle("Conectores")
        .navigationSubtitle("Dão novas ferramentas aos Orbs, como Gmail, Agenda, Slack e GitHub")
        .toolbar {
            Button("Reconectar", systemImage: "arrow.clockwise") { model.retryFailedConnectors() }
                .help(hasProblem ? "Tenta conectar de novo os conectores com erro" : "Nenhum conector está com erro")
                .disabled(!hasProblem)
            Button("Adicionar manualmente", systemImage: "plus") {
                editing = ConnectorDraft(config: MCPServerConfig(name: ""))
            }
            .help("Abre o editor para adicionar um servidor pelo comando ou pela URL")
        }
        .sheet(item: $editing) { draft in
            ConnectorEditor(draft: draft)
        }
        .sheet(item: $settingUp) { kind in
            LocalConnectorSheet(kind: kind)
        }
    }
}

/// A connector being added or edited, plus what its catalog entry says about it and asks the user to fill in.
struct ConnectorDraft: Identifiable {
    var config: MCPServerConfig
    var inputs: [RegistryServer.Input] = []
    /// What the connector does, in plain words (empty for one typed in by hand).
    var summary = ""
    var isOfficial = false
    /// The argument that holds the folder the server may open (the filesystem server).
    var folderArgumentIndex: Int?
    var helpURL: URL?
    var guide: ConnectorGuide?
    var note: String?
    var id: UUID { config.id }

    /// Came from the catalog: the sheet asks only for keys, the rest sits under "Avançado".
    var isGuided: Bool { !summary.isEmpty || !inputs.isEmpty || config.source != nil }
}

extension ConnectorDraft {
    init(template: ConnectorTemplate) {
        self.init(config: template.config.withNewID(), inputs: template.inputs, summary: template.summary,
                  folderArgumentIndex: template.folderArgumentIndex, helpURL: template.helpURL, guide: template.guide, note: template.note)
    }

    /// An installed connector: the same guided form it was installed with, with "Avançado" open.
    init(editing config: MCPServerConfig) {
        if let template = ConnectorTemplate.matching(config) {
            self.init(config: config, inputs: template.inputs, summary: template.summary,
                      folderArgumentIndex: template.folderArgumentIndex.flatMap { $0 < config.arguments.count ? $0 : nil },
                      helpURL: template.helpURL, guide: template.guide, note: template.note)
        } else if let source = config.source {
            self.init(config: config, inputs: ConnectorEditing.inputs(for: config), isOfficial: RegistryServer.isOfficial(source))
        } else {
            self.init(config: config)
        }
    }

    init(server: RegistryServer) {
        self.init(config: server.config.withNewID(), inputs: server.inputs, summary: server.summary, isOfficial: server.isOfficial)
    }
}

// MARK: Installed

private struct InstalledConnectors: View {
    @Environment(AppModel.self) private var model
    @Binding var editing: ConnectorDraft?
    @Binding var settingUp: LocalConnectorKind?
    /// Back to the gallery, where a connector is picked.
    let explore: () -> Void
    @State private var deleting: MCPServerConfig?
    @State private var viewingTools: MCPServerConfig?

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach($model.connectors) { $connector in
                        ConnectorCard(connector: $connector, status: model.connectorStatus[connector.id],
                                      usedBy: usedBy(connector), attention: attention(connector), onEdit: {
                            if let kind = connector.local.flatMap(LocalConnectorKind.init(rawValue:)) {
                                settingUp = kind
                            } else {
                                editing = ConnectorDraft(editing: connector)
                            }
                        }, onTest: {
                            await model.testConnector(connector.id)
                        }, onSignIn: { moreScope in
                            await model.signIn(connector: connector.id, moreScope: moreScope)
                        }, isSigningIn: model.signingIn.contains(connector.id), onCancelSignIn: {
                            model.cancelSignIn(connector: connector.id)
                        }, onSignOut: {
                            await model.signOut(connector: connector.id)
                        }, onViewTools: {
                            viewingTools = connector
                        }, onDelete: {
                            deleting = connector
                        })
                    }
                }
            }
            .pageColumn()
        }
        .overlay {
            if model.connectors.isEmpty {
                ContentUnavailableView {
                    Label("Nenhum conector", systemImage: "point.3.filled.connected.trianglepath.dotted")
                } description: {
                    Text("Conectores dão aos Orbs novas ferramentas, como ler o Gmail, a Agenda ou o GitHub. Escolha um na galeria ou adicione o seu.")
                } actions: {
                    Button("Abrir a galeria", action: explore).buttonStyle(PrimaryPillStyle())
                        .help(Tip.showGallery)
                }
            }
        }
        .sheet(item: $viewingTools) { connector in
            ConnectorToolsSheet(connector: connector)
        }
        .confirmationDialog("Apagar o conector “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Apagar", role: .destructive) {
                if let id = deleting?.id { model.removeConnector(id) }
            }
        } message: {
            Text("As chaves e variáveis dele também serão apagadas.")
        }
    }

    /// What a connector of this Mac lacks (a permission, the Google account), for its card.
    private func attention(_ connector: MCPServerConfig) -> String? {
        guard connector.isEnabled, let kind = connector.local.flatMap(LocalConnectorKind.init(rawValue:)),
              let state = model.localStates[kind], state.needsAttention else { return nil }
        return state.message
    }

    /// "Atlas, Lia" for the Orbs that get this connector now; nil for a disabled one.
    private func usedBy(_ connector: MCPServerConfig) -> String? {
        guard connector.isEnabled else { return nil }
        let names = model.orbsUsing(connector).map(\.name)
        return names.isEmpty ? "" : OrbScopeText.list(names)
    }
}

private struct ConnectorCard: View {
    @Binding var connector: MCPServerConfig
    let status: MCPStatus?
    /// Names of the Orbs that use it; "" when none does; nil when the connector is off.
    let usedBy: String?
    /// What a connector of this Mac lacks, in a line (a permission, the Google account); nil when nothing does.
    var attention: String?
    let onEdit: () -> Void
    /// Starts the server (if it is off), lists its tools and says how it went.
    let onTest: () async -> ConnectorTestOutcome
    /// Signs in through the browser (the scopes to add, for "Permitir mais"), then starts the server.
    let onSignIn: (String?) async -> ConnectorTestOutcome
    /// A login of this connector is under way in the app, started from this card or from one that has gone since.
    let isSigningIn: Bool
    let onCancelSignIn: () -> Void
    let onSignOut: () async -> Void
    let onViewTools: () -> Void
    let onDelete: () -> Void
    @State private var isShowingDetail = false
    @State private var test = TestState.none
    /// The login under way (the browser is open) or the last one that failed.
    @State private var login = LoginState.none
    @State private var loginTask: Task<Void, Never>?

    private enum TestState: Equatable { case none, running, done(String), failed(String) }
    private enum LoginState: Equatable { case none, waiting, failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ConnectorIcon(connector: connector)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(connector.local != nil ? "Neste Mac" : connector.isRemote ? connector.url : ([connector.command] + connector.arguments).joined(separator: " "))
                        // A command or a URL reads in monospace; "Neste Mac" is a plain phrase.
                        .font(connector.local != nil ? .system(size: 11) : .system(size: 11).monospaced())
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(connector.source ?? "")
                }
                Spacer(minLength: 8)
                Toggle("Ativo", isOn: $connector.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help(connector.isEnabled ? "Desativa o conector; ele fica instalado, mas os Orbs não o usam" : "Ativa o conector para os Orbs usarem")
            }
            if case .failed(let message) = status, connector.isEnabled {
                failure(message)
            } else if let attention {
                needsAttention(attention)
            } else if connector.isEnabled, let ask = loginAsk {
                loginBlock(ask)
            }
            if showsTestLine { testLine }
            if let usedBy {
                Label(usedBy.isEmpty ? "Nenhum Orb usa" : "Usado por \(usedBy)",
                      systemImage: usedBy.isEmpty ? "person.crop.circle.badge.exclamationmark" : "person.2")
                    .font(.system(size: 11))
                    .foregroundStyle(usedBy.isEmpty ? Palette.warn : Palette.muted)
                    .lineLimit(1)
                    .help(usedBy.isEmpty ? "Ligue “Conectores” no painel de um Orb, ou escolha os Orbs em Editar" : "")
            }
            HStack(spacing: 6) {
                // Ready, in use, connecting, error: the badge changes in place by fading.
                statusBadge
                    .animateChanges(of: StatusBadgeKey(isEnabled: connector.isEnabled, status: status))
                Spacer(minLength: 0)
                Menu {
                    Button("Testar conexão", action: runTest).disabled(!connector.isEnabled || test == .running)
                        .help(connector.isEnabled ? "Liga o servidor e lista as ferramentas, para ver se funciona" : "Só dá para testar com o conector ativado")
                    Button("Ver ferramentas…", action: onViewTools)
                        .help("Mostra o que este conector oferece aos Orbs")
                    Divider()
                    Button("Editar…", action: onEdit)
                        .help(connector.local != nil ? "Muda os Orbs que usam este conector" : "Abre o editor deste conector")
                    if signsIn {
                        Button("Sair da conta") { Task { await onSignOut() } }
                            .help("Esquece o login deste Mac e o revoga no serviço, se ele permitir")
                    }
                    Divider()
                    Button("Apagar…", role: .destructive, action: onDelete)
                        .help("Pede a confirmação; apaga também as chaves deste conector")
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 22)
                        .contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .iconTip("Testa, mostra as ferramentas, edita ou apaga \(connector.name)", label: Tip.moreOptions(of: connector.name))
            }
        }
        .padding(14)
        .card(radius: 14)
        .opacity(connector.isEnabled ? 1 : 0.55)
        .animateChanges(of: connector.isEnabled)
        .animateChanges(of: status)
        .animateChanges(of: test)
    }

    /// A connector that signs in with the person's account (a login, not a key).
    private var signsIn: Bool {
        connector.isRemote && !connector.hasStaticAuthorization && (connector.oauth != nil || loginAsk != nil)
    }

    /// What the card asks for when the server wants a login: which one, and the words.
    private enum LoginAsk: Equatable {
        case signIn, expired(String), morePermission(String?)
    }

    private var loginAsk: LoginAsk? {
        switch status {
        case .needsSignIn(let message)?: message.map(LoginAsk.expired) ?? .signIn
        case .needsMorePermission(let scope)?: .morePermission(scope)
        default: nil
        }
    }

    /// "Entrar" · "Sessão expirou" · "Precisa de mais permissão", with the button that fixes it. Waiting for the browser can be cancelled.
    private func loginBlock(_ ask: LoginAsk) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch isSigningIn ? LoginState.waiting : login {
            case .waiting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Abrimos o navegador. Termine o login lá e volte.").foregroundStyle(Palette.muted)
                }
                .font(.system(size: 12))
                Button("Cancelar") { loginTask?.cancel(); onCancelSignIn() }.buttonStyle(GhostStyle()).controlSize(.small).help(Tip.cancelLogin)
            default:
                Label(loginMessage(ask), systemImage: ask == .signIn ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.warn)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if case .failed(let message) = login {
                    Text(ConnectorStatusText.shortError(message))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                }
                Button(loginButton(ask), action: { signIn(moreScope: scope(of: ask)) }).buttonStyle(SecondaryPillStyle()).controlSize(.small)
                    .help(loginHelp(ask))
            }
        }
        .transition(.opacity)
        .animateChanges(of: login)
    }

    private func loginMessage(_ ask: LoginAsk) -> String {
        switch ask {
        case .signIn: "Entre com a sua conta para usar \(connector.name)."
        case .expired(let message): message
        case .morePermission: "\(connector.name) pediu mais permissão para fazer isso."
        }
    }

    private func loginButton(_ ask: LoginAsk) -> String {
        switch ask {
        case .signIn: "Entrar com \(connector.name)"
        case .expired: "Entrar de novo"
        case .morePermission: "Permitir mais"
        }
    }

    private func loginHelp(_ ask: LoginAsk) -> String {
        switch ask {
        case .signIn: "Abre o navegador para entrar com a sua conta do \(connector.name)"
        case .expired: "Abre o navegador para entrar de novo; a sessão acabou"
        case .morePermission: "Abre o navegador para você liberar a permissão que faltou"
        }
    }

    private func scope(of ask: LoginAsk) -> String? {
        if case .morePermission(let scope) = ask { scope } else { nil }
    }

    private func signIn(moreScope: String?) {
        guard login != .waiting, !isSigningIn else { return }
        loginTask = Task { @MainActor in
            login = .waiting
            switch await onSignIn(moreScope) {
            case .connected: login = .none
            case .failed(let message): login = .failed(message)
            }
        }
    }

    private func runTest() {
        guard test != .running else { return }
        Task { @MainActor in
            test = .running
            switch await onTest() {
            case .connected(let tools, let seconds):
                test = .done(ConnectorStatusText.tested(tools: tools, seconds: seconds))
                try? await Task.sleep(for: .seconds(6))
                if case .done = test { test = .none }
            case .failed(let message):
                test = .failed(message)
                try? await Task.sleep(for: .seconds(6))
                if case .failed = test { test = .none }
            }
        }
    }

    /// A failed test says so on its own line, unless the server itself failed to start: the card then shows that failure.
    private var showsTestLine: Bool {
        switch test {
        case .none: false
        case .failed: if case .failed = status, connector.isEnabled { false } else { true }
        default: true
        }
    }

    @ViewBuilder private var testLine: some View {
        HStack(spacing: 6) {
            switch test {
            case .running:
                ProgressView().controlSize(.mini)
                Text("Testando a conexão…").foregroundStyle(Palette.muted)
            case .done(let text):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                Text(text).foregroundStyle(Palette.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.danger)
                Text(ConnectorStatusText.shortError(message)).foregroundStyle(Palette.danger).lineLimit(2)
            case .none:
                EmptyView()
            }
        }
        .font(.system(size: 11))
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    /// A connector of this Mac that lacks something: the line, and the button that opens its sheet to fix it.
    private func needsAttention(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Palette.warn)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Button("Resolver…", action: onEdit).buttonStyle(SecondaryPillStyle()).controlSize(.small)
                .help("Abre a conexão para você resolver o que falta")
        }
    }

    /// The reason in words, not in a tooltip, with the two things to do about it.
    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isShowingDetail = true
            } label: {
                Text("Não conectou: \(ConnectorStatusText.shortError(message))")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.danger)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Mostra a mensagem de erro completa")
            .popover(isPresented: $isShowingDetail, arrowEdge: .bottom) {
                ScrollView {
                    Text(message)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(Palette.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 360, height: 160)
                .padding(14)
            }
            HStack(spacing: 6) {
                Button("Tentar de novo", action: runTest).buttonStyle(SecondaryPillStyle())
                    .help("Testa a conexão de novo")
                Button("Editar…", action: onEdit).buttonStyle(SecondaryPillStyle())
                    .help("Abre o editor para corrigir o conector")
            }
            .controlSize(.small)
        }
    }

    /// Pronto (off, starts by itself when an Orb needs it) · Em uso (connected now) · Conectando… · Erro · Desligado.
    @ViewBuilder private var statusBadge: some View {
        if !connector.isEnabled {
            CatalogBadge(text: "Desligado", symbol: "pause.circle")
        } else {
            switch status {
            case .ready:
                InUseBadge()
            case .idle(let count):
                CatalogBadge(text: count.map { "Pronto · \(ConnectorStatusText.toolCount($0))" } ?? "Pronto", symbol: "checkmark.circle")
                    .help("Liga sozinho quando um Orb precisar")
            case .failed:
                CatalogBadge(text: "Erro", symbol: "exclamationmark.triangle.fill", tint: Palette.danger)
            case .starting:
                CatalogBadge(text: "Conectando…", symbol: "hourglass")
            case .needsSignIn(let expired):
                CatalogBadge(text: expired == nil ? "Entrar" : "Sessão expirou", symbol: "person.crop.circle.badge.exclamationmark", tint: Palette.warn)
            case .needsMorePermission:
                CatalogBadge(text: "Precisa de mais permissão", symbol: "lock.trianglebadge.exclamationmark", tint: Palette.warn)
            case .stopped:
                CatalogBadge(text: "Desligado", symbol: "pause.circle")
            case nil:
                CatalogBadge(text: "Pronto", symbol: "checkmark.circle")
                    .help("Liga sozinho quando um Orb precisar")
            }
        }
    }
}

/// What the status badge depends on, as one value for its swaps to follow.
private struct StatusBadgeKey: Equatable {
    var isEnabled: Bool
    var status: MCPStatus?
}

/// The connector is connected right now: a small green dot, nothing louder.
private struct InUseBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Palette.ok).frame(width: 6, height: 6)
            Text("Em uso").lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Palette.ok)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Palette.ok.opacity(0.12), in: .capsule)
        .help("Conectado agora; desliga sozinho depois de um tempo sem uso")
    }
}

// MARK: Tools

/// What a connector offers, from its catalog: name, a line about it and whether it only reads or can destroy.
struct ConnectorToolsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connector: MCPServerConfig
    @State private var catalog: ConnectorCatalog?
    @State private var didLoad: Bool

    init(connector: MCPServerConfig, catalog: ConnectorCatalog? = nil) {
        self.connector = connector
        _catalog = State(initialValue: catalog)
        _didLoad = State(initialValue: catalog != nil)
    }

    private var subtitle: String {
        guard let catalog else { return "Lista guardada da última vez que o conector ligou." }
        return "\(ConnectorStatusText.toolCount(catalog.tools.count)) · atualizada \(catalog.updatedAt.formatted(.relative(presentation: .named).locale(.app)))"
    }

    /// What the sheet shows: loading, the tools, or why there are none.
    private enum Phase { case loading, tools, none }

    private var phase: Phase {
        if !didLoad { return .loading }
        return catalog.map { $0.tools.isEmpty } == false ? .tools : .none
    }

    var body: some View {
        // Loading turns into the list by cross-fading (§2.13), the spinner waiting 150 ms before it shows.
        ZStack {
            content
                .id(phase)
                .transition(.opacity)
        }
            .motion(Motion.content, value: phase)
            .task {
                guard !didLoad else { return }
                catalog = await model.mcp.catalog(connector.id)
                didLoad = true
            }
            .orbSheet("Ferramentas de \(connector.name)", subtitle: subtitle, size: .medium,
                      icon: ConnectorGallery.service(for: connector)?.mark) {
                SheetFooter(cancel: { dismiss() }, primaryTitle: "Fechar", showsCancel: false, primary: { dismiss() })
            }
    }

    @ViewBuilder private var content: some View {
        if !didLoad {
            DelayedSpinner().frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
        } else if let catalog, !catalog.tools.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(catalog.tools, id: \.name) { tool in
                        VStack(alignment: .leading, spacing: 0) {
                            row(tool)
                            Divider().overlay(Palette.line)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        } else {
            Text(catalog == nil ? "O Orb ainda não conhece as ferramentas deste conector. Use “Testar conexão” no menu do cartão."
                                : "Este conector não oferece ferramentas.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
        }
    }

    private func row(_ tool: ConnectorCatalog.Tool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(tool.name)
                    .font(.system(size: 12, weight: .semibold).monospaced())
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if tool.annotations.destructive == true {
                    CatalogBadge(text: "Destrutiva", symbol: "exclamationmark.triangle.fill", tint: Palette.warn)
                } else if tool.annotations.readOnly == true {
                    CatalogBadge(text: "Só leitura", symbol: "eye", tint: Palette.ok)
                }
            }
            Text(tool.description.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Sem descrição.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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

    private var isSearching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CatalogSearchHeader(query: $query, prompt: "Buscar no registro oficial de conectores",
                                    info: "A busca usa o registro oficial do MCP (registry.modelcontextprotocol.io). O nome de cada servidor é verificado pelo registro, mas o código é de quem publicou.")
                Label("Os servidores do registro são de quem os publicou. Só os marcados “Oficial” vêm do projeto do MCP; os outros rodam código de terceiros no seu Mac. Confira quem publicou antes de instalar. Para os serviços mais usados, veja a galeria.",
                      systemImage: "exclamationmark.shield")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if !isSearching {
                    ContentUnavailableView {
                        Label("Busque um serviço", systemImage: "sparkle.magnifyingglass")
                    } description: {
                        Text("Digite o nome do serviço ou do que ele faz, como “banco de dados” ou “calendário”.")
                    }
                    // Across the whole width, not the first column of the VStack's alignment (like the Instalados one).
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
                    .transition(.opacity)
                } else if isLoading || error != nil || results.isEmpty {
                    CatalogStateView(isLoading: isLoading, error: error, isEmpty: results.isEmpty,
                                     slowHint: "O registro às vezes demora até um minuto…", skeleton: true,
                                     retry: { Task { await search() } })
                        .transition(.opacity)
                } else {
                    grid(results) { server in
                        RegistryServerCard(server: server, isInstalled: model.installedConnector(server.id) != nil) {
                            editing = ConnectorDraft(server: server)
                        }
                    }
                    .transition(.opacity)
                }
            }
            // The hint, the loading, the error, "no result" and the results swap by fading, bound to the one phase.
            .animateChanges(of: ExplorePhase.of(isSearching: isSearching, isLoading: isLoading, error: error, isEmpty: results.isEmpty))
            .pageColumn()
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    private func grid<Item: Identifiable, Card: View>(_ items: [Item], @ViewBuilder card: @escaping (Item) -> Card) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12, alignment: .top)], spacing: 12) {
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
                    } else {
                        CatalogBadge(text: "Não oficial", symbol: "exclamationmark.triangle", tint: Palette.warn)
                    }
                    CatalogBadge(text: server.kindLabel, symbol: server.config.isRemote ? "cloud" : "desktopcomputer")
                    let required = server.inputs.filter { $0.isRequired && $0.isSecret }.count
                    if required > 0 {
                        CatalogBadge(text: required == 1 ? "Pede 1 chave" : "Pede \(required) chaves", symbol: "key")
                    }
                }
            }
            .padding(14)
            .hoverCard(isHovering, radius: 14, strongOutline: true)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Abre a instalação de \(server.title)")
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(server.title). \(server.summary)")
        .accessibilityHint("Abre a instalação")
    }
}

// MARK: Editor

/// Add/edit a connector. Catalog entries arrive pre-filled and only ask for what they need (keys, a folder); the
/// command and arguments sit under "Avançado". "Instalar e conectar" saves, connects and says how it went.
struct ConnectorEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let draft: ConnectorDraft
    /// Snapshots draw one phase of the sheet.
    var initialPhase: Phase = .form

    enum Phase: Equatable {
        /// `signingIn`: the browser is open and the Orb waits for the way back.
        case form, connecting, signingIn, connected(Int), failed(String)
    }

    @State private var config = MCPServerConfig(name: "")
    @State private var isRemote = false
    @State private var arguments = ""
    @State private var values: [KeyValueRow] = []
    @State private var orbIDs: Set<UUID>?
    @State private var showsAdvanced = false
    @State private var slackPreset = SlackApp.Preset.readOnly
    /// Slack: the token is pasted instead of signing in with the app's Client ID.
    @State private var pastesToken = false
    /// The app registered with the service (Client ID, and the Secret when it has one), for a login that cannot register the Orb itself.
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var phase = Phase.form
    @State private var signInTask: Task<Void, Never>?
    @State private var didLoad = false
    /// Whether it was new when the sheet opened: saving adds it to `connectors`, but the sheet keeps saying "Instalar".
    @State private var openedAsNew: Bool?

    private var isNew: Bool { openedAsNew ?? !model.connectors.contains { $0.id == draft.config.id } }
    private var isGuided: Bool { draft.isGuided }
    private var inputsByName: [String: RegistryServer.Input] {
        Dictionary(draft.inputs.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }
    private var missingRequired: [String] {
        guard !signsInWithApp else { return [] }
        return draft.inputs.filter(\.isRequired).map(\.name).filter { name in
            values.first { $0.key == name }?.value.trimmingCharacters(in: .whitespaces).isEmpty ?? true
        }
    }
    /// Slack, signing in with the Client ID of the person's own app (not pasting a token).
    private var signsInWithApp: Bool { draft.guide == .slack && !pastesToken }
    /// The connector enters with the person's account: the primary button signs in.
    private var signsIn: Bool { isRemote && config.oauth != nil && !(draft.guide == .slack && pastesToken) }
    private var clientIDMissing: Bool { signsInWithApp && clientID.trimmingCharacters(in: .whitespaces).isEmpty }
    /// "Só alguns" with nobody ticked, or only Orbs that no longer exist.
    private var chosenNoOrb: Bool {
        guard let orbIDs else { return false }
        return !model.bots.contains { orbIDs.contains($0.id) }
    }
    /// The Orbs that already get this connector, so only the Orbs added now have their "Conectores" switch turned on.
    private var alreadyUsing: Set<UUID> {
        model.connectors.first { $0.id == config.id }.map { $0.orbIDs ?? Set(model.bots.map(\.id)) } ?? []
    }
    /// Said before saving: turning "Conectores" on for an Orb also gives it the connectors it had not been using.
    private var extraAccessNote: String? {
        guard let orbIDs, !chosenNoOrb else { return nil }
        return OrbScopeText.extraAccess(model.extraConnectorAccess(ifEnabledFor: orbIDs.subtracting(alreadyUsing), besides: config.id))
    }
    /// The Slack guide asks for a User OAuth Token (`xoxp-…`): a bot token (`xoxb-`) cannot use the MCP server.
    private var slackTokenProblem: Bool {
        guard draft.guide == .slack, pastesToken, let token = values.first(where: { $0.key == "Authorization" })?.value,
              !token.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !SlackApp.looksLikeUserToken(token)
    }
    private var canSave: Bool {
        !config.name.trimmingCharacters(in: .whitespaces).isEmpty && missingRequired.isEmpty && !chosenNoOrb && !slackTokenProblem && !clientIDMissing
            && !(isRemote ? config.url : config.command).trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var title: String {
        let name = draft.config.name
        if name.isEmpty { return "Novo conector" }
        return isNew ? "Instalar \(name)" : "Editar \(name)"
    }
    private var subtitle: String {
        if !draft.summary.isEmpty { return draft.summary }
        if draft.config.source != nil { return "Do registro de conectores. Os Orbs que você escolher passam a usar as ferramentas dele." }
        return "Diga como iniciar o servidor. Os Orbs que você escolher passam a usar as ferramentas dele."
    }
    private var primaryTitle: String {
        guard config.isEnabled else { return "Salvar" }
        if signsIn { return "Entrar com \(draft.config.name.isEmpty ? config.name : draft.config.name)" }
        return isNew ? "Instalar e conectar" : "Salvar e conectar"
    }

    private var primaryHelp: String {
        guard config.isEnabled else { return "Salva o conector sem conectar, porque ele está desativado" }
        if signsIn { return "Salva o conector e entra com a sua conta, se ainda faltar o login" }
        return "Salva o conector e testa a conexão agora"
    }

    private var footerMessage: String? {
        if chosenNoOrb { return "Marque ao menos um Orb em “Usar com”." }
        if clientIDMissing { return "Cole o Client ID do app do Slack." }
        if slackTokenProblem { return "O token do Slack é o User OAuth Token e começa com xoxp-." }
        if !missingRequired.isEmpty { return "Preencha \(missingRequired.map { $0 == "Authorization" ? "a chave" : $0 }.joined(separator: ", "))." }
        return nil
    }

    var body: some View {
        content
            // A guide makes the form longer: the key it leads to should not be hidden under the fold.
            .orbSheet(title, subtitle: subtitle, size: .medium, maxHeight: draft.guide == nil ? SheetSize.maxHeight : 700,
                      icon: ConnectorGallery.service(for: draft.config)?.mark) { footer }
            .onAppear(perform: load)
            .onDisappear { signInTask?.cancel() }
            .motion(Motion.content, value: phase)
            .onChange(of: phase) { announce(phase) }
    }

    /// The result replaces the form, so a screen reader hears it without having to look for it.
    private func announce(_ phase: Phase) {
        switch phase {
        case .connected(let count):
            AccessibilityNotification.Announcement("Conectado. \(ConnectorStatusText.toolsAvailable(count))").post()
        case .failed(let message):
            AccessibilityNotification.Announcement("Não conectou. \(ConnectorStatusText.shortError(message))").post()
        case .form, .connecting, .signingIn:
            break
        }
    }

    /// The form, or one result view for all the phases after it: connecting, signing in, connected and failed are the
    /// same view with other values, so the spinner turns into the mark and the words change in place (§2.13).
    private var content: some View {
        ZStack {
            if case .form = phase {
                form.transition(.opacity)
            } else {
                result(outcome).transition(.opacity)
            }
        }
    }

    private struct Outcome {
        var symbol: String?
        var tint: Color
        var title: String
        var detail: String
        var full: String?
    }

    private var outcome: Outcome {
        switch phase {
        case .form, .connecting:
            Outcome(symbol: nil, tint: Palette.muted, title: "Conectando…",
                    detail: "Na primeira vez pode levar alguns segundos: o conector às vezes precisa ser baixado.")
        case .signingIn:
            Outcome(symbol: nil, tint: Palette.muted, title: "Entrar com \(config.name)",
                    detail: "Abrimos o navegador. Termine o login lá e volte.")
        case .connected(let count):
            Outcome(symbol: "checkmark.circle.fill", tint: Palette.ok, title: "Conectado",
                    detail: ConnectorStatusText.toolsAvailable(count))
        case .failed(let message):
            Outcome(symbol: "exclamationmark.triangle.fill", tint: Palette.danger, title: "Não conectou",
                    detail: ConnectorStatusText.shortError(message), full: message)
        }
    }

    @ViewBuilder private var footer: some View {
        switch phase {
        case .form:
            SheetFooter(message: footerMessage, cancel: { dismiss() }, primaryTitle: primaryTitle,
                        isPrimaryDisabled: !canSave, primaryHelp: primaryHelp, primary: save)
        case .connecting:
            SheetFooter(cancelTitle: "Fechar", cancel: { dismiss() }, primaryTitle: "Conectando…", isPrimaryDisabled: true, primary: {})
        case .signingIn:
            SheetFooter(cancel: { signInTask?.cancel() }, primaryTitle: "Esperando o navegador…", isPrimaryDisabled: true, cancelHelp: Tip.cancelLogin, primary: {})
        case .connected:
            SheetFooter(cancel: { dismiss() }, primaryTitle: "Fechar", showsCancel: false, primary: { dismiss() })
        case .failed:
            SheetFooter(message: "O conector foi salvo. Corrija e tente de novo.", cancelTitle: "Fechar", cancel: { dismiss() },
                        primaryTitle: "Editar", primaryHelp: "Volta ao formulário para corrigir o conector", primary: {
                // A service that wants an app registered by the person: the fields for it are the next thing to see.
                if case .failed(let message) = phase, message.contains("app registrado") { showsAdvanced = true }
                phase = .form
            })
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(spacing: 0) {
            if isGuided && (draft.isOfficial || draft.helpURL != nil || isRemote) {
                HStack(spacing: 8) {
                    if draft.isOfficial { CatalogBadge(text: "Oficial", symbol: "checkmark.seal.fill", tint: Palette.accentText) }
                    if isRemote { CatalogBadge(text: "Remoto", symbol: "cloud") }
                    if let url = draft.helpURL {
                        Link(destination: url) { CatalogBadge(text: "Onde conseguir a chave", symbol: "arrow.up.right.square") }
                            .help("Abre no navegador a página onde a chave é criada")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }
            Form {
                if isGuided {
                    if signsIn && draft.guide != .slack { loginSection }
                    if draft.guide == .slack { slackGuide }
                    if config.source != nil && !draft.isOfficial {
                        Section {
                            Label("Servidor de terceiros do registro: ele roda no seu Mac com as permissões do seu usuário. Instale só se confiar em quem publicou.",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Palette.warn)
                        }
                    }
                    if !secretRows.isEmpty && !signsInWithApp {
                        Section {
                            inputFields(secretRows)
                        } header: {
                            Text(secretRows.count == 1 ? "Chave" : "Chaves")
                        } footer: { FormFootnote {
                            VStack(alignment: .leading, spacing: 6) {
                                if let note = draft.note { Text(note) }
                                Text("Chaves ficam no Keychain do Mac, não no arquivo de dados do app.")
                            }
                        } }
                    }
                    if !plainRows.isEmpty {
                        Section {
                            inputFields(plainRows)
                        } header: {
                            Text("Configuração")
                        }
                    }
                    if let folderIndex = draft.folderArgumentIndex {
                        folderSection(index: folderIndex)
                    }
                } else {
                    advancedFields
                }
                Section {
                    OrbScopePicker(orbIDs: $orbIDs, allNote: "Cada Orb precisa estar com “Conectores” ligado no painel dele.")
                } header: {
                    Text("Usar com")
                } footer: { FormFootnote {
                    VStack(alignment: .leading, spacing: 6) {
                        if let extraAccessNote {
                            Label(extraAccessNote, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Palette.warn)
                        }
                        if let orbIDs, !orbIDs.isEmpty {
                            Text("“Conectores” é ligado nos Orbs marcados, se ainda não estiver.")
                        }
                    }
                } }
                if isGuided {
                    Section {
                        DisclosureGroup("Avançado", isExpanded: $showsAdvanced) { advancedFields }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    /// Slack asks for more than a login: the person creates an app (a link fills in everything) and installs it. Then the app's Client ID
    /// is enough to sign in (PKCE, nothing to copy), or the User OAuth Token can be pasted instead.
    @ViewBuilder private var slackGuide: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Escolha o que o Orb pode fazer").font(.system(size: 13, weight: .semibold))
                Picker("Permissões do app", selection: $slackPreset) {
                    ForEach(SlackApp.Preset.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Escolhe se o app do Slack só lê ou também envia mensagens")
                Text(slackPreset.detail).font(.system(size: 11)).foregroundStyle(Palette.faint)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("2. Crie o seu app do Slack").font(.system(size: 13, weight: .semibold))
                Button("Criar meu app do Slack", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(SlackApp.creationURL(slackPreset)) }
                    .buttonStyle(SecondaryPillStyle())
                    .help("Abre o Slack no navegador com o app já preenchido")
                Text("O Slack abre no navegador com tudo preenchido. Escolha o seu workspace e clique em **“Create”**. Depois, em **“Install App”**, clique em **“Install to Workspace”** e em **“Allow”**.")
                    .font(.system(size: 11)).foregroundStyle(Palette.faint)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("3. Como entrar").font(.system(size: 13, weight: .semibold))
                Picker("Como entrar", selection: $pastesToken) {
                    Text("Entrar com o app").tag(false)
                    Text("Colar o token").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Escolhe entre entrar com o app do Slack ou colar o token")
                if pastesToken {
                    Text("Em OAuth & Permissions, copie o User OAuth Token (começa com xoxp-) e cole na chave abaixo.")
                        .font(.system(size: 11)).foregroundStyle(Palette.faint)
                } else {
                    TextField("Client ID", text: $clientID, prompt: Text("Em “Basic Information” → “App Credentials”"))
                        .textFieldStyle(.roundedBorder)
                        .help("O Client ID do app do Slack, que o Orb usa para entrar com a sua conta")
                    Text("Copie o Client ID do app e clique em Entrar com Slack: o Slack pede a sua licença no navegador. Não precisa copiar token.")
                        .font(.system(size: 11)).foregroundStyle(Palette.faint)
                }
            }
        } header: {
            Text("Passo a passo")
        } footer: { FormFootnote {
            Text("O app é seu, só do seu workspace: o Orb age como você e vê só o que você vê. Se o workspace exige aprovação de apps, peça ao administrador.")
        } }
    }

    /// A service that enters with the account: what happens, and where the token stays.
    private var loginSection: some View {
        Section {
            Label("Ao continuar, o navegador abre para você entrar com a sua conta do \(config.name).", systemImage: "person.crop.circle")
                .foregroundStyle(Palette.secondary)
        } footer: { FormFootnote {
            Text("O token fica no Keychain do Mac. Você pode sair a qualquer momento.")
        } }
    }

    /// The app registered with the service, for a login the Orb cannot register itself for (the service asks for one).
    @ViewBuilder private var loginApp: some View {
        Section {
            TextField("Client ID", text: $clientID)
                .textFieldStyle(.roundedBorder)
            SecureField("Client Secret", text: $clientSecret, prompt: Text("Só se o app tiver um"))
                .textFieldStyle(.roundedBorder)
                .help("Guardado no Keychain do Mac; em branco, mantém o atual")
        } header: {
            Text("App registrado (login)")
        } footer: { FormFootnote {
            Text("Só para serviços que não deixam o Orb se registrar sozinho. O Client Secret fica no Keychain do Mac; deixe em branco para manter o atual.")
        } }
    }

    private var inputRows: [KeyValueRow] { values.filter { inputsByName[$0.key] != nil } }
    private var secretRows: [KeyValueRow] { inputRows.filter { isSecret($0.key) } }
    private var plainRows: [KeyValueRow] { inputRows.filter { !isSecret($0.key) } }

    @ViewBuilder private func inputFields(_ rows: [KeyValueRow]) -> some View {
        ForEach(rows) { row in
            KeyValueField(row: KeyValueRow.binding(in: $values, id: row.id, fallback: row), input: inputsByName[row.key],
                          secretNames: config.secretKeys) {}
        }
    }

    @ViewBuilder private var advancedFields: some View {
        Section {
            TextField("Nome", text: $config.name, prompt: Text("ex.: Meu servidor"))
            if config.source == nil && !isGuided {
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
        } footer: { FormFootnote {
            if let source = config.source { Text("Do registro: \(source)") }
        } }
        if isRemote && draft.guide != .slack { loginApp }
        if !isRemote {
            Section("Argumentos (um por linha)") {
                PlaceholderTextEditor(placeholder: "-y\n@exemplo/servidor", text: $arguments, minHeight: 60)
                    .font(.body.monospaced())
            }
        }
        Section {
            ForEach(values.filter { inputsByName[$0.key] == nil }) { row in
                KeyValueField(row: KeyValueRow.binding(in: $values, id: row.id, fallback: row), input: nil,
                              secretNames: config.secretKeys) {
                    values.removeAll { $0.id == row.id }
                }
            }
            Button(isRemote ? "Adicionar cabeçalho" : "Adicionar variável", systemImage: "plus") {
                values.append(KeyValueRow(key: "", value: ""))
            }
            .buttonStyle(.borderless)
            .help(isRemote ? "Adiciona um cabeçalho HTTP, enviado só para a URL" : "Adiciona uma variável de ambiente para o comando")
        } header: {
            Text(isRemote ? "Cabeçalhos HTTP" : "Variáveis de ambiente")
        } footer: { FormFootnote {
            Text(isRemote
                 ? "Enviados só para a URL acima. Valores que parecem chaves (token, senha…) ficam no Keychain do Mac."
                 : "O comando roda com o PATH do seu shell de login. Valores que parecem chaves (token, senha…) ficam no Keychain do Mac.")
        } }
    }

    private func isSecret(_ name: String) -> Bool {
        inputsByName[name]?.isSecret == true || ConnectorSecrets.looksSecret(name) || config.secretKeys.contains(name)
    }

    private func folderSection(index: Int) -> some View {
        let path = ConnectorArguments.line(index, in: arguments)
        let isHome = path == NSHomeDirectory()
        return Section {
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(Palette.muted)
                Text(isHome ? "Pasta pessoal (~)" : (path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Escolher pasta…") { chooseFolder(index: index, current: path) }
                    .help("Escolhe a pasta que este conector pode abrir")
            }
        } header: {
            Text("Pasta liberada")
        } footer: { FormFootnote {
            if isHome {
                Label("É a sua pasta pessoal inteira. Prefira escolher só a pasta de que o Orb precisa.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Palette.warn)
            } else {
                Text("Os Orbs com este conector podem ler e gravar arquivos nesta pasta e dentro dela.")
            }
        } }
    }

    private func chooseFolder(index: Int, current: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Liberar pasta"
        panel.message = "Escolha a pasta que este conector pode abrir."
        panel.directoryURL = URL(fileURLWithPath: current.isEmpty ? NSHomeDirectory() : current)
        if panel.runModal() == .OK, let url = panel.url {
            arguments = ConnectorArguments.replacing(line: index, with: url.path, in: arguments)
        }
    }

    // MARK: Result

    private func result(_ outcome: Outcome) -> some View {
        let (symbol, tint, title, detail, full) = (outcome.symbol, outcome.tint, outcome.title, outcome.detail, outcome.full)
        return VStack(spacing: 12) {
            // The check (or the warning) grows from 0.6 as it arrives, the same mark as everywhere (`mark`); the spinner
            // that was there gives way by fading.
            ZStack {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(tint)
                        .transition(.adapted(AnyTransition.mark.animation(Motion.enter), reduceMotion: reduceMotion))
                } else {
                    DelayedSpinner(size: .large).transition(.opacity)
                }
            }
            Text(title).font(.system(size: 15, weight: .semibold)).contentTransition(.opacity)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .contentTransition(.opacity)
            if let full, full != detail {
                Text(full)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(Palette.faint)
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.raised, in: .rect(cornerRadius: 8))
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 30)
        .accessibilityElement(children: .combine)
    }

    // MARK: Loading and saving

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        config = draft.config
        isRemote = draft.config.isRemote
        arguments = draft.config.arguments.joined(separator: "\n")
        let dictionary = isRemote ? draft.config.headers : draft.config.environment
        // Registry inputs first, in the publisher's order; then anything else. Fixed prefixes ("Bearer ") stay out of the field.
        let ordered = draft.inputs.map(\.name) + dictionary.keys.sorted().filter { inputsByName[$0] == nil }
        values = ordered.map { name in
            var value = dictionary[name] ?? ""
            if let prefix = inputsByName[name]?.prefix, !prefix.isEmpty, value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
            return KeyValueRow(key: name, value: value)
        }
        openedAsNew = !model.connectors.contains { $0.id == draft.config.id }
        clientID = draft.config.oauth?.clientID ?? ""
        // Slack: an installed one that holds a token (no login settings) is edited as it was made; a new one starts with the login.
        pastesToken = draft.guide == .slack && draft.config.oauth == nil
        if draft.config.oauth?.scopes?.contains("chat:write") == true { slackPreset = .readAndSend }
        // A new connector from the catalog starts with the Orb the user was talking to, so installing it is enough.
        orbIDs = draft.config.orbIDs ?? (isNew ? model.defaultScopeForNewConnector() : nil)
        showsAdvanced = !isNew
        phase = initialPhase
    }

    private func save() {
        let pairs = values.map { row -> (String, String) in
            let key = row.key.trimmingCharacters(in: .whitespaces)
            var value = row.value
            if let prefix = inputsByName[key]?.prefix, !prefix.isEmpty, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                value = prefix + value.trimmingCharacters(in: .whitespaces)
            }
            return (key, value)
        }.filter { !$0.0.isEmpty }
        let dictionary = Dictionary(pairs, uniquingKeysWith: { _, last in last })
        if isRemote {
            config.command = ""
            config.arguments = []
            config.environment = [:]
            config.headers = signsInWithApp ? [:] : dictionary // signing in with the app's Client ID, there is no token to keep
        } else {
            config.url = ""
            config.headers = [:]
            config.arguments = arguments.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            config.environment = dictionary
        }
        config.secretKeys = Set((isRemote ? config.headers : config.environment).keys.filter(isSecret))
        config.orbIDs = orbIDs
        config.oauth = oauthSettings()
        if !draft.summary.isEmpty { config.summary = String(draft.summary.prefix(200)) }

        let before = alreadyUsing
        if let index = model.connectors.firstIndex(where: { $0.id == config.id }) {
            model.connectors[index] = config
        } else {
            model.connectors.append(config)
        }
        // Choosing an Orb is enough: its "Conectores" switch follows.
        model.allowConnectors(for: (orbIDs ?? []).subtracting(before))

        let id = config.id, secret = clientSecret.trimmingCharacters(in: .whitespaces)
        guard config.isEnabled else {
            // A disabled connector still keeps the secret that was typed.
            if !secret.isEmpty { Task { await model.connectorAuth.setClientSecret(secret, clientID: clientID, for: id) } }
            dismiss()
            return
        }
        let appChanged = clientID.trimmingCharacters(in: .whitespaces) != (draft.config.oauth?.clientID ?? "") || !secret.isEmpty
        let wantsLogin = signsIn
        phase = wantsLogin && isNew ? .signingIn : .connecting
        signInTask = Task { @MainActor in
            if !secret.isEmpty { await model.connectorAuth.setClientSecret(secret, clientID: clientID, for: id) }
            // A new login, or a new app to sign in with; otherwise the one it has is used.
            let signedIn = await model.connectorAuth.isSignedIn(id)
            if wantsLogin, appChanged || !signedIn { return await signIn(id) }
            let status = await model.connectAndWait(id)
            if case .needsSignIn? = status { return await signIn(id) } // the server asked for a login the form did not know about
            switch status {
            case .ready(let count)?: await show(.connected(count))
            case .failed(let message)?: phase = .failed(message)
            default: phase = .failed("O conector não respondeu.")
            }
        }
    }

    /// Opens the browser for the login and waits for the way back; then the connector is started.
    private func signIn(_ id: UUID) async {
        phase = .signingIn
        switch await model.signIn(connector: id) {
        case .connected(let tools, _): await show(.connected(tools))
        case .failed(let message): phase = .failed(message)
        }
    }

    /// A connection that worked is shown for a moment, then the sheet closes.
    private func show(_ done: Phase) async {
        phase = done
        try? await Task.sleep(for: .seconds(1.6))
        if phase == done { dismiss() }
    }

    /// How the connector signs in, from the form: the Client ID typed (and Slack's redirect and scopes), kept only for a connector that
    /// signs in; nil for one that does not.
    private func oauthSettings() -> MCPOAuthSettings? {
        let typed = clientID.trimmingCharacters(in: .whitespaces)
        guard isRemote, !(draft.guide == .slack && pastesToken), config.oauth != nil || !typed.isEmpty else { return nil }
        var settings = config.oauth ?? MCPOAuthSettings()
        settings.clientID = typed.isEmpty ? nil : typed
        if draft.guide == .slack {
            settings.scopes = SlackApp.scopes(slackPreset).joined(separator: " ")
            settings.redirect = SlackApp.redirectURL
        }
        return settings
    }
}

struct KeyValueRow: Identifiable {
    let id = UUID()
    var key: String
    var value: String

    /// A binding to the row with this id that looks it up on every access: a field that still pushes its text after
    /// the row was removed finds nothing (reads `fallback`, writes nowhere) instead of indexing a stale position.
    static func binding(in rows: Binding<[KeyValueRow]>, id: UUID, fallback: KeyValueRow) -> Binding<KeyValueRow> {
        Binding(
            get: { rows.wrappedValue.first { $0.id == id } ?? fallback },
            set: { new in
                if let index = rows.wrappedValue.firstIndex(where: { $0.id == id }) { rows.wrappedValue[index] = new }
            }
        )
    }
}

/// One variable/header: the name (fixed when it comes from the registry), its value and what it is for.
private struct KeyValueField: View {
    @Binding var row: KeyValueRow
    let input: RegistryServer.Input?
    let secretNames: Set<String>
    let onRemove: () -> Void

    private var isSecret: Bool {
        input?.isSecret == true || secretNames.contains(row.key) || ConnectorSecrets.looksSecret(row.key)
    }

    private var isAuthorizationHeader: Bool { row.key == "Authorization" && input?.prefix.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if input != nil {
                    // The HTTP header ("Authorization" + "Bearer ") is plumbing: the person sees a key to paste, and the
                    // prefix is added back when saving.
                    Text(isAuthorizationHeader ? "Chave de acesso" : row.key)
                        .font(isAuthorizationHeader ? .system(size: 13) : .system(size: 12).monospaced())
                        .frame(width: 170, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    TextField("NOME", text: $row.key)
                        .font(.system(size: 12).monospaced())
                        .frame(width: 170)
                }
                if !isAuthorizationHeader, let prefix = input?.prefix.trimmingCharacters(in: .whitespaces), !prefix.isEmpty {
                    Text(prefix)
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(Palette.muted)
                }
                Group {
                    if isSecret {
                        SecureField("valor", text: $row.value)
                    } else {
                        TextField("valor", text: $row.value)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel(row.key.isEmpty ? "Valor" : "Valor de \(row.key)")
                if input == nil {
                    Button("Remover", systemImage: "minus.circle", action: onRemove)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Tira esta linha do conector; vale quando você salvar")
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
