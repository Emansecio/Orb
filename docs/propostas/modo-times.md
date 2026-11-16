# Proposta de Arquitetura e Produto — Modo **Times** no Orb

> Documento consolidado a partir de entrevista de design (`/grill-with-docs`) e análise do código atual do Orb.  
> Termos canônicos em [GLOSSARY.md](../../GLOSSARY.md). Decisões arquiteturais em [docs/adr/](../adr/).

---

## 1. Visão geral

O modo **Times** introduz no Orb equipes autônomas orientadas a uma **Missão**, criadas sob demanda a partir de uma ideia em texto livre. Um **Olheiro** — com modelo escolhido por você na própria tela da ideia — analisa o pedido e (quando informada) a pasta do projeto, conversa com você se quiser refinar a estratégia e monta uma proposta editável com papéis, modelos e critérios de pronto.

Ao aprovar a proposta:
1. O **Time** e seus **Integrantes** nascem juntos em uma ala dedicada (**`Times`**) na barra lateral, completamente isolados da lista pessoal de **Orbs** (`AppState.bots`) e dos **Grupos** (`OrbGroup`).
2. Os Integrantes compartilham um **Quadro vivo** estruturado, isolam suas edições (via *worktrees* git ou área dedicada do Time) e trabalham em paralelo e em sequência contínua até cumprir todos os critérios verificáveis da Missão.
3. O rigor "perfeccionista" é garantido por **portões programáticos no motor** (evidência executada após a última alteração, revisor distinto do autor e auditoria final integrada) e por **detecção e recuperação autônoma de loops**, operando por padrão no modo **Sem pedir permissão** (`.bypass`).

### Relação com recursos existentes (`ADR 0001`)

| Conceito | Papel no produto | Ciclo de vida dos membros | Onde fica |
|---|---|---|---|
| **Orb** | Assistente pessoal permanente | Independente | Seção `Orbs` (`AppState.bots`) |
| **Grupo** | Sala manual de 2 a 8 Orbs pessoais já existentes | Os Orbs continuam existindo fora do Grupo | Seção `Grupos` (`AppState.groups`) |
| **Time** | Exército autônomo gerado a partir de uma ideia para uma Missão | **Integrantes** nascem e somem com o Time (salvo promoção explícita para Orb) | Ala `Times` (`AppState.teams`) |

Os **Grupos** permanecem intactos (respeitando `PROD-5`), e **Times** reaproveita ao máximo a infraestrutura já existente em `Sources/Orb/Groups/` e `Sources/Orb/MultiOrb/`.

---

## 2. O que já existe no Orb vs. o que será estendido/criado

| Capacidade | O que já existe hoje | Como o modo **Times** usa ou estende |
|---|---|---|
| Orquestração e mensageria | `GroupHub`, `DelegationHub`, `GroupPrompt`, `GroupThread` | Estender para suportar `OrbTeam` + **Quadro vivo** estruturado e execução contínua multi-frente sem teto automático por turno/execução |
| Quadro compartilhado | `GroupBoard` (`nucleo/identidade.md`, `preferencias/`, `fatos/`, `procedimentos/`, `sessoes/`) | Evoluir para sincronizar 4 blocos estruturados vivos entre turnos paralelos |
| Revisão entre agentes | `GroupReview` (`ReviewVerdict`: `APPROVED` / `CHANGES:`), `GroupPrompt` (até 3 rodadas em prosa) | Tornar programático: revisor obrigatoriamente diferente do autor, checklist por critério `done_when` e auditoria final integrada |
| Evidência de execução | `CompletionWatch`, `TaskPlan` (`done_when` e `checks` com `evidence`), `PlanReminder` | Impor como portão obrigatório antes do fechamento de etapa e antes da integração no checkout principal |
| Detecção de loop | `LoopWatch` (injeta aviso ao modelo e depois `LoopWatch.userNotice`) | Acrescentar assinatura persistente de estagnação/erro entre turnos do Time e recuperação autônoma antes de acionar você |
| Isolamento de arquivos | `WorkFolders` + `GroupHub+WorkFolders` (worktrees `orb/<membro>/<execução>` no git) | Integração ordenada + re-teste no checkout principal; quando não houver git/pasta, usar espaço de artefatos dedicado do Time |
| Permissões | `PermissionMode` (`.ask`, `.auto`, `.readOnly`, `.bypass`) | Padrão `.bypass` ("Sem pedir permissão") para Times, herdado pelos Integrantes, com seletor na criação, toggle em Ajustes e log auditável |
| Retomada de trabalho | `WorkJournal` | Persistir o estado da Missão/frentes em andamento para retomar após reiniciar o app |
| Uso e custos | `UsageReport`, `UsageRecorder`, `UsageSettings` | Registrar consumo por Time/Integrante e agregar por Time na aba Uso sem poluir a lista de Orbs |

