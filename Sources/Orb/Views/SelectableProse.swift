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
        case .code, .table, .rule: false
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
            case .code, .table, .rule:
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
            text.append(NSAttributedString(string: " ●", attributes: [.font: NSFont.systemFont(ofSize: size),
                                                                     .foregroundColor: NSColor(Palette.muted)]))
        }
        return text
    }

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
    private var heights: [CGFloat: CGFloat] = [:]
    /// The text has a quote to draw a bar beside (`drawBackground`).
    private var hasQuote = false
    /// The last width SwiftUI proposed, for a proposal without one.
    var lastWidth: CGFloat?

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
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        focusRingType = .none
        linkTextAttributes = [.foregroundColor: NSColor(Palette.accentText), .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .cursor: NSCursor.pointingHand]
        setAccessibilityRole(.staticText)
    }

    func show(_ text: NSAttributedString) {
        textStorage?.setAttributedString(text)
        hasQuote = false
        text.enumerateAttribute(ProseText.quoteKey, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil { hasQuote = true; stop.pointee = true }
        }
        heights = [:]
        invalidateIntrinsicContentSize()
    }

    /// The height of the text laid out `width` wide.
    func height(forWidth width: CGFloat) -> CGFloat {
        if let known = heights[width] { return known }
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        // A few widths at most: a window being resized goes through many.
        if heights.count >= 4 { heights = [:] }
        heights[width] = height
        return height
    }

    /// `Palette.conversationLineSpacing` between the lines of a paragraph (breaks inside it included), none after its last.
    func layoutManager(_ layoutManager: NSLayoutManager, lineSpacingAfterGlyphAt glyphIndex: Int,
                       withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        guard let text = textStorage?.string as NSString? else { return 0 }
        let next = layoutManager.characterIndexForGlyph(at: glyphIndex) + 1
        guard next < text.length else { return 0 }
        return text.character(at: next) == 0x0A || text.character(at: next - 1) == 0x0A ? 0 : Palette.conversationLineSpacing
    }

    /// Only the last view a selection was made in shows one: a click elsewhere lets it go.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: 0, length: 0)) }
        return resigned
    }

    /// The copy is the text as it reads (markers as "• ", breaks as breaks), not the tabs that place them.
    override func copy(_ sender: Any?) {
        guard let textStorage else { return }
        let text = ProseText.plain(textStorage, ranges: selectedRanges.map(\.rangeValue))
        guard !text.isEmpty else { return }
        Clipboard.copy(text)
    }

    /// With text selected, a right click offers to copy it; without, the reply's own menu ("Copiar", "Copiar como
    /// Markdown") comes up as before.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard selectedRange().length > 0 else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copiar", action: #selector(copy(_:)), keyEquivalent: "")
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
        let shown = Shown(blocks: blocks, cursor: cursor, highlight: highlight)
        guard context.coordinator.shown != shown else { return }
        context.coordinator.shown = shown
        view.show(ProseText.make(blocks, cursor: cursor, cached: cached, highlight: highlight))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProseTextView, context: Context) -> CGSize? {
        let proposed = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        if let proposed { nsView.lastWidth = proposed }
        let width = proposed ?? nsView.lastWidth ?? 10_000
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}
