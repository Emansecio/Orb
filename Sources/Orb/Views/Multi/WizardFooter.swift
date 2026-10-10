import SwiftUI

/// The foot of the sheet in "Criar conversando": "Passar para o formulário" on the left (the draft goes to the form fields),
/// Cancelar (discards everything) and Criar Orb (enabled once the draft has a name) on the right.
struct WizardFooter: View {
    let canCreate: Bool
    let toForm: () -> Void
    let cancel: () -> Void
    let create: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toForm) {
                Text("Passar para o formulário")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.accentText)
            }
            .buttonStyle(.plain)
            .help("Leva o que já foi montado para o formulário, para você preencher o resto à mão")
            .accessibilityIdentifier("wizard-to-form")
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
                .help(canCreate ? "Cria o Orb que você viu" : "Converse até o Orb ter um nome")
                .accessibilityIdentifier("wizard-create")
        }
        .motion(Motion.content, value: canCreate)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}
