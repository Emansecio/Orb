import SwiftUI

// Motion of the controls: hover fills, the focus of the composer's card, the sidebar's selection (docs/MOVIMENTO.md
// §2.1, §2.5, §2.7). Everything here moves only opacity (the fills are always there, drawn at opacity 0 when they
// are not wanted), so the render server does the work and no layout changes. A color change is not movement: the
// hover fades stay under Reduce Motion; what is movement (the sliding selection, the symbol swap) goes.

extension Motion {
    /// The curve of a fill that shows and hides: in fast, out slow (so crossing a list does not flicker). A press
    /// that makes the fill show (`pressed`) answers with the press curve.
    static func fill(visible: Bool, pressed: Bool = false) -> Animation {
        guard visible else { return hoverOut }
        return pressed ? press : hoverIn
    }

    /// The hover version of `fill`: the curve for the pointer arriving (`true`) or leaving (`false`).
    static func hover(_ isHovering: Bool) -> Animation { fill(visible: isHovering) }

    /// The composer card's border and background: like a hover, they answer fast when the field gets the focus and
    /// let go slowly when it loses it. Nothing under Reduce Motion (the colors change at once).
    static func focus(_ isFocused: Bool, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : fill(visible: isFocused)
    }

    /// The animation that goes with a change of the sidebar's selection (its background slides from the old row
    /// to the new one); none under Reduce Motion, where the background changes row at once. When the list of Orbs
    /// changed in the same update (⌘N adds one and selects it, deleting removes one and selects another) there is
    /// none either: the rows being inserted, removed or pushed must not move with the selection (§0.7, §2.1).
    static func selection(reduceMotion: Bool, listChanged: Bool = false) -> Animation? {
        reduceMotion || listChanged ? nil : content
    }

    /// A control that becomes available or not (the send button when there is text): its opacity moves with the
    /// content curve, or at once under Reduce Motion.
    static func availability(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : content
    }
}

/// A spinner that says nothing for the first 150 ms (`Motion.spinnerDelay`) and then fades in (`Motion.fade`): a read
/// that finishes quickly shows nothing, and one that takes longer does not blink a spinner for a frame.
struct DelayedSpinner: View {
    var size: ControlSize = .small
    @State private var isVisible = false

    var body: some View {
        ProgressView()
            .controlSize(size)
            .opacity(isVisible ? 1 : 0)
            .task {
                try? await Task.sleep(for: Motion.spinnerDelay)
                withAnimation(Motion.fade) { isVisible = true }
            }
    }
}

extension View {
    /// A fill behind the view that fades in when `visible` (hover, pressed, highlighted) and out again, with the
    /// hover curves (in 0.10 s, out 0.22 s). `resting` is a fill that shows while it is not visible (a chip's
    /// raised background): the two cross-fade, so the end states stay exactly the colors of the theme.
    /// The animation is attached to the fills alone: the view's content never animates with it.
    func hoverFill<S: Shape>(_ visible: Bool, pressed: Bool = false, in shape: S, color: Color = Palette.ghostHover,
                             resting: Color? = nil) -> some View {
        background {
            ZStack {
                if let resting { shape.fill(resting).opacity(visible ? 0 : 1) }
                shape.fill(color).opacity(visible ? 1 : 0)
            }
            .animation(Motion.fill(visible: visible, pressed: pressed), value: visible)
        }
    }
}
