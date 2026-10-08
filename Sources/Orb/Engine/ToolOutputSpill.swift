import Foundation

// The files `ToolOutputCap` writes when a tool result is too big for the conversation. They live in the app's data
// folder (`saidas/<orb id>/`), not the system's temporary folder (which macOS empties on its own while the
// conversation keeps pointing at the files), and the app tidies them itself.

extension ToolOutputCap {
    /// Saved outputs older than this are deleted when the app starts.
    static let maxAge: TimeInterval = 14 * 24 * 3_600
    /// Most an Orb's saved outputs may take on disk; the oldest go first.
    static let maxBytesPerOrb = 200_000_000

    /// The folder of saved outputs inside the app's data folder (`Store.directory`).
    static func directory(inDataFolder dataFolder: URL) -> URL { dataFolder.appending(path: "saidas") }

    /// Deletes saved outputs older than `maxAge`, then the oldest of what is left of each Orb while it takes more
    /// than `maxBytesPerOrb`, and the Orb folders left empty. Returns how many files it deleted. Safe to run on a
    /// background queue; a folder that does not exist is nothing to do.
    @discardableResult
    static func cleanUp(directory: URL, maxAge: TimeInterval = ToolOutputCap.maxAge,
                        maxBytesPerOrb: Int = ToolOutputCap.maxBytesPerOrb, now: Date = .now) -> Int {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let folders = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        var deleted = 0
        for folder in folders {
            guard let entries = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { continue }
            var kept: [(url: URL, date: Date, size: Int)] = []
            for url in entries {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let date = values.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(date) > maxAge {
                    if (try? manager.removeItem(at: url)) != nil { deleted += 1 }
                } else {
                    kept.append((url, date, values.fileSize ?? 0))
                }
            }
            var total = kept.reduce(0) { $0 + $1.size }
            for file in kept.sorted(by: { $0.date < $1.date }) where total > maxBytesPerOrb {
                if (try? manager.removeItem(at: file.url)) != nil {
                    deleted += 1
                    total -= file.size
                }
            }
            if let left = try? manager.contentsOfDirectory(atPath: folder.path), left.isEmpty { try? manager.removeItem(at: folder) }
        }
        return deleted
    }

    /// Deletes every saved output of an Orb (when the Orb is deleted).
    static func removeAll(for botID: UUID, in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appending(path: botID.uuidString))
    }
}
