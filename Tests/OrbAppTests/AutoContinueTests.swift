import Foundation
import Testing
@testable import Orb

private func said(_ text: String) -> [LLMEvent] { [.text(text), .finished(.done, nil)] }

private func call(_ name: String, _ arguments: String) -> [LLMEvent] {
    [.toolCalls([ToolCallRequest(id: UUID().uuidString, name: name, arguments: arguments)]), .finished(.toolUse, nil)]
}

/// What counts as the task plan moving forward (`PlanProgress`), and when a stretch ends how (`AgentEngine.stretchEnd`).
struct PlanProgressTests {
    private let twoSteps = #"{"action": "set", "goal": "Publicar", "steps": ["Build", "Subir"]}"#

    private func plan(_ json: String) -> ToolCallRequest { ToolCallRequest(id: UUID().uuidString, name: TaskPlanTool.name, arguments: json) }
    private func mark(_ step: Int, _ state: String = "done") -> ToolCallRequest {
        plan(#"{"action": "update", "updates": [{"step": \#(step), "state": "\#(state)"}]}"#)
    }
    private let work = ToolCallRequest(id: "w", name: "write_file", arguments: "{}")

    @Test func aStepMarkedDoneWithOnlyThePlanToolDoesNotCount() {
        var progress = PlanProgress(plan: nil)
        progress.record(plan(twoSteps), failed: false)
        #expect(progress.record(mark(1), failed: false) == [1])
        #expect(!progress.advanced)
        #expect(progress.touched)
        #expect(progress.plan?.openSteps == [2])
    }

    @Test func aStepMarkedDoneAfterARealCallCounts() {
        var progress = PlanProgress(plan: nil)
        progress.record(plan(twoSteps), failed: false)
        progress.record(work, failed: false)
        #expect(progress.record(mark(1), failed: false).isEmpty)
        #expect(progress.advanced)
    }

    @Test func theWorkMustComeAfterTheStepWentInProgress() {
        var progress = PlanProgress(plan: nil)
        progress.record(plan(twoSteps), failed: false)
        progress.record(work, failed: false)
        progress.record(mark(1, "in_progress"), failed: false)
        #expect(progress.record(mark(1), failed: false) == [1], "the work was before the step started")
        progress.record(mark(2, "in_progress"), failed: false)
        progress.record(work, failed: false)
        #expect(progress.record(mark(2), failed: false).isEmpty)
        #expect(progress.advanced)
    }

    @Test func aStepInProgressWhenTheStretchBeganNeedsWorkInTheNewStretch() {
        var progress = PlanProgress(plan: nil)
        progress.record(plan(twoSteps), failed: false)
        progress.record(mark(1, "in_progress"), failed: false)
        progress.record(work, failed: false)
        progress.startStretch()
        #expect(!progress.advanced)
        #expect(progress.record(mark(1), failed: false) == [1], "its work was in the stretch before")
        progress.record(work, failed: false)
        #expect(progress.record(mark(2), failed: false).isEmpty)
        #expect(progress.advanced)
    }

    @Test func aNewPlanOpensItsStepsAgain() {
        var progress = PlanProgress(plan: nil)
        progress.record(plan(twoSteps), failed: false)
        progress.record(work, failed: false)
        progress.record(plan(twoSteps), failed: false)
        #expect(progress.record(mark(1), failed: false) == [1])
    }

    @Test func aFailedOrRefusedPlanCallChangesNothing() {
        var progress = PlanProgress(plan: nil)
        progress.record(plan(twoSteps), failed: false)
        progress.record(work, failed: false)
        #expect(progress.record(mark(1), failed: true).isEmpty)
        #expect(progress.record(mark(9), failed: false).isEmpty, "step 9 does not exist: the tool refused it")
        #expect(!progress.advanced && progress.plan?.openSteps == [1, 2])
    }

    @Test func aStretchEndsByItsPlanTheUserAndTheAllowance() {
        let open = TaskPlan(goal: "g", steps: [TaskPlan.Step(text: "a", state: .done), TaskPlan.Step(text: "b")])
        let closed = TaskPlan(goal: "g", steps: [TaskPlan.Step(text: "a", state: .done), TaskPlan.Step(text: "b", state: .blocked, reason: "x")])
        #expect(AgentEngine.stretchEnd(stretch: 1, of: 3, plan: open, advanced: true, stopAsked: false) == .goOn)
        #expect(AgentEngine.stretchEnd(stretch: 3, of: 3, plan: open, advanced: true, stopAsked: false) == .capped)
        #expect(AgentEngine.stretchEnd(stretch: 1, of: 3, plan: open, advanced: false, stopAsked: false) == .stalled)
        #expect(AgentEngine.stretchEnd(stretch: 1, of: 1, plan: open, advanced: true, stopAsked: false) == .pause, "switched off")
        #expect(AgentEngine.stretchEnd(stretch: 1, of: 3, plan: nil, advanced: false, stopAsked: false) == .pause, "no plan")
        #expect(AgentEngine.stretchEnd(stretch: 1, of: 3, plan: closed, advanced: true, stopAsked: false) == .pause, "nothing open")
        #expect(AgentEngine.stretchEnd(stretch: 1, of: 3, plan: open, advanced: true, stopAsked: true) == .pause, "the user asked to stop")
    }

    @Test func theStripSaysWhichStretchRunsOnlyPastTheFirst() {
        #expect(TurnStretch(number: 1, limit: 3).label == nil)
        #expect(TurnStretch(number: 2, limit: 3).label == "Continuando sozinho · trecho 2 de 3")
    }
}

/// The switch in Ajustes: on by default, read where Ajustes saves it, and the turn follows it.
@Suite(.serialized) final class AutoContinueSettingTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbAutoContinue-\(UUID().uuidString)")

