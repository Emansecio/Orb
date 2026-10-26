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
    /// The height of the whole message as laid out; the field shows up to `ComposerField.maxHeight` of it and scrolls the rest.
    @State private var fieldHeight = ComposerField.lineHeight

    /// Card width below which the chips lose their words.
    private nonisolated static let compactBelow: CGFloat = 520

    private var draft: Binding<String> {
        Binding(
            get: { model.draftText(botID) },
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
        ComposerAction.canSend(hasContent: hasContent, isWorking: isWorking, canQueue: model.canQueue(botID),
                               pendingPictures: lane.pendingPictures)
    }
    private var isQueueing: Bool { isWorking && model.canSteer(botID) }
    private var isEditing: Bool { lane.editing != nil }

    var body: some View {
        let lane = lane
        let situation = Situation(live: model.live(botID), workingChat: model.workingChatTitle(botID),
                                  routineName: model.runningRoutineName(botID), holdsRoutine: model.holdsRoutine(botID))
        let hintText = hint(lane, situation)
        VStack(spacing: 0) {
            card(lane, hint: hintText, situation)
            Text(hintText)
                .font(Typography.small)
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
        // Padded first, then capped: the card is as wide as the transcript's text (704 pt), not 56 pt wider.
        .padding(.horizontal, 28)
        .frame(maxWidth: 760)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [Palette.canvas.opacity(0), Palette.canvas], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
        }
        .background {
            // Its own view: it reads the transcript (the steered messages), which this body must not observe.
            ComposerShortcuts(botID: botID, isQueueing: isQueueing, canSend: canSend, queuedCount: lane.queued.count,
                              pendingPictures: lane.pendingPictures, isEditing: isEditing, isModelOpen: $isModelOpen)
        }
        .background { ApprovalKeyMonitor(handler: handleKey) }
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
        .onChange(of: botID) { orbChanged() }
        // The model list closing (⇧⌘M then ↩, or a click) hands the focus back to the field.
        .onChange(of: isModelOpen) { if !isModelOpen { isFocused = true } }
        // "Editar" put a message in the field: write on it.
        .onChange(of: lane.editing?.itemID) { if lane.editing != nil { isFocused = true } }
        // ⌘L, from the sidebar, the panel or another page, with this chat already open.
        .onChange(of: model.pendingChatRequest) {
            if model.takeChatRequest(.focusComposer, of: botID) { isFocused = true }
        }
    }

    /// The composer stays when another Orb is chosen (ChatView): what was open for the last one closes, and the new
    /// Orb's field takes the keys as a newly opened chat's does.
    private func orbChanged() {
        // A dictation into the Orb left behind closes there, with its last words.
        if let dictating = model.dictation.botID, dictating != botID { Task { await model.dictation.finish() } }
        isImporting = false
        isModelOpen = false
        isConfirmingEdit = false
        slashIndex = 0
        isSlashDismissed = false
        isFocused = true
        _ = model.takeChatRequest(.focusComposer, of: botID)
        // The field is the same one, with the other Orb's draft: what ⌘Z would undo was typed for the last Orb (in this
        // field or in its panel's), so it goes. The main window's undo is only its text fields'.
        NSApp.mainWindow?.undoManager?.removeAllActions()
    }

    // MARK: Card

    private func card(_ lane: ComposerLane, hint hintText: String, _ situation: Situation) -> some View {
        let matches = slashMatches
        let jobs = situation.live.jobs
        return VStack(alignment: .leading, spacing: 10) {
            if situation.holdsRoutine {
                RoutineStrip(botID: botID, routineName: situation.routineName)
                    .transition(.adapted(.unfold, reduceMotion: reduceMotion))
            } else if let working = situation.workingChat {
                ElsewhereStrip(botID: botID, chatTitle: working)
                    .transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
            if !jobs.isEmpty {
                JobsStrip(botID: botID, jobs: jobs).transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
            if lane.editing != nil {
                editingBanner.transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
            if lane.hasAttachments || lane.pendingPictures > 0 {
                attachmentStrip(lane).transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
            if let error = lane.error {
                errorLine(error, lane: lane)
                    .transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
            slashSuggestions(matches)

            // The whole message is laid out in a scroll view as tall as it is, up to `maxHeight`: past that the wheel and
            // the trackpad scroll the message (not the chat behind it) and its scroller shows. The field's own limit
            // would keep the caret in view but take no scrolling, so the caret is followed here (`ComposerCaretFollower`).
            ScrollView(.vertical) {
                // The prompt in `faint`, the placeholder gray the palette names (the system's own is fainter).
                TextField(text: draft, prompt: Text(placeholder(situation.live)).foregroundStyle(Palette.faint), axis: .vertical) { Text(placeholder(situation.live)) }
                    .textFieldStyle(.plain)
                    .font(Palette.conversationFont)
                    .foregroundStyle(Palette.ink)
                    .focused($isFocused)
                    // The line under the card is hidden from VoiceOver (it would be read twice); the keys it names are said here.
                    .accessibilityHint(ComposerHint.spoken(hintText.isEmpty && showsIdleKeys(lane, isWorking: situation.live.isWorking) ? ComposerHint.idleKeys : hintText))
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
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            .frame(height: min(max(fieldHeight, ComposerField.lineHeight), ComposerField.maxHeight))
            .background { ComposerCaretFollower() }

            bar(situation)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // The card grows or shrinks once when the suggestions, the strip or an error come or go (never by their item
        // count or by a key): one discrete value, so the field's own height keeps following the typing (§2.5).
        .animation(reduceMotion ? Motion.fade : Motion.content,
                   value: CardParts(suggestions: !matches.isEmpty, strip: lane.hasAttachments || lane.pendingPictures > 0,
                                    error: lane.error != nil, banner: lane.editing != nil, jobs: jobs.count,
                                    routine: situation.holdsRoutine || situation.workingChat != nil))
        // The shadow belongs to the background alone: on the whole card every key in the field re-rendered the text,
        // chips and buttons into an offscreen pass to cast it.
        // Reads the dictation's phase, never its level: the card does not re-render with the voice.
        .background {
            ComposerSurface(isFocused: isFocused, isDropTargeted: isDropTargeted,
                            isDictating: model.dictation.isActive(for: botID) && model.dictation.phase == .listening,
                            reduceMotion: reduceMotion)
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.compactBelow } action: { isCompact = $0 }
    }

    /// A warning under the field. Said as the app's other warnings are: the mark, then the sentence, wrapping under
    /// itself. It goes with its button or when the text changes (`AppModel.editDraft`); a microphone that was denied also
    /// gets the way to the pane that fixes it.
    private func errorLine(_ error: String, lane: ComposerLane) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.small)
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                if error == Dictation.deniedMessage, let url = Dictation.microphoneSettingsURL {
                    Button("Abrir Ajustes do Sistema") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.plain)
                        .font(Typography.small.weight(.medium))
                        .foregroundStyle(Palette.accentText)
                }
            }
            Spacer(minLength: 8)
            Button("Fechar aviso", systemImage: "xmark") { lane.error = nil }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .iconTip(Tip.dismissNotice)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
    }

    /// The line above the field while a message of the chat is being edited: what it is, how to leave, and the button for it.
    private var editingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .medium))
                .accessibilityHidden(true)
            Text(RewindWords.banner)
                .font(Typography.label.weight(.medium))
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

    private func placeholder(_ live: BotLive) -> LocalizedStringKey {
        if isQueueing { return "Escreva para orientar o Orb enquanto ele trabalha" }
        // Free or running a routine (the strip above the field says so): the same short line, naming the Orb.
        return LocalizedStringKey(ComposerAction.placeholder(orbName: live.look.name))
    }

    /// The line under the card: how the keys work, shown only when it helps and nothing else is being said.
    private func hint(_ lane: ComposerLane, _ situation: Situation) -> String {
        if let dictating = DictationButton.hint(model.dictation, botID: botID) { return dictating }
        if isQueueing, hasContent {
            return ComposerHint.queueing(needsYou: situation.live.needsYou,
                                         typesInComposer: isFocused && hasText, compact: isCompact)
        }
        if situation.live.isWorking {
            guard hasContent, model.canQueue(botID) else { return "" }
            return situation.workingChat == nil ? "↩ envia quando a rotina terminar" : "↩ envia quando a outra conversa terminar"
        }
        // "Esc cancela" is said once, in the banner above the field, with its button.
        if isEditing { return "↩ envia a edição" }
        // How ↩ and ⇧↩ work in an empty field is every chat's convention: not under the card all the time (VoiceOver
        // still says it, `showsIdleKeys`).
        return ""
    }

    /// An empty, free field with the focus: VoiceOver says how the keys work, which the line under the card no longer does.
    private func showsIdleKeys(_ lane: ComposerLane, isWorking: Bool) -> Bool {
        isFocused && !isWorking && !isEditing && !hasContent && !lane.hasAttachments
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

    private func bar(_ situation: Situation) -> some View {
        let waitsOnChain = situation.live.chainWork != nil
        let action = ComposerAction.current(isWorking: situation.live.isWorking, canSend: canSend, waitsOnChain: waitsOnChain)
        let secondaryStop = action.showsSecondaryStop(waitsOnChain: waitsOnChain)
        return HStack(spacing: 2) {
            ComposerPlusMenu(botID: botID, attach: { isImporting = true }) { insert("/\($0) ") }
            PermissionChip(botID: botID, compact: isCompact) { isFocused = true }
            Spacer(minLength: 8)
            ContextMeterChip(botID: botID, gauge: gauge, compact: isCompact)
            ModelChip(botID: botID, isOpen: $isModelOpen)
            if Dictation.isSupported { DictationButton(botID: botID) }
            actionButtons(action, secondaryStop: secondaryStop, situation)
        }
        .foregroundStyle(Palette.muted)
        // Stop stepping in or out moves the whole row: the model and meter chips slide with it (34-38 pt, 0.25 s)
        // instead of jumping. Tied to this one value, so neither the chips' texts nor `isCompact` animate with it.
        .animation(reduceMotion ? nil : Motion.content, value: secondaryStop)
    }

    /// One round button that is Send or Stop: its symbol is swapped (not the button), so the change reads as the same
    /// control changing meaning. While the Orb works and a message is typed, Stop steps back beside it as a plain round
    /// icon (like "+" and the microphone), so the white button is the one thing the eye finds, and it queues the message.
    @ViewBuilder private func actionButtons(_ action: ComposerAction, secondaryStop: Bool, _ situation: Situation) -> some View {
        let routine = situation.routineName
        let elsewhere = situation.workingChat != nil
        HStack(spacing: 6) {
            if secondaryStop {
                Button("Parar", systemImage: "stop.fill") { model.stopTurn(botID) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(CircleGhostStyle(side: 28, fontSize: 11))
                    .foregroundStyle(Palette.secondary)
                    .help(ComposerAction.stop.help(isRoutine: routine != nil, elsewhere: elsewhere))
                    .transition(.opacity)
            }
            mainButton(action, routine: routine, elsewhere: elsewhere)
        }
        // Under Reduce Motion the row above does not animate: Stop alone fades in or out (opacity is not movement).
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: secondaryStop)
    }

    private func mainButton(_ action: ComposerAction, routine: String?, elsewhere: Bool) -> some View {
        Button {
            if action == .stop { model.stopTurn(botID) } else { send() }
        } label: {
            Image(systemName: action.symbol)
                .contentTransition(.symbolEffect(.replace))
                .animation(Motion.availability(reduceMotion: reduceMotion), value: action.symbol)
        }
        .buttonStyle(RoundActionStyle(isEnabled: action == .stop || canSend))
        .disabled(action != .stop && !canSend)
        .accessibilityLabel(action.title(isRoutine: routine != nil, elsewhere: elsewhere))
        .help(action.help(isRoutine: routine != nil, elsewhere: elsewhere))
        // ⌘↩ sends when the Orb is free; while it works ⌘↩ means "stop and send" (see `shortcuts`).
        .keyboardShortcut(action == .send ? AppShortcut.commandReturn : nil)
        // ⇥ has no button: the other delivery of a message typed during a turn is offered here too, by the right click and
        // by VoiceOver. Only when the Orb takes messages into its task: with a routine or another conversation running,
        // every message waits for the end and the button already says so.
        .contextMenu {
            if action == .queue, model.canSteer(botID) {
                Button("Direcionar agora") { send() }
                Button("Depois da tarefa") { send(delivery: .afterTask) }
            }
        }
        .accessibilityActions {
            if action == .queue, model.canSteer(botID) { Button("Enviar para depois da tarefa") { send(delivery: .afterTask) } }
        }
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
            .background(Palette.raised.opacity(0.6), in: .rect(cornerRadius: Radius.card))
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
        // Esc while dictating closes the microphone; what was said stays in the field. While the model reads it over,
        // Esc keeps it as it was dictated.
        if model.dictation.isActive(for: botID) {
            if model.dictation.phase == .reviewing { model.dictation.skipReview() } else { Task { await model.dictation.finish() } }
            return .handled
        }
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
    /// ⇧↩ breaks the line too (the field itself only knows ⌥↩), at the cursor, instead of sending.
    private func handleKey(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard PasteGate.takes(eventIsInComposerWindow: event.window === window, isKey: window.isKeyWindow,
                              hasSheet: window.attachedSheet != nil, isFocused: isFocused) else { return false }
        if NewLineKey.isShiftReturn(event) { return NewLineKey.insert(in: window) }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "v" else { return false }
        return pasteImages()
    }

    /// Whether the clipboard held pictures and they were taken.
    private func pasteImages() -> Bool {
        AppModel.takePastedPictures(files: attach) { data in
            model.attachPicture(to: botID) { try await $0.attach(data, name: "imagem colada", botID: $1) }
            isFocused = true
        }
    }

    private func send(delivery: SteeringDelivery = .steer) {
        // ↩ while dictating: the microphone closes, the last words land in the field, and the message goes.
        if model.dictation.isActive(for: botID) {
            Task {
                await model.dictation.finish()
                send(delivery: delivery)
            }
            return
        }
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

/// What the body asks of the model about the Orb, once per render instead of once per place that shows it.
private struct Situation {
    let live: BotLive
    /// The title of the conversation a turn still works on after another was opened.
    let workingChat: String?
    let routineName: String?
    let holdsRoutine: Bool
}

/// Shortcuts that belong to the composer without a visible button: ⌘↩ to stop and send, ⇧⌘M for the model list. A view of
/// its own because the steered messages come from the transcript: read in the composer's body, every step of a turn would
/// render the whole composer; here it renders two hidden buttons.
private struct ComposerShortcuts: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let isQueueing: Bool
    let canSend: Bool
    let queuedCount: Int
    let pendingPictures: Int
    let isEditing: Bool
    @Binding var isModelOpen: Bool

    var body: some View {
        ZStack {
            Button("Parar e enviar") {
                // The draft is read when the key is pressed, not on every render.
                guard model.dictation.isActive(for: botID) else { return model.stopAndSend(botID, draft: model.draftText(botID)) }
                Task {
                    await model.dictation.finish()
                    model.stopAndSend(botID, draft: model.draftText(botID))
                }
            }
                .keyboardShortcut(AppShortcut.commandReturn)
                // What waits counts the messages that reached the task unanswered too: their bubble left the queue already.
                .disabled(!ComposerAction.stopAndSendEnabled(isQueueing: isQueueing, canSend: canSend,
                                                             queuedCount: queuedCount + model.unansweredSteered(of: botID).count,
                                                             pendingPictures: pendingPictures, isEditing: isEditing,
                                                             needsYou: model.live(botID).needsYou))
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
}

/// What the composer's card holds besides the field: the things whose coming and going changes its height.
private struct CardParts: Equatable {
    var suggestions: Bool
    var strip: Bool
    var error: Bool
    var banner: Bool
    /// Lines of running processes: each one that comes or goes changes the card's height once (they are rare).
    var jobs: Int
    /// A routine holds the Orb: its strip comes and goes once.
    var routine: Bool
}

/// A picture waiting to be sent: its thumbnail with a remove button.
struct PictureChip: View {
    let image: ImageAttachment
    let onRemove: () -> Void

    var body: some View {
        let name = URL(fileURLWithPath: image.path).lastPathComponent
        ImageThumbnail(path: image.path)
            .removable(label: "Remover " + name, action: onRemove)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Imagem anexada: " + name)
            .help(name)
            // The bubble shows the grid's copy of this picture: decode it now, so it is in the cache when the message goes.
            .task(id: image.path) { _ = await Thumbnails.image(at: image.path, side: Thumbnails.gridSide) }
    }
}

/// The small round button that takes an attachment out. Its target is `size` pt (the symbol itself is smaller) and it
/// gets the round hover fill the other composer buttons have; VoiceOver hears which attachment it removes.
struct RemoveButton: View {
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

extension View {
    /// The chip's remove button at its top trailing corner. The offset centers the 24 pt target where the 14 pt symbol
    /// used to sit; every attachment chip shares it so they cannot drift apart.
    func removable(label: String, action: @escaping () -> Void) -> some View {
        overlay(alignment: .topTrailing) {
            RemoveButton(label: label, symbol: "xmark.circle.fill", action: action)
                .foregroundStyle(Palette.ink, Palette.canvas)
                .offset(x: 10, y: -10)
        }
    }
}

/// A file waiting to be sent: the same card the chat shows once it is sent, with a remove button.
private struct AttachmentChip: View {
    let file: AttachedFile
    let onRemove: () -> Void

    var body: some View {
        FileCard(path: file.url.path, all: [file.url.path], style: .compact, minHeight: 56)
            .frame(width: 220)
            .removable(label: "Remover " + file.name, action: onRemove)
    }
}

/// Pictures still being shrunk and saved: a tile the size of a thumbnail in the strip, so the paste or drop is seen to
/// have worked and the strip does not change height when the picture takes its place.
struct PreparingChip: View {
    let count: Int

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 56, height: 56)
            .background(Palette.raised, in: .rect(cornerRadius: Radius.medium))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ComposerLane.preparingText(count))
    }
}

/// White circular send/stop button. Enabling fades the fill (`Motion.content`); pressing scales it to 0.92
/// (`Motion.press`). Reduce Motion: the state changes at once and a press dims instead of shrinking.
private struct RoundActionStyle: ButtonStyle {
    let isEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let press = ComposerAction.pressVisual(pressed: configuration.isPressed, reduceMotion: reduceMotion)
        return configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Palette.onInk)
            .frame(width: 28, height: 28)
            .background(Palette.ink.opacity(isEnabled ? 1 : 0.25), in: .circle)
            .animation(Motion.availability(reduceMotion: reduceMotion), value: isEnabled)
            .scaleEffect(press.scale)
            .opacity(press.opacity)
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

    /// A message can be sent: something is written, the Orb is free or the message can wait in the queue (it works on your
    /// chat or runs a routine, `AppModel.canQueue`), and no picture is still being prepared.
    static func canSend(hasContent: Bool, isWorking: Bool, canQueue: Bool, pendingPictures: Int) -> Bool {
        hasContent && pendingPictures == 0 && (!isWorking || canQueue)
    }

    /// ⌘↩ "stop and send" works with something to send: what is typed, or what already waits in the queue (the
    /// queue bubble's own "Parar e enviar" offers that key with an empty field). Not while a message is being edited:
    /// the field then holds the edit, which is no message to queue (the edit ends when a turn starts anyway). Not while an
    /// approval card is open either: stopping refuses it, and the card itself shows ⌘↩ as "Permitir", so the key would
    /// refuse a request the person meant to allow. The card is answered first; the stop button still does it on purpose.
    static func stopAndSendEnabled(isQueueing: Bool, canSend: Bool, queuedCount: Int, pendingPictures: Int = 0,
                                   isEditing: Bool = false, needsYou: Bool = false) -> Bool {
        isQueueing && pendingPictures == 0 && !isEditing && !needsYou && (canSend || queuedCount > 0)
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

    /// The sentence of the strip above the field while a routine runs (a message cannot join the run: it waits for its end).
    static func routineStrip(routineName: String?) -> String {
        let tail = "o que você escrever vai depois"
        guard let name = routineName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return "Uma rotina está rodando · \(tail)"
        }
        let shown = name.count > maxRoutineNameLength ? name.prefix(maxRoutineNameLength - 1) + "…" : name
        return "Rotina “\(shown)” rodando · \(tail)"
    }

    /// Longer routine names are cut with an ellipsis, so the sentence after them is never pushed out of the strip.
    static let maxRoutineNameLength = 36

    /// The sentence of the strip above the field while the Orb ends a turn in a conversation you left: what you write in
    /// this one waits for it, and a permission it asks for is answered there.
    static func elsewhereStrip(chatTitle: String, needsYou: Bool) -> String {
        let shown = chatTitle.count > maxRoutineNameLength ? chatTitle.prefix(maxRoutineNameLength - 1) + "…" : Substring(chatTitle)
        return needsYou ? "“\(shown)” precisa de você" : "Trabalhando em “\(shown)” · o que você escrever vai depois"
    }

    /// The button of that strip: back to the conversation, or straight to the question it is waiting on.
    static func elsewhereButton(needsYou: Bool) -> String { needsYou ? "Responder" : "Voltar" }

    /// The field's placeholder when the Orb is free (or runs a routine): short, with the Orb's name.
    static func placeholder(orbName: String) -> String {
        let name = orbName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Mensagem" : "Mensagem para \(name)"
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
        case .queue: "Direcionar o Orb (↩); ⇥ ou o botão direito deixa para depois da tarefa"
        case .stop: "\(CommandName.stop) (\(AppShortcut.stop.label))"
        }
    }

    /// Stopping during a routine says so: it ends the routine's run. Queueing says "Direcionar": the Orb takes the
    /// message in the middle of the task, which is what ↩ does there; ⇥ is the queue.
    /// During a routine queueing does not steer: the message waits for the run's end.
    func title(isRoutine: Bool, elsewhere: Bool = false) -> String {
        if elsewhere, self != .send { return self == .queue ? "Enviar depois da outra conversa" : "Parar a outra conversa" }
        guard isRoutine else { return title }
        switch self {
        case .send: return title
        case .queue: return "Enviar depois da rotina"
        case .stop: return "Parar a rotina"
        }
    }

    /// `elsewhere`: the turn is a conversation's you left (`BotSession.workingChatID`); a message waits for it, as for a routine.
    func help(isRoutine: Bool, elsewhere: Bool = false) -> String {
        if elsewhere, self != .send {
            return self == .queue ? "Enviar quando a outra conversa terminar (↩)" : "Parar a outra conversa (\(AppShortcut.stop.label))"
        }
        guard isRoutine else { return help }
        switch self {
        case .send: return help
        case .queue: return "Enviar quando a rotina terminar (↩)"
        case .stop: return "Parar a rotina (\(AppShortcut.stop.label))"
        }
    }

    /// Stop keeps its own (dark) button next to the queueing one, so a turn can still be ended with a message typed; and next
    /// to Send while the Orb only waits on other Orbs (`waitsOnChain`), so the wait can too.
    func showsSecondaryStop(waitsOnChain: Bool = false) -> Bool { self == .queue || (self == .send && waitsOnChain) }
}

/// The line under the composer while a message can be sent to a working Orb. Pure, so the tests can read it.
enum ComposerHint {
    /// How ↩ and ⇧↩ work in a free field: said to VoiceOver only (`ComposerView.showsIdleKeys`).
    static let idleKeys = "↩ envia · \(CommandName.newLineKeys) nova linha"

    /// ↩ steers the task, ⇥ waits for its end, ⌘↩ stops and sends. With a permission request open, ⌘↩ typed in the
    /// composer does nothing (`ComposerAction.stopAndSendEnabled`): the line asks for the request first. From anywhere
    /// else ⌘↩ allows the request (see `ApprovalShortcut`), and the line says so.
    static func queueing(needsYou: Bool, typesInComposer: Bool, compact: Bool = false) -> String {
        let command = AppShortcut.commandReturn.label
        let keys = "↩ envia agora · ⇥ depois da tarefa"
        if needsYou {
            if !typesInComposer { return compact ? "\(command) permite o pedido" : "\(keys) · \(command) permite o pedido" }
            // A narrow composer gets the same promises in fewer words, so the line is whole rather than cut with "…".
            return compact ? keys : "\(keys) · responda ao pedido acima"
        }
        return compact ? keys : "\(keys) · \(command) para a tarefa e envia"
    }

    /// The same line for the field's VoiceOver hint: the key symbols are not read as words, so they become the keys' names.
    static func spoken(_ hint: String) -> String {
        let names: [Character: String] = ["↩": "Return", "⇥": "Tab", "⇧": "Shift", "⌘": "Command", "⌥": "Option", "⌃": "Control"]
        var words = ""
        for character in hint {
            if let name = names[character] { words += " \(name) " } else { words.append(character == "·" ? "," : character) }
        }
        // Spaces from the substitution and from " · " collapse, and a comma never follows a space.
        return words.split(separator: " ").joined(separator: " ").replacingOccurrences(of: " ,", with: ",")
    }
}

/// ⇧↩ in a message field: a new line where the cursor is, as ⌥↩ makes, never a send.
enum NewLineKey {
    static func isShiftReturn(_ event: NSEvent) -> Bool {
        [36, 76].contains(event.keyCode) // Return, and Enter on the numeric keypad
            && event.modifierFlags.intersection([.shift, .command, .option, .control]) == .shift
    }

    /// The field being typed in takes the line break (with its undo); false when no text field has the keys.
    @MainActor
    static func insert(in window: NSWindow) -> Bool {
        guard let editor = window.firstResponder as? NSTextView else { return false }
        editor.insertNewlineIgnoringFieldEditor(nil)
        return true
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
/// 0.22 s), the background 2 % lighter and the border `lineStrong`. No glow: the Orb is the color on screen. While the
/// microphone listens the border turns a faint red, so an open microphone is seen from across the room.
struct ComposerSurface: View {
    let isFocused: Bool
    let isDropTargeted: Bool
    var isDictating = false
    let reduceMotion: Bool

    /// The card's shadow: black below it; while a file is dragged over, an accent glow all around.
    static func shadow(isDropTargeted: Bool) -> (color: Color, y: CGFloat) {
        isDropTargeted ? (Palette.accent.opacity(0.35), 0) : (Shadow.popover, 8)
    }

    /// The card's fill: `surface`, 2 % lighter while the field has the focus.
    static func fill(isFocused: Bool) -> Color { isFocused ? Palette.surfaceFocused : Palette.surface }

    /// A file dragged over wins (it is what happens next), then the open microphone, then the focus.
    static func stroke(isFocused: Bool, isDropTargeted: Bool, isDictating: Bool = false) -> Color {
        if isDropTargeted { return Palette.accentText }
        if isDictating { return Palette.danger.opacity(0.45) }
        return isFocused ? Palette.lineStrong : Palette.line
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.composer)
        let shadow = Self.shadow(isDropTargeted: isDropTargeted)
        shape.fill(Self.fill(isFocused: isFocused))
            .shadow(color: shadow.color, radius: 18, y: shadow.y)
            .overlay {
                shape.strokeBorder(Self.stroke(isFocused: isFocused, isDropTargeted: isDropTargeted, isDictating: isDictating),
                                   lineWidth: isDropTargeted ? 2 : 1)
            }
            // On the surface only: the field, its chips and its height never animate with the focus.
            .animation(Motion.focus(isFocused, reduceMotion: reduceMotion), value: isFocused)
            // The drop highlight (border, glow) answers like a hover: fast in, slow out; at once under Reduce Motion.
            .animation(reduceMotion ? nil : Motion.hover(isDropTargeted), value: isDropTargeted)
            // The microphone opening or closing: a color change, so it fades even under Reduce Motion.
            .animation(Motion.hover(isDictating), value: isDictating)
    }
}

/// The message field's measures: one line of the conversation's font, and how tall it grows before it scrolls.
enum ComposerField {
    static let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 14)))
    static let maxLines: CGFloat = 10
    static let maxHeight = lineHeight * maxLines
}

