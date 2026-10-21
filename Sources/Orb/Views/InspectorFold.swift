import SwiftUI

// The pieces the General tab folds with ("Modelo e modo", "Pode usar", "Navegar na web"): a row that opens and closes, its
// chevron, and the motion of what comes and goes. Which parts are open lives in `InspectorFold` (InspectorSupport.swift).

enum FoldMotion {
    /// The curve of a part opening or closing: the app's content curve; none under Reduce Motion (what comes then fades in
    /// by its own transition, see `foldContent`, and the height changes at once).
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
                Text(title)
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

/// What a folding part shows when it opens: it comes down from the row above and fades in (only the fade under Reduce
/// Motion), and leaves by fading.
private struct FoldContent: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(.adapted(.unfold, reduceMotion: reduceMotion))
    }
}

extension View {
    func foldContent() -> some View { modifier(FoldContent()) }
}
