import SwiftUI

/// Right-hand panel: who the bot is, what it may do, its workspace, memory and routines.
struct BotInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let botID: UUID
    @State private var tab: InspectorTab
    @State private var isEditingOrb = false
    @State private var isPickingFolder = false
    @State private var isConfirmingBypass = false
    @State private var isEditingIdentity = false
    @State private var isShowingMemory = false
    /// The kind the memory sheet opens on (nil: all of it).
    @State private var memorySheetKind: MemoryKind?
    @State private var identityDraft = ""
    @State private var isSavingIdentity = false
    @State private var identitySaveFailed = false
    /// The instruction file in the Orb's folder, if any (read off the main thread when the folder changes).
    @State private var instructionFile: FolderInstructions?
    /// The folder's state and its recent and changed files (read off the main thread, see `WorkspaceFiles`).
    @State private var listing: WorkspaceFiles.Listing?
    /// Bumped to read the folder again (after a turn, a folder change, or the refresh button).
    @State private var filesRefresh = 0
    @State private var folderProblem: String?
    @State private var editingRoutine: Routine?
    /// Height of the appearance sheet: the window's, less a margin, when the window is short.
    @State private var editorHeight = NewBotSheetLayout.height(preferred: 720)

    /// `tab` opens the panel on that tab (snapshots); otherwise on the one this Orb was last on.
    init(botID: UUID, tab: InspectorTab? = nil) {
        self.botID = botID
        _tab = State(initialValue: tab ?? InspectorTabMemory.tab(for: botID))
    }

    var body: some View {
        // This Orb's own state: what happens in another Orb does not touch the panel.
        if let live = model.liveBot(botID) {
            let bot = live.bot
            VStack(spacing: 0) {
                header(bot)
                quickActions(bot)
                InspectorTabBar(selection: $tab)
                // The tab's content swaps in a ZStack, cross-fading (§2.13): a grouped Form's own diff is unpredictable, so
                // each tab is a Form of its own. The scroll returns to the top with every tab, and the tasks below live on
                // the outer stack, so they do not run again.
                ZStack {
                    Form {
                        switch tab {
                        case .general: generalTab(bot)
                        case .memory: memoryTab(bot)
                        case .folder: folderTab(bot)
                        case .routines: routinesTab(bot)
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .id(tab)
                    .transition(.opacity)
                }
                .motion(Motion.crossFade, value: tab)
                // The task the Orb just scheduled from the chat (`AppModel.freshRoutine`, only set with this panel on screen)
                // arrives with a tap you can feel.
                .sensoryFeedback(.levelChange, trigger: model.freshRoutine) { _, new in new != nil }
            }
            .overlay(alignment: .bottom) { MemoryUndoToast(undo: model.memoryUndo).padding(.bottom, 14) }
            .onChange(of: tab) { _, new in InspectorTabMemory.remember(new, for: botID) }
            .onChange(of: botID) { _, new in tab = InspectorTabMemory.tab(for: new) }
            .task(id: bot.workingDirectory) {
                instructionFile = await FolderInstructions.loadInBackground(from: bot.workingURL)
            }
            .task(id: FilesKey(bot: bot.id, folder: bot.workingDirectory, refresh: filesRefresh)) {
                // Always read the folder again: the cached snapshot (up to a minute old) may not show what changed
                // outside the app while the panel was closed.
                let result = await WorkspaceFiles.load(botID: bot.id, folder: bot.workingURL, refresh: true)
                if !Task.isCancelled { listing = result }
            }
            // The turn may have created or changed files.
            .onChange(of: live.isWorking) { wasWorking, isWorking in
                if wasWorking && !isWorking { filesRefresh += 1 }
            }
            // The file may have been edited while the panel stayed open: read it again on coming back to the app.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { instructionFile = await FolderInstructions.loadInBackground(from: bot.workingURL) }
            }
            .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    model.chooseFolder(url, for: bot.id)
                    folderChanged()
                }
            }
            .sheet(item: $editingRoutine) { routine in
                RoutineEditor(routine: routine)
            }
            // "Personalizar…" in the sidebar's menu: the panel opens (or already is) and so does the appearance editor.
            .onAppear { takeRequests() }
            .onChange(of: model.pendingChatRequest) { takeRequests() }
            .sheet(isPresented: $isEditingIdentity) {
                IdentityEditor(name: bot.name, text: $identityDraft, isSaving: isSavingIdentity, failed: identitySaveFailed) {
                    guard !isSavingIdentity else { return }
                    isSavingIdentity = true
                    identitySaveFailed = false
                    Task {
                        let saved = await model.setIdentity(identityDraft, of: bot.id)
                        isSavingIdentity = false
                        if saved { isEditingIdentity = false } else { identitySaveFailed = true }
                    }
                } cancel: {
                    isEditingIdentity = false
                }
            }
            .sheet(isPresented: $isShowingMemory) {
                MemorySheet(botID: bot.id, name: bot.name, kind: memorySheetKind)
            }
            .sheet(isPresented: $isEditingOrb) {
                VStack(spacing: 0) {
                    OrbEditor(config: binding(\.orb, of: bot), name: bot.name)
                    HStack {
                        Spacer()
                        Button("Pronto") { isEditingOrb = false }
                            .buttonStyle(PrimaryPillStyle())
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(14)
                    .background(Palette.chrome)
                    .sheetSection(2)
                }
                .frame(width: 560, height: editorHeight)
                .registersOpenSheet()
            }
            .background(Palette.chrome)
        }
    }

    /// What a command asked of this panel: the appearance editor ("Personalizar…"), or a tab ("Gerenciar" in the
    /// permissions chip opens "Pasta e acessos", where the grants are).
    private func takeRequests() {
        if model.takeChatRequest(.editLook, of: botID) { isEditingOrb = true }
        if let requested = model.takeTabRequest(of: botID) { tab = requested }
    }

    private struct FilesKey: Hashable {
        var bot: UUID
        var folder: String
        var refresh: Int
    }

    // MARK: Top of the panel

    /// Who the Orb is, always visible: avatar, name and role (editable), its look in one line.
    private func header(_ bot: Bot) -> some View {
        let summary = AppearanceSummary.text(for: bot.orb)
        return HStack(spacing: 12) {
            LiveBotAvatar(botID: bot.id, orb: bot.orb, size: 60, interactive: true) // the only part that follows the activity
            VStack(alignment: .leading, spacing: 3) {
                InspectorHeader(bot: bot)
                    .id(bot.id)
                HStack(spacing: 6) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Personalizar…") {
                        editorHeight = NewBotSheetLayout.height(preferred: 720)
                        isEditingOrb = true
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .fixedSize()
                    .help(Tip.customizeOrb)
                }
                .help(summary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// The three things people do most with an Orb, one click each from any tab. Icons alone when the panel is narrow.
    private func quickActions(_ bot: Bot) -> some View {
        let folderIsMissing = listing?.folder == .missing
        return ViewThatFits(in: .horizontal) {
            quickActionRow(bot, showsTitles: true, folderIsMissing: folderIsMissing)
            quickActionRow(bot, showsTitles: false, folderIsMissing: folderIsMissing)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func quickActionRow(_ bot: Bot, showsTitles: Bool, folderIsMissing: Bool) -> some View {
        HStack(spacing: 6) {
            quickAction("Abrir pasta", "folder", showsTitle: showsTitles, help: Tip.openFolderInFinder(bot.name)) {
                OrbFolder.showInFinder(bot.workingURL)
            }
            .disabled(folderIsMissing)
            quickAction("Terminal", "terminal", showsTitle: showsTitles, help: Tip.openFolderInTerminal(bot.name)) {
                OrbFolder.openInTerminal(bot.workingURL)
            }
            .disabled(folderIsMissing)
            quickAction("Nova conversa", "square.and.pencil", showsTitle: showsTitles, help: Tip.newConversation()) {
                model.newConversation(bot.id)
            }
            if !showsTitles { Spacer(minLength: 0) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize(horizontal: showsTitles, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quickAction(_ title: String, _ symbol: String, showsTitle: Bool, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if showsTitle { Label(title, systemImage: symbol) } else { Image(systemName: symbol) }
        }
        .help(help)
        .accessibilityLabel(title)
    }

    /// The folder was replaced: what the panel knew about the old one no longer applies.
    private func folderChanged() {
        listing = nil
        folderProblem = nil
        filesRefresh += 1
    }

    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
            folderChanged()
        } catch {
            folderProblem = error.localizedDescription
        }
    }

    // MARK: Geral

    /// The model, what the Orb is allowed to do and what it may use.
    @ViewBuilder
    private func generalTab(_ bot: Bot) -> some View {
        Section {
            ModelPicker(selection: binding(\.model, of: bot))
        }

        Section {
            Picker("Modo", selection: binding(\.permissionMode, of: bot).confirmingBypass {
                isConfirmingBypass = true
            }) {
                ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Permissões")
        } footer: {
            Text(bot.permissionMode.summary)
                .foregroundStyle(bot.permissionMode == .bypass ? Palette.warn : .secondary)
                .textSwap(bot.permissionMode)
        }
        .bypassConfirmation(isPresented: $isConfirmingBypass) {
            model.update(bot.id) { $0.permissionMode = .bypass }
        }

        Section {
            ForEach(Capability.allCases) { capability in
                capabilityRow(capability, of: bot)
            }
        } header: {
            Text("O que \(bot.name) pode usar")
        }

        Section {
            Button("Apagar \(bot.name)…", role: .destructive) { model.askToDelete(bot.id) } // one sheet for the sidebar and here (DeleteOrbDialog.swift)
                .foregroundStyle(Palette.danger)
        }
    }

    @ViewBuilder
    private func capabilityRow(_ capability: Capability, of bot: Bot) -> some View {
        let isOn = bot.capabilities.contains(capability)
        let counts = model.connectorCounts(for: bot.id)
        let connectorsLine = capability == .connectors && isOn
            ? CapabilityCopy.connectorsLine(enabled: counts.enabled, total: counts.total, anyInstalled: !model.connectors.isEmpty)
            : nil
        Toggle(isOn: capabilityBinding(capability, of: bot)) {
            VStack(alignment: .leading, spacing: 1) {
                Label(capability.label, systemImage: capability.symbol)
                Text(connectorsLine ?? CapabilityCopy.subtitle(capability))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSwap(connectorsLine)
            }
        }
        if capability == .connectors && isOn {
            Button("Gerenciar conectores", systemImage: "arrow.up.right") { model.selection = .connectors }
                .buttonStyle(.link)
                .help(Tip.manageConnectors)
                .font(.caption)
                .transition(.quiet)
        }
        if capability == .computerUse && isOn {
            // The macOS permissions (Automação, Acessibilidade, Gravação de Tela) this switch relies on live in Ajustes.
            Button(SettingsTab.permissions.title, systemImage: "arrow.up.right") {
                SettingsRouter.open(.permissions, using: openSettings)
            }
            .buttonStyle(.link)
            .help(Tip.macPermissions)
            .font(.caption)
            .transition(.quiet)
        }
    }

    // MARK: Pasta e acessos

    @ViewBuilder
    private func folderTab(_ bot: Bot) -> some View {
        Section {
            Text(OrbFolder.display(bot.workingURL))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                .help(bot.workingURL.path)
            folderControls(bot)
        } header: {
            Text("Pasta")
        } footer: {
            if let folderProblem {
                Text(folderProblem).foregroundStyle(Palette.warn)
            }
        }

        if let file = instructionFile {
            Section {
                // Claude Code loads CLAUDE.md by itself as the project's instructions: trusting it here would change nothing.
                if !InstructionsText.claudeCodeReadsItself(file, usesClaudeCode: usesClaudeCode(bot)) {
                    Toggle(isOn: instructionsTrustBinding(file, of: bot)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Label("Confiar nas instruções desta pasta", systemImage: "checkmark.shield")
                            Text("Se ligado, \(bot.name) segue o que está em \(file.fileName) como ordens. Ligue só para pastas suas.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Ver \(file.fileName) no Finder", systemImage: "doc.text.magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting([bot.workingURL.appending(path: file.fileName)])
                }
                .help(Tip.showInstructions)
                .controlSize(.small)
            } header: {
                Text("Instruções da pasta")
            } footer: {
                Text(InstructionsText.footer(for: file, name: bot.name, trustedHash: bot.trustedInstructionsHash,
                                             usesClaudeCode: usesClaudeCode(bot)))
            }
            // What is read from the folder arrives by fading (`.quiet`), never by animating the height of a list that may
            // be long (§2.13).
            .transition(.quiet)
        }

        Section {
            if bot.permissionRules.isEmpty {
                Text("Nenhuma ainda. Ao aprovar um pedido, escolha “Sempre permitir…” e ela aparece aqui.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .transition(.quiet)
            }
            ForEach(bot.permissionRules, id: \.self) { rule in
                LabeledContent {
                    Button("Remover") { model.update(bot.id) { $0.permissionRules.removeAll { $0 == rule } } }
                        .controlSize(.small)
                        .help(Tip.removeGrant)
                } label: {
                    Text(rule.title)
                }
                // A removed grant just fades, quickly; the others close the gap.
                .transition(.adapted(.opacity.animation(Motion.exit), reduceMotion: reduceMotion))
            }
            if bot.permissionRules.count > 1 {
                Button("Remover todas", role: .destructive) { model.update(bot.id) { $0.permissionRules = [] } }
                    .controlSize(.small)
                    .help(Tip.removeAllGrants)
                    .transition(.quiet)
            }
        } header: {
            Text("Liberações")
        } footer: {
            Text(PermissionMode.grantsNote)
        }
        // Bound to the rules themselves (a short list), so only a grant coming or going moves anything.
        .animateChanges(of: bot.permissionRules)

        filesSection
    }

    /// Where the Orb works and what can be done with it: open it, move it, give the Orb a folder of its own.
    @ViewBuilder
    private func folderControls(_ bot: Bot) -> some View {
        let state = listing?.folder
        if state == .missing {
            Label("Pasta não encontrada", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warn)
                .transition(.quiet)
            Text("Ela foi apagada, renomeada ou está em um disco desconectado. \(bot.name) não consegue rodar comandos até você escolher outra pasta ou recriar esta.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .transition(.quiet)
            Button("Recriar", systemImage: "folder.badge.plus") { attempt { try model.recreateFolder(of: bot.id) } }
                .help(Tip.recreateFolder)
                .transition(.quiet)
        } else {
            HStack(spacing: 8) {
                Button("Abrir no Finder", systemImage: "folder") { OrbFolder.showInFinder(bot.workingURL) }
                    .help(Tip.openFolderInFinder(bot.name))
                Button("Abrir no Terminal", systemImage: "terminal") { OrbFolder.openInTerminal(bot.workingURL) }
                    .help(Tip.openFolderInTerminal(bot.name))
            }
            .controlSize(.small)
            .transition(.quiet)
        }
        Menu {
            Button("Escolher pasta…", systemImage: "folder.badge.gearshape") { isPickingFolder = true }
            if state == .ownFolder {
                Button("Usar a pasta pessoal", systemImage: "house") {
                    model.useHomeFolder(of: bot.id)
                    folderChanged()
                }
            } else if state == .noOwnFolder {
                Button("Criar pasta própria", systemImage: "folder.badge.plus") { attempt { try model.createOwnFolder(for: bot.id) } }
            }
        } label: {
            Text("Mudar pasta")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help(Tip.changeFolder)
        if state == .ownFolder {
            Text("Se usar a pasta pessoal, \(bot.name) volta a trabalhar nela. A pasta atual e o que há nela ficam como estão.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .transition(.quiet)
        } else if state == .noOwnFolder {
            Text("Em uma pasta própria (\(OrbFolder.display(OrbFolder.availableURL(for: bot.name, in: OrbFolder.defaultBase)))), \(bot.name) escreve sem perguntar em “Perguntar antes”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .transition(.quiet)
        }
    }

    /// Changed (git) and recently modified files of the Orb's folder. Not shown for the home folder, which is not scanned.
    @ViewBuilder
    private var filesSection: some View {
        if let listing, listing.folder != .missing, listing.snapshot != .home {
            Section {
                if listing.snapshot == .unreadable {
                    Text("Sem acesso à pasta. O macOS pode estar bloqueando: libere em Ajustes do Sistema → Privacidade e Segurança.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .transition(.quiet)
                } else if listing.files.isEmpty {
                    Text("Nada por aqui ainda.")
                        .foregroundStyle(.secondary)
                        .transition(.quiet)
                }
                ForEach(listing.files) { file in
                    WorkspaceFileRow(file: file)
                }
            } header: {
                HStack {
                    Text("Arquivos")
                    Spacer()
                    Button("Atualizar", systemImage: "arrow.clockwise") { filesRefresh += 1 }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .iconTip(Tip.refreshFolder)
                }
            } footer: {
                if !listing.files.isEmpty {
                    Text("Alterados no git primeiro, depois os mais recentes. Clique para mostrar no Finder, duas vezes para abrir.")
                }
            }
            // The list is read off the main thread and arrives later: it fades in, and its height (it may be long) is not
            // animated; a refresh that changes the files swaps them at once.
            .transition(.quiet)
        }
    }

    // MARK: Rotinas

    @ViewBuilder
    private func routinesTab(_ bot: Bot) -> some View {
        let routines = model.routines(for: bot.id)
        Section {
            if routines.isEmpty {
                Text("Nenhuma rotina ainda. Peça a \(bot.name) no chat, como “verifique meus e-mails a cada 30 minutos”, ou crie uma aqui.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(routines) { routine in
                RoutineRow(routine: routine) {
                    editingRoutine = routine
                }
            }
            Button("Nova rotina…", systemImage: "plus") {
                editingRoutine = Routine(name: "", botID: bot.id, prompt: "", schedule: .daily(hour: 9, minute: 0))
            }
            .help(Tip.newRoutine)
        } header: {
            Text("Rotinas")
        } footer: {
            if !routines.isEmpty {
                Text("\(bot.name) faz isso sozinho, no horário, enquanto o app está aberto.")
            }
        }
        // Rows come and go in place (also the ones the Orb schedules or deletes from the chat). Only this tab watches.
        .animateChanges(of: routines.map(\.id))
        Section {
            Button("Ver todas as rotinas", systemImage: "arrow.up.right") { model.selection = .routines }
                .buttonStyle(.link)
                .help(Tip.allRoutines)
        }
    }

    // MARK: Memória

    private func memoryTab(_ bot: Bot) -> some View {
        MemoryTab(botID: bot.id, name: bot.name, editIdentity: {
            Task {
                // From the file, not the panel's snapshot: the Orb may have added notes meanwhile.
                identityDraft = await model.identityText(of: bot.id)
                identitySaveFailed = false
                isEditingIdentity = true
            }
        }, showAll: { kind in
            memorySheetKind = kind
            isShowingMemory = true
        })
    }

    /// Falls back to the last rendered value, so a sheet closing after deletion never reads a missing bot.
    private func binding<Value>(_ keyPath: WritableKeyPath<Bot, Value>, of bot: Bot) -> Binding<Value> {
        Binding(
            get: { model.liveBot(botID)?.bot[keyPath: keyPath] ?? bot[keyPath: keyPath] },
            set: { value in model.update(botID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func usesClaudeCode(_ bot: Bot) -> Bool { model.modelRef(for: bot)?.provider == .claudeCode }

    /// On remembers the hash of the file as it is on disk right now, not as the panel last showed it: what the user
    /// trusts is what the next turn will read. If the file changed, the toggle shows off again.
    private func instructionsTrustBinding(_ file: FolderInstructions, of bot: Bot) -> Binding<Bool> {
        Binding(
            get: { file.isTrusted(by: model.liveBot(botID)?.bot.trustedInstructionsHash) },
            set: { isOn in
                let current = FolderInstructions.load(from: bot.workingURL)
                instructionFile = current
                model.update(bot.id) { $0.trustedInstructionsHash = isOn ? current?.hash : nil }
            }
        )
    }

    private func capabilityBinding(_ capability: Capability, of bot: Bot) -> Binding<Bool> {
        Binding(
            get: { bot.capabilities.contains(capability) },
            set: { isOn in
                model.update(bot.id) {
                    if isOn { $0.capabilities.insert(capability) } else { $0.capabilities.remove(capability) }
                }
            }
        )
    }
}

/// The panel's tabs: an icon over a short name, the chosen one lit.
private struct InspectorTabBar: View {
    @Binding var selection: InspectorTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The one highlight slides from the old tab to the new one through this namespace.
    @Namespace private var highlight

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            ForEach(InspectorTab.allCases) { tab in
                let isSelected = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .frame(height: 18)
                            .font(.system(size: 14))
                        Text(tab.title)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(isSelected ? Palette.ink : Palette.muted)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .top)
                    .padding(.horizontal, 2)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Palette.ghostSelected)
                                .matchedGeometryEffect(id: "destaque", in: highlight)
                        }
                    }
                    .contentShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(tab.title)
            }
        }
        // Bound to the selection alone, as in the sidebar: the highlight slides and the lit title changes with it; it
        // jumps under Reduce Motion.
        .animation(Motion.selection(reduceMotion: reduceMotion), value: selection)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        // For VoiceOver and the keyboard this is one group of tabs, which a segmented picker already is.
        .accessibilityRepresentation {
            Picker("Seções do painel", selection: $selection) {
                ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// The Orb's name and role, edited in place. A name with only blanks is not accepted: the old one comes back.
private struct InspectorHeader: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    @State private var name: String
    @State private var role: String
    @FocusState private var focus: Field?

    private enum Field { case name, role }

    init(bot: Bot) {
        self.bot = bot
        _name = State(initialValue: bot.name)
        _role = State(initialValue: bot.role)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Nome", text: $name, prompt: Text("Nome"))
                .font(.system(size: 15, weight: .semibold))
                .focused($focus, equals: .name)
                .onSubmit(commitName)
            TextField("Papel", text: $role, prompt: Text("Papel"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .focused($focus, equals: .role)
                .onSubmit(commitRole)
        }
        .textFieldStyle(.plain)
        .labelsHidden() // in a Form a field shows its title beside the text
        .help("Clique para mudar o nome ou o papel. A pasta do Orb não muda de lugar.")
        .onChange(of: focus) { old, _ in
            if old == .name { commitName() } else if old == .role { commitRole() }
        }
        .onChange(of: bot.name) { _, new in if focus != .name { name = new } }
        .onChange(of: bot.role) { _, new in if focus != .role { role = new } }
        // The view can go away with a field still focused (panel closed, another Orb chosen): nothing else saves it then.
        .onDisappear {
            if name != bot.name { commitName() }
            if role != bot.role { commitRole() }
        }
    }

    private func commitName() {
        if !model.rename(bot.id, to: name) { name = bot.name }
        else if let current = model.bot(bot.id) { name = current.name }
    }

    private func commitRole() {
        model.setRole(bot.id, to: role)
        if let current = model.bot(bot.id) { role = current.role }
    }
}

/// A file of the folder: a git marker (or nothing for a recent file), its name and when it changed.
private struct WorkspaceFileRow: View {
    let file: WorkspaceFile

    var body: some View {
        HStack(spacing: 8) {
            Text(file.marker?.rawValue ?? "")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 22)
                .help(file.marker?.help ?? "")
            Text(file.path)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if let modified = file.modified {
                Text(RelativeTime.text(modified))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: reveal)
        .contextMenu {
            Button("Mostrar no Finder", action: reveal)
            Button("Abrir", action: open)
        }
        .help("Clique para mostrar no Finder; duas vezes para abrir")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Mostrar no Finder", reveal)
        .accessibilityAction(named: "Abrir", open)
    }

    private var color: Color {
        switch file.marker {
        case .added, .untracked: Palette.ok
        case .deleted, .conflict: Palette.warn
        default: .secondary
        }
    }

    private func reveal() {
        guard file.marker != .deleted else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    private func open() {
        guard file.marker != .deleted else { return }
        NSWorkspace.shared.open(file.url)
    }
}

/// One of the Orb's routines in its panel: on/off, when it runs next, how the last run went, and a way to delete it.
private struct RoutineRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let routine: Routine
    let edit: () -> Void
    @State private var isConfirmingDelete = false

    var body: some View {
        // The routine as it is now (the toggle and the runs change it in the model, not in this copy).
        let current = model.routines.first { $0.id == routine.id } ?? routine
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(current.name)
                    Text(current.schedule.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Ativa", isOn: Binding(get: { current.isEnabled }, set: { model.setRoutineEnabled(routine.id, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help(Tip.routineToggle(isOn: current.isEnabled))
            }
            // The same words as the Rotinas page ("Próxima: em 3 h · hoje às 09:00", "Pausada").
            NextRunLine(routine: current)
            Text(current.lastResult ?? "Ainda não rodou.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
            footer(current)
                .controlSize(.small)
        }
        .opacity(current.isEnabled ? 1 : 0.6)
        // The task the Orb just scheduled is marked for a moment (`AppModel.freshRoutine`).
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.accent.opacity(model.freshRoutine == routine.id ? 0.12 : 0))
                .padding(.horizontal, -8).padding(.vertical, -5)
        }
        .animateChanges(of: current.isEnabled)
        .animateChanges(of: model.freshRoutine)
        .animateChanges(of: isConfirmingDelete)
        .sensoryFeedback(.alignment, trigger: current.isEnabled)
        .transition(.adapted(.arrive, reduceMotion: reduceMotion))
    }

    @ViewBuilder
    private func footer(_ current: Routine) -> some View {
        HStack {
            if isConfirmingDelete {
                Text("Apagar esta rotina?")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar") { isConfirmingDelete = false }
                Button("Apagar", role: .destructive) { model.deleteRoutine(routine.id) }
                    .foregroundStyle(.red)
            } else {
                Button("Editar", action: edit)
                    .help(Tip.editRoutine)
                Button(role: .destructive) { isConfirmingDelete = true } label: { Image(systemName: "trash") }
                    .iconTip(Tip.deleteRoutine, label: "Apagar “\(current.name)”")
                Spacer()
                // Like the Rotinas page: with the Orb busy the run waits for it (`runRoutine` queues it).
                if model.isRoutineRunning(routine.id) {
                    Label("Rodando…", systemImage: "hourglass").foregroundStyle(.secondary)
                } else if model.isRoutineQueued(routine.id) {
                    Label("Na fila", systemImage: "clock").foregroundStyle(.secondary)
                        .help(Tip.queuedRoutine)
                } else {
                    Button("Rodar agora", systemImage: "play.fill") { model.runRoutine(routine.id) }
                        .help(Tip.runRoutineNow)
                }
            }
        }
        .transition(.opacity)
    }
}

enum RelativeTime {
    /// "há 5 min", "em 2 h": for dates a little before or after now.
    static func text(_ date: Date, now: Date = .now) -> String {
        formatter.localizedString(for: date, relativeTo: now)
    }

    /// One formatter for every row: making one costs more than formatting with it.
    nonisolated(unsafe) private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.unitsStyle = .short
        return formatter
    }()
}

enum InstructionsText {
    /// CLAUDE.md in the folder of an Orb that runs on Claude Code: Claude Code reads it as instructions on its own.
    static func claudeCodeReadsItself(_ file: FolderInstructions, usesClaudeCode: Bool) -> Bool {
        usesClaudeCode && file.fileName == "CLAUDE.md"
    }

    static func footer(for file: FolderInstructions, name: String, trustedHash: String?, usesClaudeCode: Bool = false) -> String {
        if claudeCodeReadsItself(file, usesClaudeCode: usesClaudeCode) {
            return "\(file.fileName) é lido pelo próprio Claude Code como instruções do projeto."
        }
        if file.isTrusted(by: trustedHash) { return "\(file.fileName) vale como instruções de \(name) nesta pasta." }
        if trustedHash != nil {
            return "\(file.fileName) mudou desde que você confiou nele: \(name) o lê só como referência, até você confiar de novo."
        }
        return "\(file.fileName) é lido por \(name) como material de referência, não como ordens. Confie para valer como instruções."
    }
}

/// Edits the Orb's identity notes: how it should work, in your words.
private struct IdentityEditor: View {
    let name: String
    @Binding var text: String
    /// A save is under way (the button waits), or the last one failed (the editor stays open, and says why).
    let isSaving: Bool
    let failed: Bool
    let save: () -> Void
    let cancel: () -> Void

    /// Notes above the limit are not saved (they would lose their end), so the editor says so instead.
    private var excess: Int { text.count - MemoryBank.identityMaximumLength }

    private var footerMessage: String? {
        if excess > 0 { return "Muito longo: tire \(excess) caracteres para salvar." }
        return failed ? "Não foi possível salvar (talvez falte espaço no disco). O texto continua aqui." : nil
    }

    var body: some View {
        PlaceholderTextEditor(placeholder: "Ex.: Seja direto e me lembre de fazer pausas.", text: $text, minHeight: 220)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .orbSheet("Como \(name) funciona",
                      subtitle: "Vai em toda conversa. O que \(name) aprender na entrevista entra no fim destas notas. ⌘↩ salva.",
                      size: .medium) {
                SheetFooter(message: footerMessage, cancel: cancel, primaryTitle: "Salvar",
                            isPrimaryDisabled: excess > 0 || isSaving, primary: save)
            }
            // Return adds a line in the editor; ⌘↩ saves.
            .background {
                Button("Salvar", action: save)
                    .keyboardShortcut(AppShortcut.commandReturn)
                    .disabled(excess > 0 || isSaving)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
    }
}
