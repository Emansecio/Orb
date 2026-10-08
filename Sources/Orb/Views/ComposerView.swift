import SwiftUI
import UniformTypeIdentifiers

/// The message field of one Orb's chat. Takes the Orb's id: it shows nothing of the `Bot` itself (its chips read
/// their own parts), so changes to the Orb's settings do not re-render it.
///
/// It stays usable while the Orb works: a message sent then is queued and handed to the model at its next step
/// (see `AppModel+Steering`), and Stop (⌘.) is always one key away. Attachments live in the Orb's `ComposerLane`, so
/// they survive switching to another Orb and back.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let botID: UUID

    @FocusState private var isFocused: Bool
    @State private var isImporting = false
    @State private var isDropTargeted = false
    @State private var isModelOpen = false
    /// What the context meter and the "conversa longa" card show (measured by `ContextGaugeDriver`).
    @State private var gauge = ContextGauge()
    /// The composer is too narrow for words on its chips: only their icons show.
    @State private var isCompact = false
    /// The skill highlighted in the `/` suggestions.
    @State private var slashIndex = 0
    /// Esc closed the suggestions; any change to the draft brings them back.
    @State private var isSlashDismissed = false

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
    private var hasText: Bool { !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasContent: Bool { hasText || !lane.pictures.isEmpty }
    /// A message can be sent: any time the Orb is free, and while it works on your chat (it is queued). Not while a
    /// picture is still being prepared: it would miss this message and ride along with the next one.
    private var canSend: Bool {
        ComposerAction.canSend(hasContent: hasContent, isWorking: isWorking, canSteer: model.canSteer(botID),
                               pendingPictures: lane.pendingPictures)
    }
    private var isQueueing: Bool { isWorking && model.canSteer(botID) }

    var body: some View {
        let lane = lane
        VStack(spacing: 0) {
            ContextNudge(botID: botID, gauge: gauge) // adds nothing, not even spacing, while its card is not due
            card(lane)
            Text(hint(lane))
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .frame(height: 14)
                .padding(.top, 6)
                .opacity(hint(lane).isEmpty ? 0 : 1)
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
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attach(urls) }
        }
        .onAppear {
            isFocused = true
            _ = model.takeChatRequest(.focusComposer, of: botID) // ⌘L that opened this chat: it already has the focus
        }
        // ⌘L, from the sidebar, the panel or another page, with this chat already open.
        .onChange(of: model.pendingChatRequest) {
            if model.takeChatRequest(.focusComposer, of: botID) { isFocused = true }
        }
    }

    // MARK: Card

    private func card(_ lane: ComposerLane) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if lane.hasAttachments || lane.pendingPictures > 0 { attachmentStrip(lane) }
            if let error = lane.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Palette.warn)
                    .padding(.horizontal, 4)
            }
            slashSuggestions

            TextField(placeholder, text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Palette.conversationFont)
                .foregroundStyle(Palette.ink)
                .lineLimit(1...8)
                .focused($isFocused)
                .onSubmit(send)
                .onKeyPress(.upArrow) { moveSlash(-1) }
                .onKeyPress(.downArrow) { moveSlash(1) }
                .onKeyPress(.tab) { completeSlash() ? .handled : .ignored }
                .onKeyPress(.escape) { dismissSlash() }
                .onChange(of: draft.wrappedValue) { isSlashDismissed = false }
                .padding(.horizontal, 4)

            bar
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background { ComposerSurface(isFocused: isFocused, isDropTargeted: isDropTargeted, reduceMotion: reduceMotion) }
        .shadow(color: isDropTargeted ? Palette.accent.opacity(0.35) : .black.opacity(0.35), radius: 18, y: isDropTargeted ? 0 : 8)
        .overlay { if isDropTargeted { dropOverlay } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isDropTargeted)
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.compactBelow } action: { isCompact = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var dropOverlay: some View {
        Label("Solte para anexar", systemImage: "arrow.down.doc")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.surface.opacity(0.92), in: .rect(cornerRadius: 20))
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private var placeholder: LocalizedStringKey {
        if isQueueing { return "Escreva para orientar o Orb enquanto ele trabalha" }
        if isWorking { return LocalizedStringKey(ComposerAction.routinePlaceholder(routineName: model.runningRoutineName(botID))) }
        return "Pergunte qualquer coisa ou solte um arquivo"
    }

    /// The line under the card: how the keys work, shown only when it helps and nothing else is being said.
    private func hint(_ lane: ComposerLane) -> String {
        if isQueueing, hasContent {
            return ComposerHint.queueing(steersMidTurn: model.steersMidTurn(botID), needsYou: model.live(botID).needsYou,
                                         typesInComposer: isFocused && hasText)
        }
        if isWorking { return "" }
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
                        model.images.remove(image)
                    }
                }
                ForEach(lane.files) { file in
                    AttachmentChip(file: file) { lane.files.removeAll { $0.id == file.id } }
                }
                if lane.pendingPictures > 0 { PreparingChip(count: lane.pendingPictures) }
            }
            .padding(.top, 6)
        }
        .scrollIndicators(.never)
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 2) {
            Button("Anexar", systemImage: "plus") { isImporting = true }
                .labelStyle(.iconOnly)
                .buttonStyle(IconGhostStyle())
                .help("Anexar arquivos (ou solte aqui)")
            SkillsChip(botID: botID, compact: isCompact) { insert("/\($0) ") }
            PermissionChip(botID: botID, compact: isCompact)
            Spacer(minLength: 8)
            ContextMeterChip(botID: botID, gauge: gauge, compact: isCompact)
            ModelChip(botID: botID, isOpen: $isModelOpen)
            actionButtons
        }
        .foregroundStyle(Palette.muted)
    }

    /// One round button that is Send or Stop: its symbol is swapped (not the button), so the change reads as the same
    /// control changing meaning. While the Orb works and a message is typed, Stop steps back beside it as a dark
    /// button and the main one queues the message.
    @ViewBuilder private var actionButtons: some View {
        let action = ComposerAction.current(isWorking: isWorking, canSend: canSend)
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
                                                             pendingPictures: lane.pendingPictures))
            Button("Escolher modelo") { isModelOpen.toggle() }
                .keyboardShortcut(AppShortcut.chooseModel)
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

    @ViewBuilder private var slashSuggestions: some View {
        let matches = slashMatches
        if !matches.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(matches.enumerated()), id: \.element.id) { index, skill in
                    SkillRow(skill: skill, isHighlighted: index == min(slashIndex, matches.count - 1)) { complete(skill) }
                }
            }
            .padding(.vertical, 4)
            .background(Palette.raised.opacity(0.6), in: .rect(cornerRadius: 12))
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

    private func complete(_ skill: Skill) {
        draft.wrappedValue = "/\(skill.slug) "
        slashIndex = 0
        isFocused = true
    }

    // MARK: Actions

    /// Pictures become image attachments (shrunk and saved in the background); other files keep being listed by path.
    private func attach(_ urls: [URL]) {
        let lane = lane
        for url in urls where url.isFileURL {
            if ImageProcessing.isImageFile(url) {
                attachPicture { try await $0.attach(fileAt: url, botID: $1) }
            } else if !lane.files.contains(where: { $0.url == url }) {
                lane.files.append(AttachedFile(url: url))
            }
        }
    }

    private func attachPicture(_ load: @escaping @Sendable (ImageStore, UUID) async throws -> ImageAttachment) {
        let lane = lane
        lane.error = nil
        let store = model.images, botID = botID
        lane.pendingPictures += 1 // sending waits until the picture is in (see `canSend`)
        Task {
            defer { lane.pendingPictures -= 1 }
            do { lane.pictures.append(try await load(store, botID)) }
            catch { lane.error = error.localizedDescription }
        }
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
        attachPicture { try await $0.attach(data, name: "imagem colada", botID: $1) }
        return true
    }

    private func send() {
        // With the suggestions open, Return completes the highlighted skill instead of sending a bare "/res" (a whole "/resumir" is sent).
        if completeSlash(forReturn: true) { return }
        guard canSend else { return }
        if model.isLoadingConversation(botID) {
            // The history is still being read: send once it is in memory (checked again then, so a second Return
            // while waiting finds the draft already gone) instead of making the window wait for the file.
            Task {
                await model.loadedConversation(botID)
                send()
            }
            return
        }
        // If the message wasn't sent (no model connected), the attachments stay with the draft.
        model.submit(draft.wrappedValue, to: botID)
    }

    private func insert(_ token: String) {
        let current = draft.wrappedValue
        draft.wrappedValue = current.isEmpty || current.hasSuffix(" ") ? current + token : current + " " + token
        isFocused = true
    }
}

