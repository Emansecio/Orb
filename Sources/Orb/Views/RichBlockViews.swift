import AppKit
import SwiftUI
import WebKit

/// A block drawn instead of written (a chart, a diagram, a formula, a page), in the frame of a code block: the same fill, its
/// name, a way to its source, the enlarged view and "Copiar", which always gives the source.
struct RichBlockFrame<Content: View>: View {
    @Environment(\.enlargeBlock) private var enlarge
    let title: String
    let source: String
    let language: String?
    let block: MarkdownBlock
    @Binding var showsSource: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.m) {
                Text(title)
                    .font(Typography.small)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: Spacing.s)
                BlockHeaderButton(title: showsSource ? "Desenho" : "Código", symbol: showsSource ? "photo" : "chevron.left.forwardslash.chevron.right",
                                  help: showsSource ? Tip.showDrawing : Tip.showSource) { showsSource.toggle() }
                if let enlarge { EnlargeButton { enlarge.run(block) } }
                CopyTextButton(text: source, help: Tip.copyCode, label: "Copiar código", copiedLabel: "Código copiado")
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 2)
            if showsSource {
                CodeLines(text: source, language: language)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            } else {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.raised, in: .rect(cornerRadius: Radius.small))
        .accessibilityElement(children: .contain)
    }
}

/// A word and a symbol in a block's header, in the look of `CopyTextButton`.
struct BlockHeaderButton: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(Typography.small.weight(.medium))
            .foregroundStyle(Palette.muted)
        }
        .buttonStyle(.plain)
        .clickablePointer()
        .help(help)
    }
}

/// Opens a block in the enlarged view.
struct EnlargeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(Typography.small.weight(.medium))
                .foregroundStyle(Palette.muted)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickablePointer()
        .help(Tip.enlargeBlock)
        .accessibilityLabel("Ampliar")
    }
}

/// A diagram or a formula in its frame.
struct RichDrawingView: View, Equatable {
    let request: RichRequest
    let block: MarkdownBlock
    @State private var showsSource = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.request == rhs.request }

    private var title: String { request.kind == .math ? "fórmula" : "diagrama" }

    var body: some View {
        RichBlockFrame(title: title, source: request.source, language: nil, block: block, showsSource: $showsSource) {
            RichPicture(request: request, title: title.capitalized)
        }
    }
}

/// What `RichRenderer` drew. While it draws, and for good when it cannot, the source shows as code with the reason under it,
/// never an empty space.
struct RichPicture: View {
    let request: RichRequest
    let title: String
    @State private var outcome: RichOutcome?
    @State private var picture: NSImage?

