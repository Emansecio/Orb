# Revisão dos grupos de Orbs — 16/10/2026

Escopo: como os Orbs de um grupo conversam, quanta autonomia têm e o que falta para um grupo levar um trabalho longo do
começo ao fim (exemplo usado como teste: discutir, idealizar, construir, revisar, polir, testar e subir um projeto).
A revisão de 12/10 (`REVISAO-ORBS-2026-10-12.md`) deixou "a orquestração entre Orbs nos grupos" para uma rodada própria;
é esta. Conferido no código da `main` em `b7f2785`.

## Como funciona hoje

- **Entrada.** Sua mensagem vai para o orquestrador, ou para quem você @menciona (`@todos` chama todos)
  (`GroupHub.postUserMessage`, `Mentions`).
- **Distribuição.** O orquestrador divide o trabalho com `orbs ask`. Os membros trabalham em paralelo, cada um no próprio
  `BotSession`, como "side run", numa conversa própria por grupo (`conversations/<Orb>/grupo-<id>.json`). Por isso cada
  membro lembra o que já fez no grupo.
- **Respostas.** A resposta de cada membro acorda quem pediu (`DelegationHub.deliverInbox`, em lotes de até 5). O
  orquestrador junta tudo numa resposta final.
- **Fim do pedido.** O pedido termina quando ninguém tem mais nada a fazer (`GroupHub.finishIfIdle`). Nesse momento uma
  página de sessão é gravada no quadro.
- **O que cada turno recebe** (`GroupPrompt.preface`):
  - a lista de membros com os papéis;
  - o fio desde o último turno daquele membro: até 30 itens e 8 mil caracteres, com as falas dos outros Orbs marcadas
    como dados;
  - o resumo do quadro (`GroupBoard.brief`): objetivo, combinados, notas relacionadas e títulos das outras notas.
- **Conversa direta entre membros.** Os membros podem pedir uns aos outros (`GroupPolicy.membersMayTalk`). No grupo, o
  caminho da cadeia recomeça a cada turno (`groupTurnExtras`: `hop: 1`, `path: []`). Assim, o "A→B→A" e o limite de 4
  encadeamentos não travam idas e voltas, e só o orçamento do grupo segura loops.
- **Orçamento por pedido.** São 12 turnos e 150 mil tokens (`GroupBudget`). Quando acaba, aparece o cartão
  Continuar/Encerrar.
- **Aprovações.** Os cartões de aprovação dos membros aparecem na tela do grupo (`showGroupOfMember`).

**O que já funciona bem:**
- o ciclo pedir, responder e acordar, com a fila por Orb;
- a memória do grupo, com página de sessão automática;
- cada membro com o próprio modelo (por exemplo, um Dev barato e um Revisor forte);
- a presença ao vivo ("Dev e QA trabalhando…", "Revisor espera você");
- a parada com ⌘.;
- a defesa contra texto injetado (fala de outro Orb tratada como dado).

Para pedidos curtos ("pesquisa X e resume", "compara A e B"), o desenho está certo.

## Simulação: um projeto do começo ao fim

Grupo **Estúdio**: Atlas (orquestrador), Arquiteto, Dev, Revisor, QA. Você escreve: "cria um app de lista de compras em
SwiftUI, revisa, testa e sobe no GitHub".

1. **Discutir e idealizar.**
   - Atlas recebe o pedido sozinho. Ele pode perguntar ao Arquiteto, mas não existe uma "rodada" em que os membros reagem
     às ideias uns dos outros.
   - O prompt de membro manda "answer with the result only" (`GroupPrompt.section`), então cada um entrega um monólogo.
   - A discussão só acontece se o Atlas fizer as perguntas uma a uma e cada membro ler o fio.
2. **Planejar.**
   - O plano do Atlas vira texto no fio, ou um `task_plan` na conversa *dele*, que a tela do grupo não mostra (o
     `TaskPlanStrip` só existe em `ChatView.swift:301`) e que não entra no turno dos outros.
3. **Construir.**
   - O Dev escreve na pasta *dele* (`bot.workingURL`, `AppModel.swift:1525`).
   - O roster passa os colegas "sem ids nem pastas" (`teammatesText`), então o Revisor não sabe onde está o código, a não
     ser que o Dev cole os caminhos.
   - O turno do Dev para em **40 passos**, sem continuar sozinho (`sideRunMaxSteps`; `stretches = 1` quando é turno de
     grupo, `AppModel.swift:1538-1542`). Um app de verdade não sai em 40 passos.
