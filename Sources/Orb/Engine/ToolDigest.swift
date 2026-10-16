import Foundation

// One line per tool step, for steps that no longer fit the window: what was done and what came of it, so
// setting a step aside does not lose what it found.

enum ToolDigest {
    /// Most lines a digest keeps (the newest ones); older steps are counted.
    static let maxLines = 24
    static let maxLineLength = 150
    /// Characters a digest of `lines` lines can take at most, header and the files line included.
    static func maxCharacters(lines: Int = maxLines) -> Int {
        lines * (maxLineLength + 1) + 80 + maxFiles(lines: lines) * (maxPathLength + 2) + filesTitle.count
    }
    /// Files the files line names at most (the newest): two per line of the digest, up to 40.
    static func maxFiles(lines: Int = maxLines) -> Int { min(40, lines * 2) }
    static let maxPathLength = 60
    static let filesTitle = "Arquivos alterados nestes passos: "
    static var maxCharacters: Int { maxCharacters() }

    /// How many lines a window of `limit` characters can spare: a sixth of it at most, and never fewer than 6.
    static func lines(forLimit limit: Int) -> Int { max(6, min(maxLines, limit / 6 / maxLineLength)) }

    /// Digest lines for a run of messages from one task (the assistant steps, their tool results and the user's
    /// notes in between), numbering the model's steps from `firstStep`.
    static func lines(for messages: [ChatMessage], firstStep: Int = 1, maxLines: Int = ToolDigest.maxLines) -> [String] {
        var results: [String: ChatMessage] = [:]
        for message in messages where message.role == .tool {
            if let id = message.toolCallID { results[id] = message }
        }
        var lines: [String] = []
        var step = firstStep - 1
        for message in messages {
            switch message.role {
            case .assistant:
                step += 1
                let said = oneLine(message.content, 100)
                if !said.isEmpty { lines.append(clip("[passo \(step)] disse: «\(said)»")) }
                for call in message.toolCalls { lines.append(line(call: call, result: results[call.id], step: step)) }
            case .user:
                // The user's own words are never dropped silently.
                let said = oneLine(TurnPreface.userWords(message.content), 120)
                if !said.isEmpty { lines.append(clip("[usuário] «\(said)»")) }
            default:
                break
            }
        }
        guard lines.count > maxLines else { return lines }
        // The user's lines (the newest, up to half the digest) stay; the steps fill the rest, newest first.
        let pinned = lines.indices.filter { lines[$0].hasPrefix("[usuário]") }.suffix(maxLines / 2)
        let steps = lines.indices.filter { !pinned.contains($0) }.suffix(maxLines - 1 - pinned.count)
        let kept = (pinned + steps).sorted()
        return ["(+\(lines.count - kept.count) linhas anteriores)"] + kept.map { lines[$0] }
    }

    /// The files the calls in `messages` wrote or changed and that worked, each once, in the order last touched. The
    /// digest keeps only its newest lines: this keeps what the task changed early on in sight.
    static func writtenFiles(in messages: [ChatMessage]) -> [String] {
        let failed = Set(messages.filter { $0.role == .tool && $0.isError }.compactMap(\.toolCallID))
        var files: [String] = []
        for message in messages where message.role == .assistant {
            for call in message.toolCalls where (call.name == "write_file" || call.name == "edit_file") && !failed.contains(call.id) {
                guard let path = JSONValue.parse(call.arguments)?["path"]?.string, !path.isEmpty else { continue }
                files.removeAll { $0 == path }
                files.append(path)
            }
        }
        return files
    }

    /// The files line of a steps note: the newest `limit` of `files`, the rest counted.
    static func filesLine(_ files: [String], limit: Int = maxFiles()) -> String? {
        guard !files.isEmpty else { return nil }
        let kept = files.suffix(limit).map { oneLine($0, maxPathLength) }
        let earlier = files.count - kept.count
        return filesTitle + (earlier > 0 ? "(+\(earlier) antes) " : "") + kept.joined(separator: ", ")
    }

    /// The files a files line names, in its order (what `filesLine` wrote, without the count of earlier ones).
    static func files(inLine line: String) -> [String] {
        guard line.hasPrefix(filesTitle) else { return [] }
        var rest = Substring(line.dropFirst(filesTitle.count))
        if rest.hasPrefix("(+"), let close = rest.range(of: ") ") { rest = rest[close.upperBound...] }
        return rest.components(separatedBy: ", ").filter { !$0.isEmpty }
    }

