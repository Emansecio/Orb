import SwiftUI

/// The message field of one Orb's chat. Takes the Orb's id: it shows nothing of the `Bot` itself (its chips read
/// their own parts), so changes to the Orb's settings do not re-render it.
///
/// It stays usable while the Orb works: a message sent then steers the task (↩, handed to the model at its next step)
/// or waits for its end (⇥), see `AppModel+Steering`; ⌘↩ stops and sends. Stop (⌘.) is always one key away. Attachments live in the Orb's `ComposerLane`, so
/// they survive switching to another Orb and back.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let botID: UUID
    /// Something is being dragged over the chat (`ChatView` takes the drop): the card lights up where it will land.
    var isDropTargeted = false

    @FocusState private var isFocused: Bool
    @State private var isImporting = false
    @State private var isModelOpen = false
    /// What the context meter and the "conversa longa" card show (measured by `ContextGaugeDriver`).
    @State private var gauge = ContextGauge()
    /// The composer is too narrow for words on its chips: only their icons show.
    @State private var isCompact = false
    /// The skill highlighted in the `/` suggestions.
    @State private var slashIndex = 0
    /// Esc closed the suggestions; any change to the draft brings them back.
    @State private var isSlashDismissed = false
    /// The edit being sent would drop actions that changed things on the Mac: waiting for the person to say yes.
    @State private var isConfirmingEdit = false

    /// Card width below which the chips lose their words.
    private nonisolated static let compactBelow: CGFloat = 520

    private var draft: Binding<String> {
        Binding(
            get: { model.drafts[botID, default: ""] },
            set: { model.editDraft($0, for: botID) } // typing: the Orb watches you (the app's own changes use setDraft)
        )
    }

    private var lane: ComposerLane { model.composerLane(botID) }
    private var isWorking: Bool { model.live(botID).isWorking }
    /// Stops at the first character that is not a blank: no copy of a long pasted draft, however often the body asks.
    private var hasText: Bool { draft.wrappedValue.contains { !$0.isWhitespace } }
    private var hasContent: Bool { ComposerAction.hasContent(hasText: hasText, pictures: lane.pictures.count, files: lane.files.count) }
    /// A message can be sent: any time the Orb is free, and while it works on your chat (it is queued). Not while a
    /// picture is still being prepared: it would miss this message and ride along with the next one.
    private var canSend: Bool {
        ComposerAction.canSend(hasContent: hasContent, isWorking: isWorking, canSteer: model.canSteer(botID),
                               pendingPictures: lane.pendingPictures)
    }
    private var isQueueing: Bool { isWorking && model.canSteer(botID) }
    private var isEditing: Bool { lane.editing != nil }

    var body: some View {
        let lane = lane
        let hintText = hint(lane)
        VStack(spacing: 0) {
            card(lane)
            Text(hintText)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .frame(height: 14)
                .padding(.top, 6)
                .opacity(hintText.isEmpty ? 0 : 1)
                // The line changes with the focus, the first letter and the queue, never with a key: it cross-fades
                // (opacity only, so it holds under Reduce Motion too) instead of cutting.
                .contentTransition(.opacity)
                .animation(Motion.fade, value: hintText)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 28)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [Palette.canvas.opacity(0), Palette.canvas], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
        }
        .background { shortcuts }
        .background { ApprovalKeyMonitor(handler: handlePasteKey) }
        .background { ContextGaugeDriver(botID: botID, gauge: gauge) }
        .confirmationDialog(RewindWords.editTitle, isPresented: $isConfirmingEdit, titleVisibility: .visible) {
            Button(RewindWords.editConfirm, role: .destructive) { submitEdit() }
        } message: {
            Text(RewindWords.editMessage(savedToMemory: lane.editing.map { model.editSavedToMemory(itemID: $0.itemID, of: botID) } ?? false))
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attach(urls) }
        }
        .onAppear {
            isFocused = true
            _ = model.takeChatRequest(.focusComposer, of: botID) // ⌘L that opened this chat: it already has the focus
        }
        // The model list closing (⇧⌘M then ↩, or a click) hands the focus back to the field.
        .onChange(of: isModelOpen) { if !isModelOpen { isFocused = true } }
        // "Editar" put a message in the field: write on it.
        .onChange(of: lane.editing?.itemID) { if lane.editing != nil { isFocused = true } }
        // ⌘L, from the sidebar, the panel or another page, with this chat already open.
        .onChange(of: model.pendingChatRequest) {
            if model.takeChatRequest(.focusComposer, of: botID) { isFocused = true }
        }
    }

    // MARK: Card

    private func card(_ lane: ComposerLane) -> some View {
        let matches = slashMatches
        return VStack(alignment: .leading, spacing: 10) {
            if lane.editing != nil {
                editingBanner.transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
            if lane.hasAttachments || lane.pendingPictures > 0 {
                attachmentStrip(lane).transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
            if let error = lane.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Palette.warn)
                    .padding(.horizontal, 4)
                    .transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
            slashSuggestions(matches)

            TextField(placeholder, text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Palette.conversationFont)
                .foregroundStyle(Palette.ink)
                .lineLimit(1...8)
                .focused($isFocused)
                .onSubmit { send() }
                .onKeyPress(.upArrow) { moveSlash(-1) }
                .onKeyPress(.downArrow) { moveSlash(1) }
                .onKeyPress(keys: [.tab]) { handleTab($0) }
                .onKeyPress(.escape) { handleEscape() }
                .onChange(of: draft.wrappedValue) {
                    isSlashDismissed = false
                    slashIndex = 0 // a new word means a new list: the highlight starts at its top
                }
                .padding(.horizontal, 4)

            bar
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // The card grows or shrinks once when the suggestions, the strip or an error come or go (never by their item
        // count or by a key): one discrete value, so the field's own height keeps following the typing (§2.5).
        .animation(reduceMotion ? Motion.fade : Motion.content,
                   value: CardParts(suggestions: !matches.isEmpty, strip: lane.hasAttachments || lane.pendingPictures > 0,
                                    error: lane.error != nil, banner: lane.editing != nil))
        // The shadow belongs to the background alone: on the whole card every key in the field re-rendered the text,
        // chips and buttons into an offscreen pass to cast it.
        .background { ComposerSurface(isFocused: isFocused, isDropTargeted: isDropTargeted, reduceMotion: reduceMotion) }
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.compactBelow } action: { isCompact = $0 }
    }

    /// The line above the field while a message of the chat is being edited: what it is, how to leave, and the button for it.
    private var editingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .medium))
                .accessibilityHidden(true)
            Text(RewindWords.banner)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            Button("Cancelar", systemImage: "xmark") { model.cancelEditing(botID) }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .help(Tip.cancelEdit)
        }
        .foregroundStyle(Palette.accentText)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
    }

    private var placeholder: LocalizedStringKey {
        if isQueueing { return "Escreva para orientar o Orb enquanto ele trabalha" }
        if isWorking { return LocalizedStringKey(ComposerAction.routinePlaceholder(routineName: model.runningRoutineName(botID))) }
        return "Pergunte qualquer coisa ou solte um arquivo"
    }

    /// The line under the card: how the keys work, shown only when it helps and nothing else is being said.
    private func hint(_ lane: ComposerLane) -> String {
        if isQueueing, hasContent {
            return ComposerHint.queueing(needsYou: model.live(botID).needsYou,
                                         typesInComposer: isFocused && hasText, compact: isCompact)
        }
        if isWorking { return "" }
        // "Esc cancela" is said once, in the banner above the field, with its button.
        if isEditing { return "↩ envia a edição" }
        if isFocused, !hasContent, !lane.hasAttachments { return "↩ envia · \(CommandName.newLineKeys) nova linha" }
        return ""
    }

    // MARK: Attachments

    private func attachmentStrip(_ lane: ComposerLane) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(lane.pictures, id: \.path) { image in
                    PictureChip(image: image) {
                        lane.pictures.removeAll { $0 == image }
                        // A picture of the message being edited belongs to the conversation: only the strip lets go of it.
                        if lane.editing?.originalPictures.contains(image.path) != true { model.images.remove(image) }
                    }
                    .transition(chipTransition)
                }
                ForEach(lane.files) { file in
                    AttachmentChip(file: file) { lane.files.removeAll { $0.id == file.id } }
                        .transition(chipTransition)
                }
                if lane.pendingPictures > 0 { PreparingChip(count: lane.pendingPictures).transition(chipTransition) }
            }
            .padding(.top, 10)
            .padding(.trailing, 10)
            // A chip joining or leaving fades while the others slide over; keyed by what is in the strip, so nothing
            // else in the card animates with it. Under Reduce Motion the others do not slide (that is movement):
            // the chip alone fades, by its own transition.
            .animation(reduceMotion ? nil : Motion.content, value: ComposerView.stripIDs(lane))
        }
        .scrollIndicators(.never)
        .padding(.top, -4) // the strip's own top margin grew by 4 pt for the remove buttons' targets: the picture stays put
    }

    /// A chip joining or leaving the strip: a fade, on its own short curve under Reduce Motion (the strip's slide is off then).
    private var chipTransition: AnyTransition {
        reduceMotion ? .opacity.animation(Motion.fade) : .opacity
    }

    /// Who is in the attachment strip, in order: the one value its chips' coming and going animate with.
    static func stripIDs(_ lane: ComposerLane) -> [String] {
        lane.pictures.map(\.path) + lane.files.map { $0.url.absoluteString } + (lane.pendingPictures > 0 ? ["preparing"] : [])
    }

    // MARK: Bar

    private var bar: some View {
        let action = ComposerAction.current(isWorking: isWorking, canSend: canSend, waitsOnChain: model.live(botID).chainWork != nil)
        return HStack(spacing: 2) {
            Button("Anexar", systemImage: "plus") { isImporting = true }
                .labelStyle(.iconOnly)
                .buttonStyle(CircleGhostStyle(side: 28, fontSize: 13))
                .help(Tip.attach)
            SkillsChip(botID: botID, compact: isCompact) { insert("/\($0) ") }
            PermissionChip(botID: botID, compact: isCompact) { isFocused = true }
            Spacer(minLength: 8)
            ContextMeterChip(botID: botID, gauge: gauge, compact: isCompact)
            ModelChip(botID: botID, isOpen: $isModelOpen)
            actionButtons(action)
        }
        .foregroundStyle(Palette.muted)
        // Stop stepping in or out moves the whole row: the model and meter chips slide with it (34-38 pt, 0.25 s)
        // instead of jumping. Tied to this one value, so neither the chips' texts nor `isCompact` animate with it.
        .animation(reduceMotion ? nil : Motion.content, value: action.showsSecondaryStop)
    }

    /// One round button that is Send or Stop: its symbol is swapped (not the button), so the change reads as the same
    /// control changing meaning. While the Orb works and a message is typed, Stop steps back beside it as a dark
    /// button and the main one queues the message.
    @ViewBuilder private func actionButtons(_ action: ComposerAction) -> some View {
        let routine = model.runningRoutineName(botID)
        HStack(spacing: 6) {
            if action.showsSecondaryStop {
                Button("Parar", systemImage: "stop.fill") { model.stop(botID) }
                    .buttonStyle(RoundActionStyle(isEnabled: true, isSecondary: true))
                    .help("\(CommandName.stop) (\(AppShortcut.stop.label))")
                    .transition(.opacity)
            }
            mainButton(action, routine: routine)
        }
        // Under Reduce Motion the row above does not animate: Stop alone fades in or out (opacity is not movement).
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: action.showsSecondaryStop)
    }

    private func mainButton(_ action: ComposerAction, routine: String?) -> some View {
        Button {
            if action == .stop { model.stop(botID) } else { send() }
        } label: {
            Image(systemName: action.symbol)
                .contentTransition(.symbolEffect(.replace))
                .animation(Motion.availability(reduceMotion: reduceMotion), value: action.symbol)
        }
        .buttonStyle(RoundActionStyle(isEnabled: action == .stop || canSend))
        .disabled(action != .stop && !canSend)
        .accessibilityLabel(action.title(isRoutine: routine != nil))
        .help(action.help(isRoutine: routine != nil))
        // ⌘↩ sends when the Orb is free; while it works ⌘↩ means "stop and send" (see `shortcuts`).
        .keyboardShortcut(action == .send ? AppShortcut.commandReturn : nil)
    }

    /// Shortcuts that belong to the composer without a visible button: ⌘↩ to stop and send, ⇧⌘M for the model list.
    private var shortcuts: some View {
        ZStack {
            Button("Parar e enviar") { model.stopAndSend(botID, draft: draft.wrappedValue) }
                .keyboardShortcut(AppShortcut.commandReturn)
                .disabled(!ComposerAction.stopAndSendEnabled(isQueueing: isQueueing, canSend: canSend, queuedCount: lane.queued.count,
                                                             pendingPictures: lane.pendingPictures, isEditing: isEditing))
            Button("Escolher modelo") { isModelOpen.toggle() }
                .keyboardShortcut(AppShortcut.chooseModel)
            // No button takes Esc for the edit (as `.cancelAction`): a key equivalent runs before the field that has the
            // focus sees the key, so it would also have taken the Esc of the skill list, of the search bar and of the
            // permission card's note. The field's own handler (`handleEscape`) and the banner's button give the edit up.
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Slash suggestions

    /// Skills that match what follows a leading `/`, above the field: ↑↓ choose, ↩ or ⇥ complete, Esc closes.
    private var slashMatches: [Skill] {
        guard !isSlashDismissed, let query = SkillSearch.slashQuery(in: draft.wrappedValue) else { return [] }
        return Array(SkillSearch.matches(model.skills(for: botID), query).prefix(5))
    }

    @ViewBuilder private func slashSuggestions(_ matches: [Skill]) -> some View {
        if !matches.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(matches.enumerated()), id: \.element.id) { index, skill in
                    SkillRow(skill: skill, isHighlighted: index == min(slashIndex, matches.count - 1)) { complete(skill) }
                }
            }
            .padding(.vertical, 4)
            .background(Palette.raised.opacity(0.6), in: .rect(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Skills sugeridas")
            .transition(.adapted(.asymmetric(insertion: .opacity.combined(with: .offset(y: 4)), removal: .opacity),
                                 reduceMotion: reduceMotion))
        }
    }

    /// ⇥ completes the highlighted skill while the suggestions are open; otherwise, with the Orb working and a message
    /// ready, it queues the message for after the task. Anywhere else it is the plain Tab (see `ComposerAction.tab`).
    private func handleTab(_ press: KeyPress) -> KeyPress.Result {
        switch ComposerAction.tab(slashIsOpen: !slashMatches.isEmpty, isQueueing: isQueueing, canSend: canSend, isPlain: press.modifiers.intersection([.shift, .control, .option, .command]).isEmpty) {
        case .completeSkill: return completeSlash() ? .handled : .ignored
        case .queueAfterTask:
            send(delivery: .afterTask)
            return .handled
        case .ignore: return .ignored
        }
    }

    private func moveSlash(_ step: Int) -> KeyPress.Result {
        let count = slashMatches.count
        guard count > 0 else { return .ignored }
        slashIndex = (min(slashIndex, count - 1) + step + count) % count
        return .handled
    }

    /// Completes the highlighted skill. Return does not when the draft already is a skill's whole `/slug` (it sends).
    private func completeSlash(forReturn: Bool = false) -> Bool {
        let matches = slashMatches
        guard !matches.isEmpty else { return false }
        if forReturn, SkillSearch.isComplete(draft.wrappedValue, skills: matches) { return false }
        complete(matches[min(slashIndex, matches.count - 1)])
        return true
    }

    private func dismissSlash() -> KeyPress.Result {
        guard !slashMatches.isEmpty else { return .ignored }
        isSlashDismissed = true // closes the list; what was typed stays
        return .handled
    }

    /// Esc closes the skill suggestions first; with none open, it gives up the edit of a message.
    private func handleEscape() -> KeyPress.Result {
        switch ComposerAction.escape(slashIsOpen: !slashMatches.isEmpty, isEditing: isEditing) {
        case .closeSkillList: return dismissSlash()
        case .cancelEdit:
            model.cancelEditing(botID)
            return .handled
        case .ignore: return .ignored
        }
    }

    private func complete(_ skill: Skill) {
        draft.wrappedValue = "/\(skill.slug) "
        slashIndex = 0
        isFocused = true
    }

    // MARK: Actions

    /// The file picker or ⌘V: typing can go on right away.
    private func attach(_ urls: [URL]) {
        model.attach(urls, to: botID)
        isFocused = true
    }

    /// ⌘V with a picture on the clipboard (a screenshot, an image copied from Preview) or with picture files copied in
    /// Finder attaches them; anything with text on the clipboard pastes as text, as before. The text field cannot
    /// take a picture, so the key is looked at before it gets there. Only the composer's own window counts: the menu
    /// bar panel, Settings and the sheets over the chat keep their ⌘V.
    private func handlePasteKey(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "v",
              PasteGate.takes(eventIsInComposerWindow: event.window === window, isKey: window.isKeyWindow,
                              hasSheet: window.attachedSheet != nil, isFocused: isFocused) else { return false }
        return pasteImages()
    }

    /// Whether the clipboard held pictures and they were taken.
    private func pasteImages() -> Bool {
        let board = NSPasteboard.general
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if files.contains(where: ImageProcessing.isImageFile) {
            attach(files)
            return true
        }
        let hasText = board.types?.contains { [.string, .rtf].contains($0) } ?? false
        guard files.isEmpty, !hasText, let data = board.data(forType: .png) ?? board.data(forType: .tiff) else { return false }
        model.attachPicture(to: botID) { try await $0.attach(data, name: "imagem colada", botID: $1) }
        isFocused = true
        return true
    }

    private func send(delivery: SteeringDelivery = .steer) {
        // With the suggestions open, Return completes the highlighted skill instead of sending a bare "/res" (a whole "/resumir" is sent).
        if completeSlash(forReturn: true) { return }
        guard canSend else { return }
        if model.isLoadingConversation(botID) {
            // The history is still being read: send once it is in memory (checked again then, so a second Return
            // while waiting finds the draft already gone) instead of making the window wait for the file.
            Task {
                await model.loadedConversation(botID)
                send(delivery: delivery)
            }
            return
        }
        if !model.hasCheckedConnections, !model.hasUsableModel(botID) {
            // Launch: the connections are still being looked at, so "no model" would be a guess. Send once they are known.
            Task {
                await model.connectionsChecked()
                send(delivery: delivery)
            }
            return
        }
        if let edit = lane.editing {
            // What leaves with the edit may have changed things on the Mac (it stays done): ask first.
            if model.editDropsChanges(itemID: edit.itemID, of: botID) { isConfirmingEdit = true } else { submitEdit() }
            return
        }
        // If the message wasn't sent (no model connected), the attachments stay with the draft.
        model.submit(draft.wrappedValue, to: botID, delivery: delivery)
    }

    /// Sends the edited message: it takes the place of the original and the rows after it fade out.
    private func submitEdit() {
        model.submitEdit(draft.wrappedValue, to: botID, animated: true)
    }

    private func insert(_ token: String) {
        let current = draft.wrappedValue
        draft.wrappedValue = current.isEmpty || current.hasSuffix(" ") ? current + token : current + " " + token
        isFocused = true
    }
}

