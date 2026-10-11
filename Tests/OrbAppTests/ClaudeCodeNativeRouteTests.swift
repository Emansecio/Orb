import Foundation
import Testing
@testable import Orb

/// What the model was asked, and the usage it reports.
private actor Asked {
    struct Call { var model: String; var system: String; var tools: [String]; var userMessages: [String] }
    private(set) var calls: [Call] = []
    func note(_ call: Call) { calls.append(call) }
}

private struct RecordingModel: LLMClient {
    let asked: Asked

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await asked.note(.init(model: model, system: messages.first { $0.role == .system }?.content ?? "", tools: tools.map(\.name),
                                       userMessages: messages.filter { $0.role == .user }.map(\.content)))
                continuation.yield(.text("feito"))
                continuation.yield(.finished(.done, TokenUsage(input: 100, output: 20)))
                continuation.finish()
            }
        }
    }
}

/// An Orb whose model is Claude Code runs on the native engine: the same path as any provider, with the CLI as a transport only.
@Suite final class ClaudeCodeNativeRouteTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbClaudeNative-\(UUID().uuidString)")

    init() { QuietNotifications.hold() }

    deinit {
        QuietNotifications.release()
        removeTestFolder(root)
    }

    @MainActor private func setUp(_ asked: Asked) -> (AppModel, UUID) {
        var state = AppState.initial
        let folder = root.appending(path: "pasta")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        state.bots[0].workingDirectory = folder.path
        let store = Store(directory: root)
        store.save(state)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.homeFolder = root
        model.providers = [ProviderAccount(kind: .claudeCode)]
        model.publishConnections([.claudeCode])
        model.defaultModel = "claudeCode/sonnet"
        model.clientOverride = { RecordingModel(asked: asked) }
        return (model, state.bots[0].id)
    }

    @Test @MainActor func aClaudeCodeBotsTurnGoesThroughTheNativeEngineWithTheOrbsOwnPromptAndTools() async throws {
        let asked = Asked()
        let (model, botID) = setUp(asked)
        #expect(model.send("oi, tudo bem?", to: botID, fromUser: true))
        await waitUntil("the turn to end") { !model.isWorking(botID) && model.session(botID).turnTask == nil }

        let calls = await asked.calls
        let call = try #require(calls.first)
        #expect(calls.count == 1 && call.model == "sonnet")
        #expect(call.system.contains("You run natively on the user's Mac inside the Orb app"), "the Orb's prompt, not Claude Code's")
        #expect(call.tools.contains("remember") && !call.tools.contains { $0.hasPrefix("mcp__") })
        #expect(call.userMessages.contains { $0.contains("oi, tudo bem?") })
        let texts = model.transcript(botID).compactMap { item -> String? in
            if case .bot(let text, _) = item.kind { text } else { nil }
        }
        #expect(texts.last == "feito")
    }

    @Test @MainActor func aClaudeCodeTurnSteersInTheMiddleAndIsRecordedUnderThePlan() async throws {
        let asked = Asked()
        let (model, botID) = setUp(asked)
        #expect(model.send("primeiro", to: botID, fromUser: true))
        #expect(model.steersMidTurn(botID), "a message sent during the turn reaches the model between its steps, as for any provider")
        await waitUntil("the turn to end") { !model.isWorking(botID) && model.session(botID).turnTask == nil }
        #expect(model.live(botID).lastUsage == TokenUsage(input: 100, output: 20))
        #expect(UsageBilling.of(.claudeCode, account: model.account(.claudeCode)) == .plan)
        // The window the history is planned by: Claude Code's models take 200K tokens.
        #expect(model.contextBudget(for: model.bots[0])?.window == 200_000)
    }

    @Test func theFallbackModelsStateTheirWindowAndPictures() {
        for model in ClaudeCodeModels.fallback {
            #expect(model.contextLength == 200_000 && model.supportsImages == true, "\(model.id)")
        }
        #expect(ClaudeCodeModels.window(of: "claude-fable-5-1[1m]") == 1_000_000)
    }
}
