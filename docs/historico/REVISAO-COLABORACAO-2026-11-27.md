# Revisão da colaboração entre Orbs — 2026-11-27

Revisão somente de leitura de como um Orb fala com outro, orquestra e coordena: pedidos (`orbs`), grupos, pastas de trabalho e times. Escrita sobre o commit `1f693d7f`. Nada foi alterado, compilado ou executado: cada achado foi conferido lendo o código citado, e cada proposta precisa do teste indicado antes de entrar (TESTE-5).

Confira no código antes de tratar este relatório como estado atual.

**Depois da revisão (mesmo dia):** foram implementados C11 a C22, O1, M1, M3 e M8, cada um com teste de regressão conferido falhando sem a correção. O4 foi retirado e o texto de O1 foi corrigido (ver as duas seções). O comportamento atual está em `docs/COLABORACAO.md`. Seguem em aberto os itens de times (C1–C10, C7b, M2, M4–M6, O2, O3) e M7.

## Resumo

- **36 sugestões**: 23 correções (C), 4 otimizações (O) e 9 melhorias de capacidade (M).
- **O maior risco está nos times.** Pausar não interrompe o turno em andamento (C1), o veredito do revisor é lido do lugar errado (C2), uma falha do revisor conta como reprovação (C3) e o quadro vivo mostra as entradas mais antigas em vez das novas (C6). São quatro causas independentes de retrabalho e gasto de tokens, todas com correção pequena.
- **Nos pedidos e grupos**, o problema mais visível é o texto de resposta gravado já com `‹ ›` no lugar de `< >` (C11): código e HTML chegam corrompidos na tela e no arquivo de "texto completo". Em grupos com pasta git, o revisor não enxerga o trabalho do construtor (C12).
- **Ganho de contexto mensurável:** as respostas dos membros chegam duas vezes ao orquestrador (O1, no turno novo seguinte dele no grupo) e o bloco "desde o último turno" não tem teto para pedidos atendidos (C15, até ~150 mil caracteres num turno).
- **Capacidade:** o time montado pelo Olheiro nunca roda etapas em paralelo, porque as etapas saem em cadeia estrita com dono por rodízio (M2).

Itens de endurecimento ficaram fora deste arquivo (GIT-5).

## Como os Orbs conversam hoje

| Canal | O que carrega | Onde |
|---|---|---|
| `orbs ask` / `tell` / `list` | Pedido com resposta, aviso sem resposta, lista de colegas | `Engine/Tools/OrbsTool.swift`, `MultiOrb/DelegationHub*.swift` |
| Envelope | `<orb_request>` e `<orb_reply>` com o texto do colega como dado | `MultiOrb/OrbEnvelopeText.swift` |
| Contexto do pedido | Até 3 pedidos anteriores do mesmo colega (`<orb_your_context>`) | `MultiOrb/RequestBackground.swift` |
| Desde o último turno | O que aconteceu fora da conversa (`<orb_since_last_turn>`) | `MultiOrb/SinceLastTurn.swift` |
| Grupo | Seção fixa no prompt, prefácio por turno (membros, fio, quadro), @menções, veredito de revisão | `Groups/GroupPrompt.swift`, `GroupHub.swift`, `GroupReview.swift` |
| Pastas de trabalho | Worktree e ramo por membro, merge pelo orquestrador | `MultiOrb/WorkFolders.swift` |
| Time | Laço de etapas, portões de qualidade, quadro vivo, `team_note`, orientação ao vivo | `Teams/TeamHub.swift`, `TeamBoard.swift`, `TeamQualityGates.swift` |

Decisões já fechadas e respeitadas aqui: sem limite de quantidade, profundidade ou turnos de pedidos (só o teto diário do pulso freia), Orbs agem por conta própria, apagar sempre pergunta, Claude Code só como cano.

## Prioridades

Esforço: P = até ~15 linhas, M = um arquivo e seus testes, G = vários arquivos.

| # | Sugestão | Área | Impacto | Esforço |
|---|---|---|---|---|
| C1 | Pausar interrompe o turno em andamento | Times | Alto | P |
| C2 | Veredito lido só do último passo | Times | Alto | P |
| C3 | Falha do revisor não conta como reprovação | Times | Alto | P |
| C6 | Quadro vivo mostra o mais novo | Times | Alto | P |
| C11 | Resposta gravada sem trocar `< >` | Pedidos e grupos | Alto | P |
| C4 | Orientação da etapa sobrevive a pausa | Times | Alto | M |
| C12 | Revisor do grupo enxerga o ramo do construtor | Grupos | Médio-alto | P |
| C5 | Auditoria final roda no projeto integrado | Times | Médio-alto | P |
| O1 | Resposta não chega duas vezes ao orquestrador | Grupos | Médio (tokens) | M |
| C15 | Teto para pedidos atendidos no bloco | Pedidos | Médio (tokens) | P |
| C7 | Retomar reaproveita a pasta de trabalho | Times | Médio | P |
| C13 | Pedido de revisão reconhecido por prefixo | Grupos | Médio | P |
| C8 | Revisor julga só a etapa | Times | Médio | P |
| C10 | Conflito de merge com orientação acionável | Times | Médio | P |
| M2 | Olheiro define dono e dependências | Times | Alto | M |
| M1 | `ask` avisa que o colega está ocupado | Pedidos | Médio | P |
| M8 | Líder enxerga a atividade dos colegas e dos grupos | Pedidos e grupos | Médio-alto | P |
| C7b | Time "em execução" sem laço vira pausado | Times | Médio | P |
| C9, C14, C16, C17, C18 | Correções pequenas | Vários | Baixo-médio | P |
| C19–C22, O2–O4, M3–M7 | Baixa prioridade ou direção | Vários | Baixo | P–G |

