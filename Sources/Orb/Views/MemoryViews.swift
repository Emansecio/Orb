import SwiftUI

// The Orb's memory on screen: a tab of the panel (identity, a short list per kind) and a sheet with all of it.
// Both read the Orb's own `BotLive.memory`, group and search with `MemoryGroups`, and forget with a way back
// (`MemoryUndo`): "Esquecer" removes the page at once and offers "Desfazer" for a few seconds.

/// The panel's Memória tab, as sections of the panel's form.
struct MemoryTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let botID: UUID
    let name: String
    let editIdentity: () -> Void
    /// Opens the sheet with everything, on one kind when given.
    let showAll: (MemoryKind?) -> Void
    @State private var query = ""
    @State private var folded = FoldedTextCache()

    /// Rows per group in the panel; the sheet shows the rest.
    private static let rowsPerGroup = 4

    var body: some View {
        let memory = model.live(botID).memory
        let groups = MemoryGroups.make(memory.items, matching: query, cache: folded)
        // A short memory fits the panel whole; only a long one is cut to a few rows per group.
        let truncates = query.isEmpty && memory.items.count > MemoryGroups.searchableAbove

        Section {
            IdentityBlock(memory: memory, name: name, canSummarize: model.bot(botID)?.permissionMode != .readOnly, edit: editIdentity,
                          restartInterview: { model.restartInterview(of: botID) })
        } header: {
            Text("Como \(name) funciona")
        }

        Section {
            if memory.items.isEmpty {
                PanelEmptyNote("Nada guardado ainda", systemImage: "brain",
                               detail: "A memória cresce a cada conversa: preferências, fatos, procedimentos e um resumo de cada uma.")
                    .transition(.quiet)
            } else if memory.items.count > MemoryGroups.searchableAbove {
                MemorySearchField(query: $query)
            }
            if !memory.items.isEmpty && groups.isEmpty {
                Text("Nada na memória com “\(query)”.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.muted)
            }
        } header: {
            Text("O que \(name) guardou")
        } footer: { FormFootnote {
            if !memory.items.isEmpty { Text(MemoryGroups.summary(memory.items)) }
        } }

        ForEach(groups) { group in
            let shown = truncates ? Array(group.items.prefix(Self.rowsPerGroup)) : group.items
            Section {
                ForEach(shown) { item in
                    MemoryRow(item: item) { model.memoryUndo.forget(item, of: botID, in: model) }
                        .transition(MemoryMotion.forgotten(reduceMotion: reduceMotion, isSearching: !query.isEmpty))
                }
                if shown.count < group.items.count {
                    Button("Ver todos (\(group.items.count))…") { showAll(group.kind) }
                        .buttonStyle(.link)
                        .help(Tip.memoryShowKind)
                }
            } header: {
                MemoryGroupHeader(group: group)
            }
        }
        // A page forgotten fades out in `Motion.exit` and the rest close the gap. Bound to the memory's own ids, not to what the
        // search shows: typing filters at once (§2.13).
        .animateChanges(of: memory.items.map(\.id))

        Section {
            // One line of chips when they fit (one under the other in a narrow panel); "Ver tudo…" only once there is
            // something to see.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    memoryButtons(isEmpty: memory.items.isEmpty)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) { memoryButtons(isEmpty: memory.items.isEmpty) }
            }
        } footer: { FormFootnote {
            InlineLinkNote(text: "Só \(name) vê isso.", link: "Como funciona",
                           hint: "Mostra como a memória funciona", tip: Tip.memoryHow) {
                MemoryHelp(name: name)
            }
        } }
    }
}

extension MemoryTab {
    @ViewBuilder
    fileprivate func memoryButtons(isEmpty: Bool) -> some View {
        if !isEmpty {
            Button("Ver tudo…", systemImage: "list.bullet.rectangle") { showAll(nil) }
                .chipButton()
                .help(Tip.memoryShowAll)
        }
        Button("Abrir pasta da memória", systemImage: "folder") {
            NSWorkspace.shared.open(model.memory.directory(for: botID))
        }
        .chipButton()
        .help(Tip.memoryFolder)
    }
}

