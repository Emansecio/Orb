import Foundation
import Testing
@testable import Orb

// `request_access`: the Orb asks, in its own chat, for the switches, the mode and the folder a task needs. These cover what the tool
// accepts and refuses and what it offers; the card's flow is in `AccessCardFlowTests`.

@Suite final class AccessToolTests {
    /// A project folder and a stand-in for the home folder, both real folders in the temporary directory.
    private let root = TempFolder("OrbAccess", creating: true)

    private var home: URL { root.appending("home") }
    private var project: URL { root.appending("home/Projetos/app") }

    init() throws {
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    private func support(_ capabilities: Set<Capability> = [.browser], mode: PermissionMode = .ask, folder: String = "") -> AccessSupport {
        AccessSupport(capabilities: capabilities, mode: mode, folder: folder, home: home)
    }

    /// The arguments as the model would send them: `fields` is the inside of the JSON object, after a reason.
    private func args(_ fields: String = "", reason: String = "Para programar.") -> JSONValue {
        JSONValue.parse(#"{"reason":"\#(reason)"\#(fields.isEmpty ? "" : "," + fields)}"#) ?? .null
    }

    private func make(_ fields: String, _ support: AccessSupport) throws -> AccessRequest? {
        try AccessRequest.make(from: args(fields), support: support)
    }

    // MARK: What is asked

    @Test func onlyWhatIsMissingGoesOnTheCard() throws {
        let fields = #""capabilities":["terminal","browser"],"mode":"auto","folder":"\#(project.path)""#
        let request = try #require(try make(fields, support()))
        #expect(request.capabilities == [.terminal], "the browser is on already")
        #expect(request.autoMode)
        #expect(request.folder == OrbFolder.storedPath(project))
        #expect(request.reason == "Para programar.")
        #expect(request.items == ["Terminal e arquivos", "modo Automático", "pasta \(OrbFolder.storedPath(project))"])
    }

    @Test func aTildeFolderIsExpanded() throws {
        let inHome = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
        let request = try make(#""folder":"~/Library""#, AccessSupport(capabilities: [], mode: .ask, folder: ""))
        #expect(request?.folder == OrbFolder.storedPath(inHome))
    }

    @Test func automaticIsAskedFromAskAndReadOnlyOnly() throws {
        #expect(try make(#""mode":"auto""#, support(mode: .ask))?.autoMode == true)
        #expect(try make(#""mode":"auto""#, support(mode: .readOnly))?.autoMode == true)
        // Already there, or past it: nothing to grant, and never a step down from "Sem pedir permissão".
        #expect(try make(#""mode":"auto""#, support(mode: .auto)) == nil)
        #expect(try make(#""mode":"auto""#, support(mode: .bypass)) == nil)
    }

    @Test func nothingNewIsAlreadyGranted() async throws {
        let have = support([.terminal], mode: .auto, folder: project.path)
        #expect(try make(#""capabilities":["terminal"],"mode":"auto","folder":"\#(project.path)""#, have) == nil)
        var context = ToolContext(workingDirectory: root.url)
        context.accessSupport = have
        context.requestAccess = { _ in Issue.record("no card for what is true already"); return .declined }
        let text = try await AccessTool().run(args(#""capabilities":["terminal"]"#), context: context)
        #expect(text.hasPrefix("Already granted"))
    }

    // MARK: Refusals

    @Test func bypassIsNeverAskedFor() {
        for mode in ["bypass", "Sem pedir permissão", "ask", "readOnly"] {
            #expect(throws: ToolError.self, "\(mode)") { try make(#""mode":"\#(mode)""#, support()) }
        }
        let allowed = AccessTool().spec.parameters["properties"]?["mode"]?["enum"]?.array?.compactMap(\.string)
        #expect(allowed == ["auto"], "the schema offers nothing but auto")
    }

    @Test func aFolderMustBeAnExistingFolderOutsideTheHome() throws {
        let file = root.appending("home/arquivo.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: ToolError.self, "missing") { try make(#""folder":"/nao/existe/mesmo""#, support()) }
        #expect(throws: ToolError.self, "a file") { try make(#""folder":"\#(file.path)""#, support()) }
        #expect(throws: ToolError.self, "relative") { try make(#""folder":"relativa/pasta""#, support()) }
        #expect(throws: ToolError.self, "the root") { try make(#""folder":"/""#, support()) }
        #expect(throws: ToolError.self, "the home folder") { try make(#""folder":"\#(home.path)""#, support()) }
        #expect(throws: ToolError.self, "a folder that contains the home") { try make(#""folder":"\#(root.url.path)""#, support()) }
        // A folder inside the home is the usual case.
        #expect(try make(#""folder":"\#(project.path)""#, support())?.folder == OrbFolder.storedPath(project))
    }

    @Test func theArgumentsAreValidated() {
        let noReason = JSONValue.parse(#"{"capabilities":["terminal"]}"#) ?? .null
        #expect(throws: ToolError.self, "no reason") { try AccessRequest.make(from: noReason, support: support()) }
        #expect(throws: ToolError.self, "blank reason") { try AccessRequest.make(from: args(#""capabilities":["terminal"]"#, reason: "  "), support: support()) }
        #expect(throws: ToolError.self, "nothing asked") { try make("", support()) }
        #expect(throws: ToolError.self, "unknown switch") { try make(#""capabilities":["frigorifico"]"#, support()) }
        #expect(throws: ToolError.self, "connectors have their own sign-in") { try make(#""capabilities":["connectors"]"#, support()) }
    }

    @Test func theReasonIsCapped() throws {
        let long = String(repeating: "a", count: 500)
        let request = try AccessRequest.make(from: args(#""capabilities":["terminal"]"#, reason: long), support: support())
        #expect(request?.reason.count == AccessTool.reasonLimit)
    }

    @Test func withoutACardTheToolSaysItIsNotHere() async {
        let context = ToolContext(workingDirectory: root.url)
        await #expect(throws: ToolError.self) { try await AccessTool().run(self.args(#""capabilities":["terminal"]"#), context: context) }
    }

    // MARK: Words and offering

    @Test func theAnswersTellTheModelWhatToDo() {
        let granted = AccessOutcome.granted(summary: "Terminal e arquivos, modo Automático").modelText
        #expect(granted.hasPrefix("Granted: Terminal e arquivos, modo Automático."))
        #expect(granted.contains("next turn") && granted.contains("end this turn"))
        #expect(AccessOutcome.declined.modelText.contains("did not grant access"))
        #expect(AccessOutcome.declined.modelText.contains("Do not ask again"))
    }

    @Test func theToolIsOfferedOnlyWhereThePersonIs() {
        let names = { (multi: MultiOrbOffering) in
            ToolBox.offered(for: [.terminal], accessibilityGranted: true, multi: multi).map(\.spec.name)
        }
        #expect(names(MultiOrbOffering(access: true)).contains(AccessTool.name))
        #expect(!names(MultiOrbOffering()).contains(AccessTool.name))
        #expect(!names(MultiOrbOffering(sideRun: true)).contains(AccessTool.name))
        #expect(!ToolBox.all.contains { $0.spec.name == AccessTool.name })
    }

    @Test @MainActor func onlyTheOwnChatIsOffered() throws {
        let store = TempFolder("OrbAccessStore", creating: true)
        Store(directory: store.url).save(AppState.initial)
        let model = AppModel(store: Store(directory: store.url), runsBackgroundWork: false)
        let atlas = try #require(model.bots.first)
        let session = model.session(atlas.id)
        #expect(model.multiOrbOffering(for: atlas.id).access)
        session.routineID = UUID()
        #expect(!model.multiOrbOffering(for: atlas.id).access, "a routine")
        session.routineID = nil
        session.sideKind = .delegation
        #expect(!model.multiOrbOffering(for: atlas.id).access, "a request from another Orb")
        session.sideKind = .group
        #expect(!model.multiOrbOffering(for: atlas.id).access, "a group's turn")
        session.sideKind = nil
    }

    @Test func thePromptPointsToTheCardOnlyWhereItIsOffered() {
        var bot = Bot(name: "Atlas", role: "", orb: OrbConfig())
        bot.capabilities = [.browser]
        let plain = PromptParts.permissions(bot)
        let offered = PromptParts.permissions(bot, offersAccess: true)
        #expect(plain.contains("Tell the user which switch to turn on") && !plain.contains("request_access"))
        #expect(offered.contains("request_access") && !offered.contains("Tell the user which switch"))
    }

    @Test func theCardKeepsItsContentsThroughTheFile() throws {
        let access = AccessRequest(capabilities: [.terminal, .computerUse], autoMode: true, folder: "/tmp/x", reason: "Porque sim.")
        let card = ApprovalRequest(toolName: AccessTool.name, title: "t", command: "c", reason: "r", access: access)
        let decoded = try JSONDecoder().decode(ApprovalRequest.self, from: JSONEncoder().encode(card))
        #expect(decoded.access == access && decoded.isAccess)
        let old = try JSONDecoder().decode(ApprovalRequest.self, from: Data(#"{"toolName":"run_command","title":"t","command":"ls","reason":""}"#.utf8))
        #expect(old.access == nil && !old.isAccess)
        // Contents this version cannot read leave a plain card the person can still answer.
        let broken = try JSONDecoder().decode(ApprovalRequest.self, from: Data(#"{"toolName":"request_access","title":"t","command":"c","reason":"","access":{"capabilities":3}}"#.utf8))
        #expect(!broken.isAccess)
        // A newer file: unknown switches are dropped, missing fields have defaults.
        let tolerant = try JSONDecoder().decode(AccessRequest.self, from: Data(#"{"capabilities":["terminal","nova"]}"#.utf8))
        #expect(tolerant.capabilities == [.terminal] && !tolerant.autoMode && tolerant.folder.isEmpty && tolerant.reason.isEmpty)
    }

    @Test func theCardNamesTheFolderFromTheHome() {
        let access = AccessRequest(capabilities: [.terminal], autoMode: true, folder: "/Users/eu/Projetos/Y", reason: "")
        #expect(AccessLines.lines(for: access, home: "/Users/eu") == ["Terminal e arquivos", "Modo Automático", "Pasta ~/Projetos/Y"])
        #expect(AccessLines.shortPath("/Users/eu2/x", home: "/Users/eu") == "/Users/eu2/x")
    }
}
