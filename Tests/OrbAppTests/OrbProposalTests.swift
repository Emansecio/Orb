import Foundation
import Testing
@testable import Orb

// Orb creates Orb (WP3): the inheritance rules, the card's flow in both engines, the provenance and the tools server.

private func creator(mode: PermissionMode = .ask, capabilities: Set<Capability> = [.terminal, .browser, .computerUse],
                     model: String = "") -> Bot {
    var bot = Bot(name: "Atlas", role: "", orb: OrbConfig(), model: model, permissionMode: mode)
    bot.capabilities = capabilities
    return bot
}

private func args(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }

// MARK: - The rules of 4.2

struct OrbProposalTests {
    private let base: [String: JSONValue] = ["name": .string("Pesquisador"), "role": .string("Pesquisa"), "instructions": .string("Pesquise.")]

    private func make(_ extra: [String: JSONValue] = [:], from bot: Bot = creator(), names: [String] = []) -> OrbProposal {
        OrbProposal.make(from: bot, args: args(base.merging(extra) { $1 }), existingNames: names)
    }

    @Test func theChildNeverHasMoreThanTheCreatorAndNeverConnectors() {
        let asked = make(["capabilities": .array([.string("terminal"), .string("browser"), .string("computerUse"), .string("connectors")])],
                         from: creator(capabilities: [.terminal, .connectors]))
        #expect(asked.capabilities == [.terminal])
        #expect(asked.creatorCapabilities == [.terminal], "the card offers no switch the creator lacks")
        #expect(make(["capabilities": .array([.string("browser")])], from: creator(capabilities: [.terminal])).capabilities == [])
    }

    @Test func nothingAskedForInheritsWhatTheCreatorHasWithoutConnectors() {
        #expect(make().capabilities == [.terminal, .browser, .computerUse])
        #expect(make(from: creator(capabilities: [.browser, .connectors])).capabilities == [.browser])
        #expect(make(["capabilities": .array([.string("telepathy")])]).capabilities == [.terminal, .browser, .computerUse])
    }

    @Test func theModeIsAskedFirstAndCappedByTheCreatorsOwn() {
        #expect(make(from: creator(mode: .ask)).mode == .ask && make(from: creator(mode: .ask)).modeCeiling == .ask)
        #expect(make(from: creator(mode: .auto)).mode == .ask && make(from: creator(mode: .auto)).modeCeiling == .auto)
        #expect(make(from: creator(mode: .readOnly)).mode == .readOnly && make(from: creator(mode: .readOnly)).modeCeiling == .readOnly)
        let bypass = make(from: creator(mode: .bypass))
        #expect(bypass.mode != .bypass && bypass.modeCeiling == .auto, "never Sem pedir permissão")
        #expect(!bypass.allowedModes.contains(.bypass) && make(from: creator(mode: .ask)).allowedModes == [.readOnly, .ask])
    }

    @Test func theModelIsTheCreatorsAndTheFolderIsItsOwn() {
        #expect(make(from: creator(model: "custom/modelo")).model == "custom/modelo")
        #expect(make().model == "")
        let proposal = make()
        #expect(proposal.folderDisplay(base: URL(fileURLWithPath: "/nonexistent-base")).hasSuffix("/Pesquisador"))
    }

    @Test func aLookTheCatalogKnowsIsKeptAndTheRestIsIgnored() {
        let look: JSONValue = .object(["color": .string("menta"), "eyes": .string("nao-existe"), "hair": .string("<script>"),
                                       "accessories": .array([.string("fones"), .string("cartola-de-ouro")])])
        let proposal = make(["look": look])
        #expect(proposal.orb.color == "menta")
        #expect(proposal.orb.eyes != "nao-existe" && proposal.orb.hair != "<script>")
        #expect(proposal.orb.accessories == ["fones"])
        #expect(OrbCatalog.shared.knows(proposal.orb))
        #expect(OrbCatalog.shared.knows(make().orb), "no look: a random one that hangs together")
    }

