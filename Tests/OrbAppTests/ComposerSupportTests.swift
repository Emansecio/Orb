import AppKit
import Foundation
import Testing
@testable import Orb

struct ComposerSupportTests {
    @Test func aFileAloneIsSomethingToSendAndWhileWorkingItQueuesInsteadOfStopping() {
        #expect(ComposerAction.hasContent(hasText: false, pictures: 0, files: 1))
        #expect(ComposerAction.hasContent(hasText: false, pictures: 1, files: 0))
        #expect(!ComposerAction.hasContent(hasText: false, pictures: 0, files: 0))
        let canSend = ComposerAction.canSend(hasContent: ComposerAction.hasContent(hasText: false, pictures: 0, files: 1),
                                             isWorking: true, canSteer: true, pendingPictures: 0)
        #expect(ComposerAction.current(isWorking: true, canSend: canSend) == .queue)
    }

    // MARK: Keys and pictures

    @Test func theQueueHintHasAShortFormForANarrowComposer() {
        let key = AppShortcut.commandReturn.label
        #expect(ComposerHint.queueing(needsYou: false, typesInComposer: true, compact: true) == "↩ envia agora · ⇥ depois da tarefa")
        #expect(ComposerHint.queueing(needsYou: true, typesInComposer: true, compact: true) == "↩ envia agora · ⇥ depois da tarefa · \(key) recusa e envia")
        #expect(ComposerHint.queueing(needsYou: true, typesInComposer: false, compact: true) == "\(key) permite o pedido")
        // Every short form is shorter than its long one, and the long ones are unchanged without `compact`.
        for (needs, types) in [(false, true), (true, true), (true, false)] {
            let long = ComposerHint.queueing(needsYou: needs, typesInComposer: types)
            #expect(ComposerHint.queueing(needsYou: needs, typesInComposer: types, compact: true).count < long.count)
        }
    }

    @Test @MainActor func theSkillsPopoverHeightFollowsTheWholeListNotTheFilter() {
        #expect(SkillsPopover.height(skillCount: 3, listHeight: nil) == CGFloat(3 * 52 + 54)) // the estimate before it is measured
        #expect(SkillsPopover.height(skillCount: 3, listHeight: 150) == CGFloat(204)) // the measured list wins
        #expect(SkillsPopover.height(skillCount: 0, listHeight: nil) == CGFloat(52 + 54))
        #expect(SkillsPopover.height(skillCount: 40, listHeight: 2000) == CGFloat(380)) // and it scrolls past 380
    }

    @MainActor @Test func theAttachmentStripIsKeyedByWhoIsInIt() {
        let lane = ComposerLane()
        #expect(ComposerView.stripIDs(lane).isEmpty)
        lane.pictures = [ImageAttachment(path: "/tmp/a.png", mediaType: "image/png", width: 1, height: 1)]
        lane.files = [AttachedFile(url: URL(fileURLWithPath: "/tmp/b.pdf"))]
        lane.pendingPictures = 2
        #expect(ComposerView.stripIDs(lane) == ["/tmp/a.png", "file:///tmp/b.pdf", "preparing"]) // one tile, however many are pending
        lane.pendingPictures = 0
        #expect(ComposerView.stripIDs(lane) == ["/tmp/a.png", "file:///tmp/b.pdf"])
    }

    @Test func theHintNeverPromisesStopAndSendWhereCommandReturnAllows() {
        let key = AppShortcut.commandReturn.label
        // No request open: the line is the usual one.
        #expect(ComposerHint.queueing(needsYou: false, typesInComposer: true) == "↩ envia agora · ⇥ depois da tarefa · \(key) para a tarefa e envia")
        // A request open and text in the focused composer: ⌘↩ stops (refusing the request) and sends.
        let typing = ComposerHint.queueing(needsYou: true, typesInComposer: true)
        #expect(typing.contains("\(key) recusa o pedido e envia agora") && typing.hasPrefix("↩ envia agora"))
        // Elsewhere ⌘↩ still allows the request, and the line says that instead.
        let elsewhere = ComposerHint.queueing(needsYou: true, typesInComposer: false)
        #expect(elsewhere.contains("\(key) permite o pedido") && !elsewhere.contains("para a tarefa e envia"))
    }

