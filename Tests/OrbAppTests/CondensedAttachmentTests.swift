import Foundation
import Testing
@testable import Orb

/// Old messages keep the path of an attached file and its first lines, not the whole text, and the blocks about the
/// Orb's work outside the chat shrink to a line; a second pass changes nothing.
struct CondensedAttachmentTests {
    private let path = "/Users/a/Documents/relatorio.txt"

    private func message(body: String, blocks: String = "", second: String = "") -> String {
        TurnPreface.openTag + "\nNow: agora\n" + TurnPreface.closeTag + "\n" + blocks + "Leia isso.\n\nAttached files (2):\n- \(path)"
            + AttachmentText.contentsMarker + "path=\"\(path)\" kind=\"text\">\n" + body + "\n</attached_file>" + second
    }

    @Test func attachedFileKeepsHeadAndPath() {
        let body = String(repeating: "linha de texto\n", count: 2_000)
        let content = message(body: body)
        let condensed = TurnPreface.condensed(content, keepingSnapshot: false)
        #expect(condensed.count < 1_500)
        #expect(condensed.contains(String(body.prefix(TurnPreface.attachedFileLimit))))
        #expect(condensed.contains("the file is at \(path), read it again with read_file]"))
        #expect(condensed.contains("Leia isso.") && condensed.hasSuffix("</attached_file>"))
        #expect(TurnPreface.condensed(condensed, keepingSnapshot: false) == condensed)
        #expect(TurnPreface.userWords(condensed) == TurnPreface.userWords(content))
    }

    @Test func eachFileIsCutAndSmallOnesStay() {
        let big = String(repeating: "x", count: 5_000)
        let second = AttachmentText.contentsMarker + "path=\"/b.txt\">\nPequeno\n</attached_file>"
        let condensed = TurnPreface.condensed(message(body: big, second: second), keepingSnapshot: false)
        #expect(condensed.contains("Pequeno\n</attached_file>"))
        #expect(condensed.contains("4200 characters omitted; the file is at \(path)"))
    }

    @Test func snapshotMessageKeepsPrefaceButFilesShrink() {
        let content = TurnPreface.openTag + "\nNow: agora\n" + WorkspaceSnapshot.openTag + "\na.txt\n" + WorkspaceSnapshot.closeTag
            + "\n" + TurnPreface.closeTag + "\nOi" + AttachmentText.contentsMarker + "path=\"/c.txt\">\n"
            + String(repeating: "y", count: 4_000) + "\n</attached_file>"
        let condensed = TurnPreface.condensed(content, keepingSnapshot: true)
        #expect(condensed.contains("a.txt") && condensed.count < 1_500)
        #expect(TurnPreface.condensed(condensed, keepingSnapshot: true) == condensed)
    }

    @Test func backgroundBlocksBecomeALine() {
        let blocks = SinceLastTurn.openTag + "\nO Orb fez coisas\nmuitas\n" + SinceLastTurn.closeTag + "\n"
            + RequestBackground.openTag + "\nfundo longo\n" + RequestBackground.closeTag + "\n"
        let content = message(body: "curto", blocks: blocks)
        let condensed = TurnPreface.condensed(content, keepingSnapshot: false)
        #expect(!condensed.contains("muitas") && !condensed.contains("fundo longo"))
        #expect(condensed.contains(SinceLastTurn.openTag) && condensed.contains(RequestBackground.openTag))
        #expect(TurnPreface.condensed(condensed, keepingSnapshot: false) == condensed)
        #expect(TurnPreface.stripped(condensed).hasPrefix("Leia isso."))
    }

    @Test func savingsCountAttachments() {
        let messages: [ChatMessage] = [.user(message(body: String(repeating: "z", count: 20_000))), .user("ok"), .user("fim")]
        #expect(ContextCondensing.savings(in: messages, from: 0, to: 1) > 19_000)
    }
}
