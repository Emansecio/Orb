import Foundation

// What part of a conversation the model is sent, so a long task neither overflows the model's window nor
// silently loses the request: sizes are estimated, old outputs and arguments shortened, and whole old turns
// folded into a summary instead of being cut.

// MARK: - Budget

/// How much conversation history one request may carry, estimated in tokens (characters / 3.5).
struct ContextBudget: Sendable, Equatable {
    static let charactersPerToken = 3.5
    /// Share of the model's window given to history; the rest is for the system prompt, tool specs, the new
    /// message and the reply.
    static let historyShare = 0.6

    /// Tokens of history.
    var tokens: Int

    var characters: Int { Int(Double(tokens) * Self.charactersPerToken) }

    /// Used when nothing is known about the model (and by callers that don't care, like the Claude Code catch-up).
    static let fallback = ContextBudget(modelWindow: 128_000)

    init(tokens: Int) {
        self.tokens = max(tokens, 500)
    }

    /// `modelWindow`: the model's whole context window in tokens.
    init(modelWindow: Int) {
        self.init(tokens: Int(Double(modelWindow) * Self.historyShare))
    }

    /// The model's reported window when known, else a default for its wire format (local servers run small windows).
    /// `format`: the account's own wire format, used when the model is not in its catalog (custom gateways).
    init(model: ProviderModel?, provider: ProviderKind, format: APIFormat? = nil) {
        if let known = model?.contextLength, known > 0 {
            self.init(modelWindow: known)
        } else if provider == .ollama || provider == .lmstudio {
            self.init(modelWindow: 16_000)
        } else {
            let wire = model?.format ?? format ?? (provider == .anthropic ? .messages : provider == .claudeCode ? .claudeCode : .chat)
            switch wire {
            case .chat, .responses: self.init(modelWindow: 128_000)
            case .messages, .claudeCode: self.init(modelWindow: 200_000)
            }
        }
    }

    func scaled(by factor: Double) -> ContextBudget {
        ContextBudget(tokens: Int(Double(tokens) * factor))
    }
}

// MARK: - Window

/// The conversation fitted to a budget.
struct ContextWindow: Sendable, Equatable {
    /// Ready to send after the system prompt: a summary pair first when the beginning was folded away.
    var messages: [ChatMessage]
    /// How many leading messages of the input the summary now stands for.
    var droppedCount: Int
    /// Summary of those messages (nil when nothing was folded away); kept by `Conversation` between turns.
    var summary: String?

    static let toolOutputPreview = 4_000
    static let argumentLimit = 1_000
    /// Tool outputs of the latest steps of a task in progress stay whole: the model is still working on them.
    static let freshToolOutputs = 3

