import Foundation

/// Example content for the prototype. Replace with data from the OpenBot gateway.
enum SeedData {
    struct Bundle {
        var bots: [Bot]
        var transcripts: [UUID: [TranscriptItem]]
        var routines: [Routine]
        var connectors: [Connector]
        var skills: [Skill]
    }

    static func make() -> Bundle {
        let atlas = Bot(id: UUID(), name: "Atlas", role: "Cuida dos seus arquivos e do Mac", orb: OrbConfig(color: "indigo", eyes: "pilulas", mouth: "sorriso", accessories: ["oculos-redondos"]),
                        model: "grok-4.6", permissionMode: .ask, capabilities: [.terminal, .computerUse, .browser],
                        memory: [MemoryFact(text: "Prefere respostas curtas e diretas"),
                                 MemoryFact(text: "Projetos ficam em ~/Projects"),
                                 MemoryFact(text: "Não apagar nada sem perguntar")])
        let lia = Bot(id: UUID(), name: "Lia", role: "Pesquisa e escreve com você", orb: OrbConfig(color: "rosa", eyes: "ovais", cheeks: "blush", hair: "tufinho", accessories: ["laco"]),
                      model: "gpt-6-sol", permissionMode: .ask, capabilities: [.browser, .connectors], unread: 2,
                      memory: [MemoryFact(text: "Escreve em português do Brasil")])
        let ferro = Bot(id: UUID(), name: "Ferro", role: "DevOps, Terminal e deploys", orb: OrbConfig(color: "grafite", eyes: "pilulas", brows: "retas", mustache: "classico", accessories: ["fones"]),
                        model: "gpt-6-astra", permissionMode: .auto, capabilities: [.terminal, .connectors])
        let nina = Bot(id: UUID(), name: "Nina", role: "Agenda, e-mail e rotina", orb: OrbConfig(color: "menta", eyes: "felizes", mouth: "sorriso", cheeks: "sardas", accessories: ["flor"]),
                       model: "grok-4.6-fast", permissionMode: .ask, capabilities: [.connectors])

        let earlier = Date.now.addingTimeInterval(-60 * 42)
        let atlasHistory: [TranscriptItem] = [
            TranscriptItem(.user(text: "Minha pasta Downloads está um caos. Consegue organizar?", attachments: []), date: earlier),
            TranscriptItem(.tool(ToolCall(kind: .file, title: "Lendo a pasta", detail: "~/Downloads · 318 itens", state: .done,
                                          output: "PDF: 74 · Imagens: 121 · Instaladores: 38 · Outros: 85",
                                          startedAt: earlier, finishedAt: earlier.addingTimeInterval(1.8))), date: earlier),
            TranscriptItem(.bot(text: "Separei por tipo e mês. Os **38 instaladores** (.dmg/.pkg) já foram usados: posso mover para a Lixeira?", isStreaming: false), date: earlier),
            TranscriptItem(.approval(ApprovalRequest(title: "Mover arquivos para a Lixeira", command: "mv ~/Downloads/*.dmg ~/Downloads/*.pkg ~/.Trash/",
                                                     reason: "Liberar 6,2 GB de instaladores antigos.", decision: .once)), date: earlier),
            TranscriptItem(.tool(ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "mv … ~/.Trash/", state: .done,
                                          output: "38 itens movidos · 6,2 GB liberados",
                                          startedAt: earlier, finishedAt: earlier.addingTimeInterval(0.6))), date: earlier),
            TranscriptItem(.bot(text: "Feito. Liberei **6,2 GB** e criei as pastas `PDFs`, `Imagens/2026` e `Outros`. Quer que eu repita isso todo domingo?", isStreaming: false), date: earlier)
        ]

        let liaHistory: [TranscriptItem] = [
            TranscriptItem(.user(text: "Faz um resumo das novidades de agentes de IA desta semana", attachments: [])),
            TranscriptItem(.tool(ToolCall(kind: .browser, title: "Navegando", detail: "5 páginas lidas", state: .done,
                                          output: "news.ycombinator.com\nblog.openai.com\nx.ai/news\n…",
                                          startedAt: .now, finishedAt: .now.addingTimeInterval(9.4)))),
            TranscriptItem(.bot(text: "Aqui vai o resumo em 3 pontos: **agentes com computador próprio**, **rotinas agendadas** virando padrão e **MCP** consolidado como forma de conectar apps.", isStreaming: false))
        ]

