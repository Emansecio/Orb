import SwiftUI

// "Ir para…" (⌘K): one field to reach an Orb, a page, an earlier conversation or an action without the mouse.
// The list is built and ranked by plain values (`PaletteBuilder`, `PaletteSearch`), so it is tested without a window.

struct PaletteEntry: Identifiable, Equatable {
    enum Action: Equatable {
        case bot(UUID)
        case page(SidebarItem)
        case reopen(conversation: UUID, bot: UUID)
        case newBot, importOrb, newConversation, focusComposer, showConversations, openFolder, toggleInspector, shortcuts
    }

    /// The order of the groups when nothing was typed.
    enum Section: Int, Comparable {
        case orbs, actions, workspace, conversations

        static func < (a: Section, b: Section) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .orbs: "Orbs"
            case .actions: "Ações"
            case .workspace: "Espaço de trabalho"
            case .conversations: "Conversas anteriores"
            }
        }
    }

    let id: String
    var title: String
    var subtitle: String?
    var symbol: String
    var section: Section
    var shortcut: String?
    var action: Action
    /// Words that find the entry besides its title ("pasta" finds "Abrir pasta no Finder" and also "Finder").
    var keywords = ""
}

enum PaletteSearch {
    /// Lowercase without accents, so "conversa" finds "Conversá" and "ACOES" finds "Ações".
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
    }

    /// The entries that match every word typed, best first: a title that starts with the word, then a word of the
    /// title that starts with it, then anywhere in the title, then the subtitle or keywords. Ties keep the order of
    /// the groups and of `entries`. Nothing typed keeps the order of the groups.
    static func rank(_ entries: [PaletteEntry], query: String) -> [PaletteEntry] {
        let words = normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let indexed = entries.enumerated().map { (index: $0.offset, entry: $0.element) }
        guard !words.isEmpty else {
            return indexed.sorted { ($0.entry.section, $0.index) < ($1.entry.section, $1.index) }.map(\.entry)
        }
        var scored: [(score: Int, index: Int, entry: PaletteEntry)] = []
        for (index, entry) in indexed {
            let title = normalize(entry.title)
            let rest = normalize([entry.subtitle ?? "", entry.keywords].joined(separator: " "))
            var total = 0
            var matchesAll = true
            for word in words {
                if title.hasPrefix(word) {
                    total += 0
                } else if title.split(separator: " ").contains(where: { $0.hasPrefix(word) }) {
                    total += 1
                } else if title.contains(word) {
                    total += 2
                } else if rest.contains(word) {
                    total += 3
                } else {
                    matchesAll = false
                    break
                }
            }
            if matchesAll { scored.append((total, index, entry)) }
        }
        return scored.sorted { ($0.score, $0.entry.section, $0.index) < ($1.score, $1.entry.section, $1.index) }.map(\.entry)
    }
}

