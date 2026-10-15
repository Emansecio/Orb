#if DEBUG || ORB_DEV_TOOLS
import SwiftUI

/// `--snapshot` modes of the creation card: `orb-proposal` (open), `orb-proposal-editing`, `orb-proposal-created`,
/// `orb-proposal-dismissed`, `orb-proposal-narrow` (520 pt wide) and `orb-created-sidebar` (the new row and the "Criado por" line).
@MainActor
enum CreationSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
        guard let creator = model.bots.first else { return nil }
        switch screen {
        case "orb-proposal": return page(card(creator, long: true), model: model)
        case "orb-proposal-editing": return page(card(creator, long: true, editing: true), model: model, height: 980)
        case "orb-proposal-created": return page(card(creator, decision: .once, long: false, event: true), model: model, height: 260)
        case "orb-proposal-dismissed": return page(card(creator, decision: .deny, long: false), model: model, height: 220)
        case "orb-proposal-narrow": return page(card(creator, long: true), model: model, width: 520, height: 520)
        case "orb-created-sidebar": return sidebar(creator, model: model)
        default: return nil
        }
    }

    /// The proposal the snapshots show: a researcher that can use the terminal and the web (the creator has no Mac control).
    static func sample(from creator: Bot, long: Bool) -> OrbProposal {
        let instructions = long
            ? "Pesquise na web quando eu pedir, compare as fontes e devolva um resumo curto com os links.\nGuarde o que achou em notas na sua pasta.\nSe a pergunta for vaga, pergunte antes de sair procurando. Nunca invente uma fonte."
            : "Pesquise e resuma."
        return OrbProposal(
            creator: OrbRef(creator), name: "Pesquisador", role: "Pesquisa na web e resume o que achou", instructions: instructions,
            capabilities: [.browser, .terminal], mode: .ask, modeCeiling: .auto,
            orb: OrbConfig(color: "menta", eyes: "felizes", mouth: "sorriso", cheeks: "sardas", accessories: ["fones"]),
            reason: "Para cuidar das pesquisas enquanto eu organizo seus arquivos.", creatorCapabilities: [.terminal, .browser])
    }

    private static func request(_ proposal: OrbProposal, decision: ApprovalDecision? = nil) -> ApprovalRequest {
        ApprovalRequest(toolName: OrbProposeTool.name, title: "\(proposal.creator.name) quer criar um Orb", command: proposal.name,
                        reason: proposal.reason ?? "", decision: decision, proposal: proposal)
    }

    private static func card(_ creator: Bot, decision: ApprovalDecision? = nil, long: Bool, editing: Bool = false,
                             event: Bool = false) -> some View {
        let proposal = sample(from: creator, long: long)
        return VStack(alignment: .leading, spacing: 12) {
            OrbProposalCard(request: request(proposal, decision: decision), proposal: proposal, botID: creator.id, startsEditing: editing)
            if event {
                EventLineView(event: OrbEvent(kind: .orbCreated, actor: OrbRef(creator), subject: OrbRef(id: UUID(), name: proposal.name)))
            }
        }
    }

    private static func page(_ content: some View, model: AppModel, width: CGFloat = 760, height: CGFloat? = nil) -> AnyView {
        AnyView(content
            .frame(width: width - 48, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.canvas))
    }

    /// The sidebar with the Orb that was just created, and its panel with "Criado por Atlas".
    private static func sidebar(_ creator: Bot, model: AppModel) -> AnyView {
        var child = Bot(name: "Pesquisador", role: "Pesquisa na web e resume o que achou",
                        orb: OrbConfig(color: "menta", eyes: "felizes", mouth: "sorriso", cheeks: "sardas", accessories: ["fones"]))
        child.createdBy = creator.id
        child.createdByName = creator.name
        child.createdAt = .now
        model.bots.append(child)
        model.selection = .bot(child.id)
        return AnyView(HStack(spacing: 0) {
            SidebarView().frame(width: 280)
            Divider()
            BotInspector(botID: child.id).frame(width: 360)
        }
        .background(Palette.chrome))
    }
}
#endif
