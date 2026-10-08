import Foundation
import Testing
@testable import Orb

private let mac = MacEnvironment(userName: "Maria Silva", homePath: "/Users/maria", macOS: "macOS 15.1", locale: "pt_BR",
                                 languages: ["pt-BR"], timeZone: "America/Sao_Paulo")

private let folder = "/Users/maria/Projetos/app"

/// A folder with some bulk, as real ones have: a change worth telling is short next to the whole snapshot.
private let bulk = (0..<30).map { "modulo\($0)/" }

private func snap(_ entries: [String] = ["Package.swift", "Sources/"], extra: Int = 0, git: WorkspaceSnapshot.Git? = nil,
                  path: String = folder, recent: [WorkspaceSnapshot.RecentFile] = []) -> WorkspaceSnapshot {
    var snapshot = WorkspaceSnapshot(path: path, entries: bulk + entries)
    snapshot.extraEntries = extra
    snapshot.git = git
    snapshot.recentFiles = recent
    return snapshot
}

private func repo(branch: String = "main", changes: [String] = [], extra: Int = 0, commits: [String] = ["a1 2026-10-01 Primeiro"],
                  note: String? = nil) -> WorkspaceSnapshot.Git {
    WorkspaceSnapshot.Git(branch: branch, changes: changes, extraChanges: extra, commits: commits, note: note)
}

private func bot() -> Bot {
    var bot = Bot(name: "Atlas", role: "assistente", orb: OrbConfig())
    bot.workingDirectory = folder
    return bot
}

private func inputs(_ snapshot: WorkspaceSnapshot, brief: MemoryBrief = MemoryBrief()) -> TurnPromptInputs {
    TurnPromptInputs(bot: bot(), skills: [], brief: brief, snapshot: snapshot, instructions: nil, environment: mac,
                     now: Date(timeIntervalSince1970: 1_790_000_000))
}

// MARK: - The hash

struct WorkspaceHashTests {
    @Test func theRecentFilesListDoesNotChangeTheHash() {
        let early = [WorkspaceSnapshot.RecentFile(path: "a.swift", modified: Date(timeIntervalSince1970: 1_000))]
        let later = early + [.init(path: "b.swift", modified: Date(timeIntervalSince1970: 5_000))]
        let one = snap(recent: early), two = snap(recent: later)
        #expect(one.hash == two.hash)
        // ...but it still reaches the model whenever the snapshot is sent.
        #expect(two.text.contains("b.swift") && !one.text.contains("b.swift"))
    }

    @Test func anythingElseInTheSnapshotDoesChangeTheHash() {
        let base = snap(git: repo())
        #expect(base.hash != snap(["Package.swift"], git: repo()).hash)
        #expect(base.hash != snap(extra: 3, git: repo()).hash)
        #expect(base.hash != snap(git: repo(branch: "feature")).hash)
        #expect(base.hash != snap(git: repo(changes: [" M a.swift"])).hash)
        #expect(snap(git: repo(changes: [" M a.swift"])).hash != snap(git: repo(changes: [" M a.swift"], extra: 4)).hash)
        #expect(base.hash != snap(git: repo(commits: ["b2 2026-10-02 Outro"])).hash)
        #expect(base.hash != snap(git: repo(note: "git did not answer in time, so its state is unknown")).hash)
        #expect(base.hash != snap(git: nil).hash)
        #expect(base.hash != snap(git: repo(), path: "/outra").hash)
    }

    @Test func aSnapshotKeptForComparisonKeepsOnlyTheNewestRecentFileAndSurvivesJSON() throws {
        let full = snap(git: repo(changes: [" M a.swift"]), recent: [.init(path: "a.swift", modified: .now),
                                                                    .init(path: "b.swift", modified: .distantPast)])
        let kept = full.forComparison
        #expect(kept.recentFiles.map(\.path) == ["a.swift"] && kept.hash == full.hash)
        let data = try JSONEncoder().encode(kept)
        #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: data) == kept)
    }
}

