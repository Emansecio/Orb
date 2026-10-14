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
            .onChange(of: botID) { _, new in orbChanged(to: new) }
            .task(id: bot.workingDirectory) {
                instructionFile = await FolderInstructions.loadInBackground(from: bot.workingURL)
            }
            .task(id: FilesKey(bot: bot.id, folder: bot.workingDirectory, refresh: filesRefresh)) {
                // Always read the folder again: the cached snapshot (up to a minute old) may not show what changed
                // outside the app while the panel was closed.
                let result = await WorkspaceFiles.load(botID: bot.id, folder: bot.workingURL, refresh: true)
                if !Task.isCancelled { listing = result }
            }
            // While the panel is open the list follows the folder: what the Orb (or anyone) writes or deletes shows up
            // in a moment, not only at the end of the turn.
            .task(id: bot.workingDirectory) {
                for await _ in FolderWatcher.changes(in: bot.workingURL) { filesRefresh += 1 }
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
                    SheetFooterBar {
                        Spacer()
                        Button("Pronto") { isEditingOrb = false }
                            .buttonStyle(PrimaryPillStyle())
                            .keyboardShortcut(.defaultAction)
                    }
                    .background(Palette.chrome)
                    .sheetSection(2)
                }
                .frame(width: 560, height: editorHeight)
                .registersOpenSheet()
            }
            .background(Palette.chrome)
        }
    }

    /// The panel stays when another Orb is chosen (RootView): what belonged to the last one goes, and this one's tab and
    /// requests come in.
    private func orbChanged(to new: UUID) {
        tab = InspectorTabMemory.tab(for: new)
        isEditingOrb = false
        isPickingFolder = false
        isConfirmingBypass = false
        isEditingIdentity = false
        isShowingMemory = false
        memorySheetKind = nil
        identityDraft = ""
        isSavingIdentity = false
        identitySaveFailed = false
        listing = nil // read again for this Orb's folder (`FilesKey`)
        folderProblem = nil
        editingRoutine = nil
        takeRequests()
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

    /// Who the Orb is, always visible: avatar, name and role (editable), and one quiet line under them with the way to
    /// change its look (the look itself is said in the tip) and, for an Orb another made, who made it.
    private func header(_ bot: Bot) -> some View {
        let summary = AppearanceSummary.text(for: bot.orb)
        return HStack(alignment: .center, spacing: 14) {
            LiveBotAvatar(botID: bot.id, orb: bot.orb, size: 56, interactive: true) // the only part that follows the activity
            VStack(alignment: .leading, spacing: 5) {
                InspectorHeader(bot: bot)
                    .id(bot.id)
                let customize = Button("Personalizar…") {
                    editorHeight = NewBotSheetLayout.height(preferred: 720)
                    isEditingOrb = true
                }
                .buttonStyle(QuietTextStyle())
                .fixedSize()
                .help("\(Tip.customizeOrb) (\(summary))")
                // Who made it beside "Personalizar…" when both fit on the line; under it otherwise, never a name broken in two.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        customize
                        if bot.createdByName != nil {
                            Text("·").foregroundStyle(Palette.hint).accessibilityHidden(true)
                        }
                        CreatedByLine(bot: bot).fixedSize() // MultiOrb (WP3)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        customize
                        CreatedByLine(bot: bot)
                    }
                }
                .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The same side padding as the form's cards below, so the header, the buttons, the tabs and the cards share edges.
        .padding(.horizontal, Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    /// What people do most with an Orb's folder, one click each from any tab: two quiet buttons of one line, side by side.
    private func quickActions(_ bot: Bot) -> some View {
        let folderIsMissing = listing?.folder == .missing
        return HStack(spacing: 8) {
            quickAction("Finder", "folder", help: Tip.openFolderInFinder(bot.name)) {
                OrbFolder.showInFinder(bot.workingURL)
            }
            .disabled(folderIsMissing)
            quickAction("Terminal", "terminal", help: Tip.openFolderInTerminal(bot.name)) {
                OrbFolder.openInTerminal(bot.workingURL)
            }
            .disabled(folderIsMissing)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, 12)
    }

    private func quickAction(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(QuickActionTileStyle())
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
        let info = model.modelInfo(forModel: bot.model)
        Section {
            ModelPicker(selection: binding(\.model, of: bot))
            // A row like "Modo": only for a model whose catalog lists thinking levels.
            if let levels = info?.efforts {
                Picker("Esforço", selection: binding(\.effort, of: bot)) {
                    Text(ReasoningEffort.defaultLabel(for: info)).tag("")
                    if !bot.effort.isEmpty && !levels.contains(bot.effort) {
                        Text(ReasoningEffort.label(bot.effort)).tag(bot.effort)
                    }
                    ForEach(levels, id: \.self) { Text(ReasoningEffort.label($0)).tag($0) }
                }
            }
        } footer: {
            if let note = model.modelUnavailableNote(bot.model) {
                FormFootnote {
                    Text(note)
                        .foregroundStyle(Palette.warn)
                        .textSwap(note)
                }
            } else if info != nil, let note = ReasoningEffort.note(bot.effort, for: info) {
                FormFootnote {
                    Text(note).textSwap(note)
                }
            }
        }

        Section {
            Picker("Modo", selection: binding(\.permissionMode, of: bot).confirmingBypass {
                isConfirmingBypass = true
            }) {
                ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Permissões")
        } footer: { FormFootnote {
            Text(bot.permissionMode.summary)
                .foregroundStyle(bot.permissionMode == .bypass ? Palette.warn : .secondary)
                .textSwap(bot.permissionMode)
        } }
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
                // The icons share one width, so the titles start on one x whatever the symbol (terminal, globe, window…).
                Label {
                    Text(capability.label)
                } icon: {
                    Image(systemName: capability.symbol).frame(width: 20)
                }
                Text(connectorsLine ?? CapabilityCopy.subtitle(capability))
                    .capabilityCaption()
                    .textSwap(connectorsLine)
            }
        }
        if capability == .browser && BrowserPickerCopy.showsPickers(bot.capabilities) {
            BrowserPickerRows(botID: bot.id)
                .transition(.quiet)
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
        } footer: { FormFootnote {
            if let folderProblem {
                Text(folderProblem).foregroundStyle(Palette.warn)
            }
        } }

        if let file = instructionFile {
            Section {
                Toggle(isOn: instructionsTrustBinding(file, of: bot)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Label("Confiar nas instruções desta pasta", systemImage: "checkmark.shield")
                        Text("Se ligado, \(bot.name) segue o que está em \(file.fileName) como ordens. Ligue só para pastas suas.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Ver \(file.fileName) no Finder", systemImage: "doc.text.magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting([bot.workingURL.appending(path: file.fileName)])
                }
                .help(Tip.showInstructions)
                .chipButton()
            } header: {
                Text("Instruções da pasta")
            } footer: { FormFootnote {
                Text(InstructionsText.footer(for: file, name: bot.name, trustedHash: bot.trustedInstructionsHash))
            } }
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
                        .chipButton()
                        .help(Tip.removeGrant)
                } label: {
                    Text(rule.title)
                }
                // A removed grant just fades, quickly; the others close the gap.
                .transition(.adapted(.opacity.animation(Motion.exit), reduceMotion: reduceMotion))
            }
            if bot.permissionRules.count > 1 {
                Button("Remover todas", role: .destructive) { model.update(bot.id) { $0.permissionRules = [] } }
                    .chipButton()
                    .help(Tip.removeAllGrants)
                    .transition(.quiet)
            }
        } header: {
            Text("Liberações")
        } footer: { FormFootnote {
            Text(PermissionMode.grantsNote)
        } }
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
                .chipButton()
                .help(Tip.recreateFolder)
                .transition(.quiet)
        } else {
            HStack(spacing: 8) {
                Button("Abrir no Finder", systemImage: "folder") { OrbFolder.showInFinder(bot.workingURL) }
                    .help(Tip.openFolderInFinder(bot.name))
                Button("Abrir no Terminal", systemImage: "terminal") { OrbFolder.openInTerminal(bot.workingURL) }
                    .help(Tip.openFolderInTerminal(bot.name))
            }
            .chipButton()
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
        .chipButton()
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
            } footer: { FormFootnote {
                if !listing.files.isEmpty {
                    Text("Alterados no git primeiro, depois os mais recentes. Clique para mostrar no Finder, duas vezes para abrir.")
                }
            } }
            // The list is read off the main thread and arrives later: it fades in, and its height (it may be long) is not
            // animated; a refresh that changes the files swaps them at once.
            .transition(.quiet)
        }
    }

    // MARK: Rotinas

    @ViewBuilder
    private func routinesTab(_ bot: Bot) -> some View {
        let routines = model.routines(for: bot.id)
        // Each routine is a card of its own; the first one carries the tab's title.
        if routines.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Nenhuma rotina ainda", systemImage: "clock.badge")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("Peça a \(bot.name) no chat, como “verifique meus e-mails a cada 30 minutos”, ou crie uma aqui.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Rotinas")
            }
        }
        ForEach(Array(routines.enumerated()), id: \.element.id) { index, routine in
            Section {
                RoutineRow(routine: routine) { editingRoutine = routine }
            } header: {
                if index == 0 { Text("Rotinas") }
            }
        }
        Section {
            HStack(spacing: 8) {
                Button("Nova rotina…", systemImage: "plus") {
                    editingRoutine = Routine(name: "", botID: bot.id, prompt: "", schedule: .daily(hour: 9, minute: 0))
                }
                .buttonStyle(SecondaryPillStyle())
                .controlSize(.small)
                .help(Tip.newRoutine)
                Spacer(minLength: 4)
                Button("Ver todas", systemImage: "arrow.up.right") { model.selection = .routines }
                    .buttonStyle(GhostStyle(tint: Palette.accentText))
                    .controlSize(.small)
                    .hangsOnTrailingEdge()
                    .help(Tip.allRoutines)
            }
        } footer: { FormFootnote {
            if !routines.isEmpty {
                Text("\(bot.name) faz isso sozinho, no horário, enquanto o app está aberto.")
            }
        } }
        // Cards come and go in place (also the ones the Orb schedules or deletes from the chat). Only this tab watches.
        .animateChanges(of: routines.map(\.id))
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
        .id(bot.id) // its search belongs to one Orb's memory (the panel itself stays across Orbs)
    }

    /// Falls back to the last rendered value, so a sheet closing after deletion never reads a missing bot.
    private func binding<Value>(_ keyPath: WritableKeyPath<Bot, Value>, of bot: Bot) -> Binding<Value> {
        Binding(
            get: { model.liveBot(botID)?.bot[keyPath: keyPath] ?? bot[keyPath: keyPath] },
            set: { value in model.update(botID) { $0[keyPath: keyPath] = value } }
        )
    }

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
                            .frame(height: 16)
                            .font(.system(size: 13))
                        Text(tab.shortTitle)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(isSelected ? Palette.ink : Palette.muted)
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
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
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, 8)
        // A hairline under the bar: the tab's content scrolls under it, not into the buttons.
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.line).frame(height: 1)
        }
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
    /// The role's field is on screen (from the click on the text until the focus leaves it).
    @State private var isEditingRole = false

    private enum Field { case name, role }

    init(bot: Bot) {
        self.bot = bot
        _name = State(initialValue: bot.name)
        _role = State(initialValue: bot.role)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Two lines before it is cut, Return still ending the edit, as in the role below.
            TextField("Nome", text: $name, prompt: Text("Nome"), axis: .vertical)
                .lineLimit(1...2)
                .font(.system(size: 15, weight: .semibold))
                .focused($focus, equals: .name)
                .onKeyPress(.return) {
                    focus = nil
                    return .handled
                }
            // At rest the role is text of up to two lines, ending in "…" when it is longer; a click opens the field, which
            // grows with what is typed. (A two-line field would show its own first line and scroll the rest away.)
            if isEditingRole {
                TextField("Papel", text: $role, prompt: Text("Papel"), axis: .vertical)
                    .lineLimit(1...4)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .focused($focus, equals: .role)
                    .onSubmit { focus = nil }
                    // Return ends the edit (the role is one line that wraps), as in the name above.
                    .onKeyPress(.return) {
                        focus = nil
                        return .handled
                    }
                    .onAppear { focus = .role }
            } else {
                Text(role.isEmpty ? "Papel" : role)
                    .font(.callout)
                    .foregroundStyle(role.isEmpty ? Palette.hint : Palette.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { isEditingRole = true }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Papel: \(role)")
                    .accessibilityAction { isEditingRole = true }
            }
        }
        .textFieldStyle(.plain)
        .labelsHidden() // in a Form a field shows its title beside the text
        .help("Clique para mudar o nome ou o papel. A pasta do Orb não muda de lugar.")
        .onChange(of: focus) { old, new in
            if old == .name { commitName() } else if old == .role {
                commitRole()
                if new != .role { isEditingRole = false }
            }
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
        model.setRole(bot.id, to: role.replacingOccurrences(of: "\n", with: " "))
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

/// One of the Orb's routines in its panel, as a card of its own: what it is and when (with its switch), when it runs
/// next, how the last run went, and its actions (run now, edit, delete).
private struct RoutineRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let routine: Routine
    let edit: () -> Void
    @State private var isConfirmingDelete = false
    @State private var isHovering = false

    var body: some View {
        // The routine as it is now (the toggle and the runs change it in the model, not in this copy).
        let current = model.routines.first { $0.id == routine.id } ?? routine
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                RoutineGlyph(schedule: current.schedule, isOn: current.isEnabled)
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(current.schedule.label)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                    if let mismatch = RoutineText.nameMismatch(of: current) {
                        Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                Toggle("Ativa", isOn: Binding(get: { current.isEnabled }, set: { model.setRoutineEnabled(routine.id, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                    .help(Tip.routineToggle(isOn: current.isEnabled))
            }
            if let goal = current.goal { GoalProgressView(goal: goal, font: .system(size: 12), showsNote: false) }
            VStack(alignment: .leading, spacing: 6) {
                RoutineNextLine(routine: current)
                RoutineLastLine(routine: current)
            }
            footer(current)
        }
        .padding(.vertical, 4)
        // The task the Orb just scheduled is marked for a moment (`AppModel.freshRoutine`).
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.accent.opacity(model.freshRoutine == routine.id ? 0.12 : 0))
                .padding(.horizontal, -8).padding(.vertical, -4)
        }
        .animateChanges(of: current.isEnabled)
        .animateChanges(of: model.freshRoutine)
        .animateChanges(of: isConfirmingDelete)
        .onHover { isHovering = $0 }
        .sensoryFeedback(.alignment, trigger: current.isEnabled)
        .transition(.adapted(.arrive, reduceMotion: reduceMotion))
    }

    @ViewBuilder
    private func footer(_ current: Routine) -> some View {
        HStack(spacing: 4) {
            if isConfirmingDelete {
                Text("Apagar esta rotina?")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(Palette.secondary)
                Spacer(minLength: 4)
                Button("Cancelar") { isConfirmingDelete = false }
                    .buttonStyle(GhostStyle())
                Button("Apagar", role: .destructive) { model.deleteRoutine(routine.id) }
                    .buttonStyle(GhostStyle(tint: Palette.danger))
                    .hangsOnTrailingEdge()
            } else {
                // Like the Rotinas page: with the Orb busy the run waits for it (`runRoutine` queues it). The three swap
                // in place, cross-fading, so the row does not shift.
                ZStack(alignment: .leading) {
                    if model.isRoutineRunning(routine.id) {
                        Label("Rodando…", systemImage: "hourglass")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .transition(.opacity)
                    } else if model.isRoutineQueued(routine.id) {
                        Label("Na fila", systemImage: "clock")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .help(Tip.queuedRoutine)
                            .transition(.opacity)
                    } else {
                        Button("Rodar agora", systemImage: "play.fill") { model.runRoutine(routine.id) }
                            .buttonStyle(SecondaryPillStyle())
                            .help(Tip.runRoutineNow)
                            .transition(.opacity)
                    }
                }
                .controlSize(.small)
                .animateChanges(of: RoutineRunState(isRunning: model.isRoutineRunning(routine.id), isQueued: model.isRoutineQueued(routine.id)))
                Spacer(minLength: 4)
                Button("Editar", systemImage: "pencil", action: edit)
                    .labelStyle(.iconOnly)
                    .buttonStyle(CircleGhostStyle(side: 26, fontSize: 12))
                    .foregroundStyle(Palette.secondary)
                    .help(Tip.editRoutine)
                Button("Apagar “\(current.name)”", systemImage: "trash") { isConfirmingDelete = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(CircleGhostStyle(side: 26, fontSize: 12))
                    .foregroundStyle(Palette.secondary)
                    .help(Tip.deleteRoutine)
                    .padding(.trailing, -4)
                    // Only under the pointer, like the lembranças: a list of routines, not of trash cans.
                    .opacity(isHovering ? 1 : 0)
                    .animation(Motion.hover(isHovering), value: isHovering)
            }
        }
        .frame(minHeight: 26)
        .transition(.opacity)
    }
}

/// The routine's kind at a glance: a clock that turns for an interval, a calendar for a weekday or a cron line, a clock
/// for a time of day, a "1" for a single run; tinted while it is on, gray while it is paused.
private struct RoutineGlyph: View {
    static let side: CGFloat = 30
    let schedule: Schedule
    let isOn: Bool

    private var symbol: String {
        switch schedule {
        case .everyHours, .everyMinutes: "arrow.triangle.2.circlepath"
        case .weekly, .cron: "calendar"
        case .daily: "clock"
        case .once: "1.circle"
        }
    }

    var body: some View {
        Image(systemName: isOn ? symbol : "pause.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isOn ? Palette.accentText : Palette.muted)
            .frame(width: Self.side, height: Self.side)
            .background((isOn ? Palette.accent.opacity(0.16) : Palette.raised), in: .rect(cornerRadius: 8))
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}

/// "Próxima: amanhã às 01:03 · em 5 h 59 min", kept right as the minutes pass; "Pausada" while it is off.
private struct RoutineNextLine: View {
    let routine: Routine

    var body: some View {
        if routine.isEnabled {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Label {
                    // "em 9 h 57 min" never breaks inside.
                    Text("Próxima: \(RoutineText.dayAndTime(routine.nextRun, now: context.date)) · \(RoutineText.relative(until: routine.nextRun, now: context.date).replacing(" ", with: "\u{A0}"))")
                } icon: {
                    Image(systemName: "arrow.forward.circle")
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
            }
        } else if RoutineText.isConcluded(routine) {
            Label("Concluída: rodou no horário marcado", systemImage: "checkmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        } else {
            Label("Pausada: não roda até você ligar de novo", systemImage: "pause.circle")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        }
    }
}

/// How the last run went: its mark, when, and the first line of its report; "Ainda não rodou" before the first.
private struct RoutineLastLine: View {
    let routine: Routine
    @State private var isExpanded = false

    var body: some View {
        if let run = routine.runs.first {
            Label {
                Text("\(RoutineText.stamp(run.date)) · \(MarkdownCache.attributed(isExpanded ? run.report ?? run.summary : run.summary))")
                    .lineLimit(isExpanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: run.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(run.succeeded ? Palette.ok : Palette.danger)
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Última execução \(run.succeeded ? "deu certo" : "não deu certo"), \(RoutineText.stamp(run.date)). \(run.summary)")
            // A click shows the whole report (as the lembranças do), another folds it back.
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
            .help(isExpanded ? "Clique para recolher" : "Clique para ver o relatório inteiro")
            .motion(Motion.content, value: isExpanded)
        } else {
            Label(routine.lastResult ?? "Ainda não rodou", systemImage: "circle.dashed")
                .font(.system(size: 12))
                .foregroundStyle(Palette.faint)
                .lineLimit(2)
        }
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
        formatter.locale = .app
        formatter.unitsStyle = .short
        return formatter
    }()
}

enum InstructionsText {
    static func footer(for file: FolderInstructions, name: String, trustedHash: String?) -> String {
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

/// One of the panel's quick actions: an equal-width tile with a soft fill, lighter on hover, dimmed when disabled.
private struct QuickActionTileStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Palette.ink : Palette.faint)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28)
            .hoverFill(isEnabled && (configuration.isPressed || isHovering), pressed: configuration.isPressed,
                       in: .rect(cornerRadius: 7), color: Palette.ghostSelected, resting: Palette.surface)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
            .contentShape(.rect(cornerRadius: 7))
            .onHover { isHovering = $0 }
    }
}

/// A small text button that stays gray until the pointer is on it ("Personalizar…" under the Orb's name): the header
/// keeps its one color, the blue left to what leads elsewhere.
private struct QuietTextStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Palette.secondary : isHovering ? Palette.ink : Palette.muted)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(Motion.hover(isHovering), value: isHovering)
    }
}
