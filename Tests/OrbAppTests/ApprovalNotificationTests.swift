import Foundation
import AppKit
import Testing
import UserNotifications
@testable import Orb

/// The approval banner: what it says, which buttons it has, what a tap means. Pure parts only; nothing here
/// touches the real notification center.
struct ApprovalNotificationTests {
    private func request(title: String = "Rodando no Terminal", command: String = "ls -la", dangerous: Bool = false,
                         items: [ApprovalItem] = []) -> ApprovalRequest {
        ApprovalRequest(toolName: "run_command", title: title, command: command, reason: "", isDangerous: dangerous)
            .with(items: items)
    }

    @Test func thePayloadCarriesTheOrbTheCardAndTheCategory() {
        let botID = UUID(), card = request()
        let payload = ApprovalNotifications.payload(botName: "Atlas", botID: botID, request: card)
        #expect(payload.title == "Atlas")
        #expect(payload.body == "Rodando no Terminal: ls -la")
        #expect(payload.threadID == botID.uuidString)
        #expect(payload.identifier == card.id.uuidString)
        #expect(payload.category == "orb.approval")
        #expect(payload.userInfo == ["botID": botID.uuidString, "approvalID": card.id.uuidString])
    }

    @Test func aLongCommandIsCutAndFlattenedToOneLine() {
        let long = String(repeating: "palavra ", count: 60)
        let body = ApprovalNotifications.body(for: request(command: "echo 1\n\n   echo 2\n" + long))
        #expect(body.count <= ApprovalNotifications.bodyLimit)
        #expect(body.hasSuffix("…") && !body.contains("\n"))
        #expect(body.hasPrefix("Rodando no Terminal: echo 1 echo 2 palavra"))
        #expect(ApprovalNotifications.body(for: request(command: "")) == "Rodando no Terminal")
    }

    @Test func aGroupedCardListsItsActions() {
        let items = [ApprovalItem(toolName: "write_file", title: "Gravando", command: "a.txt"),
                     ApprovalItem(toolName: "write_file", title: "Gravando", command: "b.txt")]
        let body = ApprovalNotifications.body(for: request(title: "2 ações precisam da sua permissão", command: "• x", items: items))
        #expect(body == "2 ações precisam da sua permissão: Gravando a.txt; Gravando b.txt")
    }

    @Test func destructiveRequestsUseTheCategoryThatAsksToUnlock() {
        let payload = ApprovalNotifications.payload(botName: "Atlas", botID: UUID(), request: request(dangerous: true))
        #expect(payload.category == "orb.approval.dangerous")
    }

    @Test func bothCategoriesOfferAllowAndDenyAndOnlyTheDangerousOneNeedsUnlocking() throws {
        let categories = ApprovalNotifications.categories()
        let normal = try #require(categories.first { $0.identifier == "orb.approval" })
        let dangerous = try #require(categories.first { $0.identifier == "orb.approval.dangerous" })
        for category in [normal, dangerous] {
            #expect(category.actions.map(\.title) == ["Permitir", "Não permitir"])
            #expect(category.actions.map(\.identifier) == [ApprovalNotifications.allowAction, ApprovalNotifications.denyAction])
        }
        #expect(!normal.actions[0].options.contains(.authenticationRequired))
        #expect(dangerous.actions[0].options.contains(.authenticationRequired))
        #expect(!dangerous.actions[1].options.contains(.authenticationRequired))
    }

    @Test func theContentGroupsByOrbAndKeepsTheIdentifiers() {
        let payload = ApprovalNotifications.payload(botName: "Atlas", botID: UUID(), request: request())
        let content = ApprovalNotifications.content(for: payload)
        #expect(content.threadIdentifier == payload.threadID && content.categoryIdentifier == "orb.approval")
        #expect(content.title == "Atlas" && content.body == payload.body)
        #expect(content.userInfo as? [String: String] == payload.userInfo)
    }

    @Test func aBannerIsPostedOnlyWhenTheUserIsNotLookingAtTheCard() {
        let bot = UUID(), other = UUID()
        func post(active: Bool, selected: UUID?, enabled: Bool = true) -> Bool {
            ApprovalNotifications.shouldPost(appIsActive: active, selectedBotID: selected, botID: bot, enabled: enabled)
        }
        #expect(!post(active: true, selected: bot))
        #expect(post(active: false, selected: bot))
        #expect(post(active: true, selected: other))
        #expect(post(active: true, selected: nil))
        #expect(!post(active: false, selected: other, enabled: false))
    }

    // MARK: Routing

