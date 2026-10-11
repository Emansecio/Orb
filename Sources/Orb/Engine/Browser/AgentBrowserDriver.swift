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
    /// Lets the scripts of a `file://` page read other local files. Not needed to open one (Chrome opens `file://` pages without it),
    /// so it is off; Obscura rejects it.
    var allowFileAccess = false
    /// Lets Obscura reach `localhost` and private addresses (it blocks them by default); for tests of local pages only.
    var allowPrivateNetwork = false
    /// The app's own folder for agent-browser (`navegador`): the config file it is told to read (so nothing of the user's own
    /// `~/.agent-browser/config.json` or `./agent-browser.json` applies), the folder its commands run in, and what it
    /// remembers about how each session was launched. Nil only in tests that need none of that.
    var stateDirectory: URL?
    /// Where `agent-browser` keeps the sockets of its background processes (`AGENT_BROWSER_SOCKET_DIR`): its own default, except in
    /// tests that must not see (or close) the sessions of the app running on the same Mac.
    var socketDirectory: URL?

    /// The session of an Orb for an engine. Another engine is another browser, so it gets another session (a running browser
    /// keeps the settings it was launched with).
    static func sessionName(botID: UUID, engine: BrowserEngineKind) -> String {
        botPrefix(botID) + engine.rawValue
    }

    /// Every session name of the app starts with this (the person's own `agent-browser` sessions never do).
    static let sessionPrefix = "orb-"

    /// What the names of one Orb's sessions (one per engine) start with.
    static func botPrefix(_ botID: UUID) -> String { "\(sessionPrefix)\(botID.uuidString.prefix(8).lowercased())-" }

    /// The engine a session name of the app says it is for.
    static func engine(ofSession name: String) -> BrowserEngineKind? {
        name.hasPrefix(sessionPrefix) ? name.split(separator: "-").last.flatMap { BrowserEngineKind(rawValue: String($0)) } : nil
    }

    /// Flags every command carries: which browser, JSON replies, and the config file of the app (an empty one: the user's own
    /// configuration, in their home folder or in the folder the command runs in, would add a proxy, extensions or a provider).
    var globalArguments: [String] { ["--session", session, "--json"] + (configFile.map { ["--config", $0.path] } ?? []) }

    var configFile: URL? { stateDirectory?.appending(path: "agent-browser.json") }
    /// Where the commands run: the app's folder, never the home folder (`./agent-browser.json` there would be read).
    var workingDirectory: URL {
        stateDirectory ?? FileManager.default.temporaryDirectory.appending(path: "OrbBrowser", directoryHint: .isDirectory)
    }
    private var launchRecordFile: URL? { stateDirectory?.appending(path: "sessoes/\(session).launch") }

    /// Makes the folder and the empty config file the commands need.
    func prepareState() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        if let configFile, !fileManager.fileExists(atPath: configFile.path) { try? Data("{}\n".utf8).write(to: configFile, options: .atomic) }
    }

    /// What the browser of this session is launched with, as one text: the engine, the flags of the launch and the environment
    /// that changes the browser. A running browser started with another one is not reused (see `AgentBrowserDriver.open`). Whether
    /// the window is shown is not part of it: showing and hiding it is the person's, and an `open` must not close the window
    /// the person is using.
    var launchFingerprint: String {
        ([engine.rawValue] + launchArguments.filter { $0 != "--headed" } + extraEnvironment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
            .joined(separator: "\u{1F}")
    }

    func recordedFingerprint() -> String? {
        launchRecordFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    func recordFingerprint() {
        guard let file = launchRecordFile else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? launchFingerprint.write(to: file, atomically: true, encoding: .utf8)
    }

    func forgetFingerprint() {
        if let file = launchRecordFile { try? FileManager.default.removeItem(at: file) }
    }

    /// The environment of the user's login shell without what would reconfigure the browser behind the app's back: every
    /// `AGENT_BROWSER_*` setting (the app sets its own). Proxies (`HTTP_PROXY`, `HTTPS_PROXY`,
    /// `ALL_PROXY`, `NO_PROXY`) stay as the shell has them, so a Mac that needs a proxy to reach the web keeps working.
    static func sanitized(_ environment: [String: String]) -> [String: String] {
        environment.filter { !$0.key.uppercased().hasPrefix("AGENT_BROWSER_") }
    }

    /// The environment a command runs with: the login shell's (or the app's), cleaned, plus what this session sets.
    func environment(base: [String: String]?) -> [String: String] {
        Self.sanitized(base ?? ProcessInfo.processInfo.environment).merging(extraEnvironment) { _, new in new }
    }

    /// What CloakBrowser's own wrapper passes to its Chromium on macOS (`get_default_stealth_args`), without its `--no-sandbox`: macOS
    /// does not need it (checked: the browser starts and browses with the sandbox on), and in a window it shows a warning bar.
    var cloakArguments: [String] { ["--fingerprint=\(cloakSeed)", "--fingerprint-platform=macos"] }

    /// The user agent of the Chrome for Testing in a `chrome-<version>` folder, as the same Chrome says it with a window.
    static func chromeUserAgent(executable: String?) -> String? {
        guard let executable, let range = executable.range(of: #"chrome-(\d+)\."#, options: .regularExpression) else { return nil }
        let major = executable[range].dropFirst("chrome-".count).prefix { $0.isNumber }
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36"
    }

    /// What the `agent-browser` process (and the background process it starts) runs with besides the user's environment.
    var extraEnvironment: [String: String] {
        // A browser nobody has used for half an hour is closed by agent-browser itself (its default is an hour): the safety net
        // for a browser left behind when the app is killed instead of quit.
        var environment = ["AGENT_BROWSER_IDLE_TIMEOUT_MS": "1800000"]
        if let socketDirectory { environment["AGENT_BROWSER_SOCKET_DIR"] = socketDirectory.path }
        if engine == .obscura {
            // The stealth build of Obscura: one consistent fingerprint, and TLS like a real browser's.
            environment["AGENT_BROWSER_OBSCURA_STEALTH"] = "1"
            if allowPrivateNetwork { environment["OBSCURA_ALLOW_PRIVATE_NETWORK"] = "1" }
        }
        return environment
    }

    /// Flags only the command that launches the browser (`open`) needs; a running browser keeps the ones it started with.
    var launchArguments: [String] {
        var arguments: [String] = []
        switch engine {
        case .simple:
            break
        case .chrome:
            // The Chrome the app installed is named; without one agent-browser looks for a Chrome by itself.
            if let browserExecutable { arguments += ["--executable-path", browserExecutable] }
            // Chrome for Testing in the background says "HeadlessChrome" and `navigator.webdriver = true`, which DuckDuckGo and Google
            // answer with a captcha (checked); a Chrome's own name and the flag that hides the automation make them answer.
            if let agent = Self.chromeUserAgent(executable: browserExecutable) { arguments += ["--user-agent", agent] }
            arguments += ["--args", "--disable-blink-features=AutomationControlled"]
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
        if allowFileAccess, engine != .obscura { arguments.append("--allow-file-access") }
        return arguments
    }
}

/// CloakBrowser keeps one fingerprint seed per profile in `<profile>/.cloakbrowser-seed` (a decimal number and a newline), so
/// a login does not meet a new "device" every run. This reads and writes the same file its wrappers do.
enum CloakSeed {
    static let range = 10_000...99_999
    static let fileName = ".cloakbrowser-seed"

    private static func read(_ file: URL) -> Int? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let seed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), range.contains(seed) else { return nil }
        return seed
    }

    /// The seed of the profile, made once: the file is written whole in a file of its own and put in place with `link`, which
    /// fails when the name is taken, so two callers (two tasks, or two runs of the app) that both
    /// find no seed end up with the same one: the first to link wins and the other reads it.
    static func seed(inProfile profile: URL) -> Int {
        let file = profile.appending(path: fileName)
        if let seed = read(file) { return seed }
        let seed = Int.random(in: range)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: profile, withIntermediateDirectories: true)
        let draft = profile.appending(path: ".cloakbrowser-seed-\(UUID().uuidString)")
        guard (try? "\(seed)\n".write(to: draft, atomically: false, encoding: .utf8)) != nil else { return seed }
        defer { try? fileManager.removeItem(at: draft) }
        if link(draft.path, file.path) == 0 { return seed }
        // Taken (or an unreadable leftover): the one there counts; a broken one is replaced.
        if let existing = read(file) { return existing }
        try? fileManager.removeItem(at: file)
        if link(draft.path, file.path) == 0 { return seed }
        return read(file) ?? seed
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
            if text.hasPrefix("["), let json = JSONValue.parse(text), let first = json.array?.first, let success = first["success"]?.bool {
                // `batch --json` answers with a list, one entry per command (`{command, result, error, success}`).
                return AgentBrowserReply(success: success, data: first["result"], error: first["error"]?.string)
            }
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
    /// `close` was the last thing done: the background process takes a moment to go, and until a page is opened again it does not count.
    private let closed = OSAllocatedUnfairLock(initialState: false)
    /// The environment the last command ran with, for the close that cannot wait for a task (`closeSynchronously`).
    private let lastEnvironment = OSAllocatedUnfairLock<[String: String]?>(initialState: nil)
    /// The elements of the last snapshot, by ref: what Obscura needs to click a link its own click cannot reach.
    private let knownRefs = OSAllocatedUnfairLock<[String: BrowserRef]>(initialState: [:])
    /// What this driver launched the browser with (`launchFingerprint`), once it did.
    private let launched = OSAllocatedUnfairLock<String?>(initialState: nil)
    /// Until when a command that worked proves the background process is there, so the next command need not ask.
    private let aliveUntil = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
    static let aliveWindow = Duration.seconds(3)

    var config: AgentBrowserConfig { state.withLock { $0 } }

    /// The longest a page load, or the first launch of the browser, is waited for.
    static let openTimeout = Duration.seconds(75)
    static let commandTimeout = Duration.seconds(45)
    /// Output above this would be cut in the middle and no longer be JSON (a snapshot of a huge page).
    static let outputLimit = 8_000_000

    /// `run` nil: the real command line, run in the app's folder (`AgentBrowserConfig.workingDirectory`).
    init(config: AgentBrowserConfig, environment: @escaping @Sendable () async -> [String: String]? = { await ShellEnvironment.shared.resolved().environment },
         run: BrowserCommandRunner? = nil) {
        state = OSAllocatedUnfairLock(initialState: config)
        self.environment = environment
        self.run = run ?? Self.processRunner(directory: config.workingDirectory)
    }

    static func processRunner(directory: URL) -> BrowserCommandRunner {
        { executable, arguments, environment, timeout in
            try await ProcessRunner.run(executable, arguments, directory: directory, environment: environment,
                                        timeout: timeout, outputLimit: outputLimit)
        }
    }

    // MARK: Commands

    /// Runs one command and returns the `data` of the reply, or throws what went wrong. `text`: the words after the command name
    /// are text of the page (what to type, a script, an address), never options: the command line takes an argument that is exactly
    /// one of its options (`--json`, `--headed`) for the option wherever it stands, and `--` does not stop that, so such text goes
    /// through `batch`, whose own quoting passes it as it is.
    ///
    /// Only `open` (`launching`) starts a browser, with the flags of the Orb's profile and engine. Any other command first checks
    /// that the session's background process is there: `agent-browser` starts a browser of its own choosing (the one in
    /// Applications, with no profile and no flags) for a command that finds none, which is not the Orb's browser. With no
    /// process the command throws `noPage` (the model opens the page again); `needsSession: false` is for `session list` and `close`.
    @discardableResult
    func send(_ command: [String], launching: Bool = false, text: Bool = false, needsSession: Bool? = nil,
              timeout: Duration = AgentBrowserDriver.commandTimeout) async throws -> JSONValue {
        let needsSession = needsSession ?? !launching
        if needsSession { try await requireRunningSession() }
        let data = try await perform(command, launching: launching, text: text, timeout: timeout)
        guard needsSession else { return data }
        // The check above is a moment before the command: if the process went in between, the command started a browser of its own.
        // It is closed again at once and the model is told to open the page.
        if data["lifecycle"]?["launched"]?.bool == true {
            _ = try? await perform(["close"], launching: false, text: false, timeout: Self.commandTimeout)
            markClosed()
            throw BrowserDriverError.noPage
        }
        aliveUntil.withLock { $0 = .now + Self.aliveWindow }
        return data
    }

    private func markClosed() {
        closed.withLock { $0 = true }
        aliveUntil.withLock { $0 = nil }
        launched.withLock { $0 = nil }
    }

    /// Throws `noPage` unless the background process of the session is running.
    private func requireRunningSession() async throws {
        if closed.withLock({ $0 }) { throw BrowserDriverError.noPage }
        if let until = aliveUntil.withLock({ $0 }), until > .now { return }
        guard try await listSessions().contains(config.session) else { throw BrowserDriverError.noPage }
        aliveUntil.withLock { $0 = .now + Self.aliveWindow }
    }

    /// The sessions `agent-browser` has a background process for (`session list`).
    private func listSessions() async throws -> [String] {
        try await perform(["session", "list"], launching: false, text: false, timeout: Self.commandTimeout)["sessions"]?.array?.compactMap(\.string) ?? []
    }

    func runningSessions() async -> [String] { (try? await listSessions()) ?? [] }

    private func perform(_ command: [String], launching: Bool, text: Bool, timeout: Duration) async throws -> JSONValue {
        let current = config
        current.prepareState()
        let literal = text && command.dropFirst().contains { $0.hasPrefix("-") }
        let tail = literal ? ["batch", Self.shellLine(command)] : command
        let arguments = current.globalArguments + (launching ? current.launchArguments : []) + tail
        let base = await environment()
        let environment = current.environment(base: base)
        lastEnvironment.withLock { $0 = base }
        var attempt = 0
        while true {
            let output: ProcessOutput
            do {
                output = try await run(current.executable, arguments, environment, timeout)
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
            guard reply.success else {
                // The command line asked the background process that has just been closed (`close`, then `open` at once): it
                // answers on the next try, when it is gone and a new one starts.
                if attempt < Self.connectRetries, Self.isStaleConnection(reply.error) {
                    attempt += 1
                    try await Task.sleep(for: Self.connectRetryDelay)
                    continue
                }
                throw Self.classify(reply.error ?? "agent-browser reported an error.")
            }
            return reply.data ?? .null
        }
    }

    static let connectRetries = 3
    static let connectRetryDelay = Duration.milliseconds(500)

    static func isStaleConnection(_ message: String?) -> Bool {
        guard let message = message?.lowercased() else { return false }
        return message.contains("failed to connect") && message.contains("no such file or directory")
    }

    /// The command as the one string `batch` takes: every word in single quotes (an apostrophe as `'\''`), so nothing in it is an
    /// option, a variable or a space that splits.
    static func shellLine(_ words: [String]) -> String {
        words.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }

    /// An error message of the command line as the error the tools show.
    static func classify(_ message: String) -> BrowserDriverError {
        let lowered = message.lowercased()
        if lowered.contains("browser not launched") || lowered.contains("no active page") || lowered.contains("no page") && lowered.contains("open") {
            return .noPage
        }
        if lowered.contains("agent-browser install") || lowered.contains("chrome not found") || lowered.contains("could not find chrome")
            || lowered.contains("no chrome") {
            return .notInstalled(message + " (the user installs the browser in Ajustes → Navegador)")
        }
        return .failed(message)
    }

    // MARK: BrowserDriver

    func open(_ url: String) async throws -> BrowserPage {
        try await prepareLaunch()
        let data = try await send(["open", url], launching: true, text: true, timeout: Self.openTimeout)
        didLaunch()
        var page = BrowserPage(url: data["url"]?.string ?? url, title: data["title"]?.string ?? "")
        if page.title.isEmpty, let title = try? await send(["get", "title"])["title"]?.string { page.title = title }
        return page
    }

    /// The browser was launched (or reused) with the flags of this driver's configuration: written down, for this driver and for
    /// the next process that meets the same session.
    private func didLaunch() {
        closed.withLock { $0 = false }
        let current = config
        launched.withLock { $0 = current.launchFingerprint }
        aliveUntil.withLock { $0 = .now + Self.aliveWindow }
        current.recordFingerprint()
    }

    /// A session already running keeps the flags it was launched with (`agent-browser` does not relaunch a running browser for the
    /// flags of a later `open`): a browser left by an older version of the app, or by another process with other settings, would
    /// be reused with the wrong profile or program. So the flags of the launch are written down (`sessoes/<session>.launch`), and
    /// a running session that did not start with these is closed, and gone, before the page opens in a new one. Nothing to
    /// compare without the app's folder.
    private func prepareLaunch() async throws {
        let current = config
        guard current.stateDirectory != nil, !closed.withLock({ $0 }) else { return }
        let fingerprint = current.launchFingerprint
        if launched.withLock({ $0 }) == fingerprint { return }
        guard try await listSessions().contains(current.session) else { return }
        if current.recordedFingerprint() == fingerprint { return }
        _ = try? await send(["close"], needsSession: false)
        markClosed()
        await waitUntilGone()
    }

    func snapshot(interactive: Bool, selector: String?) async throws -> BrowserSnapshot {
        var command = ["snapshot"] + (interactive ? ["--interactive", "--urls", "--compact"] : ["--compact"])
        if let selector {
            // The selector reaches the command line as an option's value, which a word that starts with "-" would turn into an option.
            guard !selector.trimmingCharacters(in: .whitespaces).hasPrefix("-") else {
                throw BrowserDriverError.failed("`selector` is a CSS selector like main or #content; it cannot start with “-”.")
            }
            command += ["--selector", selector]
        }
        let data = try await send(command)
        var refs: [String: BrowserRef] = [:]
        if case .object(let entries)? = data["refs"] {
            for (id, entry) in entries {
                refs[id] = BrowserRef(role: entry["role"]?.string ?? "", name: entry["name"]?.string ?? "")
            }
        }
        let found = refs
        knownRefs.withLock { $0 = found }
        return BrowserSnapshot(url: data["origin"]?.string ?? "", tree: data["snapshot"]?.string ?? "", refs: refs)
    }

    func click(_ ref: String) async throws {
        do {
            try await send(["click", "@" + ref])
        } catch BrowserDriverError.failed(let message) where config.engine == .obscura && Self.isObscuraBoxModelFailure(message) {
            // Obscura answers the position of a link with a fractional number its command line cannot read (`DOM.getBoxModel`),
            // so the click is made in the page, on the element the snapshot called `ref`.
            try await clickInPage(ref, original: message)
        }
    }

    /// Obscura's reply to `DOM.getBoxModel` for an element that is not a block, which `agent-browser` fails to read.
    static func isObscuraBoxModelFailure(_ message: String) -> Bool {
        message.contains("DOM.getBoxModel") || (message.contains("Failed to deserialize CDP response") && message.contains("floating point"))
    }

    /// The click in the page finds the element by its role and name, which is a guess when several are alike: it clicks only
    /// when exactly one element is, and fails otherwise (a wrong click on a page where the Orb is logged in is worse than none).
    private func clickInPage(_ ref: String, original: String) async throws {
        guard let known = knownRefs.withLock({ $0[ref] }), !known.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrowserDriverError.failed(original)
        }
        let alike = knownRefs.withLock { $0.values.filter { $0.role == known.role && $0.name == known.name }.count }
        guard alike == 1 else { throw BrowserDriverError.failed(Self.ambiguousClick(known.name)) }
        let script = Self.clickScript(role: known.role, name: known.name)
        let result = try await send(["eval", script], text: true)["result"]?.string
        switch result {
        case "clicked": return
        case "ambiguous": throw BrowserDriverError.failed(Self.ambiguousClick(known.name))
        default: throw BrowserDriverError.failed(original)
        }
    }

    static func ambiguousClick(_ name: String) -> String {
        "Not clicked: more than one element is called “\(name.clipped(to: 60))” and this browser cannot click this one by its position. "
            + "Take a fresh browse_snapshot with a `selector` that holds only the one you mean, or use another element."
    }

    /// Clicks the element of the role whose text, label or title is the name, when exactly one is: "clicked", "ambiguous" (more
    /// than one is, and none is clicked) or "none".
    static func clickScript(role: String, name: String) -> String {
        let selectors: [String: String] = [
            "link": "a[href], [role=link]", "button": "button, [role=button], input[type=button], input[type=submit], input[type=reset], summary",
            "checkbox": "input[type=checkbox], [role=checkbox]", "radio": "input[type=radio], [role=radio]", "tab": "[role=tab]",
            "menuitem": "[role=menuitem]", "option": "option, [role=option]",
        ]
        let selector = selectors[role] ?? "a[href], button, [role], input, summary"
        return """
        (() => {
          const wanted = \(JSONValue.string(name).jsonString).replace(/\\s+/g, ' ').trim();
          if (!wanted) return 'none';
          const text = el => (el.getAttribute('aria-label') || el.innerText || el.value || el.title || el.alt || '').replace(/\\s+/g, ' ').trim();
          const all = Array.from(document.querySelectorAll(\(JSONValue.string(selector).jsonString)));
          let found = all.filter(e => text(e) === wanted);
          if (found.length === 0) found = all.filter(e => text(e).includes(wanted));
          if (found.length === 0) return 'none';
          if (found.length > 1) return 'ambiguous';
          found[0].click();
          return 'clicked';
        })()
        """
    }

    func fill(_ ref: String, text: String) async throws { try await send(["fill", "@" + ref, text], text: true) }

    func select(_ ref: String, value: String) async throws { try await send(["select", "@" + ref, value], text: true) }

    func press(_ key: String) async throws { try await send(["press", key], text: true) }

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

    func newTab(_ url: String?) async throws { try await send(["tab", "new"] + (url.map { [$0] } ?? []), text: true, timeout: Self.openTimeout) }

    /// A tab id as `tab` lists them (`t1`, `t12`). It reaches the command line as a word of its own, which one that starts with "-"
    /// would turn into an option.
    static func isTabID(_ id: String) -> Bool {
        id.range(of: #"^t?[0-9]+$"#, options: .regularExpression) != nil
    }

    private static func requireTabID(_ id: String) throws {
        guard isTabID(id) else { throw BrowserDriverError.failed("`tab` is a tab id from the list, like t1 or 2.") }
    }

    func selectTab(_ id: String) async throws {
        try Self.requireTabID(id)
        try await send(["tab", id])
    }

    func closeTab(_ id: String?) async throws {
        if let id { try Self.requireTabID(id) }
        try await send(["tab", "close"] + (id.map { [$0] } ?? []))
    }

    func attribute(_ name: String, of ref: String) async throws -> String? {
        let data = try await send(["get", "attr", "@" + ref, name])
        return data["value"]?.string
    }

    func evaluate(_ script: String) async throws -> String {
        let data = try await send(["eval", script], text: true)
        guard let result = data["result"] else { return "" }
        return result.string ?? result.jsonString
    }

    func currentURL() async throws -> String? {
        // `get url` on a session nobody opened would start a browser of its own choosing (the one in Applications, with no
        // profile): `send` asks only a session with a background process, and `noPage` here means there is no page.
        do {
            let url = try await send(["get", "url"])["url"]?.string
            return url?.isEmpty == true ? nil : url
        } catch BrowserDriverError.noPage {
            return nil
        }
    }

    func setHeaded(_ headed: Bool) async throws -> BrowserPage {
        let address = try await currentURL()
        // The profile folder can be used by one browser at a time: the one running is closed, and gone, before the other opens
        // (a Chrome started on a profile that is still in use hands over to it and exits, "without writing DevToolsActivePort").
        _ = try? await send(["close"], needsSession: false)
        markClosed()
        await waitUntilGone()
        state.withLock { $0.headed = headed }
        var attempt = 0
        while true {
            do {
                if let address, address != "about:blank" { return try await open(address) }
                let data = try await send(["open"], launching: true, timeout: Self.openTimeout)
                didLaunch()
                return BrowserPage(url: data["url"]?.string ?? "about:blank", title: "")
            } catch BrowserDriverError.failed(let message) where attempt < 2 && message.contains("DevToolsActivePort") {
                attempt += 1
                try await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// Waits (at most about ten seconds) for the background process of the session to be gone after a `close`.
    private func waitUntilGone() async {
        for _ in 0..<50 {
            let sessions = try? await listSessions()
            if sessions?.contains(config.session) != true { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        // The browser itself may outlive the process that closed it by a moment.
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// Runs `agent-browser` with these arguments for the moment the app quits, which cannot wait for a task: its output (when
    /// asked) once it ended or `timeout` passed. A slow command is left to finish on its own, because cutting it short would
    /// leave the browser behind.
    private func runSynchronously(_ extra: [String], timeout: TimeInterval, captureOutput: Bool) -> String? {
        let current = config
        current.prepareState()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: current.executable)
        process.arguments = current.globalArguments + extra
        process.environment = current.environment(base: lastEnvironment.withLock { $0 })
        process.currentDirectoryURL = current.workingDirectory
        let pipe = captureOutput ? Pipe() : nil
        process.standardOutput = pipe ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        guard let pipe, !process.isRunning else { return nil }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func closeSynchronously(timeout: TimeInterval) {
        _ = runSynchronously(["close"], timeout: timeout, captureOutput: false)
        config.forgetFingerprint()
    }

    func runningSessionsSynchronously(timeout: TimeInterval) -> [String] {
        guard let output = runSynchronously(["session", "list"], timeout: timeout, captureOutput: true),
              let reply = AgentBrowserReply.parse(output), reply.success else { return [] }
        return reply.data?["sessions"]?.array?.compactMap(\.string) ?? []
    }

    func close() async throws {
        state.withLock { $0.headed = false }
        markClosed()
        config.forgetFingerprint()
        do {
            do {
                try await send(["close"], needsSession: false)
            } catch BrowserDriverError.timedOut {
                // A machine too busy to answer in time (the command was cut short): once more, or the browser stays behind.
                try await send(["close"], needsSession: false)
            }
        } catch BrowserDriverError.noPage {
            return
        }
    }
}
