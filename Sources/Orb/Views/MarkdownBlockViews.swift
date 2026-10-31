import SwiftUI
import AppKit
import os

/// Space between the blocks of a reply (a blank line used to cost about 22 pt).
let markdownBlockSpacing: CGFloat = 12

/// One piece of a reply (a paragraph between blank lines while it streams, the whole text once it is done) drawn as
/// its blocks. Equatable on its source: a piece that did not change is neither parsed nor measured again.
/// `streaming` is the piece being written: it ends with the cursor. `cached`: whether its parsed blocks are kept in
/// `MarkdownCache` (the finished text is; the pieces of a reply being written, which become that text, are not).
struct MarkdownChunk: View, Equatable {
    let source: String
    var streaming = false
    var cached = true
    /// What a search in the conversation found in this reply: marked wherever it appears (nil: nothing).
    var highlight: String?
    /// Whether it starts its reply. A piece after another one gives a heading it starts with the space the whole text
    /// gives it there (`ProseText.headingLead`), so nothing moves when the pieces become one text; and the cursor shows
    /// on its own only at the start of a reply, never on a line of its own between two paragraphs.
    var first = true

    var body: some View {
        let blocks = MarkdownCache.blocks(source, cached: cached)
        if blocks.isEmpty {
            if streaming, first { Text("●").foregroundStyle(Palette.muted) }
        } else {
            // Paragraphs, headings, lists and quotes in a row are one text, so a drag selects across them; code, tables
            // and rules are drawn by themselves between those runs.
            let segments = ProseSegment.of(blocks)
            VStack(alignment: .leading, spacing: markdownBlockSpacing) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    let cursor = streaming && index == segments.count - 1
                    switch segment {
                    case .prose(let run):
                        SelectableProse(blocks: run, cursor: cursor, cached: cached, highlight: highlight)
                    case .block(let block):
                        MarkdownBlockView(block: block, cursor: cursor, highlight: highlight).equatable()
                    }
                }
            }
            .padding(.top, first ? 0 : Self.lead(blocks))
        }
    }

    private static func lead(_ blocks: [MarkdownBlock]) -> CGFloat {
        if case .heading(let level, _) = blocks.first { ProseText.headingLead(level) } else { 0 }
    }
}

struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    /// The reply is still being written and this is its last block.
    var cursor = false
    var highlight: String?

    var body: some View {
        switch block {
        case .code(let language, let code, _):
            CodeBlockView(language: language, code: code, streaming: cursor, highlight: highlight)
        case .table(let table):
            TableBlockView(table: table, streaming: cursor, highlight: highlight)
        case .rule:
            Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 4)
        case .image(let alt, let path):
            ReplyImageView(alt: alt, path: path)
        default:
            // Prose blocks go to `SelectableProse`, never here.
            EmptyView()
        }
    }

    /// On the app's type scale: 17 and 15 over the 14 pt body; from the third level on, the body's size in semibold (a
    /// size between 14 and 15 only blurred the steps).
    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 20
        case 2: 17
        default: 15
        }
    }
}

/// A picture the Orb put in its reply (`MarkdownBlock.image`): whole, in its own proportions, at most `maxSize`, with
/// what it shows under it and the actions of any attachment (Quick Look, Mostrar no Finder, Copiar). A file that is gone
/// shows the placeholder of a missing attachment.
struct ReplyImageView: View, Equatable {
    let alt: String
    let path: String
    @State private var size: CGSize

    nonisolated static let maxSize = CGSize(width: 420, height: 300)
    /// While the size is not known yet, and for a file that cannot be read.
    nonisolated static let placeholder = CGSize(width: 240, height: 150)

    init(alt: String, path: String) {
        self.alt = alt
        self.path = path
        _size = State(initialValue: ReplyImageSizes.cached(path) ?? Self.placeholder)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.alt == rhs.alt && lhs.path == rhs.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Decoded once at the largest size, so the copy does not change when the size arrives.
            ImageTile(path: path, size: size, all: [path], label: alt.isEmpty ? "Imagem" : alt,
                      decodeSide: max(Self.maxSize.width, Self.maxSize.height))
            if !alt.isEmpty {
                Text(alt)
                    .font(Typography.small)
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: size.width, alignment: .leading)
                    .accessibilityHidden(true)
            }
        }
        .task(id: path) { size = await ReplyImageSizes.size(of: path) }
    }
}

