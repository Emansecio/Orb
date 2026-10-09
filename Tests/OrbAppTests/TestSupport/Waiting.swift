import Foundation
import Testing

/// Polls `condition` until it holds, returning `true` as soon as it does, so a test never depends on how long the
/// machine takes to get there. The timeout is generous on purpose: it only bounds a test that is genuinely stuck and
/// is never part of the happy path. On timeout an `Issue` naming `what` is recorded and `false` is returned. If the
/// task is cancelled meanwhile, `false` is returned without an `Issue`: nothing timed out.
///
/// `condition` may be synchronous or `async` (reading an actor), and may throw. It runs on the caller's actor, so a
/// `@MainActor` test can read the model directly.
///
/// Use it for positive assertions ("the job finished"). For a negative one ("nothing else happened") wait for a
/// positive signal that the system settled first (an event, a task's value, a state), then assert, with at most a
/// very short sleep afterwards.
@discardableResult
func waitUntil(
    _ what: @autoclosure () -> String = "a condition",
    timeout: Duration = .seconds(30),
    poll: Duration = .milliseconds(20),
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async throws -> Bool
) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while true {
        if try await condition() { return true }
        if ContinuousClock.now >= deadline { break }
        try? await Task.sleep(for: poll)
        if Task.isCancelled { return false }
    }
    Issue.record("Timed out after \(timeout) waiting for \(what())", sourceLocation: sourceLocation)
    return false
}

/// Whether a process with this pid still exists. Orphans are reaped by launchd within moments, so after a kill
/// this turns false soon; poll it with ``waitUntil(_:timeout:poll:isolation:sourceLocation:_:)`` rather than
/// checking once.
func processIsAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}
