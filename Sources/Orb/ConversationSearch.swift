import Foundation

// Search inside the open conversation (⌘F in a chat). This file is the pure part: it reads the conversation's stored
// items (what each message says, plus the title line of a tool) and nothing else, so it never draws, parses or lays
// out a row. Finding is a pass over text, case and accent insensitive ("acao" finds "ação"), that runs off the main
// actor and gives up as soon as its task is cancelled. What it returns is a short list of hits (which item, which
// match in it, a snippet to show); only the row of the hit that is chosen is brought to the screen, by the list that
// already draws rows lazily. The controller that drives it is `ConversationFind`.

// MARK: - Folding

/// Turns text into the units two strings are compared by: letters lowercased, accents and other combining marks
/// dropped ("Ação" becomes "acao"), every run of white space (a line break included) one space, curly quotes straight.
/// One scalar at a time, so a match can be mapped back to where it was in the original text.
struct ScalarFolder {
    /// What one scalar becomes: nothing (a combining mark), one unit (almost always) or a few ("ß").
    struct Folded {
        private(set) var count = 0
        private var u0: UInt32 = 0, u1: UInt32 = 0, u2: UInt32 = 0, u3: UInt32 = 0

        init() {}

        init(_ unit: UInt32) {
            count = 1
            u0 = unit
        }

        mutating func append(_ unit: UInt32) {
            switch count {
            case 0: u0 = unit
            case 1: u1 = unit
            case 2: u2 = unit
            case 3: u3 = unit
            default: return
            }
            count += 1
        }

        func unit(at index: Int) -> UInt32 {
            switch index {
            case 0: u0
            case 1: u1
            case 2: u2
            default: u3
            }
        }
    }

    static let space: UInt32 = 0x20
    /// Letters outside ASCII are folded through Unicode once each and kept here for the rest of the search.
    private var cache: [UInt32: Folded] = [:]

    init() {}

    mutating func fold(_ scalar: Unicode.Scalar) -> Folded {
        let value = scalar.value
        if value < 0x80 {
            switch value {
            case 0x41...0x5A: return Folded(value + 0x20)
            case 0x09...0x0D, 0x20: return Folded(Self.space)
            default: return Folded(value)
            }
        }
        if let hit = cache[value] { return hit }
        let folded = Self.foldNonASCII(scalar)
        cache[value] = folded
        return folded
    }

    /// The units of a whole text (used for the query).
    mutating func units(of text: String) -> [UInt32] {
        var units: [UInt32] = []
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            let folded = fold(scalar)
            for index in 0..<folded.count {
                let unit = folded.unit(at: index)
                if unit == Self.space {
                    if lastWasSpace { continue }
                    lastWasSpace = true
                } else {
                    lastWasSpace = false
                }
                units.append(unit)
            }
        }
        return units
    }

    private static func foldNonASCII(_ scalar: Unicode.Scalar) -> Folded {
        let properties = scalar.properties
        if properties.isWhitespace { return Folded(space) }
        switch properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return Folded()
        default: break
        }
        switch scalar.value {
        case 0x2018, 0x2019: return Folded(0x27) // ‘ ’
        case 0x201C, 0x201D: return Folded(0x22) // “ ”
        default: break
        }
        var result = Folded()
        let lower = properties.lowercaseMapping
        for part in lower.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch part.properties.generalCategory {
            case .nonspacingMark, .enclosingMark: continue
            default: result.append(part.value)
            }
        }
        return result
    }
}

// MARK: - Matching

/// What is searched for: the query folded, with the table the matcher needs.
struct SearchPattern: Sendable, Equatable {
    let units: [UInt32]
    /// Knuth–Morris–Pratt: where to fall back to after a mismatch.
    fileprivate let fallback: [Int]