    private func info(_ botID: UUID, _ approvalID: UUID) -> [AnyHashable: Any] {
        ["botID": botID.uuidString, "approvalID": approvalID.uuidString]
    }

    @Test func theButtonsAnswerTheCard() {
        let bot = UUID(), approval = UUID()
        #expect(ApprovalNotifications.route(actionIdentifier: ApprovalNotifications.allowAction, userInfo: info(bot, approval))
                == .decide(.once, botID: bot, approvalID: approval))
        #expect(ApprovalNotifications.route(actionIdentifier: ApprovalNotifications.denyAction, userInfo: info(bot, approval))
                == .decide(.deny, botID: bot, approvalID: approval))
    }

    @Test func aPlainClickOpensTheOrb() {
        let bot = UUID()
        #expect(ApprovalNotifications.route(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: info(bot, UUID()))
                == .open(botID: bot))
        // A banner from the notify tool has no Orb: the app just comes forward.
        #expect(ApprovalNotifications.route(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: [:]) == .open(botID: nil))
    }

    @Test func anythingElseIsIgnoredAndNeverAllows() {
        let bot = UUID(), approval = UUID()
        #expect(ApprovalNotifications.route(actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: info(bot, approval)) == .ignore)
        #expect(ApprovalNotifications.route(actionIdentifier: "outra.coisa", userInfo: info(bot, approval)) == .ignore)
        // A button without the ids it needs cannot answer anything.
        #expect(ApprovalNotifications.route(actionIdentifier: ApprovalNotifications.allowAction, userInfo: [:]) == .ignore)
        #expect(ApprovalNotifications.route(actionIdentifier: ApprovalNotifications.allowAction, userInfo: ["botID": bot.uuidString]) == .ignore)
        #expect(ApprovalNotifications.route(actionIdentifier: ApprovalNotifications.allowAction,
                                            userInfo: ["botID": "x", "approvalID": approval.uuidString]) == .ignore)
    }

    @Test func withoutABundleTheNotificationCenterIsOffLimits() {
        // The test process is no .app: touching the center would crash it.
        #expect(!ApprovalNotifications.isAvailable)
    }

    // MARK: Keyboard

    @Test func commandReturnAllowsAndEscapeDenies() {
        #expect(ApprovalShortcut.resolve(keyCode: ApprovalShortcut.returnKey, modifiers: .command, isEditingText: false) == .allow)
        #expect(ApprovalShortcut.resolve(keyCode: ApprovalShortcut.enterKey, modifiers: .command, isEditingText: false) == .allow)
        #expect(ApprovalShortcut.resolve(keyCode: ApprovalShortcut.escapeKey, modifiers: [], isEditingText: false) == .deny)
    }

    @Test func otherKeysAndOtherModifiersAreNotOurs() {
        #expect(ApprovalShortcut.resolve(keyCode: ApprovalShortcut.returnKey, modifiers: [], isEditingText: false) == nil)
        #expect(ApprovalShortcut.resolve(keyCode: ApprovalShortcut.returnKey, modifiers: [.command, .shift], isEditingText: false) == nil)
        #expect(ApprovalShortcut.resolve(keyCode: ApprovalShortcut.escapeKey, modifiers: .command, isEditingText: false) == nil)
        #expect(ApprovalShortcut.resolve(keyCode: 0, modifiers: .command, isEditingText: false) == nil)
    }

    @Test func escapeBelongsToATextFieldBeingEdited() {
        #expect(ApprovalShortcut.resolve(keyCode: ApprovalShortcut.escapeKey, modifiers: [], isEditingText: true) == nil)
        // ⌘↩ answers the card even from the note field.
        #expect(ApprovalShortcut.resolve(keyCode: ApprovalShortcut.returnKey, modifiers: .command, isEditingText: true) == .allow)
    }

    @Test func anEmptyFocusedComposerIsNotEditingButTextOrCompositionIs() {
        func editing(text: Bool = false, marked: Bool = false, isText: Bool = true, note: Bool = false) -> Bool {
            ApprovalShortcut.isEditing(responderIsText: isText, hasText: text, hasMarkedText: marked, noteFocused: note)
        }
        #expect(!editing())
        #expect(editing(text: true))
        #expect(editing(marked: true))
        #expect(editing(note: true))
        #expect(!editing(text: true, isText: false))
    }
}

private extension ApprovalRequest {
    func with(items: [ApprovalItem]) -> ApprovalRequest {
        var copy = self
        copy.items = items
        return copy
    }
}

