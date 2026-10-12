import Foundation
import Testing
@testable import Orb

// Groups of Orbs (docs/MULTI-ORBS.md, 7.1): making and changing them, the invariants that keep them true to the Orbs that exist,
// and what is saved of them.

private func exists(_ root: URL, _ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appending(path: path).path) }

@MainActor private func chatEvents(_ model: AppModel, _ botID: UUID) -> [OrbEvent] {
    model.transcript(botID).compactMap { if case .event(let event) = $0.kind { event } else { nil } }
}

struct OrbGroupMakingTests {
    @Test @MainActor func aGroupNeedsTwoToEightExistingDistinctOrbs() {
        let world = GroupWorld(names: (1...9).map { "Orb\($0)" }, makesGroup: false)
        let ids = world.bots.map(\.id)
        let model = world.model
        #expect(model.createGroup(name: "x", members: [ids[0]]) == nil)
        #expect(model.createGroup(name: "x", members: [ids[0], ids[0]]) == nil)
        #expect(model.createGroup(name: "x", members: [ids[0], UUID()]) == nil)
        #expect(model.createGroup(name: "x", members: ids) == nil)
        #expect(model.groups.isEmpty)
        #expect(model.createGroup(name: "x", members: Array(ids[0..<8]))?.memberIDs.count == 8)
    }

    @Test @MainActor func theFirstOrbIsTheOrchestratorUnlessAMemberIsChosen() {
        let world = GroupWorld(names: ["Atlas", "Lia", "Revisor", "Teo"], makesGroup: false)
        let ids = world.bots.map(\.id)
        let first = world.model.createGroup(name: "A", members: [ids[0], ids[1]])
        #expect(first?.orchestratorID == ids[0])
        let chosen = world.model.createGroup(name: "B", members: [ids[1], ids[2], ids[3]], orchestrator: ids[3])
        #expect(chosen?.orchestratorID == ids[3] && chosen?.memberIDs == [ids[1], ids[2], ids[3]])
        let stranger = world.model.createGroup(name: "C", members: [ids[1], ids[2]], orchestrator: ids[0])
        #expect(stranger?.orchestratorID == ids[1]) // not a member: the first one
    }

    @Test @MainActor func aBlankNameBecomesTheMembersNames() {
        let world = GroupWorld(makesGroup: false)
        let group = world.model.createGroup(name: "   ", members: world.bots.map(\.id))
        #expect(group?.name == "Atlas, Pesquisador e Revisor")
    }

    @Test @MainActor func theThreadAndTheMembersChatsSayTheGroupWasMade() {
        let world = GroupWorld()
        #expect(world.events.map(\.kind) == [.groupCreated])
        #expect(world.events.first?.sentence == "Grupo Lançamento criado com 3 Orbs")
        for bot in world.bots {
            let joined = chatEvents(world.model, bot.id).filter { $0.kind == .joinedGroup }
            #expect(joined.count == 1 && joined[0].subject?.id == bot.id && joined[0].groupID == world.groupID)
            #expect(joined[0].sentence == "\(bot.name) entrou no grupo Lançamento")
        }
    }

    @Test @MainActor func theObjectiveIsTheGoalOnTheBoard() async throws {
        let world = GroupWorld(makesGroup: false)
        let group = try #require(world.model.createGroup(name: "G", members: world.bots.map(\.id), objective: "Lançar a versão 2 em outubro."))
        let bank = world.model.memory.groupBank(for: group.id)
        await waitUntil("the goal to be on the board") { await bank.identity()?.body == "Lançar a versão 2 em outubro." }
        let brief = await GroupBoard.brief(bank: bank, message: "oi")
        #expect(brief.contains("Goal: Lançar a versão 2 em outubro."))
    }

    @Test @MainActor func renamingChangingTheBudgetAndThePolicyAreSavedWithTheState() throws {
        let world = GroupWorld()
        world.model.renameGroup(world.groupID, to: "  Produto  ")
        world.model.renameGroup(world.groupID, to: "   ") // ignored
        world.model.setGroupBudget(.wide, of: world.groupID)
        world.model.setGroupPolicy(GroupPolicy(membersMayTalk: false), of: world.groupID)
        let group = try #require(world.model.group(world.groupID))
        #expect(group.name == "Produto" && group.budget == GroupBudget(maxTurns: 24, maxTokens: 300_000) && !group.policy.membersMayTalk)
        world.model.saveNow()
        #expect(world.store.readState().value?.groups == [group])
    }

