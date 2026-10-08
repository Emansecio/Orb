import Foundation

// MARK: - System prompt

enum SystemPrompt {
    /// `memory` is the Orb's memory brief (`MemoryBank.brief`).
    static func make(bot: Bot, skills: [Skill], memory: String = "", now: Date = .now) -> String {
        var lines = [
            "You are \(bot.name), \(bot.role.isEmpty ? "a personal assistant" : bot.role).",
            "You run natively on the user's Mac inside the Orb app and can act through your tools.",
            "Now: \(now.formatted(date: .complete, time: .shortened)) (\(TimeZone.current.identifier)).",
            "Home folder: \(FileManager.default.homeDirectoryForCurrentUser.path). Working directory: \(bot.workingURL.path).",
            "Reply in the user's language (Brazilian Portuguese unless they write otherwise). Be brief and concrete.",
            "Use tools to find out and to act instead of asking the user to do it. Read before you change things.",
            "Before a tool that changes something, say in one short sentence what you are about to do and why.",
        ]
        if !memory.isEmpty { lines.append("\n" + memory) }
        if !skills.isEmpty {
            lines.append("\nThe user can invoke skills with /name: " + skills.map { "/\($0.slug)" }.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    /// Expands "/slug rest" into the skill's instructions plus the request; nil if no skill matches.
    static func expandSkill(in prompt: String, skills: [Skill]) -> (skill: Skill, prompt: String)? {
        guard prompt.hasPrefix("/") else { return nil }
        let parts = prompt.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let slug = parts.first, let skill = skills.first(where: { $0.slug == slug }) else { return nil }
        let rest = parts.count > 1 ? String(parts[1]) : ""
        let files = skill.folderURL.map { "\n\n(Files this skill refers to are in \($0.absoluteString); fetch them if needed.)" } ?? ""
        return (skill, "Skill \"\(skill.name)\":\n\(skill.instructions)\(files)\n\nUser request: \(rest.isEmpty ? "(none)" : rest)")
    }
}