enum PaletteBuilder {
    /// Everything the palette can go to. `current` is the open Orb: the actions and the earlier conversations are its.
    static func entries(orbs: [BotLook], current: UUID?, routines: [Routine], skills: [Skill],
                        archive: [ConversationSummary], now: Date = .now) -> [PaletteEntry] {
        var list: [PaletteEntry] = []
        for (index, look) in orbs.enumerated() {
            list.append(PaletteEntry(id: "bot-\(look.id)", title: look.name, subtitle: look.role.isEmpty ? nil : look.role,
                                     symbol: "circle.hexagongrid.fill", section: .orbs,
                                     shortcut: index < 9 ? AppShortcut.bot(at: index).label : nil, action: .bot(look.id), keywords: "orb conversa"))
        }
        let name = orbs.first { $0.id == current }?.name
        if current != nil {
            let suffix = name.map { " de \($0)" } ?? ""
            list.append(PaletteEntry(id: "new-conversation", title: CommandName.newConversation, subtitle: name, symbol: "square.and.pencil",
                                     section: .actions, shortcut: ShortcutCatalog.keys(for: .newConversation), action: .newConversation, keywords: "limpar começar"))
            list.append(PaletteEntry(id: "focus", title: CommandName.writeMessage, subtitle: name, symbol: "text.cursor",
                                     section: .actions, shortcut: ShortcutCatalog.keys(for: .writeMessage), action: .focusComposer, keywords: "compositor campo focar digitar"))
            list.append(PaletteEntry(id: "history", title: CommandName.conversations, subtitle: name, symbol: "clock.arrow.circlepath",
                                     section: .actions, shortcut: ShortcutCatalog.keys(for: .conversations), action: .showConversations, keywords: "histórico reabrir arquivo"))
            list.append(PaletteEntry(id: "folder", title: CommandName.openFolder, subtitle: "Pasta de trabalho\(suffix)", symbol: "folder",
                                     section: .actions, shortcut: ShortcutCatalog.keys(for: .openFolder), action: .openFolder, keywords: "finder arquivos"))
            list.append(PaletteEntry(id: "inspector", title: CommandName.toggleInspector, subtitle: nil, symbol: "sidebar.right",
                                     section: .actions, shortcut: ShortcutCatalog.keys(for: .toggleInspector), action: .toggleInspector,
                                     keywords: "detalhes memória permissões modelo personalizar"))
        }
        list.append(PaletteEntry(id: "new-bot", title: CommandName.newBot, subtitle: nil, symbol: "plus", section: .actions,
                                 shortcut: ShortcutCatalog.keys(for: .newBot), action: .newBot, keywords: "criar adicionar"))
        list.append(PaletteEntry(id: "import-orb", title: CommandName.importOrb, subtitle: "Trazer o que outro assistente sabe", symbol: "square.and.arrow.down",
                                 section: .actions, shortcut: nil, action: .importOrb, keywords: "chatgpt gemini hermes openclaw memória migrar"))
        list.append(PaletteEntry(id: "shortcuts", title: CommandName.shortcuts, subtitle: nil, symbol: "keyboard", section: .actions,
                                 shortcut: nil, action: .shortcuts, keywords: "ajuda teclas"))
        list.append(PaletteEntry(id: "page-routines", title: CommandName.routines, subtitle: "Tarefas que rodam sozinhas", symbol: "clock.arrow.circlepath",
                                 section: .workspace, shortcut: ShortcutCatalog.keys(for: .routines), action: .page(.routines), keywords: "agendar horário"))
        list.append(PaletteEntry(id: "page-connectors", title: CommandName.connectors, subtitle: "Serviços que os Orbs podem usar", symbol: "point.3.filled.connected.trianglepath.dotted",
                                 section: .workspace, shortcut: ShortcutCatalog.keys(for: .connectors), action: .page(.connectors), keywords: "integrações mcp"))
        list.append(PaletteEntry(id: "page-skills", title: CommandName.skills, subtitle: "Instruções que os Orbs sabem seguir", symbol: "wand.and.stars",
                                 section: .workspace, shortcut: ShortcutCatalog.keys(for: .skills), action: .page(.skills), keywords: "habilidades"))
        for routine in routines {
            let owner = orbs.first { $0.id == routine.botID }?.name
            list.append(PaletteEntry(id: "routine-\(routine.id)", title: "Rotina: \(routine.name)", subtitle: owner, symbol: "clock",
                                     section: .workspace, action: .page(.routines)))
        }
        for skill in skills where skill.isEnabled {
            list.append(PaletteEntry(id: "skill-\(skill.id)", title: "Skill: \(skill.name)", subtitle: skill.summary.isEmpty ? "/\(skill.slug)" : skill.summary,
                                     symbol: "wand.and.stars", section: .workspace, action: .page(.skills), keywords: skill.slug))
        }
        if let current {
            for entry in archive.prefix(40) {
                list.append(PaletteEntry(id: "conversation-\(entry.id)", title: entry.title.isEmpty ? "Conversa sem título" : entry.title,
                                         subtitle: [name, dayLabel(entry.updatedAt, now: now)].compactMap { $0 }.joined(separator: " · "),
                                         symbol: "bubble.left",
                                         section: .conversations, action: .reopen(conversation: entry.id, bot: current)))
            }
        }
        return list
    }

    /// "hoje", "ontem" or the date.
    static func dayLabel(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Hoje" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Ontem" }
        let format = DateFormatter()
        format.locale = Locale(identifier: "pt_BR")
        format.dateFormat = "d 'de' MMM"
        return format.string(from: date)
    }
}

// MARK: The palette

struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var selected = 0
    @State private var entries: [PaletteEntry] = []
    @FocusState private var isFocused: Bool

    private var results: [PaletteEntry] { PaletteSearch.rank(entries, query: query) }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)
                TextField("Ir para…", text: $query, prompt: Text("Ir para um Orb, uma conversa ou uma ação…"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isFocused)
                    .onSubmit { run(results) }
                    .onKeyPress(.downArrow) { move(1, in: results.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: results.count); return .handled }
                    .onKeyPress(.escape) { model.showCommandPalette = false; return .handled }
                    .accessibilityLabel("Ir para")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Divider().opacity(0.6)
            if results.isEmpty {
                Text("Nada encontrado para “\(query)”.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                                if showsHeader(at: index, in: results) {
                                    Text(entry.section.title)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Palette.faint)
                                        .padding(.horizontal, 10)
                                        .padding(.top, index == 0 ? 2 : 10)
                                        .padding(.bottom, 3)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                // A real button: VoiceOver can activate the row, not only read it.
                                Button { selected = index; run(results) } label: {
                                    PaletteRow(entry: entry, isSelected: index == selected)
                                }
                                .buttonStyle(.plain)
                                .id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: selected) {
                        guard results.indices.contains(selected) else { return }
                        proxy.scrollTo(results[selected].id)
                    }
                }
            }
            Divider().opacity(0.6)
            HStack(spacing: 14) {
                hint("↑↓", "navegar")
                hint("↩", "abrir")
                hint("esc", "fechar")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .frame(width: 540, height: 430)
        .background(Palette.chrome)
        .onChange(of: query) { selected = 0 }
        .onAppear { isFocused = true }
        .task { await load() }
    }

    private func hint(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text(keys).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Palette.secondary)
            Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    private func showsHeader(at index: Int, in results: [PaletteEntry]) -> Bool {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return index == 0 || results[index - 1].section != results[index].section
    }

    private func move(_ step: Int, in count: Int) {
        guard count > 0 else { return }
        selected = (selected + step + count) % count
    }

    /// Built once when it opens (and again when the earlier conversations arrive), not on each keystroke.
    private func build(archive: [ConversationSummary]) {
        entries = PaletteBuilder.entries(orbs: model.botIDs.map { model.live($0).look }, current: model.commandBotID,
                                         routines: model.routines, skills: model.skills, archive: archive)
    }

    private func load() async {
        build(archive: model.commandBotID.flatMap { model.archives[$0] } ?? [])
        guard let id = model.commandBotID else { return }
        await model.loadArchive(id)
        build(archive: model.archives[id] ?? [])
    }

    private func run(_ results: [PaletteEntry]) {
        guard results.indices.contains(selected) else { return }
        let action = results[selected].action
        model.showCommandPalette = false
        // After the sheet is gone, so a command that opens something else (or moves the focus) is not swallowed by it.
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            perform(action)
        }
    }

    private func perform(_ action: PaletteEntry.Action) {
        switch action {
        case .bot(let id): model.selection = .bot(id)
        case .page(let page): model.selection = page
        case .reopen(let conversation, let bot):
            model.selection = .bot(bot)
            Task { await model.reopenConversation(conversation, of: bot) }
        case .newBot: model.showNewBot = true
        case .importOrb: model.startNewOrbImporting()
        case .newConversation: if let id = model.commandBotID { model.selection = .bot(id); model.newConversation(id) }
        case .focusComposer: model.focusComposer()
        case .showConversations: model.showConversations()
        case .openFolder: if let id = model.commandBotID { model.openFolder(of: id) }
        case .toggleInspector: model.showInspector.toggle()
        case .shortcuts: model.showShortcuts = true
        }
    }
}

private struct PaletteRow: View {
    let entry: PaletteEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbol)
                .font(.system(size: 13))
                .frame(width: 22)
                .foregroundStyle(isSelected ? Palette.ink : Palette.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = entry.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Palette.ghostSelected : .clear, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: Shortcuts

struct ShortcutsSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(ShortcutCatalog.groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.faint)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.items) { item in
                            HStack(spacing: 12) {
                                Text(item.keys)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Palette.ink)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Palette.raised, in: .rect(cornerRadius: 6))
                                    .frame(width: 96, alignment: .leading)
                                Text(item.title)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Palette.secondary)
                                Spacer(minLength: 0)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .orbSheet("Atalhos do teclado", subtitle: "Os comandos de Navegar também estão no menu Orbs e em Ir para… (⌘K).") {
            HStack {
                Spacer()
                Button("Fechar") { model.showShortcuts = false }
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Divider().opacity(0.6) }
        }
    }
}

// MARK: Presenting them

/// The sheets of the system commands, attached once to the window's root so they open whatever column has the focus.
struct SystemSheets: ViewModifier {
    @Environment(AppModel.self) private var model

    private struct DeleteTarget: Identifiable { let id: UUID }

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(isPresented: $model.showCommandPalette) { CommandPalette() }
            .sheet(isPresented: $model.showShortcuts) { ShortcutsSheet() }
            .sheet(item: Binding(get: { model.deletingBotID.map(DeleteTarget.init) },
                                 set: { if $0 == nil { model.deletingBotID = nil } })) { target in
                DeleteOrbSheet(botID: target.id)
            }
    }
}

extension View {
    func systemSheets() -> some View { modifier(SystemSheets()) }
}
