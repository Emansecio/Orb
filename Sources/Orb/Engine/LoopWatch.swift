import Foundation

/// Notices a turn going in circles by counting, without asking any model: the same call getting the same result again,
/// or one failure after another. Every `repeats` times either happens, the step's last result says so, so the model
/// changes course or asks, instead of spending the turn's steps on what does not work.
struct LoopWatch: Sendable {
    static let repeats = 3
    static let repeatingNote = "[Orb: você fez esta mesma chamada \(repeats) vezes e recebeu o mesmo resultado; repetir não muda nada. "
        + "Tente outro caminho ou, se está esperando algo ou travado, pare e diga ao usuário o que falta]"
    static let failingNote = "[Orb: as últimas \(repeats) chamadas de ferramenta falharam. Não repita o que falhou: entenda por quê e "
        + "tente outro caminho, ou diga ao usuário o que te bloqueia e pergunte]"

    /// Times each call (tool, arguments and result) was seen this turn, by its hash.
    private var seen: [Int: Int] = [:]
    private var failures = 0
    private var pending: String?

    /// Counts one call and what it gave back (the tool's own text, before any note or cap). `live`: the call looks at
    /// something that changes by itself (`isLive`), where the same words come back while it moves: only its failures count.
    mutating func record(_ call: ToolCallRequest, result: String, failed: Bool, live: Bool = false) {
        failures = failed ? failures + 1 : 0
        if failed, failures % Self.repeats == 0 {
            pending = Self.failingNote
            return
        }
        guard failed || !live else { return }
        var hasher = Hasher()
        hasher.combine(call.name)
        hasher.combine(call.arguments)
        hasher.combine(Self.steady(result))
        let key = hasher.finalize()
        let times = seen[key, default: 0] + 1
        seen[key] = times
        if times % Self.repeats == 0 { pending = Self.repeatingNote }
    }

    /// Whether a tool drives the browser page or a Mac app ("Scrolled down 600 px." again while the page moves), or reads
    /// a job that is still running (its log may stay quiet for minutes, and past one its time reads "rodando há 2 min"
    /// at every poll of that minute). Fetching a page (`web_fetch`) is no such tool: the same URL gives the same page.
    static func isLive(_ tool: String, kind: ToolCall.Kind?) -> Bool {
        tool.hasPrefix("browse_") || kind == .computer || tool == "job_output"
    }

    /// `result` without what changes on every run of the same thing: the path of a saved output (a new one each call),
    /// timestamps, clock times, IDs and "took 1.2 s".
    static func steady(_ result: String) -> String {
        guard result.utf16.count <= steadyLimit else { return result }
        let text = NSMutableString(string: result)
        for volatile in volatiles {
            volatile.replaceMatches(in: text, range: NSRange(location: 0, length: text.length), withTemplate: "…")
        }
        return text as String
    }

    /// Longer results are compared as they are: rewriting them costs more than a loop they might hide.
    private static let steadyLimit = 100_000
    private static let volatiles = [
        #"\[full output saved at [^\]\n]*\]"#,
        #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#,
        #"\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?"#,
        #"\b\d{1,2}:\d{2}:\d{2}(\.\d+)?\b"#,
        #"(?i)\b(took|elapsed|duration|in|real|user|sys)\b\s*[:=]?\s*(\d+m)?\d+(\.\d+)?\s*(ms|s)\b"#,
        #"(?i)\b(request|call|trace)[_-]?id\b\W+[\w-]+"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// What to tell the model after the calls recorded since the last time, if anything (told once).
    mutating func note() -> String? {
        defer { pending = nil }
        return pending
    }
}
