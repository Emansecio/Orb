import Foundation
import os

/// A long-running child that talks in lines: Orb writes lines to its stdin, reads its stdout line by line
/// and keeps the end of its stderr for error messages. Like `ProcessRunner` it is started with `SpawnedProcess`: the
/// child gets its own process group (stopping it also stops whatever it launched) and its arguments and environment
/// arrive byte for byte, so the persona and memory in Portuguese reach Claude Code as written, not decomposed.
final class LineProcess: Sendable {
    /// Stdout, one line at a time; finishes when the child closes stdout.
    let lines: AsyncStream<String>
    let pid: pid_t
    /// Kept so the readers' descriptors stay open for as long as the child may write.
    private let pipes: [Pipe]
    /// Only the choice of handle happens under the lock, never the I/O.
    private let input: OSAllocatedUnfairLock<FileHandle?>
    /// Writes to the child's stdin happen here, in call order and never on the caller's thread: a child that stops reading
    /// blocks `write(2)` once the pipe is full, and `send`/`closeInput` run on the main thread when a turn is cancelled.
    private let writes = DispatchQueue(label: "app.orb.line-process.writes")
    private let errors: OSAllocatedUnfairLock<OutputBuffer>
    private let exited: OSAllocatedUnfairLock<Bool>
    /// Finishes when the child's stderr reaches its end.
    private let errorsDrained: AsyncStream<Never>

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
        let (errorsDrained, errorsDone) = AsyncStream<Never>.makeStream()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                errorsDone.finish()
            } else {
                errors.withLock { $0.append(data) }
            }
        }
        let exited = OSAllocatedUnfairLock(initialState: false)

        let pid: pid_t
        do {
            pid = try SpawnedProcess.start(executable.path, arguments, directory: directory, environment: environment,
                                           output: stdout.fileHandleForWriting.fileDescriptor,
                                           error: stderr.fileHandleForWriting.fileDescriptor,
                                           input: stdin.fileHandleForReading.fileDescriptor)
        } catch {
            errorsDone.finish()
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
        ChildProcessGroups.insert(pid)
        SpawnedProcess.watch(pid) { _ in
            exited.withLock { $0 = true }
            ChildProcessGroups.remove(pid)
        }
        // A child that exits early must not kill the app with SIGPIPE when we write to it.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        self.lines = lines
        self.errors = errors
        self.exited = exited
        self.errorsDrained = errorsDrained
        self.pid = pid
        pipes = [stdin, stdout, stderr]
        input = OSAllocatedUnfairLock(initialState: stdin.fileHandleForWriting)
    }

    /// Queues one line (a newline is appended). Ignored once input is closed or the child is gone. Never blocks.
    func send(_ line: String) {
        guard let handle = input.withLock({ $0 }) else { return }
        let data = Data((line + "\n").utf8)
        writes.async { [input] in
            do { try handle.write(contentsOf: data) } catch { input.withLock { if $0 === handle { $0 = nil } } }
        }
    }

    /// Closes stdin after the lines already queued. Behind a write that is stuck, if there is one: the child ending
    /// (`terminate`) is what frees it. Never blocks.
    func closeInput() {
        guard let handle = input.withLock({ current in defer { current = nil }; return current }) else { return }
        writes.async { try? handle.close() }
    }

    /// The last few KB the child wrote to stderr.
    var errorOutput: String { errors.withLock { $0.text }.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// `errorOutput` once the child's stderr has been read to its end, for a message about why it died: stdout can
    /// close before the last bytes of stderr are read. Waits at most `limit` (a grandchild may hold stderr open).
    func finalErrorOutput(waitingUpTo limit: Duration = .seconds(1)) async -> String {
        let drained = errorsDrained
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in drained {} }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
        return errorOutput
    }

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
