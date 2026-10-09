import Foundation

/// The Orb's own tools for Claude Code turns. Claude Code only takes extra tools through MCP, so each turn's MCP
/// config starts the app's own binary as `Orb --tools-mcp <memory folder> [--mac] [--folder <working folder>]`: a
/// small stdio server offering `remember` and `recall` on the same files as the app (SQLite WAL lets it share the
/// index), `schedule` (which reaches the app through `ScheduleMailbox`) and, for an Orb with "Controlar apps do Mac",
/// the Mac tools (`open`, `applescript`, `shortcuts_*`, `clipboard_*`, `screenshot`, `notify`, `apps_list`, `processes`, `app_quit`, `trash`, `browser_tab`) with the same schemas.
enum OrbToolsMCPServer {
    static let flag = "--tools-mcp"
    /// What the server was called when it only served memory; still accepted.
    static let legacyFlag = "--memory-mcp"
    static let macFlag = "--mac"
    /// The Orb has "Terminal e arquivos": the file tools that need no Mac permission (`trash`) are served too.
    static let filesFlag = "--files"
    static let folderFlag = "--folder"
    /// What the app (the parent process, which knows) found out about Accessibility, so the server does not have to
    /// ask macOS from a child process whose trust is not certain to be attributed to the app.
    static let accessibilityFlag = "--accessibility"
    static let noAccessibilityFlag = "--no-accessibility"
    /// MCP server name in the Claude Code config, so its tools are `mcp__orb_memoria__remember`, `__recall`, `__open`…
    /// The name stays what it was: sessions that are resumed, and the user's "Sempre permitir" choices, refer to the
    /// tools by it. It is also a name unlikely to collide with an MCP server of the user's own.
    static let name = "orb_memoria"

    /// Every tool the server can offer, for naming and summarizing the calls Claude Code reports.
    static let allTools: [any AgentTool] = ToolBox.memoryTools + ToolBox.scheduleTools + ToolBox.macTools

    /// What one server process offers, gated like the native tools: memory always, and each Mac tool when the Orb has
    /// "Controlar apps do Mac" or the tool needs no capability (`open`, `notify`).
    static func tools(mac: Bool, files: Bool = false) -> [any AgentTool] {
        var capabilities: Set<Capability> = []
        if mac { capabilities.insert(.computerUse) }
        if files { capabilities.insert(.terminal) }
        return ToolBox.memoryTools + ToolBox.scheduleTools + ToolBox.macTools.filter { $0.capability == nil || $0.isOffered(for: capabilities) }
    }

    /// What `tools/list` shows: `tools(mac:)` without `ui_read` and `ui_act` while the app lacks Accessibility (they
    /// would only fail, and every Claude Code request carries their descriptions). Calling one still works.
    /// `accessibilityGranted` nil asks macOS.
    static func listedTools(mac: Bool, files: Bool = false, accessibilityGranted: Bool? = nil) -> [any AgentTool] {
        let tools = tools(mac: mac, files: files)
        guard tools.contains(where: { ToolBox.accessibilityToolNames.contains($0.spec.name) }) else { return tools }
        let granted = accessibilityGranted ?? LiveMacPermissionSystem().isAccessibilityTrusted()
        return tools.filter { granted || !ToolBox.accessibilityToolNames.contains($0.spec.name) }
    }

    /// The tool behind a Claude Code tool name (`mcp__orb_memoria__open`), nil for anything else.
    static func tool(claudeCodeName: String) -> (any AgentTool)? {
        guard claudeCodeName.hasPrefix(ClaudeCodeTools.memoryPrefix) else { return nil }
        let short = claudeCodeName.dropFirst(ClaudeCodeTools.memoryPrefix.count)
        return allTools.first { $0.spec.name == short }
    }

    /// The folder name the server's temporary pictures are kept under (there is no Orb in this process).
    static let pictureOwner = UUID(uuidString: "0B5E5E5E-0000-4000-8000-00000000C0DE")!

