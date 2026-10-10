import AppKit
import SwiftUI
import UserNotifications

// The "Permissões" settings tab: what macOS lets the Orb do, row by row, with a way to ask and a way to change it.

@MainActor @Observable
final class MacPermissionsModel {
    private(set) var statuses: [MacPermissionKind: MacPermissionStatus] = [:]
    private(set) var asking: Set<MacPermissionKind> = []
    /// Rows whose "Pedir agora" was pressed and changed nothing: macOS shows the Screen Recording prompt only once,
    /// so from then on only System Settings can grant it.
    private(set) var askedInVain: Set<MacPermissionKind> = []
    /// Whether the Orb may post banners (nil until read).
    private(set) var notifications: NotificationPermission?
    private let checker: MacPermissionChecker
    private let readNotifications: @MainActor () async -> NotificationPermission

    init(checker: MacPermissionChecker = .live,
         notifications: @escaping @MainActor () async -> NotificationPermission = { await NotificationPermission.current() }) {
        self.checker = checker
        readNotifications = notifications
    }

    /// What the tab's header says, from what has been read so far.
    var summary: MacPermissionsSummary { MacPermissionsSummary.make(statuses: statuses, notifications: notifications) }

    func status(of kind: MacPermissionKind) -> MacPermissionStatus? { statuses[kind] }

    /// Whether the row offers "Pedir agora".
    func canAsk(_ kind: MacPermissionKind) -> Bool {
        guard let status = statuses[kind] else { return false }
        return status.canShowSystemPrompt && kind.canBeAskedNow && !askedInVain.contains(kind)
    }

    /// Reads every status again without prompting. Safe to call whenever the tab appears or the app comes back to the front.
    func refresh() async {
        let fresh = await checker.statuses()
        // A request in flight owns its row; its own refresh follows.
        statuses = fresh.merging(statuses.filter { asking.contains($0.key) }) { _, current in current }
        askedInVain = askedInVain.filter { statuses[$0] != .granted }
        notifications = await readNotifications()
    }

    /// Asks macOS to allow banners (its dialog shows once; after a refusal only System Settings changes it).
    func askNotifications() async {
        notifications = await NotificationPermission.request()
    }

    /// Opens the app (an Automation row cannot be checked while its app is closed), waits for it to answer, then asks.
    func openAppAndAsk(_ kind: MacPermissionKind) async {
        guard case .automation(let target) = kind,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) else {
            kind.pane.open()
            return
        }
        asking.insert(kind)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<10 {
            if await checker.status(ofInBackground: kind) != .appNotRunning { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        asking.remove(kind)
        await ask(kind)
    }

    /// Shows the system dialog (where macOS has one) and waits for the answer.
    func ask(_ kind: MacPermissionKind) async {
        guard !asking.contains(kind) else { return }
        asking.insert(kind)
        let answer = await checker.requestInBackground(kind)
        asking.remove(kind)
        statuses[kind] = answer
        if kind == .screenRecording, answer != .granted { askedInVain.insert(kind) }
        await refresh()
    }
}


// MARK: - What the tab says

/// How macOS lets the Orb post banners.
enum NotificationPermission: Equatable, Sendable {
    /// Not a bundled app (`swift run`): there is no notification center to ask.
    case unavailable
    case notDetermined
    case denied
    case allowed

