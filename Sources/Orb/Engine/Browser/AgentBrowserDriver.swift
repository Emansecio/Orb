import Foundation
import os

/// How one Orb's browser is launched by `agent-browser`: the session (one browser per Orb, kept alive by agent-browser's
/// own background process between commands), the engine, and the persistent profile folder where logins stay.
struct AgentBrowserConfig: Sendable, Equatable {
    var executable: String
    var session: String
    var engine: BrowserEngineKind
    /// Obscura's binary, or CloakBrowser's Chromium (`--executable-path`).
    var browserExecutable: String?
    /// The folder that keeps cookies and logins between runs (Chrome and CloakBrowser; Obscura has none).
    var profile: URL?
    /// A visible window instead of the background browser (only for the person to finish a login).
    var headed = false
    /// CloakBrowser's fingerprint seed (`--fingerprint=`): the same for the same profile, so a site sees one browser over time.
    var cloakSeed = CloakSeed.range.lowerBound
    /// Lets pages at `file://` load (tests, local pages); off for the Orb's browsing.
    var allowFileAccess = false

    /// The session of an Orb for an engine. Another engine is another browser, so it gets another session (a running browser
    /// keeps the settings it was launched with).
    static func sessionName(botID: UUID, engine: BrowserEngineKind) -> String {
        "orb-\(botID.uuidString.prefix(8).lowercased())-\(engine.rawValue)"
    }

    /// Flags every command carries: which browser, and JSON replies.
    var globalArguments: [String] { ["--session", session, "--json"] }

    /// What CloakBrowser's own wrapper passes to its Chromium on macOS (`get_default_stealth_args`).
    var cloakArguments: [String] { ["--no-sandbox", "--fingerprint=\(cloakSeed)", "--fingerprint-platform=macos"] }

    /// Flags only the command that launches the browser (`open`) needs; a running browser keeps the ones it started with.
    var launchArguments: [String] {
        var arguments: [String] = []
        switch engine {
        case .simple:
            break
        case .chrome:
            if let profile { arguments += ["--profile", profile.path] }
            if headed { arguments.append("--headed") }
        case .obscura:
            // Obscura has no profile and no window: agent-browser rejects both with it.
            arguments += ["--engine", "obscura"]
            if let browserExecutable { arguments += ["--executable-path", browserExecutable] }
        case .cloak:
            if let browserExecutable { arguments += ["--executable-path", browserExecutable] }
            arguments += ["--args", cloakArguments.joined(separator: ",")]
            if let profile { arguments += ["--profile", profile.path] }
            if headed { arguments.append("--headed") }
        }
        if allowFileAccess { arguments.append("--allow-file-access") }
        return arguments
    }
}

/// CloakBrowser keeps one fingerprint seed per profile in `<profile>/.cloakbrowser-seed` (a decimal number and a newline), so
/// a login does not meet a new "device" every run. This reads and writes the same file its wrappers do.
enum CloakSeed {
    static let range = 10_000...99_999
    static let fileName = ".cloakbrowser-seed"

    static func seed(inProfile profile: URL) -> Int {
        let file = profile.appending(path: fileName)
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let seed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), range.contains(seed) {
            return seed
        }
        let seed = Int.random(in: range)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try? "\(seed)\n".write(to: file, atomically: true, encoding: .utf8)
        return seed
    }
}

/// Runs the `agent-browser` command line. A parameter of the driver so tests can answer without a browser.
typealias BrowserCommandRunner = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String]?,
                                            _ timeout: Duration) async throws -> ProcessOutput

/// A reply of the command line with `--json`: `{"success":true,"data":{…},"error":null}`.
struct AgentBrowserReply: Sendable, Equatable {
    var success: Bool
    var data: JSONValue?
    var error: String?

    /// The reply in the output of a command. Warnings and notes may share the stream (it is merged with the error output), so
    /// the reply is the last line that is a JSON object with a `success`.
    static func parse(_ output: String) -> AgentBrowserReply? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("{"), let json = JSONValue.parse(text), case .object = json, let success = json["success"]?.bool else { continue }
            return AgentBrowserReply(success: success, data: json["data"], error: json["error"]?.string)
        }
        return nil
    }
}

