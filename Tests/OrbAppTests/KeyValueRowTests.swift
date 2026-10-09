import Foundation
import SwiftUI
import Testing
@testable import Orb

// The variable/header rows of the connector sheet.

struct KeyValueRowTests {
    @Test func aFieldThatOutlivesItsRowNeitherCrashesNorTouchesAnotherRow() {
        var store = [KeyValueRow(key: "A", value: "1"), KeyValueRow(key: "B", value: "2")]
        let rows = Binding(get: { store }, set: { store = $0 })
        let last = store[1]
        let binding = KeyValueRow.binding(in: rows, id: last.id, fallback: last)

        // Edits reach the row while it exists...
        var edited = last
        edited.value = "novo"
        binding.wrappedValue = edited
        #expect(store[1].value == "novo")

        // ...and after it is removed the old binding reads the fallback and writes nowhere.
        store.removeAll { $0.id == last.id }
        edited.value = "tarde"
        binding.wrappedValue = edited
        #expect(binding.wrappedValue.id == last.id && binding.wrappedValue.key == "B")
        #expect(store.count == 1 && store[0].key == "A" && store[0].value == "1")
    }
}
