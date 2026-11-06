#if DEBUG || ORB_DEV_TOOLS
import SwiftUI

/// `Orb --snapshot transcript[-approvals|-long-command|-commands[-open]|-question|-quote|-notices|-compacted|-failed|-retry|-skill-proposal|-tools[-open]|-work[-open]|-interrupted|-attachments|-outputs|-screen-steps|-browser-live|-browser-need|-browser-done|-find|-edit] out.png`
/// (the last two, like the plain `transcript`, show the default conversation and then open the find bar or take the first
/// message back into the field): a seeded conversation of the first Orb for visual review of the replies' Markdown, the approval cards and the notices
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

    /// A reply with code in a few languages and a table with cells that exports must get right.
    private static let richMarkdown = #"""
        A taxa mudou em dois lugares. O cálculo ficou assim:

        ```swift
        // Preço final, com a taxa da moeda
        @MainActor struct Preco: Sendable {
            let valor: Decimal
            func total(taxa: Decimal = 0.12) -> String {
                guard valor > 0 else { return "grátis" }
                return "R$ \(valor * (1 + taxa))"
            }
        }
        ```

        ```python
        @dataclass
        class Fila:
            nome: str = "leads"  # uma fila por dia
            def __len__(self):
                return 42 if self.nome else None
        ```

        ```json
        { "moeda": "BRL", "taxa": 0.12, "ativa": true }
        ```

        ```diff
        @@ -1,2 +1,3 @@
        -let taxa = 0.1
        +let taxa = 0.12
        +let moeda = "BRL"
        ```

        | Plano | Taxa | Observação |
        | --- | ---: | :---: |
        | **Básico** | 0,10 | sem `moeda` |
        | Pro | 0,12 | com a, b \| c |

        ```chart
        {"type":"bar","title":"Leads por mês","labels":["Jan","Fev","Mar","Abr"],
         "series":[{"name":"2025","values":[12,18,9,22]},{"name":"2026","values":[20,16,27,31]}]}
        ```

        ```chart
        {"type":"pie","title":"Origem","labels":["Busca","Indicação","Anúncio"],"values":[48,31,21]}
        ```

        ```mermaid
        flowchart LR
          A[Pedido] --> B{Tem estoque?}
          B -- sim --> C[Separar]
          B -- não --> D[Avisar o cliente]
        ```

        ```mermaid
        flowchart TD
          A --> B[
        ```

        $$
        \int_0^1 x^2\,dx = \frac{1}{3}
        $$

        ```html
        <h2 style="color:#459FFE">Prévia</h2><p>Sem scripts.</p><script>document.body.innerHTML = "falhou"</script>
        <img src="https://exemplo.invalid/x.png" alt="sem rede">
        ```

        ```page
        <h3>Contador</h3><button id="b">Somar</button> <span id="n">0</span>
        <script>let n = 41; const s = document.getElementById("n"); s.textContent = ++n;
        document.getElementById("b").onclick = () => { s.textContent = ++n; orb.propose("Cheguei a " + n); };</script>
        ```

        Custa $5 ou $10, e o relatório está em `/tmp` e em /Users/voce/inexistente/nota.md.
        """#

    /// A routine's report as its prompt now asks: what needs you first, then what waits, then what is scheduled.
    static let routineReport = """
        Rodada das 18:00: link enviado à Andressa e abertura para uma lead nova. 2 casos precisam de você.

        ## Precisa de você
        - **Marco Antônio**: mandou um áudio dizendo que passaram o contato de uma academia. Não há histórico com ele; não respondi.
        - **Vanessa**: respondeu "Tá bom". O acesso dela termina em 06/11; reativar ou substituir depende de você.

        ## Aguardando resposta
        - Andressa Souza perguntou se podia fechar o Família. Mandei o link; quando o pedido for pago, peço os dados das 4 pessoas.
        - Carla Noronha, amiga do Lucian, quer o Família. Pedi academia e cidade para conferir a cobertura.
        - Olavo, Gabriel, Adriano, Giselly, Marques e Carolina receberam a abertura e não responderam.

        ## Lembretes agendados
        - Andressa e Laine: lembrete único amanhã, perto das 18:00 e das 15:30, se não pagarem.
        - Úrsula e Rafa a partir das 19:45; Lucien e Érika a partir das 20:35.
        """

    /// The run marker's date, as `Conversation.startingRoutineRun` writes it (its formatter is private).
    private static let routineRunDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "dd/MM/yyyy 'às' HH:mm"
        return formatter
    }()

    static func view(_ screen: String, model: AppModel, bot: Bot) -> AnyView {
        let user = TranscriptItem(.user(text: "Organiza a minha pasta de Downloads", attachments: []))
        let reply = TranscriptItem(.bot(text: markdown, isStreaming: false))
        let tool = TranscriptItem(.tool(ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "ls -la ~/Downloads",
                                                 state: .done, output: "total 8\ndrwxr-xr-x  3 voce  staff   96 Oct  7 10:00 .")))
        var items: [TranscriptItem]
        switch screen {
        case "transcript-activity", "transcript-activity-open", "transcript-activity-need":
            ToolGroupRow.opensInSnapshots = screen.hasSuffix("-open")
            model.liveScreens = LiveFeedHub(source: ActivitySnapshotBrowser())
            var provider = ProviderAccount(kind: .ollama)
            provider.models = [ProviderModel(id: "modelo-teste", name: "Modelo de revisão", format: .chat)]
            model.providers = [provider]
            model.defaultModel = "ollama/modelo-teste"
            func action(_ intent: String, _ state: ToolCall.State = .done) -> TranscriptItem {
                let start = Date.now.addingTimeInterval(-60)
                return TranscriptItem(.tool(ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "python3 rotina.py",
                                                     state: state, output: state == .done ? "ok" : nil, startedAt: start,
                                                     finishedAt: state == .running ? nil : start.addingTimeInterval(0.1), intent: intent)))
            }
            let browser = LiveScreenSnapshots.items("transcript-browser-live", model: model, bot: bot)
            items = [TranscriptItem(.user(text: "Altere a rotina para cada 30 minutos e rode uma rodada agora.", attachments: [])),
                     TranscriptItem(.bot(text: "Encontrei uma rotina ativa e outra antiga pausada. Vou alterar só a ativa para não duplicar mensagens.", isStreaming: false)),
                     action("Conferir rotina ativa"), action("Conferir rotina ativa"),
                     TranscriptItem(.bot(text: "A rotina já está em intervalos de 30 minutos, mantendo a faixa das 8h às 23h.", isStreaming: false)),
                     action("Ajustar rotina para cada 30 minutos"),
                     TranscriptItem(.bot(text: "Agora vou conferir as respostas recentes, os pagamentos e os leads elegíveis, excluindo os contatados hoje.", isStreaming: false)),
                     action("Revisar conversas e pagamentos", .running)]
            items += browser.filter { if case .browserView = $0.kind { true } else { false } }
            if screen.hasSuffix("-need") {
                items.append(TranscriptItem(.approval(ApprovalRequest.question(
                    OrbQuestion(text: "Qual limite de desconto posso oferecer?", options: ["Sem desconto", "Até 10%"]), botName: bot.name))))
            }
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
            items = [user, TranscriptItem(.notice("Não deu certo: A chave ou o login foi recusado (401). Detalhe do provedor: invalid x-api-key"))]
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
                     TranscriptItem(.notice("Cache do provedor desligado: cada passo custa mais. Ver Ajustes › Modelos")),
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
        case "transcript-routine":
            // The chat while a routine runs: your lines stay, the run is narrated after them (`BotSession.shownItems`).
            // Seeded in the task below: the launch read of the conversation would otherwise replace this one after the
            // scene was built.
            items = []
        case "transcript-browser-live", "transcript-browser-need", "transcript-browser-done":
            items = LiveScreenSnapshots.items(screen, model: model, bot: bot)
        case "transcript-rich":
            // Colors in code, the buttons of a table, a change in `edit_file` and the way back to the end.
            ToolGroupRow.opensInSnapshots = true
            ToolCallLine.opensInSnapshots = true
            JumpToEndButton.showsInSnapshots = true
            let start = Date.now.addingTimeInterval(-60)
            let edit = ToolCall(kind: .file, title: EditFileTool.title,
                                detail: "/Users/voce/Projetos/app/Sources/Preco.swift\n" + EditFileTool.diff(old: "let taxa = 0.1", new: "let taxa = 0.12\nlet moeda = \"BRL\""),
                                state: .done, output: "Arquivo editado.", startedAt: start, finishedAt: start.addingTimeInterval(0.2))
            items = [user, TranscriptItem(.tool(edit)), TranscriptItem(.bot(text: richMarkdown, isStreaming: false))]
        case "transcript-rich-work":
            // The rail, the plan's card, what a turn read and changed, and the fuller questions.
            let start = Date.now.addingTimeInterval(-60)
            func call(_ kind: ToolCall.Kind, _ title: String, _ detail: String) -> TranscriptItem {
                TranscriptItem(.tool(ToolCall(kind: kind, title: title, detail: detail, state: .done, output: "ok", startedAt: start, finishedAt: start.addingTimeInterval(1))))
            }
            items = [TranscriptItem(.user(text: "Pesquise os preços dos concorrentes", attachments: [])),
                     call(.browser, "Lendo página", "https://www.exemplo.com.br/precos"),
                     call(.browser, "Lendo página", "https://docs.exemplo.org/planos"),
                     call(.schedule, "Agendando tarefa", "“Conferir preços” · toda segunda · 9h"),
                     call(.memory, "Guardando na memória (fato)", "O plano Pro custa R$ 49"),
                     TranscriptItem(.bot(text: "O Pro continua a R$ 49. Deixei uma rotina semanal para conferir.", isStreaming: false)),
                     TranscriptItem(.user(text: "Agora monte o relatório para a reunião de sexta", attachments: [])),
                     TranscriptItem(.bot(text: "Preciso de dois detalhes.", isStreaming: false)),
                     TranscriptItem(.approval(ApprovalRequest.question(
                         OrbQuestion(text: "Quais seções entram?", options: ["Resumo", "Preços", "Riscos"], multiple: true), botName: bot.name))),
                     TranscriptItem(.approval(ApprovalRequest.question(
                         OrbQuestion(text: "Como devo enviar?", fields: [.init(label: "Para quem"), .init(label: "Formato", options: ["PDF", "Planilha"])]), botName: bot.name)))]
        case "transcript-report":
            // A routine's report in the shape its prompt asks for (`RoutinePrompt.unattended`), with the way back to
            // the end over the fade and the chip of an Orb that asks nothing.
            JumpToEndButton.showsInSnapshots = true
            model.update(bot.id) { $0.permissionMode = .bypass }
            items = [TranscriptItem(.user(text: "Como estão os atendimentos de hoje?", attachments: [])),
                     TranscriptItem(.bot(text: routineReport, isStreaming: false))]
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
            if screen != "transcript-routine" { model.seedConversation(Conversation(items: items), for: bot.id) }
            if screen == "transcript-routine" {
                let routine = Routine(name: "Resumo da manhã", botID: bot.id,
                                      prompt: "Faça um resumo da minha manhã usando a agenda e o e-mail.",
                                      schedule: .daily(hour: 8, minute: 30))
                if !model.routines.contains(where: { $0.name == routine.name }) { model.routines.append(routine) }
                let started = Date.now.addingTimeInterval(-90)
                var run = Conversation(items: [
                    TranscriptItem(.notice(Conversation.routineRunMarker + Self.routineRunDate.string(from: started))),
                    TranscriptItem(.user(text: routine.prompt, attachments: [])),
                    TranscriptItem(.tool(ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "ls -la ~/Downloads",
                                                  state: .done, output: "total 8"))),
                    TranscriptItem(.bot(text: "Agenda conferida: 3 reuniões hoje. Agora vou ao e-mail para completar o resumo.",
                                        isStreaming: true))])
                for index in run.items.indices { run.items[index].date = started.addingTimeInterval(Double(index) * 12) }
                let session = model.session(bot.id)
                // The chat first, then the run parks it for its own conversation.
                session.conversation = Conversation(items: [
                    TranscriptItem(.user(text: "Me lembra de revisar o orçamento amanhã cedo.", attachments: [])),
                    TranscriptItem(.bot(text: "Anotado! Vou te lembrar no resumo de amanhã.", isStreaming: false))])
                session.startRoutineRun(routine.id, conversation: run, at: started)
                let live = model.live(bot.id)
                live.setStatus("Pensando")
                live.setWork(WorkLine(verb: "Lendo e-mails novos", target: "caixa de entrada", routine: routine.name, actions: 2))
                model.orbTranscript(bot.id).setLive(true)
            }
            if screen.hasPrefix("transcript-activity") {
                let live = model.live(bot.id)
                live.setStatus("Pensando")
                live.setWork(WorkLine(verb: "Pensando", actions: 4))
                let transcript = model.orbTranscript(bot.id)
                transcript.setLive(true)
                transcript.showPlan(TaskPlan(goal: "Ajustar rotina e iniciar nova rodada", steps: [
                    .init(text: "Conferir rotina ativa", state: .done),
                    .init(text: "Ajustar intervalo", state: .done),
                    .init(text: "Revisar conversas e pagamentos", state: .inProgress),
                    .init(text: "Responder leads elegíveis")
                ]))
                if screen.hasSuffix("-need") {
                    model.setAwaitingApproval(true, of: bot.id)
                    live.setWork(WorkLine(verb: "Esperando sua resposta", tone: .waiting, actions: 4))
                }
                // Re-seed after the offscreen layer subscribed: this scene has a drawn page, never a running browser.
                try? await Task.sleep(for: .milliseconds(500))
                LiveScreenSnapshots.tab(model: model, botID: bot.id)
            }
            if screen == "transcript-rich-work" {
                model.orbTranscript(bot.id).showPlan(TaskPlan(goal: "Montar o relatório", steps: [
                    TaskPlan.Step(text: "Reunir os preços", state: .done), TaskPlan.Step(text: "Escrever o resumo", state: .inProgress),
                    TaskPlan.Step(text: "Conferir os números", state: .pending)]))
            }
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

/// Holds the transport while the review scene supplies its own frame. No real browser or socket is opened.
private struct ActivitySnapshotBrowser: LiveBrowserSource {
    func generation(botID: UUID) -> Int? { 1 }
    func streamPort(botID: UUID) async throws -> Int? {
        try await Task.sleep(for: .seconds(30))
        return nil
    }
    func pageLooksSensitive(botID: UUID) -> Bool { false }
    func setPointerHandler(_ handler: (@Sendable (UUID, LivePointer) -> Void)?, only botID: UUID?) {}
}
#endif