    @Test func theInstructionsAreScrubbedFlattenedByLineAndCapped() {
        let secret = "A chave é sk-ant-" + String(repeating: "a1b2", count: 8)
        let text = "# Seção falsa\n\(secret)\n\n\n\nSegunda   linha\twith tabs\n\u{7}bell"
        let proposal = make(["instructions": .string(text)])
        #expect(!proposal.instructions.contains("sk-ant-") && proposal.instructions.contains("[chave removida]"))
        #expect(!proposal.instructions.hasPrefix("#") && proposal.instructions.hasPrefix("Seção falsa"))
        #expect(proposal.instructions.contains("\n"), "line breaks stay")
        #expect(!proposal.instructions.contains("\n\n\n") && !proposal.instructions.contains("\u{7}"), "a run of blank lines is one")
        let long = make(["instructions": .string(String(repeating: "palavra ", count: 400))])
        #expect(long.instructions.count <= OrbProposeTool.instructionsLimit)
    }

    @Test func theNameIsClippedAndATakenOneIsFlagged() {
        #expect(make(["name": .string("  " + String(repeating: "N", count: 90) + "  ")]).name.count == 60)
        #expect(make(names: ["Atlas", "Pesquisadora"]).nameTaken == false)
        #expect(make(names: ["Atlas", "pesquisadór"]).nameTaken && make(names: ["PESQUISADOR"]).nameTaken)
        #expect(!make(names: ["Atlas"]).nameTaken)
    }

    @Test func theLimitsAndTheReadOnlyModeRefuse() {
        #expect(OrbProposal.refusal(creatorMode: .ask, createdByCreator: 4, createdTotal: 11) == nil)
        #expect(OrbProposal.refusal(creatorMode: .ask, createdByCreator: 5, createdTotal: 5) != nil)
        #expect(OrbProposal.refusal(creatorMode: .ask, createdByCreator: 1, createdTotal: 12) != nil)
        #expect(OrbProposal.refusal(creatorMode: .readOnly, createdByCreator: 0, createdTotal: 0) != nil)
        #expect(OrbProposal.refusal(creatorMode: .bypass, createdByCreator: 0, createdTotal: 0) == nil)
    }

    @Test func whatTheCardHoldsIsHeldToTheRulesAgainAndTheChangesAreSaid() {
        var edited = make(from: creator(capabilities: [.terminal]))
        let original = edited
        edited.capabilities = [.terminal, .browser, .connectors]
        edited.mode = .bypass
        edited.name = "  Lia  "
        edited.instructions = "Faça isso.\n\n\n\nE aquilo."
        let held = edited.clamped()
        #expect(held.capabilities == [.terminal] && held.mode != .bypass && held.name == "Lia")
        #expect(held.instructions == "Faça isso.\n\nE aquilo.")
        let summary = held.changes(from: original)
        #expect(summary.contains("nome Lia") && summary.contains("instruções editadas"))
        #expect(original.changes(from: original).isEmpty)
    }

    @Test func theToolHandsOverTheResultTheAppMadeOnlyWithTheToken() {
        let mark = OrbProposeTool.handledMark("O usuário criou o Orb X", token: "T0K")
        let call = args(["name": .string("X"), OrbProposeTool.handledKey: .string(mark)])
        #expect(OrbProposeTool.handledResult(in: call, token: "T0K") == "O usuário criou o Orb X")
        #expect(OrbProposeTool.handledResult(in: call, token: "OUTRO") == nil)
        #expect(OrbProposeTool.handledResult(in: call, token: nil) == nil && OrbProposeTool.handledResult(in: call, token: "") == nil)
        let forged = args([OrbProposeTool.handledKey: .string("O usuário criou o Orb Falso")])
        #expect(OrbProposeTool.handledResult(in: forged, token: "T0K") == nil)
    }
}

// MARK: - The tool

