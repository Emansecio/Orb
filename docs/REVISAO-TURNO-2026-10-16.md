# Revisão: o turno e as ferramentas — 16/10/2026 (fase 1, diagnóstico; fase 2, correções)

## Resposta direta

**Nota 3 de 5.** O turno é confiável no que dá errado de forma explícita. Um 5xx ou uma queda antes do texto são tentados de novo. A mensagem de erro vem em português, com "Tentar de novo" e "Outro modelo". O ⌘. é instantâneo e mata o processo filho, e uma chamada sem resultado não quebra o turno seguinte. Ele é **frágil no que dá errado em silêncio, e isso piorou com o "sem limites"**:
- um modelo em laço roda para sempre: a sonda fez 869 chamadas em 15 s, e ninguém vê o custo, que o app calcula e não mostra;
- um provedor que manda só keep-alive prende o turno em "Pensando" sem prazo;
- um 429 sem `Retry-After` derruba uma tarefa longa em 6 s;
- o Enter fica preso no main por até 0,3 s em conversas longas.

Nenhum desses casos pede limite de volta. Pedem **ver** e **avisar**.

## Situação depois da fase 2 (16/10)

Os 16 achados estão implementados, cada um com teste. Nenhum limite voltou: tudo é ver, avisar ou não perder o que já foi feito.

| Achado | O que mudou | Teste |
|---|---|---|
| P0-1 | A linha de trabalho mostra o gasto do turno a partir de 50 mil tokens ("· 180 mil tokens", com "· US$ 3,10" quando o modelo é pago por uso e o preço é conhecido). Na 3ª nota do `LoopWatch` no turno (9 repetições), a conversa recebe um aviso, uma vez. Quem não está olhando aquele Orb recebe também um banner com **Parar**. O turno segue. | `TurnReliabilityTests` (gasto, laço, banner) |
| P1-1 | Uma resposta que só manda keep-alive (comentário SSE ou evento `ping`) por 10 min (`ProviderTransport.contentTimeout`) vira o erro "O provedor parou de responder". Ela é tentada mais uma vez, não três. Resposta lenta, mas viva, nunca é cortada. | servidor `TrickleServer` |
| P1-2 | Limite de uso (429, 529, `overloaded_error`) recebe 5 tentativas, com esperas de 5, 15, 30 e 60 s. O `Retry-After` do provedor continua valendo, e 429 de saldo não espera. | `withRetries` e motor com 429 no meio |
| P1-3 | O `prepareHistory` roda numa cópia, fora do main. O resultado só é aplicado se a conversa não mudou nesse meio-tempo (`HistoryShape`); se mudou, é refeito no main. O resumo da compactação no envio grava a memória dentro do turno (`pendingStretch` com fim fixo). | 640 mensagens: o `send` fica abaixo de 1/3 do tempo da dobra, e o histórico enviado é igual |
| P1-4 | Um pedido em andamento há mais de 3 h (`workTimeout`) gera um banner com **Parar**, uma vez. O pedido não é encerrado. | `DelegationHubTests` |
| P2-1 | O ⌘. no meio do texto guarda o que a pessoa leu como mensagem do assistente com "[resposta interrompida]". O próximo turno a recebe. | `TurnReliabilityTests` |
| P2-2, P3-6 | Uma queda depois do texto grava o parcial e segue **uma vez** com o "continue". Na segunda queda, o turno falha com "O provedor cortou a resposta no meio (…)", sem "Sem conexão". | idem; dois testes antigos do `AgentEngineTests` passaram a esperar o comportamento novo |
| P2-3 | A nota de passos postos de lado ganha uma linha fixa, "Arquivos alterados nestes passos:", fora das 24 linhas. Ela traz até 40 arquivos (2 por linha em janelas pequenas), só de escritas que deram certo. Ao juntar notas, os arquivos viram uma linha só. | 200 passos de `write_file` |
| P2-4 | Rotina que falha manda um banner com o motivo; se você a parou, não manda. Um `tell` que falha põe no chat de quem mandou a linha "X não conseguiu fazer o que você pediu: motivo" (`OrbEvent.tellFailed`). | rotina com erro 400; `tell` que estoura o prazo |
| P2-5 | Novo `withDeadline` e `cancellably` (`Engine/Deadline.swift`), que não esperam a operação travada terminar. ScreenCaptureKit tem 10 s e depois cai no `screencapture`. O OCR tem 20 s; sem ele, a imagem volta sem texto. A espera do início de um conector MCP para no ⌘., e o início segue para quem mais espera. PDF e Office checam o cancelamento por página, aba e slide, e o `read_file` de documento para de esperar no ⌘. O `save_to` tem 10 min no total e não deixa arquivo pela metade. O `search_files` avisa quando o `mdfind` estoura os 30 s. O `connector_call` com `arguments` que não é objeto JSON dá erro explícito. | um teste por item, menos o OCR, coberto pelo teste do `withDeadline` |
| P3-1 | A mensagem que abre o turno é gravada na hora. A conversa ganha a marca `turnOpen`, que faz o aviso de "O app foi fechado no meio desta tarefa" aparecer mesmo quando o disco pegou um momento quieto. | leitura do disco logo após o `send` |
| P3-2 | A desistência de 24 h passa o motivo `.gaveUp` à cadeia: quem pediu não lê "Você parou a conversa entre Orbs". | `DelegationHubTests` |
| P3-3 | Saídas longas passam pelo `ToolOutputCap`, que grava arquivo, fora do ator do motor. O motor por Orb não foi feito. | regressão do motor |
| P3-4 | Os anexos são lidos em paralelo com o `brief`. O `gather` depende do `brief`, então segue em série. O ganho não foi medido. | regressão |
| P3-5 | Um pedido de outro Orb fora de grupo diz ao modelo que ninguém acompanha a execução e que ele não deve esperar confirmação. | `OrbEnvelopeTextTests` |

**Diferenças em relação ao proposto:**
- Os banners novos usam o interruptor que já existe, **Me avisar quando um Orb terminar ou precisar de mim**, e não um controle novo em Ajustes.
- O banner de laço vale para qualquer turno cujo Orb você não está olhando, não só para rotina ou pedido.
- O vigia do provedor desiste aos 10 min, sem o status intermediário dos 60 s.

**Regressão.** Só suítes filtradas, sem a suíte inteira e sem `--snapshot`:
- 3.220 testes em três partes, todos verdes;
- `TurnReliabilityTests` tem 30 testes.

Numa rodada única com tudo em paralelo, algumas suítes com prazo de relógio falharam (`BrowserCleanupTests`, `WebToolTests`, `SteeringTests` e outras). Todas passam sozinhas e nas três partes.

