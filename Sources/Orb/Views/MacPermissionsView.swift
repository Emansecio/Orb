import AppKit
import SwiftUI
import UserNotifications

// The "Acesso ao Mac" settings tab: what macOS lets the Orb do, row by row, with a way to ask and a way to change it.

@MainActor @Observable
final class MacPermissionsModel {
    private(set) var statuses: [MacPermissionKind: MacPermissionStatus] = [:]
    private(set) var asking: Set<MacPermissionKind> = []
    /// Screen Recording once macOS can no longer grant it by itself: "Pedir agora" changed nothing (the prompt shows only
    /// once), or the user went to System Settings to turn it on. Either way the switch takes effect only in a reopened Orb.
    private(set) var awaitsRelaunch: Set<MacPermissionKind> = []
    /// What the live test of a granted row found, until its status changes.
    private(set) var tests: [MacPermissionKind: PermissionTestOutcome] = [:]
    private(set) var testing: Set<MacPermissionKind> = []
    /// Whether the Orb may post banners (nil until read).
    private(set) var notifications: NotificationPermission?
    private let checker: MacPermissionChecker
    private let tester: MacPermissionTester
    private let readNotifications: @MainActor () async -> NotificationPermission

    /// The rows read again while the tab is open: each a quick yes/no. Automation (one question per app) waits for the
    /// app to come back to the front.
    static let watched: [MacPermissionKind] = [.accessibility, .screenRecording, .fullDiskAccess]

    init(checker: MacPermissionChecker = .live, tester: MacPermissionTester = .live,
         notifications: @escaping @MainActor () async -> NotificationPermission = { await NotificationPermission.current() }) {
        self.checker = checker
        self.tester = tester
        readNotifications = notifications
    }

    /// Fixed rows for `--snapshot`: nothing is read, asked or tested.
    convenience init(sample statuses: [MacPermissionKind: MacPermissionStatus], notifications: NotificationPermission,
                     tests: [MacPermissionKind: PermissionTestOutcome] = [:], awaitsRelaunch: Set<MacPermissionKind> = []) {
        self.init()
        self.statuses = statuses
        self.notifications = notifications
        self.tests = tests
        self.awaitsRelaunch = awaitsRelaunch
    }

    /// What the tab's header says, from what has been read so far.
    var summary: MacPermissionsSummary { MacPermissionsSummary.make(statuses: statuses, notifications: notifications) }

    func status(of kind: MacPermissionKind) -> MacPermissionStatus? { statuses[kind] }

    /// Whether the row offers "Pedir agora".
    func canAsk(_ kind: MacPermissionKind) -> Bool {
        guard let status = statuses[kind] else { return false }
        return status.canShowSystemPrompt && kind.canBeAskedNow && !awaitsRelaunch.contains(kind)
    }

    func row(_ kind: MacPermissionKind) -> PermissionRowState {
        PermissionRowState.make(kind: kind, status: statuses[kind], isAsking: asking.contains(kind), canAsk: canAsk(kind),
                                awaitsRelaunch: awaitsRelaunch.contains(kind), test: tests[kind], isTesting: testing.contains(kind))
    }

    /// Reads the statuses again without prompting. Safe to call whenever the tab appears or the app comes back to the front.
    func refresh(_ kinds: [MacPermissionKind] = MacPermissionChecker.allKinds) async {
        let fresh = await checker.statuses(of: kinds)
        // A request in flight owns its row; its own refresh follows. Assign only what changed, so the observers stay quiet.
        var merged = statuses
        merged.merge(fresh.filter { !asking.contains($0.key) }) { _, new in new }
        if merged != statuses { statuses = merged }
        let relaunch = awaitsRelaunch.filter { statuses[$0] != .granted }
        if relaunch != awaitsRelaunch { awaitsRelaunch = relaunch }
        let kept = tests.filter { statuses[$0.key] == .granted }
        if kept != tests { tests = kept }
        // Read on the watch too: the notifications row also changes in System Settings, which does not bring the Orb back.
        let current = await readNotifications()
        if current != notifications { notifications = current }
    }

    /// Reads the `watched` rows every `interval` until the task is cancelled (the tab went away). System Settings does
    /// not bring the Orb back to the front, so this is how a switch turned there shows up here.
    func watch(every interval: Duration = .seconds(2)) async {
        while (try? await Task.sleep(for: interval)) != nil {
            await refresh(Self.watched)
        }
    }

    /// Uses a granted permission for real (a tiny capture, a read of the Dock) and keeps what it found.
    func test(_ kind: MacPermissionKind) async {
        guard !testing.contains(kind) else { return }
        testing.insert(kind)
        let outcome = await tester.run(kind)
        testing.remove(kind)
        tests[kind] = outcome
    }

