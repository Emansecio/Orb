import Foundation

// What part of a conversation the model is sent, so a long task neither overflows the model's window nor
// silently loses the request: sizes are estimated, old outputs and arguments shortened, and whole old turns
// folded into a summary instead of being cut. The budget is in `ContextBudget`.
//
// Every provider caches the start of a request, so what is sent changes in batches: nothing is touched while the
// history fits, and when it no longer does it is brought down to a low-water mark (half the budget), not just
// under the limit. The next compaction then comes many messages later instead of at the very next one.

// MARK: - Cut

/// What successive fits of one growing conversation remember, so that the cut moves only when it must: the part
/// already folded into the summary, how hard old outputs have been shortened, the steps already set aside. A
/// fit without memory (`ContextWindow.fit(_:budget:summary:)`) starts from an empty cut.
struct ContextCut: Sendable, Equatable {
    /// Messages at the start of the input already folded into `summary` (a leading summary pair counts).
    var covered = 0
    var summary: String?
    /// What `summary` is rendered from (see `ConversationLedger`): a fold extends it with the messages leaving the
    /// window. nil with a summary: the summary is a text of an earlier version, read into a ledger once when extended.
    var ledger: ConversationLedger?
    /// The model's notes on stretches not folded yet, in the input's own indexes (see `ChunkSummary`): a fold that
    /// takes a stretch whole adds its note to the ledger. nil/empty: the summary is the rules' alone.
    var chunks: [ChunkSummary] = []
    /// The notes that folds through this cut added to the ledger so far, oldest first: what the memory page of the folded
    /// stretch gets besides the rules' page (the ledger itself keeps only its newest `maxDigests`).
    var attachedNotes: [String] = []
    /// The task all the fields below belong to starts at this index of the input; a new task starts them over.
    var anchor = -1
    /// Shortening level reached in a task too big for the window (see `ContextWindow.rungs`); it only goes up.
    var rung = 0
    /// Messages after the task's request set aside so far (they live on as lines in the summary pair).
    var skipped = 0
    /// Tool outputs of the task, oldest first, already past their fresh period (shortened).
    var settled = 0

    init(summary: String? = nil, ledger: ConversationLedger? = nil) {
        self.summary = summary
        self.ledger = ledger
    }
}

// MARK: - Window

/// The conversation fitted to a budget.
struct ContextWindow: Sendable, Equatable {
    /// Ready to send after the system prompt: a summary pair first when the beginning was folded away.
    var messages: [ChatMessage]
    /// How many leading messages of the input the summary now stands for.
    var droppedCount: Int
    /// How many of them this fit folded into the summary (those before the first user message of a slice that began
    /// mid-turn are only left out).
    var foldedCount = 0
    /// Summary of those messages (nil when nothing was folded away); kept by `Conversation` between turns.
    var summary: String?
    /// What the summary is rendered from; kept with it.
    var ledger: ConversationLedger?
    /// How many model steps after the request of a task too big for the window were set aside (digested in the pair).
    var skippedSteps = 0
    /// Estimated size of the history before this fit folded or set aside anything new (the summary pair included), and
    /// of what it sends: for telling the user what a compaction did.
    var charactersBefore = 0
    var charactersAfter: Int { messages.contextCharacters }

    /// Old tool outputs (those of earlier turns, and the task's own once past their fresh period), in characters.
    static let toolOutputPreview = 4_000
    static let argumentLimit = 1_000
    /// Tool outputs of a task in progress stay whole while the model is working on them, and changing them would
    /// start the provider's cache over at every step: so they become previews in batches (see `freshShare`) or when
    /// the task crowds the window, but this many of the newest always stay whole.
    static let freshToolOutputs = 3
    /// Share of the budget the whole outputs of a task in progress may take before the oldest become previews, and
    /// how many outputs beyond the newest few it takes for that to happen (so it comes in batches).
    static let freshShare = 0.4
    static let freshBatch = 3
    /// How much of the budget a fold may take beyond what it needs, to end where a stretch with a note ends.
    static let noteSnapShare = 0.25

    /// How hard a task that alone outgrows the window is shortened, from the first level up: the previews of old outputs
    /// first, then the whole outputs of the task are capped, and only as a last resort the oldest steps are set aside.
    /// Levels only apply to what is already in the request or is added at its end, so after a level is reached the
    /// request grows at its end again.
    struct Rung: Sendable {
        var oldOutputs: Int
        var arguments: Int
        /// Cap on the outputs of the task that are still whole (nil: no cap).
        var wholeOutputs: Int?
    }

