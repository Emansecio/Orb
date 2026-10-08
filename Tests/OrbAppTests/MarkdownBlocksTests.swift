import Foundation
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
