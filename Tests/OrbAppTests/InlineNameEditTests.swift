import Testing
@testable import Orb

// What ends an inline name edit (`InlineNameField`): the chat's title and the category's name share it.

@Suite("InlineNameEdit")
struct InlineNameEditTests {
    /// The category's rule: trimmed, blank is no name.
    private let categoryRule: (String) -> String? = SidebarOrder.name

    @Test func enterKeepsAChangedName() {
        #expect(InlineNameEdit.committed(typed: "  Vendas  ", initial: "Atlas", keeping: true, normalize: categoryRule) == "Vendas")
    }

    @Test func escapeSavesNothing() {
        #expect(InlineNameEdit.committed(typed: "Vendas", initial: "Atlas", keeping: false, normalize: categoryRule) == nil)
    }

    @Test func aBlankNameSavesNothing() {
        #expect(InlineNameEdit.committed(typed: " \n ", initial: "Atlas", keeping: true, normalize: categoryRule) == nil)
        #expect(InlineNameEdit.committed(typed: "", initial: "", keeping: true, normalize: categoryRule) == nil)
    }

    @Test func anUnchangedNameIsNotSavedAgain() {
        #expect(InlineNameEdit.committed(typed: "Atlas ", initial: "Atlas", keeping: true, normalize: categoryRule) == nil)
        #expect(InlineNameEdit.committed(typed: "Atlas", initial: "Atlas", keeping: true, normalize: { $0 }) == nil)
    }

    @Test func theChatsDefaultKeepsWhatWasTyped() {
        // The chat's field hands the text over as typed; `OrbChats.rename` trims it and refuses a blank one.
        #expect(InlineNameEdit.committed(typed: "  Plano  ", initial: "Conversa", keeping: true, normalize: { $0 }) == "  Plano  ")
    }

    @Test func theLimitCutsTheTextOnlyWhenThereIsOne() {
        #expect(InlineNameEdit.limited("abcdef", to: 3) == "abc")
        #expect(InlineNameEdit.limited("abc", to: 3) == "abc")
        #expect(InlineNameEdit.limited("abcdef", to: nil) == "abcdef")
    }
}
