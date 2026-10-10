import SwiftUI
import AppKit

/// Ajustes → Navegador: install, update and remove the browsers the Orbs drive, and keep the key of the search that needs one.
/// Everything is installed inside the app's data folder (nothing from Homebrew or Node, nothing with administrator rights).
struct BrowserSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let setup = model.browserSetup
        Form {
            Section {
                ForEach(setup.rows) { row in BrowserEngineRowView(row: row, setup: setup) }
            } header: {
                Text("Navegadores")
            } footer: { FormFootnote {
                Text("Cada Orb escolhe o seu no painel dele. O modo Leitura simples lê páginas sem JavaScript e não precisa de nada instalado. "
                     + "O que você instala aqui fica na pasta de dados do Orb, sem Homebrew, sem Node e sem pedir senha.")
            } }
            SearchKeySection()
            Section("Privacidade") {
                Text("Os navegadores rodam neste Mac, em segundo plano, e guardam os logins de cada Orb em uma pasta separada. "
                     + "Senhas nunca são digitadas pelo Orb: quando um site pede, ele abre a janela para você. "
                     + "As buscas do Google e do DuckDuckGo saem do seu IP; a do TinyFish passa pela conta dele.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .orbFormBackground()
        .task {
            await setup.refresh()
            await setup.checkForUpdates() // at most once a day
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await setup.refresh() }
        }
    }
}

/// One engine: its name and what it is, what it is doing, and the buttons that fit its state.
private struct BrowserEngineRowView: View {
    let row: BrowserEngineRow
    let setup: BrowserSetup
    @State private var isConfirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.engine.label).font(.body.weight(.medium))
                if row.updateAvailable, case .installed(managed: true) = row.phase {
                    CatalogBadge(text: "Atualização", tint: Palette.accentText)
                }
                Spacer()
                actions
            }
            Text(row.engine.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            statusLine
            if case .installing(let progress) = row.phase {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        }
        .padding(.vertical, 2)
        .animation(.default, value: row.phase)
        .confirmationDialog("Remover o navegador \(row.engine.label)?", isPresented: $isConfirmingRemoval) {
            Button("Remover e manter os logins") { setup.remove(row.engine) }
            if row.engine.keepsProfile {
                Button("Remover e apagar os logins dos Orbs", role: .destructive) { setup.remove(row.engine, removeProfiles: true) }
            }
        } message: {
            Text(row.engine.keepsProfile
                 ? "Os arquivos do navegador saem deste Mac. Os logins que os Orbs guardaram ficam, a menos que você apague também."
                 : "Os arquivos do navegador saem deste Mac. Você pode instalar de novo quando quiser.")
        }
    }

    @ViewBuilder private var actions: some View {
        switch row.phase {
        case .checking:
            EmptyView()
        case .notInstalled, .failed:
            Button(isFailed ? "Tentar de novo" : "Instalar") { setup.install(row.engine) }
                .disabled(!row.canInstall)
                .help(isFailed ? "Tenta instalar de novo" : "Baixa e instala este navegador na pasta do Orb")
        case .installing:
            Button("Cancelar") { setup.cancel() }
                .help("Interrompe a instalação e descarta o que já foi baixado")
        case .installed(let managed):
            if managed {
                if row.canUpdate {
                    Button("Atualizar") { setup.update(row.engine) }
                        .help("Instala a versão mais nova")
                }
                Button("Remover…", role: .destructive) { isConfirmingRemoval = true }
                    .disabled(!row.canRemove)
                    .buttonStyle(.borderless)
                    .help("Tira este navegador do Mac, perguntando antes")
            }
        }
    }

    private var isFailed: Bool { if case .failed = row.phase { true } else { false } }

    @ViewBuilder private var statusLine: some View {
        switch row.phase {
        case .installed:
            Label(row.statusText, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Palette.ok)
        case .failed:
            Label(row.statusText, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Palette.warn)
                .fixedSize(horizontal: false, vertical: true)
        case .installing:
            HStack(spacing: 6) {
                Text(row.statusText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let progress = installingProgress, progress.componentFraction != nil {
                    Text("\(Int(((progress.fraction ?? 0) * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(row.statusText).font(.caption).foregroundStyle(.secondary)
            }
        case .notInstalled:
            Label(row.statusText, systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(Palette.muted)
        }
    }

    private var installingProgress: BrowserInstallProgress? {
        if case .installing(let progress) = row.phase { progress } else { nil }
    }
}

/// The TinyFish key: free, no card, kept in the Keychain with the providers' keys.
private struct SearchKeySection: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var hasKey: Bool?
    @State private var isReplacing = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var keys: SearchKeys { SearchKeys(vault: model.secretVault) }

    var body: some View {
        Section {
            LabeledContent("Chave do TinyFish") {
                if hasKey == true && !isReplacing {
                    HStack(spacing: 10) {
                        Label("Chave salva", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                        Button("Trocar") {
                            isReplacing = true
                            focused = true
                        }
                        .buttonStyle(.borderless)
                        .help(Tip.replaceKey)
                        Button("Apagar") { save("") }
                            .buttonStyle(.borderless)
                            .help(Tip.deleteKey)
                    }
                } else {
                    HStack {
                        SecureField("Chave", text: $key, prompt: Text("Cole a chave"))
                            .labelsHidden()
                            .focused($focused)
                            .onSubmit { save(key) }
                        if !key.isEmpty {
                            Button("Salvar") { save(key) }
                                .help(Tip.saveKey)
                        } else if isReplacing {
                            Button("Cancelar") { isReplacing = false }
                                .help(Tip.keepKey)
                        } else if let page = SearchKeyCopy.keyPage {
                            Link("Obter chave", destination: page)
                                .help(Tip.getKey)
                        }
                    }
                }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.warn)
            }
        } header: {
            Text("Pesquisa na web")
        } footer: { FormFootnote {
            Text(SearchKeyCopy.footer)
        } }
        .task { hasKey = await Self.read(keys) }
    }

    private func save(_ value: String) {
        let keys = keys
        key = ""
        failure = nil
        Task {
            let stored = (try? await runDetached { keys.setTinyFish(value) }) ?? false
            if stored {
                hasKey = await Self.read(keys)
                isReplacing = false
            } else {
                failure = "O Keychain não guardou a chave. Tente de novo."
            }
        }
    }

    private static func read(_ keys: SearchKeys) async -> Bool {
        ((try? await runDetached { keys.tinyFish }) ?? nil) != nil
    }
}

/// The words around the TinyFish key.
enum SearchKeyCopy {
    static let keyPage = URL(string: "https://agent.tinyfish.ai/api-keys")

    static let footer = "O TinyFish é grátis e não pede cartão: crie a conta em agent.tinyfish.ai e cole a chave aqui. "
        + "Ela fica no Keychain deste Mac. Sem chave, ou quando a cota do dia acaba, a pesquisa usa o DuckDuckGo."
}
