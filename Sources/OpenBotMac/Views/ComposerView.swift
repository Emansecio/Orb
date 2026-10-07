import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    @FocusState private var isFocused: Bool
    @State private var isImporting = false
    @State private var attachments: [URL] = []

    private var draft: Binding<String> {
        Binding(
            get: { model.drafts[bot.id, default: ""] },
            set: { model.drafts[bot.id] = $0 }
        )
    }

    private var isWorking: Bool { model.isWorking(bot.id) }
    private var canSend: Bool {
        !isWorking && !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { url in
                            AttachmentChip(name: url.lastPathComponent) {
                                attachments.removeAll { $0 == url }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
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
            attachments.append(contentsOf: urls.filter(\.isFileURL))
            return true
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attachments.append(contentsOf: urls) }
        }
        .onAppear { isFocused = true }
    }

    private func send() {
        guard canSend else { return }
        model.send(draft.wrappedValue, attachments: attachments, to: bot.id)
        attachments.removeAll()
    }

    private func insert(_ token: String) {
        let current = draft.wrappedValue
        draft.wrappedValue = current.isEmpty || current.hasSuffix(" ") ? current + token : current + " " + token
        isFocused = true
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
            ForEach(model.skills) { skill in
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

    var body: some View {
        Menu {
            Picker("Permissões", selection: Binding(
                get: { bot.permissionMode },
                set: { mode in model.update(bot.id) { $0.permissionMode = mode } }
            )) {
                ForEach(PermissionMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(bot.permissionMode.label, systemImage: bot.permissionMode.symbol)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Permissões: \(bot.permissionMode.label)")
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
            Text(model.modelID(for: bot).isEmpty ? "Sem modelo" : model.modelID(for: bot))
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Palette.raised, in: .capsule)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Modelo deste bot")
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
