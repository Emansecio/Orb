import Foundation

extension AppModel {
    /// The preference behind Ajustes → Geral → "Orbs podem conversar entre si".
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
}
