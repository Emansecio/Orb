import Foundation
import Testing
@testable import Orb

// The contract types of several Orbs working together (docs/MULTI-ORBS.md, WP0): they save and load, an old file opens
// with defaults, a newer one loses only what it must, and the quiet defaults leave the app as it was.

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

private let atlas = OrbRef(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!, name: "Atlas")
private let revisor = OrbRef(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!, name: "Revisor")

// MARK: - Round trips

struct MultiOrbRoundTripTests {
    @Test func everyNewTypeSurvivesSavingAndLoading() throws {
        let request = UUID(), chain = UUID(), group = UUID()
        let event = OrbEvent(kind: .groupCreated, actor: atlas, subject: revisor, detail: "Lançamento · 3",
                             requestID: request, chainID: chain, groupID: group)
        #expect(try roundTrip(event) == event)

        let message = OrbMessageItem(direction: .sent, kind: .ask, state: .open, from: atlas, to: revisor, text: "Revise o README",
                                     requestID: request, chainID: chain, groupID: group)
        #expect(try roundTrip(message) == message)

        let pause = GroupPauseItem(groupID: group, runID: chain, reason: .tokens, state: .open, turnsUsed: 12, tokensUsed: 150_000,
                                   turnLimit: 12, tokenLimit: 150_000)
        #expect(try roundTrip(pause) == pause)

        let envelope = OrbEnvelope(kind: .reply, from: revisor, to: atlas, text: "Pronto", hop: 2, path: [atlas.id, revisor.id],
                                   replyTo: request, servingRequest: UUID(), status: .ok, groupID: group,
                                   sentAt: Date(timeIntervalSince1970: 1_000_000))
        #expect(try roundTrip(envelope) == envelope)

        let orbGroup = OrbGroup(name: "Lançamento", memberIDs: [atlas.id, revisor.id], orchestratorID: atlas.id,
                                budget: GroupBudget(maxTurns: 8, maxTokens: 100_000), policy: GroupPolicy(membersMayTalk: false))
        #expect(try roundTrip(orbGroup) == orbGroup)

        let proposal = OrbProposal(creator: atlas, name: "Pesquisador", role: "Pesquisa na web", instructions: "Você pesquisa.",
                                   capabilities: [.browser], mode: .ask, modeCeiling: .auto, model: "openai/gpt", reason: "Preciso de ajuda",
                                   creatorCapabilities: [.browser, .terminal], nameTaken: true)
        #expect(try roundTrip(proposal) == proposal)
    }

    @Test func theNewTranscriptItemsSurviveInsideAConversation() throws {
        let event = OrbEvent(kind: .orbCreated, actor: atlas, subject: revisor)
        let message = OrbMessageItem(direction: .reply, kind: .reply, state: .replied, from: revisor, to: atlas, text: "ok",
                                     requestID: UUID(), chainID: UUID())
        let pause = GroupPauseItem(groupID: UUID(), runID: UUID(), reason: .turns, turnsUsed: 1, tokensUsed: 2, turnLimit: 3, tokenLimit: 4)
        var conversation = Conversation()
        conversation.items = [TranscriptItem(.user(text: "oi", attachments: [])), TranscriptItem(.event(event)),
                              TranscriptItem(.orbMessage(message)), TranscriptItem(.groupPause(pause))]
        let back = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        #expect(back.items.map(\.kind) == conversation.items.map(\.kind))
    }

    @Test func aProposalCardSurvivesInsideAnApprovalAndOnlyProposalsAreProposals() throws {
        let proposal = OrbProposal(creator: atlas, name: "Pesquisador")
        let card = ApprovalRequest(toolName: "orb_propose", title: "Atlas quer criar um Orb", command: "Pesquisador", reason: "",
                                   proposal: proposal)
        #expect(card.isProposal)
        #expect(try roundTrip(card) == card)
        #expect(!ApprovalRequest(toolName: "run_command", title: "t", command: "ls", reason: "").isProposal)
        // A proposal this version cannot read leaves a card that is still answerable, not a lost conversation.
        let json = #"{"toolName":"orb_propose","title":"t","command":"c","reason":"","proposal":{"name":3}}"#
        let broken = try decode(ApprovalRequest.self, json)
        #expect(!broken.isProposal && broken.toolName == "orb_propose")
    }

    @Test func theGroupsOfTheStateSurviveSaving() throws {
        let group = OrbGroup(name: "Time", memberIDs: [atlas.id, revisor.id], orchestratorID: revisor.id)
        var state = AppState(bots: [])
        state.groups = [group]
        let back = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        #expect(back.groups == [group])
    }