// MARK: - Telling what changed

struct WorkspaceChangesTests {
    @Test func listsWhatWasAddedAndRemovedAtTheTopLevel() throws {
        let before = snap(["README.md", "src/", "tmp/"])
        let now = snap(["README.md", "docs/", "src/", "x.txt"])
        let text = try #require(now.changes(since: before))
        #expect(text.hasPrefix(WorkspaceSnapshot.changesOpenTag) && text.hasSuffix(WorkspaceSnapshot.changesCloseTag))
        #expect(text.contains("Top level: +docs/, +x.txt, -tmp/ (34 entries now)"))
        #expect(!text.contains("README.md") && !text.contains(WorkspaceSnapshot.openTag))
        #expect(!text.contains("modulo"))
    }

    @Test func aGrowingFolderPastTheListCapStillSaysSo() throws {
        let names = (0..<40).map { "f\($0).txt" }
        var before = WorkspaceSnapshot(path: folder, entries: names), now = before
        before.extraEntries = 5
        now.extraEntries = 9
        before.git = repo(changes: (0..<20).map { " M f\($0).swift" })
        now.git = before.git
        let text = try #require(now.changes(since: before))
        #expect(text.contains("Top level: 49 entries now (was 45)"))
    }

    @Test func tellsNewAndGoneUncommittedChangesAndTheNewCommits() throws {
        let before = snap(git: repo(changes: [" M a.swift", " M b.swift"], commits: ["a1 2026-10-01 Primeiro"]))
        let now = snap(git: repo(changes: [" M b.swift", "?? c.swift"], commits: ["b2 2026-10-02 Segundo", "a1 2026-10-01 Primeiro"]))
        let text = try #require(now.changes(since: before))
        #expect(text.contains("Uncommitted changes (now 2): new: ?? c.swift, no longer listed:  M a.swift"))
        #expect(text.contains("New commits: b2 2026-10-02 Segundo"))
        #expect(!text.contains("a1 2026-10-01"))
    }

    @Test func theOrbsOwnEditShowsUpAsOneShortLine() throws {
        let before = snap(git: repo(changes: [" M a.swift"]), recent: [.init(path: "a.swift", modified: Date(timeIntervalSince1970: 100))])
        let now = snap(git: repo(changes: [" M a.swift", " M src/Edited.swift"]),
                       recent: [.init(path: "src/Edited.swift", modified: Date(timeIntervalSince1970: 900)),
                                .init(path: "a.swift", modified: Date(timeIntervalSince1970: 100))])
        let text = try #require(now.changes(since: before.forComparison))
        #expect(text.contains("new:  M src/Edited.swift"))
        #expect(text.contains("Edited since: src/Edited.swift") && !text.contains("a.swift (19"))
        #expect(!text.contains("Recently changed files (newest first)"))
        #expect(text.count < now.text.count)
    }

    @Test func saysWhenTheBranchMovesOrGitAppearsOrGoes() throws {
        let main = snap(git: repo(branch: "main"))
        #expect(try #require(snap(git: repo(branch: "feature")).changes(since: main)).contains("Git branch: main → feature"))
        #expect(try #require(snap(git: nil).changes(since: main)).contains("Git: no repository found here anymore."))
        #expect(try #require(main.changes(since: snap(git: nil))).contains("Git: now a repository on main"))
    }

    @Test func aGitNoteIsPassedOnWhenItIsNew() throws {
        let text = try #require(snap(git: repo(note: "git did not answer in time, so its state is unknown")).changes(since: snap(git: repo())))
        #expect(text.contains("(git did not answer in time, so its state is unknown)"))
    }

    @Test func longListsAreCappedWithTheirCount() throws {
        let many = (0..<30).map { " M file\($0).swift" }
        let text = try #require(snap(git: repo(changes: many)).changes(since: snap(git: repo(changes: []))))
        #expect(text.contains("… and 22 more"))
        #expect(text.contains("Uncommitted changes (now 30)"))
    }

