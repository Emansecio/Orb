import SwiftUI

/// A line of the chat for a message between Orbs. A plain stand-in: the package that draws the exchange lines replaces it.
struct OrbMessageRow: View {
    let message: OrbMessageItem
    /// The Orb whose chat shows the line.
    let botID: UUID

    var body: some View {
        Text(message.to.map { "\(message.from.name) → \($0.name): \(message.text)" } ?? "\(message.from.name): \(message.text)")
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("orb-message-row")
    }
}
