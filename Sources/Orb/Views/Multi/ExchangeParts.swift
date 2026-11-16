import SwiftUI

/// The small pieces of an exchange line: an Orb's still avatar at 16 pt, the two of them joined by an arrow, and the messages
/// an exchange holds as the chat keeps them.

/// An Orb's avatar in an exchange line (16 pt, still: its look, not its motion).
struct MiniOrb: View {
    @Environment(AppModel.self) private var model
    let botID: UUID

    var body: some View {
        BotAvatar(orb: model.live(botID).look.orb, size: 16, animated: false)
            .accessibilityHidden(true)
    }
}

/// Who talks to whom: the mini avatars of each side with an arrow between them ("Atlas → Revisor"); a group's side stacks its
/// members, up to three. `awaits`: the answer has not come, and a dot breathes in the arrow's place (Core Animation, paused
/// out of view; still under Reduce Motion).
struct ExchangeGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let from: [UUID]
    let to: [UUID]
    var awaits = false

    var body: some View {
        HStack(spacing: 4) {
            MiniOrbs(ids: from)
            Group {
                if awaits {
                    BreathingDot(color: Palette.accentText, breathes: !reduceMotion)
                        .frame(width: 5, height: 5)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.hint)
                }
            }
            .frame(width: 10) // the dot and the arrow take the same room: the line does not move when the answer comes
            MiniOrbs(ids: to)
        }
        .accessibilityHidden(true)
    }
}

/// Up to three mini avatars, 6 pt over each other.
struct MiniOrbs: View {
    let ids: [UUID]

    var body: some View {
        HStack(spacing: -6) {
            ForEach(ids.prefix(3), id: \.self) { MiniOrb(botID: $0) }
        }
    }
}

/// Under a request this chat's Orb is waiting on: what the Orb asked does right now and for how long ("Revisor: Lendo
/// README.md · 45 s"), and "Ver o trabalho". Only while that Orb works on this very request; nothing while it waits its turn.
struct ExchangeWorkLine: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let requestID: UUID
    let openWork: () -> Void

    var body: some View {
        let live = model.live(botID)
        // `servingRequest` is not observed; the turn starting or ending (`workingSince`) is, and draws this line again.
        let since = live.workingSince
        if since != nil, model.sessions[botID]?.servingRequest == requestID {
            HStack(spacing: Spacing.s) {
                // A second's tick only while the line is on screen (the list drops it out of view).
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let text = Self.text(name: live.look.name, phrase: live.shownWork?.phrase,
                                         elapsed: since.map { ElapsedFormat.working(since: $0, now: context.date) })
                    Text(text)
                        .font(Typography.small)
                        .foregroundStyle(Palette.faint)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Ver o trabalho", action: openWork)
                    .buttonStyle(GhostStyle(tint: nil))
                    .help("Mostra o que \(live.look.name) está fazendo, só para ler")
            }
        }
    }

    /// "Revisor: Lendo README.md · 45 s"; "Revisor: Trabalhando…" before its first step; no time under a second.
    static func text(name: String, phrase: String?, elapsed: String?) -> String {
        let doing = "\(name): \(phrase ?? "Trabalhando…")"
        guard let elapsed, !elapsed.isEmpty else { return doing }
        return "\(doing) · \(elapsed)"
    }
}

/// The messages of one exchange, read from the chat of the Orb that holds them (its asks and their replies).
enum ExchangeSource {
    /// The messages of the exchange `chain` in `botID`'s chat, in order. Empty for an Orb that no longer exists. `request`: only
    /// that request and its reply (a woken Orb keeps the chain, so the chain alone also holds the other Orbs' requests).
    @MainActor
    static func messages(chain: UUID, request: UUID? = nil, of botID: UUID, in model: AppModel) -> [OrbMessageItem] {
        guard model.bot(botID) != nil else { return [] }
        return model.orbTranscript(botID).items.compactMap { item in
            if case .orbMessage(let message) = item.kind, message.chainID == chain, request == nil || message.requestID == request {
                return message
            }
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
