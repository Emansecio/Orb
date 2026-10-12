import Foundation

/// After a compaction the chat folds what came before it into one line ("47 mensagens anteriores foram resumidas ·
/// Mostrar"). Only the screen changes: nothing is removed, and the line opens them again. The fold ends where the latest
/// compaction left the conversation whole for the model: at the request it was made in (the message just sent, the turn
/// under way, or the last exchange when you compacted it yourself). Read from the items alone, so a rewind past the
/// notice takes the fold with it and a conversation compacted before this existed folds too.
struct CompactedFold: Equatable, Sendable {
    /// The first items of the chat that fold.
    var count: Int
    /// Messages among them (yours, the Orb's, between Orbs): what the line counts.
    var messages: Int

    static let none = CompactedFold(count: 0, messages: 0)

    static func of(_ items: [TranscriptItem]) -> CompactedFold {
        guard let notice = items.lastIndex(where: isFoldNotice) else { return .none }
        let end = items[..<notice].lastIndex(where: startsRequest) ?? notice
        let messages = items[..<end].reduce(0) { $0 + (isMessage($1) ? 1 : 0) }
        return messages > 0 ? CompactedFold(count: end, messages: messages) : .none
    }

    private static func isFoldNotice(_ item: TranscriptItem) -> Bool {
        guard case .notice(let text) = item.kind else { return false }
        return CompactionReport.foldNoticePrefixes.contains { text.hasPrefix($0) }
    }

    /// A message of yours that started a request (one sent in the middle of a task did not).
    private static func startsRequest(_ item: TranscriptItem) -> Bool {
        if case .user = item.kind { item.duringTask != true } else { false }
    }

    private static func isMessage(_ item: TranscriptItem) -> Bool {
        switch item.kind {
        case .user, .bot, .orbMessage: true
        default: false
        }
    }

    /// "47 mensagens anteriores foram resumidas".
    var title: String {
        messages == 1 ? "1 mensagem anterior foi resumida" : "\(messages) mensagens anteriores foram resumidas"
    }
}
