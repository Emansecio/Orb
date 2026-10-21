import Foundation
import Testing
@testable import Orb

// The folding cards of the Orb's General tab: when each is open, what the closed row says and warns of, what the folded
// "Navegar na web" shows, and the words of the rows.

struct InspectorFoldTests {
    // MARK: Open or closed

    @Test func aPartIsOpenWhenStoredOpenOrWhenItHasAProblem() {
        #expect(!InspectorFold.isOpen(stored: false, hasProblem: false))
        #expect(InspectorFold.isOpen(stored: true, hasProblem: false))
        #expect(InspectorFold.isOpen(stored: false, hasProblem: true))
        #expect(InspectorFold.isOpen(stored: true, hasProblem: true))
    }

    @Test func aClickStoresTheOtherStateUnlessAProblemHoldsThePartOpen() {
        #expect(InspectorFold.stored(afterClickWhen: false, stored: false, hasProblem: false))
        #expect(!InspectorFold.stored(afterClickWhen: true, stored: true, hasProblem: false))
        // Open only for the problem: the click must not turn into "stay open" once the problem is gone.
        #expect(!InspectorFold.stored(afterClickWhen: true, stored: false, hasProblem: true))
        #expect(InspectorFold.stored(afterClickWhen: true, stored: true, hasProblem: true))
    }

    @Test func theThreePartsKeepTheirOwnFlag() {
        let keys = [InspectorFold.modelKey, InspectorFold.capabilitiesKey, InspectorFold.browserKey]
        #expect(Set(keys).count == 3)
    }

    @Test func voiceOverHearsTheStateAndWhatTheClosedRowShows() {
        #expect(InspectorFold.spokenState(isOpen: true, summary: "3 de 4 ligadas") == "expandido")
        #expect(InspectorFold.spokenState(isOpen: false) == "recolhido")
        #expect(InspectorFold.spokenState(isOpen: false, summary: "") == "recolhido")
        #expect(InspectorFold.spokenState(isOpen: false, summary: "3 de 4 ligadas") == "recolhido, 3 de 4 ligadas")
    }

    // MARK: Modelo e modo

    @Test func theWarningMarkShowsForTheModeThatNeverAsksAndForAModelThatCannotAnswer() {
        for mode in PermissionMode.allCases where mode != .bypass {
            #expect(ModelCardSummary.warning(mode: mode, unavailableNote: nil) == nil)
        }
        #expect(ModelCardSummary.warning(mode: .bypass, unavailableNote: nil) == "Roda tudo sem perguntar")
        #expect(ModelCardSummary.warning(mode: .ask, unavailableNote: "Claude Code não está conectado.") == "Claude Code não está conectado.")
        // The model that cannot answer comes first: it is the one that needs doing something.
        #expect(ModelCardSummary.warning(mode: .bypass, unavailableNote: "Sem conexão") == "Sem conexão")
    }

    @Test func onlyAModelThatCannotAnswerHoldsTheCardOpen() {
        #expect(ModelCardSummary.hasProblem(unavailableNote: "Claude Code está desligado em Ajustes → Modelos."))
        #expect(!ModelCardSummary.hasProblem(unavailableNote: nil))
        // "Sem pedir permissão" is a choice: a mark on the closed row, not a reason to open the card.
        let bypassOnly = ModelCardSummary.warning(mode: .bypass, unavailableNote: nil)
        #expect(bypassOnly != nil && !ModelCardSummary.hasProblem(unavailableNote: nil))
    }

    @Test func theClosedRowNamesTheChosenModelThenTheDefaultThenPadrao() {
        let names = ["anthropic/sonnet": "Sonnet 5.5", "openai/gpt": "GPT"]
        func name(_ selection: String) -> String { names[selection] ?? selection }
        #expect(ModelCardSummary.modelText(selection: "openai/gpt", defaultModel: "anthropic/sonnet", name: name) == "GPT")
        #expect(ModelCardSummary.modelText(selection: "", defaultModel: "anthropic/sonnet", name: name) == "Sonnet 5.5")
        #expect(ModelCardSummary.modelText(selection: "", defaultModel: "", name: name) == "Padrão")
    }

