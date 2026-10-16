# Autonomia dos Orbs — análise e proposta (13/10/2026)

## Como foi feita

Cinco análises em paralelo, somente leitura, pelos agentes Codex (GPT-6.1-Sol e GPT-6-Luna), sobre o checkout `15bdb08`:
A) núcleo do loop do motor (Sol); B) ferramentas (Luna); C) memória, rotinas e aprendizado (Luna); D) vários Orbs (Sol);
E) estado da arte com pesquisa na web (Luna). As afirmações centrais foram conferidas no código antes desta consolidação.

## Conclusão

O Orb já tem as peças de um agente longo: até 100 passos por turno (150 em rotina), ledger que sobrevive à compactação,
`LoopWatch`, `CompletionWatch`, jobs em segundo plano que retomam o turno, rotinas com meta, delegação assíncrona e
grupos com orquestrador. O que falta não é mais limite nem mais prompt; são três fundações, apontadas por todas as frentes:

1. **A tarefa não existe como objeto.** Plano, critérios de aceite e próximo passo vivem só no texto da conversa;
   o registro de progresso é escrito apenas quando o limite de passos acaba (`Engine/ToolDigest.swift:113`).
2. **"Terminei" não exige prova.** O turno acaba quando a resposta não chama ferramentas; o `CompletionWatch` só
   contradiz o último build/teste que falhou ou um arquivo ausente (`Engine/CompletionWatch.swift:10`). O grupo se
   declara concluído quando fica ocioso (`Groups/GroupHub.swift:330`). A meta da rotina pausa quando o próprio relatório
   escreve "Progresso … concluída" (`RoutineGoal.swift:131`).
3. **O trabalho para quando um limite acaba ou o app fecha.** No passo 100 o turno pausa e espera "continua"
   (`Engine/AgentEngine.swift:349`); o orçamento do grupo pausa com um cartão "Continuar?" (`Groups/GroupHub.swift:238`);
   jobs terminam quando o app sai (`Engine/Tools/BackgroundJobs.swift:4`); delegações e execuções de grupo em voo vivem
   só em memória (`Groups/GroupRun.swift:3`); o agendador roda dentro do app (`AppModel.swift:423`).

## Proposta, em ordem

### Fundação (P0) — fazer juntas, uma depende da outra

**1. Tarefa durável (`TaskPlan`).** Objeto persistido por conversa/rotina/grupo: objetivo, etapas com estado
(pendente, em andamento, feita, bloqueada), dependências, critérios de aceite, evidências, decisões e próximo passo.
Uma ferramenta para o Orb criar e atualizar o plano durante o trabalho (não só no fim); o plano entra no prompt de cada
passo em forma curta e sobrevive a compactação e reinício. Ativar só em trabalho longo, para não virar burocracia.
Onde: `Models.swift`, `Engine/ConversationLedger.swift`, `Engine/TurnPrompt.swift`, `Engine/SystemPrompt.swift`,
nova ferramenta em `Engine/Tools`. Esforço G. Verificar: tarefa de dez etapas atravessa compactações e reinício com as
pendências certas. (A1, B1, C1, D1, E)

**2. Conclusão por evidência.** Cada critério de aceite liga-se a uma evidência (check que passou, arquivo, observação).
Um check passa a valer só para a versão atual: edição relevante depois dele exige revalidação. Grupo ocioso dispara a
avaliação do orquestrador contra os critérios, não o "concluído" automático; meta de rotina só conclui com evidência,
e meta sem avanço em N execuções vira "estagnada". Onde: `Engine/CompletionWatch.swift`, `Engine/AgentEngine.swift`,
`RoutineGoal.swift`, `Groups/GroupHub.swift`, `Groups/GroupRun.swift`. Esforço M. Verificar: falha → correção → check
obrigatório; "concluída" sem evidência não pausa a rotina; membro que entrega pela metade faz o grupo replanejar.
(A3, C2, D1, E)

**3. Continuar sozinho enquanto houver progresso.** O passo 100 vira checkpoint e um novo segmento da mesma tarefa começa
sem "continua"; o orçamento do grupo renova sozinho quando há progresso verificável no plano (etapa nova feita,
evidência nova). Tetos totais de tempo e tokens por tarefa e parada por estagnação (segmento sem avanço) substituem o
cartão de cada janela. Permissões "nesta tarefa" passam a valer entre segmentos (`AppModel+Approvals.swift:152`).
Onde: `Engine/AgentEngine.swift`, `BotSession+Turn.swift`, `Groups/GroupHub.swift`, `MultiOrb/OrbGroup.swift`. Esforço M/G.
Verificar: tarefa com mais de 250 passos termina sem intervenção; tarefa que gira em falso para com resultado parcial
útil. (A2, D7)

### Execução contínua (P1)

**4. Erros que ensinam a se corrigir.** Resultado de ferramenta com categoria (argumento inválido, pré-condição,
transitório, bloqueio externo), "repetir é seguro?" e alternativa sugerida; o `catch` genérico deixa de reduzir tudo a
`localizedDescription` (`Engine/AgentEngine.swift:916`). `LoopWatch` passa a medir progresso (navegação ou polling
que não muda nada) e, após repetição, exige hipótese e caminho diferente. Esforço M. (A5, B5)

