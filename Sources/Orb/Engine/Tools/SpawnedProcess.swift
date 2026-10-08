import Foundation

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
    /// `output` is used for both stdout and stderr; stdin is empty. The caller still owns (and should close) `output`.
    static func start(_ executable: String, _ arguments: [String], directory: URL?, environment: [String: String]?,
                      output: Int32) throws -> pid_t {
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
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, output, 2)

        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable, &actions, &attributes, argv + [nil], envp + [nil])
        guard code == 0 else { throw ToolError(String(cString: strerror(code))) }
        return pid
    }

    /// Calls `onExit` once, when `pid` (a child of this app) ends. Reaps it.
    static func watch(_ pid: pid_t, onExit: @escaping @Sendable (ChildExit) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0 {
                if errno != EINTR { return onExit(ChildExit(status: -1, signaled: false)) }
            }
            // WIFEXITED / WIFSIGNALED, which Swift does not import.
            let signal = raw & 0x7f
            onExit(signal == 0 ? ChildExit(status: (raw >> 8) & 0xff, signaled: false) : ChildExit(status: signal, signaled: true))
        }
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
