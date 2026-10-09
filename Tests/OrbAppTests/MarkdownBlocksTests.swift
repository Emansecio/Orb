import Foundation
import SwiftUI
import AppKit
import Testing
@testable import Orb

/// Replies are read into blocks (paragraphs, lists, code…) the same way while they stream and when they are done.
@Suite("Markdown em blocos") struct MarkdownBlocksTests {
    private func items(_ block: MarkdownBlock?) -> [MarkdownListItem] {
        if case .list(let items)? = block { items } else { [] }
    }

    @Test func plainTextIsOneParagraphWithItsLineBreaks() {
        #expect(MarkdownBlocks.parse("Uma linha.") == [.paragraph("Uma linha.")])
        #expect(MarkdownBlocks.parse("Primeira\nsegunda") == [.paragraph("Primeira\nsegunda")])
        #expect(MarkdownBlocks.parse("um\n\ndois") == [.paragraph("um"), .paragraph("dois")])
        #expect(MarkdownBlocks.parse("").isEmpty)
    }

    @Test func headingsHaveALevelAndLoseTheirHashes() {
        #expect(MarkdownBlocks.parse("# Título") == [.heading(level: 1, text: "Título")])
        #expect(MarkdownBlocks.parse("### Passo 3 ###") == [.heading(level: 3, text: "Passo 3")])
        #expect(MarkdownBlocks.parse("## C#") == [.heading(level: 2, text: "C#")])
        // Not a heading: no space after the hashes, or too many of them.
        #expect(MarkdownBlocks.parse("#hashtag") == [.paragraph("#hashtag")])
        #expect(MarkdownBlocks.parse("####### sete") == [.paragraph("####### sete")])
    }

    @Test func bulletedAndNumberedListsKeepTheirMarks() {
        let bullets = items(MarkdownBlocks.parse("- um\n- dois\n* três\n• quatro").first)
        #expect(bullets.map(\.text) == ["um", "dois", "três", "quatro"])
        #expect(bullets.allSatisfy { $0.marker == .bullet && $0.depth == 0 })

        let numbered = items(MarkdownBlocks.parse("1. primeiro\n2. segundo\n3) terceiro").first)
        #expect(numbered.map(\.marker) == [.number(1), .number(2), .number(3)])

        // A list in a piece of its own keeps the number the reply gave it.
        #expect(items(MarkdownBlocks.parse("4. quarto").first).first?.marker == .number(4))
    }

    @Test func nestedItemsAndContinuationLines() {
        let list = items(MarkdownBlocks.parse("- a\n  - b\n    - c\n- d\n  continua o d").first)
        #expect(list.map(\.depth) == [0, 1, 2, 0])
        #expect(list.last?.text == "d\ncontinua o d")
    }

    @Test func taskItemsKnowIfTheyAreDone() {
        let list = items(MarkdownBlocks.parse("- [ ] fazer\n- [x] feito").first)
        #expect(list.map(\.marker) == [.task(done: false), .task(done: true)])
        #expect(list.map(\.text) == ["fazer", "feito"])
    }

    @Test func aListEndsWhereAParagraphBeginsAndStartsInsideOne() {
        let blocks = MarkdownBlocks.parse("Segundo:\n- item um\n- item dois\nFim.")
        #expect(blocks.count == 3)
        #expect(blocks[0] == .paragraph("Segundo:"))
        #expect(items(blocks[1]).count == 2)
        #expect(blocks[2] == .paragraph("Fim."))
    }

    @Test func quotesJoinTheirLines() {
        #expect(MarkdownBlocks.parse("> um\n> dois\n>três") == [.quote("um\ndois\ntrês")])
    }

    @Test func rulesAreNotLists() {
        #expect(MarkdownBlocks.parse("---") == [.rule])
        #expect(MarkdownBlocks.parse("* * *") == [.rule])
        #expect(MarkdownBlocks.parse("___") == [.rule])
        #expect(items(MarkdownBlocks.parse("- item").first).count == 1)
    }

    @Test func codeKeepsItsLanguageItsBlankLinesAndWhetherItWasClosed() {
        let closed = MarkdownBlocks.parse("```swift\nlet a = 1\n\nlet b = 2\n```")
        #expect(closed == [.code(language: "swift", code: "let a = 1\n\nlet b = 2", isClosed: true)])

        let open = MarkdownBlocks.parse("```\nainda escrevendo")
        #expect(open == [.code(language: nil, code: "ainda escrevendo", isClosed: false)])

        // Markdown inside a fence is not read; a longer fence holds a shorter one.
        let nested = MarkdownBlocks.parse("````md\n```\n# não é título\n```\n````")
        #expect(nested == [.code(language: "md", code: "```\n# não é título\n```", isClosed: true)])

        // Inline code in a line is not a fence.
        #expect(MarkdownBlocks.parse("```inline``` no meio") == [.paragraph("```inline``` no meio")])
    }

