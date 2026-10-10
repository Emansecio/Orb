import Foundation

/// A group's board is a memory bank like an Orb's, in `memoria/_grupos/<groupID>/` (same folders and format; see `GroupBoard`).
/// The library's banks are keyed by id, and a group id never equals an Orb's.
extension MemoryLibrary {
    func groupDirectory(for id: UUID) -> URL {
        root.appending(path: GroupFiles.memoryFolder, directoryHint: .isDirectory).appending(path: id.uuidString)
    }

    /// The group's bank. After `deleteGroup` (or `seal`), a closed bank that writes nothing.
    func groupBank(for id: UUID) -> MemoryBank {
        state.withLock { state in
            if let bank = state.banks[id] { return bank }
            let bank = MemoryBank(directory: groupDirectory(for: id))
            if state.closed.contains(id) || state.isSealed { bank.close() } else { state.banks[id] = bank }
            return bank
        }
    }

    /// Deletes the group's board for good.
    func deleteGroup(_ id: UUID) {
        closeBank(id)
        try? FileManager.default.removeItem(at: groupDirectory(for: id))
    }
}