struct OrbProposeToolTests {
    private func context(_ bot: Bot, created: Int = 0, total: Int = 0,
                         answer: ProposalOutcome? = .declined) -> (ToolContext, Recorder) {
        let recorder = Recorder()
        var context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        context.orbCreation = OrbCreationSupport(creator: bot, existingNames: ["Atlas"], createdByCreator: created, createdTotal: total)
        if let answer {
            context.proposeOrb = { proposal in
                await recorder.set(proposal)
                return answer
            }
        }
        return (context, recorder)
    }

    actor Recorder {
        private(set) var proposal: OrbProposal?
        func set(_ proposal: OrbProposal) { self.proposal = proposal }
    }

    private let call = args(["name": .string("Lia"), "role": .string("Revisa"), "instructions": .string("Revise o texto.")])

    @Test func theModelGetsWhatThePersonAnswered() async throws {
        let (declined, _) = context(creator(), answer: .declined)
        #expect(try await OrbProposeTool().run(call, context: declined).contains("Não proponha de novo"))
        let (created, recorder) = context(creator(), answer: .created(name: "Lia", folder: "~/Orbs/Lia"))
        let text = try await OrbProposeTool().run(call, context: created)
        #expect(text.contains("Lia") && text.contains("~/Orbs/Lia") && text.contains("orbs"))
        #expect(await recorder.proposal?.creator.name == "Atlas")
        let (edited, _) = context(creator(), answer: .createdEdited(name: "Lia", folder: "~/Orbs/Lia", summary: "sem Web"))
        #expect(try await OrbProposeTool().run(call, context: edited).contains("com ajustes: sem Web"))
    }

    @Test func itRefusesInReadOnlyAtTheLimitsAndWithoutNameOrInstructions() async {
        let (readOnly, a) = context(creator(mode: .readOnly))
        await #expect(throws: ToolError.self) { try await OrbProposeTool().run(call, context: readOnly) }
        let (own, _) = context(creator(), created: 5)
        await #expect(throws: ToolError.self) { try await OrbProposeTool().run(call, context: own) }
        let (all, _) = context(creator(), total: 12)
        await #expect(throws: ToolError.self) { try await OrbProposeTool().run(call, context: all) }
        let (open, b) = context(creator())
        await #expect(throws: ToolError.self) { try await OrbProposeTool().run(args(["name": .string(" "), "instructions": .string("x")]), context: open) }
        await #expect(throws: ToolError.self) { try await OrbProposeTool().run(args(["name": .string("Lia")]), context: open) }
        let first = await a.proposal, second = await b.proposal
        #expect(first == nil && second == nil, "no card for a call that is refused")
    }

    @Test func aFailureOfTheAppIsAnErrorForTheModel() async {
        let (failing, _) = context(creator(), answer: .failed("Sem espaço"))
        await #expect(throws: ToolError.self) { try await OrbProposeTool().run(call, context: failing) }
    }

    @Test func withNobodyToAnswerItIsUnavailable() async {
        var bare = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        bare.orbCreation = OrbCreationSupport(creator: creator())
        await #expect(throws: ToolError.self) { try await OrbProposeTool().run(call, context: bare) }
    }
}

// MARK: - The card in the app

private actor Script {
    private var responses: [[LLMEvent]]
    init(_ responses: [[LLMEvent]]) { self.responses = responses }
    func next() -> [LLMEvent] { responses.isEmpty ? [.text("fim"), .finished(.done, nil)] : responses.removeFirst() }
}

