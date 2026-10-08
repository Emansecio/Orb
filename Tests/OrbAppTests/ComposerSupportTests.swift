import Foundation
import Testing
@testable import Orb

struct ComposerSupportTests {
    // MARK: Permission chip

    @Test func theChipSaysTheModeAndCountsGrantsOnlyWhereTheOrbAsks() {
        let rules = [PermissionRule.shell("git"), .shell("brew")]
        #expect(PermissionChipText.label(PermissionState(mode: .ask, rules: rules)) == "Perguntar antes · 2")
        #expect(PermissionChipText.label(PermissionState(mode: .ask, rules: [])) == "Perguntar antes")
        #expect(PermissionChipText.label(PermissionState(mode: .auto, rules: rules)) == "Automático")
        #expect(PermissionChipText.label(PermissionState(mode: .bypass, rules: [])) == "Sem pedir permissão")
        #expect(PermissionChipText.spoken(PermissionState(mode: .ask, rules: [rules[0]])) == "Perguntar antes, 1 liberação")
        #expect(PermissionChipText.spoken(PermissionState(mode: .ask, rules: rules)) == "Perguntar antes, 2 liberações")
        #expect(PermissionChipText.grantsLine(PermissionState(mode: .readOnly, rules: rules)) == "2 liberações")
        #expect(PermissionChipText.grantsLine(PermissionState(mode: .ask, rules: [])) == nil)
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
