import Foundation
import Testing
@testable import Orb

/// What the Orb hands Claude Code on every turn has to be the same bytes from one turn to the next, or Claude Code's own
/// prompt cache starts over on each resume: the appended system prompt and the list of MCP tools.

private let mac = MacEnvironment(userName: "Maria Silva", homePath: "/Users/maria", macOS: "macOS 15.1", locale: "pt_BR",
                                 languages: ["pt-BR"], timeZone: "America/Sao_Paulo")

private func bot(name: String = "Atlas", mode: PermissionMode = .ask) -> Bot {
    var bot = Bot(name: name, role: "assistente", orb: OrbConfig())
    bot.permissionMode = mode
    bot.capabilities = [.terminal, .browser, .computerUse]
    bot.workingDirectory = "/Users/maria/Projetos/app"
    return bot
}

private func inputs(_ bot: Bot = bot(), skills: [Skill] = [], pinned: String = "## Your identity\nSeja direto.", related: String = "",
                    headers: [String] = [], at hour: Int = 10) -> TurnPromptInputs {
    TurnPromptInputs(bot: bot, skills: skills,
                     brief: MemoryBrief(pinned: pinned, notes: "## Memory notes\nantigas", related: related, relatedHeaders: headers,
                                        footer: "Search your memory with the recall tool."),
                     snapshot: WorkspaceSnapshot(path: "/Users/maria/Projetos/app", entries: ["a.txt"]), instructions: nil, environment: mac,
                     now: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: hour)) ?? .now)
}

private func skill(_ slug: String) -> Skill { Skill(slug: slug, name: slug, summary: "faz \(slug)", instructions: "x") }

/// The session marks a conversation would hold after `built`'s turn was answered.
private func marks(after built: TurnPrompt.ClaudeCode) -> TurnPrompt.SessionMarks {
    var conversation = Conversation()
    conversation.record(built.marks)
    return TurnPrompt.SessionMarks(isNewSession: false, workspaceHash: conversation.claudeWorkspaceHash, pinned: conversation.claudeMemoryPinned,
                                   standingHash: conversation.claudeStandingHash, workspace: conversation.claudeWorkspaceSeen,
                                   system: conversation.claudeSystem)
}

private func appended(_ system: String) -> String {
    let turn = ClaudeCodeTurn(bot: bot(), executable: URL(fileURLWithPath: "/bin/claude"), model: "default", system: system, prompt: "oi",
                              sessionID: "s-1")
    return turn.arguments(newSessionID: "x", mcpConfig: nil).first { $0.hasPrefix("--append-system-prompt=") } ?? ""
}

// MARK: - The appended system prompt

struct ClaudeCodeSystemPromptStabilityTests {
    private func firstTurn(_ inputs: TurnPromptInputs = inputs()) -> TurnPrompt.ClaudeCode {
        TurnPrompt.claudeCode(inputs, session: .init(isNewSession: true, workspaceHash: nil, pinned: nil, standingHash: nil))
    }

    @Test func aResumedSessionSendsTheTextItStartedWithWhateverVariesFromTurnToTurn() {
        let first = firstTurn()
        let session = marks(after: first)
        // Another time of day, other related memory, other notes: none of it is part of the system prompt.
        let later = TurnPrompt.claudeCode(inputs(related: "- [Fato] café", headers: ["- [Fato, 01/01/2026 10:01 #a1b2] "], at: 17), session: session)
        #expect(later.system == first.system)
        #expect(appended(later.system) == appended(first.system))
    }

    @Test func theSystemPromptIsRebuiltWhenTheIdentityOrPreferencesChange() {
        let first = firstTurn()
        let later = TurnPrompt.claudeCode(inputs(pinned: "## Your identity\nSeja formal."), session: marks(after: first))
        #expect(first.system.contains("Seja direto.") && later.system.contains("Seja formal.") && !later.system.contains("Seja direto."))
        // The change also rides with the message, and the rebuilt text is what the following turns send again.
        #expect(later.context.contains("Seja formal."))
        let next = TurnPrompt.claudeCode(inputs(pinned: "## Your identity\nSeja formal.", at: 20), session: marks(after: later))
        #expect(next.system == later.system && !next.context.contains("[Memory]\nYour identity"))
    }

