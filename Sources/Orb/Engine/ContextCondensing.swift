import Foundation

// Condensing: what the model is sent of the older stretch of a conversation once it is no longer needed in full.
// The stored messages keep everything; only the copy sent shrinks:
// - the <orb_context> preface of old user messages (folder snapshot, memory notes) is cut down to its "Now:" line,
//   except the newest snapshot and the folder changes sent after it, so the model still has the folder's state;
// - old tool outputs keep only 800 characters (errors a bit more, and the path of a saved output always);
// - reasoning the provider returned (signatures, encrypted blobs) is no longer sent back.
//
// Changing old messages rewrites the provider's prompt cache from the first one changed, so a conversation is
// condensed in batches: `Conversation.condensedCount` remembers how far it got, and moves only when a compaction
// is happening anyway or when condensing would save enough to pay for the rewrite.

enum ContextCondensing {
    /// Old tool outputs, in characters (head and tail, plus the marker).
    static let outputLimit = 800
    /// Errors keep more: the cause is at the end and is what the model needs to avoid repeating the mistake.
    static let errorLimit = 1_200

    static func outputLimit(of message: ChatMessage) -> Int { message.isError ? errorLimit : outputLimit }

    /// Index of the message that starts the second-to-last turn: everything before it may be condensed, the last two
    /// turns stay as they were. 0 when there is nothing to condense yet.
    static func frontier(in messages: [ChatMessage]) -> Int {
        let users = messages.indices.filter { messages[$0].role == .user && !messages[$0].content.hasPrefix(ContextSummary.marker) }
        return users.count >= 2 ? users[users.count - 2] : 0
    }

    /// Index of the newest user message that carries the folder snapshot (it is kept whole when condensing).
    static func snapshotIndex(in messages: [ChatMessage]) -> Int? {
        messages.indices.last { messages[$0].role == .user && messages[$0].content.contains(WorkspaceSnapshot.openTag) }
    }

    /// Characters condensing `messages[from..<to]` would save (what they take now minus what they would take).
    static func savings(in messages: [ChatMessage], from: Int, to: Int) -> Int {
        guard from < to, to <= messages.count else { return 0 }
        let snapshot = snapshotIndex(in: messages)
        var saved = 0
        for index in from..<to {
            let message = messages[index]
            switch message.role {
            case .tool:
                saved += ContextText.preview(message.content, limit: ContextWindow.toolOutputPreview).count
                    - ContextText.preview(message.content, limit: outputLimit(of: message)).count
            case .user, .assistant:
                let kept = condensed(message, keepingSnapshot: index == snapshot,
                                     keepingChanges: snapshot.map { index > $0 } ?? false)
                saved += message.contextCharacters - kept.contextCharacters
            case .system:
                break
            }
        }
        return max(saved, 0)
    }

    /// The user message without its preface (but the time, and with `keepingChanges` the folder changes it reported:
    /// those after the newest snapshot are how the model knows the folder's current state), the assistant message
    /// without its reasoning.
    static func condensed(_ message: ChatMessage, keepingSnapshot: Bool, keepingChanges: Bool = false) -> ChatMessage {
        var copy = message
        switch message.role {
        case .user:
            copy.content = TurnPreface.condensed(message.content, keepingSnapshot: keepingSnapshot, keepingChanges: keepingChanges)
        case .assistant:
            copy.reasoning = nil
        default:
            break
        }
        return copy
    }
}

extension TurnPreface {
    /// A user message with its preface cut down to the "Now:" line: the snapshot and the memory notes of an old
    /// message are superseded by newer ones. With `keepingSnapshot` the message is left alone (it holds the folder's
    /// newest state). Written to stay the same under a second pass.
    static func condensed(_ content: String, keepingSnapshot: Bool, keepingChanges: Bool = false) -> String {
        guard !keepingSnapshot, content.hasPrefix(openTag), let close = content.range(of: closeTag) else { return content }
        let inner = content[content.index(content.startIndex, offsetBy: openTag.count)..<close.lowerBound]
        let rest = content[close.upperBound...]
        var kept: [Substring] = []
        if let now = inner.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Now:") }) { kept.append(now) }
        if keepingChanges, let start = inner.range(of: WorkspaceSnapshot.changesOpenTag),
           let end = inner.range(of: WorkspaceSnapshot.changesCloseTag, range: start.upperBound..<inner.endIndex) {
            kept.append(inner[start.lowerBound..<end.upperBound])
        }
        // Nothing to keep: the whole preface goes.
        guard !kept.isEmpty else { return String(rest.drop { $0.isNewline }) }
        return openTag + "\n" + kept.joined(separator: "\n") + "\n" + closeTag + rest
    }
}