4. **Esperar.**
   - Se o Dev levar mais de 30 minutos, o pedido do Atlas, que está em `awaitingChildren`, **falha com "Tempo esgotado"**
     mesmo com o Dev ainda trabalhando.
   - O `sweep` (`DelegationHub.swift:573`) só poupa quem tem resposta na caixa ou filho retido por pausa; um filho
     *rodando* não protege. É bug.
5. **Revisar e polir.**
   - Revisor e Dev vão e voltam, e cada volta consome turnos do orçamento.
   - Com 12 turnos, já que cada acordar conta como turno, o grupo pausa várias vezes por fase.
   - Com 4 membros ou mais, o Atlas ainda esbarra em **3 pedidos abertos por Orb** (`DelegationRules`, regra 7, que vale
     também nos grupos).
6. **Testar.** O QA roda os testes na pasta dele, e não na do Dev, ou seja, no lugar errado.
7. **Subir.**
   - O `git push` de um membro pede aprovação na tela do grupo. Isso está certo.
8. **Encerrar.**
   - O pedido termina quando fica ocioso, e não quando os critérios foram cumpridos.
   - Se você fechar o app no meio, o pedido some (`GroupRun` só fica em memória).

**Resultado:** o grupo serve para pedidos curtos, mas não sustenta um projeto. Faltam quatro fundações: a pasta comum,
o plano do grupo, turnos longos e a espera sem prazo fixo. O resto é ajuste.

## Lacunas, por prioridade

### P0: sem isso um projeto não fecha

**1. Pasta do projeto do grupo.**
- `OrbGroup.folder: URL?`, opcional, escolhida na criação ou na edição do grupo.
- No turno de grupo, `groupTurnExtras` passa essa pasta como `workingDirectory` no `ToolContext`.
- Ela também vale para o retrato da pasta, para as instruções da pasta (confiança por hash, como já existe) e para o
  `dangerScope`.
- Sem pasta, nada muda (cada um na sua).
- O roster do grupo passa a dizer "pasta do projeto: …".
- Esforço: M.

**2. Plano do grupo, visível e na cabeça de todos.**
- Reaproveitar o `TaskPlan`: o plano do orquestrador passa a ser o plano do grupo, guardado na conversa do grupo, e não
  na conversa lateral dele.
- Cada etapa ganha um dono (membro).
- A tela do grupo mostra a faixa do plano (o `TaskPlanStrip` existente), e o preface de cada membro ganha uma linha:
  fase atual e as etapas dele.
- Fechamento: grupo ocioso com etapas pendentes acorda o orquestrador uma vez ("faltam X, Y: replaneje ou conclua"), em
  vez de gravar "concluído".
- Esforço: M/G. É o item 1 e 2 da `AUTONOMIA-2026-10-13.md` levado ao grupo.

**3. Turno de membro que não morre em 40 passos.**
- Liberar o `AutoContinue` nos turnos de grupo enquanto o plano avança.
- Os tokens continuam contando no orçamento do grupo, que é quem para tudo.
- Esforço: P/M, porque o mecanismo já existe para a conversa própria.

**4. Bug: tempo esgotado com filho rodando.**
- No `sweep`, não falhar o pedido em `awaitingChildren` enquanto algum filho está `queued`/`running`.
- Ou contar o prazo desde a última atividade da cadeia (`chainStates.touched`), e não desde o início da espera.
- Teste em `DelegationHubTests`.
- Esforço: P.

### P1: o grupo funciona, mas engasga

**5. Orçamento do tamanho do trabalho.**
- Predefinições no grupo:
  - Econômico, Equilibrado (12 turnos e 150 mil tokens, o padrão) e Amplo, que já existem;
  - "Projeto": por exemplo 60 turnos e 2 milhões de tokens.
- Renovação automática enquanto o plano avança (etapa nova feita), com teto total e parada por estagnação. Hoje é um
  cartão a cada janela.
- Esforço: M.

**6. Paralelismo de verdade.**
- No grupo, o limite de pedidos abertos do orquestrador passa a ser `membros − 1`, e não 3.
- Esforço: P.

**7. Rodada de discussão.**
- Um modo do orquestrador (`orbs ask` com `round: true`, ou `@todos discutam …`) que chama os membros **em sequência**.
- Cada membro lê as falas anteriores da rodada antes de falar, e o prompt de membro, nessa hora, pede opinião e crítica,
  e não "result only".
- No fim, o orquestrador consolida as decisões e as grava como combinados (`preferencias/`) no quadro.
- É o que faz o "discutir e idealizar" existir.
- Esforço: M.