---

## 3. Modelo de domínio e persistência (`ADR 0004`)

Todos os tipos persistidos seguem decodificação tolerante (`init(from:)` em `extension` com valores padrão para chaves novas) e conformidade `Sendable` / `Equatable` para concorrência estrita do Swift 6.

### 3.1 Entidades principais

- **`OrbTeam`** (salvo em `AppState.teams`, separado de `AppState.groups` e `AppState.bots`):
  - `id: UUID`, `name: String`, `createdAt: Date`, `updatedAt: Date`
  - `idea: String` (texto original da proposta)
  - `scouterModel: String` (`"provider/model"` usado pelo Olheiro)
  - `projectFolder: String` (opcional; vazio cria espaço dedicado em dados do Time)
  - `permissionMode: PermissionMode` (padrão `.bypass`)
  - `orchestratorID: UUID` (aponta para um `TeamMember.id` do próprio Time)
  - `members: [TeamMember]` (2 a 8 recomendados pelo Olheiro, expansível até 12)
  - `mission: TeamMission`
  - `status: TeamStatus` (`preparing`, `running`, `waitingUser`, `paused`, `completed`, `failed`)
  - `unread: Int`

- **`TeamMember`** (com escopo exclusivo no `OrbTeam`):
  - `id: UUID`
  - `name: String` (único dentro do mesmo Time; dois Times podem repetir `"Revisor"` sem colisão com `AppModel.isOrbNameTaken`)
  - `role: String` (descrição objetiva da responsabilidade)
  - `systemGoal: String` (instruções específicas geradas pelo Olheiro e ajustáveis na criação)
  - `orb: OrbConfig` (aparência/cor distinta gerada pelo Olheiro para leitura rápida na lateral e no fio)
  - `model: String`, `effort: String`
  - `capabilities: Set<Capability>` (`.terminal`, `.browser`, `.computerUse`)
  - `state: TeamMemberState` (`idle`, `working`, `reviewing`, `blocked`, `done`)

- **`TeamMission`**, **`MissionStage`** e **`MissionCriterion`**:
  - `objective: String`
  - `criteria: [MissionCriterion]` (`id`, `description`, `verificationCommandOrRule`, `status`, `lastEvidence`, `verifiedAtCommit`)
  - `stages: [MissionStage]` (`id`, `title`, `ownerMemberID`, `reviewerMemberID`, `dependsOn: [UUID]`, `status`, `retryCount`, `lastFailureSignature`, `blockerNote`)

- **`TeamProposal`** (estado transiente da folha do Olheiro antes de criar o Time):
  - `idea: String`, `scouterModel: String`, `projectFolder: String`, `permissionMode: PermissionMode`
  - `conversation: [ChatMessage]` (histórico curto da conversa de refino com o Olheiro)
  - `draftName: String`, `draftMission: TeamMission`, `draftMembers: [TeamMemberDraft]`
  - `analysisSummary: String` (o que o Olheiro observou na pasta do projeto ao propor o time)

### 3.2 Armazenamento em disco