    /// A call to a connector, through the gateway (`connector_tools`, `connector_call`) or by the tool's own name
    /// (`GitHub__create_issue`, `mcp__github__…`): what it carries and returns is the connector's content, not the Orb's.
    static func isConnectorCall(_ name: String) -> Bool {
        name == ConnectorGateway.toolsName || name == ConnectorGateway.callName || name.contains("__")
    }

    /// `[passo 7] read_file /src/mod3.swift -> ok, 20.000 car.; começa com «func exemplo…»`. A connector's call keeps only its
    /// name and whether it worked: the arguments and the start of the answer are the connector's content.
    static func line(call: ToolCallRequest, result: ChatMessage?, step: Int) -> String {
        var text = "[passo \(step)] \(call.name)"
        let isConnector = isConnectorCall(call.name)
        let target = isConnector ? (JSONValue.parse(call.arguments)?["connector"]?.string.map { oneLine($0, 40) } ?? "") : target(of: call.arguments)
        if !target.isEmpty { text += " " + target }
        guard let result else { return clip(text + " -> sem resposta") }
        if isConnector { return clip(text + (result.isError ? " -> ERRO" : " -> ok")) }
        let first = oneLine(firstLine(of: result.content), result.isError ? 100 : 50)
        if result.isError {
            text += " -> ERRO" + (first.isEmpty ? "" : ": " + first)
        } else if result.content.isEmpty {
            text += result.images.isEmpty ? " -> ok, vazio" : " -> ok, \(result.images.count) imagem(ns)"
        } else {
            text += " -> ok, \(grouped(result.content.count)) car."
            if !first.isEmpty { text += "; começa com «\(first)»" }
        }
        return clip(text)
    }

    /// The path, command, link or search a call was about, short.
    private static func target(of arguments: String) -> String {
        guard let parsed = JSONValue.parse(arguments) else { return "" }
        for key in ["path", "file_path", "filepath", "command", "cmd", "url", "pattern", "query", "q", "name", "text"] {
            if let value = parsed[key]?.string, !value.isEmpty { return oneLine(value, 60) }
        }
        if case .object(let fields) = parsed {
            for key in fields.keys.sorted() {
                if let value = fields[key]?.string, !value.isEmpty { return oneLine(value, 60) }
            }
        }
        return ""
    }

    private static func firstLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }.map(String.init) ?? ""
    }

    private static func oneLine(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }

    private static func clip(_ text: String) -> String {
        text.count <= maxLineLength ? text : String(text.prefix(maxLineLength - 1)) + "…"
    }

    /// 20000 -> "20.000".
    static func grouped(_ number: Int) -> String {
        var digits = String(number)
        var result = ""
        while digits.count > 3 {
            result = "." + digits.suffix(3) + result
            digits.removeLast(3)
        }
        return digits + result
    }
}

// MARK: - Progress record

/// What a task that hit the step limit leaves in the history: a local digest of what it did, so "continua" (or
/// the next run of a routine) picks up knowing where it stands, whatever the model remembered to say.
enum ProgressRecord {
    static let marker = "[Orb] Progresso até aqui:"

    /// The record for the steps of the task since its request: the task plan first, while some step is open, so a
    /// "continua" picks up at the right step. nil when the task made no tool calls.
    static func text(task messages: [ChatMessage], plan: TaskPlan? = nil) -> String? {
        let lines = ToolDigest.lines(for: messages)
        guard !lines.isEmpty else { return nil }
        let planned = plan.flatMap { $0.isActive ? [$0.compact()] : nil } ?? []
        return ([marker] + planned + lines).joined(separator: "\n")
    }

    /// Whether the last message of `history` is such a record (inside the final message or as a message of its own).
    static func endsHistory(_ history: [ChatMessage]) -> Bool {
        guard let last = history.last, last.role == .assistant else { return false }
        return last.content.contains(marker)
    }
}

extension Conversation {
    /// The last task stopped at the step limit and has not been picked up since: the next message continues it.
    /// The engine says so (`taskPaused`); the record's marker only decides for conversations stored before that, so a
    /// model that imitates the marker in an ordinary reply does not pause anything.
    var isTaskPaused: Bool { taskPaused ?? ProgressRecord.endsHistory(messages) }
}
