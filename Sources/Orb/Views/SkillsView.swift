import SwiftUI
import AppKit

/// Skills: the installed ones (use, enable, edit, delete) and the public catalog (search, preview, install).
struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: CatalogTab
    @State private var editing: Skill?
    /// The filter of the installed list, which ⌘F focuses (the tab bar holds the shortcut).
    @FocusState private var filterFocused: Bool

    init(tab: CatalogTab = .installed) {
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            CatalogTabBar(tab: $tab, installedTitle: "Instaladas", installedCount: model.skills.count,
                           findInstalled: model.skills.count >= InstalledSkillFilter.threshold ? { filterFocused = true } : nil)
                .padding(.top, 16)
                .padding(.bottom, 4)
            CatalogTabContent(tab: tab) {
                switch tab {
                case .installed, .gallery: InstalledSkills(editing: $editing, filterFocused: $filterFocused, explore: { tab = .explore }) // only connectors have a gallery
                case .explore: ExploreSkills()
                }
            }
        }
        .background(Palette.canvas)
        .navigationTitle("Skills")
        .navigationSubtitle("Instruções prontas: comece a mensagem com /nome")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Nova skill", systemImage: "plus", action: newSkill)
                    Button("Do catálogo", systemImage: "sparkle.magnifyingglass") { tab = .explore }
                } label: {
                    Label("Nova skill", systemImage: "plus")
                } primaryAction: {
                    newSkill()
                }
                .help(Tip.newSkill)
            }
        }
        .sheet(item: $editing) { skill in
            SkillEditor(skill: skill)
        }
    }

    private func newSkill() {
        editing = Skill(slug: "", name: "", summary: "", instructions: "", orbIDs: model.defaultScopeForNewSkill())
    }
}

// MARK: Using a skill

/// "Usar": opens the chat of the Orb the user was on with `/comando ` ready in the composer (one click); with no
/// such Orb, a menu of the Orbs that may use the skill.
struct UseSkillButton: View {
    @Environment(AppModel.self) private var model
    let skill: Skill
    var onUsed: () -> Void = {}
    var title = "Usar"

    private var candidates: [Bot] { model.bots.filter { skill.isAvailable(to: $0.id) } }

    var body: some View {
        if let preferred = model.preferredBot(for: skill) ?? (candidates.count == 1 ? candidates.first : nil) {
            Button(title) { use(preferred) }
                .buttonStyle(SecondaryPillStyle())
                .help(Tip.useSkill(orb: preferred.name, slug: skill.slug))
                .disabled(!skill.isEnabled)
        } else if candidates.isEmpty {
            Button(title) {}
                .buttonStyle(SecondaryPillStyle())
                .disabled(true)
                .help(Tip.noOrbForSkill)
        } else {
            Menu(title) {
                ForEach(candidates) { bot in
                    Button(bot.name) { use(bot) }
                }
            }
            .menuStyle(.button)
            .buttonStyle(SecondaryPillStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!skill.isEnabled)
            .help(Tip.chooseOrbForSkill(slug: skill.slug))
        }
    }

    private func use(_ bot: Bot) {
        model.useSkill(skill, with: bot.id)
        onUsed()
    }
}

// MARK: Installed

/// The filter of the installed list: by name, command or summary, case and accents aside.
enum InstalledSkillFilter {
    /// From this many skills on the list gets a field (and ⌘F goes to it instead of the catalog).
    static let threshold = 8

    static func matches(_ skill: Skill, query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespaces)
        return term.isEmpty || [skill.name, skill.slug, skill.summary].contains { $0.localizedStandardContains(term) }
    }
}

private struct InstalledSkills: View {
    @Environment(AppModel.self) private var model
    @Binding var editing: Skill?
    var filterFocused: FocusState<Bool>.Binding
    let explore: () -> Void
    @State private var deleting: Skill?
    @State private var query = ""
    /// What the Orbs proposed and waits for you, read from their memories when the page opens and when a review ends.
    @State private var pending: [SkillDraft] = []
    @State private var reviewing: SkillDraft?
    /// The proposals already opened by "Revisar uma a uma" (nil outside it): "Decidir depois" must not open the same one again.
    @State private var reviewedInQueue: Set<String>?

    private var showsFilter: Bool { model.skills.count >= InstalledSkillFilter.threshold }
    /// A filter typed before the list got short is gone with its field, not kept hiding skills.
    private var activeQuery: String { showsFilter ? query : "" }