    @MainActor static func current() async -> NotificationPermission {
        guard ApprovalNotifications.isAvailable else { return .unavailable }
        return map(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    /// Shows the system dialog if macOS never asked, then reports the answer.
    @MainActor static func request() async -> NotificationPermission {
        guard ApprovalNotifications.isAvailable else { return .unavailable }
        let center = UNUserNotificationCenter.current()
        ApprovalNotifications.prepare(center)
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await current()
    }

    static func map(_ status: UNAuthorizationStatus) -> NotificationPermission {
        switch status {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        ?? URL(filePath: "/System/Applications/System Settings.app")

    var status: MacPermissionStatus {
        switch self {
        case .allowed: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        case .unavailable: .unknown
        }
    }
}

/// The header of the tab: everything ready, or what is missing.
struct MacPermissionsSummary: Equatable {
    var isLoaded: Bool
    /// Names of the essential permissions that are not granted.
    var missing: [String]
    var automationGranted: Int
    var automationTotal: Int

    static func make(statuses: [MacPermissionKind: MacPermissionStatus], notifications: NotificationPermission?) -> MacPermissionsSummary {
        let essentials: [MacPermissionKind] = [.accessibility, .screenRecording, .fullDiskAccess]
        let notGranted: Set<MacPermissionStatus> = [.denied, .notGranted, .notDetermined]
        var missing = essentials.filter { statuses[$0].map(notGranted.contains) ?? false }.map(\.title)
        if let notifications, notGranted.contains(notifications.status) { missing.append("Notificações") }
        let automation = AutomationTarget.known.map { statuses[.automation($0)] }
        return MacPermissionsSummary(isLoaded: !statuses.isEmpty && notifications != nil, missing: missing,
                                     automationGranted: automation.filter { $0 == .granted }.count,
                                     automationTotal: automation.count)
    }

    var title: String {
        if !isLoaded { return "Verificando…" }
        switch missing.count {
        case 0: return "Tudo pronto"
        case 1: return "Falta 1 permissão"
        default: return "Faltam \(missing.count) permissões"
        }
    }

    var subtitle: String {
        if !isLoaded { return "Lendo o que o macOS já liberou." }
        return missing.isEmpty ? "As permissões essenciais estão liberadas." : missing.joined(separator: ", ") + "."
    }

    var isComplete: Bool { isLoaded && missing.isEmpty }
    var automationText: String { "\(automationGranted) de \(automationTotal) liberados" }
}

/// The one button a row offers.
enum PermissionRowAction: Equatable {
    case ask
    case openAppAndAsk(appName: String)
    case openSystemSettings

    /// Nil while the status is unknown or when nothing is left to do.
    static func resolve(kind: MacPermissionKind, status: MacPermissionStatus?, canAsk: Bool) -> PermissionRowAction? {
        guard let status, status != .granted else { return nil }
        if case .automation(let target) = kind, status == .appNotRunning { return .openAppAndAsk(appName: target.name) }
        return canAsk ? .ask : .openSystemSettings
    }

    var title: String {
        switch self {
        case .ask: "Pedir agora"
        case .openAppAndAsk(let name): "Abrir \(name) e pedir"
        case .openSystemSettings: "Abrir Ajustes do Sistema"
        }
    }
}

// MARK: - The tab

struct MacPermissionsView: View {
    @State private var model = MacPermissionsModel()
    @State private var showsAutomation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let summary = model.summary
        Form {
            Section {
                MacPermissionsHeader(summary: summary) { Task { await model.refresh() } }
            }
            Section {
                MacPermissionRow(kind: .accessibility, model: model)
                MacPermissionRow(kind: .screenRecording, model: model)
                MacPermissionRow(kind: .fullDiskAccess, model: model)
                NotificationRow(model: model)
            } header: {
                Text("Essenciais")
            } footer: { FormFootnote {
                Text("A gravação de tela só vale depois de reabrir o Orb, e o macOS pergunta uma vez só.")
            } }
            Section {
                DisclosureGroup(isExpanded: $showsAutomation) {
                    ForEach(AutomationTarget.known) { target in
                        MacPermissionRow(kind: .automation(target), model: model)
                    }
                } label: {
                    HStack {
                        Text("Apps que o Orb controla")
                        Spacer()
                        Text(summary.isLoaded ? summary.automationText : "")
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                    }
                    .contentShape(.rect)
                    .onTapGesture { withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) { showsAutomation.toggle() } }
                }
            } footer: { FormFootnote {
                Text("Cada app pede a própria permissão, na primeira vez que o Orb o controla.")
            } }
            Section {
                DisclosureGroup("Avançado (desenvolvedores)") {
                    Text("As permissões valem para esta cópia do Orb. Se o app é recompilado com a assinatura temporária, o macOS "
                         + "trata a nova cópia como outro app e pede tudo de novo. Para manter, assine com o certificado local "
                         + "\"Orb Local\" (scripts/make-signing-identity.sh, descrito no README).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .orbFormBackground()
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }
}

private struct MacPermissionsHeader: View {
    let summary: MacPermissionsSummary
    let recheck: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: summary.isComplete ? "checkmark.shield.fill" : "lock.shield")
                .font(.system(size: 24))
                .foregroundStyle(summary.isComplete ? Palette.ok : (summary.isLoaded ? Palette.warn : Palette.muted))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).font(.system(size: 14, weight: .semibold))
                Text(summary.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Verificar de novo", action: recheck)
                .controlSize(.small)
                .help(Tip.recheckPermissions)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct MacPermissionRow: View {
    let kind: MacPermissionKind
    let model: MacPermissionsModel

    var body: some View {
        let status = model.status(of: kind)
        let isAsking = model.asking.contains(kind)
        let action = PermissionRowAction.resolve(kind: kind, status: status, canAsk: model.canAsk(kind))
        LabeledContent {
            HStack(spacing: 8) {
                StatusBadge(status: status, isAsking: isAsking)
                if let action {
                    Button(action.title) { perform(action) }
                        .controlSize(.small)
                        .help(Tip.permissionAction(action))
                        .disabled(isAsking)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .foregroundStyle(status == .appNotRunning ? Palette.muted : Palette.ink)
                Text(detail(status))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ status: MacPermissionStatus?) -> String {
        if model.askedInVain.contains(kind) { return "O macOS não pergunta de novo: ligue o Orb em Ajustes do Sistema." }
        if status == .appNotRunning, case .automation = kind { return "Precisa estar aberto para verificar. O botão abre o app e pede a permissão." }
        return kind.detail
    }

    private func perform(_ action: PermissionRowAction) {
        switch action {
        case .ask: Task { await model.ask(kind) }
        case .openAppAndAsk: Task { await model.openAppAndAsk(kind) }
        case .openSystemSettings: kind.pane.open()
        }
    }
}

/// Notifications are not a privacy pane of their own kind: the row reads and asks through the notification center.
private struct NotificationRow: View {
    let model: MacPermissionsModel

    var body: some View {
        let state = model.notifications
        LabeledContent {
            HStack(spacing: 8) {
                StatusBadge(status: state?.status, isAsking: false)
                switch state {
                case .notDetermined?:
                    Button("Pedir agora") { Task { await model.askNotifications() } }.controlSize(.small)
                        .help(Tip.askNotifications)
                case .denied?:
                    Button("Abrir Ajustes do Sistema") { NSWorkspace.shared.open(NotificationPermission.settingsURL) }
                        .controlSize(.small)
                        .help(Tip.openSystemNotifications)
                default:
                    EmptyView()
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Notificações")
                Text(state == .unavailable ? "Só funcionam no app instalado, não ao rodar pelo Xcode ou terminal."
                     : "Avisar quando um Orb terminar ou precisar de você")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct StatusBadge: View {
    let status: MacPermissionStatus?
    let isAsking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What comes after the spinner (granted, a warning): the same mark as everywhere (`mark`), growing from 0.6 in `Motion.enter`.
    private var mark: AnyTransition { .adapted(AnyTransition.mark.animation(Motion.enter), reduceMotion: reduceMotion) }

    var body: some View {
        // Spinner → mark swap in place, one over the other, so the row does not shift while they trade.
        ZStack(alignment: .trailing) {
            if isAsking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Aguardando você").font(.caption).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else if let status {
                Label(status.label, systemImage: status.symbol)
                    .font(.caption)
                    .foregroundStyle(status.tint)
                    .transition(mark)
            } else {
                ProgressView().controlSize(.small)
                    .transition(.opacity)
            }
        }
        .motion(Motion.content, value: BadgeKey(status: status, isAsking: isAsking))
    }

    private struct BadgeKey: Equatable {
        var status: MacPermissionStatus?
        var isAsking: Bool
    }
}

/// "Permitir…" on a failed tool row whose output names a missing permission: asks macOS where it can show its
/// dialog, and otherwise opens the pane of System Settings where the user turns it on.
struct OpenPrivacySettingsButton: View {
    let problem: MacPermissionProblem
    @State private var isWorking = false

    var body: some View {
        Button {
            Task { await allow() }
        } label: {
            Label("Permitir…", systemImage: "lock.shield")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.accentText)
        .disabled(isWorking)
        .help("Pede a permissão ao macOS ou abre Ajustes do Sistema, em \(problem.settingsPath)")
        .accessibilityLabel("Permitir: \(problem.paneTitle)")
    }

    private func allow() async {
        isWorking = true
        defer { isWorking = false }
        let checker = MacPermissionChecker.live
        if let kind = await problem.permissionKind(checker), kind.canBeAskedNow,
           await checker.status(ofInBackground: kind).canShowSystemPrompt {
            _ = await checker.requestInBackground(kind)
            return // macOS showed its own dialog, which offers System Settings when it needs it
        }
        problem.pane.open()
    }
}

extension MacPermissionProblem {
    /// The row of the settings tab this failure belongs to, when it can be told.
    func permissionKind(_ checker: MacPermissionChecker) async -> MacPermissionKind? {
        switch self {
        case .accessibility: return .accessibility
        case .screenRecording: return .screenRecording
        case .fullDiskAccess: return .fullDiskAccess
        case .automation(let app):
            guard let app else { return nil }
            return await Blocking.run(fallback: nil) { checker.target(forScriptName: app).map(MacPermissionKind.automation) }
        }
    }
}

// MARK: Presentation

extension MacPermissionStatus {
    var label: String {
        switch self {
        case .granted: "Liberado"
        case .denied: "Negado"
        case .notDetermined: "Não pedido"
        case .notGranted: "Não liberado"
        case .appNotRunning: "Abra o app para verificar"
        case .unknown: "Não deu para verificar"
        }
    }

    var symbol: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .denied, .notGranted: "xmark.circle.fill"
        case .notDetermined: "circle.dashed"
        case .appNotRunning: "moon.zzz"
        case .unknown: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .granted: Palette.ok
        case .denied, .notGranted: Palette.danger
        case .notDetermined, .appNotRunning, .unknown: .secondary
        }
    }
}

extension MacPermissionKind {
    /// Whether "Pedir agora" can do anything: Full Disk Access has no system prompt, only System Settings.
    var canBeAskedNow: Bool {
        if case .fullDiskAccess = self { return false }
        return true
    }
}