    /// Opens the row's pane. For Screen Recording the row then offers to reopen the Orb, the only way the switch applies.
    func openSettings(_ kind: MacPermissionKind, open: (MacPrivacyPane) -> Void = { $0.open() }) {
        open(kind.pane)
        if kind == .screenRecording { awaitsRelaunch.insert(kind) }
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
        if kind == .screenRecording, answer != .granted { awaitsRelaunch.insert(kind) }
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

/// A button a row offers.
enum PermissionRowAction: Equatable {
    case ask
    case openAppAndAsk(appName: String)
    case openSystemSettings
    /// Uses a granted permission for real, read-only (`MacPermissionTester`).
    case test
    /// Quits and opens the Orb again (`AppRelaunch`): macOS applies Screen Recording only to a reopened app.
    case relaunch

    /// The button of a row that is not granted; nil while the status is unknown or when nothing is left to do.
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
        case .test: "Testar"
        case .relaunch: "Reabrir o Orb"
        }
    }
}

/// What a row shows next to its buttons.
enum PermissionBadge: Equatable {
    case loading
    case asking
    case testing
    case status(MacPermissionStatus)
    /// The live test used the permission and it worked.
    case working
    /// Granted on paper, but the live test came back empty or refused.
    case broken
}

/// A permission row from everything the tab knows about it: the flag, the live test, whether only a reopened Orb can
/// apply it.
struct PermissionRowState: Equatable {
    var badge: PermissionBadge
    var actions: [PermissionRowAction]
    /// Replaces the row's description when there is something to say.
    var note: String?

    static let screenRecordingBroken = "A captura voltou vazia: o macOS só aplica a permissão depois de reabrir o Orb."
    static let accessibilityBroken = "O macOS diz que está liberado, mas o Orb não consegue ler os apps: remova o Orb da lista "
        + "de Acessibilidade e adicione de novo."
    static let inconclusive = "Não deu para testar agora. Tente de novo em instantes."
    static let awaitingRelaunch = "Ligue o Orb em Ajustes do Sistema e reabra o Orb: o macOS só aplica a gravação de tela num app reaberto."
    static let appClosed = "Precisa estar aberto para verificar. O botão abre o app e pede a permissão."

    static func make(kind: MacPermissionKind, status: MacPermissionStatus?, isAsking: Bool, canAsk: Bool,
                     awaitsRelaunch: Bool, test: PermissionTestOutcome?, isTesting: Bool) -> PermissionRowState {
        let fallback = PermissionRowAction.resolve(kind: kind, status: status, canAsk: canAsk).map { [$0] } ?? []
        guard let status else { return PermissionRowState(badge: .loading, actions: []) }
        if isAsking { return PermissionRowState(badge: .asking, actions: fallback) }
        if status == .granted, kind.canBeTested {
            if isTesting { return PermissionRowState(badge: .testing, actions: [.test]) }
            switch test {
            case .working?:
                return PermissionRowState(badge: .working, actions: [.test])
            case .broken?:
                return kind == .screenRecording
                    ? PermissionRowState(badge: .broken, actions: [.relaunch], note: screenRecordingBroken)
                    : PermissionRowState(badge: .broken, actions: [.openSystemSettings], note: accessibilityBroken)
            case .inconclusive?:
                return PermissionRowState(badge: .status(.granted), actions: [.test], note: inconclusive)
            case nil:
                return PermissionRowState(badge: .status(.granted), actions: [.test])
            }
        }
        if awaitsRelaunch { return PermissionRowState(badge: .status(status), actions: [.openSystemSettings, .relaunch], note: awaitingRelaunch) }
        if status == .appNotRunning, case .automation = kind { return PermissionRowState(badge: .status(status), actions: fallback, note: appClosed) }
        return PermissionRowState(badge: .status(status), actions: fallback)
    }
}

// MARK: - The tab

struct MacPermissionsView: View {
    @State private var model: MacPermissionsModel
    @State private var showsAutomation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// False for a `--snapshot` sample, whose rows are fixed.
    private let readsTheSystem: Bool

    init() {
        _model = State(initialValue: MacPermissionsModel())
        readsTheSystem = true
    }

