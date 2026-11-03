import Foundation
import Testing
@testable import Orb

// `orbs ask` with a project `folder`: the Orb asked works in a worktree of it (the folder itself when it is not a git repository),
// told so in the request; the folder is checked like `request_access` checks one.

private let gitReady = WorkFolders.Git.make() != nil

@Suite final class AskWithFolderTests {
    let root = TempFolder("OrbAskFolder", creating: true)

    init() { QuietNotifications.hold() }

    deinit { QuietNotifications.release() }

    private var project: URL { root.appending("projeto") }

    @MainActor private func setUp(_ script: CallScript) throws -> (model: AppModel, atlas: Bot, revisor: Bot) {
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var state = AppState.initial
        state.bots = ["Atlas", "Revisor"].map { name in
            var bot = Bot(name: name, role: "Papel de \(name)", orb: OrbConfig())
            bot.workingDirectory = root.appending("pasta-\(name)").path
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
        model.preferences = UserDefaults(suiteName: "OrbAskFolder-\(UUID().uuidString)") ?? .standard
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = { CallScriptModel(script: script) }
        return (model, model.bots[0], model.bots[1])
    }

    @MainActor private static func ask(_ model: AppModel, from atlas: Bot, folder: String?) async throws -> String {
        var arguments: [String: JSONValue] = ["action": .string("ask"), "to": .string("Revisor"), "message": .string("Revise o projeto")]
        if let folder { arguments["folder"] = .string(folder) }
        return try await model.delegation.handleTool(.object(arguments), orb: atlas.id)
    }

    @Test @MainActor func aFolderWithoutGitIsSharedAndNamedInTheSystemPrompt() async throws {
        let script = CallScript([[.text("Revisado."), .finished(.done, nil)]], whenExhausted: .fim)
        let (model, atlas, revisor) = try setUp(script)
        _ = try await Self.ask(model, from: atlas, folder: project.path)
        _ = await waitUntil("the request to run") { await script.calls.count >= 1 }
        let call = try #require(await script.calls.first)
        let path = OrbFolder.storedPath(project)
        #expect(call.system.contains("Your folder \(path) is your home base"))
        #expect(call.messages.last?.content.contains("Shared folder \(path)") == true)
        #expect(model.bot(revisor.id)?.workingDirectory == root.appending("pasta-Revisor").path)
    }

    @Test(.enabled(if: gitReady)) @MainActor func aRepositoryGivesTheAskedOrbABranchOfItsOwn() async throws {
        let git = try #require(WorkFolders.Git.make())
        let identity = ["-c", "user.name=Teste", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "um\n".write(to: project.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-b", "main"], ["add", "-A"], ["commit", "-m", "primeiro"]] {
            #expect(await git.run(identity + arguments, in: project).succeeded)
        }
        let script = CallScript([[.text("Revisado."), .finished(.done, nil)]], whenExhausted: .fim)
        let (model, atlas, _) = try setUp(script)
        _ = try await Self.ask(model, from: atlas, folder: project.path)
        _ = await waitUntil("the request to run") { await script.calls.count >= 1 }
        let call = try #require(await script.calls.first)
        let told = call.messages.last?.content ?? ""
        #expect(told.contains("(branch orb/revisor/") && told.contains("Name the branch in your answer."))
        #expect(call.system.contains("Your folder \(root.appending("trabalho").path)"))
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: "novo.txt").path))
    }

    @Test @MainActor func aFolderThatDoesNotExistOrIsTheHomeIsRefused() async throws {
        let (model, atlas, _) = try setUp(CallScript([[.text("x"), .finished(.done, nil)]]))
        let missing = root.appending("nao-existe").path, home = root.url.path
        await #expect(throws: ToolError.self) { _ = try await Self.ask(model, from: atlas, folder: missing) }
        await #expect(throws: ToolError.self) { _ = try await Self.ask(model, from: atlas, folder: home) }
        await #expect(throws: ToolError.self) { _ = try await Self.ask(model, from: atlas, folder: "relativo/projeto") }
    }

    @Test @MainActor func theEnvelopeCarriesTheFolderOnlyInAnAsk() async throws {
        let (model, atlas, _) = try setUp(CallScript([[.text("x"), .finished(.done, nil)]]))
        let hub = model.delegation
        let asked = try hub.submit(from: atlas.id, to: "Revisor", text: "Revise", kind: .ask, messageID: UUID(), groupID: nil,
                                   folder: "/a/b")
        #expect(asked.folder == "/a/b")
        let told = try hub.submit(from: atlas.id, to: "Revisor", text: "Aviso", kind: .tell, messageID: UUID(), groupID: nil,
                                  folder: "/a/b")
        #expect(told.folder == nil)
    }
}
