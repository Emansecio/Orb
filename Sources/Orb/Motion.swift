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
    /// What replaces every movement under Reduce Motion.
    static let fade = Animation.easeOut(duration: 0.15)
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

extension AnyTransition {
    /// Rises 6 pt and appears; leaves by fading only.
    static var rise: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity)
    }

    /// Comes down from the item above (details that open); leaves by fading only.
    static var unfold: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: -4)), removal: .opacity)
    }

    /// `transition`, or a plain fade when Reduce Motion is on.
    static func adapted(_ transition: AnyTransition, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : transition
    }
}
