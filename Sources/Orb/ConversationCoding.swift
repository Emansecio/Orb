import Foundation

// How a conversation becomes the bytes of its file: old tool outputs shortened, and, when the same file is saved
// again, only what changed since the last save encoded again.

// MARK: - Pruning

extension Conversation {
    /// Where "old" starts: items and messages before these indexes come before the second-to-last user message.
    struct PruneCutoffs: Equatable {
        var items: Int
        var messages: Int
    }

    /// The second-to-last user item and message (0 when there are fewer than two: nothing is old yet).
    var pruneCutoffs: PruneCutoffs {
        var itemSeen = 0, itemCutoff = 0
        for index in items.indices.reversed() {
            guard case .user = items[index].kind else { continue }
            itemSeen += 1
            if itemSeen == 2 { itemCutoff = index; break }
        }
        var messageSeen = 0, messageCutoff = 0
        for index in messages.indices.reversed() where messages[index].role == .user {
            messageSeen += 1
            if messageSeen == 2 { messageCutoff = index; break }
        }
        return PruneCutoffs(items: itemCutoff, messages: messageCutoff)
    }

    /// What is written to disk: tool outputs older than the second-to-last user message keep only a head and a
    /// tail (the model sees no more than that of old outputs anyway). `self` is not changed. (The Store does the
    /// same one item at a time, see `ConversationEncoder`; this is the whole-value form.)
    func pruningOldToolOutputs(limit: Int = 4_000) -> Conversation {
        var copy = self
        let cutoffs = pruneCutoffs
        for index in copy.items.indices where index < cutoffs.items {
            copy.items[index] = copy.items[index].pruningToolOutput(limit: limit)
        }
        for index in copy.messages.indices where index < cutoffs.messages {
            copy.messages[index] = copy.messages[index].pruningToolOutput(limit: limit)
        }
        return copy
    }

    /// `text` as is when it fits in `limit`, otherwise its head and tail around a marker (about `limit` in all).
    static func preview(_ text: String, limit: Int) -> String {
        guard text.utf8.count > limit, text.count > limit else { return text }
        let keep = max(0, (limit - 100) / 2)
        let omitted = text.count - 2 * keep
        return String(text.prefix(keep)) + "\n[… \(omitted) caracteres omitidos de uma saída antiga …]\n" + String(text.suffix(keep))
    }
}

extension TranscriptItem {
    /// A tool item's output is the only thing pruning touches.
    var hasToolOutput: Bool {
        if case .tool(let call) = kind { call.output != nil } else { false }
    }

    func pruningToolOutput(limit: Int) -> TranscriptItem {
        guard case .tool(var call) = kind, let output = call.output else { return self }
        let short = Conversation.preview(output, limit: limit)
        guard short != output else { return self }
        call.output = short
        var copy = self
        copy.kind = .tool(call)
        return copy
    }
}

extension ChatMessage {
    func pruningToolOutput(limit: Int) -> ChatMessage {
        guard role == .tool else { return self }
        var copy = self
        copy.content = Conversation.preview(content, limit: limit)
        return copy
    }
}

// MARK: - Incremental encoding

/// Encodes the conversation kept in one file, again and again as it grows, without redoing what did not change.
///
/// A save used to prune and encode the whole conversation (60–160 ms for 2,000 items, every few seconds while a reply
/// streams), though a save changes the last item or two. This keeps, for each item and message, the JSON it was
/// last encoded to, next to the value that JSON came from; an item is encoded again only when it is no longer equal
/// to that value (comparing is cheap: unchanged strings share their storage) or when the cut between old and recent
/// turns moved past one of its tool outputs. The pieces are joined into the file's JSON, which is the same
/// document `JSONEncoder` writes for the pruned conversation, so every version of the app reads it, and nothing
/// about the format changed. Only the writer's queue uses an encoder.
final class ConversationEncoder: @unchecked Sendable {
    private struct Entry<Value> {
        var source: Value
        /// The value has a tool output that pruning may shorten, so its JSON depends on which side of the cut it is.
        var prunable: Bool
        var pruned: Bool
        var json: Data
    }

    /// What the file the last successful write left behind holds, to recognise a save that would change nothing.
    private struct Committed {
        var shell: Data
        var itemCount: Int
        var messageCount: Int
        var fingerprint: FileFingerprint?
    }

    private var items: [Entry<TranscriptItem>] = []
    private var messages: [Entry<ChatMessage>] = []
    private let encoder = JSONEncoder()
    private let shellEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
    private var committed: Committed?
    /// The `limit` the pieces were pruned with (a different one makes them all stale).
    private var limit = 4_000
    /// Something was encoded since the last write that went through: the next write cannot be skipped.
    private var changedSinceCommit = true
    /// Bytes of JSON held (for the Store's cap on what it keeps).
    private(set) var byteCount = 0

    /// The conversation's pieces are ready; `data(for:)` joins them into the file.
    struct Output {
        /// Nothing differs from what the last successful write put in the file.
        var isUnchanged: Bool
        fileprivate var shell: Data
        fileprivate var split: Split
    }