    static let rungs: [Rung] = [
        Rung(oldOutputs: toolOutputPreview, arguments: argumentLimit, wholeOutputs: nil),
        Rung(oldOutputs: 1_500, arguments: 300, wholeOutputs: nil),
        Rung(oldOutputs: 800, arguments: 300, wholeOutputs: nil),
        // Even the newest output keeps this much, never less.
        Rung(oldOutputs: 800, arguments: 300, wholeOutputs: 8_000),
    ]

    /// Fits `input` (no system message) to `budget` with no memory of earlier fits.
    /// `previousSummary` stands for messages already left out of `input`; `previousLedger` is what it was rendered from.
    static func fit(_ input: [ChatMessage], budget: ContextBudget, summary previousSummary: String? = nil,
                    ledger previousLedger: ConversationLedger? = nil, condensing: Int = 0, continuing: Bool = false) -> ContextWindow {
        var cut = ContextCut(summary: previousSummary, ledger: previousLedger)
        return fit(input, budget: budget, cut: &cut, condensing: condensing, continuing: continuing)
    }

    /// Fits `input` (no system message) to `budget`:
    /// 1. starts at a user message (never an assistant or tool message);
    /// 2. keeps the outputs of a task in progress whole while they are fresh and shortens all other outputs and
    ///    tool-call arguments;
    /// 3. when over the budget, drops the oldest whole turns, down to the low-water mark, folding them into a summary;
    /// 4. if the latest turn alone is still too big, shortens it harder step by step and sets aside its oldest steps
    ///    (down to the low-water mark as well, leaving a line for each), but it always keeps the user message that
    ///    started it and its newest step.
    ///
    /// `cut` is what the caller's earlier fits of this same conversation decided: it is applied again before
    /// anything else, so the start of the request stays the same until the history is over the budget again, and it is
    /// updated with what this fit decided. The input may only grow at its end between calls.
    /// `condensing`: the first `condensing` messages of the input are sent condensed (see `ContextCondensing`).
    /// `continuing`: the last user message of the input only picks up the task before it (a task that stopped at
    /// the step limit), so that task's outputs are the fresh ones and its turn is not dropped from under it.
    /// `paused`: the input ends with such a task, before the message that picks it up: it still counts as in progress.
    /// `nudge`: index in the input of a user message the engine added only to steer the turn (the "continue" after a
    /// reply cut by the output limit): part of the turn in progress, never the start of one, so the turn's request
    /// is never folded away from under it.
    /// `steering`: indexes in the input of the messages the user sent while the turn ran: like the nudge, one more step of
    /// the turn in progress (the request that started it stays the turn's start, its outputs stay whole).
    /// `foldAbove`: the share of the budget past which the history is folded down to the low-water mark (1: only when
    /// it is over the budget; less when folding is free anyway, see `Conversation.isCacheCold`).
    static func fit(_ input: [ChatMessage], budget: ContextBudget, cut: inout ContextCut, condensing: Int = 0,
                    continuing: Bool = false, paused: Bool = false, nudge: Int? = nil, steering: [Int] = [],
                    foldAbove: Double = 1) -> ContextWindow {
        let limit = budget.characters
        let covered = min(max(cut.covered, 0), input.count)
        var work = Array(input[covered...])
        var previous = cut.summary
        // The note about steps an earlier fit set aside belongs to the request right after its pair: it goes on, apart
        // from the summary, for as long as that request is in the window.
        var carriedNote: String?
        var pairLength = 0
        if covered == 0, let inherited = ContextSummary.inherited(in: work) {
            previous = inherited.summary ?? previous
            carriedNote = inherited.stepsNote
            work.removeFirst(2)
            pairLength = 2
        }
        work = work.elidingOldImages()
        let start = work.firstIndex { $0.role == .user } ?? work.firstIndex { $0.role != .tool } ?? work.count
        let raw = Array(work[start...])
        /// Index in `input` of `raw[0]`.
        let origin = covered + pairLength + start

        // The task in progress: the latest request, or, for a task picked up again, the one before it.
        let nudgeIndex = nudge.map { $0 - origin }
        let stepIndexes = Set(([nudgeIndex].compactMap { $0 }) + steering.map { $0 - origin })
        let users = raw.indices.filter { raw[$0].role == .user && !stepIndexes.contains($0) }
        let pickedUp = continuing && users.count >= 2
        let taskStart = pickedUp ? users[users.count - 2] : (users.last ?? -1)
        let nudged = stepIndexes.contains { $0 > taskStart && $0 < raw.count }
        let inProgress = pickedUp || paused || nudged || (raw.last.map { $0.role == .tool || !$0.toolCalls.isEmpty } ?? false)
        let anchor = origin + max(taskStart, 0)
        if cut.anchor != anchor {
            cut.anchor = anchor
            cut.rung = 0
            cut.skipped = 0
            cut.settled = 0
        }

        // Which outputs of the task are still whole: all of them, until the task is crowding the window.
        let taskOutputs = inProgress ? raw.indices.filter { $0 > taskStart && raw[$0].role == .tool } : []
        var settled = min(cut.settled, taskOutputs.count)
        // Whole outputs take at most `freshShare` of the budget: past it, and once there are `freshBatch` more than the
        // newest few, the oldest become previews in one go, down to half of that. (One at every step would change
        // the middle of the request every time, and the provider's cache would start over from there.)
        let argumentSizes = raw.reduce(into: [String: Int]()) { sizes, message in
            for call in message.toolCalls { sizes[call.id] = call.arguments.count }
        }
        let costs = taskOutputs.map { raw[$0].content.count + (raw[$0].toolCallID.flatMap { argumentSizes[$0] } ?? 0) }
        var freshCost = costs[settled...].reduce(0, +)
        let freshLimit = Int(Double(limit) * freshShare)
        if taskOutputs.count - settled >= freshToolOutputs + freshBatch, freshCost > freshLimit {
            while taskOutputs.count - settled > freshToolOutputs, freshCost > freshLimit / 2 {
                freshCost -= costs[settled]
                settled += 1
            }
        }

        let condensedUpTo = max(0, condensing - origin)
        let newestSnapshot = ContextCondensing.snapshotIndex(in: raw)

        /// `raw` shortened at level `rung`.
        func prepared(_ rung: Int) -> [ChatMessage] {
            let level = rungs[rung]
            let fresh = Set(taskOutputs[settled...])
            let freshCalls = Set(fresh.compactMap { raw[$0].toolCallID })
            var messages = raw
            for index in messages.indices {
                let condensed = index < condensedUpTo
                switch messages[index].role {
                case .user where condensed:
                    messages[index] = ContextCondensing.condensed(messages[index], keepingSnapshot: index == newestSnapshot,
                                                                  keepingChanges: newestSnapshot.map { index > $0 } ?? false)
                case .tool where fresh.contains(index):
                    if let cap = level.wholeOutputs {
                        messages[index].content = ContextText.preview(messages[index].content, limit: cap)
                    }
                case .tool:
                    var allowed = level.oldOutputs
                    if condensed { allowed = min(allowed, ContextCondensing.outputLimit) }
                    allowed = max(allowed, messages[index].isError ? ContextCondensing.errorLimit : 0)
                    messages[index].content = ContextText.preview(messages[index].content, limit: allowed)
                case .assistant:
                    if condensed { messages[index] = ContextCondensing.condensed(messages[index], keepingSnapshot: false) }
                    for call in messages[index].toolCalls.indices where !freshCalls.contains(messages[index].toolCalls[call].id) {
                        messages[index].toolCalls[call].arguments =
                            ContextText.shortenArguments(messages[index].toolCalls[call].arguments, stringLimit: level.arguments)
                    }
                default:
                    break
                }
            }
            return messages
        }

        var rung = min(cut.rung, rungs.count - 1)
        var body = prepared(rung)
        let sizes = body.map(\.contextCharacters)
        var total = sizes.reduce(0, +)
        // A task picked up again is one turn with its predecessor: its own request is not a place to cut.
        let turnStarts = users.filter { !(pickedUp && $0 == users.last) }
        var dropped = 0
        // The model's notes ride in the summary pair too, in a room of their own.
        let notesRoom = cut.chunks.isEmpty && cut.ledger?.digests.isEmpty != false ? 0 : ConversationLedger.digestRoom
        func reserve() -> Int { previous != nil || carriedNote != nil || dropped > 0 ? ContextSummary.reserve + notesRoom : 0 }
        let charactersBefore = total + (previous != nil || carriedNote != nil ? ContextSummary.pair(
            [previous, carriedNote].compactMap { $0 }.joined(separator: "\n")).contextCharacters : 0)

        // Over the limit: fold whole old turns away, down to the low-water mark.
        var turn = 0
        let target = total + reserve() > Int(Double(limit) * foldAbove) ? Int(Double(limit) * budget.lowWater) : limit
        while total + reserve() > target, turn + 1 < turnStarts.count {
            let end = turnStarts[turn + 1]
            total -= sizes[dropped..<end].reduce(0, +)
            dropped = end
            turn += 1
        }
        // A fold that stops a little before the end of a stretch the model wrote a note on goes on to it, so the note is
        // used (the real fold usually takes a bit more or less than the one the note was planned for).
        if dropped > 0, let end = cut.chunks.map({ $0.end - origin }).filter({ $0 > dropped && turnStarts.contains($0) }).min(),
           Double(sizes[dropped..<end].reduce(0, +)) <= Double(limit) * noteSnapShare {
            total -= sizes[dropped..<end].reduce(0, +)
            dropped = end
        }
        body.removeFirst(dropped)

        // What is left of the latest turn alone. Steps already set aside stay set aside.
        let canSkip = body.first?.role == .user
        var skipped = canSkip ? min(cut.skipped, max(body.count - 2, 0)) : 0
        func view(_ rung: Int) -> [ChatMessage] {
            var messages = Array(prepared(rung).dropFirst(dropped))
            if skipped > 0 { messages.removeSubrange(1..<(1 + skipped)) }
            return messages
        }
        // Steps set aside leave a digest in the summary pair; a small window can spare fewer lines of it.
        let digestLines = ToolDigest.lines(forLimit: limit)
        let digestRoom = ToolDigest.maxCharacters(lines: digestLines)
        func crowded() -> Bool { total + reserve() + (skipped > 0 ? digestRoom : 0) > limit }
        if skipped > 0 {
            body = view(rung)
            total = body.contextCharacters
        }
        if crowded() {
            // Over the limit: bring the task down to the low-water mark, so this does not happen again at the very
            // next step (every change rewrites the provider's cache). The gentlest cuts come first.
            let goal = Int(Double(limit) * budget.stepsLowWater)
            func relieved() -> Bool { total + reserve() + (skipped > 0 ? digestRoom : 0) <= goal }
            // 1. The task's oldest whole outputs become previews (the newest few stay whole): until now nothing of
            //    the task changed, so the cache held from step to step.
            var estimate = total, next = settled
            while taskOutputs.count - next > freshToolOutputs, estimate + reserve() > goal {
                estimate -= max(0, sizes[taskOutputs[next]] - (toolOutputPreview + 120))
                next += 1
            }
            if next > settled {
                settled = next
                body = view(rung)
                total = body.contextCharacters
            }
            // 2. Previews get shorter, then the whole outputs are capped, then only the newest stays long.
            while !relieved(), rung + 1 < rungs.count {
                rung += 1
                body = view(rung)
                total = body.contextCharacters
            }
            // 3. The oldest steps are set aside, one line each in the summary; the newest step always stays.
            if crowded(), canSkip {
                while !relieved() {
                    // One step at a time: from the message after the request to the next model reply.
                    guard let next = body.indices.dropFirst(2).first(where: { body[$0].role == .assistant }) else { break }
                    total -= body[1..<next].contextCharacters
                    skipped += next - 1
                    body.removeSubrange(1..<next)
                }
            }
        }
        cut.rung = rung
        cut.skipped = skipped
        cut.settled = settled
        let skippedRange = skipped > 0 ? (dropped + 1)..<(dropped + 1 + skipped) : 0..<0
        // The nudge is no word of the user's: it leaves no line.
        let skippedSteps = skippedRange.filter { $0 != nudgeIndex }.map { raw[$0] }

        // Messages before the first user message (a slice that began mid-turn) are just left out, not summarized.
        // What leaves the window is absorbed into the ledger once; the summary is rendered from it (never nested).
        let folded = Array(work[start..<(start + dropped)])
        var ledger = cut.ledger
        var summary = previous
        if !folded.isEmpty {
            let base = cut.ledger ?? previous.map { ConversationLedger(legacy: $0) } ?? ConversationLedger()
            var extended = base.absorbing(folded)
            let foldedUpTo = origin + dropped
            let carried = cut.chunks.filter { $0.end <= foldedUpTo }.map(\.text)
            extended.attach(carried)
            cut.attachedNotes += carried
            cut.chunks.removeAll { $0.end <= foldedUpTo }
            ledger = extended
            summary = extended.render()
        }
        let note = ContextSummary.mergedNotes(dropped == 0 ? carriedNote : nil,
                                              ContextSummary.stepsNote(skippedSteps, maxLines: digestLines))
        let shown = [summary, note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let messages = shown.isEmpty ? [] : ContextSummary.pair(shown, foldedTurns: summary != nil)
        if dropped > 0 {
            cut.covered = covered + pairLength + start + dropped
            cut.summary = summary
            cut.ledger = ledger
        }
        return ContextWindow(messages: (messages + body).answeringDanglingToolCalls(), droppedCount: start + dropped,
                             foldedCount: folded.count, summary: summary, ledger: ledger,
                             skippedSteps: skippedSteps.filter { $0.role == .assistant }.count, charactersBefore: charactersBefore)
    }
}

extension ChatMessage {
    /// Tokens a picture costs, whatever its size (providers charge by area; ours are at most 1568 px on a side,
    /// which is about this).
    static let imageTokens = 1_600

