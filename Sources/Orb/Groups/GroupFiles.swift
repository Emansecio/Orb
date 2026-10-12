import Foundation

/// Where a group keeps its files in the data folder (see docs/historico/MULTI-ORBS.md, 2.7).
enum GroupFiles {
    /// `conversations/_grupos/<groupID>.json`: the group's thread. `memoria/_grupos/<groupID>/`: its board.
    static let threadFolder = "_grupos"
    static let memoryFolder = "_grupos"
    /// `conversations/<Orb>/grupo-<groupID>.json`: a member's own conversation in the group.
    static let sidePrefix = "grupo-"
}
