import SwiftUI

/// `--snapshot` modes of the group screens (groups-sidebar, group-chat…). None yet: the package that builds them fills this in.
@MainActor
enum GroupSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? { nil }
}
