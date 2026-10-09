import SwiftUI

/// "Conectar" for Google Agenda, Lembretes and Gmail: one click asks macOS for the permission, and when the Google account is
/// not on this Mac yet a short guide takes the person to Contas de Internet. The login is Apple's, so the Orb needs no
/// password and no review from Google.
struct LocalConnectorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: LocalConnectorKind
    /// Snapshots draw one phase of the sheet.
    var initialPhase: Phase = .intro

    enum Phase: Equatable {
        /// Said what it will do; waiting for the click.
        case intro
        case working
        /// macOS answered, but something is missing.
        case attention(LocalConnectorState)
        /// Connected, with its number of tools.
        case done(Int)
    }

    @State private var phase = Phase.intro
    @State private var orbIDs: Set<UUID>?
    @State private var didLoad = false

    private var installed: MCPServerConfig? { model.installedLocalConnector(kind) }

    var body: some View {
        content
            .orbSheet(installed == nil ? "Conectar \(kind.title)" : kind.title, subtitle: kind.summary, size: .medium) { footer }
            .onAppear(perform: load)
            .animation(reduceMotion ? nil : Motion.content, value: phase)
            .onChange(of: phase) { announce(phase) }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch phase {
        case .intro, .working:
            Form {
                Section {
                    ForEach(steps, id: \.self) { step in
                        Label(step, systemImage: "checkmark.circle").foregroundStyle(Palette.secondary)
                    }
                } header: {
                    Text("O que acontece")
                } footer: {
                    Text(privacyNote)
                }
                if phase == .intro || phase == .working {
                    Section {
                        OrbScopePicker(orbIDs: $orbIDs, allNote: "Cada Orb precisa estar com “Conectores” ligado no painel dele.")
                    } header: {
                        Text("Usar com")
                    }
                }
            }
            .formStyle(.grouped)
        case .attention(let state):
            attention(state)
        case .done(let count):
            result(symbol: "checkmark.circle.fill", tint: Palette.ok, title: "Conectado", detail: ConnectorStatusText.toolsAvailable(count))
        }
    }

    private var steps: [String] {
        switch kind {
        case .agenda: ["O macOS pede permissão para o Orb usar a Agenda.", "O Orb lista as agendas e procura a da sua conta Google.",
                       "Ele vê, cria, altera e apaga eventos. Apagar sempre pergunta antes."]
        case .lembretes: ["O macOS pede permissão para o Orb usar os Lembretes.", "O Orb vê as suas listas e os lembretes abertos.",
                          "Ele cria lembretes novos. Não apaga nem conclui nenhum."]
        case .gmail: ["O macOS pede permissão para o Orb controlar o Mail.", "O Orb procura a sua conta Google no Mail.",
                      "Ele busca e lê e-mails e cria rascunhos. Enviar sempre pergunta antes."]
        }
    }

    private var privacyNote: String {
        switch kind {
        case .agenda, .lembretes: "Tudo acontece neste Mac. O login do Google é o do macOS: o Orb nunca vê a sua senha."
        case .gmail: "Tudo acontece neste Mac, pelo app Mail. O login do Google é o do macOS: o Orb nunca vê a sua senha."
        }
    }

    /// Something is missing: what, and the button that fixes it.
    private func attention(_ state: LocalConnectorState) -> some View {
        VStack(spacing: 14) {
            Image(systemName: state == .noAccount ? "person.crop.circle.badge.plus" : "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Palette.warn)
            Text(state == .noAccount ? "Falta a sua conta Google no Mac" : state == .denied ? "O macOS está sem permissão" : "Não deu para conectar")
                .font(.system(size: 15, weight: .semibold))
            if state == .noAccount {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(accountSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Palette.onInk)
                                .frame(width: 18, height: 18)
                                .background(Palette.ink, in: .circle)
                            Text(step).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        }
                    }
                }
                .frame(maxWidth: 380, alignment: .leading)
                Button("Abrir Contas de Internet") { NSWorkspace.shared.open(LocalConnectorSetup.internetAccountsURL) }
                    .buttonStyle(SecondaryPillStyle())
                    .help("Abre as Contas de Internet nos Ajustes do Sistema, onde você entra com o Google")
            } else {
                Text(state == .denied ? deniedText : state.message)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                if state == .denied {
                    Button("Abrir Privacidade e Segurança") { NSWorkspace.shared.open(privacyURL) }
                        .buttonStyle(SecondaryPillStyle())
                        .help("Abre a tela dos Ajustes do Sistema onde você liga o Orb")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .contain)
    }

    private var accountSteps: [String] {
        let app = kind == .gmail ? "Mail" : "Calendários"
        return ["Abra Contas de Internet (o botão abaixo).", "Escolha Google e entre com a sua conta, como em qualquer app do Mac.",
                "Deixe \(app) marcado e feche. Depois volte aqui e clique em Verificar de novo."]
    }

    private var deniedText: String {
        "Você disse não ao pedido do macOS antes. Só dá para mudar em Ajustes do Sistema → Privacidade e Segurança → \(privacyPane). Ligue o Orb e volte aqui."
    }

    private var privacyPane: String {
        switch kind {
        case .agenda: "Calendários"
        case .lembretes: "Lembretes"
        case .gmail: "Automação"
        }
    }

    private var privacyURL: URL {
        let name = switch kind {
        case .agenda: "Privacy_Calendars"
        case .lembretes: "Privacy_Reminders"
        case .gmail: "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(name)") ?? MacPrivacyPane.automation.url
    }

    private func result(symbol: String?, tint: Color, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(tint)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 30)
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        switch phase {
        case .intro:
            SheetFooter(message: installed == nil ? nil : "Já conectado. Aqui você muda quais Orbs usam.", cancel: { dismiss() },
                        primaryTitle: installed == nil ? "Conectar" : "Verificar e salvar", isPrimaryDisabled: chosenNoOrb,
                        primaryHelp: "Pede a permissão ao macOS, se faltar, e liga o conector", primary: connect)
        case .working:
            SheetFooter(cancelTitle: "Fechar", cancel: { dismiss() }, primaryTitle: "Conectando…", isPrimaryDisabled: true, primary: {})
        case .attention(let state):
            SheetFooter(message: state == .noAccount && kind == .agenda ? "Sua conta tem outro nome? Dá para conectar assim mesmo." : nil,
                        destructiveTitle: state == .noAccount && kind == .agenda ? "Conectar assim mesmo" : nil,
                        destructive: { Task { @MainActor in await install(anyAccount: true) } }, cancel: { dismiss() },
                        primaryTitle: "Verificar de novo", destructiveHelp: "Conecta usando qualquer agenda do Mac, mesmo sem achar a sua conta Google",
                        primaryHelp: "Confere de novo a permissão e a conta", primary: connect)
        case .done:
            SheetFooter(cancel: { dismiss() }, primaryTitle: "Fechar", showsCancel: false, primary: { dismiss() })
        }
    }

    private var chosenNoOrb: Bool {
        guard let orbIDs else { return false }
        return !model.bots.contains { orbIDs.contains($0.id) }
    }

    private func announce(_ phase: Phase) {
        switch phase {
        case .done(let count): AccessibilityNotification.Announcement("Conectado. \(ConnectorStatusText.toolsAvailable(count))").post()
        case .attention(let state): AccessibilityNotification.Announcement("Falta algo. \(state.message)").post()
        case .intro, .working: break
        }
    }

    // MARK: Actions

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        orbIDs = installed?.orbIDs ?? (installed == nil ? model.defaultScopeForNewConnector() : nil)
        phase = initialPhase
    }

    private func connect() {
        phase = .working
        Task { @MainActor in
            let state = await model.localSetup.connect(kind, anyAccount: installed?.anyAccount ?? false)
            switch state {
            case .ready, .unchecked:
                await install()
            case .needsPermission, .denied, .noAccount, .unavailable:
                phase = .attention(state)
            }
        }
    }

    /// Installs the connector (or saves which Orbs use it), starts it once to list its tools and closes after a moment.
    private func install(anyAccount: Bool = false) async {
        phase = .working
        let config = model.installLocalConnector(kind, orbIDs: orbIDs, anyAccount: anyAccount)
        switch await model.connectAndWait(config.id) {
        case .ready(let count)?:
            phase = .done(count)
            await model.refreshLocalStates()
            try? await Task.sleep(for: .seconds(1.6))
            if phase == .done(count) { dismiss() }
        case .failed(let message)?:
            phase = .attention(.unavailable(ConnectorStatusText.shortError(message)))
        default:
            phase = .attention(.unavailable("O conector não respondeu."))
        }
    }
}
