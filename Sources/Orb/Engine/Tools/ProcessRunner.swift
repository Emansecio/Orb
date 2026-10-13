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
    /// Processes of the command's group (a `cmd &` left behind) were still alive when it returned. They are not
    /// tracked or stopped by the app.
    var leftoversAlive = false
    /// Bytes and lines of the whole stream, including what the cut removed.
    var totalBytes = 0
    var totalLines = 0
    /// Where the whole stream was saved, when it was longer than the limit and a folder to save it in was given.
    var fullOutputFile: URL?
    /// The saved file stops at `StreamCapture.maxSpillBytes`; the stream was longer.
    var fullOutputCut = false
    /// Mostly unreadable bytes (an executable, an archive): `output` is a placeholder, not the data.
    var isBinary = false
    /// The command still runs: the caller stopped waiting for it (`ProcessRunner.Detach`). `output` is what it printed so far.
    var detached: DetachedProcess?
}

/// Runs an executable directly (no shell) with a timeout, task cancellation and capped merged output.
/// `executable` must be a full path. Arguments and environment reach the child byte for byte (see `SpawnedProcess`).
enum ProcessRunner {
    /// When to stop waiting for a command and leave it running (`CommandRelease`), and the log its output goes to from then
    /// on: what was read so far first, then the rest as it comes.
    struct Detach: Sendable {
        var log: URL
        /// Asked a few times a second while the command runs, with how long it has run.
        var when: @Sendable (Duration) -> Bool
    }

    /// How often `Detach.when` is asked.
    static let detachCheck = Duration.milliseconds(250)

    /// `environment` replaces the inherited one when given. `spillTo`: a file to write the whole stream to when it is
    /// longer than `outputLimit` (the result keeps only the start and end); never created for shorter output.
    /// `onOutput`: called with each piece of output as it arrives (from a background queue), for progress lines.
    /// `detach`: the command may be left running; the result then has `detached` and the output read until then.
    static func run(_ executable: String, _ arguments: [String], directory: URL? = nil, environment: [String: String]? = nil,
                    timeout: Duration, outputLimit: Int = 20_000, spillTo: URL? = nil, detach: Detach? = nil,
                    onOutput: (@Sendable (Data) -> Void)? = nil) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let pipe = Pipe()
        let (waited, waitedContinuation) = AsyncStream<ChildEnd.Wait>.makeStream()
        let end = ChildEnd(runner: waitedContinuation)
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
        ChildProcessGroups.insert(pid)
        // Leftovers (`cmd &`) are not ours to track after the call: the warning in the result says so. A detached command
        // is the background jobs' to track (`BackgroundJobs.adopt`).
        defer { ChildProcessGroups.remove(pid) }
        let started = ContinuousClock.now
        SpawnedProcess.watch(pid) { end.report($0) }