## Correções

### C1 · Times: pausar ou apagar não interrompe o turno em andamento

- **Onde:** `Teams/TeamHub.swift:203-213` (tarefas das etapas), `:126-131` (`pause`), `Engine/AgentEngine.swift:141-146`.
- **Por quê:** `pause` cancela `runTasks[teamID]`, mas cada etapa roda numa `Task { @MainActor … }` não estruturada, que não herda o cancelamento. O motor só para quando quem consome o `AsyncStream` é cancelado, então o turno segue até o fim (até 40 passos, editando arquivos e gastando tokens) com o time já mostrado como pausado. Pausar e retomar roda a mesma etapa duas vezes ao mesmo tempo.
- **Como:** grupo de tarefas estruturado, que propaga o cancelamento.

```swift
// TeamHub.runLoop, in place of `stageTasks` and the loop that awaits them
let results = await withTaskGroup(of: (UUID, Bool).self) { group in
    for stage in readyStages {
        group.addTask { @MainActor [weak self] in
            (stage.id, await self?.processStage(teamID: teamID, runID: runID, stage: stage) ?? false)
        }
    }
    var results: [(UUID, Bool)] = []
    for await result in group { results.append(result) }
    return results
}
```

- **Impacto:** Pausar passa a parar de fato; fim do gasto e das edições depois da pausa e das etapas em dobro.
- **Teste:** motor real com cliente preso num `TestGate`; `pauseTeam`; `waitUntil` o cliente ver o cancelamento. O teste atual (`TeamExecutionAndGatesTests.swift:151-195`) usa `turnExecutor` falso e só confere status.

### C2 · Times: o veredito é lido do texto de todos os passos

- **Onde:** `Teams/TeamHub.swift:653-655`; leitura em `Groups/GroupReview.swift:12-21`.
- **Por quê:** `reply += delta` junta o texto de todos os passos do turno, e `ReviewVerdict.read` olha a primeira linha. Um revisor que escreve "Vou conferir os testes" antes de usar uma ferramenta nunca tem `APPROVED` na primeira linha: a etapa volta como "sem veredito" e a auditoria final como reprovada.
- **Como:** guardar só o texto do último passo. A mensagem do assistente é montada depois do texto do passo (`AgentEngine.swift:341`), então basta zerar quando ela traz chamadas de ferramenta.

```swift
case .message(let msg):
    // Only the last step's words are the answer: what came before a tool call is narration.
    if msg.role == .assistant, !msg.toolCalls.isEmpty { reply = "" }
    for call in msg.toolCalls { pendingRequests[call.id] = call }
```

- **Impacto:** fim das reprovações falsas, a causa mais provável de etapas refeitas sem motivo. O resumo do construtor também passa a ser só o relato final; confira que os testes de `CompletionWatch` continuam passando.
- **Teste:** turno com dois passos (texto + ferramenta, depois `APPROVED`) aprova a etapa.

### C3 · Times: falha do turno do revisor conta como reprovação

- **Onde:** `Teams/TeamHub.swift:308-320`, `Teams/TeamQualityGates.swift:42-44`.
- **Por quê:** `reviewOutcome.failedError` nunca é lido. Uma queda de rede ou erro 429 no revisor devolve resposta vazia, que vira `missingReviewVerdict`: o construtor recebe uma orientação que não existe, a recusa é contada e a etapa é refeita.
- **Como:** tratar como falha de execução, igual ao ramo do construtor.

```swift
guard !Task.isCancelled, isCurrentRun(teamID: teamID, runID: runID) else { return false }
if let err = reviewOutcome.failedError, !err.isEmpty {
    await handleRecovery(teamID: teamID, runID: runID, stage: stage, rawError: err, workspace: workspace, bank: bank)
    setMemberState(teamID: teamID, memberID: reviewer.id, state: .idle)
    return false
}
```

- **Impacto:** falha de provedor deixa de virar retrabalho e de empurrar a etapa para a escalada ao líder. A etapa ainda é construída de novo na rodada seguinte; guardar o resultado do construtor para evitar isso só vale depois de medir.
- **Teste:** revisor que falha não registra recusa nem grava orientação.

### C4 · Times: a orientação do revisor some em pausa ou reinício

- **Onde:** `Teams/TeamHub.swift:40` (`extraDirectives`, só em memória), `:259` (removida ao começar a etapa), `:502` (orientação da etapa corretiva).
- **Por quê:** a orientação é consumida no início do turno. Se o turno é cancelado, ou o app fecha, a etapa recomeça sem saber o que o revisor ou a auditoria pediu, e repete o mesmo erro.
- **Como:** guardar na própria etapa, que já é persistida, e limpar só depois que o turno de construção terminou.

