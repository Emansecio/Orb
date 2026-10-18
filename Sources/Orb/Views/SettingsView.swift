import SwiftUI
import AppKit
import ServiceManagement

// Ajustes: five tabs (Geral, Modelos, Navegador, Uso, Permissões) that anything in the app can open directly.

enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, models, browser, usage, permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Geral"
        case .models: "Modelos"
        case .browser: "Navegador"
        case .usage: "Uso"
        case .permissions: "Permissões"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .models: "cpu"
        case .browser: "globe"
        case .usage: "chart.bar"
        case .permissions: "lock.shield"
        }
    }

    /// One height for every tab: a window that grew and shrank at each click jumped under the pointer (SwiftUI does not
    /// animate the Settings window's frame). A taller tab scrolls inside it, as its `Form` already does.
    var height: CGFloat { 720 }
}

/// Opens Ajustes on a given tab: from the first-use card, a failed tool, a provider error.
enum SettingsRouter {
    static let tabKey = "settingsTab"
    /// A tab asked for and not yet shown. Settings reads it and clears it.
    static let requestKey = "settingsTabRequest"

    static func request(_ tab: SettingsTab, defaults: UserDefaults = .standard) {
        defaults.set(tab.rawValue, forKey: requestKey)
    }

    @MainActor static func open(_ tab: SettingsTab, using openSettings: OpenSettingsAction) {
        request(tab)
        openSettings()
    }

    /// The tab Ajustes opens on: the one asked for; else Modelos while no model is connected (it is what the user
    /// came for); else the one used last.
    static func initialTab(request: String, stored: String, isProviderReady: Bool) -> SettingsTab {
        if let asked = SettingsTab(rawValue: request) { return asked }
        if !isProviderReady { return .models }
        return SettingsTab(rawValue: stored) ?? .general
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsRouter.tabKey) private var storedTab = ""
    @AppStorage(SettingsRouter.requestKey) private var request = ""
    @State private var tab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: SettingsRouter.tabKey) ?? "") ?? .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbol) }
                .tag(SettingsTab.general)
            ProviderSettings()
                .tabItem { Label(SettingsTab.models.title, systemImage: SettingsTab.models.symbol) }
                .tag(SettingsTab.models)
            BrowserSettings()
                .tabItem { Label(SettingsTab.browser.title, systemImage: SettingsTab.browser.symbol) }
                .tag(SettingsTab.browser)
            UsageSettings()
                .tabItem { Label(SettingsTab.usage.title, systemImage: SettingsTab.usage.symbol) }
                .tag(SettingsTab.usage)
            MacPermissionsView()
                .tabItem { Label(SettingsTab.permissions.title, systemImage: SettingsTab.permissions.symbol) }
                .tag(SettingsTab.permissions)
        }
        .frame(width: 640, height: tab.height)
        .onAppear {
            tab = SettingsRouter.initialTab(request: request, stored: storedTab, isProviderReady: model.isProviderReady || !model.hasCheckedConnections)
            request = ""
        }
        .onChange(of: request) {
            guard let asked = SettingsTab(rawValue: request) else { return }
            tab = asked
            request = ""
        }
        .onChange(of: tab) { storedTab = tab.rawValue }
    }
}

