import SwiftUI

/// Ajustes → Modelos → Claude Code: install state and the account Claude Code itself is signed in to.
/// Signing in and out runs Claude Code's own commands; Orb never handles the credentials.
/// The row says which of three things is true, in one sentence with its action: not installed, not signed in, signed in.
struct ClaudeCodeAccountRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var hasChecked = false
    @State private var isWorking = false
    @State private var error: String?
    @State private var isConfirmingSignOut = false

    var body: some View {
        Group {
            if !hasChecked {
                LabeledContent("Conta") { ProgressView().controlSize(.small) }
            } else if !model.claudeCode.isInstalled {
                line("exclamationmark.triangle.fill", Palette.warn, "Claude Code não encontrado neste Mac") {
                    Button("Verificar de novo") { run { await model.refreshConnections() } }.disabled(isWorking)
                        .help(Tip.checkClaudeCode)
                        .chipButton()
                    // A chip like "Verificar de novo" beside it: a system-blue Link next to a gray chip looked like two apps.
                    if let page = ClaudeCode.setupPage {
                        Button("Como instalar") { openURL(page) }.help(Tip.installClaudeCode).chipButton()
                    }
                }
            } else if model.claudeCode.isLoggedIn {
                line("checkmark.circle.fill", Palette.ok, "Conectado como \(model.claudeCode.accountLabel)\(modelCount)") {
                    Button("Sair da conta") { isConfirmingSignOut = true }.disabled(isWorking)
                        .help(Tip.signOutClaudeCode)
                        .buttonStyle(GhostStyle())
                        .controlSize(.small)
                        .hangsOnTrailingEdge()
                }
            } else {
                line("person.crop.circle.badge.questionmark", Palette.muted, "Entre na sua conta Claude (Pro ou Max)") {
                    Button(isWorking ? "Aguardando o navegador…" : "Entrar") {
                        run { try await model.signIn(.claudeCode) }
                    }
                    .help(Tip.signInClaudeCode)
                    .disabled(isWorking)
                    .chipButton()
                }
                Text("O próprio Claude Code abre o navegador para você entrar.").capabilityCaption()
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.small)
                    .foregroundStyle(Palette.danger)
            }
        }
        .confirmationDialog("Sair da conta do Claude Code?", isPresented: $isConfirmingSignOut) {
            Button("Sair da conta", role: .destructive) { run { await model.signOutOfClaudeCode() } }
        } message: {
            Text("Isso desconecta o Claude Code neste Mac, inclusive no Terminal.")
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

    private var modelCount: String {
        let count = model.account(.claudeCode)?.models.count ?? 0
        return count == 0 ? "" : " · \(count) \(count == 1 ? "modelo" : "modelos")"
    }

    private func line<Actions: View>(_ symbol: String, _ tint: Color, _ text: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        LabeledContent {
            HStack(spacing: Spacing.controlGap) { actions() }
        } label: {
            Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
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
