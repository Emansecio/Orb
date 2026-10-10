import Foundation
import Observation

/// A group's thread in memory: the conversation of the group (`.user`, `.orbMessage(post)`, `.event`, `.groupPause`) and what
/// the chat view shows of it. The shell the group runtime fills in (saving, unloading, the loop).
@MainActor
@Observable
final class GroupSession {
    let groupID: UUID
    var conversation = Conversation()
    let transcript: OrbTranscript
    private(set) var unread = 0

    init(groupID: UUID, conversation: Conversation = Conversation()) {
        self.groupID = groupID
        self.conversation = conversation
        transcript = OrbTranscript(items: conversation.items)
    }
}