**5. Perguntar sem parar tudo.** Pergunta opcional vem com a hipótese que o Orb vai seguir e o trabalho independente
continua; só as etapas que dependem da resposta esperam. Onde: `Engine/Tools/AskUserTool.swift`, `Engine/SystemPrompt.swift`,
`TaskPlan`. Esforço M. (A6)

**6. Esperar por eventos.** Tarefa e rotina podem aguardar um evento — job terminou, arquivo chegou na pasta, e-mail ou
lembrete novo por conector — e acordam uma vez, com o motivo registrado. Jobs ficam ligados à etapa da tarefa; sai o
teto fixo de três retomadas (`AppModel.swift:1712`). Onde: `AppModel.swift`, `AppModel+Schedule.swift`,
`Engine/Tools/BackgroundJobs.swift`, observador local novo. Esforço G. (A4, B3)

**7. Sobreviver ao fechamento do app.** Checkpoints nos marcos (inclusive "ação iniciada, resultado desconhecido"),
delegações/filas/execuções de grupo persistidas, jobs com estado e log em disco; ao reabrir, reconciliar com o mundo
(arquivo existe? processo vivo?) antes de repetir algo, e rodar uma vez as rotinas que venceram com o app fechado.
Onde: `BotSession+Turn.swift`, `Store.swift`, `MultiOrb/DelegationHub.swift`, `Groups/GroupRun.swift`,
`Engine/Tools/BackgroundJobs.swift`. Esforço G. (A7, B2, C6, D2, E)

**8. Desfazer edições do Orb.** Snapshot dos arquivos antes de cada `write_file`/`edit_file` da tarefa, para voltar a
um estado que funcionava (hoje "Refazer" só corta o histórico, `Rewind.swift:68`). Dá margem para o Orb arriscar mais
sozinho. Esforço M. (E)

### Aprender com o uso (P2)

**9. Skills que se formam sozinhas.** A revisão de skills passa a cobrir rotinas e turnos incompletos (hoje só turnos
longos concluídos, `AppModel+SkillReview.swift:38`); a skill é testada num exemplo e promovida após repetição
consistente, com versão e reversão. Decisão do dono: ativar sem aprovação ou manter o cartão. Esforço M/G. (B6, C3, E)

**10. Preferências a partir de correções.** Correção explícita ou repetida ("não, usa X") vira preferência com origem,
atualizando a existente e com desfazer. Onde: `Memory/MemoryIntent.swift`, `Memory/MemoryBank.swift`,
`AppModel+MemoryConsolidation.swift`. Esforço M. (C4)

**11. Propor rotinas ao perceber recorrência.** Pedido da mesma classe repetido vira proposta de rotina (ou ajuste de uma
existente), sem duplicar. Esforço G. (C5)

### Equipes de Orbs (P2)

**12. Escolher a quem delegar pela competência real:** `orbs list` com skills, ferramentas disponíveis, fila e entregas
verificadas, não só o papel cortado em 80 caracteres (`MultiOrb/DelegationHub.swift:675`). Esforço M. (D4)

**13. Revisão cruzada como etapa:** entrega relevante passa por outro Orb com os critérios e os artefatos (não só os
6.000 caracteres do envelope); defeito volta ao autor. Esforço M. (D5)

**14. Especialista e substituto sob demanda:** criar especialista durante o trabalho do grupo sem cartão obrigatório,
reaproveitando um compatível; redistribuir quando o alvo falha ou está ocupado; justiça entre pedidos, respostas e
rotinas na fila. Esforço M/G. (D3, D6)

Menores: leitura paginada de saídas grandes por identificador também para Orbs sem `read_file`, e não expirar saídas
ligadas a tarefas ativas (`Engine/ContextWindow.swift:632`, `Engine/ToolOutputSpill.swift:7`). (B4)

## O que não fazer

- Só subir limites de passos, de contexto ou adicionar mais Orbs: sem plano, aceite e retomada, isso aumenta custo e
  conversa sem garantir entrega.
- Gravar toda falha como memória: mistura incidente com procedimento e piora o aprendizado.
- Tentar automatizar login, 2FA e CAPTCHA: continua com a pessoa.

## Riscos transversais

Plano e checkpoint desatualizados em relação ao mundo (conferir antes de marcar feito); repetir efeitos externos ao
retomar ou redistribuir (registrar ações concluídas e só repetir o que for seguro); consumo crescente com continuação
automática (tetos totais e parada por estagnação). Introduzir em etapas e medir.

## Fontes externas (frente E)

- Anthropic — [effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents),
  [harness design for long-running apps](https://www.anthropic.com/engineering/harness-design-long-running-apps),
  [context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- Manus — [context engineering lessons](https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus)
- Cline — [checkpoints](https://github.com/cline/cline/blob/main/docs/core-workflows/checkpoints.mdx),
  [task management](https://github.com/cline/cline/blob/main/docs/core-workflows/task-management.mdx)
- Devin — [Devin managing Devins](https://cognition.com/blog/devin-can-now-manage-devins)
- Cursor — [subagents](https://prod.cursor.com/docs/subagents), [long-running agents](https://forum.cursor.com/t/introducing-long-running-agents/151696)
- Jules — [proactive updates](https://blog.google/innovation-and-ai/technology/developers-tools/jules-proactive-updates/)
