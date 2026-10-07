import SwiftUI

/// Ajustes → Modelos: the default model and every provider (sign-in or key, live model list, enable, remove).
struct ProviderSettings: View {
    @Environment(AppModel.self) private var model

    private var available: [ProviderKind] { ProviderKind.allCases.filter { model.account($0) == nil } }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ModelPicker(selection: $model.defaultModel, title: "Modelo padrão", allowsDefault: false)
                    .disabled(model.modelChoices.isEmpty)
            } footer: {
                Text(model.modelChoices.isEmpty
                     ? "Adicione um provedor abaixo para escolher um modelo."
                     : "Usado pelos bots que não têm um modelo próprio. As listas de modelos se atualizam sozinhas.")
            }
            ForEach(model.providers) { account in
                ProviderSection(kind: account.kind)
            }
            Section {
                Menu("Adicionar provedor", systemImage: "plus") {
                    ForEach(available) { kind in
                        Button(kind.label) { model.addProvider(kind) }
                    }
                }
                .disabled(available.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderSection: View {
    @Environment(AppModel.self) private var model
    let kind: ProviderKind
    @State private var key = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var email: String?
    @State private var isConfirmingRemoval = false

    private var account: ProviderAccount? { model.account(kind) }
    private var isConnected: Bool { account.map(model.isUsable) ?? false }

    var body: some View {
        if let account {
            Section {
                LabeledContent("Status") { status(account) }
                if kind == .claudeCode {
                    ClaudeCodeAccountRow()
                } else if kind.usesSignIn {
                    signInRow
                } else if kind.needsKey || kind == .custom {
                    keyRow
                }
                if kind.hasEditableURL {
                    TextField("URL base", text: Binding(get: { account.baseURL },
                                                       set: { url in model.updateProvider(kind) { $0.baseURL = url } }),
                              prompt: Text("http://localhost:11434/v1"))
                }
                Toggle("Usar este provedor", isOn: Binding(get: { account.isEnabled },
                                                          set: { on in model.updateProvider(kind) { $0.isEnabled = on } }))
                HStack {
                    Button(isWorking ? "Atualizando…" : "Atualizar modelos", systemImage: "arrow.clockwise") {
                        run { try await model.refreshModels(kind) }
                    }
                    .disabled(isWorking || !isConnected)
                    Spacer()
                    Button("Remover", role: .destructive) { isConfirmingRemoval = true }
                }
                .buttonStyle(.borderless)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.warn)
                }
            } header: {
                Text(kind.label)
            } footer: {
                Text(kind.summary)
            }
            .confirmationDialog("Remover \(kind.label)?", isPresented: $isConfirmingRemoval) {
                Button("Remover e apagar a chave", role: .destructive) { model.removeProvider(kind) }
            } message: {
                Text("Bots que usam modelos deste provedor passam a usar o modelo padrão.")
            }
            .task(id: kind) { email = kind == .chatgpt ? await ChatGPTAuth.shared.credential?.email : nil }
        }
    }

    @ViewBuilder private func status(_ account: ProviderAccount) -> some View {
        if isConnected && !account.models.isEmpty {
            HStack(spacing: 6) {
                Label("\(account.models.count) modelos", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                if let updated = account.modelsUpdatedAt {
                    (Text("· atualizado ") + Text(updated, style: .relative)).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        } else if isConnected {
            Label("Conectado", systemImage: "checkmark.circle").foregroundStyle(Palette.muted).font(.caption)
        } else {
            Label(kind.usesSignIn ? "Não conectado" : "Falta a chave", systemImage: "circle.dashed")
                .foregroundStyle(Palette.muted).font(.caption)
        }
    }

    @ViewBuilder private var signInRow: some View {
        if isConnected {
            LabeledContent("Conta") {
                HStack {
                    Text(email ?? "ChatGPT").foregroundStyle(.secondary)
                    Button("Sair") { model.signOut(kind) }
                }
            }
        } else {
            LabeledContent {
                Button(isWorking ? "Aguardando o navegador…" : "Entrar com ChatGPT") {
                    run {
                        try await model.signIn(kind)
                        email = await ChatGPTAuth.shared.credential?.email
                    }
                }
                .disabled(isWorking)
            } label: {
                Text("Abre o navegador para você entrar na sua conta. Precisa de Plus ou Pro.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var keyRow: some View {
        LabeledContent("Chave de API") {
            HStack {
                SecureField("Chave", text: $key, prompt: Text(isConnected ? "Salva no Keychain" : "Cole a chave"))
                    .labelsHidden()
                    .onSubmit(saveKey)
                if !key.isEmpty {
                    Button("Salvar", action: saveKey).disabled(isWorking)
                } else if let page = kind.keyPage {
                    Link("Obter chave", destination: page)
                }
            }
        }
    }

    private func saveKey() {
        let value = key
        key = ""
        run { try await model.setKey(value, for: kind) }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            isWorking = false
        }
    }
}
