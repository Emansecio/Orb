import SwiftUI

// The Orb's memory on screen: a tab of the panel (identity, a short list per kind) and a sheet with all of it.
// Both read the Orb's own `BotLive.memory`, group and search with `MemoryGroups`, and forget with a way back
// (`MemoryUndo`): "Esquecer" removes the page at once and offers "Desfazer" for a few seconds.

/// The panel's Memória tab, as sections of the panel's form.
struct MemoryTab: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let name: String
    let editIdentity: () -> Void
    /// Opens the sheet with everything, on one kind when given.
    let showAll: (MemoryKind?) -> Void
    @State private var query = ""
    @State private var isShowingHelp = false
    @State private var folded = FoldedTextCache()

    /// Rows per group in the panel; the sheet shows the rest.
    private static let rowsPerGroup = 4

    var body: some View {
        let memory = model.live(botID).memory
        let groups = MemoryGroups.make(memory.items, matching: query, cache: folded)
        // A short memory fits the panel whole; only a long one is cut to a few rows per group.
        let truncates = query.isEmpty && memory.items.count > MemoryGroups.searchableAbove

        Section {
            IdentityBlock(memory: memory, name: name, edit: editIdentity,
                          restartInterview: { model.restartInterview(of: botID) })
        } header: {
            Text("Como \(name) funciona")
        }

        Section {
            if memory.items.isEmpty {
                Text("Ainda não guardou nada. A memória cresce a cada conversa: preferências, fatos, procedimentos e um resumo de cada uma.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if memory.items.count > MemoryGroups.searchableAbove {
                MemorySearchField(query: $query)
            }
            if !memory.items.isEmpty && groups.isEmpty {
                Text("Nada na memória com “\(query)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Memória")
        } footer: {
            if !memory.items.isEmpty { Text(MemoryGroups.summary(memory.items)) }
        }

        ForEach(groups) { group in
            let shown = truncates ? Array(group.items.prefix(Self.rowsPerGroup)) : group.items
            Section {
                ForEach(shown) { item in
                    MemoryRow(item: item) { model.memoryUndo.forget(item, of: botID, in: model) }
                }
                if shown.count < group.items.count {
                    Button("Ver todos (\(group.items.count))…") { showAll(group.kind) }
                        .buttonStyle(.link)
                        .help(Tip.memoryShowKind)
                }
            } header: {
                Text("\(group.title) · \(group.items.count)")
            }
        }

        Section {
            Button("Ver tudo…", systemImage: "list.bullet.rectangle") { showAll(nil) }
                .help(Tip.memoryShowAll)
                .disabled(memory.items.isEmpty)
            Button("Abrir pasta da memória", systemImage: "folder") {
                NSWorkspace.shared.open(model.memory.directory(for: botID))
            }
            .help(Tip.memoryFolder)
        } footer: {
            HStack(spacing: 4) {
                Text("Só \(name) vê isso. São arquivos .md na sua pasta de dados.")
                Button("Como funciona") { isShowingHelp = true }
                    .buttonStyle(.link)
                    .help(Tip.memoryHow)
                    .popover(isPresented: $isShowingHelp, arrowEdge: .top) { MemoryHelp(name: name) }
            }
        }
    }
}

/// The identity notes: what the Orb was told about how to work, and whether it will interview you.
private struct IdentityBlock: View {
    let memory: MemorySnapshot
    let name: String
    let edit: () -> Void
    let restartInterview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(memory.identity.isEmpty ? "Ainda sem notas sobre como \(name) deve funcionar."
                 : memory.identity.replacingOccurrences(of: "## ", with: ""))
                .font(.callout)
                .foregroundStyle(memory.identity.isEmpty ? .secondary : Palette.secondary)
                .lineLimit(5)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if memory.identity.count > MemoryBank.identityShare {
                Text("Longa: em cada conversa vão o começo e o fim (cerca de \(MemoryBank.identityShare) caracteres).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if memory.interviewPending {
                Label("Vai fazer perguntas a você nas primeiras mensagens", systemImage: "questionmark.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Editar…", action: edit)
                    .help(Tip.editIdentity)
                Spacer()
                if !memory.interviewPending {
                    Menu {
                        Button("Fazer a entrevista de novo", systemImage: "questionmark.bubble", action: restartInterview)
                            .help(Tip.restartInterview(name))
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(Tip.moreOptions(of: name))
                    .accessibilityLabel("Mais opções de \(name)")
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

private struct MemorySearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Buscar na memória", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button("Limpar busca", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(Tip.clearSearch)
            }
        }
    }
}

/// The long explanation that used to sit under the list.
private struct MemoryHelp: View {
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Como a memória funciona")
                .font(.headline)
            Text("\(name) guarda preferências, fatos e procedimentos que aprende com você, e um resumo de cada conversa (salvo depois de 30 minutos sem mensagens ou ao começar outra).")
            Text("Conversas antigas são compactadas, nunca apagadas sem você. Tudo fica em arquivos .md: dá para abrir no Obsidian e editar à mão.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 300)
    }
}

/// One remembered thing: its text, when it came, and a "Esquecer" that shows on hover (and to VoiceOver and the menu).
struct MemoryRow: View {
    let item: MemorySnapshot.Item
    var lineLimit = 3
    let forget: () -> Void
    @State private var isHovering = false
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.text(of: item))
                    .lineLimit(isExpanded ? nil : (item.kind == .sessao ? 1 : lineLimit))
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.caption(of: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Esquecer", systemImage: "trash", action: forget)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(isHovering ? 1 : 0.45)
                .help(Tip.forget)
                .accessibilityLabel("Esquecer: \(item.title)")
        }
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
        .help(isExpanded ? Tip.collapseMemory : Tip.expandMemory)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Esquecer", systemImage: "trash", action: forget)
        }
        .accessibilityElement(children: .contain)
    }

    static func text(of item: MemorySnapshot.Item) -> String {
        item.kind == .sessao || item.title == item.body ? item.title : item.body
    }

    static func caption(of item: MemorySnapshot.Item) -> String {
        item.kind == .sessao
            ? MemoryBank.dayFormat.string(from: item.date) + (item.compacted ? " · compactada" : "")
            : RelativeTime.text(item.date)
    }
}