    @Test func aMessageWaitsForThePicturesStillBeingPrepared() {
        func canSend(content: Bool = true, working: Bool = false, steer: Bool = false, pending: Int = 0) -> Bool {
            ComposerAction.canSend(hasContent: content, isWorking: working, canSteer: steer, pendingPictures: pending)
        }
        #expect(canSend())
        #expect(!canSend(pending: 1)) // text typed, the picture not in yet
        #expect(!canSend(pending: 2))
        #expect(!canSend(content: false))
        #expect(canSend(working: true, steer: true)) // queued
        #expect(!canSend(working: true, steer: true, pending: 1))
        #expect(!canSend(working: true, steer: false)) // a routine's run
        #expect(ComposerLane.preparingText(1) == "Preparando imagem…" && ComposerLane.preparingText(3) == "Preparando 3 imagens…")
    }

    @Test func stopAndSendWorksWithAnEmptyFieldWhenSomethingIsQueued() {
        #expect(ComposerAction.stopAndSendEnabled(isQueueing: true, canSend: true, queuedCount: 0))
        #expect(ComposerAction.stopAndSendEnabled(isQueueing: true, canSend: false, queuedCount: 1)) // the queue bubble's key
        #expect(!ComposerAction.stopAndSendEnabled(isQueueing: true, canSend: false, queuedCount: 0))
        #expect(!ComposerAction.stopAndSendEnabled(isQueueing: false, canSend: true, queuedCount: 1))
        #expect(!ComposerAction.stopAndSendEnabled(isQueueing: true, canSend: false, queuedCount: 1, pendingPictures: 1))
    }

    @Test func stopAndSendIsOffWhileAMessageIsBeingEdited() {
        // The field holds the edit then: it is not a message to queue.
        #expect(!ComposerAction.stopAndSendEnabled(isQueueing: true, canSend: true, queuedCount: 0, isEditing: true))
        #expect(!ComposerAction.stopAndSendEnabled(isQueueing: true, canSend: false, queuedCount: 2, isEditing: true))
        #expect(ComposerAction.stopAndSendEnabled(isQueueing: true, canSend: true, queuedCount: 0, isEditing: false))
    }

    @Test func escClosesTheSkillListBeforeItGivesTheEditUp() {
        #expect(ComposerAction.escape(slashIsOpen: true, isEditing: true) == .closeSkillList) // the first Esc
        #expect(ComposerAction.escape(slashIsOpen: true, isEditing: false) == .closeSkillList)
        #expect(ComposerAction.escape(slashIsOpen: false, isEditing: true) == .cancelEdit) // the second one
        #expect(ComposerAction.escape(slashIsOpen: false, isEditing: false) == .ignore) // nothing of ours: the key goes on
    }

    @Test func theCatalogSaysTheEscOfTheEditNeedsTheCursorInTheField() {
        // The Esc of the edit lives in the field (a key equivalent would run before the field, the search bar or the note
        // of a permission card saw the key): the catalog says where it works.
        let item = ShortcutCatalog.groups.flatMap(\.items).first { $0.command == .cancelEdit }
        #expect(item?.title.contains("cursor no campo") == true)
    }

    @Test func theComposerNamesTheRoutineThatHoldsTheOrb() {
        #expect(ComposerAction.routinePlaceholder(routineName: "Resumo diário") == "A rotina “Resumo diário” está rodando. Envie quando ela terminar.")
        #expect(ComposerAction.routinePlaceholder(routineName: nil) == "Uma rotina está rodando. Envie quando ela terminar.")
        #expect(ComposerAction.stop.title(isRoutine: false) == "Parar" && ComposerAction.stop.title(isRoutine: true) == "Parar a rotina")
        #expect(ComposerAction.stop.help(isRoutine: true) == "Parar a rotina (\(AppShortcut.stop.label))")
        #expect(ComposerAction.stop.help(isRoutine: false) == "\(CommandName.stop) (\(AppShortcut.stop.label))")
        #expect(ComposerAction.send.title(isRoutine: true) == "Enviar") // only Stop changes
    }

