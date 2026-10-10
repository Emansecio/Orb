import SwiftUI

/// What a member of a group is doing right now, as the presence line says it.
enum GroupPresenceState: Equatable, Sendable {
    /// Its text is arriving ("escrevendo").
    case writing
    /// It uses tools, reads, searches ("trabalhando").
    case working
    /// The orchestrator, before its first words, splits the work ("planejando").
    case planning
    /// An approval card of its waits for you ("esperando você").
    case waitingYou
}

/// One member in the presence line.
struct GroupPresenceItem: Equatable {
    var id: UUID
    var name: String
    var orb: OrbConfig
    var state: GroupPresenceState
}

/// The presence line's words, as plain values the tests read.
enum GroupPresence {
    /// The state of a member from what its Orb does now.
    static func state(of activity: OrbActivity, needsYou: Bool, isOrchestrator: Bool) -> GroupPresenceState {
        if needsYou || activity == .waiting { return .waitingYou }
        if activity == .speaking { return .writing }
        if isOrchestrator && activity == .thinking { return .planning }
        return .working
    }

    /// "Pesquisador está escrevendo…", "Pesquisador e Revisor estão trabalhando…", "Pesquisador está esperando você"; nil
    /// when nobody is in a turn. A member waiting for you is named first and alone, whatever the others do.
    static func text(_ items: [GroupPresenceItem]) -> String? {
        guard !items.isEmpty else { return nil }
        let waiting = items.filter { $0.state == .waitingYou }
        if !waiting.isEmpty {
            return "\(names(waiting)) \(waiting.count == 1 ? "está esperando você" : "estão esperando você")"
        }
        if items.count == 1 {
            return "\(items[0].name) \(verb(items[0].state, plural: false))…"
        }
        let states = Set(items.map(\.state))
        if states.count == 1 {
            return "\(names(items)) \(verb(items[0].state, plural: true))…"
        }
        return "\(names(items)) estão trabalhando…"
    }

    /// "A", "A e B", "A, B e C".
    static func names(_ items: [GroupPresenceItem]) -> String {
        names(items.map(\.name))
    }

    static func names(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " e " + names[names.count - 1]
        }
    }

    private static func verb(_ state: GroupPresenceState, plural: Bool) -> String {
        switch state {
        case .writing: plural ? "estão escrevendo" : "está escrevendo"
        case .working: plural ? "estão trabalhando" : "está trabalhando"
        case .planning: plural ? "estão planejando" : "está planejando"
        case .waitingYou: plural ? "estão esperando você" : "está esperando você"
        }
    }

    /// The Orb that stands for a state: a member who writes speaks, one who plans thinks, one who waits waits.
    static func activity(of state: GroupPresenceState) -> OrbActivity {
        switch state {
        case .writing: .speaking
        case .working: .typing
        case .planning: .thinking
        case .waitingYou: .waiting
        }
    }
}

/// The line above the composer: the Orbs in a turn, their small avatars and what they do ("Pesquisador está escrevendo…").
/// Empty when nobody works, so the composer stands alone.
struct GroupPresenceStrip: View {
    let items: [GroupPresenceItem]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let text = GroupPresence.text(items)
        let waiting = items.contains { $0.state == .waitingYou }
        HStack(spacing: 8) {
            ForEach(items.prefix(3), id: \.id) { item in
                BotAvatar(orb: item.orb, size: 24, activity: GroupPresence.activity(of: item.state), paused: false)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            }
            if let text {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(waiting ? Palette.warn : Palette.muted)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                if !waiting {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: text == nil ? 0 : 30, alignment: .leading)
        .padding(.horizontal, 28)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
        .clipped()
        .animation(reduceMotion ? Motion.fade : Motion.enter, value: text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text ?? "")
        .accessibilityHidden(text == nil)
    }
}
