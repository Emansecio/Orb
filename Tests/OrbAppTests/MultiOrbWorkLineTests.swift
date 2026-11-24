import Foundation
import Testing
@testable import Orb

// The Orb's lines while it talks to other Orbs (docs/historico/MULTI-ORBS.md, 8.1 to 8.3, WP2): the phrases of the work line, the
// conversing face, and what the search finds of the lines between Orbs.

@Suite("Linha de trabalho entre Orbs")
struct MultiOrbWorkLineTests {
    @Test("Pedido de outro Orb vem na frente da frase")
    func prefixComesFirst() {
        let line = WorkLine(verb: "Lendo", target: "README.md", style: .code, prefix: "Pedido de Atlas")
        #expect(line.text == "Pedido de Atlas: Lendo README.md")
        #expect(line.phrase == "Lendo README.md")
        let other = WorkLine(verb: "Lendo", target: "README.md", style: .code)
        #expect(line.phraseKey != other.phraseKey)
    }

    @Test("Falando com X enquanto a ferramenta orbs roda; Avisando X para tell")
    func talkingPhrases() {
        #expect(WorkPhrase.talking(to: "Pesquisador").phrase == "Falando com Pesquisador")
        let call = ToolCall(kind: .orbs, title: "Falando com Pesquisador", detail: "", state: .done)
        let line = WorkPhrase.line(for: call)
        #expect(line.verb == "Falando com")
        #expect(line.target == "Pesquisador")
        #expect(line.style == .plain)
        let notice = WorkPhrase.line(for: ToolCall(kind: .orbs, title: "Avisando Revisor", detail: "", state: .done))
        #expect(notice.phrase == "Avisando Revisor")
    }

    @Test("Esperando X, X e Y, ou N Orbs conforme quantos")
    func waitingPhrases() {
        #expect(WorkPhrase.waiting(for: []) == nil)
        #expect(WorkPhrase.waiting(for: ["Pesquisador"])?.phrase == "Esperando Pesquisador")
        #expect(WorkPhrase.waiting(for: ["Pesquisador", "Revisor"])?.phrase == "Esperando Pesquisador e Revisor")
        #expect(WorkPhrase.waiting(for: ["Pesquisador", "Revisor", "Lia"])?.phrase == "Esperando 3 Orbs")
        #expect(WorkPhrase.waiting(for: ["Pesquisador"])?.tone == .working)
    }
}

@Suite("Pesquisa nas linhas entre Orbs")
struct MultiOrbSearchTests {
    @Test("Eventos e mensagens entre Orbs entram na busca pelo texto que mostram")
    @MainActor func searchableText() {
        let atlas = OrbRef(id: UUID(), name: "Atlas")
        let researcher = OrbRef(id: UUID(), name: "Pesquisador")
        let event = TranscriptItem(.event(OrbEvent(kind: .orbCreated, actor: atlas, subject: researcher)))
        #expect(ConversationSearch.searchable(event)?.text == "Atlas criou o Pesquisador")
        let message = OrbMessageItem(direction: .sent, kind: .ask, state: .replied, from: atlas, to: researcher,
                                     text: "Pesquisa preços.", requestID: UUID(), chainID: UUID())
        let found = ConversationSearch.searchable(TranscriptItem(.orbMessage(message)))?.text ?? ""
        #expect(found.contains("pediu ajuda ao Pesquisador"))
        #expect(found.contains("Pesquisa preços."))
        #expect(ConversationSearch.searchable(TranscriptItem(.groupPause(GroupPauseItem(groupID: UUID(), runID: UUID(), reason: .turns, turnsUsed: 1, tokensUsed: 0, turnLimit: 1, tokenLimit: 1)))) == nil)
    }
}