    @Test func theBypassLineIsOneShortLineAndTheModeKeepsItsFullText() {
        #expect(ModelCardSummary.bypassLine.count < 40 && !ModelCardSummary.bypassLine.contains("\n"))
        #expect(PermissionMode.bypass.summary.count > ModelCardSummary.bypassLine.count)
    }

    // MARK: Pode usar

    @Test func theIconsOfTheClosedRowAreDimmedForWhatIsOff() {
        #expect(CapabilityStrip.opacity(isOn: true) == 1)
        #expect(CapabilityStrip.opacity(isOn: false) == 0.3)
        #expect(Capability.allCases.count == 4 && Capability.allCases.allSatisfy { !$0.symbol.isEmpty })
    }

    @Test func theClosedRowSaysHowManyAreOn() {
        #expect(CapabilityStrip.spokenCount(enabled: 3, total: 4) == "3 de 4 ligadas")
        #expect(CapabilityStrip.spokenCount(enabled: 0, total: 4) == "0 de 4 ligadas")
    }

    @Test func everyRowKeepsItsDescriptionAsAHoverTextInTheTipStyle() {
        for capability in Capability.allCases {
            let tip = Tip.capability(capability)
            #expect(!tip.isEmpty && !tip.hasSuffix(".") && tip.count <= 90)
        }
        #expect(Set(Capability.allCases.map(Tip.capability)).count == Capability.allCases.count)
    }

    @Test func theFoldingRowsHaveATipForEachState() {
        #expect(Tip.toggleModelCard(isOpen: true) != Tip.toggleModelCard(isOpen: false))
        #expect(Tip.toggleCapabilities(isOpen: true) != Tip.toggleCapabilities(isOpen: false))
        #expect(Tip.toggleBrowserOptions(isOpen: true) != Tip.toggleBrowserOptions(isOpen: false))
    }

    // MARK: Navegar na web

    @Test func theFoldedBrowserRowSaysTheModeAndTheSearch() {
        #expect(BrowserFoldSummary.text(mode: .background, provider: .duckduckgo) == "Segundo plano, DuckDuckGo")
        #expect(BrowserFoldSummary.text(mode: .visible, provider: .google) == "Visível, Google")
        #expect(BrowserFoldSummary.text(mode: .background, provider: .tinyfish) == "Segundo plano, TinyFish")
    }

    private func missing(_ names: String...) -> BrowserStatus {
        var status = BrowserStatus(agentBrowser: "/fake/agent-browser")
        status.missing = names.map { .init(name: $0) }
        return status
    }

    private var ready: BrowserStatus {
        BrowserStatus(agentBrowser: "/fake/agent-browser",
                      program: BrowserProgram(kind: .chrome, executable: "/fake/chrome", major: 155))
    }

    @Test func aBrowserNotReadyIsAProblemOnlyWhileTheOrbBrowses() {
        let caps: Set<Capability> = [.terminal, .browser]
        #expect(BrowserPickerCopy.hasProblem(capabilities: caps, status: missing("Chrome"), provider: .duckduckgo, hasKey: nil))
        #expect(!BrowserPickerCopy.hasProblem(capabilities: caps, status: ready, provider: .duckduckgo, hasKey: nil))
        // Still looking is not a verdict yet.
        #expect(!BrowserPickerCopy.hasProblem(capabilities: caps, status: nil, provider: .duckduckgo, hasKey: nil))
        // Without "Navegar na web" there is no browser to be ready.
        #expect(!BrowserPickerCopy.hasProblem(capabilities: [.terminal], status: missing("Chrome"), provider: .google, hasKey: nil))
    }

    @Test func aSearchThatFallsBackIsAProblemToo() {
        let caps: Set<Capability> = [.browser]
        #expect(BrowserPickerCopy.hasProblem(capabilities: caps, status: ready, provider: .tinyfish, hasKey: false))
        #expect(!BrowserPickerCopy.hasProblem(capabilities: caps, status: ready, provider: .tinyfish, hasKey: true))
        #expect(!BrowserPickerCopy.hasProblem(capabilities: caps, status: ready, provider: .tinyfish, hasKey: nil))
        #expect(!BrowserPickerCopy.hasProblem(capabilities: caps, status: ready, provider: .google, hasKey: nil))
    }
}