    var body: some View {
        @Bindable var model = model
        let visible = $model.skills.filter { InstalledSkillFilter.matches($0.wrappedValue, query: activeQuery) }
        ScrollView {
            VStack(spacing: 8) {
                // The same field as the catalog's search (without its ⌘F button: the tab bar owns the shortcut).
                if showsFilter { SearchBox(label: "Filtrar skills instaladas", text: $query, isFocused: filterFocused).padding(.bottom, 4) }
                if !pending.isEmpty { pendingReview }
                if visible.isEmpty, !model.skills.isEmpty {
                    ContentUnavailableView.search(text: activeQuery)
                }
                LazyVStack(spacing: Spacing.cardSpacing) {
                    ForEach(visible) { skill in
                        InstalledSkillRow(skill: skill) {
                            editing = skill.wrappedValue
                        } onDelete: {
                            deleting = skill.wrappedValue
                        }
                    }
                }
            }
            .pageColumn()
        }
        .overlay {
            if model.skills.isEmpty, pending.isEmpty {
                ContentUnavailableView {
                    Label("Nenhuma skill instalada", systemImage: "wand.and.stars")
                } description: {
                    Text("Encontre skills prontas no catálogo ou crie a sua.")
                } actions: {
                    Button("Explorar", action: explore).buttonStyle(PrimaryPillStyle())
                        .help(Tip.exploreSkills)
                }
            }
        }
        .task { pending = await model.pendingSkillDrafts() }
        .sheet(item: $reviewing, onDismiss: {
            Task {
                pending = await model.pendingSkillDrafts()
                presentNext()
            }
        }) { draft in
            SkillEditor(skill: draft.skill, proposal: draft)
        }
        .confirmationDialog("Apagar a skill “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Apagar", role: .destructive) {
                if let id = deleting?.id { model.skills.removeAll { $0.id == id } }
            }
        } message: {
            Text(deleting.map(SkillDeleteCopy.message) ?? "")
        }
    }

    /// Opens the next proposal not yet seen in the one-by-one review; ends the review when none is left.
    private func presentNext() {
        guard var seen = reviewedInQueue else { return }
        guard let next = pending.first(where: { !seen.contains($0.id) }) else { reviewedInQueue = nil; return }
        seen.insert(next.id)
        reviewedInQueue = seen
        reviewing = next
    }

    /// The skills the Orbs learned and proposed, from every Orb: nothing is saved until you read it and say so.
    private var pendingReview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Aguardando sua revisão (\(pending.count))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 12)
                if pending.count > 1 {
                    Button("Revisar uma a uma") {
                        reviewedInQueue = []
                        presentNext()
                    }
                    .buttonStyle(LinkTextStyle())
                    .help("Abre uma proposta depois da outra")
                }
            }
            ForEach(pending) { draft in
                HStack(spacing: Spacing.cardSpacing) {
                    // The initial of the Orb that proposed it tells the cards apart at a glance.
                    CatalogIcon(symbol: SkillText.orbInitialSymbol(draft.orbName))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(SkillText.displayName(draft.skill.name))
                                .font(.system(size: 14, weight: .semibold))
                            Text("de \(draft.orbName)")
                                .font(Typography.label)
                                .foregroundStyle(Palette.muted)
                        }
                        if draft.isUpdate {
                            CatalogBadge(text: "Melhoria de \(SkillText.displayName(draft.slug))", symbol: "arrow.triangle.2.circlepath")
                        }
                    }
                    Spacer(minLength: 12)
                    Button("Revisar") { reviewedInQueue = nil; reviewing = draft }
                        .buttonStyle(SecondaryPillStyle())
                        .accessibilityLabel("Revisar \(SkillText.displayName(draft.skill.name)), proposta de \(draft.orbName)")
                        .help("Abre a proposta para salvar ou descartar")
                }
                .padding(Spacing.cardPadding)
                .card(radius: Radius.large)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }
}

/// What the delete dialog of a skill promises: only what is true for where the skill came from.
enum SkillDeleteCopy {
    static func message(for skill: Skill) -> String {
        switch skill.source {
        case nil: "As instruções que você escreveu serão apagadas. Não dá para desfazer."
        case Skill.learnedSource?: "As instruções que o Orb aprendeu e você aprovou serão apagadas. Não dá para desfazer."
        case Skill.importedSource?: "As instruções que vieram do outro assistente serão apagadas. Não dá para desfazer."
        case Skill.builtInSource?: "Ela vem com o app e não volta sozinha depois de apagada. Você pode escrever outra com o mesmo comando."
        default: "Você pode instalar de novo pelo catálogo depois."
        }
    }
}

