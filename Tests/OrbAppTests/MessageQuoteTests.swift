import Foundation
import Testing
@testable import Orb

/// Quoting a reply: the quote at the start of the draft, how a message's quote is read back, and the reply it came from.
struct MessageQuoteTests {
    @Test func aSelectionBecomesAQuoteBlockAtTheStartOfTheDraft() {
        #expect(MessageQuote.block("  Mover os PDFs\n\n  para Contratos/ ") == "> Mover os PDFs\n> para Contratos/")
        #expect(MessageQuote.draft(quoting: "Apagar as duplicadas", before: "  por quê? ") == "> Apagar as duplicadas\n\npor quê?")
        #expect(MessageQuote.draft(quoting: "Apagar", before: "") == "> Apagar\n\n")
        #expect(MessageQuote.draft(quoting: " \n ", before: "oi") == "oi")
        // A second passage joins the first block instead of breaking it.
        let twice = MessageQuote.draft(quoting: "Segundo trecho", before: "> Primeiro trecho\n\npor quê?")
        #expect(twice == "> Primeiro trecho\n> Segundo trecho\n\npor quê?")
        #expect(MessageQuote.split(twice).quote == "Primeiro trecho\nSegundo trecho")
        let long = MessageQuote.block(String(repeating: "a", count: 2_000))
        #expect(long.hasSuffix("…") && long.count <= MessageQuote.limit + 3)
    }

    @Test func aMessagesLeadingQuoteIsReadApartFromWhatFollows() {
        let parts = MessageQuote.split("> Mover os PDFs\n>para Contratos/\n\nPor que não 2024?")
        #expect(parts.quote == "Mover os PDFs\npara Contratos/")
        #expect(parts.body == "Por que não 2024?")
        #expect(MessageQuote.split("Sem citação\n> no meio").quote == nil)
        #expect(MessageQuote.split("> só a citação").body.isEmpty)
        #expect(MessageQuote.split(">\n> \ntexto").quote == nil) // marks without words are no quote
    }

    @Test func theQuoteIsFoundInTheNearestReplyThatHoldsItsStart() {
        let older = TranscriptItem(.bot(text: "1. **Mover** os PDFs para `Contratos/`\n2. Apagar", isStreaming: false))
        let other = TranscriptItem(.bot(text: "Outra coisa.", isStreaming: false))
        let newer = TranscriptItem(.bot(text: "Vou mover os PDFs para Contratos/ agora.", isStreaming: false))
        let message = TranscriptItem(.user(text: "> 1. Mover os PDFs para Contratos/\n\nok", attachments: []))
        let items = [older, other, message, newer]
        // A list item's marker and the Markdown marks do not matter; a reply after the message is not where it came from.
        #expect(MessageQuote.source(of: "1. Mover os PDFs para Contratos/", before: 2, in: items) == older.id)
        #expect(MessageQuote.source(of: "Nada disso foi dito", before: 2, in: items) == nil)
        #expect(MessageQuote.probe("• Mover   os\nPDFs") == "Mover os")
    }

    @MainActor @Test func revealingAQuoteMarksTheReplyForAMomentWithTheBarClosed() async throws {
        let find = ConversationFind(flashDuration: .milliseconds(20))
        let reply = UUID()
        find.reveal(quoteOf: reply, words: "Mover os PDFs")
        #expect(find.jump?.itemID == reply)
        #expect(find.focus == FindFocus(itemID: reply, query: "Mover os PDFs", isFlashing: true))
        #expect(find.pausesFollowing)
        // The wash ends after the flash (waited for, as long as a busy test run needs).
        for _ in 0..<250 where find.focus != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(find.focus == nil && find.jump == nil && !find.pausesFollowing)
    }
}