private struct ScriptedLLM: LLMClient {
    let script: Script
    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for event in await script.next() { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

@Suite final class OrbProposeFlowTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbPropose-\(UUID().uuidString)")

    init() { QuietNotifications.hold() }

    deinit {
        QuietNotifications.release()
        removeTestFolder(root)
    }

    private func proposeCall(_ extra: [String: JSONValue] = [:]) -> LLMEvent {
        let fields: [String: JSONValue] = ["name": .string("Pesquisador"), "role": .string("Pesquisa na web"),
                                          "instructions": .string("Pesquise e resuma."), "reason": .string("Para pesquisar.")]
        let arguments = JSONValue.object(fields.merging(extra) { $1 }).jsonString
        return .toolCalls([ToolCallRequest(id: "c1", name: "orb_propose", arguments: arguments)])
    }

    @MainActor private func setUp(mode: PermissionMode = .ask, extra: [String: JSONValue] = [:],
                                  second: [LLMEvent] = [.text("Combinado."), .finished(.done, nil)]) -> (AppModel, Bot) {
        var state = AppState.initial
        state.bots[0].permissionMode = mode
        let folder = root.appending(path: "atlas")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        state.bots[0].workingDirectory = folder.path
        Store(directory: root).save(state)
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.proposedOrbFolderBase = root.appending(path: "Orbs")
        let script = Script([[proposeCall(extra), .finished(.toolUse, nil)], second])
        model.clientOverride = { ScriptedLLM(script: script) }
        return (model, model.bots[0])
    }

    @MainActor private func openCard(_ model: AppModel, _ bot: Bot) async -> ApprovalRequest? {
        #expect(model.send("crie um pesquisador", to: bot.id))
        _ = await waitUntil("the creation card") { !model.pendingApprovals(of: bot.id).isEmpty }
        return model.pendingApprovals(of: bot.id).first
    }

    @MainActor private func toolResult(_ model: AppModel, _ bot: Bot) -> String? {
        model.session(bot.id).conversation?.messages.first { $0.role == .tool }?.content
    }

    @Test @MainActor func criarMakesTheOrbWithItsProvenanceAndLeavesTheSelectionAlone() async throws {
        let (model, atlas) = setUp()
        model.selection = .bot(atlas.id)
        let card = try #require(await openCard(model, atlas))
        #expect(card.isProposal && card.title == "Atlas quer criar um Orb" && card.proposal?.name == "Pesquisador")
        #expect(model.needsYou(atlas.id), "Precisa de você")
        #expect(model.bots.count == 1, "nothing exists until the person accepts")

        model.decide(.once, approvalID: card.id, botID: atlas.id)
        _ = await waitUntil("the Orb to exist") { model.bots.count == 2 }
        let child = try #require(model.bots.last)
        #expect(child.name == "Pesquisador" && child.createdBy == atlas.id && child.createdByName == "Atlas" && child.createdAt != nil)
        #expect(child.workingDirectory == root.appending(path: "Orbs/Pesquisador").path)
        #expect(FileManager.default.fileExists(atPath: child.workingDirectory))
        #expect(!child.capabilities.contains(.connectors) && model.connectors(for: child.id).isEmpty)
        #expect(child.permissionMode == .ask)
        #expect(model.selection == .bot(atlas.id), "the person is reading Atlas")

        _ = await waitUntil("the turn to end") { !model.isWorking(atlas.id) }
        let events = model.transcript(atlas.id).compactMap { item -> OrbEvent? in if case .event(let event) = item.kind { event } else { nil } }
        #expect(events.map(\.kind) == [.orbCreated] && events.first?.subject?.id == child.id && events.first?.sentence == "Atlas criou o Pesquisador")
        #expect(toolResult(model, atlas)?.contains("O usuário criou o Orb Pesquisador") == true)
        #expect(toolResult(model, atlas)?.contains("Orbs/Pesquisador") == true)
        // The provenance survives the file.
        let saved = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(child))
        #expect(saved.createdBy == atlas.id && saved.createdByName == "Atlas")
        model.deleteBot(atlas.id)
        #expect(model.bot(child.id)?.createdByName == "Atlas", "deleting the creator keeps the name")
    }

    @Test @MainActor func naoCriarCreatesNothingAndTheModelIsToldNotToAskAgain() async throws {
        let (model, atlas) = setUp()
        let card = try #require(await openCard(model, atlas))
        model.decide(.deny, approvalID: card.id, botID: atlas.id)
        _ = await waitUntil("the turn to end") { !model.isWorking(atlas.id) && toolResult(model, atlas) != nil }
        #expect(model.bots.count == 1)
        #expect(toolResult(model, atlas)?.contains("Não proponha de novo") == true)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Orbs/Pesquisador").path))
        #expect(model.transcript(atlas.id).allSatisfy { if case .event = $0.kind { false } else { true } })
    }