/// What the composer's card holds besides the field: the three things whose coming and going changes its height.
private struct CardParts: Equatable {
    var suggestions: Bool
    var strip: Bool
    var error: Bool
    var banner: Bool
}

/// A picture waiting to be sent: its thumbnail with a remove button.
private struct PictureChip: View {
    let image: ImageAttachment
    let onRemove: () -> Void

    var body: some View {
        let name = URL(fileURLWithPath: image.path).lastPathComponent
        ImageThumbnail(path: image.path)
            .overlay(alignment: .topTrailing) {
                RemoveButton(label: "Remover " + name, symbol: "xmark.circle.fill", action: onRemove)
                    .foregroundStyle(Palette.ink, Palette.canvas)
                    .offset(x: 10, y: -10) // the 24 pt target is centered where the 14 pt symbol used to be
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Imagem anexada: " + name)
            .help(name)
            // The bubble shows the grid's copy of this picture: decode it now, so it is in the cache when the message goes.
            .task(id: image.path) { _ = await Thumbnails.image(at: image.path, side: Thumbnails.gridSide) }
    }
}

/// The small round button that takes an attachment out. Its target is `size` pt (the symbol itself is smaller) and it
/// gets the round hover fill the other composer buttons have; VoiceOver hears which attachment it removes.
private struct RemoveButton: View {
    let label: String
    let symbol: String
    var size: CGFloat = 24
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(label, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help(Tip.removeAttachment)
            .frame(width: size, height: size)
            // The fill is a little smaller than the target, so the strip's edges never clip it.
            .hoverFill(isHovering, in: .circle, color: Palette.ghostSelected)
            .contentShape(.circle)
            .onHover { isHovering = $0 }
    }
}

/// A file waiting to be sent: the same card the chat shows once it is sent, with a remove button.
private struct AttachmentChip: View {
    let file: AttachedFile
    let onRemove: () -> Void