Testes antigos ajustados:
- `NoStepLimitTests` e `SkillFlowTests` usam consultas distintas, para que um turno longo não pareça um laço;
- dois testes do `AgentEngineTests` agora esperam que o turno siga depois de um corte no meio do texto.

## Como foi feita

- **Versão:** `c844567` (HEAD da main, árvore limpa). Copiei com `git archive` para o scratchpad e todas as sondas rodaram nessa cópia. Nada do repositório foi alterado além deste arquivo. Os dados reais não foram tocados e o app não foi aberto.
- **Leitura:** três agentes de leitura (Sonnet) fizeram a varredura das ferramentas, da gravação em disco e dos cartões, rotinas e ⌘.. Eu li o núcleo (`AgentEngine`, `Retry`, `LoopWatch`, `ProviderTransport`, `BotSession+Turn`, `AppModel.send`) e conferi nas linhas as afirmações que entram nos achados.
- **Servidor falso:** escrevi um `fault-llm.py` (temporário, compatível com OpenAI) com estes modos:
  - `429`, `429` com `Retry-After: 2` e com `Retry-After: 600`;
  - `500` sempre, e `500` só na 1ª vez;
  - 200 que fecha sem eventos, e 200 que fecha no meio de um evento depois de texto;
  - argumentos de ferramenta com JSON quebrado;
  - keep-alive `: keep-alive` a cada 1 s sem conteúdo;
  - laço (a mesma chamada sempre), alternância A/B, `run_command` com `sleep 30`;
  - texto com tempo por token.
- **Sonda (`TurnProbeTests`, temporária):** usa o `AppModel` real, com `Store` numa pasta temporária, e o `OpenAIClient` real apontado para o servidor. O único desvio é o `clientOverride`, que embrulha o cliente para anotar quando cada pedido sai e quando o stream termina. A sonda mede:
  - o status ao vivo (amostrado a cada 2 ms), os avisos da conversa e os pedidos recebidos pelo servidor;
  - o maior intervalo do main thread;
  - o custo do `Store.save` e do `prepareHistory`.
- **Execução:** só testes filtrados (`swift test --skip-build --filter TurnProbeTests/…`), com `nice`. Nada de suíte inteira nem `--snapshot`. A máquina estava com carga entre 4 e 6 durante as medições, então os tempos são ordem de grandeza, não benchmark.
- **Limpeza:** cópia, servidor e sonda foram apagados no fim.

## Respostas

### A. Falhas

**A1. O que o turno faz em cada caso.** Tudo passa por `respond` (`Engine/AgentEngine.swift:478-527`), que roda `withRetries` com 4 tentativas no total (`Engine/Retry.swift:58-80`). A espera é de 1, 2 e 4 s com jitter de 50 a 100% e teto de 30 s (`Retry.swift:7-9, 43-50`). Um `Retry-After` do provedor é respeitado até 120 s; acima disso, falha na hora (`Retry.swift:11, 44-45`). O que é transitório está em `Engine/EngineTypes.swift:459-480`.

Medido com o servidor falso:

| Caso | Pedidos | Tempo até desistir | Status mostrado | Aviso final |
|---|---|---|---|---|
| 429 sem `Retry-After` | 4 (intervalos 0,7 / 1,7 / 3,4 s) | 5,9 s | "Limite do provedor, tentando de novo em 1 s / 2 s / 4 s" | "Não deu certo: Você atingiu o limite de uso do provedor (429); espere um pouco ou confira seu plano." |
| 429 com `Retry-After: 2` | 4 (2,0 / 2,0 / 2,0 s) | 6,0 s | idem, "em 2 s" | idem + "O provedor pediu para aguardar 2 s." |
| 429 com `Retry-After: 600` | 1 | 0,02 s | — | idem + "aguardar 10 min." |
| 500 sempre | 4 | 5,7 s | "Provedor ocupado, tentando de novo em …" | "O provedor está sobrecarregado ou instável (500); tente de novo em instantes." |
| 500 só na 1ª | 2 | 0,6 s | "Provedor ocupado…", depois "Escrevendo" | nenhum (deu certo) |
| 200 que fecha sem evento | 4 | 5,6 s | "Provedor ocupado, tentando…" | "A resposta foi interrompida: o provedor encerrou antes do fim." |
| Conexão cai **depois** de texto | 1 | 0,01 s | — | "Não deu certo: Sem conexão com o provedor: a conexão terminou no meio de uma resposta" |
| JSON de ferramenta quebrado | 2 | — | normal | nenhum; o modelo recebe a correção e segue |
| Só keep-alive, sem conteúdo | 1 | **nunca** (20 s observados, ainda "Pensando") | "Pensando" | — |
| Silêncio total | — | por código, 300 s × 4 tentativas ≈ **20 min** | "Pensando" | "Sem conexão com o provedor: …" |

Detalhes:
- **Falha depois de texto.** Não é tentada de novo, para não repetir o que já foi mostrado (`AgentEngine.swift:471-475, 512-513`). O texto parcial entra no histórico com `[resposta interrompida]` (`:284-290`).
- **Fim cortado antes do texto.** Desde a B2 da REVISAO-CODIGO, conta como transitório (`:510-511`).
- **JSON quebrado.** O motor devolve `Error: the arguments are not valid JSON. Send one JSON object with: path (string, required), … and call read_file again.` (`AgentEngine.swift:915-918`). O 2º pedido da sonda chegou com exatamente esse texto.
- **Keep-alive sem conteúdo.** O único prazo é o `idleTimeout` de 300 s do `URLRequest` (`Engine/ProviderTransport.swift:47-49, 65`). O `URLSession` o conta entre bytes, então um comentário SSE ou um evento `ping` zera o relógio. Não existe vigia de "nenhum conteúdo há N s".
- **Silêncio total.** `timedOut` está entre os erros transitórios (`EngineTypes.swift:479`), então o silêncio de 300 s é repetido até 4 vezes.

**A2. O que a pessoa vê.** Durante as tentativas, a linha de trabalho diz a causa certa ("Conexão caiu", "Limite do provedor", "Provedor ocupado") com contagem regressiva (`Retry.swift:22-29`). No fim, `BotSession+Turn.swift:248-250` mostra "Não deu certo: …" com a frase do app e o "Detalhe do provedor" dobrado à parte (`AppModel+Transcript.swift:156-161`). Os botões são:
- "Tentar de novo" e "Outro modelo" (`AppModel+Transcript.swift:118-133`);
- "Ajustes" quando é chave ou login;
- "Compactar" quando a conversa ficou grande.