/// Keeps the caret of the message field in view once the message is taller than the field: the field lives in a scroll
/// view of SwiftUI, which the text editor's own scrolling does not move. Watches the selection of the window's text
/// editor and, when that editor is the one in the scroll view this sits behind, scrolls the caret into view (after the
/// field has grown with the new line, so twice: now and once laid out).
struct ComposerCaretFollower: NSViewRepresentable {
    func makeNSView(context: Context) -> FollowerView { FollowerView() }
    func updateNSView(_ view: FollowerView, context: Context) {}

    final class FollowerView: NSView {
        private var observer: NSObjectProtocol?

        /// Leaving the window lets the observation go (and a view that leaves for good leaves its window first).
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil else { return }
            observer = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil,
                                                              queue: .main) { [weak self] note in
                let editor = note.object as? NSTextView
                MainActor.assumeIsolated {
                    guard let self, let editor else { return }
                    self.follow(editor)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.follow(editor) }
                }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func follow(_ editor: NSTextView) {
            guard let window, editor.window === window, window.firstResponder === editor,
                  let scroll = editor.enclosingScrollView, let document = scroll.documentView,
                  scroll.convert(scroll.bounds, to: nil).intersects(convert(bounds, to: nil)) else { return }
            guard let caret = Self.caret(in: editor) else { return }
            document.scrollToVisible(document.convert(caret, from: editor).insetBy(dx: 0, dy: -4))
        }

        /// Where the caret is, in the editor's coordinates (`firstRect` will not do: it answers from the field's own
        /// one-line clip). After a line break at the end it is the empty line's.
        private static func caret(in editor: NSTextView) -> NSRect? {
            guard let layout = editor.layoutManager, let container = editor.textContainer else { return nil }
            let selection = editor.selectedRange()
            var rect: NSRect
            if selection.location >= (editor.string as NSString).length, !layout.extraLineFragmentRect.isEmpty {
                rect = layout.extraLineFragmentRect
            } else {
                let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: selection.location, length: 0),
                                               actualCharacterRange: nil)
                rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            }
            rect.size.width = max(rect.width, 1)
            return rect.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        }
    }
}
