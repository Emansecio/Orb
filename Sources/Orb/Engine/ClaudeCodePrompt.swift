import Foundation

// MARK: - System prompt

/// Text appended to Claude Code's own system prompt. No clock or other per-turn values. A session sends the same text on
/// every resume (`TurnPrompt.claudeCode`), byte for byte, so Claude Code's own prompt cache holds from one turn to the next;
/// the text is rebuilt (one cache miss) only when the identity, the preferences or the standing rules change, and then the
/// change also goes in the turn's context (`TurnPreface`, `memoryUpdate`, `standingUpdate`), as everything else that varies.
enum ClaudeCodePrompt {
    /// Conversation turns this Claude Code session has not seen (other models answered in Orb), as a compact
    /// preface for its next prompt. Empty when there is nothing to catch up on.
    static func catchUp(_ messages: [ChatMessage], limit: Int = 12_000) -> String {
        let lines: [String] = messages.compactMap { message in
            switch message.role {
            case .system:
                return nil
            case .user:
                // Pictures cannot travel in a prompt; Claude Code's Read tool opens the files.
                let pictures = message.images.isEmpty ? "" : "\n[images: " + message.images.map(\.path).joined(separator: ", ") + "]"
                return "User: \(TurnPreface.stripped(message.content))" + pictures
            case .assistant:
                var text = message.content
                let calls = message.toolCalls.map { "\($0.name)(\($0.arguments.prefix(200)))" }
                if !calls.isEmpty { text += (text.isEmpty ? "" : "\n") + "[called: " + calls.joined(separator: "; ") + "]" }
                return text.isEmpty ? nil : "Assistant: \(text)"
            case .tool:
                let pictures = message.images.isEmpty ? "" : " [images: " + message.images.map(\.path).joined(separator: ", ") + "]"
                return "Tool result: \(message.content.prefix(500))" + pictures
            }
        }
        guard !lines.isEmpty else { return "" }
        var body = lines.joined(separator: "\n\n")
        if body.count > limit { body = "…" + body.suffix(limit) }
        return "Earlier in this Orb conversation (answered by another model, so you have not seen it):\n\n"
            + body + "\n\n---\nThe user's new message:"
    }

    /// The memory tools as Claude Code names them (served by `OrbToolsMCPServer`).
    static let memoryTools = MemoryToolNames(remember: ClaudeCodeTools.memoryPrefix + "remember",
                                             recall: ClaudeCodeTools.memoryPrefix + "recall")

    /// On resumed turns the memory that changes goes with the message, not in the system prompt (which stays the same for
    /// the cache): what relates to this message, and the identity and preferences again if they changed.
    static func memoryUpdate(_ brief: MemoryBrief, pinnedChanged: Bool) -> String {
        var parts: [String] = []
        if pinnedChanged, !brief.pinned.isEmpty {
            parts.append("Your identity and the user's preferences changed; this replaces the earlier version:\n" + brief.pinned)
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
        [opening(bot), standingPermissions(bot), PromptParts.skills(skills, engine: .claudeCode), folder].filter { !$0.isEmpty }
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
            memory,
            PromptParts.skills(skills, engine: .claudeCode),
            folder,
        ]
        sections.removeAll { $0.isEmpty }
        return sections.joined(separator: "\n\n")
    }

    /// The permissions section as the system prompt has it.
    static func standingPermissions(_ bot: Bot) -> String { PromptParts.permissions(bot, engine: .claudeCode) }
}
