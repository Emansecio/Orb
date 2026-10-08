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
    @State private var pasteMonitor: Any?
    /// The skill highlighted in the `/` suggestions.
    @State private var slashIndex = 0
    /// Esc closed the suggestions; any change to the draft brings them back.
    @State private var isSlashDismissed = false

    /// Card width below which the chips lose their words.
    private nonisolated static let compactBelow: CGFloat = 520

    private var draft: Binding<String> {
        Binding(
            get: { model.drafts[botID, default: ""] },
            set: { model.setDraft($0, for: botID) }
        )
    }

    private var lane: ComposerLane { model.composerLane(botID) }
    private var isWorking: Bool { model.live(botID).isWorking }
    private var hasContent: Bool {
        !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !lane.pictures.isEmpty
    }
    /// A message can be sent: any time the Orb is free, and while it works on your chat (it is queued).
    private var canSend: Bool { hasContent && (!isWorking || model.canSteer(botID)) }
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
        .background { ContextGaugeDriver(botID: botID, gauge: gauge) }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attach(urls) }
        }
        .onAppear {
            isFocused = true
            installPasteMonitor()
            _ = model.takeChatRequest(.focusComposer, of: botID) // ⌘L that opened this chat: it already has the focus
        }
        .onDisappear { removePasteMonitor() }
        // ⌘L, from the sidebar, the panel or another page, with this chat already open.
        .onChange(of: model.pendingChatRequest) {
            if model.takeChatRequest(.focusComposer, of: botID) { isFocused = true }
        }
    }

    // MARK: Card

    private func card(_ lane: ComposerLane) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if lane.hasAttachments { attachmentStrip(lane) }
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
        .card(radius: 20, stroke: isDropTargeted ? Palette.accentText : (isFocused ? Palette.lineStrong : Palette.line),
              lineWidth: isDropTargeted ? 2 : 1)
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
        if isWorking { return "Uma rotina está rodando. Envie quando ela terminar." }
        return "Pergunte qualquer coisa ou solte um arquivo"
    }

    /// The line under the card: how the keys work, shown only when it helps and nothing else is being said.
    private func hint(_ lane: ComposerLane) -> String {
        if isQueueing, hasContent {
            return model.steersMidTurn(botID)
                ? "↩ entra na fila e chega ao Orb no próximo passo · ⌘↩ para e envia agora"
                : "↩ entra na fila e segue quando a resposta terminar · ⌘↩ para e envia agora"
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

    /// Send, and Stop while the Orb works. With something typed during a turn both show: Send queues it, Stop ends
    /// the turn. Alone, Stop is the white button; next to Send it steps back.
    @ViewBuilder private var actionButtons: some View {
        HStack(spacing: 6) {
            if isWorking {
                Button("Parar", systemImage: "stop.fill") { model.stop(botID) }
                    .buttonStyle(RoundActionStyle(isEnabled: true, isSecondary: canSend))
                    .help("\(CommandName.stop) (\(AppShortcut.stop.label))")
            }
            if !isWorking {
                sendButton.keyboardShortcut(.return, modifiers: .command)
            } else if canSend {
                sendButton.transition(.opacity) // ⌘↩ then means "stop and send" (see `shortcuts`)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: canSend)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isWorking)
    }

    private var sendButton: some View {
        Button(isQueueing ? "Enviar para a fila" : "Enviar", systemImage: "arrow.up", action: send)
            .buttonStyle(RoundActionStyle(isEnabled: canSend))
            .disabled(!canSend)
            .help(isQueueing ? "Colocar na fila (↩)" : "Enviar (↩)")
    }

    /// Shortcuts that belong to the composer without a visible button: ⌘↩ to stop and send, ⇧⌘M for the model list.
    private var shortcuts: some View {
        ZStack {
            Button("Parar e enviar") { model.stopAndSend(botID, draft: draft.wrappedValue) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!(isQueueing && canSend))
            Button("Escolher modelo") { isModelOpen.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
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
        Task {
            do { lane.pictures.append(try await load(store, botID)) }
            catch { lane.error = error.localizedDescription }
        }
    }

    /// ⌘V with a picture on the clipboard (a screenshot, an image copied from Preview) or with picture files copied in
    /// Finder attaches them; anything with text on the clipboard pastes as text, as before. The text field cannot
    /// take a picture, so the key is looked at before it gets there.
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v" else { return event }
            let taken = MainActor.assumeIsolated { pasteImages() }
            return taken ? nil : event
        }
    }

    private func removePasteMonitor() {
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }

    /// Whether the clipboard held pictures and they were taken.
    private func pasteImages() -> Bool {
        guard isFocused else { return false }
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

/// White circular send/stop button. Stepping back (`isSecondary`) when Send is next to it: a dark button.
private struct RoundActionStyle: ButtonStyle {
    let isEnabled: Bool
    var isSecondary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(isSecondary ? Palette.ink : Palette.onInk)
            .frame(width: 28, height: 28)
            .background(isSecondary ? Palette.raised : Palette.ink.opacity(isEnabled ? 1 : 0.25), in: .circle)
            .overlay { if isSecondary { Circle().strokeBorder(Palette.lineStrong) } }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Small icon button with a circular hover fill.
private struct IconGhostStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .frame(width: 28, height: 28)
            .background(configuration.isPressed || isHovering ? Palette.ghostSelected : .clear, in: .circle)
            .contentShape(.circle)
            .onHover { isHovering = $0 }
    }
}
