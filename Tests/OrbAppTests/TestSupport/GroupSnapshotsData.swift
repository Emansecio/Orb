import Foundation
@testable import Orb

/// Sample data for the group screens' `--snapshot` modes (docs/historico/MULTI-ORBS.md, WP6): a group of three, a thread with the
/// person's message, the plan, the assignments, the answers, a pause card, and the numbers of a request in progress. Fixed ids and
/// dates, so a snapshot is the same every time. Put the thread into a `GroupSession` with `seedConversation(_:)`.
enum GroupSnapshotsData {
    static let atlas = OrbRef(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!, name: "Atlas")
    static let pesquisador = OrbRef(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!, name: "Pesquisador")
    static let revisor = OrbRef(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000C3")!, name: "Revisor")
    static let groupID = UUID(uuidString: "00000000-0000-4000-8000-0000000000D4")!
    static let chainID = UUID(uuidString: "00000000-0000-4000-8000-0000000000E5")!
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// "Lançamento": Atlas coordinates, the others work.
    static var group: OrbGroup {
        OrbGroup(id: groupID, name: "Lançamento", memberIDs: [atlas.id, pesquisador.id, revisor.id], orchestratorID: atlas.id,
                 createdAt: start)
    }

    private static func item(_ kind: TranscriptItem.Kind, _ seconds: TimeInterval) -> TranscriptItem {
        var item = TranscriptItem(kind)
        item.date = start.addingTimeInterval(seconds)
        return item
    }

    private static func post(_ from: OrbRef, to: OrbRef? = nil, _ kind: OrbMessageItem.Kind, _ state: OrbMessageItem.State, _ text: String,
                             _ seconds: TimeInterval) -> TranscriptItem {
        item(.orbMessage(OrbMessageItem(direction: .post, kind: kind, state: state, from: from, to: to, text: text,
                                        requestID: UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", Int(seconds)))!,
                                        chainID: chainID, groupID: groupID)), seconds)
    }

    /// The group just made, before anyone said anything.
    static var emptyThread: Conversation {
        var conversation = Conversation()
        conversation.items = [item(.event(OrbEvent(kind: .groupCreated, detail: "Lançamento · 3", groupID: groupID)), 0)]
        return conversation
    }

    /// A request that went well: the plan, two assignments, a member asking another directly, the answers and the final answer.
    static var finishedThread: Conversation {
        var conversation = emptyThread
        conversation.items += [
            item(.user(text: "Prepare o lançamento da versão 2: pesquise o mercado e revise o texto do anúncio.", attachments: []), 10),
            post(atlas, .tell, .replied, "Vou dividir: o Pesquisador levanta o mercado e o Revisor revisa o anúncio.", 20),
            post(atlas, to: pesquisador, .ask, .replied, "Levante três concorrentes e os preços deles.", 21),
            post(atlas, to: revisor, .ask, .replied, "Revise o texto do anúncio em tópicos curtos.", 22),
            post(pesquisador, to: revisor, .ask, .replied, "Estes números de preço estão coerentes com o anúncio?", 30),
            post(revisor, to: pesquisador, .reply, .replied, "Estão. Ajustei o preço do plano básico no texto.", 40),
            post(pesquisador, to: atlas, .reply, .replied, "Três concorrentes: A (R$ 29), B (R$ 35), C (R$ 41).", 50),
            post(revisor, to: atlas, .reply, .replied, "Anúncio revisado: 3 correções e título mais curto.", 51),
            post(atlas, .reply, .replied, "Pronto: o mercado está levantado (três concorrentes entre R$ 29 e R$ 41) e o anúncio revisado.", 60),
            item(.event(OrbEvent(kind: .groupRunDone, detail: "6 turnos · 42 mil tokens", chainID: chainID, groupID: groupID)), 61),
        ]
        return conversation
    }

    /// A request in the middle: the plan and the assignments are out, nobody has answered yet.
    static var workingThread: Conversation {
        var conversation = emptyThread
        conversation.items += [
            item(.user(text: "Prepare o lançamento da versão 2.", attachments: []), 10),
            post(atlas, .tell, .open, "Vou dividir o trabalho entre vocês dois.", 20),
            post(atlas, to: pesquisador, .ask, .open, "Levante três concorrentes e os preços deles.", 21),
            post(atlas, to: revisor, .ask, .open, "Revise o texto do anúncio.", 22),
        ]
        return conversation
    }

    /// The same request stopped by the budget: the card waits for Continuar or Encerrar.
    static var pausedThread: Conversation {
        var conversation = workingThread
        conversation.items.append(item(.groupPause(pause), 70))
        return conversation
    }

    static var pause: GroupPauseItem {
        GroupPauseItem(groupID: groupID, runID: chainID, reason: .turns, state: .open, turnsUsed: 12, tokensUsed: 98_000,
                       turnLimit: 12, tokenLimit: 150_000)
    }

    /// What a request spent after nine turns.
    static var nineTurns: GroupUsage { GroupUsage(turnsUsed: 9, tokensUsed: 71_000) }
}
