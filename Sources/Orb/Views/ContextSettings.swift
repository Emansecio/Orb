import SwiftUI
import AppKit

// Ajustes → Orbs: how much conversation the Orbs remember word for word, and the windows Orb learned from refusals.

/// "Contexto das conversas": the three levels with a line each, as a group of radio rows.
struct ContextMemorySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            ForEach(ContextMemoryLevel.allCases, id: \.self) { level in
                RadioChoiceRow(title: level.label, summary: level.summary, isSelected: model.contextMemory == level) {
                    model.contextMemory = level
                }
            }
        } header: {
            Text("Contexto das conversas")
        } footer: { FormFootnote {
            Text("Vale para todos os Orbs. Passando do limite, o começo da conversa vira um resumo; as mensagens continuam salvas.")
        } }
    }
}

/// One option of a group of radio rows: a title and a gray line under it. "Contexto das conversas" and
/// "Redefinir o Orb" use it, so the two look and read alike.
struct RadioChoiceRow: View {
    let title: String
    let summary: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Palette.accentText : Palette.muted)
                    .accessibilityHidden(true)
                toggleLabel(title, summary)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(summary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// "Janelas aprendidas": models whose window a refusal once showed to be smaller than assumed, each with "Esquecer".
/// Nothing at all while there are none. The rows are the caller's (`OrbsSettings` reads them with its other
/// look at the world when it appears and when the app comes back): a view with nothing in it never appears itself.
struct LearnedWindowsSettings: View {
    @Environment(AppModel.self) private var model
    @Binding var rows: [LearnedWindowRow]

    var body: some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    LabeledContent {
                        Button("Esquecer") { forget(row) }
                            .help(Tip.forgetWindow)
                            .chipButton()
                            .accessibilityLabel("Esquecer a janela de \(row.name)")
                    } label: {
                        toggleLabel(row.name, "Janela de \(row.words) · \(row.age())")
                    }
                }
            } header: {
                Text("Janelas aprendidas")
            } footer: { FormFootnote {
                Text("O provedor recusou uma conversa grande demais e o Orb respeita esse limite. Esqueça um se aumentou o limite no servidor.")
            } }
        }
    }

    private func forget(_ row: LearnedWindowRow) {
        model.forgetLearnedContext(of: row.id)
        rows = model.learnedWindowRows()
        model.announceForAccessibility("Janela de \(row.name) esquecida.")
    }
}
