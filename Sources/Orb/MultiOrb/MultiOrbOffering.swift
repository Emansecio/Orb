import Foundation

/// Which of the multi-Orb tools an Orb is offered in a turn (see `ToolBox.offered`). `orb_draft` is never here: it is only in
/// the creation assistant's own list.
struct MultiOrbOffering: Sendable, Equatable {
    /// `orbs`: the switch is on and there is at least one teammate, or the turn belongs to a group.
    var orbs = false
    /// `orb_propose`: in an Orb's own chat; with "Orbs agem por conta própria" also in a routine, a request and a group's turn
    /// (its orchestrator).
    var propose = false
    /// `group_remember` and `group_recall`: only in a group's turn.
    var groupMemory = false
    /// `group_recall` alone, in the Orb's own chat, for the boards of the groups it is in (`ToolContext.groupBoards`).
    var groupRecall = false
    /// `group_create`: with "Orbs podem acionar grupos" on, in the Orb's own chat; with "Orbs agem por conta própria" also in a
    /// routine, a request and a group's turn (its orchestrator).
    var groupCreate = false
    /// `group_edit`: with "Orbs organizam os grupos" on, in every kind of turn, when there is a group or a second Orb to put in one;
    /// in a group's turn, for its orchestrator.
    var groupEdit = false
    /// `orb_delete`: with "Orbs organizam o time" on, in every kind of turn, when there is a second Orb; in a group's turn, for
    /// its orchestrator. Every call asks the user.
    var orbDelete = false
    /// `ask_user`: only in an Orb's own chat, where the person is to answer (a routine or a request reports what it needs).
    var askUser = false
    /// `request_access`: only in an Orb's own chat, for the same reason as `askUser`: the person is there to click the card.
    var access = false
    /// The turn is a run nobody watches (a routine, a request from another Orb, a group's turn): `schedule` comes in its short
    /// form, since only listing and pausing work there.
    var sideRun = false
}
