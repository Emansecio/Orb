import SwiftUI

/// `--snapshot` modes of the "Criar conversando" assistant (wizard…). None yet: the package that builds it fills this in.
@MainActor
enum WizardSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? { nil }
}
