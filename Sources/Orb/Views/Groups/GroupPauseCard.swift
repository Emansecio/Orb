import SwiftUI

/// The card a group's thread shows when a request reached its budget: Continuar (one more window of turns) or Encerrar. Once
/// the person chose, it leaves a quiet record of the choice.
struct GroupPauseCard: View {
    let pause: GroupPauseItem
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch pause.state {
            case .open: openCard
            case .continued: record("Continuado", symbol: "play.circle")
            case .ended: record("Encerrado", symbol: "stop.circle")
            }
        }
        .frame(maxWidth: .infinity)
        .transition(.adapted(.rise, reduceMotion: reduceMotion))
        .accessibilityIdentifier("group-pause-card")
    }

    private var openCard: some View {
        let more = model.groups.first { $0.id == pause.groupID }?.budget.maxTurns ?? 12
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Palette.warn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("O grupo chegou ao orçamento deste pedido (\(pause.turnLimit) turnos · \(GroupBudgetText.thousands(pause.tokenLimit)) tokens)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Usados: \(pause.turnsUsed) turnos · \(GroupBudgetText.thousands(pause.tokensUsed)) tokens")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                ActionRow {
                    Button("Encerrar") { model.stopGroup(pause.groupID) }
                        .buttonStyle(GhostStyle())
                        .hangsOnLeadingEdge()
                } trailing: {
                    Button("Continuar (+\(more) turnos)") { model.continueRun(pause.groupID) }
                        .buttonStyle(PrimaryPillStyle())
                }
                .padding(.top, Spacing.s)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.cardPadding)
        .frame(maxWidth: 680, alignment: .leading)
        .card(radius: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("O grupo pausou: \(pause.turnsUsed) de \(pause.turnLimit) turnos. Continuar ou encerrar.")
    }

    private func record(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("group-pause-record")
    }
}