/// The card's data and the app model's side of the new answers.
@Suite final class ApprovalModelTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbApprovalModel-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: root) }

    @MainActor private func model() -> AppModel {
        var state = AppState.initial
        state.bots.append(Bot(name: "Luna", role: "Agenda", orb: OrbConfig()))
        Store(directory: root).save(state)
        return AppModel(store: Store(directory: root), runsBackgroundWork: false)
    }

    @MainActor private func open(_ model: AppModel, _ request: ApprovalRequest, for botID: UUID) async {
        await model.gate.open(request.id, botID: botID)
        model.apply(.approval(request), to: botID)
    }

    private func card(_ command: String, items: [ApprovalItem] = [], suggestions: [PermissionRule] = []) -> ApprovalRequest {
        ApprovalRequest(toolName: "run_command", title: "Rodando", command: command, reason: "", suggestions: suggestions, items: items)
    }

    @Test func oldCardsWithoutTheNewFieldsStillLoad() throws {
        let json = #"{"id":"5F7E1D3A-0000-4000-8000-000000000001","toolName":"run_command","title":"T","command":"ls","reason":"","decision":"once"}"#
        let decoded = try JSONDecoder().decode(ApprovalRequest.self, from: Data(json.utf8))
        #expect(decoded.items.isEmpty && !decoded.isBatch && !decoded.isDangerous && decoded.note == nil && decoded.decision == .once)
    }

    @Test func aDamagedItemIsSkippedAndAnUnknownDecisionCountsAsDenied() throws {
        let json = #"{"title":"T","items":[{"toolName":"a","title":"x","command":"1"},"lixo",{"title":"y"}],"decision":"talvez"}"#
        let decoded = try JSONDecoder().decode(ApprovalRequest.self, from: Data(json.utf8))
        #expect(decoded.items.map(\.title) == ["x", "y"])
        #expect(decoded.decision == .deny)
    }

    @Test func aCardRoundTripsWithItsItemsAndNote() throws {
        var original = card("• a\n• b", items: [ApprovalItem(toolName: "a", title: "A", command: "1"), ApprovalItem(toolName: "b", title: "B", command: "2")])
        original.note = "faça diferente"
        original.decision = .deny
        original.isDangerous = true
        let decoded = try JSONDecoder().decode(ApprovalRequest.self, from: JSONEncoder().encode(original))
        #expect(decoded == original && decoded.isBatch)
    }

    @Test func theNoteIsCleanedAndCapped() {
        #expect(ApprovalNote.clean(nil) == nil && ApprovalNote.clean("  \n ") == nil)
        #expect(ApprovalNote.clean("  oi \n") == "oi")
        #expect(ApprovalNote.clean(String(repeating: "x", count: 900))?.count == ApprovalNote.maxLength)
        #expect(ApprovalAnswer(decision: .deny, note: "  ").note == nil)
        #expect(PermissionPolicy.userDenial(note: "faça X") == PermissionPolicy.userDenial + " The user said: faça X")
        #expect(ClaudeCodePolicy.userDenial(note: nil) == ClaudeCodePolicy.userDenial)
    }

    @Test @MainActor func openCardsOfEveryOrbAreListedAndFlagTheirOrb() async {
        let model = model()
        let (first, second) = (model.bots[0].id, model.bots[1].id)
        let one = card("ls"), two = card("pwd")
        await open(model, one, for: first)
        await open(model, two, for: second)
        #expect(model.pendingApprovals.map(\.request.id) == [one.id, two.id])
        #expect(model.pendingApprovals.map(\.bot.id) == [first, second])
        #expect(model.needsYou(first) && model.needsYou(second))
        #expect(model.newestPendingApprovalID(of: first) == one.id)

        model.decide(.once, approvalID: one.id, botID: first)
        #expect(!model.needsYou(first) && model.needsYou(second))
        #expect(model.pendingApprovals.map(\.request.id) == [two.id])
    }

    @Test @MainActor func theKeyboardTargetIsTheNewestOpenCard() async {
        let model = model()
        let botID = model.bots[0].id
        let older = card("ls"), newer = card("pwd")
        await open(model, older, for: botID)
        await open(model, newer, for: botID)
        #expect(model.newestPendingApprovalID(of: botID) == newer.id)
        model.decide(.deny, approvalID: newer.id, botID: botID)
        #expect(model.newestPendingApprovalID(of: botID) == older.id)
        // Still waiting for the older one.
        #expect(model.needsYou(botID))
    }

    @Test @MainActor func denyingWithANoteMarksTheCardAndAnswersTheEngine() async {
        let model = model()
        let botID = model.bots[0].id
        let pending = card("rm a")
        await open(model, pending, for: botID)
        let waiting = Task { await model.gate.wait(for: pending.id) }
        model.decide(.deny, note: "  mova para a lixeira  ", approvalID: pending.id, botID: botID)
        let answer = await waiting.value
        #expect(answer.decision == .deny && answer.note == "mova para a lixeira")
        let shown = model.transcript(botID).compactMap { item -> ApprovalRequest? in
            if case .approval(let request) = item.kind { request } else { nil }
        }
        #expect(shown.first?.decision == .deny && shown.first?.note == "mova para a lixeira")
    }

    @Test @MainActor func aCardAlreadyAnsweredIsNotAnsweredAgain() async {
        let model = model()
        let botID = model.bots[0].id
        let pending = card("ls")
        await open(model, pending, for: botID)
        let waiting = Task { await model.gate.wait(for: pending.id) }
        model.handle(.decide(.deny, botID: botID, approvalID: pending.id))
        #expect(await waiting.value.decision == .deny)
        // A tap on the banner after the card was answered in the app changes nothing.
        model.handle(.decide(.once, botID: botID, approvalID: pending.id))
        let shown = model.transcript(botID).compactMap { item -> ApprovalRequest? in
            if case .approval(let request) = item.kind { request } else { nil }
        }
        #expect(shown.first?.decision == .deny)
    }

    @Test @MainActor func onlyThisTaskOnAGroupLeavesTheChoiceOfRulesToTheEngine() async {
        let model = model()
        let botID = model.bots[0].id
        let items = [ApprovalItem(toolName: "run_command", title: "A", command: "git status"), ApprovalItem(toolName: "run_command", title: "B", command: "npm test")]
        let group = card("• A\n• B", items: items, suggestions: [.shell("git"), .shell("npm")])
        await open(model, group, for: botID)
        let waiting = Task { await model.gate.wait(for: group.id) }
        model.decide(.task, approvalID: group.id, botID: botID)
        #expect(await waiting.value.rule == nil)
        // A single card still grants its first rule.
        let single = card("ls", suggestions: [.shell("ls")])
        await open(model, single, for: botID)
        let waitingSingle = Task { await model.gate.wait(for: single.id) }
        model.decide(.task, approvalID: single.id, botID: botID)
        #expect(await waitingSingle.value.rule == .shell("ls"))
    }

    @Test @MainActor func reviewingOneByOneIsRecordedAndSavesNoRule() async {
        let model = model()
        let botID = model.bots[0].id
        let group = card("• A\n• B", items: [ApprovalItem(toolName: "a", title: "A", command: ""), ApprovalItem(toolName: "b", title: "B", command: "")],
                         suggestions: [.shell("git")])
        await open(model, group, for: botID)
        let waiting = Task { await model.gate.wait(for: group.id) }
        let before = model.bots[0].permissionRules
        model.decide(.review, approvalID: group.id, botID: botID)
        #expect(await waiting.value.decision == .review)
        #expect(model.bots[0].permissionRules == before)
        #expect(!model.needsYou(botID))
    }

    @Test @MainActor func aBannerTappedAfterTheAppReopenedDoesNotAnswerACardTheRunLeftOpen() {
        // Rex's conversation is on disk with a card nobody answered (the app closed): it is not loaded at launch.
        var state = AppState.initial
        state.bots.append(Bot(name: "Luna", role: "", orb: OrbConfig()))
        let rex = Bot(name: "Rex", role: "", orb: OrbConfig())
        state.bots.append(rex)
        let store = Store(directory: root)
        store.save(state)
        let stale = card("rm a")
        var saved = Conversation()
        saved.items = [TranscriptItem(.approval(stale))]
        store.save(saved, for: rex.id)
        store.flush()
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)

        model.handle(.decide(.once, botID: rex.id, approvalID: stale.id))
        let shown = model.transcript(rex.id).compactMap { item -> ApprovalRequest? in
            if case .approval(let request) = item.kind { request } else { nil }
        }
        // It stays what the interruption made it: denied, not "allowed once", and nothing is waiting for it.
        #expect(shown.map(\.decision) == [.deny])
        #expect(!model.needsYou(rex.id))
    }

    @Test @MainActor func aBannerOfAnOrbThatNoLongerExistsLeavesNoConversationBehind() {
        let model = model()
        let gone = UUID()
        model.handle(.decide(.once, botID: gone, approvalID: UUID()))
        #expect(model.transcript(gone).isEmpty)
        model.saveNow()
        #expect(Store(directory: root).readConversation(gone).value == nil)
    }
}