    /// Rough size for budgeting: text, tool calls, reasoning kept for the provider, pictures and a little
    /// per-message overhead.
    var contextCharacters: Int {
        content.count + toolCalls.reduce(0) { $0 + $1.id.count + $1.name.count + $1.arguments.count } + 16
            + images.count * Int(Double(Self.imageTokens) * ContextBudget.charactersPerToken)
            + (reasoning?.parts.reduce(0) { $0 + $1.text.count + ($1.data?.count ?? 0) + ($1.signature?.count ?? 0) } ?? 0)
    }
}

extension Sequence where Element == ChatMessage {
    /// Rough size of all these messages for budgeting (the sum of each one's `contextCharacters`).
    var contextCharacters: Int { reduce(0) { $0 + $1.contextCharacters } }
}

extension [ChatMessage] {
    /// Pictures in the last `turns` user turns stay; older ones become a line with their path (the conversation
    /// itself keeps them). A task that takes many screenshots keeps only the newest `maxToolImages` of them, so one
    /// long turn cannot fill the window with pictures.
    func elidingOldImages(turns: Int = 3, maxToolImages: Int = 6) -> [ChatMessage] {
        guard contains(where: { !$0.images.isEmpty }) else { return self }
        let userTurns = indices.filter { self[$0].role == .user && !self[$0].content.hasPrefix(ContextSummary.marker) }
        let oldest = userTurns.count > turns ? userTurns[userTurns.count - turns] : 0
        let recentToolImages = Set(indices.filter { self[$0].role == .tool && !self[$0].images.isEmpty && $0 >= oldest }
            .suffix(maxToolImages))
        return enumerated().map { index, message in
            let keep = index >= oldest && (message.role != .tool || recentToolImages.contains(index))
            return keep ? message : message.replacingImages { "[imagem anexada: \($0.path)]" }
        }
    }
}

// MARK: - Shortening text

enum ContextText {
    private static let omissionOpen = "\n[… "
    private static let omissionClose = " characters omitted from the middle …]\n"
    /// How the note about a saved output starts, whichever tool wrote it (see `RunCommandTool`): later shortening of the
    /// conversation keeps such a note whole.
    static let savedNoteOpen = "\n[full output saved at "
    private static let maxSavedNote = 600

