import SwiftUI

// The app's motion vocabulary: a few curves and transitions, always the same ones, so every animation reads as part of
// one calm interface (docs/MOVIMENTO.md). The Orb is where the personality lives; the chrome only shows what changed.
// Under Reduce Motion nothing slides, scales or bounces: changes fade in 0.15 s or happen at once.

enum Motion {
    /// A button pressed, a chip chosen.
    static let press = Animation.snappy(duration: 0.12)
    /// Hover backgrounds answer fast and let go slowly, so moving across a list doesn't flicker.
    static let hoverIn = Animation.easeOut(duration: 0.10)
    static let hoverOut = Animation.easeOut(duration: 0.22)
    /// A state that changes in place (the app's content curve, `animateChanges`).
    static let content = Animation.smooth(duration: 0.25)
    /// Something that appears: a message, a card, a row.
    static let enter = Animation.spring(response: 0.38, dampingFraction: 0.86)
    /// Something that needs you (an approval card).
    static let emphasis = Animation.spring(response: 0.45, dampingFraction: 0.72)
    /// Something that goes away.
    static let exit = Animation.easeOut(duration: 0.16)
    /// The page, tab or Orb that leaves a swap (`AnyTransition.pageSwap`): gone in half the time the new one takes to come,
    /// so the two are never seen laid over each other at the same strength.
    static let swapOut = Animation.easeOut(duration: 0.08)
    /// How long `exit` lasts: what has to wait for something to be gone (rows that fade before they are removed).
    static let exitDuration = Duration.milliseconds(160)
    /// What replaces every movement under Reduce Motion.
    static let fade = Animation.easeOut(duration: 0.15)
    /// A spinner stays invisible this long: what loads faster than that shows no spinner at all (the chat's, and every
    /// "loading, then ready" in a sheet).
    static let spinnerDelay = Duration.milliseconds(150)
    /// Delay between the items of a short list that enter together; at most `staggerLimit` items are staggered.
    static let stagger: Double = 0.035
    static let staggerLimit = 6

    /// The delay of the `index`th item of a staggered entrance (the ones past the limit come with the last).
    static func staggerDelay(_ index: Int) -> Double {
        Double(min(max(index, 0), staggerLimit - 1)) * stagger
    }

    /// `animation`, or the plain fade when Reduce Motion is on.
    static func adapted(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : animation
    }
}

extension Motion {
    /// The Orb's panel (the inspector column) opening or closing: it slides in the content curve, the same from every
    /// path (the toolbar button, ⌘⌥I, the palette, a window that got narrow, "Ver na memória"); no animation under
    /// Reduce Motion.
    static func panel(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : content
    }
}

extension AnyTransition {
    /// One content replacing another in the same place (pattern A of docs/MOVIMENTO.md): the new one fades in at the
    /// swap's pace, the old one fades out at `Motion.swapOut`, faster, so the old screen does not linger under the new.
    static var pageSwap: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .opacity.animation(Motion.swapOut))
    }

    /// Rises 6 pt and appears; leaves by fading only.
    static var rise: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity)
    }

    /// A phrase replaced by another in place (the working line): the new one rises 4 pt and appears, the old one just
    /// fades, quickly, so the two never fight for the eye.
    static var swap: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 4)), removal: .opacity.animation(Motion.exit))
    }

    /// A line that arrives with the turn (the working line): rises 6 pt and appears with the entrance curve; leaves by
    /// fading only, with the exit one.
    static var arrive: AnyTransition {
        .asymmetric(insertion: AnyTransition.rise.animation(Motion.enter), removal: .opacity.animation(Motion.exit))
    }

    /// Comes down from the item above (details that open); leaves by fading only.
    static var unfold: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: -4)), removal: .opacity)
    }

    /// Fades in and out by itself, in `Motion.fade` (0.15 s), whatever the surrounding transaction says: for what
    /// appears where the container must not animate its height (the menu-bar window, a popover, a `Form` row). The
    /// container takes its new size at once and the content fades into it.
    static var quiet: AnyTransition {
        .opacity.animation(Motion.fade)
    }

    /// A small state mark (a check, a warning, a spinner turning into its result) that appears: grows from 0.6 and
    /// fades in; leaves by fading. Used across the app so every "it worked" looks the same.
    static var mark: AnyTransition {
        .scale(scale: 0.6).combined(with: .opacity)
    }

    /// `transition`, or the quiet fade when Reduce Motion is on: nothing slides, scales or turns, and a row that
    /// arrives inside a change that is instant (`animateChanges`) still fades in 0.15 s instead of appearing dry.
    static func adapted(_ transition: AnyTransition, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .quiet : transition
    }
}
