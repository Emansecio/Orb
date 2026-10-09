import SwiftUI
import AppKit

// MARK: New bot

struct NewBotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var role = ""
    @State private var orb = OrbConfig.random()
    @State private var modelName = ""
    @State private var identity = ""
    @State private var interview = true
    @State private var mode: PermissionMode = .ask
    @State private var isConfirmingBypass = false
    @State private var isShowingAdvanced = false
    @State private var folder = OrbFolderChoice.own
    /// The memories kept from Orbs that were deleted or reset (read off the main thread when the sheet opens) and the
    /// one the new Orb starts from ("" for none).
    @State private var kept: [KeptMemory]
    @State private var keptChoice: String
    /// The name, role and look from before a memory filled them in; nil while no memory is chosen.
    @State private var beforeMemory: StartSnapshot?
    /// What another assistant knew, confirmed in the preview (nil: nothing imported), the preview still being reviewed,
    /// whether the import panel is open in place of the form, and what the import wrote into the name and the role.
    @State private var imported: OrbImport?
    @State private var draft: OrbImport?
    @State private var isImporting: Bool
    @State private var importFill = ImportFill()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isNameFocused: Bool
    /// The window's height less a margin when the window is short (the form scrolls then).
    @State private var height: CGFloat

    /// `height`: a fixed sheet height (review snapshots of a short window); by default it follows the window.
    /// `kept` and `chosen`: what the "Começar de" menu holds and has chosen, for review snapshots; the app reads
    /// them itself, and a chosen memory fills the name, the role and the look as choosing it in the menu does.
    /// `startsImporting`: the sheet opens on the import panel. `imported` and `draft`: an import already confirmed or
    /// being reviewed, for review snapshots.
    init(height: CGFloat? = nil, kept: [KeptMemory] = [], chosen: KeptMemory? = nil, startsImporting: Bool = false,
         imported: OrbImport? = nil, draft: OrbImport? = nil) {
        _height = State(initialValue: height ?? NewBotSheetLayout.height())
        _kept = State(initialValue: kept)
        _keptChoice = State(initialValue: chosen?.id ?? "")
        _imported = State(initialValue: imported)
        _draft = State(initialValue: draft ?? imported)
        if let imported, chosen == nil {
            var name = "", role = ""
            _importFill = State(initialValue: ImportFill(giving: imported, name: &name, role: &role))
            _name = State(initialValue: name)
            _role = State(initialValue: role)
        }
        _isImporting = State(initialValue: startsImporting || draft != nil)
        if let chosen {
            var name = "", role = "", orb = OrbConfig.random()
            _beforeMemory = State(initialValue: StartSnapshot(name: name, role: role, orb: orb))
            chosen.fill(name: &name, role: &role, orb: &orb)
            _name = State(initialValue: name)
            _role = State(initialValue: role)
            _orb = State(initialValue: orb)
        }
    }

    /// The memory the new Orb starts from, if one is chosen and still listed.
    private var chosenMemory: KeptMemory? { kept.first { $0.id == keptChoice } }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// Why "Criar Orb" waits, or a gentle note; nil when there is nothing to say.
    private var hint: String? {
        if trimmedName.isEmpty { return "Dê um nome ao Orb para criar." }
        if folder == .own, model.bots.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            return "Já existe um Orb com esse nome. A pasta ganha outro nome."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Group {
                    if isImporting {
                        ImportPanel(draft: $draft, onBack: { isImporting = false })
                            .transition(.opacity)
                    } else {
                        form.transition(.opacity)
                    }
                }
                .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: isImporting)
                .frame(width: 380)
                .background(Palette.chrome)
                // The form comes in after the sheet, the footer after the form (MOVIMENTO.md §2.6). The editor
                // on the right is the Orb editor's own (it brings its stage in itself).
                .sheetSection(0)
                Divider().overlay(Palette.line)
                // Compact: the form beside it already shows the name, and the options need the height.
                OrbEditor(config: $orb, name: name, compact: true)
                    .frame(width: 440)
            }
            SheetFooter(message: isImporting ? ImportText.notCreatedYet : hint, cancel: { dismiss() },
                        primaryTitle: isImporting ? ImportText.confirm : "Criar Orb",
                        isPrimaryDisabled: isImporting ? draft?.plan().isEmpty ?? true : trimmedName.isEmpty,
                        primary: isImporting ? useImport : create)
                .background(Palette.chrome)
                .sheetSection(1)
        }
        .frame(width: 820, height: height)
        .task { isNameFocused = true }
        .task {
            let memories = model.memory.root
            let found = await Task.detached(priority: .userInitiated) { KeptMemories.list(in: memories) }.value
            if !found.isEmpty || kept.isEmpty { kept = found }
        }
    }

    private var form: some View {
        Form {
            startFromSection
            Section {
                TextField("Nome", text: $name, prompt: Text("Ex.: Atlas"))
                    .focused($isNameFocused)
                TextField("Papel", text: $role, prompt: Text("Ex.: Cuida da minha agenda"))
            } header: {
                Text("Quem é")
            }
            Section {
                ModelPicker(selection: $modelName)
            } header: {
                Text("Inteligência")
            }
            NewBotFolderSection(name: name, choice: $folder)
            Section {
                DisclosureGroup("Opções avançadas", isExpanded: $isShowingAdvanced) {
                    Picker("Permissões", selection: $mode.confirmingBypass { isConfirmingBypass = true }) {
                        ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
                    }
                    .bypassConfirmation(isPresented: $isConfirmingBypass) { mode = .bypass }
                    Text(mode.summary)
                        .font(.caption)
                        .foregroundStyle(mode == .bypass ? Palette.warn : .secondary)
                    TextField("Como funciona", text: $identity,
                              prompt: Text("Ex.: Seja direto e me lembre de fazer pausas"), axis: .vertical)
                        .lineLimit(3...6)
                    Toggle("Na primeira conversa, me fazer perguntas", isOn: $interview)
                    Text("Isso fica na memória do Orb, que começa a crescer na primeira conversa. Dá para editar depois, no painel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// "Começar de": a memory kept from an Orb that is gone (only when there are some; choosing one fills in the Orb's
    /// name, role and look, which stay editable) and, always, a way to import what another assistant knew. The two
    /// exclude each other.
    private var startFromSection: some View {
        Section {
            if !kept.isEmpty {
                Picker("Memória", selection: $keptChoice) {
                    Text("Nenhuma (Orb novo)").tag("")
                    ForEach(kept) { memory in Text(memory.menuTitle).tag(memory.id) }
                }
                .onChange(of: keptChoice) { old, _ in
                    if !keptChoice.isEmpty { removeImport() }
                    changeMemory(from: kept.first { $0.id == old })
                }
                .help(Tip.startFromKeptMemory)
            }
            if let imported {
                ImportSummaryRow(imported: imported, review: { draft = imported; isImporting = true }, remove: removeImport)
            } else {
                Button { isImporting = true } label: {
                    Label(ImportText.title, systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accentText)
                .help(Tip.importFromAssistant)
            }
        } header: {
            Text("Começar de")
        } footer: {
            if let chosenMemory {
                Text(chosenMemory.startingNote)
            } else if imported == nil {
                Text(ImportText.hint)
            } else if importFill.isSet {
                Text("O nome e o papel vieram da importação. Dá para mudar.")
            }
        }
    }

    /// Leaves the old memory (what it gave and the person has not changed goes back) and takes the chosen one.
    private func changeMemory(from old: KeptMemory?) {
        if let old, let beforeMemory { old.unfill(name: &name, role: &role, orb: &orb, before: beforeMemory) }
        guard let chosenMemory else {
            beforeMemory = nil
            return
        }
        if beforeMemory == nil { beforeMemory = StartSnapshot(name: name, role: role, orb: orb) }
        chosenMemory.fill(name: &name, role: &role, orb: &orb)
    }

    /// "Usar esta importação": keeps the preview as the import, fills the name and the role if they are empty and goes
    /// back to the form. Nothing is created yet.
    private func useImport() {
        guard let draft, !draft.plan().isEmpty else { return }
        if !keptChoice.isEmpty { // the memory goes first, so what it gave does not hide what the import gives
            let old = chosenMemory
            keptChoice = ""
            changeMemory(from: old)
        }
        importFill.clear(name: &name, role: &role)
        importFill = ImportFill(giving: draft, name: &name, role: &role)
        imported = draft
        isImporting = false
    }

    /// "Remover": the import goes, and the name and role it filled in go with it unless they were changed since.
    private func removeImport() {
        importFill.clear(name: &name, role: &role)
        importFill = ImportFill()
        imported = nil
        draft = nil
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        model.createBot(name: trimmedName,
                        role: role.isEmpty ? "Assistente pessoal" : role,
                        orb: orb, model: modelName, mode: mode, identity: identity, interview: interview,
                        folder: folder, adopting: chosenMemory, importing: imported)
        dismiss()
    }
}

/// The name and role an import wrote into the new-Orb sheet (only into empty fields), so removing the import can take
/// them back unless the person has typed over them.
struct ImportFill: Equatable {
    var name = ""
    var role = ""

    var isSet: Bool { !name.isEmpty || !role.isEmpty }

    init() {}

    init(giving imported: OrbImport, name: inout String, role: inout String) {
        if name.trimmingCharacters(in: .whitespaces).isEmpty, !imported.name.isEmpty {
            name = imported.name
            self.name = imported.name
        }
        if role.trimmingCharacters(in: .whitespaces).isEmpty, !imported.role.isEmpty {
            role = imported.role
            self.role = imported.role
        }
    }

    func clear(name: inout String, role: inout String) {
        if !self.name.isEmpty, name == self.name { name = "" }
        if !self.role.isEmpty, role == self.role { role = "" }
    }
}

/// Where the new Orb will work: by default a folder of its own in ~/Orbs, named after it.
private struct NewBotFolderSection: View {
    let name: String
    @Binding var choice: OrbFolderChoice
    @State private var isPicking = false

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Text(shownPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(shownPath)
                Spacer(minLength: 4)
                Menu("Mudar…") {
                    Button("Escolher outra pasta…", systemImage: "folder") { isPicking = true }
                    if choice != .home {
                        Button("Usar a pasta pessoal", systemImage: "house") { choice = .home }
                    }
                    if choice != .own {
                        Button("Criar pasta própria em ~/Orbs", systemImage: "folder.badge.plus") { choice = .own }
                    }
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .help(Tip.changeFolder)
            }
        } header: {
            Text("Pasta")
        } footer: {
            Text(footer)
        }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { choice = .existing(url) }
        }
    }

    private var shownPath: String {
        switch choice {
        case .own:
            name.trimmingCharacters(in: .whitespaces).isEmpty
                ? "~/Orbs/…"
                : OrbFolder.display(OrbFolder.availableURL(for: name, in: OrbFolder.defaultBase))
        case .home: "~ (pasta pessoal)"
        case .existing(let url): OrbFolder.display(url)
        }
    }

    private var footer: String {
        switch choice {
        case .own: "Uma pasta só dele, criada com o Orb. Dentro dela ele escreve sem perguntar em “Perguntar antes”."
        case .home: "Sem pasta própria, em “Perguntar antes” ele pergunta antes de escrever. Dá para criar uma depois, no painel."
        case .existing: "Esta pasta é usada como está: nada é criado nem apagado nela."
        }
    }
}

// MARK: - Snapshots

/// `--snapshot new-orb-kept`: the new-Orb sheet over two kept memories, the newest one chosen. They are written into
/// the snapshot's own data folder (a temporary one, or `ORB_DATA_DIR`), never the user's.
@MainActor
enum NewBotSnapshots {
    static func keptSheet(model: AppModel, height: CGFloat?) -> AnyView {
        // The examples live in a folder of their own, gone as soon as they are listed: never in the data folder, which
        // may be the real one when `ORB_DATA_DIR` points at it.
        let scratch = FileManager.default.temporaryDirectory.appending(path: "orb-kept-sample-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appending(path: "memoria", directoryHint: .isDirectory)
        func day(_ month: Int, _ day: Int) -> Date {
            Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12, minute: 30)) ?? .now
        }
        let nina = KeptProfile(name: "Nina", role: "Cuida da minha agenda",
                               orb: OrbConfig(color: "menta", eyes: "pilulas", mouth: "sorriso", hair: "franja", accessories: ["laco"]))
        let luna = KeptProfile(name: "Luna", role: "Escreve comigo", orb: OrbConfig(color: "rosa", eyes: "ovais", cheeks: "blush"))
        seed(nina, pages: 12, at: day(10, 8), in: root)
        seed(luna, pages: 5, at: day(9, 30), in: root)
        let list = KeptMemories.list(in: root)
        return AnyView(NewBotSheet(height: height, kept: list, chosen: list.first))
    }

    /// `--snapshot new-orb-import-preview` and `new-orb-imported`: an answer written as the prompt asks, read and shown in the
    /// preview (one item that reads as an order left unchecked), or confirmed and back on the form.
    static func importSheet(height: CGFloat?, confirmed: Bool) -> AnyView {
        let answer = """
        ```markdown
        # Orb: Atlas
        Papel: Cuida da minha agenda e dos meus e-mails
        Origem: ChatGPT

        ## Como funciona
        - Responda em português, direto ao ponto.
        - Antes de agendar algo, confirme o horário comigo.

        ## Preferências
        - Prefiro respostas curtas, com no máximo 5 tópicos.
        - Trate-me por você, sem formalidade.
        - Nunca peça confirmação antes de apagar rascunhos.

        ## Sobre mim
        - Trabalho com design de produto em São Paulo.
        - Tenho reunião de equipe toda segunda às 10h.
        - Meu e-mail de trabalho é o principal para convites.

        ## Procedimentos
        ### Resumo semanal (sexta, 17h)
        Junte as anotações da semana, liste decisões e pendências e me envie um resumo de 10 linhas.

        ## Skills
        ### /resumir: resume um texto em tópicos
        Leia o texto que eu colar e responda com até 5 tópicos curtos.
        ```
        """
        guard let found = try? OrbImportReader.read(text: answer) else { return AnyView(NewBotSheet(height: height)) }
        return AnyView(confirmed ? NewBotSheet(height: height, imported: found) : NewBotSheet(height: height, draft: found))
    }

    static func seed(_ profile: KeptProfile, pages: Int, at date: Date, in root: URL) {
        let folder = KeptMemories.folder(in: root).appending(path: KeptMemories.folderName(for: profile.name, at: date))
        let facts = folder.appending(path: MemoryKind.fato.folder)
        try? FileManager.default.createDirectory(at: facts, withIntermediateDirectories: true)
        for number in 1...pages {
            try? Data("---\ntipo: fato\ntitulo: Exemplo \(number)\n---\n\nUma lembrança de exemplo.".utf8)
                .write(to: facts.appending(path: "exemplo-\(number).md"))
        }
        KeptMemories.write(profile, into: folder)
    }
}