```swift
// OrbTeam.swift
struct MissionStage { …; var directive = "" }        // init(from:): directive = try c.value(.directive, default: "")

// TeamHub.swift
private func setDirective(_ text: String, teamID: UUID, stageID: UUID) {
    guard let model, let t = model.teams.firstIndex(where: { $0.id == teamID }),
          let s = model.teams[t].mission.stages.firstIndex(where: { $0.id == stageID }) else { return }
    model.teams[t].mission.stages[s].directive = text
}
// processStage: let directive = stage.directive.isEmpty ? nil : stage.directive
// after the guard that follows the build turn: setDirective("", teamID: teamID, stageID: stage.id)
```

  Cada `extraDirectives[id] = x` vira `setDirective(x, …)` e o dicionário sai (COD-4).
- **Impacto:** retomada continua de onde parou; menos rodadas de revisão perdidas.
- **Teste:** orientação gravada, time pausado e retomado: o prompt da etapa ainda traz a orientação. Decodificar um time antigo sem a chave.

### C5 · Times: a reauditoria final roda numa pasta antiga

- **Onde:** `Teams/TeamHub.swift:400`, `MultiOrb/WorkFolders.swift:54-55`.
- **Por quê:** o auditor recebe uma worktree própria, que nunca é mesclada nem removida. Quando a auditoria devolve o trabalho e a etapa corretiva entra no projeto, a nova auditoria reaproveita a mesma worktree, parada no commit antigo: audita código que não tem a correção.
- **Como:** auditar no checkout do projeto, que é o resultado integrado.

```swift
let project = team.projectFolder.trimmingCharacters(in: .whitespacesAndNewlines)
let workspace = project.isEmpty
    ? await TeamWorkspaces.prepareMemberFolder(team: team, member: auditor, runID: runID, dataFolder: model.store.directory)
    : WorkFolder(url: URL(fileURLWithPath: project, isDirectory: true).standardizedFileURL)
```

- **Impacto:** a auditoria julga o que será entregue; some também a worktree e o ramo órfãos de cada auditoria.
- **Teste:** repositório temporário, auditoria devolve, etapa corretiva mescla, a segunda auditoria recebe a pasta do projeto.

### C6 · Times: o quadro vivo mostra as entradas mais antigas e corta as novas

- **Onde:** `Teams/TeamBoard.swift:52-53` (contratos gravados do mais antigo para o mais novo), `:171-174` e `:177-180` (bloco cortado em 650 caracteres mantendo o começo), `:162-164` (mapa de etapas).
- **Por quê:** com 10 contratos de até ~330 caracteres, só os dois mais antigos cabem; o contrato que um membro acabou de registrar para os colegas não aparece para ninguém. O mesmo vale para o log de verificações. No mapa de etapas, as concluídas vêm primeiro e as abertas são as cortadas.
- **Como:**

```swift
let contractsCombined = contractLines.reversed().map { MemoryBank.untrusted($0) } + otherPrefs
let verifications = (await existingLines(at: verificationsPath, in: bank)).reversed().map { MemoryBank.untrusted($0) }

// formatStagesBlock(_ team: OrbTeam, openFirst: Bool = false), called with `openFirst: true` only by `brief`
let stages = openFirst ? team.mission.stages.filter { !$0.isDone } + team.mission.stages.filter(\.isDone) : team.mission.stages
```

- **Impacto:** o quadro volta a servir para o que existe: avisar uma interface nova a quem trabalha em paralelo.
- **Teste:** 10 contratos gravados, o último aparece no `brief`; 8 etapas com 5 concluídas, as abertas aparecem.

### C7 · Times: retomar cria pastas novas e deixa o trabalho anterior para trás

- **Onde:** `Teams/TeamHub.swift:100` (novo `runID` a cada `start`), `Teams/TeamWorkFolders.swift:41`, `MultiOrb/WorkFolders.swift:44-48`.
- **Por quê:** worktree e ramo levam o `runID` no nome. Depois de pausar no meio de uma etapa, a retomada cria outra worktree a partir do `HEAD`: o que o membro já tinha feito fica numa pasta que ninguém mais abre, e as pastas se acumulam.
- **Como:** a chave da pasta é o time, não a execução. Em `prepareMemberFolder`, `run: team.id`. O parâmetro `runID` de `prepareMemberFolder` fica sem uso e o de `integrateBranch` já não é usado: remova os dois (COD-4).
- **Impacto:** retomar continua o trabalho em curso; nada de worktrees órfãs.
- **Teste:** duas chamadas com execuções diferentes devolvem a mesma pasta e o mesmo ramo.

### C7b · Times: time gravado como "em execução" sem laço ativo

- **Onde:** `AppModel+Resume.swift:15-40`; nada zera o status ao abrir.
- **Por quê:** a retomada depende do diário de trabalho. Sem a entrada lá, o time abre com status `.running`, mostra "em execução" e não faz nada. Confiança média: reproduza antes de corrigir.
- **Como:** depois de retomar o que o diário traz,

```swift
for index in teams.indices where teams[index].status.isWorking && !teamHub.isRunning(teams[index].id) {
    teams[index].status = .paused
}
```

