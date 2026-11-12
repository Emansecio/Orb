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
final class OrbTranscript: WritesOnlyChanges {
    /// The user's chat. The reply still being streamed is in it as it was when it began; its text is a `LiveText`.
    /// Its readers are told of every new array, without comparing it with the last one element by element (as a stored
    /// property of an observable class would, at the length of the chat for each action of the Orb): `show` only takes
    /// an array that is not the one shown, so it all but always differs.
    var items: [TranscriptItem] {
        access(keyPath: \.items)
        return storedItems
    }
    @ObservationIgnored private var storedItems: [TranscriptItem]
    /// Counts the changes of `items`, for a list that has to follow them.
    private(set) var revision = 0
    /// Counts the times the whole chat was replaced by another conversation (a new one, one reopened): the chat cross-fades
    /// then, whatever the length of what it shows, instead of guessing from the shape of the list.
    private(set) var swaps = 0
    // MARK: MultiOrb (WP2)
    /// The chat folded into rows (exchanges between Orbs, repeated events, `TranscriptFolding`); nil when it holds neither, and
    /// then its rows are its items. Made once per change of `items`, not per view pass; told without comparing, like `items`.
    var rows: [TranscriptRowModel]? {
        access(keyPath: \.rows)
        return storedRows
    }
    @ObservationIgnored private var storedRows: [TranscriptRowModel]?
    // MARK: end MultiOrb (WP2)
    /// What a compaction folded at the top of the chat (`CompactedFold`), and how many of `rows` hold only those items.
    private(set) var fold = CompactedFold.none
    private(set) var foldedRows = 0
    /// The rows a time separator goes above (`TimeSeparators`), by row id, with the time each shows.
    private(set) var timeBreaks: [UUID: Date] = [:]
    /// The replies that carry an avatar (`ReplyAvatars`) and the reply "Refazer" belongs to while the Orb is idle
    /// (`RewindRows.redoTarget`): one walk of the chat per change of its items, not one per pass of the list's body (which also
    /// runs when a scroll begins or ends, a search moves, a run of actions opens).
    private(set) var avatars = ReplyAvatars([])
    private(set) var redoCandidate: UUID?
    /// When each work row's answer came and what it used (`TranscriptFolding.workAnswers`), by row id.
    private(set) var workAnswers: [UUID: WorkAnswer] = [:]
    /// The task plan while some step of it is open (`Conversation.activePlan`), for the line at the end of the chat.
    private(set) var plan: TaskPlan?

    /// Shows `plan`; the same plan again changes nothing, so the line is not redrawn for every message of the turn.
    func showPlan(_ plan: TaskPlan?) {
        assign(\.plan, to: plan)
    }

    /// Each message of the reader, for the rail beside the chat (`RequestRail`).
    private(set) var requests: [RequestMark] = []
    /// What each turn read and changed (`TurnTrail`), by the row it goes under.
    private(set) var trails: [UUID: TurnTrail] = [:]

    /// The last item on show when the reader left, and whether what came after it is marked as new.
    @ObservationIgnored private var seenLast: UUID?
    @ObservationIgnored private var marksNew = false
    /// Left and not back yet: a second "left" (the app went to the back, then a notification changed the Orb) is the same absence.
    @ObservationIgnored private var isAway = false
    /// The row the "Novas" line goes above (`NewItemsLine`): the first one that arrived while the reader was away.
    private(set) var newFrom: UUID?

    /// The reader stopped looking at this chat. A mark from an earlier visit goes: that was read.
    func readerLeft() {
        guard !isAway else { return }
        isAway = true
        // A reply still being written counts as unseen: it is what the reader comes back for.
        seenLast = storedItems.last { item in if case .bot(_, true) = item.kind { false } else { true } }?.id
        marksNew = false
        assign(\.newFrom, to: nil)
    }

    /// The reader came back, with `unread` turns finished while away. Marked here or, when the conversation is still being
    /// read from disk, as soon as it arrives.
    func readerReturned(unread: Int) {
        isAway = false
        guard unread > 0, seenLast != nil else { return }
        marksNew = true
        markNew()
    }

    private func markNew() {
        guard marksNew else { return }
        let first = NewItems.first(after: seenLast, in: storedItems)
        let row = first.flatMap { id in storedRows?.first { $0.items.contains { $0.id == id } }?.id ?? id }
        assign(\.newFrom, to: row)
    }

    /// The chat is now another conversation (call before `show`).
    func swapped() {
        swaps &+= 1
        seenLast = nil
        isAway = false
        marksNew = false
        assign(\.newFrom, to: nil)
    }

