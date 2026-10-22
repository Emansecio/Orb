#if DEBUG || ORB_DEV_TOOLS
import SwiftUI

/// `--snapshot` modes of the exchange lines, the folds, the exchange view and the sidebar while Orbs talk (docs/historico/MULTI-ORBS.md,
/// 8.1 to 8.3 and 9, WP2). Made-up data in the snapshot's own folder, never the user's: `Orb --snapshot <mode> out.png`.
///
/// - `events`: one line of each kind of event, in Atlas's chat (the one asked for help has its avatar and opens the exchange).
/// - `events-folded`: three creations and three entries into a group, each run folded into one line.
/// - `delegation-thread`: a finished exchange folded, then an open, a failed and a lost message in their own lines.
/// - `delegation-folded`: an exchange of three messages with two Orbs, folded (closed) and unfolded.
/// - `delegation-exchange`: the read-only exchange view.
/// - `delegation-waiting`: the work line of an Orb that waits for two answers (the composer's Stop ends it).
/// - `sidebar-talking`: the sidebar while Atlas talks with Pesquisador: the rings and the phrases of both sides.
/// - `delegation-group`: Atlas creates the group Lançamento, asks it from its chat and gets the group's answer, and a notice
///   from the Revisor arrives.
@MainActor
enum DelegationSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
        guard let atlas = model.bots.first else { return nil }
        switch screen {
        case "events", "events-folded", "delegation-thread", "delegation-waiting", "delegation-folded", "delegation-exchange",
             "sidebar-talking", "delegation-group":
            break
        default:
            return nil
        }
        let team = Team(model: model, atlas: atlas)
        switch screen {
        case "events":
            return chat(model, atlas, events(team))
        case "events-folded":
            return chat(model, atlas, eventsFolded(team))
        case "delegation-thread":
            return chat(model, atlas, thread(team))
        case "delegation-waiting":
            let live = model.live(atlas.id)
            live.setChainWork(WorkPhrase.waiting(for: [team.researcher.name, team.reviewer.name]))
            live.setPartner(PartnerTint(botID: team.researcher.id, color: team.researcher.orb.color))
            return chat(model, atlas, waiting(team))
        case "delegation-group":
            let group = OrbGroup(name: "Lançamento", memberIDs: [atlas.id, team.researcher.id, team.reviewer.id],
                                 orchestratorID: team.researcher.id)
            model.groups = [group]
            return chat(model, atlas, groupLines(team, group: group.id))
        case "delegation-folded":
            return AnyView(foldedPreview(team))
        case "delegation-exchange":
            return AnyView(exchangePreview(team))
        default: // sidebar-talking
            setUpTalking(model, team)
            return AnyView(SidebarView().frame(width: 280))
        }
    }

    // MARK: The Orbs of the snapshots

    /// Atlas and the Orbs it talks with: Pesquisador and Revisor (and Lia, who is a woman's name for the article "à").
    @MainActor
    struct Team {
        let atlas: Bot
        let researcher: Bot
        let reviewer: Bot
        let lia: Bot

        init(model: AppModel, atlas: Bot) {
            self.atlas = atlas
            researcher = Self.orb(model, "Pesquisador", role: "Pesquisa e resume", color: "menta")
            reviewer = Self.orb(model, "Revisor", role: "Confere o trabalho", color: "coral")
            lia = Self.orb(model, "Lia", role: "Escreve textos", color: "rosa")
        }

        /// The Orb of that name, made once in the snapshot's folder.
        private static func orb(_ model: AppModel, _ name: String, role: String, color: String) -> Bot {
            if let existing = model.bots.first(where: { $0.name == name }) { return existing }
            return model.createBot(name: name, role: role, orb: OrbConfig(color: color), model: "", mode: .ask, folder: .home)
        }
    }

    // MARK: Fixtures

    private static func event(_ kind: OrbEvent.Kind, actor: Bot? = nil, subject: Bot? = nil, detail: String? = nil,
                              chain: UUID? = nil) -> TranscriptItem {
        TranscriptItem(.event(OrbEvent(kind: kind, actor: actor.map { OrbRef($0) }, subject: subject.map { OrbRef($0) },
                                       detail: detail, chainID: chain)))
    }

    private static func message(_ kind: OrbMessageItem.Kind, _ state: OrbMessageItem.State, from: Bot, to: Bot, text: String,
                                chain: UUID, direction: OrbMessageItem.Direction? = nil) -> TranscriptItem {
        let direction = direction ?? (kind == .reply ? .reply : .sent)
        return TranscriptItem(.orbMessage(OrbMessageItem(direction: direction, kind: kind, state: state, from: OrbRef(from),
                                                         to: OrbRef(to), text: text, requestID: UUID(), chainID: chain)))
    }

    private static func say(_ text: String) -> TranscriptItem { TranscriptItem(.bot(text: text, isStreaming: false)) }

    /// Atlas's chat: a request to the group Lançamento (the Pesquisador orchestrates), the group's answer, then a notice.
    private static func groupLines(_ team: Team, group groupID: UUID) -> [TranscriptItem] {
        let chain = UUID(), request = UUID()
        let group = OrbRef(id: team.researcher.id, name: "Lançamento")
        func line(_ direction: OrbMessageItem.Direction, _ kind: OrbMessageItem.Kind, from: OrbRef, to: OrbRef, _ text: String,
                  fromChat: Bool? = true) -> TranscriptItem {
            TranscriptItem(.orbMessage(OrbMessageItem(direction: direction, kind: kind, state: .replied, from: from, to: to,
                                                      text: text, requestID: request, chainID: chain, fromChat: fromChat)))
        }
        return [
            TranscriptItem(.user(text: "Cria o grupo Lançamento com o Pesquisador e o Revisor e pede os preços dos concorrentes",
                                 attachments: [])),
            TranscriptItem(.event(OrbEvent(kind: .groupCreated, actor: OrbRef(team.atlas), detail: "Lançamento · 3",
                                           groupID: groupID))),
            line(.sent, .ask, from: OrbRef(team.atlas), to: group, "Levantem o preço de três concorrentes no plano anual."),
            say("Pedi ao grupo Lançamento; a resposta chega aqui."),
            line(.reply, .reply, from: group, to: OrbRef(team.atlas), "Todoist US$ 48, Things US$ 50 (uma vez), TickTick US$ 36."),
            say("O grupo respondeu: o TickTick é o mais barato no plano anual."),
            line(.received, .tell, from: OrbRef(team.reviewer), to: OrbRef(team.atlas), "O Things mudou o preço ontem.",
                 fromChat: nil),
        ]
    }

    private static func events(_ team: Team) -> [TranscriptItem] {
        let chain = UUID()
        return [
            TranscriptItem(.user(text: "Monta uma equipe para comparar preços", attachments: [])),
            event(.orbCreated, actor: team.atlas, subject: team.researcher),
            event(.routineCreated, actor: team.atlas, detail: "Checar preços toda segunda"),
            event(.renamed, actor: team.atlas, detail: "Atlas Pro"),
            event(.joinedGroup, subject: team.researcher, detail: "Lançamento"),
            event(.leftGroup, subject: team.reviewer, detail: "Lançamento"),
            event(.groupCreated, detail: "Lançamento · 3"),
            event(.groupRunDone, detail: "Comparar três lojas"),
            event(.groupStopped),
            event(.chainStopped),
            event(.delegationReceived, actor: team.atlas, subject: team.researcher, chain: chain),
        ]
    }

    private static func eventsFolded(_ team: Team) -> [TranscriptItem] {
        [
            TranscriptItem(.user(text: "Cria os três Orbs da equipe", attachments: [])),
            event(.orbCreated, actor: team.atlas, subject: team.researcher),
            event(.orbCreated, actor: team.atlas, subject: team.reviewer),
            event(.orbCreated, actor: team.atlas, subject: team.lia),
            say("Pronto. Agora entram no grupo."),
            event(.joinedGroup, subject: team.researcher, detail: "Lançamento"),
            event(.joinedGroup, subject: team.reviewer, detail: "Lançamento"),
            event(.joinedGroup, subject: team.lia, detail: "Lançamento"),
        ]
    }

    private static func thread(_ team: Team) -> [TranscriptItem] {
        let first = UUID(), second = UUID()
        return [
            TranscriptItem(.user(text: "Pesquisa o preço do Mac mini M5 e confere com o Revisor", attachments: [])),
            message(.ask, .replied, from: team.atlas, to: team.researcher,
                    text: "Pesquisa o preço do Mac mini M5 em três lojas do Brasil.", chain: first),
            message(.reply, .replied, from: team.researcher, to: team.atlas,
                    text: "Encontrei três preços: R$ 5.499, R$ 5.599 e R$ 5.649.", chain: first),
            say("Já tenho três preços. Vou pedir ao Revisor para conferir os impostos."),
            message(.ask, .open, from: team.atlas, to: team.reviewer, text: "Confere se estes preços incluem impostos.", chain: second),
            say("Enquanto isso, a Lia escreve o resumo."),
            message(.ask, .failed, from: team.atlas, to: team.lia, text: "Escreve um resumo de duas linhas.", chain: second),
            say("Sem resposta da Lia; sigo sem ela."),
            message(.ask, .lost, from: team.atlas, to: team.reviewer, text: "Vê se o frete entra no preço.", chain: second),
        ]
    }

    private static func waiting(_ team: Team) -> [TranscriptItem] {
        let chain = UUID()
        return [
            TranscriptItem(.user(text: "Compara os três preços e confere com o Revisor", attachments: [])),
            message(.ask, .open, from: team.atlas, to: team.researcher, text: "Manda o link de cada loja.", chain: chain),
            say("Pedi os links ao Pesquisador. Vou pedir a conferência ao Revisor também."),
            message(.ask, .open, from: team.atlas, to: team.reviewer, text: "Confere os impostos de cada preço.", chain: chain),
        ]
    }

    /// The asker's chat of a fold of three messages with two Orbs (asked, answered, and asked again).
    private static func foldedItems(_ team: Team) -> [TranscriptItem] {
        let chain = UUID()
        return [
            message(.ask, .replied, from: team.atlas, to: team.researcher, text: "Pesquisa o preço do Mac mini M5.", chain: chain),
            message(.reply, .replied, from: team.researcher, to: team.atlas, text: "R$ 5.499 na loja A.", chain: chain),
            message(.ask, .replied, from: team.atlas, to: team.reviewer, text: "Confere o preço da loja A.", chain: chain),
        ]
    }

    // MARK: Screens

    /// A chat of `atlas` with the seeded items. The seed goes in once the chat has read the Orb's conversation from disk (which
    /// would otherwise replace it), as `TranscriptSample` does.
    private static func chat(_ model: AppModel, _ atlas: Bot, _ items: [TranscriptItem]) -> AnyView {
        AnyView(ChatView(botID: atlas.id).task {
            try? await Task.sleep(for: .seconds(1))
            model.seedConversation(Conversation(items: items), for: atlas.id)
        })
    }

    /// The fold of the exchange, closed and open, as the chat draws it (the rows are the chat's own).
    private static func foldedPreview(_ team: Team) -> some View {
        let items = foldedItems(team)
        return VStack(alignment: .leading, spacing: 18) {
            FoldedThread(items: items, summary: { ExchangeSummary(items: items, botID: team.atlas.id, unfolded: $0) },
                         child: { TranscriptRow(item: $0, botID: team.atlas.id, orb: team.atlas.orb).equatable() })
            FoldedThread(items: items, startsUnfolded: true,
                         summary: { ExchangeSummary(items: items, botID: team.atlas.id, unfolded: $0) },
                         child: { TranscriptRow(item: $0, botID: team.atlas.id, orb: team.atlas.orb).equatable() })
        }
        .padding(28)
        .frame(width: 760, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.canvas)
    }

    /// The read-only exchange: the two Orbs at the top, the messages as the Orb's bubbles on the left.
    private static func exchangePreview(_ team: Team) -> some View {
        let chain = UUID()
        let messages = [
            OrbMessageItem(direction: .sent, kind: .ask, state: .replied, from: OrbRef(team.atlas), to: OrbRef(team.researcher),
                           text: "Pesquisa o preço do Mac mini M5 em três lojas do Brasil.", requestID: UUID(), chainID: chain),
            OrbMessageItem(direction: .reply, kind: .reply, state: .replied, from: OrbRef(team.researcher), to: OrbRef(team.atlas),
                           text: "Encontrei três preços: **R$ 5.499**, R$ 5.599 e R$ 5.649. Fontes na página de preços.",
                           requestID: UUID(), chainID: chain),
            OrbMessageItem(direction: .sent, kind: .ask, state: .failed, from: OrbRef(team.atlas), to: OrbRef(team.researcher),
                           text: "Manda também o link da loja A.", requestID: UUID(), chainID: chain),
        ]
        return ExchangeSheet(messages: messages, parties: ExchangeSource.parties(of: messages), onOpenWork: {})
            .frame(width: 560, height: 600)
            .background(Palette.chrome)
    }

    /// The sidebar while Atlas asks Pesquisador for work: Atlas's line says whom it talks to, Pesquisador's says whose request
    /// it works on, and both avatars wear the other's ring.
    private static func setUpTalking(_ model: AppModel, _ team: Team) {
        let atlas = model.live(team.atlas.id)
        atlas.setWork(WorkPhrase.talking(to: team.researcher.name))
        atlas.setPartner(PartnerTint(botID: team.researcher.id, color: team.researcher.orb.color))
        let researcher = model.live(team.researcher.id)
        researcher.setWork(WorkLine(verb: "Lendo", target: "README.md", style: .code, prefix: "Pedido de \(team.atlas.name)"))
        researcher.setPartner(PartnerTint(botID: team.atlas.id, color: team.atlas.orb.color))
    }
}
#endif
