import SwiftUI
import AppKit
import ServiceManagement

// Ajustes: three tabs (Geral, Modelos, Permissões do Mac) that anything in the app can open directly.

enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, models, permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Geral"
        case .models: "Modelos"
        case .permissions: "Permissões do Mac"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .models: "cpu"
        case .permissions: "lock.shield"
        }
    }

    /// Each tab is as tall as it needs, not as the tallest.
    var height: CGFloat {
        switch self {
        case .general: 760
        case .models, .permissions: 640
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
            MacPermissionsView()
                .tabItem { Label(SettingsTab.permissions.title, systemImage: SettingsTab.permissions.symbol) }
                .tag(SettingsTab.permissions)
        }
        .frame(width: 640, height: tab.height)
        .onAppear {
            tab = SettingsRouter.initialTab(request: request, stored: storedTab, isProviderReady: model.isProviderReady)
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

/// One line of the shortcuts list.
struct SettingsShortcut: Identifiable {
    var keys: String
    var action: String
    var id: String { keys }

    static let all = [
        SettingsShortcut(keys: "⌘N", action: "Novo Orb"),
        SettingsShortcut(keys: "⇧⌘N", action: "Nova conversa"),
        SettingsShortcut(keys: "⌥⌘B", action: "Mostrar ou ocultar o painel do Orb"),
        SettingsShortcut(keys: "⌥↑  ⌥↓", action: "Ir para o Orb anterior ou o próximo"),
        SettingsShortcut(keys: "⌘1 – ⌘9", action: "Ir direto para um Orb"),
    ]
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var learnedWindows: [LearnedWindowRow] = []
    @AppStorage("notifyWhenDone") private var notifyWhenDone = true
    @AppStorage(GlobalHotKey.defaultsKey) private var globalShortcut = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var notifications: NotificationPermission?
    @State private var hasKeptMemories = false
    @State private var hasOrbsFolder = false

    var body: some View {
        Form {
            Section("Geral") {
                Toggle("Abrir ao iniciar sessão", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.warn)
                }
                Toggle("Me avisar quando um Orb terminar ou precisar de mim", isOn: $notifyWhenDone)
                notificationState
            }
            ContextMemorySettings()
            LearnedWindowsSettings(rows: $learnedWindows)
            Section {
                dataRow("Pasta de dados", "Conversas, memórias e ajustes", button: "Mostrar no Finder", isEnabled: true) {
                    NSWorkspace.shared.activateFileViewerSelecting([Store.standard.directory])
                }
                dataRow("Memórias guardadas", hasKeptMemories ? "De Orbs que você apagou" : "Nenhuma ainda",
                        button: "Mostrar no Finder", isEnabled: hasKeptMemories) {
                    NSWorkspace.shared.activateFileViewerSelecting([GeneralSettings.keptMemoriesFolder])
                }
                dataRow("Pasta dos Orbs", OrbFolder.display(OrbFolder.defaultBase), button: "Mostrar no Finder",
                        isEnabled: hasOrbsFolder) {
                    NSWorkspace.shared.activateFileViewerSelecting([OrbFolder.defaultBase])
                }
            } header: {
                Text("Seus dados")
            } footer: {
                Text("Tudo fica neste Mac. As chaves ficam no Keychain.")
            }
            Section("Atalhos") {
                Toggle(CommandName.globalShortcut, isOn: Binding(
                    get: { globalShortcut },
                    set: { wanted in
                        // Another app may already hold the keys: then the switch stays off and the user is told.
                        let works = GlobalHotKey.shared.apply(wanted)
                        globalShortcut = wanted && works
                        if wanted && !works { GlobalHotKey.showUnavailableAlert() }
                    }
                ))
                ForEach(SettingsShortcut.all) { shortcut in
                    LabeledContent(shortcut.action) {
                        Text(shortcut.keys)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                    }
                }
            }
            Section("Sobre") {
                LabeledContent("Orb", value: GeneralSettings.versionText())
            }
        }
        .formStyle(.grouped)
        .orbFormBackground()
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
            } label: {
                Label("O macOS está bloqueando os avisos do Orb.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.warn)
            }
        case .notDetermined? where notifyWhenDone:
            LabeledContent {
                Button("Pedir agora") { Task { notifications = await NotificationPermission.request() } }
            } label: {
                Text("O macOS ainda não deixou o Orb avisar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    private func dataRow(_ title: String, _ detail: String, button: String, isEnabled: Bool,
                         action: @escaping () -> Void) -> some View {
        LabeledContent {
            Button(button, action: action).disabled(!isEnabled)
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
        hasKeptMemories = FileManager.default.fileExists(atPath: GeneralSettings.keptMemoriesFolder.path)
        hasOrbsFolder = FileManager.default.fileExists(atPath: OrbFolder.defaultBase.path)
    }

    /// Where a deleted Orb's memory goes when you keep it.
    static var keptMemoriesFolder: URL { Store.standard.directory.appending(path: "memoria/_guardadas") }

    /// "1.0.0 (1)", or "versão de desenvolvimento" when run outside the bundled app.
    static func versionText(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "versão de desenvolvimento" }
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return version }
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

/// `--snapshot settings-general | settings-models | settings-perms | first-run-banner`: each tab of Ajustes on its own
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
        case "settings-general": (tab, content) = (.general, AnyView(GeneralSettings()))
        case "settings-models": (tab, content) = (.models, AnyView(ProviderSettings()))
        case "settings-perms": (tab, content) = (.permissions, AnyView(MacPermissionsView()))
        default: return nil
        }
        return AnyView(content
            .frame(width: 640, height: tab.height)
            .background(Palette.chrome)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    }
}