    /// The command line of one server process.
    struct Options: Equatable, Sendable {
        var memoryDirectory: URL
        var mac = false
        var files = false
        /// The Orb's folder, where relative paths and commands of its tools start. Nil means the home folder.
        var folder: URL?
        /// Whether the app has Accessibility, as the app said it when it started the server. Nil (no flag) asks macOS.
        var accessibilityGranted: Bool?
        /// Where `schedule` reaches the app, and the Orb it speaks for. Nil without them: the tool says it is unavailable.
        var scheduleMailbox: URL?
        var orb: UUID?

        init(memoryDirectory: URL, mac: Bool = false, files: Bool = false, folder: URL? = nil, accessibilityGranted: Bool? = nil,
             scheduleMailbox: URL? = nil, orb: UUID? = nil) {
            self.memoryDirectory = memoryDirectory
            self.mac = mac
            self.files = files
            self.folder = folder
            self.accessibilityGranted = accessibilityGranted
            self.scheduleMailbox = scheduleMailbox
            self.orb = orb
        }

        /// Reads `--tools-mcp <dir>` (or `--memory-mcp <dir>`) with the optional `--mac`, `--folder <dir>`,
        /// `--accessibility` / `--no-accessibility` and `--schedule-mailbox <dir> --orb <id>`;
        /// nil when the arguments do not ask for the server.
        init?(arguments: [String]) {
            guard let start = arguments.firstIndex(where: { $0 == OrbToolsMCPServer.flag || $0 == OrbToolsMCPServer.legacyFlag }),
                  arguments.indices.contains(start + 1) else { return nil }
            self.init(memoryDirectory: URL(fileURLWithPath: arguments[start + 1]))
            let rest = Array(arguments[(start + 2)...])
            mac = rest.contains(OrbToolsMCPServer.macFlag)
            files = rest.contains(OrbToolsMCPServer.filesFlag)
            if rest.contains(OrbToolsMCPServer.noAccessibilityFlag) { accessibilityGranted = false }
            else if rest.contains(OrbToolsMCPServer.accessibilityFlag) { accessibilityGranted = true }
            func value(of flag: String) -> String? { rest.firstIndex(of: flag).flatMap { rest.indices.contains($0 + 1) ? rest[$0 + 1] : nil } }
            folder = value(of: OrbToolsMCPServer.folderFlag).map { URL(fileURLWithPath: $0) }
            scheduleMailbox = value(of: ScheduleMailbox.flag).map { URL(fileURLWithPath: $0) }
            orb = value(of: ScheduleMailbox.orbFlag).flatMap(UUID.init(uuidString:))
        }

        var context: ToolContext {
            var context = ToolContext(workingDirectory: folder ?? FileManager.default.homeDirectoryForCurrentUser,
                                      memory: MemoryBank(directory: memoryDirectory, createsRoot: false), computerUseAllowed: mac)
            if mac {
                // Claude Code sees pictures: a screenshot goes back as one (shrunk like the native engine's), and the copy is
                // deleted once it was sent.
                context.imageStore = ImageStore(directory: FileManager.default.temporaryDirectory.appending(path: "OrbMCPImages"))
                context.botID = pictureOwner
                context.acceptsImages = true
            }
            if let scheduleMailbox, let orb { context.schedule = ScheduleMailbox.client(directory: scheduleMailbox, orb: orb) }
            return context
        }
    }