/// The words on a skill's badge that depend on the skill, not on the screen.
enum SkillBadge {
    /// "Aprendida por Atlas" (just "Aprendida" when the Orb that proposed it is gone).
    static func learned(by orb: String?) -> String { orb.map { "Aprendida por \($0)" } ?? "Aprendida" }

    /// "owner/repo" of a catalog skill's source.
    static func origin(of source: String) -> String {
        source == Skill.importedSource ? "Importada" : source.split(separator: "/").prefix(2).joined(separator: "/")
    }

    /// What the editor says of a skill that came from the catalog: the copy on this Mac is its own from the first edit.
    /// nil for yours, the app's and the ones an Orb learned.
    static func catalogNote(for skill: Skill) -> String? {
        guard skill.isFromCatalog, let source = skill.source else { return nil }
        return "Veio de \(origin(of: source)). A edição fica só neste Mac."
    }
}

/// How a skill's name and a search theme read on screen: a proposal arrives named after its slug ("publicar-lp-docker").
enum SkillText {
    /// Words that are initialisms, written in capitals wherever they appear in a name or a theme.
    private static let acronyms: Set<String> = ["pdf", "seo", "aeo", "api", "ui", "ux", "csv", "json", "html", "css", "sql",
                                                "url", "lp", "ai", "ia", "ios", "cli", "mcp", "xml", "yaml", "ssh", "http"]

    /// "publicar-lp-docker" -> "Publicar LP docker"; "pdf" -> "PDF". A word that already has a capital is left as written,
    /// so a name the person typed ("Resumir para o CEO") does not change.
    static func displayName(_ raw: String) -> String {
        let words = raw.split(whereSeparator: { $0 == "-" || $0 == "_" || $0.isWhitespace }).map(String.init)
        return words.enumerated().map { index, word in
            if acronyms.contains(word.lowercased()) { return word.uppercased() }
            if index == 0, word.first?.isLowercase == true { return word.prefix(1).uppercased() + word.dropFirst() }
            return word
        }.joined(separator: " ")
    }

    /// The instructions without a first-line "# Title" that repeats the sheet's own title (the name of the skill).
    static func droppingTitle(_ markdown: String, matching name: String) -> String {
        let lines = markdown.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first, first.hasPrefix("# "),
              first.dropFirst(2).trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame else { return markdown }
        return lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .newlines) : ""
    }

    /// "a.circle" for an Orb called "Atlas" (accents folded); a neutral symbol when the name starts with anything else.
    static func orbInitialSymbol(_ orbName: String) -> String {
        guard let first = orbName.trimmingCharacters(in: .whitespaces).folding(options: .diacriticInsensitive, locale: nil)
            .lowercased().first, first.isASCII, first.isLetter else { return "sparkles" }
        return "\(first).circle"
    }
}

/// A line diff between two texts, for the review of an improvement an Orb proposed.
enum LineDiff {
    enum Kind: Equatable { case same, added, removed }
    struct Line: Equatable {
        let kind: Kind
        let text: String
    }

    /// Past this many cells of the table the exact diff is not worth its memory: the middle is shown as replaced whole.
    private static let maxCells = 4_000_000