```text
<ORB_DATA_DIR>/
├── state.json                         # AppState (+ teams: [OrbTeam])
└── times/
    └── <teamID>/
        ├── thread.json                # Fio compartilhado da Missão
        ├── quadro/                    # Memória compartilhada (Quadro vivo + sessoes/)
        ├── membros/<memberID>/        # Histórico individual de execução de cada Integrante
        ├── espaco/                    # Área dedicada quando o Time não usa pasta git
        └── audit.jsonl                # Registro estruturado de comandos/edições em modo autônomo
```

Os *worktrees* git seguem o mesmo padrão de `WorkFolders` (`<dados>/trabalho/<projeto>-<hash>/<integrante>-<execução>`), sendo removidos com segurança (sem `--force`) após o merge confirmado no checkout principal.

---

## 4. Fluxo completo ponta a ponta

### Etapa 1 — Ideia, Olheiro interativo e proposta editável

1. Você abre **"Novo time"** a partir do botão `+` da ala `Times`, do atalho dedicado ou da paleta de comandos (`⌘K`).
2. Na tela inicial da proposta:
   - Escreve a **ideia** em texto livre;
   - Escolhe o **modelo do Olheiro** num seletor nativo (lembrando o último escolhido);
   - Opcionalmente aponta a **pasta do projeto** e ajusta a **permissão base** (padrão: **Sem pedir permissão**, com aviso claro de risco).
3. Ao enviar a ideia, o **Olheiro**:
   - Se houver pasta informada, inspeciona em modo somente leitura sua estrutura, arquivos de instruções (`AGENTS.md`, `README.md`, manifestos de build/testes) e organização do repositório;
   - Gera o **blueprint da proposta**: nome do Time, objetivo e critérios de pronto da Missão, papéis dos **Integrantes** (tipicamente 2 a 8, expansível até 12), escolhendo modelo, esforço, capacidades e cor do orb adequados a cada função (ex.: modelo mais forte para Líder/Arquiteto e Revisor; mais ágil para Explorador/Documentador).
4. **Refino antes de iniciar**:
   - **Edição direta**: nos cartões dos Integrantes, você pode adicionar/remover membro, editar papel, trocar modelo/esforço e mudar nome/critérios da Missão;
   - **Chat em linha com o Olheiro**: um campo de conversa logo abaixo da proposta permite pedir ajustes em linguagem natural (ex.: *"Troque o revisor por um especialista em concorrência Swift, adicione um agente só para `--snapshot` e simplifique para 4 integrantes"*). O Olheiro conversa e devolve a **proposta reformulada** mantendo o contexto do que foi discutido.
5. Um único botão **"Criar e iniciar"** materializa o `OrbTeam`, inicializa os Integrantes, popula o Quadro vivo inicial e dispara o primeiro turno da Missão.

### Etapa 2 — Execução autônoma contínua (`ADR 0002`)

1. Ao contrário de um `Grupo` (que para ao final de um `GroupRun`) ou do `Pulso` (preso a intervalos e teto diário), o **Time** entra em um **laço contínuo em segundo plano** coordenado pelo líder/orquestrador até que:
   - **Todos os critérios de pronto da Missão** sejam aprovados na auditoria final; **ou**
   - Você clique em **Pausar** (ou envie intervenção no fio redirecionando o plano); **ou**
   - Ocorra um **bloqueio físico externo** impossível de resolver sem você (ex.: login/2FA, CAPTCHA, pagamento, credencial ausente no Keychain/ambiente).
2. Frentes sem dependência entre si rodam **em paralelo** via `DelegationHub`. Cada Integrante tem contexto limpo da sua tarefa + o prefácio sincronizado do Quadro vivo.

### Etapa 3 — Contexto compartilhado e isolamento de escrita

