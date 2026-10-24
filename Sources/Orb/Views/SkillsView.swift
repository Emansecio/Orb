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
        editing = Skill(slug: "", name: "", summary: "", instructions: "")
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

    private var showsFilter: Bool { model.skills.count >= InstalledSkillFilter.threshold }
    /// A filter typed before the list got short is gone with its field, not kept hiding skills.
    private var activeQuery: String { showsFilter ? query : "" }

    var body: some View {
        @Bindable var model = model
        let visible = $model.skills.filter { InstalledSkillFilter.matches($0.wrappedValue, query: activeQuery) }
        ScrollView {
            VStack(spacing: 8) {
                if showsFilter { filterField }
                if !pending.isEmpty { pendingReview }
                if visible.isEmpty, !model.skills.isEmpty {
                    ContentUnavailableView.search(text: activeQuery)
                }
                LazyVStack(spacing: 8) {
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
            Task { pending = await model.pendingSkillDrafts() }
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

    /// The same field as the catalog's search (without its ⌘F button: the tab bar owns the shortcut).
    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.faint)
            TextField("Filtrar skills instaladas", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused(filterFocused)
            if !query.isEmpty {
                Button("Limpar", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.faint)
                    .help(Tip.clearSearch)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .card(radius: Radius.card, stroke: filterFocused.wrappedValue ? Palette.lineStrong : Palette.line)
        .padding(.bottom, 4)
    }

    /// The skills the Orbs learned and proposed, from every Orb: nothing is saved until you read it and say so.
    private var pendingReview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aguardando sua revisão (\(pending.count))")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
            ForEach(pending) { draft in
                HStack(spacing: 14) {
                    CatalogIcon(symbol: "sparkles")
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(draft.skill.name)
                                .font(.system(size: 14, weight: .semibold))
                            Text("de \(draft.orbName)")
                                .font(Typography.label)
                                .foregroundStyle(Palette.muted)
                        }
                        if draft.isUpdate {
                            CatalogBadge(text: "Melhoria de /\(draft.slug)", symbol: "arrow.triangle.2.circlepath")
                        }
                    }
                    Spacer(minLength: 12)
                    Button("Revisar") { reviewing = draft }
                        .buttonStyle(SecondaryPillStyle())
                        .accessibilityLabel("Revisar \(draft.skill.name), proposta de \(draft.orbName)")
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
    static func origin(of source: String) -> String { source.split(separator: "/").prefix(2).joined(separator: "/") }

    /// What the editor says of a skill that came from the catalog: the copy on this Mac is its own from the first edit.
    /// nil for yours, the app's and the ones an Orb learned.
    static func catalogNote(for skill: Skill) -> String? {
        guard let source = skill.source, source != Skill.builtInSource, source != Skill.learnedSource else { return nil }
        return "Veio de \(origin(of: source)). A edição fica só neste Mac."
    }
}

private struct InstalledSkillRow: View {
    @Environment(AppModel.self) private var model
    @Binding var skill: Skill
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var copied = CopiedFlash()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A switched-off skill dims its icon and title only: the badge says why, and the buttons stay legible.
        let dimmed = skill.isEnabled ? 1.0 : 0.55
        HStack(alignment: .center, spacing: 14) {
            // A click anywhere on this part opens the editor; the copy button here and the controls beside it keep their own.
            HStack(alignment: .center, spacing: 14) {
                CatalogIcon(symbol: skill.source == nil || skill.source == Skill.builtInSource || skill.source == Skill.learnedSource ? "wand.and.stars" : "shippingbox")
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
                            .buttonStyle(.plain)
                            .font(Typography.small)
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
                        if skill.source == Skill.builtInSource {
                            CatalogBadge(text: "Incluída no app", symbol: "circle.hexagongrid")
                        } else if skill.source == Skill.learnedSource {
                            CatalogBadge(text: SkillBadge.learned(by: model.bots.first { $0.id == skill.learnedBy }?.name), symbol: "sparkles")
                        } else if let source = skill.source {
                            CatalogBadge(text: SkillBadge.origin(of: source), symbol: "shippingbox")
                        } else {
                            CatalogBadge(text: "Criada por você", symbol: "person")
                        }
                        if skill.orbIDs != nil {
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
            Spacer(minLength: 12)
            UseSkillButton(skill: skill)
            Toggle("Ativa", isOn: $skill.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help(Tip.skillToggle(isOn: skill.isEnabled))
            Menu {
                Button("Editar…", action: onEdit)
                if let folder = skill.folderURL {
                    Link("Ver no GitHub", destination: folder)
                }
                Divider()
                Button("Apagar…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Tip.moreOptions(of: skill.name))
            .accessibilityLabel("Mais opções de \(skill.name)")
        }
        .padding(Spacing.cardPadding)
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
            VStack(alignment: .leading, spacing: 18) {
                CatalogSearchHeader(query: $query, prompt: "Buscar no catálogo de skills (Skills.sh)",
                                    suggestions: Self.suggestions)
                if !isSearching {
                    intro
                } else if isLoading || error != nil || results.isEmpty {
                    CatalogStateView(isLoading: isLoading, error: error, isEmpty: results.isEmpty, skeleton: true,
                                     retry: { Task { await search() } })
                        .transition(.opacity)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 10, alignment: .top)], spacing: 10) {
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
        defer { if ExploreSearch.accepts(term: term, currentQuery: query) { isLoading = false } }
        do {
            let found = try await SkillCatalog.shared.search(term)
            if !Task.isCancelled, ExploreSearch.accepts(term: term, currentQuery: query) { results = found }
        } catch {
            // A newer search cancels this one; only real failures are shown.
            if !Task.isCancelled, ExploreSearch.accepts(term: term, currentQuery: query) { self.error = error.localizedDescription }
        }
    }
}

enum ExploreSearch {
    /// Whether the answer to a search for `term` still belongs on the page: the field still holds that term (spaces aside).
    static func accepts(term: String, currentQuery: String) -> Bool {
        term == currentQuery.trimmingCharacters(in: .whitespaces)
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
            .padding(12)
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
            VStack(alignment: .leading, spacing: 14) {
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
                        VStack(alignment: .leading, spacing: 14) {
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
                            MarkdownChunk(source: document.instructions).equatable()
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.raised, in: .rect(cornerRadius: Radius.medium))
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
            .padding(20)
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

struct SkillEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var skill: Skill
    /// Whether the shortcut was typed by the user (until then it follows the name).
    @State private var slugEdited: Bool
    /// The skill an Orb proposed, which this editor shows whole for you to save or discard (nil: a skill of yours).
    let proposal: SkillDraft?

    /// Beyond this many characters the instructions weigh on every conversation that uses the skill.
    static let longInstructions = 4_000

    init(skill: Skill, proposal: SkillDraft? = nil) {
        _skill = State(initialValue: skill)
        _slugEdited = State(initialValue: !skill.slug.isEmpty)
        self.proposal = proposal
    }

    private var isNew: Bool { !model.skills.contains { $0.id == skill.id } }
    private var finalSlug: String { Skill.cleanSlug(skill.slug) }
    private var slugTaken: Bool { model.skills.contains { $0.slug == finalSlug && $0.id != skill.id } }
    private var chosenNoOrb: Bool { skill.orbIDs?.isEmpty == true }
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
        if let proposal { return proposal.isUpdate ? "Melhoria de \(skill.name)" : "Skill proposta" }
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
                TextField("O que faz", text: $skill.summary, prompt: Text("ex.: Resume um texto em 5 tópicos"))
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
                PlaceholderTextEditor(placeholder: "Quando eu pedir /\(finalSlug.isEmpty ? "resumir" : finalSlug), leia o texto e responda em 5 tópicos curtos.",
                                      text: $skill.instructions, minHeight: proposal == nil ? 100 : 260)
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
                OrbScopePicker(orbIDs: $skill.orbIDs, noun: "esta skill")
            } header: {
                Text("Usar com")
            }
        }
        .formStyle(.grouped)
        .orbSheet(title, subtitle: subtitle, size: .medium) {
            if let proposal {
                // Esc and "Fechar" leave the proposal waiting; only "Descartar" throws it away.
                SheetFooter(message: message, destructiveTitle: "Descartar", destructive: {
                    model.finishSkillDraft(proposal)
                    dismiss()
                }, cancelTitle: "Fechar", cancel: { dismiss() }, primaryTitle: "Salvar skill", isPrimaryDisabled: !canSave,
                destructiveHelp: Tip.discardProposal, cancelHelp: Tip.keepProposal, primaryHelp: Tip.saveProposal, primary: save)
            } else {
                SheetFooter(message: message, cancel: { dismiss() }, primaryTitle: "Salvar", isPrimaryDisabled: !canSave, primary: save)
            }
        }
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
