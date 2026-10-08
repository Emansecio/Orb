import Foundation
import os

/// Everything one Claude Code turn needs, captured up front.
struct ClaudeCodeTurn: Sendable {
    var bot: Bot
    var executable: URL
    /// `--model` value; nil or "default" keeps Claude Code's own choice.
    var model: String?
    /// Appended to Claude Code's system prompt (persona, memory, skills).
    var system: String
    var prompt: String
    /// The user's pictures, recorded with the message so a later turn by another model still has them as pictures
    /// (Claude Code itself opens the files named in `prompt`).
    var images: [ImageAttachment] = []
    /// What happened in the conversation that this Claude Code session has not seen; sent before the prompt.
    var context = ""
    /// Claude Code session to resume; nil starts a new one.
    var sessionID: String?
    /// MCP servers for `--mcp-config`: the Orb's tools server (memory, and the Mac tools with "Controlar apps do Mac"), plus
    /// the enabled connectors when the bot may use them. With "Conectores" off, `--strict-mcp-config` keeps the
    /// user's own Claude Code MCP servers out.
    var connectors: [MCPServerConfig] = []
    var environment: [String: String] = [:]
    /// Connector tools the connector itself marks destructive, by `PermissionPolicy.connectorKey`, with the reason shown
    /// on the card. Built from the app's own connections (the CLI starts its own, whose annotations never reach us),
    /// so "Automático" asks about them here as it does in the native engine.
    var destructiveConnectors: [String: String] = [:]
    /// Connectors of this Orb whose tools the app's own connection could not list in time (still starting, or failed),
    /// as the prefix `connectorKey` gives their tools (`github__`). Their annotations are unknown, so every tool of
    /// theirs asks, with `unverifiedReason`, instead of running unchecked.
    var unverifiedConnectors: Set<String> = []
    static let unverifiedReason = "não deu para conferir se o conector marca esta ferramenta como destrutiva"
    /// Grants for this turn only that the user's own request already gave (saving to memory when asked to remember).
    var turnGrants: [PermissionRule] = []
    /// The permission mode and rules as they are now, read at every permission request. nil keeps the ones in
    /// `bot` as they were when the turn started.
    var permissions: PermissionSource?
    /// Folder that gets `--add-dir` when the Orb works somewhere else, so reading across the user's files does not
    /// prompt for every folder (Claude Code only trusts the folder it starts in).
    var homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    /// How long Claude Code has to answer `initialize` before the turn is given up. Generous: a cold first launch
    /// may be starting the Orb's tools server and the user's connectors (some remote) before it answers.
    var initializeTimeout: TimeInterval = 60

    /// What the CLI process runs with. Its Bash tool keeps the directory between calls (a `cd` in one call carries
    /// to the next), while the permission checks judge every command in the Orb's folder; this brings each call of the
    /// main session back to the project folder so the two agree (https://code.claude.com/docs/en/env-vars). It says
    /// "in the main session": the Bash of a subagent still keeps its `cd`, so those requests are judged without
    /// assuming a folder (`PermissionPolicy.call(claudeCodeTool:…fromSubagent:)`).
    var processEnvironment: [String: String] {
        environment.merging(["CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR": "1"]) { $1 }
    }

    /// The destructive ones among the tools of the app's connections, keyed by the name the CLI gives them
    /// (`mcp__<name in the config>__<tool>`, see `mcpNames`), not by the connector's own name.
    static func destructiveConnectors(_ tools: [any AgentTool], cliNames: [UUID: String]) -> [String: String] {
        var result: [String: String] = [:]
        for case let tool as MCPTool in tools {
            guard let reason = tool.danger(.object([:])), let id = tool.serverID, let name = cliNames[id] else { continue }
            result[PermissionPolicy.connectorKey("mcp__\(name)__\(tool.toolName)")] = reason
        }
        return result
    }

    /// The connectors in `ids` that none of `tools` belongs to: the app's connection has not told what they offer.
    static func unverifiedConnectors(_ ids: Set<UUID>, tools: [any AgentTool], cliNames: [UUID: String]) -> Set<String> {
        let known = Set(tools.compactMap { ($0 as? MCPTool)?.serverID })
        return Set(ids.subtracting(known).compactMap { cliNames[$0] }.map { PermissionPolicy.connectorKey($0) + "__" })
    }

    func currentPermissions() async -> PermissionState {
        if let permissions { return await permissions() }
        return PermissionState(mode: bot.permissionMode, rules: bot.permissionRules)
    }

