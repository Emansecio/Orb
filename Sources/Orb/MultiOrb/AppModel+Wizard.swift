import Foundation

// The "Criar conversando" assistant's side of the app: where a call of the creation assistant that arrives through Claude Code's
// mailbox (`ponte/`, see `OrbBridge`) finds the assistant it speaks for. The assistants themselves are `WizardRunner`s, one per
// open sheet (`WizardRegistry` keeps them by their stand-in Orb's id); nothing about them is saved.

extension AppModel {
    /// `orb_draft` for the assistant `wizardID`: the draft takes it and the answer is the draft read back. Throws when that
    /// assistant is not open (the sheet closed while Claude Code was still answering).
    func wizardDraft(_ wizardID: UUID, _ arguments: JSONValue) throws -> String {
        try WizardRegistry.draft(orb: wizardID, tool: OrbDraftTool.name, arguments: arguments)
    }

    /// Whether the creation sheet opens in the assistant: a model is connected for it to talk with.
    var canCreateByConversing: Bool { isProviderReady }
}
