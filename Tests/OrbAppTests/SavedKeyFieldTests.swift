import Foundation
import Testing
@testable import Orb

@Suite struct SavedKeyFieldTests {
    @Test func typedKeyOffersSaveEvenWhileReplacing() {
        #expect(SavedKeyField.Trailing.of(key: "sk-1", isReplacing: false, hasKeyPage: true) == .save)
        #expect(SavedKeyField.Trailing.of(key: "sk-1", isReplacing: true, hasKeyPage: false) == .save)
    }

    @Test func emptyFieldNeverOffersSave() {
        #expect(SavedKeyField.Trailing.of(key: "", isReplacing: true, hasKeyPage: true) == .cancel)
        #expect(SavedKeyField.Trailing.of(key: "", isReplacing: false, hasKeyPage: true) == .getKey)
        #expect(SavedKeyField.Trailing.of(key: "", isReplacing: false, hasKeyPage: false) == .none)
    }
}
