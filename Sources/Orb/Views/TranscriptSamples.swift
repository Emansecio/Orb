#if DEBUG || ORB_DEV_TOOLS
import SwiftUI

/// `Orb --snapshot transcript[-approvals|-long-command|-commands[-open]|-question|-quote|-notices|-compacted|-failed|-attachments|-outputs|-screen-steps|-browser-live|-browser-need|-browser-done] out.png`:
/// a seeded conversation of the first Orb for visual review of the replies' Markdown, the approval cards and the notices
/// with an action. Dev aid; nothing is saved.
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
        var items: [TranscriptItem]
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
        case "transcript-long-command":
            let script = (["set -e", "cd ~/Projetos/app"] + (1...28).map { "swift test --filter Suite\($0) | tee -a /tmp/log.txt" })
                .joined(separator: "\n")
            items = [user, TranscriptItem(.approval(ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal",
                                                                    command: script, reason: "")))]
        case "transcript-question":
            // Yesterday's question, answered, and a new one waiting: a time separator above each moment.
            let yesterday = Date.now.addingTimeInterval(-26 * 3600)
            var asked = ApprovalRequest.question(OrbQuestion(text: "Os PDFs de contratos vão para onde?",
                                                             options: ["Contratos/2024 e Contratos/2025", "Uma pasta só, Contratos"]),
                                                 botName: bot.name)
            asked.decision = .once
            asked.question?.answer = "Contratos/2024 e Contratos/2025"
            var earlier = [user, TranscriptItem(.approval(asked)),
                           TranscriptItem(.bot(text: "Pronto: 12 PDFs separados por ano.", isStreaming: false))]
            for index in earlier.indices { earlier[index].date = yesterday.addingTimeInterval(Double(index) * 60) }
            let open = ApprovalRequest.question(OrbQuestion(text: "Achei 20 imagens duplicadas (310 MB). O que faço com elas?",
                                                            options: ["Mover para a Lixeira", "Deixar numa pasta Duplicadas",
                                                                      "Não mexer agora"]),
                                                botName: bot.name)
            items = earlier + [TranscriptItem(.user(text: "Agora as imagens", attachments: [])), TranscriptItem(.approval(open))]
        case "transcript-quote":
            // A message that quotes a passage of the reply above it.
            items = [user, reply,
                     TranscriptItem(.user(text: "> Mover os PDFs para Contratos/\n\nPode, mas separa por ano.", attachments: [])),
                     TranscriptItem(.bot(text: "Combinado: `Contratos/2024` e `Contratos/2025`.", isStreaming: false))]
        case "transcript-screen-steps":
            items = AttachmentSnapshots.screenSteps()
        case "transcript-attachments":
            items = AttachmentSnapshots.conversation()
        case "transcript-outputs":
            items = AttachmentSnapshots.outputs()
        case "transcript-notices":
            items = [user, reply,
                     TranscriptItem(.notice("Conversa compactada: o começo virou um resumo.")),
                     TranscriptItem(.notice(AgentEngineNotice.paused))]
        case "transcript-compacted":
            // Two older requests folded by "Compactar agora"; the last exchange and the notice stay.
            let older = [("Lista os PDFs da pasta", "São 12 PDFs, a maioria contratos de 2024."),
                         ("Quais são de 2025?", "Três: o de aluguel, o da academia e o do seguro.")]
            items = older.flatMap { asked, said in
                [TranscriptItem(.user(text: asked, attachments: [])), TranscriptItem(.bot(text: said, isStreaming: false))]
            } + [TranscriptItem(.user(text: "Move esses três para Contratos/2025", attachments: [])),
                 TranscriptItem(.bot(text: "Pronto: os três estão em `Contratos/2025`.", isStreaming: false)),
                 TranscriptItem(.notice("Compactei a conversa: os 2 primeiros pedidos viraram um resumo (≈ 58 mil → 19 mil tokens)."))]
        case "transcript-failed":
            items = [user, TranscriptItem(.notice("Não deu certo: Chave ou login inválido (401). Confira em Ajustes → Modelos. Detalhe do provedor: invalid x-api-key"))]
        case "transcript-skill-proposal":
            items = [TranscriptItem(.user(text: "Publica o site de novo, agora com a versão 2.4", attachments: [])), tool,
                     TranscriptItem(.bot(text: "Publicado: a versão 2.4 já está no ar e o rodapé confere.", isStreaming: false)),
                     TranscriptItem(.notice("Skill proposta: /publicar-site — Publicar site"))]
        case "transcript-tools", "transcript-tools-open", "transcript-work", "transcript-work-open", "transcript-interrupted":
            // The shape of a long task: words of the Orb between runs of commands, a notice in the middle, one failure.
            // `transcript-work`: the same request finished, with its answer (its work folds into one line).
            // `transcript-interrupted`: the app closed in the middle of it, and the next request asked about it.
            ToolGroupRow.opensInSnapshots = screen.hasSuffix("-open")
            let folder = "\"/Users/voce/Projetos/AcessosFit-Brain/scripts"
            func run(_ detail: String, _ kind: ToolCall.Kind = .shell, _ title: String = "Rodando no Terminal",
                     _ state: ToolCall.State = .done) -> TranscriptItem {
                let start = Date.now.addingTimeInterval(-60)
                return TranscriptItem(.tool(ToolCall(kind: kind, title: title, detail: detail, state: state, output: "ok",
                                                     startedAt: start, finishedAt: start.addingTimeInterval(0.2))))
            }
            items = [TranscriptItem(.user(text: "Levante os leads de 01/10 até hoje e responda os pendentes", attachments: [])),
                     TranscriptItem(.bot(text: "Vou revisar a skill, levantar os leads e então responder os pendentes.", isStreaming: false)),
                     run("/Users/voce/Projetos/AcessosFit-Brain/skills/whatsapp/SKILL.md", .file, "Lendo arquivo"),
                     run("python3 \(folder)/fila.py\" --desde 2025-10-01"),
                     run("python3 \(folder)/fila.py\" --resumo"),
                     TranscriptItem(.bot(text: "A fila trouxe 61 conversas; agora vou ler o histórico de cada uma em lotes.", isStreaming: false)),
                     run("cd \(folder)\" && ls"),
                     TranscriptItem(.notice("O provedor não está reaproveitando o início das conversas (cache), o que deixa cada passo mais caro. Se continuar, confira o modelo e o provedor em Ajustes → Modelos.")),
                     run("python3.14 \(folder)/historico.py\" --lote 1"),
                     run("python3.14 \(folder)/historico.py\" --lote 2"),
                     run("python3.14 \(folder)/historico.py\" --lote 3", .shell, "Rodando no Terminal", .failed),
                     run("python3.14 \(folder)/historico.py\" --lote 3"),
                     run("python3.14 - <<'PY'"),
                     run("python3.14 - <<'PY'"),
                     run("python3.14 - <<'PY' > /tmp/af_report.txt")]
            if screen.hasPrefix("transcript-work") {
                items[0].date = .now.addingTimeInterval(-65)
                items.append(TranscriptItem(.bot(text: "Pronto: dos 61 contatos, 12 eram leads sem resposta. Respondi os 12 conforme o Brain e deixei o relatório em /tmp/af_report.txt.", isStreaming: false)))
            }
            if screen == "transcript-interrupted" {
                items[0].date = .now.addingTimeInterval(-65)
                items += [TranscriptItem(.notice(BotSession.quitNotice)),
                          TranscriptItem(.user(text: "respondeu todos?", attachments: [])),
                          run("python3 \(folder)/fila.py\" --pendentes"),
                          TranscriptItem(.bot(text: "Ainda não: ficaram 4 sem resposta. Vou terminar agora.", isStreaming: false)),
                          run("python3 \(folder)/responder.py\" --lote 4"),
                          run("python3 \(folder)/fila.py\" --pendentes"),
                          TranscriptItem(.bot(text: "Respondidos todos: os 4 que faltavam receberam o link e o passo a passo do Pix.", isStreaming: false)),
                          TranscriptItem(.notice("Melhoria proposta para /publicar-site")),
                          TranscriptItem(.user(text: "valeu", attachments: [])),
                          TranscriptItem(.bot(text: "Por nada!", isStreaming: false))]
            }
        case "transcript-commands", "transcript-commands-open":
            // Single actions in each state, each opened in `-open`: a command that worked (run elsewhere), one that failed
            // with a long traceback, a script, a file read, a background server and one still running.
            // Seven actions in a row fold into one group: drawn open, so every line shows.
            ToolGroupRow.opensInSnapshots = true
            ToolCallLine.opensInSnapshots = screen.hasSuffix("-open")
            func action(_ kind: ToolCall.Kind, _ title: String, _ detail: String, _ state: ToolCall.State = .done,
                        output: String?, seconds: Double, intent: String? = nil) -> TranscriptItem {
                let start = Date.now.addingTimeInterval(-120)
                return TranscriptItem(.tool(ToolCall(kind: kind, title: title, detail: detail, state: state, output: output,
                                                     startedAt: start, finishedAt: state == .running ? nil : start.addingTimeInterval(seconds),
                                                     intent: intent)))
            }
            let traceback = (["Lendo 20 conversas…", "Traceback (most recent call last):",
                              "  File \"historico.py\", line 88, in <module>", "    for msg in fetch(chat_id):",
                              "  File \"historico.py\", line 41, in fetch", "    r.raise_for_status()"]
                             + (1...30).map { "  [debug] tentativa \($0) de 30" }
                             + ["requests.exceptions.HTTPError: 429 Too Many Requests", "Lote 3 interrompido."]).joined(separator: "\n")
            items = [TranscriptItem(.user(text: "Compila o app e roda o lote 3 do histórico", attachments: [])),
                     action(.shell, "Rodando no Terminal", "swift build\n\nem ~/Projetos/app",
                            output: "Código de saída: 0\nBuilding for debugging...\n[412/418] Compiling Orb TranscriptViews.swift\n[416/418] Linking Orb\nBuild complete! (12,38s)",
                            seconds: 12.4),
                     action(.shell, "Rodando no Terminal", "python3.14 historico.py --lote 3", .failed,
                            output: "Código de saída: 1\n" + traceback + "\n[full output saved at /tmp/orb-saidas/x.txt (44 lines, 2 KB); read it with read_file (offset/limit) or grep instead of running the command again]",
                            seconds: 2.1),
                     action(.shell, "Rodando no Terminal", "python3 - <<'EOF'\nimport json\nprint(json.dumps({'ok': True}))\nEOF",
                            output: "Código de saída: 0\n{\"ok\": true}", seconds: 1.1),
                     action(.shell, "Rodando no Terminal", "grep -n TODO README.md", output: "Código de saída: 1\n(sem saída)", seconds: 0.1,
                            intent: "Procurar pendências no README"),
                     action(.file, "Lendo arquivo", "/Users/voce/Projetos/AcessosFit-Brain/skills/whatsapp/SKILL.md",
                            output: "# WhatsApp\n\nResponda os leads em até 1 hora.\nUse o modelo de mensagem do Brain.", seconds: 0.05),
                     action(.shell, "Rodando em segundo plano", "npm run dev",
                            output: "[O comando continua rodando em segundo plano como o processo j1.]", seconds: 0.4),
                     action(.shell, "Rodando no Terminal", "swift test --filter ToolIntentTests", .running, output: nil, seconds: 0)]
        case "transcript-browser-live", "transcript-browser-need", "transcript-browser-done":
            items = LiveScreenSnapshots.items(screen, model: model, bot: bot)
        case "transcript-retry":
            items = [user, TranscriptItem(.notice("Não deu certo: Sem conexão com o provedor: A conexão com a Internet parece estar desligada."))]
        default:
            items = [user, tool, reply]
        }
        // After the Orb's own conversation has been read from disk, which would replace this one.
        return AnyView(ChatView(botID: bot.id).task {
            // The notice offers "Revisar" only while the proposal it speaks of waits in the Orb's memory.
            if screen == "transcript-skill-proposal" || screen == "transcript-interrupted" { _ = await model.memory.bank(for: bot.id).proposeSkill(SkillSnapshots.proposal) }
            try? await Task.sleep(for: .seconds(1))
            model.seedConversation(Conversation(items: items), for: bot.id)
            if screen == "transcript-browser-live" { await LiveScreenSnapshots.point(model: model, botID: bot.id) }
            // The bar over the top of the conversation (⌘F), and the first message taken back into the field (Editar).
            if screen == "transcript-find" { try? await Task.sleep(for: .seconds(1)); model.request(.findInConversation, of: bot.id) }
            if screen == "transcript-edit" {
                try? await Task.sleep(for: .seconds(1))
                if let first = items.first { _ = model.beginEditing(itemID: first.id, of: bot.id) }
            }
        })
    }
}

private enum AgentEngineNotice {
    static let paused = AgentEngine.pausedNotice(after: 100)
}
#endif
