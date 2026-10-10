import Foundation
import Testing
@testable import Orb

// The group screens' rules as plain values (docs/MULTI-ORBS.md, WP6): the stacked avatars, the presence words, the budget
// text, the new group's rules, the mentions, the shortcut and the sidebar's spoken words.

@Suite("Pilha de avatares")
struct StackedAvatarsTests {
    @Test func upToThreeOrbsAreAllShown() {
        #expect(StackedAvatars.plan(count: 1) == (1, 0))
        #expect(StackedAvatars.plan(count: 2) == (2, 0))
        #expect(StackedAvatars.plan(count: 3) == (3, 0))
    }

    @Test func pastThreeTheThirdPlaceBecomesThePlusPill() {
        #expect(StackedAvatars.plan(count: 4) == (2, 2))
        #expect(StackedAvatars.plan(count: 8) == (2, 6))
    }

    @Test func overlapIsNineAndTheAvatarIs24() {
        #expect(StackedAvatars.overlap == 9)
    }
}

@Suite("Texto de presença")
struct GroupPresenceTests {
    private func item(_ name: String, _ state: GroupPresenceState) -> GroupPresenceItem {
        GroupPresenceItem(id: UUID(), name: name, orb: OrbConfig(), state: state)
    }

    @Test func nobodyInTurnSaysNothing() {
        #expect(GroupPresence.text([]) == nil)
    }

    @Test func oneMemberSaysWhatItDoes() {
        #expect(GroupPresence.text([item("Pesquisador", .writing)]) == "Pesquisador está escrevendo…")
        #expect(GroupPresence.text([item("Revisor", .working)]) == "Revisor está trabalhando…")
        #expect(GroupPresence.text([item("Atlas", .planning)]) == "Atlas está planejando…")
    }

    @Test func twoMembersInTheSameStateShareTheVerb() {
        #expect(GroupPresence.text([item("Pesquisador", .working), item("Revisor", .working)]) == "Pesquisador e Revisor estão trabalhando…")
    }

    @Test func aWaitingMemberIsNamedAloneFirst() {
        #expect(GroupPresence.text([item("Pesquisador", .waitingYou)]) == "Pesquisador está esperando você")
        #expect(GroupPresence.text([item("Pesquisador", .writing), item("Revisor", .waitingYou)]) == "Revisor está esperando você")
    }

    @Test func mixedStatesOfWorkingMembersSayTheyWork() {
        #expect(GroupPresence.text([item("Atlas", .planning), item("Revisor", .working)]) == "Atlas e Revisor estão trabalhando…")
    }

    @Test func aMemberIsWaitingWhenItsOrbWaits() {
        #expect(GroupPresence.state(of: .waiting, needsYou: false, isOrchestrator: false) == .waitingYou)
        #expect(GroupPresence.state(of: .speaking, needsYou: false, isOrchestrator: false) == .writing)
        #expect(GroupPresence.state(of: .thinking, needsYou: false, isOrchestrator: true) == .planning)
        #expect(GroupPresence.state(of: .thinking, needsYou: false, isOrchestrator: false) == .working)
    }
}

@Suite("Orçamento do grupo")
struct GroupBudgetTextTests {
    private func usage(turns: Int, tokens: Int = 0) -> GroupUsage {
        GroupUsage(turns: turns, turnLimit: 100, tokens: tokens, tokenLimit: 100_000)
    }

    @Test func theShareIsTheLargerOfTurnsAndTokens() {
        #expect(GroupBudgetText.fraction(usage(turns: 10, tokens: 50_000)) == 0.5)
        #expect(GroupBudgetText.fraction(usage(turns: 10, tokens: 90_000)) == 0.9)
    }

    /// 0, 79, 80 and 100 %: the text shows from 80 %, the warning color only past it.
    @Test func textAppearsFromEightyPercentAndWarnsPastIt() {
        #expect(!GroupBudgetText.showsText(0))
        #expect(!GroupBudgetText.showsText(0.79))
        #expect(GroupBudgetText.showsText(0.8))
        #expect(!GroupBudgetText.isWarning(0.8))
        #expect(GroupBudgetText.isWarning(0.81))
        #expect(GroupBudgetText.showsText(1.0) && GroupBudgetText.isWarning(1.0))
    }

    @Test func barMovesInStepsOfFivePercent() {
        #expect(GroupBudgetText.barStep(0) == 0)
        #expect(GroupBudgetText.barStep(0.79) == 15)
        #expect(GroupBudgetText.barStep(1.0) == 20)
        #expect(GroupBudgetText.barStep(1.7) == 20)
    }

    @Test func labelNamesTheTurnsOrTheTokensThatRunOut() {
        #expect(GroupBudgetText.label(GroupUsage(turns: 3, turnLimit: 12, tokens: 0, tokenLimit: 150_000)) == "3/12 turnos")
        #expect(GroupBudgetText.label(GroupUsage(turns: 3, turnLimit: 12, tokens: 120_000, tokenLimit: 150_000))
            == "120 mil/150 mil tokens")
        #expect(GroupBudgetText.thousands(950) == "950")
        #expect(GroupBudgetText.thousands(42_300) == "42 mil")
    }
}

@Suite("Novo grupo")
struct NewGroupRulesTests {
    private func look(_ name: String, _ role: String) -> BotLook {
        BotLook(Bot(id: UUID(), name: name, role: role, orb: OrbConfig()))
    }

