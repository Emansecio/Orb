import Foundation

/// The environment commands run in: what the user's own Terminal would have.
///
/// A Mac app starts with launchd's bare environment, and a plain `zsh -lc` skips `~/.zshrc`, where people put
/// their PATH (npm, Android platform-tools, Homebrew…) and variables like JAVA_HOME. So the user's login +
/// interactive shell is asked once for its environment, which is cached and handed to every command; commands
/// then run with `-c` and never re-run the profile files.
actor ShellEnvironment {
    static let shared = ShellEnvironment()

    /// What commands run with, and the shell that runs them.
    struct Resolved: Sendable, Equatable {
        var environment: [String: String]
        /// Path of the shell that runs `-c` commands.
        var shell: String
        /// False when the user's shell could not be asked and the app's own environment stands in.
        var isFromUserShell: Bool
    }

    private let shellPath: String
    private let base: [String: String]
    private let timeout: Duration
    private var cached: (value: Resolved, at: ContinuousClock.Instant)?
    private var resolving: Task<Resolved, Never>?

    /// A fallback is retried after this long; a real answer is kept until the app quits.
    private static let retryAfter = Duration.seconds(300)

    /// `shell` defaults to the user's login shell; `base` is the environment used as fallback and as a starting point.
    init(shell: String? = nil, base: [String: String] = ProcessInfo.processInfo.environment, timeout: Duration = .seconds(5)) {
        shellPath = shell ?? Self.loginShell(in: base)
        self.base = base
        self.timeout = timeout
    }

    func resolved() async -> Resolved {
        if let cached, cached.value.isFromUserShell || ContinuousClock.now - cached.at < Self.retryAfter { return cached.value }
        if let resolving { return await resolving.value }
        let task = Task { await self.resolve() }
        resolving = task
        let value = await task.value
        resolving = nil
        cached = (value, .now)
        return value
    }

    // MARK: Resolving

    private static let marker = "__ORB_ENV_BEGIN__"

    private func resolve() async -> Resolved {
        let runner = Self.commandShell(for: shellPath)
        let fallback = Resolved(environment: Self.prepared(base), shell: runner, isFromUserShell: false)
        guard FileManager.default.isExecutableFile(atPath: shellPath),
              let result = try? await ProcessRunner.run(shellPath, ["-lic", "printf '\(Self.marker)'; env -0"],
                                                        directory: FileManager.default.homeDirectoryForCurrentUser,
                                                        environment: base, timeout: timeout, outputLimit: 4_000_000),
              !result.timedOut, result.status == 0, let parsed = Self.parse(result.output), parsed["PATH"] != nil
        else { return fallback }
        return Resolved(environment: Self.prepared(parsed), shell: runner, isFromUserShell: true)
    }

    /// The variables printed by `env -0` after the marker. Anything before it (a noisy `.zshrc`) or after the
    /// last NUL (an exit message) is ignored; nil when the marker never appeared.
    static func parse(_ output: String) -> [String: String]? {
        guard let start = output.range(of: marker) else { return nil }
        var entries = output[start.upperBound...].split(separator: "\0", omittingEmptySubsequences: false)
        entries.removeLast() // not NUL-terminated: stray text, or the empty piece after the final NUL
        var environment: [String: String] = [:]
        for entry in entries {
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
            let name = entry[..<equals]
            guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { continue }
            environment[String(name)] = String(entry[entry.index(after: equals)...])
        }
        return environment
    }

    // MARK: Cleaning up

    /// Markers of an enclosing Claude Code session or SDK host, which must not leak into a child.
    static func isClaudeSessionVariable(_ name: String) -> Bool {
        name == "CLAUDECODE" || name.hasPrefix("CLAUDE_CODE_") || name.hasPrefix("CLAUDE_AGENT_SDK_")
    }

    /// Variables that describe this app or the way it was launched, not the user's Terminal.
    static func leaksFromApp(_ name: String) -> Bool {
        isClaudeSessionVariable(name) || name.hasPrefix("ORB_") || name.hasPrefix("DYLD_")
            || ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "OS_ACTIVITY_DT_MODE", "PWD", "OLDPWD", "_"].contains(name)
    }

    /// `environment` minus what leaks from the app, plus the settings that keep command output readable:
    /// no pager, no terminal tricks, and git printing accented file names as they are.
    static func prepared(_ environment: [String: String]) -> [String: String] {
        var result = environment.filter { !leaksFromApp($0.key) }
        result["TERM"] = "dumb"
        result["PAGER"] = "cat"
        result["GIT_PAGER"] = "cat"
        // Appended after whatever the user's own environment already configures through GIT_CONFIG_*.
        let existing = result["GIT_CONFIG_COUNT"].flatMap { Int($0) }.map { max($0, 0) } ?? 0
        result["GIT_CONFIG_COUNT"] = String(existing + 1)
        result["GIT_CONFIG_KEY_\(existing)"] = "core.quotepath"
        result["GIT_CONFIG_VALUE_\(existing)"] = "false"
        return result
    }

    // MARK: Shells

    /// `$SHELL`, else the account's shell, else zsh.
    static func loginShell(in environment: [String: String]) -> String {
        if let shell = environment["SHELL"], shell.hasPrefix("/") { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if path.hasPrefix("/") { return path }
        }
        return "/bin/zsh"
    }

    /// Runs commands with the user's shell when it speaks the syntax models write (zsh, bash); fish, nushell and
    /// the like get zsh, which every Mac has.
    static func commandShell(for shell: String) -> String {
        ["zsh", "bash"].contains((shell as NSString).lastPathComponent) && FileManager.default.isExecutableFile(atPath: shell)
            ? shell : "/bin/zsh"
    }
}
