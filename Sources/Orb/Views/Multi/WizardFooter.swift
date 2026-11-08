import SwiftUI

/// The foot of the sheet in "Criar conversando": why "Criar Orb" is still off on the left (the mode picker above carries the
/// draft to the form), Cancelar (discards everything) and Criar Orb (enabled once the draft has a name) on the right.
struct WizardFooter: View {
    let canCreate: Bool
    /// The draft's name is another Orb's: the way out is another name, asked of the assistant.
    var nameTaken = false
    /// The assistant stopped at its limit without a name: the way out is the form, so the foot offers it.
    var hitLimit = false
    /// "Ir para o Formulário": the same step as the mode picker (the draft fills the form).
    var toForm: () -> Void = {}
    let cancel: () -> Void
    let create: () -> Void

    var body: some View {
        SheetFooterBar {
            if !canCreate {
                Text(nameTaken ? "Já existe um Orb com esse nome. Peça outro ao assistente."
                     : hitLimit ? "A conversa chegou ao limite sem um nome." : "O assistente ainda não escolheu um nome.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .transition(.opacity)
                if hitLimit {
                    Button("Ir para o Formulário", action: toForm)
                        .buttonStyle(.plain)
                        .font(Typography.label)
                        .foregroundStyle(Palette.accentText)
                        .help("Leva o que o assistente já entendeu para o formulário, onde você dá o nome")
                        .accessibilityIdentifier("wizard-to-form")
                }
            }
            Spacer(minLength: Spacing.m)
            Button("Cancelar", action: cancel)
                .buttonStyle(GhostStyle())
                .keyboardShortcut(.cancelAction)
                .help("Fecha sem criar nada")
            Button("Criar Orb", action: create)
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                .background {
                    Button("", action: create).keyboardShortcut(.return, modifiers: .command).opacity(0).accessibilityHidden(true)
                        .disabled(!canCreate)
                }
                .help(canCreate ? "Cria o Orb que você viu (↩ ou ⌘↩)" : nameTaken ? "Peça outro nome ao assistente" : "Converse até o Orb ter um nome")
                .accessibilityIdentifier("wizard-create")
        }
        .motion(Motion.content, value: canCreate)
    }
}
