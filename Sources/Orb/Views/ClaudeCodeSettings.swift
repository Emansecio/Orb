import SwiftUI

/// Ajustes → Modelos → Claude Code: install state and the account Claude Code itself is signed in to.
/// Signing in and out runs Claude Code's own commands; Orb never handles the credentials.
struct ClaudeCodeAccountRow: View {
    @Environment(AppModel.self) private var model
    @State private var hasChecked = false
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        Group {
            if !hasChecked {
                LabeledContent("Conta") { ProgressView().controlSize(.small) }
            } else if !model.claudeCode.isInstalled {
                notInstalled
            } else if model.claudeCode.isLoggedIn {
                LabeledContent("Conta") {
                    HStack {
                        Text(model.claudeCode.accountLabel).foregroundStyle(.secondary)
                        Button("Sair") { run { await model.signOutOfClaudeCode() } }.disabled(isWorking)
                    }
                }
                Text("Sair desconecta o Claude Code neste Mac, inclusive no Terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent {
                    Button(isWorking ? "Aguardando o navegador…" : "Entrar com Claude Code") {
                        run { try await model.signIn(.claudeCode) }
                    }
                    .disabled(isWorking)
                } label: {
                    Text("O próprio Claude Code abre o navegador para você entrar na sua conta Claude (Pro ou Max).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.warn)
            }
        }
        .task {
            await model.refreshConnections()
            hasChecked = true
            // Already signed in to Claude Code (e.g. in the Terminal): load its models right away.
            if model.claudeCode.isLoggedIn, model.account(.claudeCode)?.models.isEmpty == true {
                try? await model.refreshModels(.claudeCode)
            }
        }
    }

    private var notInstalled: some View {
        LabeledContent {
            HStack {
                Button("Verificar de novo") { run { await model.refreshConnections() } }.disabled(isWorking)
                if let page = ClaudeCode.setupPage { Link("Como instalar", destination: page) }
            }
        } label: {
            Text("O Claude Code não está instalado neste Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
