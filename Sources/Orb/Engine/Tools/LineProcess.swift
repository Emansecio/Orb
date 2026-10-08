import Foundation
import os

/// A long-running child that talks in lines: Orb writes lines to its stdin, reads its stdout line by line
/// and keeps the end of its stderr for error messages. Like `ProcessRunner` it is started with `SpawnedProcess`: the
/// child gets its own process group (stopping it also stops whatever it launched) and its arguments and environment
/// arrive byte for byte, so the persona and memory in Portuguese reach Claude Code as written, not decomposed.
final class LineProcess: Sendable {
    /// Stdout, one line at a time; finishes when the child closes stdout.
    let lines: AsyncStream<String>
    private let pid: pid_t
    /// Kept so the readers' descriptors stay open for as long as the child may write.
    private let pipes: [Pipe]
    private let input: OSAllocatedUnfairLock<FileHandle?>
    private let errors: OSAllocatedUnfairLock<OutputBuffer>
    private let exited: OSAllocatedUnfairLock<Bool>

    init(executable: URL, arguments: [String], directory: URL, environment: [String: String]) throws {
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()

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

        let pid: pid_t
        do {
            pid = try SpawnedProcess.start(executable.path, arguments, directory: directory, environment: environment,
                                           output: stdout.fileHandleForWriting.fileDescriptor,
                                           error: stderr.fileHandleForWriting.fileDescriptor,
                                           input: stdin.fileHandleForReading.fileDescriptor)
        } catch {
            for handle in [stdin.fileHandleForReading, stdin.fileHandleForWriting, stdout.fileHandleForReading, stdout.fileHandleForWriting,
                           stderr.fileHandleForReading, stderr.fileHandleForWriting] {
                try? handle.close()
            }
            throw error
        }
        // Only the child holds these ends now, so the readers see the end of the streams when it is gone.
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        SpawnedProcess.watch(pid) { _ in exited.withLock { $0 = true } }
        // A child that exits early must not kill the app with SIGPIPE when we write to it.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        self.lines = lines
        self.errors = errors
        self.exited = exited
        self.pid = pid
        pipes = [stdin, stdout, stderr]
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
        let pid = pid, exited = exited
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            guard !exited.withLock({ $0 }) else { return }
            kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if !exited.withLock({ $0 }) { kill(-pid, SIGKILL) }
            }
        }
    }
}
