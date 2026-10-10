import Foundation

extension ClaudeCodeTools {
    /// Every built-in tool of the CLI that the creation assistant must not have: named in `--disallowedTools` next to the empty
    /// `--tools=`, so a CLI that ignores one of the two still has none (and `authorize` refuses what slips through).
    static let everyBuiltIn = Array(Set(terminal + web + [
        "Read", "Task", "Agent", "TodoWrite", "TaskCreate", "TaskGet", "TaskList", "TaskUpdate", "ExitPlanMode", "EnterPlanMode",
        "SlashCommand", "Skill", "ToolSearch", "Monitor", "ListMcpResourcesTool", "ReadMcpResourceTool", "EnterWorktree",
        "ExitWorktree", "CronCreate", "CronDelete", "CronList", "ScheduleWakeup", "AskUserQuestion",
    ])).sorted()
}