    @Test @MainActor func theModelKeepsItsGroupsAcrossLaunches() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbGroups-\(UUID().uuidString)")
        defer { removeTestFolder(folder) }
        let model = AppModel(store: Store(directory: folder), runsBackgroundWork: false, secretVault: MemoryVault())
        // The members are Orbs that exist (a group of Orbs that are gone is dropped when the app opens, see `normalizeGroups`).
        let second = Bot(name: "Revisor", role: "Revisa código", orb: OrbConfig())
        model.bots.append(second)
        let group = OrbGroup(name: "Time", memberIDs: [model.bots[0].id, second.id], orchestratorID: model.bots[0].id)
        model.groups = [group]
        await waitUntil("the state with the group is saved") { Store(directory: folder).readState().value?.groups == [group] }
        let again = AppModel(store: Store(directory: folder), runsBackgroundWork: false, secretVault: MemoryVault())
        #expect(again.groups == [group])
    }
}

// MARK: - Old and newer files

struct MultiOrbCompatibilityTests {
    @Test func aStateFromBeforeGroupsOpensWithNone() throws {
        let state = try decode(AppState.self, #"{"bots":[{"id":"00000000-0000-4000-8000-0000000000A1","name":"Atlas"}]}"#)
        #expect(state.groups.isEmpty)
        #expect(state.bots.count == 1)
        #expect(state.bots[0].createdBy == nil && state.bots[0].createdByName == nil && state.bots[0].createdAt == nil)
    }

    @Test func aDamagedGroupIsDroppedAndTheOthersStay() throws {
        let good = #"{"name":"Time","memberIDs":["00000000-0000-4000-8000-0000000000A1","00000000-0000-4000-8000-0000000000B2"],"#
            + #""orchestratorID":"00000000-0000-4000-8000-0000000000A1"}"#
        let state = try decode(AppState.self, #"{"bots":[],"groups":[\#(good),"not a group",{"name":7}]}"#)
        #expect(state.groups.count == 1 && state.groups[0].name == "Time")
    }

    @Test func aGroupMissingFieldsGetsDefaults() throws {
        let one = "00000000-0000-4000-8000-0000000000A1"
        let group = try decode(OrbGroup.self, #"{"memberIDs":["\#(one)"]}"#)
        #expect(group.budget == GroupBudget() && group.policy == GroupPolicy())
        #expect(group.orchestratorID == UUID(uuidString: one))
        #expect(group.budget.maxTurns == 12 && group.budget.maxTokens == 150_000)
    }

    @Test func aBotWithAnUnreadableOriginStillLoads() throws {
        let bot = try decode(Bot.self, #"{"id":"00000000-0000-4000-8000-0000000000A1","name":"Filho","createdBy":42,"createdByName":["x"],"createdAt":"ontem"}"#)
        #expect(bot.name == "Filho")
        #expect(bot.createdBy == nil && bot.createdByName == nil && bot.createdAt == nil)
    }

    @Test func aBotKeepsItsOrigin() throws {
        var bot = Bot(name: "Filho", role: "", orb: OrbConfig())
        bot.createdBy = atlas.id
        bot.createdByName = "Atlas"
        bot.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(try roundTrip(bot) == bot)
    }

    @Test func anOldConversationOpensAsItWas() throws {
        let json = #"{"items":[{"kind":{"user":{"text":"oi","attachments":[]}}},{"kind":{"notice":{"_0":"aviso"}}}],"messages":[]}"#
        let conversation = try decode(Conversation.self, json)
        #expect(conversation.items.count == 2)
    }

    @Test func anItemFromANewerVersionIsDroppedWithoutLosingTheConversation() throws {
        let json = #"{"items":[{"kind":{"user":{"text":"oi","attachments":[]}}},{"kind":{"coisaDoFuturo":{"x":1}}},{"kind":{"notice":{"_0":"fica"}}}],"messages":[]}"#
        let read = try DecodeLoss.measure { try decode(Conversation.self, json) }
        #expect(read.value.items.count == 2)
        #expect(read.skipped == 1)
    }

    @Test func unknownCasesInsideTheNewTypesFallBackInsteadOfFailing() throws {
        let ids = #""requestID":"00000000-0000-4000-8000-0000000000C3","chainID":"00000000-0000-4000-8000-0000000000D4""#
        let from = #""from":{"id":"00000000-0000-4000-8000-0000000000A1","name":"Atlas"}"#
        let message = try decode(OrbMessageItem.self, #"{"direction":"sideways","kind":"shout","state":"limbo",\#(from),\#(ids)}"#)
        #expect(message.direction == .received && message.kind == .tell && message.state == .lost)
        #expect(message.text.isEmpty && message.to == nil && message.groupID == nil)

        let event = try decode(OrbEvent.self, #"{"kind":"somethingNew","detail":"x"}"#)
        #expect(event.kind == .unknown)

        let envelope = try decode(OrbEnvelope.self, #"{"id":"00000000-0000-4000-8000-0000000000C3","chainID":"00000000-0000-4000-8000-0000000000D4","kind":"?","from":{"id":"00000000-0000-4000-8000-0000000000A1","name":"A"},"to":{"id":"00000000-0000-4000-8000-0000000000B2","name":"B"}}"#)
        #expect(envelope.kind == .tell && envelope.hop == 1 && envelope.path.isEmpty && envelope.text.isEmpty)

        let pause = try decode(GroupPauseItem.self, #"{"groupID":"00000000-0000-4000-8000-0000000000C3","runID":"00000000-0000-4000-8000-0000000000D4","reason":"x","state":"y"}"#)
        #expect(pause.reason == .turns && pause.state == .ended)
    }

    @Test func aMessageWithoutItsIdsIsNotReadSoTheListAroundItDropsIt() throws {
        let from = #""from":{"id":"00000000-0000-4000-8000-0000000000A1","name":"Atlas"}"#
        #expect(throws: (any Error).self) { try decode(OrbMessageItem.self, #"{\#(from),"text":"sem ids"}"#) }
    }

    @Test func aToolCallOfAnUnknownKindStillFallsBackToConnector() throws {
        let call = try decode(ToolCall.self, #"{"kind":"naoExiste","title":"x"}"#)
        #expect(call.kind == .connector)
        #expect(try decode(ToolCall.self, #"{"kind":"orbs","title":"x"}"#).kind == .orbs)
        #expect(ToolCall.Kind.orbs.symbol == "bubble.left.and.bubble.right")
    }

    @Test func theNewUsageSourcesAreKeptAndAnUnknownOneIsChat() throws {
        for source in [UsageSource.delegation, .group, .creation] { #expect(try roundTrip(source) == source) }
        #expect(try decode(UsageSource.self, "\"daqui-a-pouco\"") == .chat)
        #expect(try decode(UsageSource.self, "\"routine\"") == .routine)
    }
}

// MARK: - Interrupted turns

struct MultiOrbInterruptedTurnTests {
    private func message(_ direction: OrbMessageItem.Direction, _ state: OrbMessageItem.State) -> TranscriptItem {
        TranscriptItem(.orbMessage(OrbMessageItem(direction: direction, kind: .ask, state: state, from: atlas, to: revisor, text: "x",
                                                  requestID: UUID(), chainID: UUID())))
    }

    @Test func aRequestStillOpenWhenTheAppClosedIsLostAndTheRestStaysAsItWas() {
        var conversation = Conversation()
        conversation.items = [message(.sent, .open), message(.sent, .replied), message(.received, .open), message(.reply, .open)]
        let kinds = conversation.closingInterruptedTurn().items.map(\.kind)
        func state(_ index: Int) -> OrbMessageItem.State? { if case .orbMessage(let m) = kinds[index] { m.state } else { nil } }
        #expect(state(0) == .lost)
        #expect(state(1) == .replied)
        #expect(state(2) == .open) // not a request this Orb sent: nothing here is waiting for an answer
        #expect(state(3) == .open)
    }

    @Test func aPauseCardNobodyCanAnswerAnymoreEnds() {
        var conversation = Conversation()
        let open = GroupPauseItem(groupID: UUID(), runID: UUID(), reason: .turns, turnsUsed: 1, tokensUsed: 1, turnLimit: 1, tokenLimit: 1)
        var continued = open
        continued.state = .continued
        conversation.items = [TranscriptItem(.groupPause(open)), TranscriptItem(.groupPause(continued))]
        let states = conversation.closingInterruptedTurn().items.compactMap { item -> GroupPauseItem.State? in
            if case .groupPause(let pause) = item.kind { pause.state } else { nil }
        }
        #expect(states == [.ended, .continued])
    }
}

// MARK: - Sentences

struct OrbEventSentenceTests {
    private func sentence(_ kind: OrbEvent.Kind, actor: OrbRef? = nil, subject: OrbRef? = nil, detail: String? = nil) -> String {
        OrbEvent(kind: kind, actor: actor, subject: subject, detail: detail).sentence
    }

    @Test func eachKindReadsAsTheContractSays() {
        let pesquisador = OrbRef(id: UUID(), name: "Pesquisador")
        let lia = OrbRef(id: UUID(), name: "Lia")
        #expect(sentence(.orbCreated, actor: atlas, subject: pesquisador) == "Atlas criou o Pesquisador")
        #expect(sentence(.orbCreated, actor: atlas, subject: lia) == "Atlas criou a Lia")
        #expect(sentence(.joinedGroup, subject: revisor, detail: "Lançamento") == "Revisor entrou no grupo Lançamento")
        #expect(sentence(.leftGroup, subject: revisor, detail: "Lançamento") == "Revisor saiu do grupo Lançamento")
        #expect(sentence(.groupCreated, detail: "Lançamento · 3") == "Grupo Lançamento criado com 3 Orbs")
        #expect(sentence(.routineCreated, actor: atlas, detail: "Resumo diário") == "Atlas criou a rotina “Resumo diário”")
        #expect(sentence(.renamed, actor: atlas, detail: "Mapa") == "Atlas agora se chama Mapa")
        #expect(sentence(.chainStopped) == "Você parou a conversa entre Orbs")
        #expect(sentence(.groupRunDone, detail: "5 turnos · 42 mil tokens") == "Pedido concluído: 5 turnos · 42 mil tokens")
        #expect(sentence(.groupStopped) == "Você parou o grupo")
        #expect(sentence(.delegationReceived, actor: atlas, subject: revisor) == "Atlas pediu ajuda ao Revisor")
        #expect(sentence(.delegationReceived, actor: revisor, subject: lia) == "Revisor pediu ajuda à Lia")
    }

    @Test func aGroupNameWithTheSeparatorKeepsItsWordsAndOneOrbReadsInTheSingular() {
        #expect(sentence(.groupCreated, detail: "A · B · 4") == "Grupo A · B criado com 4 Orbs")
        #expect(sentence(.groupCreated, detail: "Sozinho · 1") == "Grupo Sozinho criado com 1 Orb")
        #expect(sentence(.groupCreated, detail: "Sem contagem") == "Grupo Sem contagem criado")
    }

    @Test func missingPartsNeverCrashAndNeverLeaveAHole() {
        for kind in [OrbEvent.Kind.orbCreated, .joinedGroup, .leftGroup, .groupCreated, .routineCreated, .renamed, .chainStopped,
                     .groupRunDone, .groupStopped, .delegationReceived] {
            #expect(!sentence(kind).isEmpty, "\(kind)")
        }
        #expect(sentence(.unknown) == "")
        #expect(sentence(.unknown, detail: "texto") == "texto")
    }

    @Test func theSentenceIsPure() {
        let event = OrbEvent(kind: .orbCreated, actor: atlas, subject: revisor)
        #expect(event.sentence == event.sentence)
    }
}

struct PortugueseArticleTests {
    @Test func aNameEndingInAIsFeminineAndAnyOtherIsMasculine() {
        #expect(PortugueseArticle.article(for: "Atlas") == "o")
        #expect(PortugueseArticle.article(for: "Lia") == "a")
        #expect(PortugueseArticle.article(for: "Pesquisadora") == "a")
        #expect(PortugueseArticle.article(for: "Pesquisador") == "o")
        #expect(PortugueseArticle.article(for: "Revisor") == "o")
    }

    @Test func accentsCaseAndTrailingMarksDoNotMatter() {
        #expect(PortugueseArticle.article(for: "JÚLIA") == "a")
        #expect(PortugueseArticle.article(for: "Lia 2") == "a")
        #expect(PortugueseArticle.article(for: "  Lia!  ") == "a")
        #expect(PortugueseArticle.article(for: "Orbê") == "o")
    }

    @Test func anEmptyOrLetterlessNameIsMasculineAndNeverAnError() {
        #expect(PortugueseArticle.article(for: "") == "o")
        #expect(PortugueseArticle.article(for: "123") == "o")
    }

    @Test func theContractionFollowsTheArticle() {
        #expect(PortugueseArticle.contraction(for: "Revisor") == "ao")
        #expect(PortugueseArticle.contraction(for: "Lia") == "à")
    }
}

// MARK: - Invariants

struct MultiOrbInvariantTests {
    private func group(_ members: [UUID], orchestrator: UUID) -> OrbGroup {
        OrbGroup(name: "G", memberIDs: members, orchestratorID: orchestrator)
    }

    @Test func membersThatAreGoneLeaveAndTheOrchestratorIsReplacedByTheFirstMember() {
        let a = UUID(), b = UUID(), c = UUID(), gone = UUID()
        let normalized = group([a, gone, b, c], orchestrator: gone).normalized(alive: [a, b, c])
        #expect(normalized?.memberIDs == [a, b, c])
        #expect(normalized?.orchestratorID == a)
    }

    @Test func anOrchestratorStillThereStays() {
        let a = UUID(), b = UUID()
        #expect(group([a, b], orchestrator: b).normalized(alive: [a, b])?.orchestratorID == b)
    }

    @Test func aGroupLeftWithFewerThanTwoMembersIsDissolved() {
        let a = UUID(), b = UUID()
        #expect(group([a, b], orchestrator: a).normalized(alive: [a]) == nil)
        #expect(group([a, b], orchestrator: a).normalized(alive: []) == nil)
        #expect(group([a], orchestrator: a).normalized(alive: [a]) == nil)
    }

    @Test func aRepeatedMemberCountsOnceAndAGroupNeverHasMoreThanEight() {
        let a = UUID(), b = UUID()
        #expect(group([a, a], orchestrator: a).normalized(alive: [a, b]) == nil)
        let ten = (0..<10).map { _ in UUID() }
        let capped = group(ten, orchestrator: ten[9]).normalized(alive: Set(ten))
        #expect(capped?.memberIDs == Array(ten.prefix(8)))
        #expect(capped?.orchestratorID == ten[0])
        #expect(OrbGroup.memberLimits == 2...8)
    }

    @Test func theLimitsAreTheOnesTheContractNames() {
        #expect(DelegationLimits.maxHops == 4 && DelegationLimits.maxOpenPerOrb == 3)
        #expect(DelegationLimits.maxMessagesPerChain == 12 && DelegationLimits.maxTurnsPerChain == 10)
        #expect(DelegationLimits.maxTokensPerChain == 200_000 && DelegationLimits.maxPerPair == 3)
        #expect(DelegationLimits.messageLimit == 4_000 && DelegationLimits.replyLimit == 6_000)
        #expect(DelegationLimits.replyLimit > DelegationLimits.messageLimit)
    }

    @Test func everyRefusalSaysSomethingInPortugueseAndNamesWhatMatters() {
        let refusals: [DelegationRefusal] = [.switchedOff, .unknownOrb("Zé"), .selfRequest, .notInGroup, .hopLimit, .alreadyInChain("Revisor"),
                                             .tooManyOpen, .budgetSpent, .pairLimit, .duplicate, .emptyMessage, .tooLong, .orbBusyDeleting]
        for refusal in refusals { #expect(!refusal.message.isEmpty && refusal.toolError.message == refusal.message) }
        #expect(DelegationRefusal.hopLimit.message == "Limite de 4 encadeamentos atingido: responda com o que tem.")
        #expect(DelegationRefusal.alreadyInChain("Revisor").message == "Revisor já está esperando por você nesta conversa.")
        #expect(DelegationRefusal.tooManyOpen.message == "Você já tem 3 pedidos abertos; espere as respostas.")
        #expect(DelegationRefusal.budgetSpent.message == "O orçamento desta conversa entre Orbs acabou.")
        #expect(DelegationRefusal.duplicate.message == "Pedido idêntico já enviado.")
        #expect(DelegationRefusal.unknownOrb("Zé").message.contains("Zé"))
    }

    @Test func theProposalOutcomesSayWhatTheContractSays() {
        #expect(ProposalOutcome.created(name: "Pesquisador", folder: "~/Orbs/Pesquisador").modelText
            == "O usuário criou o Orb Pesquisador (pasta ~/Orbs/Pesquisador). Você pode pedir trabalho a ele com orbs.")
        #expect(ProposalOutcome.declined.modelText == "O usuário não quis criar esse Orb. Não proponha de novo.")
        #expect(ProposalOutcome.createdEdited(name: "P", folder: "~/Orbs/P", summary: "nome").modelText.contains("com ajustes: nome"))
        #expect(ProposalOutcome.failed("Limite").modelText == "Limite")
    }

    @Test func aDraftCanBeCreatedOnlyWithAName() {
        var draft = OrbDraft()
        #expect(!draft.canCreate)
        draft.name = "  "
        #expect(!draft.canCreate)
        draft.name = "Lia"
        #expect(draft.canCreate)
        #expect(draft.mode == .ask && draft.capabilities == [.terminal, .browser, .computerUse] && draft.revision == 0 && !draft.ready)
    }
}

// MARK: - The quiet runtime

@MainActor
struct DelegationShellTests {
    @Test func theShellRefusesEverythingAndHoldsNothing() {
        let hub = DelegationHub()
        #expect(throws: DelegationRefusal.switchedOff) {
            try hub.submit(from: atlas.id, to: "Revisor", text: "oi", kind: .ask, messageID: UUID(), groupID: nil)
        }
        let chain = ChainContext(chainID: UUID(), hop: 1, path: [atlas.id])
        let turn = hub.submitGroupTurn(member: revisor.id, text: "x", chain: chain, groupID: UUID(), askedBy: nil)
        #expect(turn.state == .failed && turn.envelope.to.id == revisor.id && turn.envelope.chainID == chain.chainID)
        hub.cancelChain(chain.chainID, by: .user)
        hub.tokensUsed(10, chain: chain.chainID)
        #expect(hub.chains(involving: atlas.id).isEmpty)
        #expect(hub.openRequests(from: atlas.id).isEmpty)
        #expect(hub.roster(for: atlas.id, groupID: nil).isEmpty)
        #expect(hub.groupHooks == nil)
    }

    @Test func theModelCarriesTheShellsAndTheSwitchIsOnByDefault() throws {
        let suite = "OrbMultiOrb-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbShell-\(UUID().uuidString)")
        defer { removeTestFolder(folder) }
        let model = AppModel(store: Store(directory: folder), runsBackgroundWork: false, secretVault: MemoryVault())
        model.preferences = defaults
        #expect(model.orbsCanTalk)
        model.orbsCanTalk = false
        #expect(!model.orbsCanTalk)
        model.orbsCanTalk = true
        #expect(model.orbsCanTalk)
        #expect(model.groups.isEmpty && model.groupSessions.isEmpty && model.groupLives.isEmpty)
    }
}

// MARK: - Tools and permission

struct MultiOrbToolOfferTests {
    private let everything: Set<Capability> = [.terminal, .browser, .computerUse, .connectors]

    private func names(_ multi: MultiOrbOffering = MultiOrbOffering(), _ capabilities: Set<Capability> = [.terminal, .browser, .computerUse]) -> Set<String> {
        Set(ToolBox.offered(for: capabilities, accessibilityGranted: true, multi: multi).map(\.spec.name))
    }

    @Test func withoutTheOfferingNothingChanges() {
        let plain = Set(ToolBox.offered(for: everything, accessibilityGranted: true).map(\.spec.name))
        #expect(names(MultiOrbOffering(), everything) == plain)
        for name in ["orbs", "orb_propose", "orb_draft", "group_remember", "group_recall"] { #expect(!plain.contains(name), "\(name)") }
        #expect(!ToolBox.all.contains { ["orbs", "orb_propose", "orb_draft", "group_remember", "group_recall"].contains($0.spec.name) })
    }

    @Test func eachSwitchOffersItsOwnTools() {
        let base = names()
        #expect(names(MultiOrbOffering(orbs: true)).subtracting(base) == ["orbs"])
        #expect(names(MultiOrbOffering(propose: true)).subtracting(base) == ["orb_propose"])
        #expect(names(MultiOrbOffering(groupMemory: true)).subtracting(base) == ["group_remember", "group_recall"])
        #expect(names(MultiOrbOffering(orbs: true, propose: true, groupMemory: true)).subtracting(base).count == 4)
    }

    @Test func theDraftToolIsNeverOfferedToAnOrbOnlyToTheAssistant() {
        #expect(!names(MultiOrbOffering(orbs: true, propose: true, groupMemory: true)).contains("orb_draft"))
        #expect(ToolBox.wizardTools.map(\.spec.name) == ["orb_draft"])
    }

    @Test func everySpecIsShortAndWellFormed() {
        for tool in ToolBox.multiOrbTools + ToolBox.wizardTools {
            #expect(!tool.spec.description.isEmpty, "\(tool.spec.name)")
            #expect(tool.spec.parameters["type"] == .string("object"), "\(tool.spec.name)")
            #expect(tool.spec.parameters["required"]?.array?.isEmpty != true, "\(tool.spec.name)")
            #expect(tool.kind == (tool.spec.name.hasPrefix("group_") ? .memory : .orbs), "\(tool.spec.name)")
        }
    }

    @Test func theToolsSayWhatTheyWillDoAndTheNotWiredOnesRefuseAtRunTime() async {
        let orbs = OrbsTool()
        #expect(orbs.summary(.object(["action": .string("ask"), "to": .string("Revisor"), "message": .string("Revise")])) == ("Falando com Revisor", "Revise"))
        #expect(orbs.summary(.object(["action": .string("tell"), "to": .string("Revisor"), "message": .string("Oi")])) == ("Avisando Revisor", "Oi"))
        #expect(orbs.summary(.object(["action": .string("list")])) == ("Vendo o time", ""))
        #expect(OrbProposeTool().summary(.object(["name": .string("Lia")])) == ("Propondo um Orb", "Lia"))
        #expect(OrbDraftTool().summary(.object(["name": .string("Lia")])) == ("Montando o Orb", "Lia"))
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        await #expect(throws: ToolError.self) { try await orbs.run(.object(["action": .string("list")]), context: context) }
        await #expect(throws: ToolError.self) { try await OrbProposeTool().run(.object([:]), context: context) }
        await #expect(throws: ToolError.self) { try await OrbDraftTool().run(.object([:]), context: context) }
        await #expect(throws: ToolError.self) { try await GroupRecallTool().run(.object(["query": .string("x")]), context: context) }
    }

    @Test func aWiredHandlerIsWhatTheToolsCall() async throws {
        var context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        context.orbs = { arguments in "visto: \(arguments["action"]?.string ?? "")" }
        #expect(try await OrbsTool().run(.object(["action": .string("list")]), context: context) == "visto: list")
        context.draft = { _ in "rascunho" }
        #expect(try await OrbDraftTool().run(.object([:]), context: context) == "rascunho")
    }
}

struct MultiOrbPermissionTests {
    private let home = URL(fileURLWithPath: "/Users/teste")
    private let grant = [PermissionRule(family: .delegation)]

    private func call(_ action: String?, tool: any AgentTool = OrbsTool()) -> PermissionCall {
        let arguments: JSONValue = action.map { .object(["action": .string($0), "to": .string("Revisor"), "message": .string("oi")]) } ?? .object([:])
        return PermissionPolicy.call(for: tool, arguments: arguments, context: ToolContext(workingDirectory: home), home: home)
    }

    private func verdict(_ mode: PermissionMode, _ call: PermissionCall, grants: [PermissionRule] = []) -> PermissionVerdict {
        PermissionPolicy.evaluate(mode: mode, call: call, rules: [], turnGrants: grants, workspace: nil, home: home)
    }

    @Test func theToolsBelongToTheirFamilies() {
        #expect(call("ask").family == .delegation)
        #expect(call("list").family == .delegation)
        #expect(call(nil, tool: GroupRememberTool()).family == .groupMemory)
        #expect(call(nil, tool: GroupRecallTool()).family == .groupMemory)
        #expect(PermissionPolicy.family(ofTool: "algo_novo", kind: .orbs) == .delegation)
    }

    @Test func askingAndTellingDependOnTheModeAndTheTurnsGrant() {
        for action in ["ask", "tell"] {
            let c = call(action)
            #expect(c.risk == .sensitive)
            #expect(verdict(.readOnly, c, grants: grant) == .deny(PermissionPolicy.readOnlyDenial))
            #expect(verdict(.readOnly, c) == .deny(PermissionPolicy.readOnlyDenial))
            for mode in [PermissionMode.ask, .auto, .bypass] { #expect(verdict(mode, c, grants: grant) == .allow, "\(action) \(mode)") }
            // Without the grant "Perguntar antes" asks; the others do not.
            #expect(verdict(.ask, c) == .ask(.needsPermission))
            #expect(verdict(.auto, c) == .allow && verdict(.bypass, c) == .allow)
        }
    }

    @Test func listingAlwaysRunsAndAMissingActionIsTheWholeToolSoItAsks() {
        for mode in PermissionMode.allCases { #expect(verdict(mode, call("list")) == .allow, "\(mode)") }
        #expect(call(nil).risk == .sensitive)
        #expect(call("sideways").risk == .sensitive)
    }

    @Test func theFamiliesOfDelegationAreNeverOfferedAsStandingGrants() {
        for action in ["ask", "tell"] {
            #expect(PermissionPolicy.suggestions(for: call(action)).isEmpty)
        }
        #expect(PermissionPolicy.suggestions(for: call(nil, tool: GroupRememberTool())).isEmpty)
        // A standing rule for it never covers a call without the "any" scope either way, and a scoped one is not valid.
        let scoped = PermissionRule(family: .delegation, scope: .host("x.com"))
        #expect(!scoped.isValid)
        #expect(!PermissionPolicy.isCovered(call("ask"), by: [scoped]))
        #expect(PermissionPolicy.isCovered(call("ask"), by: grant))
        #expect(!grant[0].title.isEmpty && !PermissionRule(family: .groupMemory).title.isEmpty)
    }

    @Test func theProposalAndTheDraftAreSafeForThePermissionCheck() {
        let propose = PermissionPolicy.call(for: OrbProposeTool(), arguments: .object(["name": .string("x")]),
                                            context: ToolContext(workingDirectory: home), home: home)
        #expect(propose.risk == .safe)
        for mode in PermissionMode.allCases { #expect(verdict(mode, propose) == .allow) }
    }

    @Test func aFactForTheGroupBoardIsCoveredByTheGroupsGrantButAPreferenceStillAsks() {
        let fact = PermissionPolicy.call(for: GroupRememberTool(), arguments: .object(["fact": .string("x"), "tipo": .string("fato")]),
                                         context: ToolContext(workingDirectory: home), home: home)
        let preference = PermissionPolicy.call(for: GroupRememberTool(), arguments: .object(["fact": .string("x"), "tipo": .string("preferencia")]),
                                               context: ToolContext(workingDirectory: home), home: home)
        let grants = [PermissionRule(family: .groupMemory)]
        #expect(verdict(.ask, fact, grants: grants) == .allow)
        #expect(verdict(.ask, fact) == .ask(.needsPermission))
        #expect(verdict(.ask, preference, grants: grants) == .ask(.instructs))
    }

}

// MARK: - The Orb's face

struct MultiOrbActivityTests {
    @Test func conversingLooksLikeAttentiveAndRestsLikeIt() {
        let conversing = OrbActivity.conversing
        #expect(conversing.label == "Conversando" && conversing.symbol == "bubble.left.and.bubble.right")
        #expect(conversing.hasSameFace(as: .attentive, mouth: "sorriso"))
        #expect(conversing.eyes == nil && conversing.brows == nil && conversing.bubble == nil && conversing.mouth(base: "sorriso") == nil)
        #expect(!conversing.isTool && conversing.energy == 0 && conversing.minFrameRate == 10 && conversing.wander == 0.2)
        #expect(OrbActivity.allCases.contains(.conversing))
    }

    @Test func itsGazeGoesToTheChatAndBackAndItsBodyLeansGently() {
        let toChat = OrbActivity.conversing.gaze(at: 0.5)
        let middle = OrbActivity.conversing.gaze(at: 2.0)
        #expect(toChat.look == CGPoint(x: 0.7, y: 0.05) && toChat.pointerWeight == 0.25)
        #expect(middle.look == .zero)
        let body = OrbActivity.conversing.motion(at: 1.0)
        #expect(abs(body.tilt) <= 2.0001 && body.shake == 0)
    }

    @Test func itRanksBelowEverythingTheOrbDoesAndAboveWatchingYouType() {
        func activity(working: Bool = false, tool: ToolCall.Kind? = nil, composing: Bool = false, conversing: Bool = false,
                      awaiting: Bool = false) -> OrbActivity {
            BotLive.activity(awaitingApproval: awaiting, failed: false, celebrating: false, isWorking: working, tool: tool,
                             speaking: false, listening: false, composing: composing, conversing: conversing)
        }
        #expect(activity(conversing: true) == .conversing)
        #expect(activity(composing: true, conversing: true) == .conversing)
        #expect(activity(composing: true) == .attentive)
        #expect(activity() == .idle)
        #expect(activity(working: true, conversing: true) == .thinking)
        #expect(activity(working: true, tool: .orbs) == .conversing)
        #expect(activity(working: true, tool: .shell, conversing: true) == .typing)
        #expect(activity(conversing: true, awaiting: true) == .waiting)
    }

    @Test @MainActor func theLiveStateHoldsWhatTheRuntimeWillWriteAndWritesOnlyWhatChanged() {
        let live = BotLive(Bot(name: "Atlas", role: "", orb: OrbConfig()))
        #expect(live.chainWork == nil && live.partner == nil && !live.isConversing && live.shownWork == nil)
        let waiting = WorkLine(verb: "Esperando", target: "Pesquisador")
        live.setChainWork(waiting)
        #expect(live.shownWork == waiting)
        live.setStatus("Pensando…")
        #expect(live.shownWork != waiting) // a running turn's own phrase comes first
        live.setStatus(nil)
        #expect(live.shownWork == waiting)
        live.setChainWork(nil)
        #expect(live.shownWork == nil)
        let tint = PartnerTint(botID: UUID(), color: "rosa")
        live.setPartner(tint)
        #expect(live.partner == tint)
        live.isConversing = true
        #expect(live.activity == .conversing)
        live.isConversing = false
        #expect(live.activity == .idle)
    }
}

// MARK: - Screens

struct MultiOrbScreenTests {
    @Test func theNewSelectionIsAnItemOfTheSidebar() {
        let id = UUID()
        #expect(SidebarItem.group(id) != SidebarItem.bot(id))
        #expect(DetailPage.page(for: .group(id), botIDs: [id]) == .orb)
    }

    @Test @MainActor func theSnapshotChainKnowsNoScreenYet() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbSnap-\(UUID().uuidString)")
        defer { removeTestFolder(folder) }
        let model = AppModel(store: Store(directory: folder), runsBackgroundWork: false, secretVault: MemoryVault())
        // "events" and the delegation screens belong to WP2, the creation card's to WP3, the groups' to WP6, the wizard's to WP4.
        for screen in ["settings-general-orbs", "transcript"] {
            #expect(MultiOrbSnapshots.view(screen, model: model) == nil, "\(screen)")
        }
        #expect(MultiOrbSnapshots.view("group-chat", model: model) != nil) // WP6
        // The creation card's modes are registered (WP3).
        for screen in ["orb-proposal", "orb-proposal-editing", "orb-proposal-created", "orb-proposal-dismissed", "orb-proposal-narrow",
                       "orb-created-sidebar"] {
            #expect(MultiOrbSnapshots.view(screen, model: model) != nil, "\(screen)")
        }
    }
}
