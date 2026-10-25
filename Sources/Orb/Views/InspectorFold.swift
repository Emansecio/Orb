import SwiftUI

// The pieces the General tab folds with ("Modelo e permissões", "Pode usar", "Navegar na web"): a row that opens and closes, its
// chevron, and the motion of what comes and goes. Which parts are open lives in `InspectorFold` (InspectorSupport.swift).

enum FoldMotion {
    /// The curve of a part of the chat opening or closing (a run of actions, a request's work, an action's output): the app's
    /// content curve; none under Reduce Motion (what comes then fades in by its own transition and the height changes at
    /// once). The General tab's parts never animate their height (`foldContent`).
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : Motion.content
    }
}

/// The turning chevron at the end of a folding row. Under Reduce Motion it swaps its sign instead of turning.
struct FoldChevron: View {
    let isOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: reduceMotion && isOpen ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.faint)
            .rotationEffect(.degrees(!reduceMotion && isOpen ? 90 : 0))
            // It turns by itself: the row's part opens without an animation (`foldContent`).
            .animation(reduceMotion ? nil : Motion.content, value: isOpen)
            .frame(width: 12)
            .accessibilityHidden(true)
    }
}

/// A folding row's button: the whole row answers the click, and dims a little while pressed.
struct FoldRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The first row of a folding card: its title at the start and, at the end, what it says while closed (`closedSummary`)
/// and the chevron.
struct FoldHeader<ClosedSummary: View>: View {
    let title: String
    let isOpen: Bool
    let tip: String
    /// What VoiceOver hears after "recolhido" (the closed row's drawing is mostly icons it skips).
    var spokenSummary: String?
    let action: () -> Void
    @ViewBuilder let closedSummary: () -> ClosedSummary

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // The title keeps its line at the narrowest panel ("Modelo e permissões" broke in two at 244 pt): the
                // closed summary is what gives way, it truncates.
                Text(title)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if !isOpen {
                    closedSummary()
                        .transition(.opacity)
                }
                FoldChevron(isOpen: isOpen)
            }
            .contentShape(.rect)
        }
        .buttonStyle(FoldRowStyle())
        .help(tip)
        .accessibilityLabel(title)
        .accessibilityValue(InspectorFold.spokenState(isOpen: isOpen, summary: spokenSummary))
    }
}

/// What a folding part shows when it opens: rows of a `Form`, so it only fades in and out, and the table takes its new
/// height at once (MOVIMENTO.md, pattern H): animating it would animate every row of the table.
private struct FoldContent: ViewModifier {
    func body(content: Content) -> some View {
        content.transition(.quiet)
    }
}

extension View {
    func foldContent() -> some View { modifier(FoldContent()) }
}
