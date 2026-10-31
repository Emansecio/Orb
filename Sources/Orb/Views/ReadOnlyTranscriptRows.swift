import SwiftUI

/// The running request's card: the same one in the chat and in a routine's conversation.
struct ActivityCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cardSpacing, content: content)
            .padding(.vertical, Spacing.catalogCardPadding)
            .padding(.trailing, Spacing.catalogCardPadding)
            .background {
                RoundedRectangle(cornerRadius: Radius.card)
                    .fill(Palette.surface)
                    .padding(.leading, gutter - 12)
            }
    }
}

/// Skills proposed together, on one quiet line.
struct ProposalsSummary: View {
    let count: Int
    let unfolded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars").font(Typography.small).frame(width: 14)
            Text("\(count) melhorias propostas").font(Typography.label)
            FoldChevron(isOpen: unfolded, size: 9)
        }
        .foregroundStyle(Palette.secondary)
    }
}

/// A conversation to read, folded as the chat folds it (`TranscriptFolding`): finished work on one line, the running
/// request in its card. Nothing here is edited, searched or entered, so it needs none of the chat's row state.
struct ReadOnlyTranscriptRows: View {
    let items: [TranscriptItem]
    let isLive: Bool
    let botID: UUID
    let orb: OrbConfig
    @State private var openRuns: Set<UUID> = []
    /// Step disclosures have their own state: the first step and its outer work row share an item id.
    @State private var openSteps: Set<UUID> = []

    var body: some View {
        ForEach(TranscriptFolding.rows(for: items, liveTail: isLive)) { row($0) }
    }

    private func row(_ row: TranscriptRowModel) -> AnyView {
        switch row {
        case .single(let item):
            AnyView(plain(item))
        case .events(let kind, let items):
            AnyView(FoldedThread(items: items, summary: { EventsSummary(kind: kind, items: items, unfolded: $0).alignedWithReplyText() },
                                 child: { plain($0) }))
        case .exchange(let items):
            AnyView(FoldedThread(items: items, summary: { ExchangeSummary(items: items, botID: botID, unfolded: $0).alignedWithReplyText() },
                                 child: { plain($0) }))
        case .proposals(let items):
            AnyView(FoldedThread(items: items, summary: { ProposalsSummary(count: items.count, unfolded: $0).alignedWithReplyText() },
                                 child: { plain($0) }))
        case .tools(let items):
            AnyView(ToolGroupRow(items: items, botID: botID, orb: orb, isOpen: openRuns.contains(row.id)) { toggleRun(row.id) })
        case .work(let items, let seconds, let outcome):
            AnyView(work(items, seconds: seconds, outcome: outcome, owner: row.id,
                         steps: TranscriptFolding.activityRows(for: items)))
        case .activity(let items):
            AnyView(activity(items, owner: row.id))
        }
    }

    private func activity(_ items: [TranscriptItem], owner: UUID) -> some View {
        let parts = TranscriptFolding.activityParts(TranscriptFolding.activityRows(for: items))
        return ActivityCard {
            if !parts.earlier.isEmpty {
                work(parts.earlier.flatMap(\.items), seconds: nil, outcome: .answered, owner: owner, steps: parts.earlier)
            }
            steps(parts.current, owner: owner)
        }
    }

    private func work(_ items: [TranscriptItem], seconds: Int?, outcome: WorkOutcome, owner: UUID,
                      steps rows: [TranscriptRowModel]) -> some View {
        WorkGroupRow(items: items, seconds: seconds, outcome: outcome, isOpen: openRuns.contains(owner)) {
            toggleRun(owner)
        } content: {
            steps(rows, owner: owner)
        }
    }

    private func steps(_ rows: [TranscriptRowModel], owner: UUID) -> some View {
        ForEach(rows) { step in
            if case .tools(let actions) = step {
                ToolGroupRow(items: actions, botID: botID, orb: orb, isOpen: openSteps.contains(step.id), isStep: true) {
                    if openSteps.remove(step.id) == nil {
                        openSteps.insert(step.id)
                        // Keep the outer disclosure open when this request ends while its details are being read.
                        openRuns.insert(owner)
                    }
                }
            } else {
                row(step)
            }
        }
    }

    private func toggleRun(_ id: UUID) {
        if openRuns.remove(id) == nil { openRuns.insert(id) }
    }

    private func plain(_ item: TranscriptItem) -> some View {
        TranscriptRow(item: item, botID: botID, orb: orb).equatable()
    }
}
