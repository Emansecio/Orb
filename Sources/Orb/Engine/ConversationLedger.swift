import Foundation

// The summary that stands in for the part of a conversation the model no longer sees. It is a small data model
// (not a text that is summarized again and again): each message that leaves the window is absorbed once, with a
// cap per section, and the text the model reads is rendered from it. The first request, the decisions, the files
// that were changed, the unresolved errors and what is still open therefore survive any number of compactions,
// and nothing is ever nested ("Resumo anterior" inside "Resumo anterior").

struct ConversationLedger: Codable, Sendable, Equatable {
    /// One line of "Pedidos e decisões": something the user asked, or decided.
    struct Entry: Codable, Sendable, Equatable {
        var text: String
        var isDecision: Bool
    }

    /// A tool call that failed (or was refused), until the same action works.
    struct Failure: Codable, Sendable, Equatable {
        var key: String
        var text: String
    }

    // Limits of what is kept (the text rendered from it has its own, smaller ones).
    static let originalLimit = 600
    static let goalLimit = 200
    static let requestLimit = 120
    static let decisionLimit = 160
    static let focusLimit = 300
    static let maxEntries = 25
    static let maxFiles = 40
    static let maxFailures = 5
    /// Room in the rendered summary for decisions and for the whole timeline of requests and decisions.
    static let decisionRoom = 900
    static let entriesRoom = 1_400
    static let replyLimit = 300
    static let questionLimit = 160
    static let legacyLimit = 800
    /// What the rendered summary shows of an old summary (the first request is pinned apart, see `init(legacy:)`).
    static let legacyShown = 400
    /// A first message shorter than this ("oi") is not "the original request".
    static let minimumOriginal = 20
    /// A message shorter than this ("e agora?") does not change what the current task is.
    static let minimumGoal = 10

    /// The first real request of the conversation. Fixed: never replaced or dropped.
    var original: String?
    /// The latest request: the task in progress.
    var goal: String?
    /// What the user asked a manual compaction to pay attention to.
    var focus: String?
    var entries: [Entry] = []
    /// Lines that left `entries` because of the cap.
    var earlierEntries = 0
    /// Files written or changed, oldest first.
    var changed: [String] = []
    /// Files and links only read, oldest first. A file that is changed later moves to `changed`.
    var read: [String] = []
    var failures: [Failure] = []
    /// The assistant's last question, which the user's next message (outside the summary) most likely answers.
    var openQuestion: String?
    /// The last request that has no answer from the assistant yet.
    var unanswered: String?
    var lastReply: String?
    /// A summary written by an earlier version of the app (one block of text), carried once and never extended.
    var legacy: String?
    /// How many messages have been absorbed.
    var foldedMessages = 0

    init() {}

    /// Starts from a summary text saved by an earlier version (or by the engine from a summary pair). A text this type
    /// rendered whose ledger was lost (a version that does not know ledgers saved the conversation again, or the
    /// saved ledger could not be read) is read back into its sections, so the first request stays pinned.
    init(legacy summary: String) {
        if let rendered = Self.reading(rendered: summary) {
            self = rendered
            return
        }
        let text = Self.cleanLegacy(summary)
        legacy = text.isEmpty ? nil : text
        // The old text is the only record of the first request: it is pinned like a new one, so it outlives the
        // old text when the summary is too long to keep both.
        original = Self.firstRequest(inLegacy: text)
        if let original { goal = Self.clip(original, Self.goalLimit) }
    }

    /// The first line of "Pedidos do usuário:" in a summary of the earlier format, unless older requests had already
    /// been cut from it ("(+N pedidos anteriores)") or it is too short to be a request.
    private static func firstRequest(inLegacy text: String) -> String? {
        let heading = "Pedidos do usuário:"
        guard text.hasPrefix(heading) else { return nil }
        let first = text.dropFirst(heading.count).split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
        guard let line = first?.trimmingCharacters(in: .whitespaces), line.hasPrefix("- ") else { return nil }
        let request = clip(String(line.dropFirst(2)), originalLimit)
        return request.count >= minimumOriginal ? request : nil
    }