/// The size a picture of a reply is drawn at, read from the file (its header only) off the main thread and kept, so
/// a reply that scrolls back into view does not jump from the placeholder.
enum ReplyImageSizes {
    private static let known = OSAllocatedUnfairLock(initialState: [String: CGSize]())

    static func cached(_ path: String) -> CGSize? { known.withLock { $0[path] } }

    static func size(of path: String) async -> CGSize {
        if let size = cached(path) { return size }
        let pixels = await Task.detached { ScreenshotImage.pixelSize(of: URL(fileURLWithPath: path)) }.value
        guard let pixels, pixels.width > 0, pixels.height > 0 else { return ReplyImageView.placeholder }
        let size = fitted(width: CGFloat(pixels.width), height: CGFloat(pixels.height))
        known.withLock { $0[path] = size }
        return size
    }

    /// Pixels as points of a Retina screen (half), shrunk to fit `ReplyImageView.maxSize`, never under 40 pt a side.
    nonisolated static func fitted(width: CGFloat, height: CGFloat) -> CGSize {
        let natural = CGSize(width: width / 2, height: height / 2)
        let bound = ReplyImageView.maxSize
        let scale = min(1, bound.width / natural.width, bound.height / natural.height)
        return CGSize(width: max(40, (natural.width * scale).rounded()), height: max(40, (natural.height * scale).rounded()))
    }
}

/// The inline Markdown of `source` as the text a row draws, with what a search found marked.
@MainActor func markdownText(_ source: String, cached: Bool, highlight: String?) -> AttributedString {
    FindMarking.marked(MarkdownCache.attributed(source, cached: cached), query: highlight)
}

/// Marks the matches of a search in the text a row draws. Only the row of the chosen result is ever marked, so the cost is
/// one search in one message.
enum FindMarking {
    static func marked(_ text: AttributedString, query: String?) -> AttributedString {
        guard let query, let pattern = SearchPattern(query) else { return text }
        var searcher = TextSearcher(pattern)
        let ranges = searcher.matches(in: text.unicodeScalars)
        guard !ranges.isEmpty else { return text }
        var marked = text
        for range in ranges { marked[range].backgroundColor = Palette.findMatch }
        return marked
    }

    static func marked(_ text: String, query: String?) -> AttributedString {
        marked(AttributedString(text), query: query)
    }
}

/// Code on `Palette.raised`, monospaced, with its language and a button that copies it. No hairline: on the canvas the fill
/// alone sets it apart, and it is the reply's only frame.
struct CodeBlockView: View, Equatable {
    let language: String?
    let code: String
    /// The code is still being written (this is the last block of a reply that streams).
    var streaming = false
    var highlight: String?

