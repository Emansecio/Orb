import Foundation

/// Helpers for ending process groups (each child the app starts leads a group of its own).
enum ProcessGroups {
    /// Whether anything is still alive in the group led by `pid`.
    static func exists(_ pid: pid_t) -> Bool { kill(-pid, 0) == 0 }

    /// SIGTERM to every group that is still there, up to `grace` for them to leave, then SIGKILL to what remains.
    /// Synchronous on purpose: it is what runs while the app quits and cannot wait for an actor.
    static func terminate(_ groups: [pid_t], grace: Duration) {
        let alive = groups.filter(exists)
        alive.forEach { kill(-$0, SIGTERM) }
        let seconds = Double(grace.components.seconds) + Double(grace.components.attoseconds) / 1e18
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline, alive.contains(where: exists) { usleep(20_000) }
        alive.filter(exists).forEach { kill(-$0, SIGKILL) }
    }
}
