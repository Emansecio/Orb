import Foundation

// What the Orb says it is doing while a turn runs: a verb and, when there is one, its target ("Rodando" `swift build`,
// "Lendo" README.md, "Pesquisando" “swiftui shimmer”). A small `Equatable` value the working line, the sidebar row and
// the menu bar panel read, changed once per step of the turn and never per token. Where the words come from (the tool
// call, the engine's status line), how long each stays on screen (`StatusDwell`) and when VoiceOver is told
// (`WorkAnnouncer`) are in this file too: all of it is plain logic, tested without a view.

/// One phrase of the working line.
struct WorkLine: Equatable, Sendable {
    /// How the target is written: code (a command, a file, a pattern) in a monospaced face, a plain word (a host),
    /// or a quoted piece of text (what is searched for, what is delegated).
    enum Style: Equatable, Sendable { case code, plain, quoted }

    /// Whether the Orb works (shimmers), waits for you (still, in the warning color) or waits to try again.
    enum Tone: Equatable, Sendable {
        case working
        case waiting
        case retrying(until: Date)
    }

    var verb: String
    var target: String?
    var style = Style.plain
    var tone = Tone.working
    /// The routine this turn belongs to (its name), when it is a routine's run.
    var routine: String?
    /// Who the work is for, in front of the phrase ("Pedido de Atlas": "Pedido de Atlas: Lendo README.md"), when the Orb
    /// works on another Orb's request.
    var prefix: String?
    /// How many actions (tool calls) the turn has made so far, this phrase's one included.
    var actions = 0

    init(verb: String, target: String? = nil, style: Style = .plain, tone: Tone = .working, routine: String? = nil,
         prefix: String? = nil, actions: Int = 0) {
        self.verb = verb
        self.target = target?.isEmpty == true ? nil : target
        self.style = style
        self.tone = tone
        self.routine = routine
        self.prefix = prefix
        self.actions = actions
    }

    /// The longest target shown: past it, the middle is left out ("swift build --jobs … -configuration release"), so
    /// the clock stays near the words.
    static let displayLimit = 56

    /// The target as written: cut in the middle when long, and quoted text between “ ”.
    var shownTarget: String? {
        guard let target else { return nil }
        var shown = target
        if target.count > Self.displayLimit {
            let half = (Self.displayLimit - 1) / 2
            shown = target.prefix(half) + "…" + target.suffix(half)
        }
        return style == .quoted ? "“\(shown)”" : shown
    }

    /// Whether the line shimmers: only while the Orb works.
    var shimmers: Bool { tone == .working }
    /// Whether the Orb is running a command (in the Terminal or in the background): the line also breathes.
    var runsCommand: Bool { tone == .working && verb.hasPrefix("Rodando") }

    /// The phrase as plain text (the sidebar, the menu bar panel and VoiceOver read this): the verb and its target,
    /// or the verb with an ellipsis when it has none ("Pensando…"). A wait is a state, not an action: no ellipsis.
    var phrase: String {
        if let shownTarget { return "\(verb) \(shownTarget)" }
        return tone == .working ? "\(verb)…" : verb
    }

    /// `phrase`, with the routine's name in front, or the request's ("Pedido de Atlas: Lendo README.md").
    var text: String {
        if let routine { return "Rotina “\(routine)”: \(phrase)" }
        if let prefix { return "\(prefix): \(phrase)" }
        return phrase
    }

    /// What identifies the phrase on screen: it changes when the words or the mood change, not when the count of
    /// actions, the routine or the countdown do. A new key swaps the phrase in the working line.
    var phraseKey: String {
        let mood = switch tone {
        case .working: "w"
        case .waiting: "a"
        case .retrying: "r"
        }
        return "\(mood)|\(prefix ?? "")|\(verb)|\(target ?? "")|\(style)"
    }

    /// Whether VoiceOver may be told about the phrase: it names something the Orb is doing.
    var isAnnounceable: Bool { tone == .working && target != nil }
}

// MARK: - Where the words come from

enum WorkPhrase {
    /// The longest target kept (a pasted script is not a status line).
    static let targetLimit = 120

