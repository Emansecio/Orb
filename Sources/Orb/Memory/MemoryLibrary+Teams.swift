import Foundation

/// A Team's live board lives inside `times/<teamID>/quadro/`, keyed in `MemoryLibrary` by Team UUID.
extension MemoryLibrary {
    func teamDirectory(for id: UUID) -> URL {
        root.deletingLastPathComponent()
            .appending(path: TeamFiles.rootFolder, directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
            .appending(path: TeamFiles.boardFolder, directoryHint: .isDirectory)
    }

    func teamBank(for id: UUID) -> MemoryBank {
        state.withLock { state in
            if let bank = state.banks[id] { return bank }
            let bank = MemoryBank(directory: teamDirectory(for: id))
            if state.closed.contains(id) || state.isSealed { bank.close() } else { state.banks[id] = bank }
            return bank
        }
    }

    func deleteTeam(_ id: UUID) {
        closeBank(id)
        try? FileManager.default.removeItem(at: teamDirectory(for: id))
    }
}
