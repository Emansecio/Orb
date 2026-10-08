import SwiftUI

/// Skills: the installed ones (enable, edit, delete) and the public catalog (search, preview, install).
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
        .navigationSubtitle("Instruções reutilizáveis: comece a mensagem com /nome")
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
            Text("Você pode instalar de novo pelo catálogo depois.")
        }
    }
}

private struct InstalledSkillRow: View {
    @Binding var skill: Skill
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CatalogIcon(symbol: skill.source == nil || skill.source == Skill.builtInSource ? "wand.and.stars" : "shippingbox")
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(skill.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text("/\(skill.slug)")
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(Palette.faint)
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
                    if skill.uses > 0 {
                        CatalogBadge(text: skill.uses == 1 ? "1 uso" : "\(skill.uses) usos")
                    }
                }
            }
            Spacer(minLength: 12)
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
        }
        .padding(14)
        .card(radius: 14)
        .opacity(skill.isEnabled ? 1 : 0.55)
        .animation(.snappy(duration: 0.2), value: skill.isEnabled)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CatalogSearchHeader(query: $query, prompt: "Buscar no catálogo de skills (Skills.sh)",
                                    suggestions: Self.suggestions)
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    Text("Escolha um tema acima ou digite o que precisa. As skills vêm do catálogo aberto Skills.sh e o conteúdo, do GitHub de quem publicou.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.faint)
                } else if isLoading || error != nil || results.isEmpty {
                    CatalogStateView(isLoading: isLoading, error: error, isEmpty: results.isEmpty, retry: { Task { await search() } })
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12)], spacing: 12) {
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
        .onAppear { if query.isEmpty { query = Self.suggestions[0] } }
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

/// Review before installing: who published it, what it says, and the full instructions the bot will follow.
private struct SkillPreview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: CatalogSkill
    @State private var document: SkillDocument?
    @State private var error: String?

    private var installed: Skill? { model.installedSkill(entry.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                CatalogIcon(symbol: "wand.and.stars")
                VStack(alignment: .leading, spacing: 6) {
                    Text(document?.name ?? entry.name)
                        .font(.system(size: 17, weight: .semibold))
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
                }
            }
            .padding(20)

            Divider().overlay(Palette.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let document {
                        if !document.description.isEmpty {
                            Text(document.description)
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.secondary)
                        }
                        Text("Instruções que o Orb vai seguir")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.faint)
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

            Divider().overlay(Palette.line)

            HStack(spacing: 10) {
                Label("Instale só de fontes em que você confia: a skill vira instrução para o Orb.", systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
                Spacer()
                Button("Fechar") { dismiss() }
                    .buttonStyle(GhostStyle())
                    .keyboardShortcut(.cancelAction)
                if installed != nil {
                    Label("Instalada", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ok)
                } else {
                    Button("Instalar skill") {
                        if let document { model.install(document, from: entry) }
                        dismiss()
                    }
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(document == nil)
                }
            }
            .padding(16)
        }
        .frame(width: 620, height: 640)
        .background(Palette.chrome)
        .task {
            do {
                document = try await SkillCatalog.shared.document(for: entry)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: Editor

private struct SkillEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var skill: Skill

    private var slugTaken: Bool { model.skills.contains { $0.slug == skill.slug && $0.id != skill.id } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Nome", text: $skill.name)
                TextField("Atalho", text: $skill.slug, prompt: Text("ex.: resumir"))
                    .onChange(of: skill.slug) { skill.slug = Skill.slugify(skill.slug) }
                TextField("O que faz", text: $skill.summary)
                Section {
                    TextEditor(text: $skill.instructions).font(.body).frame(minHeight: 160)
                } header: {
                    Text("Instruções para o Orb")
                } footer: {
                    if slugTaken { Text("Já existe uma skill com /\(skill.slug).").foregroundStyle(Palette.warn) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salvar") {
                    if let index = model.skills.firstIndex(where: { $0.id == skill.id }) {
                        model.skills[index] = skill
                    } else {
                        model.skills.append(skill)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(skill.name.isEmpty || skill.slug.isEmpty || skill.instructions.isEmpty || slugTaken)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
    }
}