- **Impacto:** a tela diz a verdade e o botão de retomar aparece.
- **Teste:** estado salvo com `.running` e diário vazio abre como `.paused`.

### C8 · Times: o revisor da etapa recebe todos os critérios da missão

- **Onde:** `Teams/TeamHub.swift:305-307`, `:925-937`.
- **Por quê:** o prompt lista todos os critérios sem dizer que a etapa cobre só parte deles. Um revisor rigoroso reprova a primeira etapa porque critérios de etapas seguintes ainda não estão atendidos.
- **Como:** uma linha no prompt.

```swift
Criteria of the whole mission (judge only what this stage is responsible for; later stages cover the rest):
```

- **Impacto:** menos reprovações por trabalho que ainda nem começou.
- **Teste:** o prompt contém a frase.

### C9 · Times: o contador de recusas não zera depois de chamar o líder

- **Onde:** `Teams/TeamLoopRecovery.swift:64-75` e `:46-51`.
- **Por quê:** a partir da terceira recusa, toda recusa seguinte chama o líder de novo (um turno extra cada).
- **Como:** `stages[stageID]?.reviewRejectCount = 0` antes do `return .escalateToLeader` em `recordReviewChanges`; em `recordFailure`, `stages[stageID]?.sameFailureCount = 0`.
- **Impacto:** o líder é chamado uma vez a cada três recusas.
- **Teste:** a quarta recusa devolve `.none`.

### C10 · Times: conflito de merge devolve uma orientação vaga

- **Onde:** `Teams/TeamHub.swift:342-347`.
- **Por quê:** o membro recebe "Resolva o problema de integração" em português, sem saber onde nem como, e a etapa passa de novo por construção e revisão.
- **Como:**

```swift
case .conflict(let detail):
    extraDirectives[stage.id] = "Your branch \(branch) conflicts with the project (\(detail)). In \(workspace.url.path), run "
        + "git merge $(git -C \(project.path) rev-parse HEAD), resolve the conflicts, run the checks again and commit."
```

  Os outros dois casos (`postMergeFailed`, `unavailable`) mantêm o detalhe, em inglês.
- **Impacto:** o conflito é resolvido na rodada seguinte, em vez de repetir até escalar.
- **Teste:** dois ramos que tocam a mesma linha; a orientação cita a pasta e o comando.

### C11 · Pedidos e grupos: a resposta é gravada com `‹ ›` no lugar de `< >`

- **Onde:** `MultiOrb/DelegationHub+Replies.swift:26` e `:61`.
- **Por quê:** `OrbEnvelopeText.sanitize` é aplicado na origem, então o texto trocado é o que vai para o chat, para o fio do grupo e para o arquivo de texto completo (`:129`). `Array<Int>`, `->`, HTML e JSX chegam corrompidos para a pessoa e para o Orb que abre o arquivo. Quem monta texto para o modelo já troca na hora de montar (`OrbEnvelopeText.swift:71`, `GroupThread.fenced`, `SinceLastTurn`, `RequestBackground`).
- **Como:** guardar o texto como veio, sem caracteres de controle.

```swift
let said = reply?.withoutControlCharacters.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
```

  Antes de mudar, procure todo uso do texto do envelope num prompt e confirme que cada um troca na montagem.
- **Impacto:** código íntegro na tela e no arquivo; o Orb que lê o arquivo completo recebe código que compila.
- **Teste:** resposta com `Array<Int>` aparece igual no item do chat e no arquivo, e com `‹ ›` dentro de `<orb_reply>`.

### C12 · Grupos com pasta git: o revisor não enxerga o trabalho do construtor

- **Onde:** `MultiOrb/DelegationHub.swift:392`, `MultiOrb/WorkFolders.swift:63` e `:107-115`, `Groups/GroupPrompt.swift:32-35`.
- **Por quê:** cada membro trabalha na própria worktree, criada do `HEAD`. O revisor abre uma pasta sem o trabalho do construtor, e o orquestrador só conhece os nomes dos ramos. O construtor nem é instruído a dizer onde deixou o trabalho (`memberNote` é chamado sem `asked`).
- **Como:**

```swift
// DelegationHub.groupWork
return (work.url, WorkFolders.memberNote(work, asked: true))

// WorkFolders.orchestratorNote: list "branch (folder)" (runBranches already returns both) and end with
+ " A review request names the branch and the folder to review."

// GroupPrompt, orchestrator duty
"… then ask a different member to review it against done_when, naming the folder and branch where the work is …"
```

- **Impacto:** a revisão passa a ser sobre o código real, não sobre o resumo do construtor.
- **Teste:** a nota do membro pede o ramo; a do orquestrador lista ramo e pasta.

### C13 · Grupos: "pedido de revisão" é reconhecido por pedaço de palavra

- **Onde:** `Groups/GroupReview.swift:25-28`, `Groups/GroupHub.swift:281-296` e `:217-219`.
- **Por quê:** `isReviewRequest` procura `revis`, `aprov`, `valid`, `verifi` em qualquer lugar: "previsão", "validade", "aproveitar" e "implement validation" contam como pedido de revisão. Se o construtor responde começando por "Alterações:" ou "Mudanças:", vira um `CHANGES` falso; três seguidos travam o grupo com "Review limit reached".
- **Como:** prefixo combinado no prompt, com reserva por começo de palavra.

