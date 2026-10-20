import AppKit
import SwiftUI

// The prose of a reply (paragraphs, headings, lists, quotes that follow each other) as one AppKit text, so a drag selects
// across all of it: SwiftUI selects inside one `Text` at a time, and a reply is a `Text` per paragraph and per list item.
// Code blocks, tables and rules stay views of their own between the runs of prose (`ProseSegments`).

/// A reply's blocks as runs of prose and the blocks that are drawn by themselves.
enum ProseSegment: Equatable {
    case prose([MarkdownBlock])
    case block(MarkdownBlock)

    static func of(_ blocks: [MarkdownBlock]) -> [ProseSegment] {
        var segments: [ProseSegment] = []
        var run: [MarkdownBlock] = []
        for block in blocks {
            if isProse(block) {
                run.append(block)
            } else {
                if !run.isEmpty { segments.append(.prose(run)) }
                run = []
                segments.append(.block(block))
            }
        }
        if !run.isEmpty { segments.append(.prose(run)) }
        return segments
    }

    static func isProse(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .paragraph, .heading, .list, .quote: true
        case .code, .table, .rule, .image: false
        }
    }
}

/// The text of a run of prose blocks with the look of the chat (`Palette.conversationFont`, its line spacing, the block
/// spacing of `MarkdownChunk`, list markers on tab stops, quotes indented with their bar), and the plain text a copy gives.
@MainActor
enum ProseText {
    static let size: CGFloat = 14
    /// Between the items of a list.
    static let itemSpacing: CGFloat = 4
    /// Where a list's text starts past its marker (the marker column, 18, and the gap, 8), and the indent of each level.
    static let markerWidth: CGFloat = 18
    static let markerGap: CGFloat = 8
    static let levelIndent: CGFloat = 18
    static let quoteIndent: CGFloat = 12

    /// Marks a quote, for its bar (`ProseTextView`).
    static let quoteKey = NSAttributedString.Key("OrbQuote")
    /// What a range stands for in a copy (a list marker with its tabs, a checkbox picture).
    static let plainKey = NSAttributedString.Key("OrbPlain")
    /// Ends the text being written.
    static let cursor = " ●"

