import Foundation

// How much history one request may carry: the model's window minus what every request carries anyway (the system
// prompt, the tool specs, room for the reply), capped so that models with huge windows are not fed all of it.

// MARK: - Memory level

/// How much conversation an Orb remembers word for word before the beginning is folded into a summary
/// ("Contexto das conversas" in the settings). More is not always better: every message is billed with all of it, and
/// models answer worse from a very long context.
enum ContextMemoryLevel: String, Codable, CaseIterable, Sendable {
    /// Up to 40 thousand tokens of history.
    case economical
    /// Up to 80 thousand tokens of history.
    case balanced
    /// Up to 60% of the model's window, never less than `balanced`.
    case wide

    init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .balanced) }

    var label: String {
        switch self {
        case .economical: "Econômico"
        case .balanced: "Equilibrado"
        case .wide: "Amplo"
        }
    }

    var summary: String {
        switch self {
        case .economical: "Lembra até ~40 mil tokens palavra por palavra. Gasta menos."
        case .balanced: "Lembra até ~80 mil tokens palavra por palavra. Custo e contexto em equilíbrio."
        case .wide: "Usa até 60% da janela do modelo. Mais contexto, mais custo."
        }
    }

    /// The most history tokens this level allows in a window of `window` tokens.
    func cap(window: Int) -> Int {
        switch self {
        case .economical: 40_000
        case .balanced: 80_000
        // In a window under ~133k tokens 60% is less than the balanced cap: "wide" never gives less.
        case .wide: max(ContextMemoryLevel.balanced.cap(window: window), Int(Double(window) * ContextBudget.wideShare))
        }
    }
}

// MARK: - Budget

/// How much conversation history one request may carry, estimated in tokens (characters / 3.5).
struct ContextBudget: Sendable, Equatable {
    static let charactersPerToken = 3.5
    /// Share of the window that is ever planned for: the rest is slack for the error of the estimate.
    static let windowShare = 0.9
    /// What `ContextMemoryLevel.wide` takes of the window.
    static let wideShare = 0.6
    /// A window past this is taken as this: no model has one that large, and a catalog that says so is wrong (and its
    /// arithmetic would overflow).
    static let largestWindow = 50_000_000
    /// History never gets less than this, however crowded the window is.
    static let minimumTokens = 2_000
    /// System prompt plus tool specs of an ordinary Orb (about 1,250 and 6,900 tokens measured), for callers that
    /// do not know them yet. The engine measures the real ones (`refined(overheadTokens:)`).
    static let typicalOverheadTokens = 8_000
    /// Where a compaction that was triggered stops: the history is brought down to this share of the budget, so
    /// the next compactions come after a good many messages instead of at every one (each one rewrites the
    /// provider's prompt cache).
    static let defaultLowWater = 0.5
    /// A small budget (a local model with a small window) cannot spare half of itself, and the summary takes its
    /// own room: below `smallBudgetTokens` the low-water mark is higher.
    static let smallBudgetLowWater = 0.75
    static let smallBudgetTokens = 12_000
    /// The same for a long task that alone outgrows the window (steps are set aside, newest ones kept).
    static let defaultStepsLowWater = 0.6
    /// Old stretches are condensed in a batch once that would save this share of the budget.
    static let condenseShare = 0.08
    /// Providers keep the start of a request in cache for about this long (seconds) after the last call: past it the
    /// next request pays for the whole history anyway.
    static let cacheColdAfter: TimeInterval = 300
    /// Claude Code (subscription) caches the whole history for 1 h, not 5 min: between the two the cache is still warm
    /// and folding early would rewrite tens of thousands of tokens at twice the input price. A margin under the hour
    /// covers clock differences.
    static let claudeCodeCacheColdAfter: TimeInterval = 3_300
    /// With a cold cache the history is folded to the low-water mark once it passes this share of the budget.
    static let coldFoldShare = 0.6

    /// How long without a call makes the provider's cache of the history cold (see `cacheColdAfter`); longer for
    /// Claude Code.
    var coldAfter: TimeInterval = ContextBudget.cacheColdAfter
    /// Tokens of history: the level at which a compaction starts.
    var tokens: Int
    /// The model's whole window, when known.
    var window: Int?
    /// Tokens every request carries besides the history (system prompt and tool specs).
    var overheadTokens: Int
    /// Tokens kept free for the reply.
    var replyTokens: Int
    var level: ContextMemoryLevel
    /// Set to override the low-water mark (a manual compaction goes lower).
    var lowWaterShare: Double?
    var stepsLowWater = ContextBudget.defaultStepsLowWater