O "Tentar de novo" reenvia se nada aconteceu e manda "continua" se já houve passo (`RetryPlan`, `:165-185`). Ou seja, a mensagem é clara e diz o que fazer, com três exceções:
- (a) a conexão que cai depois do texto diz "**Sem conexão** com o provedor", e a conexão estava boa: foi o provedor que cortou;
- (b) o keep-alive infinito não mostra nada além de "Pensando";
- (c) o 429 diz "espere um pouco" depois de o app ter esperado só 6 s.

**A3. Erro sem ninguém olhando.**
- **Rotina.**
  - `finishRoutineRun` grava "Não terminou: veja a conversa.", com o último aviso como resumo (`AppModel.swift:1959-2004`).
  - Na lista aparecem o ícone vermelho e "Não deu certo" (`Views/RoutinesView.swift:450-451, 538, 562-563`), e o chat do Orb ganha uma linha de evento vermelha (`AppModel.swift:2000-2003`).
  - Soma 1 no contador de não lidas (`BotSession+Turn.swift:393-395`).
  - **Não há notificação do macOS para falha**: `notify` só é chamado em `else if succeeded` (`BotSession+Turn.swift:388`).
  - Não há nova tentativa: a rotina só roda no próximo horário.
- **Pedido de outro Orb.**
  - `ask`: quem pediu recebe `<orb_reply status="failed">` com "Não consegui: <motivo>" (`MultiOrb/DelegationHub.swift:260-262, 308-333`).
  - `tell`: ninguém fica sabendo. O erro só fica no `pedido-<id>.json`, visível em "Ver o trabalho".
- **Grupo.** O fio recebe "<Orb> não conseguiu responder: <motivo>" (`Groups/GroupHub.swift:167-171`), sem banner.

### B. Parar e retomar

**B4. ⌘. no meio de cada coisa.** `BotSession.stop` (`BotSession+Turn.swift:118-146`) faz, em ordem:
1. cancela a `Task` do turno, o que termina o `AsyncStream` e, pelo `onTermination`, cancela o motor (`AgentEngine.swift:133-137`);
2. nega os cartões abertos;
3. fecha o streaming;
4. marca as ferramentas em andamento como "Interrompido.";
5. escreve "Você interrompeu esta resposta";
6. fecha o turno.

O ⌘. em si é síncrono e mediu 0,000 s nas duas sondas.

- **No meio do streaming (medido).** O chat fica com o texto parcial (3.343 caracteres, `streaming=false`), mas o histórico do modelo fica só com a mensagem do usuário (`messages = [user]`). O `catch is CancellationError` só retorna (`AgentEngine.swift:425-426`), e os eventos que chegam depois são descartados (`BotSession+Turn.swift:101`). No turno seguinte, o modelo não sabe o que tinha dito. É diferente de uma queda de conexão, que grava o parcial com `[resposta interrompida]`.
- **No meio de um comando (medido com `sleep 30`).** O `ProcessRunner` manda SIGTERM ao grupo e SIGKILL 2 s depois (`Engine/Tools/ProcessRunner.swift:109-114, 157-161`). Antes do Parar havia 1 processo; 2,5 s depois, 0. A linha fica "failed Interrompido.", e o histórico fica com o `assistant` com 1 `tool_call` sem resultado. O turno seguinte saiu com 1 pedido e sem erro: `answeringDanglingToolCalls` responde "Not run: the turn was interrupted." na cópia enviada (`Engine/EngineTypes.swift:113, 220-241`, chamado em `ContextWindow.swift:343`).
- **No navegador.** O `agent-browser` em curso é morto pelo mesmo `ProcessRunner`. O navegador e a página continuam abertos, de propósito; só fecham ao apagar o Orb ou sair do app.
- **No uso do computador.** O cancelamento é cooperativo, e a restauração da tela (app da frente, cursor) roda num `Task.detached` aguardado (`Engine/Tools/ScreenTakeover.swift:326, 350-361`). A tela não fica tomada.
- **Na compactação.** A do turno é parte da `Task` e para junto. O `/compactar` manual é síncrono no main (`AppModel.swift:1321`); não há o que cancelar, e ele é rápido.
- **O que continua rodando por baixo depois do Parar:**
  - jobs em segundo plano e comandos mandados para o fundo (de propósito);
  - o navegador do Orb;
  - leitura de PDF, Office ou imagem já começada: `runDetached` repassa o cancelamento, mas os leitores não o checam (`Engine/Tools/ToolBox.swift:117-120`);
  - a partida de um conector MCP: `ensureStarted` aguarda uma `Task` não estruturada (`Engine/MCPTool.swift:262, 275-280`), até cerca de 90 s;
  - as tarefas do fim do turno (`bank.sweep`, `collectSkillProposals`, `BotSession+Turn.swift:354-357, 402`).

  A interface fica livre na hora; esse trabalho termina sozinho e o resultado é jogado fora.

**B5. Fechar o app ou ele cair.**
- **⌘Q.** Não há `applicationShouldTerminate`. O observador de `willTerminate` (`AppModel.swift:457-467`):
  - para cada turno com "O app foi fechado no meio desta tarefa." (`stopTurnsForQuit`, `:1697-1702`);
  - grava tudo de forma síncrona (`saveNow`, com `store.flush` = `queue.sync`);
  - mata processos, jobs e navegadores.

  Nada se perde.
- **Queda.** O disco tem o último instantâneo. A gravação é por limitação de ritmo, não debounce: 5 s depois da primeira mudança, até 10 s em conversas grandes (`BotSession+Conversation.swift:120-134`). Perde-se **até 5 a 10 s**, inclusive a própria mensagem que a pessoa acabou de mandar, se a queda vier antes da primeira gravação: ela entra por `mutateItems` com o mesmo atraso.
- **Ao reabrir.** `closingInterruptedTurn` (`Models.swift:241-270`):
  - fecha o streaming;
  - marca as ferramentas `.running` como "Interrompido.";
  - nega os cartões pendentes;
  - escreve o aviso com "Continuar", que manda "continua… a última ação pode ter sido feita… Confira antes de repetir." (`AppModel+Transcript.swift:79-84`).

  Nada retoma sozinho, de propósito. Uma chamada sem resultado **não quebra** o turno seguinte: a cópia enviada sempre passa por `answeringDanglingToolCalls`, como comprovado acima. Lacuna: se a queda pegar o disco num momento "limpo" (último item já fechado), não aparece aviso nenhum, e o chat parece parado sem explicação (`Models.swift:243, 266`).