    @Test func theSystemPromptIsRebuiltWhenTheModeTheNameOrTheSkillsChange() {
        let first = firstTurn()
        var renamed = bot(name: "Luma", mode: .readOnly)
        renamed.role = "outra coisa"
        let later = TurnPrompt.claudeCode(inputs(renamed, skills: [skill("resumir")]), session: marks(after: first))
        #expect(later.system != first.system)
        #expect(later.system.contains("you are Luma") && later.system.contains("Só leitura") && later.system.contains("/resumir"))
        #expect(later.system == ClaudeCodePrompt.make(bot: renamed, skills: [skill("resumir")], memory: inputs().brief.stable, environment: mac))
        // Same rules again: the rebuilt text stays.
        let next = TurnPrompt.claudeCode(inputs(renamed, skills: [skill("resumir")], at: 18), session: marks(after: later))
        #expect(next.system == later.system && !next.context.contains("[Updated rules]"))
    }

    @Test func whatChangedReachesTheSessionWithTheMessageInstead() {
        let first = firstTurn()
        let session = marks(after: first)
        var renamed = bot(name: "Luma", mode: .readOnly)
        renamed.role = "assistente"
        let later = TurnPrompt.claudeCode(inputs(renamed, skills: [skill("resumir")], pinned: "## Your identity\nSeja formal."), session: session)
        #expect(later.context.contains("[Updated rules]"))
        #expect(later.context.contains("you are Luma") && later.context.contains("Só leitura") && later.context.contains("/resumir"))
        #expect(later.context.contains("Seja formal.")) // identity and preferences
    }

    @Test func nothingIsSaidAgainWhenNothingChanged() {
        let first = firstTurn()
        let quiet = TurnPrompt.claudeCode(inputs(at: 15), session: marks(after: first))
        #expect(!quiet.context.contains("[Updated rules]") && !quiet.context.contains("[Memory]\nYour identity"))
        #expect(quiet.standingHash == first.standingHash)
    }

    @Test func aNewSessionStartsFromTheCurrentSettings() {
        let first = firstTurn()
        var other = marks(after: first)
        other.isNewSession = true
        let fresh = TurnPrompt.claudeCode(inputs(bot(name: "Luma"), pinned: "## Your identity\nSeja formal."), session: other)
        #expect(fresh.system != first.system && fresh.system.contains("Seja formal.") && fresh.system.contains("you are Luma"))
        #expect(marks(after: fresh).system == fresh.system) // and that is what the next resume sends
    }

    @Test func aSessionFromBeforeThePromptWasKeptUsesTheCurrentOneAndKeepsItFromThen() {
        var legacy = marks(after: firstTurn())
        legacy.system = nil
        let built = TurnPrompt.claudeCode(inputs(pinned: "## Your identity\nSeja formal."), session: legacy)
        #expect(built.system.contains("Seja formal."))
        let next = TurnPrompt.claudeCode(inputs(pinned: "## Your identity\nSeja formal.", related: "- [Fato] x", at: 22), session: marks(after: built))
        #expect(next.system == built.system)
    }

    @Test func theTextCarriesNoDateNoTimeAndNoTimeZone() {
        let morning = firstTurn(inputs(at: 9)).system, night = firstTurn(inputs(at: 23)).system
        #expect(morning == night)
        #expect(!morning.contains("2026") && !morning.contains("America/Sao_Paulo") && !morning.contains("Today"))
    }

    @Test func theSameInputsGiveTheSameBytesEveryTime() {
        let one = firstTurn(inputs(skills: [skill("a"), skill("b")]))
        for _ in 0..<5 { #expect(firstTurn(inputs(skills: [skill("a"), skill("b")])).system == one.system) }
    }
}

// MARK: - Related memory in a session

struct ClaudeCodeRelatedMemoryTests {
    @Test func theLatestTurnsRelatedLinesAreKeptForTheSession() {
        var conversation = Conversation()
        for turn in 1...5 {
            let built = TurnPrompt.claudeCode(inputs(headers: ["- [Fato, 01/01/2026 10:0\(turn)] Nota \(turn)"]),
                                              session: .init(isNewSession: turn == 1, workspaceHash: nil, pinned: nil, standingHash: nil))
            conversation.record(built.marks)
        }
        #expect(conversation.claudeRelatedSent?.count == TurnPreface.relatedWindow)
        #expect(conversation.claudeRelatedSent?.flatMap { $0 }.map { $0.suffix(6) } == ["Nota 3", "Nota 4", "Nota 5"])
    }

    @Test func aNewSessionForgetsWhatTheOldOneWasSent() {
        var conversation = Conversation()
        conversation.claudeRelatedSent = [["- [Fato, 01/01/2026 10:01 #aaaa] X"], []]
        // The session was lost (or the folder changed): the first turn of the new one replaces the ring...
        let first = TurnPrompt.claudeCode(inputs(headers: ["- [Fato, 01/01/2026 10:02 #bbbb] Y"]),
                                          session: .init(isNewSession: true, workspaceHash: nil, pinned: nil, standingHash: nil))
        conversation.record(first.marks)
        #expect(conversation.claudeRelatedSent == [["- [Fato, 01/01/2026 10:02 #bbbb] Y"]])
        // ...and a resumed turn after it adds to it.
        let second = TurnPrompt.claudeCode(inputs(), session: marks(after: first))
        conversation.record(second.marks)
        #expect(conversation.claudeRelatedSent == [["- [Fato, 01/01/2026 10:02 #bbbb] Y"], []])
    }