    /// Fits `input` (no system message) to `budget`:
    /// 1. starts at a user message (never an assistant or tool message);
    /// 2. keeps the last 3 tool outputs of a task in progress whole and shortens all other outputs and
    ///    tool-call arguments;
    /// 3. drops the oldest whole turns until it fits, folding them into a summary;
    /// 4. if the latest turn alone is still too big, shortens harder and sets aside its oldest steps, but it
    ///    always keeps the user message that started it.
    /// `previousSummary` stands for messages already left out of `input`.
    static func fit(_ input: [ChatMessage], budget: ContextBudget, summary previousSummary: String? = nil) -> ContextWindow {
        var work = input
        var previous = previousSummary
        if let inherited = ContextSummary.leading(in: work) {
            previous = inherited
            work.removeFirst(2)
        }
        let start = work.firstIndex { $0.role == .user } ?? work.firstIndex { $0.role != .tool } ?? work.count
        var body = Array(work[start...])
        shorten(&body, keepFull: freshToolOutputs, outputLimit: toolOutputPreview, argumentLimit: argumentLimit)

        let sizes = body.map(\.contextCharacters)
        var total = sizes.reduce(0, +)
        let turnStarts = body.indices.filter { body[$0].role == .user }
        var dropped = 0
        func reserve() -> Int { previous != nil || dropped > 0 ? ContextSummary.reserve : 0 }

        var turn = 0
        while total + reserve() > budget.characters, turn + 1 < turnStarts.count {
            let end = turnStarts[turn + 1]
            total -= sizes[dropped..<end].reduce(0, +)
            dropped = end
            turn += 1
        }
        body.removeFirst(dropped)

        var skippedSteps: [ChatMessage] = []
        if total + reserve() > budget.characters {
            // Only the latest turn is left and it alone is too big.
            for (outputLimit, argumentLimit) in [(toolOutputPreview, argumentLimit), (1_200, 300)] {
                shorten(&body, keepFull: 0, outputLimit: outputLimit, argumentLimit: argumentLimit)
                total = body.reduce(0) { $0 + $1.contextCharacters }
                if total + reserve() <= budget.characters { break }
            }
            if total + reserve() > budget.characters {
                skippedSteps = dropOldestSteps(of: &body, whileOver: budget.characters - ContextSummary.reserve)
            }
        }

        // Messages before the first user message (a slice that began mid-turn) are just left out, not summarized.
        let folded = Array(work[start..<(start + dropped)])
        let summary: String? = folded.isEmpty ? previous : ContextSummary.make(from: folded, previous: previous)
        let shown = [summary, ContextSummary.stepsNote(skippedSteps)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let messages = shown.isEmpty ? [] : ContextSummary.pair(shown, foldedTurns: summary != nil)
        return ContextWindow(messages: (messages + body).answeringDanglingToolCalls(), droppedCount: start + dropped, summary: summary)
    }

    /// Sets aside the oldest model/tool steps after the leading user message, never the newest one.
    private static func dropOldestSteps(of body: inout [ChatMessage], whileOver limit: Int) -> [ChatMessage] {
        guard let first = body.firstIndex(where: { $0.role == .user }) else { return [] }
        var skipped: [ChatMessage] = []
        while body.reduce(0, { $0 + $1.contextCharacters }) > limit {
            let steps = body.indices.dropFirst(first + 1)
            guard let next = steps.dropFirst().first(where: { body[$0].role == .assistant }) else { break }
            skipped += body[(first + 1)..<next]
            body.removeSubrange((first + 1)..<next)
        }
        return skipped
    }

    /// Shortens tool outputs, and the long strings inside tool-call arguments, except the newest `keepFull`
    /// outputs of a task still in progress (the conversation ends with a tool result or a pending call) and the
    /// calls they answer. Once the assistant has answered, every output of that task counts as old, so a huge
    /// output is not re-sent whole on every later message.
    static func shorten(_ messages: inout [ChatMessage], keepFull: Int, outputLimit: Int, argumentLimit: Int) {
        let inProgress = messages.last.map { $0.role == .tool || !$0.toolCalls.isEmpty } ?? false
        let taskStart = messages.lastIndex { $0.role == .user } ?? -1
        let fresh = inProgress
            ? Set(messages.indices.filter { $0 > taskStart && messages[$0].role == .tool }.suffix(keepFull)) : []
        let freshCalls = Set(fresh.compactMap { messages[$0].toolCallID })
        for index in messages.indices {
            switch messages[index].role {
            case .tool where !fresh.contains(index):
                messages[index].content = ContextText.preview(messages[index].content, limit: outputLimit)
            case .assistant:
                for call in messages[index].toolCalls.indices where !freshCalls.contains(messages[index].toolCalls[call].id) {
                    messages[index].toolCalls[call].arguments =
                        ContextText.shortenArguments(messages[index].toolCalls[call].arguments, stringLimit: argumentLimit)
                }
            default:
                break
            }
        }
    }
}

extension ChatMessage {
    /// Rough size for budgeting: text, tool calls and a little per-message overhead.
    var contextCharacters: Int {
        content.count + toolCalls.reduce(0) { $0 + $1.id.count + $1.name.count + $1.arguments.count } + 16
    }
}

// MARK: - Shortening text

enum ContextText {
    private static let omissionOpen = "\n[… "
    private static let omissionClose = " characters omitted from the middle …]\n"

