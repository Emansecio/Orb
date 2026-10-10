import SwiftUI

/// `--snapshot` modes of the exchange lines and the delegation screens (events, delegation-thread, delegation-exchange…).
/// None yet: the package that draws them fills this in.
@MainActor
enum DelegationSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? { nil }
}
