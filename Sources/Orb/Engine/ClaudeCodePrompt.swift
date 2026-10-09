import Foundation

// MARK: - System prompt

/// Text appended to Claude Code's own system prompt. No clock or other per-turn values. A session sends the same text on
/// every resume (`TurnPrompt.claudeCode`), byte for byte, so Claude Code's own prompt cache holds from one turn to the next;
/// the text is rebuilt (one cache miss) only when the identity, the preferences or the standing rules change, and then the
/// change also goes in the turn's context (`TurnPreface`, `memoryUpdate`, `standingUpdate`), as everything else that varies.
enum ClaudeCodePrompt {
    /// What a Claude Code session has not seen of the conversation (other models answered in Orb, or the session is
    /// new), as a compact preface for its next prompt; empty when there is nothing to catch up on.
    /// `seen`: how many of the conversation's messages the session already has (0 for a new session).
    ///
    /// - The conversation's summary stands in for what it covers (the first request and the decisions among it), so a
    ///   new session starts from it and only the messages after it are listed.
    /// - Messages are listed whole or not at all, newest first until `limit` characters are used: the user's requests
    ///   and the assistant's answers before tool calls and results, which are one short line each. A request or an
    ///   answer is cut at 1,200 characters, except the latest request and the latest answer (up to 8,000 and 4,000:
    ///   a pasted specification or log is what the new session has to work on). What does not fit is summarized the
    ///   same way as the conversation's own summary (so the first request and the decisions are never lost), not cut
    ///   in the middle of a line.
    static func catchUp(_ conversation: Conversation, seen: Int = 0, limit: Int = 16_000) -> String {
        let all = conversation.messages
        let seen = min(max(seen, 0), all.count)
        guard seen < all.count else { return "" }
        // The summary covers a prefix of the conversation; use it when the session missed part of that prefix.
        let covered = conversation.coveredMessageCount
        let useSummary = conversation.summary != nil && seen < covered
        let start = useSummary ? covered : seen
        var messages = Array(all[start...])
        while messages.first?.role == .tool { messages.removeFirst() }   // the call it answers is not part of this

        let lastRequest = messages.lastIndex { $0.role == .user && !$0.content.hasPrefix(ContextSummary.marker) }
        let lastAnswer = messages.lastIndex { $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let units = messages.enumerated().map { index, message in
            Unit(message, limit: index == lastRequest ? Unit.latestRequestLimit : index == lastAnswer ? Unit.latestAnswerLimit : Unit.textLimit)
        }
        // What is summarized takes a share of the room; when everything fits, none of it is needed.
        let share = min(ContextSummary.maxLength, limit / 3)
        var room = limit - 200 - (useSummary ? share : 0)
        if !useSummary, units.reduce(0, { $0 + $1.text.count + 2 }) > room { room -= share }
        let chosen = choose(units, room: room)

        // The messages older than the oldest one listed join the summary (which keeps the first request and the
        // decisions), instead of being cut off.
        let firstListed = chosen.min() ?? messages.count
        var ledger = useSummary ? conversation.currentLedger : nil
        if firstListed > 0 { ledger = (ledger ?? ConversationLedger()).absorbing(Array(messages[..<firstListed])) }
        let recap = ledger.map { $0.render(limit: share) }.flatMap { $0.isEmpty ? nil : $0 }

        var body = chosen.sorted().map { units[$0].text }
        if firstListed > 0, !body.isEmpty { body.insert("[… \(firstListed) earlier messages are in the summary above …]", at: 0) }
        guard !body.isEmpty || recap != nil else { return "" }
        var text = "Earlier in this Orb conversation (answered by another model, so you have not seen it):\n\n"
        if let recap { text += "Summary of the older part (written by Orb):\n" + recap + "\n\n" }
        return text + body.joined(separator: "\n\n") + "\n\n---\nThe user's new message:"
    }

    /// The same for a list of messages that is all of the conversation (no summary).
    static func catchUp(_ messages: [ChatMessage], limit: Int = 16_000) -> String {
        var conversation = Conversation()
        conversation.messages = messages
        return catchUp(conversation, seen: 0, limit: limit)
    }

    /// One message as a catch-up line.
    private struct Unit {
        var text: String
        /// A request or an answer: kept before tool lines when space is short.
        var isEssential: Bool

        static let textLimit = 1_200
        static let latestRequestLimit = 8_000
        static let latestAnswerLimit = 4_000

        init(_ message: ChatMessage, limit: Int = Unit.textLimit) {
            func clip(_ text: String, _ limit: Int) -> String { text.count > limit ? String(text.prefix(limit)) + "…" : text }
            switch message.role {
            case .system:
                text = ""
                isEssential = false
            case .user:
                // Pictures cannot travel in a prompt; Claude Code's Read tool opens the files.
                let pictures = message.images.isEmpty ? "" : "\n[images: " + message.images.map(\.path).joined(separator: ", ") + "]"
                text = message.content.hasPrefix(ContextSummary.marker) ? "" : "User: " + clip(TurnPreface.stripped(message.content), limit) + pictures
                isEssential = true
            case .assistant:
                var line = clip(message.content, limit)
                let calls = message.toolCalls.map { "\($0.name)(\($0.arguments.prefix(160)))" }
                if !calls.isEmpty { line += (line.isEmpty ? "" : "\n") + "[called: " + calls.joined(separator: "; ") + "]" }
                text = line.isEmpty ? "" : "Assistant: " + line
                isEssential = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .tool:
                let pictures = message.images.isEmpty ? "" : " [images: " + message.images.map(\.path).joined(separator: ", ") + "]"
                let first = message.content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                text = "Tool result: " + clip(first, 240) + pictures
                isEssential = false
            }
        }
    }

    /// The indices to list: the newest requests and answers first, then the tool lines newer than the oldest of
    /// them, until `limit` characters are used. The latest request is always in.
    private static func choose(_ units: [Unit], room: Int) -> Set<Int> {
        var room = room
        var chosen: Set<Int> = []
        for index in units.indices.reversed() where units[index].isEssential && !units[index].text.isEmpty {
            let cost = units[index].text.count + 2
            guard cost <= room || chosen.isEmpty else { break }
            chosen.insert(index)
            room -= cost
        }
        guard let oldest = chosen.min() else { return chosen }
        for index in units.indices.reversed() where index > oldest && !units[index].isEssential && !units[index].text.isEmpty {
            let cost = units[index].text.count + 2
            guard cost <= room else { continue }
            chosen.insert(index)
            room -= cost
        }
        return chosen
    }

    /// The memory tools as Claude Code names them (served by `OrbToolsMCPServer`).
    static let memoryTools = MemoryToolNames(remember: ClaudeCodeTools.memoryPrefix + "remember",
                                             recall: ClaudeCodeTools.memoryPrefix + "recall")

    /// On resumed turns the memory that changes goes with the message, not in the system prompt (which stays the same for
    /// the cache): what relates to this message, and the identity and preferences again if they changed.
    static func memoryUpdate(_ brief: MemoryBrief, pinnedChanged: Bool) -> String {
        var parts: [String] = []
        if pinnedChanged, !brief.pinned.isEmpty {
            parts.append("Your identity, the user's profile and preferences changed; this replaces the earlier version:\n" + brief.pinned)
        }
        if !brief.related.isEmpty { parts.append(TurnPreface.relatedNotes(brief)) }
        return parts.isEmpty ? "" : "[Memory]\n" + parts.joined(separator: "\n\n")
    }

    /// What a resumed session must be told again when the sections of `standing` changed since its system prompt was built
    /// (in case the system prompt of a session is not read again, or Claude Code compacts the session).
    static func standingUpdate(_ sections: [String]) -> String {
        "[Updated rules]\nThese replace the earlier version of the same sections in your instructions:\n\n"
            + sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The parts of the system prompt that can change while a session runs (the Orb is renamed or given another mode,
    /// skills are added, the folder's instructions are edited), in prompt order. They are compared by hash, and sent
    /// again with the message when they differ from what the session started with.
    static func standing(bot: Bot, skills: [Skill], folder: String) -> [String] {
        [opening(bot), standingPermissions(bot), PromptParts.macApps(bot, engine: .claudeCode),
         PromptParts.skills(skills, engine: .claudeCode), folder].filter { !$0.isEmpty }
    }

    /// Who the Orb is and how it talks: the first lines of the prompt.
    static func opening(_ bot: Bot) -> String {
        [PromptParts.identity(bot, engine: .claudeCode), PromptParts.roaming(bot), PromptParts.language, PromptParts.announce]
            .joined(separator: "\n")
    }

    /// `memory` is the stable part of the Orb's memory brief (`MemoryBrief.stable`); its tools come from the
    /// `orb_memoria` MCP server (`OrbToolsMCPServer`), with the Mac tools. `folder` is the folder's instruction file section; Claude Code
    /// reads CLAUDE.md by itself, so the caller leaves that one out.
    static func make(bot: Bot, skills: [Skill], memory: String = "", environment: MacEnvironment = .current(), folder: String = "") -> String {
        var sections = [
            opening(bot),
            PromptParts.environment(environment, engine: .claudeCode),
            standingPermissions(bot),
            PromptParts.untrustedContent,
            PromptParts.workHabits,
            PromptParts.macApps(bot, engine: .claudeCode),
            memory,
            PromptParts.skills(skills, engine: .claudeCode),
            folder,
        ]
        sections.removeAll { $0.isEmpty }
        return sections.joined(separator: "\n\n")
    }

    /// The system prompt, plus the note that the interface tools are held back when the app lacks Accessibility (the native
    /// engine says the same in its prompt). `accessibilityGranted` nil means the Orb does not control apps: nothing to say.
    static func withAccessibilityNote(_ system: String, accessibilityGranted: Bool?) -> String {
        accessibilityGranted == false ? system + "\n\n" + ToolBox.accessibilityUnavailableNote : system
    }

    /// The permissions section as the system prompt has it.
    static func standingPermissions(_ bot: Bot) -> String { PromptParts.permissions(bot, engine: .claudeCode) }
}
