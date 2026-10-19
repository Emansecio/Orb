import Foundation

/// One line per model step of the Claude Code pipe, to measure how much of each request the prompt cache already had.
/// Numbers and enums only: nothing of the conversation is written.
struct ClaudePipeMetric: Sendable, Equatable {
    /// Why a step started a new process (nil for a step that continued a parked one).
    enum FreshReason: String, Sendable { case noParked, notContinuation, toolChoice }

    var timestamp: Date
    /// A short, stable tag of the conversation (see `tag(of:)`), when the client knows one.
    var conversation: String?
    var model: String
    var fresh: FreshReason?
    var messageCount: Int
    var characterCount: Int
    var usage: TokenUsage?

    /// The 8 hex digits of an FNV-1a hash: groups the steps of a conversation without exposing its id.
    static func tag(of id: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(format: "%08x", hash)
    }

    /// The JSON line (sorted keys, no newline).
    var line: String {
        var object: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: timestamp), "model": model, "plan": fresh == nil ? "resume" : "fresh",
            "messages": messageCount, "chars": characterCount,
        ]
        if let conversation { object["conv"] = conversation }
        if let fresh { object["reason"] = fresh.rawValue }
        if let usage {
            if let input = usage.input { object["input"] = input }
            if let cacheRead = usage.cacheRead { object["cacheRead"] = cacheRead }
            if let cacheWrite = usage.cacheWrite { object["cacheWrite"] = cacheWrite }
            if let cacheWrite1h = usage.cacheWrite1h { object["cacheWrite1h"] = cacheWrite1h }
            if let output = usage.output { object["output"] = output }
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Appends `ClaudePipeMetric` lines to a file, off the main thread, and starts over (keeping one `.1` copy) past `limit` bytes.
/// Every failure is silent: measuring must never get in the way of a turn.
final class ClaudePipeMetricsLog: @unchecked Sendable {
    static let defaultLimit = 2 * 1024 * 1024

    private let file: URL
    private let limit: Int
    private let queue = DispatchQueue(label: "orb.claude-pipe.metrics", qos: .utility)

    init(file: URL, limit: Int = ClaudePipeMetricsLog.defaultLimit) {
        self.file = file
        self.limit = limit
    }

    func record(_ metric: ClaudePipeMetric) {
        let line = metric.line + "\n"
        queue.async { Self.append(line, to: self.file, limit: self.limit) }
    }

    /// Blocks until what was recorded is written (tests).
    func flush() { queue.sync {} }

    static func append(_ line: String, to file: URL, limit: Int) {
        let fileManager = FileManager.default
        let size = (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size >= limit {
            let old = file.appendingPathExtension("1")
            try? fileManager.removeItem(at: old)
            try? fileManager.moveItem(at: file, to: old)
        }
        guard let data = line.data(using: .utf8) else { return }
        if !fileManager.fileExists(atPath: file.path) {
            try? fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            fileManager.createFile(atPath: file.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