    /// The start and end of `text` with a marker for what is left out, `limit` characters in all (plus the marker).
    /// Text that already carries such a marker keeps its count: what it left out is added to what is cut now, and
    /// whatever follows the marker (like the path of a saved output) stays at the end.
    static func preview(_ text: String, limit: Int) -> String {
        guard text.count > limit + 80 else { return text }
        // The note of a saved output (its path) is the way back to the whole text: it always stays, whole.
        if text.hasSuffix("]"), let note = text.range(of: savedNoteOpen, options: .backwards),
           text[note.lowerBound...].count <= maxSavedNote {
            return preview(String(text[..<note.lowerBound]), limit: limit) + String(text[note.lowerBound...])
        }
        let head = limit * 5 / 8, tail = limit - head
        if let close = text.range(of: omissionClose, options: .backwards),
           let open = text.range(of: omissionOpen, options: .backwards, range: text.startIndex..<close.lowerBound),
           let earlier = Int(text[open.upperBound..<close.lowerBound]) {
            let before = text[..<open.lowerBound], after = text[close.upperBound...]
            let keptHead = before.prefix(head), keptTail = after.suffix(tail)
            let omitted = earlier + (before.count - keptHead.count) + (after.count - keptTail.count)
            return String(keptHead) + marker(omitted) + String(keptTail)
        }
        return String(text.prefix(head)) + marker(text.count - limit) + String(text.suffix(tail))
    }

