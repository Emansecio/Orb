import Foundation
import Testing
@testable import Orb

private func user(_ text: String) -> TranscriptItem { TranscriptItem(.user(text: text, attachments: [])) }
private func bot(_ text: String) -> TranscriptItem { TranscriptItem(.bot(text: text, isStreaming: false)) }
private func tool() -> TranscriptItem {
    TranscriptItem(.tool(ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "ls", state: .done)))
}

struct ReplyAvatarsTests {
    @Test func aRunOfRepliesKeepsTheAvatarOnlyOnTheLast() {
        let a = bot("a"), b = bot("b"), c = bot("c")
        let avatars = ReplyAvatars([user("oi"), a, b, c])
        #expect(avatars.quiet == [a.id, b.id])
        #expect(avatars.lastID == c.id)
    }

    @Test func aMessageOfYoursCutsTheRun() {
        let a = bot("a"), b = bot("b"), c = bot("c")
        #expect(ReplyAvatars([user("1"), a, b, user("2"), c]).quiet == [a.id])
    }

    @Test func toolLinesAndNoticesInTheMiddleDoNotCutTheRun() {
        let a = bot("a"), b = bot("b")
        #expect(ReplyAvatars([user("1"), a, tool(), TranscriptItem(.notice("aviso")), b]).quiet == [a.id])
    }

    @Test func aMessageBetweenOrbsCutsTheRun() {
        let a = bot("a"), b = bot("b")
        let ref = OrbRef(id: UUID(), name: "Luna")
        let message = TranscriptItem(.orbMessage(OrbMessageItem(
            direction: .received, kind: .tell, state: .replied, from: ref, to: nil, text: "oi",
            requestID: UUID(), chainID: UUID(), groupID: nil, fromChat: nil)))
        #expect(ReplyAvatars([a, message, b]).quiet.isEmpty)
    }

    @Test func anEmptyChatHasNoLastReplyAndNothingQuiet() {
        let avatars = ReplyAvatars([])
        #expect(avatars.lastID == nil)
        #expect(avatars.quiet.isEmpty)
    }

    @Test func wordsFollowedByActionsAreNarrationWithoutAvatar() {
        let a = bot("a"), b = bot("b")
        let avatars = ReplyAvatars([user("1"), a, tool(), b, tool()])
        #expect(avatars.lastID == nil) // the working line below wears the avatar
        #expect(avatars.narration == [a.id, b.id])
        #expect(avatars.quiet == [a.id, b.id])
    }

    @Test func theAnswerAfterTheWorkIsNotNarration() {
        let a = bot("a"), b = bot("b"), earlier = bot("antes")
        let avatars = ReplyAvatars([user("0"), earlier, user("1"), a, tool(), b])
        #expect(avatars.narration == [a.id])
        #expect(avatars.quiet == [a.id])
        #expect(avatars.lastID == b.id)
    }

    @Test func aPermissionCardMakesTheWordsBeforeItNarration() {
        let a = bot("Vou apagar a pasta.")
        let card = TranscriptItem(.approval(ApprovalRequest(toolName: "run_command", title: "Apagar", command: "rm -rf build", reason: "")))
        #expect(ReplyAvatars([user("1"), a, card]).narration == [a.id])
    }

    @Test func yourMessageEndsTheWorkThatMadeWordsNarration() {
        let a = bot("a")
        // An action of an earlier request does not reach past your message to the answer of the next one.
        #expect(ReplyAvatars([user("1"), tool(), user("2"), a]).narration.isEmpty)
        #expect(ReplyAvatars([user("1"), a, user("2"), tool()]).narration.isEmpty)
    }

    @Test func aGreetingFollowedByAReplyGivesWayToIt() {
        let greeting = TranscriptItem(.greeting("Oi"))
        #expect(ReplyAvatars([greeting, bot("a")]).quiet == [greeting.id])
    }
}
