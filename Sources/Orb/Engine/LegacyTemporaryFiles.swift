import Foundation

/// Files in `$TMPDIR` that the old Claude Code engine wrote and nothing writes anymore.
enum LegacyTemporaryFiles {
    private static let mcpConfigPrefix = "orb-mcp-"

    /// Deletes the connector configs (`orb-mcp-*.json`, with the connectors' tokens) that the old Claude Code engine
    /// left behind when the app quit or crashed during a turn. A config named for a process (`orb-mcp-p<pid>-…`) goes when
    /// that process is gone: one whose app (an older copy) is still running is never touched. Names without a process go
    /// once untouched for `olderThan` seconds. Returns how many it deleted.
    @discardableResult
    static func removeStaleMCPConfigs(in directory: URL = FileManager.default.temporaryDirectory, olderThan: TimeInterval = 120,
                                      now: Date = .now, isRunning: (pid_t) -> Bool = LegacyTemporaryFiles.isRunning) -> Int {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var deleted = 0
        for url in files where url.lastPathComponent.hasPrefix(mcpConfigPrefix) && url.pathExtension == "json" {
            let stale: Bool
            if let pid = owner(of: url.lastPathComponent) {
                stale = !isRunning(pid)
            } else {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                stale = now.timeIntervalSince(date) > olderThan
            }
            if stale, (try? manager.removeItem(at: url)) != nil { deleted += 1 }
        }
        return deleted
    }

    /// The process named in `orb-mcp-p<pid>-<uuid>.json`, if the name has one.
    private static func owner(of fileName: String) -> pid_t? {
        let rest = fileName.dropFirst(mcpConfigPrefix.count)
        guard rest.hasPrefix("p"), let dash = rest.firstIndex(of: "-") else { return nil }
        return pid_t(rest[rest.index(after: rest.startIndex)..<dash])
    }

    private static func isRunning(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
