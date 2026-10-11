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
        case "chat-working", "chat-working-wait", "chat-working-retry", "chat-attachments-queued":
            return workingTurn(screen, model: model, bot: bot)
        case "chat-typed":
            seedConversation(model, bot: bot)
            model.setDraft("Resuma o relatório e destaque os riscos", for: bot.id)
            let lane = model.composerLane(bot.id)
            lane.files = [AttachedFile(url: URL(fileURLWithPath: "/Users/x/Documentos/relatório.pdf")),
                          AttachedFile(url: URL(fileURLWithPath: "/Users/x/Documentos/orçamento.xlsx"))]
            return AnyView(ChatView(botID: bot.id))
        case "chat-attachments":
            // Two pictures (drawn here, in the run's data folder), a file and one picture still being prepared.
            seedConversation(model, bot: bot)
            let lane = model.composerLane(bot.id)
            lane.pictures = [sampleImage(named: "a", hue: 0.6), sampleImage(named: "b", hue: 0.05)]
            lane.files = [AttachedFile(url: URL(fileURLWithPath: "/Users/x/Documentos/relatório.pdf"))]
            lane.pendingPictures = 1
            lane.error = "Não foi possível ler uma das imagens."
            model.setDraft("O que há nestas imagens?", for: bot.id)
            return AnyView(ChatView(botID: bot.id))
        case "chat-slash":
            model.skills = [Skill(slug: "resumir", name: "Resumir", summary: "Resume um texto ou arquivo em poucos tópicos.", instructions: "x"),
                            Skill(slug: "revisar", name: "Revisar código", summary: "Revisa mudanças e aponta riscos.", instructions: "x"),
                            Skill(slug: "traduzir", name: "Traduzir", summary: "Traduz mantendo o tom.", instructions: "x")]
            model.setDraft("/re", for: bot.id)
            return AnyView(ChatView(botID: bot.id))
        case "chat-greeting", "chat-greeting-returning", "chat-greeting-typed":
            // A new Orb as the app makes it (it works in the home folder, so no folder is made), with its greeting.
            let lia = model.createBot(name: "Lia", role: "Assistente pessoal", orb: OrbConfig(color: "rosa", eyes: "ovais", mouth: "sorriso", temperament: .calmo),
                                      model: "", mode: .ask, folder: .home)
            if screen.hasSuffix("returning") {
                let text = OrbGreeting.text(name: lia.name, temperament: lia.orb.temperament, returning: true)
                model.editConversation(lia.id) { $0.items = [TranscriptItem(.greeting(text))] }
            }
            if screen.hasSuffix("typed") { model.setDraft(OrbGreeting.draft, for: lia.id) } // the replies are gone
            return AnyView(ChatView(botID: lia.id))
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

    /// Mid-turn, 16 s in, after two steps that are done: `chat-working` runs `swift build --jobs 6` (the phrase with its
    /// target, "3 ações"; one message that reached the Orb mid-task, marked, and two that wait: one steers, one for
    /// after the task), `chat-working-wait` waits for your answer to a card (the phrase
    /// stands still in the warning color) and `chat-working-retry` waits to try again (the countdown takes the
    /// clock's place). The phrases come in at once (no minimum time), as in a turn that has been going on a while.
    @MainActor
    private static func workingTurn(_ screen: String, model: AppModel, bot: Bot) -> AnyView {
        let id = bot.id
        let live = model.live(id)
        live.setWorkDwell(.zero)
        let read = ToolCall(kind: .file, title: "Lendo arquivo", detail: "/Users/x/Projetos/app/README.md", state: .done,
                            output: "# App\n\nTODO: escrever docs", startedAt: .now - 9, finishedAt: .now - 8.6)
        let search = ToolCall(kind: .search, title: "Buscando no conteúdo", detail: "TODO", state: .done,
                              output: "README.md:3: TODO: escrever docs", startedAt: .now - 8, finishedAt: .now - 7.7)
        var items = [TranscriptItem(.user(text: "Compile o projeto e me diga se há erros", attachments: [])),
                     TranscriptItem(.bot(text: "Vou olhar o projeto antes de compilar.", isStreaming: false)),
                     TranscriptItem(.tool(read)), TranscriptItem(.tool(search))]
        model.apply(.status("Pensando"), to: id)
        for done in [read, search] {
            model.apply(.toolStarted(done), to: id)
            model.apply(.toolFinished(id: done.id, state: .done, output: done.output ?? ""), to: id)
            model.apply(.status("Pensando"), to: id)
        }
        switch screen {
        case "chat-working-wait":
            let card = ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "git push origin main",
                                       reason: "", suggestions: [.shell("git", "push"), .shell("git")])
            items.append(TranscriptItem(.approval(card)))
            model.apply(.status("Esperando sua resposta"), to: id)
            model.setAwaitingApproval(true, of: id)
        case "chat-working-retry":
            // Long enough that the countdown still has a number when the picture is taken.
            model.apply(.status(Retry.waitStatus(seconds: 40, after: LLMError.network(code: -1009, message: "offline"))), to: id)
        default:
            let build = ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "swift build --jobs 6")
            if screen == "chat-working" {
                items += [TranscriptItem(.user(text: "Só o módulo Engine, por favor.", attachments: []), duringTask: true),
                          TranscriptItem(.bot(text: "Certo, só o Engine.", isStreaming: false))]
            }
            items.append(TranscriptItem(.tool(build)))
            model.apply(.toolStarted(build), to: id)
            model.apply(.status("Rodando no Terminal"), to: id)
        }
        model.session(id).turnTask = Task { try? await Task.sleep(for: .seconds(3600)) }
        live.backdateWork(to: .now.addingTimeInterval(-16))
        if screen == "chat-attachments-queued" { AttachmentSnapshots.queue(model.composerLane(id)) }
        if screen == "chat-working" {
            let lane = model.composerLane(id)
            lane.enqueue(SteeredMessage(text: "Na verdade, ignore a pasta node_modules.", prompt: "", delivery: .steer))
            lane.enqueue(SteeredMessage(text: "E me mande um resumo no fim.", files: [URL(fileURLWithPath: "/Users/x/Documentos/relatório.pdf")], prompt: "",
                                        delivery: .afterTask))
            model.setDraft("Depois disso, rode os testes", for: id)
        }
        // After the Orb's own conversation has been read from disk, which would replace this one.
        return AnyView(ChatView(botID: id).task {
            try? await Task.sleep(for: .seconds(1))
            model.seedConversation(Conversation(items: items), for: id)
        })
    }

    /// A small gradient PNG in the run's data folder (which `DevRun` removes on exit when it is temporary), as a
    /// picture attached to the composer.
    @MainActor
    static func sampleImage(named name: String, hue: CGFloat) -> ImageAttachment {
        let size = NSSize(width: 240, height: 180)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1),
                                NSColor(hue: hue + 0.1, saturation: 0.8, brightness: 0.4, alpha: 1)])?.draw(in: rect, angle: 60)
            return true
        }
        let folder = DevRun.currentDataFolder.url.appendingPathComponent("snapshot-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("orb-snapshot-\(name).png")
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        return ImageAttachment(path: url.path, mediaType: "image/png", width: 240, height: 180)
    }

    @MainActor
    private static func seedConversation(_ model: AppModel, bot: Bot) {
        model.apply(.message(.user("Organize minha pasta Downloads por tipo")), to: bot.id)
        model.send("Organize minha pasta Downloads por tipo", to: bot.id) // no model connected: only adds the notice line
        model.apply(.text("Vou olhar o que há na pasta antes de mover qualquer coisa."), to: bot.id)
        model.apply(.toolStarted(ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "ls ~/Downloads")), to: bot.id)
    }
}
