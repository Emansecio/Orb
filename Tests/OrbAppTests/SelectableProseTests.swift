import AppKit
import Testing
@testable import Orb

/// A reply's paragraphs, headings, lists and quotes are one text, so a drag selects across them; a copy reads as the reply does.
@MainActor
struct SelectableProseTests {
    private let list = MarkdownBlock.list([MarkdownListItem(depth: 0, marker: .bullet, text: "PDFs: **12**"),
                                           MarkdownListItem(depth: 1, marker: .bullet, text: "contratos"),
                                           MarkdownListItem(depth: 0, marker: .number(2), text: "fim"),
                                           MarkdownListItem(depth: 0, marker: .task(done: true), text: "feito")])

    @Test func proseRunsBreakOnlyAtCodeTablesAndRules() {
        let code = MarkdownBlock.code(language: "bash", code: "ls", isClosed: true)
        let blocks: [MarkdownBlock] = [.paragraph("a"), .heading(level: 2, text: "b"), list, .quote("c"), code, .paragraph("d"), .rule]
        #expect(ProseSegment.of(blocks) == [.prose([.paragraph("a"), .heading(level: 2, text: "b"), list, .quote("c")]),
                                            .block(code), .prose([.paragraph("d")]), .block(.rule)])
        #expect(ProseSegment.of([]) == [])
    }

    @Test func theTextHoldsEveryBlockAndACopyReadsAsTheReply() {
        let text = ProseText.make([.paragraph("Encontrei **42** arquivos\nna pasta."), .heading(level: 2, text: "Por tipo"), list,
                                   .quote("Nada foi apagado.")], cursor: false, cached: false, highlight: nil)
        let all = NSRange(location: 0, length: text.length)
        #expect(ProseText.plain(text, ranges: [all]) == """
            Encontrei 42 arquivos
            na pasta.
            Por tipo
            • PDFs: 12
              ◦ contratos
            2. fim
            ☑ feito
            Nada foi apagado.
            """)
        // Bold stays bold; the break inside the paragraph does not start a new one (its spacing comes after the paragraph).
        let bold = (text.string as NSString).range(of: "42")
        let font = text.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(!text.string.contains("arquivos\nna"))
        // A part of a list item copies its marker once.
        let item = (text.string as NSString).range(of: "\t•\tPDFs")
        #expect(ProseText.plain(text, ranges: [NSRange(location: item.location + 1, length: 6)]) == "• PDFs")
    }

    @Test func blocksAreSpacedAsTheStackHadThemAndTheLastIsNot() {
        let text = ProseText.make([.paragraph("um"), .paragraph("dois")], cursor: true, cached: false, highlight: nil)
        let first = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let last = text.attribute(.paragraphStyle, at: text.length - 6, effectiveRange: nil) as? NSParagraphStyle
        #expect(first?.paragraphSpacing == markdownBlockSpacing)
        #expect(last?.paragraphSpacing == 0)
        #expect(text.string.hasSuffix("dois ●"))
    }

    @Test func linksAndFoundTextKeepTheirMarks() {
        let text = ProseText.make([.paragraph("Ver a [documentação](https://example.com) agora")], cursor: false, cached: false,
                                  highlight: "agora")
        let link = (text.string as NSString).range(of: "documentação")
        #expect((text.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.absoluteString == "https://example.com")
        let found = (text.string as NSString).range(of: "agora")
        #expect(text.attribute(.backgroundColor, at: found.location, effectiveRange: nil) != nil)
    }

    @Test func theViewIsAsTallAsItsLinesAtTheWidthItIsGiven() {
        let view = ProseTextView()
        view.show(ProseText.make([.paragraph(String(repeating: "palavra ", count: 20))], cursor: false, cached: false, highlight: nil),
                  cursor: false, fades: false)
        let wide = view.size(forWidth: 2_000).height, narrow = view.size(forWidth: 200).height
        #expect(wide > 10 && wide < 30)
        #expect(narrow > wide * 4)
    }

    /// While a reply streams each paragraph is a view of its own, one under the other `markdownBlockSpacing` apart; the
    /// finished reply is one text. The two are as tall, so the reply does not move when the stream ends.
    @Test func theFinishedReplyIsAsTallAsItsParagraphsWereWhileStreaming() {
        let paragraphs: [MarkdownBlock] = [.paragraph(String(repeating: "palavra ", count: 30)), .heading(level: 2, text: "Por tipo"),
                                           .list([MarkdownListItem(depth: 0, marker: .bullet, text: "PDFs: 12"),
                                                  MarkdownListItem(depth: 0, marker: .bullet, text: "Imagens: 20")]),
                                           .paragraph(String(repeating: "outra ", count: 25))]
        func height(_ blocks: [MarkdownBlock]) -> CGFloat {
            let view = ProseTextView()
            view.show(ProseText.make(blocks, cursor: false, cached: false, highlight: nil), cursor: false, fades: false)
            return view.size(forWidth: 320).height
        }
        // While streaming each paragraph is a text of its own, stacked with the blocks' spacing, and a heading after
        // another paragraph takes its lead on top (`MarkdownChunk.first`).
        let leads = paragraphs.dropFirst().map { block -> CGFloat in
            if case .heading(let level, _) = block { ProseText.headingLead(level) } else { 0 }
        }
        let apart = paragraphs.map { height([$0]) }.reduce(0, +) + leads.reduce(0, +)
            + markdownBlockSpacing * CGFloat(paragraphs.count - 1)
        #expect(abs(height(paragraphs) - apart) < 0.5)
    }

    /// Inside a bubble the text is as wide as its longest line, and laid out again at that width it keeps its lines.
    @Test func theLongestLineIsTheWidthAndKeepsTheLinesWhereTheyBreak() {
        // Already laid out in a frame as wide as the chat (the container's own used rect then spans all of it).
        let short = ProseTextView()
        short.frame = NSRect(x: 0, y: 0, width: 600, height: 20)
        short.show(ProseText.make([.paragraph("Oi! Em que posso ajudar?")], cursor: false, cached: false, highlight: nil),
                   cursor: false, fades: false)
        let line = short.size(forWidth: 600)
        #expect(line.width > 40 && line.width < 300)
        #expect(short.size(forWidth: line.width) == line)

        let long = ProseTextView()
        long.show(ProseText.make([.paragraph(String(repeating: "palavra ", count: 40)), .list([MarkdownListItem(depth: 0, marker: .bullet, text: "um item")])],
                                 cursor: false, cached: false, highlight: nil),
                  cursor: false, fades: false)
        let wrapped = long.size(forWidth: 300)
        #expect(wrapped.width <= 300 && wrapped.width > 250)
        #expect(long.size(forWidth: wrapped.width).height == wrapped.height)
    }

    @Test func narrationIsAPointSmallerAndDimmerWithItsBoldKept() {
        let text = ProseText.make([.paragraph("Vou **baixar** o áudio.")], cursor: false, cached: false, highlight: nil)
        let quiet = ProseText.quieter(text)
        #expect(quiet.string == text.string)
        let bold = (quiet.string as NSString).range(of: "baixar").location
        for index in [0, bold] {
            let font = text.attribute(.font, at: index, effectiveRange: nil) as? NSFont
            let quietFont = quiet.attribute(.font, at: index, effectiveRange: nil) as? NSFont
            #expect(quietFont?.pointSize == (font?.pointSize ?? 0) - 1)
            #expect(quietFont?.fontDescriptor.symbolicTraits.contains(.bold) == font?.fontDescriptor.symbolicTraits.contains(.bold))
            let color = text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
            let quietColor = quiet.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
            #expect(abs((quietColor?.alphaComponent ?? 0) - (color?.alphaComponent ?? 0) * ProseText.quietAlpha) < 0.001)
        }
    }
}
