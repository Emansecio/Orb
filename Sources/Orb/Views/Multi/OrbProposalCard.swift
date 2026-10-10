import SwiftUI

/// The card an Orb's proposal for a new Orb opens (Criar / Editar antes / Não criar). A plain stand-in: the package that
/// builds the card replaces it, and `ApprovalCard` shows it for a request with a proposal.
struct OrbProposalCard: View {
    let request: ApprovalRequest
    let proposal: OrbProposal
    /// The Orb that proposes it, whose chat shows the card.
    let botID: UUID

    var body: some View {
        Text("\(proposal.creator.name) quer criar o Orb \(proposal.name)")
            .font(.system(size: 13))
            .foregroundStyle(Palette.secondary)
            .accessibilityIdentifier("orb-proposal-card")
    }
}
