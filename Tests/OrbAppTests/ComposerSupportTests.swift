import Foundation
import Testing
@testable import Orb

struct ComposerSupportTests {
    // MARK: Keys and pictures

    @Test func theQueueHintHasAShortFormForANarrowComposer() {
        let key = AppShortcut.commandReturn.label
        #expect(ComposerHint.queueing(steersMidTurn: true, needsYou: false, typesInComposer: true, compact: true) == "Na fila · próximo passo")
        #expect(ComposerHint.queueing(steersMidTurn: false, needsYou: false, typesInComposer: true, compact: true) == "Na fila · segue ao terminar")
        #expect(ComposerHint.queueing(steersMidTurn: true, needsYou: true, typesInComposer: true, compact: true) == "Na fila · \(key) recusa e envia")
        #expect(ComposerHint.queueing(steersMidTurn: true, needsYou: true, typesInComposer: false, compact: true) == "Na fila · \(key) permite o pedido")
        // Every short form is shorter than its long one, and the long ones are unchanged without `compact`.
        for (steers, needs, types) in [(true, false, true), (false, false, true), (true, true, true), (true, true, false)] {
            let long = ComposerHint.queueing(steersMidTurn: steers, needsYou: needs, typesInComposer: types)
            #expect(ComposerHint.queueing(steersMidTurn: steers, needsYou: needs, typesInComposer: types, compact: true).count < long.count)
        }
    }

    @Test func theSkillsPopoverHeightFollowsTheWholeListNotTheFilter() {
        #expect(SkillsPopover.height(skillCount: 3, listHeight: nil) == CGFloat(3 * 52 + 48)) // the estimate before it is measured
        #expect(SkillsPopover.height(skillCount: 3, listHeight: 150) == CGFloat(198)) // the measured list wins
        #expect(SkillsPopover.height(skillCount: 0, listHeight: nil) == CGFloat(52 + 48))
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
        #expect(ComposerHint.queueing(steersMidTurn: true, needsYou: false, typesInComposer: true).contains("\(key) para e envia agora"))
        #expect(ComposerHint.queueing(steersMidTurn: false, needsYou: false, typesInComposer: true).contains("segue quando a resposta terminar"))
        // A request open and text in the focused composer: ⌘↩ stops (refusing the request) and sends.
        let typing = ComposerHint.queueing(steersMidTurn: true, needsYou: true, typesInComposer: true)
        #expect(typing.contains("\(key) recusa o pedido e envia agora") && typing.hasPrefix("↩ entra na fila"))
        // Elsewhere ⌘↩ still allows the request, and the line says that instead.
        let elsewhere = ComposerHint.queueing(steersMidTurn: true, needsYou: true, typesInComposer: false)
        #expect(elsewhere.contains("\(key) permite o pedido") && !elsewhere.contains("para e envia"))
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

    @Test func theComposerNamesTheRoutineThatHoldsTheOrb() {
        #expect(ComposerAction.routinePlaceholder(routineName: "Resumo diário") == "A rotina “Resumo diário” está rodando. Envie quando ela terminar.")
        #expect(ComposerAction.routinePlaceholder(routineName: nil) == "Uma rotina está rodando. Envie quando ela terminar.")
        #expect(ComposerAction.stop.title(isRoutine: false) == "Parar" && ComposerAction.stop.title(isRoutine: true) == "Parar a rotina")
        #expect(ComposerAction.stop.help(isRoutine: true) == "Parar a rotina (\(AppShortcut.stop.label))")
        #expect(ComposerAction.stop.help(isRoutine: false) == "\(CommandName.stop) (\(AppShortcut.stop.label))")
        #expect(ComposerAction.send.title(isRoutine: true) == "Enviar") // only Stop changes
    }

    @Test func theQueueSaysItWaitsForYourAnswerWhenARequestIsOpen() {
        #expect(QueuedMessages.whenText(needsYou: true, steersMidTurn: true) == "Na fila · entra depois que você responder ao pedido")
        #expect(QueuedMessages.whenText(needsYou: true, steersMidTurn: false).contains("responder ao pedido"))
        #expect(QueuedMessages.whenText(needsYou: false, steersMidTurn: true) == "Na fila · entra no próximo passo")
        #expect(QueuedMessages.whenText(needsYou: false, steersMidTurn: false) == "Na fila · segue quando a resposta terminar")
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
}