    static func marker(_ omitted: Int) -> String { omissionOpen + "\(omitted)" + omissionClose }

    /// Tool-call arguments with every string longer than `stringLimit` cut. Still valid JSON.
    static func shortenArguments(_ arguments: String, stringLimit: Int) -> String {
        guard arguments.count > stringLimit else { return arguments }
        guard let parsed = JSONValue.parse(arguments) else {
            return JSONValue.object(["truncated_arguments": .string(clip(arguments, stringLimit))]).jsonString
        }
        var changed = false
        let shortened = parsed.mappingStrings { text in
            let clipped = clip(text, stringLimit)
            if clipped != text { changed = true }
            return clipped
        }
        return changed ? shortened.jsonString : arguments
    }

    private static let clipOpen = "… ["
    private static let clipClose = " more characters omitted]"

    /// `text` cut to `limit` characters plus a marker. Already-cut text is left alone when it is within the limit
    /// (plus its marker), so fitting twice gives the same result, and a second cut adds to the earlier count.
    private static func clip(_ text: String, _ limit: Int) -> String {
        var base = Substring(text), earlier = 0
        if text.hasSuffix(clipClose), let open = text.range(of: clipOpen, options: .backwards),
           let count = Int(text[open.upperBound...].dropLast(clipClose.count)) {
            base = text[..<open.lowerBound]
            earlier = count
        }
        guard base.count > limit else { return text }
        return String(base.prefix(limit)) + clipOpen + "\(base.count - limit + earlier)" + clipClose
    }
}

private extension JSONValue {
    func mappingStrings(_ transform: (String) -> String) -> JSONValue {
        switch self {
        case .string(let text): .string(transform(text))
        case .array(let items): .array(items.map { $0.mappingStrings(transform) })
        case .object(let fields): .object(fields.mapValues { $0.mappingStrings(transform) })
        default: self
        }
    }
}

// MARK: - Summary

/// The summary of messages folded out of the window, as the model reads it. What it says comes from a
/// `ConversationLedger` (rules, no model call); this type is its wrapper in the history: the marker, the pair and
/// the lines about steps of the current request.
enum ContextSummary {
    static let marker = "[Resumo do começo desta conversa]"
    static let acknowledgement = "Entendido. Sigo a partir deste resumo e das mensagens abaixo."
    /// Characters set aside in the budget for the summary pair.
    static let reserve = 4_000
    static let maxLength = 3_000
    /// The title line of the note about steps set aside (`stepsNote`).
    static let stepsNoteTitle = "Neste pedido, os primeiros passos foram omitidos; o que cada um fez:"

