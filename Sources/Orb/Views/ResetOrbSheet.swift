import SwiftUI
import AppKit

/// "Redefinir o Orb?": the app back to its first use. Sister of "Apagar Atlas?": the same two lines (what goes, what
/// stays), then the choices as the settings show them (radio rows like "Contexto das conversas", a switch like the
/// ones in Ajustes), and the usual footer whose white button asks once more in a native alert. Opened from Ajustes → Geral → Seus dados.
struct ResetOrbSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The numbers to show instead of the app's own (review snapshots).
    var sample: ResetSummary?
    @State private var conversations: Int?
    @State private var memories = ResetOptions.Memories.keep
    @State private var leavesProviders = false
    @State private var isRunning = false
    @State private var problem: String?

    private var summary: ResetSummary { sample ?? model.resetSummary(conversations: conversations) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                SummaryLine(.goes, summary.goes)
                SummaryLine(.stays, summary.stays)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
            Form {
                Section {
                    RadioChoiceRow(title: "Guardar as memórias",
                                   summary: "O que cada Orb aprendeu vai para Memórias guardadas.",
                                   isSelected: memories == .keep) { memories = .keep }
                    RadioChoiceRow(title: "Apagar tudo, inclusive as memórias",
                                   summary: "Apaga também as memórias já guardadas. Não dá para desfazer.",
                                   isSelected: memories == .erase) { memories = .erase }
                }
                Section {
                    Toggle(isOn: $leavesProviders) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Também sair dos provedores")
                            Text("Apaga as chaves e os logins guardados no Orb. O login do Claude Code no Terminal não muda.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(isRunning)
        .orbSheet("Redefinir o Orb?", size: .medium) {
            // A destructive sheet: Return does nothing here, and nothing in the alert answers Return either.
            SheetFooter(message: isRunning ? "Redefinindo…" : problem, cancel: { if !isRunning { dismiss() } },
                        primaryTitle: "Redefinir…", isPrimaryDisabled: isRunning, primaryIsDefault: false, primary: ask)
        }
        .task {
            guard sample == nil else { return }
            let folder = model.store.directory
            conversations = await Task.detached(priority: .utility) { ResetSummary.conversationCount(in: folder) }.value
        }
    }

    /// Why the reset did not run.
    static func message(for refusal: ResetGuard.Refusal) -> String {
        switch refusal {
        case .developerRun: "Não dá para redefinir neste modo de desenvolvedor."
        case .unsafeFolder: "Esta pasta de dados não pode ser redefinida com segurança."
        case .notAppData: "Esta pasta de dados não parece ser do Orb, então nada foi apagado."
        }
    }

    private func ask() {
        let options = ResetOptions(memories: memories, leavesProviders: leavesProviders)
        Task {
            let relaunches = AppRelaunch.bundleURL() != nil
            guard await ResetConfirmation.ask(options, relaunches: relaunches, in: NSApp.keyWindow) else { return }
            problem = nil
            isRunning = true
            switch await model.resetEverything(options) {
            case .done:
                break // the app is quitting
            case .refused(let refusal):
                isRunning = false
                problem = ResetOrbSheet.message(for: refusal)
            case .alreadyRunning:
                break
            }
        }
    }
}

/// While the reset runs the window, the menu bar panel and Ajustes take no click and no key: a message or a new Orb
/// then would write where the reset is removing (the model refuses them too).
private struct ResetShield: ViewModifier {
    /// Passed in, not read from the environment: the modifier wraps the scene's root view from outside its
    /// `.environment(model)`, where the environment has no model yet.
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .disabled(model.isResetting)
            .overlay {
                if model.isResetting {
                    ZStack {
                        Rectangle().fill(.black.opacity(0.5)).contentShape(Rectangle())
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Redefinindo o Orb…")
                                .font(.callout)
                                .foregroundStyle(Palette.secondary)
                        }
                        .padding(20)
                        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Redefinindo o Orb")
                }
            }
    }
}

extension View {
    /// Blocks the view while "Redefinir o Orb" runs.
    func resetShield(_ model: AppModel) -> some View { modifier(ResetShield(model: model)) }
}

/// The alert that asks once more: "Redefinir o Orb agora?". Esc presses "Cancelar" and Return presses nothing: the
/// destructive button has no key at all, so nothing but a click on it redefines.
@MainActor
enum ResetConfirmation {
    static let title = "Redefinir o Orb agora?"
    static let confirmTitle = "Redefinir e reabrir"
    static let cancelTitle = "Cancelar"

    /// What the alert says, by what was chosen. Out of an installed app the Orb has nothing to reopen: it says it only closes.
    static func message(for options: ResetOptions, relaunches: Bool) -> String {
        var parts = [options.memories == .keep ? "As memórias vão para Memórias guardadas."
                     : "Tudo será apagado, inclusive as memórias. Não dá para desfazer."]
        if options.leavesProviders { parts.append("As chaves e os logins guardados no Orb também serão apagados.") }
        if !relaunches { parts.append("Este Orb não está num app instalado: ele só vai fechar, e você abre de novo.") }
        return parts.joined(separator: " ")
    }

    static func makeAlert(for options: ResetOptions, relaunches: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message(for: options, relaunches: relaunches)
        let cancel = alert.addButton(withTitle: cancelTitle)
        let confirm = alert.addButton(withTitle: confirmTitle)
        confirm.hasDestructiveAction = true
        // After the panel is laid out (reading `window` does it), or the layout gives Return to the first button and
        // leaves Esc to a button whose title AppKit happens to recognize as "Cancel". Taking Return from the first
        // button also takes its "default" look: no button of this alert is the default.
        _ = alert.window
        cancel.keyEquivalent = "\u{1b}"
        confirm.keyEquivalent = ""
        return alert
    }

    /// True when the person chose "Redefinir e reabrir". As a sheet of `window` when there is one.
    static func ask(_ options: ResetOptions, relaunches: Bool, in window: NSWindow?) async -> Bool {
        let alert = makeAlert(for: options, relaunches: relaunches)
        let response = if let window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
        return response == .alertSecondButtonReturn
    }
}
