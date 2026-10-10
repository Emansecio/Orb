import Foundation
import Testing
@testable import Orb

// The folding of a chat's lines between Orbs (docs/MULTI-ORBS.md, 5 and 8.3, WP2): which lines fold together, the words of a
// folded row, and that a chat without such lines is left as it is.

@MainActor
@Suite("Dobra da conversa entre Orbs")
struct TranscriptFoldingTests {
    private let atlas = OrbRef(id: UUID(), name: "Atlas")
    private let researcher = OrbRef(id: UUID(), name: "Pesquisador")
    private let reviewer = OrbRef(id: UUID(), name: "Revisor")
    private let lia = OrbRef(id: UUID(), name: "Lia")

    private func event(_ kind: OrbEvent.Kind, actor: OrbRef? = nil, subject: OrbRef? = nil, detail: String? = nil,
                       chain: UUID? = nil) -> TranscriptItem {
        TranscriptItem(.event(OrbEvent(kind: kind, actor: actor, subject: subject, detail: detail, chainID: chain)))
    }

    private func msg(_ kind: OrbMessageItem.Kind, _ direction: OrbMessageItem.Direction = .sent,
                     _ state: OrbMessageItem.State = .replied, from: OrbRef, to: OrbRef, chain: UUID) -> OrbMessageItem {
        OrbMessageItem(direction: direction, kind: kind, state: state, from: from, to: to, text: "texto", requestID: UUID(),
                       chainID: chain)
    }

    private func message(_ kind: OrbMessageItem.Kind, _ direction: OrbMessageItem.Direction = .sent,
                         _ state: OrbMessageItem.State = .replied, from: OrbRef, to: OrbRef, chain: UUID) -> TranscriptItem {
        TranscriptItem(.orbMessage(msg(kind, direction, state, from: from, to: to, chain: chain)))
    }

    private func tool() -> TranscriptItem {
        TranscriptItem(.tool(ToolCall(kind: .orbs, title: "Falando com Pesquisador", detail: "", state: .done)))
    }

    private func say(_ text: String) -> TranscriptItem { TranscriptItem(.bot(text: text, isStreaming: false)) }

    @Test("Uma linha sozinha fica como está")
    func loneLine() {
        let items = [event(.orbCreated, actor: atlas, subject: researcher)]
        let rows = TranscriptFolding.rows(for: items)
        #expect(rows == [.single(items[0])])
    }

    @Test("Eventos do mesmo tipo e do mesmo ator, seguidos, viram uma linha")
    func eventsFold() {
        let items = [event(.orbCreated, actor: atlas, subject: researcher),
                     event(.orbCreated, actor: atlas, subject: reviewer),
                     event(.orbCreated, actor: atlas, subject: lia)]
        let rows = TranscriptFolding.rows(for: items)
        #expect(rows == [.events(.orbCreated, items)])
        #expect(TranscriptFolding.eventsTitle(.orbCreated, items) == "Atlas criou 3 Orbs: Pesquisador, Revisor e Lia")
    }

