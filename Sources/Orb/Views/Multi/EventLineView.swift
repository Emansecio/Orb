import SwiftUI

/// A line of a chat for something that happened between Orbs or to them ("Atlas criou o Pesquisador"): a small symbol for
/// its kind and the sentence, on the left edge of the replies' text (the chat gives the inset), in the muted ink of the app's notices. The line that says an Orb asked this one for
/// help also has the asker's mini avatar, and opens the exchange (`ExchangeSheet`) when it is chosen.
struct EventLineView: View {
    @Environment(AppModel.self) private var model
    let event: OrbEvent
    /// Centred in a group's thread, where notices sit centred among the bubbles; on the replies' left edge in an Orb's chat.
    var centered = false
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
                        .multilineTextAlignment(centered ? .center : .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                }
                .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
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
        } else if event.kind == .routineRun {
            RoutineRunLine(event: event)
        } else {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(for: event.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)
                Text(event.sentence)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(centered ? .center : .leading)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("event-line")
        }
    }

    /// The symbol of a kind of line.
    static func symbol(for kind: OrbEvent.Kind) -> String {
        switch kind {
        case .orbCreated: "sparkles"
        case .joinedGroup, .leftGroup, .groupCreated: "person.2"
        case .routineCreated, .routineRun: "clock.arrow.circlepath"
        case .renamed: "pencil"
        case .chainStopped, .groupStopped: "stop.circle"
        case .tellFailed: "exclamationmark.circle"
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
        if kind == .routineRun, case .event(let last) = items[items.count - 1].kind {
            // The routine's runs: the count and the last one's line (its note while folded), on the left like each run.
            RoutineRunLine(event: last, title: TranscriptFolding.eventsTitle(kind, items), mark: Self.marked(items) ?? last.outcome,
                           showsNote: !unfolded, chevron: unfolded ? "chevron.down" : "chevron.right")
        } else {
            folded
        }
    }

    /// The outcome of the last run that failed or needs you, which the folded line keeps showing. A plain loop: the chain of
    /// closures it replaces took the CI's compiler too long to type-check.
    private static func marked(_ items: [TranscriptItem]) -> OrbEvent.Outcome? {
        for item in items.reversed() {
            guard case .event(let event) = item.kind, let outcome = event.outcome else { continue }
            if outcome == .failed || outcome == .attention { return outcome }
        }
        return nil
    }

    private var folded: some View {
        HStack(spacing: 6) {
            Image(systemName: EventLineView.symbol(for: kind))
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            Text(TranscriptFolding.eventsTitle(kind, items))
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.leading)
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

/// A routine's run in the chat, on the left: a mark (gray for an ordinary run, orange or red when it needs you, green for a
/// goal reached), what happened, the report's first line in two lines at most, and "Abrir relatório". Folded, `title`
/// counts the runs and there is no button: the line itself unfolds.
struct RoutineRunLine: View {
    @Environment(AppModel.self) private var model
    let event: OrbEvent
    var title: String?
    var mark: OrbEvent.Outcome?
    var showsNote = true
    var chevron: String?

    var body: some View {
        let outcome = mark ?? event.outcome
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: outcome.symbol)
                .font(.system(size: 11))
                .foregroundStyle(outcome.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title ?? event.headline).foregroundStyle(Palette.muted)
                    if let chevron {
                        Image(systemName: chevron)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.faint)
                    }
                }
                if showsNote, let note = event.note, !note.isEmpty {
                    Text(note)
                        .foregroundStyle(Palette.faint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if chevron == nil, let url = reportURL {
                    Button("Abrir relatório") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link)
                        .help(Tip.openReportFile)
                }
            }
        }
        .font(.system(size: 12))
        .multilineTextAlignment(.leading)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("event-line")
    }

    private var reportURL: URL? {
        let botID = event.actor?.id ?? model.routines.first { $0.name == event.detail }?.botID // a run told as text has no actor
        guard let file = event.file, let bot = botID.flatMap({ model.bot($0) }) else { return nil }
        return bot.workingURL.appendingPathComponent(file)
    }
}

extension Optional<OrbEvent.Outcome> {
    var symbol: String {
        switch self {
        case .failed: "xmark.circle.fill"
        case .attention: "flag.fill"
        case .goalReached: "checkmark.seal.fill"
        case .finished, nil: "clock.arrow.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .failed: Palette.danger
        case .attention: Palette.warn
        case .goalReached: Palette.ok
        case .finished, nil: Palette.muted
        }
    }
}
