import SwiftUI

/// The foot of the sheet in "Criar conversando": why "Criar Orb" is still off on the left (the mode picker above carries the
/// draft to the form), Cancelar (discards everything) and Criar Orb (enabled once the draft has a name) on the right.
struct WizardFooter: View {
    let canCreate: Bool
    /// The assistant said the draft is complete: "Criar Orb" is the next step and shows it (a halo, and ⌘↩ as well as ↩).
    var isReady = false
    let cancel: () -> Void
    let create: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if !canCreate {
                Text("O assistente ainda não escolheu um nome.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Spacer(minLength: 12)
            Button("Cancelar", action: cancel)
                .buttonStyle(GhostStyle())
                .keyboardShortcut(.cancelAction)
                .help("Fecha sem criar nada")
            Button("Criar Orb", action: create)
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                .shadow(color: Palette.stageGlow.opacity(isReady && canCreate ? 0.4 : 0), radius: 7, y: 1)
                .animation(Motion.fade, value: isReady)
                .background {
                    Button("", action: create).keyboardShortcut(.return, modifiers: .command).opacity(0).accessibilityHidden(true)
                        .disabled(!canCreate)
                }
                .help(canCreate ? "Cria o Orb que você viu (↩ ou ⌘↩)" : "Converse até o Orb ter um nome")
                .accessibilityIdentifier("wizard-create")
        }
        .motion(Motion.content, value: canCreate)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}
