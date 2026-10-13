import Foundation
import os

/// The local servers (stdio) running now. `end` ends one for good (SIGTERM, then SIGKILL for the one that ignores it) and
/// `killAllNow` is for the app quitting, when nothing else would end them: a server that holds other handles open (a browser,
/// a connection pool) does not leave on EOF alone.
///
/// Each server leads a process group of its own (`SpawnedProcess`), and the signals go to the group: `npx`/`uvx` start the
/// real server as a child, and none of them may outlive the connection. A group is alive while any member is, even after its
/// leader was reaped, so `kill(-pid, 0)` also tells whether grandchildren are left. A process that starts a session of its own
/// (a browser launched detached) leaves the group: it only ends if the server closes it on SIGTERM.
final class StdioServerRegistry: Sendable {
    static let shared = StdioServerRegistry()

    private let live = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    var count: Int { live.withLock { $0.count } }

    /// `pid` leads the group of a server just started.
    func add(_ pid: pid_t) {
        live.withLock { _ = $0.insert(pid) }
    }

    /// Asks the server's group to end now and, if anything is still there after `grace`, kills it. Forgotten once gone.
    func end(_ pid: pid_t, grace: Duration) {
        if kill(-pid, 0) == 0 { kill(-pid, SIGTERM) }
        let seconds = Double(grace.components.seconds) + Double(grace.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
            live.withLock { _ = $0.remove(pid) }
        }
    }

    /// Ends every server now, synchronously (the app is quitting): SIGTERM, a moment to leave, then SIGKILL.
    func killAllNow(wait: TimeInterval = 0.3) {
        ProcessGroups.terminate(live.withLock { Array($0) }, grace: .seconds(wait))
        live.withLock { $0.removeAll() }
    }
}
