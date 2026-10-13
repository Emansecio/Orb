import Foundation
import os

/// When a `run_command` the turn waits for is let go on as a background job, so the Orb can talk again: the user pressed
/// "Segundo plano" on the working line, or sent a message for the running task (the composer's ↩) while the command had
/// already run for `messageGrace`. One per turn; the commands of the turn ask it while they run (`ProcessRunner.Detach`).
final class CommandRelease: Sendable {
    /// How long a command runs before a message sends it to the background: a quick one just ends, and the message
    /// reaches the model right after it.
    static let messageGrace: Duration = .seconds(3)

    private struct State {
        var pressed = false
        var running = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let steering: SteeringQueue?
    private let grace: Duration
    /// Told when commands start being waited for (true) and when the last one stops being (false), for the button.
    private let onWaiting: @Sendable (Bool) -> Void

    init(steering: SteeringQueue?, grace: Duration = messageGrace, onWaiting: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.steering = steering
        self.grace = grace
        self.onWaiting = onWaiting
    }

    /// The button: every command the turn waits for now goes on in the background.
    func press() { state.withLock { $0.pressed = true } }

    /// A command starts being waited for. A press made while none was running does not count for it.
    func begin() {
        let first = state.withLock { state in
            defer { state.running += 1 }
            if state.running == 0 { state.pressed = false }
            return state.running == 0
        }
        if first { onWaiting(true) }
    }

    /// The command ended or went to the background.
    func end() {
        let last = state.withLock { state in
            state.running = max(state.running - 1, 0)
            if state.running == 0 { state.pressed = false }
            return state.running == 0
        }
        if last { onWaiting(false) }
    }

    /// Whether a command that has run for `elapsed` should stop being waited for.
    func isRequested(after elapsed: Duration) -> Bool {
        state.withLock { $0.pressed } || (elapsed >= grace && steering?.hasSteering == true)
    }
}