        // Read as data arrives so a chatty child never blocks on a full pipe. Once detached, into the log instead. The
        // handler holds the pipe until the end of the stream, which a detached command reaches after this returns.
        let reading = OSAllocatedUnfairLock(initialState: Reading(capture: StreamCapture(limit: outputLimit, spillTo: spillTo)))
        let (drained, drainedContinuation) = AsyncStream<Never>.makeStream()
        pipe.fileHandleForReading.readabilityHandler = { [pipe] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if let log = reading.withLock({ $0.log }) {
                    try? log.close()
                    try? pipe.fileHandleForReading.close()
                }
                drainedContinuation.finish()
            } else if reading.withLock({ $0.take(data) }) {
                onOutput?(data)
            }
        }

        let watchdog = Task {
            do { try await Task.sleep(for: timeout) } catch { return false }
            terminateGroup(pid)
            return true
        }
        let watcher = detach.map { detach in
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: detachCheck)
                    guard !Task.isCancelled, detach.when(ContinuousClock.now - started),
                          let log = Self.openLog(detach.log) else { continue }
                    if end.detach(into: log) { return }
                    try? log.close()
                    try? FileManager.default.removeItem(at: detach.log)
                }
            }
        }
        let outcome = await withTaskCancellationHandler {
            var iterator = waited.makeAsyncIterator()
            return await iterator.next()
        } onCancel: {
            terminateGroup(pid)
        }
        watcher?.cancel()
        watchdog.cancel()
        let timedOut = await watchdog.value

        if case .detached(let log)? = outcome, let detach {
            // Everything read so far goes first into the log, and from now on the handler writes there.
            let captured = reading.withLock { $0.handOver(to: log) }
            return ProcessOutput(status: 0, output: captured.text, timedOut: false, totalBytes: captured.bytes,
                                 totalLines: captured.lines, isBinary: captured.isBinary,
                                 detached: DetachedProcess(pid: pid, log: detach.log, end: end))
        }
        try Task.checkCancellation()
        let ended: ChildExit? = if case .ended(let exit)? = outcome { exit } else { nil }

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
        // The leader is gone; the group id lives on while anything it started is still running.
        let leftoversAlive = kill(-pid, 0) == 0
        let captured = reading.withLock { $0.capture.finish() }
        return ProcessOutput(status: ended?.status ?? -1, signal: ended.flatMap { $0.signaled ? $0.status : nil },
                             output: captured.text, timedOut: timedOut, leftOutputOpen: !drainedInTime, leftoversAlive: leftoversAlive,
                             totalBytes: captured.bytes, totalLines: captured.lines, fullOutputFile: captured.file,
                             fullOutputCut: captured.fileCut, isBinary: captured.isBinary)
    }

    /// A new, private log open for appending; nil when it cannot be made (the command is then waited for as before).
    private static func openLog(_ url: URL) -> FileHandle? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // O_APPEND so that emptying an oversized log (`BackgroundJobs`) does not leave the writes past a hole.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o600)
        return descriptor < 0 ? nil : FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// SIGTERM to the whole process group, then SIGKILL to whatever is left 2 seconds later.
    private static func terminateGroup(_ pid: pid_t) {
        kill(-pid, SIGTERM)
        // Only if the group is still there: once it is gone its id may belong to someone else.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if ProcessGroups.exists(pid) { kill(-pid, SIGKILL) } }
    }

    /// Where the output read goes: the capture for the result, or the log once the command was detached.
    private struct Reading {
        var capture: StreamCapture
        var log: FileHandle?

        /// True when it went to the capture (and so counts as the command's output, for `onOutput`).
        mutating func take(_ data: Data) -> Bool {
            guard let log else { capture.append(data); return true }
            try? log.write(contentsOf: data)
            return false
        }

        /// Writes what was read into `log` (the whole of it: the saved file when the capture kept only the start and end),
        /// switches to it and gives what the result shows.
        mutating func handOver(to log: FileHandle) -> (text: String, bytes: Int, lines: Int, isBinary: Bool) {
            let captured = capture.finish()
            if let file = captured.file, let whole = try? Data(contentsOf: file) {
                try? log.write(contentsOf: whole)
            } else {
                try? log.write(contentsOf: Data(captured.text.utf8))
            }
            self.log = log
            return (captured.text, captured.bytes, captured.lines, captured.isBinary)
        }
    }
}

/// A command `ProcessRunner` stopped waiting for while it still ran: its process group, the log its output goes to, and
/// its end, for the background job that takes it over (`BackgroundJobs.adopt`).
struct DetachedProcess: Sendable {
    let pid: pid_t
    let log: URL
    let end: ChildEnd
}

/// Who hears that a command's process ended: the runner waiting for it or, once the runner let it go on
/// (`ProcessRunner.Detach`), whoever took it over. One lock decides which, so the end is told exactly once.
final class ChildEnd: Sendable {
    enum Wait: Sendable {
        case ended(ChildExit)
        /// The runner stopped waiting; the output goes to this log.
        case detached(FileHandle)
    }

