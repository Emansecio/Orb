import Foundation

/// Which of the multi-Orb tools an Orb is offered in a turn (see `ToolBox.offered`). `orb_draft` is never here: it is only in
/// the creation assistant's own list.
struct MultiOrbOffering: Sendable, Equatable {
    /// `orbs`: the switch is on and there is at least one teammate, or the turn belongs to a group.
    var orbs = false
    /// `orb_propose`: only in an Orb's own chat (not in a routine, a request or a group turn).
    var propose = false
    /// `group_remember` and `group_recall`: only in a group's turn.
    var groupMemory = false
    /// `ask_user`: only in an Orb's own chat, where the person is to answer (a routine or a request reports what it needs).
    var askUser = false
}