    /// A user message with the summary and an assistant acknowledgement, so the conversation alternates
    /// correctly for every provider.
    /// `foldedTurns`: false when only early steps of the current request were left out, not earlier turns.
    static func pair(_ summary: String, foldedTurns: Bool = true) -> [ChatMessage] {
        let header = foldedTurns ? "O começo desta conversa foi compactado para caber na janela do modelo."
            : "Os primeiros passos deste pedido foram omitidos para caber na janela do modelo."
        return [.user(marker + "\n" + header + "\n" + summary),
         ChatMessage(role: .assistant, content: acknowledgement)]
    }

    /// What a pair at the start of a history holds: the summary of the folded turns and, apart from it, the note
    /// about steps of the current request that an earlier fit set aside (which is no summary of anything older).
    struct Inherited: Equatable {
        var summary: String?
        var stepsNote: String?
    }

    /// The pair at the start of `messages` (from an earlier fit), or nil when there is none.
    static func inherited(in messages: [ChatMessage]) -> Inherited? {
        guard messages.count >= 2, messages[0].role == .user, messages[0].content.hasPrefix(marker),
              messages[1].role == .assistant, messages[1].content == acknowledgement else { return nil }
        let lines = messages[0].content.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        let body = lines.count == 3 ? String(lines[2]) : ""
        var summary = body
        var note: String?
        if let title = body.range(of: stepsNoteTitle),
           title.lowerBound == body.startIndex || body[body.index(before: title.lowerBound)] == "\n" {
            summary = String(body[..<title.lowerBound])
            note = String(body[title.lowerBound...])
        }
        summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return Inherited(summary: summary.isEmpty ? nil : summary, stepsNote: note)
    }

    /// The summary text of a pair at the start of `messages` (from an earlier fit), or nil.
    static func leading(in messages: [ChatMessage]) -> String? { inherited(in: messages)?.summary }

    /// An earlier note and a new one as one note (the title once).
    static func mergedNotes(_ earlier: String?, _ new: String) -> String {
        guard let earlier, !earlier.isEmpty else { return new }
        guard !new.isEmpty else { return earlier }
        return ([earlier] + new.components(separatedBy: "\n").dropFirst()).joined(separator: "\n")
    }

    /// The summary of `dropped` added to `previous` (the text of an earlier summary, carried once as it is).
    static func make(from dropped: [ChatMessage], previous: String?) -> String {
        make(from: dropped, ledger: previous.map { ConversationLedger(legacy: $0) } ?? ConversationLedger())
    }