/// Everything the Orb remembers, with search: for long memories the panel's four rows per group are not enough.
struct MemorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let botID: UUID
    let name: String
    @State private var query = ""
    @State private var kind: MemoryKind?
    @State private var folded = FoldedTextCache()

    /// `kind` opens the sheet on that kind alone (from a group's "Ver todos").
    init(botID: UUID, name: String, kind: MemoryKind? = nil) {
        self.botID = botID
        self.name = name
        _kind = State(initialValue: kind)
    }

    var body: some View {
        let memory = model.live(botID).memory
        let groups = MemoryGroups.make(memory.items, matching: query, kind: kind, cache: folded)

        Form {
            Section {
                MemorySearchField(query: $query)
                Picker("Mostrar", selection: $kind) {
                    Text("Tudo").tag(MemoryKind?.none)
                    ForEach(MemoryGroups.kinds, id: \.self) { Text(MemoryGroup(kind: $0, items: []).title).tag(MemoryKind?.some($0)) }
                }
            }
            if groups.isEmpty {
                Text(memory.items.isEmpty ? "Ainda não guardou nada."
                     : query.isEmpty ? "Nada neste tipo de memória." : "Nada na memória com “\(query)”.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        MemoryRow(item: item, lineLimit: 4) { model.memoryUndo.forget(item, of: botID, in: model) }
                    }
                } header: {
                    Text("\(group.title) · \(group.items.count)")
                }
            }
        }
        .formStyle(.grouped)
        .orbSheet("Memória de \(name)", subtitle: MemoryGroups.summary(memory.items), size: .large) {
            HStack(spacing: 8) {
                Button("Abrir pasta da memória", systemImage: "folder") {
                    NSWorkspace.shared.open(model.memory.directory(for: botID))
                }
                .buttonStyle(GhostStyle())
                .help(Tip.memoryFolder)
                Text("Arquivos .md: dá para abrir no Obsidian.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Button("Fechar") { dismiss() }
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Divider().opacity(0.6) }
        }
        .overlay(alignment: .bottom) { MemoryUndoToast(undo: model.memoryUndo).padding(.bottom, 64) }
    }
}

/// "Atlas esqueceu isso. Desfazer", for a few seconds after "Esquecer". ⌘Z does the same, and the countdown waits
/// while the pointer or the keyboard focus is on it.
struct MemoryUndoToast: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    let undo: MemoryUndo

    var body: some View {
        ZStack {
            if let entry = undo.entry {
                HStack(spacing: 10) {
                    Text("\(model.liveBot(entry.botID)?.look.name ?? "O Orb") esqueceu isso.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                    Button("Desfazer") { undo.undo(in: model) }
                        .buttonStyle(.link)
                        .font(.system(size: 12, weight: .semibold))
                        .focused($isFocused)
                        .help("Desfazer (\(AppShortcut.undoForget.label))")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Palette.raised, in: .capsule)
                .overlay(Capsule().stroke(Palette.lineStrong))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                .background { undoShortcut }
                .onHover { undo.hold(.hover, $0) }
                .onChange(of: isFocused) { _, focused in undo.hold(.focus, focused) }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Memória esquecida. Desfazer disponível por alguns segundos.")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: undo.entry)
    }

    /// ⌘Z while the toast is up. Typing in a text field keeps its own undo: that one wins when it has something to undo.
    private var undoShortcut: some View {
        Button("Desfazer") {
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canUndo == true {
                text.undoManager?.undo()
            } else {
                undo.undo(in: model)
            }
        }
        .keyboardShortcut(AppShortcut.undoForget)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