    /// Command line for this turn. Values use the `--flag=value` form so text starting with "-" is never read
    /// as a flag (as the SDK does for `--resume`).
    func arguments(newSessionID: String, mcpConfig: URL?) -> [String] {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                         "--include-partial-messages", "--verbose",
                         // Permission prompts come to us as `can_use_tool` control requests (SDK: subprocess_cli.py).
                         "--permission-prompt-tool", "stdio",
                         "--permission-mode", ClaudeCodePolicy.cliMode(bot.permissionMode),
                         "--append-system-prompt=\(system)"]
        if let model, !model.isEmpty, model != ClaudeCodeModels.defaultID { arguments.append("--model=\(model)") }
        arguments.append(sessionID.map { "--resume=\($0)" } ?? "--session-id=\(newSessionID)")
        var removed: [String] = []
        if bot.workingURL.standardizedFileURL.path != homeDirectory.standardizedFileURL.path {
            arguments.append("--add-dir=\(homeDirectory.path)")
        }
        if !bot.capabilities.contains(.terminal) { removed += ClaudeCodeTools.terminal }
        if !bot.capabilities.contains(.browser) { removed += ClaudeCodeTools.web }
        if bot.permissionMode != .bypass { removed += ClaudeCodeTools.secretReads }
        if !removed.isEmpty { arguments.append("--disallowedTools=\(removed.joined(separator: ","))") }
        if !bot.capabilities.contains(.connectors) { arguments.append("--strict-mcp-config") }
        if let mcpConfig { arguments.append("--mcp-config=\(mcpConfig.path)") }
        return arguments
    }

    /// The name each server has in `mcpConfig`, which is also the name the CLI gives its tools (`mcp__<name>__<tool>`):
    /// only `[a-z0-9_-]` (the CLI rewrites anything else, and `MCPTool.modelName` is ASCII too), with `-2`, `-3` when two
    /// servers would share one. Servers that are off or have nothing to run have none.
    static func mcpNames(_ servers: [MCPServerConfig]) -> [UUID: String] {
        var names: [UUID: String] = [:], taken: Set<String> = []
        for server in servers where server.isEnabled && (server.isRemote || !server.command.isEmpty) {
            let base = String(server.name.lowercased().unicodeScalars.map { scalar -> Character in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_") ? Character(scalar) : "-"
            })
            var name = base.isEmpty ? "conector" : base, suffix = 2
            while taken.contains(name) { name = "\(base)-\(suffix)"; suffix += 1 }
            taken.insert(name)
            names[server.id] = name
        }
        return names
    }

    /// `{"mcpServers": {name: {type: stdio, command, args, env} | {type: http, url, headers}}}`; nil when empty.
    static func mcpConfig(_ servers: [MCPServerConfig]) -> JSONValue? {
        let names = mcpNames(servers)
        var entries: [String: JSONValue] = [:]
        for server in servers {
            guard let name = names[server.id] else { continue }
            entries[name] = server.isRemote
                ? .object(["type": .string("http"), "url": .string(server.url),
                           "headers": .object(server.headers.mapValues(JSONValue.string))])
                : .object(["type": .string("stdio"), "command": .string(server.command),
                           "args": .array(server.arguments.map(JSONValue.string)),
                           "env": .object(server.environment.mapValues(JSONValue.string))])
        }
        return entries.isEmpty ? nil : .object(["mcpServers": .object(entries)])
    }
}