    @Test @MainActor func editarAntesChangesWhatIsCreatedAndTheModelIsToldWhat() async throws {
        let (model, atlas) = setUp()
        let card = try #require(await openCard(model, atlas))
        var edited = try #require(card.proposal)
        edited.name = "Lia"
        edited.capabilities = [.terminal]
        edited.mode = .auto
        edited.instructions = "Revise com cuidado."
        model.updateProposal(edited, approvalID: card.id, botID: atlas.id)
        model.decide(.once, approvalID: card.id, botID: atlas.id)
        _ = await waitUntil("the Orb to exist") { model.bots.count == 2 }
        let child = try #require(model.bots.last)
        #expect(child.name == "Lia" && child.capabilities == [.terminal])
        // Atlas is in "Perguntar antes": "Automático" is past what it may hand down.
        #expect(child.permissionMode == .ask)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Orbs/Lia").path))
        _ = await waitUntil("the result") { toolResult(model, atlas) != nil }
        let result = toolResult(model, atlas) ?? ""
        #expect(result.contains("com ajustes") && result.contains("nome Lia") && result.contains("sem Navegar na web"))
        let bank = model.memory.bank(for: child.id)
        #expect(await bank.identity()?.body.contains("Revise com cuidado.") == true)
    }

    @Test @MainActor func theCardAsksEvenWithoutAskingPermission() async throws {
        let (model, atlas) = setUp(mode: .bypass)
        let card = try #require(await openCard(model, atlas))
        #expect(card.isProposal)
        #expect(card.proposal?.modeCeiling == .auto && card.proposal?.mode == .ask)
        // A change of mode does not answer it.
        model.update(atlas.id) { $0.permissionMode = .auto }
        #expect(model.isPending(card.id, of: atlas.id))
        #expect(model.bots.count == 1)
        model.decide(.deny, approvalID: card.id, botID: atlas.id)
    }

    @Test @MainActor func inReadOnlyTheToolRefusesAndNoCardOpens() async throws {
        let (model, atlas) = setUp(mode: .readOnly)
        #expect(model.send("crie um pesquisador", to: atlas.id))
        _ = await waitUntil("the turn to end") { toolResult(model, atlas) != nil && !model.isWorking(atlas.id) }
        #expect(model.pendingApprovals(of: atlas.id).isEmpty && model.bots.count == 1)
        #expect(toolResult(model, atlas)?.contains("read-only") == true)
    }

    @Test @MainActor func stoppingTheOrbCancelsTheCard() async throws {
        let (model, atlas) = setUp()
        let card = try #require(await openCard(model, atlas))
        model.stop(atlas.id)
        _ = await waitUntil("the card to be answered") { !model.isPending(card.id, of: atlas.id) }
        _ = await waitUntil("the Orb to stop") { !model.isWorking(atlas.id) }
        #expect(model.bots.count == 1)
    }

    @Test @MainActor func aTakenNameFlagsTheCardAndTheFolderGetsAnotherName() async throws {
        let (model, atlas) = setUp()
        model.createBot(name: "Pesquisador", role: "", orb: OrbConfig(), model: "", mode: .ask, interview: false,
                        folder: .own, base: root.appending(path: "Orbs"))
        model.selection = .bot(atlas.id)
        let card = try #require(await openCard(model, atlas))
        #expect(card.proposal?.nameTaken == true)
        model.decide(.once, approvalID: card.id, botID: atlas.id)
        _ = await waitUntil("the Orb to exist") { model.bots.count == 3 }
        #expect(model.bots.last?.workingDirectory == root.appending(path: "Orbs/Pesquisador 2").path)
    }