    /// What `render()` writes at the start of a line, for reading a rendered summary back.
    private enum Heading {
        static let original = "Pedido original: "
        static let goal = "Objetivo atual: "
        static let focus = "Dar atenção a: "
        static let entries = "Pedidos e decisões:"
        static let failures = "Erros e bloqueios:"
        static let pending = "Pendente:"
        static let changed = "Arquivos alterados: "
        static let legacy = "Resumo anterior (formato antigo): "
        static let read = "Arquivos e links lidos: "
        static let lastReply = "Última resposta do assistente: "
        static let unanswered = "- Pedido ainda sem resposta final: "
        static let openQuestion = "- Última pergunta do assistente (a mensagem seguinte provavelmente a responde): "
        static let decision = "- decisão: "
        /// Only a rendered summary starts with one of these (an older summary starts with "Pedidos do usuário:").
        static let opening = [original, goal, focus, entries]
    }

    /// The ledger a summary rendered by `render()` was made from, as far as its text tells (what the caps had already
    /// left out is gone; lists cut short keep what they show). nil for any other text.
    private static func reading(rendered summary: String) -> ConversationLedger? {
        let lines = summary.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard let first = lines.first, Heading.opening.contains(where: first.hasPrefix) else { return nil }
        var ledger = ConversationLedger()
        var section = ""
        func items(_ text: String) -> [String] {
            text.components(separatedBy: "; ").filter { !$0.isEmpty && !$0.hasPrefix("e mais ") }
        }
        for line in lines {
            func value(_ heading: String) -> String? { line.hasPrefix(heading) ? String(line.dropFirst(heading.count)) : nil }
            if let text = value(Heading.original) {
                ledger.original = clip(text, originalLimit)
            } else if let text = value(Heading.goal) {
                ledger.goal = clip(text, goalLimit)
            } else if let text = value(Heading.focus) {
                ledger.focus = clip(text, focusLimit)
            } else if let text = value(Heading.changed) {
                ledger.changed = items(text)
            } else if let text = value(Heading.read) {
                ledger.read = items(text)
            } else if let text = value(Heading.legacy) {
                ledger.legacy = text.isEmpty ? nil : text
            } else if let text = value(Heading.lastReply) {
                ledger.lastReply = clip(text, replyLimit)
            } else if [Heading.entries, Heading.failures, Heading.pending].contains(line) {
                section = line
            } else if line.hasPrefix("- ") || line.hasPrefix("(+") {
                switch section {
                case Heading.entries:
                    if line.hasPrefix("(+") {
                        ledger.earlierEntries += Int(line.dropFirst(2).prefix { $0.isNumber }) ?? 0
                    } else if let text = value(Heading.decision) {
                        ledger.entries.append(Entry(text: text, isDecision: true))
                    } else {
                        ledger.entries.append(Entry(text: String(line.dropFirst(2)), isDecision: false))
                    }
                case Heading.failures:
                    let text = String(line.dropFirst(2))
                    ledger.failures.append(Failure(key: "?" + text, text: text))
                case Heading.pending:
                    if let text = value(Heading.unanswered) { ledger.unanswered = text }
                    if let text = value(Heading.openQuestion) { ledger.openQuestion = text }
                default:
                    break
                }
            }
        }
        // The goal is left out of the text when it repeats the original request or the newest request.
        if ledger.goal == nil { ledger.goal = ledger.entries.last { !$0.isDecision }?.text ?? ledger.original.map { clip($0, goalLimit) } }
        return ledger
    }

    var isEmpty: Bool {
        original == nil && goal == nil && entries.isEmpty && changed.isEmpty && read.isEmpty && failures.isEmpty
            && lastReply == nil && legacy == nil
    }

    // MARK: Codable (tolerant: every field may be missing, a newer version may add more)