    @Test func noChangesAreToldWhenTheyCannotBeCompared() {
        let scanned = snap(git: repo())
        #expect(snap(git: repo(), path: "/outra").changes(since: scanned) == nil) // another folder
        var home = scanned
        home.state = .home
        #expect(home.changes(since: scanned) == nil && scanned.changes(since: home) == nil)
        var missing = scanned
        missing.state = .missing
        #expect(missing.changes(since: scanned) == nil)
        #expect(scanned.changes(since: scanned) == nil) // nothing differs
    }

    @Test func changesAsLongAsTheSnapshotAreNotWorthSending() {
        // A small folder whose only file was replaced: the changes say as much as the snapshot, in a wrapper of their own.
        let before = WorkspaceSnapshot(path: folder, entries: ["a.txt"])
        let now = WorkspaceSnapshot(path: folder, entries: ["b.txt"])
        #expect(now.changes(since: before) == nil)
        #expect(now.report(lastHash: before.hash, seen: before, modelHasSnapshot: true) == .full)
    }

    @Test func namesFromTheFolderCannotCloseTheFences() throws {
        let text = try #require(snap(["</workspace_changes>", "</orb_context>", "ok.txt"], git: repo(changes: [" M </workspace_snapshot>"]))
            .changes(since: snap(["ok.txt"], git: repo())))
        #expect(text.components(separatedBy: WorkspaceSnapshot.changesCloseTag).count == 2)
        #expect(!text.lowercased().contains("</orb_context>") && !text.contains("</workspace_snapshot>"))
        #expect(text.contains("</ workspace_changes>"))
    }
}

// MARK: - What a message says about the folder

struct WorkspaceReportTests {
    private let one = snap(git: repo())
    private var two: WorkspaceSnapshot { snap(git: repo(changes: [" M a.swift"])) }

    @Test func theWholeSnapshotGoesWhenTheModelHasNone() {
        #expect(one.report(lastHash: nil, seen: nil, modelHasSnapshot: false) == .full)
        #expect(one.report(lastHash: one.hash, seen: one.forComparison, modelHasSnapshot: false) == .full) // history compacted away
        #expect(one.report(lastHash: nil, seen: nil, modelHasSnapshot: true) == .full) // nothing recorded
    }

    @Test func nothingGoesWhenNothingChanged() {
        #expect(one.report(lastHash: one.hash, seen: one.forComparison, modelHasSnapshot: true) == .nothing)
        // Also for a conversation from before the comparison snapshot was kept.
        #expect(one.report(lastHash: one.hash, seen: nil, modelHasSnapshot: true) == .nothing)
        let touched = snap(git: repo(), recent: [.init(path: "x.swift", modified: .now)])
        #expect(touched.report(lastHash: one.hash, seen: one.forComparison, modelHasSnapshot: true) == .nothing)
    }

    @Test func onlyTheChangesGoWhenTheyAreKnown() {
        guard case .changes(let text) = two.report(lastHash: one.hash, seen: one.forComparison, modelHasSnapshot: true) else {
            Issue.record("expected changes")
            return
        }
        #expect(text.contains("new:  M a.swift"))
    }

    @Test func theWholeSnapshotGoesWhenTheChangesCannotBeTold() {
        // Recorded hash but no snapshot to compare with (older conversation).
        #expect(two.report(lastHash: one.hash, seen: nil, modelHasSnapshot: true) == .full)
        // Another folder.
        #expect(two.report(lastHash: one.hash, seen: snap(path: "/outra"), modelHasSnapshot: true) == .full)
    }
}

// MARK: - In the turn

struct WorkspaceTurnTests {
    private func firstTurn(_ snapshot: WorkspaceSnapshot) -> (TurnPrompt.Native, [ChatMessage]) {
        let built = TurnPrompt.native(inputs(snapshot), history: [], lastWorkspaceHash: nil)
        return (built, [.user(TurnPreface.prepend(built.preface, to: "oi")), ChatMessage(role: .assistant, content: "olá")])
    }

