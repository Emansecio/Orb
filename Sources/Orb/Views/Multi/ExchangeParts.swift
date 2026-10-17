import SwiftUI

/// The small pieces of an exchange line: an Orb's still avatar at 16 pt, the two of them joined by an arrow, and the messages
/// an exchange holds as the chat keeps them.

/// An Orb's avatar in an exchange line (16 pt, still: its look, not its motion).
struct MiniOrb: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    var size: CGFloat = 16

    var body: some View {
        BotAvatar(orb: model.live(botID).look.orb, size: size, animated: false)
            .accessibilityHidden(true)
    }
}

/// Who talks to whom: two mini avatars with an arrow between them ("Atlas → Revisor").
struct ExchangeGlyph: View {
    let from: UUID
    let to: UUID

    var body: some View {
        HStack(spacing: 4) {
            MiniOrb(botID: from)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Palette.hint)
            MiniOrb(botID: to)
        }
        .accessibilityHidden(true)
    }
}

/// The messages of one exchange, read from the chat of the Orb that holds them (its asks and their replies).
enum ExchangeSource {
    /// The messages of the exchange `chain` in `botID`'s chat, in order. Empty for an Orb that no longer exists.
    @MainActor
    static func messages(chain: UUID, of botID: UUID, in model: AppModel) -> [OrbMessageItem] {
        guard model.bot(botID) != nil else { return [] }
        return model.orbTranscript(botID).items.compactMap { item in
            if case .orbMessage(let message) = item.kind, message.chainID == chain { return message }
            return nil
        }
    }

    /// The Orbs of an exchange with no message to read them from (the asker was deleted or began another conversation): the two
    /// the event line names.
    static func parties(of messages: [OrbMessageItem], event: OrbEvent) -> [OrbRef] {
        let found = parties(of: messages)
        return found.isEmpty ? [event.actor, event.subject].compactMap { $0 } : found
    }

    /// The Orbs an exchange is between, each once, in the order they first speak.
    static func parties(of messages: [OrbMessageItem]) -> [OrbRef] {
        var parties: [OrbRef] = []
        for message in messages {
            for ref in [message.from, message.to].compactMap({ $0 }) where !parties.contains(where: { $0.id == ref.id }) {
                parties.append(ref)
            }
        }
        return parties
    }
}