    @Test func theQueueSaysItWaitsForYourAnswerWhenARequestIsOpen() {
        #expect(QueuedMessages.whenText(needsYou: true, delivery: .steer) == "Entra depois que você responder ao pedido")
        #expect(QueuedMessages.whenText(needsYou: true, delivery: .afterTask) == "Depois da tarefa")
    }

    @Test func eachWaitingMessageSaysWhereItIsGoingWithoutSayingQueuedWhenItEntersTheTask() {
        #expect(QueuedMessages.whenText(needsYou: false, delivery: .steer) == "Entra no próximo passo")
        #expect(QueuedMessages.whenText(needsYou: false, delivery: .afterTask) == "Depois da tarefa")
        #expect(!QueuedMessages.whenText(needsYou: false, delivery: .steer).contains("fila"))
        #expect(QueuedMessages.switchHelp(from: .steer) == Tip.queueAfterTask && QueuedMessages.switchHelp(from: .afterTask) == Tip.steerNow)
    }

    @Test func aWaitingBubbleDoesNotShareItsIdentityWithTheRowItBecomes() {
        // Both are children of the chat's lazy stack: with one id, SwiftUI showed the delivered message as still waiting.
        let message = SteeredMessage(text: "oi", prompt: "oi")
        #expect(message.queuedRowID != message.id.uuidString && message.queuedRowID.contains(message.id.uuidString))
    }

    @Test func tabQueuesForAfterTheTaskOnlyWithTheOrbWorkingAndSomethingToSend() {
        func tab(slash: Bool = false, working: Bool = true, content: Bool = true, steer: Bool = true, pending: Int = 0, plain: Bool = true) -> ComposerAction.TabKey {
            let canSend = ComposerAction.canSend(hasContent: content, isWorking: working, canSteer: steer, pendingPictures: pending)
            return ComposerAction.tab(slashIsOpen: slash, isQueueing: working && steer, canSend: canSend, isPlain: plain)
        }
        #expect(tab() == .queueAfterTask)
        #expect(tab(content: false) == .ignore) // nothing to send: the plain Tab
        #expect(tab(working: false) == .ignore) // the Orb is free
        #expect(tab(steer: false) == .ignore) // a routine's run takes no message
        #expect(tab(pending: 1) == .ignore) // a picture still on its way
        #expect(tab(plain: false) == .ignore) // ⇧⇥ keeps moving the focus backwards
        // The skill suggestions keep ⇥ for completing, with the Orb working or not.
        #expect(tab(slash: true) == .completeSkill)
        #expect(tab(slash: true, working: false, content: false) == .completeSkill)
    }

    @Test func theRoundButtonSaysDirecionarWhereTheOrbTakesMessagesMidTask() {
        #expect(ComposerAction.queue.title(isRoutine: false) == "Direcionar")
        #expect(ComposerAction.queue.help(isRoutine: false).hasPrefix("Direcionar"))
        #expect(ComposerAction.stop.title(isRoutine: false) == "Parar")
    }

    @Test func pasteIsTakenOnlyInTheComposersOwnKeyWindowWithoutASheet() {
        func takes(window: Bool = true, key: Bool = true, sheet: Bool = false, focused: Bool = true) -> Bool {
            PasteGate.takes(eventIsInComposerWindow: window, isKey: key, hasSheet: sheet, isFocused: focused)
        }
        #expect(takes())
        #expect(!takes(window: false)) // the menu bar panel, Settings, a popover
        #expect(!takes(key: false))
        #expect(!takes(sheet: true)) // a sheet over the chat keeps its own ⌘V
        #expect(!takes(focused: false))
    }

    // MARK: Permission chip