- **Quadro vivo em 4 blocos** (injetado de forma compacta e sempre atualizada no prefácio de cada turno ativo):
  1. **Missão e critérios (`done_when`)**: objetivo final e estado atual de cada critério (`pendente`, `em revisão`, `verificado`);
  2. **Mapa de etapas e frentes**: etapa → dono → revisor → dependências → status;
  3. **Contratos e decisões ativas**: interfaces acordadas, nomes canônicos, convenções e mudanças já integradas na branch base — evitando que um Integrante paralelo trabalhe sobre suposições obsoletas;
  4. **Log de verificações e evidências**: últimos comandos/testes executados, commit/arquivo alvo e resultado.
- **Com repositório git**: cada Integrante escreve no seu próprio *worktree*. Quando uma etapa é aprovada na revisão, o líder integra no checkout principal em ordem determinística, resolve conflitos (ou reencaminha ao autor com contexto atualizado), **roda os testes pós-merge no checkout principal** e atualiza o bloco de Contratos do Quadro para os colegas em andamento.
- **Sem pasta ou sem git**: o Time trabalha em `<dados>/times/<teamID>/espaco/` (com subpastas por frente quando paralelo) e consolida entregas, relatórios ou artefatos no Quadro vivo.

### Etapa 4 — Portões de qualidade e saída autônoma de loops (`ADR 0002`, `ADR 0003`)

1. **Portão de evidência pós-edição**: extensão do `CompletionWatch`. Um Integrante executor não pode concluir uma etapa se editou arquivos (`write_file`/`edit_file`) depois do último comando de verificação que passou, nem se o último check falhou.
2. **Portão de revisão independente**:
   - O motor impede que o mesmo `TeamMember.id` que implementou a etapa atue como revisor dela (salvo se o Time tiver apenas 1 executor possível por indisponibilidade explicitada);
   - O revisor recebe os critérios `done_when` da etapa e deve verificar cada item executando os testes/ferramentas aplicáveis antes de responder `APPROVED` ou `CHANGES:` (estendendo `ReviewVerdict`).
3. **Auditoria final integrada**: antes de marcar `TeamStatus.completed`, um revisor/auditor independente verifica o checkout integrado completo (todos os `criteria` da `TeamMission` verdes após o último merge).
4. **Detecção e quebra autônoma de loop/erro**:
   - Estende `LoopWatch` no nível de **etapa + Integrante**: calcula uma assinatura normalizada de ferramenta + argumento + mensagem de erro.
   - Se a mesma assinatura se repetir consecutivamente ou a etapa completar N ciclos de `CHANGES:` sem reduzir os erros (estagnação):
     1. O motor injeta um diagnóstico estruturado obrigando o Integrante a **abandonar a tática atual** (explicando o porquê da repetição e exigindo diagnóstico de causa raiz antes de tentar outro comando);
     2. Se persistir após a troca de abordagem, a etapa é **escalada automaticamente ao líder** para redistribuir para outro especialista, abrir investigação focada ou quebrar a etapa em partes menores;
     3. Somente se o diagnóstico provar **bloqueio externo não-contornável pelo agente** (credencial faltando, login, serviço fora do ar sem fallback local, decisão de produto ausente) aquela frente entra em `waitingUser` com pergunta direta no fio — sem derrubar frentes paralelas independentes.

### Etapa 5 — Pós-conclusão e encerramento

Quando a auditoria final aprova:
1. O Time passa a `completed` e entrega no fio compartilhado o resumo executivo: o que foi entregue, onde está (arquivos/commits/artefatos) e o relatório de verificações/revisões;
2. *Worktrees* já presentes no `HEAD` principal são limpos automaticamente (`WorkFolders`);
3. O Time permanece na ala `Times` como **registro consultável**:
   - Você pode enviar nova mensagem para reabrir o Time sobre o mesmo contexto/Quadro;
   - Pelo menu `⋯` de um Integrante, pode clicar em **"Promover para meus Orbs"** (validando colisão com `AppModel.isOrbNameTaken` e criando uma cópia independente em `AppState.bots`);
   - Ao escolher **"Apagar Time"**, após confirmação no menu `⋯` (vermelho só na confirmação destrutiva, regra `UI-3`), o `OrbTeam`, todos os seus Integrantes, memórias locais, histórico individual e pastas/worktrees temporários são removidos em conjunto.

