import SwiftUI

// How the chat shows attachments: pictures in a grid of one width, files as cards (an icon for the type, the name cut
// in the middle so the extension stays, "PDF · 2,1 MB"), the same in a sent message, in one that waits in the queue and
// under the tool line of a file the Orb made. A click opens Quick Look on all of them; the right button offers Abrir,
// Mostrar no Finder and Copiar caminho; a file can be dragged out. Nothing reads the disk on the main thread: the cards
// start from the name and fill in the size when `AttachmentInfo.load` returns.

/// The attachments of one message: the grid of pictures, then up to four file cards, in a column at most 260 pt wide.
struct AttachmentStack: View {
    let paths: [String]
    /// Waiting in the queue, not sent: a little dimmed, like the bubble beside it.
    var dimmed = false

    static let width: CGFloat = 260

    var body: some View {
        let parts = AttachmentLayout.split(paths)
        let all = parts.images + parts.files
        let shown = parts.files.prefix(AttachmentLayout.fileLimit)
        let hidden = parts.files.count - shown.count
        VStack(alignment: .trailing, spacing: 6) {
            if !parts.images.isEmpty { AttachmentGrid(paths: parts.images, all: all) }
            if !shown.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, path in
                        FileCard(path: path, all: all)
                    }
                    if hidden > 0 {
                        Button("+\(hidden) \(hidden == 1 ? "arquivo" : "arquivos")") {
                            QuickLookPreview.show(all, at: parts.images.count + shown.count)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                    }
                }
            }
        }
        .frame(maxWidth: Self.width, alignment: .trailing)
        .opacity(dimmed ? 0.75 : 1)
    }
}

/// The pictures of a message in one width: one wide, two side by side, three or more in three columns (nine at most,
/// the last one saying how many more there are).
struct AttachmentGrid: View {
    let paths: [String]
    /// Everything Quick Look pages through, the pictures first.
    let all: [String]

    var body: some View {
        let plan = AttachmentLayout.grid(count: paths.count)
        let shown = Array(paths.prefix(plan.visible))
        Grid(alignment: .topLeading, horizontalSpacing: plan.spacing, verticalSpacing: plan.spacing) {
            ForEach(Array(stride(from: 0, to: shown.count, by: plan.columns)), id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + plan.columns, shown.count), id: \.self) { index in
                        ImageTile(path: shown[index], size: plan.cell, all: all, label: label(index),
                                  more: plan.overflow > 0 && index == plan.visible - 1 ? plan.overflow + 1 : 0)
                    }
                }
            }
        }
    }

    private func label(_ index: Int) -> String {
        paths.count == 1 ? "Imagem anexada" : "Imagem anexada \(index + 1) de \(paths.count)"
    }
}

/// One picture of the grid, or the capture under a tool line. `more`: the tile that stands for the pictures that did not fit.
struct ImageTile: View {
    let path: String
    let size: CGSize
    let all: [String]
    let label: String
    var more = 0
    @State private var info: AttachmentInfo

    init(path: String, size: CGSize, all: [String], label: String, more: Int = 0) {
        self.path = path
        self.size = size
        self.all = all
        self.label = label
        self.more = more
        _info = State(initialValue: AttachmentInfo.cachedOrQuick(path))
    }

    var body: some View {
        ImageThumbnail(path: path, size: size)
            .overlay {
                if more > 0 {
                    RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.45))
                    Text("+\(more)").font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.ink)
                }
            }
            .opacity(info.state == .missing ? 0.55 : 1)
            .attachmentActions(path: path, all: all, info: info, label: label + (info.state == .missing ? ", arquivo ausente" : ""),
                               help: info.state == .ok ? "Ver imagem" : "Imagem não está mais aqui")
            .task(id: path) { info = await AttachmentInfo.load(path: path) }
    }
}

/// A file: the icon of its type, its name and "PDF · 2,1 MB". `note` goes after that ("novo", "alterado").
struct FileCard: View {
    enum Style { case regular, compact }

    let path: String
    let all: [String]
    var style = Style.regular
    var note: String?
    /// Taller than the style's own height, to line up with what stands beside it (the composer's pictures are 56 pt).
    var minHeight: CGFloat?
    @State private var info: AttachmentInfo
    @State private var isHovering = false

