import Foundation
import Observation

// The state of the find bar of one chat (⌘F): the query, the hits, which one is chosen, and what the chat has to do about
// it (scroll to a message, mark it). The search itself is `ConversationSearch`; this runs it at the right moments: after
// a pause in typing, never twice at once (a newer query cancels the older), again when the conversation changed under it.

/// What the row of the chosen hit draws: its text marked, and, for a moment, a wash behind the whole message.
struct FindFocus: Equatable, Sendable {
    let itemID: UUID
    /// The text to mark in the row.
    let query: String
    /// Behind the message while it was just brought into view; off after `ConversationFind.flashDuration`.
    var isFlashing: Bool
}

/// A request to the chat to scroll to a message. A new `token` is a new request, even to the same message.
struct FindJump: Equatable, Sendable {
    let token: Int
    let itemID: UUID
    /// Where in the viewport the message (or the match inside a long one) goes: 0 top, 1 bottom.
    let anchorY: Double
    /// The message is close to the one the last jump went to: the list may glide to it (unless Reduce Motion is on). A
    /// far one is a cut: a glide through rows not made yet would take as long as the distance.
    let glides: Bool

    /// Items apart that still count as close.
    static let nearItems = 8
}

@MainActor @Observable
final class ConversationFind {
    /// The pause after the last keystroke before searching; a change of the conversation waits a little longer.
    static let typingDelay = Duration.milliseconds(180)
    static let refreshDelay = Duration.milliseconds(400)
    /// How long the wash stays behind the message that was jumped to (it fades in `Motion.content`).
    static let flashDuration = Duration.milliseconds(1_400)

    private(set) var isOpen = false
    var query = "" {
        didSet {
            guard query != oldValue, isOpen else { return }
            needsJump = true
            startSearch(after: delays.typing)
        }
    }
    /// The list of results is showing.
    var showsResults = false
    /// Counts the requests to put the cursor in the field (opening, ⌘F again).
    private(set) var focusRequests = 0
    private(set) var results: ConversationSearch.Results?
    private(set) var cursor = FindCursor()
    private(set) var isSearching = false
    private(set) var focus: FindFocus?
    private(set) var jump: FindJump?
    /// The chat does not follow the end of the conversation while a hit is on show: a reply that is written meanwhile
    /// must not take the view away from what was found.
    private(set) var pausesFollowing = false

    /// The stored items of the chat that is searched (not its rows).
    @ObservationIgnored var source: @MainActor () -> [TranscriptItem] = { [] }
    /// Says something to VoiceOver ("3 de 12 resultados").
    @ObservationIgnored var announce: (@MainActor (String) -> Void)?

    private struct Delays {
        var typing: Duration
        var refresh: Duration
        var flash: Duration
    }

    @ObservationIgnored private let delays: Delays
    @ObservationIgnored private let probe: (@Sendable () -> Void)?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var jumpTokens = 0
    @ObservationIgnored private var lastJumpItemIndex: Int?
    /// The next results are for a query just typed: they take the view to the chosen hit. Results for the same query
    /// after the conversation changed only update the count.
    @ObservationIgnored private var needsJump = false

    init(typingDelay: Duration = ConversationFind.typingDelay, refreshDelay: Duration = ConversationFind.refreshDelay,
         flashDuration: Duration = ConversationFind.flashDuration, probe: (@Sendable () -> Void)? = nil) {
        delays = Delays(typing: typingDelay, refresh: refreshDelay, flash: flashDuration)
        self.probe = probe
    }

    // MARK: Opening and closing

    /// ⌘F: the bar opens with the cursor in the field (and the last query selected, searched again); with the bar open,
    /// the cursor comes back to the field.
    func open() {
        focusRequests += 1
        guard !isOpen else { return }
        isOpen = true
        if SearchPattern(query) != nil {
            needsJump = true
            startSearch(after: .zero)
        }
    }

    /// Esc: the bar closes, the marks go, the chat follows the end again.
    func close() {
        guard isOpen else { return }
        isOpen = false
        showsResults = false
        searchTask?.cancel()
        flashTask?.cancel()
        searchTask = nil
        flashTask = nil
        results = nil
        cursor = FindCursor()
        isSearching = false
        focus = nil
        jump = nil
        pausesFollowing = false
        needsJump = false
        lastJumpItemIndex = nil
    }

    /// The person sent a message: the chat goes to the end, as it always does then.
    func resumeFollowing() {
        pausesFollowing = false
    }

    // MARK: Searching

    /// The conversation's items changed (a reply ended, a message arrived, the conversation was replaced).
    func itemsChanged() {
        guard isOpen, SearchPattern(query) != nil else { return }
        startSearch(after: delays.refresh)
    }