    @Test func theChipSaysTheModeAndCountsGrantsOnlyWhereTheOrbAsks() {
        let rules = [PermissionRule.shell("git"), .shell("brew")]
        #expect(PermissionChipText.label(PermissionState(mode: .ask, rules: rules)) == "Perguntar antes · 2")
        #expect(PermissionChipText.label(PermissionState(mode: .ask, rules: [])) == "Perguntar antes")
        #expect(PermissionChipText.label(PermissionState(mode: .auto, rules: rules)) == "Automático")
        #expect(PermissionChipText.label(PermissionState(mode: .bypass, rules: [])) == "Sem pedir permissão")
        #expect(PermissionChipText.spoken(PermissionState(mode: .ask, rules: [rules[0]])) == "Perguntar antes, 1 liberação")
        #expect(PermissionChipText.spoken(PermissionState(mode: .ask, rules: rules)) == "Perguntar antes, 2 liberações")
        #expect(PermissionChipText.grantsTitle(PermissionState(mode: .readOnly, rules: rules)) == "Liberações permanentes: 2")
        #expect(PermissionChipText.grantsTitle(PermissionState(mode: .ask, rules: [rules[0]])) == "Liberações permanentes: 1")
        #expect(PermissionChipText.grantsTitle(PermissionState(mode: .ask, rules: [])) == nil)
    }

    /// The bar says nothing beside the icon in the mode every Orb starts in, only its grants' count; any other mode in words.
    @Test func theBarNamesOnlyAModeThatIsNotTheUsualOne() {
        let rules = [PermissionRule.shell("git"), .shell("brew")]
        #expect(PermissionChipText.barLabel(PermissionState(mode: .ask, rules: [])) == nil)
        #expect(PermissionChipText.barLabel(PermissionState(mode: .ask, rules: rules)) == "2")
        #expect(PermissionChipText.barLabel(PermissionState(mode: .auto, rules: rules)) == "Automático")
        #expect(PermissionChipText.barLabel(PermissionState(mode: .readOnly, rules: [])) == "Só leitura")
        #expect(PermissionChipText.barLabel(PermissionState(mode: .bypass, rules: [])) == "Sem pedir permissão")
    }

    /// One order everywhere (the Orb's panel, the new-Orb sheet and the composer all list `allCases`) and one wording:
    /// the long description of a mode starts with its short one.
    @Test func everyPickerListsTheModesInOneOrderWithTheRiskiestLast() {
        #expect(PermissionMode.allCases == [.ask, .auto, .readOnly, .bypass])
        #expect(PermissionMode.allCases.map(\.label) == ["Perguntar antes", "Automático", "Só leitura", "Sem pedir permissão"])
        for mode in PermissionMode.allCases {
            #expect(!mode.shortSummary.isEmpty)
            #expect(mode.summary.hasPrefix(mode.shortSummary) && mode.summary.count > mode.shortSummary.count, "\(mode)")
        }
        #expect(Set(PermissionMode.allCases.map(\.summary)).count == 4 && Set(PermissionMode.allCases.map(\.shortSummary)).count == 4)
        #expect(PermissionMode.bypass.summary.hasSuffix("Use só com Orbs e pastas em que você confia.")) // the warning closes the text
        #expect(!PermissionMode.bypass.shortSummary.contains("confia"))
    }

