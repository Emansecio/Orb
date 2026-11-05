import Foundation
import Testing
@testable import Orb

// The access card of `request_access`, from the model's call to the Orb going on by itself: "Liberar" turns on what the card lists
// and tells the model, "Agora não" changes nothing, and the Orb is asked to continue once, after the turn that asked has ended.

@Suite final class AccessCardFlowTests {
    private let root = TempFolder("OrbAccessFlow", creating: true)

    init() { QuietNotifications.hold() }

    deinit { QuietNotifications.release() }

    private var project: URL { root.appending("projeto") }

    private func accessCall(_ fields: String? = nil) -> LLMEvent {
        let body = fields ?? #""capabilities":["terminal"],"mode":"auto","folder":"\#(project.path)""#
        return .toolCalls([ToolCallRequest(id: "c1", name: AccessTool.name,
                                           arguments: #"{"reason":"Para programar o app.",\#(body)}"#)])
    }

    /// Atlas with only the browser, asking for the terminal, Automático and the project folder. The model's calls, in order: the
    /// request, its short answer, and the answer to "continua".
    @MainActor private func setUp(mode: PermissionMode = .ask, fields: String? = nil) throws -> (AppModel, Bot, CallScript) {
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var state = AppState.initial
        state.bots[0].permissionMode = mode
        state.bots[0].capabilities = [.browser]
        Store(directory: root.url).save(state)
        let model = AppModel(store: Store(directory: root.url), runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        let script = CallScript([[accessCall(fields), .finished(.toolUse, nil)],
                                 [.text("Liberado, já continuo."), .finished(.done, nil)],
                                 [.text("Pronto, comecei."), .finished(.done, nil)]],
                                whenExhausted: .reply(ModelReply([.text("fim"), .finished(.done, nil)])))
        model.clientOverride = { CallScriptModel(script: script) }
        return (model, model.bots[0], script)
    }

    @MainActor private func openCard(_ model: AppModel, _ bot: Bot) async -> ApprovalRequest? {
        #expect(model.send("programa um app na pasta projeto", to: bot.id))
        _ = await waitUntil("the access card") { !model.pendingApprovals(of: bot.id).isEmpty }
        return model.pendingApprovals(of: bot.id).first
    }

    @MainActor private func toolResult(_ model: AppModel, _ bot: Bot) -> String? {
        model.session(bot.id).conversation?.messages.first { $0.role == .tool }?.content
    }

    @MainActor private func continuations(_ model: AppModel, _ bot: Bot) -> Int {
        model.transcript(bot.id).filter { item in
            if case .user(let text, _) = item.kind { text == NoticeAction.continueMessage } else { false }
        }.count
    }

    @Test @MainActor func liberarAppliesEverythingAndTheModelIsTold() async throws {
        let (model, atlas, _) = try setUp()
        let card = try #require(await openCard(model, atlas))
        #expect(card.isAccess && card.title == "Atlas precisa de acesso" && !card.isHandoff)
        #expect(card.access?.capabilities == [.terminal] && card.access?.autoMode == true)
        #expect(card.access?.folder == OrbFolder.storedPath(project) && card.access?.reason == "Para programar o app.")
        #expect(model.needsYou(atlas.id))
        // Nothing changes until the person says so.
        #expect(model.bot(atlas.id)?.capabilities == [.browser] && model.bot(atlas.id)?.permissionMode == .ask)

        model.decide(.once, approvalID: card.id, botID: atlas.id)
        _ = await waitUntil("the result") { toolResult(model, atlas) != nil }
        let bot = try #require(model.bot(atlas.id))
        #expect(bot.capabilities == [.browser, .terminal])
        #expect(bot.permissionMode == .auto)
        #expect(bot.workingDirectory == OrbFolder.storedPath(project))
        let result = toolResult(model, atlas) ?? ""
        #expect(result.hasPrefix("Granted: Terminal e arquivos, modo Automático, pasta "))
        #expect(result.contains("The new tools arrive in your next turn"))
        _ = await waitUntil("the turn to end") { !model.isWorking(atlas.id) }
    }

    @Test @MainActor func theOrbGoesOnByItselfOnceAfterTheTurnEnds() async throws {
        let (model, atlas, script) = try setUp()
        let card = try #require(await openCard(model, atlas))
        model.decide(.once, approvalID: card.id, botID: atlas.id)
        _ = await waitUntil("the continuation") { continuations(model, atlas) == 1 }
        _ = await waitUntil("the second turn to end") { !model.isWorking(atlas.id) && model.session(atlas.id).turnTask == nil }
        // The tools of the second turn include what was just turned on: the terminal's, not only the browser's.
        let calls = await script.calls
        #expect(calls.count == 3, "the request, its short answer, the continuation")
        let secondTurnTools = calls.last?.tools ?? []
        #expect(secondTurnTools.contains("run_command"))
        // Once: nothing asks the Orb to continue again.
        try await Task.sleep(for: .milliseconds(300))
        #expect(continuations(model, atlas) == 1)
        #expect(await script.calls.count == 3)
    }

    @Test @MainActor func agoraNaoChangesNothingAndTheOrbDoesNotContinue() async throws {
        let (model, atlas, script) = try setUp()
        let card = try #require(await openCard(model, atlas))
        model.decide(.deny, approvalID: card.id, botID: atlas.id)
        _ = await waitUntil("the turn to end") { !model.isWorking(atlas.id) && toolResult(model, atlas) != nil }
        #expect(model.bot(atlas.id)?.capabilities == [.browser] && model.bot(atlas.id)?.permissionMode == .ask)
        #expect(model.bot(atlas.id)?.workingDirectory != OrbFolder.storedPath(project))
        let result = toolResult(model, atlas) ?? ""
        #expect(result.contains("did not grant access") && result.contains("Do not ask again"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(continuations(model, atlas) == 0)
        #expect(await script.calls.count == 2, "the request and its answer, nothing more")
    }

    @Test @MainActor func theCardAsksEvenWithoutAskingPermissionAndAModeChangeDoesNotAnswerIt() async throws {
        let (model, atlas, _) = try setUp(mode: .bypass)
        let card = try #require(await openCard(model, atlas))
        // "Sem pedir permissão" is past Automático: the card only lists the terminal and the folder.
        #expect(card.access?.autoMode == false)
        model.update(atlas.id) { $0.permissionMode = .auto }
        #expect(model.isPending(card.id, of: atlas.id))
        model.decide(.deny, approvalID: card.id, botID: atlas.id)
    }

    @Test @MainActor func grantingNeverLowersTheModeOrReachesBypass() async throws {
        let (model, atlas, _) = try setUp(mode: .bypass, fields: #""capabilities":["terminal"]"#)
        let card = try #require(await openCard(model, atlas))
        model.decide(.once, approvalID: card.id, botID: atlas.id)
        _ = await waitUntil("the grant") { model.bot(atlas.id)?.capabilities.contains(.terminal) == true }
        #expect(model.bot(atlas.id)?.permissionMode == .bypass)
        // Applied directly: a request for Automático does not touch a mode that is past it, and bypass is never set from ask.
        #expect(model.grantAccess(AccessRequest(autoMode: true, reason: "x"), to: atlas.id) == .granted(summary: "modo Automático"))
        #expect(model.bot(atlas.id)?.permissionMode == .bypass)
        model.update(atlas.id) { $0.permissionMode = .ask }
        _ = model.grantAccess(AccessRequest(autoMode: true, reason: "x"), to: atlas.id)
        #expect(model.bot(atlas.id)?.permissionMode == .auto)
    }

    @Test @MainActor func aFolderThatWentAwayWhileTheCardWaitedChangesNothing() throws {
        let (model, atlas, _) = try setUp()
        let gone = AccessRequest(capabilities: [.terminal], autoMode: true, folder: root.appending("sumiu").path, reason: "x")
        guard case .failed(let reason) = model.grantAccess(gone, to: atlas.id) else {
            Issue.record("a folder that is gone must not be granted")
            return
        }
        #expect(reason.contains("Nothing was changed"))
        #expect(model.bot(atlas.id)?.capabilities == [.browser] && model.bot(atlas.id)?.permissionMode == .ask)
    }

    @Test @MainActor func aFolderGoneBeforeLiberarLeavesTheCardAsNotGranted() async throws {
        let (model, atlas, _) = try setUp()
        let card = try #require(await openCard(model, atlas))
        try FileManager.default.removeItem(at: project)
        model.decide(.once, approvalID: card.id, botID: atlas.id)
        _ = await waitUntil("the card to say it was not granted") {
            model.transcript(atlas.id).contains { item in
                if case .approval(let request) = item.kind { request.id == card.id && request.decision == .deny && request.note != nil } else { false }
            }
        }
        #expect(model.bot(atlas.id)?.capabilities == [.browser])
    }

    @Test @MainActor func stoppingTheOrbCancelsTheCardAndGrantsNothing() async throws {
        let (model, atlas, _) = try setUp()
        let card = try #require(await openCard(model, atlas))
        model.stop(atlas.id)
        _ = await waitUntil("the card to be answered") { !model.isPending(card.id, of: atlas.id) }
        _ = await waitUntil("the Orb to stop") { !model.isWorking(atlas.id) }
        #expect(model.bot(atlas.id)?.capabilities == [.browser] && model.bot(atlas.id)?.permissionMode == .ask)
        #expect(continuations(model, atlas) == 0)
    }

    @Test @MainActor func aDraftInTheComposerHoldsTheContinuationBack() async throws {
        let (model, atlas, _) = try setUp()
        let card = try #require(await openCard(model, atlas))
        model.setDraft("estou escrevendo", for: atlas.id)
        model.decide(.once, approvalID: card.id, botID: atlas.id)
        _ = await waitUntil("the turn to end") { !model.isWorking(atlas.id) && toolResult(model, atlas) != nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(continuations(model, atlas) == 0)
        #expect(model.bot(atlas.id)?.capabilities.contains(.terminal) == true, "it was granted all the same")
    }
}
