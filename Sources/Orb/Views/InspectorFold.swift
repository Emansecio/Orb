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
    /// The glyph's point size: 10 in the General tab's rows, 9 in the chat's lines.
    var size: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: reduceMotion && isOpen ? "chevron.down" : "chevron.right")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Palette.faint)
            .rotationEffect(.degrees(!reduceMotion && isOpen ? 90 : 0))
            // It turns by itself: the row's part opens without an animation (`foldContent`).
            .animation(FoldMotion.animation(reduceMotion: reduceMotion), value: isOpen)
            .frame(width: size + 2)
            .accessibilityHidden(true)
    }
}

/// A folding row's button: the whole row answers the click, shows the hover fill of the app's other rows (it hangs a
/// little past the row's text, as the sidebar's rows do) and dims a little while pressed.
struct FoldRowStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .hoverFill(isHovering, pressed: configuration.isPressed, in: .rect(cornerRadius: Radius.small))
            .padding(.horizontal, -6)
            .padding(.vertical, -4)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { isHovering = $0 }
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
                    // `.quiet` carries its own fade (and it is the 0.15 s one under Reduce Motion): the part's height
                    // changes at once, so a bare `.opacity` here had no animation to run in.
                    closedSummary()
                        .transition(.quiet)
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
