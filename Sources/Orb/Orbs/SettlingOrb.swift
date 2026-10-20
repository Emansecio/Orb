import SwiftUI

/// Gives an Orb with room around it (the empty chat, the welcome, a group's stage) its life at the start and then lets it
/// rest, like the selected sidebar row (`selectionSettled`): it animates while it enters, while the pointer is on it and
/// while something happens (`wake` changes, `idle` is false), and `settleDelay` after the last of those it holds still in
/// its resting pose and stops producing frames. An Orb that animates for ever, with nobody touching it, costs frames for nothing.
struct SettlingOrb<Content: View>: View {
    /// Nothing to do: only an idle Orb settles.
    let idle: Bool
    /// Changes when the Orb is poked or lands: it wakes for another round.
    var wake = 0
    var settleDelay: Duration = .seconds(6)
    @ViewBuilder let content: (_ paused: Bool) -> Content

    @State private var settled = false
    @State private var hovering = false

    private struct Round: Equatable {
        var idle: Bool
        var wake: Int
        var hovering: Bool
    }

    var body: some View {
        content(idle && settled && !hovering)
            .onHover { hovering = $0 }
            .task(id: Round(idle: idle, wake: wake, hovering: hovering)) {
                settled = false
                guard idle, !hovering else { return }
                try? await Task.sleep(for: settleDelay)
                if !Task.isCancelled { settled = true }
            }
    }
}