**B6. Mensagem nova durante o turno.** A mensagem fica na `SteeringQueue`, só em memória (`Engine/Steering.swift:59`). Ela é entregue **no início de cada passo** (`AgentEngine.swift:218, 437-450`), com o quadro "Sent while you were working…" (`:871-872`). Se o modelo acabar de escrever enquanto há mensagem na fila, o turno dá mais um passo em vez de terminar (`:388-393`). Ela pode se perder:
- **queda:** perde-se. A fila não vai para o disco, e os rascunhos são gravados a cada 30 s;
- **⌘Q, ⌘. ou erro:** não se perde. `settleSteering(succeeded: false)` a devolve ao compositor (`AppModel+Steering.swift:384-407`), e as já entregues sem resposta saem do chat e voltam ao rascunho (`BotSession+Turn.swift:168-175`).

Numa rotina não há direcionamento (`AppModel+Steering.swift:201-204`).

### C. Ferramentas

**C7. Tempo limite, corte e erro.**
- **Corte central.** Vale para todo resultado: `ToolOutputCap.apply` (`Engine/ContextWindow.swift:642-684`, chamado em `AgentEngine.swift:699`). Acima de 30.000 caracteres ficam os primeiros 10.000 e os últimos 5.000, e o texto inteiro vai para um arquivo com uma nota do caminho e de como reler. Sem ferramenta de leitura, o limite é 40.000 e só as pontas ficam.
- **Erro.** Qualquer exceção vira `Error: <mensagem>` com `isError: true` (`AgentEngine.swift:1004-1007`). Um código de saída diferente de 0 vira `failed` com o texto em prosa. Ferramenta desconhecida, JSON inválido e recusa também voltam como `isError` com instrução de como corrigir.
- **Não existe prazo global por chamada** no motor. Cada ferramenta tem o seu:

| Ferramenta | Tempo limite | Corte próprio | Observação |
|---|---|---|---|
| `run_command` | 120 s (até 600) (`Tools/ShellTool.swift:4-5`) | 20.000 + arquivo completo | grupo inteiro morto no tempo e no Parar |
| `read_file` | nenhum | página de 24.000, linhas de 2.000 | PDF/Office: Parar não interrompe |
| `write_file` / `edit_file` / `trash` | nenhum | — | E/S síncrona; volume de rede morto trava |
| `grep` / `glob` / `list_directory` | 20 s / 20 s / — | 24.000 | cancelam de verdade |
| `search_files` (mdfind) | 30 s | 500 itens | no estouro devolve resultado parcial sem avisar |
| `web_fetch` | 20 s de silêncio; 30 ou 180 s de leitura | 24.000 por página | `save_to`: **sem prazo total** |
| `web_search` | 20 s (HTTP), 45/75 s (navegador) | 15 resultados | — |
| `browse_*` | 75 s (abrir), 45 s (resto) | 24.000 | a fila do mutex não cancela a espera |
| `applescript` / `browser_tab` | 60 s (até 300) + até 120 s por app de diálogo de permissão | 20.000 | — |
| `shortcuts_run` | 60 s (até 300) | 20.000 | — |
| `ui_read` / `ui_act` | 4 a 8 s / 2 s por ação (`AccessibilitySession.swift:14-18`) | 14.000 | app AX travado não prende o turno |
| `screenshot` | 20 s (tela inteira) | OCR 1.500/8.000 | janela por ScreenCaptureKit e OCR: **sem prazo** |
| conectores MCP | 60 s por chamada (Mail 200 s); reinicia depois de 2 silêncios | só o corte central | partida não cancela; JSON inválido em `connector_call` vira `{}` em silêncio |
| `ask_user`, `browse_show`, `orb_propose`, cartões | sem prazo (humano) | — | ver C9 |

**C8. Ferramenta que trava.** O turno só fica preso **sem limite** quando espera uma pessoa. No resto há prazo, e o pior caso normal é um `run_command` de 600 s ou um `applescript` de 300 s com espera de permissão. As lacunas reais, onde nem o prazo nem o Parar resolvem logo, são:
- captura de janela por ScreenCaptureKit (`Tools/WindowCapture.swift:335`);
- OCR (`ScreenshotTool.swift:450-453`, `BrowseTools.swift:280`);
- leitura de PDF/Office grande;
- `web_fetch save_to`;
- E/S de arquivo em volume de rede;
- a partida de um MCP.

Em todos, o Parar libera a interface na hora; a `Task` do motor só termina quando a ferramenta voltar.

**C9. Cartão de aprovação sem ninguém olhando.** O turno espera (`ApprovalGate.swift:120-135`, `AgentEngine.swift:943-946`). O app lembra com um banner depois de 1 h e desiste depois de 24 h, como se fosse o Parar, com "Ninguém respondeu em 24 horas: o Orb parou de esperar" (`AppModel+Approvals.swift:115-132, 203-206`). O relógio continua correndo com o Mac dormindo.
- **Rotina.** É `unattended` (`AppModel.swift:1619`), mas isso só muda o texto para o modelo. No modo "Perguntar antes", o cartão abre e prende o Orb e as rotinas da fila atrás dele por até 24 h.
- **Pedido de outro Orb.** O banner abre "Ver o trabalho". A desistência de 24 h aparece para quem pediu como "Você parou a conversa", sem a pessoa ter parado.

### D. Laços e custo, agora sem teto

**D10. Repetição.** O `LoopWatch` (`Engine/LoopWatch.swift`) faz duas contagens:
- a mesma chamada com o mesmo resultado, por hash de nome, argumentos e resultado sem horários e IDs (`:20-35, 46-64`);
- falhas seguidas (`:21-25`).

A cada 3 vezes, acrescenta uma nota ao último resultado ("você fez esta mesma chamada 3 vezes…") e a linha de trabalho mostra "Mudando de abordagem" (`AgentEngine.swift:224, 707-711`). A alternância A, B, A, B é pega porque cada par chamada/resultado é contado à parte. Ferramentas "vivas" (`browse_*`, uso do computador, `job_output`) só contam falhas (`:40-42`).

**Mas a nota é só para o modelo.** Medido com um modelo que ignora a nota: **869 chamadas em 15 s**, 482 delas com a nota no resultado e nenhuma mudança. O turno não terminou, e a compactação entrou duas vezes ("resumi os 350 primeiros passos…"). A pessoa vê só a linha alternando entre "Lendo arquivo" e "Mudando de abordagem". Não há aviso na conversa, nem banner, nem nada que escale. Antes do `c3d8029`, o limite de passos fazia esse papel por acidente.