    /// The stdio server entry for one Orb.
    /// `accessibilityGranted` is the app's own answer for `listedTools`; nil leaves the server to ask macOS.
    static func config(directory: URL, mac: Bool = false, files: Bool = false, folder: URL? = nil,
                       accessibilityGranted: Bool? = nil, scheduleMailbox: URL? = nil, orb: UUID? = nil) -> MCPServerConfig {
        var server = MCPServerConfig(name: name, command: Bundle.main.executablePath ?? CommandLine.arguments[0])
        server.arguments = [flag, directory.path] + (mac ? [macFlag] : []) + (files ? [filesFlag] : [])
            + (folder.map { [folderFlag, $0.path] } ?? [])
            + (accessibilityGranted.map { [$0 ? accessibilityFlag : noAccessibilityFlag] } ?? [])
        if let scheduleMailbox, let orb { server.arguments += [ScheduleMailbox.flag, scheduleMailbox.path, ScheduleMailbox.orbFlag, orb.uuidString] }
        return server
    }

    /// Runs the server until stdin closes, then exits the process; see `MCPStdioServer.run`.
    static func run(_ options: Options) -> Never {
        MCPStdioServer.run { Handler(context: options.context, mac: options.mac, files: options.files, accessibilityGranted: options.accessibilityGranted) }
    }

    /// The reply to one line (a parse error gets a JSON-RPC error; notifications get none).
    static func respond(to line: String, context: ToolContext, mac: Bool = false, files: Bool = false,
                        accessibilityGranted: Bool? = nil) async -> JSONValue? {
        await MCPStdioServer.respond(toLine: line, handler: Handler(context: context, mac: mac, files: files, accessibilityGranted: accessibilityGranted))
    }

    /// The JSON-RPC response to one message (nil for notifications).
    static func handle(_ request: JSONValue, context: ToolContext, mac: Bool = false, files: Bool = false,
                       accessibilityGranted: Bool? = nil) async -> JSONValue? {
        await MCPStdioServer.respond(to: request, handler: Handler(context: context, mac: mac, files: files, accessibilityGranted: accessibilityGranted))
    }

    /// One server process as an MCP server: the tools it offers, and `callResult` for a call.
    private struct Handler: MCPServerHandler {
        let context: ToolContext
        let mac: Bool
        let files: Bool
        let accessibilityGranted: Bool?
        var serverName: String { "orb-memoria" }

        func listedTools() -> [JSONValue] {
            OrbToolsMCPServer.listedTools(mac: mac, files: files, accessibilityGranted: accessibilityGranted).map {
                .object(["name": .string($0.spec.name), "description": .string($0.spec.description),
                         "inputSchema": $0.spec.parameters,
                         "annotations": .object(["readOnlyHint": .bool($0.risk(.object([:])) == .safe)])])
            }
        }

        func offers(_ tool: String) -> Bool { OrbToolsMCPServer.tools(mac: mac, files: files).contains { $0.spec.name == tool } }

        func call(_ tool: String, arguments: JSONValue) async -> JSONValue {
            guard let tool = OrbToolsMCPServer.tools(mac: mac, files: files).first(where: { $0.spec.name == tool }) else {
                return MCPStdioServer.textResult("Ferramenta desconhecida", isError: true)
            }
            return await OrbToolsMCPServer.callResult(of: tool, arguments: arguments, context: context)
        }
    }

    /// The `tools/call` result of one tool: its text, then the pictures it returned as MCP image blocks (read back from the
    /// store and deleted), and `isError` when it threw.
    static func callResult(of tool: any AgentTool, arguments: JSONValue, context: ToolContext) async -> JSONValue {
        var content: [JSONValue] = []
        var failed = false
        do {
            let output = try await tool.runWithImages(arguments, context: context)
            content.append(.object(["type": .string("text"), "text": .string(output.text)]))
            for image in output.images {
                defer { context.imageStore?.remove(image) }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: image.path)), !data.isEmpty else { continue }
                content.append(.object(["type": .string("image"), "data": .string(data.base64EncodedString()),
                                        "mimeType": .string(image.mediaType)]))
            }
        } catch {
            failed = true
            content = [.object(["type": .string("text"), "text": .string(error.localizedDescription)])]
        }
        return .object(["content": .array(content), "isError": .bool(failed)])
    }
}
