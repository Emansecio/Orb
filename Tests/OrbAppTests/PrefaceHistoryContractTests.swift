import Foundation
import Testing
@testable import Orb

/// The prefaces rest on what stays in the history: a block of folder changes means something only next to the snapshot
/// it follows, and a memory counts as sent only while the message that carried it is still there. Trimming the history
/// (`ContextWindow.fit`) drops whole turns from the front, never from the middle, and `TurnPrompt.native` reads the
/// history it is given, so both hold by construction. These tests keep it that way.

private let mac = MacEnvironment(userName: "Maria", homePath: "/Users/maria", macOS: "macOS 15.1", locale: "pt_BR",
                                 languages: ["pt-BR"], timeZone: "UTC")

private let bulk = (0..<30).map { "modulo\($0)/" }

private func snapshot(_ step: Int) -> WorkspaceSnapshot {
    var snapshot = WorkspaceSnapshot(path: "/Users/maria/app", entries: bulk + ["arquivo\(step).txt"])
    snapshot.git = .init(branch: "main", commits: ["a1 2026-10-01 Primeiro"])
    return snapshot
}

private func brief(_ related: String) -> MemoryBrief {
    var brief = MemoryBrief(related: related)
    brief.notes = TurnPreface.relatedNotes(brief) // the first message takes the notes, later ones the related lines
    return brief
}

private func inputs(_ step: Int, related: String = "") -> TurnPromptInputs {
    var bot = Bot(name: "Atlas", role: "assistente", orb: OrbConfig())
    bot.workingDirectory = "/Users/maria/app"
    return TurnPromptInputs(bot: bot, skills: [], brief: brief(related), snapshot: snapshot(step), instructions: nil,
                            environment: mac, now: Date(timeIntervalSince1970: 1_790_000_000 + Double(step)))
}

/// A conversation of `turns` messages where the folder changes before each one, so the first message carries the whole
/// snapshot and each later one a block of changes. `related[turn]` is the memory line that message carries.
private func conversation(turns: Int, related: [Int: String] = [:], padding: Int = 0) -> [ChatMessage] {
    var history: [ChatMessage] = []
    var last: TurnPrompt.Native?
    for turn in 0..<turns {
        let built = TurnPrompt.native(inputs(turn, related: related[turn] ?? ""), history: history, lastWorkspaceHash: last?.workspaceHash,
                                      lastWorkspace: last?.workspace)
        let text = "pergunta \(turn) " + String(repeating: "x", count: padding)
        history += [.user(TurnPreface.prepend(built.preface, to: text)), ChatMessage(role: .assistant, content: "resposta \(turn)")]
        last = built
    }
    return history
}

struct PrefaceHistoryContractTests {
    @Test func theConversationHasTheChainTheTestsRelyOn() {
        let history = conversation(turns: 4)
        let users = history.filter { $0.role == .user }.map(\.content)
        #expect(users[0].contains(WorkspaceSnapshot.openTag))
        #expect(users.dropFirst().allSatisfy { $0.contains(WorkspaceSnapshot.changesOpenTag) && !$0.contains(WorkspaceSnapshot.openTag) })
    }

    @Test func trimmingTheHistoryDropsWholeTurnsFromTheFrontOnly() {
        let history = conversation(turns: 8, padding: 700)
        let window = ContextWindow.fit(history, budget: ContextBudget(tokens: 1_200))
        #expect(window.droppedCount > 0)
        let kept = window.messages.filter { $0.role == .user && $0.content.hasPrefix(TurnPreface.openTag) }.map(\.content)
        let all = history.filter { $0.role == .user }.map(\.content)
        // What is left is the end of the conversation, with no turn missing in the middle.
        #expect(!kept.isEmpty && kept == Array(all.suffix(kept.count)))
    }

    @Test func aChainWhoseSnapshotWasTrimmedAwayGetsTheWholeSnapshotAgain() {
        let history = conversation(turns: 8, padding: 700)
        let window = ContextWindow.fit(history, budget: ContextBudget(tokens: 1_200))
        let kept = window.messages
        #expect(!TurnPreface.hasSnapshot(in: kept)) // the snapshot was in the first message
        let last = TurnPrompt.native(inputs(7), history: history, lastWorkspaceHash: nil)
        let next = TurnPrompt.native(inputs(8), history: kept, lastWorkspaceHash: snapshot(7).hash, lastWorkspace: last.workspace)
        #expect(next.preface.contains(WorkspaceSnapshot.openTag) && !next.preface.contains(WorkspaceSnapshot.changesOpenTag))
    }

    @Test func aSnapshotThatSurvivesKeepsEveryBlockOfChangesAfterIt() {
        let history = conversation(turns: 4)
        let window = ContextWindow.fit(history, budget: ContextBudget(tokens: 100_000))
        #expect(window.droppedCount == 0 && window.messages.count == history.count)
        let last = TurnPrompt.native(inputs(3), history: Array(history.prefix(6)), lastWorkspaceHash: nil)
        let next = TurnPrompt.native(inputs(4), history: window.messages, lastWorkspaceHash: snapshot(3).hash, lastWorkspace: last.workspace)
        #expect(TurnPreface.hasSnapshot(in: window.messages))
        #expect(next.preface.contains(WorkspaceSnapshot.changesOpenTag) && !next.preface.contains(WorkspaceSnapshot.openTag))
    }

    @Test func aMemoryCountsAsSentOnlyWhileItsMessageIsStillInTheHistory() {
        let line = "- [Fato, 07/10/2026 14:32 #a1b2] O banco é Postgres 16"
        let history = conversation(turns: 8, related: [0: line], padding: 700)
        // In the whole history the line is out of the window of the last three messages, so it is not "sent" anymore...
        #expect(TurnPreface.relatedLines(in: history).isEmpty)
        // ...and with a short history it is.
        #expect(TurnPreface.relatedLines(in: Array(history.prefix(4))) == [line])
        // Whatever the trimming keeps, a line only counts if its message was kept.
        let kept = ContextWindow.fit(conversation(turns: 8, related: [1: line], padding: 700), budget: ContextBudget(tokens: 1_200)).messages
        #expect(TurnPreface.relatedLines(in: kept).isEmpty)
    }

    @Test func theWindowOfRelatedMemoryIsWithinWhatTrimmingKeepsWhole() {
        // The window is counted in messages of the history that is actually sent, and the budget never trims below the
        // latest turn, so a window larger than the history just means "everything still there".
        let history = conversation(turns: 2, related: [0: "- [Fato, 07/10/2026 14:32 #a1b2] A"])
        #expect(TurnPreface.relatedLines(in: history).count == 1)
        #expect(TurnPreface.relatedWindow == 3)
    }
}
