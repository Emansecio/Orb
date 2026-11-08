import SwiftUI

/// A line of marks at the chat's right edge, one per message of the reader: a click goes to it, the pointer says which it is. It
/// reads the transcript itself, so a new reply does not draw it again, and it only shows where it does not cover the text.
struct RequestRail: View {
    let transcript: OrbTranscript
    let go: (UUID) -> Void
    @State private var isWide = false

    private static let minimum = 2
    private static let limit = 40
    /// The chat's column and the room the rail takes beside it.
    private static let wide = TranscriptLayout.column + 96

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onGeometryChange(for: Bool.self) { $0.size.width >= Self.wide } action: { isWide = $0 }
            .overlay(alignment: .trailing) {
                if isWide, transcript.requests.count >= Self.minimum { rail }
            }
    }

    private var rail: some View {
        VStack(alignment: .trailing, spacing: 2) {
            // The latest request is the current one (the chat does not track what is scrolled into view): it stands in ink.
            let current = transcript.requests.last?.id
            ForEach(RequestMark.thinned(transcript.requests, limit: Self.limit)) { mark in
                RequestRailMark(title: mark.title, isCurrent: mark.id == current) { go(mark.id) }
            }
        }
        .padding(.trailing, Spacing.l)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pedidos da conversa")
    }
}

private struct RequestRailMark: View {
    let title: String
    var isCurrent = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(isHovering || isCurrent ? Palette.ink : Palette.muted)
                .frame(width: isHovering ? 18 : 14, height: 2)
                .frame(width: 22, height: 9, alignment: .trailing)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hover(isHovering), value: isHovering)
        .clickablePointer()
        .help(title)
        .accessibilityLabel("Ir para o pedido: \(title)")
    }
}

/// The plan of the task as a card at the end of the chat, while some step of it is open: it reads the plan itself, so a step
/// marked done changes in place and no row is added. Finished, the plan stays in the chat as the line of its event.
struct PlanCard: View {
    let transcript: OrbTranscript
    @State private var isFolded = false

    var body: some View {
        if let plan = transcript.plan, plan.steps.count > 1 {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Button { isFolded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checklist")
                            .font(Typography.small)
                            .foregroundStyle(Palette.muted)
                            .accessibilityHidden(true)
                        Text(TaskPlanRing.title(plan))
                            .font(Typography.label.weight(.medium).monospacedDigit())
                            .foregroundStyle(Palette.secondary)
                        Spacer(minLength: 8)
                        Image(systemName: isFolded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .clickablePointer()
                .accessibilityLabel("Plano, " + TaskPlanRing.summary(plan))
                .accessibilityHint(isFolded ? "Mostra as etapas" : "Oculta as etapas")
                if !isFolded { TaskPlanSteps(plan: plan, showsGoal: false) }
            }
            .padding(Spacing.m)
            .frame(maxWidth: cardWidth, alignment: .leading)
            .card(radius: Radius.small)
            .padding(.leading, gutter)
        }
    }
}

/// Under the last reply of a turn: what it changed in the app, with a way there, and the pages it read.
struct TurnTrailView: View {
    @Environment(AppModel.self) private var model
    let trail: TurnTrail
    let botID: UUID
    /// Routines the line pointed at that are gone by now (the Orb or the user deleted them).
    @State private var goneRoutines: Set<String> = []

    private static let shownSources = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(trail.changes.enumerated()), id: \.offset) { _, change in
                changeLine(change)
            }
            if !trail.sources.isEmpty { sources }
        }
        .alignedWithReplyText()
    }

    private func changeLine(_ change: TurnTrail.Change) -> some View {
        let (symbol, words, action): (String, String, String?) = switch change {
        case .routine(let name): ("clock.arrow.circlepath", "Rotina criada: \(name)", "Abrir")
        case .memory(let fact): ("brain", "Guardado na memória: \(fact)", "Ver")
        case .group(let name): ("person.3", "Grupo criado: \(name)", nil)
        }
        return HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.faint)
                .accessibilityHidden(true)
            Text(words)
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            if case .routine(let name) = change, goneRoutines.contains(name) {
                Text("(apagada)").foregroundStyle(Palette.warn)
            } else if let action {
                Button(action) { open(change) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accentText)
                    .clickablePointer()
                    .accessibilityLabel("\(action): \(words)")
            }
        }
        .font(Typography.small)
    }

    private func open(_ change: TurnTrail.Change) {
        switch change {
        case .routine(let name):
            // Focus this Orb's routine of that name; one deleted since says so instead of opening the page on nothing.
            guard let routine = model.routines.first(where: { $0.botID == botID && $0.name.sameName(as: name) }) else {
                goneRoutines.insert(name)
                return
            }
            model.inicioRoutineFocus = routine.id
            model.selection = .routines
        case .memory: model.showMemory(of: botID)
        case .group: break
        }
    }

    private var sources: some View {
        WrappingLayout(spacing: 6) {
            Text("Fontes")
                .font(Typography.small)
                .foregroundStyle(Palette.faint)
                .padding(.vertical, 2)
            ForEach(trail.sources.prefix(Self.shownSources), id: \.self) { address in
                SourceChip(address: address)
            }
            if trail.sources.count > Self.shownSources {
                Text("+\(trail.sources.count - Self.shownSources)")
                    .font(Typography.small)
                    .foregroundStyle(Palette.faint)
                    .padding(.vertical, 2)
                    .help(trail.sources.dropFirst(Self.shownSources).joined(separator: "\n"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fontes")
    }
}

/// A page the turn read: its site, and its whole address under the pointer.
private struct SourceChip: View {
    let address: String
    @State private var isHovering = false

    var body: some View {
        Button {
            if TurnTrail.host(of: address) != nil, let url = URL(string: address) { NSWorkspace.shared.open(url) }
        } label: {
            Text(TurnTrail.host(of: address) ?? address)
                .font(Typography.small)
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .hoverFill(isHovering, in: .capsule, color: Palette.ghostSelected, resting: Palette.ghostHover)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .clickablePointer()
        .help(Tip.openSource + ": " + address)
        .accessibilityLabel("Abrir \(TurnTrail.host(of: address) ?? address) no navegador")
    }
}