    static func lines(old: String, new: String) -> [Line] {
        func split(_ text: String) -> [String] {
            text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        let a = split(old), b = split(new)
        // What both texts share at the ends stays out of the table: edits are usually in the middle.
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        let x = Array(a[head..<(a.count - tail)]), y = Array(b[head..<(b.count - tail)])
        var middle: [Line] = []
        if x.count * y.count > maxCells {
            middle = x.map { Line(kind: .removed, text: $0) } + y.map { Line(kind: .added, text: $0) }
        } else {
            // Longest common subsequence, filled from the end so the walk below reads forward.
            var table = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
            for i in stride(from: x.count - 1, through: 0, by: -1) {
                for j in stride(from: y.count - 1, through: 0, by: -1) {
                    table[i][j] = x[i] == y[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
            var i = 0, j = 0
            while i < x.count || j < y.count {
                if i < x.count, j < y.count, x[i] == y[j] {
                    middle.append(Line(kind: .same, text: x[i])); i += 1; j += 1
                } else if i < x.count, j == y.count || table[i + 1][j] >= table[i][j + 1] {
                    middle.append(Line(kind: .removed, text: x[i])); i += 1
                } else {
                    middle.append(Line(kind: .added, text: y[j])); j += 1
                }
            }
        }
        let same: (ArraySlice<String>) -> [Line] = { $0.map { Line(kind: .same, text: $0) } }
        return same(a[..<head]) + middle + same(a[(a.count - tail)...])
    }
}

private struct InstalledSkillRow: View {
    @Environment(AppModel.self) private var model
    @Binding var skill: Skill
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var copied = CopiedFlash()
    @State private var isCompact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A switched-off skill dims its icon and title only: the badge says why, and the buttons stay legible.
        let dimmed = skill.isEnabled ? 1.0 : 0.55
        let layout = isCompact ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.m)) : AnyLayout(HStackLayout(spacing: Spacing.m))
        layout {
            // A click anywhere on this part opens the editor; the copy button here and the controls beside it keep their own.
            HStack(alignment: .center, spacing: Spacing.m) {
                CatalogIcon(symbol: skill.isFromCatalog ? "shippingbox" : "wand.and.stars")
                    .opacity(dimmed)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .font(.system(size: 14, weight: .semibold))
                            .opacity(dimmed)
                        // One line: in a narrow window it broke letter by letter ("/organiza r"). The copy button keeps the whole command.
                        Text("/\(skill.slug)")
                            .font(.system(size: 12).monospaced())
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                        Button(copied.isOn ? "Copiado" : "Copiar /\(skill.slug)", systemImage: copied.isOn ? "checkmark" : "doc.on.doc", action: copy)
                            .labelStyle(.iconOnly)
                            // 22 pt target (the bare glyph was ~12 pt), with the hover circle of the other small buttons.
                            .buttonStyle(CircleGhostStyle(side: 22, fontSize: 11))
                            .foregroundStyle(copied.isOn ? Palette.ok : Palette.faint)
                            // The symbol is replaced by the check, as in the chat (a plain change under Reduce Motion); in on the
                            // press curve, back on the content one.
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                            .animation(copied.isOn ? Motion.press : Motion.content, value: copied.isOn)
                            .help(Tip.copySlug(skill.slug))
                    }
                    if !skill.summary.isEmpty {
                        Text(MemoryText.tidyEllipsis(skill.summary))
                            .font(Typography.label)
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        if !skill.isEnabled {
                            CatalogBadge(text: "Desativada", symbol: "pause.circle")
                        }
                        // No badge for the app's own skills: it is the default, and the delete dialog says where it came from.
                        if skill.source == Skill.builtInSource {
                            EmptyView()
                        } else if skill.source == Skill.learnedSource {
                            CatalogBadge(text: SkillBadge.learned(by: model.bots.first { $0.id == skill.learnedBy }?.name), symbol: "sparkles")
                        } else if let source = skill.source {
                            CatalogBadge(text: SkillBadge.origin(of: source), symbol: skill.isFromCatalog ? "shippingbox" : "wand.and.stars")
                        } else {
                            CatalogBadge(text: "Criada por você", symbol: "person")
                        }
                        if !skill.orbIDs.isEmpty {
                            CatalogBadge(text: OrbScopeText.summary(orbIDs: skill.orbIDs, bots: model.bots), symbol: "person.2")
                        }
                        if skill.uses > 0 {
                            CatalogBadge(text: skill.uses == 1 ? "1 uso" : "\(skill.uses) usos")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture(perform: onEdit)
            .accessibilityAction(named: "Editar", onEdit)
            .help("Abre a skill para ler e editar")
            if !isCompact { Spacer(minLength: 12) }
            HStack(spacing: Spacing.m) {
                UseSkillButton(skill: skill)
                // Hidden label, read by VoiceOver: names the skill, since every row has the same switch.
                Toggle("Ativar \(skill.name)", isOn: $skill.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help(Tip.skillToggle(isOn: skill.isEnabled))
                MoreMenu(name: skill.name) {
                    Button("Editar…", action: onEdit)
                    if let folder = skill.folderURL {
                        Link("Ver no GitHub", destination: folder)
                    }
                    Divider()
                    Button("Apagar…", role: .destructive, action: onDelete)
                }
            }
            .frame(maxWidth: isCompact ? .infinity : nil, alignment: .trailing)
        }
        .padding(Spacing.cardPadding)
        // Change layout only at this boundary; resizing does not write every pixel into view state.
        .onGeometryChange(for: Bool.self) { $0.size.width < 520 } action: { isCompact = $0 }
        .card(radius: Radius.large)
        .animateChanges(of: skill.isEnabled)
    }

    private func copy() {
        Clipboard.copy("/\(skill.slug)")
        copied.trigger()
    }
}

// MARK: Explore

private struct ExploreSkills: View {
    @State private var query = ""
    @State private var results: [CatalogSkill] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var previewing: CatalogSkill?

    private static let suggestions = ["pdf", "excel", "slides", "docx", "pesquisa", "escrita", "design", "git",
                                      "marketing", "dados", "testes", "seo"]

    private var isSearching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                CatalogSearchHeader(query: $query, prompt: "Buscar no catálogo de skills (Skills.sh)",
                                    suggestions: Self.suggestions)
                if !isSearching {
                    intro
                } else if isLoading || error != nil || results.isEmpty {
                    CatalogStateView(isLoading: isLoading, error: error, isEmpty: results.isEmpty, skeleton: true,
                                     retry: { Task { await search() } })
                        .transition(.opacity)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: Spacing.cardSpacing, alignment: .top)], spacing: Spacing.cardSpacing) {
                        ForEach(results) { entry in
                            CatalogSkillCard(entry: entry) { previewing = entry }
                        }
                    }
                    .transition(.opacity)
                }
            }
            // The hint, the loading, the error, "no result" and the results swap by fading, bound to the one phase.
            .animateChanges(of: ExplorePhase.of(isSearching: isSearching, isLoading: isLoading, error: error, isEmpty: results.isEmpty))
            .pageColumn()
        }
        .task(id: query) {
            // Loading from the first key, not "no result" while the search waits to start.
            isLoading = isSearching
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search()
        }
        .sheet(item: $previewing) { entry in
            SkillPreview(entry: entry)
        }
    }

    /// What the page is for, until the user picks a theme or types (nothing is searched on its own).
    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Escolha um tema ou digite o que você precisa", systemImage: "sparkle.magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
            Text("As skills vêm do catálogo aberto Skills.sh e o conteúdo é de quem publicou, no GitHub. Você lê as instruções antes de instalar e depois usa com /comando no chat.")
                .font(Typography.label)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: Radius.large)
        .transition(.opacity)
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { results = []; return }
        isLoading = true
        error = nil
        // "Tentar de novo" runs this outside `.task(id:)`, so nothing cancels it when the person types on: what it brings
        // counts only while its term is still the one in the field.
        defer { if RegistryQuery.isCurrent(term, query: query, cancelled: Task.isCancelled) { isLoading = false } }
        do {
            let found = try await SkillCatalog.shared.search(term)
            if !Task.isCancelled, RegistryQuery.isCurrent(term, query: query) { results = found }
        } catch {
            // A newer search cancels this one; only real failures are shown.
            if !Task.isCancelled, RegistryQuery.isCurrent(term, query: query) { self.error = error.localizedDescription }
        }
    }
}