```swift
static func isReviewRequest(_ text: String) -> Bool {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    return folded.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("review:")
        || folded.range(of: #"\b(review|revis)"#, options: .regularExpression) != nil
}
// GroupPrompt, orchestrator duty: "… start a review request with REVIEW: …"
```

- **Impacto:** a trava de três rodadas só dispara em revisões de verdade.
- **Teste:** "calcule a previsão e a validade" não é pedido de revisão; "REVIEW: confira o login" e "revise o login" são.

### C14 · Grupos: o prompt manda o membro usar `orbs` mesmo sem a ferramenta

- **Onde:** `Groups/GroupPrompt.swift:37-38`, `Groups/AppModel+Groups.swift:323`.
- **Por quê:** com "membros podem conversar" desligado, o membro não recebe `orbs`, mas o prompt diz "ask them directly with orbs". O modelo tenta uma ferramenta que não tem.
- **Como:** `section(groupName:role:mayAsk:)`, passando `policy.membersMayTalk`.

```swift
+ (mayAsk ? "If you need another member, ask them directly with \(orbs). "
          : "If you need another member, say so in your answer. ")
```

- **Impacto:** um passo desperdiçado a menos por turno e pedidos de ajuda que chegam ao orquestrador.
- **Teste:** seção com `mayAsk: false` não cita `orbs`.

### C15 · "Desde o último turno" não tem teto para pedidos atendidos

- **Onde:** `MultiOrb/SinceLastTurn.swift:18`, `:92-112`.
- **Por quê:** avisos têm teto de 10 e reações de 8, mas pedidos atendidos não. Um Orb que atendeu 20 pedidos recebe até 20 × (1.500 + 6.000) caracteres no turno seguinte, repetindo respostas que ele mesmo escreveu.
- **Como:** um auxiliar no lugar dos dois blocos repetidos, mais o teto novo.

```swift
static let requestCount = 5
static let replyLimit = 1_500   // its own answer, told back: the gist is enough

private static func keepNewest(_ limit: Int, of sources: [Source], where matches: (Source) -> Bool) -> [Source] {
    let found = sources.indices.filter { matches(sources[$0]) }
    guard found.count > limit else { return sources }
    let dropped = Set(found.dropLast(limit))
    return sources.indices.filter { !dropped.contains($0) }.map { sources[$0] }
}
```

  Aplique depois de tirar os pedidos repetidos, para o teto contar pedidos distintos.
- **Impacto:** teto de ~15 mil caracteres no pior caso, contra ~150 mil hoje.
- **Teste:** 8 pedidos atendidos, o bloco traz os 5 mais novos.

### C16 · Mais de 5 respostas: a primeira leva manda concluir sem avisar que faltam

- **Onde:** `MultiOrb/DelegationHub+Replies.swift:220-223`, `MultiOrb/OrbEnvelopeText.swift:76-83`.
- **Por quê:** as respostas chegam de 5 em 5. A primeira leva termina com "tell the user the result", e o Orb escreve uma resposta final com parte dos relatos.
- **Como:** `reply(_:more:…)`, chamado com `more: sameWork.count - batch.count`.

```swift
+ (more > 0 ? " \(more) more reports arrive in your next message: wait for them before the final answer." : "")
```

- **Impacto:** uma resposta final só, com todos os relatos.
- **Teste:** 7 respostas, a primeira leva traz o aviso de mais 2.

### C17 · Arquivo da resposta longa usa 4 caracteres do id

- **Onde:** `MultiOrb/OrbEnvelopeText.swift:118`, `MultiOrb/DelegationHub+Replies.swift:111`.
- **Por quê:** `resposta-a1b2.md` tem 65.536 nomes possíveis por Orb, guardados por 14 dias. Duas respostas longas com o mesmo começo de id sobrescrevem uma à outra.
- **Como:** `"resposta-\(requestID.uuidString.lowercased()).md"`.
- **Impacto:** o caminho de texto completo sempre aponta para a resposta certa.
- **Teste:** dois ids com os mesmos 4 caracteres geram arquivos diferentes.

### C18 · A checagem de repetição mistura `tell` e `ask`

- **Onde:** `MultiOrb/DelegationRules.swift:117`, `MultiOrb/DelegationHub.swift:136-137` e `:153`, `MultiOrb/DelegationTypes.swift:132`.
- **Por quê:** a chave é destino + texto. Um `tell` seguido de um `ask` com o mesmo texto em 60 s é recusado como repetido, com uma mensagem que promete uma resposta que nunca vem.
- **Como:** `repeatKey(to:text:kind:)` com o tipo na chave; três pontos de chamada (`validate`, `submit`, `forgetRepeat`).
- **Impacto:** o Orb não fica esperando a resposta de um aviso.
- **Teste:** `tell` e depois `ask` com o mesmo texto passam; dois `ask` iguais continuam recusados.

### C19 · Pedido que falha por tempo não encerra os filhos na fila

