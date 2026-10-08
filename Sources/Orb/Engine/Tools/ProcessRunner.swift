import Foundation
import os

struct ProcessOutput: Sendable {
    /// Exit code, or the signal number when `signal` is set.
    var status: Int32
    /// The signal that ended the process, when it did not exit on its own.
    var signal: Int32?
    /// Interleaved stdout and stderr, cut in the middle when longer than the limit.
    var output: String
    var timedOut: Bool
    /// A descendant still held the output open after the process ended (a `cmd &` left behind), so the rest of
    /// its output was not read and it may die from SIGPIPE on its next write.
    var leftOutputOpen = false
}

/// Runs an executable directly (no shell) with a timeout, task cancellation and capped merged output.
/// `executable` must be a full path. Arguments and environment reach the child byte for byte (see `SpawnedProcess`).
enum ProcessRunner {
    /// `environment` replaces the inherited one when given.
    static func run(_ executable: String, _ arguments: [String], directory: URL? = nil, environment: [String: String]? = nil,
                    timeout: Duration, outputLimit: Int = 20_000) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let pipe = Pipe()
        let (exited, exitedContinuation) = AsyncStream<ChildExit>.makeStream()
        let pid: pid_t
        do {
            pid = try SpawnedProcess.start(executable, arguments, directory: directory, environment: environment,
                                           output: pipe.fileHandleForWriting.fileDescriptor)
        } catch {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
            throw error
        }
        // Only the child writes now, so the reader sees the end of the stream when the last writer is gone.
        try? pipe.fileHandleForWriting.close()
        SpawnedProcess.watch(pid) {
            exitedContinuation.yield($0)
            exitedContinuation.finish()
        }

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
        let ended = await withTaskCancellationHandler {
            var iterator = exited.makeAsyncIterator()
            return await iterator.next()
        } onCancel: {
            terminateGroup(pid)
        }
        watchdog.cancel()
        let timedOut = await watchdog.value
        try Task.checkCancellation()

        // Background children may keep the pipe open; give the remaining output a moment, not forever.
        let drainedInTime = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in drained {}; return true }
            group.addTask { try? await Task.sleep(for: .seconds(1)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        return ProcessOutput(status: ended?.status ?? -1, signal: ended.flatMap { $0.signaled ? $0.status : nil },
                             output: buffer.withLock { $0.text }, timedOut: timedOut, leftOutputOpen: !drainedInTime)
    }

    /// SIGTERM to the whole process group, then SIGKILL to whatever is left 2 seconds later.
    private static func terminateGroup(_ pid: pid_t) {
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(-pid, SIGKILL) }
    }
}

enum Signals {
    private static let names: [Int32: String] = [SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGILL: "SIGILL",
                                                 SIGABRT: "SIGABRT", SIGFPE: "SIGFPE", SIGKILL: "SIGKILL", SIGBUS: "SIGBUS",
                                                 SIGSEGV: "SIGSEGV", SIGPIPE: "SIGPIPE", SIGALRM: "SIGALRM", SIGTERM: "SIGTERM"]

    /// "15 (SIGTERM)", or just the number for signals without a well-known name.
    static func describe(_ number: Int32) -> String {
        names[number].map { "\(number) (\($0))" } ?? "\(number)"
    }

    /// For an exit code above 128 that is a well-known signal plus 128 (a shell reports a child killed by a signal
    /// that way, e.g. 139 for a crash), the " (provavelmente ...)" note to add after the code; empty otherwise.
    static func hint(forExitCode code: Int32) -> String {
        guard code > 128, names[code - 128] != nil else { return "" }
        return " (provavelmente o sinal \(describe(code - 128)))"
    }
}

/// Keeps the first and last `limit / 2` bytes of a stream and counts what was dropped in between. The cuts
/// fall on character boundaries, so a multi-byte character is never split into a replacement mark.
struct OutputBuffer: Sendable {
    let limit: Int
    private var head = Data()
    private var tail = Data()
    private var droppedBytes = 0
    /// Unicode scalars in the dropped middle (counted as the bytes go, since they are not kept).
    private var droppedCharacters = 0

    init(limit: Int) { self.limit = limit }

    mutating func append(_ data: Data) {
        let room = max(limit / 2 - head.count, 0)
        head.append(data.prefix(room))
        tail.append(data.dropFirst(room))
        let excess = tail.count - (limit - limit / 2)
        if excess > 0 {
            droppedCharacters += tail.prefix(excess).reduce(0) { $0 + ($1 & 0xC0 == 0x80 ? 0 : 1) }
            tail.removeFirst(excess)
            droppedBytes += excess
        }
    }

    var text: String {
        if droppedBytes == 0 { return String(decoding: head + tail, as: UTF8.self) }
        let start = Self.withoutPartialCharacter(head)
        // A character split by the cut counts as omitted: its first byte left `head`, the rest is skipped below.
        let omitted = droppedCharacters + (start.count < head.count ? 1 : 0)
        let end = tail.drop { $0 & 0xC0 == 0x80 }
        return String(decoding: start, as: UTF8.self) + "\n[... \(omitted) caracteres omitidos ...]\n"
            + String(decoding: end, as: UTF8.self)
    }

    /// `data` without a trailing UTF-8 sequence that is cut short.
    static func withoutPartialCharacter(_ data: Data) -> Data {
        let bytes = [UInt8](data.suffix(4))
        guard let lastLead = bytes.lastIndex(where: { $0 & 0xC0 != 0x80 }) else { return data }
        let lead = bytes[lastLead]
        let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        return bytes.count - lastLead < length ? data.dropLast(bytes.count - lastLead) : data
    }
}