    init(sample: MacPermissionsModel) {
        _model = State(initialValue: sample)
        readsTheSystem = false
    }

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
                LearnMoreNote(short: "A gravação de tela só vale depois de reabrir o Orb.",
                              more: "O macOS pergunta uma vez só. Testar usa a permissão de verdade, só olhando, sem salvar nada.")
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
                            .font(Typography.small)
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
                        .capabilityCaption()
                }
            }
        }
        .formStyle(.grouped)
        .orbFormBackground()
        .task {
            guard readsTheSystem else { return }
            await model.refresh()
            await model.watch()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard readsTheSystem else { return }
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
                Text(summary.title).font(Typography.text.weight(.semibold))
                Text(summary.subtitle).capabilityCaption()
            }
            Spacer()
            Button("Verificar de novo", action: recheck)
                .chipButton()
                .help(Tip.recheckPermissions)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct MacPermissionRow: View {
    let kind: MacPermissionKind
    let model: MacPermissionsModel
    @Environment(AppModel.self) private var app
    @State private var confirmsRelaunch = false

    var body: some View {
        let row = model.row(kind)
        let isBusy = row.badge == .asking || row.badge == .testing
        LabeledContent {
            HStack(spacing: 8) {
                StatusBadge(badge: row.badge)
                ForEach(row.actions, id: \.title) { action in
                    Button(action.title) { perform(action) }
                        .chipButton()
                        .help(Tip.permissionAction(action))
                        .disabled(isBusy)
                }
                if row.actions.isEmpty { ActionSlot() }
            }
            .confirmationDialog("Reabrir o Orb agora?", isPresented: $confirmsRelaunch) {
                Button("Reabrir", role: .destructive) { AppRelaunch.finish() }
            } message: {
                Text("Há Orbs trabalhando: o que estão fazendo é interrompido.")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .foregroundStyle(model.status(of: kind) == .appNotRunning ? Palette.muted : Palette.ink)
                Text(row.note ?? kind.detail).capabilityCaption()
            }
        }
    }

    private func perform(_ action: PermissionRowAction) {
        switch action {
        case .ask: Task { await model.ask(kind) }
        case .openAppAndAsk: Task { await model.openAppAndAsk(kind) }
        case .openSystemSettings: model.openSettings(kind)
        case .test: Task { await model.test(kind) }
        case .relaunch:
            // Quitting stops every turn and command in progress: asked first when there is one.
            let busy = app.bots.contains { app.isWorking($0.id) || app.live($0.id).jobs.contains(where: \.isRunning) }
            if busy { confirmsRelaunch = true } else { AppRelaunch.finish() }
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
                StatusBadge(badge: state.map { .status($0.status) } ?? .loading)
                switch state {
                case .notDetermined?:
                    Button("Pedir agora") { Task { await model.askNotifications() } }
                        .chipButton()
                        .help(Tip.askNotifications)
                case .denied?:
                    Button("Abrir Ajustes do Sistema") { NSWorkspace.shared.open(NotificationPermission.settingsURL) }
                        .chipButton()
                        .help(Tip.openSystemNotifications)
                default:
                    ActionSlot()
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Notificações")
                // `capabilityCaption` wraps at the column's width: at 460 pt the long line was cut short.
                Text(state == .unavailable ? "Só funcionam no app instalado, não ao rodar pelo Xcode ou terminal."
                     : "Avisar quando um Orb terminar ou precisar de você")
                    .capabilityCaption()
            }
        }
    }
}

/// The room of a row's one-word button ("Testar") when it has none, so the status of every granted row ends at the same
/// x and the right edge of the column is one line (the badge sits left of the button).
private struct ActionSlot: View {
    var body: some View {
        Button("Testar") {}
            .chipButton()
            .hidden()
            .accessibilityHidden(true)
    }
}

private struct StatusBadge: View {
    let badge: PermissionBadge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What comes after the spinner (granted, a warning): the same mark as everywhere (`mark`), growing from 0.6 in `Motion.enter`.
    private var mark: AnyTransition { .adapted(AnyTransition.mark.animation(Motion.enter), reduceMotion: reduceMotion) }

    var body: some View {
        // Spinner → mark swap in place, one over the other, so the row does not shift while they trade.
        ZStack(alignment: .trailing) {
            switch badge {
            case .loading:
                ProgressView().controlSize(.small)
                    .transition(.opacity)
            case .asking, .testing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(badge == .asking ? "Aguardando você" : "Testando…").font(Typography.small).foregroundStyle(Palette.muted)
                }
                .transition(.opacity)
            case .status(let status):
                Label(status.label, systemImage: status.symbol)
                    .font(Typography.small)
                    .foregroundStyle(status.tint)
                    .transition(mark)
            case .working:
                Label("Funcionando", systemImage: "checkmark.circle.fill")
                    .font(Typography.small)
                    .foregroundStyle(Palette.ok)
                    .transition(mark)
            case .broken:
                Label("Não funciona", systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.small)
                    .foregroundStyle(Palette.danger)
                    .transition(mark)
            }
        }
        .motion(Motion.content, value: badge)
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
                .font(Typography.small)
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
        case .notDetermined, .appNotRunning, .unknown: Palette.muted
        }
    }
}

extension MacPermissionKind {
    /// Whether "Pedir agora" can do anything: Full Disk Access has no system prompt, only System Settings.
    var canBeAskedNow: Bool {
        if case .fullDiskAccess = self { return false }
        return true
    }

    /// Whether a granted row offers "Testar": the two permissions whose flag can say yes while they do nothing.
    var canBeTested: Bool { self == .accessibility || self == .screenRecording }
}
