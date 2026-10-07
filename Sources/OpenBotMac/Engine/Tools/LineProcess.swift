import Foundation
import os

/// A long-running child that talks in lines: OpenBot writes lines to its stdin, reads its stdout line by line
/// and keeps the end of its stderr for error messages. Like `ProcessRunner`, the child gets its own process
/// group, so stopping it also stops whatever it launched.
final class LineProcess: Sendable {
    /// Stdout, one line at a time; finishes when the child closes stdout.
    let lines: AsyncStream<String>
    /// Kept so the child is never released while it runs.
    private let process: Process
    private let input: OSAllocatedUnfairLock<FileHandle?>
    private let errors: OSAllocatedUnfairLock<OutputBuffer>
    private let exited: OSAllocatedUnfairLock<Bool>

    init(executable: URL, arguments: [String], directory: URL, environment: [String: String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        let partial = OSAllocatedUnfairLock(initialState: Data())
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                let rest = partial.withLock { buffer in defer { buffer = Data() }; return buffer }
                if !rest.isEmpty { continuation.yield(String(decoding: rest, as: UTF8.self)) }
                continuation.finish()
                return
            }
            let complete = partial.withLock { buffer in
                buffer.append(data)
                var found: [Data] = []
                while let newline = buffer.firstIndex(of: 0x0A) {
                    found.append(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
                return found
            }
            for line in complete where !line.isEmpty { continuation.yield(String(decoding: line, as: UTF8.self)) }
        }
        let errors = OSAllocatedUnfairLock(initialState: OutputBuffer(limit: 4000))
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { errors.withLock { $0.append(data) } }
        }
        let exited = OSAllocatedUnfairLock(initialState: false)
        process.terminationHandler = { _ in exited.withLock { $0 = true } }

        try process.run()
        // A child that exits early must not kill the app with SIGPIPE when we write to it.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        self.lines = lines
        self.errors = errors
        self.exited = exited
        self.process = process
        input = OSAllocatedUnfairLock(initialState: stdin.fileHandleForWriting)
    }

    /// Writes one line (a newline is appended). Ignored once input is closed or the child is gone.
    func send(_ line: String) {
        input.withLock { handle in
            guard let current = handle else { return }
            do { try current.write(contentsOf: Data((line + "\n").utf8)) } catch { handle = nil }
        }
    }

    func closeInput() {
        input.withLock { handle in
            try? handle?.close()
            handle = nil
        }
    }

    /// The last few KB the child wrote to stderr.
    var errorOutput: String { errors.withLock { $0.text }.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Unless the child exits first: SIGTERM to its process group after `grace` seconds, SIGKILL 2 seconds later.
    func terminate(after grace: TimeInterval) {
        let pid = process.processIdentifier, exited = exited
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            guard !exited.withLock({ $0 }) else { return }
            kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if !exited.withLock({ $0 }) { kill(-pid, SIGKILL) }
            }
        }
    }
}