    var body: some View {
        FileCard(path: file.url.path, all: [file.url.path], style: .compact, minHeight: 56)
            .frame(width: 220)
            .overlay(alignment: .topTrailing) {
                RemoveButton(label: "Remover " + file.name, symbol: "xmark.circle.fill", action: onRemove)
                    .foregroundStyle(Palette.ink, Palette.canvas)
                    .offset(x: 10, y: -10)
            }
    }
}

/// Pictures still being shrunk and saved: a tile the size of a thumbnail in the strip, so the paste or drop is seen to
/// have worked and the strip does not change height when the picture takes its place.
private struct PreparingChip: View {
    let count: Int

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 56, height: 56)
            .background(Palette.raised, in: .rect(cornerRadius: 10))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ComposerLane.preparingText(count))
    }
}

/// White circular send/stop button. Stepping back (`isSecondary`) when Send is next to it: a dark button.
/// Enabling fades the fill (`Motion.content`); pressing scales it to 0.92 (`Motion.press`). Reduce Motion: the
/// state changes at once and a press dims instead of shrinking.
private struct RoundActionStyle: ButtonStyle {
    let isEnabled: Bool
    var isSecondary = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(isSecondary ? Palette.ink : Palette.onInk)
            .frame(width: 28, height: 28)
            .background(isSecondary ? Palette.raised : Palette.ink.opacity(isEnabled ? 1 : 0.25), in: .circle)
            .animation(Motion.availability(reduceMotion: reduceMotion), value: isEnabled)
            .overlay { if isSecondary { Circle().strokeBorder(Palette.lineStrong) } }
            .scaleEffect(ComposerAction.pressVisual(pressed: configuration.isPressed, reduceMotion: reduceMotion).scale)
            .opacity(ComposerAction.pressVisual(pressed: configuration.isPressed, reduceMotion: reduceMotion).opacity)
            .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
    }
}