private struct CatalogSkillCard: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogSkill
    let onOpen: () -> Void
    @State private var document: SkillDocument?
    /// The SKILL.md could not be read (gone from its repository, or GitHub refused): the card says so instead of waiting.
    @State private var failure: String?
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    CatalogIcon(symbol: "wand.and.stars")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(document?.name ?? entry.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(entry.repo)
                            .font(.system(size: 11).monospaced())
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if model.installedSkill(entry.id) != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Palette.ok)
                            .help(Tip.installed)
                    }
                }
                Group {
                    if let document {
                        Text(document.description.isEmpty ? "Sem descrição." : document.description)
                    } else if let failure {
                        Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(Palette.faint)
                    } else {
                        // Static: a grid of cards loading at once shouldn't run a shimmer each.
                        Text("Carregando descrição…").foregroundStyle(Palette.faint)
                    }
                }
                .font(Typography.label)
                .foregroundStyle(Palette.muted)
                .lineLimit(3, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animateChanges(of: document == nil && failure == nil)
                HStack(spacing: 6) {
                    if entry.isFromKnownSource {
                        CatalogBadge(text: "Fonte conhecida", symbol: "checkmark.seal.fill", tint: Palette.accentText)
                    }
                    CatalogBadge(text: entry.installs.installsLabel, symbol: "arrow.down.circle")
                }
            }
            .padding(Spacing.catalogCardPadding)
            .hoverCard(isHovering, radius: Radius.large, strongOutline: true)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Tip.openSkillDetails)
        .onHover { isHovering = $0 }
        .task {
            do { document = try await SkillCatalog.shared.document(for: entry) }
            catch { if !Task.isCancelled { failure = CatalogError.cardText(for: error) } }
        }
    }
}

