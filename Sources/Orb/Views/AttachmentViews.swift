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
                        .help(Tip.moreAttachments)
                        .font(Typography.small)
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
    /// The side the picture is decoded for (`ImageThumbnail`): the chat's grid copy unless the tile is larger.
    var decodeSide = Thumbnails.gridSide
    @State private var info: AttachmentInfo

    init(path: String, size: CGSize, all: [String], label: String, more: Int = 0, decodeSide: CGFloat = Thumbnails.gridSide) {
        self.path = path
        self.size = size
        self.all = all
        self.label = label
        self.more = more
        self.decodeSide = decodeSide
        _info = State(initialValue: AttachmentInfo.cachedOrQuick(path))
    }

    var body: some View {
        ImageThumbnail(path: path, size: size, decodeSide: decodeSide)
            .overlay {
                if more > 0 {
                    RoundedRectangle(cornerRadius: Radius.medium).fill(.black.opacity(0.45))
                    Text("+\(more)").font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.ink)
                }
            }
            .opacity(info.state == .missing ? 0.55 : 1)
            .attachmentActions(path: path, all: all, info: info, label: label + (info.state == .missing ? ", arquivo ausente" : ""),
                               help: info.state == .ok ? Tip.previewImage : Tip.missingAttachment)
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
                .background(Palette.surface, in: .rect(cornerRadius: Radius.small))
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name)
                    .font(Typography.label.weight(.medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let caption = [info.caption, info.state == .ok ? note : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !caption.isEmpty {
                    Text(caption)
                        .font(Typography.small)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: isCompact ? 280 : AttachmentStack.width, minHeight: minHeight ?? (isCompact ? 40 : 48), alignment: .leading)
        .hoverFill(isHovering && info.state == .ok, in: .rect(cornerRadius: Radius.medium), color: Palette.raisedHover, resting: Palette.raised)
        .overlay { RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Palette.line) }
        .opacity(info.state == .missing ? 0.55 : 1)
        .motion(Motion.fade, value: info)
        .onHover { isHovering = $0 }
        .attachmentActions(path: path, all: all, info: info, label: TranscriptSpeech.attachment(info),
                               help: info.state == .ok ? Tip.previewAttachment : Tip.missingAttachment)
        .task(id: path) { info = await AttachmentInfo.load(path: path) }
    }
}

/// The files the Orb made or changed with a tool call, under its line. A picture is a thumbnail (at most three); the
/// other files are one line, "3 arquivos novos: a.txt · b.txt · c.txt", each name opening the file in Quick Look, so a
/// run that wrote a few working files does not stack a card for each. `captures`: the pictures that are what the Orb
/// saw (a capture of the screen or a page, see `ToolCall.capturedPictures`), named so instead of "Imagem criada".
struct ProducedFilesView: View {
    let files: [ProducedFile]
    var captures: Set<String> = []

    static let limit = 3

    var body: some View {
        let (shown, others) = Self.split(files)
        let all = shown.map(\.path)
        VStack(alignment: .leading, spacing: 4) {
            if !others.isEmpty {
                ProducedFilesLine(files: others)
            }
            // By path: when `BotSession.takeOver` takes a file off an earlier call, the tile of the file that stays keeps its own.
            ForEach(shown, id: \.path) { file in
                ImageTile(path: file.path, size: CGSize(width: 112, height: 72), all: all, label: captures.contains(file.path) ? "Captura" : "Imagem criada")
            }
        }
    }

    /// The pictures shown (at most `limit`) and the other files, in one pass: `isPicture` checks each file's type, so it
    /// is asked once per file instead of once per filter.
    private static func split(_ files: [ProducedFile]) -> (pictures: [ProducedFile], others: [ProducedFile]) {
        var pictures: [ProducedFile] = [], others: [ProducedFile] = []
        for file in files {
            if !isPicture(file) { others.append(file) } else if pictures.count < limit { pictures.append(file) }
        }
        return (pictures, others)
    }

    private static func isPicture(_ file: ProducedFile) -> Bool {
        file.path.hasPrefix("/") && ImageProcessing.isImageFile(URL(fileURLWithPath: file.path))
    }

    /// "3 arquivos novos", "1 arquivo alterado", "3 arquivos (2 novos, 1 alterado)".
    nonisolated static func heading(_ files: [ProducedFile]) -> String {
        let created = files.count(where: \.created), changed = files.count - created
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        if changed == 0 { return count(created, "arquivo novo", "arquivos novos") }
        if created == 0 { return count(changed, "arquivo alterado", "arquivos alterados") }
        return "\(files.count) arquivos (\(count(created, "novo", "novos")), \(count(changed, "alterado", "alterados")))"
    }
}