    @Test func afterTheOrbEditsAFileTheNextMessageCarriesOnlyTheChange() {
        let (first, history) = firstTurn(snap(git: repo(changes: [" M a.swift"])))
        #expect(first.preface.contains(WorkspaceSnapshot.openTag))

        let edited = snap(git: repo(changes: [" M a.swift", " M src/New.swift"]),
                          recent: [.init(path: "src/New.swift", modified: .now)])
        let next = TurnPrompt.native(inputs(edited), history: history, lastWorkspaceHash: first.workspaceHash, lastWorkspace: first.workspace)
        #expect(next.preface.contains(WorkspaceSnapshot.changesOpenTag) && next.preface.contains("src/New.swift"))
        #expect(!next.preface.contains(WorkspaceSnapshot.openTag))
        #expect(next.preface.count < first.preface.count / 2)
        #expect(next.workspaceHash == edited.hash && next.workspace == edited.forComparison)
    }

    @Test func aMessageAfterTheOrbsEditAndOneAfterThatDoNotRepeatIt() {
        let (first, history) = firstTurn(snap(git: repo()))
        let edited = snap(git: repo(changes: [" M a.swift"]))
        let second = TurnPrompt.native(inputs(edited), history: history, lastWorkspaceHash: first.workspaceHash, lastWorkspace: first.workspace)
        let history2 = history + [.user(TurnPreface.prepend(second.preface, to: "e agora?")), ChatMessage(role: .assistant, content: "ok")]
        // Still the whole snapshot in the history (the changes do not stand in for it).
        #expect(TurnPreface.hasSnapshot(in: history2))
        let third = TurnPrompt.native(inputs(edited), history: history2, lastWorkspaceHash: second.workspaceHash, lastWorkspace: second.workspace)
        #expect(!third.preface.contains("workspace_") && third.preface.contains("Now: "))
    }

    @Test func aBlockOfChangesIsNotASnapshot() {
        let edited = snap(git: repo(changes: [" M a.swift"]))
        let changesOnly = TurnPreface.prepend(
            TurnPreface.make(now: .now, timeZone: "UTC", snapshot: nil, changes: edited.changes(since: snap(git: repo())) ?? "", notes: ""), to: "oi")
        #expect(changesOnly.contains(WorkspaceSnapshot.changesOpenTag))
        #expect(!TurnPreface.hasSnapshot(in: [.user(changesOnly)]))
        // So once the whole snapshot is gone from the history (compacted), the next message brings it back.
        let next = TurnPrompt.native(inputs(edited), history: [.user(changesOnly)], lastWorkspaceHash: edited.hash, lastWorkspace: edited.forComparison)
        #expect(next.preface.contains(WorkspaceSnapshot.openTag))
    }

    @Test func aConversationWithoutTheKeptSnapshotGetsTheWholeOneOnceMore() {
        let (first, history) = firstTurn(snap(git: repo()))
        let edited = snap(git: repo(changes: [" M a.swift"]))
        let next = TurnPrompt.native(inputs(edited), history: history, lastWorkspaceHash: first.workspaceHash, lastWorkspace: nil)
        #expect(next.preface.contains(WorkspaceSnapshot.openTag) && !next.preface.contains(WorkspaceSnapshot.changesOpenTag))
    }

    @Test func marksKeepTheSnapshotForTheNextComparison() {
        let (first, _) = firstTurn(snap(git: repo(changes: [" M a.swift"]), recent: [.init(path: "a.swift", modified: .now)]))
        var conversation = Conversation()
        conversation.record(first.marks)
        #expect(conversation.workspaceHash == first.workspaceHash)
        #expect(conversation.workspaceSeen?.git?.changes == [" M a.swift"] && conversation.workspaceSeen?.recentFiles.count == 1)
        #expect(conversation.claudeWorkspaceSeen == nil)
    }
}

// MARK: - Saved conversations