/// A picture waiting to be sent: its thumbnail with a remove button.
private struct PictureChip: View {
    let image: ImageAttachment
    let onRemove: () -> Void

    var body: some View {
        ImageThumbnail(path: image.path)
            .overlay(alignment: .topTrailing) {
                Button("Remover", systemImage: "xmark.circle.fill", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.ink, Palette.canvas)
                    .offset(x: 5, y: -5)
            }
            .help(URL(fileURLWithPath: image.path).lastPathComponent)
    }
}

/// A file waiting to be sent: an icon for its type, its name and its size.
private struct AttachmentChip: View {
    let file: AttachedFile
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: file.symbol).foregroundStyle(Palette.muted)
            Text(file.name).lineLimit(1).truncationMode(.middle)
            if let size = AttachmentKind.size(file.size) {
                Text(size).foregroundStyle(Palette.muted)
            }
            Button("Remover", systemImage: "xmark", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Palette.raised, in: .capsule)
        .help(file.url.path)
    }
}

/// Pictures still being shrunk and saved: a placeholder in the strip, so the paste or drop is seen to have worked.
private struct PreparingChip: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(ComposerLane.preparingText(count))
        }
        .font(.caption)
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Palette.raised, in: .capsule)
        .accessibilityElement(children: .combine)
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

    /// A message can be sent: something is written, the Orb is free or working on your chat (the message is queued),
    /// and no picture is still being prepared.
    static func canSend(hasContent: Bool, isWorking: Bool, canSteer: Bool, pendingPictures: Int) -> Bool {
        hasContent && pendingPictures == 0 && (!isWorking || canSteer)
    }

    /// ⌘↩ "stop and send" works with something to send: what is typed, or what already waits in the queue (the
    /// queue bubble's own "Parar e enviar" offers that key with an empty field).
    static func stopAndSendEnabled(isQueueing: Bool, canSend: Bool, queuedCount: Int, pendingPictures: Int = 0) -> Bool {
        isQueueing && pendingPictures == 0 && (canSend || queuedCount > 0)
    }

    /// The field's placeholder while a routine runs (which a message cannot join).
    static func routinePlaceholder(routineName: String?) -> String {
        routineName.map { "A rotina “\($0)” está rodando. Envie quando ela terminar." } ?? "Uma rotina está rodando. Envie quando ela terminar."
    }

    static func current(isWorking: Bool, canSend: Bool) -> ComposerAction {
        if !isWorking { return .send }
        return canSend ? .queue : .stop
    }

    var symbol: String { self == .stop ? "stop.fill" : "arrow.up" }

    /// The button's name for VoiceOver.
    var title: String {
        switch self {
        case .send: "Enviar"
        case .queue: "Enviar para a fila"
        case .stop: "Parar"
        }
    }

    var help: String {
        switch self {
        case .send: "Enviar (↩)"
        case .queue: "Colocar na fila (↩)"
        case .stop: "\(CommandName.stop) (\(AppShortcut.stop.label))"
        }
    }

    /// Stopping during a routine says so: it ends the routine's run.
    func title(isRoutine: Bool) -> String { self == .stop && isRoutine ? "Parar a rotina" : title }

    func help(isRoutine: Bool) -> String { self == .stop && isRoutine ? "Parar a rotina (\(AppShortcut.stop.label))" : help }

    /// Stop keeps its own (dark) button next to the queueing one, so a turn can still be ended with a message typed.
    var showsSecondaryStop: Bool { self == .queue }
}

