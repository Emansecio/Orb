import SwiftUI

/// A line of a chat for something that happened between Orbs or to them ("Atlas criou o Pesquisador"): a small symbol for
/// its kind and the sentence, centred, in the muted ink of the app's notices. The line that says an Orb asked this one for
/// help also has the asker's mini avatar, and opens the exchange (`ExchangeSheet`) when it is chosen.
struct EventLineView: View {
    @Environment(AppModel.self) private var model
    let event: OrbEvent
    @State private var showsExchange = false

    var body: some View {
        if event.kind == .delegationReceived, let asker = event.actor, let chain = event.chainID {
            Button {
                showsExchange = true
            } label: {
                HStack(spacing: 6) {
                    MiniOrb(botID: asker.id)
                    Text(event.sentence)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Ver a troca")
            .accessibilityLabel(event.sentence)
            .accessibilityHint("Abre a troca, somente leitura")
            .accessibilityIdentifier("event-line")
            .sheet(isPresented: $showsExchange) {
                let found = ExchangeSource.messages(chain: chain, of: asker.id, in: model)
                ExchangeSheet(messages: found, parties: ExchangeSource.parties(of: found))
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(for: event.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)
                Text(event.sentence)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("event-line")
        }
    }

    /// The symbol of a kind of line.
    static func symbol(for kind: OrbEvent.Kind) -> String {
        switch kind {
        case .orbCreated: "sparkles"
        case .joinedGroup, .leftGroup, .groupCreated: "person.2"
        case .routineCreated: "clock.arrow.circlepath"
        case .renamed: "pencil"
        case .chainStopped, .groupStopped: "stop.circle"
        case .groupRunDone: "checkmark.circle"
        case .delegationReceived: "bubble.left"
        case .unknown: "info.circle"
        }
    }
}

/// A run of events of one kind, folded into one line ("Atlas criou 3 Orbs: A, B e C") that unfolds into the lines it holds.
struct EventsSummary: View {
    let kind: OrbEvent.Kind
    let items: [TranscriptItem]
    let unfolded: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: EventLineView.symbol(for: kind))
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            Text(TranscriptFolding.eventsTitle(kind, items))
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
            // The chevron turns its sign rather than turning: nothing rotates in a row that folds under Reduce Motion.
            Image(systemName: unfolded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.faint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("event-line-folded")
    }
}
