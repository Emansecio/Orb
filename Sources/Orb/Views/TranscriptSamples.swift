import SwiftUI

/// `Orb --snapshot transcript[-approvals|-notices|-failed|-attachments|-outputs] out.png`: a seeded conversation of the first Orb for visual
/// review of the replies' Markdown, the approval cards and the notices with an action. Dev aid; nothing is saved.
@MainActor
enum TranscriptSample {
    static let markdown = """
        Encontrei **42 arquivos** na pasta. Resumo por tipo:

        ## Por tipo

        - PDFs: 12 (maioria contratos)
        - Imagens: 20, entre elas `logo.png`
        - Planilhas: 10
          - 4 de `2024` e 6 de `2025`

        ### Próximos passos

        1. Mover os PDFs para `Contratos/`
        2. Apagar as imagens duplicadas
        3. Ver a [documentação](https://example.com/docs) antes de mexer nas planilhas

        > Nada foi apagado ainda. Eu só listei o que existe.

        Para mover tudo de uma vez:

        ```bash
        mkdir -p Contratos
        mv *.pdf Contratos/

        echo "pronto"
        ```

        | Tipo | Quantidade | Tamanho |
        | --- | :---: | ---: |
        | PDF | 12 | 48 MB |
        | Imagem | 20 | 310 MB |

        ---

        Quer que eu faça isso agora?
        """

    static func view(_ screen: String, model: AppModel, bot: Bot) -> AnyView {
        let user = TranscriptItem(.user(text: "Organiza a minha pasta de Downloads", attachments: []))
        let reply = TranscriptItem(.bot(text: markdown, isStreaming: false))
        let tool = TranscriptItem(.tool(ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "ls -la ~/Downloads",
                                                 state: .done, output: "total 8\ndrwxr-xr-x  3 voce  staff   96 Oct  7 10:00 .")))
        let items: [TranscriptItem]
        switch screen {
        case "transcript-approvals":
            let batch = [ApprovalItem(toolName: "write_file", title: "Gravando arquivo", command: "~/Projetos/app/README.md"),
                         ApprovalItem(toolName: "write_file", title: "Gravando arquivo", command: "~/Projetos/app/notas.txt"),
                         ApprovalItem(toolName: "run_command", title: "Rodando no Terminal", command: "git commit -am \"Atualiza notas\"")]
            items = [user, tool,
                     TranscriptItem(.approval(ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "brew upgrade",
                                                              reason: "", decision: .once))),
                     TranscriptItem(.approval(ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "rm -rf build",
                                                              reason: "", decision: .deny, note: "use a lixeira"))),
                     TranscriptItem(.approval(ApprovalRequest(toolName: "batch", title: "3 ações precisam da sua permissão", command: "",
                                                              reason: "\(bot.name) precisa da sua permissão para continuar.",
                                                              suggestions: [.shell("git"), .folder("/Users/x/Projetos/app")], items: batch))),
                     TranscriptItem(.approval(ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "brew upgrade",
                                                              reason: "", suggestions: [.shell("brew", "upgrade"), .shell("brew")]))),
                     TranscriptItem(.approval(ApprovalRequest(toolName: "run_command", title: "Apagando arquivos", command: "rm -rf ~/Downloads/antigos",
                                                              reason: "Esta ação não pode ser desfeita.", isDangerous: true)))]
        case "transcript-attachments":
            items = AttachmentSnapshots.conversation()
        case "transcript-outputs":
            items = AttachmentSnapshots.outputs()
        case "transcript-notices":
            items = [user, reply,
                     TranscriptItem(.notice("Conversa compactada: o começo virou um resumo.")),
                     TranscriptItem(.notice(AgentEngineNotice.paused))]
        case "transcript-failed":
            items = [user, TranscriptItem(.notice("Não deu certo: Chave ou login inválido (401). Confira em Ajustes → Modelos. Detalhe do provedor: invalid x-api-key"))]
        case "transcript-skill-proposal":
            items = [TranscriptItem(.user(text: "Publica o site de novo, agora com a versão 2.4", attachments: [])), tool,
                     TranscriptItem(.bot(text: "Publicado: a versão 2.4 já está no ar e o rodapé confere.", isStreaming: false)),
                     TranscriptItem(.notice("Skill proposta: /publicar-site — Publicar site"))]
        case "transcript-retry":
            items = [user, TranscriptItem(.notice("Não deu certo: Sem conexão com o provedor: A conexão com a Internet parece estar desligada."))]
        default:
            items = [user, tool, reply]
        }
        // After the Orb's own conversation has been read from disk, which would replace this one.
        return AnyView(ChatView(botID: bot.id).task {
            // The notice offers "Revisar" only while the proposal it speaks of waits in the Orb's memory.
            if screen == "transcript-skill-proposal" { _ = await model.memory.bank(for: bot.id).proposeSkill(SkillSnapshots.proposal) }
            try? await Task.sleep(for: .seconds(1))
            model.seedConversation(Conversation(items: items), for: bot.id)
        })
    }
}

private enum AgentEngineNotice {
    static let paused = AgentEngine.pausedNotice(after: 30)
}