    init() { QuietNotifications.hold() }

    deinit {
        QuietNotifications.release()
        removeTestFolder(root)
    }

    @MainActor private func setUp(_ script: CallScript, continues: Bool?) -> (AppModel, UUID) {
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
        let suite = UserDefaults(suiteName: "OrbAutoContinue-\(UUID().uuidString)")!
        suite.set(false, forKey: SkillReview.settingKey) // its review would be one more call after the turn
        if let continues { suite.set(continues, forKey: AutoContinue.settingKey) }
        model.preferences = suite
        return (model, state.bots[0].id)
    }

    /// A first stretch that plans two steps and does the first with real work, then a second that does the rest.
    private var longTask: [[LLMEvent]] {
        let steps = AgentEngine.defaultMaxSteps
        return [call(TaskPlanTool.name, #"{"action": "set", "goal": "Publicar o site", "steps": ["Gerar o build", "Subir"]}"#)]
            + (0..<(steps - 3)).map { _ in call("recall", #"{"query": "deploy"}"#) }
            + [call(TaskPlanTool.name, #"{"action": "update", "updates": [{"step": 1, "state": "done"}]}"#), said("Build feito.")]
            + [call("recall", #"{"query": "deploy"}"#),
               call(TaskPlanTool.name, #"{"action": "update", "updates": [{"step": 2, "state": "done"}]}"#), said("Pronto: site no ar.")]
    }

    @MainActor private func notices(_ model: AppModel, _ botID: UUID) -> [String] {
        model.transcript(botID).compactMap { if case .notice(let text) = $0.kind { text } else { nil } }
    }

    @Test @MainActor func theSwitchIsOnUntilAjustesSavesItOff() {
        let (model, _) = setUp(CallScript([said("oi")]), continues: nil)
        #expect(model.continuesLongTasks)
        model.preferences.set(false, forKey: AutoContinue.settingKey)
        #expect(!model.continuesLongTasks)
        #expect(AutoContinue.settingKey == "continueLongTasks", "the key Ajustes saves under (@AppStorage)")
    }

    @Test @MainActor func onALongTaskThatMovesTheTurnGoesPastTheLimit() async {
        let script = CallScript(longTask)
        let (model, botID) = setUp(script, continues: true)
        #expect(model.send("publica o site", to: botID))
        await waitUntilIdle(model, botID)
        #expect(await script.calls.count == AgentEngine.defaultMaxSteps + 3)
        #expect(notices(model, botID) == [AutoContinue.notice(stretch: 2, of: AutoContinue.maxStretches)])
        #expect(model.session(botID).conversation?.taskPaused == false)
        #expect(model.live(botID).stretch == nil, "the line goes once the turn ends")
    }

    @Test @MainActor func switchedOffTheTurnPausesAtTheLimitAsBefore() async {
        let script = CallScript(longTask)
        let (model, botID) = setUp(script, continues: false)
        #expect(model.send("publica o site", to: botID))
        await waitUntilIdle(model, botID)
        #expect(await script.calls.count == AgentEngine.defaultMaxSteps)
        #expect(notices(model, botID) == [AgentEngine.pausedNotice(after: AgentEngine.defaultMaxSteps)])
        #expect(model.session(botID).conversation?.taskPaused == true)
    }
}