    /// The cut of this block while it streams, kept between flushes so only what grew past the closed pieces is
    /// re-split — cutting the whole code at each flush made a flush cost grow with the code's length.
    @State private var streamCut = StreamCut()

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.language == rhs.language && lhs.code == rhs.code && lhs.streaming == rhs.streaming && lhs.highlight == rhs.highlight
    }

    /// Lines per piece of a long code block while it streams.
    nonisolated static let pieceLines = 40

    /// The pieces of the code block that is being written, kept between flushes. `covered` is the text the closed
    /// pieces already account for (it always ends with "\n"): while the code still starts with it, only what came
    /// after is re-split and the closed pieces stay the same `String`s, so the Equatable views they feed compare
    /// in constant time. A code that does not start with it (a retry, another block in this place) is recut whole.
    @MainActor final class StreamCut {
        private(set) var closed: [String] = []
        private var covered = ""

        /// The same cut `pieces(of:)` makes, splitting only what grew past `covered`.
        func pieces(of code: String) -> (closed: [String], tail: String)? {
            guard let rest = uncovered(of: code) else {
                covered = ""
                closed = []
                guard let fresh = CodeBlockView.pieces(of: code) else { return nil }
                closed = fresh.closed
                covered = fresh.closed.joined(separator: "\n") + "\n"
                return fresh
            }
            let pieceLines = CodeBlockView.pieceLines
            let lines: [Substring] = rest.isEmpty ? [""] : rest.split(separator: "\n", omittingEmptySubsequences: false)
            let newPieces = (lines.count - 1) / pieceLines
            for index in 0..<newPieces {
                let piece = lines[index * pieceLines..<(index + 1) * pieceLines].joined(separator: "\n")
                closed.append(piece)
                covered += piece + "\n"
            }
            guard !closed.isEmpty else { return nil }
            return (closed, lines[(newPieces * pieceLines)...].joined(separator: "\n"))
        }

        /// `code` past `covered`, or nil when `code` does not start with it. Compared and cut on the UTF-8 buffer:
        /// `hasPrefix`/`dropFirst` would walk the whole code at every flush.
        private func uncovered(of code: String) -> String? {
            let rest = covered.utf8.withContiguousStorageIfAvailable { old -> String? in
                code.utf8.withContiguousStorageIfAvailable { bytes -> String? in
                    guard bytes.count >= old.count,
                          old.isEmpty || memcmp(bytes.baseAddress!, old.baseAddress!, old.count) == 0
                    else { return nil }
                    return String(decoding: bytes[old.count...], as: UTF8.self)
                } ?? nil
            }
            return rest ?? nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language ?? "código")
                    .font(Typography.small)
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 8)
                CopyTextButton(text: code, help: Tip.copyCode, label: "Copiar código", copiedLabel: "Código copiado")
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 2)
            codeText
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.raised, in: .rect(cornerRadius: Radius.small))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.map { "Código em \($0)" } ?? "Código")
    }

    /// One `Text` for the whole code, which keeps selection and "Copiar" whole. While a long block streams it is drawn in
    /// pieces of `pieceLines` complete lines instead: the closed ones do not change (they keep what was drawn of them)
    /// and only the last, the one being written, is laid out and drawn again at each flush, so the cost of a flush no
    /// longer grows with the length of the code.
    @ViewBuilder private var codeText: some View {
        if streaming, let pieces = streamCut.pieces(of: code) {
            // The stack's spacing is the line spacing, so the seams between pieces are the same as between lines.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(pieces.closed.enumerated()), id: \.offset) { _, piece in
                    CodeLines(text: piece).equatable()
                }
                CodeLines(text: pieces.tail)
            }
        } else {
            CodeLines(text: code, highlight: highlight)
        }
    }

    /// The code cut into closed pieces of `pieceLines` lines and what is left (never empty), or nil when it is short.
    nonisolated static func pieces(of code: String) -> (closed: [String], tail: String)? {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > pieceLines else { return nil }
        let closedCount = (lines.count - 1) / pieceLines
        let closed = (0..<closedCount).map { index in
            lines[index * pieceLines..<(index + 1) * pieceLines].joined(separator: "\n")
        }
        return (closed, lines[(closedCount * pieceLines)...].joined(separator: "\n"))
    }

}

/// "Copiar" with its symbol, and "Copiado" with a check for a moment after a click: the button of a block of code in a
/// reply and of a command (`CommandBlock`).
struct CopyTextButton: View {
    let text: String
    let help: String
    /// What VoiceOver says, before and after the click.
    let label: String
    let copiedLabel: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash = CopiedFlash()

    var body: some View {
        Button {
            Clipboard.copy(text)
            flash.trigger()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: flash.isOn ? "checkmark" : "doc.on.doc")
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                // No width is reserved for "Copiado": at rest the button sits on the block's margin. It is anchored to the
                // right by the spacer before it, so only the symbol slides a few points, inside the same animation.
                Text(flash.isOn ? "Copiado" : "Copiar")
                    .contentTransition(.opacity)
            }
            .font(Typography.small.weight(.medium))
            .foregroundStyle(flash.isOn ? Palette.ink : Palette.muted)
            // On the view that changes, not `withAnimation`: a reply sets "never animate" on everything it draws.
            .animation(flash.isOn ? Motion.press : Motion.content, value: flash.isOn)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(flash.isOn ? copiedLabel : label)
    }
}

