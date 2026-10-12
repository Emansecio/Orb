import Foundation

/// Where the pipe runs: an empty neutral working folder (the CLI's cwd), a scratch folder for per-run files, and the user's home.
struct ClaudePipeFolders: Sendable, Equatable {
    /// The CLI's cwd. Created on demand and kept empty, so the CLI finds nothing of a project to read about.
    var workingDirectory: URL
    /// One subfolder per run: system prompt, session file source, tool declarations, MCP config, mailbox.
    var scratch: URL
    var home: URL

    /// Under the app's data folder (`ORB_DATA_DIR` moves it, so a developer run never touches the user's), and the user's home.
    static var standard: ClaudePipeFolders {
        let root = DevRun.currentDataFolder.url.appending(path: "claude-pipe", directoryHint: .isDirectory)
        return ClaudePipeFolders(workingDirectory: root.appending(path: "cwd", directoryHint: .isDirectory),
                                 scratch: root.appending(path: "runs", directoryHint: .isDirectory),
                                 home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// `~/.claude/projects/<escaped realpath of workingDirectory>`: where the CLI looks for a session to resume.
    /// The CLI names the folder after the real path of its cwd (symlinks resolved: /var is /private/var on a Mac) with
    /// every character that is not an ASCII letter or digit replaced by "-" (one per UTF-16 unit, like the CLI's JavaScript).
    var projectDirectory: URL {
        let escaped = String(decoding: Self.realPath(workingDirectory).utf16.map { unit -> UInt16 in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: unit
            default: 0x2D
            }
        }, as: UTF16.self)
        return home.appending(path: ".claude", directoryHint: .isDirectory)
            .appending(path: "projects", directoryHint: .isDirectory)
            .appending(path: escaped, directoryHint: .isDirectory)
    }

    /// `realpath` of the folder, or, while it does not exist yet, of its deepest existing ancestor plus the rest of the path.
    static func realPath(_ url: URL) -> String {
        var rest: [String] = []
        var current = url.standardizedFileURL
        while true {
            if let resolved = realpath(current.path, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return rest.reversed().reduce(base) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 }
            }
            guard current.path != "/", current.pathComponents.count > 1 else { return url.standardizedFileURL.path }
            rest.append(current.lastPathComponent)
            current = current.deletingLastPathComponent()
        }
    }
}

/// Turns the engine's conversation into what the Claude Code CLI takes in: a session file it resumes (the history), and
/// one user message on stdin (the prompt). The CLI is only a transport; the conversation is the Orb's.
enum ClaudePipeSession {
    /// How the CLI names those tools: `mcp__<server>__<tool>`.
    static let toolPrefix = "mcp__orb__"

    struct Split: Equatable {
        /// Every `.system` message's content, joined by a blank line.
        var system: String
        /// Goes into the session file. Empty, or ends with an assistant message that is not a dangling tool call.
        var history: [ChatMessage]
        /// The user message to send on stdin.
        var prompt: String
        /// The pictures of that user message.
        var images: [ImageAttachment]
    }

    /// Splits the engine's messages for a FRESH process.
    ///
    /// The last `.user` message (index k) is the prompt. What comes before it is the history, from which the end is
    /// trimmed while it does not finish on an assistant message with text and no tool calls (the CLI would invent a
    /// "No response requested." reply after a user/tool message, and mark a tool call without result as interrupted):
    /// the trimmed messages are written as text in front of the user message. What comes after k (tool calls and results of
    /// an unfinished turn: a retry, or an app restart) is written as text after it. So nothing is lost.
    /// Without a user message, the whole conversation becomes the prompt, as text.
    static func split(_ messages: [ChatMessage]) -> Split {
        let system = messages.filter { $0.role == .system }.map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        let conversation = messages.filter { $0.role != .system }
        guard let k = conversation.lastIndex(where: { $0.role == .user }) else {
            let text = transcript(conversation)
            return Split(system: system, history: [], prompt: text.isEmpty ? "" : "[Conversa até aqui, em texto]\n" + text, images: [])
        }
        var end = k
        while end > 0, !endsCleanly(conversation[end - 1]) { end -= 1 }

        var sections: [String] = []
        let before = transcript(conversation[end..<k])
        if !before.isEmpty { sections.append("[Histórico anterior, em texto]\n" + before) }
        sections.append(conversation[k].content)
        let after = transcript(conversation[(k + 1)...])
        if !after.isEmpty { sections.append("[Continuação deste pedido, em texto]\n" + after) }
        return Split(system: system, history: Array(conversation[..<end]), prompt: sections.joined(separator: "\n\n"),
                     images: conversation[k].images)
    }

