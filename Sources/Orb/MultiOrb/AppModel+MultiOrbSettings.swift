import Foundation

extension AppModel {
    /// The preference behind Ajustes → Orbs → "Orbs podem conversar entre si".
    static let orbsCanTalkKey = "orbsCanTalk"

    /// Whether Orbs see their teammates and ask each other for work. On unless the person switched it off. Groups do not depend on it.
    /// Switching it off stops every conversation between Orbs that is going on.
    var orbsCanTalk: Bool {
        get { preferences.object(forKey: Self.orbsCanTalkKey) as? Bool ?? true }
        set {
            preferences.set(newValue, forKey: Self.orbsCanTalkKey)
            if !newValue { delegation.cancelAll(by: .switchOff) }
        }
    }

    /// The preference behind Ajustes → Orbs → "Orbs podem acionar grupos".
    static let orbsCanStartGroupsKey = "orbsCanStartGroups"

    /// Whether an Orb, in its own chat and only when you ask in that turn, may send a request to a group it is in (`orbs ask`
    /// with the group's name): the orchestrator gets it and the group's final answer comes back to the chat. On unless switched
    /// off. Switching it off stops nothing: a request already sent goes on, as one you typed in the group would.
    var orbsCanStartGroups: Bool {
        get { preferences.object(forKey: Self.orbsCanStartGroupsKey) as? Bool ?? true }
        set { preferences.set(newValue, forKey: Self.orbsCanStartGroupsKey) }
    }

    /// The preference behind Ajustes → Orbs → "Orbs agem por conta própria".
    static let orbsActOnOwnKey = "orbsActOnOwn"

    /// Whether an Orb may create and ask groups without the user asking in that turn: from a routine, another Orb's request or a
    /// group's turn too. On unless switched off; off, only the own chat in a turn the person started (the old rule). It adds no
    /// permission of its own: "Orbs podem acionar grupos" still has to be on.
    var orbsActOnOwn: Bool {
        get { preferences.object(forKey: Self.orbsActOnOwnKey) as? Bool ?? true }
        set { preferences.set(newValue, forKey: Self.orbsActOnOwnKey) }
    }

    /// The preference behind Ajustes → Orbs → "Orbs organizam os grupos".
    static let orbsCanManageGroupsKey = "orbsCanManageGroups"

    /// Whether an Orb may change the user's groups on its own with `group_edit` (members, orchestrator, name, objective). On unless
    /// switched off. Deleting a group, or taking out the member that would dissolve it, always asks the user, whatever this says.
    var orbsCanManageGroups: Bool {
        get { preferences.object(forKey: Self.orbsCanManageGroupsKey) as? Bool ?? true }
        set { preferences.set(newValue, forKey: Self.orbsCanManageGroupsKey) }
    }
}
