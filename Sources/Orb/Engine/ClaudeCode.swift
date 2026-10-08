import Foundation

// "Claude Code (sua assinatura)": Orb runs the user's own, unmodified `claude` CLI headless, and the user
// signs in through Claude Code's own flow (`claude auth login`). Per Anthropic's policy
// (https://code.claude.com/docs/en/legal-and-compliance, "Authentication and credential use"), Orb never
// reads, copies or stores Claude Code's credentials and never calls Anthropic with them: it only launches the CLI.

struct ClaudeCodeStatus: Equatable, Sendable {
    var isInstalled = false
    var isLoggedIn = false
    /// `none`, `claude.ai`, `oauth_token`, `api_key`, `api_key_helper` or `third_party`.
    var authMethod: String?
    var email: String?
    /// `subscriptionType` for Claude accounts (e.g. "pro", "max").
    var plan: String?
    var organization: String?

    /// Parses `claude auth status --json`; anything around the JSON object (warnings) is ignored.
    static func parse(_ output: String) -> ClaudeCodeStatus {
        var status = ClaudeCodeStatus(isInstalled: true)
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let json = JSONValue.parse(String(output[start...end])) else { return status }
        status.isLoggedIn = json["loggedIn"]?.bool ?? false
        status.authMethod = json["authMethod"]?.string
        status.email = json["email"]?.string
        status.plan = json["subscriptionType"]?.string
        status.organization = json["orgName"]?.string
        return status
    }

    /// "fulano@x.com · Claude Max" (pt-BR, for Ajustes).
    var accountLabel: String {
        let method: String? = switch authMethod {
        case "claude.ai": plan.map { "Claude \($0.prefix(1).uppercased() + $0.dropFirst())" } ?? "Conta Claude"
        case "api_key", "api_key_helper": "Chave de API"
        case "third_party": "Provedor de nuvem"
        default: nil
        }
        let parts = [email, method].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Conectado" : parts.joined(separator: " · ")
    }
}

actor ClaudeCode {
    static let shared = ClaudeCode()
    static let setupPage = URL(string: "https://code.claude.com/docs/en/setup")

    struct Installation: Equatable, Sendable {
        var executable: URL
        /// The login shell's PATH, so Claude Code's tools find what the user's Terminal finds.
        var path: String
    }

    private var cached: Installation?

    // MARK: Installation

    /// Finds `claude`: `ORB_CLAUDE_PATH` (dev/tests), then the login shell, then the usual install folders.
    func installation(refresh: Bool = false) async -> Installation? {
        if let cached, !refresh, FileManager.default.isExecutableFile(atPath: cached.executable.path) { return cached }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let script = "printf '\(Self.marker)claude=%s\\n' \"$(command -v claude)\"; printf '\(Self.marker)path=%s\\n' \"$PATH\""
        let probe = try? await ProcessRunner.run(shell, ["-l", "-c", script], timeout: .seconds(15))
        let found = Self.parseShellProbe(probe?.output ?? "")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [ProcessInfo.processInfo.environment["ORB_CLAUDE_PATH"], found.claude,
                          "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let executable = candidates.compactMap({ $0 }).first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) })
        else {
            cached = nil
            return nil
        }
        let directory = (executable as NSString).deletingLastPathComponent
        var path = found.path ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !path.split(separator: ":").contains(Substring(directory)) { path = directory + ":" + path }
        cached = Installation(executable: URL(fileURLWithPath: executable), path: path)
        return cached
    }

    private static let marker = "__orb__"

    /// Reads `__orb__claude=…` / `__orb__path=…` lines; anything else a login shell prints is ignored.
    static func parseShellProbe(_ output: String) -> (claude: String?, path: String?) {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(marker) {
            let pair = line.dropFirst(marker.count).split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2, !pair[1].isEmpty { values[pair[0]] = pair[1] }
        }
        return (values["claude"], values["path"])
    }

    /// The CLI's environment: ours without the markers of an enclosing Claude Code session (or SDK host),
    /// which would otherwise leak into the child, and with the login shell's PATH.
    static func environment(_ base: [String: String], path: String) -> [String: String] {
        var environment = base.filter { !ShellEnvironment.isClaudeSessionVariable($0.key) }
        environment["PATH"] = path
        return environment
    }

    func environment(for installation: Installation) -> [String: String] {
        Self.environment(ProcessInfo.processInfo.environment, path: installation.path)
    }

    // MARK: Account (Claude Code's own commands)

    func status() async -> ClaudeCodeStatus {
        guard let installation = await installation(refresh: true) else { return ClaudeCodeStatus() }
        // Exits 1 when logged out; the JSON says so either way.
        guard let output = try? await run(installation, ["auth", "status", "--json"]) else {
            return ClaudeCodeStatus(isInstalled: true)
        }
        return ClaudeCodeStatus.parse(output)
    }

    /// Runs `claude auth login --claudeai`: Claude Code opens the browser and finishes the sign-in itself.
    /// Returns when the command ends (or after 5 minutes).
    func login() async throws {
        guard let installation = await installation() else { throw ToolError("O Claude Code não está instalado neste Mac.") }
        let process = try LineProcess(executable: installation.executable, arguments: ["auth", "login", "--claudeai"],
                                      directory: FileManager.default.homeDirectoryForCurrentUser,
                                      environment: environment(for: installation))
        process.terminate(after: 300)
        await withTaskCancellationHandler {
            // Stdin stays open: the CLI also accepts a pasted code there; we only wait for it to finish.
            for await _ in process.lines {}
        } onCancel: {
            process.terminate(after: 0)
        }
        process.closeInput()
    }

    func logout() async {
        guard let installation = await installation() else { return }
        _ = try? await run(installation, ["auth", "logout"])
    }

    /// Runs a short CLI command with our environment and returns its stdout.
    private func run(_ installation: Installation, _ arguments: [String]) async throws -> String {
        let process = try LineProcess(executable: installation.executable, arguments: arguments,
                                      directory: FileManager.default.homeDirectoryForCurrentUser,
                                      environment: environment(for: installation))
        process.closeInput()
        process.terminate(after: 20)
        var lines: [String] = []
        for await line in process.lines { lines.append(line) }
        return lines.joined(separator: "\n")
    }

    // MARK: Models

    /// The models Claude Code offers this account, from its `initialize` answer (no prompt is sent, so nothing
    /// is used from the plan). Falls back to the documented aliases if the CLI does not answer.
    func models() async throws -> [ProviderModel] {
        guard let installation = await installation() else { throw ToolError("O Claude Code não está instalado neste Mac.") }
        let process = try LineProcess(
            executable: installation.executable,
            arguments: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                        "--no-session-persistence", "--strict-mcp-config"],
            directory: FileManager.default.temporaryDirectory, environment: environment(for: installation))
        let requestID = ClaudeCodeWire.newRequestID()
        process.send(ClaudeCodeWire.controlRequest(id: requestID, subtype: "initialize"))
        process.terminate(after: 30)
        defer {
            process.closeInput()
            process.terminate(after: 3)
        }
        for await line in process.lines {
            if let models = ClaudeCodeWire.models(fromInitializeResponse: line, requestID: requestID), !models.isEmpty {
                return models
            }
        }
        return ClaudeCodeModels.fallback
    }
}
