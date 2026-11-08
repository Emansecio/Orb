import Foundation

// What the routine editor may save and what it writes: the `schedule` tool's limits applied to the screen too, and a save
// that touches only what the editor changed.

extension Routine {
    /// What saving the editor writes over the routine as it is now. Only what the editor itself changed (`edited` against
    /// `original`, the copy it opened with) is applied on `current`: the Orb may have changed the prompt, the precheck, the
    /// goal or the schedule through `schedule update` while the sheet was open, and the editor never shows `precheck` at all.
    static func merged(edited: Routine, original: Routine, current: Routine, now: Date = .now) -> Routine {
        var result = current
        if edited.name != original.name { result.name = edited.name }
        if edited.botID != original.botID { result.botID = edited.botID }
        if edited.prompt != original.prompt { result.prompt = edited.prompt }
        if edited.permissionMode != original.permissionMode { result.permissionMode = edited.permissionMode }
        if edited.schedule != original.schedule {
            // Count the next run from now, not from when the routine was created.
            result.schedule = edited.schedule
            result.createdAt = now
            result.lastRun = nil
        }
        // The last check measured the goal as it was: a new target starts unmeasured, an untouched one keeps its check.
        if edited.goal?.target != original.goal?.target { result.goal = edited.goal }
        return result
    }
}

extension RoutineText {
    /// `name` unless another of `taken` already has it (case and accents aside); then "name (2)", "name (3)"...
    static func freeName(_ name: String, taken: [String]) -> String {
        guard taken.contains(where: { $0.sameName(as: name) }) else { return name }
        var number = 2
        while taken.contains(where: { $0.sameName(as: "\(name) (\(number))") }) { number += 1 }
        return "\(name) (\(number))"
    }
}

extension AppModel {
    /// Why the editor may not save `routine` (nil: it may), with the same limits as the `schedule` tool. `original` is the
    /// routine as stored (nil for a new one): what it already had is not blocked again, so an older routine can still be
    /// edited. A blank name is not a clash: saving gives it a free one.
    func routineEditProblem(_ routine: Routine, original: Routine?) -> String? {
        let prompt = routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.count > ScheduleCommand.promptLimit, prompt != original?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) {
            return "O texto passa de \(ScheduleCommand.promptLimit) caracteres (tem \(prompt.count)). Encurte o que fazer."
        }
        let others = routines.filter { $0.botID == routine.botID && $0.id != routine.id }
        let movesIn = original == nil || original?.botID != routine.botID
        if movesIn, others.count >= Self.scheduledTaskLimit {
            return "Este Orb já tem \(Self.scheduledTaskLimit) rotinas. Apague alguma antes."
        }
        let name = routine.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let renamed = movesIn || original.map { !$0.name.sameName(as: name) } == true
        if !name.isEmpty, renamed, others.contains(where: { $0.name.sameName(as: name) }) {
            return "Este Orb já tem uma rotina chamada “\(name)”. Escolha outro nome."
        }
        return nil
    }

    /// The name the routine is saved with: what was typed, or the first words of the prompt, never one the Orb already uses.
    func routineSaveName(_ routine: Routine) -> String {
        let typed = routine.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = RoutineText.resolvedName(typed, prompt: routine.prompt)
        guard typed.isEmpty else { return resolved }
        let taken = routines.filter { $0.botID == routine.botID && $0.id != routine.id }.map(\.name)
        return RoutineText.freeName(resolved, taken: taken)
    }
}