    /// A request runs in this chat: its activity block keeps the current words and pending cards visible until it ends.
    private(set) var isLive = false

    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        refold()
    }

    init(items: [TranscriptItem] = []) {
        storedItems = items
        refold()
    }

    /// Shows `items`. The same array again (one conversation mutation that left the items alone) changes nothing.
    func show(_ items: [TranscriptItem]) {
        guard !storedItems.isSameStorage(as: items) else { return }
        withMutation(keyPath: \.items) { storedItems = items }
        refold()
        revision &+= 1
    }

    /// Whether the item is one of those the compaction folded.
    func folds(_ itemID: UUID) -> Bool {
        items[..<fold.count].contains { $0.id == itemID }
    }

    /// The rows and what a compaction folded, from the items: the rows end where the fold does, so none is half in it.
    private func refold() {
        let items = storedItems
        let fold = CompactedFold.of(items)
        let rows = TranscriptFolding.foldedRows(items, boundary: fold.count, liveTail: isLive)
        withMutation(keyPath: \.rows) { storedRows = rows }
        assign(\.fold, to: fold)
        let breaks = TimeSeparators.breaks(spans: rows.map { $0.map { ($0.id, $0.span.start, $0.span.end) } }
                                           ?? items.map { ($0.id, $0.date, $0.date) })
        assign(\.timeBreaks, to: breaks)
        let avatars = ReplyAvatars(items)
        assign(\.avatars, to: avatars)
        assign(\.workAnswers, to: rows.map(TranscriptFolding.workAnswers) ?? [:])
        let redo = RewindRows.redoTarget(in: items, isWorking: false)
        assign(\.redoCandidate, to: redo)
        markNew()
        let marks = RequestMark.of(items)
        assign(\.requests, to: marks)
        var trails = TurnTrail.of(items, isLive: isLive)
        if let rows, !trails.isEmpty {
            for row in rows {
                for item in row.items where item.id != row.id {
                    if let trail = trails.removeValue(forKey: item.id) { trails[row.id] = trail }
                }
            }
        }
        assign(\.trails, to: trails)
        guard let rows, fold.count > 0 else {
            assign(\.foldedRows, to: 0)
            return
        }
        let folded = Set(items[..<fold.count].lazy.map(\.id))
        let count = rows.prefix { row in row.items.allSatisfy { folded.contains($0.id) } }.count
        assign(\.foldedRows, to: count)
    }
}

/// A message of the reader on the rail beside the chat.
struct RequestMark: Equatable, Identifiable {
    let id: UUID
    let title: String

    static func of(_ items: [TranscriptItem]) -> [RequestMark] {
        items.compactMap { item in
            guard case .user(let text, _) = item.kind else { return nil }
            // Bounded by the title, not by the text: this runs per change of the items, and a message can be a pasted file.
            let line = text.drop(while: \.isNewline).prefix(160).prefix { !$0.isNewline }
            return RequestMark(id: item.id, title: line.isEmpty ? "Mensagem" : String(line))
        }
    }

    /// At most `limit` of them, evenly over the chat, with the first and the last: a rail longer than the window helps nobody.
    static func thinned(_ marks: [RequestMark], limit: Int) -> [RequestMark] {
        guard marks.count > limit, limit > 1 else { return marks }
        return (0..<limit).map { marks[$0 * (marks.count - 1) / (limit - 1)] }
    }
}

/// What one turn read and changed, read from its tool calls: nothing is asked of the model and the tools' results stay as they
/// were. It goes under the last reply of the turn.
struct TurnTrail: Equatable {
    enum Change: Equatable {
        case routine(String)
        case memory(String)
        case group(String)
    }

    /// Pages read, once each, in the order they were read.
    var sources: [String] = []
    var changes: [Change] = []

    var isEmpty: Bool { sources.isEmpty && changes.isEmpty }

    /// With `isLive`, the last turn has no trail yet: a word said along the way is not its reply.
    static func of(_ items: [TranscriptItem], isLive: Bool = false) -> [UUID: TurnTrail] {
        var trails: [UUID: TurnTrail] = [:]
        var trail = TurnTrail()
        var reply: UUID?
        func close() {
            if let reply, !trail.isEmpty { trails[reply] = trail }
            trail = TurnTrail()
            reply = nil
        }
        for item in items {
            switch item.kind {
            case .user: close()
            case .bot(_, let isStreaming): reply = isStreaming ? nil : item.id
            case .tool(let call): trail.note(call)
            default: break
            }
        }
        if !isLive { close() }
        return trails
    }

    private mutating func note(_ call: ToolCall) {
        guard call.state == .done else { return }
        let detail = call.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        switch call.title {
        case "Lendo página":
            if let host = Self.host(of: detail), !host.isEmpty, !sources.contains(detail) { sources.append(detail) }
        case "Agendando tarefa":
            if let name = detail.split(separator: "”").first?.dropFirst(), detail.hasPrefix("“") { changes.append(.routine(String(name))) }
        case "Criando um grupo":
            changes.append(.group(detail))
        case let title where title.hasPrefix("Guardando na memória"):
            changes.append(.memory(String(detail.prefix(80))))
        default: break
        }
    }

    /// The host of a web address; nil for anything else, which never becomes a link.
    static func host(of address: String) -> String? {
        guard let url = URL(string: address), url.scheme == "https" || url.scheme == "http", let host = url.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Where the "Novas" line goes: above the first item after the last one the reader saw. No line when that item is gone (the
/// conversation was compacted or redone) or nothing came after it.
enum NewItems {
    static func first(after seen: UUID?, in items: [TranscriptItem]) -> UUID? {
        guard let seen, let index = items.lastIndex(where: { $0.id == seen }), index + 1 < items.count else { return nil }
        return items[index + 1].id
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
