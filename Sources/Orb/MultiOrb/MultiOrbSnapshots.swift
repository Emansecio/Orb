import SwiftUI

/// The `--snapshot` modes of the multi-Orb features. Each package registers its modes in its own file (an enum with
/// `view(_:model:)` returning nil for a screen that is not its own); this is the one place that chains them, so adding a mode
/// never touches `Snapshot.render`.
@MainActor
enum MultiOrbSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
        // MARK: one line per package (each package fills in its own enum, in its own file)
        DelegationSnapshots.view(screen, model: model)
            ?? CreationSnapshots.view(screen, model: model)
            ?? WizardSnapshots.view(screen, model: model)
            ?? GroupSnapshots.view(screen, model: model)
            ?? MultiOrbSnapshotsFinal.view(screen, model: model)
    }
}