/// The line of the files that are not pictures: as many names as fit, then "e mais 2"; when not even one fits, the
/// heading alone, which opens the first. Quick Look's arrows go through all of them.
private struct ProducedFilesLine: View {
    let files: [ProducedFile]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(Palette.faint)
                .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                naming(3)
                naming(2)
                naming(1)
                naming(0)
            }
        }
        .font(Typography.label)
        .accessibilityElement(children: .contain)
    }

    private func naming(_ wanted: Int) -> some View {
        let named = min(wanted, files.count), all = files.map(\.path)
        let heading = ProducedFilesView.heading(files)
        return HStack(spacing: 4) {
            if named == 0 {
                FileNameLink(path: files[0].path, all: all, title: heading)
            } else {
                Text(heading + ":").foregroundStyle(Palette.faint)
                ForEach(Array(files.prefix(named).enumerated()), id: \.element.path) { index, file in
                    if index > 0 { Text("·").foregroundStyle(Palette.faint).accessibilityHidden(true) }
                    FileNameLink(path: file.path, all: all)
                }
                if files.count > named {
                    Text("e mais \(files.count - named)").foregroundStyle(Palette.faint)
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// A file's name in `ProducedFilesLine`: a click opens it in Quick Look, the right click has the card's menu, and it
/// drags out as the file. One that is gone is dimmed and does nothing.
private struct FileNameLink: View {
    let path: String
    let all: [String]
    /// Said instead of the name (the heading, when no name fits).
    var title: String?
    @State private var info: AttachmentInfo
    @State private var isHovering = false

    init(path: String, all: [String], title: String? = nil) {
        self.path = path
        self.all = all
        self.title = title
        _info = State(initialValue: AttachmentInfo.cachedOrQuick(path))
    }

    var body: some View {
        let isOK = info.state == .ok
        Text(title ?? info.name)
            .foregroundStyle(isOK ? (isHovering ? Palette.ink : Palette.secondary) : Palette.hint)
            .underline(isHovering && isOK, color: Palette.muted)
            .onHover { isHovering = $0 }
            .clickablePointer(isOK)
            .attachmentActions(path: path, all: all, info: info, label: title ?? TranscriptSpeech.attachment(info),
                               help: isOK ? Tip.previewAttachment : Tip.missingAttachment)
            .task(id: path) { info = await AttachmentInfo.load(path: path) }
    }
}

/// The captures of the screen or a page that a run of actions took, in order, as a strip: what the Orb saw at each
/// step, with the step that took it. A click opens them in Quick Look, where the arrows go from step to step.
struct ScreenStepsStrip: View {
    struct Step: Equatable {
        var path: String
        var caption: String
    }

    let steps: [Step]

    /// From this many captures on, a run gets the strip; fewer stay as the thumbnails of their lines.
    nonisolated static let minimum = 2
    private static let tile = CGSize(width: 120, height: 76)

    var body: some View {
        let all = steps.map(\.path)
        VStack(alignment: .leading, spacing: 6) {
            Text("\(steps.count) capturas, em ordem")
                .font(Typography.small)
                .foregroundStyle(Palette.faint)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 8) {
                    ForEach(Array(steps.enumerated()), id: \.element.path) { index, step in
                        VStack(alignment: .leading, spacing: 3) {
                            ImageTile(path: step.path, size: Self.tile, all: all, label: "Passo \(index + 1): \(step.caption)")
                            Text("\(index + 1) · \(step.caption)")
                                .font(Typography.small)
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: Self.tile.width, alignment: .leading)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    /// The captures of `calls` that are still pictures, each named by what it shows: the window it names, or else the
    /// action just before it (a capture of the page says nothing by itself: "Capturando a página"). Only what looked at
    /// the screen or a page: a chart a command drew or a picture written to a file is a result, not a step. nil when
    /// there are too few for a strip.
    nonisolated static func steps(of calls: [ToolCall]) -> [Step]? {
        var steps: [Step] = []
        var before: ToolCall?
        for call in calls where call.state == .done {
            let pictures = call.capturedPictures
            guard !pictures.isEmpty else {
                before = call
                continue
            }
            let named = call.detail.isEmpty ? before.map { $0.detail.isEmpty ? $0.title : $0.detail } : call.detail
            steps += pictures.map { Step(path: $0.path, caption: named ?? call.title) }
            before = nil
        }
        return steps.count >= minimum ? steps : nil
    }
}

extension ToolCall {
    /// The pictures of this call that are what the Orb saw: captures of the screen or a page. A chart a command drew or a
    /// picture written to a file is a result, not a capture.
    var capturedPictures: [ProducedFile] {
        guard kind == .computer || kind == .browser else { return [] }
        return (files ?? []).filter { $0.path.hasPrefix("/") && ImageProcessing.isImageFile(URL(fileURLWithPath: $0.path)) }
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