---

## 5. Experiência visual e interface (`UI-1`–`UI-4`, `TXT-1`–`TXT-4`)

### 5.1 Ala `Times` na barra lateral

- Fica no mesmo nível hierárquico de `Orbs` e `Grupos` em `SidebarView` usando o componente padrão `SidebarFoldHeader` e `SectionPlus` (`+`).
- **Linha do Time** (`SidebarRow`): avatar composto/ícone discreto de equipe, nome do Time, segunda linha curta de status (ex.: `"Executando · etapa 3 de 6"`, `"Aguardando você"`, `"Concluído"`), indicador discreto de atividade ou atenção e botão de expandir os Integrantes.
- **Lista expansível de Integrantes** (logo abaixo da linha do Time, com recuo visual consistente com sublinhas de categorias):
  - Mini orb animado (`LiveBotAvatar` / `SettlingOrb` respeitando pausa por visibilidade), nome, papel curto e estado sutil (`Trabalhando`, `Revisando`, `Pronto`).
  - Clicar no **Integrante** seleciona `.teamMember(teamID, memberID)`.

### 5.2 Área principal e inspetor

| Seleção na lateral | Conteúdo da área central | Inspetor direito (`PanelSection` / abas padrão) |
|---|---|---|
| **Time** (`.team(teamID)`) | Cabeçalho com estado + controles (**Pausar / Retomar**, indicador de permissão), barra de progresso das etapas/portões, fio compartilhado da Missão e compositor para direcionar o líder | Abas: **Missão** (etapas e critérios com evidências), **Integrantes** (papéis, modelos e ação `"Promover para meus Orbs"`), **Quadro** (4 blocos + notas), **Uso** (tokens/custo detalhado do Time), menu `⋯` (pausar, exportar relatório, apagar Time) |
| **Integrante** (`.teamMember(teamID, memberID)`) | Cabeçalho identificando `Time › Integrante (papel)`, barra de retorno rápido para o Time, conversa e execução ao vivo daquele Integrante (ferramentas, diffs, tela ao vivo se aplicável) | Versão enxuta herdada do painel de Orb em modo contextual (modelo, capacidades, histórico de trabalho e ações do Time, sem expor opções de Orb pessoal solto) |

### 5.3 Folha do Olheiro (`NewTeamSheet`)

- Layout com cartões `.card()` / `CardSurface` seguindo `NewGroupSheet` e `NewOrbSheet`:
  - Topo: campo de **Ideia**, seletor de **Modelo do Olheiro**, seletor opcional de **Pasta do projeto** e modo de **Permissão** (padrão `Sem pedir permissão` com nota laranja de aviso de risco `Palette.warn` / regra `UI-3`).
  - Corpo após resposta do Olheiro: resumo da análise da pasta (se houver), bloco editável da **Missão** (`nome` + `critérios`), grade de cartões dos **Integrantes** (adicionar/remover até 12, editar papel, modelo/esforço e cor), e **chat em linha com o Olheiro** para pedir reformas textuais na proposta.
  - Rodapé fixo: **"Cancelar"** e botão primário **"Criar e iniciar"**.

### 5.4 Outras superfícies do app

- **Início (`InicioView`)**: os Times ativos e concluídos recentemente aparecem num bloco ou filtro agregado de **Times** (mostrando status da Missão e atalhos para Pausar/Responder bloqueio), mantendo os contadores de `Orbs` limpos.
- **Uso (`UsageSettings`)**: cada turno de `TeamMember` grava `UsageKey` com contexto de Time para aparecer agrupado por **Time** (e expansível por Integrante dentro do Time), mantendo controle total de custo mesmo sem teto automático.
- **Ajustes (`SettingsView`)**: nova opção discreta na área de colaboração para definir a **permissão padrão de novos Times** (padrão `Sem pedir permissão`) e o **modelo padrão do Olheiro** (usando controles padrão `Picker` / `Toggle`, regra `UI-1`).

