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
    @State private var showsPlan = false

    var body: some View {
        if event.kind == .delegationReceived, let asker = event.actor, let chain = event.chainID {
            Button {
                showsExchange = true
            } label: {
                HStack(spacing: 6) {
                    MiniOrb(botID: asker.id)
                    Text(event.sentence)
                        .font(Typography.label)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(centered ? .center : .leading)
                    EventChevron(name: "chevron.right")
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
                let found = ExchangeSource.messages(chain: chain, request: event.requestID, of: asker.id, in: model)
                ExchangeSheet(messages: found, parties: ExchangeSource.parties(of: found, event: event))
            }
        } else if event.kind == .routineRun {
            RoutineRunLine(event: event)
        } else if event.kind == .planDone, let plan = event.plan {
            // The steps open in the same popover the plan's ring uses while the plan is open.
            Button {
                showsPlan.toggle()
            } label: {
                line(opens: true)
            }
            .buttonStyle(.plain)
            .help("Ver as etapas")
            .popover(isPresented: $showsPlan, arrowEdge: .bottom) {
                TaskPlanSteps(plan: plan)
                    .padding(Spacing.m)
                    .frame(width: 320, alignment: .leading)
            }
            .accessibilityLabel(event.sentence)
            .accessibilityHint("Mostra as etapas")
            .accessibilityIdentifier("event-line")
        } else if let group = openableGroup {
            Button {
                model.selection = .group(group)
            } label: {
                line(opens: true)
            }
            .buttonStyle(.plain)
            .help("Abrir o grupo")
            .accessibilityLabel(event.sentence)
            .accessibilityHint("Abre o grupo")
            .accessibilityIdentifier("event-line")
        } else {
            line(opens: false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("event-line")
        }
    }

    /// In an Orb's chat, the line about a group that still exists opens it.
    private var openableGroup: UUID? {
        guard !centered, [.groupCreated, .joinedGroup, .groupWorked].contains(event.kind), let id = event.groupID,
              model.group(id) != nil else { return nil }
        return id
    }

    /// The symbol and the sentence; with the chevron of the lines that open something.
    private func line(opens: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Self.symbol(for: event.kind))
                .font(Typography.small)
                .foregroundStyle(Palette.muted)
                // One width for every symbol, so the sentences start on the same column.
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(event.sentence)
                .font(Typography.label)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(centered ? .center : .leading)
                .contentTransition(.opacity)
            if opens {
                EventChevron(name: "chevron.right")
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .contentShape(.rect)
    }

    /// The symbol of a kind of line.
    static func symbol(for kind: OrbEvent.Kind) -> String {
        switch kind {
        case .orbCreated: "sparkles"
        case .joinedGroup, .leftGroup, .groupCreated, .groupWorked: "person.2"
        case .routineCreated, .routineRun: "clock.arrow.circlepath"
        case .renamed: "pencil"
        case .chainStopped, .groupStopped: "stop.circle"
        case .tellFailed: "exclamationmark.circle"
        case .groupRunDone: "checkmark.circle"
        case .delegationReceived: "bubble.left"
        case .planDone: "checklist"
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
                .font(Typography.small)
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            Text(TranscriptFolding.eventsTitle(kind, items))
                .font(Typography.label)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.leading)
                .contentTransition(.opacity)
            // The chevron turns its sign rather than turning: nothing rotates in a row that folds under Reduce Motion.
            EventChevron(name: unfolded ? "chevron.down" : "chevron.right")
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
    /// The report was asked for and is gone (deleted, or in a folder that no longer exists).
    @State private var reportIsMissing = false

    var body: some View {
        let outcome = mark ?? event.outcome
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: outcome.symbol)
                .font(Typography.small)
                .foregroundStyle(outcome.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title ?? event.headline).foregroundStyle(Palette.muted)
                    if let chevron {
                        EventChevron(name: chevron)
                    }
                }
                if showsNote, let note = event.note, !note.isEmpty {
                    Text(note)
                        .foregroundStyle(Palette.faint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if chevron == nil, event.file != nil {
                    if reportIsMissing {
                        Text("O arquivo do relatório não está mais lá.").foregroundStyle(Palette.warn)
                    } else {
                        Button("Abrir relatório", action: openReport)
                            .buttonStyle(.link)
                            .help(Tip.openReportFile)
                    }
                }
            }
        }
        .font(Typography.label)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: cardWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("event-line")
    }

    /// Opens the report if the file is still there, else says so. The run (by id) knows the folder it was written in; a line
    /// without a run falls back to the Orb's folder. A routine found by name only counts when it is the only one with it:
    /// another Orb's routine of the same name is not this run's.
    private func openReport() {
        let run = model.routines.lazy.flatMap(\.runs).first { $0.id == event.runID }
        let named = model.routines.filter { $0.name == event.detail }
        let botID = event.actor?.id ?? (named.count == 1 ? named[0].botID : nil) // a run told as text has no actor
        let orbFolder = botID.flatMap { model.bot($0) }?.workingURL
        guard let file = event.file else { return }
        let probe = run ?? RoutineRun(date: .now, succeeded: true, summary: "", reportFile: file)
        Task {
            let url = await Task.detached { probe.existingReportFile(inOrbFolder: orbFolder) }.value
            if let url { NSWorkspace.shared.open(url) } else { reportIsMissing = true }
        }
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

/// A routine's run in its Orb's chat, read like a message: which run, when, and its whole report. A run the routine no
/// longer keeps shows the line saved in the chat.
struct RoutineRunMessage: View {
    @Environment(AppModel.self) private var model
    let event: OrbEvent
    let date: Date

    var body: some View {
        let run = model.routines.lazy.flatMap(\.runs).first { $0.id == event.runID }
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("\(event.detail ?? "Rotina") · \(RoutineText.stamp(date))", systemImage: "clock.arrow.circlepath")
                .font(Typography.small)
                .foregroundStyle(event.outcome == .failed ? Palette.danger : Palette.muted)
            MarkdownChunk(source: run?.report ?? run?.summary ?? event.note ?? event.sentence).equatable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The small chevron at the end of the lines that open or fold something.
private struct EventChevron: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Palette.faint)
    }
}