    var lowWater: Double {
        lowWaterShare ?? (tokens < Self.smallBudgetTokens ? Self.smallBudgetLowWater : Self.defaultLowWater)
    }

    /// A window from this size up gives the model's notes in the summary their wide room.
    static let wideNotesWindow = 64_000

    /// Characters the summary may spend on the model's notes of folded stretches (`ConversationLedger.render`): one note
    /// in a small window (a local model), three where the window can spare ~2 thousand tokens. It goes by the window, which
    /// a budget made smaller for one fit (a manual compaction, room for the message) keeps.
    var digestRoom: Int {
        (window ?? tokens) >= Self.wideNotesWindow ? ConversationLedger.wideDigestRoom : ConversationLedger.digestRoom
    }

    /// Share of the budget the whole outputs of a task in progress may take before the oldest become previews
    /// (`ContextWindow.freshShare`). 1 for Claude Code: there a preview in the middle of a task changes what the parked
    /// process was sent, the process is dropped and the new one writes the whole prompt to the cache again. Measured in
    /// 12 days of use: 164 of the 250 processes dropped with one alive were this (the request about 24 thousand
    /// characters shorter, 17 s after the step before), 11.7 M tokens written again; a preview saves a tenth of its size
    /// at each later step and the new process costs 1.25 times the whole prompt, so it only pays back after some 50
    /// steps. The outputs still become previews when the task crowds the window, and at the next turn.
    var freshShare = ContextWindow.freshShare

    /// Characters a token of this model takes, as its own answers measured it (`LearnedDensity`); `charactersPerToken`
    /// until enough of them were seen. The history is cut by characters, so this is what makes "80 thousand tokens" be
    /// 80 thousand of the model's tokens and not of an average one's.
    var density = ContextBudget.charactersPerToken

    var characters: Int { Int(min(Double(tokens) * density, Double(Int.max / 4))) }

    /// Used when nothing is known about the model.
    static let fallback = ContextBudget(modelWindow: 128_000)

    /// A budget of exactly `tokens` of history (tests, and callers that know better).
    init(tokens: Int) {
        self.tokens = max(tokens, 500)
        window = nil
        overheadTokens = 0
        replyTokens = 0
        level = .balanced
    }

    /// `modelWindow`: the model's whole context window in tokens.
    init(modelWindow: Int, overheadTokens: Int = ContextBudget.typicalOverheadTokens, replyTokens: Int? = nil,
         level: ContextMemoryLevel = .balanced) {
        let reply = replyTokens ?? Self.replyTokens(window: modelWindow, format: nil)
        tokens = Self.historyTokens(window: modelWindow, overhead: overheadTokens, reply: reply, level: level)
        window = modelWindow
        self.overheadTokens = overheadTokens
        self.replyTokens = reply
        self.level = level
    }

    /// The model's reported window when known, else a default for its wire format (local servers run small windows).
    /// `format`: the account's own wire format, used when the model is not in its catalog (custom gateways).
    /// `learnedWindow`: what a refusal of this model once showed its window really is; it wins when smaller.
    init(model: ProviderModel?, provider: ProviderKind, format: APIFormat? = nil, level: ContextMemoryLevel = .balanced,
         learnedWindow: Int? = nil) {
        let wire = model?.format ?? format ?? (provider == .anthropic ? .messages : provider == .claudeCode ? .claudeCode : .chat)
        var window: Int
        if let known = model?.contextLength, known > 0 {
            window = known
        } else if provider == .ollama || provider == .lmstudio {
            window = 16_000
        } else {
            switch wire {
            case .chat, .responses: window = 128_000
            case .messages, .claudeCode: window = 200_000
            }
        }
        if let learnedWindow, learnedWindow > 0 { window = min(window, learnedWindow) }
        self.init(modelWindow: window, replyTokens: Self.replyTokens(window: window, format: wire), level: level)
        if provider == .claudeCode || wire == .claudeCode {
            coldAfter = Self.claudeCodeCacheColdAfter
            freshShare = 1
        }
    }

