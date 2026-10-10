import Foundation
import Testing
@testable import Orb

/// The app model's side of permissions: a mode change answers the open cards and marks them in the transcript,
/// and "Sempre" saves its rule before the engine is answered. No provider and no Claude Code are involved.
@Suite final class PermissionModelTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbPermissionModel-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    /// A model with one Orb that is showing an open approval card.
    @MainActor private func modelWithOpenCard(mode: PermissionMode) async throws -> (model: AppModel, botID: UUID, request: ApprovalRequest) {
        var state = AppState.initial
        state.bots[0].permissionMode = mode
        let botID = state.bots[0].id
        let request = ApprovalRequest(toolName: "run_command", title: "Rodar um comando", command: "ls", reason: "",
                                      decision: nil, suggestions: [.shell("ls")])
        Store(directory: root).save(state)
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        // No banner from the test process.
        QuietNotifications.hold()
        defer { QuietNotifications.release() }
        await model.gate.open(request.id, botID: botID)
        model.apply(.approval(request), to: botID)
        // A turn is running (it is waiting on the card).
        model.session(botID).turnTask = Task { try? await Task.sleep(for: .seconds(30)) }
        return (model, botID, request)
    }

    @MainActor private func decision(in model: AppModel, of request: ApprovalRequest, botID: UUID) -> ApprovalDecision? {
        for item in model.transcript(botID) {
            if case .approval(let shown) = item.kind, shown.id == request.id { return shown.decision }
        }
        return nil
    }

    @Test @MainActor func changingTheModeAnswersTheOpenCardsAndMarksThem() async throws {
        let (model, botID, request) = try await modelWithOpenCard(mode: .ask)
        defer { model.turns[botID]?.cancel() }
        let waiting = Task { await model.gate.wait(for: request.id) }
        #expect(decision(in: model, of: request, botID: botID) == nil)

        model.update(botID) { $0.permissionMode = .readOnly }

        let answer = await waiting.value
        #expect(answer.decision == .deny)
        await waitUntil("the card to be marked in the transcript") { decision(in: model, of: request, botID: botID) != nil }
        #expect(decision(in: model, of: request, botID: botID) == .deny)
    }

    @Test @MainActor func switchingToNoPromptsAllowsTheOpenCards() async throws {
        let (model, botID, request) = try await modelWithOpenCard(mode: .ask)
        defer { model.turns[botID]?.cancel() }
        let waiting = Task { await model.gate.wait(for: request.id) }

        model.update(botID) { $0.permissionMode = .bypass }

        #expect(await waiting.value.decision == .once)
        await waitUntil("the card to be marked in the transcript") { decision(in: model, of: request, botID: botID) != nil }
        #expect(decision(in: model, of: request, botID: botID) == .once)
    }

    @Test @MainActor func aModeChangeWithoutARunningTurnTouchesNothing() async throws {
        let (model, botID, request) = try await modelWithOpenCard(mode: .ask)
        model.turns[botID]?.cancel()
        model.session(botID).turnTask = nil
        model.update(botID) { $0.permissionMode = .readOnly }
        // Without a running turn the change returns before it spawns anything; the short settle covers a regression that does.
        try await Task.sleep(for: .milliseconds(20))
        #expect(decision(in: model, of: request, botID: botID) == nil)
        #expect(await model.gate.openIDs(for: botID) == [request.id])
    }

    @Test @MainActor func alwaysSavesTheRuleBeforeTheEngineIsAnswered() async throws {
        let (model, botID, request) = try await modelWithOpenCard(mode: .ask)
        defer { model.turns[botID]?.cancel() }
        let waiting = Task { await model.gate.wait(for: request.id) }

        model.decide(.always, rule: .shell("ls"), approvalID: request.id, botID: botID)

        // Saved synchronously: whatever the engine does next already sees the rule.
        #expect(model.permissionState(of: botID)?.rules.contains(.shell("ls")) == true)
        let answer = await waiting.value
        #expect(answer.decision == .always && answer.rule == .shell("ls"))
        #expect(decision(in: model, of: request, botID: botID) == .always)
    }

    @Test @MainActor func alwaysWithoutAPickedRuleTakesTheFirstSuggestion() async throws {
        let (model, botID, request) = try await modelWithOpenCard(mode: .ask)
        defer { model.turns[botID]?.cancel() }
        model.decide(.always, approvalID: request.id, botID: botID)
        #expect(model.permissionState(of: botID)?.rules == [.shell("ls")])
    }

    @Test @MainActor func onlyThisTaskDoesNotSaveARule() async throws {
        let (model, botID, request) = try await modelWithOpenCard(mode: .ask)
        defer { model.turns[botID]?.cancel() }
        let waiting = Task { await model.gate.wait(for: request.id) }
        model.decide(.task, rule: .shell("ls"), approvalID: request.id, botID: botID)
        #expect(model.permissionState(of: botID)?.rules.isEmpty == true)
        #expect(await waiting.value.rule == .shell("ls"))
    }
}