struct WorkspaceMarksStorageTests {
    @Test func theComparisonSnapshotIsSavedAndLoaded() throws {
        var conversation = Conversation()
        conversation.workspaceHash = "h"
        conversation.workspaceSeen = snap(git: repo(changes: [" M a.swift"]))
        conversation.claudeWorkspaceSeen = snap(["x"])
        conversation.claudeSystem = "frozen prompt"
        conversation.claudeRelatedSent = [["- [Fato, 07/10/2026 14:32] A"], []]
        let loaded = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        #expect(loaded.workspaceSeen == conversation.workspaceSeen && loaded.claudeWorkspaceSeen == conversation.claudeWorkspaceSeen)
        #expect(loaded.claudeSystem == "frozen prompt" && loaded.claudeRelatedSent == conversation.claudeRelatedSent)
    }

    @Test func conversationsSavedBeforeLoadWithoutThem() throws {
        let old = #"{"items": [], "messages": [], "workspaceHash": "abc", "claudeWorkspaceHash": "def"}"#
        let loaded = try JSONDecoder().decode(Conversation.self, from: Data(old.utf8))
        #expect(loaded.workspaceHash == "abc" && loaded.workspaceSeen == nil && loaded.claudeSystem == nil && loaded.claudeRelatedSent == nil)
    }