    /// nil for a query with nothing to look for (empty, or only spaces and marks).
    init?(_ query: String) {
        var folder = ScalarFolder()
        let units = folder.units(of: query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !units.isEmpty else { return nil }
        var fallback = [Int](repeating: 0, count: units.count)
        var length = 0
        for index in 1..<max(units.count, 1) {
            while length > 0, units[index] != units[length] { length = fallback[length - 1] }
            if units[index] == units[length] { length += 1 }
            fallback[index] = length
        }
        self.units = units
        self.fallback = fallback
    }
}

/// Finds a pattern in text in one pass over its scalars, without building a folded copy of the text. The ranges it
/// returns are in the original text (the type of its indexes, so the same code finds in a `String` and in the
/// `AttributedString` a row is drawn from), do not overlap, and leave out nothing a combining mark belongs to.
struct TextSearcher {
    let pattern: SearchPattern
    private var folder = ScalarFolder()

    init(_ pattern: SearchPattern) {
        self.pattern = pattern
    }

    mutating func matches<Scalars: Collection>(in scalars: Scalars, limit: Int = .max) -> [Range<Scalars.Index>]
    where Scalars.Element == Unicode.Scalar {
        let units = pattern.units, fallback = pattern.fallback
        let length = units.count
        var found: [Range<Scalars.Index>] = []
        guard length > 0, limit > 0 else { return found }
        // Where each of the last `length` units began: the oldest is the start of a match that has just completed.
        var starts = [Scalars.Index](repeating: scalars.startIndex, count: length)
        var head = 0
        var state = 0
        var lastWasSpace = false
        var index = scalars.startIndex
        while index != scalars.endIndex {
            let next = scalars.index(after: index)
            let folded = folder.fold(scalars[index])
            if folded.count == 0, let last = found.last, last.upperBound == index {
                found[found.count - 1] = last.lowerBound..<next // a mark on the last letter of the match belongs to it
            }
            for position in 0..<folded.count {
                let unit = folded.unit(at: position)
                if unit == ScalarFolder.space {
                    if lastWasSpace { continue }
                    lastWasSpace = true
                } else {
                    lastWasSpace = false
                }
                starts[head] = index
                head += 1
                if head == length { head = 0 }
                while state > 0, units[state] != unit { state = fallback[state - 1] }
                if units[state] == unit { state += 1 }
                if state == length {
                    found.append(starts[head]..<next)
                    if found.count >= limit { return found }
                    state = 0
                }
            }
            index = next
        }
        return found
    }
}

// MARK: - The conversation

enum ConversationSearch {
    /// Where a hit was said, for the label of a result.
    enum Source: Sendable, Equatable {
        case user, bot, greeting, notice, tool
        /// A line of an exchange between Orbs or of an event (MultiOrb).
        case exchange
    }

    /// A match with a little of what surrounds it, to read in the list of results.
    struct Snippet: Sendable, Equatable {
        var before: String
        var match: String
        var after: String

        var text: String { before + match + after }
    }

    struct Hit: Identifiable, Sendable, Equatable {
        /// The place in the results (hits come in the order of the conversation, the oldest first).
        let id: Int
        let itemID: UUID
        /// The position of the item in the conversation when it was searched.
        let itemIndex: Int
        /// Which match of the item this is (0 for its first).
        let occurrence: Int
        let source: Source
        let snippet: Snippet
        /// Where the match begins in the item's text, 0 (start) to 1 (end); the list scrolls so the match, not the top of
        /// a long message, comes into view.
        let position: Double
        /// How long the item's searched text is, in UTF-8 bytes.
        let length: Int
    }

    struct Results: Sendable, Equatable {
        /// The query as searched (trimmed).
        var query: String
        var hits: [Hit]
        /// There were more matches than `ConversationSearch.maxHits`: the later ones were not collected.
        var isTruncated: Bool
        /// Items whose text was looked at.
        var itemsScanned: Int
    }

    /// More hits than this are not collected (the count says "1000+"): a one-letter query in a long conversation would
    /// otherwise build a list nobody reads.
    static let maxHits = 1_000

