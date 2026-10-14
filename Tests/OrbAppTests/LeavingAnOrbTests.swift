import Foundation
import Testing
@testable import Orb

/// What stops when you leave an Orb or delete it: the microphone belongs to the Orb on screen, and a deleted Orb's
/// background work on its memory ends with it.
@MainActor @Suite("Leaving and deleting an Orb") struct LeavingAnOrbTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "OrbDictation-\(UUID().uuidString)")

    private func twoOrbs() -> (AppModel, UUID, UUID) {
        var state = AppState.initial
        state.bots.append(Bot(name: "Luna", role: "", orb: OrbConfig()))
        let store = Store(directory: root)
        store.save(state)
        store.flush()
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        return (model, state.bots[0].id, state.bots[1].id)
    }

    @Test func leavingTheOrbClosesItsDictation() async {
        defer { removeTestFolder(root) }
        let (model, first, second) = twoOrbs()
        model.selection = .bot(first)
        model.dictation.pose(.listening, for: first)
        model.selection = .bot(first) // the same Orb again: the microphone stays open
        #expect(model.dictation.isActive(for: first))
        model.selection = .bot(second)
        await waitUntil("the dictation to close") { !model.dictation.isActive(for: first) }
    }

    @Test func leavingForAnotherPageClosesItToo() async {
        defer { removeTestFolder(root) }
        let (model, first, _) = twoOrbs()
        model.selection = .bot(first)
        model.dictation.pose(.listening, for: first)
        model.selection = .routines
        await waitUntil("the dictation to close") { model.dictation.botID == nil }
    }

    @Test func deletingTheOrbClosesItsDictation() {
        defer { removeTestFolder(root) }
        let (model, first, second) = twoOrbs()
        model.selection = .bot(second)
        model.dictation.pose(.listening, for: first) // dictating into an Orb shown elsewhere (its own window)
        model.deleteBot(first)
        #expect(model.dictation.botID == nil)
        #expect(model.dictation.phase == .idle)
    }

    @Test func deletingTheOrbStopsTheWorkOnItsMemory() {
        defer { removeTestFolder(root) }
        let (model, first, _) = twoOrbs()
        let session = model.session(first)
        let consolidation = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        let merge = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        session.memoryConsolidation = consolidation
        session.memoryMerge = merge
        model.deleteBot(first)
        #expect(consolidation.isCancelled && merge.isCancelled)
    }
}