/// What the composer's round button does right now. Pure, so the tests can read it.
enum ComposerAction: Equatable {
    /// The Orb is free: send (⌘↩ also sends).
    case send
    /// The Orb works on your chat and something is typed: the message waits its turn.
    case queue
    /// The Orb works and nothing is typed (or the turn is a routine, which only stops): stop.
    case stop

    static let pressedScale: CGFloat = 0.92

    /// What a press does to the button: it shrinks to `pressedScale`; under Reduce Motion it only dims.
    static func pressVisual(pressed: Bool, reduceMotion: Bool) -> (scale: CGFloat, opacity: Double) {
        guard pressed else { return (1, 1) }
        return reduceMotion ? (1, 0.8) : (pressedScale, 1)
    }

    /// There is something to send: text, or an attachment of any kind (a file alone is a message: "veja isto").
    static func hasContent(hasText: Bool, pictures: Int, files: Int) -> Bool { hasText || pictures > 0 || files > 0 }

    /// A message can be sent: something is written, the Orb is free or working on your chat (the message is queued),
    /// and no picture is still being prepared.
    static func canSend(hasContent: Bool, isWorking: Bool, canSteer: Bool, pendingPictures: Int) -> Bool {
        hasContent && pendingPictures == 0 && (!isWorking || canSteer)
    }