/// The identity notes: what the Orb was told about how to work, and whether it will interview you.
private struct IdentityBlock: View {
    let memory: MemorySnapshot
    let name: String
    let canSummarize: Bool
    let edit: () -> Void
    let restartInterview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if memory.identity.isEmpty {
                PanelEmptyNote("Nenhuma nota ainda", systemImage: "person.text.rectangle",
                               detail: "Diga como \(name) deve trabalhar com você: o tom, o que evitar, o que lembrar sempre.")
            } else {
                Text(memory.identity.replacingOccurrences(of: "## ", with: ""))
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(5)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if memory.identity.count > MemoryBank.identityShare {
                Text("Longa: em cada conversa vão cerca de \(MemoryBank.identityShare) caracteres; as notas mais antigas saem primeiro.")
                    .font(Typography.small)
                    .foregroundStyle(.secondary)
            }
            if memory.preferencesOverflow > 0 {
                Text("\(memory.preferencesOverflow) \(memory.preferencesOverflow == 1 ? "preferência não cabe" : "preferências não cabem") inteira\(memory.preferencesOverflow == 1 ? "" : "s") no que \(name) sempre vê; "
                     + (canSummarize && memory.preferencesConsolidate
                        ? "\(name) vai juntar as mais curtas sozinho." : "o resto é encontrado só quando \(name) busca."))
                    .font(Typography.small)
                    .foregroundStyle(.secondary)
            }
            if memory.interviewPending {
                Label("Vai fazer perguntas a você nas primeiras mensagens", systemImage: "questionmark.bubble")
                    .font(Typography.small)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Editar…", systemImage: "pencil", action: edit)
                    .chipButton()
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

/// A group's title with its count a step quieter: "Preferências  2".
private struct MemoryGroupHeader: View {
    let group: MemoryGroup

    var body: some View {
        HStack(spacing: 6) {
            Text(group.title)
            Text("\(group.items.count)")
                .foregroundStyle(Palette.faint)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The search line of a memory (an Orb's, or a group's board: the same field).
struct MemorySearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // The hint inside the field: in a Form a field's title would become a label column beside it.
            TextField("Buscar na memória", text: $query, prompt: Text("Buscar na memória"))
                .textFieldStyle(.plain)
                .labelsHidden()
                .lineLimit(1)
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
            Text("Conversas antigas são compactadas, nunca apagadas sem você. Tudo fica em arquivos .md na pasta da memória, um por lembrança.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 300)
    }
}

/// One remembered thing: its text, when it came, and a "Esquecer" that shows on hover or keyboard focus (and to VoiceOver and the menu).
struct MemoryRow: View {
    let item: MemorySnapshot.Item
    var lineLimit = 3
    let forget: () -> Void
    @State private var isHovering = false
    @State private var isExpanded = false
    @FocusState private var forgetFocused: Bool

    /// One flag for the trash can's opacity and its animation, as in `RoutineRow`.
    private var showsForget: Bool { isHovering || forgetFocused }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.text(of: item))
                    .font(.callout)
                    .foregroundStyle(Palette.ink.opacity(0.9))
                    .lineSpacing(1.5)
                    .lineLimit(isExpanded ? nil : (item.kind == .sessao ? 1 : lineLimit))
                    .fixedSize(horizontal: false, vertical: true)
                    .motion(Motion.content, value: isExpanded)
                if isExpanded, item.kind == .sessao {
                    let details = Self.details(of: item)
                    if !details.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(details, id: \.self) { line in
                                Text(line)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .font(Typography.small)
                        .foregroundStyle(Palette.secondary)
                        .padding(.vertical, 2)
                        .transition(.quiet)
                    }
                }
                Text(Self.caption(of: item))
                    .font(Typography.small)
                    .foregroundStyle(Palette.faint)
                    .padding(.top, 1)
            }
            Spacer(minLength: 4)
            // The 11 pt icon sits in a 20 pt square that is all clickable (the plain icon would be a target of its own size).
            // Only under the pointer or with the keyboard on it (it takes Tab, so it must be seen there): a list of
            // lembranças, not of trash cans. VoiceOver and the menu always have it.
            Button(action: forget) {
                Image(systemName: "trash")
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.muted)
            .font(Typography.small)
            .focused($forgetFocused)
            .opacity(showsForget ? 1 : 0)
            .animation(Motion.hover(showsForget), value: showsForget)
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
        let text = item.kind == .sessao || item.title == item.body ? item.title : item.body
        return displayed(text)
    }

    /// The text as the row shows it: without the list mark it was written with ("- ", "* ", "1. "), which on its own
    /// line in a card only adds noise. The page keeps it.
    nonisolated static func displayed(_ text: String) -> String {
        let trimmed = text.drop { $0 == " " }
        if let first = trimmed.first, "-*•".contains(first), trimmed.dropFirst().first == " " {
            return String(trimmed.dropFirst(2))
        }
        let digits = trimmed.prefix { $0.isNumber }
        if (1...2).contains(digits.count), trimmed.dropFirst(digits.count).hasPrefix(". ") || trimmed.dropFirst(digits.count).hasPrefix(") ") {
            return String(trimmed.dropFirst(digits.count + 2))
        }
        return text
    }

    /// What an opened conversation shows under its title: the model's summary, then what was decided and what was left
    /// open (each item says what it is: "Ficou sem resposta", "Não deu certo"…), each on a line of its own and only when the
    /// page has it.
    static func details(of item: MemorySnapshot.Item) -> [String] {
        func joined(_ title: String, _ label: String) -> String? {
            let lines = SessionSummary.section(title, in: item.body).suffix(3)
            return lines.isEmpty ? nil : label + lines.joined(separator: " · ")
        }
        return [SessionSummary.section("Resumo", in: item.body).last, joined("Decisões", "Decidido: "),
                joined("Pendências", "")].compactMap { $0 }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            // Nothing stored: no search or filter to offer, and the subtitle already says it is empty, so the body
            // explains how the memory fills instead (the overlay below).
            if !memory.items.isEmpty {
                Section {
                    MemorySearchField(query: $query)
                    Picker("Mostrar", selection: $kind) {
                        Text("Tudo").tag(MemoryKind?.none)
                        ForEach(MemoryGroups.kinds, id: \.self) { Text(MemoryGroup(kind: $0, items: []).title).tag(MemoryKind?.some($0)) }
                    }
                }
                if groups.isEmpty {
                    Text(query.isEmpty ? "Nada neste tipo de memória." : "Nada na memória com “\(query)”.")
                        .foregroundStyle(.secondary)
                        // Only a different message fades; the query typed into it is not an animation.
                        .textSwap(query.isEmpty ? 1 : 2)
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        MemoryRow(item: item, lineLimit: 4) { model.memoryUndo.forget(item, of: botID, in: model) }
                            .transition(MemoryMotion.forgotten(reduceMotion: reduceMotion, isSearching: !query.isEmpty))
                    }
                } header: {
                    MemoryGroupHeader(group: group)
                }
                .transition(.opacity)
            }
            // "Mostrar" changes the kinds on show by fading; forgetting closes the gap; typing in the search filters at once.
            .motion(Motion.crossFade, value: kind)
            .animateChanges(of: memory.items.map(\.id))
        }
        .formStyle(.grouped)
        // The same empty page as Conectores and Skills: a symbol, a line and what fills it, centered in the sheet.
        .overlay {
            if memory.items.isEmpty {
                ContentUnavailableView {
                    Label("A memória cresce a cada conversa", systemImage: "brain")
                } description: {
                    Text("Preferências, fatos, procedimentos e um resumo de cada conversa aparecem aqui.")
                }
                .transition(.quiet)
            }
        }
        .orbSheet("Memória de \(name)", subtitle: MemoryGroups.summary(memory.items), size: .large) {
            SheetFooterBar {
                Button("Abrir pasta da memória", systemImage: "folder") {
                    NSWorkspace.shared.open(model.memory.directory(for: botID))
                }
                .buttonStyle(GhostStyle())
                .labelStyle(FixedIconLabelStyle())
                .help(Tip.memoryFolder)
                .hangsOnLeadingEdge()
                Text("Um arquivo .md por lembrança.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: Spacing.m)
                Button("Fechar") { dismiss() }
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .overlay(alignment: .bottom) { MemoryUndoToast(undo: model.memoryUndo).padding(.bottom, 64) }
    }
}

enum MemoryMotion {
    /// A page of memory that was forgotten: it only fades, quickly; the others close the gap.
    /// While a search is typed the rows that stop matching leave at once (typing is not an animation).
    static func forgotten(reduceMotion: Bool, isSearching: Bool = false) -> AnyTransition {
        isSearching ? .identity : .adapted(.opacity.animation(Motion.exit), reduceMotion: reduceMotion)
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
                        .font(Typography.label)
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
                .shadow(color: Shadow.popover, radius: 8, y: 2)
                .background { undoShortcut }
                .onHover { undo.hold(.hover, $0) }
                .onChange(of: isFocused) { _, focused in undo.hold(.focus, focused) }
                .onDisappear { undo.releaseHolds() }
                .transition(.adapted(.arrive, reduceMotion: reduceMotion))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Memória esquecida. Desfazer disponível por alguns segundos.")
            }
        }
        // Rises 6 pt in `Motion.enter` and leaves by fading in `Motion.exit` (`arrive`); a fade of 0.15 s under Reduce Motion.
        .motion(Motion.enter, value: undo.entry)
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