**D11. Quanto já gastou.**
- O motor soma o uso a cada chamada e emite `.usage(total)` (`AgentEngine.swift:293-300`).
- O `BotSession` guarda esse total (`BotSession.swift:212, 219`), mas **nenhuma tela o lê**. A única leitura viva é `lastUsage`, o tamanho do **último** pedido, que alimenta o medidor de contexto (`AppModel+ContextUI.swift:20`, `Views/ContextMeterViews.swift:42`).
- Na sonda do laço, depois de 15 s, `session.usage` marcava 869 mil tokens de entrada; `lastUsage` dizia 1.000.
- O custo por pedido vai para Ajustes → Uso (`recordUsage`, `BotSession+Turn.swift:260-263`), longe do chat.

Então: o total só aparece em Ajustes, e **não dá para notar um turno descontrolado pelo chat**. Numa rotina ou num pedido, nem pela linha de trabalho, porque ninguém está olhando.

**D12. A compactação num turno longo.** O `ContextWindow.fit` (`ContextWindow.swift:106-347`) faz quatro coisas:
- sempre mantém a mensagem que abriu o turno, ou seja, o objetivo, e o passo mais novo (`:111-113`);
- primeiro encurta as saídas antigas da tarefa e só depois põe de lado os passos mais velhos, deixando uma linha de resumo por passo (`:275-307`);
- reapresenta o plano (`task_plan`) a cada 8 passos, anexado ao último resultado (`AgentEngine.swift:660-674`), e por isso o plano sobrevive;
- responde as chamadas sem resultado.

O que **não** sobrevive bem: o resumo dos passos postos de lado guarda no máximo **24 linhas, as mais novas**, e as demais viram "(+N linhas anteriores)" (`Engine/ToolDigest.swift:8, 41-46`). A lista de "arquivos alterados" do ledger (`ConversationLedger.swift:57-60`) só recebe **turnos anteriores** dobrados, não passos do turno em andamento. Num turno de centenas de passos, que agora é possível, os arquivos tocados no começo saem da vista do modelo.

### E. Latência

**E13. Onde o turno espera sem precisar.**
- **No Enter (main, síncrono).** `send` roda `prepareHistory` no main antes de criar a `Task` (`AppModel.swift:1528`). É o único trabalho que cresce com a conversa, e domina o tempo até o pedido sair (ver E14).
- **Na `Task` do turno.** Ela herda o `MainActor` e faz em série: `bank.brief` → `TurnPromptInputs.gather` (este já paraleliza a pasta e as instruções) → os anexos → o cliente → `browserHub.status` → `connectorSync` (`AppModel.swift:1564-1606`). `brief`, `gather` e anexos não dependem um do outro e poderiam ser `async let`. Numa conversa nova e com memória vazia, tudo isso somou ~7 ms. Com um banco de memória real não medi, porque os dados reais ficam de fora.
- **Entre passos.** Fora do main, ~6 ms (ver E14). O motor é **um único ator para todos os Orbs** (`AppModel.swift:225`), então o trabalho síncrono dele passa por ele em fila:
  - montar a janela;
  - o `ToolOutputCap`, que grava arquivo dentro do ator;
  - os hashes do `LoopWatch`, com regex sobre até 100 mil caracteres.

  Com vários Orbs em paralelo num grupo, isso é fila; hoje é pouco, mas cresce com a conversa.
- **Gravação.** Não é a cada token. É no máximo a cada 5 a 10 s, com a codificação na fila do `Store` (`Store.swift:270-277, 612-628`) e só os itens que mudaram. O texto que chega em streaming é publicado a cada 33 ms (`BotSession+Turn.swift:13`).
- **Montagem do prompt.** É feita uma vez por turno; por passo só se recalcula a janela.

**E14. Números (medidos na cópia, servidor local sem latência de rede).**

| Medida | Valor |
|---|---|
| Enter → pedido sair, conversa nova (10×) | mediana **7,4 ms** (7,2–47 ms) |
| Fim do stream → próximo pedido (passo com `read_file`), turnos 1 a 40 | **5,6–6,4 ms**, estável |
| `prepareHistory` no main, por tamanho da conversa | 4 msgs: 1,8 ms · 160 msgs/1,2 MB: **81 ms** · 320/2,4 MB: **143 ms** · 480/3,7 MB: **230 ms** · 640/4,9 MB: **293 ms** |
| Enter → pedido sair, mesma série | 60 · 80 · 307 · 233 · 297 ms (≈ o `prepareHistory`) |
| `Store.save` incremental (fila, fora do main), 1,2 MB | mediana **1,4 ms** |
| `JSONEncoder` da conversa inteira (1,2 MB) | 5,3 ms |
| Cópia `withLiveText` no main | < 0,001 ms |
| Maior intervalo do main durante 2.000 tokens em 6,3 s | **19 ms** |
| Maior intervalo do main em turnos curtos | mediana 2,1 ms, máx. 17,5 ms |

Uma ressalva: a medida "Enter → texto na tela" falhou na sonda, porque procurei o texto no lugar errado. Pelo código, ela é o primeiro token mais até 33 ms do `textFlushInterval`. O tamanho das conversas da sonda vem de saídas inteiras de 20 KB. No disco, as saídas antigas são gravadas encurtadas (`pruningOldToolOutputs`), então uma conversa recarregada do disco é menor que a mesma conversa ainda na memória.

## Tabela de falhas

| Situação | O que acontece | O que a pessoa vê | Deveria |
|---|---|---|---|
| 429 sem `Retry-After` | 4 tentativas em ~6 s e o turno acaba | "Limite do provedor, tentando em 1/2/4 s", depois "Não deu certo… espere um pouco" | esperar o bastante para um limite por minuto (~1–2 min) antes de desistir |
| 429 com `Retry-After` ≤ 120 s | espera o pedido, 4 vezes | contagem regressiva | ok |
| 429 com `Retry-After` > 120 s | falha na hora | "…aguardar 10 min" + Tentar de novo | ok |
| 5xx / 529 | 4 tentativas, ~6 s | "Provedor ocupado…" | ok (talvez um pouco mais longo) |
| Queda antes do texto | tenta de novo | "Provedor ocupado…" | ok |
| Queda depois do texto | turno acaba, parcial gravado | "Sem conexão com o provedor…" | dizer "o provedor cortou a resposta"; seguir uma vez com "continue" |
| Keep-alive sem conteúdo | **preso para sempre** | "Pensando" | vigia de conteúdo: avisar aos 60 s, desistir e tentar de novo aos ~3 min |
| Silêncio total | 300 s × 4 ≈ 20 min | "Pensando" | o mesmo vigia; `timedOut` tentado no máximo 1 vez |
| JSON de ferramenta quebrado | o modelo recebe a correção | nada | ok |
| Argumentos cortados por `max_tokens` | não executa e explica | nada | ok |
| Modelo em laço | **roda para sempre**, nota só para o modelo | "Mudando de abordagem" piscando | aviso na conversa + banner em rotina/pedido + custo visível |
| Turno longo e caro | sem sinal no chat | nada (só Ajustes → Uso) | total do turno na linha de trabalho |
| ⌘. no streaming | para; parcial só no chat | "Você interrompeu esta resposta" | parcial também no histórico do modelo |
| ⌘. num comando | processo morto em ≤ 2 s; chamada sem resultado reparada | "Interrompido." | ok |
| ⌘. num PDF / MCP partindo / captura SCK | interface livre; trabalho segue por baixo | ok | cancelar de verdade |
| ⌘Q no meio | para, grava, mata processos | "O app foi fechado…" + Continuar | ok |
| Queda do app | perde até 5–10 s, às vezes a própria mensagem | aviso só se algo estava aberto | gravar já a mensagem do usuário; aviso sempre que o último turno não fechou |
| Falha em rotina | registro, ícone vermelho, não lida | nada fora do app | notificação de falha (opção) |
| Falha num `tell` | só no pedido | nada | uma linha no chat de quem mandou |
| Cartão numa rotina | espera até 24 h | banner (app inativo), lembrete em 1 h | ok; texto da desistência não dizer "você parou" |
| Turno delegado pendurado (`.running`) | nenhum prazo do hub o pega | nada | ver P1-4 |

