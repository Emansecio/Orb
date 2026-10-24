import SwiftUI

/// What is left of the card a group's thread showed when a request reached its budget: groups have no budget anymore, so a
/// thread saved with one shows a quiet record of how it ended.
struct GroupPauseCard: View {
    let pause: GroupPauseItem

    var body: some View {
        Label(pause.state == .continued ? "Continuado" : "Encerrado",
              systemImage: pause.state == .continued ? "play.circle" : "stop.circle")
            .font(Typography.label)
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("group-pause-record")
    }
}