    static func make(from dropped: [ChatMessage], ledger: ConversationLedger) -> String {
        ledger.absorbing(dropped).render()
    }

    /// Lines about steps of the current request that were set aside to make room: one for each (see `ToolDigest`).
    static func stepsNote(_ skipped: [ChatMessage], maxLines: Int = ToolDigest.maxLines) -> String {
        let lines = ToolDigest.lines(for: skipped, maxLines: maxLines)
        guard !lines.isEmpty else { return "" }
        return stepsNoteTitle + "\n" + lines.joined(separator: "\n")
    }
}

// MARK: - Model context

extension Conversation {
    /// The history for the next turn. When turns had to be folded away, remembers the summary and how many
    /// messages it covers (the messages themselves stay, for the transcript and for Claude Code). Compaction is
    /// permanent by design: it uses the budget of the model active at that moment, and a later switch to a model
    /// with a larger window keeps working from the summary.
    ///
    /// The history only changes in batches, because every change rewrites the provider's prompt cache from the
    /// first message touched: turns are folded away when the history passes the budget (down to its low-water mark,
    /// see `ContextBudget`), and the older stretch is condensed (see `ContextCondensing`) at that same moment, or
    /// when that alone would save enough. Between batches the history only grows at its end.
    /// `firstCompaction` is true the first time this conversation gets a summary; `compaction` says what this call
    /// folded away, with numbers (nil when it folded nothing): one notice per fold.
    /// `reserving`: characters the request carries besides this history (the new message and what goes before it),
    /// left out of the room, so a fold at sending is not followed by another at the turn's first step.
    /// `focus`: something the summary should pay attention to (a manual compaction); kept only when this call folds.
    /// `now`: when given (a message being sent), a conversation whose provider cache has gone cold is folded early
    /// (see `isCacheCold`).
    mutating func prepareHistory(budget: ContextBudget, reserving characters: Int = 0, focus: String? = nil, now: Date? = nil)
        -> (history: [ChatMessage], firstCompaction: Bool, compaction: CompactionReport?) {
        let room = budget.leavingRoom(forCharacters: characters)
        let covered = coveredMessageCount
        let slice = Array(messages[covered...])
        let stored = max((condensedCount ?? 0) - covered, 0)
        var condensing = stored
        let paused = isTaskPaused
        var base = currentLedger
        if let focus = Self.cleanFocus(focus) {
            var seeded = base ?? ConversationLedger()
            seeded.focus = focus
            base = seeded
        }
        let foldAbove = now.map(isCacheCold) == true ? ContextBudget.coldFoldShare : 1
        func startingCut() -> ContextCut {
            var cut = ContextCut(summary: summary, ledger: base)
            cut.chunks = pendingChunks(after: covered)
            return cut
        }
        var cut = startingCut()
        var window = ContextWindow.fit(slice, budget: room, cut: &cut, condensing: condensing, paused: paused, foldAbove: foldAbove)
        let before = window.charactersBefore

        let frontier = ContextCondensing.frontier(in: slice)
        if frontier > stored {
            let saving = ContextCondensing.savings(in: slice, from: stored, to: frontier)
            if cut.covered > 0 || saving >= Int(Double(room.characters) * ContextBudget.condenseShare) {
                condensing = frontier
                cut = startingCut()
                window = ContextWindow.fit(slice, budget: room, cut: &cut, condensing: condensing, paused: paused, foldAbove: foldAbove)
            }
        }
        if condensing > 0 { condensedCount = covered + condensing }

        let first = summary == nil && window.summary != nil
        guard cut.covered > 0, window.summary != nil else { return (window.messages, first, nil) }
        summary = window.summary
        ledger = cut.ledger
        summaryCoveredCount = covered + window.droppedCount
        compactions = (compactions ?? 0) + 1
        var report = CompactionReport(kind: .turns, foldedMessages: window.foldedCount,
                                      tokensBefore: ContextBudget.tokens(forCharacters: before),
                                      tokensAfter: ContextBudget.tokens(forCharacters: window.charactersAfter))
        report.foldedRequests = requestCount(in: 0..<coveredMessageCount)
        // The notes this fold carried into the summary also go to the memory with the stretch (see `SessionSummary`).
        report.digests = cut.attachedNotes
        return (window.messages, first, report)
    }