    @Test func tablesHaveAHeaderRowsAndAlignments() {
        let blocks = MarkdownBlocks.parse("| Tipo | Qtd |\n| :-- | --: |\n| PDF | 12 |\n| Foto | 20 |")
        guard case .table(let table)? = blocks.first else { Issue.record("no table"); return }
        #expect(blocks.count == 1)
        #expect(table.header == ["Tipo", "Qtd"])
        #expect(table.rows == [["PDF", "12"], ["Foto", "20"]])
        #expect(table.alignments == [.leading, .trailing])

        // A line with a pipe and no separator under it is text.
        #expect(MarkdownBlocks.parse("a | b\nc | d") == [.paragraph("a | b\nc | d")])
        // Short rows are padded to the header's width.
        guard case .table(let padded)? = MarkdownBlocks.parse("a | b\n- | -\nx | ").first else { Issue.record("no table"); return }
        #expect(padded.rows == [["x", ""]])
    }

    @Test func aWholeReplyIsThePiecesItHadWhileStreaming() {
        let reply = """
            Olá **mundo**.

            ## Lista

            - um
            - dois

            ```sh
            echo a

            echo b
            ```

            Fim.
            """
        var streamed = ReplyParagraphs()
        var seen: [MarkdownBlock] = []
        for chunk in reply.map(String.init) { streamed.append(chunk) }
        for piece in streamed.closed { seen += MarkdownBlocks.parsePiece(piece) }
        seen += MarkdownBlocks.parsePiece(streamed.tail)
        #expect(seen == MarkdownBlocks.parse(reply))
        #expect(MarkdownBlocks.parse(reply).count == 5)
    }

    @Test func plainTextDropsTheMarksButKeepsTheStructure() {
        let reply = "Veja **isto** e `aquilo`.\n\n## Passos\n\n1. um\n2. dois\n\n- a\n  - b\n\n```sh\nls -la\n```\n\n| x | y |\n|---|---|\n| 1 | 2 |"
        #expect(MarkdownBlocks.plainText(of: reply) == "Veja isto e aquilo.\n\nPassos\n\n1. um\n2. dois\n\n• a\n  • b\n\nls -la\n\nx\ty\n1\t2")
    }

    @MainActor @Test func parsedBlocksAreKeptForFinishedTextAndBounded() {
        MarkdownCache.removeAll()
        let first = MarkdownCache.blocks("- a\n- b")
        #expect(first == MarkdownBlocks.parse("- a\n- b"))
        #expect(MarkdownCache.blockCount == 1)
        _ = MarkdownCache.blocks("- a\n- b")
        #expect(MarkdownCache.blockCount == 1)
        _ = MarkdownCache.blocks("ainda chegando", cached: false)
        #expect(MarkdownCache.blockCount == 1)
        // Inline text is counted apart.
        #expect(MarkdownCache.count == 0)

        let big = String(repeating: "x", count: 40_000)
        for index in 0..<40 { _ = MarkdownCache.blocks("\(index) " + big) }
        #expect(MarkdownCache.blockCount <= 28)
        MarkdownCache.removeAll()
    }

    @MainActor @Test func inlineCodeAndLinksGetTheLookOfTheChat() {
        let text = MarkdownCache.attributed("use `ls` ou veja [o guia](https://example.com)", cached: false)
        var code = 0, links = 0
        for run in text.runs {
            if run.inlinePresentationIntent?.contains(.code) == true, run.backgroundColor != nil { code += 1 }
            if run.link != nil, run.underlineStyle != nil { links += 1 }
        }
        #expect(code == 1)
        #expect(links == 1)
        #expect(String(text.characters) == "use ls ou veja o guia")
    }
}

/// A long block of code that streams is drawn in pieces of complete lines, so a flush only draws the last one.
@Suite("Código em stream") struct CodeBlockPiecesTests {
    private func lines(_ count: Int) -> String {
        (1...count).map { "linha \($0)" }.joined(separator: "\n")
    }

    @Test func shortCodeIsNotCut() {
        #expect(CodeBlockView.pieces(of: "") == nil)
        #expect(CodeBlockView.pieces(of: lines(CodeBlockView.pieceLines)) == nil)
    }

    @Test func longCodeIsCutInClosedPiecesAndATailThatIsNeverEmpty() throws {
        let size = CodeBlockView.pieceLines
        // One line more than a piece: the first 40 close, the 41st is the one being written.
        let one = try #require(CodeBlockView.pieces(of: lines(size + 1)))
        #expect(one.closed.count == 1)
        #expect(one.tail == "linha \(size + 1)")
        // Exactly two pieces: the second stays open until another line arrives, so the tail is never empty.
        let two = try #require(CodeBlockView.pieces(of: lines(size * 2)))
        #expect(two.closed.count == 1 && two.tail.split(separator: "\n").count == size)
        let three = try #require(CodeBlockView.pieces(of: lines(size * 2 + 5)))
        #expect(three.closed.count == 2 && three.tail.split(separator: "\n").count == 5)
    }