    @Test @MainActor func theBudgetPresetsAreTheOnesOfTheDocument() {
        #expect(GroupBudget.economic == GroupBudget(maxTurns: 8, maxTokens: 100_000))
        #expect(GroupBudget.balanced == GroupBudget())
        #expect(GroupBudget.wide == GroupBudget(maxTurns: 24, maxTokens: 300_000))
    }
}

struct OrbGroupMembershipTests {
    @Test @MainActor func addingAMemberWritesTheEventsAndStopsAtEight() throws {
        let world = GroupWorld(names: (1...9).map { "Orb\($0)" }, members: 3)
        let ids = world.bots.map(\.id)
        #expect(world.model.addMember(ids[3], to: world.groupID))
        #expect(!world.model.addMember(ids[3], to: world.groupID)) // already in
        #expect(!world.model.addMember(UUID(), to: world.groupID))
        #expect(world.events.last?.kind == .joinedGroup && world.events.last?.subject?.name == "Orb4")
        #expect(chatEvents(world.model, ids[3]).contains { $0.kind == .joinedGroup })
        for index in 4..<8 { #expect(world.model.addMember(ids[index], to: world.groupID)) }
        #expect(world.model.group(world.groupID)?.memberIDs.count == 8)
        #expect(!world.model.addMember(ids[8], to: world.groupID))
    }

    @Test @MainActor func removingAMemberLeavesTheGroupWithTheOthersAndTellsBothChats() throws {
        let world = GroupWorld()
        #expect(world.model.removeMember(world.revisor.id, from: world.groupID))
        #expect(world.model.group(world.groupID)?.memberIDs == [world.atlas.id, world.pesquisador.id])
        #expect(world.events.last?.kind == .leftGroup && world.events.last?.sentence == "Revisor saiu do grupo Lançamento")
        #expect(chatEvents(world.model, world.revisor.id).contains { $0.kind == .leftGroup })
        #expect(!world.model.removeMember(world.revisor.id, from: world.groupID)) // no longer in
    }

    @Test @MainActor func removingTheOrchestratorPassesTheRoleToTheFirstMember() {
        let world = GroupWorld()
        world.model.removeMember(world.atlas.id, from: world.groupID)
        #expect(world.model.group(world.groupID)?.orchestratorID == world.pesquisador.id)
    }

    @Test @MainActor func changingTheOrchestratorNeedsAMember() {
        let world = GroupWorld(members: 2)
        #expect(world.model.setOrchestrator(world.pesquisador.id, of: world.groupID))
        #expect(world.model.group(world.groupID)?.orchestratorID == world.pesquisador.id)
        #expect(!world.model.setOrchestrator(world.revisor.id, of: world.groupID)) // not a member
        #expect(world.model.group(world.groupID)?.orchestratorID == world.pesquisador.id)
    }

    @Test @MainActor func aThreadWhoseWriteFailedStaysUnsavedAndIsNotLetGoOf() async throws {
        let world = GroupWorld()
        // A file where the groups' folder goes: the write fails.
        let folder = world.root.appending(path: "conversations/\(GroupFiles.threadFolder)")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder)
        world.session.append(.user(text: "oi", attachments: []))
        world.model.saveGroupSessionsNow()
        #expect(!world.session.isDirty)
        world.store.flush()
        #expect(await waitUntil("the failed write marks the thread unsaved") { world.session.isDirty })
        world.model.unloadIdleGroupSessions(idle: .zero)
        #expect(world.model.groupSessions[world.groupID] != nil)
    }

    @Test @MainActor func takingOutOneOfTwoDissolvesTheGroup() async {
        let world = GroupWorld(members: 2)
        let id = world.groupID
        world.session.append(.user(text: "oi", attachments: []))
        world.model.saveGroupSessionsNow()
        world.store.flush()
        #expect(exists(world.root, "conversations/_grupos/\(id.uuidString).json"))
        await world.model.memory.groupBank(for: id).remember("combinado", kind: .preferencia)
        #expect(exists(world.root, "memoria/_grupos/\(id.uuidString)"))

        #expect(world.model.removeMember(world.pesquisador.id, from: id))
        world.store.flush()
        #expect(world.model.group(id) == nil && world.model.groups.isEmpty)
        #expect(world.model.groupSessions[id] == nil)
        #expect(!exists(world.root, "conversations/_grupos/\(id.uuidString).json"))
        #expect(!exists(world.root, "memoria/_grupos/\(id.uuidString)"))
        // The Orb that stays is told in its own chat.
        let notes = chatEvents(world.model, world.atlas.id).filter { $0.kind == .unknown }
        #expect(notes.count == 1 && notes[0].sentence.contains("foi desfeito") && notes[0].sentence.contains("Lançamento"))
    }
}