// MARK: - Geral

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var learnedWindows: [LearnedWindowRow] = []
    @AppStorage(AppModel.notifyWhenDoneKey) private var notifyWhenDone = true
    @AppStorage(SkillReview.settingKey) private var proposeSkills = true
    @AppStorage(SessionNote.settingKey) private var summarizeSessions = false
    @AppStorage(DictationReview.settingKey) private var reviewDictation = true
    @AppStorage(GlobalHotKey.defaultsKey) private var globalShortcut = false
    @State private var launchAtLogin = LoginItemState(SMAppService.mainApp.status).isOn
    @State private var loginError: String?
    /// What the Mac still waits for before the Orb opens at login (nil when nothing).
    @State private var loginApproval = LoginItemState(SMAppService.mainApp.status).approvalMessage
    @State private var notifications: NotificationPermission?
    @State private var keptCount = 0
    @State private var hasOrbsFolder = false
    @State private var isShowingReset = false
    @State private var orbsCanTalk = true
    @State private var orbsCanStartGroups = true
    @State private var openTalks: [DelegationHub.OpenTalk] = []
    /// The open talks a review snapshot shows in place of the hub's (`settings-orbs`).
    private let sampleTalks: [DelegationHub.OpenTalk]?

    init(sampleTalks: [DelegationHub.OpenTalk]? = nil) {
        self.sampleTalks = sampleTalks
    }
    @State private var isConfirmingOrbsOff = false

    /// Turning it off while Orbs talk asks first (it stops their conversations); turning it on never does.
    private func setOrbsCanTalk(_ on: Bool) {
        if !on, model.delegation.hasActiveChains { isConfirmingOrbsOff = true } else { applyOrbsCanTalk(on) }
    }

    private func applyOrbsCanTalk(_ on: Bool) {
        orbsCanTalk = on
        model.orbsCanTalk = on
    }

    var body: some View {
        Form {
            ProfileSettings()
            Section("Geral") {
                Toggle("Abrir ao iniciar sessão", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                    .help(Tip.launchAtLogin)
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.danger)
                        .transition(.quiet)
                }
                if let loginApproval {
                    LabeledContent {
                        Button("Abrir Ajustes do Sistema") { SMAppService.openSystemSettingsLoginItems() }
                            .help(Tip.openLoginItems)
                            .chipButton()
                    } label: {
                        Label(loginApproval, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Palette.warn)
                    }
                    .transition(.quiet)
                }
                Toggle("Me avisar quando um Orb terminar ou precisar de mim", isOn: $notifyWhenDone)
                    .help(Tip.notifyWhenDone)
                notificationState
                Toggle(isOn: $proposeSkills) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Propor skills com o que os Orbs aprendem")
                        Text("Depois de tarefas longas, o Orb pode propor uma skill. Nada é salvo sem você aprovar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(Tip.proposeSkills)
                Toggle(isOn: $summarizeSessions) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resumir com o modelo as conversas longas que vão para a memória")
                        Text("Um resumo curto, escrito pelo modelo, de cada conversa longa guardada. Conversas com conectores, modelos locais ou o Claude Code ficam de fora.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(Tip.summarizeSessions)
                if Dictation.isSupported {
                    Toggle(isOn: $reviewDictation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ajustar o ditado com o modelo do Orb")
                            Text("Ao parar de ditar, o modelo corrige pontuação e palavras mal entendidas. O áudio nunca sai do Mac.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help(Tip.reviewDictation)
                }
                // MARK: MultiOrb (WP1)
                Toggle(isOn: Binding(get: { orbsCanTalk }, set: { setOrbsCanTalk($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Orbs podem conversar entre si")
                        Text("Os Orbs pedem ajuda uns aos outros sem cartão por mensagem, cada um com as próprias permissões. Não afeta grupos.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(Tip.orbsCanTalk)
                .onAppear { orbsCanTalk = model.orbsCanTalk }
                .confirmationDialog("Desligar a conversa entre Orbs?", isPresented: $isConfirmingOrbsOff, titleVisibility: .visible) {
                    Button("Desligar e parar as conversas", role: .destructive) { applyOrbsCanTalk(false) }
                    Button("Cancelar", role: .cancel) {}
                } message: {
                    Text("Há Orbs conversando agora. Desligar interrompe essas conversas.")
                }
                Toggle(isOn: Binding(get: { orbsCanStartGroups }, set: { orbsCanStartGroups = $0; model.orbsCanStartGroups = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Orbs podem acionar grupos")
                        Text("Quando você pede no chat, o Orb cria um grupo ou manda um pedido a um grupo de que faz parte; a resposta final do grupo volta para o chat. Nunca por conta própria.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(Tip.orbsCanStartGroups)
                .onAppear { orbsCanStartGroups = model.orbsCanStartGroups }
                // The hub is not observed: the open requests are read again every two seconds while Ajustes is open.
                .task {
                    if let sampleTalks { openTalks = sampleTalks; return }
                    while !Task.isCancelled {
                        let now = model.delegation.openTalks()
                        if now != openTalks { openTalks = now }
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
                // MARK: end MultiOrb (WP1)
            }
            OpenTalksSection(talks: $openTalks)
            ContextMemorySettings()
            LearnedWindowsSettings(rows: $learnedWindows)
            Section {
                dataRow("Pasta de dados", "Conversas, memórias e ajustes", button: "Mostrar no Finder", isEnabled: true,
                        help: Tip.dataFolder) {
                    NSWorkspace.shared.activateFileViewerSelecting([Store.standard.directory])
                }
                dataRow("Memórias guardadas", GeneralSettings.keptMemoriesDetail(count: keptCount),
                        button: "Mostrar no Finder", isEnabled: keptCount > 0, help: Tip.keptMemoriesFolder) {
                    NSWorkspace.shared.activateFileViewerSelecting([GeneralSettings.keptMemoriesFolder])
                }
                dataRow("Pasta dos Orbs", OrbFolder.display(OrbFolder.defaultBase), button: "Mostrar no Finder",
                        isEnabled: hasOrbsFolder, help: Tip.orbsFolder) {
                    NSWorkspace.shared.activateFileViewerSelecting([OrbFolder.defaultBase])
                }
                dataRow("Redefinir o Orb", "Volta ao primeiro uso. Você escolhe se guarda as memórias.", button: "Redefinir…",
                        isEnabled: true, tint: Palette.danger, help: Tip.resetOrb) {
                    isShowingReset = true
                }
            } header: {
                Text("Seus dados")
            } footer: { FormFootnote {
                Text("Tudo fica neste Mac. As chaves ficam no Keychain.")
            } }
            Section("Atalhos") {
                Toggle(CommandName.globalShortcut, isOn: GlobalHotKey.toggleBinding($globalShortcut))
                .help(Tip.globalShortcut)
            }
            // The whole list, from the same catalog as the "Atalhos do teclado" sheet (Ajuda → Atalhos do teclado).
            ForEach(ShortcutCatalog.groups) { group in
                Section("Atalhos · \(group.title)") {
                    ForEach(group.items) { item in
                        let lines = ShortcutItem.lines(item.titleInGeneral ?? item.title)
                        LabeledContent {
                            Text(item.keys)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Palette.muted)
                        } label: {
                            Text(lines.main)
                            if let note = lines.note { Text(note).capabilityCaption() }
                        }
                    }
                }
            }
            Section("Sobre") {
                LabeledContent("Orb", value: GeneralSettings.versionText())
            }
        }
        .formStyle(.grouped)
        .orbFormBackground()
        .sheet(isPresented: $isShowingReset) { ResetOrbSheet() }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    @ViewBuilder private var notificationState: some View {
        switch notifications {
        case .denied?:
            LabeledContent {
                Button("Abrir Ajustes do Sistema") { NSWorkspace.shared.open(NotificationPermission.settingsURL) }
                    .help(Tip.openSystemNotifications)
                    .chipButton()
            } label: {
                Label("O macOS está bloqueando as notificações do Orb.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.warn)
            }
            .transition(.quiet)
        case .notDetermined? where notifyWhenDone:
            LabeledContent {
                Button("Pedir agora") { Task { notifications = await NotificationPermission.request() } }
                    .help(Tip.askNotifications)
                    .chipButton()
            } label: {
                Text("O macOS ainda não deixou o Orb avisar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .transition(.quiet)
        default:
            EmptyView()
        }
    }

    /// `tint`: a color for the button's text only (the one that redefines the app is the tone of danger).
    private func dataRow(_ title: String, _ detail: String, button: String, isEnabled: Bool, tint: Color? = nil,
                         help: String, action: @escaping () -> Void) -> some View {
        LabeledContent {
            Group {
                // The label is as wide as "Mostrar no Finder", so the buttons of the rows are one size, whatever they say.
                if let tint {
                    Button(action: action) { Text(button).frame(minWidth: Self.dataButtonLabelWidth).foregroundStyle(tint) }
                } else {
                    Button(action: action) { Text(button).frame(minWidth: Self.dataButtonLabelWidth) }
                }
            }
            .help(help)
            .disabled(!isEnabled)
            .chipButton()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func refresh() async {
        learnedWindows = model.learnedWindowRows()
        notifications = await NotificationPermission.current()
        readLoginItem() // the item may have been changed in the System Settings meanwhile
        // A look at the disk, once, off the render path.
        let memories = model.memory.root
        keptCount = await Task.detached(priority: .utility) { KeptMemories.count(in: memories) }.value
        hasOrbsFolder = FileManager.default.fileExists(atPath: OrbFolder.defaultBase.path)
    }

    /// The width of the text "Mostrar no Finder", the longest label of the rows' buttons.
    private static let dataButtonLabelWidth: CGFloat = 108

    /// What the "Memórias guardadas" row says: how many, and that a new Orb can start from one.
    static func keptMemoriesDetail(count: Int) -> String {
        switch count {
        case ...0: "Nenhuma ainda"
        case 1: "1 guardada · um Orb novo pode começar dela"
        default: "\(count) guardadas · um Orb novo pode começar de uma delas"
        }
    }

    /// Where a deleted Orb's memory goes when you keep it.
    static var keptMemoriesFolder: URL { Store.standard.directory.appending(path: "memoria/_guardadas") }

    /// "1.0.243 · 9ac1745" (the commit `scripts/bundle.sh` wrote down), "1.2.0 (7)" when there is no commit and the build
    /// is not already in the version, or "versão de desenvolvimento" when run outside the bundled app.
    static func versionText(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "versão de desenvolvimento" }
        if let commit = info?["OrbGitCommit"] as? String, !commit.isEmpty, commit != "unknown" { return "\(version) · \(commit)" }
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty, !version.hasSuffix(".\(build)") else { return version }
        return "\(version) (\(build))"
    }

    private func setLaunchAtLogin(_ isOn: Bool) {
        do {
            if isOn { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Não foi possível mudar: \(error.localizedDescription)"
        }
        let state = readLoginItem()
        // No error from the system, but the item is not on: the Mac says why (it is the System Settings' to approve).
        if loginError == nil, state.approvalMessage == nil, let message = state.message { loginError = message }
    }

    /// Reads the item's state into the switch (and the approval line).
    @discardableResult
    private func readLoginItem() -> LoginItemState {
        let state = LoginItemState(SMAppService.mainApp.status)
        launchAtLogin = state.isOn
        loginApproval = state.approvalMessage
        return state
    }
}

// MARK: - Login item

/// How the Mac's login item reads on the switch "Abrir ao iniciar sessão": on only when enabled; and what to tell when it is
/// not on and the person should know why (it waits for their approval in the System Settings, or the app was not found).
struct LoginItemState: Equatable {
    var isOn: Bool
    var message: String?
    /// The message is about an approval only the person can give (a button opens the System Settings).
    var needsApproval: Bool

    var approvalMessage: String? { needsApproval ? message : nil }

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: (isOn, message, needsApproval) = (true, nil, false)
        case .requiresApproval:
            (isOn, message, needsApproval) = (false, "O macOS espera a sua aprovação: ligue o Orb em Ajustes do Sistema > Itens de Início.", true)
        case .notFound:
            (isOn, message, needsApproval) = (false, "O macOS não encontrou o Orb para abrir ao iniciar sessão. Abra o app instalado em Aplicativos.", false)
        case .notRegistered: (isOn, message, needsApproval) = (false, nil, false)
        @unknown default: (isOn, message, needsApproval) = (false, nil, false)
        }
    }
}

// MARK: - Snapshots

#if DEBUG || ORB_DEV_TOOLS
/// `--snapshot settings-general | settings-profile | settings-orbs | settings-reset | settings-models | settings-perms[-tested|-stale] | settings-usage[...] | first-run-banner`:
/// each tab of Ajustes on its own (the tab bar does not render offscreen), at the size the window gives it. Two differ:
/// `settings-orbs` is all of Geral at 2000 pt, tall enough to reach the Orbs' switches and the open talks (with samples), and
/// `settings-usage[...]` is drawn by `UsageSnapshots` (it needs the model).
@MainActor
enum SettingsSnapshots {
    static func view(_ screen: String, firstBotID: UUID?) -> AnyView? {
        if screen == "first-run-banner", let id = firstBotID {
            return AnyView(VStack { Spacer(); FirstRunBanner(botID: id, alwaysShown: true) }
                .frame(width: 800, height: 300).background(Palette.canvas)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        }
        let tab: SettingsTab
        let content: AnyView
        switch screen {
        case "settings-general", "settings-profile": (tab, content) = (.general, AnyView(GeneralSettings()))
        case "settings-orbs":
            // All of Geral, tall enough to reach the Orbs' switches and the open talks below them.
            let talks = [
                DelegationHub.OpenTalk(id: UUID(), chainID: UUID(), title: "Atlas → Pesquisador",
                                       detail: "“Pesquise o preço do Mac mini M5 em três lojas” · esperando Revisor · há 4 min"),
                DelegationHub.OpenTalk(id: UUID(), chainID: UUID(), title: "Pesquisador → Revisor",
                                       detail: "“Confira se estes preços incluem impostos” · trabalhando · há 2 min"),
                DelegationHub.OpenTalk(id: UUID(), chainID: UUID(), title: "Lia (rotina) → Atlas",
                                       detail: "“Resuma os e-mails de ontem” · na fila · há menos de 1 min"),
            ]
            return AnyView(GeneralSettings(sampleTalks: talks)
                .frame(width: 640, height: 2000)
                .background(Palette.chrome)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        case "settings-reset":
            // The sheet on its own, as wide as a sheet is, with the numbers of the example in its description.
            return AnyView(ResetOrbSheet(sample: ResetSummary(orbs: 3, conversations: 42, routines: 5, connectors: 2, skills: 4,
                                                                folder: OrbFolder.display(OrbFolder.defaultBase)))
                .background(Palette.chrome)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        case "settings-models": (tab, content) = (.models, AnyView(ProviderSettings()))
        case "settings-perms": (tab, content) = (.permissions, AnyView(MacPermissionsView()))
        case "settings-perms-tested", "settings-perms-stale": (tab, content) = (.permissions, AnyView(MacPermissionsView(sample: permissionsSample(screen))))
        case let name where name.hasPrefix("settings-usage"): return nil // `UsageSnapshots` draws it (it needs the model)
        default: return nil
        }
        return AnyView(content
            .frame(width: 640, height: tab.height)
            .background(Palette.chrome)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    }

    /// Permissões with fixed rows, read from nothing: `settings-perms-tested` after both tests (Accessibility works, the
    /// capture came back empty), `settings-perms-stale` with Accessibility refused despite its flag and Screen Recording
    /// waiting for the Orb to reopen.
    private static func permissionsSample(_ screen: String) -> MacPermissionsModel {
        var statuses = Dictionary(uniqueKeysWithValues: MacPermissionChecker.allKinds.map { ($0, MacPermissionStatus.granted) })
        if screen == "settings-perms-tested" {
            return MacPermissionsModel(sample: statuses, notifications: .allowed,
                                       tests: [.accessibility: .working, .screenRecording: .broken])
        }
        statuses[.screenRecording] = .notGranted
        return MacPermissionsModel(sample: statuses, notifications: .allowed, tests: [.accessibility: .broken],
                                   awaitsRelaunch: [.screenRecording])
    }
}
#endif

/// One short sentence under a setting, with the rest behind "Saiba mais": for notes whose extra detail matters to
/// few people, so the page is not a wall of gray text.
struct LearnMoreNote: View {
    let short: String
    let more: String
    @State private var isOpen = false

    var body: some View {
        // The sentence and the link read as one run of text, the link wrapping with it when the window is narrow.
        (Text(short + " ") + Text("Saiba mais").foregroundColor(.accentColor))
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(.rect)
            .onTapGesture { isOpen = true }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Mostra mais detalhes")
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                Text(more)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 300, alignment: .leading)
                    .padding(12)
            }
    }
}