    /// ⌘↩ "stop and send" works with something to send: what is typed, or what already waits in the queue (the
    /// queue bubble's own "Parar e enviar" offers that key with an empty field). Not while a message is being edited:
    /// the field then holds the edit, which is no message to queue (the edit ends when a turn starts anyway).
    static func stopAndSendEnabled(isQueueing: Bool, canSend: Bool, queuedCount: Int, pendingPictures: Int = 0,
                                   isEditing: Bool = false) -> Bool {
        isQueueing && pendingPictures == 0 && !isEditing && (canSend || queuedCount > 0)
    }

    /// What Esc does in the message field.
    enum EscapeKey: Equatable {
        /// Closes the skill suggestions (what was typed stays).
        case closeSkillList
        /// Gives up the edit of a message.
        case cancelEdit
        /// Not ours: the key goes on (nothing is open).
        case ignore
    }

    /// The skill suggestions go first: with them open Esc closes only them, and a second Esc gives the edit up.
    static func escape(slashIsOpen: Bool, isEditing: Bool) -> EscapeKey {
        if slashIsOpen { return .closeSkillList }
        return isEditing ? .cancelEdit : .ignore
    }

    /// What ⇥ does in the message field.
    enum TabKey: Equatable {
        /// Completes the highlighted skill of the `/` suggestions.
        case completeSkill
        /// Sends the message to wait for the end of the task (↩ would steer the task with it).
        case queueAfterTask
        /// Not ours: the plain Tab (moving the focus) goes on.
        case ignore
    }