    /// The phrase for a tool call, from its title and the first line of its detail. A title this does not know says
    /// itself, without a target ("Usando github", "Clicando em Salvar").
    static func line(for call: ToolCall) -> WorkLine {
        let first = firstLine(of: call.detail)
        switch call.title {
        case "Rodando no Terminal":
            return WorkLine(verb: "Rodando", target: first, style: .code)
        case "Rodando em segundo plano":
            return WorkLine(verb: "Rodando em segundo plano", target: first, style: .code)
        case "Lendo arquivo", "Lendo caderno":
            return WorkLine(verb: "Lendo", target: fileName(first), style: .code)
        case "Editando arquivo":
            return WorkLine(verb: "Editando", target: fileName(first), style: .code)
        case "Gravando arquivo":
            return WorkLine(verb: "Gravando", target: fileName(first), style: .code)
        case "Listando pasta":
            return WorkLine(verb: "Abrindo a pasta", target: folderName(first), style: .code)
        case "Procurando arquivos":
            // A glob is code; a Spotlight query ("relatório de vendas": words, no pattern characters) is a phrase.
            let isQuery = first.map { $0.contains(" ") && !$0.contains(where: { "*?[".contains($0) }) } ?? false
            return WorkLine(verb: "Procurando", target: first, style: isQuery ? .quoted : .code)
        case "Buscando no conteúdo":
            return WorkLine(verb: "Procurando", target: first, style: .quoted)
        case "Lendo página":
            return WorkLine(verb: "Abrindo", target: host(of: first), style: .plain)
        case "Baixando arquivo":
            return WorkLine(verb: "Baixando de", target: host(of: first), style: .plain)
        case "Pesquisando na web":
            return WorkLine(verb: "Pesquisando", target: first, style: .quoted)
        case "Delegando a um subagente":
            return WorkLine(verb: "Delegando", target: first, style: .quoted)
        case "Atualizando a lista de tarefas":
            // The step under way ("Rodando os testes") says it all.
            return WorkLine(verb: first ?? call.title)
        default:
            if let name = exchangeTarget(call.title, verb: talkingVerb) { return talking(to: name) }
            if let name = exchangeTarget(call.title, verb: notifyingVerb) { return WorkLine(verb: notifyingVerb, target: name) }
            return WorkLine(verb: call.title)
        }
    }

    /// The verbs of a tool call that talks to another Orb: "Falando com Pesquisador" (`orbs` ask, tell).
    static let talkingVerb = "Falando com", notifyingVerb = "Avisando"

