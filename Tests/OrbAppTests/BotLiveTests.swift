import Foundation
import Observation
import Testing
@testable import Orb

/// What each Orb publishes to the views (`BotLive`), and that an event in one Orb notifies nothing that shows
/// another. A "view" here is a closure run under `withObservationTracking`: whatever it reads is what it depends on.
@Suite final class BotLiveTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbLive-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Atlas, Luna and Rex, saved in `root`.
    @MainActor private func model() -> AppModel {
        var state = AppState.initial
        state.bots.append(Bot(name: "Luna", role: "Agenda", orb: OrbConfig()))
        state.bots.append(Bot(name: "Rex", role: "Código", orb: OrbConfig()))
        Store(directory: root).save(state)
        return AppModel(store: Store(directory: root), runsBackgroundWork: false)
    }

    private final class Flag: @unchecked Sendable { var raised = false }

    /// Whether `change` notifies a view that reads `reads`.
    @MainActor private func notifies(reading reads: @MainActor () -> Void, whenYouDo change: @MainActor () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking { reads() } onChange: { flag.raised = true }
        change()
        return flag.raised
    }

    @MainActor private func expectSilent(reading reads: @MainActor () -> Void, whenYouDo change: @MainActor () -> Void,
                                         sourceLocation: SourceLocation = #_sourceLocation) {
        let fired = notifies(reading: reads, whenYouDo: change)
        #expect(!fired, "notified a view that should not depend on this", sourceLocation: sourceLocation)
    }

    @MainActor private func expectNotified(reading reads: @MainActor () -> Void, whenYouDo change: @MainActor () -> Void,
                                           sourceLocation: SourceLocation = #_sourceLocation) {
        let fired = notifies(reading: reads, whenYouDo: change)
        #expect(fired, "did not notify a view that shows this", sourceLocation: sourceLocation)
    }

    private func call(_ kind: ToolCall.Kind = .shell) -> ToolCall { ToolCall(kind: kind, title: "Rodando", detail: "ls") }

    private func card(_ command: String = "ls") -> ApprovalRequest {
        ApprovalRequest(toolName: "run_command", title: "Rodando", command: command, reason: "", suggestions: [], items: [])
    }

    // MARK: Activity

    @Test func theActivityFollowsTheMostUrgentFact() {
        func activity(waiting: Bool = false, failed: Bool = false, celebrating: Bool = false, working: Bool = true,
                      tool: ToolCall.Kind? = nil, speaking: Bool = false, listening: Bool = false) -> OrbActivity {
            BotLive.activity(awaitingApproval: waiting, failed: failed, celebrating: celebrating, isWorking: working,
                             tool: tool, speaking: speaking, listening: listening)
        }
        #expect(activity(working: false) == .idle)
        #expect(activity() == .thinking)
        #expect(activity(listening: true) == .listening)
        #expect(activity(speaking: true, listening: true) == .speaking)
        #expect(activity(tool: .shell, speaking: true) == .typing)
        #expect(activity(tool: .computer) == .browsing && activity(tool: .browser) == .browsing)
        #expect(activity(tool: .file) == .reading && activity(tool: .search) == .searching)
        #expect(activity(tool: .memory) == .thinking && activity(tool: .connector) == .thinking)
        #expect(activity(celebrating: true, working: false) == .happy)
        #expect(activity(failed: true, celebrating: true, working: false) == .error)
        #expect(activity(waiting: true, failed: true, celebrating: true) == .waiting)
    }

    @Test @MainActor func turnEventsMoveTheOrbsLiveState() {
        let model = model()
        let id = model.bots[0].id
        let live = model.live(id)
        #expect(!live.isWorking && live.status == nil && live.activity == .idle)

        model.apply(.status("Pensando"), to: id)
        #expect(live.isWorking && live.status == "Pensando" && live.activity == .thinking)
        #expect(model.isWorking(id) && model.activity(for: id) == .thinking)

        let shell = call()
        model.apply(.toolStarted(shell), to: id)
        #expect(live.activity == .typing)
        model.apply(.toolFinished(id: shell.id, state: .done, output: "ok"), to: id)
        #expect(live.activity == .thinking)

        model.apply(.text("olá"), to: id)
        #expect(live.activity == .speaking)

        let open = card()
        model.apply(.approval(open), to: id)
        #expect(live.needsYou && live.activity == .waiting && model.needsYou(id))
    }

    @Test @MainActor func aTurnEndsWithTheStatusClearedTheBeatsFlashedAndTheUnreadCounted() async throws {
        let model = model()
        let id = model.bots[1].id
        model.selection = .bot(model.bots[0].id)
        model.providers = [ProviderAccount(kind: .custom)] // usable but without a client: the turn fails at once
        model.defaultModel = "custom/modelo"
        #expect(model.send("oi", to: id))
        let live = model.live(id)
        #expect(live.poke == 1 && live.isWorking && live.isListening)

        model.stop(id)
        #expect(!live.isWorking && live.status == nil && !live.needsYou)
        #expect(live.hasFailed && live.activity == .error)
        #expect(live.unread == 1) // the app is not active in a test: the turn ended while you were elsewhere
    }

    // MARK: Writing only what changes

    @Test @MainActor func aRepeatedStatusNotifiesNobody() {
        let model = model()
        let id = model.bots[0].id
        model.apply(.status("Pensando"), to: id)
        let live = model.live(id)

        expectSilent(reading: { _ = (live.status, live.isWorking, live.activity, live.needsYou) },
                          whenYouDo: { model.apply(.status("Pensando"), to: id) })
        expectNotified(reading: { _ = live.status }, whenYouDo: { model.apply(.status("Lendo"), to: id) })
    }

    @Test @MainActor func aNewStatusLineThatKeepsTheActivityDoesNotReachWhoOnlyShowsTheActivity() {
        let model = model()
        let id = model.bots[0].id
        model.apply(.status("Pensando"), to: id)
        let live = model.live(id)
        // The composer reads isWorking, the avatars the activity: neither changes with the words of the status.
        expectSilent(reading: { _ = (live.isWorking, live.activity) }, whenYouDo: { model.apply(.status("Escrevendo"), to: id) })
    }

    @Test @MainActor func nothingThatDoesNotChangeNotifies() {
        let model = model()
        let id = model.bots[0].id
        let live = model.live(id)
        let everything: @MainActor () -> Void = {
            _ = (live.status, live.isWorking, live.activity, live.needsYou, live.unread, live.look, live.permission, live.modelID,
                 live.bot, live.memory, model.botIDs, model.workingIDs, model.waitingIDs, model.drafts, model.usage)
        }
        expectSilent(reading: everything, whenYouDo: {
            model.apply(.toolFinished(id: UUID(), state: .done, output: nil), to: id) // no tool was running
            model.stop(id) // no turn
            model.setDraft("", for: id)
            model.update(id) { _ in } // no change
            live.setUnread(0)
            live.setMemory(MemorySnapshot())
        })
    }

    @Test @MainActor func writingTheSameThingToAnObservedDictionaryNotifiesNobody() {
        let model = model()
        let id = model.bots[0].id
        model.setDraft("rascunho", for: id)
        expectSilent(reading: { _ = model.drafts[id] }, whenYouDo: { model.setDraft("rascunho", for: id) })
        expectSilent(reading: { _ = model.drafts[id] }, whenYouDo: { model.writeIfChanged(nil, at: UUID(), in: \.drafts) })
        expectNotified(reading: { _ = model.drafts[id] }, whenYouDo: { model.setDraft("outro", for: id) })
        #expect(model.drafts[id] == "outro")
        model.writeIfChanged(nil, at: id, in: \.drafts)
        #expect(model.drafts[id] == nil)
    }

    // MARK: One Orb's change reaches only that Orb

    @Test @MainActor func aToolInOneOrbNotifiesNoViewOfAnother() {
        let model = model()
        let (a, b) = (model.bots[0].id, model.bots[1].id)
        let other = model.live(a)
        let sidebarRowOfA: @MainActor () -> Void = {
            _ = (other.look, other.status, other.activity, other.needsYou, other.unread, other.poke)
        }
        let composerOfA: @MainActor () -> Void = { _ = (other.isWorking, other.permission, other.modelID) }
        let lists: @MainActor () -> Void = { _ = model.botIDs }

        for change: (@MainActor () -> Void) in [
            { model.apply(.status("Pensando"), to: b) },
            { model.apply(.toolStarted(self.call(.file)), to: b) },
            { model.apply(.status("Lendo"), to: b) },
            { model.apply(.approval(self.card()), to: b) },
            { model.update(b) { $0.permissionRules = [.shell("ls")] } },
            { model.update(b) { $0.workingDirectory = "/tmp" } },
        ] {
            expectSilent(reading: sidebarRowOfA, whenYouDo: change)
            expectSilent(reading: composerOfA, whenYouDo: change)
            expectSilent(reading: lists, whenYouDo: change)
        }
    }

    @Test @MainActor func changingAnOrbsSettingsReachesOnlyWhatShowsThatSetting() {
        let model = model()
        let id = model.bots[0].id
        let live = model.live(id)
        // The folder is nothing a row, a title, an avatar or the composer's menus show.
        let showsLookAndMenus: @MainActor () -> Void = { _ = (live.look, live.permission, live.modelID, live.status) }
        expectSilent(reading: showsLookAndMenus, whenYouDo: { model.update(id) { $0.workingDirectory = "/tmp" } })
        expectSilent(reading: showsLookAndMenus, whenYouDo: { model.update(id) { $0.trustedInstructionsHash = "abc" } })
        expectNotified(reading: { _ = live.bot }, whenYouDo: { model.update(id) { $0.trustedInstructionsHash = "def" } })
        expectNotified(reading: { _ = live.permission }, whenYouDo: { model.update(id) { $0.permissionMode = .auto } })
        expectNotified(reading: { _ = live.look }, whenYouDo: { model.update(id) { $0.role = "Outro papel" } })
        expectNotified(reading: { _ = live.modelID }, whenYouDo: { model.update(id) { $0.model = "custom/x" } })
        #expect(live.bot == model.bot(id))
    }

    @Test @MainActor func theListOfOrbsChangesOnlyWhenAnOrbIsAddedDeletedOrMoved() {
        let model = model()
        let ids = model.bots.map(\.id)
        #expect(model.botIDs == ids)
        let list: @MainActor () -> Void = { _ = model.botIDs }

        expectSilent(reading: list, whenYouDo: { model.update(ids[1]) { $0.name = "Luna 2" } })
        expectSilent(reading: list, whenYouDo: { model.apply(.status("Pensando"), to: ids[0]) })
        expectNotified(reading: list, whenYouDo: { model.bots.swapAt(0, 2) })
        #expect(model.botIDs == [ids[2], ids[1], ids[0]])

        let added = model.createBot(name: "Nova", role: "", orb: OrbConfig(), model: "", mode: .ask, interview: false, folder: .home)
        #expect(model.botIDs.last == added.id && model.liveBot(added.id) != nil)
        model.deleteBot(added.id)
        #expect(!model.botIDs.contains(added.id) && model.liveBot(added.id) == nil)
        #expect(model.botIDs == [ids[2], ids[1], ids[0]])
    }

    @Test @MainActor func anOrbThatWasDeletedLeavesAHarmlessStandIn() {
        let model = model()
        let id = model.bots[2].id
        model.deleteBot(id)
        // A late event (a flash timer, a view still on screen) must neither crash nor bring the Orb back.
        model.apply(.status("Pensando"), to: id)
        #expect(model.live(id).bot.name.isEmpty && !model.isWorking(id) && model.workingIDs.isEmpty)
        #expect(model.liveBot(id) == nil)
    }

    // MARK: Who is working, who waits

    @Test @MainActor func theWorkingAndWaitingListsFollowTheOrbsInOrder() {
        let model = model()
        let (a, b, c) = (model.bots[0].id, model.bots[1].id, model.bots[2].id)
        #expect(model.workingIDs.isEmpty && model.waitingIDs.isEmpty)

        model.apply(.status("Pensando"), to: c)
        model.apply(.status("Pensando"), to: a)
        #expect(model.workingIDs == [a, c])
        // A new status line of an Orb that was already working does not touch the list.
        expectSilent(reading: { _ = model.workingIDs }, whenYouDo: { model.apply(.status("Lendo"), to: a) })

        model.apply(.approval(card()), to: c)
        model.apply(.approval(card("pwd")), to: b)
        #expect(model.waitingIDs == [b, c])
        #expect(model.pendingApprovals.map(\.bot.id) == [b, c])
    }

    // MARK: Unread

    @Test @MainActor func unreadLivesApartFromTheBotSoCountingItTouchesNoSettingsView() {
        let model = model()
        let (a, b) = (model.bots[0].id, model.bots[1].id)
        model.selection = .bot(a)
        let botsBefore = model.bots

        expectSilent(reading: { _ = (model.bots, model.live(a).bot, model.live(a).look, model.botIDs) }, whenYouDo: {
            model.live(b).setUnread(1)
        })
        // The end of a turn in the Orb that is not open counts one.
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        #expect(model.send("oi", to: b))
        model.stop(b)
        #expect(model.live(b).unread == 2)
        #expect(model.bots == botsBefore)

        model.selection = .bot(b) // opening the Orb reads them
        #expect(model.live(b).unread == 0)
    }

    @Test @MainActor func unreadIsSavedWithTheStateAndComesBack() throws {
        let model = model()
        let (a, b) = (model.bots[0].id, model.bots[1].id)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        #expect(model.send("oi", to: b))
        model.stop(b)
        model.saveNow()

        let saved = try #require(Store(directory: root).readState().value)
        #expect(saved.unread == [b.uuidString: 1])
        #expect(saved.unread[a.uuidString] == nil)

        let reopened = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        #expect(reopened.live(b).unread == 1 && reopened.live(a).unread == 0)
    }

    @Test @MainActor func readingTheUnreadOrbSchedulesTheSaveThatForgetsIt() throws {
        let model = model()
        let a = model.bots[0].id, b = model.bots[1].id
        model.live(b).setUnread(3)
        model.selection = .bot(a)
        model.selection = .bot(b)
        model.saveNow()
        let saved = try #require(Store(directory: root).readState().value)
        #expect(saved.unread.isEmpty)
    }

    @Test func aFileThatKeptTheCountInsideEachOrbStillLoads() throws {
        let one = UUID(), two = UUID()
        let json = """
        {"bots":[{"id":"\(one.uuidString)","name":"A","role":"x","unread":4},
                 {"id":"\(two.uuidString)","name":"B","role":"y"},
                 {"id":"\(UUID().uuidString)","name":"C","role":"z","unread":"muitas"},
                 {"name":"sem id","unread":9}],
         "routines":[],"skills":[],"connectors":[],"providers":[],"defaultModel":""}
        """
        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        #expect(state.bots.count == 3)
        #expect(state.unread == [one.uuidString: 4])
    }

    @Test func aDamagedCountNeverLosesTheFile() throws {
        let id = UUID()
        let json = #"{"bots":[{"id":"\#(id.uuidString)","name":"A"}],"unread":"muitas"}"#
        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        #expect(state.bots.count == 1 && state.unread.isEmpty)
    }

    @Test func oneDamagedCountKeepsTheOthers() throws {
        let (good, bad) = (UUID(), UUID())
        let json = #"{"bots":[],"unread":{"\#(good.uuidString)":3,"\#(bad.uuidString)":"muitas"}}"#
        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        #expect(state.unread == [good.uuidString: 3])
    }

    @Test func theCountIsNotWrittenInsideTheBotAnyMore() throws {
        var state = AppState(bots: [Bot(name: "A", role: "x", orb: OrbConfig())])
        state.unread = [state.bots[0].id.uuidString: 2]
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        let bot = try #require((object["bots"] as? [[String: Any]])?.first)
        #expect(bot["unread"] == nil)
        #expect((object["unread"] as? [String: Int]) == state.unread)
        // And it round-trips.
        let again = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        #expect(again.unread == state.unread)
    }

    // MARK: Memory

    @Test @MainActor func anOrbsMemoryIsPublishedToItsOwnObjectOnly() async {
        let model = model()
        let (a, b) = (model.bots[0].id, model.bots[1].id)
        await model.refreshMemory(a)
        let other = model.live(b)
        expectSilent(reading: { _ = other.memory }, whenYouDo: { model.live(a).setMemory(MemorySnapshot(identity: "novo")) })
        #expect(model.live(a).memory.identity == "novo")
        // The same snapshot again changes nothing.
        let same = model.live(a).memory
        expectSilent(reading: { _ = model.live(a).memory }, whenYouDo: { model.live(a).setMemory(same) })
    }
}