    init(request: RichRequest, title: String) {
        self.request = request
        self.title = title
        _outcome = State(initialValue: RichRenderer.shared.known(request))
    }

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .task(id: request) {
                let drawn = await RichRenderer.shared.draw(request)
                let loaded = await RichPictures.load(drawn)
                outcome = drawn
                picture = loaded
            }
    }

    @ViewBuilder private var content: some View {
        if case .image(_, let size) = outcome, let picture {
            Image(nsImage: picture)
                .resizable()
                .interpolation(.high)
                .aspectRatio(size, contentMode: .fit)
                .frame(maxWidth: size.width, maxHeight: size.height)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(request.source))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                CodeLines(text: request.source)
                if case .failed(let reason) = outcome {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(Typography.small)
                        .foregroundStyle(Palette.muted)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// A ```page fence: the picture of the page without its scripts, and a button that opens it alive in the enlarged view, the only place a page ever
/// runs for the person, so there is one at a time and no web view in the list. Off in Ajustes, it is code.
struct PageBlockView: View {
    @Environment(\.enlargeBlock) private var enlarge
    @AppStorage(PageSandbox.settingKey) private var isEnabled = true
    @State private var showsSource = false
    let html: String
    let block: MarkdownBlock

    var body: some View {
        if isEnabled {
            RichBlockFrame(title: "página interativa", source: html, language: "html", block: block, showsSource: $showsSource) {
                RichPicture(request: RichRequest(kind: .page, source: html), title: "Página interativa")
                if let enlarge {
                    Button("Abrir página") { enlarge.run(block) }
                        .buttonStyle(PrimaryPillStyle())
                        .help(Tip.openPage)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
        } else {
            CodeBlockView(language: "html", code: html)
        }
    }
}

/// Pictures read from the renderer's folder, off the main thread.
enum RichPictures {
    static func load(_ outcome: RichOutcome) async -> NSImage? {
        guard case .image(let url, let size) = outcome else { return nil }
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        guard let data, let image = NSImage(data: data) else { return nil }
        image.size = size
        return image
    }
}

/// Opens a block in the enlarged view; set by the chat. Equal whatever its closure: it only reaches the chat's own state.
struct EnlargeBlockAction: Equatable {
    let run: @MainActor (MarkdownBlock) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var enlargeBlock: EnlargeBlockAction?
}

struct EnlargedBlock: Identifiable {
    let id = UUID()
    let block: MarkdownBlock
}

/// A block with the whole window to itself: code and tables to read, charts larger, diagrams to zoom and drag. Esc closes it.
struct EnlargedBlockSheet: View {
    @Environment(\.dismiss) private var dismiss
    let block: MarkdownBlock

    private var title: String {
        switch block {
        case .code(let language, _, _): language ?? "Código"
        case .table: "Tabela"
        case .chart(let spec, _): spec.title ?? "Gráfico"
        case .diagram: "Diagrama"
        case .math: "Fórmula"
        case .page: "Página interativa"
        default: "Bloco"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(Typography.title)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.m)
                SheetCloseButton { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Spacing.sheetEdge)
            .padding(.top, Spacing.sheetHeaderTop)
            .padding(.bottom, Spacing.sheetHeaderBottom)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, idealWidth: 980, maxWidth: 1600, minHeight: 420, idealHeight: 680, maxHeight: 1200)
        .background(Palette.chrome)
        .registersOpenSheet()
    }

    @ViewBuilder private var content: some View {
        switch block {
        case .code(let language, let code, _):
            ScrollView {
                CodeLines(text: code, language: language)
                    .textSelection(.enabled)
                    .padding(Spacing.sheetEdge)
            }
        case .table(let table):
            ScrollView { TableBlockView(table: table).padding(Spacing.sheetEdge) }
        case .chart(let spec, _):
            ChartCanvas(spec: spec).padding(Spacing.sheetEdge)
        case .diagram(let source):
            ZoomingPicture(request: RichRequest(kind: .diagram, source: source))
        case .math(let tex):
            ZoomingPicture(request: RichRequest(kind: .math, source: tex))
        case .page(let html):
            LivePageView(html: html)
        default:
            EmptyView()
        }
    }
}

/// A page alive, in the sheet. Closing the sheet ends it. All it can do is propose a text, which shows here and goes to the
/// composer only if the person says so; sending stays theirs.
private struct LivePageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let html: String
    @State private var view: WKWebView?
    @State private var failed = false
    @State private var proposal: String?
    @State private var inbox = PageProposals()

    var body: some View {
        VStack(spacing: 0) {
            if let view {
                HostedPage(view: view)
            } else if failed {
                Text("Não consegui abrir esta página.")
                    .font(Typography.text)
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let proposal { proposalBar(proposal) }
        }
        .task {
            inbox.received = { proposal = $0 }
            guard let page = await PageSandbox.makeView(javaScript: true, messages: inbox) else {
                failed = true
                return
            }
            view = page
            let loaded = await PageSandbox.load(page, deadline: .seconds(10)) {
                page.loadHTMLString(PageSandbox.document(html, scripts: true), baseURL: nil)
            }
            if !loaded {
                page.stopLoading()
                view = nil
                failed = true
            }
        }
        .onDisappear {
            view?.stopLoading()
            view?.configuration.userContentController.removeAllScriptMessageHandlers()
        }
    }

    /// The whole text, as it would go: a page must not be able to hide its tail below the first lines.
    private func proposalBar(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("A página sugere:")
                .font(Typography.label.weight(.medium))
                .foregroundStyle(Palette.secondary)
            ScrollView {
                Text(text)
                    .font(Typography.label)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button("Ignorar") {
                    inbox.mute()
                    proposal = nil
                }
                .buttonStyle(GhostStyle())
                .help(Tip.ignoreProposals)
                Button("Pôr na mensagem") {
                    // Keep the proposal when there is nowhere to put it.
                    guard let id = model.draftTargetID else { return }
                    model.addToDraft(text, for: id)
                    dismiss()
                }
                .buttonStyle(PrimaryPillStyle())
                .help(Tip.useProposal)
            }
        }
        .padding(.horizontal, Spacing.sheetEdge)
        .padding(.vertical, Spacing.m)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}

private struct HostedPage: NSViewRepresentable {
    let view: WKWebView

    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// What a live page says to the app, through `window.orb.propose`.
@MainActor private final class PageProposals: NSObject, WKScriptMessageHandler {
    var received: ((String) -> Void)?
    private var isMuted = false
    /// One at a time, so a page on a timer cannot swap the text under the person's pointer.
    private var hasOne = false

    /// "Ignorar": this page has nothing more to say.
    func mute() { isMuted = true }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !isMuted, !hasOne, message.frameInfo.isMainFrame, let text = message.body as? String else { return }
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PageSandbox.proposalLimit))
        guard !clean.isEmpty else { return }
        hasOne = true
        received?(clean)
    }
}

/// A picture to zoom and drag: pinch, or the buttons (which the keyboard reaches); two fingers or a drag move it.
private struct ZoomingPicture: View {
    let request: RichRequest
    @State private var picture: NSImage?
    @State private var problem: String?
    @State private var command = ZoomCommand()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let picture {
                ZoomingScrollView(image: picture, command: command)
                HStack(spacing: Spacing.m) {
                    zoomButton("Reduzir", "minus", key: "-") { command.by(1 / 1.4) }
                    zoomButton("Tamanho inteiro", "arrow.counterclockwise", key: "0") { command.fit() }
                    zoomButton("Aumentar", "plus", key: "=") { command.by(1.4) }
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
                .background(Palette.surface, in: .capsule)
                .overlay(Capsule().strokeBorder(Palette.line))
                .padding(Spacing.l)
            } else if let problem {
                Text(problem)
                    .font(Typography.text)
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let outcome = await RichRenderer.shared.draw(request)
            picture = await RichPictures.load(outcome)
            guard picture == nil else { return }
            if case .failed(let reason) = outcome { problem = reason } else { problem = "Não consegui abrir o desenho." }
        }
    }

    private func zoomButton(_ title: String, _ symbol: String, key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .keyboardShortcut(key, modifiers: .command)
            .foregroundStyle(Palette.muted)
            .frame(width: 22, height: 22)
            .contentShape(.rect)
            .help(title)
    }
}

/// What the buttons ask of the scroll view.
@MainActor private final class ZoomCommand {
    weak var view: NSScrollView?

    func by(_ factor: CGFloat) {
        guard let view else { return }
        view.setMagnification(view.magnification * factor, centeredAt: NSPoint(x: view.documentVisibleRect.midX, y: view.documentVisibleRect.midY))
    }

    func fit() {
        guard let view, let document = view.documentView else { return }
        view.magnify(toFit: document.bounds)
    }
}

private struct ZoomingScrollView: NSViewRepresentable {
    let image: NSImage
    let command: ZoomCommand

    /// Dragging moves the picture.
    final class DragView: NSImageView {
        override func mouseDragged(with event: NSEvent) {
            guard let clip = enclosingScrollView?.contentView else { return }
            var origin = clip.bounds.origin
            origin.x -= event.deltaX / (enclosingScrollView?.magnification ?? 1)
            origin.y -= event.deltaY / (enclosingScrollView?.magnification ?? 1)
            clip.scroll(to: origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    /// A picture larger than the view starts fitted, at the first layout that has a size: before it the bounds are zero,
    /// and fitting then gives the smallest zoom.
    final class FittingScrollView: NSScrollView {
        private var hasFitted = false

        override func layout() {
            super.layout()
            guard !hasFitted, bounds.width > 0, bounds.height > 0, let document = documentView else { return }
            hasFitted = true
            if document.frame.width > bounds.width || document.frame.height > bounds.height { magnify(toFit: document.bounds) }
        }
    }

    /// Keeps a picture smaller than the view in its middle, not at its bottom left.
    final class CenteringClipView: NSClipView {
        override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
            var rect = super.constrainBoundsRect(proposed)
            guard let document = documentView else { return rect }
            if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
            if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
            return rect
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FittingScrollView()
        scroll.contentView = CenteringClipView()
        let picture = DragView(image: image)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.frame = CGRect(origin: .zero, size: image.size)
        scroll.documentView = picture
        // The fill the picture was drawn on.
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Palette.raised)
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = NSColor(Palette.raised)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 6
        command.view = scroll
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}