    @Test @MainActor func theLimitsCountTheOrbsThatExist() async throws {
        let (model, atlas) = setUp()
        for index in 0..<OrbProposal.perCreatorLimit {
            var child = Bot(name: "Filho \(index)", role: "", orb: OrbConfig())
            child.createdBy = atlas.id
            model.bots.append(child)
        }
        #expect(model.send("crie mais um", to: atlas.id))
        _ = await waitUntil("the turn to end") { toolResult(model, atlas) != nil && !model.isWorking(atlas.id) }
        #expect(model.pendingApprovals(of: atlas.id).isEmpty)
        #expect(toolResult(model, atlas)?.contains("already created 5") == true)
        #expect(model.bots.count == 6)
    }

    @Test @MainActor func theToolIsOfferedOnlyInTheOrbsOwnChat() {
        let (model, atlas) = setUp()
        let session = model.session(atlas.id)
        #expect(model.multiOrbOffering(for: atlas.id).propose)
        session.routineID = UUID()
        #expect(!model.multiOrbOffering(for: atlas.id).propose)
        session.routineID = nil
        session.sideKind = .delegation
        #expect(!model.multiOrbOffering(for: atlas.id).propose)
        session.sideKind = nil
    }

    @Test @MainActor func aCardLeftOpenWhenTheAppClosesIsRecordedAsNotCreated() async throws {
        let (model, atlas) = setUp()
        let card = try #require(await openCard(model, atlas))
        let conversation = try #require(model.session(atlas.id).conversation).closingInterruptedTurn()
        let kept = conversation.items.compactMap { item -> ApprovalRequest? in if case .approval(let request) = item.kind { request } else { nil } }
        #expect(kept.first?.id == card.id && kept.first?.decision == .deny && kept.first?.proposal?.name == "Pesquisador")
        model.decide(.deny, approvalID: card.id, botID: atlas.id)
    }
}

// MARK: - Words

struct ProposalSpeechTests {
    @Test func theExcerptEndsInASingleEllipsisNeverAfterThePeriod() {
        let text = "Pesquise na web quando eu pedir, compare as fontes e devolva um resumo curto com os links.\nGuarde o que achou em notas na sua pasta.\nSe a pergunta for vaga, pergunte antes."
        // Cut by lines: the period of the last kept line goes, the ellipsis stays.
        let byLines = ProposalSpeech.excerpt(text, maxLines: 2, maxCharacters: 500)
        #expect(byLines.hasSuffix("sua pasta…") && !byLines.contains("...") && !byLines.contains(".…"))
        // Cut by length: at a word, with punctuation and blanks dropped.
        let byLength = ProposalSpeech.excerpt("Primeiro passo, depois o segundo; e então o terceiro passo do trabalho todo.", maxLines: 3, maxCharacters: 40)
        #expect(byLength.hasSuffix("…") && !byLength.hasSuffix(",…") && !byLength.hasSuffix(" …") && byLength.filter { $0 == "…" }.count == 1)
        // What fits stays whole, period and all.
        #expect(ProposalSpeech.excerpt("Pesquise e resuma.") == "Pesquise e resuma.")
        #expect(ProposalSpeech.excerpt("a\nb\nc") == "a\nb\nc")
        #expect(ProposalSpeech.excerpt("Acabou!!!\nmais\nmais\nmais", maxLines: 1) == "Acabou…")
    }

    @Test func theCardIsReadAsOneSentence() {
        let proposal = OrbProposal(creator: OrbRef(id: UUID(), name: "Atlas"), name: "Pesquisador", role: "Cuida de pesquisas",
                                   capabilities: [.terminal, .browser])
        #expect(ProposalSpeech.card(proposal) == "Atlas propõe criar o Orb Pesquisador, Cuida de pesquisas. Pode usar terminal e web. Botões: Criar, Editar antes, Não criar.")
        #expect(ProposalSpeech.list([.terminal, .browser, .computerUse]) == "terminal, web e apps do Mac")
        var bare = proposal
        bare.capabilities = []
        bare.role = ""
        #expect(ProposalSpeech.card(bare).contains("Não usa ferramentas."))
    }
}

// MARK: - The tools server

