import Foundation
import os

/// How a spawned process ended.
struct ChildExit: Sendable, Equatable {
    /// Exit code, or the signal number when `signaled`.
    var status: Int32
    var signaled: Bool
}

/// Starts a process with `posix_spawn`, so arguments and environment reach it byte for byte.
///
/// Foundation's `Process` turns every argument and environment value into decomposed Unicode (é becomes
/// e + U+0301), so `git commit -m "João"` or `export NOME=João` would arrive as something other than what was
/// written. It also hides what ended a process that a shell would have `exec`ed. Here the child is:
/// - the leader of a new process group (pgid == pid), so signalling `-pid` reaches everything it launches;
/// - given only the three descriptors below (nothing else leaks into it, even from concurrent spawns);
/// - started with default signal handling and an empty signal mask.
enum SpawnedProcess {
    /// Starts `executable` (a full path) and returns its pid. `environment` nil inherits the app's own.
    /// `output` is used for both stdout and stderr, and stdin is empty, unless `error` or `input` give descriptors for
    /// those. The caller still owns (and should close) the descriptors it passes.
    static func start(_ executable: String, _ arguments: [String], directory: URL?, environment: [String: String]?,
                      output: Int32, error: Int32? = nil, input: Int32? = nil) throws -> pid_t {
        let environment = environment ?? ProcessInfo.processInfo.environment
        let argv = try cStrings([executable] + arguments)
        let envp = try cStrings(environment.map { "\($0.key)=\($0.value)" })
        defer { (argv + envp).forEach { free($0) } }

        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw ToolError("Não consegui preparar o processo.") }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ToolError("Não consegui preparar o processo.") }
        defer { posix_spawn_file_actions_destroy(&actions) }

        var noSignals = sigset_t()
        var everySignal = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&everySignal)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
                                                    | POSIX_SPAWN_CLOEXEC_DEFAULT))
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory.path) }
        if let input {
            posix_spawn_file_actions_adddup2(&actions, input, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, error ?? output, 2)

        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable, &actions, &attributes, argv + [nil], envp + [nil])
        guard code == 0 else { throw ToolError(String(cString: strerror(code))) }
        return pid
    }

    /// Calls `onExit` once, when `pid` (a child of this app) ends. Reaps it. No thread waits for it: a process source (kqueue)
    /// reports the exit, so many long-lived children (dev servers, watchers) do not use up the threads of the global queues.
    static func watch(_ pid: pid_t, onExit: @escaping @Sendable (ChildExit) -> Void) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        let claimed = OSAllocatedUnfairLock(initialState: false)
        // The event and the check below can both see the exit; only the first one reaps and reports.
        let finish: @Sendable () -> Void = {
            guard claimed.withLock({ taken in defer { taken = true }; return !taken }) else { return }
            source.cancel()
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0 {
                if errno != EINTR { return onExit(ChildExit(status: -1, signaled: false)) }
            }
            // WIFEXITED / WIFSIGNALED, which Swift does not import.
            let signal = raw & 0x7f
            onExit(signal == 0 ? ChildExit(status: (raw >> 8) & 0xff, signaled: false) : ChildExit(status: signal, signaled: true))
        }
        source.setEventHandler(handler: finish)
        source.resume()
        // A child that ended before the source was listening (it is a zombie by now) never produces the event.
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 || info.si_pid != 0 { finish() }
    }

    private static func cStrings(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = []
        for string in strings {
            guard !string.utf8.contains(0) else {
                result.forEach { free($0) }
                throw ToolError("O comando ou o ambiente contém um byte nulo, que o sistema não aceita.")
            }
            result.append(strdup(string))
        }
        return result
    }
}

/// The process groups of the commands and CLIs that are running now (`ProcessRunner`, `LineProcess`). Each child leads a group
/// of its own, so it does not die with the app: quitting in the middle of a turn would leave a build or `claude` running.
/// `willTerminate` stops them all with `killAllNow`.
enum ChildProcessGroups {
    private static let live = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    static var running: Set<pid_t> { live.withLock { $0 } }

    static func insert(_ pid: pid_t) { live.withLock { _ = $0.insert(pid) } }
    static func remove(_ pid: pid_t) { live.withLock { _ = $0.remove(pid) } }

    /// SIGTERM to every registered group (and to `extra`), SIGKILL to what is still there half a second later. `only` limits
    /// it to those groups (for tests, which share the registry with each other). Blocks for at most half a second.
    static func killAllNow(including extra: [pid_t] = [], only: Set<pid_t>? = nil) {
        let registered = live.withLock { only.map($0.intersection) ?? $0 }
        ProcessGroups.terminate(Array(registered) + (only == nil ? extra : []), grace: .milliseconds(500))
    }
}
