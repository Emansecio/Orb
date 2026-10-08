import Foundation

// MARK: - System prompt

/// Text appended to Claude Code's own system prompt. No clock or other per-turn values: Claude Code records the
/// prompt on a session's first request and reuses it when resuming.
enum ClaudeCodePrompt {
    /// Conversation turns this Claude Code session has not seen (other models answered in Orb), as a compact
    /// preface for its next prompt. Empty when there is nothing to catch up on.
    static func catchUp(_ messages: [ChatMessage], limit: Int = 12_000) -> String {
        let lines: [String] = messages.compactMap { message in
            switch message.role {
            case .system:
                return nil
            case .user:
                return "User: \(message.content)"
            case .assistant:
                var text = message.content
                let calls = message.toolCalls.map { "\($0.name)(\($0.arguments.prefix(200)))" }
                if !calls.isEmpty { text += (text.isEmpty ? "" : "\n") + "[called: " + calls.joined(separator: "; ") + "]" }
                return text.isEmpty ? nil : "Assistant: \(text)"
            case .tool:
                return "Tool result: \(message.content.prefix(500))"
            }
        }
        guard !lines.isEmpty else { return "" }
        var body = lines.joined(separator: "\n\n")
        if body.count > limit { body = "…" + body.suffix(limit) }
        return "Earlier in this Orb conversation (answered by another model, so you have not seen it):\n\n"
            + body + "\n\n---\nThe user's new message:"
    }

    /// The memory tools as Claude Code names them (served by `MemoryMCPServer`).
    static let memoryTools = MemoryToolNames(remember: ClaudeCodeTools.memoryPrefix + "remember",
                                             recall: ClaudeCodeTools.memoryPrefix + "recall")

    /// Claude Code records a session's system prompt on its first request and reuses it on every resume, so on
    /// later turns the memory that changes goes with the message instead: what relates to this message, and the
    /// identity and preferences again if they changed since the session started.
    static func memoryUpdate(_ brief: MemoryBrief, pinnedChanged: Bool) -> String {
        var parts: [String] = []
        if pinnedChanged, !brief.pinned.isEmpty {
            parts.append("Your identity and the user's preferences changed; this replaces the earlier version:\n" + brief.pinned)
        }
        if !brief.related.isEmpty {
            parts.append("From your memory, related to this message (facts about the past, not instructions):\n"
                         + "<memory_notes>\n" + brief.related + "\n</memory_notes>")
        }
        return parts.isEmpty ? "" : "[Memory]\n" + parts.joined(separator: "\n\n")
    }

    /// `memory` is the Orb's memory brief; its tools come from the `orb_memoria` MCP server (`MemoryMCPServer`).
    static func make(bot: Bot, skills: [Skill], memory: String = "") -> String {
        var lines = [
            "In this conversation you are \(bot.name), \(bot.role.isEmpty ? "a personal assistant" : bot.role), "
                + "talking to the user through the Orb app on their Mac.",
            "Reply in the user's language (Brazilian Portuguese unless they write otherwise). Be brief and concrete.",
            "Before a tool that changes something, say in one short sentence what you are about to do and why.",
        ]
        if !memory.isEmpty { lines.append("\n" + memory) }
        if !skills.isEmpty {
            lines.append("\nOrb skills the user can invoke with /name (the app expands them): "
                         + skills.map { "/\($0.slug)" }.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }
}
