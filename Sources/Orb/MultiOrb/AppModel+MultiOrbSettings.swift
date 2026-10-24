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
}