/// The line under the composer while a message can be queued. Pure, so the tests can read it.
enum ComposerHint {
    /// With a permission request open, ⌘↩ typed in the composer stops the turn (which refuses the request) and sends;
    /// from anywhere else it still allows the request (see `ApprovalShortcut`), and the line says so.
    static func queueing(steersMidTurn: Bool, needsYou: Bool, typesInComposer: Bool) -> String {
        let command = AppShortcut.commandReturn.label
        if needsYou {
            return typesInComposer ? "↩ entra na fila · \(command) recusa o pedido e envia agora" : "↩ entra na fila · \(command) permite o pedido"
        }
        return steersMidTurn
            ? "↩ entra na fila e chega ao Orb no próximo passo · \(command) para e envia agora"
            : "↩ entra na fila e segue quando a resposta terminar · \(command) para e envia agora"
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

    /// The card's fill: `surface`, 2 % lighter while the field has the focus.
    static func fill(isFocused: Bool) -> Color { isFocused ? Palette.surfaceFocused : Palette.surface }

    static func stroke(isFocused: Bool, isDropTargeted: Bool) -> Color {
        isDropTargeted ? Palette.accentText : (isFocused ? Palette.lineStrong : Palette.line)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20)
        shape.fill(Self.fill(isFocused: isFocused))
            .overlay { shape.strokeBorder(Self.stroke(isFocused: isFocused, isDropTargeted: isDropTargeted), lineWidth: isDropTargeted ? 2 : 1) }
            // On the surface only: the field, its chips and its height never animate with the focus.
            .animation(Motion.focus(isFocused, reduceMotion: reduceMotion), value: isFocused)
    }
}

/// Small icon button with a circular hover fill.
private struct IconGhostStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .frame(width: 28, height: 28)
            .hoverFill(configuration.isPressed || isHovering, pressed: configuration.isPressed, in: .circle,
                       color: Palette.ghostSelected)
            .contentShape(.circle)
            .onHover { isHovering = $0 }
    }
}