        let now = Date.now
        let routines = [
            Routine(name: "Resumo da manhã", botID: nina.id, schedule: "Seg–Sex · 08:00",
                    nextRun: now.addingTimeInterval(60 * 60 * 9), isEnabled: true, pausedForInactivity: false,
                    lastResult: "3 reuniões, 12 e-mails importantes"),
            Routine(name: "Arrumar Downloads", botID: atlas.id, schedule: "Domingos · 20:00",
                    nextRun: now.addingTimeInterval(60 * 60 * 52), isEnabled: true, pausedForInactivity: false,
                    lastResult: "Liberou 6,2 GB"),
            Routine(name: "Pacotes desatualizados", botID: ferro.id, schedule: "Segundas · 09:30",
                    nextRun: now.addingTimeInterval(60 * 60 * 30), isEnabled: true, pausedForInactivity: true,
                    lastResult: "Ninguém leu os últimos 4 resultados"),
            Routine(name: "Radar de IA", botID: lia.id, schedule: "Diariamente · 18:00",
                    nextRun: now.addingTimeInterval(60 * 60 * 4), isEnabled: false, pausedForInactivity: false,
                    lastResult: "Desativada por você")
        ]

        let connectors = [
            Connector(name: "Mail", symbol: "envelope", category: "Apple", summary: "Ler, resumir e rascunhar e-mails", isConnected: true),
            Connector(name: "Calendário", symbol: "calendar", category: "Apple", summary: "Consultar e criar eventos", isConnected: true),
            Connector(name: "Notas", symbol: "note.text", category: "Apple", summary: "Buscar e escrever notas", isConnected: false),
            Connector(name: "Lembretes", symbol: "checklist", category: "Apple", summary: "Listas e tarefas", isConnected: false),
            Connector(name: "Mensagens", symbol: "message", category: "Apple", summary: "Enviar mensagens com sua aprovação", isConnected: false),
            Connector(name: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", category: "Desenvolvimento", summary: "Issues, PRs e repositórios", isConnected: true),
            Connector(name: "Linear", symbol: "line.3.horizontal.decrease", category: "Trabalho", summary: "Tarefas e ciclos", isConnected: false),
            Connector(name: "Slack", symbol: "number", category: "Trabalho", summary: "Canais e mensagens diretas", isConnected: false),
            Connector(name: "Notion", symbol: "doc.richtext", category: "Trabalho", summary: "Páginas e bancos de dados", isConnected: false),
            Connector(name: "Google Drive", symbol: "externaldrive", category: "Trabalho", summary: "Documentos e planilhas", isConnected: false),
            Connector(name: "Servidor MCP", symbol: "puzzlepiece.extension", category: "Avançado", summary: "Qualquer servidor MCP via HTTP ou stdio", isConnected: false)
        ]

        let skills = [
            Skill(slug: "relatorio-semanal", name: "Relatório semanal", summary: "Junta tarefas, commits e reuniões num resumo", uses: 18, owner: "Você"),
            Skill(slug: "triagem-email", name: "Triagem de e-mails", summary: "Classifica a caixa de entrada e sugere respostas", uses: 42, owner: "Nina"),
            Skill(slug: "limpeza-disco", name: "Limpeza segura de disco", summary: "Audita o uso de disco e propõe o que remover", uses: 7, owner: "Atlas"),
            Skill(slug: "resumo-pdf", name: "Resumo de PDF", summary: "Lê PDFs longos e devolve pontos-chave", uses: 31, owner: "Lia"),
            Skill(slug: "revisao-pr", name: "Revisão de PR", summary: "Revisa diffs com foco em bugs", uses: 12, owner: "Ferro")
        ]

        return Bundle(bots: [atlas, lia, ferro, nina],
                      transcripts: [atlas.id: atlasHistory, lia.id: liaHistory],
                      routines: routines, connectors: connectors, skills: skills)
    }
}