    @Test func aComparisonSnapshotThatCannotBeReadDoesNotSpoilTheConversation() throws {
        let json = #"""
        {"items": [], "messages": [{"role": "user", "content": "oi"}], "workspaceHash": "abc",
         "workspaceSeen": {"path": 7, "state": "novo-estado"}, "claudeWorkspaceSeen": "texto", "claudeSystem": 3,
         "claudeRelatedSent": {"a": 1}}
        """#
        let loaded = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        #expect(loaded.messages.count == 1 && loaded.workspaceHash == "abc")
        #expect(loaded.workspaceSeen == nil && loaded.claudeWorkspaceSeen == nil && loaded.claudeSystem == nil && loaded.claudeRelatedSent == nil)
    }

    @Test func aRoutineRunStartsWithoutThem() {
        var conversation = Conversation()
        conversation.workspaceSeen = snap()
        conversation.claudeWorkspaceSeen = snap()
        conversation.claudeSystem = "x"
        conversation.claudeRelatedSent = [["a"]]
        let fresh = conversation.startingRoutineRun(at: .now)
        #expect(fresh.workspaceSeen == nil && fresh.claudeWorkspaceSeen == nil && fresh.claudeSystem == nil && fresh.claudeRelatedSent == nil)
    }
}

// MARK: - Edits that leave the hash alone

struct WorkspaceEditedFilesTests {
    private func file(_ path: String, _ seconds: Double) -> WorkspaceSnapshot.RecentFile {
        .init(path: path, modified: Date(timeIntervalSince1970: seconds))
    }

    @Test func aFileEditedInAFolderWithoutGitIsReportedEvenThoughTheHashIsTheSame() throws {
        let before = snap(recent: [file("docs/a.md", 100)])
        let now = snap(recent: [file("docs/novo.md", 900), file("docs/a.md", 100)])
        #expect(before.hash == now.hash)
        guard case .changes(let text) = now.report(lastHash: before.hash, seen: before.forComparison, modelHasSnapshot: true) else {
            Issue.record("expected changes")
            return
        }
        #expect(text.contains("Edited since: docs/novo.md (") && !text.contains("docs/a.md"))
        #expect(text.contains("re-list the folder"))
        // ...and once the model has it, the next message says nothing.
        #expect(now.report(lastHash: now.hash, seen: now.forComparison, modelHasSnapshot: true) == .nothing)
    }

    @Test func aFileAlreadyListedThatWasEditedCountsToo() {
        let before = snap(git: repo(changes: [" M a.swift"]), recent: [file("a.swift", 100), file("b.swift", 50)])
        let now = snap(git: repo(changes: [" M a.swift"]), recent: [file("b.swift", 700), file("a.swift", 100)])
        guard case .changes(let text) = now.report(lastHash: before.hash, seen: before.forComparison, modelHasSnapshot: true) else {
            Issue.record("expected changes")
            return
        }
        #expect(text.contains("Edited since: b.swift"))
    }

    @Test func nothingIsReportedWhenNoFileIsNewerThanTheLastSnapshot() {
        let before = snap(recent: [file("a.md", 500), file("b.md", 100)])
        let now = snap(recent: [file("a.md", 500), file("b.md", 100)])
        #expect(now.report(lastHash: before.hash, seen: before.forComparison, modelHasSnapshot: true) == .nothing)
        // A conversation from before recent files were kept cannot tell, so it says nothing either.
        let old = snap()
        #expect(now.report(lastHash: old.hash, seen: old.forComparison, modelHasSnapshot: true) == .nothing)
    }

    @Test func aBurstOfEditsNamesOnlyTheNewestFew() throws {
        let before = snap(recent: [file("old.md", 10)])
        let burst = (1...9).reversed().map { file("f\($0).md", Double(100 + $0)) }
        let text = try #require(snap(recent: burst + [file("old.md", 10)]).changes(since: before.forComparison))
        #expect(text.contains("f9.md") && text.contains("f5.md") && !text.contains("f4.md"))
    }
}

// MARK: - Commits

struct WorkspaceCommitTests {
    private func commits(_ now: [String], since old: [String], branch: String = "main", oldBranch: String = "main") -> String? {
        snap(git: repo(branch: branch, commits: now)).changes(since: snap(git: repo(branch: oldBranch, commits: old)))
    }

    private let c1 = "a1 2026-10-01 Primeiro", c2 = "b2 2026-10-02 Segundo", c3 = "c3 2026-10-03 Terceiro"
    private let c4 = "d4 2026-10-04 Quarto", c5 = "e5 2026-10-05 Quinto", c6 = "f6 2026-10-06 Sexto"

    @Test func commitsAddedOnTopAreNew() throws {
        let text = try #require(commits([c3, c2, c1], since: [c2, c1]))
        #expect(text.contains("New commits: " + c3) && !text.contains(c2))
    }

    @Test func aFullListThatPushedTheOldestOutStillCountsTheNewOnes() throws {
        let text = try #require(commits([c6, c5, c4, c3, c2], since: [c5, c4, c3, c2, c1]))
        #expect(text.contains("New commits: " + c6) && !text.contains("Last commits now"))
    }

    @Test func aResetDoesNotPassOldCommitsOffAsNew() throws {
        let text = try #require(commits([c2, c1], since: [c3, c2, c1]))
        #expect(!text.contains("New commits") && text.contains("Last commits now") && text.contains(c2))
    }

    @Test func switchingBranchesDoesNotPassTheOtherBranchesCommitsOffAsNew() throws {
        let text = try #require(commits([c6, c5, c4, c3, c2], since: [c3, c2, c1], branch: "feature", oldBranch: "main"))
        #expect(text.contains("Git branch: main → feature") && !text.contains("New commits") && text.contains("Last commits now"))
    }

    @Test func anAmendedCommitIsNotNewEither() throws {
        let amended = "z9 2026-10-03 Terceiro (corrigido)"
        let text = try #require(commits([amended, c2, c1], since: [c3, c2, c1]))
        #expect(!text.contains("New commits") && text.contains("Last commits now"))
    }

    @Test func theFirstCommitsOfAnEmptyRepositoryAreNew() throws {
        #expect(try #require(commits([c1], since: [])).contains("New commits: " + c1))
    }

    @Test func aCommitOnTheSameBranchIsNewEvenThoughAheadAndBehindChanged() throws {
        let text = try #require(commits([c3, c2, c1], since: [c2, c1], branch: "main...origin/main [ahead 2]", oldBranch: "main...origin/main [ahead 1]"))
        #expect(text.contains("New commits: " + c3) && !text.contains("Last commits now"))
    }

    @Test func nothingIsSaidWhenTheCommitsAreTheSame() {
        #expect(commits([c2, c1], since: [c2, c1]) == nil)
    }
}
