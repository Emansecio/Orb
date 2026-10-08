import SwiftUI
import AppKit

/// Space between the blocks of a reply (a blank line used to cost about 22 pt).
let markdownBlockSpacing: CGFloat = 8

/// Puts text on the general pasteboard.
@MainActor
enum Clipboard {
    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

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
                    ListItemRow(item: item, cursor: cursor && index == items.count - 1)
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
            CodeBlockView(language: language, code: code)
        case .table(let table):
            TableBlockView(table: table)
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

private struct ListItemRow: View {
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
    @State private var copied = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.language == rhs.language && lhs.code == rhs.code }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language ?? "código")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 8)
                Button(action: copy) {
                    Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(copied ? Palette.ink : Palette.muted)
                        .contentTransition(.identity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Código copiado" : "Copiar código")
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 2)
            Text(code.isEmpty ? " " : code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.ink.opacity(0.9))
                .lineSpacing(2)
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

    private func copy() {
        Clipboard.copy(code)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}

/// A Markdown table: the header in semibold, a hairline under it, the columns aligned as the table says.
struct TableBlockView: View, Equatable {
    let table: MarkdownTable

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                    cellText(cell, column: column).fontWeight(.semibold)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal).overlay(Palette.line)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        cellText(cell, column: column)
                    }
                }
            }
        }
        .font(.system(size: 13))
        .padding(10)
        .background(Palette.raised.opacity(0.7), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cellText(_ source: String, column: Int) -> some View {
        let alignment: Alignment = switch table.alignments.indices.contains(column) ? table.alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Text(MarkdownCache.attributed(source))
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}
