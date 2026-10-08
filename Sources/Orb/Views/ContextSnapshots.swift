import SwiftUI

/// `Orb --snapshot context-meter | context-nudge | context-popover | context-popover-result | context-popover-claude |
/// context-popover-short | settings-context out.png`: the context meter in the composer, the card for a long
/// conversation (at the default window height too: the card must not push the composer out), its popover (a popover
/// window does not render offscreen, so it is drawn on its own) and the memory settings with learned windows.
/// Made-up data in the temporary data folder `ORB_DATA_DIR` points to.
@MainActor
enum ContextSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
        guard screen.hasPrefix("context-") || screen == "settings-context", let bot = model.bots.first else { return nil }
        switch screen {
        case "context-meter":
            return chat(model, bot: bot, charactersPerMessage: 6_000)
        case "context-nudge":
            return chat(model, bot: bot, charactersPerMessage: 10_500)
        case "context-popover":
            seed(model, bot: bot, turns: 12, charactersPerMessage: 6_000)
            return popover(model, bot: bot)
        case "context-popover-result":
            seed(model, bot: bot, turns: 12, charactersPerMessage: 10_500)
            return popover(model, bot: bot, result: CompactionResult(
                status: .compacted, foldedMessages: 18, tokensBefore: 60_000, tokensAfter: 18_000, savedToMemory: true,
                message: "Compactei a conversa."))
        case "context-popover-short":
            seed(model, bot: bot, turns: 1, charactersPerMessage: 400)
            return popover(model, bot: bot)
        case "context-popover-claude":
            seed(model, bot: bot, turns: 6, charactersPerMessage: 2_000, claudeCode: true)
            return popover(model, bot: bot, result: CompactionResult(
                status: .claudeSessionRestarted, foldedMessages: 10, tokensBefore: 22_000, tokensAfter: 4_000,
                message: "Compactei a conversa. " + AppModel.claudeRestartNote))
        case "settings-context":
            model.learnContextWindow(8_192, of: "ollama/gpt-5")
            model.learnContextWindow(32_000, of: "ollama/qwen3", stated: false)
            return AnyView(GeneralSettings()
                .frame(width: 640, height: SettingsTab.general.height)
                .background(Palette.chrome)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        default:
            return nil
        }
    }

    private static let usage = TokenUsage(input: 7_000, output: 300, cacheRead: 35_000, cacheWrite: 0)

    /// A model with a 128k window (or Claude Code).
    private static func seedModel(_ model: AppModel, claudeCode: Bool) {
        var account = ProviderAccount(kind: claudeCode ? .claudeCode : .ollama)
        account.models = [ProviderModel(id: "gpt-5", name: "GPT-5", format: .chat, contextLength: 128_000)]
        model.providers = [account]
        model.defaultModel = claudeCode ? "claudeCode/sonnet" : "ollama/gpt-5"
    }

    /// `turns` exchanges of `charactersPerMessage` characters each.
    private static func conversation(turns: Int, charactersPerMessage: Int) -> Conversation {
        var conversation = Conversation()
        let filler = "Texto de exemplo da conversa com o Orb sobre o projeto. "
        let body = String(String(repeating: filler, count: charactersPerMessage / filler.count + 1).prefix(charactersPerMessage))
        for turn in 0..<turns {
            conversation.messages += [.user("Pedido \(turn + 1): " + body), ChatMessage(role: .assistant, content: "Resposta \(turn + 1): " + body)]
            conversation.items += [TranscriptItem(.user(text: "Pedido \(turn + 1) sobre o projeto", attachments: [])),
                                   TranscriptItem(.bot(text: "Resposta \(turn + 1)", isStreaming: false))]
        }
        return conversation
    }

    /// For the popover scenes, which need no chat: the conversation is there at once.
    private static func seed(_ model: AppModel, bot: Bot, turns: Int, charactersPerMessage: Int, claudeCode: Bool = false) {
        seedModel(model, claudeCode: claudeCode)
        model.seedConversation(conversation(turns: turns, charactersPerMessage: charactersPerMessage), for: bot.id)
        model.apply(.requestUsage(usage), to: bot.id)
    }

    /// The chat, with the conversation put in memory after the Orb's own one has been read from disk (which would replace it).
    private static func chat(_ model: AppModel, bot: Bot, charactersPerMessage: Int) -> AnyView {
        let conversation = conversation(turns: 12, charactersPerMessage: charactersPerMessage)
        seedModel(model, claudeCode: false)
        return AnyView(ChatView(botID: bot.id).task {
            try? await Task.sleep(for: .seconds(1))
            model.seedConversation(conversation, for: bot.id)
            model.apply(.requestUsage(usage), to: bot.id)
        })
    }

    private static func popover(_ model: AppModel, bot: Bot, result: CompactionResult? = nil) -> AnyView? {
        guard let input = model.contextInput(for: bot.id), let reading = ContextReading.make(input) else { return nil }
        return AnyView(
            ContextPopover(reading: reading, result: result, compact: { _ in CompactionResult(status: .busy, message: "") }, adjustMemory: {})
                .background(Palette.chrome)
                .clipShape(.rect(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.lineStrong) }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .background(Palette.canvas))
    }
}