    /// JSONL lines of the session file for `history`: one object per line, chained by `parentUuid`.
    ///
    /// Assistant text and tool calls become content blocks (tool names carry `toolPrefix`); the `.tool` messages right after
    /// an assistant message become ONE user message with a `tool_result` block per answered call. A call with no result
    /// there, and a tool message with no call, are written as text instead (the API refuses a `tool_use` without its
    /// result). Neighbours of the same role are merged, the way the API reads them; a history that starts with the
    /// assistant gets a short user message first. Pictures are read from their files (unreadable ones are skipped);
    /// reasoning is not replayed; empty messages are skipped.
    static func sessionLines(_ history: [ChatMessage], sessionID: String, cwd: String, model: String, now: Date) throws -> [String] {
        var entries = entries(for: history)
        if entries.first?.role == "assistant" {
            entries.insert(Entry(role: "user", blocks: [textBlock("(A conversa começou pelo assistente.)")]), at: 0)
        }
        var lines: [String] = []
        var parent: String?
        for (index, entry) in entries.enumerated() {
            let uuid = UUID().uuidString.lowercased()
            var message: [String: JSONValue] = ["role": .string(entry.role)]
            if entry.role == "assistant" {
                message["model"] = .string(model)
                message["content"] = .array(entry.blocks)
            } else {
                message["content"] = content(entry.blocks)
            }
            let line: JSONValue = .object([
                "type": .string(entry.role), "uuid": .string(uuid), "parentUuid": parent.map(JSONValue.string) ?? .null,
                "sessionId": .string(sessionID), "cwd": .string(cwd), "isSidechain": .bool(false), "userType": .string("external"),
                "timestamp": .string(timestamp(now.addingTimeInterval(Double(index) * 0.001))), "message": .object(message),
            ])
            lines.append(try encode(line))
            parent = uuid
        }
        return lines
    }

    /// The stdin line of a user message (text + base64 images). Unreadable pictures are skipped.
    static func userLine(_ text: String, images: [ImageAttachment]) throws -> String {
        var blocks: [JSONValue] = []
        if !text.isEmpty { blocks.append(textBlock(text)) }
        blocks += images.compactMap(imageBlock)
        let content: JSONValue = blocks.isEmpty ? .string(text) : content(blocks)
        return try encode(.object(["type": .string("user"), "message": .object(["role": .string("user"), "content": content])]))
    }

    // MARK: - Session entries

    private struct Entry {
        var role: String
        var blocks: [JSONValue]
    }

    private static func entries(for history: [ChatMessage]) -> [Entry] {
        var result: [Entry] = []
        func add(_ role: String, _ blocks: [JSONValue]) {
            guard !blocks.isEmpty else { return }
            if let last = result.last, last.role == role { result[result.count - 1].blocks += blocks } else { result.append(Entry(role: role, blocks: blocks)) }
        }
        var i = 0
        while i < history.count {
            let message = history[i]
            switch message.role {
            case .system:
                i += 1
            case .user:
                var blocks: [JSONValue] = []
                if !message.content.isEmpty { blocks.append(textBlock(message.content)) }
                add("user", blocks + message.images.compactMap(imageBlock))
                i += 1
            case .tool:
                add("user", orphanBlocks(message))
                i += 1
            case .assistant:
                var j = i + 1
                while j < history.count, history[j].role == .tool { j += 1 }
                let (assistant, user) = assistantEntries(message, results: Array(history[(i + 1)..<j]))
                add("assistant", assistant)
                add("user", user)
                i = j
            }
        }
        return result
    }

    /// The assistant message's blocks, and the user blocks that answer them.
    private static func assistantEntries(_ message: ChatMessage, results: [ChatMessage]) -> (assistant: [JSONValue], user: [JSONValue]) {
        let callIDs = Set(message.toolCalls.map(\.id))
        var used = Set<String>()
        var answered: [ChatMessage] = []
        var strays: [ChatMessage] = []
        for result in results {
            if let id = result.toolCallID, callIDs.contains(id), used.insert(id).inserted { answered.append(result) } else { strays.append(result) }
        }
        var text = message.content
        var uses: [JSONValue] = []
        for call in message.toolCalls {
            if used.contains(call.id) {
                uses.append(.object(["type": .string("tool_use"), "id": .string(call.id), "name": .string(toolPrefix + call.name),
                                     "input": inputObject(call.arguments)]))
            } else {
                text += (text.isEmpty ? "" : "\n") + describe(call, result: nil)
            }
        }
        var assistant: [JSONValue] = []
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { assistant.append(textBlock(text)) }
        assistant += uses
        guard !assistant.isEmpty else { return ([], []) }
        var user = answered.map(resultBlock)
        for stray in strays { user += orphanBlocks(stray) }
        return (assistant, user)
    }

