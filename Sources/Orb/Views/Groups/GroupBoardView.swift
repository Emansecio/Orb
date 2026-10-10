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
                section("Objetivo") {
                    TextField("Para que o grupo existe", text: $objective, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .lineLimit(2...5)
                        .padding(10)
                        .background(Palette.surface, in: .rect(cornerRadius: 10))
                        .onSubmit { setObjective(objective) }
                        .accessibilityLabel("Objetivo do grupo")
                }
                section("Combinados") {
                    ForEach(agreements) { item in
                        MemoryRow(item: item, lineLimit: 3) { forgetItem(item) }
                    }
                    TextField("Novo combinado (↩ salva)", text: $agreement)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Palette.surface, in: .rect(cornerRadius: 8))
                        .onSubmit {
                            let text = agreement.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            remember(text)
                            agreement = ""
                        }
                }
                section("Lembranças") {
                    MemorySearchField(query: $query)
                    if memory.items.isEmpty {
                        Text("Ainda não há nada no quadro. Os membros guardam aqui o que vale para todos: decisões, links e combinados.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    } else if groups.isEmpty && agreements.isEmpty {
                        Text("Nada no quadro com “\(query)”.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    }
                    // The kinds of memory are told apart by the space between them, wider than the one inside a kind.
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 6) {
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
                .padding(.bottom, 12)
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
    }

    private func forgetItem(_ item: MemorySnapshot.Item) {
        forget(item)
        forgotten = item
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.faint)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Esquecido: <title>. Desfazer", for the ten seconds the board keeps a forgotten note.
private struct UndoForgetToast: View {
    let title: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Esquecido: \(title)")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
            Button("Desfazer", action: undo)
                .buttonStyle(GhostStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .card(radius: 12, fill: Palette.surface)
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }
}
