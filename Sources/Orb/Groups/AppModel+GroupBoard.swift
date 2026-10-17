import Foundation

// The group's board as the panel's "Quadro" tab uses it (docs/historico/MULTI-ORBS.md, 7.7): the objective, the agreements the person
// writes and what the members saved, read from the group's memory bank. The panel reads `groupBoard`, a copy the app keeps up to
// date (`refreshGroupBoard` runs when the tab opens and after each change), so a view never waits on the bank.

extension AppModel {
    /// The board as last read; empty until `refreshGroupBoard` has run.
    func groupBoard(_ id: UUID) -> MemorySnapshot { groupBoards[id] ?? MemorySnapshot() }

    func refreshGroupBoard(_ id: UUID) async {
        guard group(id) != nil else { return }
        groupBoards[id] = await memory.groupBank(for: id).snapshot()
    }

    /// Writes the objective (the board's identity note).
    func setGroupObjective(_ id: UUID, to text: String) {
        Task { await saveGroupObjective(text, of: id) }
    }

    /// The body of `setGroupObjective(_:to:)`: a refused or failed write says so (the field would otherwise look saved).
    func saveGroupObjective(_ text: String, of id: UUID) async {
        if await !setGroupObjective(text, of: id) {
            addNotice(StoreNotice(message: "Não consegui salvar o objetivo do grupo: o texto passa de \(MemoryBank.identityMaximumLength / 1000) mil caracteres ou a pasta não aceitou a gravação."))
        }
        await refreshGroupBoard(id)
    }

    /// Adds an agreement the person made: a preference of the board, written as theirs.
    func rememberGroupAgreement(_ id: UUID, text: String) {
        guard group(id) != nil else { return }
        Task { await saveGroupAgreement(text, of: id) }
    }

    /// The body of `rememberGroupAgreement(_:text:)`: a write that failed says so.
    func saveGroupAgreement(_ text: String, of id: UUID) async {
        if await memory.groupBank(for: id).remember(text, kind: .preferencia, origin: .voce) == .failed {
            addNotice(StoreNotice(message: "Não consegui salvar o combinado do grupo: a pasta não aceitou a gravação."))
        }
        await refreshGroupBoard(id)
    }

    /// "Esquecer" on the board; the page is kept for the "Desfazer" that follows.
    func forgetGroupNote(_ item: MemorySnapshot.Item, of id: UUID) {
        guard group(id) != nil else { return }
        let bank = memory.groupBank(for: id)
        let directory = bank.directory
        let path = item.path, title = item.title
        Task {
            guard let forgotten = await Task.detached(operation: { ForgottenMemory.capture(path, title: title, in: directory) }).value,
                  await bank.forget(path) else {
                addNotice(StoreNotice(message: Self.couldNotForget(title)))
                await refreshGroupBoard(id)
                return
            }
            forgottenGroupNotes[id, default: [:]][path] = forgotten
            await refreshGroupBoard(id)
        }
    }

    func restoreGroupNote(_ item: MemorySnapshot.Item, of id: UUID) {
        guard group(id) != nil, let forgotten = forgottenGroupNotes[id]?[item.path] else { return }
        forgottenGroupNotes[id]?[item.path] = nil
        let bank = memory.groupBank(for: id)
        let directory = bank.directory
        Task {
            _ = await Task.detached(operation: { forgotten.restore(in: directory) }).value
            await bank.reconcile()
            await refreshGroupBoard(id)
        }
    }
}