- **Onde:** `MultiOrb/DelegationHub+Stopping.swift:178-190`.
- **Por quê:** `fail` encerra o pedido, mas os pedidos que ele abriu continuam na fila e rodam um turno cuja resposta ninguém espera. Raro.
- **Como:** em `fail`, falhar também os filhos que ainda não começaram.

```swift
for child in request.openChildren.compactMap({ requests[$0] }) where child.state == .queued {
    fail(child, "Quem pediu não espera mais")
}
```

- **Impacto:** nenhum turno gasto com trabalho sem destinatário.
- **Teste:** pai em espera com um filho na fila; depois do prazo, os dois ficam `failed`.

### C20 · Grupos: o fio é cortado sem avisar

- **Onde:** `Groups/GroupPrompt.swift:120-130`.
- **Por quê:** acima de 30 itens ou 8.000 caracteres, as mensagens mais antigas somem em silêncio e o membro acha que viu tudo.
- **Como:** uma linha quando houve corte.

```swift
let cut = fitting.count < kept.count || kept.count >= maxItems
return (cut ? ["[earlier messages not shown]"] : []) + fitting.reversed()
```

- **Impacto:** o membro sabe que pode faltar contexto e consulta o quadro.
- **Teste:** 40 itens, a primeira linha é o aviso.

### C21 · Grupos: parar durante um merge pode deixar o projeto com merge pela metade

- **Onde:** `MultiOrb/WorkFolders.swift:113-114` e `:211-232`, `Groups/GroupHub.swift:386-397`.
- **Por quê:** o orquestrador faz `git merge` no checkout do projeto pela ferramenta de terminal. Parar o grupo nesse momento encerra o turno, e a limpeza não confere o estado do repositório.
- **Como:** na limpeza da rodada, se existir `MERGE_HEAD` no projeto, publicar um aviso no fio do grupo dizendo que há um merge por concluir. Não desfazer sozinho.
- **Impacto:** a pessoa fica sabendo antes de trabalhar em cima de um merge incompleto.
- **Teste:** repositório com `MERGE_HEAD`, a limpeza publica o aviso.

### C22 · Criar a worktree tem limite de 30 s

- **Onde:** `MultiOrb/WorkFolders.swift:17`, `:63-72`, `:294`.
- **Por quê:** todo comando git usa o mesmo limite. Em repositório grande, o `worktree add` estoura e o membro cai na pasta compartilhada, sem isolamento.
- **Como:** parâmetro `timeout` em `Git.run` com o valor atual como padrão, e 5 minutos só no `worktree add`.
- **Impacto:** isolamento garantido também em repositórios grandes.
- **Teste:** unitário do parâmetro; o efeito real pede um repositório grande e não foi medido.

## Otimizações

### O1 · Grupos: a resposta do membro chega duas vezes ao orquestrador

- **Onde:** `Groups/GroupPrompt.swift:112-116`, `Groups/GroupHub.swift:202-207`, `MultiOrb/DelegationHub+Replies.swift:233-236`.
- **Por quê:** a resposta chega como `<orb_reply>` e também está no fio do grupo, que entra de novo em "thread since your last turn" no próximo turno novo do orquestrador naquele grupo (a retomada em si não leva prefácio: só `GroupHub.prompt(for:)` monta o fio). Cada resposta repetida ocupa até 1.500 caracteres do fio, que tem teto de 8.000.
- **Como:** o hub avisa o grupo de quais respostas já entregou, e o fio pula essas.

```swift
// GroupTurnHooks (default: does nothing)
func repliesHanded(_ requests: [UUID], to member: UUID)

// DelegationHub.deliverInbox, before startRun in the `serving` branch
if request.envelope.groupID != nil { groupHooks?.repliesHanded(batch.compactMap(\.replyTo), to: botID) }

// GroupHub: memory only, so a restart never hides a reply that was not delivered
private var handed: [UUID: Set<UUID>] = [:]
func repliesHanded(_ requests: [UUID], to member: UUID) { handed[member, default: []].formUnion(requests) }

// GroupThread.lines(…, handed: Set<UUID>)
if message.kind == .reply, handed.contains(message.requestID) { continue }
```

  Como ficou: o gancho leva também o grupo, e `handed` é limpo quando o próximo turno novo do membro começa (a marca do fio já passou das respostas), não no fim da rodada, que deixaria a repetição voltar no pedido seguinte.
- **Impacto:** menos tokens por turno do orquestrador, sem perder informação. Medido no teste `anAnswerHandedAsAReplyIsNotReadAgainInTheThreadOfTheNextRequest` (um membro, resposta de 1.200 caracteres): a mensagem do turno seguinte do orquestrador caiu de 1.565 para 276 caracteres.
- **Teste:** resposta entregue não aparece nas linhas do fio; resposta não entregue aparece.

### O2 · Times: o retrabalho recomeça do zero

- **Onde:** `Teams/TeamHub.swift:630` (`history: []`).
- **Por quê:** depois de um `CHANGES`, o construtor relê o código e refaz o raciocínio sem o histórico do turno anterior.
- **Como:** guardar o histórico do último turno de construção por etapa e reenviá-lo na rodada seguinte, limpando em `markStageDone`. Esforço M.
- **Impacto:** rodadas de correção mais curtas. Meça primeiro: o histórico também custa tokens, e só compensa se o cache do provedor segurar.

