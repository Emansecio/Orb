import Foundation

/// Lets an Orb ask, in its own chat, for the access a task needs: switches it has off, "Automático" and a work folder. The tool
/// opens no permission card of its own: the engine shows the access card (`ToolContext.requestAccess`) and nothing changes until
/// the person says "Liberar". "Sem pedir permissão" can never be asked for here: it is confirmed only in the Orb's panel.
struct AccessTool: AgentTool {
    static let name = "request_access"
    static let reasonLimit = 200
    /// What the model may ask a switch for: "Conectores" have their own sign-in and are not a one-click grant.
    static let capabilityNames = ["terminal", "browser", "computerUse"]

    let spec = ToolSpec(
        name: AccessTool.name,
        description: """
        Ask the user, on a card, for access this task needs: switches that are off, Automático mode, a work folder.
        """,
        parameters: .schema([
            "capabilities": .object(["type": .string("array"),
                                     "items": .object(["type": .string("string"),
                                                       "enum": .array(AccessTool.capabilityNames.map(JSONValue.string))])]),
            "mode": .object(["type": .string("string"), "enum": .array([.string("auto")])]),
            "folder": .property("string", "Existing folder, absolute or starting with ~."),
            "reason": .property("string", "Why, in one sentence."),
        ], required: ["reason"]))

    var kind: ToolCall.Kind { .orbs }
    var capability: Capability? { nil }

    /// Safe for the permission check: the person's own card is the approval, and it opens in every mode.
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Pedindo acesso", arguments["reason"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let support = context.accessSupport, let ask = context.requestAccess else {
            throw ToolError("You cannot ask for access here: only in your own chat with the user, not in a routine, a request from another Orb or a group.")
        }
        guard let request = try AccessRequest.make(from: arguments, support: support) else {
            return "Already granted: nothing to change. Go ahead with the task."
        }
        return await ask(request).modelText
    }
}

/// What an Orb asks to be allowed, as the card lists it. Only what is still missing: what the Orb already has is left out.
struct AccessRequest: Codable, Sendable, Equatable {
    /// Switches to turn on, in the panel's order.
    var capabilities: [Capability] = []
    /// "Automático" is asked for (never anything beyond it).
    var autoMode = false
    /// The work folder to switch to, as `Bot.workingDirectory` stores it; empty: none asked.
    var folder = ""
    var reason = ""

    var isEmpty: Bool { capabilities.isEmpty && !autoMode && folder.isEmpty }

    /// The items in the words of the card and of the model's result: "Terminal e arquivos", "modo Automático", "pasta /x".
    var items: [String] {
        capabilities.map(\.label) + (autoMode ? ["modo Automático"] : []) + (folder.isEmpty ? [] : ["pasta \(folder)"])
    }

    /// The arguments of a call against what the Orb has now. Refusals are errors for the model; nil: everything asked is true already.
    static func make(from arguments: JSONValue, support: AccessSupport) throws -> AccessRequest? {
        let reason = String((arguments["reason"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(AccessTool.reasonLimit))
        guard !reason.isEmpty else { throw ToolError("Say in reason, in one sentence, why you need it.") }

        var asked = Set<Capability>()
        for name in (arguments["capabilities"]?.array ?? []).compactMap(\.string) {
            guard AccessTool.capabilityNames.contains(name), let capability = Capability(rawValue: name) else {
                throw ToolError("Unknown capability \"\(name)\": ask for \(AccessTool.capabilityNames.joined(separator: ", ")).")
            }
            asked.insert(capability)
        }

        var wantsAuto = false
        if let mode = arguments["mode"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !mode.isEmpty {
            guard mode == "auto" else {
                throw ToolError("Only mode \"auto\" can be asked for. \"Sem pedir permissão\" is never granted here: only the user can turn it on, in the Orb's panel.")
            }
            wantsAuto = true
        }

        var folder = ""
        if let path = arguments["folder"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            folder = try checkedFolder(path, home: support.home)
        }

        guard !asked.isEmpty || wantsAuto || !folder.isEmpty else {
            throw ToolError("Ask for at least one of capabilities, mode or folder.")
        }

        var request = AccessRequest(capabilities: Capability.allCases.filter { asked.contains($0) && !support.capabilities.contains($0) },
                                    reason: reason)
        // Already in Automático, or past it: asking again would only lower or repeat.
        request.autoMode = wantsAuto && (support.mode == .ask || support.mode == .readOnly)
        let current = support.folder.isEmpty ? "" : OrbFolder.storedPath(URL(fileURLWithPath: support.folder))
        request.folder = folder == current ? "" : folder
        return request.isEmpty ? nil : request
    }

    /// The folder as the Orb stores it. It has to exist and to be a folder of its own: the home folder, the root and anything
    /// that contains the home are not (`PermissionPolicy.ownFolder`), since the Orb would then write anywhere unasked.
    static func checkedFolder(_ path: String, home: URL) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw ToolError("folder must be an absolute path or start with ~/.") }
        let url = URL(fileURLWithPath: expanded)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError("\(path) is not an existing folder. Create it first (or ask the user), then ask for access.")
        }
        guard PermissionPolicy.ownFolder(url, home: home) != nil else {
            throw ToolError("\(path) is the home folder, the root or contains the home folder: pick a project folder inside it.")
        }
        return OrbFolder.storedPath(url)
    }
}

extension AccessRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capabilities = try c.lossyArray(.capabilities)
        autoMode = try c.value(.autoMode, default: false)
        folder = try c.value(.folder, default: "")
        reason = try c.value(.reason, default: "")
    }
}

/// What the tool knows about the Orb that asks, captured when the turn starts (the mode is refreshed when the call runs), and how to
/// apply what the person allows. Nil where the Orb cannot ask: a routine, a request from another Orb, a group's turn.
struct AccessSupport: Sendable {
    var capabilities: Set<Capability>
    var mode: PermissionMode
    /// `Bot.workingDirectory` as it is now (empty: the home folder).
    var folder: String
    var home = FileManager.default.homeDirectoryForCurrentUser
    /// Applies the request to the Orb after "Liberar".
    var grant: @Sendable (AccessRequest) async -> AccessOutcome = { _ in .failed("The app could not change the access now.") }
    /// Called with the card's id when `grant` failed, so the card does not stay as "Liberado" for something nothing granted.
    var grantFailed: @Sendable (UUID, String) async -> Void = { _, _ in }
}

/// How the person answered the access card, for the model that asked.
enum AccessOutcome: Equatable, Sendable {
    /// `summary` lists what was turned on.
    case granted(summary: String)
    case declined
    case failed(String)

    var modelText: String {
        switch self {
        case .granted(let summary):
            "Granted: \(summary). The new tools arrive in your next turn: end this turn now in one short line."
        case .declined:
            "The user did not grant access. Do not ask again in this conversation; continue with what you have or explain what is missing."
        case .failed(let reason):
            reason
        }
    }
}

/// Opens the access card and waits for the person's answer (the engine sets it for the call).
typealias AccessHandler = @Sendable (AccessRequest) async -> AccessOutcome
