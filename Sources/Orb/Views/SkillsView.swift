import SwiftUI
import AppKit

/// Skills: the installed ones (use, enable, edit, delete) and the public catalog (search, preview, install).
struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: CatalogTab
    @State private var editing: Skill?

    init(tab: CatalogTab = .installed) {
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            CatalogTabBar(tab: $tab, installedTitle: "Instaladas", installedCount: model.skills.count)
                .padding(.top, 16)
                .padding(.bottom, 4)
            switch tab {
            case .installed: InstalledSkills(editing: $editing, explore: { tab = .explore })
            case .explore: ExploreSkills()
            }
        }
        .background(Palette.canvas)
        .navigationTitle("Skills")
        .navigationSubtitle("Instruções prontas: comece a mensagem com /nome")
        .toolbar {
            Button("Nova skill", systemImage: "plus") {
                editing = Skill(slug: "", name: "", summary: "", instructions: "")
            }
            .help("Criar uma skill sua")
        }
        .sheet(item: $editing) { skill in
            SkillEditor(skill: skill)
        }
    }
}

// MARK: Using a skill

/// "Usar": opens the chat of the Orb the user was on with `/atalho ` ready in the composer (one click); with no
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
                .help("Abrir a conversa com \(preferred.name) com /\(skill.slug) pronto")
                .disabled(!skill.isEnabled)
        } else if candidates.isEmpty {
            Button(title) {}
                .buttonStyle(SecondaryPillStyle())
                .disabled(true)
                .help("Nenhum Orb pode usar esta skill")
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
            .help("Escolher o Orb que vai usar /\(skill.slug)")
        }
    }

    private func use(_ bot: Bot) {
        model.useSkill(skill, with: bot.id)
        onUsed()
    }
}

// MARK: Installed

private struct InstalledSkills: View {
    @Environment(AppModel.self) private var model
    @Binding var editing: Skill?
    let explore: () -> Void
    @State private var deleting: Skill?