/// Runs bot turns through the user's Claude Code: one `claude -p` process per turn, resuming the bot's
/// session. Same shape as `AgentEngine`; Claude Code's permission prompts become Orb approval cards.
actor ClaudeCodeEngine {
    /// Open approval cards; shared with the other engine by passing the same gate.
    let gate: ApprovalGate
    /// The running process of each Orb's turn, to tell it when the permission mode changes.
    private var running: [UUID: LineProcess] = [:]

    init(gate: ApprovalGate = ApprovalGate()) { self.gate = gate }

    nonisolated func run(_ turn: ClaudeCodeTurn) -> AsyncStream<TurnEvent> {
        AsyncStream { continuation in
            let task = Task { await self.play(turn, out: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The Orb's permission mode changed during its turn: Claude Code decides some things itself (a session
    /// started in `bypassPermissions` never asks Orb), so it is told too. Orb's own check runs on every request
    /// either way; a CLI that refuses the switch is ignored.
    func modeChanged(for botID: UUID, to mode: PermissionMode) {
        running[botID]?.send(ClaudeCodeWire.setPermissionMode(id: ClaudeCodeWire.newRequestID(), mode: ClaudeCodePolicy.cliMode(mode)))
    }

    // MARK: Turn

    private func play(_ turn: ClaudeCodeTurn, out: AsyncStream<TurnEvent>.Continuation) async {
        defer { out.finish() }
        out.yield(.message(.user(turn.prompt, images: turn.images)))
        out.yield(.status("Pensando"))
        // Connector secrets go in a private temporary file, not on the command line.
        let mcpFile = ClaudeCodeTurn.mcpConfig(turn.connectors).flatMap(Self.writePrivate)
        defer { mcpFile.map { try? FileManager.default.removeItem(at: $0) } }
        let process: LineProcess
        do {
            process = try LineProcess(executable: turn.executable,
                                      arguments: turn.arguments(newSessionID: UUID().uuidString.lowercased(), mcpConfig: mcpFile),
                                      directory: turn.bot.workingURL, environment: turn.processEnvironment)
        } catch {
            out.yield(.failed("Não consegui abrir o Claude Code: \(error.localizedDescription)"))
            return
        }
        running[turn.bot.id] = process
        // Only its own entry: stopping and sending again starts a new process while this one is still leaving.
        defer { if running[turn.bot.id] === process { running[turn.bot.id] = nil } }
        await withTaskCancellationHandler {
            await converse(turn, process: process, out: out)
        } onCancel: {
            // End the turn the way the SDK does: interrupt, end input, then stop the process if it lingers.
            process.send(ClaudeCodeWire.controlRequest(id: ClaudeCodeWire.newRequestID(), subtype: "interrupt"))
            process.closeInput()
            process.terminate(after: 3)
        }
    }

    private func converse(_ turn: ClaudeCodeTurn, process: LineProcess, out: AsyncStream<TurnEvent>.Continuation) async {
        let initializeID = ClaudeCodeWire.newRequestID()
        process.send(ClaudeCodeWire.controlRequest(id: initializeID, subtype: "initialize"))
        var parser = ClaudeCodeParser()
        var transcript = ClaudeCodeTranscript(isResuming: turn.sessionID != nil)
        var granted = turn.turnGrants
        // Tool calls of the main session, seen in its assistant messages. The parser drops a subagent's messages, so a
        // permission request for a call not in here comes from a subagent.
        var mainSession: Set<String> = []
        // A CLI that never answers `initialize` (stuck on a prompt, a broken install) would hold the turn forever.
        let handshake = Handshake()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(turn.initializeTimeout))
            guard !Task.isCancelled, handshake.expire() else { return }
            process.closeInput()
            process.terminate(after: 0)
        }
        defer { watchdog.cancel() }

        for await line in process.lines {
            for message in parser.parse(line) {
                switch message {
                case .controlResponse(let id, let error) where id == initializeID:
                    guard handshake.answer() else { continue }
                    if let error {
                        out.yield(.failed("O Claude Code recusou iniciar a conversa: \(error)"))
                        process.closeInput()
                        process.terminate(after: 3)
                        return
                    }
                    process.send(ClaudeCodeWire.userMessage(turn.context.isEmpty ? turn.prompt : turn.context + "\n\n" + turn.prompt))
                case .permission(let request):
                    let fromSubagent = request.toolUseID.map { !mainSession.contains($0) } ?? false
                    let answer = await permission(request, turn: turn, hasText: transcript.hasText, fromSubagent: fromSubagent,
                                                  granted: &granted, out: out)
                    if case .deny = answer { transcript.noteDenied(request.toolUseID, mode: await turn.currentPermissions().mode) }
                    process.send(ClaudeCodeWire.permissionResponse(requestID: request.requestID, answer: answer, input: request.input))
                case .unsupportedRequest(let id, let subtype):
                    process.send(ClaudeCodeWire.errorResponse(requestID: id, message: "Unsupported control request: \(subtype)"))
                default:
                    if case .toolUse(let id, _, _) = message { mainSession.insert(id) }
                    for event in transcript.apply(message) { out.yield(event) }
                    if transcript.isFinished {
                        // One turn per process: let it exit on its own, but not linger.
                        process.closeInput()
                        process.terminate(after: 10)
                        return
                    }
                }
            }
        }
        guard !Task.isCancelled else { return }
        switch handshake.state {
        case .expired:
            out.yield(.failed("O Claude Code não respondeu em \(Int(turn.initializeTimeout)) segundos e foi encerrado. "
                              + "Tente de novo; se continuar, confira o Claude Code em Ajustes → Modelos." + Self.details(process.errorOutput)))
        case .waiting:
            out.yield(.failed("O Claude Code fechou antes de começar a conversa." + Self.details(process.errorOutput)))
        case .answered:
            for event in transcript.endedEarly(details: process.errorOutput) { out.yield(event) }
        }
    }

    private static func details(_ errorOutput: String) -> String {
        let tail = ClaudeCodeTranscript.tail(errorOutput)
        return tail.isEmpty ? "" : "\n" + tail
    }

    /// Whether Claude Code has answered `initialize`; the watchdog and the message loop race to settle it.
    private final class Handshake: Sendable {
        enum State { case waiting, answered, expired }
        private let current = OSAllocatedUnfairLock(initialState: State.waiting)
        var state: State { current.withLock { $0 } }

        /// False when the time already ran out.
        func answer() -> Bool {
            current.withLock { state in
                if state == .waiting { state = .answered }
                return state == .answered
            }
        }

        /// True when this call is the one that gave up (the answer had not come).
        func expire() -> Bool {
            current.withLock { state in
                guard state == .waiting else { return false }
                state = .expired
                return true
            }
        }
    }

    /// Answers a `can_use_tool` request: by the Orb's mode and rules as they are now, or by asking the user.
    /// `granted` holds the grants of this turn ("Só nesta tarefa").
    private func permission(_ request: ClaudeCodePermissionRequest, turn: ClaudeCodeTurn, hasText: Bool, fromSubagent: Bool,
                            granted: inout [PermissionRule], out: AsyncStream<TurnEvent>.Continuation) async -> ClaudeCodePermissionAnswer {
        let live = await turn.currentPermissions()
        let workspace = turn.bot.workingURL
        var call = PermissionPolicy.call(claudeCodeTool: request.toolName, input: request.input, workspace: workspace,
                                         fromSubagent: fromSubagent)
        if call.danger == nil, let key = call.connector {
            call.danger = turn.destructiveConnectors[key]
                ?? (turn.unverifiedConnectors.contains { key.hasPrefix($0) } ? ClaudeCodeTurn.unverifiedReason : nil)
        }
        let why: PermissionVerdict.AskReason
        switch PermissionPolicy.evaluate(mode: live.mode, call: call, rules: live.rules, turnGrants: granted, workspace: workspace) {
        case .allow: return .allow
        case .deny(let message): return .deny(message)
        case .ask(let reason): why = reason
        }
        guard !Task.isCancelled else { return .deny(ClaudeCodePolicy.userDenial) }
        let summary = ClaudeCodeTools.summary(request.toolName, request.input)
        let fallback = hasText ? "" : "\(turn.bot.name) precisa da sua permissão para continuar."
        let approval = ApprovalRequest(
            toolName: request.toolName, title: summary.title, command: summary.detail,
            reason: why.explanation ?? fallback, // the CLI's own reason is English, so it is not shown
            suggestions: PermissionPolicy.suggestions(for: call, existing: live.rules + granted, workspace: workspace,
                                                      extra: request.suggestions),
            isDangerous: why.isDangerous)
        await gate.open(approval.id, botID: turn.bot.id, alwaysAsks: why != .needsPermission)
        out.yield(.approval(approval))
        out.yield(.status("Esperando sua resposta"))
        let answer = await gate.wait(for: approval.id)
        let rule = answer.rule ?? approval.suggestions.first
        switch answer.decision {
        case .deny, .review:
            // Switching to read-only answers open cards with a denial.
            return .deny(await turn.currentPermissions().mode == .readOnly ? ClaudeCodePolicy.readOnlyDenial
                         : ClaudeCodePolicy.userDenial(note: answer.note))
        case .task:
            if let rule { granted.append(rule) }
        case .always:
            // The app saves the rule in the Orb, which the next request reads; without a live source (nothing
            // saves it) it is kept for this turn.
            if turn.permissions == nil, let rule { granted.append(rule) }
        case .once:
            break
        }
        out.yield(.status("Pensando"))
        return .allow
    }

    /// The connector configs are named `orb-mcp-p<pid>-<uuid>.json` after the app that wrote them.
    private static let mcpConfigPrefix = "orb-mcp-"

    /// Deletes the connector configs (`orb-mcp-*.json`, with the connectors' tokens) that an earlier run left behind
    /// because the app quit or crashed during a turn. A config named for a process (`orb-mcp-p<pid>-…`) goes when that
    /// process is gone, however young: one whose app is still running (this one, another copy, a developer run) is
    /// never touched. Names without a process (older versions) go once untouched for `olderThan` seconds.
    /// Returns how many it deleted.
    @discardableResult
    static func removeStaleMCPConfigs(in directory: URL = FileManager.default.temporaryDirectory, olderThan: TimeInterval = 120,
                                      now: Date = .now, isRunning: (pid_t) -> Bool = ClaudeCodeEngine.isRunning) -> Int {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var deleted = 0
        for url in files where url.lastPathComponent.hasPrefix(mcpConfigPrefix) && url.pathExtension == "json" {
            let stale: Bool
            if let pid = owner(of: url.lastPathComponent) {
                stale = !isRunning(pid)
            } else {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                stale = now.timeIntervalSince(date) > olderThan
            }
            if stale, (try? manager.removeItem(at: url)) != nil { deleted += 1 }
        }
        return deleted
    }

    /// The process named in `orb-mcp-p<pid>-<uuid>.json`, if the name has one.
    private static func owner(of fileName: String) -> pid_t? {
        let rest = fileName.dropFirst(mcpConfigPrefix.count)
        guard rest.hasPrefix("p"), let dash = rest.firstIndex(of: "-") else { return nil }
        return pid_t(rest[rest.index(after: rest.startIndex)..<dash])
    }

    private static func isRunning(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// Writes JSON readable only by the user, in a fresh temporary file named for this process.
    private static func writePrivate(_ json: JSONValue) -> URL? {
        let name = "\(mcpConfigPrefix)p\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let created = FileManager.default.createFile(atPath: url.path, contents: Data(json.jsonString.utf8),
                                                     attributes: [.posixPermissions: 0o600])
        return created ? url : nil
    }
}

/// Turns Claude Code messages into transcript events and tracks how the turn is going.
struct ClaudeCodeTranscript {
    let isResuming: Bool
    private(set) var isFinished = false
    /// What the turn used and cost, from the CLI's result message (nil until it arrives, or if it reports none).
    /// The usage also goes out as a `.usage` event, like the native engine's.
    private(set) var usage: TokenUsage?
    private(set) var costUSD: Double?
    private var didStart = false
    private var segments: [String] = []
    private var isWriting = false
    /// Claude Code tool-use id → transcript tool id, for calls still running.
    private var running: [String: UUID] = [:]
    private var denials: [String: String] = [:]
    private var apiError: String?
    /// Short notes of what Claude Code did this turn, kept in the history so other models know.
    private var actions: [String] = []

    init(isResuming: Bool) { self.isResuming = isResuming }

    var hasText: Bool { segments.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    mutating func apply(_ message: ClaudeCodeMessage) -> [TurnEvent] {
        switch message {
        case .started(let id):
            didStart = true
            return [.session(id)]
        case .text(let delta):
            apiError = nil // the CLI went on after a passing error
            var events: [TurnEvent] = []
            if !isWriting {
                isWriting = true
                segments.append("")
                events.append(.status("Escrevendo"))
            }
            segments[segments.count - 1] += delta
            return events + [.text(delta)]
        case .toolUse(let id, let name, let input):
            apiError = nil
            isWriting = false
            let summary = ClaudeCodeTools.summary(name, input)
            let call = ToolCall(kind: ClaudeCodeTools.kind(name), title: summary.title, detail: summary.detail)
            running[id] = call.id
            if actions.count < 20 { actions.append("\(summary.title): \(summary.detail.prefix(120))") }
            return [.toolStarted(call), .status(summary.title)]
        case .toolResult(let id, let output, let isError):
            guard let callID = running.removeValue(forKey: id) else { return [] }
            let shown = denials[id] ?? (output.count > 4000 ? output.prefix(4000) + "\n…" : output)
            return [.toolFinished(id: callID, state: isError ? .failed : .done, output: shown), .status("Pensando")]
        case .apiError(let code):
            apiError = code
            return []
        case .result(let result):
            isFinished = true
            usage = result.usage
            costUSD = result.costUSD
            var events = closeRunningTools()
            if let used = result.usage { events.insert(.usage(used), at: 0) }
            if !result.isError {
                let reply = segments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                var content = reply.joined(separator: "\n\n")
                if !actions.isEmpty {
                    content += (content.isEmpty ? "" : "\n\n") + "(Actions taken in this turn: " + actions.joined(separator: "; ") + ")"
                }
                if !content.isEmpty { events.append(.message(ChatMessage(role: .assistant, content: content))) }
            } else if isResuming && !didStart {
                // The saved session is gone (e.g. deleted in Claude Code): forget it so the next message starts fresh.
                events += [.session(""), .failed("A conversa anterior não existe mais no Claude Code. Mande de novo para começar uma nova.")]
            } else if apiError == "authentication_failed" {
                events.append(.failed("O Claude Code não está conectado à sua conta. Entre em Ajustes → Modelos → Claude Code."))
            } else {
                events.append(.failed(Self.failureText(result.message, apiError: apiError)))
            }
            return events
        case .compacted(let trigger, let before, let after):
            return [.compacted(CompactionReport(kind: .claudeCode, foldedMessages: 0, tokensBefore: before, tokensAfter: after,
                                                trigger: trigger))]
        case .permission, .unsupportedRequest, .controlResponse:
            return []
        }
    }

    /// Shows a denial in Portuguese on the tool's row instead of Claude Code's English message.
    mutating func noteDenied(_ toolUseID: String?, mode: PermissionMode) {
        guard let toolUseID else { return }
        denials[toolUseID] = mode == .readOnly ? "Bloqueado: o Orb está em modo Só leitura." : "Você negou esta ação."
    }

    /// A failed result in Portuguese, with the CLI's own words kept at the end (as `LLMError` does). The plan's usage
    /// limit comes as `Claude AI usage limit reached|<epoch>`: the epoch (when it resets) becomes a local time.
    static func failureText(_ message: String, apiError: String?, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines), resets: Date?
        if let bar = text.lastIndex(of: "|"), let epoch = Double(text[text.index(after: bar)...]), epoch > 1_000_000_000 {
            resets = Date(timeIntervalSince1970: epoch > 100_000_000_000 ? epoch / 1000 : epoch)
            text = String(text[..<bar]).trimmingCharacters(in: .whitespaces)
        }
        let lower = text.lowercased()
        let detail = text.isEmpty ? "" : " Detalhe do Claude Code: \(text)"
        // "Context limit reached" and the like are about the conversation, not the plan.
        let aboutContext = lower.contains("context") || lower.contains("token")
        if apiError == "rate_limit" || ["usage limit", "hit your limit"].contains(where: lower.contains)
            || (!aboutContext && ["limit reached", "rate limit"].contains(where: lower.contains)) {
            var when = ""
            if let resets {
                let format = DateFormatter()
                format.locale = Locale(identifier: "pt_BR")
                format.timeZone = timeZone
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                format.dateFormat = calendar.isDate(resets, inSameDayAs: now) ? "HH:mm" : "dd/MM 'às' HH:mm"
                when = ", por volta de \(format.string(from: resets))"
            }
            return "Você chegou ao limite de uso do seu plano Claude. Ele volta sozinho\(when).\(detail)"
        }
        if apiError == "billing_error" || lower.contains("billing") {
            return "Há um problema de cobrança na sua conta Claude. Confira o plano e o pagamento em claude.ai.\(detail)"
        }
        if apiError == "server_error" || lower.contains("overloaded")
            || lower.range(of: #"api error: 5\d\d"#, options: .regularExpression) != nil {
            return "O serviço da Anthropic está instável ou sobrecarregado. Tente de novo em instantes.\(detail)"
        }
        // The subtype alone (`error_during_execution`, `error_max_turns`): no text came with the failure.
        if text.hasPrefix("error_"), !text.contains(" ") { return "O Claude Code encerrou com erro (\(text))." }
        return message
    }

    /// The last 600 characters of the CLI's stderr, enough to show why it stopped.
    static func tail(_ errorOutput: String) -> String {
        errorOutput.count > 600 ? "…" + errorOutput.suffix(600) : errorOutput
    }

    /// The CLI closed its output without a result (crash, bad flag, killed).
    mutating func endedEarly(details: String) -> [TurnEvent] {
        isFinished = true
        let tail = Self.tail(details)
        return closeRunningTools() + [.failed("O Claude Code parou sem terminar a resposta." + (tail.isEmpty ? "" : "\n\(tail)"))]
    }

    private mutating func closeRunningTools() -> [TurnEvent] {
        defer { running = [:] }
        return running.values.map { .toolFinished(id: $0, state: .failed, output: "Interrompido.") }
    }
}
