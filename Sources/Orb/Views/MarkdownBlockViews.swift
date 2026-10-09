import SwiftUI
import AppKit

/// Space between the blocks of a reply (a blank line used to cost about 22 pt).
let markdownBlockSpacing: CGFloat = 8

/// One piece of a reply (a paragraph between blank lines while it streams, the whole text once it is done) drawn as
/// its blocks. Equatable on its source: a piece that did not change is neither parsed nor measured again.
/// `streaming` is the piece being written: it ends with the cursor. `cached`: whether its parsed blocks are kept in
/// `MarkdownCache` (the finished text is; the pieces of a reply being written, which become that text, are not).
struct MarkdownChunk: View, Equatable {
    let source: String
    var streaming = false
    var cached = true

    var body: some View {
        let blocks = MarkdownCache.blocks(source, cached: cached)
        if blocks.isEmpty {
            if streaming { Text("●").foregroundColor(Palette.muted) }
        } else {
            VStack(alignment: .leading, spacing: markdownBlockSpacing) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    MarkdownBlockView(block: block, cursor: streaming && index == blocks.count - 1).equatable()
                }
            }
        }
    }
}

struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    /// The reply is still being written and this is its last block.
    var cursor = false

    var body: some View {
        switch block {
        case .paragraph(let source):
            inline(source)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: Self.headingSize(level), weight: .semibold))
                .padding(.top, level <= 2 ? 4 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    ListItemRow(item: item, cursor: cursor && index == items.count - 1).equatable()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .quote(let source):
            inline(source)
                .foregroundStyle(Palette.secondary)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(Palette.lineStrong).frame(width: 2)
                }
        case .code(let language, let code, _):
            CodeBlockView(language: language, code: code, streaming: cursor)
        case .table(let table):
            TableBlockView(table: table, streaming: cursor)
        case .rule:
            Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 4)
        }
    }

    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 17
        case 2: 15.5
        default: 14.5
        }
    }

    /// Text with the Markdown of its inline syntax applied (and the cursor after it while the reply is written).
    private func inline(_ source: String) -> some View {
        let text = Text(MarkdownCache.attributed(source, cached: !cursor))
        return cursor ? text + Text(" ●").foregroundColor(Palette.muted) : text
    }
}

/// Equatable, so while a long list streams only the item being written is evaluated again.
private struct ListItemRow: View, Equatable {
    let item: MarkdownListItem
    let cursor: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker
                .frame(width: 18, alignment: .trailing)
                .accessibilityHidden(true)
            let text = Text(MarkdownCache.attributed(item.text, cached: !cursor))
            (cursor ? text + Text(" ●").foregroundColor(Palette.muted) : text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(item.depth) * 18)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var marker: some View {
        switch item.marker {
        case .bullet:
            Text(item.depth == 0 ? "•" : "◦").foregroundStyle(Palette.muted)
        case .number(let number):
            Text("\(number).").monospacedDigit().foregroundStyle(Palette.muted)
        case .task(let done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundStyle(done ? Palette.accentText : Palette.muted)
        }
    }
}

/// Code on `Palette.raised`, monospaced, with its language and a button that copies it.
struct CodeBlockView: View, Equatable {
    let language: String?
    let code: String
    /// The code is still being written (this is the last block of a reply that streams).
    var streaming = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash = CopiedFlash()

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.language == rhs.language && lhs.code == rhs.code && lhs.streaming == rhs.streaming
    }

    /// Lines per piece of a long code block while it streams.
    nonisolated static let pieceLines = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language ?? "código")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 8)
                Button(action: copy) {
                    HStack(spacing: 5) {
                        Image(systemName: flash.isOn ? "checkmark" : "doc.on.doc")
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        // No width is reserved for "Copiado": at rest the button sits on the 10 pt margin like the language
                        // does. The button is anchored to the right by the spacer, so only the symbol slides a few points,
                        // inside the same animation.
                        Text(flash.isOn ? "Copiado" : "Copiar")
                            .contentTransition(.opacity)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(flash.isOn ? Palette.ink : Palette.muted)
                    // On the view that changes, not `withAnimation`: the reply sets "never animate" on everything it draws.
                    .animation(flash.isOn ? Motion.press : Motion.content, value: flash.isOn)
                }
                .buttonStyle(.plain)
                .help(Tip.copyCode)
                .accessibilityLabel(flash.isOn ? "Código copiado" : "Copiar código")
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
        .background(Palette.raised, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.map { "Código em \($0)" } ?? "Código")
    }

    /// One `Text` for the whole code, which keeps selection and "Copiar" whole. While a long block streams it is drawn in
    /// pieces of `pieceLines` complete lines instead: the closed ones do not change (they keep what was drawn of them)
    /// and only the last, the one being written, is laid out and drawn again at each flush, so the cost of a flush no
    /// longer grows with the length of the code.
    @ViewBuilder private var codeText: some View {
        if streaming, let pieces = Self.pieces(of: code) {
            // The stack's spacing is the line spacing, so the seams between pieces are the same as between lines.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(pieces.closed.enumerated()), id: \.offset) { _, piece in
                    CodeLines(text: piece).equatable()
                }
                CodeLines(text: pieces.tail)
            }
        } else {
            CodeLines(text: code)
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

    private func copy() {
        Clipboard.copy(code)
        flash.trigger()
    }
}

/// Lines of code in the block's style. Equatable, so a piece that did not change is not laid out again.
private struct CodeLines: View, Equatable {
    let text: String

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Palette.ink.opacity(0.9))
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A Markdown table: the header in semibold, a hairline under it, the columns aligned as the table says.
struct TableBlockView: View, Equatable {
    let table: MarkdownTable
    /// The table is still being written (it is the last block of a reply that streams).
    var streaming = false

    /// Rows per piece of a long table while it streams.
    nonisolated static let pieceRows = 20

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                    TableCell(source: cell, alignment: table.alignments.alignment(at: column), cached: true).fontWeight(.semibold)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal).overlay(Palette.line)
            rows
        }
        .font(.system(size: 13))
        .padding(10)
        .background(Palette.raised.opacity(0.7), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The rows in one `Grid`, so the columns stay aligned. While a long table streams the closed pieces of `pieceRows`
    /// rows are Equatable views that keep what was evaluated of them (no `.equatable()` on them: it would make each piece
    /// a cell of the grid instead of its rows), and only the last piece is evaluated again at each
    /// flush; the cells of the row being written are not kept in `MarkdownCache` (each half-written state would be).
    @ViewBuilder private var rows: some View {
        if streaming, let pieces = Self.pieces(of: table.rows) {
            ForEach(Array(pieces.closed.enumerated()), id: \.offset) { _, piece in
                TableRows(rows: piece, alignments: table.alignments, writing: false)
            }
            TableRows(rows: pieces.tail, alignments: table.alignments, writing: true)
        } else {
            TableRows(rows: table.rows, alignments: table.alignments, writing: streaming)
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
    let writing: Bool

    var body: some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            GridRow {
                ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                    TableCell(source: cell, alignment: alignments.alignment(at: column), cached: !(writing && index == rows.count - 1))
                }
            }
        }
    }
}

private struct TableCell: View {
    let source: String
    let alignment: Alignment
    let cached: Bool

    var body: some View {
        Text(MarkdownCache.attributed(source, cached: cached))
            .frame(maxWidth: .infinity, alignment: alignment)
    }
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
