import SwiftUI
import AppKit

// Ajustes → Geral: how much conversation the Orbs remember word for word, and the windows Orb learned from refusals.

/// "Memória das conversas": the three levels with a line each, as a group of radio rows.
struct ContextMemorySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            ForEach(ContextMemoryLevel.allCases, id: \.self) { level in
                ContextMemoryRow(level: level, isSelected: model.contextMemory == level) { model.contextMemory = level }
            }
        } header: {
            Text("Memória das conversas")
        } footer: {
            Text("Vale para todos os Orbs. Quando passa do limite, o começo da conversa vira um resumo; as mensagens continuam salvas em Conversas.")
        }
    }
}

private struct ContextMemoryRow: View {
    let level: ContextMemoryLevel
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Palette.accentText : Palette.muted)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(level.label)
                    Text(level.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level.label)
        .accessibilityValue(level.summary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// "Janelas aprendidas": models whose window a refusal once showed to be smaller than assumed, each with "Esquecer".
/// Nothing at all while there are none. The rows are the caller's (`GeneralSettings` reads them with its other
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
                            .accessibilityLabel("Esquecer a janela de \(row.name)")
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                            Text("Janela de \(row.words) · \(row.age())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Janelas aprendidas")
            } footer: {
                Text("O provedor recusou uma conversa grande demais e o Orb passou a respeitar esse limite. Esqueça um se você aumentou o limite do servidor.")
            }
        }
    }

    private func forget(_ row: LearnedWindowRow) {
        model.forgetLearnedContext(of: row.id)
        rows = model.learnedWindowRows()
        model.announceForAccessibility("Janela de \(row.name) esquecida.")
    }
}
