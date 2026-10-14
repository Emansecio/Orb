import SwiftUI

/// What the last model refresh of each provider said, so a row can be honest: a local server that is not running is
/// "Servidor não encontrado", not "Conectado".
@MainActor @Observable
final class ProviderHealth {
    private(set) var failures: [ProviderKind: ProviderCheckFailure] = [:]
    private(set) var checking: Set<ProviderKind> = []

    func failure(of kind: ProviderKind) -> ProviderCheckFailure? { failures[kind] }
    func isChecking(_ kind: ProviderKind) -> Bool { checking.contains(kind) }

    /// Reloads the provider's models and remembers how it went. Rethrows so a caller can show it too.
    func refresh(_ kind: ProviderKind, model: AppModel) async throws {
        guard !checking.contains(kind) else { return }
        checking.insert(kind)
        defer { checking.remove(kind) }
        do {
            try await model.refreshModels(kind)
            failures[kind] = nil
        } catch {
            failures[kind] = ProviderCheck.failure(from: error)
            throw error
        }
    }

    /// Remembers a failure (nil: forgets it).
    func record(_ error: Error?, for kind: ProviderKind) { failures[kind] = error.map(ProviderCheck.failure(from:)) }

    /// Local servers and gateways are looked at when the tab opens (a request to your own machine takes
    /// milliseconds), so their rows say what is true. Providers with a remote key are refreshed by the app on its own.
    func checkServers(model: AppModel) async {
        for account in model.providers where account.isEnabled && (account.kind.isLocalServer || account.kind == .custom)
            && (account.kind.isLocalServer || GatewayForm.urlState(account.baseURL) == .valid) {
            try? await refresh(account.kind, model: model)
        }
    }
}

/// Ajustes → Modelos: the default model and every provider, grouped by how it is paid for or reached.
struct ProviderSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var health = ProviderHealth()
    @State private var firstRun = FirstRunModel()

    var body: some View {
        @Bindable var model = model
        Form {
            // The card stays while a connection is under way, failed or just done ("Pronto"), not only while no provider
            // is listed: connecting adds the provider first, and the card would vanish before saying how it went.
            if model.providers.isEmpty || firstRun.working != nil || firstRun.failure != nil || firstRun.connectedName != nil {
                // The card to connect and the default model trade places by fading, in the Form's own rows (`.quiet`).
                Section { FirstRunCard(style: .settings, run: firstRun).transition(.quiet) }
            } else {
                let noModels = model.modelChoices.isEmpty
                Section {
                    if noModels {
                        LabeledContent("Modelo padrão") {
                            Text("Nenhum modelo ainda").foregroundStyle(Palette.muted)
                        }
                    } else {
                        ModelPicker(selection: $model.defaultModel, title: "Modelo padrão", allowsDefault: false)
                    }
                } footer: { FormFootnote {
                    Text(noModels
                         ? "Conecte um provedor abaixo: os modelos dele aparecem aqui."
                         : model.isProviderReady || !model.hasCheckedConnections
                         ? "Usado por Orbs sem modelo próprio."
                         : "O modelo padrão não está disponível. Escolha outro.")
                        .textSwap(noModels ? 0 : model.isProviderReady || !model.hasCheckedConnections ? 1 : 2)
                } }
            }
            ForEach(ProviderGroup.allCases) { group in
                let kinds = group.kinds.filter { model.account($0) != nil }
                if !kinds.isEmpty {
                    Section(group.title) {
                        // A provider added comes in, and one removed goes, by fading: the row is a Form's.
                        ForEach(kinds) { ProviderRow(kind: $0, health: health).transition(.adapted(.opacity.animation(Motion.exit), reduceMotion: reduceMotion)) }
                    }
                }
            }
            Section { addMenu }
        }
        .formStyle(.grouped)
        .orbFormBackground()
        .task(id: model.providers.map(\.kind)) { await health.checkServers(model: model) }
    }

    private var addMenu: some View {
        Menu {
            ForEach(ProviderGroup.allCases) { group in
                let kinds = group.kinds.filter { model.account($0) == nil }
                if !kinds.isEmpty {
                    Section(group.title) {
                        ForEach(kinds) { kind in
                            Button(kind.shortName) {
                                model.addProvider(kind)
                                ProviderExpansion.set(kind, expanded: true) // a new provider opens for setup
                            }
                            .help(kind.tagline)
                        }
                    }
                }
            }
        } label: {
            Label(model.providers.isEmpty ? "Outros provedores" : "Adicionar provedor", systemImage: "plus")
        }
        .help(Tip.addProvider)
        .disabled(ProviderKind.allCases.allSatisfy { model.account($0) != nil })
    }
}