## Achados

### P0

#### P0-1. Um turno descontrolado é invisível: o laço não escala e o custo do turno não aparece

- **Evidência:**
  - Sonda do laço: 869 chamadas em 15 s, o turno sem fim, a nota do `LoopWatch` repetida 482 vezes ao modelo e ignorada.
  - A pessoa vê só "Mudando de abordagem" (`AgentEngine.swift:224`), que pisca e some no passo seguinte.
  - `LoopWatch.note()` só alimenta o resultado da ferramenta (`AgentEngine.swift:707-711`).
  - O total do turno é calculado (`AgentEngine.swift:293-300`) e guardado (`BotSession.swift:212, 219`), mas nenhuma view o lê. Só o `lastUsage` chega à tela (`AppModel+ContextUI.swift:20`).
  - Em rotina e pedido não há ninguém olhando (`AppModel.swift:1618-1619`), e o hub não tem prazo para `.running` (`DelegationHub.swift:500-521`).
- **Por que P0:** com `maxSteps: .max` (`AppModel.swift:1618`) é o único caso em que o app gasta sem parar e sem ninguém ver. A decisão de tirar os limites pressupõe que a pessoa consiga notar e parar; hoje ela não consegue.
- **Correção mínima (sem limites):**
  1. **Ver.** Mostrar o total do turno na linha de trabalho, a partir de um piso (≥ 50 mil tokens ou ≥ 20 passos), como "· 12 passos · 180 mil tokens". O dado já existe em `BotSession.usage`; é ligar ao `WorkLine` (`showWork`, `BotSession+Turn.swift:55-63`). Com preço conhecido (`Usage/ModelPricing.swift`), mostrar também em reais ou dólares.
  2. **Avisar.** Quando o `LoopWatch` der a mesma nota pela 3ª vez no turno (9 repetições), emitir um `.notice`: "Parece que estou repetindo a mesma coisa (9 vezes). Pare com ⌘. se não for isso." Em rotina ou pedido, mandar também um banner com "Parar". A nota ao modelo continua como está.
- **Esforço:** P (meio dia). Um evento novo ou um contador no `LoopWatch`, mais a linha de trabalho e o banner.
- **Teste:**
  - `CallScript` com 30 chamadas idênticas: espere exatamente 1 aviso na conversa, o turno ainda rodando e a linha de trabalho com "passos" depois do piso.
  - Uma rotina com o mesmo script: espere 1 banner, contado por `QuietNotifications`.
- **Relação:** a AUTONOMIA (13/10) propôs o `LoopWatch` "medindo progresso"; esta é a parte que faltou, mostrar à pessoa. Também completa o `c3d8029`, que deixou no topo do grupo o gasto do pedido (`GroupLive.usage`, `Views/Groups/GroupChatView.swift:84`); o chat solo não tem o equivalente.

### P1

#### P1-1. Provedor que manda keep-alive e nunca conteúdo prende o turno para sempre; silêncio total leva ~20 min

- **Evidência:**
  - Sonda `ping_stall`: 20 s em "Pensando" com 1 pedido.
  - O único prazo é `idleTimeout = 300` do `URLRequest` (`ProviderTransport.swift:47-49, 65`), zerado por qualquer byte.
  - Os comentários SSE e o `ping` da Anthropic são bytes.
  - `timedOut` é transitório (`EngineTypes.swift:479`), então 4 tentativas × 300 s.
  - O Claude Code pelo cano também só tem prazo no `initialize` (60 s) e na espera de 30 min do resultado (`ClaudePipe/ClaudeCodeClient.swift:71, 364-373`; `ClaudePipeTools.swift:54-55`).
- **Correção mínima:** um vigia de **conteúdo** no `ProviderTransport.stream`, contando o tempo desde o último `LLMEvent` produzido (texto, raciocínio, pedaço de ferramenta), não desde o último byte.
  - Aos 60 s sem conteúdo, mostrar o status "Sem resposta do provedor há 1 min".
  - Aos `contentTimeout` (3 min; 10 min para provedor local/Ollama, que pode demorar no primeiro token), lançar `LLMError.network(.timedOut)`.
  - Em `withRetries`, tentar `timedOut` no máximo 1 vez.
- **Esforço:** P–M. A parte do `ProviderTransport` é pequena. Distinguir o provedor local é uma linha (`account.kind`).
- **Teste:** servidor falso com keep-alive e `contentTimeout` injetado em 2 s. Espere o status "Sem resposta…", 2 pedidos e o aviso "O provedor parou de responder", em menos de 10 s.
- **Relação:** nova. A REVISAO-CODIGO B1 tratou "context deadline" como estouro; não tocou em prazos.

#### P1-2. 429 sem `Retry-After` desiste em 6 s e derruba tarefas longas

- **Evidência:**
  - Sonda: intervalos de 0,7, 1,7 e 3,4 s, falha aos 5,9 s.
  - A espera vem de `Retry.swift:7-9, 47-49` e o número de tentativas de `maxAttempts: 4`.
  - Limites por minuto (TPM/RPM) liberam em até 60 s.
  - Sem limite de passos, uma tarefa de 2 h tem muitas chances de bater num 429. Quando bate, o turno acaba, e numa rotina vira "Não deu certo" até o próximo horário.
