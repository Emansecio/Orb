#if DEBUG || ORB_DEV_TOOLS
import SwiftUI

/// The pictures of the README (`scripts/readme-shots.sh`). `Orb --snapshot readme-<scene> out.png` draws any other scene
/// (`readme-group-chat`, `readme-routines`…) as a Mac with a model connected would show it: no card asking for one, the
/// model's name in the composer. Two scenes are the README's own: `readme-showcase`, the whole window (Orbs in the
/// sidebar, three of them in a category, and a finished task in the chat), and `readme-permission`, one card waiting.
/// Made-up data; nothing is saved.
@MainActor
enum ReadmeSnapshots {
    static let prefix = "readme-"

    /// The scene to draw for `screen` once the model is connected, or nil when `screen` is not one of the README's.
    static func prepare(_ screen: String, model: AppModel) -> String? {
        guard screen.hasPrefix(prefix) else { return nil }
        connectModel(model)
        return String(screen.dropFirst(prefix.count))
    }

    /// A local provider (no key, no sign-in) whose one model reads like the one the README talks about.
    private static func connectModel(_ model: AppModel) {
        var account = ProviderAccount(kind: .custom)
        account.models = [ProviderModel(id: "claude-sonnet-5-5", name: "Sonnet 5.5", format: .chat, contextLength: 200_000)]
        model.providers = [account]
        model.defaultModel = "custom/claude-sonnet-5-5"
    }

    /// The whole window, as in the README's first picture.
    static func app(_ model: AppModel) -> AnyView {
        let atlas = Bot(name: "Atlas", role: "Assistente do seu Mac", orb: WelcomeLooks.atlas)
        let lia = Bot(name: "Lia", role: "Pesquisa e resume", orb: WelcomeLooks.lia)
        let bento = Bot(name: "Bento", role: "Cuida das finanças da casa", orb: WelcomeLooks.bento)
        let support = Bot(name: "Atendente", role: "Responde clientes no WhatsApp", orb: OrbConfig(color: "ceu", eyes: "ovais", mouth: "sorriso"))
        let landing = Bot(name: "Gestor do site", role: "Mantém a página de vendas", orb: OrbConfig(color: "lavanda", eyes: "pontos", mouth: "sorriso"))
        let review = Bot(name: "Revisor", role: "Revisa textos antes de publicar",
                         orb: OrbConfig(color: "grafite", eyes: "pilulas", brows: "retas", accessories: ["fones"]))
        model.bots = [atlas, lia, bento, support, landing, review]
        model.categories = [SidebarCategory(name: "Minha loja", botIDs: [support.id, landing.id, review.id])]
        model.live(support.id).setUnread(3)
        model.selection = .bot(atlas.id)
        return AnyView(RootView().task {
            // After the Orb's own conversation has been read from disk, which would replace this one.
            try? await Task.sleep(for: .seconds(1))
            model.seedConversation(Conversation(items: downloads), for: atlas.id)
        })
    }

    /// One request that needs a yes: the card with what the Orb wants to run and the ways to allow it.
    static func permission(_ model: AppModel) -> AnyView {
        guard let bot = model.bots.first else { return AnyView(EmptyView()) }
        let items = [
            TranscriptItem(.user(text: "Atualiza os apps do Homebrew", attachments: [])),
            TranscriptItem(.bot(text: "Vou atualizar tudo de uma vez; preciso da sua permissão para rodar o comando.", isStreaming: false)),
            TranscriptItem(.approval(ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "brew upgrade",
                                                     reason: "", suggestions: [.shell("brew", "upgrade"), .shell("brew")]))),
        ]
        return AnyView(ChatView(botID: bot.id).task {
            try? await Task.sleep(for: .seconds(1))
            model.seedConversation(Conversation(items: items), for: bot.id)
        })
    }

    /// "Organiza a minha pasta de Downloads": a few steps, folded into one line, the answer, and the go-ahead.
    private static var downloads: [TranscriptItem] {
        let start = Date.now.addingTimeInterval(-95)
        func step(_ kind: ToolCall.Kind, _ title: String, _ detail: String, at second: Double) -> TranscriptItem {
            TranscriptItem(.tool(ToolCall(kind: kind, title: title, detail: detail, state: .done, output: "ok",
                                          startedAt: start + second, finishedAt: start + second + 1.4)))
        }
        var items = [
            TranscriptItem(.user(text: "Organiza a minha pasta de Downloads e me diz o que dá para apagar", attachments: [])),
            TranscriptItem(.bot(text: "Vou ver o que tem lá antes de mexer em qualquer coisa.", isStreaming: false)),
            step(.shell, "Rodando no Terminal", "ls -la ~/Downloads", at: 2),
            step(.search, "Buscando arquivos", "*.dmg", at: 5),
            step(.shell, "Rodando no Terminal", "shasum -a 256 ~/Downloads/*.jpg", at: 9),
            step(.shell, "Rodando no Terminal", "mkdir -p ~/Downloads/{Documentos,Imagens,Instaladores}", at: 14),
            TranscriptItem(.bot(text: """
                Pronto: separei **214 arquivos** em pastas por tipo. Nada foi apagado.

                | Pasta | Arquivos | Tamanho |
                | --- | ---: | ---: |
                | Documentos | 86 | 1,2 GB |
                | Imagens | 97 | 3,4 GB |
                | Instaladores | 31 | 6,8 GB |

                **Dá para apagar sem medo**
                - 31 instaladores `.dmg` de apps que já estão instalados (6,8 GB)
                - 12 fotos repetidas, iguais byte a byte (410 MB)

                Quer que eu mande esses para a Lixeira?
                """, isStreaming: false)),
            TranscriptItem(.user(text: "Pode mandar", attachments: [])),
            step(.shell, "Rodando no Terminal", "trash ~/Downloads/Instaladores/*.dmg", at: 60),
            TranscriptItem(.bot(text: "Feito: 43 arquivos foram para a Lixeira e você ganhou **7,2 GB**. Eles ficam lá até você esvaziá-la.",
                                isStreaming: false)),
        ]
        items[0].date = start
        return items
    }
}
#endif