### O3 · Campo `usage` do resultado do turno nunca é lido

- **Onde:** `Teams/TeamHub.swift:29`, `:649`, `:675`, `:683`.
- **Por quê:** é sobrescrito a cada chamada e ninguém o consulta; o uso real já vai para `usageLog`.
- **Como:** remover o campo e a variável, depois de confirmar com busca que nada o lê.
- **Impacto:** menos código morto.

### O4 · Textos de retorno de `orbs` longos e em português

- **Onde:** `MultiOrb/DelegationHub+Tool.swift:50-68`, recusas em `MultiOrb/DelegationTypes.swift`.
- **Por quê:** a convenção do projeto para texto enviado ao modelo é inglês e curto; estes voltam a cada chamada.
- **Como:** reescrever em inglês, com a mesma informação. Faça junto com M1, que mexe na mesma linha.
- **Impacto:** pequeno, por chamada.
- **Retirado:** o teste `listShowsTheTeammatesWithoutIdsAndRefusalsAreInPortuguese` mostra que os retornos e recusas de `orbs` em português são decisão deliberada. M1 e M8 escrevem em português, como as linhas vizinhas.

## Melhorias de capacidade

### M1 · `ask` avisa quando o colega está ocupado

- **Onde:** `MultiOrb/DelegationHub+Tool.swift:61-67`.
- **Por quê:** quem pede não sabe se o colega está livre ou com fila, e não consegue decidir entre esperar, pedir a outro ou fazer sozinho.
- **Como:**

```swift
let ahead = queues[envelope.to.id]?.firstIndex(of: envelope.id) ?? 0
let busy = ahead > 0 || isInTurn(envelope.to.id)
+ (busy ? " \(envelope.to.name) is busy (\(ahead) request(s) ahead of yours): the answer may take a while." : "")
```

- **Impacto:** o orquestrador distribui melhor o trabalho, sem custo extra.
- **Teste:** pedido a um Orb em turno devolve o aviso.

### M2 · Olheiro define o dono e as dependências de cada etapa

- **Onde:** `Teams/TeamProposal.swift:226-232`, `Teams/TeamProposalTool.swift` (`stages` é lista de textos).
- **Por quê:** hoje o dono é o rodízio por índice e cada etapa depende da anterior. O time nunca roda duas etapas ao mesmo tempo, embora o laço saiba fazer isso (`TeamHub.swift:202`), e o dono ignora o papel de cada integrante. Nenhuma tela edita dono ou dependência.
- **Como:** etapa como objeto, aceitando texto simples como hoje.

```swift
// tool schema: "stages": [{ "title": string, "owner": string?, "after": [int]? }]
let owner = builtMembers.first { $0.name.caseInsensitiveCompare(stage.owner ?? "") == .orderedSame }
    ?? builtMembers[index % builtMembers.count]
let dependsOn = stage.after.map { $0.compactMap { ids.indices.contains($0 - 1) ? ids[$0 - 1] : nil } }
    ?? (index > 0 ? [ids[index - 1]] : [])
```

  Sem `owner` ou `after`, o comportamento é o de hoje (PROD-2).
- **Impacto:** etapas independentes em paralelo e cada uma com quem tem o papel certo; é o maior ganho de tempo de missão desta lista.
- **Teste:** proposta com `after: []` em duas etapas gera duas frentes prontas ao mesmo tempo; proposta só com textos gera a cadeia atual.

### M3 · `tell` ao vivo para quem já trabalha no seu pedido

- **Onde:** `MultiOrb/DelegationHub.swift:153` (`leaveNotice`), fila de orientação do turno (`SteeringQueue`).
- **Por quê:** um aviso só é lido na próxima mensagem do destinatário. Quem pediu não consegue corrigir o rumo de um pedido em andamento, só esperar ou parar tudo.
- **Como:** quando o destinatário está em turno atendendo um pedido do remetente, colocar o aviso na fila de orientação desse turno, marcado como vindo do colega (a fila de hoje é a da pessoa, então precisa de proveniência própria). Esforço M.
- **Impacto:** correção de rumo sem refazer o pedido.

### M4 · A verificação depois do merge nunca é ligada

- **Onde:** `Teams/TeamHub.swift:334-337`, `Teams/TeamWorkFolders.swift:49` e `:62`.
- **Por quê:** `integrateBranch` aceita `verify`, mas a chamada de produção não passa. Cada etapa é verificada no próprio ramo, nunca o conjunto integrado, até a auditoria final.
- **Como:** decisão sua: ou a missão ganha um comando de verificação opcional, rodado depois de cada merge, ou a documentação deixa de citar a verificação pós-merge.
- **Impacto:** quebra de integração aparece na etapa que a causou.

### M5 · A etapa do líder não gera commit

- **Onde:** `Teams/TeamWorkFolders.swift:38-39`.
- **Por quê:** o líder trabalha no checkout do projeto sem commit, e as mudanças soltas podem fazer o merge dos outros falhar.
- **Como:** commit ao fim da etapa do líder. Risco: levar junto mudanças suas que já estavam no projeto. Só com pedido explícito.

