import Foundation
@testable import Orb

extension Store {
    func saveGroupSideConversation(_ conversation: Conversation, group groupID: UUID, for botID: UUID,
                                   then done: (@Sendable (Bool) -> Void)? = nil) {
        saveSideConversation(conversation, prefix: Self.grupoPrefix, id: groupID, for: botID, then: done)
    }

    func readGroupSideConversation(group groupID: UUID, for botID: UUID) -> StoreRead<Conversation> {
        readSideConversation(prefix: Self.grupoPrefix, id: groupID, for: botID)
    }
}