/// Lines of code in the block's style. Equatable, so a piece that did not change is not laid out again.
private struct CodeLines: View, Equatable {
    let text: String
    var highlight: String?

    var body: some View {
        line
            .font(Typography.code)
            .foregroundStyle(Palette.ink.opacity(0.9))
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var line: some View {
        if highlight != nil {
            Text(FindMarking.marked(text, query: highlight))
        } else {
            Text(text.isEmpty ? " " : text)
        }
    }
}

/// A Markdown table: the header in semibold, a hairline under it, the columns aligned as the table says.
struct TableBlockView: View, Equatable {
    let table: MarkdownTable
    /// The table is still being written (it is the last block of a reply that streams).
    var streaming = false
    var highlight: String?

    /// The measured floors of this table, kept between flushes so only the rows that grew are measured — measuring
    /// every cell at each flush made a flush cost grow with the table's length.
    @State private var floorMeasure = FloorMeasure()

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.table == rhs.table && lhs.streaming == rhs.streaming && lhs.highlight == rhs.highlight
    }

    /// Rows per piece of a long table while it streams.
    nonisolated static let pieceRows = 20

    /// Space between columns and around the table.
    private static let columnSpacing: CGFloat = 18
    private static let inset: CGFloat = 10

    /// The widest word seen per column (what `columnFloors` returns), measured once per row. `header` and `rows`
    /// are what was measured: while they still lead the table's, only the new rows are folded into the floors; when
    /// they do not (a retry, another table in this place) the table is measured whole.
    @MainActor final class FloorMeasure {
        private var header: [String] = []
        private var rows: [[String]] = []
        private(set) var floors: [CGFloat] = []

        /// The floors `columnFloors` computes, measuring only what grew since the last call.
        func floors(of table: MarkdownTable) -> [CGFloat] {
            let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
            guard table.header == header, table.rows.starts(with: rows), floors.count == columns else {
                header = table.header
                rows = table.rows
                floors = TableBlockView.columnFloors(of: table)
                return floors
            }
            let regular = NSFont.systemFont(ofSize: 13)
            for row in table.rows.dropFirst(rows.count) {
                for (column, cell) in row.enumerated() where column < floors.count && floors[column] < TableBlockView.maxFloor {
                    // A word narrower than the floor cannot lift it, so the measure starts from it.
                    let word = TableBlockView.widestWord([cell], font: regular, seed: floors[column] - 2)
                    floors[column] = min(ceil(word) + 2, TableBlockView.maxFloor)
                }
            }
            rows = table.rows
            return floors
        }
    }

    var body: some View {
        // Each column is at least as wide as its longest word, so a narrow chat (inspector open, small window) never
        // breaks words letter by letter; when even that does not fit, the table scrolls sideways.
        let floors = floorMeasure.floors(of: table)
        let needed = floors.reduce(0, +) + Self.columnSpacing * CGFloat(max(floors.count - 1, 0)) + Self.inset * 2
        ViewThatFits(in: .horizontal) {
            grid(floors).frame(minWidth: needed, idealWidth: needed, maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal) {
                grid(floors).frame(width: needed)
            }
        }
    }