    /// ⇥ is taken only when it means something: the skill suggestions are open, or the Orb works on your chat and a
    /// message is ready (`canSend`: something to send, no picture still on its way). With ⇧ or another modifier, or
    /// with the Orb free or running a routine, it stays the plain Tab.
    static func tab(slashIsOpen: Bool, isQueueing: Bool, canSend: Bool, isPlain: Bool) -> TabKey {
        if slashIsOpen { return .completeSkill }
        return isPlain && isQueueing && canSend ? .queueAfterTask : .ignore
    }

    /// The field's placeholder while a routine runs (which a message cannot join).
    static func routinePlaceholder(routineName: String?) -> String {
        routineName.map { "A rotina “\($0)” está rodando. Envie quando ela terminar." } ?? "Uma rotina está rodando. Envie quando ela terminar."
    }

    /// `waitsOnChain` (MultiOrb, WP2): the Orb is idle but waits on other Orbs' answers; with nothing typed the button stops that chain.
    static func current(isWorking: Bool, canSend: Bool, waitsOnChain: Bool = false) -> ComposerAction {
        if !isWorking { return waitsOnChain && !canSend ? .stop : .send }
        return canSend ? .queue : .stop
    }

    var symbol: String { self == .stop ? "stop.fill" : "arrow.up" }

