import SwiftUI

/// Right-hand panel: who the bot is, what it may do, its workspace, memory and routines.
struct BotInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let botID: UUID
    @State private var tab: InspectorTab
    @State private var isEditingOrb = false
    /// "Renomear…" in the sidebar's menu: the header takes it and puts the cursor in the name.
    @State private var isFocusingName = false
    /// The look the appearance sheet opened with, for "Desfazer mudanças" (the editor saves as it goes).
    @State private var orbAtOpen: OrbConfig?
    @State private var isPickingFolder = false
    @State private var isConfirmingBypass = false
    @State private var isShowingBypassInfo = false
    /// Which of the General tab's cards are open, for the whole app (a card with a problem is open whatever this says).
    @AppStorage(InspectorFold.modelKey) private var modelFoldOpen = false
    @AppStorage(InspectorFold.capabilitiesKey) private var capabilitiesFoldOpen = false
    /// What the browser has on this Mac and whether the search key is kept: read here, not by the browser rows, because a
    /// problem in them opens the "Pode usar" card even when the rows are not drawn.
    @State private var browserStatus: BrowserStatus?
    @State private var searchKey: Bool?
    /// Bumped when the app comes back to the front: the person may have installed the browser meanwhile.
    @State private var browserRecheck = 0
    @State private var isEditingIdentity = false
    @State private var isShowingMemory = false
    /// The kind the memory sheet opens on (nil: all of it).
    @State private var memorySheetKind: MemoryKind?
    @State private var identityDraft = ""
    /// What the editor opened with: notes the Orb saves while it is open are kept on save.
    @State private var identityBase = ""
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
            let contentKey = ContentKey(tab: tab, bot: botID)
            VStack(spacing: 0) {
                header(bot)
                InspectorTabBar(selection: $tab)
                // The content swaps in a ZStack, cross-fading (§2.13): a grouped Form's own diff is unpredictable, so each
                // tab is a Form of its own. The key is the tab and the Orb: changing Orbs fades the content too, while the
                // panel itself (header, tab bar, tasks) stays. The scroll returns to the top with every swap, and the tasks
                // below live on the outer stack, so they do not run again.
                ZStack {
                    Form {
                        switch tab {
                        case .general: generalTab(bot)
                        case .memory: memoryTab(bot)
                        case .folder: folderTab(bot)
                        case .routines: routinesTab(bot)
                        case .screen: LiveScreenTab(botID: bot.id)
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .id(contentKey)
                    .transition(.pageSwap)
                }
                .motion(Motion.crossFade, value: contentKey)
                // The task the Orb just scheduled from the chat (`AppModel.freshRoutine`, only set with this panel on screen)
                // arrives with a tap you can feel.
                .sensoryFeedback(.levelChange, trigger: model.freshRoutine) { _, new in new != nil }
            }
            .overlay(alignment: .bottom) { MemoryUndoToast(undo: model.memoryUndo).padding(.bottom, 14) }
            .onChange(of: tab) { _, new in
                InspectorTabMemory.remember(new, for: botID)
                // Changes made while another tab was open are read on coming back to the folder one.
                if new == .folder { filesRefresh += 1 }
            }
            .onChange(of: botID) { _, new in orbChanged(to: new) }
            .task(id: bot.workingDirectory) {
                instructionFile = await FolderInstructions.loadInBackground(from: bot.workingURL)
            }
            .task(id: FilesKey(bot: bot.id, folder: bot.workingDirectory, refresh: filesRefresh)) {
                // Only the Pasta tab uses the listing (state, chips and files), and the read is a scan plus `git status`:
                // the other tabs skip it. Coming back to the tab bumps `filesRefresh`, which runs this again.
                guard tab == .folder else { return }
                // Always read the folder again: the cached snapshot (up to a minute old) may not show what changed
                // outside the app while the panel was closed.
                let result = await WorkspaceFiles.load(botID: bot.id, folder: bot.workingURL, refresh: true)
                if !Task.isCancelled && result != listing { listing = result }
            }
            // While the panel is open the list follows the folder: what the Orb (or anyone) writes or deletes shows up
            // in a moment, not only at the end of the turn. Only the folder tab shows the files (the header needs just
            // the folder's state, read once above), so the other tabs neither watch nor reread.
            .task(id: FolderWatch(folder: bot.workingDirectory, isShown: tab == .folder)) {
                guard tab == .folder else { return }
                for await _ in FolderWatcher.changes(in: bot.workingURL) { filesRefresh += 1 }
            }
            // The turn may have created or changed files. The watcher above already follows them, but it gives up on a
            // folder it cannot watch (the home folder, some network volumes), so the end of the turn still reads once.
            .onChange(of: live.isWorking) { wasWorking, isWorking in
                if wasWorking && !isWorking && tab == .folder { filesRefresh += 1 }
            }
            // Only the General tab, and only for an Orb that browses, needs to know what the browser has on this Mac.
            .task(id: BrowserCheck(provider: bot.searchProvider, comingBack: browserRecheck,
                                   isShown: tab == .general && bot.capabilities.contains(.browser))) {
                guard tab == .general, bot.capabilities.contains(.browser) else { return }
                let provider = bot.searchProvider
                async let found = model.browserStatus()
                async let key = model.hasSearchKey(for: provider)
                let (newStatus, newKey) = await (found, key)
                guard !Task.isCancelled else { return }
                browserStatus = newStatus
                searchKey = provider == .tinyfish ? newKey : nil
            }
            // The file may have been edited while the panel stayed open: read it again on coming back to the app.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                browserRecheck += 1
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
                        let saved = await model.setIdentity(identityDraft, basedOn: identityBase, of: bot.id)
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
                        let hasChanged = orbAtOpen.map { $0 != bot.orb } ?? false
                        Button("Desfazer mudanças") {
                            if let orbAtOpen { model.update(bot.id) { $0.orb = orbAtOpen } }
                        }
                        .buttonStyle(GhostStyle())
                        .hangsOnLeadingEdge()
                        .disabled(!hasChanged)
                        .opacity(hasChanged ? 1 : 0.4)
                        .help("Volta à aparência de quando esta janela abriu")
                        Spacer()
                        Button("Pronto") { isEditingOrb = false }
                            .buttonStyle(PrimaryPillStyle())
                            .keyboardShortcut(.defaultAction)
                    }
                    .background(Palette.chrome)
                    .sheetSection(2)
                }
                .frame(width: 560, height: editorHeight)
                .onAppear { orbAtOpen = bot.orb }
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
        isShowingBypassInfo = false
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
        if model.takeChatRequest(.renameOrb, of: botID) {
            tab = .general
            isFocusingName = true
        }
        if let requested = model.takeTabRequest(of: botID) { tab = requested }
    }

    /// What the content below the tab bar is: one tab of one Orb. A change of either cross-fades it.
    private struct ContentKey: Hashable {
        var tab: InspectorTab
        var bot: UUID
    }

    private struct FolderWatch: Hashable {
        var folder: String
        var isShown: Bool
    }

    private struct BrowserCheck: Hashable {
        var provider: SearchProvider
        var comingBack: Int
        var isShown: Bool
    }

    private struct FilesKey: Hashable {
        var bot: UUID
        var folder: String
        var refresh: Int
    }

    // MARK: Top of the panel

    /// Who the Orb is, always visible: avatar, name and role (editable, the role in one line), and one quiet line under
    /// them with the way to change its look (the look itself is said in the tip). The folder's actions are on the Pasta
    /// tab. Who made an Orb another made is at the end of the General tab.
    private func header(_ bot: Bot) -> some View {
        let summary = AppearanceSummary.text(for: bot.orb)
        return HStack(alignment: .center, spacing: 12) {
            LiveBotAvatar(botID: bot.id, orb: bot.orb, size: 46, interactive: true, restsWhenIdle: true) // the only part that follows the activity
            VStack(alignment: .leading, spacing: 3) {
                // The name and role fade into the other Orb's, as the content below does.
                ZStack(alignment: .leading) {
                    InspectorHeader(bot: bot, focusName: $isFocusingName)
                        .id(bot.id)
                        .transition(.pageSwap)
                }
                .motion(Motion.crossFade, value: bot.id)
                Button("Personalizar…") {
                    editorHeight = NewBotSheetLayout.height(preferred: 720)
                    isEditingOrb = true
                }
                .buttonStyle(QuietTextStyle())
                .font(Typography.small)
                .fixedSize()
                .help("\(Tip.customizeOrb) (\(summary))")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The same side padding as the form's cards below, so the header, the tabs and the cards share edges.
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.sheetHeaderTop)
        .padding(.bottom, Spacing.m)
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

    /// Two cards that each fold to one line ("Modelo e permissões", "Pode usar"), then, under them, who made the Orb and the way
    /// to delete it. A card with a problem (a model that cannot answer, a browser not ready) shows open until it is gone.
    @ViewBuilder
    private func generalTab(_ bot: Bot) -> some View {
        let info = model.modelInfo(forModel: bot.model)
        let unavailable = model.modelUnavailableNote(bot.model)
        let modelIsOpen = InspectorFold.isOpen(stored: modelFoldOpen,
                                               hasProblem: ModelCardSummary.hasProblem(unavailableNote: unavailable))
        let browserHasProblem = BrowserPickerCopy.hasProblem(capabilities: bot.capabilities, status: browserStatus,
                                                             provider: bot.searchProvider, hasKey: searchKey)
        let capabilitiesAreOpen = InspectorFold.isOpen(stored: capabilitiesFoldOpen, hasProblem: browserHasProblem)
        modelCard(bot, info: info, unavailable: unavailable, isOpen: modelIsOpen)
        // Read here, once per pass, and only for the open card that shows them.
        let skillNames = capabilitiesAreOpen ? model.skills(for: bot.id).map(\.name) : []
        let connectorNames = capabilitiesAreOpen ? model.connectorNames(for: bot.id) : []
        capabilitiesCard(bot, isOpen: capabilitiesAreOpen, hasProblem: browserHasProblem,
                         skillNames: skillNames, connectorNames: connectorNames)
    }

    /// A folding row's click: the part stores the other state (a part held open by a problem keeps what it had).
    private func toggleFold(_ stored: Binding<Bool>, isOpen: Bool, hasProblem: Bool) {
        let next = InspectorFold.stored(afterClickWhen: isOpen, stored: stored.wrappedValue, hasProblem: hasProblem)
        stored.wrappedValue = next // the height changes at once; what comes fades in (`foldContent`)
    }

    // MARK: Modelo e permissões

    /// The model's name on the folded card's line.
    private func modelSummary(_ name: String) -> some View {
        Text(name)
            .foregroundStyle(Palette.faint)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(name) // cut in a narrow panel: the hover text has it whole
    }

    /// Folded: one line with the model's name and, when something needs a look, a mark. Open: the model, its effort (when
    /// the model has levels) and the permission mode. The mode's description is the picker's hover text; only the mode that
    /// never asks keeps a line, and a model that cannot answer says why.
    private func modelCard(_ bot: Bot, info: ProviderModel?, unavailable: String?, isOpen: Bool) -> some View {
        let warning = ModelCardSummary.warning(mode: bot.permissionMode, unavailableNote: unavailable)
        let modelName = ModelCardSummary.modelText(selection: bot.model, defaultModel: model.defaultModel,
                                                   name: { model.modelName($0) })
        return Section {
            FoldHeader(title: "Modelo e permissões", isOpen: isOpen, tip: Tip.toggleModelCard(isOpen: isOpen),
                       spokenSummary: [modelName, warning].compactMap { $0 }.joined(separator: ", "),
                       action: { toggleFold($modelFoldOpen, isOpen: isOpen, hasProblem: unavailable != nil) }) {
                HStack(spacing: Spacing.s) {
                    // Whole; cut, when at least 80 pt are left; or left out, when only "…" would show (244 pt). The
                    // warning stays in every case, and VoiceOver hears the name in the row's value.
                    ViewThatFits(in: .horizontal) {
                        modelSummary(modelName).fixedSize(horizontal: true, vertical: false)
                        modelSummary(modelName).frame(maxWidth: 80, alignment: .trailing)
                        Color.clear.frame(width: 0, height: 0)
                    }
                    if let warning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(Typography.small)
                            .foregroundStyle(Palette.warn)
                            .help(warning)
                            .accessibilityHidden(true)
                    }
                }
            }
            if isOpen {
                ModelPicker(selection: binding(\.model, of: bot))
                    .foldContent()
                // A row like "Permissões": only for a model whose catalog lists thinking levels.
                if let levels = info?.efforts {
                    Picker("Esforço", selection: binding(\.effort, of: bot)) {
                        Text(ReasoningEffort.defaultLabel(for: info)).tag("")
                        if !bot.effort.isEmpty && !levels.contains(bot.effort) {
                            Text(ReasoningEffort.label(bot.effort)).tag(bot.effort)
                        }
                        ForEach(levels, id: \.self) { Text(ReasoningEffort.label($0)).tag($0) }
                    }
                    .help(ReasoningEffort.note(bot.effort, for: info) ?? "")
                    .foldContent()
                }
                if let unavailable {
                    Text(unavailable)
                        .capabilityCaption()
                        .foregroundStyle(Palette.warn)
                        .textSwap(unavailable)
                        .foldContent()
                }
                Picker("Permissões", selection: binding(\.permissionMode, of: bot).confirmingBypass {
                    isConfirmingBypass = true
                }) {
                    ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
                }
                .help(bot.permissionMode.summary)
                .foldContent()
                if bot.permissionMode == .bypass {
                    bypassLine(bot.permissionMode.summary)
                        .foldContent()
                }
            }
        }
        .bypassConfirmation(isPresented: $isConfirmingBypass) {
            model.update(bot.id) { $0.permissionMode = .bypass }
        }
    }

    /// "Roda tudo sem perguntar" in the warning color, with a small ⓘ that says it all (hover or click).
    private func bypassLine(_ summary: String) -> some View {
        HStack(spacing: Spacing.s) {
            Text(ModelCardSummary.bypassLine)
                .font(Typography.small)
                .foregroundStyle(Palette.warn)
            Button("Sobre este modo", systemImage: "info.circle") { isShowingBypassInfo.toggle() }
                .labelStyle(.iconOnly)
                .buttonStyle(CircleGhostStyle(side: 20, fontSize: 11)) // 20 pt target with hover around the ⓘ
                .foregroundStyle(Palette.warn)
                .iconTip(summary, label: "Sobre este modo")
                .popover(isPresented: $isShowingBypassInfo, arrowEdge: .bottom) {
                    Text(summary)
                        .font(Typography.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Spacing.m)
                        .frame(width: 280, alignment: .leading)
                }
            Spacer(minLength: 0)
        }
    }

    // MARK: Pode usar

    /// Folded: one line with a small icon for each thing the Orb may use, dimmed for what is off. Open: a switch row for
    /// each (the description is the row's hover text, the links sit after the title). Under the card, who made the Orb and
    /// "Apagar".
    private func capabilitiesCard(_ bot: Bot, isOpen: Bool, hasProblem: Bool, skillNames: [String],
                                  connectorNames: [String]) -> some View {
        let enabled = Capability.allCases.filter { bot.capabilities.contains($0) }.count
        return Section {
            FoldHeader(title: "Pode usar", isOpen: isOpen, tip: Tip.toggleCapabilities(isOpen: isOpen),
                       spokenSummary: CapabilityStrip.spokenCount(enabled: enabled, total: Capability.allCases.count),
                       action: { toggleFold($capabilitiesFoldOpen, isOpen: isOpen, hasProblem: hasProblem) }) {
                capabilityStrip(bot)
            }
            if isOpen {
                ForEach(Capability.allCases) { capability in
                    capabilityRow(capability, of: bot)
                }
                // What the Orb gets from the catalog pages, read only: which ones, and the way to change them.
                if !skillNames.isEmpty {
                    scopeNote("Skills", names: skillNames, tip: Tip.skillsPage) { model.selection = .skills }
                }
                if !connectorNames.isEmpty {
                    scopeNote("Conectores", names: connectorNames, tip: Tip.manageConnectors) { model.selection = .connectors }
                }
            }
        } footer: {
            panelFooter(bot)
        }
    }

    /// The icons of the folded row: VoiceOver gets the count from the row itself.
    private func capabilityStrip(_ bot: Bot) -> some View {
        HStack(spacing: Spacing.s) {
            ForEach(Capability.allCases) { capability in
                Image(systemName: capability.symbol)
                    .font(Typography.label)
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 20, height: 20)
                    .background(Palette.raised, in: .rect(cornerRadius: 6))
                    .opacity(CapabilityStrip.opacity(isOn: bot.capabilities.contains(capability)))
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func capabilityRow(_ capability: Capability, of bot: Bot) -> some View {
        let isOn = bot.capabilities.contains(capability)
        if capability == .browser {
            BrowserPickerRows(botID: bot.id, isOn: capabilityBinding(capability, of: bot), status: browserStatus, hasKey: searchKey)
        } else {
            Toggle(isOn: capabilityBinding(capability, of: bot)) {
                // The link sits after the title when both fit; in the narrow panel it drops under it, whole (inline it
                // broke letter by letter).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        capabilityTitle(capability)
                        if isOn { inlineLink(capability) }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        // Two lines before an ellipsis, as "Navegar na web" ("Controlar apps d…" at 244 pt).
                        capabilityTitle(capability).lineLimit(2)
                        // Under the title text, past the icon's frame, as the browser's pickers.
                        if isOn { inlineLink(capability, leadingDot: false).padding(.leading, BrowserPickerRows.indent) }
                    }
                }
                .lineLimit(1)
            }
            .help(Tip.capability(capability))
            .foldContent()
        }
    }

    /// The icons share one width, so the titles start on one x whatever the symbol (terminal, globe, window…).
    private func capabilityTitle(_ capability: Capability) -> some View {
        Label {
            Text(capability.label)
        } icon: {
            Image(systemName: capability.symbol).frame(width: 20)
        }
        .layoutPriority(1)
    }

    /// The way on from a row, in quiet text after its title: the macOS permissions that "Controlar apps do Mac" relies on
    /// (Automação, Acessibilidade, Gravação de Tela, which live in Ajustes), and the connectors' page with how many are on.
    @ViewBuilder
    private func inlineLink(_ capability: Capability, leadingDot: Bool = true) -> some View {
        switch capability {
        case .computerUse:
            inlineLink(SettingsTab.permissions.title, tip: Tip.macPermissions, leadingDot: leadingDot) {
                SettingsRouter.open(.permissions, using: openSettings)
            }
        case .connectors:
            let counts = model.connectorCounts(for: botID)
            inlineLink(CapabilityCopy.connectorsLine(enabled: counts.enabled, total: counts.total, anyInstalled: !model.connectors.isEmpty),
                       tip: Tip.manageConnectors, leadingDot: leadingDot) { model.selection = .connectors }
        case .terminal, .browser:
            EmptyView()
        }
    }

    /// "Skills: Resumir e Traduzir" with "Gerenciar" after it, in the quiet text of the links above. Cut in a narrow
    /// panel, the whole list is the hover text.
    private func scopeNote(_ title: String, names: [String], tip: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text("\(title): \(OrbScopeText.list(names, limit: 3))")
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(names.joined(separator: ", "))
            Text("·").foregroundStyle(Palette.faint).accessibilityHidden(true)
            Button("Gerenciar", action: action)
                .buttonStyle(QuietTextStyle())
                .fixedSize()
                .help(tip)
                .accessibilityLabel("Gerenciar \(title.lowercased())")
        }
        .font(Typography.small)
        .foldContent()
    }

    private func inlineLink(_ title: String, tip: String, leadingDot: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            if leadingDot { Text("·").foregroundStyle(Palette.faint).accessibilityHidden(true) }
            Button(title, action: action)
                .buttonStyle(QuietTextStyle())
                .help(tip)
        }
        .font(Typography.small)
        .lineLimit(1)
        .transition(.quiet)
    }

    /// Under the cards, quietly: who made an Orb another made, and "Apagar", gray until the pointer is over it. Both sit
    /// outside the cards, on the same inset as the notes under a section.
    private func panelFooter(_ bot: Bot) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if bot.createdByName != nil {
                CreatedByLine(bot: bot) // MultiOrb (WP3)
            }
            // One sheet for the sidebar and here (DeleteOrbDialog.swift).
            Button("Apagar \(bot.name)…", role: .destructive) { model.askToDelete(bot.id) }
                .buttonStyle(QuietDeleteStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, FormFootnote<EmptyView>.headingInset)
        .padding(.top, 8)
    }

    // MARK: Pasta e acessos

    @ViewBuilder
    private func folderTab(_ bot: Bot) -> some View {
        Section {
            folderRow(bot)
            folderActions(bot)
            folderControls(bot)
        } header: {
            // Not "Pasta": that is the tab's own name, right above.
            Text("Onde trabalha").sectionTitleStyle()
        } footer: { FormFootnote {
            if let folderProblem {
                Text(folderProblem).foregroundStyle(Palette.warn)
            }
        } }

        if let file = instructionFile {
            Section {
                Toggle(isOn: instructionsTrustBinding(file, of: bot)) {
                    // What it means is said once, in the section's footer below.
                    Label("Confiar nas instruções desta pasta", systemImage: "checkmark.shield")
                }
                Button("Ver \(file.fileName) no Finder", systemImage: "doc.text.magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting([bot.workingURL.appending(path: file.fileName)])
                }
                .help(Tip.showInstructions)
                .chipButton()
            } header: {
                Text("Instruções da pasta").sectionTitleStyle()
            } footer: { FormFootnote {
                Text(InstructionsText.footer(for: file, name: bot.name, trustedHash: bot.trustedInstructionsHash))
            } }
            // What is read from the folder arrives by fading (`.quiet`), never by animating the height of a list that may
            // be long (§2.13).
            .transition(.quiet)
        }

        Section {
            if bot.permissionRules.isEmpty {
                PanelEmptyNote("Nenhuma liberação ainda", systemImage: "checkmark.shield",
                               detail: "Ao aprovar um pedido, escolha “Sempre permitir…” e ela aparece aqui.")
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
            Text("Liberações").sectionTitleStyle()
        } footer: { FormFootnote {
            Text(PermissionMode.grantsNote).help(PermissionMode.grantsNoteDetail)
        } }
        // Bound to the rules themselves (a short list), so only a grant coming or going moves anything.
        .animateChanges(of: bot.permissionRules)

        filesSection(bot)
    }

    /// The folder the Orb works in, said as a place: its name ("Pasta pessoal" for the home folder) over its path, and
    /// "Mudar…" at the end of the line.
    private func folderRow(_ bot: Bot) -> some View {
        let isHome = EmptyChatContent.usesHome(bot)
        return HStack(spacing: Spacing.s) {
            Image(systemName: isHome ? "house" : "folder")
                .foregroundStyle(Palette.muted)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                // Two lines before a cut: beside "Mudar…" at 244 pt, one line made "Pasta pessoal" into "Pas…soal".
                Text(isHome ? "Pasta pessoal" : bot.workingURL.lastPathComponent)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(OrbFolder.display(bot.workingURL)) // "~" for the home folder too, as in Conectores
                    .font(Typography.small.monospaced())
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            .help(bot.workingURL.path)
            Spacer(minLength: 4)
            changeFolderMenu(bot)
        }
    }

    /// Open the folder where the Orb works, in the Finder or in the Terminal: the two things people do most with it. Chips
    /// like the ones of the rows around (one line when they fit, one under the other in a narrow panel); off while the
    /// folder is gone, which "Recriar" below brings back.
    private func folderActions(_ bot: Bot) -> some View {
        let chips = Group {
            Button("Abrir no Finder", systemImage: "folder") { OrbFolder.showInFinder(bot.workingURL) }
                .help(Tip.openFolderInFinder(bot.name))
            Button("Abrir no Terminal", systemImage: "terminal") { OrbFolder.openInTerminal(bot.workingURL) }
                .help(Tip.openFolderInTerminal(bot.name))
        }
        .chipButton()
        .disabled(listing?.folder == .missing)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                chips
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) { chips }
        }
    }

    /// "Mudar…": choose another folder, or switch between the home folder and one of the Orb's own.
    private func changeFolderMenu(_ bot: Bot) -> some View {
        let state = listing?.folder
        return Menu {
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
            Text("Mudar…")
        }
        .menuStyle(.button)
        // Without the system's blue arrow, the same chip as "Recriar" and the others; the "…" says it opens more.
        .menuIndicator(.hidden)
        .chipButton()
        .fixedSize()
        .help(changeFolderTip(bot, state: state))
        .accessibilityLabel("Mudar pasta")
    }

    /// What "Mudar…" offers besides choosing another folder, in its hover text (it used to be a gray line under the row).
    private func changeFolderTip(_ bot: Bot, state: OrbFolder.State?) -> String {
        guard state == .ownFolder else { return Tip.changeFolder }
        return "\(Tip.changeFolder). Na pasta pessoal, \(bot.name) volta a trabalhar nela; a pasta atual e o que há nela ficam como estão."
    }

    /// What goes with the folder's line: the warning when it is gone (and the way to bring it back), and what an own
    /// folder would loosen.
    @ViewBuilder
    private func folderControls(_ bot: Bot) -> some View {
        let state = listing?.folder
        // Stays in sight, not in a hover text: "Criar pasta própria" changes what the Orb may do without asking.
        if state == .noOwnFolder {
            OwnFolderNote(name: bot.name)
                .transition(.quiet)
        }
        if state == .missing {
            Label("Pasta não encontrada", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warn)
                .transition(.quiet)
            Text("Ela foi apagada, renomeada ou está em um disco desconectado. \(bot.name) não consegue rodar comandos até você escolher outra pasta ou recriar esta.")
                .font(Typography.small)
                .foregroundStyle(Palette.muted)
                .transition(.quiet)
            Button("Recriar", systemImage: "folder.badge.plus") { attempt { try model.recreateFolder(of: bot.id) } }
                .chipButton()
                .help(Tip.recreateFolder)
                .transition(.quiet)
        }
    }

    /// Changed (git) and recently modified files of the Orb's folder. Not shown for the home folder, which is not scanned.
    @ViewBuilder
    private func filesSection(_ bot: Bot) -> some View {
        if let listing, listing.folder != .missing, listing.snapshot != .home {
            Section {
                if listing.snapshot == .unreadable {
                    PanelEmptyNote("Sem acesso à pasta", systemImage: "lock",
                                   detail: "O macOS pode estar bloqueando: libere em Ajustes do Sistema → Privacidade e Segurança.")
                        .transition(.quiet)
                } else if listing.files.isEmpty {
                    PanelEmptyNote("Nenhum arquivo ainda", systemImage: "doc",
                                   detail: "O que \(bot.name) criar ou mudar nesta pasta aparece aqui.")
                        .transition(.quiet)
                }
                // The git column only when some file has a marker: a folder without git lists names from the edge.
                let showsMarkers = listing.files.contains { $0.marker != nil }
                ForEach(listing.files) { file in
                    WorkspaceFileRow(file: file, showsMarker: showsMarkers)
                }
            } header: {
                HStack {
                    Text("Arquivos").sectionTitleStyle()
                    Spacer()
                    Button("Atualizar", systemImage: "arrow.clockwise") { filesRefresh += 1 }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .iconTip(Tip.refreshFolder)
                }
            } footer: { FormFootnote {
                if !listing.files.isEmpty {
                    Text("Alterados no git primeiro, depois os mais recentes.")
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
        // Each routine is a card of its own, with no heading: "Rotinas" is already the tab's name right above.
        if routines.isEmpty {
            Section {
                PanelEmptyNote("Nenhuma rotina ainda", systemImage: "clock.badge",
                               detail: "Peça a \(bot.name) no chat, como “verifique meus e-mails a cada 30 minutos”, ou crie uma aqui.")
            }
        }
        ForEach(routines) { routine in
            Section {
                RoutineRow(routine: routine) { editingRoutine = routine }
            }
        }
        Section {
            let newRoutine = Button("Nova rotina…", systemImage: "plus") {
                editingRoutine = Routine(name: "", botID: bot.id, prompt: "", schedule: .daily(hour: 9, minute: 0))
            }
            .buttonStyle(SecondaryPillStyle())
            .controlSize(.small)
            .help(Tip.newRoutine)
            let allRoutines = Button("Ver todas", systemImage: "arrow.up.right") { model.selection = .routines }
                .buttonStyle(GhostStyle(tint: Palette.accentText))
                .controlSize(.small)
                .help(Tip.allRoutines)
            // Side by side when both fit; at 244 pt "Ver todas" goes under, hanging on the leading edge instead.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    newRoutine
                    Spacer(minLength: 4)
                    allRoutines.hangsOnTrailingEdge()
                }
                VStack(alignment: .leading, spacing: 6) {
                    newRoutine
                    allRoutines.hangsOnLeadingEdge()
                }
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
                identityBase = identityDraft
                identitySaveFailed = false
                isEditingIdentity = true
            }
        }, showAll: { kind in
            memorySheetKind = kind
            isShowingMemory = true
        })
        // No `.id(bot.id)` here: the Form around the tabs is already keyed by tab and Orb (`contentKey`), so its search
        // state is rebuilt per Orb.
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
        // Every name when they all fit (244 pt, the panel's minimum, does with the 20 pt sides: about 195 pt of 204);
        // narrower than that, only the chosen tab keeps its name (the rest keep their tip and their VoiceOver label)
        // instead of each one cut ("Memó…") or squeezed.
        ViewThatFits(in: .horizontal) {
            tabs(showsEveryName: true)
            tabs(showsEveryName: false)
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
        // For VoiceOver this is one named group of the tab buttons themselves (each says whether it is the selected one).
        // Not a segmented picker standing in for them: its segments are laid out on their own and point beside the
        // buttons, so a click by accessibility landed on the next tab.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Seções do painel")
    }

    private func tabs(showsEveryName: Bool) -> some View {
        HStack(alignment: .top, spacing: 2) {
            ForEach(InspectorTab.allCases) { tab in
                let isSelected = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .frame(height: 16)
                            .font(Typography.text)
                        if showsEveryName || isSelected {
                            // One weight for every state: the semibold of the chosen tab widened it and moved its neighbors.
                            // `fixedSize` so the bar measures the whole name and `ViewThatFits` can tell when it does not fit.
                            Text(tab.shortTitle)
                                .font(Typography.small.weight(.medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .foregroundStyle(isSelected ? Palette.ink : Palette.muted)
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                    .padding(.horizontal, 2)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: Radius.small)
                                .fill(Palette.ghostSelected)
                                .matchedGeometryEffect(id: "destaque", in: highlight)
                        }
                    }
                    .contentShape(.rect(cornerRadius: Radius.small))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(tab.title)
            }
        }
    }
}

/// The Orb's name and role, edited in place. A name with only blanks is not accepted: the old one comes back.
private struct InspectorHeader: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    /// Set by the panel to ask for the cursor in the name; the header puts it there and clears it.
    @Binding var focusName: Bool
    @State private var name: String
    @State private var role: String
    @FocusState private var focus: Field?
    /// The role's field is on screen (from the click on the text until the focus leaves it).
    @State private var isEditingRole = false
    /// Why the name was not kept as typed (blank, or cut at the limit): shown under the field for a few seconds.
    @State private var nameProblem: String?

    private enum Field { case name, role }

    init(bot: Bot, focusName: Binding<Bool>) {
        self.bot = bot
        _focusName = focusName
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
            if let nameProblem {
                Text(nameProblem)
                    .font(Typography.small)
                    .foregroundStyle(Palette.warn)
                    .transition(.quiet)
            }
            // At rest the role is one line, ending in "…" when it is longer (all of it in the hover text); a click opens the
            // field, which grows with what is typed. (A one-line field would show its own first line and scroll the rest away.)
            if isEditingRole {
                TextField("Papel", text: $role, prompt: Text("Papel"), axis: .vertical)
                    .lineLimit(1...4)
                    .font(Typography.label)
                    .foregroundStyle(Palette.muted)
                    .focused($focus, equals: .role)
                    .onSubmit { focus = nil }
                    // Return ends the edit (the role is one line that wraps), as in the name above.
                    .onKeyPress(.return) {
                        focus = nil
                        return .handled
                    }
                    .onAppear { focus = .role }
            } else {
                // A plain button with the same look, so the keyboard reaches it (Space/Return open the field).
                Button { isEditingRole = true } label: {
                    Text(role.isEmpty ? "Papel" : role)
                        .font(Typography.label)
                        .foregroundStyle(role.isEmpty ? Palette.faint : Palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The whole role is one hover away when the line cuts it.
                .help(role.isEmpty ? "Clique para escrever o papel" : role)
                .accessibilityLabel("Papel: \(role)")
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
        // Typing again (the commit itself rewrites `name` while the field is not focused) takes the note away.
        .onChange(of: name) { if focus == .name { nameProblem = nil } }
        .task(id: nameProblem) {
            guard nameProblem != nil, (try? await Task.sleep(for: .seconds(5))) != nil else { return }
            nameProblem = nil
        }
        .onChange(of: focusName) {
            guard focusName else { return }
            focusName = false
            focus = .name
        }
        .onChange(of: bot.name) { _, new in if focus != .name { name = new } }
        .onChange(of: bot.role) { _, new in if focus != .role { role = new } }
        // The view can go away with a field still focused (panel closed, another Orb chosen): nothing else saves it then.
        .onDisappear {
            if name != bot.name { commitName(reporting: false) }
            if role != bot.role { commitRole() }
        }
    }

    private func commitName(reporting: Bool = true) {
        let problem = NameCheck.problem(name)
        if !model.rename(bot.id, to: name) { name = bot.name }
        else if let current = model.bot(bot.id) { name = current.name }
        guard reporting, let problem else { return }
        nameProblem = problem
        AccessibilityNotification.Announcement(problem).post()
    }

    private func commitRole() {
        model.setRole(bot.id, to: role.replacingOccurrences(of: "\n", with: " "))
        if let current = model.bot(bot.id) { role = current.role }
    }
}

/// A file of the folder: a git marker (or nothing for a recent file), its name and when it changed.
private struct WorkspaceFileRow: View {
    let file: WorkspaceFile
    /// Whether the list has a git column: off when no file of it has a marker, so no row starts with an empty gap.
    var showsMarker = true

    var body: some View {
        // A button, so the row takes keyboard focus and hovers like the panel's other rows. A click reveals at once (no
        // waiting for a double click that may not come); the double click also opens, through the simultaneous gesture.
        Button(action: reveal) { content }
            .buttonStyle(FoldRowStyle())
            .simultaneousGesture(TapGesture(count: 2).onEnded(open))
            .contextMenu {
                Button("Mostrar no Finder", action: reveal)
                Button("Abrir", action: open)
            }
            .help("Clique para mostrar no Finder; duas vezes para abrir")
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "Abrir", open)
    }

    private var content: some View {
        HStack(spacing: 8) {
            if showsMarker {
                Text(file.marker?.rawValue ?? "")
                    .font(Typography.small.monospaced().weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 22)
                    .help(file.marker?.help ?? "")
            }
            Text(file.path)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if let modified = file.modified {
                Text(RelativeTime.text(modified))
                    .font(Typography.small)
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
            }
        }
    }

    private var color: Color {
        switch file.marker {
        case .added, .untracked: Palette.ok
        case .deleted, .conflict: Palette.warn
        default: Palette.muted
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
    @FocusState private var deleteIsFocused: Bool

    /// One flag for the trash can's opacity and its animation, so the two cannot drift apart.
    private var showsDelete: Bool { isHovering || deleteIsFocused }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.name)
                        .font(Typography.text.weight(.medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(routine.schedule.label)
                        .font(Typography.label)
                        .foregroundStyle(Palette.muted)
                    if let mismatch = RoutineText.nameMismatch(of: routine) {
                        Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                            .font(Typography.small)
                            .foregroundStyle(Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Spacing.s)
                Toggle("Ativa", isOn: Binding(get: { routine.isEnabled }, set: { model.setRoutineEnabled(routine.id, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                    .accessibilityLabel("Ativar \(routine.name)")
                    .disabled(!routine.canBeEnabled())
                    .help(routine.canBeEnabled() ? Tip.routineToggle(isOn: routine.isEnabled) : Tip.routineDatePassed)
            }
            if let goal = routine.goal { GoalProgressView(goal: goal, font: Typography.label, showsNote: false) }
            VStack(alignment: .leading, spacing: 6) {
                RoutineNextLine(routine: routine)
                RoutineLastLine(routine: routine)
            }
            footer
        }
        .padding(.vertical, Spacing.xs)
        // The task the Orb just scheduled is marked for a moment (`AppModel.freshRoutine`).
        .background {
            RoundedRectangle(cornerRadius: Radius.medium)
                .fill(Palette.accent.opacity(model.freshRoutine == routine.id ? 0.12 : 0))
                .padding(.horizontal, -Spacing.s).padding(.vertical, -Spacing.xs)
        }
        .animateChanges(of: routine.isEnabled)
        .animateChanges(of: model.freshRoutine)
        .animateChanges(of: isConfirmingDelete)
        .onHover { isHovering = $0 }
        .sensoryFeedback(.alignment, trigger: routine.isEnabled)
        .transition(.adapted(.arrive, reduceMotion: reduceMotion))
    }

    /// Like the Rotinas page: with the Orb busy the run waits for it (`runRoutine` queues it). The three swap in place,
    /// cross-fading, so the row does not shift.
    private func runControl(_ state: RoutineRunState) -> some View {
        RoutineRunControl(state: state) { model.runRoutine(routine.id) }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 4) {
            if isConfirmingDelete {
                Text("Apagar esta rotina?")
                    .font(Typography.label)
                    .lineLimit(1)
                    .foregroundStyle(Palette.secondary)
                Spacer(minLength: 4)
                Button("Cancelar") { isConfirmingDelete = false }
                    .buttonStyle(GhostStyle())
                Button("Apagar", role: .destructive) { model.deleteRoutine(routine.id) }
                    .buttonStyle(GhostStyle(tint: Palette.danger))
                    .hangsOnTrailingEdge()
            } else {
                // "Rodar agora" and "Editar" together at the start, the same pill; the trash can at the end. At the narrowest
                // panel only the pencil fits; it keeps "Editar" as its tip and VoiceOver label.
                let editButton = Button("Editar", systemImage: "pencil", action: edit)
                    .buttonStyle(SecondaryPillStyle())
                    .help(Tip.editRoutine)
                // Read once: both layouts below are made.
                let runState = RoutineRunState(isRunning: model.isRoutineRunning(routine.id),
                                               isQueued: model.isRoutineQueued(routine.id))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.controlGap) {
                        runControl(runState)
                        editButton
                    }
                    HStack(spacing: Spacing.controlGap) {
                        runControl(runState)
                        editButton.labelStyle(.iconOnly)
                    }
                }
                .controlSize(.small)
                Spacer(minLength: 4)
                Button("Apagar “\(routine.name)”", systemImage: "trash") { isConfirmingDelete = true }
                    .panelTrashButton()
                    .help(Tip.deleteRoutine)
                    .padding(.trailing, -Spacing.xs)
                    .focused($deleteIsFocused)
                    // Only under the pointer, like the lembranças: a list of routines, not of trash cans. It takes Tab
                    // too, so it must also show while it has the keyboard focus.
                    .opacity(showsDelete ? 1 : 0)
                    .animation(Motion.hover(showsDelete), value: showsDelete)
            }
        }
        .frame(minHeight: 26)
        .transition(.opacity)
    }
}

/// "Próxima: amanhã às 01:03 · em 5 h 59 min", kept right as the minutes pass; "Pausada" while it is off.
private struct RoutineNextLine: View {
    let routine: Routine

    var body: some View {
        if routine.isEnabled {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                // `nextRun` walks the cron expression: once per tick, not once per use.
                let next = routine.nextRun
                let isLate = RoutineText.isLate(next, now: context.date)
                Label {
                    if isLate {
                        Text(RoutineText.late(next, now: context.date))
                    } else {
                        // "em 9 h 57 min" never breaks inside.
                        Text("Próxima: \(RoutineText.dayAndTime(next, now: context.date)) · \(RoutineText.relative(until: next, now: context.date).replacing(" ", with: "\u{A0}"))")
                    }
                } icon: {
                    Image(systemName: isLate ? "clock.badge.exclamationmark" : "arrow.forward.circle")
                }
                .font(Typography.label)
                .foregroundStyle(Palette.secondary)
            }
        } else if RoutineText.isConcluded(routine) {
            // One mark per state: the glyph and the switch already say it is off, so the line is only the word.
            Text("Concluída")
                .font(Typography.label)
                .foregroundStyle(Palette.muted)
        } else {
            Text("Pausada")
                .font(Typography.label)
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
                Image(systemName: run.wasStopped ? "stop.circle" : run.succeeded ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(run.wasStopped ? Palette.muted : run.succeeded ? Palette.ok : Palette.danger)
            }
            .font(Typography.label)
            .foregroundStyle(Palette.muted)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Última execução \(run.succeeded ? "deu certo" : "não deu certo"), \(RoutineText.stamp(run.date)). \(run.summary)")
            // A click shows the whole report (as the lembranças do), another folds it back.
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
            // Without a pointer the report is reached by this action (VoiceOver's actions rotor).
            .accessibilityAction(named: isExpanded ? "Recolher relatório" : "Ver relatório inteiro") { isExpanded.toggle() }
            .help(isExpanded ? "Clique para recolher" : "Clique para ver o relatório inteiro")
            .motion(Motion.content, value: isExpanded)
        } else {
            Label(routine.lastResult ?? "Ainda não rodou", systemImage: "circle.dashed")
                .font(Typography.label)
                .foregroundStyle(Palette.faint)
                .lineLimit(2)
        }
    }
}

enum RelativeTime {
    /// "há 5 min", "em 2 h", "há 3 semanas": for dates a little before or after now. "agora" within a minute either way,
    /// never "em 0 seg." for something just saved. Written by hand, not with `RelativeDateTimeFormatter`: its short style
    /// says "há 39 min." and "há 1 sem." (with the abbreviation's period), where the rest of the app (the routines'
    /// "em 9 h 57 min") has none.
    static func text(_ date: Date, now: Date = .now) -> String {
        let seconds = date.timeIntervalSince(now)
        guard abs(seconds) >= 60 else { return "agora" }
        return (seconds < 0 ? "há " : "em ") + span(abs(seconds))
    }

    /// "5 min", "2 h", "1 dia", "3 semanas", "1 mês", "2 anos": the largest unit that fits, rounded down.
    static func span(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h" }
        let days = hours / 24
        if days < 7 { return days == 1 ? "1 dia" : "\(days) dias" }
        if days < 30 { return days / 7 == 1 ? "1 semana" : "\(days / 7) semanas" }
        if days < 365 { return days / 30 == 1 ? "1 mês" : "\(days / 30) meses" }
        return days / 365 == 1 ? "1 ano" : "\(days / 365) anos"
    }
}

/// What "Criar pasta própria" would loosen, with the folder it would make. The folder is looked up off the main actor
/// (`availableURL` hits the disk, up to a thousand times when names are taken), once per name, not on every render.
private struct OwnFolderNote: View {
    let name: String
    @State private var path: String?

    var body: some View {
        Text(FolderNoteText.ownFolder(name: name, path: path))
            .font(Typography.small)
            .foregroundStyle(Palette.muted)
            .task(id: name) {
                let orbName = name
                path = await Task.detached {
                    OrbFolder.display(OrbFolder.availableURL(for: orbName, in: OrbFolder.defaultBase))
                }.value
            }
    }
}

enum FolderNoteText {
    /// The sentence under the folder's row when the Orb has none of its own. `path` is nil until the folder is looked up.
    static func ownFolder(name: String, path: String?) -> String {
        let place = path.map { "uma pasta própria (\($0))" } ?? "uma pasta própria"
        return "Em \(place), \(name) grava e edita arquivos sem pedir, mesmo em “Perguntar antes”."
    }
}

enum InstructionsText {
    static func footer(for file: FolderInstructions, name: String, trustedHash: String?) -> String {
        if file.isTrusted(by: trustedHash) { return "\(file.fileName) vale como instruções de \(name) nesta pasta." }
        if trustedHash != nil {
            return "\(file.fileName) mudou desde que você confiou nele: \(name) o lê só como referência, até você confiar de novo."
        }
        return "\(file.fileName) é lido por \(name) como material de referência, não como ordens. Confie para valer como instruções, só em pastas suas."
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
            .padding(.horizontal, Spacing.sheetEdge)
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

/// What a section of the Orb's panel says while it has nothing to list: a short title with its symbol and one gray
/// line on what will fill it (the same in Rotinas, Liberações, Arquivos and Memória).
struct PanelEmptyNote: View {
    let title: String
    let symbol: String
    let detail: String

    init(_ title: String, systemImage: String, detail: String) {
        self.title = title
        self.symbol = systemImage
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(Typography.text.weight(.medium))
                .foregroundStyle(Palette.ink)
            Text(detail)
                .font(Typography.label)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// "Apagar" at the end of the General tab: small and gray (as readable as the quiet links, it is the only way out), red only
/// with the pointer over it.
private struct QuietDeleteStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.label)
            .foregroundStyle(configuration.isPressed || isHovering ? Palette.danger : Palette.muted)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(Motion.hover(isHovering), value: isHovering)
    }
}