    private enum CodingKeys: String, CodingKey {
        case original, goal, focus, entries, earlierEntries, changed, read, failures, openQuestion, unanswered
        case lastReply, legacy, foldedMessages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        original = try c.decodeIfPresent(String.self, forKey: .original)
        goal = try c.decodeIfPresent(String.self, forKey: .goal)
        focus = try c.decodeIfPresent(String.self, forKey: .focus)
        entries = try c.lossyArray(.entries)
        earlierEntries = try c.value(.earlierEntries, default: 0)
        changed = try c.value(.changed, default: [])
        read = try c.value(.read, default: [])
        failures = try c.lossyArray(.failures)
        openQuestion = try c.decodeIfPresent(String.self, forKey: .openQuestion)
        unanswered = try c.decodeIfPresent(String.self, forKey: .unanswered)
        lastReply = try c.decodeIfPresent(String.self, forKey: .lastReply)
        legacy = try c.decodeIfPresent(String.self, forKey: .legacy)
        foldedMessages = try c.value(.foldedMessages, default: 0)
    }

    // MARK: Absorbing messages

    /// This ledger with `messages` (in order) added. `followedByUser`: a user message comes right after them (a
    /// summary always ends at a turn boundary), so the assistant's last question is kept for it to answer.
    func absorbing(_ messages: [ChatMessage], followedByUser: Bool = true) -> ConversationLedger {
        var copy = self
        copy.absorb(messages, followedByUser: followedByUser)
        return copy
    }

