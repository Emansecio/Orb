import AppKit
import Testing
@testable import Orb

/// The words a flush adds to the reply being written fade in; what was shown never fades again.
@MainActor
struct TextFadeTests {
    @Test func onlyWhatAFlushAddsIsNew() {
        #expect(TextFade.appended(to: "Olá, mun", in: "Olá, mundo") == NSRange(location: 8, length: 2))
        #expect(TextFade.appended(to: "", in: "Olá") == NSRange(location: 0, length: 3))
        // UTF-16, as the text storage counts.
        #expect(TextFade.appended(to: "Feito 👍", in: "Feito 👍 e mais") == NSRange(location: 8, length: 7))
        // A change (Markdown read differently once more arrived) or nothing added: nothing fades.
        #expect(TextFade.appended(to: "**negr", in: "negrito") == nil)
        #expect(TextFade.appended(to: "igual", in: "igual") == nil)
        #expect(TextFade.appended(to: "mais longo", in: "mais") == nil)
    }

    @Test func wordsSplitAtSpacesBreaksAndColours() {
        let text = NSMutableAttributedString(string: "um  dois\u{2028}três\tver👍 link.")
        let link = (text.string as NSString).range(of: "link")
        text.addAttribute(.link, value: URL(string: "https://example.com")!, range: link)
        let words = TextFade.words(in: text, range: NSRange(location: 0, length: text.length))
        #expect(words.map { (text.string as NSString).substring(with: $0) } == ["um", "dois", "três", "ver👍", "link", "."])
        // Only the range asked for.
        let tail = TextFade.words(in: text, range: NSRange(location: 1, length: 7))
        #expect(tail.map { (text.string as NSString).substring(with: $0) } == ["m", "dois"])
    }

    @Test func aBatchIsStaggeredAndEachWordEasesIn() {
        #expect(TextFade.delay(of: 0, among: 1) == 0)
        #expect(TextFade.delay(of: 0, among: 5) == 0)
        #expect(TextFade.delay(of: 4, among: 5) == TextFade.stagger)
        #expect(TextFade.delay(of: 2, among: 5) == TextFade.stagger / 2)
        #expect(TextFade.opacity(at: -0.05) == 0)
        #expect(TextFade.opacity(at: 0) == 0)
        #expect(TextFade.opacity(at: TextFade.duration) == 1)
        #expect(TextFade.opacity(at: 10) == 1)
        // Eased out: past half way at half the time.
        #expect(TextFade.opacity(at: TextFade.duration / 2) > 0.8)
    }

    @Test func aViewMadeAgainFadesOnlyWhatCameSince() {
        // A new paragraph: all of it is new.
        #expect(TextFade.added("Parágrafo sendo escrito", after: nil) == NSRange(location: 0, length: 23))
        // The same paragraph in a view made again (a row scrolled back into view): only what came since.
        #expect(TextFade.added("Parágrafo sendo escrito agora", after: nil) == NSRange(location: 23, length: 6))
        #expect(TextFade.added("Parágrafo sendo escrito agora", after: nil) == nil)
        // A view that showed something compares with that only.
        #expect(TextFade.added("Outro texto", after: "Outro") == NSRange(location: 5, length: 6))
        #expect(TextFade.added("Outro texto", after: "Diferente") == nil)
    }

    /// The added words start invisible, as temporary colours of the layout manager; the text shown before keeps its own.
    @Test func theViewFadesOnlyTheAddedWordsOfTheTextBeingWritten() {
        let view = ProseTextView()
        func show(_ source: String, cursor: Bool = true, fades: Bool = true) {
            view.show(ProseText.make([.paragraph(source)], cursor: cursor, cached: false, highlight: nil), cursor: cursor, fades: fades)
        }
        func faded(_ word: String) -> Bool {
            let range = (view.string as NSString).range(of: word)
            let color = view.layoutManager?.temporaryAttributes(atCharacterIndex: range.location, effectiveRange: nil)[.foregroundColor]
            return (color as? NSColor).map { $0.alphaComponent < 0.01 } ?? false
        }
        show("Começo da vista de teste", fades: false)
        show("Começo da vista de teste e o resto")
        #expect(!faded("Começo") && !faded("teste") && !faded("●"))
        #expect(faded("resto"))
        // A paste too long to fade appears at once; the words already fading go on.
        show("Começo da vista de teste e o resto" + String(repeating: " palavra", count: TextFade.wordLimit + 1))
        #expect(faded("resto") && !faded("palavra"))
        // Anything but growing shows at once.
        show("Outra coisa da vista de teste")
        #expect(!faded("Outra") && !faded("coisa"))
        // Not the text being written: at once.
        show("Outra coisa da vista de teste já pronta", cursor: false, fades: false)
        #expect(!faded("pronta"))
    }
}