- **Correção mínima:** para 429 e `overloaded`/529 sem `Retry-After`, usar uma escala própria: 5, 15, 30 e 60 s, cerca de 2 min no total, com a mesma contagem regressiva. Manter 1/2/4 s para 5xx comum e para rede. Não mexer em 429 de saldo (`isAboutMoney`), que continua falhando na hora.
- **Esforço:** P.
- **Teste:** servidor com 429 nas 3 primeiras respostas e depois `ok`, com o `retrySleep` falso do `AgentEngine`. Espere 4 pedidos, nenhuma falha e a soma das esperas pedidas ≥ 45 s.
- **Relação:** nova.

#### P1-3. `prepareHistory` no main cresce com a conversa (até 0,3 s por Enter)

- **Evidência:**
  - Sonda `scaling`: 1,8 → 81 → 143 → 230 → 293 ms, de 4 a 640 mensagens.
  - Enter → pedido acompanha esses números.
  - A chamada fica em `AppModel.swift:1528` (`session.changeConversation { $0.prepareHistory(…) }`), síncrona antes da `Task`.
  - Durante esse tempo a janela inteira congela: digitar, rolar e animar.
- **Correção mínima:**
  - (a) Calcular a janela numa `Task.detached` a partir de uma cópia da conversa e aplicar o resultado (o novo `ledger` e o `covered`) no main, dentro da `Task` do turno, antes do `brief`. A conversa é um valor, e a cópia já existe hoje em `withLiveText`, por < 0,001 ms.
  - (b) Como passo seguinte, guardar o `ContextCut` entre turnos, para não refazer o `fit` desde o começo.
- **Esforço:** M. É preciso cuidar da ordem: o aviso de compactação e o `itemsBeforeMessage` usam o resultado.
- **Teste:** conversa com 600 mensagens de 8 KB e um relógio em volta de `send(...)`. Espere `send` voltar em < 10 ms e o pedido sair com a mesma janela de hoje, comparando `CallScript.calls[0].messages` antes e depois.
- **Relação:** nova. A REVISAO-CODIGO T4 tratou de regravação de cache, não de tempo no main.

#### P1-4. O hub não tem prazo para um pedido em andamento; turno delegado pendurado só acaba pela pessoa ou em 24 h

- **Evidência:**
  - `sweep` só olha `.queued` e `.awaitingChildren` (`MultiOrb/DelegationHub.swift:500-521`).
  - O comentário do `workTimeout` diz "(a turn that hangs)" (`MultiOrb/DelegationTypes.swift:30-32`), mas nada aplica isso a `.running`.
  - Combinado com P1-1 ou P0-1, um pedido pode ficar rodando indefinidamente.
  - O pai, em `.awaitingChildren`, só cai em 3 h e deixa o filho rodando. A resposta posterior é descartada (`DelegationHub.swift:346-348`).
- **Correção mínima:** **não** cancelar. Em `sweep`, um `.running` além de `workTimeout` gera um banner "<Orb> está há 3 h no pedido de <Orb>", com "Ver o trabalho" e "Parar". Corrigir também o comentário.
- **Esforço:** P.
- **Teste:** `FakeDelegation` com um turno que não termina e `sweep(now: +3 h 1 min)`. Espere 1 banner e o pedido ainda `.running`.
- **Relação:** REVISAO-COLABORACAO, "turno do membro que pode se perder com um pedido suspenso". Este é o outro lado: o pedido que não termina.

### P2

#### P2-1. ⌘. no streaming tira o texto do histórico do modelo

- **Evidência:** sonda: o chat com 3.343 caracteres e `messages = [user]`; `AgentEngine.swift:425-426`; `BotSession+Turn.swift:101`. Uma queda de conexão, ao contrário, grava o parcial (`:284-290`).
- **Correção mínima:** em `BotSession.stop`, se `liveText` tem texto, chamar `conversation.absorb(.assistant(text + interruptedMarker))` antes de fechar. Assim "o que você leu, o modelo também leu", como já é na queda.
- **Esforço:** P.
- **Teste:** `CallScript` com uma resposta segurada (`holdsCall`) que já emitiu texto, e então `stop()`. Espere a última `messages` ser `assistant` com o texto e o marcador, e o turno seguinte enviá-la.
- **Relação:** nova.

#### P2-2. Queda de conexão depois de texto encerra o turno inteiro

- **Evidência:** sonda `cut_after_text`: 1 pedido, falha imediata, aviso "Sem conexão com o provedor…" (`AgentEngine.swift:284-290`, `ProviderTransport.swift:102-107`).
- **Correção mínima:**
  - Gravar o parcial, como já é feito, e seguir **uma vez** com o mesmo "continue" usado depois de `max_tokens` (`:338-347`), em vez de `.failed`.
  - Se falhar de novo, aí falhar.
  - Trocar a frase para "O provedor cortou a resposta no meio".
- **Esforço:** P.
- **Teste:** script com uma resposta que emite texto e lança `networkConnectionLost`, depois "fim". Espere 2 chamadas, o turno ok e o parcial no histórico.
- **Relação:** irmão da B2 da REVISAO-CODIGO, que só tratou o corte antes do texto.

#### P2-3. Turno longo perde de vista os arquivos tocados no começo

- **Evidência:** resumo de passos com ≤ 24 linhas (`ToolDigest.swift:8, 41-46`). O ledger só absorve turnos dobrados (`ContextWindow.swift:318-333`). O `writeTarget` já sabe quais arquivos cada passo escreveu (`AgentEngine.swift:976, 1047-1052`).
- **Correção mínima:** ao pôr passos de lado, juntar a lista de arquivos escritos ou alterados nesses passos numa linha fixa do resumo ("Arquivos alterados nesta tarefa: …", até 40, como `maxFiles`), fora das 24 linhas.
- **Esforço:** P–M.
- **Teste:** `ContextWindow.fit` com 200 passos de `write_file` em arquivos distintos e orçamento pequeno. Espere os 40 arquivos mais recentes na nota de passos, mesmo com mais de 24 passos postos de lado.
- **Relação:** REVISAO-MEMORIA (o ledger) e REVISAO-CODIGO T4.

#### P2-4. Falha em rotina não avisa fora do app; `tell` que falha não avisa ninguém

- **Evidência:**
  - `notify` só em sucesso (`BotSession+Turn.swift:388`).
  - `answer` só para `ask` (`DelegationHub.swift:324`).
- **Correção mínima:**
  - Uma opção em Ajustes → Notificações, "Avisar quando uma rotina não terminar", ligada por padrão, que manda um banner com o motivo.
  - Para `tell`, uma linha de evento no chat de quem mandou: "<Orb> não conseguiu: <motivo>".
