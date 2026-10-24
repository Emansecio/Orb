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
    @State private var isConfirmingDiscard = false
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
    // MARK: MultiOrb (WP4)
    /// The way the person chose to create the Orb; nil until they choose (see `creation`).
    @State private var userMode: OrbCreationMode?
    /// "Quem ele é" or "Aparência". The look (`orb`, random when the sheet opens) is the person's in both ways of creating.
    @State private var tab: NewOrbTab
    /// The sheet was opened to start from a kept memory or an import: those are the form's.
    private let prefersForm: Bool
    /// The parts of the preview washed at the start (review snapshots only).
    private let previewFlashed: Set<DraftField>
    /// The "Criar conversando" assistant. It lives as long as the sheet and writes nothing down until "Criar".
    @State private var wizard: WizardRunner
    /// What the assistant said the Orb may use, carried over when the person switches to "Formulário" (the form has no switches for it).
    @State private var draftCapabilities: Set<Capability>?
    // MARK: end MultiOrb (WP4)

    /// `height`: a fixed sheet height (review snapshots of a short window); by default it follows the window.
    /// `kept` and `chosen`: what the "Começar de" menu holds and has chosen, for review snapshots; the app reads
    /// them itself, and a chosen memory fills the name, the role and the look as choosing it in the menu does.
    /// `startsImporting`: the sheet opens on the import panel. `imported` and `draft`: an import already confirmed or
    /// being reviewed, for review snapshots.
    /// `mode` and `assistant` (MultiOrb, WP4): the way the sheet opens and the assistant it holds, for review snapshots and tests;
    /// the app lets the sheet choose (the assistant when a model is connected) and make its own.
    init(height: CGFloat? = nil, kept: [KeptMemory] = [], chosen: KeptMemory? = nil, startsImporting: Bool = false,
         imported: OrbImport? = nil, draft: OrbImport? = nil, mode: OrbCreationMode? = nil, assistant: WizardRunner? = nil,
         previewFlashed: Set<DraftField> = [], tab: NewOrbTab = .who, look: OrbConfig? = nil) {
        self.previewFlashed = previewFlashed
        _tab = State(initialValue: tab)
        if let look { _orb = State(initialValue: look) }
        _height = State(initialValue: height ?? NewBotSheetLayout.height())
        _userMode = State(initialValue: mode)
        _wizard = State(initialValue: assistant ?? WizardRunner())
        prefersForm = startsImporting || imported != nil || draft != nil || chosen != nil
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

    // MARK: MultiOrb (WP4)
    /// The way the sheet creates the Orb now: the person's choice, else the assistant when a model is connected (and the sheet
    /// was not opened to start from a memory or an import), else the form.
    private var creation: OrbCreationMode {
        userMode ?? OrbCreationMode.initial(canConverse: model.canCreateByConversing, prefersForm: prefersForm)
    }

    /// The assistant is what the sheet shows (the import panel, when open, takes the column instead).
    private var isAssistant: Bool { creation == .assistant && !isImporting }

    /// "Criar conversando | Formulário" at the top of the left column; off, with its reason, while no model is connected.
    private var modePicker: some View {
        // Going from the assistant to the form carries the draft over (name, role, instructions, mode, what it may use).
        // The quiet form of the pills above (`PillTabs`): one kind of switch in the sheet, a step softer for the inner one.
        PillTabs(selection: Binding(get: { creation }, set: { new in
            if new == .form && creation == .assistant { passDraftToForm() } else { userMode = new }
        }), items: OrbCreationMode.allCases.map { .init(value: $0, title: $0.title, symbol: "") }, isQuiet: true)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .disabled(!model.canCreateByConversing)
        .help(model.canCreateByConversing ? "Conversar com o assistente ou preencher o formulário" : OrbCreationMode.needsModel)
        .accessibilityLabel("Como criar o Orb")
        .accessibilityIdentifier("new-orb-mode")
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// "Criar" in the assistant: the Orb the draft describes, and the sheet closes.
    private func createFromAssistant() {
        guard wizard.create(look: orb) != nil else { return } // the look is the person's (`orb`), never the assistant's
        dismiss()
    }

    /// "Sortear": another look, in place (the temperament stays, as in the editor's own dice).
    private func randomLook() {
        var next = OrbConfig.random()
        next.temperament = orb.temperament
        orb = next
    }

    /// What the preview shows in the form: the fields as they are now, as a draft.
    private var formDraft: OrbDraft {
        var draft = OrbDraft()
        draft.name = trimmedName
        draft.role = role.trimmingCharacters(in: .whitespaces)
        // While an import is being reviewed its name and role are not in the fields yet: the preview shows what they would give.
        if isImporting, let reviewed = self.draft {
            if draft.name.isEmpty { draft.name = reviewed.name }
            if draft.role.isEmpty { draft.role = reviewed.role }
        }
        draft.instructions = identity
        draft.mode = mode
        if let draftCapabilities { draft.capabilities = draftCapabilities }
        draft.revision = trimmedName.isEmpty && draft.role.isEmpty ? 0 : 1
        return draft
    }

    /// "Quem ele é | Aparência", full width at the top of the sheet.
    private var tabPicker: some View {
        // The pill switch of the catalog pages. "Criar conversando | Formulário" below is its quiet form (gray, no icons):
        // the same kind of switch, and still a level under this one.
        PillTabs(selection: Binding(get: { tab }, set: { tab = $0 }),
                 items: NewOrbTab.allCases.map { .init(value: $0, title: $0.title, symbol: $0.symbol) })
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Parte do Orb")
        .accessibilityIdentifier("new-orb-tab")
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(Palette.chrome)
        .sheetSection(0)
    }

    /// The preview of "Quem ele é": the assistant's draft, or the form's fields, always with the person's look.
    @ViewBuilder private var previewPane: some View {
        if creation == .assistant {
            WizardPreviewPane(draft: wizard.draft, look: orb, activity: wizard.activity, flashed: previewFlashed,
                              onAdjust: passDraftToForm, onBack: wizard.backToChatting,
                              onDraw: { tab = .look }, onRandom: randomLook)
        } else {
            WizardPreviewPane(draft: formDraft, look: orb, emptyText: "Seu Orb aparece aqui conforme você preenche",
                              onDraw: { tab = .look }, onRandom: randomLook)
        }
    }

    /// What closing the sheet now would lose, or nil when there is nothing to lose (then Cancelar/Esc closes at once).
    static func discardMessage(isAssistant: Bool, userMessages: Int, isFinished: Bool,
                               name: String, role: String, identity: String) -> String? {
        if isAssistant {
            return userMessages >= 1 && !isFinished ? "A conversa com o assistente se perde." : nil
        }
        let typed = [name, role, identity].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return typed ? "O que você preencheu se perde." : nil
    }

    private var pendingLoss: String? {
        Self.discardMessage(isAssistant: isAssistant, userMessages: wizard.userMessageCount, isFinished: wizard.isFinished,
                            name: name, role: role, identity: identity)
    }

    /// Cancelar and Esc: ask first when there is something typed or a conversation to lose.
    private func requestClose() {
        if pendingLoss == nil { dismiss() } else { isConfirmingDiscard = true }
    }

    /// "Formulário" in the mode picker (and the final card's "Ajustar"): the draft fills the form's fields and the form is shown.
    private func passDraftToForm() {
        let draft = wizard.draft
        wizard.stopTalking()
        if !draft.name.isEmpty { name = draft.name }
        if !draft.role.isEmpty { role = draft.role }
        if !draft.instructions.isEmpty { identity = draft.instructions }
        mode = draft.mode // (the look stays the one the person chose)
        draftCapabilities = draft.capabilities
        interview = false // the assistant did the interview
        withAnimation(reduceMotion ? nil : Motion.content) { userMode = .form }
    }
    // MARK: end MultiOrb (WP4)

    var body: some View {
        VStack(spacing: 0) {
            if !isImporting { tabPicker }
            // "Quem ele é" (the assistant or the form, and the preview) or "Aparência" (the editor, the sheet's whole width).
            ZStack {
                if tab == .look && !isImporting {
                    OrbEditor(config: $orb, name: creation == .assistant ? wizard.draft.name : name)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    whoTab.transition(.opacity)
                }
            }
            .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: tab)
            Group {
                if isAssistant {
                    WizardFooter(canCreate: wizard.draft.canCreate, isReady: wizard.draft.ready, hitLimit: wizard.hitLimit, toForm: passDraftToForm,
                                 cancel: requestClose, create: createFromAssistant)
                } else {
                    SheetFooter(message: isImporting ? ImportText.notCreatedYet : hint, cancel: requestClose,
                                primaryTitle: isImporting ? ImportText.confirm : "Criar Orb",
                                isPrimaryDisabled: isImporting ? draft?.plan().isEmpty ?? true : trimmedName.isEmpty,
                                primary: isImporting ? useImport : create)
                }
            }
            .background(Palette.chrome)
            .sheetSection(2)
        }
        .frame(width: 820, height: height)
        .background(Palette.chrome) // one ground under both tabs: the hairline between the columns sits on it, not on the window
        .task { wizard.attach(model) } // MultiOrb (WP4)
        .onDisappear { wizard.cancel() } // MultiOrb (WP4): the sheet closed: the assistant's turn stops, nothing is kept
        .confirmationDialog("Descartar o Orb que você está criando?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Descartar", role: .destructive) { dismiss() }
        } message: {
            Text(pendingLoss ?? "")
        }
        .task { isNameFocused = creation == .form }
        .task {
            let memories = model.memory.root
            let found = await Task.detached(priority: .userInitiated) { KeptMemories.list(in: memories) }.value
            if !found.isEmpty || kept.isEmpty { kept = found }
        }
    }

    /// "Quem ele é": the left column (the assistant's chat, the form or the import panel) and the preview.
    private var whoTab: some View {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if !isImporting { modePicker.transition(.opacity) }
                    if !isImporting && creation == .assistant { assistantImportLink.transition(.opacity) }
                    // A ZStack, not a Group: a Group hands its modifiers to each child, so the form and the import panel
                    // would sit side by side while they swap, and the one coming in would repeat the sheet's entrance.
                    ZStack {
                        if isImporting {
                            ImportPanel(draft: $draft, opensOn: creation == .assistant ? .marketplace : .assistant,
                                        onBack: { isImporting = false })
                                .transition(.opacity)
                        } else if creation == .assistant {
                            WizardChatView(runner: wizard, look: orb).transition(.opacity)
                        } else {
                            form.transition(.opacity)
                        }
                    }
                }
                .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: isImporting)
                .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: creation)
                .frame(width: 380)
                .background(Palette.chrome)
                // The left column comes in just after the tabs, the footer last (MOVIMENTO.md §2.6).
                .sheetSection(1)
                Rectangle().fill(Palette.line).frame(width: 1)
                // The preview, in the assistant and in the form: the Orb with the look the person chose.
                previewPane
                    // Without the tabs over it (the import panel is open) the Orb would touch the sheet's top edge.
                    .padding(.top, isImporting ? 24 : 0)
                    .id(creation)
                    .transition(.opacity)
                    .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: creation)
                    .frame(width: 440)
            }
    }

    /// The import in "Criar conversando", where the form's "Começar de" is not shown: it opens on the Grok Bot gallery.
    private var assistantImportLink: some View {
        Button { isImporting = true } label: {
            Label(ImportText.fromMarketplace, systemImage: "square.and.arrow.down").font(Typography.label)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.accentText)
        .help(Tip.importFromAssistant)
        // Centered under the pills above it, as one header for the chat.
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
                    if let draftCapabilities { // MultiOrb (WP4)
                        Text("Do assistente: " + (draftCapabilities.isEmpty ? "sem ferramentas extras"
                                                  : OrbDraft.offeredCapabilities.filter(draftCapabilities.contains).map(\.label).joined(separator: ", ")))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                    // The Orb on the stage changes look the way it does for an edit; the name and the role change by fading.
                    withAnimation(reduceMotion ? nil : .snappy) {
                        changeMemory(from: kept.first { $0.id == old })
                    }
                }
                .help(Tip.startFromKeptMemory)
            }
            if let imported {
                ImportSummaryRow(imported: imported, review: { draft = imported; isImporting = true }, remove: removeImport)
                    .transition(.quiet)
            } else {
                Button { isImporting = true } label: {
                    Label(ImportText.title, systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accentText)
                .help(Tip.importFromAssistant)
                .transition(.quiet)
            }
        } header: {
            Text("Começar de")
        } footer: { FormFootnote {
            // The footer changes with the choice: one text fades into the other, in the same place.
            ZStack(alignment: .leading) {
                if let chosenMemory {
                    Text(chosenMemory.startingNote).transition(.opacity)
                } else if imported == nil {
                    Text(ImportText.hint).transition(.opacity)
                } else if importFill.isSet {
                    Text("O nome e o papel vieram da importação. Dá para mudar.").transition(.opacity)
                }
            }
            .motion(Motion.content, value: footerKey)
        } }
    }

    /// Which of the "Começar de" footers shows (what its change animates).
    private var footerKey: String {
        if let chosenMemory { return "memoria-\(chosenMemory.id)" }
        if imported == nil { return "dica" }
        return importFill.isSet ? "importou" : "nada"
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
        if creation == .assistant { // the import shows (and is created) in the form
            wizard.stopTalking()
            userMode = .form
        }
    }

    /// "Remover": the import goes, and the name and role it filled in go with it unless they were changed since.
    private func removeImport() {
        importFill.clear(name: &name, role: &role)
        importFill = ImportFill()
        imported = nil
        draft = nil
    }

    /// The role a new Orb is made with: what was typed, trimmed like the name, or "Assistente pessoal" when nothing is left
    /// (a role of only spaces would show as a blank line under the name).
    static func finalRole(_ role: String) -> String {
        let trimmed = role.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Assistente pessoal" : trimmed
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        let bot = model.createBot(name: trimmedName,
                                  role: Self.finalRole(role),
                                  orb: orb, model: modelName, mode: mode, identity: identity, interview: interview,
                                  folder: folder, adopting: chosenMemory, importing: imported)
        // MARK: MultiOrb (WP4)
        // What the assistant said the Orb may use, if its draft came to the form.
        if let draftCapabilities { model.update(bot.id) { $0.capabilities = draftCapabilities.subtracting([.connectors]) } }
        // MARK: end MultiOrb (WP4)
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
    /// The Orb's own folder as it would be named ("Atlas 2" when "Atlas" is taken), looked up off the main thread when the
    /// name changes: asking the disk in `body` would repeat on every keystroke.
    @State private var ownURL: URL?

    private var ownFallback: URL { OrbFolder.defaultBase.appending(path: OrbFolder.folderName(for: name), directoryHint: .isDirectory) }

    var body: some View {
        Section {
            // The same line as the folder in the Orb's panel: what the place is called, its path under it, "Mudar…" at the end.
            HStack(spacing: 10) {
                Image(systemName: choice == .home ? "house" : "folder")
                    .foregroundStyle(Palette.muted)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(shownName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSwap(shownName)
                    Text(shownPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
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
                // Without the system's blue arrow: the panel's chip, the "…" says it opens more.
                .menuIndicator(.hidden)
                .chipButton()
                .fixedSize()
                .help(Tip.changeFolder)
                .accessibilityLabel("Mudar pasta")
            }
        } header: {
            Text("Pasta")
        } footer: { FormFootnote {
            Text(footer).textSwap(footer)
        } }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { choice = .existing(url) }
        }
        .task(id: name) {
            // A short pause while typing; the first lookup goes at once.
            if ownURL != nil { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let name = name
            let url = await Task.detached { OrbFolder.availableURL(for: name, in: OrbFolder.defaultBase) }.value
            if !Task.isCancelled { ownURL = url }
        }
    }

    private var shownPath: String {
        switch choice {
        case .own:
            name.trimmingCharacters(in: .whitespaces).isEmpty
                ? "~/Orbs/…"
                : OrbFolder.display(ownURL ?? ownFallback)
        case .home: "~"
        case .existing(let url): OrbFolder.display(url)
        }
    }

    /// The folder's name over its path: the Orb's own one is named after it as soon as it has a name.
    private var shownName: String {
        switch choice {
        case .own:
            name.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Pasta própria"
                : (ownURL ?? ownFallback).lastPathComponent
        case .home: "Pasta pessoal"
        case .existing(let url): url.lastPathComponent
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

#if DEBUG || ORB_DEV_TOOLS
/// `--snapshot new-orb-kept`: the new-Orb sheet over two kept memories, the newest one chosen. They are written into
/// the snapshot's own data folder (a temporary one, or `ORB_DATA_DIR`), never the user's.
@MainActor
enum NewBotSnapshots {
    static func keptSheet(height: CGFloat?) -> AnyView {
        let nina = KeptProfile(name: "Nina", role: "Cuida da minha agenda",
                               orb: OrbConfig(color: "menta", eyes: "pilulas", mouth: "sorriso", hair: "franja", accessories: ["laco"]))
        let luna = KeptProfile(name: "Luna", role: "Escreve comigo", orb: OrbConfig(color: "rosa", eyes: "ovais", cheeks: "blush"))
        let list = sampleKept(nina, luna)
        return AnyView(NewBotSheet(height: height, kept: list, chosen: list.first))
    }

    /// Two kept memories (Nina with 12 pages, Luna with 5), written into a folder of their own that is gone as soon as
    /// they are listed: never the data folder, which may be the real one when `ORB_DATA_DIR` points at it.
    static func sampleKept(_ nina: KeptProfile, _ luna: KeptProfile) -> [KeptMemory] {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "orb-kept-sample-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appending(path: "memoria", directoryHint: .isDirectory)
        func day(_ month: Int, _ day: Int) -> Date {
            Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12, minute: 30)) ?? .now
        }
        seed(nina, pages: 12, at: day(10, 8), in: root)
        seed(luna, pages: 5, at: day(9, 30), in: root)
        return KeptMemories.list(in: root)
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

    /// `--snapshot new-orb-marketplace`: a Grok Bot marketplace bot read from its link, in the preview.
    static func marketplaceSheet(height: CGFloat?) -> AnyView {
        let bot = MarketplaceBot(
            id: "researchy", name: "Researchy", creatorName: "Farzad",
            description: "A research and fact-check desk that runs every pass with live web search, for sourced, dated claims.",
            summary: "A research and fact-check desk with live web search.",
            memories: [.init(name: "memory 1", description: "Every research or fact-check uses live search. Never a training-only pass."),
                       .init(name: "memory 2", description: "Deliver the result as soon as the run ends; do not wait to be asked."),
                       .init(name: "memory 3", description: "Run every pass without asking for permission.")],
            skills: [.init(name: "Research pass", description: "Use when running a live research or fact-check.",
                           content: "Launch the research, wait until it exits, then deliver sourced dated claims.")],
            integrations: [.init(name: "Notion", description: "Notion MCP server.")])
        let card = { (id: String, name: String, by: String, color: String, categories: [String], summary: String) in
            MarketplaceBot(id: id, name: name, creatorName: by, summary: summary, categories: categories, color: color)
        }
        MarketplaceGallery.preloaded = [
            card("dr-eggbot-v2", "dr eggbot", "Lauren Tan", "red", ["From Grok Bot Team"],
                 "Designs high-quality Grok Bots. Asks a few preference questions, then creates them."),
            card("overheard", "Overheard", "Grok Bot Team", "violet", ["From Grok Bot Team", "Personal"],
                 "Turns what you hear in meetings into notes and follow-ups."),
            card("researchy", "Researchy", "Farzad", "green", ["Engineering"], bot.summary),
            card("seo-aeo-desk", "SEO & AEO Desk", "Mia", "orange", ["Marketing"],
                 "Audits pages for search and answer engines and drafts the fixes."),
            card("outbound", "Outbound Prospecting", "Leo", "cyan", ["Sales"],
                 "Finds leads, writes the first message and keeps the follow-up going."),
            card("haggle-bot", "Haggle Bot", "Ana", "magenta", ["Personal"], "Negotiates prices and bills for you, politely and persistently."),
        ]
        guard let found = try? GrokMarketplace.orbImport(bot, link: .page(bot.id)) else { return AnyView(NewBotSheet(height: height)) }
        return AnyView(NewBotSheet(height: height, draft: found))
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
#endif