    @Test func thePiecesJoinedBackAreTheCodeAndAClosedPieceNeverChangesWhileItGrows() throws {
        let size = CodeBlockView.pieceLines
        var previous: [String] = []
        for count in stride(from: size + 1, through: size * 4 + 3, by: 7) {
            let code = lines(count) + (count % 2 == 0 ? "\n\nfim" : "")
            let pieces = try #require(CodeBlockView.pieces(of: code))
            #expect((pieces.closed + [pieces.tail]).joined(separator: "\n") == code)
            #expect(!pieces.tail.isEmpty)
            // What closed before is still the same text: that is what lets each piece keep what was drawn of it.
            #expect(Array(pieces.closed.prefix(previous.count)) == previous)
            previous = pieces.closed
        }
    }

    /// The stack's spacing equals the code's line spacing: the seam between two pieces is the gap between two lines.
    @MainActor @Test func theSeamBetweenPiecesAddsNoHeight() {
        let all = (1...80).map { "linha \($0)" }
        func height(_ view: some View) -> CGFloat { NSHostingView(rootView: view.frame(width: 400)).fittingSize.height }
        let font = Font.system(size: 12, design: .monospaced)
        let whole = height(Text(all.joined(separator: "\n")).font(font).lineSpacing(2))
        let pieces = height(VStack(alignment: .leading, spacing: 2) {
            Text(all[0..<40].joined(separator: "\n")).font(font).lineSpacing(2)
            Text(all[40...].joined(separator: "\n")).font(font).lineSpacing(2)
        })
        #expect(abs(whole - pieces) < 0.5)
    }
}

/// A long table that streams is drawn in pieces of rows (the columns stay aligned in one `Grid`), and the cells of the row
/// being written stay out of `MarkdownCache`.
@Suite("Tabela e lista em stream") struct TableStreamingTests {
    private func table(rows: Int, columns: Int = 3) -> MarkdownTable {
        MarkdownTable(header: (0..<columns).map { "Coluna \($0)" },
                      rows: (0..<rows).map { row in (0..<columns).map { "r\(row)c\($0)" + String(repeating: "x", count: (row * 7 + $0 * 3) % 9) } },
                      alignments: Array(repeating: .leading, count: columns))
    }

    @Test func shortTablesAreNotCut() {
        #expect(TableBlockView.pieces(of: []) == nil)
        #expect(TableBlockView.pieces(of: table(rows: TableBlockView.pieceRows).rows) == nil)
    }

    @Test func longTablesAreCutInClosedPiecesAndATailThatIsNeverEmpty() throws {
        let size = TableBlockView.pieceRows
        let one = try #require(TableBlockView.pieces(of: table(rows: size + 1).rows))
        #expect(one.closed.count == 1 && one.closed[0].count == size && one.tail.count == 1)
        let two = try #require(TableBlockView.pieces(of: table(rows: size * 2).rows))
        #expect(two.closed.count == 1 && two.tail.count == size)
        let rows = table(rows: size * 2 + 5).rows
        let three = try #require(TableBlockView.pieces(of: rows))
        #expect(three.closed.count == 2 && three.tail.count == 5)
        #expect((three.closed.flatMap { $0 } + three.tail) == rows)
    }

    @Test func aClosedPieceNeverChangesWhileTheLastCellGrows() throws {
        let size = TableBlockView.pieceRows
        var rows = table(rows: size * 2 + 3).rows
        let before = try #require(TableBlockView.pieces(of: rows))
        rows[rows.count - 1][2] += " mais um pouco" // the cell being written
        let after = try #require(TableBlockView.pieces(of: rows))
        #expect(after.closed == before.closed && after.tail != before.tail)
    }

    @MainActor @Test func theColumnsStayAlignedWhilePiecesStream() {
        func size(_ view: some View) -> CGSize { NSHostingView(rootView: view.frame(width: 700)).fittingSize }
        let long = table(rows: TableBlockView.pieceRows * 2 + 7)
        let whole = size(TableBlockView(table: long, streaming: false))
        let pieces = size(TableBlockView(table: long, streaming: true))
        #expect(whole.height > 0 && abs(whole.height - pieces.height) < 0.5 && abs(whole.width - pieces.width) < 0.5)
    }

    @MainActor @Test func theCellsOfTheRowBeingWrittenStayOutOfTheCache() {
        MarkdownCache.removeAll()
        let small = table(rows: 3, columns: 2)
        let host = NSHostingView(rootView: TableBlockView(table: small, streaming: true).frame(width: 500))
        _ = host.fittingSize
        // The header and the two closed rows (4 + ... cells) are kept, the last row is not.
        #expect(MarkdownCache.count == 2 + 2 * 2)
        MarkdownCache.removeAll()
        _ = NSHostingView(rootView: TableBlockView(table: small, streaming: false).frame(width: 500)).fittingSize
        #expect(MarkdownCache.count == 2 + 3 * 2) // a finished table keeps every cell
        MarkdownCache.removeAll()
    }
}