    private struct State {
        var exit: ChildExit?
        var detached = false
        var listener: (@Sendable (ChildExit) -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let runner: AsyncStream<Wait>.Continuation

    init(runner: AsyncStream<Wait>.Continuation) { self.runner = runner }

    /// From `SpawnedProcess.watch`.
    func report(_ exit: ChildExit) {
        let (detached, listener) = state.withLock { state in
            state.exit = exit
            return (state.detached, state.listener)
        }
        if detached {
            listener?(exit)
        } else {
            runner.yield(.ended(exit))
            runner.finish()
        }
    }

    /// Ends the runner's wait while the process runs on. False when it has already ended (it is then waited for as usual).
    func detach(into log: FileHandle) -> Bool {
        let detached = state.withLock { state in
            guard state.exit == nil, !state.detached else { return false }
            state.detached = true
            return true
        }
        if detached {
            runner.yield(.detached(log))
            runner.finish()
        }
        return detached
    }

    /// After `detach`: `listener` is called once, when the process ends (at once if it has already).
    func onEnd(_ listener: @escaping @Sendable (ChildExit) -> Void) {
        let ended = state.withLock { state in
            state.listener = listener
            return state.exit
        }
        if let ended { listener(ended) }
    }
}

/// The merged output as it is read: the start and end for the result, and the whole stream in a file once it outgrows
/// the limit (everything before that is still in the buffer, so the file starts complete).
struct StreamCapture: Sendable {
    /// What the saved file may hold (like the log of a background job): a command that never stops printing (`yes`) fills
    /// the disk in minutes otherwise. The counts and the start and end kept in the result still cover the whole stream.
    static let maxSpillBytes = 50_000_000
    private var buffer: OutputBuffer
    private let spillTarget: URL?
    private let spillLimit: Int
    private var spill: FileHandle?
    private var spilledBytes = 0
    private var spillCut = false
    private var lines = 0
    private var binaryBytes = 0
    private var sampled = 0

    init(limit: Int, spillTo: URL?, spillLimit: Int = StreamCapture.maxSpillBytes) {
        buffer = OutputBuffer(limit: limit)
        spillTarget = spillTo
        self.spillLimit = spillLimit
    }

    mutating func append(_ data: Data) {
        data.withUnsafeBytes { raw in
            for byte in raw {
                if byte == 10 { lines += 1 }
            }
        }
        // Binary data is spotted on the first kilobytes; the rest of the stream does not change the verdict.
        if sampled < 4_096 {
            for byte in data.prefix(4_096 - sampled) where byte == 0 { binaryBytes += 1 }
            sampled += min(data.count, 4_096 - sampled)
        }
        if let spillTarget, spill == nil, !spillCut, buffer.totalBytes + data.count > buffer.limit {
            let manager = FileManager.default
            try? manager.createDirectory(at: spillTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.createFile(atPath: spillTarget.path, contents: buffer.bytes) {
                spill = try? FileHandle(forWritingTo: spillTarget)
                _ = try? spill?.seekToEnd()
                spilledBytes = buffer.bytes.count
            }
        }
        if let handle = spill {
            let room = max(spillLimit - spilledBytes, 0)
            if data.count > room {
                // Stop at the limit: the file ends here, the rest of the stream is only counted.
                if room > 0 { try? handle.write(contentsOf: data.prefix(room)) }
                try? handle.close()
                spill = nil
                spillCut = true
                spilledBytes = spillLimit
            } else {
                try? handle.write(contentsOf: data)
                spilledBytes += data.count
            }
        }
        buffer.append(data)
    }

    /// Closes the file and gives the result.
    mutating func finish() -> (text: String, bytes: Int, lines: Int, file: URL?, fileCut: Bool, isBinary: Bool) {
        try? spill?.close()
        let wrote = spill != nil || spillCut
        spill = nil
        // The last line may have no newline.
        let total = buffer.totalBytes
        let text = buffer.text
        return (text, total, lines + (total > 0 && !text.hasSuffix("\n") ? 1 : 0), wrote ? spillTarget : nil, spillCut, looksBinary(text))
    }

    /// NUL bytes in the first kilobytes, or mostly replacement and control characters: not text to show a model.
    private func looksBinary(_ text: String) -> Bool {
        if binaryBytes > 0, sampled > 0, binaryBytes * 20 >= sampled { return true }
        var bad = 0
        var total = 0
        for scalar in text.unicodeScalars.prefix(4_096) {
            total += 1
            if scalar.value == 0xFFFD || scalar.value == 0 || (scalar.value < 0x20 && ![9, 10, 13, 27].contains(scalar.value)) { bad += 1 }
        }
        return total >= 32 && bad * 4 >= total
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

    /// Bytes read so far, kept or not.
    var totalBytes: Int { head.count + tail.count + droppedBytes }
    /// The stream itself, while nothing has been dropped.
    var bytes: Data { head + tail }
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
