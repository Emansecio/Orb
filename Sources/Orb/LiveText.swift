import Foundation
import Observation

// What the chat shows of a reply while it is being written, kept apart from the conversation: a flush of streamed
// text changes only a `LiveText`, not the list of items (see `BotSession.flushText`), and the transcript an Orb's
// chat view reads is an object of its own, so another Orb's work does not redraw it.

/// A reply split into paragraphs at blank lines, updated as text arrives. Paragraphs that are done never change,
/// so a view can keep them (and what it measured of them) while only the last one is written to.
///
/// Nothing is split inside a fenced code block (a blank line in code is not a paragraph break), and a block that
/// is never closed stays in the paragraph being written. `text` gives back exactly what was appended.
///
/// Only blank lines (`\n\n`) end a paragraph: a long list or table with no blank line between its lines is one
/// paragraph, so a flush re-reads all of it, as it did before. A line break written as CRLF does not end one either.
struct ReplyParagraphs: Equatable, Sendable {
    /// The finished paragraphs, without the blank line that ended each.
    private(set) var closed: [String] = []
    /// The paragraph being written: everything after the last blank line.
    private(set) var tail = ""

    // Where the next scan of `tail` resumes. Offsets are in UTF-8 bytes of `tail`, so appending a chunk costs the
    // size of the chunk, not of the paragraph.
    private var scanned = 0
    private var lineStart = 0
    /// Backticks of the code fence the scan is inside (0 outside one).
    private var fence = 0

    init() {}

    init(_ text: String) {
        append(text)
    }

    /// The whole reply, as it was appended.
    var text: String {
        closed.isEmpty ? tail : closed.joined(separator: "\n\n") + "\n\n" + tail
    }

    mutating func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        tail += chunk
        var position = scanned, line = lineStart, inFence = fence
        var finished: [String] = []
        var rest: String?
        var begin = 0
        tail.withUTF8 { bytes in
            while position < bytes.count {
                if bytes[position] == 0x0A {
                    // `line..<position` is a complete line. A blank line right after another line end, outside a
                    // code fence, ends the paragraph that began at `begin`.
                    Self.track(&inFence, in: UnsafeBufferPointer(rebasing: bytes[line..<position]))
                    if inFence == 0, line == position, position > begin {
                        finished.append(String(decoding: bytes[begin..<(position - 1)], as: UTF8.self))
                        begin = position + 1
                    }
                    line = position + 1
                }
                position += 1
            }
            if begin > 0 { rest = String(decoding: bytes[begin...], as: UTF8.self) }
        }
        closed += finished
        if let rest { tail = rest }
        scanned = position - begin
        lineStart = line - begin
        fence = inFence
    }

    /// Opens or closes a code fence when `line` is a fence line (three or more backticks after at most three
    /// spaces; a closing one is at least as long as the opening one and has nothing after it).
    private static func track(_ fence: inout Int, in line: UnsafeBufferPointer<UInt8>) {
        var index = 0
        while index < line.count, index < 3, line[index] == 0x20 { index += 1 }
        var ticks = 0
        while index + ticks < line.count, line[index + ticks] == 0x60 { ticks += 1 }
        guard ticks >= 3 else { return }
        let after = line[(index + ticks)...]
        if fence == 0 {
            if !after.contains(0x60) { fence = ticks } // a backtick in the rest means inline code, not a fence
        } else if ticks >= fence, after.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
            fence = 0
        }
    }
}

/// The text of the reply being streamed. Views read the finished paragraphs and the one being written separately,
/// so a flush redraws only the last paragraph and a paragraph break adds one row.
@MainActor @Observable
final class LiveText {
    /// The transcript item this text belongs to.
    let itemID: UUID
    private(set) var closed: [String]
    private(set) var tail: String
    @ObservationIgnored private var paragraphs: ReplyParagraphs