- **Esforço:** P.
- **Teste:** rotina com cliente que lança 500 e `QuietNotifications`: espere 1 banner com o motivo. Um `tell` para um Orb que falha: espere 1 evento `.failed` no chat de origem.
- **Relação:** REVISAO-COLABORACAO (tell acorda o destino e descarta o resultado).

#### P2-5. O Parar não interrompe parte do trabalho, e algumas ferramentas não têm prazo

- **Evidência:**
  - Leitores de PDF/Office sem checagem de cancelamento (`Tools/ToolBox.swift:117-120`).
  - `MCPManager.ensureStarted` com `Task` não estruturada (`MCPTool.swift:262, 275-280`).
  - ScreenCaptureKit sem prazo (`WindowCapture.swift:335`).
  - OCR sem prazo (`ScreenshotTool.swift:450-453`).
  - `web_fetch save_to` sem prazo total.
  - `search_files` não avisa quando o `mdfind` estoura os 30 s.
  - `connector_call` com `arguments` em JSON inválido vira `{}` em silêncio (`ConnectorGateway.swift:126-132`).
- **Correção mínima:**
  - um `withTimeout` comum (corrida com `Task.sleep`) em SCK (10 s) e OCR (20 s);
  - `withTaskCancellationHandler` no `ensureStarted`;
  - checagem de cancelamento por página nos leitores;
  - erro explícito para `arguments` inválido no `connector_call`.
- **Esforço:** M, espalhado; cada item é P.
- **Teste:** um por item. Por exemplo, um MCP falso que demora 30 s para iniciar e Parar aos 1 s: espere a `Task` do motor terminar em < 2 s.
- **Relação:** REVISAO-CODIGO B4/B7 (o que vive depois do Parar).

### P3

- **P3-1. A queda do app pode perder a própria mensagem.**
  - Ela entra com 5 s de atraso (`AppModel.swift:1466` → `mutateItems` → `scheduleSave(5)`), e não há aviso quando o disco ficou num momento "limpo" (`Models.swift:243, 266`).
  - Correção: `scheduleSave(delay: 0)` só para a mensagem do usuário que abre o turno (1 gravação a mais por turno, 1,4 ms fora do main), mais uma marca `turnOpen` no `ConversationMeta` para o aviso ao reabrir.
  - Teste: gravar logo depois do `send` e ler do disco.
- **P3-2. Desistência de 24 h aparece como "Você parou a conversa" para quem pediu** (`AppModel+Approvals.swift:129-132` → `stop` → `cancelChain(.user)`).
  - Correção: passar o motivo (`.gaveUp`) para a cadeia.
  - Relação: REVISAO-COLABORACAO, "recusas que enganam".
- **P3-3. O motor é um ator único** (`AppModel.swift:225`). A montagem da janela, o `ToolOutputCap` (que grava arquivo) e os hashes do `LoopWatch` de todos os Orbs passam por ele em fila.
  - Hoje é pouco: 6 ms por passo.
  - Correção futura: tirar o I/O do ator (`ToolOutputCap.save` numa fila própria) ou ter um motor por Orb.
- **P3-4. O preparo do turno faz em série coisas independentes** (`brief`, `gather`, anexos; `AppModel.swift:1564-1569`).
  - Correção: `async let`.
  - Ganho pequeno na sonda (7 ms no total), provavelmente maior com memória real. Medir antes de fazer.
- **P3-5. Pedido delegado não recebe o texto de "execução automática"** (`unattendedPrompt` só para rotina cadastrada, `AppModel.swift:2028-2032`). O motor já trata o turno como `unattended` (`:1619`), então o efeito é menor.
- **P3-6. "Sem conexão com o provedor" para uma resposta cortada pelo provedor.** A frase culpa o Wi-Fi da pessoa (`EngineTypes.swift:448`, `ProviderTransport.swift:105-106`). Vai junto com P2-2.

## Ordem em etapas (cada uma usável sozinha)

1. **Ver o gasto do turno** (P0-1, parte 1). Só exibe; não muda o comportamento. A pessoa já ganha o meio de notar um turno caro.
2. **Aviso de laço** (P0-1, parte 2). Um aviso na conversa e, em rotina ou pedido, um banner com "Parar". Pode ter um interruptor em Ajustes → Notificações ("Avisar quando um Orb parecer andar em círculos"), ligado por padrão.
3. **Vigia de conteúdo do provedor** (P1-1). Status primeiro (aviso aos 60 s); a desistência aos 3 min pode entrar no mesmo pacote ou depois. Cada metade funciona sozinha.
4. **Espera maior para 429** (P1-2). Independente.
5. **Banner de pedido longo e de falha de rotina** (P1-4, P2-4). Só avisos, com interruptor.
6. **`prepareHistory` fora do main** (P1-3). Independente; mudança só de desempenho.
7. **Parar e queda de conexão preservam o que foi dito** (P2-1, P2-2, P3-6).
8. **Arquivos tocados no resumo do turno** (P2-3).
9. **Prazos e cancelamentos das ferramentas** (P2-5), um item por vez.
10. **Acabamentos P3**, à medida que mexer nas áreas.

## O que não fazer

- **Não trazer de volta os limites removidos no `c3d8029`**: passos por turno, orçamento do grupo, encadeamentos e pedidos entre Orbs. Tudo aqui é **ver e avisar**. Mesmo o aviso de laço não para o turno sozinho.
- **Não parar um turno automaticamente por gasto ou por tempo.** Um aviso com "Parar" deixa a decisão com a pessoa. Se um dia houver "pausa de segurança" em rotina, que seja opção desligada por padrão e decidida por você.
- **Não tentar de novo uma resposta que já mostrou texto, refazendo-a do zero:** duplicaria o que a pessoa leu. Seguir com "continue" (P2-2) é diferente.
- **Não retomar sozinho, ao reabrir, um turno, rotina ou pedido interrompido:** a última ação pode ter sido feita.
- **Não pôr um prazo global por chamada de ferramenta que alcance os cartões** (aprovação, `ask_user`, `browse_show`): a espera humana já tem o lembrete de 1 h e a desistência de 24 h.
- **Não gravar a cada token nem a cada passo para "não perder nada":** o ritmo de 5–10 s custa 1,4 ms por gravação e cobre bem. Só a mensagem do usuário merece gravação imediata (P3-1).
- **Não aumentar tentativas para 429 de saldo nem para 401/403:** esperar não paga a conta nem conserta a chave.
- **Não fechar o navegador nem os jobs no Parar:** a pessoa usa isso de propósito.