/// One provider as an expandable row: status in a line, credential and address inside.
private struct ProviderRow: View {
    @Environment(AppModel.self) private var model
    let kind: ProviderKind
    let health: ProviderHealth
    @State private var key = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var email: String?
    @State private var isReplacingKey = false
    @State private var isConfirmingRemoval = false
    @State private var isConfirmingSignOut = false
    /// The browser sign-in under way, so it can be cancelled when the tab was closed or the login went wrong.
    @State private var signInTask: Task<Void, Never>?
    @FocusState private var keyFocused: Bool
    @AppStorage(ProviderExpansion.storageKey) private var expansion = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var account: ProviderAccount? { model.account(kind) }
    private var isConnected: Bool { account.map(model.isUsable) ?? false }
    private var hasKey: Bool { model.storedKeys.contains(kind) }
    private var isDefault: Bool { ModelRef(model.defaultModel)?.provider == kind }
    /// The user's choice, else open only the provider of the default model.
    private var isExpanded: Bool { ProviderExpansion.parse(expansion)[kind] ?? isDefault }

    private func status(_ account: ProviderAccount) -> ProviderStatus {
        ProviderStatus.make(kind: kind, account: account, isConnected: isConnected, lastError: health.failure(of: kind),
                            isChecking: health.isChecking(kind) || isWorking)
    }

