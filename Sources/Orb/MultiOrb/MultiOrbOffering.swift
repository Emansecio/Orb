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
    /// `group_recall` alone, in the Orb's own chat, for the boards of the groups it is in (`ToolContext.groupBoards`).
    var groupRecall = false
    /// `group_create`: in the Orb's own chat, with "Orbs podem acionar grupos" on.
    var groupCreate = false
    /// `ask_user`: only in an Orb's own chat, where the person is to answer (a routine or a request reports what it needs).
    var askUser = false
    /// The turn is a run nobody watches (a routine, a request from another Orb, a group's turn): `schedule` comes in its short
    /// form, since only listing and pausing work there.
    var sideRun = false
}