    /// "Comandos arriscados sempre perguntam" is not true in "Sem pedir permissão": the note says so.
    @Test func theGrantsNoteIsTrueInEveryMode() {
        let note = PermissionMode.grantsNote
        #expect(note.contains("“Perguntar antes”") && note.contains("exceto em “Sem pedir permissão”"))
        #expect(note.contains("em “Só leitura” são recusados")) // read-only refuses them, it does not ask
        for mode in PermissionMode.allCases where mode != .bypass {
            // In every other mode the dangerous call asks, whatever the standing grants.
            let call = PermissionCall(toolName: "run_command", family: .shell, risk: .sensitive, danger: "apaga arquivos")
            let verdict = PermissionPolicy.evaluate(mode: mode, call: call, rules: [.init(family: .shell)], workspace: nil)
            if mode == .readOnly { #expect(verdict != .allow) } else { #expect(verdict == .ask(.dangerous("apaga arquivos")), "\(mode)") }
        }
        let call = PermissionCall(toolName: "run_command", family: .shell, risk: .sensitive, danger: "apaga arquivos")
        #expect(PermissionPolicy.evaluate(mode: .bypass, call: call, rules: [], workspace: nil) == .allow)
    }

    // MARK: Skills

    private let skills = [
        Skill(slug: "resumir", name: "Resumir", summary: "Resume textos longos", instructions: ""),
        Skill(slug: "revisar", name: "Revisar código", summary: "Aponta riscos nas mudanças", instructions: ""),
        Skill(slug: "traduzir", name: "Traduzir", summary: "Passa para outro idioma e resume o tom", instructions: ""),
    ]

    @Test func skillsMatchByNameThenSlugThenSummaryIgnoringCaseAndAccents() {
        #expect(SkillSearch.matches(skills, "").map(\.slug) == ["resumir", "revisar", "traduzir"])
        // Names that start with it first, then one that only mentions it in its summary ("resume o tom").
        #expect(SkillSearch.matches(skills, "re").map(\.slug) == ["resumir", "revisar", "traduzir"])
        #expect(SkillSearch.matches(skills, "CODIGO").map(\.slug) == ["revisar"]) // accents and case
        #expect(SkillSearch.matches(skills, "resumir").map(\.slug) == ["resumir"])
        #expect(SkillSearch.matches(skills, "tom").map(\.slug) == ["traduzir"]) // only in a summary
        #expect(SkillSearch.matches(skills, "idioma tom").map(\.slug) == ["traduzir"]) // every word must match
        #expect(SkillSearch.matches(skills, "zzz").isEmpty)
    }

    @Test func theSuggestionsFollowWhatIsTypedAfterASlash() {
        #expect(SkillSearch.slashQuery(in: "/") == "")
        #expect(SkillSearch.slashQuery(in: "/res") == "res")
        #expect(SkillSearch.slashQuery(in: "/resumir ") == nil) // moved on to the message
        #expect(SkillSearch.slashQuery(in: "/resumir isto") == nil)
        #expect(SkillSearch.slashQuery(in: "oi /res") == nil)
        #expect(SkillSearch.slashQuery(in: "") == nil)
    }

    @Test func aWholeSlugIsSentAndAPartialOneIsCompleted() {
        #expect(SkillSearch.isComplete("/resumir", skills: skills))
        #expect(!SkillSearch.isComplete("/resum", skills: skills))
        #expect(!SkillSearch.isComplete("/resumir ", skills: skills)) // already moved on
        #expect(!SkillSearch.isComplete("resumir", skills: skills))
        #expect(!SkillSearch.isComplete("/nada", skills: skills))
    }

    @Test func aSlugTypedInFullIsNotCutFromTheFiveSuggestions() {
        let many = ["revisar-a", "revisar-b", "revisar-c", "revisar-d", "revisar-e", "revisar"]
            .map { Skill(slug: $0, name: $0, summary: "", instructions: "") }
        let shown = Array(SkillSearch.matches(many, "revisar").prefix(5))
        #expect(shown.first?.slug == "revisar")
        #expect(SkillSearch.isComplete("/revisar", skills: shown), "Return sends it instead of completing another")
        #expect(SkillSearch.matches(many, "REVISAR").first?.slug == "revisar")
        #expect(SkillSearch.matches(many, "revisar-").first?.slug == "revisar-a", "a partial word keeps the order")
    }

    // MARK: Clock

    @Test func theClockIsShortAndStaysSteady() {
        #expect(ElapsedFormat.text(seconds: 0) == "0 s")
        #expect(ElapsedFormat.text(seconds: 12) == "12 s")
        #expect(ElapsedFormat.text(seconds: 59) == "59 s")
        #expect(ElapsedFormat.text(seconds: 60) == "1 min 00 s")
        #expect(ElapsedFormat.text(seconds: 125) == "2 min 05 s")
        #expect(ElapsedFormat.text(seconds: 3600) == "1 h 00 min")
        #expect(ElapsedFormat.text(seconds: 3725) == "1 h 02 min")
        #expect(ElapsedFormat.text(seconds: -4) == "0 s")
    }

    @Test func theWorkingClockStaysEmptyDuringTheFirstSecond() {
        let start = Date(timeIntervalSince1970: 1000)
        #expect(ElapsedFormat.working(since: start, now: start.addingTimeInterval(0.4)).isEmpty)
        #expect(ElapsedFormat.working(since: start, now: start.addingTimeInterval(12.9)) == "12 s")
        #expect(ElapsedFormat.working(since: start, now: start.addingTimeInterval(-3)).isEmpty) // clock went back
    }

    @Test @MainActor func aTurnKnowsWhenItBegan() {
        let live = BotLive(Bot(name: "A", role: "", orb: OrbConfig()))
        #expect(live.workingSince == nil)
        live.setStatus("Pensando")
        let began = live.workingSince
        #expect(began != nil)
        live.setStatus("Escrevendo") // a new status line is not a new turn
        #expect(live.workingSince == began)
        live.backdateWork(to: .now.addingTimeInterval(-30))
        #expect(live.workingSince! < began!)
        live.setStatus(nil)
        #expect(live.workingSince == nil)
    }

    // MARK: Attachments

    @Test func filesGetAnIconForTheirType() {
        func symbol(_ name: String) -> String { AttachmentKind.symbol(for: URL(fileURLWithPath: "/tmp/\(name)")) }
        #expect(symbol("a.pdf") == "doc.richtext")
        #expect(symbol("a.csv") == "tablecells")
        #expect(symbol("a.xlsx") == "tablecells")
        #expect(symbol("a.zip") == "doc.zipper")
        #expect(symbol("a.mp3") == "waveform")
        #expect(symbol("a.mov") == "film")
        #expect(symbol("a.swift") == "chevron.left.forwardslash.chevron.right")
        #expect(symbol("a.txt") == "doc.text")
        #expect(symbol("semextensao") == "doc")
        #expect(AttachmentKind.size(nil) == nil)
        #expect(AttachmentKind.size(2_000_000)?.contains("MB") == true)
    }

    // MARK: Models

    private func defaults() -> UserDefaults {
        let suite = "OrbRecents-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func recentModelsKeepTheLastThreeNewestFirstAndSurviveRelaunch() {
        let store = defaults()
        var recents = RecentModels(defaults: store)
        #expect(recents.ids.isEmpty)
        for id in ["openai/a", "xai/b", "openai/c", "openai/a", "xai/d"] { recents.record(id) }
        #expect(recents.ids == ["xai/d", "openai/a", "openai/c"])
        #expect(RecentModels(defaults: store).ids == recents.ids)
        recents.record("") // the app's default is not a model
        recents.record("sem-provedor")
        #expect(recents.ids == ["xai/d", "openai/a", "openai/c"])
    }

    private func choices() -> [(account: ProviderAccount, models: [ProviderModel])] {
        func models(_ names: [String]) -> [ProviderModel] { names.map { ProviderModel(id: $0.lowercased(), name: $0, format: .chat) } }
        return [(ProviderAccount(kind: .openai), models(["GPT-5", "GPT-5 mini"])), (ProviderAccount(kind: .xai), models(["Grok 4"]))]
    }

    @Test func returnInTheComposersModelSearchPicksNothingUntilSomethingIsTyped() {
        #expect(ModelListing(choices: choices(), recents: [], query: "").submitted(query: "") == nil)
        #expect(ModelListing(choices: choices(), recents: [], query: "  ").submitted(query: "  ") == nil)
        #expect(ModelListing(choices: choices(), recents: [], query: "mini").submitted(query: "mini") == "openai/gpt-5 mini")
    }

    @Test func theModelListGroupsByProviderAndLeadsWithRecentOnes() {
        let listing = ModelListing(choices: choices(), recents: ["xai/grok 4", "openai/apagado"], query: "")
        #expect(listing.groups.map(\.provider) == [.openai, .xai])
        #expect(listing.recents.map(\.ref) == ["xai/grok 4"]) // a model that is gone is dropped
        #expect(listing.recents.first?.name == "Grok 4")
        #expect(listing.first == "openai/gpt-5")
    }

    @Test func searchingFiltersGroupsAndHidesRecents() {
        let listing = ModelListing(choices: choices(), recents: ["xai/grok 4"], query: "mini")
        #expect(listing.groups.map(\.provider) == [.openai])
        #expect(listing.groups[0].models.map(\.name) == ["GPT-5 mini"])
        #expect(listing.recents.isEmpty)
        #expect(listing.first == "openai/gpt-5 mini")
        #expect(ModelListing(choices: choices(), recents: [], query: "zzz").first == nil)
    }

    // MARK: Layout

    @Test func theInspectorStepsAsideWhenTheWindowGetsNarrowAndComesBack() {
        var close = InspectorAutoClose()
        #expect(close.windowResized(to: 1400, isOpen: true) == nil)
        #expect(close.windowResized(to: 1100, isOpen: true) == false) // crossed the limit
        #expect(close.windowResized(to: 1050, isOpen: false) == nil)
        #expect(close.windowResized(to: 1190, isOpen: false) == nil) // not wide enough yet (no flicker)
        #expect(close.windowResized(to: 1300, isOpen: false) == true) // wide again: reopened
        #expect(close.windowResized(to: 1500, isOpen: true) == nil)
    }

    @Test func aPanelYouClosedYourselfStaysClosed() {
        var close = InspectorAutoClose()
        #expect(close.windowResized(to: 1100, isOpen: true) == false)
        close.userToggled() // you opened it, then closed it again, in the narrow window
        #expect(close.windowResized(to: 1400, isOpen: false) == nil)
    }

    @Test func aPanelYouOpenedInANarrowWindowIsNotClosedAgain() {
        var close = InspectorAutoClose()
        #expect(close.windowResized(to: 1100, isOpen: false) == nil) // narrow from the start, panel closed
        close.userToggled()
        #expect(close.windowResized(to: 1090, isOpen: true) == nil) // still narrow: nothing crossed
        #expect(close.windowResized(to: 1400, isOpen: true) == nil)
    }

    @Test func aNarrowWindowAtLaunchClosesAnOpenPanel() {
        var close = InspectorAutoClose()
        #expect(close.windowResized(to: 1000, isOpen: true) == false)
        #expect(close.windowResized(to: 1500, isOpen: false) == true)
    }

    // The panel closed itself right after you opened it in a window under 1210 pt: the split view's width, read before,
    // swells for a moment while the panel slides in, which read as the window getting wide and then narrow again.
    @Test @MainActor func theInspectorIsToldTheWindowsWidthNotTheWidthOfWhatIsInIt() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1027, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = try #require(window.contentView)
        let reader = WindowWidthReader.ReaderView(frame: NSRect(x: 0, y: 0, width: 1027, height: 1))
        var widths: [CGFloat] = []
        reader.onChange = { widths.append($0) }
        content.addSubview(reader)
        await waitUntil("the first width") { !widths.isEmpty } // told once it is in the window
        #expect(widths == [window.frame.width])

        // What is in the window grows while the panel slides in: not the window, so nothing is told.
        reader.setFrameSize(NSSize(width: 1327, height: 1))
        content.setFrameSize(NSSize(width: 1327, height: 600))
        #expect(widths == [window.frame.width])

        // The window itself is resized: that is told, once per width.
        window.setContentSize(NSSize(width: 1400, height: 600))
        window.setContentSize(NSSize(width: 1400, height: 700))
        #expect(widths.count == 2 && widths.last == window.frame.width)

        // Told to the panel's rule, opening the panel in the narrow window never closes it.
        var close = InspectorAutoClose()
        #expect(close.windowResized(to: widths[0], isOpen: false) == nil)
        close.userToggled()
        #expect(close.windowResized(to: widths[0], isOpen: true) == nil)
        reader.removeFromSuperview()
    }
}

/// ⇧↩ breaks the line where the cursor is instead of sending.
@MainActor struct NewLineKeyTests {
    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!
    }

    @Test func onlyShiftReturnIsTheNewLine() {
        #expect(NewLineKey.isShiftReturn(key(36, .shift)))
        #expect(NewLineKey.isShiftReturn(key(76, .shift))) // Enter on the keypad
        #expect(!NewLineKey.isShiftReturn(key(36, [])))
        #expect(!NewLineKey.isShiftReturn(key(36, [.shift, .command])))
        #expect(!NewLineKey.isShiftReturn(key(48, .shift))) // ⇧⇥
    }

    @Test func theLineBreakGoesWhereTheCursorIs() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: true)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView?.addSubview(editor)
        editor.string = "primeirasegunda"
        #expect(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        #expect(NewLineKey.insert(in: window))
        #expect(editor.string == "primeira\nsegunda")
        // No text field with the keys: nothing taken.
        #expect(window.makeFirstResponder(nil))
        #expect(!NewLineKey.insert(in: window))
    }
}