/// Review before installing: who published it, what it says, and the full instructions the Orb will follow.
/// After installing, the sheet stays to say how to use it.
struct SkillPreview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: CatalogSkill
    @State private var document: SkillDocument?
    @State private var error: String?

    init(entry: CatalogSkill, document: SkillDocument? = nil) {
        self.entry = entry
        _document = State(initialValue: document)
    }

    private var installed: Skill? { model.installedSkill(entry.id) }

    var body: some View {
        content
            .orbSheet(document?.name ?? entry.name, subtitle: "Revise o que a skill diz antes de instalar.", size: .large) { footer }
            .task { await load() }
    }

    /// Reads the SKILL.md; "Tentar de novo" runs it again.
    private func load() async {
        guard document == nil else { return }
        error = nil
        do {
            document = try await SkillCatalog.shared.document(for: entry)
        } catch {
            if !Task.isCancelled { self.error = CatalogError.previewText(for: error) }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.cardSpacing) {
                HStack(spacing: 6) {
                    if entry.isFromKnownSource {
                        CatalogBadge(text: "Fonte conhecida", symbol: "checkmark.seal.fill", tint: Palette.accentText)
                    }
                    CatalogBadge(text: entry.installs.installsLabel, symbol: "arrow.down.circle")
                    if let folder = document?.folderURL {
                        Link(destination: folder) {
                            CatalogBadge(text: entry.repo, symbol: "arrow.up.right.square")
                        }
                    }
                }
                // The spinner (after 150 ms), the error and the text cross-fade in the same place (§2.13).
                ZStack(alignment: .top) {
                    if let document {
                        VStack(alignment: .leading, spacing: Spacing.cardSpacing) {
                            if !document.description.isEmpty {
                                Text(document.description)
                                    .font(Typography.text)
                                    .foregroundStyle(Palette.secondary)
                            }
                            // In normal case, as every other heading in the app's sheets ("Chave", "Usar com", "Quando").
                            Text("Instruções que o Orb vai seguir")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                            // Read as the Markdown it is (headings, lists, code), not as raw source.
                            // On the canvas, as in a chat: code and tables are `raised` with no hairline, and would vanish on
                            // a `raised` frame.
                            MarkdownChunk(source: SkillText.droppingTitle(document.instructions, matching: document.name)).equatable()
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.canvas, in: .rect(cornerRadius: Radius.medium))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                    } else if let error {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.danger)
                            Button("Tentar de novo") { Task { await load() } }
                                .buttonStyle(SecondaryPillStyle())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                    } else {
                        DelayedSpinner().frame(maxWidth: .infinity).padding(.top, 40)
                            .transition(.opacity)
                    }
                }
                .motion(Motion.content, value: PreviewPhase(isReady: document != nil, error: error))
            }
            .padding(Spacing.sheetEdge)
        }
    }

    /// The footer: "Instalar skill" turns into "Instalada" in place, cross-fading.
    private var footer: some View {
        ZStack {
            footerContent
                .id(installed != nil)
                .transition(.opacity)
        }
        .motion(Motion.content, value: installed != nil)
    }

    /// What the preview shows below its badges, as one value for the animation to follow.
    private struct PreviewPhase: Equatable {
        var isReady: Bool
        var error: String?
    }

    @ViewBuilder private var footerContent: some View {
        if let installed {
            SheetFooterBar {
                Label("Instalada. Use com /\(installed.slug)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ok)
                Spacer()
                Button("Fechar") { dismiss() }
                    .buttonStyle(GhostStyle())
                    .keyboardShortcut(.cancelAction)
                UseSkillButton(skill: installed, onUsed: { dismiss() }, title: "Usar agora")
            }
        } else {
            SheetFooter(message: "Instale só de fontes em que você confia: a skill vira instrução para o Orb.",
                        cancelTitle: "Fechar", cancel: { dismiss() }, primaryTitle: "Instalar skill",
                        isPrimaryDisabled: document == nil) {
                if let document { model.install(document, from: entry) }
            }
        }
    }
}

