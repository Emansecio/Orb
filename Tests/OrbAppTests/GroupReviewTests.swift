import Testing
@testable import Orb

struct GroupReviewTests {
    @Test func theFirstLineIsTheVerdictInAnyCaseAccentOrMarkdown() {
        for reply in ["APPROVED", "approved", "Approved.", "**APPROVED**", "## APPROVED", "> Approved: all green", "APPROVED - works",
                      "Aprovado", "APROVADO!", "aprovada", "\n\n  **Aprovado:** tudo certo\nresto"] {
            #expect(ReviewVerdict.read(reply) == .approved, "\(reply)")
        }
        for reply in ["CHANGES: fix login", "changes", "**CHANGES:** the button", "- Changes: x", "Alterações: o botão", "ALTERACOES - x",
                      "MUDANÇAS: tudo", "Mudancas\n1. foo"] {
            #expect(ReviewVerdict.read(reply) == .changes, "\(reply)")
        }
    }

    @Test func textThatOnlyStartsLikeAVerdictIsNotOne() {
        for reply in ["", "  \n ", "Done: built it", "Changes were made to the file", "Approvedly yes", "Not APPROVED", "Aprovação pendente",
                      "I APPROVED it\nAPPROVED", "Todas as alterações foram feitas"] {
            #expect(ReviewVerdict.read(reply) == nil, "\(reply)")
        }
    }

    @Test func theLinesAreInPortuguese() {
        #expect(ReviewVerdict.eventLine(.approved, round: 2) == "Revisão: aprovado na rodada 2")
        #expect(ReviewVerdict.eventLine(.changes, round: 1) == "Revisão: pediu mudanças (rodada 1)")
        #expect(ReviewVerdict.pageLine(.approved, round: 3) == "aprovada na rodada 3")
    }
}
