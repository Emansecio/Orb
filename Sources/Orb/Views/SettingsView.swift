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

    /// Each tab is as tall as it needs, not as the tallest.
    var height: CGFloat {
        switch self {
        case .general: 760
        case .models, .permissions: 640
        case .browser: 720
        case .usage: 700
        }
    }
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
    @AppStorage(AutoContinue.settingKey) private var continueLongTasks = true
    @AppStorage(SessionNote.settingKey) private var summarizeSessions = false
    @AppStorage(DictationReview.settingKey) private var reviewDictation = true
    @AppStorage(GlobalHotKey.defaultsKey) private var globalShortcut = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var notifications: NotificationPermission?
    @State private var keptCount = 0
    @State private var hasOrbsFolder = false
    @State private var isShowingReset = false
    @State private var orbsCanTalk = true
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
                        .foregroundStyle(Palette.warn)
                        .transition(.quiet)
                }
                Toggle("Me avisar quando um Orb terminar ou precisar de mim", isOn: $notifyWhenDone)
                    .help(Tip.notifyWhenDone)
                notificationState
                Toggle(isOn: $proposeSkills) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Propor skills com o que os Orbs aprendem")
                        Text("Depois de tarefas longas, o Orb revisa o que fez e pode propor uma skill. Costuma usar uma chamada extra ao modelo (até \(SkillReview.maxSteps) quando propõe algo), quase toda em cache. Nada é salvo sem você aprovar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(Tip.proposeSkills)
                Toggle(isOn: $continueLongTasks) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Continuar sozinho em tarefas longas")
                        Text("Quando o plano está avançando, o Orb segue sem pedir “continua”, até \(AutoContinue.maxStretches) trechos de \(AgentEngine.defaultMaxSteps) passos seguidos. Desligado, ele pausa no limite de passos e espera você.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(Tip.continueLongTasks)
                Toggle(isOn: $summarizeSessions) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resumir com o modelo as conversas longas que vão para a memória")
                        Text("Quando uma conversa de \(SessionNote.minimumRequests) pedidos ou mais é guardada, o modelo menor do mesmo provedor (quando há) escreve um resumo dela, que entra na página da sessão. Uma chamada curta por conversa. Desligado, a página tem só o que as regras tiram: pedidos, decisões, o que foi feito. Conversas com conectores, modelos locais e o Claude Code nunca são resumidos.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(Tip.summarizeSessions)
                if Dictation.isSupported {
                    Toggle(isOn: $reviewDictation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ajustar o ditado com o modelo do Orb")
                            Text("Ao parar de ditar, o texto vai ao modelo do Orb (um menor do mesmo provedor, quando há) com as últimas mensagens da conversa, para corrigir pontuação e palavras mal entendidas. Uma chamada curta por ditado; o áudio nunca sai do Mac. Esc durante o ajuste mantém o texto como foi ditado.")
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
                        Text("Os Orbs veem os colegas e pedem ajuda uns aos outros sozinhos, sem cartão por mensagem. Cada um segue as próprias permissões. Parar (⌘.) interrompe a conversa toda. Não afeta grupos.")
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
                // MARK: end MultiOrb (WP1)
            }
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
                        LabeledContent(item.title) {
                            Text(item.keys)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Palette.muted)
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
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Snapshots

/// `--snapshot settings-general | settings-profile | settings-reset | settings-models | settings-perms[-tested|-stale] | first-run-banner`: each tab of Ajustes on its own
/// (the tab bar does not render offscreen), at the size the window gives it.
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
