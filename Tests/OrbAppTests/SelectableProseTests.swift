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
        view.show(ProseText.make([.paragraph(String(repeating: "palavra ", count: 20))], cursor: false, cached: false, highlight: nil))
        let wide = view.height(forWidth: 2_000), narrow = view.height(forWidth: 200)
        #expect(wide > 10 && wide < 30)
        #expect(narrow > wide * 4)
    }
}
