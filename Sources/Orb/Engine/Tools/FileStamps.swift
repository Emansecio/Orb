import Foundation
import os

/// What an Orb last saw of each file it read or wrote (modification date and size), so that a write over a file someone else
/// changed since is refused instead of silently undoing their work. One per Orb, kept across its turns; `ToolContext.stamps`
/// carries it to `read_file`, `write_file` and `edit_file`. A file the Orb never read has no stamp and is written as before.
final class FileStamps: Sendable {
    struct Stamp: Equatable, Sendable {
        var modified: Date
        var size: Int
    }

    /// Past this many paths the oldest are forgotten (a forgotten file is simply written as if never read).
    static let limit = 500

    private struct State {
        var stamps: [String: Stamp] = [:]
        /// Oldest first, to know what to drop.
        var order: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The file's stamp now; nil when it does not exist or cannot be read.
    static func stamp(of url: URL) -> Stamp? {
        // Not `URL.resourceValues`: a URL object caches what it read, and the same one is used before and after a write.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Stamp(modified: modified, size: (attributes[.size] as? NSNumber)?.intValue ?? 0)
    }

    /// Remembers the file as it is now, or as `stamp` was taken before a read (a change during the read then shows up later).
    func record(_ url: URL, stamp: Stamp? = nil) {
        guard let stamp = stamp ?? Self.stamp(of: url) else { return }
        let key = url.path
        state.withLock { state in
            if state.stamps.updateValue(stamp, forKey: key) != nil { state.order.removeAll { $0 == key } }
            state.order.append(key)
            if state.order.count > Self.limit {
                let dropped = state.order.prefix(state.order.count - Self.limit)
                for path in dropped { state.stamps[path] = nil }
                state.order.removeFirst(dropped.count)
            }
        }
    }

    /// Throws when the Orb has seen this file and it is different now. Without a stamp, or when the file is gone (writing
    /// creates it), nothing is refused.
    func check(_ url: URL) throws {
        guard let known = state.withLock({ $0.stamps[url.path] }), let current = Self.stamp(of: url), current != known else { return }
        throw ToolError("\(url.path) changed since you last read it (another Orb or the user). Read it again before writing.")
    }
}