    init(itemID: UUID, text: String) {
        self.itemID = itemID
        paragraphs = ReplyParagraphs(text)
        closed = paragraphs.closed
        tail = paragraphs.tail
    }

    /// The whole reply so far.
    var text: String { paragraphs.text }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        let before = paragraphs.closed.count
        paragraphs.append(chunk)
        if paragraphs.closed.count != before { closed = paragraphs.closed }
        tail = paragraphs.tail
    }
}

/// What the chat view of one Orb shows of its conversation. An object of its own, so a view reading it is redrawn
/// only when this Orb's items change, not when any conversation does. The Orb's `BotSession` makes and feeds it.
@MainActor @Observable
final class OrbTranscript {
    /// The user's chat. The reply still being streamed is in it as it was when it began; its text is a `LiveText`.
    private(set) var items: [TranscriptItem]
    /// Counts the changes of `items`, for a list that has to follow them.
    private(set) var revision = 0
    /// Counts the times the whole chat was replaced by another conversation (a new one, one reopened): the chat cross-fades
    /// then, whatever the length of what it shows, instead of guessing from the shape of the list.
    private(set) var swaps = 0
    // MARK: MultiOrb (WP2)
    /// The chat folded into rows (exchanges between Orbs, repeated events, `TranscriptFolding`); nil when it holds neither, and
    /// then its rows are its items. Made once per change of `items`, not per view pass.
    private(set) var rows: [TranscriptRowModel]?
    // MARK: end MultiOrb (WP2)
    /// What a compaction folded at the top of the chat (`CompactedFold`), and how many of `rows` hold only those items.
    private(set) var fold = CompactedFold.none
    private(set) var foldedRows = 0
    /// The rows a time separator goes above (`TimeSeparators`), by row id, with the time each shows.
    private(set) var timeBreaks: [UUID: Date] = [:]

    /// The chat is now another conversation (call before `show`).
    func swapped() { swaps &+= 1 }

    /// A request of the Orb runs in this chat: its work stays unfolded until it ends (`TranscriptFolding.workStretches`).
    private(set) var isLive = false

    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        refold()
    }

    init(items: [TranscriptItem] = []) {
        self.items = items
        refold()
    }

    /// Shows `items`. The same array again (one conversation mutation that left the items alone) changes nothing.
    func show(_ items: [TranscriptItem]) {
        guard !self.items.isSameStorage(as: items) else { return }
        self.items = items
        refold()
        revision &+= 1
    }

    /// Whether the item is one of those the compaction folded.
    func folds(_ itemID: UUID) -> Bool {
        items[..<fold.count].contains { $0.id == itemID }
    }

    /// The rows and what a compaction folded, from the items: the rows end where the fold does, so none is half in it.
    private func refold() {
        let fold = CompactedFold.of(items)
        rows = TranscriptFolding.foldedRows(items, boundary: fold.count, liveTail: isLive)
        if fold != self.fold { self.fold = fold }
        let breaks = TimeSeparators.breaks(rows.map { $0.map { ($0.id, $0.items.map(\.date)) } } ?? items.map { ($0.id, [$0.date]) })
        if breaks != timeBreaks { timeBreaks = breaks }
        guard let rows, fold.count > 0 else {
            if foldedRows != 0 { foldedRows = 0 }
            return
        }
        let folded = Set(items[..<fold.count].lazy.map(\.id))
        let count = rows.prefix { row in row.items.allSatisfy { folded.contains($0.id) } }.count
        if count != foldedRows { foldedRows = count }
    }
}

extension Array {
    /// Whether both arrays are one buffer: an array that is not mutated in place while the other holds it, so equal
    /// storage means equal elements. A quick "did anything change" check where comparing the elements would cost
    /// the length of the array.
    func isSameStorage(as other: [Element]) -> Bool {
        count == other.count && withUnsafeBufferPointer { mine in
            other.withUnsafeBufferPointer { theirs in mine.baseAddress == theirs.baseAddress }
        }
    }
}