    /// The text of an item that is searched, and where it comes from. Tool outputs are not: a line of a tool is its title
    /// and detail, which is all its row shows. A reply still being written is not either: its text is not stable, and the
    /// item holds only how it began.
    static func searchable(_ item: TranscriptItem) -> (source: Source, text: String)? {
        switch item.kind {
        case .user(let text, _): return text.isEmpty ? nil : (.user, text)
        case .bot(let text, let isStreaming): return isStreaming || text.isEmpty ? nil : (.bot, text)
        case .greeting(let text): return (.greeting, text)
        case .notice(let text): return (.notice, text)
        case .tool(let call): return (.tool, call.title + "  " + call.detail.prefix(400))
        case .approval: return nil
        // MARK: MultiOrb (WP2): the lines between Orbs are searched as the text they read
        case .event(let event): return (event.kind == .routineRun ? .notice : .exchange, event.sentence)
        case .orbMessage(let message):
            let line = ExchangeWords.line(for: message)
            return (.exchange, message.text.isEmpty ? line : line + ": " + message.text)
        case .groupPause: return nil
        case .browserView: return nil
        }
    }

    /// Looks for `query` in the items' text. Runs on the global executor, never on the main actor, and throws
    /// `CancellationError` soon after its task is cancelled (a newer query replaces an older one).
    /// - Parameter probe: called once, from the thread doing the work, if the search was not cancelled before it began (tests
    ///   check it is not the main one, and how many searches ran).
    @concurrent
    static func search(_ query: String, in items: [TranscriptItem], maxHits: Int = ConversationSearch.maxHits,
                       probe: (@Sendable () -> Void)? = nil) async throws -> Results {
        try Task.checkCancellation()
        probe?()
        return try scan(query, in: items, maxHits: maxHits) { try Task.checkCancellation() }
    }

    /// The same, in the caller's thread. `checkpoint` is called before each item and may throw to stop.
    static func scan(_ query: String, in items: [TranscriptItem], maxHits: Int = ConversationSearch.maxHits,
                     checkpoint: () throws -> Void = {}) throws -> Results {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pattern = SearchPattern(trimmed) else {
            return Results(query: trimmed, hits: [], isTruncated: false, itemsScanned: 0)
        }
        var searcher = TextSearcher(pattern)
        var hits: [Hit] = []
        var scanned = 0
        var truncated = false
        for (index, item) in items.enumerated() {
            try checkpoint()
            // The action that sent a message between Orbs has no row (the message's card says it): no hit to scroll to.
            guard let (source, text) = searchable(item), text.utf8.count >= pattern.units.count,
                  !TranscriptFolding.sendsMessage(items, at: index) else { continue }
            scanned += 1
            let room = maxHits - hits.count
            let ranges = searcher.matches(in: text.unicodeScalars, limit: room + 1)
            for (occurrence, range) in ranges.prefix(room).enumerated() {
                let offset = text.utf8.distance(from: text.startIndex, to: range.lowerBound)
                hits.append(Hit(id: hits.count, itemID: item.id, itemIndex: index, occurrence: occurrence, source: source,
                                snippet: snippet(in: text, match: range),
                                position: Double(offset) / Double(max(text.utf8.count, 1)), length: text.utf8.count))
            }
            if ranges.count > room {
                truncated = true
                break
            }
        }
        return Results(query: trimmed, hits: hits, isTruncated: truncated, itemsScanned: scanned)
    }

    // MARK: Snippets

    static let contextBefore = 36
    static let contextAfter = 72

    /// The match with some words before and after it, on one line ("…trecho com a palavra destacada…").
    static func snippet(in text: String, match: Range<String.Index>) -> Snippet {
        var from = text.index(match.lowerBound, offsetBy: -contextBefore, limitedBy: text.startIndex) ?? text.startIndex
        var to = text.index(match.upperBound, offsetBy: contextAfter, limitedBy: text.endIndex) ?? text.endIndex
        // Whole words at the cut: step in to the next space, unless that would leave nothing of the context.
        if from > text.startIndex,
           let space = text[from..<match.lowerBound].firstIndex(where: \.isWhitespace),
           text.index(after: space) < match.lowerBound {
            from = text.index(after: space)
        }
        if to < text.endIndex,
           let space = text[match.upperBound..<to].lastIndex(where: \.isWhitespace),
           space > match.upperBound {
            to = space
        }
        let before = (from > text.startIndex ? "…" : "") + flatten(text[from..<match.lowerBound], trimmingMarks: true)
        let after = flatten(text[match.upperBound..<to], trimmingMarks: true) + (to < text.endIndex ? "…" : "")
        return Snippet(before: before, match: flatten(text[match], trimmingMarks: false), after: after)
    }

