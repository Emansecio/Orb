import Testing
@testable import Orb

/// The new-Orb sheet asks before Cancelar/Esc throws work away, and says the way out when the assistant hits its limit.
@MainActor struct NewOrbDiscardTests {
    private func message(assistant: Bool = false, userMessages: Int = 0, finished: Bool = false,
                         name: String = "", role: String = "", identity: String = "") -> String? {
        NewBotSheet.discardMessage(isAssistant: assistant, userMessages: userMessages, isFinished: finished,
                                   name: name, role: role, identity: identity)
    }

    @Test func theAssistantAsksOnlyAfterThePersonSpoke() {
        #expect(message(assistant: true, userMessages: 0) == nil)
        #expect(message(assistant: true, userMessages: 1) == "A conversa com o assistente se perde.")
        // The Orb was made (or the sheet already closed): nothing is left to lose.
        #expect(message(assistant: true, userMessages: 3, finished: true) == nil)
    }

    @Test func theFormAsksWhenAnyFieldHasText() {
        #expect(message() == nil)
        #expect(message(name: "Atlas") != nil)
        #expect(message(role: "Agenda") != nil)
        #expect(message(identity: "Você é o Atlas.") != nil)
    }

    @Test func spacesAloneAreNotWorkToLose() {
        #expect(message(name: "  ", role: "\n", identity: " \t ") == nil)
    }

    @Test func eachModeCountsOnlyItsOwnWork() {
        // The person moved to the form: the assistant's conversation no longer counts, only the fields.
        #expect(message(assistant: false, userMessages: 5) == nil)
        // In the assistant the form's fields are not on screen.
        #expect(message(assistant: true, userMessages: 0, name: "x") == nil)
    }

    @Test func thePlaceholderPointsToTheWayOutAtTheLimit() {
        #expect(WizardChatView.placeholder(hitLimit: true, canCreate: true, failed: false) == "Vamos fechar: clique em Criar Orb")
        #expect(WizardChatView.placeholder(hitLimit: true, canCreate: false, failed: false).contains("Formulário"))
        // The limit wins over a failure: the field is off for good.
        #expect(WizardChatView.placeholder(hitLimit: true, canCreate: false, failed: true).contains("limite"))
        #expect(WizardChatView.placeholder(hitLimit: false, canCreate: false, failed: true) == "Clique em Tentar de novo")
        #expect(WizardChatView.placeholder(hitLimit: false, canCreate: false, failed: false) == "Responda aqui…")
    }

    // The assistant's draft is not lost on the way to the form, and the mode does not follow the connection check.
    @Test func theDraftFillsTheFormButKeepsWhatItLeftEmpty() {
        var draft = OrbDraft()
        draft.name = "Lia"
        draft.instructions = "Você é a Lia."
        let carried = NewBotSheet.carried(draft, name: "x", role: "Agenda", identity: "")
        #expect(carried.0 == "Lia" && carried.1 == "Agenda" && carried.2 == "Você é a Lia.")
    }

    @Test func aSecondTripToTheFormDoesNotOverwriteWhatWasEdited() {
        var draft = OrbDraft()
        draft.name = "Lia"
        draft.revision = 2
        #expect(NewBotSheet.carriesDraft(draft, since: 0))
        // Same draft again: the form's own edits stay. A newer draft carries.
        #expect(!NewBotSheet.carriesDraft(draft, since: 2))
        draft.revision = 3
        #expect(NewBotSheet.carriesDraft(draft, since: 2))
    }

    @Test func theSheetKeepsTheModeItOpenedIn() {
        #expect(NewBotSheet.pinnedMode(chosen: nil, opened: .form) == .form)
        #expect(NewBotSheet.pinnedMode(chosen: .assistant, opened: .form) == .assistant)
    }

    @Test func longIdentityNotesSayHowMuchReachesTheModel() {
        #expect(MemoryBank.identityTrimNote(count: MemoryBank.identityShare) == nil)
        let note = MemoryBank.identityTrimNote(count: MemoryBank.identityShare + 1)
        #expect(note?.contains("\(MemoryBank.identityShare.formatted())") == true)
    }
}