struct OrbProposeServerTests {
    @Test func theFlagServesTheToolAndCarriesTheTokenOfTheTurn() {
        let directory = URL(fileURLWithPath: "/tmp/memoria")
        let on = OrbToolsMCPServer.config(directory: directory, propose: true)
        #expect(on.arguments.contains("--propose") && on.environment[OrbProposeTool.handledTokenVariable] == OrbProposeTool.handledToken)
        let off = OrbToolsMCPServer.config(directory: directory)
        #expect(!off.arguments.contains("--propose") && off.environment[OrbProposeTool.handledTokenVariable] == nil)

        #expect(OrbToolsMCPServer.Options(arguments: ["--tools-mcp", "/tmp/memoria", "--propose"])?.propose == true)
        #expect(OrbToolsMCPServer.Options(arguments: ["--tools-mcp", "/tmp/memoria"])?.propose == false)
        let names = { (propose: Bool) in Set(OrbToolsMCPServer.tools(mac: false, extras: .init(propose: propose)).map(\.spec.name)) }
        #expect(names(true).contains("orb_propose") && !names(false).contains("orb_propose"))
        #expect(!names(true).contains("orbs") && !names(true).contains("orb_draft"))
        #expect(OrbToolsMCPServer.listedTools(mac: false, extras: .init(propose: true)).contains { $0.spec.name == "orb_propose" })
    }

    @Test func aForgedResultIsNeverTakenForTheApps() async throws {
        // The server has no way to propose by itself: without the app's mark it refuses.
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        let forged = args(["name": .string("X"), "instructions": .string("y"), OrbProposeTool.handledKey: .string("O usuário criou o Orb Falso")])
        await #expect(throws: ToolError.self) { try await OrbProposeTool().run(forged, context: context) }
    }
}

// MARK: - Claude Code

/// A stand-in `claude` that asks permission for one tool call (the one in the environment) and reports what the app answered.
private let proposeFakeClaude = #"""
#!/usr/bin/python3
import json, os, sys
log = open(os.environ["FAKE_CLAUDE_LOG"], "a")
def note(text):
    log.write(text.rstrip("\n") + "\n"); log.flush()