    var body: some View {
        @Bindable var model = model
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach($model.skills) { $skill in
                    InstalledSkillRow(skill: $skill) {
                        editing = skill
                    } onDelete: {
                        deleting = skill
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if model.skills.isEmpty {
                ContentUnavailableView {
                    Label("Nenhuma skill instalada", systemImage: "wand.and.stars")
                } description: {
                    Text("Encontre skills prontas no catálogo ou crie a sua.")
                } actions: {
                    Button("Explorar catálogo", action: explore).buttonStyle(PrimaryPillStyle())
                }
            }
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
}

/// What the delete dialog of a skill promises: only what is true for where the skill came from.
enum SkillDeleteCopy {
    static func message(for skill: Skill) -> String {
        switch skill.source {
        case nil: "As instruções que você escreveu serão apagadas. Não dá para desfazer."
        case Skill.builtInSource?: "Ela vem com o app e não volta sozinha depois de apagada. Você pode escrever outra com o mesmo atalho."
        default: "Você pode instalar de novo pelo catálogo depois."
        }
    }
}

private struct InstalledSkillRow: View {
    @Environment(AppModel.self) private var model
    @Binding var skill: Skill
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            CatalogIcon(symbol: skill.source == nil || skill.source == Skill.builtInSource ? "wand.and.stars" : "shippingbox")
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text("/\(skill.slug)")
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(Palette.muted)
                    Button(didCopy ? "Copiado" : "Copiar /\(skill.slug)", systemImage: didCopy ? "checkmark" : "doc.on.doc", action: copy)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(didCopy ? Palette.ok : Palette.faint)
                        .help("Copiar /\(skill.slug)")
                }
                if !skill.summary.isEmpty {
                    Text(skill.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if skill.source == Skill.builtInSource {
                        CatalogBadge(text: "Incluída no app", symbol: "circle.hexagongrid")
                    } else if let source = skill.source {
                        CatalogBadge(text: source.split(separator: "/").prefix(2).joined(separator: "/"), symbol: "shippingbox")
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
            Spacer(minLength: 12)
            UseSkillButton(skill: skill)
            Toggle("Ativa", isOn: $skill.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help(skill.isEnabled ? "Desativar (fica instalada, mas não pode ser usada)" : "Ativar")
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
            .accessibilityLabel("Mais ações de \(skill.name)")
        }
        .padding(14)
        .card(radius: 14)
        .opacity(skill.isEnabled ? 1 : 0.55)
        .animation(.snappy(duration: 0.2), value: skill.isEnabled)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("/\(skill.slug)", forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
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
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12, alignment: .top)], spacing: 12) {
                        ForEach(results) { entry in
                            CatalogSkillCard(entry: entry) { previewing = entry }
                        }
                    }
                }
            }
            .animateChanges(of: isLoading)
            .padding(24)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
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
            Text("As skills vêm do catálogo aberto Skills.sh e o conteúdo é de quem publicou, no GitHub. Você lê as instruções antes de instalar e depois usa com /atalho no chat.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 14)
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { results = []; return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let found = try await SkillCatalog.shared.search(term)
            if !Task.isCancelled { results = found }
        } catch {
            // A newer search cancels this one; only real failures are shown.
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

private struct CatalogSkillCard: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogSkill
    let onOpen: () -> Void
    @State private var document: SkillDocument?
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
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
                            .help("Instalada")
                    }
                }
                Group {
                    if let document {
                        Text(document.description.isEmpty ? "Sem descrição." : document.description)
                    } else {
                        // Static: a grid of cards loading at once shouldn't run a shimmer each.
                        Text("Carregando descrição…").foregroundStyle(Palette.faint)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .lineLimit(3, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animateChanges(of: document == nil)
                HStack(spacing: 6) {
                    if entry.isFromKnownSource {
                        CatalogBadge(text: "Fonte conhecida", symbol: "checkmark.seal.fill", tint: Palette.accentText)
                    }
                    CatalogBadge(text: entry.installs.installsLabel, symbol: "arrow.down.circle")
                }
            }
            .padding(14)
            .card(radius: 14, fill: isHovering ? Palette.raised : Palette.surface,
                  stroke: isHovering ? Palette.lineStrong : Palette.line)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .task { document = try? await SkillCatalog.shared.document(for: entry) }
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
            .task {
                guard document == nil else { return }
                do {
                    document = try await SkillCatalog.shared.document(for: entry)
                } catch {
                    self.error = error.localizedDescription
                }
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
                if let document {
                    if !document.description.isEmpty {
                        Text(document.description)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.secondary)
                    }
                    Text("Instruções que o Orb vai seguir")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .textCase(.uppercase)
                    Text(document.instructions)
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(Palette.secondary)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.raised, in: .rect(cornerRadius: 10))
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.warn)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder private var footer: some View {
        if let installed {
            HStack(spacing: 10) {
                Label("Instalada. Use com /\(installed.slug)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ok)
                Spacer()
                Button("Fechar") { dismiss() }
                    .buttonStyle(GhostStyle())
                    .keyboardShortcut(.cancelAction)
                UseSkillButton(skill: installed, onUsed: { dismiss() }, title: "Usar agora")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Divider().opacity(0.6) }
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

    /// Beyond this many characters the instructions weigh on every conversation that uses the skill.
    static let longInstructions = 4_000

    init(skill: Skill) {
        _skill = State(initialValue: skill)
        _slugEdited = State(initialValue: !skill.slug.isEmpty)
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
    private var title: String { isNew ? "Nova skill" : "Editar \(skill.name.isEmpty ? "skill" : skill.name)" }

    var body: some View {
        Form {
            Section {
                TextField("Nome", text: $skill.name, prompt: Text("ex.: Resumir"))
                    .onChange(of: skill.name) {
                        skill.slug = Skill.suggestedSlug(forName: skill.name, current: skill.slug, edited: slugEdited)
                    }
                // The slash sits in the field's text, so the value lines up with the other rows.
                LabeledContent("Atalho") {
                    TextField("Atalho", text: Binding(
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
            } footer: {
                Text(finalSlug.isEmpty ? "O atalho é o que você escreve no chat para usar a skill."
                     : "Para usar, escreva /\(finalSlug) no começo da mensagem no chat.")
            }
            Section {
                PlaceholderTextEditor(placeholder: "Quando eu pedir /\(finalSlug.isEmpty ? "resumir" : finalSlug), leia o texto e responda em 5 tópicos curtos.",
                                      text: $skill.instructions, minHeight: 100)
            } header: {
                Text("Instruções para o Orb")
            } footer: {
                HStack(spacing: 0) {
                    if skill.instructions.count > Self.longInstructions {
                        Text("Instruções longas gastam contexto em toda conversa que usar a skill. ")
                            .foregroundStyle(Palette.warn)
                    }
                    Spacer(minLength: 8)
                    Text("\(skill.instructions.count.formatted()) caracteres").monospacedDigit()
                }
            }
            Section {
                OrbScopePicker(orbIDs: $skill.orbIDs, noun: "esta skill")
            } header: {
                Text("Usar com")
            }
        }
        .formStyle(.grouped)
        .orbSheet(title, subtitle: "Instruções que o Orb segue quando você começa a mensagem com o atalho.", size: .medium) {
            SheetFooter(message: message, cancel: { dismiss() }, primaryTitle: "Salvar", isPrimaryDisabled: !canSave, primary: save)
        }
    }

    private func save() {
        skill.slug = finalSlug
        skill.name = skill.name.trimmingCharacters(in: .whitespaces)
        if let index = model.skills.firstIndex(where: { $0.id == skill.id }) {
            model.skills[index] = skill
        } else {
            model.skills.append(skill)
        }
        dismiss()
    }
}
