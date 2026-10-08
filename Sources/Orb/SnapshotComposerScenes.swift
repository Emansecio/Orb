import SwiftUI

// Review snapshots of the composer and the chat while an Orb works (`Orb --snapshot <mode> out.png`, see
// `Snapshot.render`). They fill the model with made-up data in a fresh temporary data folder (or in the
// one `ORB_DATA_DIR` names; `DevRun` never lets them reach the user's own); nothing here is used by the app itself.

extension Snapshot {
    /// The scene named `screen`, or nil when it is not one of these.
    @MainActor
    static func composerScene(_ screen: String, model: AppModel) -> AnyView? {
        guard let bot = model.bots.first else { return nil }
        switch screen {
        case "chat-working":
            // Mid-turn: a tool ran, the Orb is working for 12 s and two messages wait their turn.
            seedConversation(model, bot: bot)
            model.apply(.status("Rodando no Terminal"), to: bot.id)
            model.session(bot.id).turnTask = Task { try? await Task.sleep(for: .seconds(3600)) }
            model.live(bot.id).backdateWork(to: .now.addingTimeInterval(-12))
            let lane = model.composerLane(bot.id)
            lane.enqueue(SteeredMessage(text: "Na verdade, ignore a pasta node_modules.", prompt: ""))
            lane.enqueue(SteeredMessage(text: "E me mande um resumo no fim.", files: [URL(fileURLWithPath: "/Users/x/Documentos/relatório.pdf")], prompt: ""))
            model.setDraft("Depois disso, rode os testes", for: bot.id)
            return AnyView(ChatView(botID: bot.id))
        case "chat-typed":
            seedConversation(model, bot: bot)
            model.setDraft("Resuma o relatório e destaque os riscos", for: bot.id)
            let lane = model.composerLane(bot.id)
            lane.files = [AttachedFile(url: URL(fileURLWithPath: "/Users/x/Documentos/relatório.pdf")),
                          AttachedFile(url: URL(fileURLWithPath: "/Users/x/Documentos/orçamento.xlsx"))]
            return AnyView(ChatView(botID: bot.id))
        case "chat-slash":
            model.skills = [Skill(slug: "resumir", name: "Resumir", summary: "Resume um texto ou arquivo em poucos tópicos.", instructions: "x"),
                            Skill(slug: "revisar", name: "Revisar código", summary: "Revisa mudanças e aponta riscos.", instructions: "x"),
                            Skill(slug: "traduzir", name: "Traduzir", summary: "Traduz mantendo o tom.", instructions: "x")]
            model.setDraft("/re", for: bot.id)
            return AnyView(ChatView(botID: bot.id))
        case "popover-permissions":
            return AnyView(popover(PermissionPopover(permission: PermissionState(mode: .ask, rules: [.shell("git"), .shell("brew"), .folder("/Users/x/Projetos")]),
                                                     choose: { _ in }, manage: {})))
        case "popover-model":
            seedProviders(model)
            return AnyView(popover(ModelPopover(botID: bot.id) {}))
        case "popover-skills":
            model.skills = [Skill(slug: "resumir", name: "Resumir", summary: "Resume um texto ou arquivo em poucos tópicos.", instructions: "x"),
                            Skill(slug: "revisar", name: "Revisar código", summary: "Revisa mudanças e aponta riscos.", instructions: "x"),
                            Skill(slug: "traduzir", name: "Traduzir", summary: "Traduz mantendo o tom.", instructions: "x")]
            return AnyView(popover(SkillsPopover(skills: model.enabledSkills) { _ in }))
        default:
            return nil
        }
    }

    @MainActor
    private static func popover(_ content: some View) -> some View {
        content
            .background(Palette.chrome)
            .clipShape(.rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.lineStrong) }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(Palette.canvas)
    }

    @MainActor
    private static func seedProviders(_ model: AppModel) {
        func models(_ names: [String]) -> [ProviderModel] {
            names.map { ProviderModel(id: $0.lowercased().replacingOccurrences(of: " ", with: "-"), name: $0, format: .chat) }
        }
        var openai = ProviderAccount(kind: .ollama)
        openai.models = models(["GPT-5", "GPT-5 mini", "GPT-4.1"])
        var xai = ProviderAccount(kind: .lmstudio)
        xai.models = models(["Grok 4", "Grok 3 mini"])
        var openrouter = ProviderAccount(kind: .custom)
        openrouter.models = models((1...60).map { "Modelo \($0)" })
        model.providers = [openai, xai, openrouter]
        model.defaultModel = "ollama/gpt-5"
    }

    @MainActor
    private static func seedConversation(_ model: AppModel, bot: Bot) {
        model.apply(.message(.user("Organize minha pasta Downloads por tipo")), to: bot.id)
        model.send("Organize minha pasta Downloads por tipo", to: bot.id) // no model connected: only adds the notice line
        model.apply(.text("Vou olhar o que há na pasta antes de mover qualquer coisa."), to: bot.id)
        model.apply(.toolStarted(ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "ls ~/Downloads")), to: bot.id)
    }
}
