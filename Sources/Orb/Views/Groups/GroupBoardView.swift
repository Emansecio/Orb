import SwiftUI

/// The group's board: the objective and the agreements the person writes, then what the members saved, by kind, with the
/// same search and rows as an Orb's memory (`MemoryGroups`, `MemoryRow`). "Esquecer" offers "Desfazer" for ten seconds.
struct GroupBoardView: View {
    let memory: MemorySnapshot
    let setObjective: (String) -> Void
    let remember: (String) -> Void
    let forget: (MemorySnapshot.Item) -> Void
    let restore: (MemorySnapshot.Item) -> Void

    @State private var objective: String
    @State private var agreement = ""
    @State private var query = ""
    @State private var forgotten: MemorySnapshot.Item?
    @State private var folded = FoldedTextCache()
    @FocusState private var isObjectiveFocused: Bool
    /// What this field last saved: the save re-reads the board, which rebuilds the view (`.id`), and leaving then must
    /// not write the same text again against the board it was drawn from.
    @State private var savedObjective: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(memory: MemorySnapshot, setObjective: @escaping (String) -> Void, remember: @escaping (String) -> Void,
         forget: @escaping (MemorySnapshot.Item) -> Void, restore: @escaping (MemorySnapshot.Item) -> Void) {
        self.memory = memory
        self.setObjective = setObjective
        self.remember = remember
        self.forget = forget
        self.restore = restore
        _objective = State(initialValue: memory.identity)
    }

    /// The window of the undo: ten seconds, as the Orb's memory gives.
    static let undoSeconds = 10

    var body: some View {
        let agreements = MemoryGroups.make(memory.items, matching: query, kind: .preferencia, cache: folded).flatMap(\.items)
        let groups = MemoryGroups.make(memory.items.filter { $0.kind != .preferencia }, matching: query, cache: folded)
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                TitledSection("Objetivo", isHeader: true) {
                    TextField("Para que o grupo existe", text: $objective, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Typography.text)
                        .lineLimit(2...5)
                        .sheetTextField()
                        .focused($isObjectiveFocused)
                        .onSubmit { commitObjective() }
                        .accessibilityLabel("Objetivo do grupo")
                }
                TitledSection("Combinados", isHeader: true) {
                    ForEach(agreements) { item in
                        MemoryRow(item: item, lineLimit: 3) { forgetItem(item) }
                    }
                    TextField("Novo combinado (↩ salva)", text: $agreement)
                        .textFieldStyle(.plain)
                        .font(Typography.text)
                        .sheetTextField(radius: Radius.small)
                        .onSubmit {
                            let text = agreement.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            remember(text)
                            agreement = ""
                        }
                }
                TitledSection("Lembranças", isHeader: true) {
                    MemorySearchField(query: $query)
                    if memory.items.isEmpty {
                        Text("Ainda não há nada no quadro. Os membros guardam aqui o que vale para todos: decisões, links e combinados.")
                            .font(Typography.label)
                            .foregroundStyle(Palette.muted)
                    } else if groups.isEmpty && agreements.isEmpty {
                        Text("Nada no quadro com “\(query)”.")
                            .font(Typography.label)
                            .foregroundStyle(Palette.muted)
                    }
                    // The kinds of memory are told apart by the space between them, wider than the one inside a kind.
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: Spacing.s) {
                                Text("\(group.title) · \(group.items.count)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Palette.faint)
                                ForEach(group.items) { item in
                                    MemoryRow(item: item, lineLimit: 3) { forgetItem(item) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(Spacing.l)
        }
        .overlay(alignment: .bottom) {
            if let forgotten {
                UndoForgetToast(title: forgotten.title) {
                    restore(forgotten)
                    self.forgotten = nil
                }
                .padding(.bottom, Spacing.m)
                .transition(.adapted(.rise, reduceMotion: reduceMotion))
                // Ten seconds to take it back; a new "Esquecer" restarts the count (the id changes with the item).
                .task(id: forgotten.id) {
                    try? await Task.sleep(for: .seconds(Self.undoSeconds))
                    guard !Task.isCancelled else { return }
                    self.forgotten = nil
                }
            }
        }
        .animation(Motion.content, value: forgotten?.id)
        .onChange(of: memory.identity) { objective = memory.identity }
        // Leaving the field (another tab, the panel closed, another group) keeps what was typed, as the group's name does.
        .onChange(of: isObjectiveFocused) { old, new in if old && !new { commitObjective() } }
        .onDisappear { commitObjective() }
    }

    private func commitObjective() {
        guard let text = GroupObjectiveEdit.commit(draft: objective, current: savedObjective ?? memory.identity) else { return }
        savedObjective = text
        setObjective(text)
    }

    private func forgetItem(_ item: MemorySnapshot.Item) {
        forget(item)
        forgotten = item
    }
}

/// "Esquecido: <title>. Desfazer", for the ten seconds the board keeps a forgotten note.
private struct UndoForgetToast: View {
    let title: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            Text("Esquecido: \(title)")
                .font(Typography.label)
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
            Button("Desfazer", action: undo)
                .buttonStyle(GhostStyle())
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .card(radius: Radius.card, fill: Palette.surface)
        .shadow(color: Shadow.popover, radius: 10, y: 3)
    }
}

/// What leaving the objective's field saves: the text without its outer blanks, or nil when it did not change. An empty
/// objective is saved too: clearing the field is how it is removed.
enum GroupObjectiveEdit {
    static func commit(draft: String, current: String) -> String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == current.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : text
    }
}
