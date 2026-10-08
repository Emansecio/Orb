import Foundation
import Testing
@testable import Orb

/// Condensing old messages must not lose what the model knows about the folder: the newest snapshot stays whole and
/// the changes reported after it (which describe the folder since that snapshot) keep their block.
struct CondensedFolderChangesTests {
    private let changes = WorkspaceSnapshot.changesOpenTag + "\n+relatorio.md\n" + WorkspaceSnapshot.changesCloseTag

    private func preface(_ body: String) -> String {
        TurnPreface.openTag + "\nNow: quinta-feira, 8 de outubro de 2026 às 9:00\n" + body + "\n<memory_notes>\n- nota\n</memory_notes>\n"
            + TurnPreface.closeTag + "\nOlá"
    }

    @Test func changesAfterTheNewestSnapshotSurviveCondensing() {
        let condensed = TurnPreface.condensed(preface(changes), keepingSnapshot: false, keepingChanges: true)
        #expect(condensed.contains("+relatorio.md") && condensed.contains("Now:"))
        #expect(!condensed.contains("<memory_notes>"))
        #expect(condensed.hasSuffix("Olá"))
        // A second pass changes nothing.
        #expect(TurnPreface.condensed(condensed, keepingSnapshot: false, keepingChanges: true) == condensed)
    }

    @Test func changesBeforeTheNewestSnapshotGo() {
        let condensed = TurnPreface.condensed(preface(changes), keepingSnapshot: false)
        #expect(!condensed.contains("+relatorio.md") && condensed.contains("Now:"))
    }

    @Test func onlyMessagesAfterTheNewestSnapshotKeepTheirChanges() {
        let snapshot = TurnPreface.openTag + "\nNow: agora\n" + WorkspaceSnapshot.openTag + "\na.txt\n" + WorkspaceSnapshot.closeTag
            + "\n" + TurnPreface.closeTag + "\nComeço"
        let messages: [ChatMessage] = [.user(preface(changes)), .user(snapshot), .user(preface(changes))]
        let index = ContextCondensing.snapshotIndex(in: messages)
        #expect(index == 1)
        let before = ContextCondensing.condensed(messages[0], keepingSnapshot: false, keepingChanges: index.map { 0 > $0 } ?? false)
        let after = ContextCondensing.condensed(messages[2], keepingSnapshot: false, keepingChanges: index.map { 2 > $0 } ?? false)
        #expect(!before.content.contains("+relatorio.md"))
        #expect(after.content.contains("+relatorio.md"))
    }
}
