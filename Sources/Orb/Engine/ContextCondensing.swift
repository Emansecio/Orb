import Foundation

// Condensing: what the model is sent of the older stretch of a conversation once it is no longer needed in full.
// The stored messages keep everything; only the copy sent shrinks:
// - the <orb_context> preface of old user messages (folder snapshot, memory notes) is cut down to its "Now:" line,
//   except the newest snapshot and the folder changes sent after it, so the model still has the folder's state;
// - the blocks about the Orb's work outside the chat shrink to a line, and each attached file keeps its first 800
//   characters and its path (to be read again with read_file);
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
        let users = messages.indices.filter { messages[$0].isConversationRequest }
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
    /// What an old attached file keeps of its text, in characters (head only; the marker says where to read the rest).
    static let attachedFileLimit = 800
    /// What replaces the inside of an old "since the last turn" or request background block (the tags stay, so
    /// `stripped` still takes the block off where the user's words are read back).
    static let omittedBlock = "(older context omitted)"
    private static let fileOmissionMiddle = " characters omitted; the file is at "
    private static let fileOmissionEnd = ", read it again with read_file]"
    private static let fileClose = "\n</attached_file>"

    /// A user message with its preface cut down to the "Now:" line: the snapshot and the memory notes of an old
    /// message are superseded by newer ones. With `keepingSnapshot` the preface is left alone (it holds the folder's
    /// newest state). What follows the preface shrinks in any case: the blocks about the Orb's work outside the chat
    /// become a line, and each attached file keeps its head and its path. Written to stay the same under a second pass.
    static func condensed(_ content: String, keepingSnapshot: Bool, keepingChanges: Bool = false) -> String {
        var head = "", rest = Substring(content)
        if content.hasPrefix(openTag), let close = content.range(of: closeTag) {
            rest = content[close.upperBound...]
            if keepingSnapshot {
                head = String(content[..<close.upperBound])
            } else {
                let inner = content[content.index(content.startIndex, offsetBy: openTag.count)..<close.lowerBound]
                var kept: [Substring] = []
                if let now = inner.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Now:") }) { kept.append(now) }
                if keepingChanges, let start = inner.range(of: WorkspaceSnapshot.changesOpenTag),
                   let end = inner.range(of: WorkspaceSnapshot.changesCloseTag, range: start.upperBound..<inner.endIndex) {
                    kept.append(inner[start.lowerBound..<end.upperBound])
                }
                // Nothing to keep: the whole preface goes.
                if kept.isEmpty {
                    rest = rest.drop { $0.isNewline }
                } else {
                    head = openTag + "\n" + kept.joined(separator: "\n") + "\n" + closeTag
                }
            }
        }
        return head + condensedBody(rest)
    }

    /// The message after its preface: blocks about work outside the chat as a line, attached files cut.
    private static func condensedBody(_ body: Substring) -> String {
        var text = String(body)
        // The blocks sit at the start, in this order (see `stripped`).
        var offset = text.startIndex
        for (open, close) in [(SinceLastTurn.openTag, SinceLastTurn.closeTag), SinceLastTurn.legacyTags,
                              (RequestBackground.openTag, RequestBackground.closeTag),
                              (RoutineBackground.openTag, RoutineBackground.closeTag)] {
            let after = text[offset...].drop { $0.isNewline }
            guard after.hasPrefix(open), let end = text.range(of: close, range: after.startIndex..<text.endIndex) else { continue }
            let innerStart = text.index(after.startIndex, offsetBy: open.count)
            let short = "\n" + omittedBlock + "\n"
            if text[innerStart..<end.lowerBound] != short { text.replaceSubrange(innerStart..<end.lowerBound, with: short) }
            guard let closed = text.range(of: close, range: innerStart..<text.endIndex) else { break }
            offset = closed.upperBound
        }
        guard text.contains(AttachmentText.contentsMarker) else { return text }
        return condensedFiles(text)
    }

    private static func condensedFiles(_ text: String) -> String {
        var output = "", position = text.startIndex
        let opener = AttachmentText.contentsMarker + "path=\""
        while let start = text.range(of: opener, range: position..<text.endIndex) {
            // The opening line ends at its first newline; the body at the last closing tag before the next file.
            guard let lineEnd = text.range(of: "\n", range: start.upperBound..<text.endIndex) else { break }
            let nextFile = text.range(of: opener, range: lineEnd.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
            guard let close = text.range(of: fileClose, options: .backwards, range: lineEnd.upperBound..<nextFile) else { break }
            let opening = text[start.upperBound..<lineEnd.lowerBound]
            let pathEnd = [opening.range(of: "\" kind="), opening.range(of: "\">")].compactMap { $0 }
                .min { $0.lowerBound < $1.lowerBound }?.lowerBound ?? opening.endIndex
            let path = String(opening[..<pathEnd])
            let body = text[lineEnd.upperBound..<close.lowerBound]
            output += text[position..<lineEnd.upperBound]
            let alreadyCut = body.hasSuffix(fileOmissionEnd) && body.contains(fileOmissionMiddle)
            if alreadyCut || body.count <= attachedFileLimit + 200 {
                output += body
            } else {
                output += body.prefix(attachedFileLimit) + "\n[… \(body.count - attachedFileLimit)" + fileOmissionMiddle + path + fileOmissionEnd
            }
            position = close.lowerBound
        }
        return output + text[position...]
    }
}
