import AppKit
import SwiftUI

// The "Permissões do Mac" settings tab: what macOS lets the Orb do, row by row, with a way to ask and a way to change it.

@MainActor @Observable
final class MacPermissionsModel {
    private(set) var statuses: [MacPermissionKind: MacPermissionStatus] = [:]
    private(set) var asking: Set<MacPermissionKind> = []
    /// Rows whose "Pedir agora" was pressed and changed nothing: macOS shows the Screen Recording prompt only once,
    /// so from then on only System Settings can grant it.
    private(set) var askedInVain: Set<MacPermissionKind> = []
    private let checker: MacPermissionChecker

    init(checker: MacPermissionChecker = .live) { self.checker = checker }

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

struct MacPermissionsView: View {
    @State private var model = MacPermissionsModel()

    var body: some View {
        Form {
            Section {
                ForEach(AutomationTarget.known) { target in
                    MacPermissionRow(kind: .automation(target), model: model)
                }
            } header: {
                Text("Automação")
            } footer: {
                Text("Cada app pede a própria permissão, na primeira vez que o Orb o controla. Apps fechados só podem ser verificados depois de abertos.")
            }
            Section {
                MacPermissionRow(kind: .accessibility, model: model)
                MacPermissionRow(kind: .screenRecording, model: model)
            } header: {
                Text("Interface e tela")
            } footer: {
                Text("A Gravação de Tela só vale depois que o Orb é reaberto. O macOS pergunta uma vez só: se já negou, use Abrir Ajustes.")
            }
            Section {
                MacPermissionRow(kind: .fullDiskAccess, model: model)
            } header: {
                Text("Arquivos")
            } footer: {
                Text("O macOS não informa se o Acesso Total ao Disco está ligado: o Orb tenta abrir uma pasta protegida (Mail ou Safari) e deduz.")
            }
            Section {
                Text("As permissões valem para esta cópia do Orb. Se o app é recompilado com a assinatura temporária, o macOS "
                     + "trata a nova cópia como outro app e pede tudo de novo. Para manter, assine com o certificado local "
                     + "\"Orb Local\" (scripts/make-signing-identity.sh, descrito no README).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }
}

private struct MacPermissionRow: View {
    let kind: MacPermissionKind
    let model: MacPermissionsModel

    var body: some View {
        let status = model.status(of: kind)
        LabeledContent {
            HStack(spacing: 8) {
                StatusBadge(status: status, isAsking: model.asking.contains(kind))
                if model.canAsk(kind) {
                    Button("Pedir agora") { Task { await model.ask(kind) } }
                        .controlSize(.small)
                        .disabled(model.asking.contains(kind))
                }
                Button("Abrir Ajustes") { kind.pane.open() }
                    .controlSize(.small)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(model.askedInVain.contains(kind) ? "O macOS não pergunta de novo: ligue o Orb em Abrir Ajustes." : kind.detail)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct StatusBadge: View {
    let status: MacPermissionStatus?
    let isAsking: Bool

    var body: some View {
        if isAsking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Aguardando você").font(.caption).foregroundStyle(.secondary)
            }
        } else if let status {
            Label(status.label, systemImage: status.symbol)
                .font(.caption)
                .foregroundStyle(status.tint)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// A tiny "Abrir Ajustes" button for a failed tool row whose output names a missing permission.
struct OpenPrivacySettingsButton: View {
    let problem: MacPermissionProblem

    var body: some View {
        Button {
            problem.pane.open()
        } label: {
            Label("Abrir Ajustes: \(problem.paneTitle)", systemImage: "lock.shield")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.accentText)
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