    /// The button's name for VoiceOver.
    var title: String {
        switch self {
        case .send: "Enviar"
        case .queue: "Direcionar"
        case .stop: "Parar"
        }
    }

    var help: String {
        switch self {
        case .send: "Enviar (↩)"
        case .queue: "Direcionar o Orb (↩); ⇥ deixa para depois da tarefa"
        case .stop: "\(CommandName.stop) (\(AppShortcut.stop.label))"
        }
    }

    /// Stopping during a routine says so: it ends the routine's run. Queueing says "Direcionar": the Orb takes the
    /// message in the middle of the task, which is what ↩ does there; ⇥ is the queue.
    func title(isRoutine: Bool) -> String {
        self == .stop && isRoutine ? "Parar a rotina" : title
    }

    func help(isRoutine: Bool) -> String {
        self == .stop && isRoutine ? "Parar a rotina (\(AppShortcut.stop.label))" : help
    }

    /// Stop keeps its own (dark) button next to the queueing one, so a turn can still be ended with a message typed.
    var showsSecondaryStop: Bool { self == .queue }
}

/// The line under the composer while a message can be sent to a working Orb. Pure, so the tests can read it.
enum ComposerHint {
    /// ↩ steers the task, ⇥ waits for its end, ⌘↩ stops and sends. With a permission request open, ⌘↩ typed
    /// in the composer stops the turn (which refuses the request) and sends; from anywhere else it still allows the
    /// request (see `ApprovalShortcut`), and the line says so.
    static func queueing(needsYou: Bool, typesInComposer: Bool, compact: Bool = false) -> String {
        let command = AppShortcut.commandReturn.label
        let keys = "↩ direciona · ⇥ fila"
        if needsYou {
            if !typesInComposer { return compact ? "\(command) permite o pedido" : "\(keys) · \(command) permite o pedido" }
            // A narrow composer gets the same promises in fewer words, so the line is whole rather than cut with "…".
            return compact ? "\(keys) · \(command) recusa e envia" : "\(keys) · \(command) recusa o pedido e envia agora"
        }
        return compact ? keys : "\(keys) · \(command) para e envia"
    }
}

