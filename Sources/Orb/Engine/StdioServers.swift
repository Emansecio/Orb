import Foundation
import os

/// The local servers (stdio) running now. `close` ends one for good (SIGTERM, then SIGKILL for the one that ignores it) and
/// `killAllNow` is for the app quitting, when nothing else would end them: a server that holds other handles open (a browser,
/// a connection pool) does not leave on EOF alone.
final class StdioServerRegistry: Sendable {
    static let shared = StdioServerRegistry()

    /// A `Process` is not `Sendable`; it is only asked `isRunning` and signalled, which is thread-safe.
    private final class Entry: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    private let live = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: Entry]())

    var count: Int { live.withLock { $0.count } }

    func add(_ process: Process) {
        live.withLock { $0[ObjectIdentifier(process)] = Entry(process) }
    }

    /// Asks the server to end now and, if it is still there after `grace`, kills it. Forgotten once gone.
    func end(_ process: Process, grace: Duration) {
        if process.isRunning { process.terminate() }
        let entry = Entry(process)
        let seconds = Double(grace.components.seconds) + Double(grace.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            // The Process object tells whether it is the same process: a pid alone could have been reused.
            if entry.process.isRunning { kill(entry.process.processIdentifier, SIGKILL) }
            live.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(entry.process)) }
        }
    }

    /// Ends every server now, synchronously (the app is quitting): SIGTERM, a moment to leave, then SIGKILL.
    func killAllNow(wait: TimeInterval = 0.3) {
        let running = live.withLock { Array($0.values) }.filter(\.process.isRunning)
        running.forEach { $0.process.terminate() }
        let deadline = Date.now.addingTimeInterval(wait)
        while Date.now < deadline, running.contains(where: \.process.isRunning) { usleep(20_000) }
        for entry in running where entry.process.isRunning { kill(entry.process.processIdentifier, SIGKILL) }
        live.withLock { $0.removeAll() }
    }
}
