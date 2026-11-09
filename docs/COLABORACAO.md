# Orbs juntos (`MultiOrb/`, `Groups/`)

Parte do mapa do código: veja [ARQUITETURA.md](ARQUITETURA.md) para a visão geral.


Fora de `ToolBox.all`: `MultiOrbOffering` (`AppModel.multiOrbOffering`) decide por turno quais destas o Orb recebe, e a ponte `ToolContext.orbs`
leva a chamada ao `DelegationHub`. `orbs` (`ask`, `tell`, `list`), `group_create`, `group_edit`, `group_recall`, `orb_propose` e `orb_delete`.
- **Pedidos e grupos.** `DelegationHub` (pedidos, cadeias, filas, recusas) e `GroupHub` (a run de cada grupo, o fio). Um grupo acionado por
  outro devolve a resposta ao turno do grupo que pediu, e `ChainState.groupsVisited` barra o laço grupo → grupo.
- **Preferências** (`AppModel+MultiOrbSettings.swift`, todas `UserDefaults`, ligadas por padrão): `orbsCanTalk`, `orbsCanStartGroups`,
  `orbsActOnOwn` (cria e aciona grupos e propõe Orbs fora do chat próprio: rotina, pedido, turno de grupo, pulso), `orbsCanManageGroups`
  (`group_edit` e `orb_delete`) e `orbsCreateWithoutAsking` (`orb_propose` cria na hora, sem teto de quantidade, e a linha do criador
  oferece `undoCreation`; sem cartão, um papel igual ao de um colega é recusado, `OrbCreationSupport.sameRole`). Apagar grupo ou
  Orb, e tirar o membro que desfaz um grupo de dois, passam por `ToolContext.confirm` (`ApprovalGate.confirm`, `onlyPerson`), nunca
  pelo `confirmed` do modelo; o sim leva os ids do plano (`ConfirmedEdit`, `expect_group`/`expect_orb`). Num turno `unattended` o
  `confirm` é nil e a ferramenta usa `*_later`: uma linha `deletionAsked` no chat (`AppModel+PendingDeletion.swift`, `DeletionAsk`),
  respondida por `answerDeletion`, que vira `deletionAnswered` e chega ao Orb pelo `SinceLastTurn` (`<user_decision>`). Como as
  rodadas que pedem (rotina, pulso) não leem as linhas do chat, um Manter fica guardado (`keptDeletions` nas preferências, 30
  dias, apagado com o Orb ou ao redefinir) e o `*_later` seguinte responde "already chose to keep it". `unattended` vale também para o turno de grupo de cadeia
  que nenhuma pessoa começou (`DelegationHub.isUnattended`: origem `.pulse` ou `.routine`); o chat acordado por uma resposta é
  da pessoa e fica com cartão e steering.
- **Pulso** (`Pulse.swift`). `pulseTick` roda no agendador: com `pulseIsOn` (`pulseEnabled && orbsActOnOwn`), passado `pulseMinutes`, percorre
  os Orbs em rodízio (`PulseState.lastOrb`), pula o que não tem demanda nova e começa em `beginPulse`. A demanda sai de `Pulse.demands`
  (pura, sem modelo nem disco): plano parado há `planIdle` em qualquer conversa do Orb (`PulseState.plans`, gravado por `notePlan`
  em `BotSession.write` e ao estacionar o chat, até 3 por Orb; tarefa pausada não conta); rotina cuja última execução recente
  falhou ou pediu atenção (a chave junta a sequência de falhas iguais); pedido do Orb que falhou fora de grupo; turno falho de grupo
  que ele orquestra; aviso (`tell`) não lido há `noticeIdle` (`PulseState.notices`, de `notePulseNotice`). Trabalho com
  `envelope.pulseRun` nunca é demanda. As chaves vão no `PulseRun` e só são entregues no fim (`settleDemands`): falha conta em
  `PulseState.failures` e entrega após `failureLimit`; `delivered` guarda só chaves cujo trabalho ainda existe (teto 200).
  Com um plano entre as demandas, `beginPulseInChat` roda na conversa dele (`prepareTurn`, `BotSession.pulseInChat`,
  `SendOrigin.pulse`, linha `pulseResumed`, turno `unattended`; no `WorkJournal` só a entrada `.pulse`, descartada na abertura,
  nunca a tarefa do chat; o Orb com uma tarefa cortada esperando a retomada (`WorkJournal.awaitsChatResume`) fica fora do
  pulso até ela; um pedido do pulso não é reenviado na abertura com o pulso desligado ou o teto gasto; o que a pessoa escreve nesse turno espera por ele, `canSteer` falso, e vira um turno dela; fechar o
  app no meio não entrega as demandas); sem plano, um side run `.pulse`
  (`BotSession.sideKind`) com o `RoutineBackground` do chat. Pedido feito no side run leva `servingPulse`: `finishPulse` segura o
  run (`DelegationHub.holdPulse`, `waitingRoutines` com `pulse`) e a resposta o retoma (`resumePulse`); sem espera, vai ao chat.
  **Linhagem:** `AppModel.pulseLineage(of:)` é a fonte única de "é trabalho do pulso" (side run, `pulseInChat`, cadeia de origem
  `.pulse`, pedido servido com `envelope.pulseRun`), usada por `pulseCharge`, `DelegationHub.newChain`/`queueGroupTurn`/`submit`
  (que recusam com `pulseBudget` depois do teto) e `stopPulseWork`. Fronteira com a pessoa: a mensagem dela num grupo que o pulso
  pôs para trabalhar passa a cadeia a `.group` (`handToPerson`: o trabalho é dela, sem teto, inclusive os turnos já em curso, e o
  diário retoma a rodada como dela); a retomada do app (`GroupHub.resume`, `fromPerson` falso) não conta como mensagem dela, e um pedido do pulso a um grupo que ela já pôs para
  trabalhar entra na rodada dela, sem contar no teto (decisão: a rodada é uma só). O teto diário (`pulseDailyTokens`, `PulseState.tokensToday`)
  conta tudo da linhagem; ao estourar, ou ao desligar o pulso ou `orbsActOnOwn`, `stopPulseWork` cancela as cadeias, os turnos e os
  pulsos que esperam e grava `pulseStopped` (`detail == OrbEvent.pulseOff` quando foi desligado); um grupo parado pelo teto grava
  `groupStopped` com `detail == OrbEvent.budgetStop`.