    /// The start and end of `text` with a marker for what is left out, `limit` characters in all (plus the marker).
    /// Text that already carries such a marker keeps its count: what it left out is added to what is cut now, and
    /// whatever follows the marker (like the path of a saved output) stays at the end.
    static func preview(_ text: String, limit: Int) -> String {
        guard text.count > limit + 80 else { return text }
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

/// Rule-based summary of messages folded out of the window (the spirit of `SessionSummary`, over `ChatMessage`s).
enum ContextSummary {
    static let marker = "[Resumo do começo desta conversa]"
    static let acknowledgement = "Entendido. Sigo a partir deste resumo e das mensagens abaixo."
    /// Characters set aside in the budget for the summary pair.
    static let reserve = 4_000
    static let maxLength = 3_000
    private static let previousLength = 1_200

    /// A user message with the summary and an assistant acknowledgement, so the conversation alternates
    /// correctly for every provider.
    /// `foldedTurns`: false when only early steps of the current request were left out, not earlier turns.
    static func pair(_ summary: String, foldedTurns: Bool = true) -> [ChatMessage] {
        let header = foldedTurns ? "O começo desta conversa foi compactado para caber na janela do modelo."
            : "Os primeiros passos deste pedido foram omitidos para caber na janela do modelo."
        return [.user(marker + "\n" + header + "\n" + summary),
         ChatMessage(role: .assistant, content: acknowledgement)]
    }

    /// The summary text of a pair at the start of `messages` (from an earlier fit), or nil.
    static func leading(in messages: [ChatMessage]) -> String? {
        guard messages.count >= 2, messages[0].role == .user, messages[0].content.hasPrefix(marker),
              messages[1].role == .assistant, messages[1].content == acknowledgement else { return nil }
        let lines = messages[0].content.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        return lines.count == 3 ? String(lines[2]) : ""
    }

    static func make(from dropped: [ChatMessage], previous: String?) -> String {
        func line(_ text: String, _ limit: Int) -> String { MemoryText.clip(MemoryText.flatten(text), limit) }
        var sections: [String] = []

        let requests = dropped.filter { $0.role == .user }.map { line(TurnPreface.stripped($0.content), 200) }.filter { !$0.isEmpty }
        if !requests.isEmpty {
            let older = requests.count > 8 ? ["(+\(requests.count - 8) pedidos anteriores)"] : []
            sections.append("Pedidos do usuário:\n" + (older + requests.suffix(8).map { "- " + $0 }).joined(separator: "\n"))
        }
        if let work = work(in: dropped) { sections.append(work) }
        if let answer = dropped.last(where: { $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            sections.append("Última resposta do assistente: " + line(answer.content, 600))
        }
        if let previous, !previous.isEmpty {
            sections.append("Resumo anterior: " + MemoryText.clip(previous, previousLength))
        }
        return MemoryText.clip(sections.joined(separator: "\n"), maxLength)
    }

    /// A line about steps of the current request that were set aside to make room.
    static func stepsNote(_ skipped: [ChatMessage]) -> String {
        guard let work = work(in: skipped) else { return "" }
        return "Neste pedido, os primeiros passos foram omitidos.\n" + work
    }

    /// Tools used and the files and links they touched.
    private static func work(in messages: [ChatMessage]) -> String? {
        var counts: [(name: String, count: Int)] = []
        var references: [String] = []
        for message in messages {
            for call in message.toolCalls {
                if let index = counts.firstIndex(where: { $0.name == call.name }) { counts[index].count += 1 }
                else { counts.append((call.name, 1)) }
                for token in MemoryText.keepTokens(String(call.arguments.prefix(2_000)), limit: 6)
                where references.count < 12 && !references.contains(token) {
                    references.append(token)
                }
            }
        }
        var lines: [String] = []
        if !counts.isEmpty {
            lines.append("Ferramentas usadas: " + counts.prefix(10).map { "\($0.name) (\($0.count))" }.joined(separator: ", ") + ".")
        }
        if !references.isEmpty { lines.append("Arquivos e links: " + references.joined(separator: "; ")) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

// MARK: - Model context

extension [ChatMessage] {
    /// The part of a conversation sent to the model, fitted to `budget` (see `ContextWindow.fit`), with every
    /// tool call answered.
    func modelContext(budget: ContextBudget = .fallback) -> [ChatMessage] {
        ContextWindow.fit(self, budget: budget).messages
    }
}

extension Conversation {
    /// The history for the next turn. When turns had to be folded away, remembers the summary and how many
    /// messages it covers (the messages themselves stay, for the transcript and for Claude Code). Compaction is
    /// permanent by design: it uses the budget of the model active at that moment, and a later switch to a model
    /// with a larger window keeps working from the summary.
    /// `firstCompaction` is true the first time this conversation gets a summary.
    mutating func prepareHistory(budget: ContextBudget) -> (history: [ChatMessage], firstCompaction: Bool) {
        let covered = summary == nil ? 0 : min(max(summaryCoveredCount ?? 0, 0), messages.count)
        let window = ContextWindow.fit(Array(messages[covered...]), budget: budget, summary: summary)
        let first = summary == nil && window.summary != nil
        if window.summary != nil {
            summary = window.summary
            summaryCoveredCount = covered + window.droppedCount
        }
        return (window.messages, first)
    }
}

// MARK: - Big tool outputs

/// A tool result larger than the cap goes to a file; the model gets its start and end and the path.
enum ToolOutputCap {
    static let limit = 30_000
    private static let head = 10_000
    private static let tail = 5_000
    /// Without a way to read files back, a saved copy would be useless, so the output stays inline up to a larger
    /// size (above `web_fetch`'s own 30,000 characters) and only the extremes are cut.
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