    static func make(_ blocks: [MarkdownBlock], cursor: Bool, cached: Bool, highlight: String?) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let isLast = index == blocks.count - 1
            // Only the block being written is parsed fresh; the ones before it are final, so a flush reuses them.
            let cached = cached || !isLast
            if index > 0 { text.append(NSAttributedString(string: "\n")) }
            let start = text.length
            switch block {
            case .paragraph(let source):
                text.append(inline(source, cached: cached, highlight: highlight, style: paragraphStyle()))
            case .heading(let level, let source):
                let style = paragraphStyle()
                style.paragraphSpacingBefore = level <= 2 ? 4 : 2
                text.append(inline(source, cached: cached, highlight: highlight, style: style,
                                   size: MarkdownBlockView.headingSize(level), weight: .semibold))
            case .quote(let source):
                let style = paragraphStyle()
                style.headIndent = quoteIndent
                style.firstLineHeadIndent = quoteIndent
                let quote = NSMutableAttributedString(attributedString: inline(source, cached: cached, highlight: highlight,
                                                                              style: style, color: NSColor(Palette.secondary)))
                quote.addAttribute(quoteKey, value: true, range: NSRange(location: 0, length: quote.length))
                text.append(quote)
            case .list(let items):
                for (number, item) in items.enumerated() {
                    if number > 0 { text.append(NSAttributedString(string: "\n")) }
                    text.append(listItem(item, cached: cached || number < items.count - 1, highlight: highlight, spacing: number == items.count - 1 ? 0 : itemSpacing))
                }
            case .code, .table, .rule, .image:
                continue // never in a run (`ProseSegment`)
            }
            // The space after each block, as the stack of blocks had it; none after the last.
            let range = NSRange(location: start, length: text.length - start)
            text.enumerateAttribute(.paragraphStyle, in: range) { value, part, _ in
                guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                let isLastParagraph = NSMaxRange(part) == NSMaxRange(range)
                if isLastParagraph { style.paragraphSpacing = isLast ? 0 : markdownBlockSpacing }
                text.addAttribute(.paragraphStyle, value: style, range: part)
            }
        }
        if cursor {
            text.append(NSAttributedString(string: Self.cursor, attributes: [.font: NSFont.systemFont(ofSize: size),
                                                                          .foregroundColor: NSColor(Palette.muted)]))
        }
        return text
    }

    /// Words said along the work: a point smaller and as dim as `Palette.secondary` (the marks and links with them), since
    /// the text is AppKit's and does not take SwiftUI's font or color.
    static func quieter(_ text: NSAttributedString) -> NSAttributedString {
        let quiet = NSMutableAttributedString(attributedString: text)
        let all = NSRange(location: 0, length: quiet.length)
        quiet.enumerateAttribute(.font, in: all, options: .longestEffectiveRangeNotRequired) { value, range, _ in
            guard let font = value as? NSFont else { return }
            quiet.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: font.pointSize - 1), range: range)
        }
        quiet.enumerateAttribute(.foregroundColor, in: all, options: .longestEffectiveRangeNotRequired) { value, range, _ in
            guard let color = value as? NSColor else { return }
            quiet.addAttribute(.foregroundColor, value: color.withAlphaComponent(color.alphaComponent * quietAlpha), range: range)
        }
        return quiet
    }

    /// `Palette.secondary` over `Palette.ink`.
    static let quietAlpha: CGFloat = 0.74

    /// The space between the lines of a paragraph is the layout manager's (`ProseTextView`): a paragraph style's would also
    /// come after its last line, which SwiftUI's `lineSpacing` does not.
    private static func paragraphStyle() -> NSMutableParagraphStyle {
        NSMutableParagraphStyle()
    }

    private static func listItem(_ item: MarkdownListItem, cached: Bool, highlight: String?, spacing: CGFloat) -> NSAttributedString {
        let indent = CGFloat(item.depth) * levelIndent
        let style = paragraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: indent + markerWidth),
                          NSTextTab(textAlignment: .left, location: indent + markerWidth + markerGap)]
        style.headIndent = indent + markerWidth + markerGap
        style.paragraphSpacing = spacing
        let muted = NSColor(Palette.muted)
        let line = NSMutableAttributedString()
        let plain: String
        let markerAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: muted]
        switch item.marker {
        case .bullet:
            let bullet = item.depth == 0 ? "•" : "◦"
            line.append(NSAttributedString(string: "\t\(bullet)\t", attributes: markerAttributes))
            plain = bullet + " "
        case .number(let number):
            line.append(NSAttributedString(string: "\t\(number).\t", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular), .foregroundColor: muted]))
            plain = "\(number). "
        case .task(let done):
            line.append(NSAttributedString(string: "\t", attributes: markerAttributes))
            line.append(checkbox(done))
            line.append(NSAttributedString(string: "\t", attributes: markerAttributes))
            plain = done ? "☑ " : "☐ "
        }
        line.addAttribute(plainKey, value: String(repeating: "  ", count: item.depth) + plain,
                          range: NSRange(location: 0, length: line.length))
        line.append(inline(item.text, cached: cached, highlight: highlight, style: style))
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        return line
    }

    private static func checkbox(_ done: Bool) -> NSAttributedString {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(done ? Palette.accentText : Palette.muted)]))
        guard let image = NSImage(systemSymbolName: done ? "checkmark.square.fill" : "square", accessibilityDescription: done ? "feito" : "a fazer")?
            .withSymbolConfiguration(configuration) else { return NSAttributedString(string: done ? "☑" : "☐") }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    /// The inline Markdown of `source` (bold, italics, code, links, the marks of a search) in AppKit's attributes. Its line
    /// breaks stay breaks inside the paragraph, so the paragraph's spacing comes only after it.
    private static func inline(_ source: String, cached: Bool, highlight: String?, style: NSParagraphStyle,
                               size: CGFloat = size, weight: NSFont.Weight = .regular,
                               color: NSColor = NSColor(Palette.ink)) -> NSAttributedString {
        let parsed = markdownText(source, cached: cached, highlight: highlight)
        let output = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters).replacingOccurrences(of: "\n", with: "\u{2028}")
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .bold : weight)
                : NSFont.systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .bold : weight)
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            if let background = run[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] {
                attributes[.backgroundColor] = NSColor(background)
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            output.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return output
    }

    /// What a copy of `ranges` of `text` gives: list markers as "• " (indented by level), checkboxes as ☐/☑, the breaks
    /// inside a paragraph as line breaks.
    static func plain(_ text: NSAttributedString, ranges: [NSRange]) -> String {
        ranges.compactMap { range -> String? in
            guard range.length > 0, NSMaxRange(range) <= text.length else { return nil }
            var out = ""
            var lastMarker: NSRange?
            text.enumerateAttribute(plainKey, in: range) { value, part, _ in
                if let plain = value as? String {
                    // One marker spans its tabs and picture: written once, whatever part of it is selected.
                    var whole = NSRange()
                    _ = text.attribute(plainKey, at: part.location, effectiveRange: &whole)
                    if lastMarker != whole { out += plain }
                    lastMarker = whole
                } else {
                    out += (text.string as NSString).substring(with: part)
                }
            }
            return out.replacingOccurrences(of: "\u{2028}", with: "\n")
        }
        .joined(separator: "\n")
    }
}