    /// The file's bytes for `conversation`. `nil` when the conversation could not be split into pieces (never
    /// expected), in which case the caller encodes it whole.
    func encode(_ conversation: Conversation, limit: Int = 4_000) throws -> Output? {
        if limit != self.limit {
            self.limit = limit
            items = []
            messages = []
            byteCount = 0
            invalidateCommit()
        }
        var shell = conversation
        shell.items = []
        shell.messages = []
        let shellData = try shellEncoder.encode(shell)
        guard let split = Self.split(shellData) else { return nil }

        let cutoffs = conversation.pruneCutoffs
        for index in conversation.items.indices {
            let item = conversation.items[index]
            let beyondCut = index < cutoffs.items
            if index < items.count, items[index].source == item, !items[index].prunable || items[index].pruned == beyondCut {
                continue
            }
            let prunable = item.hasToolOutput
            let json = try encoder.encode(beyondCut && prunable ? item.pruningToolOutput(limit: limit) : item)
            let entry = Entry(source: item, prunable: prunable, pruned: beyondCut, json: json)
            if index < items.count {
                byteCount += json.count - items[index].json.count
                items[index] = entry
            } else {
                byteCount += json.count
                items.append(entry)
            }
            changedSinceCommit = true
        }
        if items.count > conversation.items.count {
            byteCount -= items[conversation.items.count...].reduce(0) { $0 + $1.json.count }
            items.removeSubrange(conversation.items.count...)
            changedSinceCommit = true
        }
        for index in conversation.messages.indices {
            let message = conversation.messages[index]
            let beyondCut = index < cutoffs.messages
            if index < messages.count, messages[index].source == message,
               !messages[index].prunable || messages[index].pruned == beyondCut {
                continue
            }
            let prunable = message.role == .tool
            let json = try encoder.encode(beyondCut && prunable ? message.pruningToolOutput(limit: limit) : message)
            let entry = Entry(source: message, prunable: prunable, pruned: beyondCut, json: json)
            if index < messages.count {
                byteCount += json.count - messages[index].json.count
                messages[index] = entry
            } else {
                byteCount += json.count
                messages.append(entry)
            }
            changedSinceCommit = true
        }
        if messages.count > conversation.messages.count {
            byteCount -= messages[conversation.messages.count...].reduce(0) { $0 + $1.json.count }
            messages.removeSubrange(conversation.messages.count...)
            changedSinceCommit = true
        }

        let unchanged = !changedSinceCommit && committed.map {
            $0.shell == shellData && $0.itemCount == items.count && $0.messageCount == messages.count
        } == true
        return Output(isUnchanged: unchanged, shell: shellData, split: split)
    }

    /// The file's bytes: the pieces of the last `encode`, joined.
    func data(for output: Output) -> Data {
        let split = output.split
        var data = Data()
        data.reserveCapacity(split.head.count + split.middle.count + split.tail.count + byteCount + items.count + messages.count + 4)
        data.append(split.head)
        data.append(UInt8(ascii: "["))
        for (index, entry) in items.enumerated() {
            if index > 0 { data.append(UInt8(ascii: ",")) }
            data.append(entry.json)
        }
        data.append(UInt8(ascii: "]"))
        data.append(split.middle)
        data.append(UInt8(ascii: "["))
        for (index, entry) in messages.enumerated() {
            if index > 0 { data.append(UInt8(ascii: ",")) }
            data.append(entry.json)
        }
        data.append(UInt8(ascii: "]"))
        data.append(split.tail)
        return data
    }

    /// The write of `output` went through and left the file as `fingerprint` describes it.
    func commit(_ output: Output, fingerprint: FileFingerprint?) {
        committed = Committed(shell: output.shell, itemCount: items.count, messageCount: messages.count, fingerprint: fingerprint)
        changedSinceCommit = false
    }

    /// Whether the file is still exactly as the last successful write left it (so an unchanged conversation needs
    /// no write at all).
    func fileIsAsWeLeftIt(_ url: URL) -> Bool {
        guard let committed, let fingerprint = committed.fingerprint else { return false }
        return FileFingerprint(of: url) == fingerprint
    }

    /// A write failed or the file was touched by someone else: forget what is on disk, so the next save writes.
    func invalidateCommit() {
        committed = nil
        changedSinceCommit = true
    }

    // MARK: Splitting the conversation's own fields from its two lists

    fileprivate struct Split {
        /// Everything up to and including `"items":`.
        var head: Data
        /// From after the items list to and including `"messages":`.
        var middle: Data
        /// After the messages list.
        var tail: Data
    }

    /// `{"compactions":…,"items":[],"memorySavedCount":…,"messages":[],…}` (keys sorted) cut around the two
    /// empty lists. Needs each to appear once, items first; anything else (a field added with such a name in a
    /// string value cannot match: quotes inside strings are escaped) means the shortcut is not safe.
    private static func split(_ shell: Data) -> Split? {
        let itemsKey = Data(#""items":[]"#.utf8), messagesKey = Data(#""messages":[]"#.utf8)
        guard let items = shell.range(of: itemsKey), let messages = shell.range(of: messagesKey),
              items.upperBound <= messages.lowerBound,
              shell.range(of: itemsKey, in: items.upperBound..<shell.endIndex) == nil,
              shell.range(of: messagesKey, in: messages.upperBound..<shell.endIndex) == nil else { return nil }
        let empty = 2 // the "[]" at the end of each key
        return Split(head: shell[shell.startIndex..<(items.upperBound - empty)],
                     middle: shell[items.upperBound..<(messages.upperBound - empty)],
                     tail: shell[messages.upperBound..<shell.endIndex])
    }
}
