import SwiftUI

/// The field under a group's thread. ↩ sends, ⇧↩ or ⌥↩ breaks the line, "@" opens the members (and "todos") with ↑↓, ↩ or ⇥, and
/// Esc closes the list. Pictures (and only pictures) go with the message: the "+", ⌘V and a drop on the chat put them in the
/// strip above the field, with the limits and warnings of an Orb's chat (`AppModel.attachPicture`).
struct GroupComposer: View {
    @Environment(AppModel.self) private var model
    let groupID: UUID
    /// The pictures waiting to be sent, and the warning about the last one that failed. Kept by the app per group, like the text.
    let lane: ComposerLane
    /// The names of the members: what a mention can call.
    let names: [String]
    /// The members as the picker draws them (avatar and role); `names` is what the mention rules work on.
    let looks: [BotLook]
    /// The draft: kept by the app per group, so it is still there after a visit to another conversation.
    @Binding var text: String
    /// Sends the message with the lane's pictures; false when it was not sent, and then text and pictures stay.
    let onSend: (String) -> Bool
    @State private var selected = 0
    /// Esc closed the list; a change of the text opens it again.
    @State private var isPickerDismissed = false
    @State private var isImporting = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var query: String? { MentionCandidates.openQuery(in: text) }
    private var options: [String] { query.map { MentionCandidates.options(query: $0, names: names) } ?? [] }
    private var isPicking: Bool { !isPickerDismissed && query != nil && !options.isEmpty }
    /// Something to send (text or a picture), and no picture still being prepared: it would miss this message.
    private var canSend: Bool {
        ComposerAction.canSend(hasContent: text.contains { !$0.isWhitespace } || !lane.pictures.isEmpty, isWorking: false,
                               canQueue: false, pendingPictures: lane.pendingPictures)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isPicking {
                MentionPicker(options: options, looks: looks, selected: min(selected, options.count - 1), choose: choose)
                    .transition(.adapted(.rise, reduceMotion: reduceMotion))
            }
            // The card: the pictures and the warning over the field, as in an Orb's composer.
            VStack(alignment: .leading, spacing: 8) {
                if !lane.pictures.isEmpty || lane.pendingPictures > 0 { pictureStrip }
                if let error = lane.error { errorLine(error) }
                HStack(alignment: .bottom, spacing: 8) {
                    Button("Anexar imagens", systemImage: "plus") { isImporting = true }
                        .labelStyle(.iconOnly)
                        .buttonStyle(CircleGhostStyle(side: 28, fontSize: 13))
                        .foregroundStyle(Palette.muted)
                        .help(Tip.attachPictures)
                    TextField("Escreva para o grupo. Use @ para chamar um Orb", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Palette.conversationFont)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1...8)
                        .focused($isFocused)
                        .onKeyPress(.return, phases: .down) { press in
                            // ⌥↩ is the line break: the field takes it as it is. ⇧↩ makes the same one.
                            if press.modifiers.contains(.option) { return .ignored }
                            if press.modifiers.contains(.shift), let window = NSApp.keyWindow {
                                return NewLineKey.insert(in: window) ? .handled : .ignored
                            }
                            if isPicking {
                                choose(options[min(selected, options.count - 1)])
                            } else {
                                send()
                            }
                            return .handled
                        }
                        .onKeyPress(.downArrow) { isPicking ? move(1) : .ignored }
                        .onKeyPress(.upArrow) { isPicking ? move(-1) : .ignored }
                        .onKeyPress(keys: [.tab]) { _ in
                            guard isPicking else { return .ignored }
                            choose(options[min(selected, options.count - 1)])
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            guard isPicking else { return .ignored }
                            isPickerDismissed = true
                            return .handled
                        }
                        .onChange(of: text) {
                            selected = 0
                            isPickerDismissed = false
                            if lane.error != nil { lane.error = nil } // it was about what was there before
                        }
                        .accessibilityLabel("Mensagem para o grupo")
                    SendArrowButton(canSend: canSend, help: "Enviar para o grupo (↩)", action: send)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isFocused ? Palette.surfaceFocused : Palette.surface, in: .rect(cornerRadius: Radius.large))
            .overlay(RoundedRectangle(cornerRadius: Radius.large).strokeBorder(isFocused ? Palette.lineStrong : Palette.line, lineWidth: 1))
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
        .animation(Motion.adapted(Motion.enter, reduceMotion: reduceMotion), value: isPicking)
        .background { ApprovalKeyMonitor(handler: handleKey) }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.attach(urls, toGroup: groupID) }
            isFocused = true
        }
        // The caller gives each group its own composer (`.id`), so this runs when the group opens or changes.
        .onAppear { isFocused = true }
    }

    // MARK: Pictures

    private var pictureStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(lane.pictures, id: \.path) { image in
                    PictureChip(image: image) {
                        lane.pictures.removeAll { $0 == image }
                        model.images.remove(image) // never sent: nothing else points at the file
                    }
                }
                if lane.pendingPictures > 0 { PreparingChip(count: lane.pendingPictures) }
            }
            .padding(.top, 10)
            .padding(.trailing, 10)
        }
        .scrollIndicators(.never)
        .padding(.top, -4) // room for the remove buttons' targets, as in an Orb's composer
    }

    private func errorLine(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
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

    /// ⌘V with a picture on the clipboard attaches it; text pastes as text. Only while the field has the focus, in its own
    /// window and with no sheet over it, as in an Orb's composer.
    private func handleKey(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard PasteGate.takes(eventIsInComposerWindow: event.window === window, isKey: window.isKeyWindow,
                              hasSheet: window.attachedSheet != nil, isFocused: isFocused),
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "v" else { return false }
        let model = model, groupID = groupID, lane = lane
        return AppModel.takePastedPictures(files: { model.attach($0, toGroup: groupID) }) { data in
            model.attachPicture(into: lane, of: groupID) { try await $0.attach(data, name: "imagem colada", botID: $1) }
        }
    }

    private func send() {
        guard canSend else { return }
        // The text goes only if the message did; the pictures leave the lane by the same rule (`AppModel.postUserMessage`).
        if onSend(text.trimmingCharacters(in: .whitespacesAndNewlines)) { text = "" }
    }

    private func choose(_ option: String) {
        text = MentionCandidates.inserting(option, into: text)
        selected = 0
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let count = options.count
        guard count > 0 else { return .ignored }
        selected = (selected + step + count) % count
        return .handled
    }
}
