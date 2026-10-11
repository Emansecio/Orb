import Foundation
import Testing
@testable import Orb

/// An Orb has one conversation: where it lives, that an older single-file layout still loads, and what deleting an
/// Orb removes (the conversation, the routines' conversations and any leftover set-aside file).
@Suite final class ConversationHistoryTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbHistory-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    private var store: Store { Store(directory: root) }

    private func currentURL(_ botID: UUID) -> URL { root.appending(path: "conversations/\(botID.uuidString).json") }
    private func archiveFolder(_ botID: UUID) -> URL { root.appending(path: "conversations/\(botID.uuidString)") }

    private func put(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func conversation(_ said: String..., reply: String = "certo", at start: Date = .now) -> Conversation {
        var items: [TranscriptItem] = []
        var messages: [ChatMessage] = []
        for (index, text) in said.enumerated() {
            var user = TranscriptItem(.user(text: text, attachments: []))
            user.date = start.addingTimeInterval(Double(index) * 60)
            var bot = TranscriptItem(.bot(text: reply, isStreaming: false))
            bot.date = start.addingTimeInterval(Double(index) * 60 + 30)
            items += [user, bot]
            messages += [.user(text), ChatMessage(role: .assistant, content: reply)]
        }
        return Conversation(items: items, messages: messages)
    }

    /// A model whose only Orb already has `current` as its conversation.
    @MainActor private func model(current: Conversation? = nil) -> (AppModel, UUID) {
        let state = AppState.initial
        let botID = state.bots[0].id
        store.save(state)
        if let current { store.save(current, for: botID) }
        store.flush()
        return (AppModel(store: store, runsBackgroundWork: false), botID)
    }

    // MARK: Layout

    @Test @MainActor func theSingleFileLayoutOfOlderVersionsLoadsAsTheCurrentConversation() {
        let (model, botID) = model(current: conversation("oi"))
        #expect(model.transcript(botID).count == 2)
        #expect(!FileManager.default.fileExists(atPath: archiveFolder(botID).path)) // nothing was created for it
    }

    @Test @MainActor func theConversationStaysWhereItAlwaysWas() async {
        let (model, botID) = model(current: conversation("primeira"))
        model.saveNow()
        #expect(FileManager.default.fileExists(atPath: currentURL(botID).path))
        #expect(store.loadConversation(botID)?.items.count == 2)
        #expect(!FileManager.default.fileExists(atPath: archiveFolder(botID).path))
    }

    // MARK: Deleting an Orb

    @Test @MainActor func deletingAnOrbDeletesItsConversationsAndLeavesTheOthersAlone() throws {
        var state = AppState.initial
        state.bots.append(Bot(name: "Luna", role: "", orb: OrbConfig()))
        let (kept, doomed) = (state.bots[0].id, state.bots[1].id)
        store.save(state)
        for id in [kept, doomed] {
            store.save(conversation("atual"), for: id)
            store.saveRoutineConversation(conversation("rotina"), routine: UUID(), for: id)
        }
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)

        model.deleteBot(doomed)
        store.flush()

        #expect(!FileManager.default.fileExists(atPath: archiveFolder(doomed).path))
        #expect(!FileManager.default.fileExists(atPath: currentURL(doomed).path))
        #expect(FileManager.default.fileExists(atPath: currentURL(kept).path)) // the other Orb is untouched
        #expect(FileManager.default.fileExists(atPath: archiveFolder(kept).path)) // its routine conversation stays
    }

    @Test func aSealedFolderAnswersWritesWithFailureInsteadOfNeverAnswering() async {
        let sealed = Store(directory: root)
        sealed.sealWrites()
        #expect(await sealed.saveAndWait(conversation("oi"), for: UUID()) == false)
    }
}
