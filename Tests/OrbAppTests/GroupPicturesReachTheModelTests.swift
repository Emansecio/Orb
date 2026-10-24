import Foundation
import Testing
@testable import Orb

// The picture of a group message, through the real delegation hub and the engine (not the fake service).

private actor Calls {
    private(set) var all: [[ChatMessage]] = []
    func note(_ messages: [ChatMessage]) { all.append(messages) }
    var count: Int { all.count }
}

private struct Capture: LLMClient {
    let calls: Calls

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await calls.note(messages)
                continuation.yield(.text("visto"))
                continuation.yield(.finished(.done, nil))
                continuation.finish()
            }
        }
    }
}

/// The picture of a group message is in the request of the member's turn, the same way an Orb's chat sends it; a model that
/// cannot see gets the path and no picture.
@Suite final class GroupPicturesReachTheModelTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbGroupPictures-\(UUID().uuidString)")

    init() { QuietNotifications.hold() }

    deinit {
        QuietNotifications.release()
        removeTestFolder(root)
    }

    @MainActor private func setUp(_ calls: Calls, sees: Bool?) -> (model: AppModel, group: OrbGroup) {
        var state = AppState.initial
        state.bots = ["Atlas", "Revisor"].map { name in
            var bot = Bot(name: name, role: "Papel de \(name)", orb: OrbConfig())
            bot.workingDirectory = root.appending(path: "pasta-\(name)").path
            try? FileManager.default.createDirectory(atPath: bot.workingDirectory, withIntermediateDirectories: true)
            return bot
        }
        state.routines = []
        let store = Store(directory: root)
        store.save(state)
        for bot in state.bots { store.save(Conversation(), for: bot.id) }
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        var account = ProviderAccount(kind: .custom)
        account.models = [ProviderModel(id: "modelo", name: "modelo", format: .chat, supportsImages: sees)]
        model.providers = [account]
        model.defaultModel = "custom/modelo"
        let client = Capture(calls: calls)
        model.clientOverride = { client }
        model.groupHub.settle = .zero
        model.groupHub.isAppActive = { false }
        let group = model.createGroup(name: "Lançamento", members: model.bots.map(\.id))!
        return (model, group)
    }

    @Test @MainActor func theOrchestratorsRequestCarriesThePicture() async throws {
        let calls = Calls()
        let (model, group) = setUp(calls, sees: true)
        let photo = try model.images.add(try Pictures.data(width: 40, height: 40), name: "foto", botID: group.id)
        model.groupLane(group.id).pictures = [photo]
        model.postUserMessage("O que é isto?", to: group.id)

        await waitUntil("the model to be called") { await calls.count > 0 }
        let first = await calls.all[0]
        let user = try #require(first.last { $0.role == .user })
        #expect(user.images == [photo])
        #expect(user.content.contains("O que é isto?") && user.content.contains("Attached images"))
        await waitUntil("the request to end") { model.groupHub.run(group.id) == nil }
    }

    @Test @MainActor func aModelThatCannotSeeGetsThePathAndNoPicture() async throws {
        let calls = Calls()
        let (model, group) = setUp(calls, sees: false)
        let photo = try model.images.add(try Pictures.data(width: 40, height: 40), name: "foto", botID: group.id)
        model.groupLane(group.id).pictures = [photo]
        model.postUserMessage("O que é isto?", to: group.id)

        await waitUntil("the model to be called") { await calls.count > 0 }
        let sent = await calls.all[0]
        #expect(sent.allSatisfy { $0.images.isEmpty })
        #expect(sent.contains { $0.role == .user && $0.content.contains(photo.path) })
        await waitUntil("the request to end") { model.groupHub.run(group.id) == nil }
    }
}
