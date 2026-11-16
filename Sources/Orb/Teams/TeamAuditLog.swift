import Foundation

/// Auditable record written to `times/<teamID>/audit.jsonl` for every command, edit, review, gate rejection,
/// loop recovery, merge, pause, or completion during autonomous Team execution.
struct TeamAuditEntry: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case command
        case fileEdit
        case merge
        case review
        case gateRejected
        case loopRecovery
        case escalation
        case paused
        case resumed
        case completed
        case unknown

        init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .unknown) }
    }

    var id = UUID()
    var timestamp = Date.now
    var teamID: UUID
    var memberID: UUID?
    var memberName: String
    var kind: Kind
    var summary: String
    var detail = ""
    var commit = ""
}

extension TeamAuditEntry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        timestamp = try c.value(.timestamp, default: Date.now)
        teamID = try c.value(.teamID, default: UUID())
        memberID = try c.decodeIfPresent(UUID.self, forKey: .memberID)
        memberName = try c.value(.memberName, default: "")
        kind = try c.value(.kind, default: .unknown)
        summary = try c.value(.summary, default: "")
        detail = try c.value(.detail, default: "")
        commit = try c.value(.commit, default: "")
    }
}

/// Appends and reads `times/<teamID>/audit.jsonl` safely off the main actor.
enum TeamAuditLog {
    private static let maxTailEntries = 200

    static func append(_ entry: TeamAuditEntry, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(line.utf8)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: url, options: .atomic)
        }
    }

    static func readRecent(from url: URL, limit: Int = maxTailEntries) -> [TeamAuditEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit)
        return lines.compactMap { line in
            try? decoder.decode(TeamAuditEntry.self, from: Data(line.utf8))
        }
    }
}
