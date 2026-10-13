# Revisão do workspace dos Orbs — 12/10/2026

Base da análise: código atual (`dc75ab7`), **o prompt e as ferramentas reais** que um Orb recebeu hoje
(`~/Library/Application Support/Orb/claude-pipe/runs/*/system.txt` e `tools.json`), as **3 conversas salvas**
(~1.350 mensagens, 80 finais de turno, 293 `run_command`) e o registro de uso de outubro. Subagentes: Codex Sol
(término do turno), Sonnet (jobs em background) e Codex Luna (medição, que eu também refiz direto no disco). Conferi
pessoalmente cada `arquivo:linha` que eles citaram antes de usar.

## O diagnóstico em uma frase

O prompt **não** é o vilão: ele é enxuto (~2,5 mil tokens). Os Orbs se perdem por **quatro lacunas concretas**: o
motor não liga os jobs à tela, o prompt pede para anunciar a ação mas não para executá-la na mesma resposta, a pasta
do Orb não é usada como workspace (scripts vão para `/tmp`) e a revisão de skills gera quase-duplicatas. O excesso de
informação que você sente vem principalmente das **48 ferramentas (~7,4 mil tokens)**, três vezes o tamanho do prompt.

---

## P0 — Comandos em background invisíveis

**O que detectei**
- `AppModel.jobs` é `@ObservationIgnored` e `BackgroundJobs` é um actor sem nenhum estado observável
  ([AppModel.swift:231](../Sources/Orb/AppModel.swift:231)). Nenhuma view lê jobs (`grep -i job` em `Views/` não acha nada).
- `run_command(background: true)` espera 1 s e devolve. O cartão vira **"concluído em 1,0 s"**
  ([BackgroundJobs.swift:138](../Sources/Orb/Engine/Tools/BackgroundJobs.swift:138)). Para você, parece um comando que já acabou.
- Quando o job termina, `ended()` só atualiza um dicionário interno
  ([BackgroundJobs.swift:228](../Sources/Orb/Engine/Tools/BackgroundJobs.swift:228)). Ninguém é avisado, nem você nem o Orb.
  O resultado fica parado no log até alguém perguntar.

**Proposta (~45 linhas, sem tipo novo)**
1. `BackgroundJobs`: um stream de mudanças, `nonisolated let (changes, changed) = AsyncStream<UUID>.makeStream()`,
   e `changed.yield(botID)` no fim de `start`, `ended`, `terminate` e `watchGroup`. São 5 linhas.
2. `BotLive`: `var jobs: [BackgroundJobs.Snapshot] = []`. O `Snapshot` já é `Sendable`/`Equatable` e já traz
   `command`, `startedAt`, `statusText`.
3. `AppModel.init`: um único `Task` consome `jobs.changes` e faz `live(id).jobs = list.filter(\.isActive)`. Ele também
   compara com a lista anterior: um job que saiu **sozinho** (`.exited`/`.signaled`, não `.stopped`) vira
   `append(.notice("Processo 3 terminou (código 0): npm run build"), to: botID)`.
4. `NoticeAction.actions(for:)`: o prefixo "Processo " recebe `[.continueTurn]`, então o aviso já ganha o botão
   **Continuar**, que existe hoje. Se o Orb estiver no meio de um turno, em vez do aviso:
   `queueMessage(…, delivery: .steer)`, e o modelo vê no próximo passo.
5. Uma faixa `JobsStrip` no `card` do composer ([ComposerView.swift:129](../Sources/Orb/Views/ComposerView.swift:129)),
   ao lado do `attachmentStrip`: ícone de terminal, comando truncado, tempo com `TimelineView(.periodic(1))` e botão
   ⏹ que chama `jobs.stop`. Com mais de um job, mostra "3 comandos rodando" e abre um popover.

**O que você vê:** enquanto houver servidor ou script rodando, uma faixa viva acima da caixa de mensagem. Quando
terminar, uma linha no chat com o botão Continuar.

*Fase 2 (opcional):* acordar o Orb sozinho quando um job termina, como o Claude Code faz. Para isso falta um
`SendOrigin.system`; deixei de fora da proposta mínima por causa do risco de laço (servidor que reinicia) e do custo.