    @Test func aLostSessionClearsTheRing() {
        var conversation = Conversation()
        conversation.claudeSessionReported("s-1", folder: "/a")
        conversation.claudeRelatedSent = [["- [Fato, 01/01/2026 10:01 #aaaa] X"]]
        conversation.claudeSessionReported("", folder: "/a")
        #expect(conversation.claudeRelatedSent == nil)
    }

    @Test func aTurnWithoutRelatedMemoryStillCountsAsATurn() {
        var conversation = Conversation()
        conversation.claudeRelatedSent = [["- [Fato, 01/01/2026 10:01] A"]]
        conversation.record(TurnPrompt.claudeCode(inputs(), session: .init(isNewSession: false, workspaceHash: nil, pinned: nil, standingHash: nil)).marks)
        #expect(conversation.claudeRelatedSent == [["- [Fato, 01/01/2026 10:01] A"], []])
    }

    @Test func relatedMemoryRidesWithTheMessageOfAResumedSession() {
        let session = marks(after: TurnPrompt.claudeCode(inputs(), session: .init(isNewSession: true, workspaceHash: nil, pinned: nil, standingHash: nil)))
        let built = TurnPrompt.claudeCode(inputs(related: "- [Fato, 01/01/2026 10:01] Postgres 16", headers: ["- [Fato, 01/01/2026 10:01] Postgres 16"]),
                                          session: session)
        #expect(built.context.contains("Postgres 16") && built.related == ["- [Fato, 01/01/2026 10:01] Postgres 16"])
    }
}

// MARK: - The MCP configuration and its tools

struct ClaudeCodeMCPStabilityTests {
    private func servers() -> [MCPServerConfig] {
        var local = MCPServerConfig(name: "Meu Server", command: "npx", arguments: ["-y", "srv"],
                                    environment: Dictionary(uniqueKeysWithValues: (0..<12).map { ("VAR_\($0)", "v\($0)") }))
        local.isEnabled = true
        let remote = MCPServerConfig(name: "Docs", url: "https://example.com/mcp",
                                     headers: Dictionary(uniqueKeysWithValues: (0..<12).map { ("X-Header-\($0)", "h\($0)") }))
        return [OrbToolsMCPServer.config(directory: URL(fileURLWithPath: "/tmp/memoria"), mac: true, folder: URL(fileURLWithPath: "/tmp/pasta")),
                local, remote]
    }

    @Test func theConfigIsTheSameBytesEveryTurn() throws {
        let first = try #require(ClaudeCodeTurn.mcpConfig(servers())).jsonString
        for _ in 0..<20 { #expect(ClaudeCodeTurn.mcpConfig(servers())?.jsonString == first) }
    }

    @Test func theOrderOfTheServersDoesNotMatter() throws {
        let all = servers()
        let reordered = [all[2], all[0], all[1]]
        #expect(ClaudeCodeTurn.mcpConfig(all)?.jsonString == ClaudeCodeTurn.mcpConfig(reordered)?.jsonString)
        // The Orb's own server is always there, under its fixed name.
        let json = try #require(ClaudeCodeTurn.mcpConfig(all))
        #expect(json["mcpServers"]?["orb_memoria"]?["type"] == .string("stdio"))
    }

    @Test func theToolListIsTheSameBytesEveryTime() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OrbMCPStable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = OrbToolsMCPServer.Options(memoryDirectory: directory).context
        let request = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/list")])
        // Accessibility granted, so the list holds every tool whatever this Mac allows the test runner.
        for mac in [true, false] {
            let first = try #require(await OrbToolsMCPServer.handle(request, context: context, mac: mac, accessibilityGranted: true)).jsonString
            for _ in 0..<5 {
                #expect(try #require(await OrbToolsMCPServer.handle(request, context: context, mac: mac, accessibilityGranted: true)).jsonString == first)
            }
            // In the order the app lists them, memory first.
            let names = try #require(JSONValue.parse(first)?["result"]?["tools"]?.array).compactMap { $0["name"]?.string }
            #expect(names == OrbToolsMCPServer.tools(mac: mac).map(\.spec.name))
            #expect(names.prefix(ToolBox.memoryTools.count) == ToolBox.memoryTools.map(\.spec.name)[...])
        }
    }
}
