import Foundation

/// One line per Responses-API request for diagnosing prompt-cache misses (docs/REVISAO-TOKENS-2026-10-27.md):
/// a fingerprint of the request's segments next to the cached-token count the provider reported. Diffing
/// consecutive lines of one conversation shows the first input item that changed — where the provider's
/// cache stopped matching (`scripts/cache-probe-diff.py` does that diff). The file lives with the usage
/// rows (`uso/cache-probe-YYYY-MM.jsonl`), never leaves the Mac, and holds hashes and sizes, not text.
enum CacheProbe {
    /// The `uso` folder, set when the usage recorder exists; nil keeps the probe off (tests, early boot).
    /// Written once on the main actor at startup, read from request streams afterwards.
    nonisolated(unsafe) static var folder: URL?

    /// A hash that survives relaunches (Swift's `Hasher` is seeded per process): 64-bit FNV-1a as hex.
    static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// What repeated and what did not in one request body: sizes and hashes of `instructions`, the tool
    /// list, and each `input` item (tagged by its role or type, so position + kind identify it in a diff).
    /// No text, arguments or credentials are kept.
    static func fingerprint(of body: JSONValue) -> JSONValue {
        func segment(_ value: JSONValue?) -> [JSONValue] {
            let text = value?.jsonString ?? ""
            return [.number(Double(text.utf8.count)), .string(hash(text))]
        }
        // ChatGPT's gateway carries the tools as an `additional_tools` input item instead of `tools`.
        let tools = body["tools"]
            ?? body["input"]?.array?.first { $0["type"]?.string == "additional_tools" }?["tools"]
        let items = (body["input"]?.array ?? []).map { item -> JSONValue in
            let text = item.jsonString
            return .array([.string(item["type"]?.string ?? item["role"]?.string ?? "?"),
                           .number(Double(text.utf8.count)), .string(hash(text))])
        }
        return .object([
            "instr": .array(segment(body["instructions"])),
            "tools": .array([.number(Double(tools?.array?.count ?? 0))] + segment(tools)),
            "items": .array(items),
        ])
    }

    /// Appends one line to this month's file; the write happens off the caller's queue.
    static func record(fingerprint: JSONValue, model: String, conversation: String?, stop: StopReason?,
                       usage: TokenUsage?, now: Date = .now) {
        guard let folder else { return }
        var use: [String: JSONValue] = [:]
        if let input = usage?.input { use["in"] = .number(Double(input)) }
        if let cached = usage?.cacheRead { use["cached"] = .number(Double(cached)) }
        if let output = usage?.output { use["out"] = .number(Double(output)) }
        var fields: [String: JSONValue] = [
            "t": .number(now.timeIntervalSince1970.rounded()), "model": .string(model),
            "fp": fingerprint, "usage": .object(use),
        ]
        if let conversation { fields["conv"] = .string(conversation) }
        if let stop { fields["stop"] = .string("\(stop)") }
        let line = JSONValue.object(fields).jsonString + "\n"
        let file = Self.file(in: folder, at: now)
        Task.detached(priority: .utility) { append(line, to: file) }
    }

    /// `uso/cache-probe-2026-10.jsonl`, like the month files of the usage rows.
    static func file(in folder: URL, at date: Date, calendar: Calendar = .current) -> URL {
        folder.appending(path: "cache-probe-\(Store.usageMonthID(of: date, calendar: calendar)).jsonl")
    }

    private static func append(_ line: String, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                try Data(line.utf8).write(to: file, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // The probe may never cost a request or fill a log: it just stops recording.
        }
    }
}