struct OrbGroupInvariantTests {
    @Test @MainActor func aMemberThatNoLongerExistsLeavesAndAMissingOrchestratorIsReplaced() {
        let world = GroupWorld()
        world.model.bots.removeAll { $0.id == world.atlas.id } // the orchestrator is gone
        let group = world.model.group(world.groupID)
        #expect(group?.memberIDs == [world.pesquisador.id, world.revisor.id])
        #expect(group?.orchestratorID == world.pesquisador.id)
    }

    @Test @MainActor func aGroupLeftWithLessThanTwoMembersIsDissolvedWhenAnOrbDisappears() {
        let world = GroupWorld(members: 2)
        let id = world.groupID
        world.model.bots.removeAll { $0.id == world.pesquisador.id }
        #expect(world.model.groups.isEmpty)
        #expect(world.model.groupSessions[id] == nil)
        #expect(chatEvents(world.model, world.atlas.id).contains { $0.kind == .unknown && $0.sentence.contains("foi desfeito") })
    }

    @Test @MainActor func aGroupOfOrbsThatAreGoneIsDroppedWhenTheStateIsRead() {
        let world = GroupWorld(members: 2)
        var state = AppState(bots: world.model.bots)
        state.groups = [OrbGroup(name: "Fantasma", memberIDs: [UUID(), UUID()], orchestratorID: UUID()),
                        OrbGroup(name: "Meio", memberIDs: [world.atlas.id, UUID(), world.revisor.id], orchestratorID: UUID())]
        world.store.save(state)
        world.store.flush()
        let reopened = AppModel(store: world.store, runsBackgroundWork: false)
        #expect(reopened.groups.map(\.name) == ["Meio"])
        #expect(reopened.groups[0].memberIDs == [world.atlas.id, world.revisor.id])
        #expect(reopened.groups[0].orchestratorID == world.atlas.id)
    }

    @Test @MainActor func deletingAnOrbLeavesItsGroupsAndTheThreadSaysWho() throws {
        let world = GroupWorld()
        _ = world.model.deleteBot(world.revisor.id)
        #expect(world.model.group(world.groupID)?.memberIDs == [world.atlas.id, world.pesquisador.id])
        #expect(world.events.last?.kind == .leftGroup)
        #expect(world.events.last?.sentence == "Revisor saiu do grupo Lançamento")
        // The orchestrator goes next: the group of two is dissolved.
        _ = world.model.deleteBot(world.atlas.id)
        #expect(world.model.groups.isEmpty)
        #expect(chatEvents(world.model, world.pesquisador.id).contains { $0.sentence.contains("foi desfeito") })
    }

    @Test @MainActor func deletingTheOrchestratorOfThreePassesTheRole() {
        let world = GroupWorld()
        _ = world.model.deleteBot(world.atlas.id)
        #expect(world.model.group(world.groupID)?.orchestratorID == world.pesquisador.id)
    }

    @Test @MainActor func deletingAGroupKeepsTheOrbsAndRemovesEverythingOfTheGroup() async {
        let world = GroupWorld()
        let id = world.groupID
        world.session.append(.user(text: "oi", attachments: []))
        world.model.saveGroupSessionsNow()
        world.store.flush()
        await world.model.memory.groupBank(for: id).remember("fato do grupo")
        world.model.selection = .group(id)
        world.model.deleteGroup(id)
        world.store.flush()
        #expect(world.model.groups.isEmpty && world.model.bots.count == 3)
        #expect(!exists(world.root, "conversations/_grupos/\(id.uuidString).json"))
        #expect(!exists(world.root, "memoria/_grupos/\(id.uuidString)"))
        #expect(world.model.selection == .bot(world.atlas.id)) // the open group is gone: the first Orb
    }

    @Test @MainActor func aGroupOfOrbsIsSavedAndComesBack() throws {
        let world = GroupWorld()
        world.model.postUserMessage("Olá, grupo", to: world.groupID)
        world.model.saveNow()
        let reopened = AppModel(store: world.store, runsBackgroundWork: false)
        #expect(reopened.groups == world.model.groups)
        let session = try #require(reopened.groupSession(world.groupID))
        #expect(session.items.contains { if case .user(let text, _) = $0.kind { text == "Olá, grupo" } else { false } })
    }
}
