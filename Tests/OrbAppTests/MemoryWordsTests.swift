import Testing
@testable import Orb

/// The memory panel's note about preferences that do not fit whole in what the Orb always sees.
@Suite struct MemoryWordsTests {
    @Test func oneThatDoesNotFitIsSingular() {
        #expect(MemoryWords.preferencesOverflow(1, name: "Luna", summarizes: false)
                == "1 preferência não cabe no que Luna sempre vê. As outras só aparecem quando Luna busca.")
    }

    @Test func severalArePlural() {
        #expect(MemoryWords.preferencesOverflow(3, name: "Luna", summarizes: true)
                == "3 preferências não cabem no que Luna sempre vê. Luna vai juntar as mais curtas.")
    }

    @Test func nothingOverflowingSaysNothing() {
        #expect(MemoryWords.preferencesOverflow(0, name: "Luna", summarizes: true).isEmpty)
        #expect(MemoryWords.preferencesOverflow(-2, name: "Luna", summarizes: false).isEmpty)
    }
}