    private static func resultBlock(_ message: ChatMessage) -> JSONValue {
        let images = message.images.compactMap(imageBlock)
        let content: JSONValue
        if images.isEmpty {
            content = .string(message.content)
        } else {
            content = .array((message.content.isEmpty ? [] : [textBlock(message.content)]) + images)
        }
        return .object(["type": .string("tool_result"), "tool_use_id": .string(message.toolCallID ?? ""), "content": content,
                        "is_error": .bool(message.isError)])
    }

    /// A tool result whose call is not in the history: said as text (and its pictures).
    private static func orphanBlocks(_ message: ChatMessage) -> [JSONValue] {
        [textBlock(describeOrphan(message))] + message.images.compactMap(imageBlock)
    }

    private static func inputObject(_ arguments: String) -> JSONValue {
        if let value = JSONValue.parse(arguments), case .object = value { return value }
        return .object([:])
    }

    // MARK: - Text rendering

    /// Messages as plain text lines. A call and its result (a later `.tool` message of the slice) share one line.
    private static func transcript<S: Sequence>(_ messages: S) -> String where S.Element == ChatMessage {
        let list = Array(messages)
        var claimed = Set<Int>()
        var lines: [String] = []
        for (index, message) in list.enumerated() {
            switch message.role {
            case .system:
                break
            case .user:
                let text = [message.content, pictureNote(message.images.count)].filter { !$0.isEmpty }.joined(separator: " ")
                if !text.isEmpty { lines.append("Usuário: " + text) }
            case .assistant:
                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append("Assistente: " + message.content) }
                for call in message.toolCalls {
                    let found = list.indices.first { $0 > index && !claimed.contains($0) && list[$0].role == .tool && list[$0].toolCallID == call.id }
                    if let found { claimed.insert(found) }
                    lines.append(describe(call, result: found.map { list[$0] }))
                }
            case .tool:
                if !claimed.contains(index) { lines.append(describeOrphan(message)) }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ call: ToolCallRequest, result: ChatMessage?) -> String {
        let arguments = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = "Ferramenta \(call.name) chamada com \(arguments.isEmpty ? "{}" : arguments)"
        guard let result else { return head + " → sem resultado" }
        return head + " → resultado\(result.isError ? " (erro)" : ""): " + result.content + (result.images.isEmpty ? "" : " " + pictureNote(result.images.count))
    }

    private static func describeOrphan(_ message: ChatMessage) -> String {
        "Resultado de ferramenta\(message.isError ? " (erro)" : ""): " + message.content
            + (message.images.isEmpty ? "" : " " + pictureNote(message.images.count))
    }

    private static func pictureNote(_ count: Int) -> String {
        count == 0 ? "" : count == 1 ? "[1 imagem anexada]" : "[\(count) imagens anexadas]"
    }

    /// The history may end here: an assistant message with text and no tool calls.
    private static func endsCleanly(_ message: ChatMessage) -> Bool {
        message.role == .assistant && message.toolCalls.isEmpty
            && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - JSON

    private static func textBlock(_ text: String) -> JSONValue {
        .object(["type": .string("text"), "text": .string(text)])
    }

    private static func imageBlock(_ image: ImageAttachment) -> JSONValue? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: image.path)), !data.isEmpty else { return nil }
        return .object(["type": .string("image"), "source": .object([
            "type": .string("base64"), "media_type": .string(image.mediaType), "data": .string(data.base64EncodedString()),
        ])])
    }

    /// A lone text block is written as a plain string, the way the API takes a simple user message.
    private static func content(_ blocks: [JSONValue]) -> JSONValue {
        if blocks.count == 1, blocks[0]["type"]?.string == "text", let text = blocks[0]["text"]?.string { return .string(text) }
        return .array(blocks)
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Compact JSON with sorted keys: the same bytes for the same content.
    private static func encode(_ value: JSONValue) throws -> String {
        String(decoding: try WireEncoder.encode(value), as: UTF8.self)
    }
}