    @Test("Mudança de tipo quebra a dobra; de ator também")
    func kindAndActorBreakFolds() {
        let items = [event(.orbCreated, actor: atlas, subject: researcher),
                     event(.routineCreated, actor: atlas, detail: "Checar"),
                     event(.orbCreated, actor: researcher, subject: reviewer)]
        let rows = TranscriptFolding.rows(for: items)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { if case .single = $0 { true } else { false } })
    }

    @Test("Entradas no mesmo grupo dobram; em grupos diferentes não")
    func groupEntriesFoldByGroup() {
        let same = [event(.joinedGroup, subject: researcher, detail: "Lançamento"),
                    event(.joinedGroup, subject: reviewer, detail: "Lançamento")]
        #expect(TranscriptFolding.rows(for: same) == [.events(.joinedGroup, same)])
        #expect(TranscriptFolding.eventsTitle(.joinedGroup, same) == "Pesquisador e Revisor entraram no grupo Lançamento")
        let other = [event(.joinedGroup, subject: researcher, detail: "Lançamento"),
                     event(.joinedGroup, subject: reviewer, detail: "Outro")]
        #expect(TranscriptFolding.rows(for: other).count == 2)
    }

    @Test("Mensagens entre Orbs seguidas viram uma troca; uma só fica como linha")
    func messagesFoldIntoOneExchange() {
        let chain = UUID()
        let items = [message(.ask, from: atlas, to: researcher, chain: chain),
                     message(.reply, .reply, from: researcher, to: atlas, chain: chain),
                     message(.ask, from: atlas, to: reviewer, chain: chain)]
        let rows = TranscriptFolding.rows(for: items)
        #expect(rows == [.exchange(items)])
        #expect(TranscriptFolding.exchangeTitle(items, botID: atlas.id) == "3 mensagens com 2 Orbs")
        let speech = say("oi")
        #expect(TranscriptFolding.rows(for: [items[0], speech]) == [.single(items[0]), .single(speech)])
    }

    @Test("Só envios com dois parceiros: 'Pediu ajuda a P Orbs'; com um, 'N mensagens com X'")
    func exchangeTitles() {
        let chain = UUID()
        let asks = [message(.ask, from: atlas, to: researcher, chain: chain), message(.ask, from: atlas, to: reviewer, chain: chain)]
        #expect(TranscriptFolding.exchangeTitle(asks, botID: atlas.id) == "Pediu ajuda a 2 Orbs")
        let one = [message(.ask, from: atlas, to: researcher, chain: chain), message(.reply, .reply, from: researcher, to: atlas, chain: chain)]
        #expect(TranscriptFolding.exchangeTitle(one, botID: atlas.id) == "2 mensagens com Pesquisador")
    }

    @Test("Uma linha de ferramenta entre duas mensagens não quebra a troca; fica depois dela")
    func toolLineDoesNotBreakExchange() {
        let chain = UUID()
        let first = message(.ask, from: atlas, to: researcher, chain: chain)
        let second = message(.ask, from: atlas, to: reviewer, chain: chain)
        let call = tool()
        let rows = TranscriptFolding.rows(for: [first, call, second])
        #expect(rows == [.exchange([first, second]), .single(call)])
    }

    @Test("Uma fala do Orb quebra a troca")
    func speechBreaksExchange() {
        let chain = UUID()
        let items = [message(.ask, from: atlas, to: researcher, chain: chain), say("Vou esperar."),
                     message(.ask, from: atlas, to: reviewer, chain: chain)]
        #expect(TranscriptFolding.rows(for: items).count == 3)
    }

    @Test("Ids estáveis: a linha dobrada tem o id do primeiro item, mesmo quando cresce")
    func stableIDs() {
        let items = [event(.orbCreated, actor: atlas, subject: researcher), event(.orbCreated, actor: atlas, subject: reviewer)]
        let grown = items + [event(.orbCreated, actor: atlas, subject: lia)]
        #expect(TranscriptFolding.rows(for: items)[0].id == items[0].id)
        #expect(TranscriptFolding.rows(for: grown)[0].id == items[0].id)
    }

    @Test("Chat sem linhas de Orb não tem dobra: a lista é a de hoje")
    func plainChatHasNoRows() {
        #expect(!TranscriptFolding.hasFoldableItems([say("oi"), TranscriptItem(.user(text: "tudo bem", attachments: []))]))
        #expect(TranscriptFolding.hasFoldableItems([event(.renamed, actor: atlas, detail: "Atlas Pro")]))
        let many = (0..<10_000).map { _ in say("x") }
        #expect(OrbTranscript(items: many).rows == nil)
    }

    @Test("Palavras da linha de mensagem: pediu ajuda, avisou, respondeu, com a preposição certa")
    func exchangeWords() {
        let chain = UUID()
        #expect(ExchangeWords.line(for: msg(.ask, from: atlas, to: researcher, chain: chain)) == "Atlas pediu ajuda ao Pesquisador")
        #expect(ExchangeWords.line(for: msg(.ask, from: atlas, to: lia, chain: chain)) == "Atlas pediu ajuda à Lia")
        #expect(ExchangeWords.line(for: msg(.tell, from: atlas, to: reviewer, chain: chain)) == "Atlas avisou o Revisor")
        #expect(ExchangeWords.line(for: msg(.reply, .reply, from: researcher, to: atlas, chain: chain)) == "Pesquisador respondeu a Atlas")
        #expect(ExchangeWords.line(for: msg(.reply, .reply, from: researcher, to: lia, chain: chain)) == "Pesquisador respondeu à Lia")
    }

    @Test("Lista em português")
    func listing() {
        #expect(PortugueseList.join([]) == "")
        #expect(PortugueseList.join(["A"]) == "A")
        #expect(PortugueseList.join(["A", "B"]) == "A e B")
        #expect(PortugueseList.join(["A", "B", "C"]) == "A, B e C")
    }
}