/// Whether the composer's ⌘V monitor takes a key press. The monitor sees every key of the app, so it must be sure the
/// press is for the composer's window (not the menu bar panel, Settings or a sheet over the chat) and its field.
enum PasteGate {
    static func takes(eventIsInComposerWindow: Bool, isKey: Bool, hasSheet: Bool, isFocused: Bool) -> Bool {
        eventIsInComposerWindow && isKey && !hasSheet && isFocused
    }
}

/// The card around the message field: its border and background answer the focus like a hover does (in 0.10 s, out
/// 0.22 s), the background 2 % lighter and the border `lineStrong`. No glow: the Orb is the color on screen.
struct ComposerSurface: View {
    let isFocused: Bool
    let isDropTargeted: Bool
    let reduceMotion: Bool

    /// The card's shadow: black below it; while a file is dragged over, an accent glow all around.
    static func shadow(isDropTargeted: Bool) -> (color: Color, y: CGFloat) {
        isDropTargeted ? (Palette.accent.opacity(0.35), 0) : (.black.opacity(0.35), 8)
    }

    /// The card's fill: `surface`, 2 % lighter while the field has the focus.
    static func fill(isFocused: Bool) -> Color { isFocused ? Palette.surfaceFocused : Palette.surface }

    static func stroke(isFocused: Bool, isDropTargeted: Bool) -> Color {
        isDropTargeted ? Palette.accentText : (isFocused ? Palette.lineStrong : Palette.line)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20)
        let shadow = Self.shadow(isDropTargeted: isDropTargeted)
        shape.fill(Self.fill(isFocused: isFocused))
            .shadow(color: shadow.color, radius: 18, y: shadow.y)
            .overlay { shape.strokeBorder(Self.stroke(isFocused: isFocused, isDropTargeted: isDropTargeted), lineWidth: isDropTargeted ? 2 : 1) }
            // On the surface only: the field, its chips and its height never animate with the focus.
            .animation(Motion.focus(isFocused, reduceMotion: reduceMotion), value: isFocused)
            // The drop highlight (border, glow) answers like a hover: fast in, slow out; at once under Reduce Motion.
            .animation(reduceMotion ? nil : Motion.hover(isDropTargeted), value: isDropTargeted)
    }
}