### 5.5 Movimento, marcação visual de progresso e arquitetura de componentes

- **Vocabulário único de movimento (`Motion.swift` / `FoldMotion`)**:
  - Seleção na ala `Times` e troca de abas usam `SlidingSelectionFill` (`matchedGeometryEffect`) e `AnyTransition.pageSwap` (quem sai some em `Motion.swapOut`).
  - Expansão da lista de Integrantes sob um Time usa `FoldMotion.animation` e `.adapted(.unfold, reduceMotion:)`; aparição de cartões da proposta do Olheiro e etapas novas usam `Motion.enter` com `Motion.staggerDelay` (teto de 6 itens).
  - Selos de conclusão (`check`, portão aprovado, critério verificado) entram com `.adapted(.mark, reduceMotion:)`; trocas de status em linha (`Trabalhando` → `Revisando` → `Pronto`) usam `.adapted(.swap, reduceMotion:)`; avatares usam `LiveBotAvatar` / `SettlingOrb` respeitando pausa automática por visibilidade.
  - Sob *Reduzir Movimento*, todas as transições recaem automaticamente em `Motion.fade` / `.quiet`, mantendo zero trabalho pesado dentro do `body`.
- **Marcação visual do que já foi feito (na própria Missão)**:
  - Cabeçalho e barra da Missão exibem progresso objetivo (`3 de 6 etapas concluídas · 4/5 critérios verificados`), separando claramente etapas **concluídas com evidência**, **em execução**, **em revisão** e **bloqueadas**.
  - Cada critério e etapa concluída exibe o marcador de conclusão + atalho para a evidência/veredito que o validou.
- **Organização limpa e modular**:
  - Views enxutas e pequenas (subcomponentes dedicados por responsabilidade em `Views/Teams/`, recebendo apenas `teamID`/`memberID` em vez de objetos pesados, usando `.card()` / `PanelSection` e `Typography` / `Palette` existentes).

### 5.6 Conferência visual obrigatória

Todas as novas views devem ganhar casos em `Snapshot.render` (em `OrbApp.swift` / `Views/Teams/TeamSnapshots.swift`) com cenários de exemplo e validação via `--snapshot` nas larguras **`460 pt`** e **`1100 pt`** (com `ORB_DATA_DIR` temporário, regra `UI-4`).

---

## 6. Segurança, riscos e mitigações (`PROD-2`)

1. **Risco de `.bypass` em autonomia contínua**: mitigado por (a) aviso explícito na tela de criação e toggle configurável antes de iniciar e em Ajustes, (b) escopo preferencial de comandos/edições no worktree ou espaço dedicado do Time, e (c) trilha auditável (`audit.jsonl`) visível no inspetor e no histórico do Integrante.
2. **Risco de custo ilimitado sem teto automático**: mitigado por (a) visibilidade em tempo real de tokens/custo no cabeçalho e no inspetor do Time, (b) botão imediato de **Pausar** na lateral e no cabeçalho, e (c) detector de estagnação (`LoopWatch` estendido) impedindo queima cega no mesmo erro.
3. **Risco de fechamento do app no meio da Missão**: mitigado por `WorkJournal` persistindo etapas em aberto para oferecer retomada limpa ao reabrir o Orb.
4. **Risco de regressão nos Grupos existentes**: mitigado mantendo `OrbGroup`, `NewGroupSheet` e `AppState.groups` sem remoção ou alteração semântica (`PROD-5`).

---

## 7. Plano de implementação incremental e registro de progresso

Cada caixa abaixo deve ser marcada (`[x]`) assim que concluída, compilada em Debug + Release e validada na suíte filtrada correspondente (`TESTE-4`–`TESTE-6`) e por `--snapshot` em `460` e `1100 pt`:

### Fase 1 — Domínio, persistência e ala `Times` na lateral
- [x] Criar `OrbTeam`, `TeamMember`, `TeamMission`, `MissionStage`, `MissionCriterion` com decodificação tolerante e `AppState.teams`.
- [x] Isolar armazenamento em `times/<teamID>/` e regras de unicidade de nomes por escopo do Time (sem tocar em `AppModel.isOrbNameTaken` global até eventual promoção).
- [x] Estender `SidebarSelection` (`.team`, `.teamMember`), criar a seção colapsável `Times` em `SidebarView` (com `SidebarFoldHeader`, `SlidingSelectionFill`, expansão animada de Integrantes via `FoldMotion` e avatares `LiveBotAvatar`/`SettlingOrb`).
- [x] Adicionar snapshots da lateral (`460` e `1100 pt`) e testes unitários de modelo/persistência/sidebar.

### Fase 2 — Olheiro interativo e criação conjunta
- [x] Implementar `TeamScouterRunner` (leitura segura da pasta quando informada, geração da `TeamProposal` e chat de refino mantendo contexto para reformar a proposta).
- [x] Criar `NewTeamSheet` com componentes modulares `.card()`, seletor de modelo do Olheiro (lembrando o último), grade editável de Integrantes (2–8 até 12), toggle/aviso de `.bypass` e chat em linha com o Olheiro.
- [x] Implementar criação atômica do Time, **"Promover para meus Orbs"** (validando `isOrbNameTaken`) e **"Apagar Time"** com remoção conjunta.
- [x] Validar snapshots (`460` e `1100 pt`) e testes do fluxo do Olheiro e ciclo de vida.

### Fase 3 — Quadro vivo, espaço sem git e integração ordenada
- [x] Estender `GroupBoard` para sincronizar os 4 blocos vivos (`Missão e critérios`, `Mapa de etapas`, `Contratos e decisões`, `Log de verificações`) no prefácio dos turnos.
- [x] Integrar `WorkFolders` para merge sequencial + re-teste no checkout principal pelo líder e criar fallback em `times/<teamID>/espaco/` para Times sem pasta/git.
- [x] Adicionar testes de propagação de contratos, isolamento de escrita e limpeza de *worktrees* pós-conclusão.

### Fase 4 — Motor contínuo, portões de perfeccionismo e anti-loop
- [x] Implementar laço contínuo autônomo em segundo plano (`TeamHub` sobre `GroupHub`) com `WorkJournal`, **Pausar / Retomar** imediato e trilha `audit.jsonl`.
- [x] Implementar portões programáticos: `CompletionWatch` exigindo check verde após a última edição, bloqueio de auto-revisão (`revisor != autor` em `ReviewVerdict`) e auditoria final integrada antes de `completed`.
- [x] Estender `LoopWatch` com detecção de estagnação entre turnos, injeção de troca de abordagem, escalonamento automático ao líder e pausa isolada (`waitingUser`) apenas para bloqueios físicos externos.
- [x] Cobrir regressões com testes simulados (falha repetida, edição sem re-teste, auto-revisão negada, pausa/retomada e bloqueio externo).

### Fase 5 — Visões do Time e Integrante, `Início`, `Uso`, `Ajustes` e polimento final
- [x] Construir `TeamChatView`, `TeamMemberChatView` e `TeamPanel` (`Missão` com marcação visual clara do que já foi feito, `Integrantes`, `Quadro`, `Uso` e menu `⋯`) usando `Motion` / `AnyTransition.adapted`.
- [x] Agregar Times em `InicioView` e `UsageSettings`, e expor preferências padrão em `SettingsView`.
- [x] Rodar revisão final de espaçamento, textos pt-BR (`TXT-1`–`TXT-4`), `swift build`, `swift build -c release`, suítes filtradas da área e conferência visual `--snapshot` (`460` e `1100 pt`).