    /// Whether the provider's cache of this conversation has gone cold: its last model call was `cacheColdAfter` ago or
    /// more. The next request pays for the whole history anyway, so folding the start now costs no cache; the history
    /// is folded already at `coldFoldShare` of the budget (what `prepareHistory` does with `now`). A conversation with
    /// no recorded call is not cold.
    func isCacheCold(now: Date) -> Bool {
        lastModelCall.map { now.timeIntervalSince($0) >= ContextBudget.cacheColdAfter } ?? false
    }

    /// How many of `messages` the summary stands for.
    var coveredMessageCount: Int { summary == nil ? 0 : min(max(summaryCoveredCount ?? 0, 0), messages.count) }

    /// The ledger the summary was rendered from; for a conversation saved before ledgers existed, its text.
    var currentLedger: ConversationLedger? {
        guard let summary else { return nil }
        return ledger ?? ConversationLedger(legacy: summary)
    }

    /// The focus of a manual compaction on one line, at most `ConversationLedger.focusLimit` characters; nil when blank.
    static func cleanFocus(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = ConversationLedger.clip(text, ConversationLedger.focusLimit)
        return line.isEmpty ? nil : line
    }
}

// MARK: - Big tool outputs

/// A tool result larger than the cap goes to a file; the model gets its start and end and the path.
enum ToolOutputCap {
    static let limit = 30_000
    private static let head = 10_000
    private static let tail = 5_000
    /// Without a way to read files back, a saved copy would be useless, so the output stays inline up to a larger
    /// size (above the 24,000 characters of a page, `ToolOutputBudget.pageCharacters`) and only the extremes are cut.
    static let limitWithoutFiles = 40_000
    private static let headWithoutFiles = 28_000
    private static let tailWithoutFiles = 8_000

    /// The tools that can read a saved file back.
    static let readers: Set<String> = ["read_file", "run_command"]

    static var defaultDirectory: URL { FileManager.default.temporaryDirectory.appending(path: "orb-saidas") }

    /// `toolNames`: the tools the bot has. The note about the saved file only names tools it can use.
    /// The note comes last, so shortening the output later (`ContextText.preview`) keeps the path.
    static func apply(_ output: String, botID: UUID, callID: String, toolNames: Set<String> = readers,
                      directory: URL = defaultDirectory) -> String {
        guard !toolNames.isDisjoint(with: readers) else {
            guard output.count > limitWithoutFiles else { return output }
            let omitted = output.count - headWithoutFiles - tailWithoutFiles
            return String(output.prefix(headWithoutFiles)) + ContextText.marker(omitted) + String(output.suffix(tailWithoutFiles))
                + "\n[the middle of this output was cut and cannot be read back; ask for narrower output]"
        }
        guard output.count > limit else { return output }
        let safeID = String(callID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.prefix(80))
        // Providers may omit call IDs (the clients fall back to "call_0"), so the name never depends on the ID alone.
        let unique = String(UUID().uuidString.prefix(8))
        let folder = directory.appending(path: botID.uuidString)
        let file = folder.appending(path: (safeID.isEmpty ? unique : safeID + "-" + unique) + ".txt")
        let saved: Bool
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try output.write(to: file, atomically: true, encoding: .utf8)
            saved = true
        } catch {
            saved = false
        }
        let note = saved ? "full output saved at \(file.path); \(readAdvice(toolNames))"
            : "the rest of the output could not be saved; run the command again with narrower output"
        return String(output.prefix(head)) + ContextText.marker(output.count - head - tail) + String(output.suffix(tail))
            + "\n[\(note)]"
    }

    private static func readAdvice(_ toolNames: Set<String>) -> String {
        switch (toolNames.contains("read_file"), toolNames.contains("run_command")) {
        case (true, true):
            "read it with read_file (offset/limit page by lines) or grep; for very long lines use run_command with head -c, cut or grep -o"
        case (true, false):
            "read it with read_file (offset/limit page by lines)"
        default:
            "read it with run_command (grep, sed -n, head -c)"
        }
    }
}

// MARK: - Context overflow

enum ContextOverflow {
    /// The provider refused the request for its size (HTTP 400/413, or an error event in the stream, whose message talks about context or length).
    static func matches(_ error: Error) -> Bool {
        let message: String
        switch error {
        // The clients already recognize most overflows.
        case LLMError.contextExceeded: return true
        case LLMError.http(let status, let text, _) where status == 400 || status == 413: message = text
        // Responses and Anthropic streams can report the same refusal as an error event in the stream.
        case LLMError.invalidResponse(let text): message = text
        case LLMError.stream(_, let text): message = text
        default: return false
        }
        let text = message.lowercased()
        return ["context", "prompt is too long", "prompt too long", "too long", "too many tokens", "maximum length", "input length"]
            .contains { text.contains($0) }
    }
}
