import Foundation

// The group's board as the panel's "Quadro" tab uses it (docs/historico/MULTI-ORBS.md, 7.7): the objective, the agreements the person
// writes and what the members saved, read from the group's memory bank. The panel reads `groupBoard`, a copy the app keeps up to
// date (`refreshGroupBoard` runs when the tab opens and after each change), so a view never waits on the bank.

extension AppModel {
    /// The board as last read; empty until `refreshGroupBoard` has run.
    func groupBoard(_ id: UUID) -> MemorySnapshot { groupBoards[id] ?? MemorySnapshot() }

    func refreshGroupBoard(_ id: UUID) async {
        guard group(id) != nil else { return }
        let snapshot = await memory.groupBank(for: id).snapshot()
        // The group may have been deleted while the bank was read: do not bring its board back into the dictionary.
        guard group(id) != nil else { return }
        groupBoards[id] = snapshot
    }

    /// Writes the objective (the board's identity note).
    func setGroupObjective(_ id: UUID, to text: String) {
        Task { await saveGroupObjective(text, of: id) }
    }

    /// The body of `setGroupObjective(_:to:)`: a refused or failed write says so (the field would otherwise look saved).
    func saveGroupObjective(_ text: String, of id: UUID) async {
        // A group deleted with the field still open (it saves on disappear) has nothing to say: no false "refused" notice.
        guard group(id) != nil else { return }
        if await !setGroupObjective(text, of: id), group(id) != nil {
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
    /// True when the page was forgotten (and can come back); false when it failed, after the notice, so no "Desfazer" is offered.
    @discardableResult
    func forgetGroupNote(_ item: MemorySnapshot.Item, of id: UUID) async -> Bool {
        guard group(id) != nil else { return false }
        let bank = memory.groupBank(for: id)
        let directory = bank.directory
        let path = item.path, title = item.title
        guard let forgotten = await Task.detached(operation: { ForgottenMemory.capture(path, title: title, in: directory) }).value,
              await bank.forget(path) else {
            addNotice(StoreNotice(message: Self.couldNotForget(title)))
            await refreshGroupBoard(id)
            return false
        }
        // The group may have gone meanwhile: keep nothing for it.
        guard group(id) != nil else { return false }
        forgottenGroupNotes[id, default: [:]][path] = forgotten
        // Few are kept: a board forgotten from all day does not hold every old page in memory (no date to tell the oldest).
        while let extra = forgottenGroupNotes[id]?.keys.first(where: { $0 != path }), (forgottenGroupNotes[id]?.count ?? 0) > 20 {
            forgottenGroupNotes[id]?[extra] = nil
        }
        await refreshGroupBoard(id)
        return true
    }

    func restoreGroupNote(_ item: MemorySnapshot.Item, of id: UUID) {
        guard group(id) != nil, let forgotten = forgottenGroupNotes[id]?[item.path] else { return }
        forgottenGroupNotes[id]?[item.path] = nil
        let bank = memory.groupBank(for: id)
        Task {
            await restoreForgotten(forgotten, in: bank)
            await refreshGroupBoard(id)
        }
    }
}
