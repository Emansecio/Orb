import Foundation
import os

/// The text of the last few Word, Excel and PowerPoint files `read_file` converted: reading a long one in pages
/// (`offset`) converts it once instead of for every page (a workbook is several `unzip` runs and a parse of all its XML).
/// A file that changes (date or size) is converted again.
final class DocumentTextCache: Sendable {
    static let shared = DocumentTextCache()

    struct Key: Hashable, Sendable {
        var path: String
        var modified: Date
        var size: Int

        /// The key for the file now, nil when its date cannot be read (then nothing is cached).
        init?(_ url: URL, size: Int) {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            (path, self.modified, self.size) = (url.path, modified, size)
        }
    }

    static let capacity = 6
    /// All the cached text together stays under this, so a few huge documents are not kept in memory.
    static let characterBudget = 50_000_000

    private let entries = OSAllocatedUnfairLock<[(key: Key, text: String)]>(initialState: [])

    /// The cached text for `key`, or `load()`'s, which is then kept. `load` runs outside the lock (it can take seconds).
    func text(for key: Key?, load: () throws -> String) throws -> String {
        guard let key else { return try load() }
        let hit = entries.withLock { entries -> String? in
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            let found = entries.remove(at: index)
            entries.append(found)   // most recently used last
            return found.text
        }
        if let hit { return hit }
        let text = try load()
        entries.withLock { entries in
            // The older version of the same file is stale now.
            entries.removeAll { $0.key.path == key.path }
            guard text.utf8.count <= Self.characterBudget else { return }
            entries.append((key, text))
            var total = entries.reduce(0) { $0 + $1.text.utf8.count }
            while entries.count > Self.capacity || total > Self.characterBudget, !entries.isEmpty {
                total -= entries.removeFirst().text.utf8.count
            }
        }
        return text
    }

    func clear() { entries.withLock { $0.removeAll() } }
}
