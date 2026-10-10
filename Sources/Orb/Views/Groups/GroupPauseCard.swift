import SwiftUI

/// The card a group's thread shows when a request reached its budget (Continuar / Encerrar). A plain stand-in: the group
/// screens replace it.
struct GroupPauseCard: View {
    let pause: GroupPauseItem

    var body: some View {
        Text("O grupo chegou ao orçamento deste pedido (\(pause.turnsUsed) de \(pause.turnLimit) turnos)")
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("group-pause-card")
    }
}
