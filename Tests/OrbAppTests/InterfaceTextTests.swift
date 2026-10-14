import Foundation
import Testing
@testable import Orb

/// Small rules of how the interface writes times and cut texts.
@Suite struct InterfaceTextTests {
    @Test func aDateWithinAMinuteIsNow() {
        let now = Date()
        #expect(RelativeTime.text(now, now: now) == "agora")
        #expect(RelativeTime.text(now.addingTimeInterval(2), now: now) == "agora")
        #expect(RelativeTime.text(now.addingTimeInterval(-40), now: now) == "agora")
        #expect(RelativeTime.text(now.addingTimeInterval(-3_600), now: now) != "agora")
    }

    @Test func aRelativeTimeHasNoAbbreviationPeriod() {
        let now = Date()
        #expect(RelativeTime.text(now.addingTimeInterval(-39 * 60), now: now) == "há 39 min")
        #expect(RelativeTime.text(now.addingTimeInterval(-2 * 3_600 - 120), now: now) == "há 2 h")
        #expect(RelativeTime.text(now.addingTimeInterval(-26 * 3_600), now: now) == "há 1 dia")
        #expect(RelativeTime.text(now.addingTimeInterval(-9 * 86_400), now: now) == "há 1 semana")
        #expect(RelativeTime.text(now.addingTimeInterval(-70 * 86_400), now: now) == "há 2 meses")
        #expect(RelativeTime.text(now.addingTimeInterval(400 * 86_400), now: now) == "em 1 ano")
        #expect(RelativeTime.text(now.addingTimeInterval(3 * 3_600), now: now) == "em 3 h")
    }

    @Test func aCutEndsInOneEllipsisAfterTheWord() {
        let text = "Ask a few preference questions, write a tight persona. Then verify against the live profile."
        let cut = MemoryText.clip(text, 57)
        #expect(cut == "Ask a few preference questions, write a tight persona…")
        // A short text is not touched, its period included.
        #expect(MemoryText.clip("Resume um texto.", 40) == "Resume um texto.")
        // An opening bracket at the start stays; a closing one at the cut too.
        #expect(MemoryText.clip("(nota) um texto bem comprido (com parênteses) e mais palavras", 47) == "(nota) um texto bem comprido (com parênteses)…")
    }

    @Test func anOlderCutLosesItsDanglingPeriod() {
        #expect(MemoryText.tidyEllipsis("against the live profile.…") == "against the live profile…")
        #expect(MemoryText.tidyEllipsis("or running the standing…") == "or running the standing…")
        #expect(MemoryText.tidyEllipsis("Sem corte.") == "Sem corte.")
    }
}