    /// One line: runs of white space (line breaks included) become one space; the Markdown emphasis and code marks, which
    /// only add noise to a line of context, are left out (not from the match itself).
    static func flatten(_ text: Substring, trimmingMarks: Bool) -> String {
        var result = ""
        var lastWasSpace = false
        for character in text {
            if character.isWhitespace {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
                continue
            }
            lastWasSpace = false
            if trimmingMarks, character == "*" || character == "`" { continue }
            result.append(character)
        }
        return result
    }
}

// MARK: - Where the results are

/// The result in view, and the walk through the others: next and previous wrap around.
struct FindCursor: Equatable, Sendable {
    private(set) var count = 0
    private(set) var index: Int?

    init() {}

    init(count: Int, index: Int? = nil) {
        self.count = count
        self.index = index.flatMap { (0..<count).contains($0) ? $0 : nil }
    }

    mutating func reset(count: Int, selecting index: Int?) {
        self = FindCursor(count: count, index: index)
    }

    /// The next result (the first one after the last). Nothing when there are none; the first when none was chosen.
    @discardableResult
    mutating func next() -> Int? {
        guard count > 0 else { return nil }
        index = index.map { ($0 + 1) % count } ?? 0
        return index
    }

    /// The previous result (the last one before the first). The last when none was chosen.
    @discardableResult
    mutating func previous() -> Int? {
        guard count > 0 else { return nil }
        index = index.map { ($0 - 1 + count) % count } ?? count - 1
        return index
    }

    mutating func select(_ index: Int) {
        guard (0..<count).contains(index) else { return }
        self.index = index
    }

    /// The first search of a query starts at the newest match: the chat is at its end, and "↑" goes back in time.
    static func initialIndex(count: Int) -> Int? { count > 0 ? count - 1 : nil }

    /// After the conversation changed under a search (a reply finished, a message arrived): the same match again, or the one
    /// that was nearest to it, so the selection does not jump.
    static func index(keeping old: ConversationSearch.Hit?, in hits: [ConversationSearch.Hit]) -> Int? {
        guard !hits.isEmpty else { return nil }
        guard let old else { return hits.count - 1 }
        if let same = hits.firstIndex(where: { $0.itemID == old.itemID && $0.occurrence == old.occurrence }) { return same }
        if let sameItem = hits.firstIndex(where: { $0.itemID == old.itemID }) { return sameItem }
        // The item is gone: the first hit at or after its place, or the last one.
        return hits.firstIndex { $0.itemIndex >= old.itemIndex } ?? hits.count - 1
    }
}

extension ConversationSearch.Results {
    /// "3 de 12" (the count is a floor when the results were cut: "3 de 1000+").
    func positionLabel(index: Int) -> String {
        "\(index + 1) de \(hits.count)\(isTruncated ? "+" : "")"
    }

    /// What VoiceOver says: "3 de 12 resultados".
    func spokenLabel(index: Int) -> String {
        hits.count == 1 && !isTruncated ? "1 de 1 resultado" : positionLabel(index: index) + " resultados"
    }
}

// MARK: - Showing the hit

/// How a found message is brought to the screen: where in the viewport the scroll puts the match.
enum FindScroll {
    /// A short message is centered a little above the middle (the find bar is at the top); in a long one the match itself
    /// is what is aligned, at its own place in the message, so it is on screen however tall the message is.
    static func anchorY(position: Double, length: Int) -> Double {
        guard length > longMessage else { return 0.4 }
        return min(max(position, 0.15), 0.85)
    }

    /// UTF-8 bytes from which a message counts as long.
    static let longMessage = 1_200
}
