import Foundation

// The deterministic gate of a routine (see `Routine.precheck`): a small program that answers whether the
// scheduled run is needed at all, before the routine conversation is loaded and the model is woken. It runs
// with the Orb's folder as its working directory, is bounded by `timeout`, and fails open: every outcome
// that is not an explicit {"skip": true} — a crash, a timeout, unreadable output — means the run happens.

extension RoutinePrecheck {
    /// What the check decided.
    enum Verdict: Equatable, Sendable {
        /// Run as usual (also every unclear outcome: the check only skips what it can prove unnecessary).
        case run
        /// The check excused this slot, with the reason it gave.
        case skip(String)
    }

    /// A precheck's allowance: long enough for a local triage (`puxar.py --peek`), short enough that a hung
    /// script does not stall the scheduler.
    static let timeout: TimeInterval = 90
    /// Past this much stdout the output cannot be a verdict anyway: the process is ended and the run happens.
    static let outputLimit = 64_000

    /// The verdict of one stdout/exit pair. Only an explicit `{"skip": true}` on the last line excuses the run.
    static func verdict(stdout: String, exit: Int32) -> Verdict {
        guard exit == 0, let last = stdout.split(separator: "\n").last,
              let json = JSONValue.parse(String(last)),
              json["skip"]?.bool == true else { return .run }
        let reason = (json["reason"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return .skip(reason.isEmpty ? "sem motivo informado" : reason)
    }

    /// Runs `command` in `folder` and reads its verdict, bounded by `timeout`. Off the calling actor: the
    /// scheduler ticks on the main actor and the check may take seconds.
    static func check(_ precheck: RoutinePrecheck, in folder: URL?) async -> Verdict {
        guard precheck.command.first?.isEmpty == false else { return .run }
        return await Task.detached(priority: .utility) { () -> Verdict in
            let process = Process()
            // `env` resolves a bare program name; the app's own PATH plus the usual user tool dirs (a GUI
            // app's PATH lacks Homebrew and ~/bin, where helpers like wacli live).
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = precheck.command
            var environment = ProcessInfo.processInfo.environment
            let home = environment["HOME"] ?? NSHomeDirectory()
            environment["PATH"] = [home + "/bin", "/opt/homebrew/bin", "/usr/local/bin",
                                   environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
            process.environment = environment
            process.currentDirectoryURL = folder
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            let output = OutputBuffer(limit: outputLimit) { process.terminate() }
            pipe.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData) }
            do { try process.run() } catch { return .run }
            let deadline = Date.now.addingTimeInterval(timeout)
            while process.isRunning && Date.now < deadline { usleep(50_000) }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            // The verdict may still be in flight when the process exits: give the handler a beat, then drain.
            usleep(100_000)
            output.append(pipe.fileHandleForReading.availableData)
            pipe.fileHandleForReading.readabilityHandler = nil
            return verdict(stdout: output.text, exit: process.terminationStatus)
        }.value
    }

    /// Accumulates the check's stdout; past the limit the process is killed (its output was already no verdict).
    private final class OutputBuffer: @unchecked Sendable {
        private var data = Data()
        private let limit: Int
        private let onOverflow: () -> Void
        private let lock = NSLock()
        private var overflowed = false

        init(limit: Int, onOverflow: @escaping () -> Void) {
            self.limit = limit
            self.onOverflow = onOverflow
        }

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            let over = data.count > limit && !overflowed
            overflowed = overflowed || data.count > limit
            lock.unlock()
            if over { onOverflow() }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data.prefix(limit), encoding: .utf8) ?? ""
        }
    }
}