### M6 · Portões mais fracos que o descrito

- **Onde:** `Teams/TeamQualityGates.swift:36-38` e `:111-116`.
- **Por quê:** o primeiro portão passa quando nenhuma verificação rodou e nada foi editado; a proveniência da evidência casa também com o texto do comando, não só com a saída; o revisor pode editar o que revisa.
- **Como:** casar a evidência só com a saída (`entry.output`) é a mudança de uma linha. O restante pede decisão de produto. Baixa prioridade.

### M7 · Pulso: demanda parada pelo teto volta todo dia

- **Onde:** `Pulse.swift` (lido só pelo agente auxiliar, não conferido por mim).
- **Por quê:** uma demanda interrompida pelo teto diário é reentregue sem contador de tentativas.
- **Como:** contar as tentativas e avisar a pessoa depois de três. Confirme no código antes.

### M8 · Orb líder enxerga o que os colegas e os grupos estão fazendo

- **Onde:** `MultiOrb/DelegationHub+Tool.swift:99` (escolha do estado), `:123-126` (`status`), `:130-138` (`groupStatus`), `:104-107` (linhas dos grupos).
- **Por quê:** `orbs list` só detalha a atividade dentro de um turno de grupo ("trabalhando em “…” (pedido de Atlas, há 4 min)"). Fora dele, o Orb vê apenas "livre", "ocupado" ou "espera aprovação do usuário", os grupos aparecem sem estado (só quem orquestra e os membros) e os pedidos que ele mesmo abriu não são listados. Um Orb que coordena outros pelo chat não consegue saber quem está parado, em quê, nem há quanto tempo, e a alternativa é perguntar a cada um com `ask`, o que custa um turno por colega.
- **Como:** reaproveitar o que o turno de grupo já mostra.

```swift
// groupStatus → activity(of:in:), with an optional group: nil lists every open request the Orb has
private func activity(of botID: UUID, in groupID: UUID?, now: Date = .now) -> String {
    …
    let open = requests.values.filter {
        (groupID == nil || $0.envelope.groupID == groupID) && $0.envelope.to.id == botID && Self.isOpen($0.state)
    }.sorted(by: Self.older)
    …
}
// teammatesText: let state = activity(of: orb.id, in: groupID)

// teammatesText, after the teammates: what the Orb itself is waiting for
let mine = openRequests(from: botID).prefix(5).map { "- \(currentName($0.envelope.to)): " + assignmentText($0, now: .now) }
```

  Nas linhas dos grupos, acrescentar se há rodada em andamento e desde quando, com o mesmo dado que a tela do grupo mostra. Decisão sua: fora de um grupo, isso expõe a um Orb os primeiros 60 caracteres do que você ou outro Orb pediu a um colega.
- **Impacto:** o líder acompanha e redistribui o trabalho com uma chamada de `list`, sem gastar turnos dos colegas. Junto com M1 (aviso de ocupado no `ask`) e M3 (`tell` ao vivo), fecha o ciclo ver, pedir e corrigir.
- **Teste:** `list` fora de grupo mostra o pedido em andamento de um colega e os pedidos abertos de quem chamou; Orb sem pedidos continua "livre".

## Ordem sugerida

1. **Times, execução:** C1, C2, C3, C9. Quatro mudanças pequenas no mesmo arquivo, que eliminam o retrabalho falso.
2. **Times, continuidade:** C4, C5, C6, C7, C7b, C8, C10.
3. **Pedidos e grupos:** C11, C12, C13, C14, C15, C16, C17, C18.
4. **Tokens e capacidade:** O1 (com medição), M1 + M8 + O4 (mesmo arquivo), M2.
5. **Resto:** C19–C22, O2, O3, M3–M7.

Cada lote roda só as suítes da área (`scripts/test.sh --filter`), com um teste de regressão por correção, conferido falhando sem ela.

## Considerado e descartado

- **Limites de profundidade, quantidade ou turnos de pedidos:** decisão sua, já fechada.
- **Um irmão lento segura as respostas prontas:** é o desenho (o Orb acorda uma vez, com tudo); a linha do chat já mostra "respondido".
- **A retomada não refaz pedidos aninhados:** documentado.
- **Lista de membros e texto fixo do envelope repetidos a cada turno:** ~200 tokens, em cache; não compensa.
- **Custo do `RequestBackground`:** por desenho; medir antes de mexer.
- **Trocar o orquestrador no meio da rodada:** cai no último texto, sem efeito visível.
- **Nomes duplicados em @menção:** raro.
- **Varredura do pulso a cada tique e custo quadrático no fio:** não medidos; sem evidência de problema.
- **Pequenos dicionários que não são limpos:** crescimento desprezível.

## O que não foi auditado

- `BotSession.finishTurn`/`stop`, `ConversationLedger`, `PermissionPolicy`, o caminho do `ClaudePipe` e as telas.
- `Pulse.swift` por inteiro (só pelo agente auxiliar; M7 depende disso).
- A maior parte do corpo dos testes existentes.
- Nada foi compilado, executado ou medido. Os números de tokens e caracteres são contas sobre os limites do código, não medições.
