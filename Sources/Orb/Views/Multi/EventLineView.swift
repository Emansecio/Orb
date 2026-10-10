import SwiftUI

/// A line of the chat for something that happened between Orbs ("Atlas criou o Pesquisador"). A plain stand-in: the package
/// that draws the exchange lines replaces it.
struct EventLineView: View {
    let event: OrbEvent

    var body: some View {
        Text(event.sentence)
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("event-line")
    }
}
