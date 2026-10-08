import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    @FocusState private var isFocused: Bool
    @State private var isImporting = false
    @State private var attachments: [URL] = []
    /// Pictures already decoded, shrunk and saved (see `ImageStore`); they go with the message as images.
    @State private var images: [ImageAttachment] = []
    @State private var attachmentError: String?
    @State private var pasteMonitor: Any?

    private var draft: Binding<String> {
        Binding(
            get: { model.drafts[bot.id, default: ""] },
            set: { model.drafts[bot.id] = $0 }
        )
    }

    private var isWorking: Bool { model.isWorking(bot.id) }
    private var canSend: Bool {
        !isWorking && (!draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty || !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(images, id: \.path) { image in
                            PictureChip(image: image) {
                                images.removeAll { $0 == image }
                                model.images.remove(image)
                            }
                        }
                        ForEach(attachments, id: \.self) { url in
                            AttachmentChip(name: url.lastPathComponent) {
                                attachments.removeAll { $0 == url }
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .scrollIndicators(.never)
            }
            if let attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(Palette.warn)
                    .padding(.horizontal, 4)
            }

            TextField("Pergunte qualquer coisa ou solte um arquivo", text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Palette.conversationFont)
                .foregroundStyle(Palette.ink)
                .lineLimit(1...8)
                .focused($isFocused)
                .onSubmit(send)
                .padding(.horizontal, 4)

            HStack(spacing: 2) {
                Button("Anexar", systemImage: "plus") { isImporting = true }
                    .help("Anexar arquivos")
                SkillMenu { insert("/\($0) ") }
                PermissionMenu(bot: bot)
                Spacer()
                ModelMenu(bot: bot)
                if isWorking {
                    Button("Parar", systemImage: "stop.fill") { model.stop(bot.id) }
                        .buttonStyle(RoundActionStyle(isEnabled: true))
                        .help("Parar resposta")
                } else {
                    Button("Enviar", systemImage: "arrow.up", action: send)
                        .buttonStyle(RoundActionStyle(isEnabled: canSend))
                        .disabled(!canSend)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Enviar (↩)")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(IconGhostStyle())
            .menuStyle(.borderlessButton)
            .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .card(radius: 20, stroke: isFocused ? Palette.lineStrong : Palette.line)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .frame(maxWidth: 760)
        .padding(.horizontal, 28)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [Palette.canvas.opacity(0), Palette.canvas], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
        }
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls)
            return true
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attach(urls) }
        }
        .onAppear {
            isFocused = true
            installPasteMonitor()
        }
        .onDisappear { removePasteMonitor() }
    }

    /// Pictures become image attachments (shrunk and saved in the background); other files keep being listed by path.
    private func attach(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            if ImageProcessing.isImageFile(url) {
                attachPicture { try await $0.attach(fileAt: url, botID: $1) }
            } else if !attachments.contains(url) {
                attachments.append(url)
            }
        }
    }

    private func attachPicture(_ load: @escaping @Sendable (ImageStore, UUID) async throws -> ImageAttachment) {
        attachmentError = nil
        let store = model.images, botID = bot.id
        Task {
            do { images.append(try await load(store, botID)) }
            catch { attachmentError = error.localizedDescription }
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
        guard canSend else { return }
        // If the message wasn't sent (no model connected), the attachments stay with the draft.
        if model.send(draft.wrappedValue, attachments: attachments, images: images, to: bot.id, fromUser: true) {
            attachments.removeAll()
            images.removeAll()
            attachmentError = nil
        }
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

private struct AttachmentChip: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
            Text(name).lineLimit(1)
            Button("Remover", systemImage: "xmark", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Palette.raised, in: .capsule)
    }
}

private struct SkillMenu: View {
    @Environment(AppModel.self) private var model
    let onPick: (String) -> Void

    var body: some View {
        Menu {
            ForEach(model.enabledSkills) { skill in
                Button(skill.name) { onPick(skill.slug) }
            }
        } label: {
            Label("Skills", systemImage: "wand.and.stars")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Usar uma skill")
    }
}

private struct PermissionMenu: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    @State private var isConfirmingBypass = false

    /// "Perguntar antes · 2 liberações": the grants only apply where the Orb asks.
    private var modeLabel: String {
        let count = bot.permissionRules.count
        guard bot.permissionMode == .ask, count > 0 else { return bot.permissionMode.label }
        return "\(bot.permissionMode.label) · \(count) \(count == 1 ? "liberação" : "liberações")"
    }

    private var grantsHelp: String {
        guard bot.permissionMode == .ask, !bot.permissionRules.isEmpty else { return "" }
        return "\n\nLiberado:\n" + bot.permissionRules.map { "• " + $0.title }.joined(separator: "\n")
    }

    var body: some View {
        Menu {
            Picker("Permissões", selection: Binding(
                get: { bot.permissionMode },
                set: { mode in model.update(bot.id) { $0.permissionMode = mode } }
            ).confirmingBypass { isConfirmingBypass = true }) {
                ForEach(PermissionMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(modeLabel, systemImage: bot.permissionMode.symbol)
                .foregroundStyle(bot.permissionMode == .bypass ? Palette.warn : Palette.muted)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Permissões: \(bot.permissionMode.label). \(bot.permissionMode.summary)" + grantsHelp)
        .bypassConfirmation(isPresented: $isConfirmingBypass) {
            model.update(bot.id) { $0.permissionMode = .bypass }
        }
    }
}

private struct ModelMenu: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    var body: some View {
        Menu {
            ModelPicker(selection: Binding(
                get: { bot.model },
                set: { name in model.update(bot.id) { $0.model = name } }
            ))
            .pickerStyle(.inline)
        } label: {
            Text(model.modelName(for: bot).isEmpty ? "Sem modelo" : model.modelName(for: bot))
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Palette.raised, in: .capsule)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Modelo deste Orb")
    }
}

/// White circular send/stop button.
private struct RoundActionStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Palette.onInk)
            .frame(width: 28, height: 28)
            .background(Palette.ink.opacity(isEnabled ? 1 : 0.25), in: .circle)
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