**8. Sobreviver ao fechar o app.**
- Persistir `GroupRun` e o plano.
- Ao reabrir, um cartão "Retomar o pedido de onde parou?" em vez de retomar sozinho.
- Os turnos em voo voltam como "interrompido"; isso já existe em `closingInterruptedTurn`.
- Esforço: G.

**9. Entregas além de texto.**
- A resposta do membro leva os `ProducedFile` do turno para a mensagem do fio, com cartões de arquivo como no chat.
- Com a pasta comum isso pesa menos, mas a tela do grupo hoje só mostra texto cortado em 6 mil caracteres.
- Esforço: P/M.

### P2: acabamento

**10. Papel no grupo.**
- `OrbGroup.roles[memberID]` sobrescreve o papel global ("neste grupo, você é o revisor").
- Esforço: P.

**11. Grupo agendado.**
- Rotina que manda uma mensagem a um grupo, por exemplo "toda manhã revisem os PRs abertos".
- Hoje o grupo só começa com mensagem sua.
- Esforço: M.

**12. Fases como modelo de grupo.**
- Um grupo criado pelo "Criar conversando" com objetivo de projeto já nasce com:
  - os papéis Arquiteto/Dev/Revisor/QA;
  - o orçamento "Projeto";
  - a pasta definida;
  - o plano inicial com as fases.
- Só convenção sobre as peças acima, sem motor novo.
- Esforço: P depois de 1–5.

## Ordem sugerida (cada etapa usável sozinha)

1. **Correções curtas.** Itens 4 e 6, e as predefinições de orçamento do item 5, sem a renovação automática.
2. **Pasta do projeto do grupo** (item 1), com a escolha na tela de edição do grupo.
3. **Plano do grupo** (item 2) e **turnos longos** (item 3), juntos, porque o segundo depende do progresso do primeiro.
4. **Renovação do orçamento por progresso** (o resto do item 5) e **rodada de discussão** (item 7).
5. **Persistir e retomar** (item 8).
6. **Acabamento:** itens 9, 10, 11 e 12.

Ao fim da etapa 3, o exemplo do Estúdio já roda do começo ao fim com você aprovando só o push.

## Status

**Depois, no mesmo dia, por decisão sua: sem limites.** Saíram o orçamento do grupo (turnos e tokens por pedido, as
predefinições, a pausa com Continuar/Encerrar) e os limites entre Orbs (encadeamentos, pedidos abertos, vezes por par,
mensagens, turnos e tokens por cadeia), e também o limite de passos por turno. Ficam: parar com ⌘. ou Parar grupo, a
recusa do A→B→A, a de mensagem repetida, o tamanho da mensagem e os tempos de espera (`requestTimeout`, `workTimeout`).
O topo do grupo mostra o que o pedido já usou. Os itens 4, 5 e 6 abaixo ficam como histórico, e a renovação por progresso
(resto do item 5) deixa de existir.

**Etapa 1, feita em 16/10:**

- **Item 4.**
  - O `sweep` não derruba mais um pedido que espera trabalho em andamento. Isso vale para dois casos:
    - um filho `queued`/`running`/`awaitingChildren`;
    - um pedido na fila de um Orb que está num turno.
  - Os dois só caem depois do teto `DelegationLimits.workTimeout` (3 h), que é a rede contra um turno travado.
  - A fila de um Orb livre continua caindo em 30 min.
  - Testes: `waitingForWorkThatGoesOnIsNotATimeoutUntilTheCeiling`, e `aTimedOutRequestThatWaitedForItsChildrenClosesItsLines`
    passa a usar o teto.
- **Item 6.**
  - `DelegationRules.openLimit(groupSize:)`: fora de grupo continua 3; num grupo, `max(3, membros − 1)`.
  - A recusa diz "Você já tem o máximo de pedidos abertos" sem citar um número, que agora varia.
  - Teste: `inABigGroupAnOrbMayWaitForOneAnswerPerTeammate`.
- **Item 5, só a primeira parte.**
  - As predefinições Econômico, Equilibrado e Amplo já existiam. Entrou a **Projeto**: 60 turnos e 2 milhões de tokens,
    que é o teto dos controles de turnos e tokens do painel.
  - No painel, a escolha vira menu quando a coluna está estreita demais para quatro segmentos (`ViewThatFits`).
  - A renovação automática por progresso continua pendente; ela depende do plano do grupo (etapa 3).

## O que não fazer

- Só aumentar números (turnos, passos, membros) sem plano e pasta comum: aumenta o custo e a conversa sem aumentar a entrega.
- Deixar os membros conversarem livremente, sem orquestrador ou rodada: vira eco e queima orçamento.
- Renovar o orçamento sem critério de progresso: um grupo girando em falso passa a custar sem limite.