    /// The name in a title that starts with `verb` ("Falando com Pesquisador" → "Pesquisador"); nil for any other title.
    private static func exchangeTarget(_ title: String, verb: String) -> String? {
        guard title.hasPrefix(verb + " ") else { return nil }
        let name = title.dropFirst(verb.count + 1).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The Orb asks another Orb for something ("Falando com Pesquisador"), while its tool call runs.
    static func talking(to name: String) -> WorkLine {
        WorkLine(verb: talkingVerb, target: name, style: .plain)
    }

    /// The Orb waits for the answers it asked for after its turn ended: "Esperando Pesquisador", "Esperando Pesquisador e
    /// Revisor", "Esperando 3 Orbs". nil when it waits for none. `names` are the distinct Orbs it waits for.
    static func waiting(for names: [String]) -> WorkLine? {
        let target: String
        switch names.count {
        case 0: return nil
        case 1: target = names[0]
        case 2: target = names.joined(separator: " e ")
        default: target = "\(names.count) Orbs"
        }
        return WorkLine(verb: "Esperando", target: target, style: .plain)
    }

    /// The phrase for a status line the engines emit between and around tools ("Pensando", "Escrevendo", "Esperando
    /// sua resposta", the wait before a new try), or a tool's own title (a status that is not a call).
    static func line(status: String, now: Date = .now) -> WorkLine {
        if status == "Esperando sua resposta" { return WorkLine(verb: status, tone: .waiting) }
        if let wait = Retry.parseWaitStatus(status) {
            return WorkLine(verb: "\(wait.cause) · tentando de novo", tone: .retrying(until: now.addingTimeInterval(Double(wait.seconds))))
        }
        return WorkLine(verb: status)
    }

    // MARK: Pieces of a target

    /// The first line that says something, its white space collapsed to single spaces and cut when very long. The
    /// notes the tools add after a blank line ("em ~/x" for a command run elsewhere) are not the target.
    static func firstLine(of detail: String) -> String? {
        for line in detail.split(separator: "\n", omittingEmptySubsequences: true) {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty else { continue }
            let text = words.joined(separator: " ")
            return text.count > targetLimit ? String(text.prefix(targetLimit)) + "…" : text
        }
        return nil
    }

    /// "README.md" for "/Users/x/Projetos/Orb/README.md"; a name that is not a path stays as it is.
    static func fileName(_ path: String?) -> String? {
        guard let path else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// The folder's name, "~" for the home folder.
    static func folderName(_ path: String?) -> String? {
        guard let path else { return nil }
        let home = NSHomeDirectory()
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if trimmed == "~" || trimmed == home { return "~" }
        if trimmed == "." { return "." }
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? trimmed : name
    }

    /// "github.com" for "https://www.github.com/x/y"; what is not a URL stays as it is.
    static func host(of address: String?) -> String? {
        guard let address else { return nil }
        guard let host = URL(string: address)?.host(percentEncoded: false), !host.isEmpty else { return address }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - The meter next to the phrase

/// What the running turn has used so far, summed over its model calls: a turn has no step limit, so this is how the person
/// notices one that costs more than it should, while it runs.
struct TurnSpend: Equatable, Sendable {
    /// Every token of every call: the prompt (cached or not) and the reply.
    var tokens: Int
    /// What it cost at the provider's prices, when the model is billed by use and its price is known.
    var dollars: Double?

    init(tokens: Int, dollars: Double? = nil) {
        self.tokens = tokens
        self.dollars = dollars
    }

    init(_ usage: TokenUsage, dollars: Double? = nil) {
        let parts = [usage.input, usage.output, usage.cacheRead, usage.cacheWrite].map { $0 ?? 0 }
        self.init(tokens: parts.reduce(0) { sum, part in
            let (total, overflow) = sum.addingReportingOverflow(part)
            return overflow ? .max : total
        }, dollars: dollars)
    }

    /// From here on the meter says it: below, a turn costs too little to be worth a word.
    static let shownFrom = 50_000

    /// "180 mil tokens · US$ 0,42"; nil below `shownFrom`.
    var text: String? {
        guard tokens >= Self.shownFrom else { return nil }
        let said = UsageFormat.tokens(tokens)
        guard let dollars, dollars > 0 else { return said }
        return said + " · " + UsageFormat.dollars(dollars)
    }
}

enum WorkMeter {
    /// "16 s · 3 ações": how long the turn has gone on and how many actions it made. The clock is empty during the first
    /// second and the count appears from the second action: one is the line itself. `spend`: what the turn used, once it
    /// is enough to matter ("16 min · 140 ações · 2,1 milhões de tokens · US$ 3,10").
    static func text(elapsed: String, actions: Int, spend: TurnSpend? = nil) -> String {
        var parts: [String] = []
        if !elapsed.isEmpty { parts.append(elapsed) }
        if actions >= 2 { parts.append("\(actions) ações") }
        if let spent = spend?.text { parts.append(spent) }
        return parts.joined(separator: " · ")
    }

    /// "em 8 s": the wait before the new try, counting down; empty once it is over.
    static func countdown(until date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded(.up))
        return seconds > 0 ? "em \(ElapsedFormat.text(seconds: seconds))" : ""
    }
}

// MARK: - How long each phrase stays

/// Gives every phrase of the working line a minimum time on screen. A tool that takes 100 ms would otherwise pass
/// "Lendo → Pensando → Procurando → Pensando" in under a second, which nobody can read and everyone sees as a
/// flicker. A phrase that arrives sooner waits (only the newest is kept); the ones that matter right now do not: the
/// end of the turn, a wait for you and the first phrase of a turn.
struct StatusDwell: Sendable {
    enum Verdict: Equatable, Sendable {
        /// Show it now.
        case now
        /// Keep it for `instant`, when the phrase on screen has had its time.
        case at(ContinuousClock.Instant)
        /// Nothing to do.
        case unchanged
    }

    var minDwell: Duration
    /// What is on screen (nil: no turn) and since when.
    private(set) var shown: WorkLine?
    private var shownAt: ContinuousClock.Instant?
    /// The newest phrase that arrived too soon.
    private(set) var pending: WorkLine?

    init(minDwell: Duration) { self.minDwell = minDwell }

    /// When the pending phrase may come in (nil: none is waiting).
    var due: ContinuousClock.Instant? { pending == nil ? nil : shownAt.map { $0 + minDwell } }

    /// A phrase (nil: the turn ended) arrives at `now`.
    mutating func offer(_ line: WorkLine?, at now: ContinuousClock.Instant) -> Verdict {
        if line == shown {
            pending = nil // the newest one is the one already there
            return .unchanged
        }
        // Leaving a wait for you is as immediate as entering it: the answer was just given.
        guard let line, let shownAt, let current = shown, current.tone != .waiting, line.tone != .waiting else {
            return show(line, at: now)
        }
        let ready = shownAt + minDwell
        if now >= ready { return show(line, at: now) }
        pending = line
        return .at(ready)
    }

    /// The pending phrase, if its time has come; it is on screen from now on.
    mutating func release(at now: ContinuousClock.Instant) -> WorkLine? {
        guard let line = pending, let due, now >= due else { return nil }
        _ = show(line, at: now)
        return line
    }

    private mutating func show(_ line: WorkLine?, at now: ContinuousClock.Instant) -> Verdict {
        shown = line
        shownAt = line == nil ? nil : now
        pending = nil
        return .now
    }
}

// MARK: - Telling VoiceOver

/// Decides which phrases of the working line VoiceOver hears: only the ones that name something the Orb is doing (never
/// "Pensando" or "Escrevendo", which say nothing new), and not more often than `interval`, so a turn of many small
/// steps is not read aloud one by one.
struct WorkAnnouncer: Sendable {
    var interval: Duration
    private var last: ContinuousClock.Instant?

    init(interval: Duration = .seconds(8)) { self.interval = interval }

    mutating func shouldAnnounce(_ line: WorkLine, at now: ContinuousClock.Instant) -> Bool {
        guard line.isAnnounceable else { return false }
        if let last, now - last < interval { return false }
        last = now
        return true
    }

    /// A new turn starts counting from zero.
    mutating func reset() { last = nil }
}