    private func startSearch(after delay: Duration) {
        searchTask?.cancel()
        guard SearchPattern(query) != nil else {
            searchTask = nil
            isSearching = false
            clearResults()
            return
        }
        isSearching = true
        let text = query, probe = probe
        searchTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            guard let self else { return }
            let items = source() // a copy of the array's reference, not of its items
            do {
                let found = try await ConversationSearch.search(text, in: items, probe: probe)
                if Task.isCancelled { return }
                apply(found)
            } catch {
                // Cancelled: a newer query is on its way (or the bar closed).
            }
        }
    }

    /// Resolves once the search that is running or waiting has ended (for tests).
    func settled() async {
        var last: Task<Void, Never>?
        while let task = searchTask, task != last {
            await task.value
            last = task
        }
    }

    private func apply(_ found: ConversationSearch.Results) {
        let previous = currentHit
        results = found
        isSearching = false
        guard !found.hits.isEmpty else {
            cursor = FindCursor()
            focus = nil
            jump = nil
            needsJump = false
            announce?("Nenhum resultado")
            return
        }
        if needsJump {
            needsJump = false
            cursor.reset(count: found.hits.count, selecting: FindCursor.initialIndex(count: found.hits.count))
            reveal(announcing: true)
        } else {
            cursor.reset(count: found.hits.count, selecting: FindCursor.index(keeping: previous, in: found.hits))
            // The same message stays marked, the new text in it too; no scroll, no wash.
            if let hit = currentHit, focus != nil {
                focus = FindFocus(itemID: hit.itemID, query: found.query, isFlashing: false)
            }
        }
    }

    private func clearResults() {
        results = nil
        cursor = FindCursor()
        focus = nil
        jump = nil
        pausesFollowing = false
        needsJump = false
        lastJumpItemIndex = nil
        flashTask?.cancel()
    }

    // MARK: Moving between hits

    var currentHit: ConversationSearch.Hit? {
        guard let results, let index = cursor.index, results.hits.indices.contains(index) else { return nil }
        return results.hits[index]
    }

    /// ↩, ↓ or ⌘G.
    func next() {
        guard cursor.next() != nil else { return }
        reveal(announcing: true)
    }

    /// ⇧↩, ↑ or ⇧⌘G.
    func previous() {
        guard cursor.previous() != nil else { return }
        reveal(announcing: true)
    }

    /// A row of the list of results was chosen.
    func choose(_ index: Int) {
        cursor.select(index)
        guard cursor.index == index else { return }
        reveal(announcing: true)
    }

    /// Takes the chat to the chosen hit.
    private func reveal(announcing: Bool) {
        guard let results, let hit = currentHit else { return }
        jumpTokens += 1
        let glides = lastJumpItemIndex.map { abs($0 - hit.itemIndex) <= FindJump.nearItems } ?? false
        lastJumpItemIndex = hit.itemIndex
        jump = FindJump(token: jumpTokens, itemID: hit.itemID, anchorY: FindScroll.anchorY(position: hit.position, length: hit.length),
                        glides: glides)
        focus = FindFocus(itemID: hit.itemID, query: results.query, isFlashing: true)
        pausesFollowing = true
        if announcing, let index = cursor.index { announce?(results.spokenLabel(index: index)) }
        flashTask?.cancel()
        let id = hit.itemID, flash = delays.flash
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: flash)
            guard !Task.isCancelled, let self, focus?.itemID == id else { return }
            focus?.isFlashing = false
        }
    }

    // MARK: Quotes

    /// A quote in a message of yours was clicked (`MessageQuote`): the chat goes to the reply it came from, marks the quoted
    /// words and washes behind the reply for a moment, as a search hit does, with the bar closed. The marks go with the wash,
    /// and the chat follows the end of the conversation again.
    func reveal(quoteOf itemID: UUID, words: String) {
        jumpTokens += 1
        jump = FindJump(token: jumpTokens, itemID: itemID, anchorY: 0.3, glides: false)
        focus = FindFocus(itemID: itemID, query: words, isFlashing: true)
        pausesFollowing = true
        flashTask?.cancel()
        let flash = delays.flash
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: flash)
            guard !Task.isCancelled, let self, focus?.itemID == itemID, !isOpen else { return }
            focus = nil
            jump = nil
            pausesFollowing = false
        }
    }

    // MARK: What the bar says

    /// "3 de 12", "Sem resultados", "Buscando…", or nothing before a query.
    var statusText: String {
        guard SearchPattern(query) != nil else { return "" }
        guard let results else { return isSearching ? "Buscando…" : "" }
        guard let index = cursor.index else { return "Sem resultados" }
        return results.positionLabel(index: index)
    }

    /// What VoiceOver reads for the status: "3 de 12 resultados".
    var spokenStatus: String {
        guard SearchPattern(query) != nil else { return "Nenhum termo" }
        guard let results else { return isSearching ? "Buscando" : "" }
        guard let index = cursor.index else { return "Nenhum resultado" }
        return results.spokenLabel(index: index)
    }
}
