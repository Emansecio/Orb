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

    @Test func aChatEndingInAToolLineHasNoLiveReplyButTheRunStillShowsOneAvatar() {
        let a = bot("a"), b = bot("b")
        let avatars = ReplyAvatars([user("1"), a, tool(), b, tool()])
        #expect(avatars.lastID == nil)
        #expect(avatars.quiet == [a.id]) // b keeps the still avatar
    }

    @Test func aGreetingFollowedByAReplyGivesWayToIt() {
        let greeting = TranscriptItem(.greeting("Oi"))
        #expect(ReplyAvatars([greeting, bot("a")]).quiet == [greeting.id])
    }
}