    @Test func aGroupNeedsTwoToEightOrbs() {
        #expect(!NewGroupRules.canCreate(selectedCount: 0))
        #expect(!NewGroupRules.canCreate(selectedCount: 1))
        #expect(NewGroupRules.canCreate(selectedCount: 2))
        #expect(NewGroupRules.canCreate(selectedCount: 8))
        #expect(!NewGroupRules.canCreate(selectedCount: 9))
        #expect(!NewGroupRules.canSelectMore(selectedCount: 8))
        #expect(NewGroupRules.canSelectMore(selectedCount: 7))
    }

    @Test func theSuggestedNameComesFromTheRoles() {
        #expect(NewGroupRules.suggestedName(for: [look("Pesquisador", "Pesquisa na web"), look("Revisor", "Revisa código")])
            == "Pesquisa e Revisa")
        #expect(NewGroupRules.suggestedName(for: [look("Lia", "")]) == "Lia")
        #expect(NewGroupRules.suggestedName(for: []) == "Grupo novo")
    }

    @Test func aWrittenNameWinsOverTheSuggestion() {
        #expect(NewGroupRules.name(written: "  Lançamento ", suggested: "Pesquisa") == "Lançamento")
        #expect(NewGroupRules.name(written: "   ", suggested: "Pesquisa") == "Pesquisa")
    }

    @Test func theOrchestratorPassesOnWhenItIsTakenOff() {
        let a = UUID(), b = UUID()
        #expect(NewGroupRules.orchestrator(afterRemoving: a, current: a, selected: [b]) == b)
        #expect(NewGroupRules.orchestrator(afterRemoving: b, current: a, selected: [a]) == a)
    }

    @Test func budgetPresetsAreTheThreeOfTheSpec() {
        #expect(GroupBudgetPreset.economical.budget == GroupBudget(maxTurns: 8, maxTokens: 100_000))
        #expect(GroupBudgetPreset.balanced.budget == GroupBudget(maxTurns: 12, maxTokens: 150_000))
        #expect(GroupBudgetPreset.broad.budget == GroupBudget(maxTurns: 24, maxTokens: 300_000))
        #expect(GroupBudgetPreset.matching(GroupBudget(maxTurns: 24, maxTokens: 300_000)) == .broad)
        #expect(GroupBudgetPreset.matching(GroupBudget(maxTurns: 13, maxTokens: 150_000)) == nil)
    }
}

@Suite("Menções do compositor")
struct MentionPickerTests {
    @Test func aMentionIsOpenOnlyWhileTheWordIsBeingTyped() {
        #expect(MentionCandidates.openQuery(in: "oi @pes") == "pes")
        #expect(MentionCandidates.openQuery(in: "@") == "")
        #expect(MentionCandidates.openQuery(in: "oi @pesquisador ") == nil)
        #expect(MentionCandidates.openQuery(in: "email@dominio") == nil)
        #expect(MentionCandidates.openQuery(in: "sem menção") == nil)
    }

    @Test func optionsFilterByNameWithoutAccentsOrCapitals() {
        let names = ["Pesquisador", "Revisor", "Lia"]
        #expect(MentionCandidates.options(query: "PESQ", names: names) == ["Pesquisador"])
        #expect(MentionCandidates.options(query: "rev", names: names) == ["Revisor"])
        #expect(MentionCandidates.options(query: "zz", names: names).isEmpty)
    }

    @Test func everyoneIsOfferedOnlyFromTwoMembers() {
        #expect(MentionCandidates.options(query: "", names: ["Atlas", "Lia"]).contains(MentionCandidates.everyone))
        #expect(!MentionCandidates.options(query: "", names: ["Atlas"]).contains(MentionCandidates.everyone))
    }

    @Test func choosingAnOptionReplacesTheOpenWord() {
        #expect(MentionCandidates.inserting("Revisor", into: "veja @rev") == "veja @Revisor ")
        #expect(MentionCandidates.inserting("todos", into: "@") == "@todos ")
    }
}

@Suite("Atalhos e textos dos grupos")
struct GroupTextsTests {
    @Test func newGroupHasItsOwnKeyAndNoCollision() {
        #expect(AppShortcut.newGroup.label == "⌥⌘G")
        #expect(AppShortcut.all.filter { $0 == AppShortcut.newGroup }.count == 1)
        #expect(Set(AppShortcut.all).count == AppShortcut.all.count)
        #expect(ShortcutCatalog.keys(for: .newGroup) == "⌥⌘G")
    }

    @Test func theSidebarRowSpeaksItsState() {
        #expect(GroupRowText.accessibilityLabel(name: "Lançamento", orbCount: 3, unread: 1, working: true, waiting: false)
            == "Lançamento, grupo, 3 Orbs, não lido, trabalhando")
        #expect(GroupRowText.accessibilityLabel(name: "Revisão", orbCount: 2, unread: 0, working: false, waiting: true)
            == "Revisão, grupo, 2 Orbs, precisa de você")
    }

    @Test func theSecondLineSaysWhatTheGroupDoes() {
        #expect(GroupRowText.secondLine(presence: nil, orbCount: 3, paused: false) == "3 Orbs")
        #expect(GroupRowText.secondLine(presence: "Revisor está trabalhando…", orbCount: 3, paused: false) == "Revisor está trabalhando…")
        #expect(GroupRowText.secondLine(presence: nil, orbCount: 3, paused: true) == "Pausado: continuar?")
    }

    @Test func deletingAnOrbSaysItLeavesTheGroups() {
        let summary = DeleteOrbSummary(name: "Lia", archivedCount: 0, routineCount: 0, folder: nil, groupCount: 2)
        #expect(summary.goes.contains("sai de 2 grupos"))
        let none = DeleteOrbSummary(name: "Lia", archivedCount: 0, routineCount: 0, folder: nil)
        #expect(!none.goes.contains("grupo"))
    }
}