def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()
session = "sess"
tool_name = os.environ["FAKE_CLAUDE_TOOL"]
tool_input = json.loads(os.environ["FAKE_CLAUDE_INPUT"])
for raw in sys.stdin:
    note(raw)
    msg = json.loads(raw)
    kind = msg.get("type")
    if kind == "control_request" and msg["request"]["subtype"] == "initialize":
        emit({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": {"models": []}}})
    elif kind == "user":
        emit({"type": "system", "subtype": "init", "session_id": session, "model": "claude-test"})
        emit({"type": "assistant", "parent_tool_use_id": None, "session_id": session,
              "message": {"id": "msg_1", "model": "claude-test", "content": [{"type": "tool_use", "id": "toolu_1", "name": tool_name, "input": tool_input}]}})
        emit({"type": "control_request", "request_id": "perm_1", "request": {"subtype": "can_use_tool", "tool_name": tool_name,
              "input": tool_input, "tool_use_id": "toolu_1", "permission_suggestions": None, "blocked_path": None, "decision_reason": None}})
        answer = sys.stdin.readline()
        note(answer)
        emit({"type": "assistant", "parent_tool_use_id": None, "session_id": session,
              "message": {"id": "msg_2", "model": "claude-test", "content": [{"type": "text", "text": "Pronto."}]}})
        emit({"type": "result", "subtype": "success", "is_error": False, "num_turns": 2, "session_id": session, "result": "Pronto."})
note("eof")
"""#

struct ClaudeCodeProposeTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-propose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: directory.appendingPathComponent("claude").path, contents: Data(proposeFakeClaude.utf8),
                                       attributes: [.posixPermissions: 0o755])
    }

    private var log: URL { directory.appendingPathComponent("log.txt") }

    private func turn(mode: PermissionMode = .ask, input: String, support: Bool = true,
                      create: @escaping OrbCreationHandler = { _, _ in .created(name: "Pesquisador", folder: "~/Orbs/Pesquisador") }) -> ClaudeCodeTurn {
        var bot = Bot(name: "Atlas", role: "", orb: OrbConfig(), permissionMode: mode)
        bot.workingDirectory = directory.path
        var turn = ClaudeCodeTurn(bot: bot, executable: directory.appendingPathComponent("claude"), model: "sonnet", system: "persona",
                                  prompt: "crie um pesquisador", sessionID: nil,
                                  environment: ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE_LOG": log.path,
                                                "FAKE_CLAUDE_TOOL": ClaudeCodeEngine.orbPropose, "FAKE_CLAUDE_INPUT": input])
        if support { turn.orbCreation = OrbCreationSupport(creator: bot, existingNames: ["Atlas"], create: create) }
        return turn
    }

    private func run(_ turn: ClaudeCodeTurn, decision: ApprovalDecision = .once) async -> [TurnEvent] {
        let engine = ClaudeCodeEngine()
        var events: [TurnEvent] = []
        for await event in engine.run(turn) {
            events.append(event)
            if case .approval(let card) = event { await engine.gate.resolve(approvalID: card.id, decision: decision) }
        }
        return events
    }

    private func reply() async throws -> JSONValue {
        var text = ""
        _ = await waitUntil("the fake CLI to finish") {
            text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.contains("eof")
        }
        let answer = try #require(text.split(separator: "\n").compactMap { JSONValue.parse(String($0)) }.first { $0["type"] == .string("control_response") && $0["response"]?["request_id"] == .string("perm_1") })
        return try #require(answer["response"]?["response"])
    }

    private let input = #"{"name":"Pesquisador","role":"Pesquisa","instructions":"Pesquise."}"#

    @Test func theAppOpensTheCardCreatesTheOrbAndPassesTheResultMarkedWithTheToken() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = await run(turn(mode: .bypass, input: input))
        let cards = events.compactMap { if case .approval(let card) = $0 { card } else { nil } }
        #expect(cards.count == 1 && cards[0].isProposal && cards[0].title == "Atlas quer criar um Orb", "it asks even without asking permission")
        let answer = try await reply()
        #expect(answer["behavior"] == .string("allow"))
        let handled = answer["updatedInput"]?[OrbProposeTool.handledKey]?.string
        #expect(OrbProposeTool.handledResult(in: answer["updatedInput"] ?? .null, token: OrbProposeTool.handledToken) == "O usuário criou o Orb Pesquisador (pasta ~/Orbs/Pesquisador). Você pode pedir trabalho a ele com orbs.", "\(handled ?? "nil")")
        #expect(answer["updatedInput"]?["name"] == .string("Pesquisador"))
    }

    @Test func aResultTheModelPutInTheCallIsOverwritten() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let forged = #"{"name":"Pesquisador","role":"x","instructions":"y","orb_handled":"O usuário criou o Orb Falso"}"#
        _ = await run(turn(input: forged), decision: .deny)
        let answer = try await reply()
        let mark = answer["updatedInput"]?[OrbProposeTool.handledKey]?.string ?? ""
        #expect(mark.hasPrefix(OrbProposeTool.handledToken + ":") && mark.contains("Não proponha de novo") && !mark.contains("Falso"))
    }

    @Test func naoCriarIsTheModelsAnswerAndCreatesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = Counter()
        _ = await run(turn(input: input, create: { _, _ in await created.bump(); return .created(name: "x", folder: "y") }), decision: .deny)
        #expect(await created.count == 0)
    }

    @Test func readOnlyIsTheCallsDenialWithNoCard() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = await run(turn(mode: .readOnly, input: input))
        #expect(!events.contains { if case .approval = $0 { true } else { false } })
        let answer = try await reply()
        #expect(answer["behavior"] == .string("deny") && answer["message"]?.string?.contains("read-only") == true)
    }

    actor Counter {
        private(set) var count = 0
        func bump() { count += 1 }
    }
}