    var body: some View {
        if let account {
            let status = status(account)
            DisclosureGroup(isExpanded: Binding(get: { isExpanded }, set: { ProviderExpansion.set(kind, expanded: $0) })) {
                details(account, status: status)
            } label: {
                HStack(spacing: 8) {
                    Text(kind.shortName)
                    if isDefault {
                        CatalogBadge(text: "Padrão", tint: Palette.accentText)
                    }
                    Spacer()
                    statusLabel(status)
                    optionsMenu(account)
                }
                .contentShape(.rect)
                .help(isExpanded ? Tip.hideProviderDetails : Tip.showProviderDetails)
                .onTapGesture {
                    withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) { ProviderExpansion.set(kind, expanded: !isExpanded) }
                }
            }
            .confirmationDialog("Remover o provedor \(kind.shortName)?", isPresented: $isConfirmingRemoval) {
                Button(kind.removeButtonTitle, role: .destructive) { model.removeProvider(kind) }
            } message: {
                Text("Os Orbs que usam estes modelos passam a usar o modelo padrão.")
            }
            .task(id: kind) { email = kind == .chatgpt ? await ChatGPTAuth.shared.credential?.email : nil }
        }
    }

    // MARK: Collapsed line

    private func statusLabel(_ status: ProviderStatus) -> some View {
        let symbol: String, tint: Color
        switch status {
        case .ready: (symbol, tint) = ("checkmark.circle.fill", Palette.ok)
        case .checking: (symbol, tint) = ("ellipsis.circle", Palette.muted)
        case .offline, .failed, .needsKey, .needsSignIn, .needsURL: (symbol, tint) = ("exclamationmark.circle", Palette.warn)
        case .disabled: (symbol, tint) = ("pause.circle", Palette.muted)
        case .noModels, .unverified: (symbol, tint) = ("circle.dashed", Palette.muted)
        }
        return HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(status.summary()).foregroundStyle(Palette.muted)
        }
        .font(.caption)
        .lineLimit(1)
        // The label changes in place (checking, ready, failed…): the words cross-fade and the line changes at once.
        .contentTransition(.opacity)
        .motion(Motion.content, value: status.summary())
        .accessibilityElement(children: .combine)
    }

    private func optionsMenu(_ account: ProviderAccount) -> some View {
        Menu {
            Button(account.isEnabled ? "Desativar este provedor" : "Usar este provedor") {
                model.updateProvider(kind) { $0.isEnabled.toggle() }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Tip.moreOptions(of: kind.shortName))
        .accessibilityLabel("Mais opções de \(kind.shortName)")
    }

    // MARK: Open row

    @ViewBuilder private func details(_ account: ProviderAccount, status: ProviderStatus) -> some View {
        Text(kind.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        if let text = status.explanation(for: kind) {
            Label(text, systemImage: status.isProblem ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.caption)
                .foregroundStyle(status.isProblem ? Palette.warn : Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        if kind == .claudeCode {
            ClaudeCodeAccountRow()
        } else if kind.usesSignIn {
            signInRow
        }
        if kind.hasEditableURL { urlField(account) }
        if kind == .custom {
            CustomProviderFields(account: account, health: health) { keyRow }
        } else if kind.needsKey {
            keyRow
        }
        HStack {
            Button(health.isChecking(kind) ? "Atualizando…" : "Atualizar modelos", systemImage: "arrow.clockwise") {
                refreshByHand()
            }
            .help(Tip.refreshModels)
            .disabled(isWorking || health.isChecking(kind) || !canRefresh(account))
            Spacer()
            Button("Remover…", role: .destructive) { isConfirmingRemoval = true }
                .help(Tip.removeProvider)
        }
        .buttonStyle(.borderless)
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Palette.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A refresh the user asked for: when the default model cannot be used, the models just listed take its place.
    private func refreshByHand() {
        run(inStatus: true) {
            try await health.refresh(kind, model: model)
            model.adoptDefaultModel(from: kind, turningOn: false)
        }
    }

    private func canRefresh(_ account: ProviderAccount) -> Bool {
        if kind == .custom { return GatewayForm.urlState(account.baseURL) == .valid }
        return isConnected
    }

    private func urlField(_ account: ProviderAccount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("URL base", text: Binding(get: { account.baseURL },
                                                set: { url in model.updateProvider(kind) { $0.baseURL = url } }),
                      prompt: Text(kind == .custom ? "https://meu-gateway.exemplo/v1" : kind.defaultBaseURL))
                .onSubmit(refreshByHand)
            if GatewayForm.urlState(account.baseURL) == .invalid {
                Label("Use um endereço que comece com http:// ou https://", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.warn)
            }
        }
    }

    @ViewBuilder private var signInRow: some View {
        if isConnected {
            LabeledContent("Conta") {
                HStack {
                    Text(email ?? "ChatGPT").foregroundStyle(.secondary)
                    Button("Sair") { isConfirmingSignOut = true }
                        .buttonStyle(.borderless) // as "Trocar" and "Remover…" in the other rows
                        .help(Tip.signOutChatGPT)
                }
            }
            .confirmationDialog("Sair do ChatGPT?", isPresented: $isConfirmingSignOut) {
                Button("Sair", role: .destructive) { model.signOut(kind) }
            } message: {
                Text("Os Orbs que usam estes modelos não respondem até você entrar de novo ou escolher outro modelo.")
            }
        } else {
            LabeledContent {
                HStack(spacing: 10) {
                    if isWorking {
                        Button("Cancelar") { signInTask?.cancel() }.buttonStyle(GhostStyle())
                            .help(Tip.stopConnecting)
                    }
                    Button(isWorking ? "Aguardando o navegador…" : "Entrar com ChatGPT") {
                        signInTask = run {
                            try await model.signIn(kind)
                            email = await ChatGPTAuth.shared.credential?.email
                        }
                    }
                    .help(Tip.signInChatGPT)
                    .disabled(isWorking)
                }
            } label: {
                Text("Abre o navegador para você entrar. Precisa de ChatGPT Plus ou Pro.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var keyRow: some View {
        LabeledContent(kind == .custom ? "Chave (opcional)" : "Chave de API") {
            if hasKey && !isReplacingKey {
                HStack(spacing: 10) {
                    if case .rejected = health.failure(of: kind) {
                        Label("Chave recusada", systemImage: "exclamationmark.circle").foregroundStyle(Palette.warn)
                    } else {
                        Label("Chave salva", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                    }
                    Button("Trocar") {
                        isReplacingKey = true
                        keyFocused = true
                    }
                    .buttonStyle(.borderless)
                    .help(Tip.replaceKey)
                    if kind == .custom { // the gateway's key is optional: it can go without removing the provider
                        Button("Apagar") { run(inStatus: true) { try await model.setKey("", for: kind) } }
                            .buttonStyle(.borderless)
                            .help(Tip.deleteKey)
                    }
                }
            } else {
                HStack {
                    SecureField("Chave", text: $key, prompt: Text("Cole a chave"))
                        .labelsHidden()
                        .focused($keyFocused)
                        .onSubmit(saveKey)
                    if !key.isEmpty {
                        Button("Salvar", action: saveKey).disabled(isWorking)
                            .help(Tip.saveKey)
                    } else if isReplacingKey {
                        Button("Cancelar") { isReplacingKey = false }
                            .help(Tip.keepKey)
                    } else if let page = kind.keyPage {
                        Link("Obter chave", destination: page)
                            .help(Tip.getKey)
                    }
                }
            }
        }
    }

    private func saveKey() {
        let value = key
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        key = ""
        run(inStatus: true) {
            try await model.setKey(value, for: kind)
            isReplacingKey = false
        }
    }

    /// Runs `work`. A failure of loading models goes to the status line (`inStatus`); any other (a sign-in) is said
    /// under the row.
    @discardableResult
    private func run(inStatus: Bool = false, _ work: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        isWorking = true
        error = nil
        return Task {
            do {
                try await work()
                if inStatus { health.record(nil, for: kind) }
            } catch where error is CancellationError || Task.isCancelled {
                // Cancelled by the person (the browser sign-in): nothing to report.
            } catch {
                if inStatus { health.record(error, for: kind) } else { self.error = error.localizedDescription }
            }
            isWorking = false
        }
    }
}

/// Which provider sections are open in Ajustes → Modelos, remembered as "kind:1,kind:0" in UserDefaults.
enum ProviderExpansion {
    static let storageKey = "expandedProviders"

    static func parse(_ text: String) -> [ProviderKind: Bool] {
        Dictionary(text.split(separator: ",").compactMap { pair -> (ProviderKind, Bool)? in
            let parts = pair.split(separator: ":")
            guard parts.count == 2, let kind = ProviderKind(rawValue: String(parts[0])) else { return nil }
            return (kind, parts[1] == "1")
        }, uniquingKeysWith: { _, last in last })
    }

    static func set(_ kind: ProviderKind, expanded: Bool) {
        var state = parse(UserDefaults.standard.string(forKey: storageKey) ?? "")
        state[kind] = expanded
        UserDefaults.standard.set(state.map { "\($0.key.rawValue):\($0.value ? 1 : 0)" }.sorted().joined(separator: ","),
                                  forKey: storageKey)
    }
}