    init(path: String, all: [String], style: Style = .regular, note: String? = nil, minHeight: CGFloat? = nil) {
        self.path = path
        self.all = all
        self.style = style
        self.note = note
        self.minHeight = minHeight
        _info = State(initialValue: AttachmentInfo.cachedOrQuick(path))
    }

    private var isCompact: Bool { style == .compact }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: info.state == .missing ? "exclamationmark.triangle" : info.symbol)
                .font(.system(size: isCompact ? 13 : 15))
                .foregroundStyle(info.state == .missing ? Palette.warn : Palette.muted)
                .frame(width: isCompact ? 28 : 32, height: isCompact ? 28 : 32)
                .background(Palette.surface, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let caption = [info.caption, info.state == .ok ? note : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: isCompact ? 280 : AttachmentStack.width, minHeight: minHeight ?? (isCompact ? 40 : 48), alignment: .leading)
        .hoverFill(isHovering && info.state == .ok, in: .rect(cornerRadius: 10), color: Palette.agentBubble, resting: Palette.raised)
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line) }
        .opacity(info.state == .missing ? 0.55 : 1)
        .motion(Motion.fade, value: info)
        .onHover { isHovering = $0 }
        .attachmentActions(path: path, all: all, info: info, label: TranscriptSpeech.attachment(info), help: path)
        .task(id: path) { info = await AttachmentInfo.load(path: path) }
    }
}

/// The files the Orb made or changed with a tool call, under its line: a card for each ("novo" or "alterado"), a
/// thumbnail for a picture (a capture of the screen). At most three.
struct ProducedFilesView: View {
    let files: [ProducedFile]

    static let limit = 3

    var body: some View {
        let shown = Array(files.prefix(Self.limit))
        let all = shown.map(\.path)
        VStack(alignment: .leading, spacing: 4) {
            // By path: when `BotSession.takeOver` takes a file off an earlier call, the card of the file that stays keeps its own.
            ForEach(shown, id: \.path) { file in
                if file.path.hasPrefix("/"), ImageProcessing.isImageFile(URL(fileURLWithPath: file.path)) {
                    ImageTile(path: file.path, size: CGSize(width: 112, height: 72), all: all, label: "Imagem criada")
                } else {
                    FileCard(path: file.path, all: all, style: .compact, note: file.created ? "novo" : "alterado")
                }
            }
        }
    }
}

// MARK: - Actions

extension View {
    /// Click = Quick Look on `all` (starting here), a menu with Abrir, Mostrar no Finder, Copiar and Copiar caminho, and the
    /// file itself to drag out. A file that is gone (or only a name, from older data) has nothing to open.
    func attachmentActions(path: String, all: [String], info: AttachmentInfo, label: String, help: String) -> some View {
        modifier(AttachmentActions(path: path, all: all, info: info, label: label, help: help))
    }
}

private struct AttachmentActions: ViewModifier {
    let path: String
    let all: [String]
    let info: AttachmentInfo
    let label: String
    let help: String

    private var url: URL { URL(fileURLWithPath: path) }

    private var isOK: Bool { info.state == .ok }

    func body(content: Content) -> some View {
        // A tap gesture, not a Button: a Button takes the mouse-down and the drag never starts.
        Group {
            if isOK {
                content
                    .contentShape(.rect)
                    .onTapGesture { preview() }
                    .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            } else {
                content
            }
        }
        .contextMenu { menu }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint(isOK ? "Abre a pré-visualização" : "")
        .accessibilityAddTraits(isOK ? .isButton : [])
        .accessibilityActions {
            if isOK {
                Button("Abrir a pré-visualização") { preview() }
                Button("Mostrar no Finder") { reveal() }
            }
            if info.state != .legacy { Button("Copiar caminho") { Clipboard.copy(path) } }
        }
    }

    @ViewBuilder private var menu: some View {
        switch info.state {
        case .ok:
            Button("Abrir") { NSWorkspace.shared.open(url) }
            Button("Mostrar no Finder") { reveal() }
            Button("Copiar") { copyFile() }
            Button("Copiar caminho") { Clipboard.copy(path) }
        case .missing:
            Button("Copiar caminho") { Clipboard.copy(path) }
            if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
                Button("Mostrar pasta") { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
            }
        case .legacy:
            EmptyView()
        }
    }

    private func preview() { QuickLookPreview.show(all, at: all.firstIndex(of: path) ?? 0) }
    private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// The file itself on the pasteboard, to paste into the Finder or a message.
    private func copyFile() {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
    }
}