    /// Room for the reply: up to 16,000 output tokens in the Messages format, which sends it as its cap (see
    /// `ProviderAccount.client`); the others need less.
    static func replyTokens(window: Int, format: APIFormat?) -> Int {
        let wanted = format == .messages || format == .claudeCode ? 16_000 : 4_000
        return min(wanted, window / 8)
    }

    /// 90% of the window, minus what each request carries besides the history, capped by the memory level and kept
    /// above the minimum.
    static func historyTokens(window: Int, overhead: Int, reply: Int, level: ContextMemoryLevel) -> Int {
        let window = min(window, largestWindow)
        let free = Int(Double(window) * windowShare) - overhead - reply
        return max(minimumTokens, min(free, level.cap(window: window)))
    }

    /// Whether what each request carries besides the history (system prompt, tool specs, room for the reply) leaves it
    /// less than its minimum: then a refusal is about the Orb's instructions and tools, not about the conversation.
    var isCrowded: Bool {
        guard let window else { return false }
        return Int(Double(min(window, Self.largestWindow)) * Self.windowShare) - overheadTokens - replyTokens < Self.minimumTokens
    }

    /// What a refused request says when the window is crowded (`isCrowded`): shrinking the history cannot help.
    var crowdedFailure: String {
        func thousands(_ tokens: Int) -> String { tokens >= 1_000 ? "\(tokens / 1_000) mil" : "\(tokens)" }
        return "As instruções e as ferramentas deste Orb (cerca de \(thousands(overheadTokens)) tokens) quase enchem a janela de "
            + "\(thousands(window ?? 0)) tokens deste modelo, e não sobra espaço para a conversa. Use um modelo com janela maior "
            + "ou desligue ferramentas e conectores deste Orb."
    }

    /// The same budget once the real overhead of the request (its system prompt and tool specs) is known.
    func refined(overheadTokens: Int) -> ContextBudget {
        guard let window else { return self }
        var copy = self
        copy.overheadTokens = overheadTokens
        copy.tokens = Self.historyTokens(window: window, overhead: overheadTokens, reply: replyTokens, level: level)
        return copy
    }

    /// The same budget for a window of `window` tokens (what a refusal revealed).
    func resized(window newWindow: Int) -> ContextBudget {
        var copy = self
        copy.window = newWindow
        copy.replyTokens = min(replyTokens, max(newWindow / 8, 0))
        copy.tokens = Self.historyTokens(window: newWindow, overhead: overheadTokens, reply: copy.replyTokens, level: level)
        return copy
    }

    /// The same budget with room left for `characters` the request carries besides the history (the new message and
    /// what goes before it). Never less than half of it.
    func leavingRoom(forCharacters characters: Int) -> ContextBudget {
        guard characters > 0 else { return self }
        var copy = self
        copy.tokens = max(tokens - Self.tokens(forCharacters: characters), tokens / 2)
        return copy
    }

    func scaled(by factor: Double) -> ContextBudget {
        var copy = self
        copy.tokens = max(Int(Double(tokens) * factor), 500)
        return copy
    }

    /// Estimated tokens of `characters`.
    static func tokens(forCharacters characters: Int) -> Int { Int((Double(characters) / charactersPerToken).rounded(.up)) }

    /// Characters of a request's system prompt and tool specs.
    static func overheadCharacters(system: String, specs: [ToolSpec]) -> Int {
        system.count + specs.reduce(0) { $0 + $1.name.count + $1.description.count + $1.parameters.jsonString.count }
    }

    /// Estimated tokens of a request's system prompt and tool specs, at `density` characters a token.
    static func overheadTokens(system: String, specs: [ToolSpec], density: Double = charactersPerToken) -> Int {
        Int((Double(overheadCharacters(system: system, specs: specs)) / density).rounded(.up))
    }
}

// MARK: - What the answers taught

/// How many characters a token of a model really takes, learned from what its provider said each request used against
/// the characters the request had. The budget counts 3.5 for every model, and a model whose tokens are shorter (Claude's,
/// on text with accents, JSON and code) was kept at a history a good deal larger than the level chosen.
struct LearnedDensity: Codable, Sendable, Equatable {
    var charactersPerToken: Double
    var samples: Int

