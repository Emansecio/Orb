import SwiftUI

/// The budget of the request a group runs, as the header words it: the counter appears from 80 % and turns warm past it.
/// Pure, so the thresholds are tested.
enum GroupBudgetText {
    /// From this share of the budget the counter's text shows.
    static let textFrom = 0.8

    /// The share spent: the larger of turns and tokens, as a fraction (it can pass 1).
    static func fraction(_ usage: GroupUsage) -> Double {
        let turns = Double(usage.turns) / Double(max(1, usage.turnLimit))
        let tokens = Double(usage.tokens) / Double(max(1, usage.tokenLimit))
        return max(turns, tokens)
    }

    static func showsText(_ fraction: Double) -> Bool { fraction >= textFrom }

    /// The text and the bar go to the warning color only past 80 %.
    static func isWarning(_ fraction: Double) -> Bool { fraction > textFrom }

    /// "3/12 turnos", or the tokens when they are the ones running out: "42 mil/150 mil tokens".
    static func label(_ usage: GroupUsage) -> String {
        let turns = Double(usage.turns) / Double(max(1, usage.turnLimit))
        let tokens = Double(usage.tokens) / Double(max(1, usage.tokenLimit))
        if turns >= tokens { return "\(usage.turns)/\(usage.turnLimit) turnos" }
        return "\(thousands(usage.tokens))/\(thousands(usage.tokenLimit)) tokens"
    }

    /// The full sentence for the tooltip and VoiceOver: "Usados: 3 de 12 turnos · 42 mil de 150 mil tokens".
    static func detail(_ usage: GroupUsage) -> String {
        "Usados: \(usage.turns) de \(usage.turnLimit) turnos · \(thousands(usage.tokens)) de \(thousands(usage.tokenLimit)) tokens"
    }

    /// 950 → "950", 42_300 → "42 mil", 1_500_000 → "1500 mil".
    static func thousands(_ count: Int) -> String {
        count >= 1000 ? "\(count / 1000) mil" : "\(count)"
    }

    /// The bar's length in steps of 5 %: it moves in steps, so a request that spends tokens does not animate per token.
    static func barStep(_ fraction: Double) -> Int { Int((min(max(fraction, 0), 1) * 20).rounded(.down)) }
}

/// The top bar of a group's chat: its Orbs one over the other and "N Orbs". While a request runs it also shows the budget
/// (text from 80 %, a 2 pt bar always), Parar grupo and the panel's button.
struct GroupHeader: View {
    let name: String
    let members: [StackedAvatars.Member]
    let orbCount: Int
    let usage: GroupUsage?
    /// A request is running or waits for the person: Parar grupo is offered.
    let isActive: Bool
    let onStop: () -> Void
    let onPanel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            StackedAvatars(members: members, size: 24)
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Text(orbCount == 1 ? "· 1 Orb" : "· \(orbCount) Orbs")
                .font(.system(size: 12))
                .foregroundStyle(Palette.faint)
                .lineLimit(1)
                .accessibilityIdentifier("group-orb-count")
            Spacer(minLength: 12)
            if let usage {
                BudgetCounter(usage: usage)
                    .transition(.adapted(.opacity, reduceMotion: reduceMotion))
            }
            if isActive {
                Button(action: onStop) {
                    Label("Parar grupo", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .medium))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(GhostStyle(tint: Palette.danger))
                .help("Parar o grupo: cancela os turnos e a fila (⌘.)")
                .transition(.adapted(.opacity, reduceMotion: reduceMotion))
            }
            Button("Painel do grupo", systemImage: "sidebar.right", action: onPanel)
                .labelStyle(.iconOnly)
                .buttonStyle(CircleGhostStyle(side: 28, fontSize: 13))
                .foregroundStyle(Palette.muted)
                .help("Mostrar ou ocultar o painel do grupo (⌥⌘B)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Palette.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        .animation(reduceMotion ? Motion.fade : Motion.content, value: usage != nil)
        .animation(reduceMotion ? Motion.fade : Motion.content, value: isActive)
    }
}

/// "3/12 turnos" and a 2 pt bar, while a request runs. The text is hidden under 80 %; its own tooltip gives the detail.
private struct BudgetCounter: View {
    let usage: GroupUsage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fraction = GroupBudgetText.fraction(usage)
        let warning = GroupBudgetText.isWarning(fraction)
        HStack(spacing: 8) {
            if GroupBudgetText.showsText(fraction) {
                Text(GroupBudgetText.label(usage))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(warning ? Palette.warn : Palette.muted)
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line)
                Capsule()
                    .fill(warning ? Palette.warn : Palette.accentText)
                    .frame(width: 56 * Double(GroupBudgetText.barStep(fraction)) / 20)
            }
            .frame(width: 56, height: 2)
            .animateChanges(of: GroupBudgetText.barStep(fraction))
        }
        .help(GroupBudgetText.detail(usage))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GroupBudgetText.detail(usage))
    }
}
