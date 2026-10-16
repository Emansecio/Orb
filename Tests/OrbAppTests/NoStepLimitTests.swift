import Foundation
import Testing
@testable import Orb

private func said(_ text: String) -> [LLMEvent] { [.text(text), .finished(.done, nil)] }

private func call(_ name: String, _ arguments: String) -> [LLMEvent] {
    [.toolCalls([ToolCallRequest(id: UUID().uuidString, name: name, arguments: arguments)]), .finished(.toolUse, nil)]
}

/// The app's own turns have no step limit: a long task runs past the engine's default without pausing or asking.
@Suite(.serialized) final class NoStepLimitTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbNoStepLimit-\(UUID().uuidString)")

    init() { QuietNotifications.hold() }

    deinit {
        QuietNotifications.release()
        removeTestFolder(root)
    }

    @MainActor private func setUp(_ script: CallScript) -> (AppModel, UUID) {
        var state = AppState.initial
        let folder = root.appending(path: "pasta")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        state.bots[0].workingDirectory = folder.path
        let store = Store(directory: root)
        store.save(state)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.homeFolder = root
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = { CallScriptModel(script: script) }
        let suite = UserDefaults(suiteName: "OrbNoStepLimit-\(UUID().uuidString)")!
        suite.set(false, forKey: SkillReview.settingKey) // its review would be one more call after the turn
        model.preferences = suite
        return (model, state.bots[0].id)
    }

    @Test @MainActor func aLongTaskRunsPastTheEnginesDefaultWithoutPausing() async {
        let steps = AgentEngine.defaultMaxSteps * 2
        // Each step asks something new: a long task, not one going in circles (that one tells the person, see `LoopWatch.userNotice`).
        let script = CallScript((0..<steps).map { call("recall", #"{"query": "deploy \#($0)"}"#) } + [said("Pronto: site no ar.")])
        let (model, botID) = setUp(script)
        #expect(model.send("publica o site", to: botID))
        await waitUntilIdle(model, botID)
        #expect(await script.calls.count == steps + 1)
        #expect(model.notices(botID).isEmpty)
        #expect(model.session(botID).conversation?.taskPaused != true)
    }
}
