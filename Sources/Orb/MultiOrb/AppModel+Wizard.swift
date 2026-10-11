import Foundation

// The "Criar conversando" assistant's side of the app. The assistants themselves are `WizardRunner`s, one per open sheet;
// nothing about them is saved.

extension AppModel {
    /// Whether the creation sheet opens in the assistant: a model is connected for it to talk with.
    var canCreateByConversing: Bool { isProviderReady }
}