    /// Requests under this are mostly system prompt and tool specs, whose JSON is denser than a conversation.
    static let minimumPromptTokens = 8_000
    /// Seen this many times before the budget believes it.
    static let trustedSamples = 5
    /// Each request moves the value this much of the way to what it measured.
    static let weight = 0.1
    /// What the budget takes: never above the estimate it always used (so no history grows past what was sent before), and
    /// not under 2.2 (a request that is mostly pictures or base64 says little about text).
    static let range = 2.2...ContextBudget.charactersPerToken

    /// The value after one more request of `characters` that the provider counted as `promptTokens`; nil when the
    /// request is too small to say anything or the numbers make no sense.
    static func learning(_ known: LearnedDensity?, characters: Int, promptTokens: Int) -> LearnedDensity? {
        guard promptTokens >= minimumPromptTokens, characters > 0 else { return nil }
        let measured = Double(characters) / Double(promptTokens)
        guard (1.0...8.0).contains(measured) else { return nil }
        guard let known else { return LearnedDensity(charactersPerToken: measured, samples: 1) }
        return LearnedDensity(charactersPerToken: known.charactersPerToken + (measured - known.charactersPerToken) * weight,
                              samples: min(known.samples + 1, 1_000_000))
    }

    /// What the budget uses, or nil while too few requests were seen. In steps of 0.05: the value drifts a little with
    /// every request, and a budget that moved each time would move where the history is cut (and the provider's cache).
    var trusted: Double? {
        guard samples >= Self.trustedSamples else { return nil }
        let stepped = (charactersPerToken * 20).rounded() / 20
        return min(max(stepped, Self.range.lowerBound), Self.range.upperBound)
    }
}

// MARK: - What a refusal taught

/// The real window of a model, learned from the provider refusing a request for its size.
struct LearnedContext: Codable, Sendable, Equatable {
    var tokens: Int
    var date: Date
    /// The refusal named no window: `tokens` is only a share of the one assumed (nil = recorded before this was tracked).
    var inferred: Bool?

    /// A learned window is kept for this long, then forgotten: the user may since have raised the server's setting.
    static let lifetime: TimeInterval = 21 * 24 * 3_600
    /// A guess is kept for less: the window may have been right all along and only the estimate wrong.
    static let inferredLifetime: TimeInterval = 7 * 24 * 3_600

    func isFresh(at now: Date = .now) -> Bool {
        now.timeIntervalSince(date) < (inferred == true ? Self.inferredLifetime : Self.lifetime)
    }
}

extension ContextOverflow {
    /// The window size a provider's refusal states ("maximum context length is 8192 tokens", "prompt is too long:
    /// 213456 tokens > 200000 maximum"), or nil when it gives no number.
    /// Each pattern captures the window in its last group; the first one that matches wins.
    private static let windowExpressions: [NSRegularExpression] = [
        #"maximum context length (?:is|of)? ?(\d{4,8})"#,
        #"\d{4,8} tokens? ?> ?(\d{4,8})"#,
        #"context (?:length|window|size)(?: limit)?[:=]? ?(?:is |of )?(?:only )?(\d{4,8})"#,
        #"n_ctx(?:_seq)? ?[=:] ?(\d{4,8})"#,
        #"(?:limit|maximum|max)(?: is| of|:|=)? ?(\d{4,8}) tokens"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func reportedWindow(_ error: Error) -> Int? {
        let message: String
        switch error {
        case LLMError.contextExceeded(let text): message = text
        case LLMError.http(_, let text, _): message = text
        case LLMError.invalidResponse(let text): message = text
        case LLMError.stream(_, let text): message = text
        default: return nil
        }
        return reportedWindow(in: message)
    }

    static func reportedWindow(in message: String) -> Int? {
        // "128,000" and "128_000" read as one number.
        let text = message.lowercased().replacingOccurrences(of: #"(?<=\d)[,_](?=\d{3})"#, with: "", options: .regularExpression)
        for regex in windowExpressions {
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges > 1, let range = Range(match.range(at: match.numberOfRanges - 1), in: text),
                  let value = Int(text[range]), (1_000...10_000_000).contains(value) else { continue }
            return value
        }
        return nil
    }
}