---

## P0 — "Diz que vai fazer e para"

**O que detectei**
- O turno termina sempre que a resposta não tem chamada de ferramenta
  ([AgentEngine.swift:332](../Sources/Orb/Engine/AgentEngine.swift:332)). O corte por `max_tokens` **já** continua sozinho
  uma vez (:292), então isso não é bug do motor.
- O prompt cria o problema. Ele manda *"Before a tool that changes something, say … what you are about to do"*
  ([SystemPrompt.swift:18](../Sources/Orb/Engine/SystemPrompt.swift:18)), mas nunca diz "e chame a ferramenta na mesma
  resposta". O `workHabits` ainda pede *"finish with … what is left"* (:127), o que convida a fechar o turno com uma
  lista de pendências. Modelos pequenos (Haiku, DeepSeek Flash e Luna fazem a maior parte das suas chamadas)
  obedecem ao pé da letra: anunciam e encerram.
- Medi nos seus dados: em **80 finais de turno**, **3 são promessas reais sem ação**. Exemplos:
  "Vou adaptar a captura do token…", "Vou precisar diagnosticar como o site inicializa o reCAPTCHA",
  "Vou com calma: separar o comprovado…". O problema é real, só é menos frequente do que parece.

**Proposta**
1. **Prompt (0 linhas de lógica, 3 frases).** É o conserto principal:
   - `announce`: acrescentar *"…and make that call in the same reply."*
   - nova frase em `behaviour`: *"Keep working until the task is done or you need the user's answer. Never end your
     turn on a promise (\"vou fazer X\"): do X now. If something blocks you, say what and ask."*
   - `workHabits`: trocar *"finish with what changed and what is left"* por *"finish with what changed; mention what is
     left only if you could not do it, and why."*
2. **Trava no motor (~10 linhas, reforço).** Antes do `return` de [AgentEngine.swift:338](../Sources/Orb/Engine/AgentEngine.swift:338):
   se o turno **já usou ferramentas** e o último parágrafo casa
   `\b(vou|irei|vamos|em seguida|a seguir|I'll|let me)\b` **sem** `não vou` e sem terminar em `?`, reaproveitar o
   mecanismo de `nudge` que já existe (como o `continueNudge`) uma única vez por turno.
   Testei a regex nos 80 finais reais: sem o filtro de negação, ela dispara 5 vezes (2 acertos e 3 falsos positivos);
   com o filtro, dispara 3 vezes (2 acertos e 1 falso). **Recomendo aplicar o item 1, medir uma semana e só então
   decidir o item 2.**

**Rejeitado:** o Codex Sol sugeriu exigir um marcador `[[ORB_DONE]]` no fim de toda resposta. Recusei. Isso suja o
texto, modelos pequenos esquecem o marcador e cada esquecimento custaria uma chamada extra **em todo turno**.

---

## P1 — A pasta do Orb não funciona como workspace

**O que detectei**
- `~/Orbs/*` está quase toda vazia: 6 de 9 pastas não têm nada, e nenhuma tem `ORB.md`.
- **79 de 293 comandos (27%) usam `/tmp`**, e há **42 scripts escritos via heredoc** (`cat > /tmp/scan_free.py <<PY`).
  Eles somem e não aparecem no snapshot da pasta. Você mesmo precisou perguntar ao Atendente: *"O script que fazia
  essa coleta… vc sabe onde estão?"*
- **129 de 293 comandos (44%) começam com `cd`**. O Atendente trabalha em `~/Documents/Projetos/AcessosFit-Brain`,
  mas a pasta dele é `~/Orbs/Atendente AcessosFit 2`, então o snapshot que vai em toda conversa nova descreve uma
  pasta irrelevante.

**Proposta**
1. **Uma frase no `roaming`** ([SystemPrompt.swift:21](../Sources/Orb/Engine/SystemPrompt.swift:21)): *"Save scripts and
   files you make for the work in your folder (scripts/ for code you may run again), never in /tmp: they must last and
   be found again."* O ganho vem de graça: o `WorkspaceSnapshot` já lista os arquivos recentes, então na próxima
   conversa o Orb **vê** o próprio kit de scripts.
2. **Zero código:** apontar a pasta do Atendente e a do Gestor LP para os projetos reais, em Geral → Pasta → escolher
   existente. O snapshot, o `git status` e o `AGENTS.md`/`CLAUDE.md` do projeto passam a chegar sozinhos, e o
   `cd` some.

---

## P1 — Skills quase duplicadas

**O que detectei**
- O Gestor LP tem 4 skills para a mesma tarefa: `/publicar-lp-docker`, `/subir-site-docker-cloudflare`,
  `/subir-site-docker` e `/subir-lp-docker`. No chat apareceram 4 avisos de "Skill proposta: /subir-lp-docker".
  Cada uma entra no prompt e compete na escolha do modelo.
- A trava contra duplicata (`repeats`) é boa, mas compara **só com as skills já salvas**
  ([MemoryBank+Skills.swift:18](../Sources/Orb/Memory/MemoryBank+Skills.swift:18)). Enquanto uma proposta espera sua
  decisão, outra parecida passa, e você acaba aprovando as duas.

**Proposta (3 linhas):** em `proposeSkill`, validar contra
`skills + proposals().filter { $0.slug != slug }.map { SkillDigest(slug:…, improvable: true) }`. A mensagem que já
existe ("/x already covers this. Improve it…") passa a mandar o Orb melhorar a proposta pendente em vez de criar outra.
Depois, juntar as 4 skills de Docker em uma só (eu faço isso se você quiser).

---

## P2 — Excesso de ferramentas e passos

**O que detectei**
- Medição real: **48 ferramentas, 26,8 mil caracteres (~7,4 mil tokens)**, contra 8,8 mil do prompt. Os 14 mil
  tokens da primeira chamada de uma conversa vêm principalmente daí.
- Nunca usadas nas suas 3 conversas: `processes`, `app_quit`, `notify`, `search_files`, `job_list`,
  `shortcuts_*`, `browse_back/scroll/select/close`, `connector_*` e `web_search`. Por outro lado, os seus Orbs **usam**
  `applescript` e `ui_act`, então cortar a capacidade inteira não vale.
- Duas ferramentas são redundantes de fato: `processes`, porque `ps` já roda sem pedir permissão
  ([ReadOnlyCommand.swift:36](../Sources/Orb/Engine/ReadOnlyCommand.swift:36)), e `job_list`, que pode ser `job_output`
  sem `id`.
- O limite de 30 passos parou o Atendente 2 vezes ("Pausei depois de 30 passos").

**Proposta**
1. Remover `ProcessesTool` e `JobListTool`, com `job_output` listando tudo quando não recebe `id`. É código **a
   menos**.
2. `WizardPrompt`: uma frase pedindo para ligar só as capacidades que o papel exige ("each one adds tools the model
   must read"). Isso vale para os Orbs que ainda vão ser criados.
3. Cortar repetição entre prompt e ferramentas: a linha "Work in this order: browse_open, browse_snapshot…" de
   `BrowserPrompt` ([SystemPrompt.swift:209](../Sources/Orb/Engine/SystemPrompt.swift:209)) repete o que as descrições
   `browse_*` já dizem. Isso é texto a menos. O Codex Luna confirmou a medição de forma independente: ~7,1 mil tokens
   em ferramentas.
4. `defaultMaxSteps` de 30 para 50 (1 linha). O aviso de "restam 3 chamadas" e o botão Continuar continuam valendo.

---

## P3 — Para depois (baixo impacto medido)

- **Timeout que vira job em vez de matar o comando.** A ideia é boa (é o modelo do "unified exec" do Codex:
  `jobs.start(wait:)` resolve com cerca de 20 linhas), mas houve só **2 timeouts em 293 comandos**.
- **Endurecer o fim do stream.** O Sol notou que `Reply.stop` começa como `.done`
  ([AgentEngine.swift:386](../Sources/Orb/Engine/AgentEngine.swift:386)), então um stream que fecha sem o evento final
  parece uma resposta completa. Antes de trocar para `.incomplete`, é preciso confirmar que todo provedor
  compatível com OpenAI manda `finish_reason`. Do contrário, o app passaria a mostrar falha em resposta boa.
- **Detalhe do prompt:** quando o papel termina em ponto, a identidade sai com ponto duplo ("…segunda instância..").

## O que não cobri

A qualidade da compactação em conversas longas (o Atendente está com 791 mensagens e ~100 mil tokens por chamada no
Sonnet) e a orquestração entre Orbs nos grupos. Os dois merecem uma rodada própria.

## Ordem sugerida

| # | Item | Código | Você vê |
|---|------|--------|---------|
| 1 | Prompt: executar na mesma resposta + não encerrar em promessa + scripts na pasta | 4 frases | Orb que termina o que começa e guarda os scripts |
| 2 | Faixa de jobs + aviso de término | ~45 linhas | Comandos vivos na tela, aviso com Continuar |
| 3 | Deduplicação contra propostas pendentes | 3 linhas | Fim das skills repetidas |
| 4 | Pastas do Atendente e do Gestor nos projetos reais | 0 (ajuste) | Contexto certo desde a 1ª mensagem |
| 5 | Remover `processes`/`job_list`, passos 30→50, frase no wizard | código a menos | Menos ferramentas, menos pausas |
| 6 | Trava de promessa no motor (após medir o item 1) | ~10 linhas | Reforço |

---

## Status da implementação (mesmo dia)

Implementado tudo menos o P3:

- **Passos por turno:** 30 → **100** (rotinas 60 → 150, para manter a regra de que a rotina tem mais passos que a conversa).
- **Prompt:** executar a ação anunciada na mesma resposta; não encerrar o turno numa promessa; guardar scripts em
  `scripts/` na pasta do Orb, nunca em `/tmp` (só para Orb com pasta própria e terminal); linha redundante do navegador
  cortada. O prompt foi de ~4,6 mil para 5.011 caracteres.
- **Trava de promessa no motor:** um lembrete oculto por turno, só depois de o turno já ter trabalhado. Ignora
  "não vou…" e perguntas.
- **Jobs visíveis:** faixa acima da caixa de mensagem (comando, cronômetro, ⏹). Quando um processo termina sozinho, entra
  no chat o aviso "Processo em segundo plano N terminou…", e o botão **Continuar** passa ao Orb qual processo terminou.
- **Skills:** a deduplicação também compara com as propostas pendentes.
- **Ferramentas:** removidas `processes` e `job_list` (`job_output` sem `id` lista os processos). Wizard e `orb_propose`
  passam a orientar que só se liguem as capacidades necessárias.
- **Item 4 (pastas) revisto e não aplicado.** A skill `/checar-elegibilidade-appai` usa o caminho relativo
  `APPAI/APPAI-LISTA-CORRIGIDA.xlsx`, e o `.venv-pdf` está na pasta atual do Atendente: trocar a pasta quebraria a
  checagem. O Gestor LP já trabalha dentro da própria pasta (`repo/AcessosFit-LP`, `Rotinas/`, `backups/`). Com a regra
  de scripts, a pasta de cada Orb passa a acumular o kit dele.

### Correções após a revisão Opus

- **Trava de promessa:** passou a olhar só a **última frase**.
  - Ignora "Let me know…", narrativas no passado ("e em seguida corrigi") e ofertas condicionais ("Se você aprovar,
    vou publicar."). No modo sem permissão, dispará-la nessas ofertas faria o Orb agir sem o seu sim.
  - Não vale no Wizard nem na revisão de skills.
  - Divide com o "continue" pós-corte uma única cobrança por turno.
- **Aviso de job:** o botão Continuar envia só o número e o status do processo, nunca o texto do comando, que foi escrito
  pelo modelo e poderia carregar uma instrução de página. Durante um turno, o fim de um job só atualiza a faixa. Um job
  parado pelo usuário que deixou filhos rodando não gera mais o falso "terminou".
- **Regra de `scripts/`:** só vale na pasta própria do Orb (`~/Orbs/<Nome>`), nunca numa pasta sua, como um repositório.
- **Acessibilidade:** o botão ⏹ da faixa fica acessível ao VoiceOver.
- **Docs:** README e ARQUITETURA atualizados para 100/150 passos.
- **Suíte completa:** 3.946 testes passando.
