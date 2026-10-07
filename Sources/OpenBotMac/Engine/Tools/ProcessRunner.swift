import Foundation
import os

struct ProcessOutput: Sendable {
    var status: Int32
    /// Interleaved stdout and stderr, cut in the middle when longer than the limit.
    var output: String
    var timedOut: Bool
}

/// Runs an executable directly (no shell) with a timeout, task cancellation and capped merged output.
enum ProcessRunner {
    static func run(_ executable: String, _ arguments: [String], directory: URL? = nil,
                    timeout: Duration, outputLimit: Int = 20_000) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let (exited, exitedContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { exitedContinuation.yield($0.terminationStatus); exitedContinuation.finish() }

        try process.run()
        // Process starts the child in a new process group (pgid == pid), so signalling -pid reaches the whole tree.
        let pid = process.processIdentifier

        // Read as data arrives so a chatty child never blocks on a full pipe.
        let buffer = OSAllocatedUnfairLock(initialState: OutputBuffer(limit: outputLimit))
        let (drained, drainedContinuation) = AsyncStream<Never>.makeStream()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                drainedContinuation.finish()
            } else {
                buffer.withLock { $0.append(data) }
            }
        }

        let watchdog = Task {
            do { try await Task.sleep(for: timeout) } catch { return false }
            terminateGroup(pid)
            return true
        }
        let status = await withTaskCancellationHandler {
            var iterator = exited.makeAsyncIterator()
            return await iterator.next()
        } onCancel: {
            terminateGroup(pid)
        }
        watchdog.cancel()
        let timedOut = await watchdog.value
        try Task.checkCancellation()

        // Background children may keep the pipe open; give the remaining output a moment, not forever.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in drained {} }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await group.next()
            group.cancelAll()
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        return ProcessOutput(status: status ?? -1,
                             output: buffer.withLock { $0.text }, timedOut: timedOut)
    }

    /// SIGTERM to the whole process group, then SIGKILL to whatever is left 2 seconds later.
    private static func terminateGroup(_ pid: pid_t) {
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(-pid, SIGKILL) }
    }
}

/// Keeps the first and last `limit / 2` bytes of a stream and counts what was dropped in between.
struct OutputBuffer: Sendable {
    let limit: Int
    private var head = Data()
    private var tail = Data()
    private var dropped = 0

    init(limit: Int) { self.limit = limit }

    mutating func append(_ data: Data) {
        let room = max(limit / 2 - head.count, 0)
        head.append(data.prefix(room))
        tail.append(data.dropFirst(room))
        let excess = tail.count - (limit - limit / 2)
        if excess > 0 {
            tail.removeFirst(excess)
            dropped += excess
        }
    }

    var text: String {
        if dropped == 0 { return String(decoding: head + tail, as: UTF8.self) }
        return String(decoding: head, as: UTF8.self) + "\n[... \(dropped) caracteres omitidos ...]\n"
            + String(decoding: tail, as: UTF8.self)
    }
}
