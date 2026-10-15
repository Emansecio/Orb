import Foundation

/// The name two spellings of one file share, to key the gate, the writer queues and the seals. It is worked out from the
/// text of the path alone (`.` and `..`, and the `/private` of `/private/var`, `/private/tmp` and `/private/etc`):
/// `URL.standardizedFileURL` also looks at the disk, so a file that did not exist yet and one just created got two
/// names, and a write registered under the first was never found finished under the second (a read waited forever).
enum FileKey {
    static func of(_ url: URL) -> String {
        var parts: [Substring] = []
        for part in url.path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        if parts.count > 1, parts[0] == "private", ["var", "tmp", "etc"].contains(parts[1]) { parts.removeFirst() }
        return "/" + parts.joined(separator: "/")
    }
}

// How the Store lets reads and writes share the disk without a read ever waiting behind an unrelated (large) write,
// and without a read ever seeing anything but a whole file.

/// Per-file coordination between the Store's writer (one serial queue) and its readers (any thread).
///
/// - A write is registered when it is *queued* (`willWrite`) and released when it has *finished* (`didWrite`). A read
///   of a file waits for the writes still queued for that same file, so it sees the last thing saved, never an older
///   copy (an Orb whose conversation was unloaded right after a save is read back whole). Writes queued for other
///   files are not waited for.
/// - Files are replaced atomically, so a read that overlaps a write sees the old file or the new one, never half
///   of either. What a reader does to a file it cannot decode (set it aside, or refuse writes to it) must not race
///   with a writer, so reads of one file run one at a time and a write waits for a read of its file in progress.
///
/// The set of files that must never be written (they could not be read nor set aside) lives here too, since both
/// sides look at it.
final class FileGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var queued: [String: Int] = [:]
    private var reading: Set<String> = []
    private var blocked: Set<String> = []

    private static func key(_ url: URL) -> String { FileKey.of(url) }

    /// How long a read may wait before the gate logs what it is waiting for.
    static let slowWait: TimeInterval = 3

    /// How many writes registered under a path that contains `fragment` are not over (for tests: none should stay behind).
    func queuedWrites(containing fragment: String) -> Int {
        condition.withLock { queued.filter { $0.key.contains(fragment) }.values.reduce(0, +) }
    }

    func isBlocked(_ url: URL) -> Bool {
        condition.withLock { blocked.contains(Self.key(url)) }
    }

    func block(_ url: URL) {
        condition.withLock { _ = blocked.insert(Self.key(url)) }
    }

    /// Called when a write is queued (on the caller's thread, before the writer has seen it).
    func willWrite(_ urls: [URL]) {
        condition.withLock { for url in urls { queued[Self.key(url), default: 0] += 1 } }
    }

    /// Called by the writer when the queued write is over, whatever came of it.
    func didWrite(_ urls: [URL]) {
        condition.withLock {
            for url in urls {
                let key = Self.key(url)
                let left = (queued[key] ?? 1) - 1
                queued[key] = left > 0 ? left : nil
            }
            condition.broadcast()
        }
    }

    /// Runs `body` (a read of `url`) once nothing is queued for the file and no other read of it is running.
    func reading<T>(_ url: URL, _ body: () -> T) -> T { reading([url], body) }

    /// The same for a read of several files at once: it starts when none of them has a write queued or a read in
    /// progress, and takes them all together (so it cannot wait on one while holding another).
    func reading<T>(_ urls: [URL], _ body: () -> T) -> T {
        let keys = urls.map(Self.key)
        condition.lock()
        var reported = false
        while keys.contains(where: { queued[$0] != nil || reading.contains($0) }) {
            // Never expected to take long. If it does, the state is logged once, so a stuck read leaves a trace.
            if !condition.wait(until: .now.addingTimeInterval(Self.slowWait)), !reported {
                reported = true
                NSLog("Orb: leitura esperando há mais de %.0f s por %@; escritas na fila: %@; leituras em andamento: %@",
                      Self.slowWait, keys.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "),
                      "\(queued.map { ($0.key as NSString).lastPathComponent + ":" + String($0.value) })",
                      "\(reading.map { ($0 as NSString).lastPathComponent })")
            }
        }
        reading.formUnion(keys)
        condition.unlock()
        defer {
            condition.withLock {
                reading.subtract(keys)
                condition.broadcast()
            }
        }
        return body()
    }

    /// The writer calls this just before it touches `url`: a read of that file in progress finishes first.
    func waitForReaders(of url: URL) {
        let key = Self.key(url)
        condition.lock()
        while reading.contains(key) { condition.wait() }
        condition.unlock()
    }
}

/// What a file looked like at a moment: enough to tell whether it is still the one a note was made about.
struct FileFingerprint: Codable, Sendable, Equatable {
    var size: Int
    var seconds: Int
    var nanoseconds: Int

    /// nil when the file does not exist.
    init?(of url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        size = Int(info.st_size)
        seconds = Int(info.st_mtimespec.tv_sec)
        nanoseconds = Int(info.st_mtimespec.tv_nsec)
    }
}

/// What the app needs to know about an Orb's conversation without reading it: whether anything in it still has to be
/// saved to the Orb's memory. Written beside the conversation file (`<id>.meta.json`) every time the Store writes
/// the conversation, and valid only while the conversation file is exactly the one it describes (`file`): a file
/// that was changed since, by an older version of the app or by hand, makes the note useless and the conversation is
/// read instead. So a note can be stale, never wrong.
struct ConversationMeta: Codable, Sendable, Equatable {
    var itemCount: Int
    var memorySavedCount: Int
    var lastItemDate: Date?
    /// The conversation file this describes (nil: there is none, so the conversation is empty).
    var file: FileFingerprint?

    /// Items added since the last stretch was saved to memory.
    var hasUnsavedStretch: Bool { itemCount > memorySavedCount }

    /// Whether the conversation in memory is what this note describes (the file holds at least this much of it).
    func matches(_ conversation: Conversation) -> Bool {
        itemCount == conversation.items.count && memorySavedCount == (conversation.memorySavedCount ?? 0)
            && lastItemDate == conversation.items.last?.date
    }

    /// An Orb that never said anything: no file.
    static let empty = ConversationMeta(itemCount: 0, memorySavedCount: 0, lastItemDate: nil, file: nil)
}

extension ConversationMeta {
    init(of conversation: Conversation, file: FileFingerprint?) {
        self.init(itemCount: conversation.items.count, memorySavedCount: conversation.memorySavedCount ?? 0,
                  lastItemDate: conversation.items.last?.date, file: file)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemCount = try c.decode(Int.self, forKey: .itemCount)
        memorySavedCount = try c.decode(Int.self, forKey: .memorySavedCount)
        lastItemDate = try c.decodeIfPresent(Date.self, forKey: .lastItemDate)
        file = try c.decodeIfPresent(FileFingerprint.self, forKey: .file)
    }
}