    private func grid(_ floors: [CGFloat]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: Self.columnSpacing, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                    TableCell(source: cell, alignment: table.alignments.alignment(at: column), minWidth: floors.floor(at: column), cached: true, highlight: highlight).fontWeight(.semibold)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal).overlay(Palette.line)
            rows(floors)
        }
        .font(Typography.text)
        .padding(Self.inset)
        // The whole `raised`, without a hairline, as the code: on the canvas a lighter fill was too close to tell apart.
        .background(Palette.raised, in: .rect(cornerRadius: Radius.small))
    }

    /// The narrowest each column may get: its widest word (header in semibold), up to `maxFloor` so a long link or
    /// path still wraps.
    nonisolated static func columnFloors(of table: MarkdownTable) -> [CGFloat] {
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        let regular = NSFont.systemFont(ofSize: 13)
        let semibold = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return (0..<columns).map { column in
            let header = widestWord(table.header.indices.contains(column) ? [table.header[column]] : [], font: semibold)
            let body = widestWord(table.rows.compactMap { $0.indices.contains(column) ? $0[column] : nil }, font: regular)
            return min(ceil(max(header, body)) + 2, maxFloor)
        }
    }

    /// The width of the widest word of some cells, without the `**` and backticks around it, never under `seed`.
    /// Measured, not counted: "Documentos" is wider than "Instaladores", and a column set by letters broke it letter by
    /// letter. A word is measured only if it could be wider than the widest so far (no character is wider than 1.2 times
    /// the type's size; an emoji counts as two UTF-16 units) and was not measured yet, which skips most of a long table
    /// while it streams.
    private nonisolated static func widestWord(_ cells: [String], font: NSFont, seed: CGFloat = 0) -> CGFloat {
        let widestCharacter = font.pointSize * 1.2
        var widest = seed
        var measured = Set<Substring>()
        for cell in cells {
            for marked in cell.split(whereSeparator: \.isWhitespace) {
                var word = marked.drop { $0 == "*" || $0 == "`" }
                while word.last == "*" || word.last == "`" { word = word.dropLast() }
                guard CGFloat(word.utf16.count) * widestCharacter > widest, measured.insert(word).inserted else { continue }
                widest = max(widest, (String(word) as NSString).size(withAttributes: [.font: font]).width)
                if widest >= maxFloor { return widest }
            }
        }
        return widest
    }

    nonisolated static let maxFloor: CGFloat = 160

    /// The rows in one `Grid`, so the columns stay aligned. While a long table streams the closed pieces of `pieceRows`
    /// rows are Equatable views that keep what was evaluated of them (no `.equatable()` on them: it would make each piece
    /// a cell of the grid instead of its rows), and only the last piece is evaluated again at each
    /// flush; the cells of the row being written are not kept in `MarkdownCache` (each half-written state would be).
    @ViewBuilder private func rows(_ floors: [CGFloat]) -> some View {
        if streaming, let pieces = Self.pieces(of: table.rows) {
            ForEach(Array(pieces.closed.enumerated()), id: \.offset) { _, piece in
                TableRows(rows: piece, alignments: table.alignments, floors: floors, writing: false)
            }
            TableRows(rows: pieces.tail, alignments: table.alignments, floors: floors, writing: true)
        } else {
            TableRows(rows: table.rows, alignments: table.alignments, floors: floors, writing: streaming, highlight: highlight)
        }
    }

    /// The rows cut into closed pieces of `pieceRows` and what is left (never empty), or nil when the table is short.
    nonisolated static func pieces(of rows: [[String]]) -> (closed: [[[String]]], tail: [[String]])? {
        guard rows.count > pieceRows else { return nil }
        let closedCount = (rows.count - 1) / pieceRows
        let closed = (0..<closedCount).map { Array(rows[$0 * pieceRows..<($0 + 1) * pieceRows]) }
        return (closed, Array(rows[(closedCount * pieceRows)...]))
    }
}

/// Rows of a table, as the `GridRow`s of the `Grid` they are in. `writing`: the last of them is the row being written.
private struct TableRows: View, Equatable {
    let rows: [[String]]
    let alignments: [MarkdownTable.Alignment]
    let floors: [CGFloat]
    let writing: Bool
    var highlight: String?

    var body: some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            GridRow {
                ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                    TableCell(source: cell, alignment: alignments.alignment(at: column), minWidth: floors.floor(at: column), cached: !(writing && index == rows.count - 1), highlight: highlight)
                }
            }
        }
    }
}

private struct TableCell: View {
    let source: String
    let alignment: Alignment
    let minWidth: CGFloat
    let cached: Bool
    var highlight: String?

    var body: some View {
        Text(markdownText(source, cached: cached, highlight: highlight))
            .frame(minWidth: minWidth, maxWidth: .infinity, alignment: alignment)
    }
}

private extension [CGFloat] {
    func floor(at column: Int) -> CGFloat { indices.contains(column) ? self[column] : 0 }
}

private extension [MarkdownTable.Alignment] {
    func alignment(at column: Int) -> Alignment {
        switch indices.contains(column) ? self[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
