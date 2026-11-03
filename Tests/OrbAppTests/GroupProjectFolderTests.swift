import Foundation
import Testing
@testable import Orb

// A group that shares a project folder, through the real delegation hub and the engine: the orchestrator works in the project, a
// member in a worktree of its own, and what each is told and can touch follows. The Orb's own saved folder never changes.

private let gitReady = WorkFolders.Git.make() != nil

@Suite final class GroupProjectFolderTests {
    let root = TempFolder("OrbGroupProject", creating: true)

    init() { QuietNotifications.hold() }

    deinit { QuietNotifications.release() }

    private var project: URL { root.appending("projeto") }

    @MainActor private func makeRepo() async throws {
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "um\n".write(to: project.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let git = try #require(WorkFolders.Git.make())
        let identity = ["-c", "user.name=Teste", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]
        for arguments in [["init", "-b", "main"], ["add", "-A"], ["commit", "-m", "primeiro"]] {
            let done = await git.run(identity + arguments, in: project)
            #expect(done.succeeded, "\(done.text)")
        }
    }

    /// Atlas (orchestrates) and Revisor, in a group over `project`; the model answers with `script`.
    @MainActor private func setUp(_ script: CallScript) throws -> (model: AppModel, group: OrbGroup, atlas: Bot, revisor: Bot) {
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var state = AppState.initial
        state.bots = ["Atlas", "Revisor"].map { name in
            var bot = Bot(name: name, role: "Papel de \(name)", orb: OrbConfig())
            bot.workingDirectory = root.appending("pasta-\(name)").path
            bot.capabilities = [.terminal]
            try? FileManager.default.createDirectory(atPath: bot.workingDirectory, withIntermediateDirectories: true)
            return bot
        }
        state.routines = []
        let store = Store(directory: root.url)
        store.save(state)
        for bot in state.bots { store.save(Conversation(), for: bot.id) }
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.homeFolder = root.url
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = { CallScriptModel(script: script) }
        model.groupHub.settle = .zero
        model.groupHub.isAppActive = { false }
        let group = try #require(model.createGroup(name: "Lançamento", members: model.bots.map(\.id),
                                                   projectFolder: OrbFolder.storedPath(project)))
        return (model, group, model.bots[0], model.bots[1])
    }

    @Test @MainActor func theOrchestratorWorksInTheProjectFolder() async throws {
        let script = CallScript([[.text("Feito."), .finished(.done, nil)]])
        let (model, group, atlas, _) = try setUp(script)
        model.postUserMessage("Organize o trabalho", to: group.id)
        _ = await waitUntil("the request to end") { model.groupHub.run(group.id) == nil }
        let call = try #require(await script.calls.first)
        let path = OrbFolder.storedPath(project)
        #expect(call.system.contains("Your folder \(path) is your home base"), "the system prompt names the project, not the Orb's folder")
        #expect(call.messages.last?.content.contains("Shared folder \(path)") == true, "a folder without git is shared")
        #expect(model.bot(atlas.id)?.workingDirectory == root.appending("pasta-Atlas").path, "the Orb's own folder is untouched")
    }

    @Test(.enabled(if: gitReady)) @MainActor func aMemberWorksInAWorktreeAndWhatItLeavesUncommittedStays() async throws {
        try await makeRepo()
        let write = ToolCallRequest(id: "c1", name: "write_file", arguments: #"{"path":"novo.txt","content":"do membro\n"}"#)
        let script = CallScript([[.toolCalls([write]), .finished(.toolUse, nil)], [.text("Escrevi."), .finished(.done, nil)]])
        let (model, group, _, revisor) = try setUp(script)
        model.postUserMessage("@Revisor escreva novo.txt", to: group.id)
        _ = await waitUntil("the request to end") { model.groupHub.run(group.id) == nil }

        let calls = await script.calls
        let first = try #require(calls.first)
        let work = root.appending("trabalho")
        #expect(first.system.contains("Your folder \(work.path)") || first.system.contains("Your folder \(work.standardizedFileURL.path)"),
                "the system prompt names the worktree")
        let told = first.messages.last?.content ?? ""
        #expect(told.contains("(branch orb/revisor/") && told.contains("Commit your work there before you answer."))
        // The file went to the worktree, not to the project nor to the Orb's folder.
        let made = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first.flatMap {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil).first
        }
        let worktree = try #require(made)
        #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "novo.txt").path))
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: "novo.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending("pasta-Revisor/novo.txt").path))
        #expect(model.bot(revisor.id)?.workingDirectory == root.appending("pasta-Revisor").path)
        // Uncommitted work is not thrown away when the request ends: the thread says what was left.
        _ = await waitUntil("the notice") {
            model.groupSession(group.id)?.items.contains { item in
                if case .notice(let text) = item.kind { text.contains("ramos de trabalho sem merge") } else { false }
            } == true
        }
    }

    @Test(.enabled(if: gitReady)) @MainActor func aMemberThatLeavesNothingToMergeLosesItsWorktreeWhenTheRequestEnds() async throws {
        try await makeRepo()
        let script = CallScript([[.text("Li tudo, nada a mudar."), .finished(.done, nil)]])
        let (model, group, _, _) = try setUp(script)
        model.postUserMessage("@Revisor confira o projeto", to: group.id)
        _ = await waitUntil("the request to end") { model.groupHub.run(group.id) == nil }
        let work = root.appending("trabalho")
        _ = await waitUntil("the worktree to go") {
            let projects = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
            return projects.isEmpty
        }
        let branches = await WorkFolders.Git.make()?.run(["branch", "--format=%(refname:short)"], in: project)
        #expect(branches?.text.contains("orb/") == false, "the merged branch goes with its worktree")
    }
}