/// The text view of a run of prose: read-only, selectable, transparent, laid out at the width SwiftUI gives it.
final class ProseTextView: NSTextView, @preconcurrency NSLayoutManagerDelegate {
    private var sizes: [CGFloat: CGSize] = [:]
    /// Widths in `sizes`, least recently used first.
    private var sizeOrder: [CGFloat] = []
    /// Tells whether the width is changing fast (an animation, a drag): then the text is laid out in steps (`ProseWidth`).
    private var widthMotion = ProseWidth.Motion()
    private var settleWork: DispatchWorkItem?
    /// The text has a quote to draw a bar beside (`drawBackground`).
    private var hasQuote = false
    /// The text shown, without the cursor: what a flush that only adds to it continues.
    private var shownBody: String?
    private lazy var fade = TextFade(view: self)
    /// Told what is selected (its text as a copy gives it, nil when nothing is), and what "Citar" quotes; set where a
    /// reply can be quoted (`EnvironmentValues.proseSelection`).
    var selection: ProseSelectionAction?

    convenience init() {
        self.init(usingTextLayoutManager: false)
        layoutManager?.delegate = self
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        backgroundColor = .clear
        allowsUndo = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        // The container is sized by `size(forWidth:)` (stepped while the width moves), not by the frame.
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        focusRingType = .none
        linkTextAttributes = [.foregroundColor: NSColor(Palette.accentText), .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .cursor: NSCursor.pointingHand]
        setAccessibilityRole(.staticText)
    }

    /// `fades`: the text is the one being written, and what it adds to the text shown fades in (`TextFade`).
    func show(_ text: NSAttributedString, cursor: Bool, fades: Bool) {
        let body = (text.string as NSString).substring(to: text.length - (cursor ? (ProseText.cursor as NSString).length : 0))
        let added = fades ? TextFade.added(body, after: shownBody) : nil
        // Words still fading keep fading while the text only grows (or loses its cursor); anything else shows at once.
        if shownBody.map({ !(body as NSString).hasPrefix($0) }) ?? true { fade.finish() }
        shownBody = body
        textStorage?.setAttributedString(text)
        if let added { fade.fade(added) } else { fade.restore() }
        hasQuote = false
        text.enumerateAttribute(ProseText.quoteKey, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil { hasQuote = true; stop.pointee = true }
        }
        sizes = [:]
        sizeOrder = []
        invalidateIntrinsicContentSize()
    }

    /// The text laid out `width` wide: its height, and the width of its longest line (never more than `width`). Laid out
    /// again at that narrower width the lines break in the same places, since each of them fits. While the width is
    /// changing fast the text is laid out at a step below it (never wider, so nothing sticks out; the height is that of
    /// the text drawn, so nothing is cut), and at the exact width once it has been still for `ProseWidth.settle`.
    func size(forWidth width: CGFloat, steps: Bool = false) -> CGSize {
        let now = ProcessInfo.processInfo.systemUptime
        // Text that hugs its lines (a bubble) is asked several widths at once: it is always laid out at the exact one.
        let moving = widthMotion.note(width, at: now) && steps
        let layoutWidth = ProseWidth.layoutWidth(width, moving: moving)
        if moving { scheduleSettle() }
        guard let container = textContainer, let layout = layoutManager else { return .zero }
        if container.containerSize.width != layoutWidth {
            container.containerSize = NSSize(width: layoutWidth, height: .greatestFiniteMagnitude)
        }
        if let known = sizes[layoutWidth] {
            if let i = sizeOrder.firstIndex(of: layoutWidth) { sizeOrder.remove(at: i); sizeOrder.append(layoutWidth) }
            return known
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        // The container's used rect can span its whole width; each line's own used rect is as wide as its words.
        var longest: CGFloat = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, line, _, _, _ in
            longest = max(longest, line.maxX)
        }
        let size = CGSize(width: min(ceil(longest), layoutWidth), height: ceil(used.height))
        if sizeOrder.count >= ProseWidth.cacheLimit, let oldest = sizeOrder.first {
            sizeOrder.removeFirst()
            sizes[oldest] = nil
        }
        sizes[layoutWidth] = size
        sizeOrder.append(layoutWidth)
        return size
    }

