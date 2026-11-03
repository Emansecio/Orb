import Foundation

extension GroupHub {
    /// A run of a group that shares a project folder ended: the members' worktrees whose branch is already in the project are
    /// removed; the others stay, and the thread says which, so the person (or the next request) can merge them.
    func cleanUpWorkFolders(of group: OrbGroup, run runID: UUID, session: GroupSession) {
        guard let model, !group.projectFolder.isEmpty else { return }
        let project = URL(fileURLWithPath: group.projectFolder)
        let root = WorkFolders.root(in: model.store.directory)
        Task { @MainActor in
            let report = await WorkFolders.cleanUp(project: project, run: runID, root: root)
            guard !report.kept.isEmpty else { return }
            let lines = report.kept.map { "\($0.branch) (\($0.path))" }.joined(separator: "; ")
            session.append(.notice("Ficaram ramos de trabalho sem merge em \(project.lastPathComponent): \(lines). "
                + "Junte com git merge ou apague com git worktree remove."))
        }
    }
}
