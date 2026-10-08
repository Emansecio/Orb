import Foundation
import os

/// Commands that keep running after `run_command` returns (dev servers, watchers, long builds).
///
/// Each job is a shell in its own process group writing to a log file, so nothing depends on a pipe that
/// closes with the tool call. Jobs belong to one Orb and end when stopped, when the Orb is deleted or when
/// the app quits.
actor BackgroundJobs {
    enum State: Sendable, Equatable {
        case running
        case exited(Int32)
        /// Killed by a signal nobody here sent (a crash, an outside `kill`).
        case signaled(Int32)
        /// Ended by `stop`, `forget` or quitting.
        case stopped
    }

    struct Snapshot: Sendable, Equatable {
        var id: String
        var command: String
        var directory: String
        var logPath: String
        var startedAt: Date
        var endedAt: Date?
        var state: State
        /// The shell ended but something it launched (`server &`) is still running in the job's process group.
        var leftoverRunning = false

        var isRunning: Bool { state == .running }
        /// Still holds processes, which counts against the limit and can be stopped.
        var isActive: Bool { state == .running || leftoverRunning }

        /// Portuguese status for the model and the transcript.
        var statusText: String {
            let base = switch state {
            case .running: "rodando há \(Self.duration(Date.now.timeIntervalSince(startedAt)))"
            case .exited(let code): "terminou com código \(code)\(Signals.hint(forExitCode: code))"
            case .signaled(let number): "encerrado pelo sinal \(Signals.describe(number))"
            case .stopped: "parado"
            }
            return leftoverRunning ? base + ", mas processos que ele iniciou continuam rodando (job_stop encerra)" : base
        }

        private static func duration(_ seconds: TimeInterval) -> String {
            let total = Int(seconds)
            return total < 60 ? "\(total) s" : total < 3600 ? "\(total / 60) min" : "\(total / 3600) h \(total % 3600 / 60) min"
        }
    }

    private struct Job {
        var snapshot: Snapshot
        let pid: pid_t
        var stopRequested = false
        var logWatch: Task<Void, Never>?
    }

    /// Running jobs one Orb may have at the same time.
    static let maxRunningPerOrb = 8
    /// A log past this size is emptied, so a chatty server cannot fill the disk.
    static let maxLogBytes = 50_000_000

    private let directory: URL
    private var jobs: [UUID: [String: Job]] = [:]
    private var lastID: [UUID: Int] = [:]
    /// Process groups that may still have members. Kept outside the actor's isolation so quitting can kill
    /// them synchronously from `willTerminate`.
    private let liveGroups = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    /// How long `start` looks at the log for the first output.
    private let firstOutputWindow: Duration
    /// Stop looking as soon as the log has something in it, instead of for the whole window.
    private let endsAtFirstOutput: Bool

    /// How often `watchGroup` looks at whether the job's process group is empty.
    private let watchInterval: Duration

    /// The last three parameters exist for tests. With a long first-output window that ends at the first output,
    /// "the first output is in the result" does not depend on how fast the machine starts a shell; with a short
    /// watch interval, `stop` meets the group watcher between its kill and its final check every time.
    init(directory: URL = FileManager.default.temporaryDirectory.appending(path: "orb-jobs"),
         firstOutputWindow: Duration = .seconds(1), endsAtFirstOutput: Bool = false, watchInterval: Duration = .seconds(1)) {
        self.directory = directory
        self.firstOutputWindow = firstOutputWindow
        self.endsAtFirstOutput = endsAtFirstOutput
        self.watchInterval = watchInterval
    }

    // MARK: Starting

    /// Starts `command` with `shell -c` and returns the job with the first output (up to about a second of it,
    /// less when the command ends sooner).
    func start(botID: UUID, command: String, directory workingDirectory: URL, shell: String,
               environment: [String: String]) async throws -> (job: Snapshot, firstOutput: String) {
        let running = jobs[botID, default: [:]].values.filter { $0.snapshot.isActive }.count
        guard running < Self.maxRunningPerOrb else {
            throw ToolError("Já há \(running) processos em segundo plano rodando. Pare algum com job_stop antes de iniciar outro.")
        }
        let id = String((lastID[botID] ?? 0) + 1)
        let botDirectory = directory.appending(path: botID.uuidString)
        let log = botDirectory.appending(path: "\(id).log")
        do { try FileManager.default.createDirectory(at: botDirectory, withIntermediateDirectories: true) } catch {
            throw ToolError("Não consegui criar a pasta de logs: \(error.localizedDescription)")
        }
        // O_APPEND so that emptying an oversized log does not leave the child writing past a hole.
        let descriptor = open(log.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o600)
        guard descriptor >= 0 else { throw ToolError("Não consegui criar o arquivo de log \(log.path).") }
        defer { close(descriptor) }

        let pid: pid_t
        do {
            pid = try SpawnedProcess.start(shell, ["-c", command], directory: workingDirectory, environment: environment,
                                           output: descriptor)
        } catch {
            try? FileManager.default.removeItem(at: log)
            throw ToolError("Não consegui iniciar o comando: \(error.localizedDescription)")
        }
        // SpawnedProcess starts the child as the leader of a new process group (pgid == pid), so signalling -pid
        // reaches the whole tree.
        liveGroups.withLock { _ = $0.insert(pid) }
        SpawnedProcess.watch(pid) { [weak self] exit in
            Task { await self?.ended(botID: botID, id: id, exit: exit) }
        }
        lastID[botID] = (lastID[botID] ?? 0) + 1
        let snapshot = Snapshot(id: id, command: command, directory: workingDirectory.path, logPath: log.path,
                                startedAt: .now, state: .running)
        var job = Job(snapshot: snapshot, pid: pid)
        job.logWatch = Task { [weak self] in await self?.watchGroup(botID: botID, id: id, pid: pid, log: log) }
        jobs[botID, default: [:]][id] = job

        let deadline = ContinuousClock.now + firstOutputWindow
        while jobs[botID]?[id]?.snapshot.isRunning == true, !Task.isCancelled, ContinuousClock.now < deadline,
              !(endsAtFirstOutput && Self.hasOutput(log)) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (jobs[botID]?[id]?.snapshot ?? snapshot, Self.tail(of: log, lines: 40))
    }

    // MARK: Looking

    func list(botID: UUID) -> [Snapshot] {
        (jobs[botID] ?? [:]).values.map(\.snapshot).sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
    }

    func output(botID: UUID, id: String, lines: Int) throws -> (job: Snapshot, text: String) {
        let job = try find(botID, id)
        return (job.snapshot, Self.tail(of: URL(fileURLWithPath: job.snapshot.logPath), lines: lines))
    }

    // MARK: Stopping

    /// SIGTERM to the job's whole process group, SIGKILL if something is still there after 2 seconds.
    func stop(botID: UUID, id: String) async throws -> Snapshot {
        _ = try find(botID, id)
        await terminate(botID, [id])
        return try find(botID, id).snapshot
    }

    /// Stops every job of the Orb and deletes its logs (the Orb was deleted).
    func forget(botID: UUID) async {
        await terminate(botID, Array((jobs[botID] ?? [:]).keys))
        jobs[botID] = nil
        lastID[botID] = nil
        try? FileManager.default.removeItem(at: directory.appending(path: botID.uuidString))
    }

    /// Kills every job's process group right away and deletes the logs; for `willTerminate`, which cannot wait
    /// for the actor. Blocks for at most half a second.
    nonisolated func killAllNow() {
        let groups = liveGroups.withLock { Array($0) }.filter { kill(-$0, 0) == 0 }
        groups.forEach { kill(-$0, SIGTERM) }
        let deadline = Date.now.addingTimeInterval(0.5)
        while Date.now < deadline, groups.contains(where: { kill(-$0, 0) == 0 }) { usleep(20_000) }
        groups.filter { kill(-$0, 0) == 0 }.forEach { kill(-$0, SIGKILL) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func terminate(_ botID: UUID, _ ids: [String]) async {
        var targets: [(id: String, pid: pid_t)] = []
        for id in ids {
            // Only a group still known to belong to the job: once it is empty its id may be someone else's.
            guard var job = jobs[botID]?[id], isLive(job.pid) else { continue }
            job.stopRequested = job.snapshot.isActive
            jobs[botID]?[id] = job
            kill(-job.pid, SIGTERM)
            targets.append((id, job.pid))
        }
        await waitUntilGone(targets.map(\.pid), seconds: 2)
        targets.filter { isLive($0.pid) }.forEach { kill(-$0.pid, SIGKILL) }
        await waitUntilGone(targets.map(\.pid), seconds: 1)
        for target in targets {
            forgetGroupIfGone(target.pid)
            // The termination handler normally got here first; if it is late, record the stop now. A job whose shell had
            // ended and left children behind has no handler to wait for, and `watchGroup` may have noticed the empty
            // group first and cleared `leftoverRunning`: the stop that emptied it is still a stop.
            if var job = jobs[botID]?[target.id], !groupExists(target.pid),
               job.snapshot.isActive || (job.stopRequested && job.snapshot.state != .stopped) {
                job.snapshot.state = .stopped
                job.snapshot.leftoverRunning = false
                job.snapshot.endedAt = job.snapshot.endedAt ?? .now
                job.logWatch?.cancel()
                jobs[botID]?[target.id] = job
            }
        }
    }

    // MARK: Bookkeeping

    private func find(_ botID: UUID, _ id: String) throws -> Job {
        guard let job = jobs[botID]?[id] else {
            let known = (jobs[botID] ?? [:]).keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
            throw ToolError("Não existe o processo em segundo plano \"\(id)\"."
                + (known.isEmpty ? " Este Orb não tem nenhum." : " Os deste Orb: \(known.joined(separator: ", ")). job_list mostra todos."))
        }
        return job
    }

    private func ended(botID: UUID, id: String, exit: ChildExit) {
        guard var job = jobs[botID]?[id], job.snapshot.isRunning else { return }
        job.snapshot.state = job.stopRequested ? .stopped : exit.signaled ? .signaled(exit.status) : .exited(exit.status)
        job.snapshot.endedAt = .now
        // The shell is gone, but a `cmd &` it started may still be running and holding a port.
        job.snapshot.leftoverRunning = !job.stopRequested && groupExists(job.pid)
        if !job.snapshot.leftoverRunning { job.logWatch?.cancel() }
        jobs[botID]?[id] = job
        // Once the group is empty its id may be reused by someone else, so it must never be signalled again.
        forgetGroupIfGone(job.pid)
    }

    private func groupExists(_ pid: pid_t) -> Bool { kill(-pid, 0) == 0 }

    /// The group exists and is still recorded as one of ours (see `liveGroups`).
    private func isLive(_ pid: pid_t) -> Bool { liveGroups.withLock { $0.contains(pid) } && groupExists(pid) }

    private func forgetGroupIfGone(_ pid: pid_t) {
        if !groupExists(pid) { liveGroups.withLock { _ = $0.remove(pid) } }
    }

    private func waitUntilGone(_ pids: [pid_t], seconds: Int) async {
        for _ in 0..<(seconds * 20) where pids.contains(where: groupExists) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// For as long as the job's process group has members: notices when it empties (so its id is never signalled
    /// after it could have been reused) and empties the log when it grows past `maxLogBytes`.
    private func watchGroup(botID: UUID, id: String, pid: pid_t, log: URL) async {
        var ticks = 0
        while !Task.isCancelled, groupExists(pid) {
            try? await Task.sleep(for: watchInterval)
            ticks += 1
            guard ticks % 10 == 0 else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
            if size > Self.maxLogBytes, let handle = try? FileHandle(forWritingTo: log) {
                try? handle.truncate(atOffset: 0)
                try? handle.close()
            }
        }
        forgetGroupIfGone(pid)
        if jobs[botID]?[id]?.snapshot.leftoverRunning == true, !groupExists(pid) {
            jobs[botID]?[id]?.snapshot.leftoverRunning = false
        }
    }

    // MARK: Reading logs

    private static func hasOutput(_ log: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0) > 0
    }

    /// The last `lines` lines of a log (at most the last 64 KB read, 20 000 characters shown), cut on
    /// character boundaries.
    static func tail(of log: URL, lines: Int, maxBytes: Int = 64_000, maxCharacters: Int = 20_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return "" }
        // Reading from the middle of the file may start inside a character or a line.
        var text = String(decoding: data.drop { $0 & 0xC0 == 0x80 }, as: UTF8.self)
        if offset > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        var all = text.split(separator: "\n", omittingEmptySubsequences: false)
        if all.last == "" { all.removeLast() }
        let result = all.suffix(lines).joined(separator: "\n")
        return result.count > maxCharacters ? "[... início omitido ...]\n" + result.suffix(maxCharacters) : result
    }
}