    /// The width stopped moving: ask SwiftUI for the size again, now at the exact width.
    private func scheduleSettle() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.widthMotion.reset()
            self.invalidateIntrinsicContentSize()
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ProseWidth.settle, execute: work)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard widthMotion.isMoving else { return }
        settleWork?.cancel()
        widthMotion.reset()
        invalidateIntrinsicContentSize()
    }

    /// `Palette.conversationLineSpacing` between the lines of a paragraph (breaks inside it included), none after its last.
    func layoutManager(_ layoutManager: NSLayoutManager, lineSpacingAfterGlyphAt glyphIndex: Int,
                       withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        guard let text = textStorage?.string as NSString? else { return 0 }
        let next = layoutManager.characterIndexForGlyph(at: glyphIndex) + 1
        guard next < text.length else { return 0 }
        return text.character(at: next) == 0x0A || text.character(at: next - 1) == 0x0A ? 0 : Palette.conversationLineSpacing
    }

    /// A fade runs only on screen: it starts once the view is in a window and ends, at once, when it leaves it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { fade.finish() } else { fade.run() }
    }

    /// Only the last view a selection was made in shows one: a click elsewhere lets it go.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: 0, length: 0)) }
        return resigned
    }

    /// The selection is told once it is made (not while the mouse drags it), after the view is done updating.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !stillSelecting, let selection else { return }
        let text = selectedText
        DispatchQueue.main.async { selection.changed(text.isEmpty ? nil : text) }
    }

    /// The selection as it reads (markers as "• ", breaks as breaks), not the tabs that place them.
    private var selectedText: String {
        guard let textStorage else { return "" }
        return ProseText.plain(textStorage, ranges: selectedRanges.map(\.rangeValue)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override func copy(_ sender: Any?) {
        let text = selectedText
        guard !text.isEmpty else { return }
        Clipboard.copy(text)
    }

    @objc private func quoteSelection(_ sender: Any?) {
        let text = selectedText
        guard !text.isEmpty else { return }
        selection?.quote(text)
    }

    /// With text selected, a right click offers to copy it (and to quote it, where a reply can be quoted); without, the
    /// reply's own menu ("Copiar", "Copiar como Markdown") comes up as before.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard selectedRange().length > 0 else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copiar", action: #selector(copy(_:)), keyEquivalent: "")
        if selection != nil { menu.addItem(withTitle: "Citar", action: #selector(quoteSelection(_:)), keyEquivalent: "") }
        return menu
    }

    override func rightMouseDown(with event: NSEvent) {
        if selectedRange().length > 0 { super.rightMouseDown(with: event) } else { nextResponder?.rightMouseDown(with: event) }
    }

    /// The bar beside a quote.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard hasQuote, let textStorage, let layoutManager, let textContainer else { return }
        NSColor(Palette.lineStrong).setFill()
        textStorage.enumerateAttribute(ProseText.quoteKey, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            let bar = NSRect(x: textContainerOrigin.x, y: bounds.minY + textContainerOrigin.y, width: 2, height: bounds.height)
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// A run of prose blocks as one selectable text (`ProseText`, `ProseTextView`).
struct SelectableProse: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    var cursor = false
    var cached = true
    var highlight: String?

    struct Shown: Equatable {
        let blocks: [MarkdownBlock]
        let cursor: Bool
        let highlight: String?
        let isQuiet: Bool
    }

    final class Coordinator {
        var shown: Shown?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ProseTextView {
        let view = ProseTextView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        update(view, context: context)
        return view
    }

    func updateNSView(_ view: ProseTextView, context: Context) {
        update(view, context: context)
    }

    /// The text is set again only when it changed: setting it would also drop a selection being made.
    private func update(_ view: ProseTextView, context: Context) {
        view.selection = context.environment.proseSelection
        let isQuiet = context.environment.proseIsQuiet
        let shown = Shown(blocks: blocks, cursor: cursor, highlight: highlight, isQuiet: isQuiet)
        guard context.coordinator.shown != shown else { return }
        context.coordinator.shown = shown
        let text = ProseText.make(blocks, cursor: cursor, cached: cached, highlight: highlight)
        view.show(isQuiet ? ProseText.quieter(text) : text, cursor: cursor,
                  fades: cursor && !context.environment.accessibilityReduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProseTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 10_000
        let size = nsView.size(forWidth: width, steps: !context.environment.proseHugsText)
        return CGSize(width: context.environment.proseHugsText ? size.width : width, height: size.height)
    }
}

/// What a reply's text views tell about their selection (`ProseTextView.selection`): what is selected, for the reply's
/// "Citar" button, and the quote itself. Equal whatever its closures: they only reach the reply's own state.
struct ProseSelectionAction: Equatable {
    let changed: @MainActor (String?) -> Void
    let quote: @MainActor (String) -> Void

    nonisolated static func == (lhs: ProseSelectionAction, rhs: ProseSelectionAction) -> Bool { true }
}

extension EnvironmentValues {
    /// Set by a finished reply: its selected words can be quoted.
    @Entry var proseSelection: ProseSelectionAction?
    /// The text takes the width of its longest line instead of all it is given (inside a bubble, `replyBubble()`).
    @Entry var proseHugsText = false
    /// Words the Orb said along its work, not an answer (`BotMessage.isNarration`): `ProseText.quieter`.
    @Entry var proseIsQuiet = false
}

/// How the width a prose text is laid out at follows the width it is given.
enum ProseWidth {
    /// Width steps while the width moves, in points.
    static let step: CGFloat = 16
    /// How long the width must stay still before the text is laid out at the exact width.
    static let settle: TimeInterval = 0.12
    /// Widths whose size is kept.
    static let cacheLimit = 16

    /// The width to lay out at: the exact one at rest, a step below it (never above) while it moves.
    static func layoutWidth(_ width: CGFloat, moving: Bool) -> CGFloat {
        guard moving, width > step else { return width }
        return (width / step).rounded(.down) * step
    }

    /// Notes the widths asked for. The width is moving after `frames` changes in a row, each less than `settle` after the
    /// one before and a frame apart (one layout pass asking several widths is not movement), until it stays the same
    /// for `settle`.
    struct Motion {
        static let frames = 3
        private var last: CGFloat?
        private var changedAt: TimeInterval = 0
        private var run = 0

        var isMoving: Bool { run >= Self.frames }

        /// True while the width is moving, `width` asked for at `now`.
        mutating func note(_ width: CGFloat, at now: TimeInterval) -> Bool {
            defer { last = width }
            guard let last else { return false }
            if width != last {
                if now - changedAt > settle { run = 0 }
                if now - changedAt > 0.004 { run += 1; changedAt = now }
            }
            return isMoving && now - changedAt < settle
        }

        mutating func reset() { run = 0; changedAt = 0 }
    }
}

/// How the width a prose text is laid out at follows the width it is given.
enum ProseWidth {
    /// Width steps while the width moves, in points.
    static let step: CGFloat = 16
    /// How long the width must stay still before the text is laid out at the exact width.
    static let settle: TimeInterval = 0.12
    /// Widths whose size is kept.
    static let cacheLimit = 16

    /// The width to lay out at: the exact one at rest, a step below it (never above) while it moves.
    static func layoutWidth(_ width: CGFloat, moving: Bool) -> CGFloat {
        guard moving, width > step else { return width }
        return (width / step).rounded(.down) * step
    }

    /// Notes the widths asked for. The width is moving after `frames` changes in a row, each less than `settle` after the
    /// one before and a frame apart (one layout pass asking several widths is not movement), until it stays the same
    /// for `settle`.
    struct Motion {
        static let frames = 3
        private var last: CGFloat?
        private var changedAt: TimeInterval = 0
        private var run = 0

        var isMoving: Bool { run >= Self.frames }

        /// True while the width is moving, `width` asked for at `now`.
        mutating func note(_ width: CGFloat, at now: TimeInterval) -> Bool {
            defer { last = width }
            guard let last else { return false }
            if width != last {
                if now - changedAt > settle { run = 0 }
                if now - changedAt > 0.004 { run += 1; changedAt = now }
            }
            return isMoving && now - changedAt < settle
        }

        mutating func reset() { run = 0; changedAt = 0 }
    }
}