// MARK: Editor

/// The instructions a skill has today, read-only, in the editor's place.
private struct ReadOnlyInstructions: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.text)
            .foregroundStyle(Palette.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
    }
}

/// The lines that changed, tinted as in the code blocks; the lines that stayed are dimmed.
private struct DiffInstructions: View {
    let lines: [LineDiff.Line]

    var body: some View {
        if lines.allSatisfy({ $0.kind == .same }) {
            Text("A proposta mantém as instruções atuais.")
                .font(Typography.label)
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    // The sign says it too: the state does not rest on color alone.
                    let sign = line.kind == .added ? "+ " : line.kind == .removed ? "− " : "  "
                    Text(sign + line.text)
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(line.kind == .same ? Palette.muted : Palette.ink)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.kind == .added ? Palette.codeAdded.opacity(0.18)
                                    : line.kind == .removed ? Palette.codeRemoved.opacity(0.18) : .clear)
                        .accessibilityLabel((line.kind == .added ? "Adicionada: " : line.kind == .removed ? "Removida: " : "") + line.text)
                }
            }
            .textSelection(.enabled)
        }
    }
}

struct SkillEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var skill: Skill
    /// Whether the shortcut was typed by the user (until then it follows the name).
    @State private var slugEdited: Bool
    /// The skill an Orb proposed, which this editor shows whole for you to save or discard (nil: a skill of yours).
    let proposal: SkillDraft?
    /// What the instructions area shows while an improvement is reviewed: the proposed text, the current one or the difference.
    enum ReviewView: String, CaseIterable { case new = "Nova", current = "Atual", changes = "Mudanças" }
    @State private var reviewView = ReviewView.new

    /// Beyond this many characters the instructions weigh on every conversation that uses the skill.
    static let longInstructions = 4_000

    init(skill: Skill, proposal: SkillDraft? = nil) {
        _skill = State(initialValue: skill)
        _slugEdited = State(initialValue: !skill.slug.isEmpty)
        self.proposal = proposal
    }

    /// The text an improvement would replace (nil for a new skill or when the skill is gone).
    private var currentInstructions: String? {
        guard let proposal, proposal.isUpdate else { return nil }
        return model.skills.first { $0.slug == proposal.slug && $0.isImprovable }?.instructions
    }
    private var isNew: Bool { !model.skills.contains { $0.id == skill.id } }
    private var finalSlug: String { Skill.cleanSlug(skill.slug) }
    private var slugTaken: Bool { model.skills.contains { $0.slug == finalSlug && $0.id != skill.id } }
    private var chosenNoOrb: Bool { skill.orbIDs.isEmpty }
    private var canSave: Bool {
        !skill.name.trimmingCharacters(in: .whitespaces).isEmpty && !finalSlug.isEmpty
            && !skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !slugTaken && !chosenNoOrb
    }
    private var message: String? {
        if slugTaken { return "Já existe uma skill com /\(finalSlug)." }
        if chosenNoOrb { return "Marque ao menos um Orb em “Usar com”." }
        return nil
    }
    private var title: String {
        if let proposal { return proposal.isUpdate ? "Melhoria de \(SkillText.displayName(skill.name))" : "Skill proposta" }
        return isNew ? "Nova skill" : "Editar \(skill.name.isEmpty ? "skill" : skill.name)"
    }
    private var subtitle: String {
        guard let proposal else { return "Instruções que o Orb segue quando você começa a mensagem com o comando." }
        return proposal.isUpdate ? "\(proposal.orbName) aprendeu isso fazendo a tarefa. Substitui as instruções atuais de /\(proposal.slug)."
            : "\(proposal.orbName) aprendeu isso fazendo a tarefa. Revise antes de salvar."
    }

    var body: some View {
        Form {
            Section {
                TextField("Nome", text: $skill.name, prompt: Text("ex.: Resumir"))
                    .onChange(of: skill.name) {
                        skill.slug = Skill.suggestedSlug(forName: skill.name, current: skill.slug, edited: slugEdited)
                    }
                // The slash sits in the field's text, so the value lines up with the other rows.
                LabeledContent("Comando") {
                    TextField("Comando", text: Binding(
                        get: { skill.slug.isEmpty ? "" : "/" + skill.slug },
                        set: { skill.slug = String($0.drop { $0 == "/" }) }
                    ), prompt: Text("/resumir"))
                        .labelsHidden()
                        .font(.system(size: 13).monospaced())
                        .multilineTextAlignment(.trailing)
                        .onChange(of: skill.slug) {
                            let cleaned = Skill.slugify(skill.slug)
                            if cleaned != skill.slug { skill.slug = cleaned }
                            slugEdited = !cleaned.isEmpty && cleaned != Skill.cleanSlug(skill.name)
                        }
                }
                // Grows to three lines: a proposed summary is a sentence and was cut off in one.
                TextField("O que faz", text: $skill.summary, prompt: Text("ex.: Resume um texto em 5 tópicos"), axis: .vertical)
                    .lineLimit(1...3)
            } footer: { FormFootnote {
                VStack(alignment: .leading, spacing: 4) {
                    Text(finalSlug.isEmpty ? "O comando é o que você escreve no chat para usar a skill."
                         : "Para usar, escreva /\(finalSlug) no começo da mensagem no chat.")
                        .textSwap(finalSlug.isEmpty)
                    // A catalog skill is edited as a copy: the repository is not touched, and what changes stays here.
                    if let note = SkillBadge.catalogNote(for: skill) { Text(note) }
                }
            } }
            Section {
                if let current = currentInstructions {
                    Picker("Ver", selection: $reviewView) {
                        ForEach(ReviewView.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Compare a proposta com as instruções que a skill tem hoje")
                    switch reviewView {
                    case .new: instructionsEditor
                    case .current: ReadOnlyInstructions(text: current)
                    case .changes: DiffInstructions(lines: LineDiff.lines(old: current, new: skill.instructions))
                    }
                } else {
                    instructionsEditor
                }
            } header: {
                Text("Instruções para o Orb")
            } footer: { FormFootnote {
                HStack(spacing: 0) {
                    if skill.instructions.count > Self.longInstructions {
                        Text("Instruções longas gastam contexto em toda conversa que usar a skill. ")
                            .foregroundStyle(Palette.warn)
                            .transition(.quiet)
                    }
                    Spacer(minLength: 8)
                    Text("\(skill.instructions.count.formatted(.number.locale(.app))) caracteres").monospacedDigit()
                }
            } }
            Section {
                OrbScopePicker(scoped: $skill.orbIDs, noun: "esta skill")
            } header: {
                Text("Usar com")
            }
        }
        .formStyle(.grouped)
        .orbSheet(title, subtitle: subtitle, size: .medium) {
            if let proposal {
                // Esc and "Fechar" leave the proposal waiting; only "Descartar" throws it away.
                SheetFooter(message: message, destructiveTitle: "Descartar proposta", destructive: {
                    model.finishSkillDraft(proposal)
                    dismiss()
                }, cancelTitle: "Decidir depois", cancel: { dismiss() }, primaryTitle: "Salvar skill", isPrimaryDisabled: !canSave,
                destructiveHelp: Tip.discardProposal, cancelHelp: Tip.keepProposal, primaryHelp: Tip.saveProposal, primary: save)
            } else {
                SheetFooter(message: message, cancel: { dismiss() }, primaryTitle: "Salvar", isPrimaryDisabled: !canSave, primary: save)
            }
        }
    }

    private var instructionsEditor: some View {
        PlaceholderTextEditor(placeholder: "Quando eu pedir /\(finalSlug.isEmpty ? "resumir" : finalSlug), leia o texto e responda em 5 tópicos curtos.",
                              text: $skill.instructions, minHeight: proposal == nil ? 100 : 260)
    }

    private func save() {
        skill.slug = finalSlug
        skill.name = skill.name.trimmingCharacters(in: .whitespaces)
        if let index = model.skills.firstIndex(where: { $0.id == skill.id }) {
            // Only what the editor edits: the count of uses and the rest may have changed while the sheet was open.
            model.skills[index] = model.skills[index].applyingEdits(from: skill)
        } else {
            model.skills.append(skill)
        }
        if let proposal { model.finishSkillDraft(proposal, saved: skill) }
        dismiss()
    }
}