/// Drives a browser through `agent-browser <flags> <command>` (https://github.com/vercel-labs/agent-browser): one process per
/// command, with its background process keeping the browser open between them.
final class AgentBrowserDriver: BrowserDriver, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<AgentBrowserConfig>
    private let run: BrowserCommandRunner
    private let environment: @Sendable () async -> [String: String]?

    var config: AgentBrowserConfig { state.withLock { $0 } }

    /// The longest a page load, or the first launch of the browser, is waited for.
    static let openTimeout = Duration.seconds(75)
    static let commandTimeout = Duration.seconds(45)
    /// Output above this would be cut in the middle and no longer be JSON (a snapshot of a huge page).
    static let outputLimit = 8_000_000

    init(config: AgentBrowserConfig, environment: @escaping @Sendable () async -> [String: String]? = { await ShellEnvironment.shared.resolved().environment },
         run: @escaping BrowserCommandRunner = AgentBrowserDriver.processRunner) {
        state = OSAllocatedUnfairLock(initialState: config)
        self.environment = environment
        self.run = run
    }

    static let processRunner: BrowserCommandRunner = { executable, arguments, environment, timeout in
        try await ProcessRunner.run(executable, arguments, directory: FileManager.default.homeDirectoryForCurrentUser,
                                    environment: environment, timeout: timeout, outputLimit: outputLimit)
    }

    // MARK: Commands

    /// Runs one command and returns the `data` of the reply, or throws what went wrong.
    @discardableResult
    func send(_ command: [String], launching: Bool = false, timeout: Duration = AgentBrowserDriver.commandTimeout) async throws -> JSONValue {
        let current = config
        let arguments = current.globalArguments + (launching ? current.launchArguments : []) + command
        let output: ProcessOutput
        do {
            output = try await run(current.executable, arguments, await environment(), timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BrowserDriverError.notInstalled("agent-browser could not be started (\(current.executable)): \(error.localizedDescription)")
        }
        if output.timedOut { throw BrowserDriverError.timedOut(command.first ?? "command") }
        guard let reply = AgentBrowserReply.parse(output.output) else {
            let text = output.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Self.classify(text.isEmpty ? "agent-browser ended with status \(output.status) and no output." : String(text.prefix(600)))
        }
        guard reply.success else { throw Self.classify(reply.error ?? "agent-browser reported an error.") }
        return reply.data ?? .null
    }

    /// An error message of the command line as the error the tools show.
    static func classify(_ message: String) -> BrowserDriverError {
        let lowered = message.lowercased()
        if lowered.contains("browser not launched") || lowered.contains("no active page") || lowered.contains("no page") && lowered.contains("open") {
            return .noPage
        }
        if lowered.contains("agent-browser install") || lowered.contains("chrome not found") || lowered.contains("could not find chrome")
            || lowered.contains("no chrome") {
            return .notInstalled(message + " (the user installs it with `agent-browser install` in the Terminal)")
        }
        return .failed(message)
    }

    // MARK: BrowserDriver

    func open(_ url: String) async throws -> BrowserPage {
        let data = try await send(["open", url], launching: true, timeout: Self.openTimeout)
        var page = BrowserPage(url: data["url"]?.string ?? url, title: data["title"]?.string ?? "")
        if page.title.isEmpty, let title = try? await send(["get", "title"])["title"]?.string { page.title = title }
        return page
    }

    func snapshot(interactive: Bool, selector: String?) async throws -> BrowserSnapshot {
        var command = ["snapshot"] + (interactive ? ["--interactive", "--urls", "--compact"] : ["--compact"])
        if let selector { command += ["--selector", selector] }
        let data = try await send(command)
        var refs: [String: BrowserRef] = [:]
        if case .object(let entries)? = data["refs"] {
            for (id, entry) in entries {
                refs[id] = BrowserRef(role: entry["role"]?.string ?? "", name: entry["name"]?.string ?? "")
            }
        }
        return BrowserSnapshot(url: data["origin"]?.string ?? "", tree: data["snapshot"]?.string ?? "", refs: refs)
    }

    func click(_ ref: String) async throws { try await send(["click", "@" + ref]) }

    func fill(_ ref: String, text: String) async throws { try await send(["fill", "@" + ref, text]) }

    func select(_ ref: String, value: String) async throws { try await send(["select", "@" + ref, value]) }

    func press(_ key: String) async throws { try await send(["press", key]) }

    func scroll(_ direction: BrowserScrollDirection, pixels: Int) async throws {
        try await send(["scroll", direction.rawValue, String(pixels)])
    }

    func read() async throws -> BrowserReadout {
        let data = try await send(["read"])
        return BrowserReadout(url: data["finalUrl"]?.string ?? data["url"]?.string ?? "", content: data["content"]?.string ?? "")
    }

    func screenshot(to file: URL) async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await send(["screenshot", file.path])
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw BrowserDriverError.failed("The browser reported a screenshot but no file was written.")
        }
    }

    func back() async throws -> BrowserPage {
        let data = try await send(["back"])
        let title = (try? await send(["get", "title"]))?["title"]?.string ?? ""
        let fallback = try? await currentURL()
        return BrowserPage(url: data["url"]?.string ?? fallback ?? "", title: title)
    }

    func tabs() async throws -> [BrowserTab] {
        let data = try await send(["tab"])
        return (data["tabs"]?.array ?? []).map { tab in
            BrowserTab(id: tab["tabId"]?.string ?? tab["label"]?.string ?? "", title: tab["title"]?.string ?? "",
                       url: tab["url"]?.string ?? "", isActive: tab["active"]?.bool ?? false)
        }
    }

    func newTab(_ url: String?) async throws { try await send(["tab", "new"] + (url.map { [$0] } ?? []), timeout: Self.openTimeout) }

    func selectTab(_ id: String) async throws { try await send(["tab", id]) }

    func closeTab(_ id: String?) async throws { try await send(["tab", "close"] + (id.map { [$0] } ?? [])) }

    func attribute(_ name: String, of ref: String) async throws -> String? {
        let data = try await send(["get", "attr", "@" + ref, name])
        return data["value"]?.string
    }

    func evaluate(_ script: String) async throws -> String {
        let data = try await send(["eval", script])
        guard let result = data["result"] else { return "" }
        return result.string ?? result.jsonString
    }

    func currentURL() async throws -> String? {
        do {
            let url = try await send(["get", "url"])["url"]?.string
            return url?.isEmpty == true ? nil : url
        } catch BrowserDriverError.noPage {
            return nil
        }
    }

    func setHeaded(_ headed: Bool) async throws -> BrowserPage {
        let address = try await currentURL()
        // The profile folder can be used by one browser at a time: the one running is closed before the other opens.
        _ = try? await send(["close"])
        state.withLock { $0.headed = headed }
        if let address, address != "about:blank" { return try await open(address) }
        let data = try await send(["open"], launching: true, timeout: Self.openTimeout)
        return BrowserPage(url: data["url"]?.string ?? "about:blank", title: "")
    }

    func close() async throws {
        state.withLock { $0.headed = false }
        do {
            try await send(["close"])
        } catch BrowserDriverError.noPage {
            return
        }
    }
}