    mutating func absorb(_ messages: [ChatMessage], followedByUser: Bool = true) {
        var calls: [String: ToolReference] = [:]
        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                if message.content.hasPrefix(ContextSummary.marker) { continue }
                absorbUser(message)
            case .assistant:
                if message.content == ContextSummary.acknowledgement { continue }
                absorbAssistant(message, calls: &calls)
            case .tool:
                absorbToolResult(message, call: message.toolCallID.flatMap { calls[$0] })
            }
            foldedMessages += 1
        }
        // The question stays only when the conversation goes on with a user message outside what was absorbed.
        if !followedByUser { openQuestion = nil }
    }

    private mutating func absorbUser(_ message: ChatMessage) {
        var text = MemoryText.flatten(TurnPreface.userWords(message.content))
        if text.isEmpty, !message.images.isEmpty { text = "(imagem anexada)" }
        let question = openQuestion
        openQuestion = nil
        guard !text.isEmpty else { return }
        unanswered = Self.clip(text, Self.decisionLimit)

        if Self.isFiller(text) {
            // "sim", "pode": only worth keeping as the answer to something the assistant asked.
            if let question { add(Entry(text: "“\(Self.clip(text, 30))” em resposta a: \(question)", isDecision: true)) }
            return
        }
        // The first real request is fixed whatever it says (it often holds a "never…" of its own).
        if original == nil, legacy == nil, text.count >= Self.minimumOriginal {
            original = Self.clip(text, Self.originalLimit)
            goal = Self.clip(text, Self.goalLimit)
            return
        }
        if Self.looksLikeDecision(text) {
            add(Entry(text: Self.decisionText(text), isDecision: true))
            return
        }
        add(Entry(text: Self.clip(text, Self.requestLimit), isDecision: false))
        if text.count >= Self.minimumGoal { goal = Self.clip(text, Self.goalLimit) }
    }

    private mutating func add(_ entry: Entry) {
        guard entries.last != entry else { return }
        entries.append(entry)
        while entries.count > Self.maxEntries {
            // Old requests go before old decisions.
            let index = entries.firstIndex { !$0.isDecision } ?? 0
            entries.remove(at: index)
            earlierEntries += 1
        }
    }

    private mutating func addFailure(_ failure: Failure) {
        failures.removeAll { $0.key == failure.key }
        failures.append(failure)
        if failures.count > Self.maxFailures { failures.removeFirst(failures.count - Self.maxFailures) }
    }

    private mutating func absorbAssistant(_ message: ChatMessage, calls: inout [String: ToolReference]) {
        for call in message.toolCalls { calls[call.id] = ToolReference(call) }
        var text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let interrupted = text.hasSuffix(AgentEngine.interruptedMarker.trimmingCharacters(in: .whitespacesAndNewlines))
        // Claude Code's turns carry a note of what it did; it is not part of what was said.
        if let note = text.range(of: "(Actions taken in this turn:", options: .backwards) { text = String(text[..<note.lowerBound]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastReply = Self.clip(MemoryText.flatten(Self.withoutCode(text)), Self.replyLimit)
        if !interrupted { unanswered = nil }
        openQuestion = text.hasSuffix("?") ? Self.lastQuestion(in: text) : nil
    }

    /// How the results of calls that did not run begin (an interrupted turn, a refusal).
    private static let notRunPrefix = "Not run:"

    private mutating func absorbToolResult(_ message: ChatMessage, call: ToolReference?) {
        guard let call else {
            if message.isError { addFailure(Failure(key: "?", text: Self.clip(Self.firstLine(message.content), 140))) }
            return
        }
        // A call that never ran (a stopped turn's made-up answer) neither worked nor failed: nothing to record.
        if !message.isError, message.content.hasPrefix(Self.notRunPrefix) { return }
        if message.isError {
            let denied = message.content.hasPrefix("Not run: the user denied")
            let why = denied ? "você negou esta ação" : Self.firstLine(message.content)
            addFailure(Failure(key: call.key, text: Self.clip("\(call.label): \(why)", 160)))
            return
        }
        // The same action worked now: the earlier failure is behind us.
        failures.removeAll { $0.key == call.key }
        for path in call.written { touch(path, written: true) }
        for path in call.consulted { touch(path, written: false) }
    }

    private mutating func touch(_ path: String, written: Bool) {
        let shown = Self.clip(path, 160)
        if written {
            read.removeAll { $0 == shown }
            changed.removeAll { $0 == shown }
            changed.append(shown)
            if changed.count > Self.maxFiles { changed.removeFirst(changed.count - Self.maxFiles) }
        } else if !changed.contains(shown) {
            read.removeAll { $0 == shown }
            read.append(shown)
            if read.count > Self.maxFiles { read.removeFirst(read.count - Self.maxFiles) }
        }
    }

    // MARK: Rendering

    /// The text the model reads. Deterministic (the same ledger always gives the same text, so the provider's
    /// cache still applies), at most `limit` characters: when the sections do not fit, the least important go
    /// first (the old summary, the last answer, files only read…); the first request never does.
    func render(limit: Int = ContextSummary.maxLength) -> String {
        var sections: [(rank: Int, text: String)] = []
        if let original { sections.append((0, "Pedido original: " + original)) }
        if let goal, !isOriginal(goal), !isLatestRequest(goal) { sections.append((1, "Objetivo atual: " + goal)) }
        if let focus, !focus.isEmpty { sections.append((2, "Dar atenção a: " + focus)) }
        if let timeline = renderedEntries() { sections.append((2, timeline)) }
        if !failures.isEmpty {
            sections.append((3, "Erros e bloqueios:\n" + failures.map { "- " + $0.text }.joined(separator: "\n")))
        }
        var pending: [String] = []
        if let unanswered { pending.append("- Pedido ainda sem resposta final: " + unanswered) }
        if let openQuestion { pending.append("- Última pergunta do assistente (a mensagem seguinte provavelmente a responde): " + openQuestion) }
        if !pending.isEmpty { sections.append((3, "Pendente:\n" + pending.joined(separator: "\n"))) }
        if !changed.isEmpty { sections.append((4, changedLine())) }
        // The old text goes after the files changed, before the files read and the last answer.
        if let legacy { sections.append((5, "Resumo anterior (formato antigo): " + Self.clip(legacy, Self.legacyShown))) }
        if !read.isEmpty { sections.append((6, readLine())) }
        if let lastReply { sections.append((7, "Última resposta do assistente: " + lastReply)) }

        func joined() -> String { sections.map(\.text).joined(separator: "\n") }
        while joined().count > limit, let worst = sections.indices.filter({ sections[$0].rank > 0 }).max(by: {
            (sections[$0].rank, $0) < (sections[$1].rank, $1)
        }) {
            sections.remove(at: worst)
        }
        let text = joined()
        return text.count > limit ? MemoryText.clip(text, limit) : text
    }

    private func changedLine() -> String { "Arquivos alterados: " + Self.list(changed, budget: 420) }
    private func readLine() -> String { "Arquivos e links lidos: " + Self.list(read, budget: 260) }

    /// Only the state: files changed and read and the errors left open (what a few skipped steps of a request leave).
    func stateLines() -> [String] {
        var lines: [String] = []
        if !changed.isEmpty { lines.append(changedLine()) }
        if !read.isEmpty { lines.append(readLine()) }
        if !failures.isEmpty { lines.append("Erros e bloqueios: " + failures.map(\.text).joined(separator: "; ")) }
        return lines
    }

    /// Whether `goal` is just the first request again (so the summary does not say it twice).
    private func isOriginal(_ goal: String) -> Bool {
        guard let original else { return false }
        return original.hasPrefix(goal.trimmingCharacters(in: CharacterSet(charactersIn: "…")))
    }

    /// Whether `goal` is the newest request on the timeline (so the summary does not say it twice).
    private func isLatestRequest(_ goal: String) -> Bool {
        guard let latest = entries.last(where: { !$0.isDecision }) else { return false }
        return goal.hasPrefix(latest.text.trimmingCharacters(in: CharacterSet(charactersIn: "…")))
    }

    private func renderedEntries() -> String? {
        guard !entries.isEmpty || earlierEntries > 0 else { return nil }
        func line(_ entry: Entry) -> String { entry.isDecision ? "- decisão: " + entry.text : "- " + entry.text }
        // Decisions first, newest first (they are what must not be forgotten), then the newest requests, until the
        // room is used; the rest is only counted.
        var picked: Set<Int> = [], used = 0
        func take(_ index: Int, upTo room: Int) -> Bool {
            let cost = line(entries[index]).count + 1
            guard used + cost <= room else { return false }
            picked.insert(index)
            used += cost
            return true
        }
        for index in entries.indices.reversed() where entries[index].isDecision { _ = take(index, upTo: Self.decisionRoom) }
        for index in entries.indices.reversed() where !entries[index].isDecision { if !take(index, upTo: Self.entriesRoom) { break } }
        for index in entries.indices.reversed() where entries[index].isDecision && !picked.contains(index) { _ = take(index, upTo: Self.entriesRoom) }
        let hidden = earlierEntries + entries.count - picked.count
        let header = hidden == 1 ? ["(+1 pedido ou decisão anterior)"] : hidden > 1 ? ["(+\(hidden) pedidos e decisões anteriores)"] : []
        return "Pedidos e decisões:\n" + (header + picked.sorted().map { line(entries[$0]) }).joined(separator: "\n")
    }

    /// The most recent items that fit in `budget` characters, oldest of them first, then how many were left out.
    private static func list(_ items: [String], budget: Int) -> String {
        var shown: [String] = [], used = 0
        for item in items.reversed() {
            let text = clip(item, 70)
            guard shown.isEmpty || used + text.count + 2 <= budget else { break }
            shown.insert(text, at: 0)
            used += text.count + 2
        }
        let more = items.count - shown.count
        return shown.joined(separator: "; ") + (more > 0 ? "; e mais \(more)" : "")
    }

    // MARK: Text helpers

    static func clip(_ text: String, _ limit: Int) -> String { MemoryText.clip(MemoryText.flatten(text), limit) }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line.map { String($0) } ?? text
    }

    /// `text` without fenced code blocks (a long reply is mostly code; the summary wants what was said).
    private static func withoutCode(_ text: String) -> String {
        let parts = text.components(separatedBy: "```")
        guard parts.count > 2 else { return text }
        return parts.enumerated().map { $0.offset.isMultiple(of: 2) ? $0.element : " [código] " }.joined()
    }

    /// The last sentence of `text` that ends in a question mark.
    private static func lastQuestion(in text: String) -> String {
        let paragraph = text.components(separatedBy: "\n\n").last { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? text
        let flat = MemoryText.flatten(paragraph)
        var start = flat.startIndex
        for index in flat.indices where index < flat.index(before: flat.endIndex) && ".!?".contains(flat[index]) {
            start = flat.index(after: index)
        }
        return clip(String(flat[start...]), questionLimit)
    }

    /// Strips what an earlier version nested: only the first block of an old summary is kept.
    private static func cleanLegacy(_ summary: String) -> String {
        var text = summary
        if let nested = text.range(of: "\nResumo anterior:") { text = String(text[..<nested.lowerBound]) }
        return MemoryText.clip(text.trimmingCharacters(in: .whitespacesAndNewlines), legacyLimit)
    }

    // MARK: Heuristics

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let fillers: Set<String> = [
        "sim", "nao", "ok", "okay", "pode", "pode sim", "pode ser", "isso", "isso mesmo", "claro", "beleza", "blz", "manda",
        "manda ver", "vai", "faz", "faca", "pode fazer", "pode continuar", "continua", "continue", "segue", "segue em frente",
        "fechado", "combinado", "certo", "ta", "ta bom", "tudo bem", "valeu", "obrigado", "obrigada", "show", "perfeito",
    ]

    /// "sim", "pode", "continua": an answer that means something only next to the question it answers.
    static func isFiller(_ text: String) -> Bool {
        let plain = normalized(text).trimmingCharacters(in: CharacterSet(charactersIn: ".!, ")).replacingOccurrences(of: ",", with: "")
        return fillers.contains(plain)
    }

    private static let decisionPatterns: [String] = [
        #"\bdecidi\b"#, #"\bdecidimos\b"#, #"\bficou decidido\b"#, #"\bvamos (usar|com|de|manter|adotar|seguir)\b"#,
        #"\b(use|usa|utilize|adote|mantenha|mantenham)\b"#, #"\b(nao|jamais|nunca) (use|usa|utilize|mude|mexa|apague|delete|remova|faca|faça)\b"#,
        #"\bsempre\b"#, #"\bnunca\b"#, #"\bprefiro\b"#, #"\blembre(-se)?\b"#, #"\ba partir de agora\b"#, #"\bcombinado\b"#,
        #"\bnao (quero|precisa|vamos)\b"#, #"\bem vez de\b"#, #"\bao inves de\b"#, #"\bevite\b"#,
    ]
    private static let decisionExpressions: [NSRegularExpression] = decisionPatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    /// What only an explicit decision says, for what is written to the memory for good (the broad rule above is
    /// for the summary, where a wrong guess costs a line; here "o build sempre quebra" must not become a decision).
    private static let explicitDecisionPatterns: [String] = [
        #"\bdecidi\b"#, #"\bdecidimos\b"#, #"\bficou decidido\b"#, #"^decisao:"#, #"\bvamos (usar|manter|adotar|seguir)\b"#,
        #"\ba partir de agora\b"#, #"\bprefiro\b"#, #"\b(nao|jamais|nunca) (use|usa|utilize|mude|mexa|apague|delete|remova|faca)\b"#,
    ]
    private static let explicitDecisionExpressions: [NSRegularExpression] = explicitDecisionPatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    /// Whether a message of the user states a decision in so many words ("decidi…", "vamos usar…", "a partir de
    /// agora…", "prefiro…", "nunca use…").
    static func looksLikeExplicitDecision(_ text: String) -> Bool {
        let plain = normalized(text)
        if plain.hasSuffix("?"), !plain.contains("decidi") { return false }
        let range = NSRange(plain.startIndex..., in: plain)
        return explicitDecisionExpressions.contains { $0.firstMatch(in: plain, range: range) != nil }
    }

    /// Whether a message of the user states a decision or a standing preference ("vamos usar…", "nunca…", "use…").
    /// A heuristic that only decides what is kept longer, so a wrong guess costs a line, not an answer.
    static func looksLikeDecision(_ text: String) -> Bool {
        let plain = normalized(text)
        if plain.hasSuffix("?"), !plain.contains("decidi") { return false }
        let range = NSRange(plain.startIndex..., in: plain)
        return decisionExpressions.contains { $0.firstMatch(in: plain, range: range) != nil }
    }

    /// The part of a decision-looking message worth keeping: the message itself when short, else the sentence that
    /// states the decision, without a leading "Decisão:" (the summary labels it).
    static func decisionText(_ text: String) -> String {
        var chosen = text
        if text.count > decisionLimit {
            let sentences = sentences(of: text)
            chosen = sentences.first(where: looksLikeDecision) ?? text
        }
        for label in ["decisão:", "decisao:", "decidi:"] where chosen.lowercased().hasPrefix(label) {
            chosen = String(chosen.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        return clip(chosen, decisionLimit)
    }

    /// `text` cut after ". ", "! ", "? " and "; " (so "m1.swift" stays whole).
    private static func sentences(of text: String) -> [String] {
        var result: [String] = [], current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let atEnd = index == characters.count - 1
            if ".!?;".contains(character), atEnd || characters[index + 1].isWhitespace {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
        return result
    }
}

// MARK: - What a tool call touches

/// A tool call as the ledger needs it: what it is called, which files it writes, which it only reads, and a key
/// to recognize the same action again (so a failure is forgotten when a later attempt works).
private struct ToolReference {
    var name: String
    var key: String
    var label: String
    var written: [String] = []
    var consulted: [String] = []

    init(_ call: ToolCallRequest) {
        name = call.name
        let arguments = JSONValue.parse(call.arguments) ?? .object([:])
        let path = arguments["path"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        switch call.name {
        case "read_file":
            consulted = path.map { [$0] } ?? []
        case "write_file", "edit_file":
            written = path.map { [$0] } ?? []
        case "web_fetch":
            consulted = arguments["url"]?.string.map { [$0] } ?? []
        case "trash":
            written = (arguments["paths"]?.array?.compactMap(\.string) ?? []) + (path.map { [$0] } ?? [])
        case "run_command":
            written = Self.writtenPaths(inCommand: arguments["command"]?.string ?? "")
        default:
            break
        }
        let target = path ?? arguments["command"]?.string ?? arguments["url"]?.string ?? ""
        let shortTarget = ConversationLedger.clip(target, 60)
        key = call.name + ":" + shortTarget
        label = shortTarget.isEmpty ? call.name : call.name + " " + shortTarget
    }

    /// Files a shell command writes, as far as its text shows: redirections, `tee`, `touch`, `mkdir`, `rm`, `mv`,
    /// `cp` and `sed -i`. Anything cleverer is not guessed.
    static func writtenPaths(inCommand command: String) -> [String] {
        // The body of a here-document is data, not commands.
        var text = command
        if let marker = text.range(of: "<<") {
            let rest = text[marker.upperBound...]
            let lineEnd = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
            text = String(text[..<marker.lowerBound]) + " " + String(rest[..<lineEnd].split(separator: " ").dropFirst().joined(separator: " "))
        }
        var found: [String] = []
        func add(_ raw: String) {
            let path = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`();"))
            guard !path.isEmpty, !path.hasPrefix("&"), !path.hasPrefix("/dev/"), !path.hasPrefix("-"), !path.hasPrefix("$"),
                  !found.contains(path) else { return }
            found.append(path)
        }
        let segments = text.replacingOccurrences(of: "&&", with: ";").split(whereSeparator: { ";|\n".contains($0) })
        for segment in segments {
            var tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)
            while let first = tokens.first, first == "sudo" || first == "env" || (first.contains("=") && !first.hasPrefix("-")) {
                tokens.removeFirst()
            }
            for (index, token) in tokens.enumerated() {
                // `> file`, `>> file`, `2> file`, `&> file`, and the same stuck to the name: `>file`.
                if let redirect = token.firstIndex(of: ">"), token[..<redirect].allSatisfy({ $0.isNumber || $0 == "&" }) {
                    var target = String(token[token.index(after: redirect)...]).replacingOccurrences(of: ">", with: "")
                    if target.isEmpty, index + 1 < tokens.count { target = tokens[index + 1] }
                    add(target)
                }
            }
            guard let command = tokens.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            let arguments = tokens.dropFirst().filter { !$0.hasPrefix("-") && !$0.contains(">") }
            switch command {
            case "tee", "touch", "mkdir", "rm", "rmdir", "mv", "cp", "ln":
                arguments.forEach(add)
            case "sed" where tokens.contains(where: { $0.hasPrefix("-i") || $0 == "--in-place" }):
                if let file = arguments.last { add(file) }
            default:
                break
            }
        }
        return found
    }
}
