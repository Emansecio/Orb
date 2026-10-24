# Revisão de UI/UX: componentes e coexistência (23/10/2026)

Levantamento de leitura sobre `72c9bcf`. Quatro recortes foram lidos em paralelo: casca e Ajustes, chat e compositor,
painel do Orb com multi-Orb e grupos, e o Espaço de trabalho (Rotinas, Conectores, Skills). Os achados de maior peso
foram reconferidos no código pela sessão principal e estão marcados **[conferido]**.

Limites: nada foi compilado nem visto na tela (sem `--snapshot`, que rouba o foco). Larguras, contraste real,
truncamento e VoiceOver ficam como **suspeita** até uma captura. Não repete o que as revisões de 14/10
(`REVISAO-INTERFACE`) e 21/10 (`REVISAO-FLUIDEZ`) já resolveram.

Notação: impacto **A/M/B**, esforço **P/M/G**. Os caminhos são relativos a `Sources/Orb/`.

## Andamento

**23/10.** O bloco de segurança de decisão está feito (itens 1, 3, 4 e 12, e "Conectar assim mesmo", em `97c510b`):

- **⌘↩ no compositor:** com um pedido aberto, ⌘↩ no compositor não faz mais nada. A dica pede "responda ao pedido acima". Parar de propósito continua pelo botão de parar e pelo "Parar e enviar" da bolha, que dizem que recusam.
- **Apagar Orb:** o diálogo agora nomeia os grupos que serão desfeitos. Os botões passam a dizer "Apagar tudo, inclusive a memória" e "Apagar, guardando a memória".
- **Objetivo do grupo:** grava também ao sair do campo e ao fechar o quadro.
- **"Conectar assim mesmo":** sai do vermelho. O `SheetFooter` ganhou `leadingIsDestructive`.

**24/10: parecer.** Cada sugestão em aberto foi reconferida no código sobre `97c510b`, só por leitura, e ganhou um
**Parecer** com veredito, lugar exato, a mudança de menor risco, o que pode quebrar e o esforço. Os vereditos são
**Concordo**, **Em parte**, **Discordo** e **Já resolvido**. Resultado:

- **Um achado mais grave que o relatório viu.** Hoje, o pedido de permissão de um membro de grupo não aparece em tela nenhuma (item 2).
- **Seis sugestões partiam de um fato desatualizado ou errado e saem da fila.** São elas: confirmação de Editar/Refazer, anel do plano, "Pulada", folha de 820 pt, ⌥⌘G com menos de 2 Orbs e "Desligado com dois sentidos".
- **Três trocas de vocabulário tocam texto enviado ao modelo ou testes que fixam o texto.** Os pareceres dizem quais.

A seção 4 traz a ordem revista.

**24/10: implementação.** As fases 2 a 8 da seção 4 foram feitas, de `90f0e7f` a `a4951ee`. Cada pacote
seguiu o parecer, com as diferenças abaixo:

| Fase | Commits | Diferenças em relação ao parecer |
|---|---|---|
| 2. Pedidos de membro no grupo | `c5adf3d` | O cartão mostra o avatar do membro na calha. Propostas de Orb não entram na barra. |
| 3. Casca | `90f0e7f`, `1fd481d`, `518a88a`, `42ba264` | Conversas vazias ("Nova conversa") não entram na paleta. O subtítulo "Pasta de trabalho" virou "Pasta de <Orb>". |
| 3. Painel do Orb | `afdec17`, `c35a359`, `d4cbf93` | O aviso de nome é uma função pura (`NameCheck`). O anel de foco do `InlineLinkNote` fica visível. |
| 3. Grupo | `5d43694`, `f9925a8`, `cfa678f` | Sem `deleteGroupAndLeave`: o `deleteGroup` já tira a seleção do grupo. `.refused` continua laranja. |
| 3. Chat e compositor | `b1e7537`, `d7137be`, `aa71790`, `1729c3f` | O menu do botão de enviar só aparece quando o Orb aceita direcionar. A tela ao vivo tem uma variante de rótulos curtos. |
| 4. Ajustes e vocabulário | `e15c575`, `d974bdc`, e as trocas nos pacotes de cada tela | "Propor skills" e "Resumir conversas longas" também foram para a aba Orbs. O `rawValue` da aba antiga continua abrindo "Acesso ao Mac". |
| 5. Wizard | `8ef5880`, `b9b3fa2` | O papel também conta como trabalho a perder. O texto colado no painel de importação não conta. |
| 5–6. Skills | `99c57d0` | A linha abre o editor por `onTapGesture` com ação de acessibilidade, porque botão aninhado em `Button` falha no macOS. |
| 6. Rotinas e Conectores | `c75a11d`, `07db17d` | Cabeçalho por Orb e Orb no cartão aparecem juntos (conferir se fica redundante). "Resolver" na galeria continua abrindo o editor. |
| 8. Resumo do plano | `3a1c627` | Usa `.event(OrbEvent)`, que não vai ao histórico do modelo, e não um `Kind` novo. |
| 8. Anexos no grupo | `7d26b2e` | A imagem vai ao orquestrador ou aos mencionados, só no turno que recebe a mensagem. O repasse entre Orbs fica de fora (faltaria um campo no `OrbEnvelope`). |
| 7. Tokens | `f29017d`, `14cd52c`, `4419fa2`, `a4951ee` | Ficaram 153 raios em `Radius`, 318 fontes em `Typography`, mais `chipFill`, `Shadow.popover` e `canvasHex`. Nenhum valor mudou, exceto duas sombras de 0,3 para 0,35. Pesos, `design` e raios fora de 8–14 seguem literais. |

Ficaram de fora, pelo parecer:

- QuickAsk com grupos;
- "Abrir no assistente" no cartão de proposta;
- trocar o prefixo "Não deu certo";
- mudar a largura mínima do painel.

Debug e release compilam na `main`. Os testes filtrados das suítes tocadas passam (2.245 testes em 295 suítes). Nenhuma tela desta rodada foi conferida com `--snapshot`, e a suíte completa não rodou.

---

## 1. As 12 que eu atacaria primeiro

| # | Proposta | Onde | Imp. | Esf. |
|---|---|---|---|---|
| 1 | **Feito.** Com um pedido de permissão aberto, ⌘↩ digitado no compositor **recusa** o pedido e envia, e só uma dica de 11 pt avisa (escondida do VoiceOver). O botão de enviar deve passar a dizer "Recusar e enviar", ou o ⌘↩ deve ser bloqueado nesse caso até o usuário escolher. **[conferido]** | `ApprovalKeyboard.swift:3-22`, `ComposerView.swift:350-361, 802-811` | A | M |
| 2 | No chat de grupo, pedidos de permissão não aparecem: a linha `.approval` vira `EmptyView`. A faixa só diz "X está esperando você" e não é clicável. Ela precisa virar um botão que abre o cartão do Orb, ou o cartão precisa entrar no fio do grupo. **[conferido]** | `GroupChatView.swift:235`, `GroupPresenceStrip.swift:39` | A | M |
| 3 | **Feito.** Apagar um Orb desfaz os grupos de 2 membros (conversa e quadro somem), e o diálogo só fala em "a participação em N grupos". Ele precisa avisar "o grupo X será desfeito". **[conferido]** | `AppModel+Groups.swift:204`, `DeleteOrbDialog.swift:17` | A | P |
| 4 | **Feito.** Os botões "Apagar com a memória" e "Apagar e guardar a memória" são ambíguos, porque "com" pode ser lido como "levando junto". Troque por "Apagar tudo, inclusive a memória" e "Apagar, guardando a memória". **[conferido]** | `DeleteOrbDialog.swift:117-120` | A | P |
| 5 | O wizard de Novo Orb descarta minutos de conversa sem confirmar (Esc ou Cancelar), e ao bater o limite pede "toque em Criar Orb" mesmo sem nome, o que é um beco sem saída. **[conferido]** | `SheetsAndSettings.swift:234`, `WizardChatView.swift:120`, `WizardFooter.swift:15,29` | A | M |
| 6 | Skills propostas pelo Orb só se abrem pelo aviso no chat. Se o aviso passa, a proposta fica órfã. Falta uma seção "Aguardando sua revisão (N)" na página Skills. **[conferido]** | `AppModel+SkillReview.swift:46-55`, `SkillsView.swift` | A | M |
| 7 | O rodapé da lateral tem Rotinas, Conectores, Skills e Ajustes só como ícones, sem rótulo nem título de seção. Conectores e Skills quase não são descobertos. **[conferido]** | `SidebarView.swift:119-133` | A | P |
| 8 | A paleta ⌘K promete "um Orb, uma conversa ou uma ação" mas não indexa conversas, e também não tem "Ajustes". **[conferido]** | `CommandPalette.swift:176, 95-153` | A | M |
| 9 | Ajustes → Geral está sobrecarregada (perfil, cerca de 8 interruptores, Orbs, memória, dados e cerca de 30 linhas de atalhos que repetem o sheet de atalhos). Separe em "Geral", "Orbs" e um botão "Ver atalhos". | `SettingsView.swift:157-297` | A | M |
| 10 | "Refazer" só existe no hover: falta no menu de contexto e nas ações de acessibilidade da resposta. **[conferido]** | `TranscriptViews.swift:434-443` | A | P |
| 11 | O compositor do grupo está bem abaixo do individual: sem Esc para fechar menções, sem Tab, sem foco inicial, sem parar embutido e sem anexos (`attachmentCount` existe, mas nunca é desenhado). | `GroupComposer.swift:33-47`, `GroupMessageBubble.swift:158` | A | M |
| 12 | **Feito.** O objetivo do grupo é multilinha mas grava só no ↩. Sair do campo perde o texto, e ↩ não quebra linha. **[conferido]** | `GroupBoardView.swift:38-44` | A | P |

### Parecer dos itens em aberto

**Item 2: pedido de permissão no grupo.** **Concordo, e o caso é mais grave do que a tabela diz.** **[conferido]**

- **O caminho do cartão.**
  1. No turno de grupo, o membro roda numa conversa lateral: `startSideRun` faz `parkedChat = chat; conversation = own` (`BotSession+Conversation.swift:195`).
  2. O cartão nasce nessa conversa.
  3. O chat do Orb mostra `parkedChat ?? conversation`, isto é, o chat parado, sem o cartão.
  4. O fio do grupo descarta `.approval` (`Views/Groups/GroupChatView.swift:235`).
  5. O banner, o "Abrir o app" do painel da barra de menus e `showApprovalOwner` levam a `.group(id)` (`AppModel+Approvals.swift:57`).
- **Na prática:** um pedido arriscado, uma pergunta ou uma passagem de controle de um membro só pode ser respondido pelo painel da barra de menus, que lista os pedidos pendentes. Sem resposta, o Orb desiste em 24 h.
- **Código morto:** o ramo `case .group` em `AppModel+Approvals.swift:68-72` nunca roda, porque a linha 57 retorna antes.
- **Doc desatualizada:** `docs/REVISAO-GRUPOS-2026-10-16.md:29` diz que os cartões aparecem na tela do grupo.
- **Onde:** `GroupConversation.body`, em `Views/Groups/GroupChatView.swift:76-77`, entre `GroupThreadView` e `GroupPresenceBar`.
- **Como:** uma barra fixa de cartões acima da faixa de presença, sem mexer no fio:
  1. **A barra.** Uma `GroupApprovalBar(group:live:)` percorre `live.waiting`. Para cada id, lê `model.pendingApprovals(of:)`, que já enxerga a conversa lateral (`AppModel+Approvals.swift:13`).
  2. **Os cartões.** Desenhe `ApprovalCard(request:botID:)` (`Views/TranscriptViews.swift:1511`) ou `QuestionCard`, com o mesmo `switch` de `TranscriptViews.swift:58-70`. O grupo não tem proposta de Orb (`propose: false`).
  3. **Muitos cartões.** Embrulhe em `ViewThatFits { cards; ScrollView { cards }.frame(maxHeight: 300) }`, como o `PendingApprovalsSection` (`Views/QuickAskView.swift:449`).
  4. **A decisão.** `AppModel.decide(...)` já grava na conversa lateral, e não precisa mudar.
  5. **Teclado.** O ⌘↩/Esc dos cartões exige `model.selectedBot?.id == botID` (`TranscriptViews.swift:1889`, `QuestionCard.swift:182`), então no grupo eles não respondem ao teclado. Dê aos dois cartões um `showsKeyHints: Bool = true` e passe `false` na barra, para o cartão não prometer tecla que não funciona. Não mexa em `showsApprovalKeys`.
  6. **VoiceOver.** Anuncie com `announceForAccessibility` quando `live.waiting` crescer. O `announceApproval` só fala pelo Orb selecionado.
  7. **Limpeza.** Apague o ramo morto e corrija a frase da revisão de 16/10.
  8. **Opcional.** A faixa de presença vira um botão que rola até a barra.
- **Risco:**
  - `GroupRunTests.swift:332` (`selection == .group`) continua valendo.
  - Leia `conversation.items` só quando `waiting` não estiver vazio, para não redesenhar o grupo a cada token.
  - A barra encolhe o fio, e o `ApprovalCard` usa recuo de 44 pt pensado para o chat. Confira com `--snapshot` em 460 e 1100 pt: o `case` novo é um grupo com um membro esperando.
  - Teste novo: um pedido aberto numa conversa lateral aparece em `pendingApprovals(of:)` e é decidido por `decide`.
- **Esforço:** M. É o próximo da fila (seção 4).

**Item 5: wizard descarta e trava.** **Concordo nas duas metades, com duas correções de referência.**

- **De onde vem o descarte.** O descarte vem de `cancel: { dismiss() }` (`Views/SheetsAndSettings.swift:220`, assistente, e `:222`, formulário). A linha 234 é só o `.onDisappear { wizard.cancel() }`. O Esc é o `.cancelAction` do "Cancelar" em `WizardFooter`.
- **Quando trava.** O beco sem saída só existe com `hitLimit && !draft.canCreate`, ou seja, ao bater as 30 mensagens (`Wizard/WizardRunner.swift:12`) sem nome. A saída existe, que é o seletor "Formulário", que chama `passDraftToForm()`. Mas nada a indica.
- **Como, para o descarte.** Copie o padrão de `ComposerView.swift:85` e de `TranscriptViews.swift:560`:
  - Os dois `cancel:` passam a chamar `requestClose()`: `hasWork ? (isConfirmingDiscard = true) : dismiss()`.
  - `hasWork` vale, no assistente, `wizard.userMessageCount >= 1 && !wizard.isFinished` e, no formulário, nome ou identidade preenchidos.
  - O diálogo: `.confirmationDialog("Descartar o Orb que você está criando?", …) { Button("Descartar", role: .destructive) { dismiss() } } message: { Text("A conversa com o assistente se perde.") }`.
- **Como, para o limite.**
  - O placeholder de `Views/Multi/WizardChatView.swift:120` passa a ser `runner.draft.canCreate ? "Vamos fechar: clique em Criar Orb" : "A conversa chegou ao limite. Passe para o Formulário para dar um nome."`.
  - O `WizardFooter` ganha `var hitLimit = false` e, nesse caso, diz o mesmo no lugar de "O assistente ainda não escolheu um nome" (`:15`).
- **Risco:**
  - Nenhum teste fixa essas frases.
  - É o primeiro `confirmationDialog` dentro de uma folha neste projeto. Confira uma vez no app que o Esc abre o diálogo e não fecha a folha por baixo.
- **Esforço:** M para o descarte, P para o limite.

**Item 6: propostas de skill.** **Em parte. A proposta não fica órfã tão fácil quanto a tabela diz.**

- **O que já funciona.** O aviso "Skill proposta" é uma oferta (`NoticeAction.isOffer`, `AppModel+Transcript.swift:118`): o botão "Revisar" fica nele em qualquer ponto da conversa enquanto a proposta existir. `collectSkillProposals` também reavisa a cada turno.
- **O buraco real.** Apagar a conversa some com o aviso, a oferta se perde num chat longo, o aviso não sai durante rotina (`AppModel+SkillReview.swift:98`) e falta uma visão de todos os Orbs. As linhas 46-55 da tabela são outra função (`reviewSkillsIfDue`).
- **Como, sem campo persistido:**
  1. `AppModel+SkillReview.swift` ganha `pendingSkillDrafts() async -> [SkillDraft]`. Ela percorre `bots`, lê `memory.bank(for:).proposals()` (`Memory/MemoryBank+Skills.swift:41`) e reaproveita `skillDraft(_:from:)`.
  2. `InstalledSkills` (`Views/SkillsView.swift:87-129`) carrega a lista em `.task` e no `onDismiss`, e desenha no topo um bloco "Aguardando sua revisão (N)" com "Nome · de Orb · Revisar". O botão abre `SkillEditor(skill:proposal:)`, como o chat faz (`TranscriptViews.swift:1305-1310`).
  3. `SkillDraft.id` hoje é só o slug (`AppModel+SkillReview.swift:8`). Troque por `"\(botID)/\(slug)"`, porque dois Orbs podem propor o mesmo slug e colidir no `ForEach`.
  4. O `overlay` de lista vazia (`SkillsView.swift:107`) deve sumir quando houver propostas.
- **Risco:**
  - Baixo: os testes de `SkillFlowTests.swift:380-430` não dependem do `id`.
  - O `.task` só roda ao entrar na página, então uma proposta nova com a página aberta só aparece ao voltar a ela. É aceitável.
  - O `case` de snapshot reaproveita `SkillSnapshots.draft`.
- **Esforço:** M.

**Item 7: rodapé da lateral.** **Em parte.** **[conferido]**

- **O que já existe.** O VoiceOver já tem rótulos (`iconTip`), então a falta é visual.
- **Por que não cabe ao lado do ícone.** A coluna tem 240 pt no mínimo (`Views/RootView.swift:20`), e só cerca de 40 pt sobram depois dos ícones. Rótulo ao lado do ícone não cabe.
- **Onde:** `Views/SidebarView.swift:117-133` e `FooterPageButton` (`:209-227`).
- **Como:**
  - Separe o rodapé em duas linhas.
  - Em cima, os três `FooterPageButton` empilham ícone e legenda de 10 pt (`VStack`), sob um `SectionTitle("Espaço de trabalho")`. O título já existe em `:143`, e é o mesmo termo da paleta.
  - Embaixo ficam o avatar e a engrenagem.
- **Risco:**
  - O rodapé cresce de 20 a 30 pt.
  - `HoverTipsTests.swift:101-118` exige dica em todo botão só de ícone.
  - Confira em 240 pt com `--snapshot`.
- **Esforço:** M, e não P como na tabela.

**Item 8: paleta.** **Concordo.** **[conferido]**

- **"Ajustes" (P).**
  - Em `Views/CommandPalette.swift`, crie `case settings` em `PaletteEntry.Action` (`:8-14`).
  - A entrada é `PaletteEntry(id: "settings", title: "Ajustes", symbol: "gearshape", section: .actions, shortcut: ShortcutCatalog.keys(for: .settings), action: .settings, keywords: "preferências configurações")`.
  - Em `perform` (`:279-293`), `case .settings: SettingsRouter.show(using: openSettings)`, com `@Environment(\.openSettings)`.
- **Conversas (M).**
  - O dado já existe em `model.live(id).chats?.list`, com título e data.
  - `PaletteBuilder.entries` ganha `chats: [UUID: OrbChats] = [:]`. O padrão mantém os testes antigos compilando.
  - A ação é `.chat(UUID, of: UUID)` e chama `model.openChat(_:of:)`.
  - As conversas só aparecem com busca: crie um `searchOnly` filtrado no ramo de busca vazia de `rank` (`:55-58`), para a lista inicial não inchar.
  - A busca é só pelo título, de até 48 caracteres. Buscar no texto exigiria ler arquivos, e fica de fora.
- **Paliativo.** Até lá, troque a frase de `:176` por "Ir para um Orb, uma página ou uma ação…".
- **Risco:** `SystemCommandsTests.swift:173-210` e `ConversationSearchTests.swift:319-324` usam a assinatura atual, que o valor padrão cobre.
- **Esforço:** P para Ajustes, M para conversas.

**Item 9: Ajustes → Geral.** **Concordo. Faça em duas etapas.**

A contagem do relatório está certa: 7 interruptores, o atalho global, 4 linhas de dados, memória e 30 linhas de
atalhos (`Views/SettingsView.swift:160-294`).

- **Etapa 1, atalhos (P).**
  - Troque o `ForEach(ShortcutCatalog.groups)` (`:280`) por um `DisclosureGroup("Atalhos do teclado")` fechado.
  - Um botão "Ver atalhos" seria mais caro: o `ShortcutsSheet` mora na janela principal, e o botão precisaria de `openWindow(id: "main")`, `NSApp.activate()` e `model.showShortcuts = true`.
- **Etapa 2, aba "Orbs" (M).**
  - Crie `case orbs` em `SettingsTab` e uma `OrbsSettings`.
  - A aba nova recebe os interruptores de `:213-238`, `OpenTalksSection`, `ContextMemorySettings` e `LearnedWindowsSettings`.
  - Leve junto os `@State` e a parte de `refresh()` que lê `learnedWindowRows()` (`:362`).
- **Risco:**
  - `AjustesPolishTests.swift:230` fixa a lista de abas.
  - Os snapshots `settings-orbs` e `settings-general` (`:445-461`) apontam para `GeneralSettings`.
  - A janela de 640 × 720 é decisão documentada (`:32-34`) e fica.
- **Esforço:** P e depois M.

**Item 10: "Refazer" fora do hover.** **Concordo.** **[conferido]**

- **O que existe hoje.**
  - O `RedoReplyButton` só existe em `MessageActions`, que aparece no hover (`Views/TranscriptViews.swift:398-403`).
  - O menu de contexto (`:434-439`) e as ações de VoiceOver (`:442-444`) só copiam.
  - A `UserBubble` (`:208-216`) já faz o caminho completo para "Editar".
- **Como:**
  1. `AppModel+Rewind.swift` ganha `redoOrExplain(_:) -> Bool`, espelho de `editOrExplain` (`:127-134`). Quando `regenerateRefusal` não é nil, ela escreve o motivo em `composerLane(botID).error`, anuncia e devolve `false`.
  2. O `.confirmationDialog` e o `isConfirming` saem do `RedoReplyButton` e vão para a `BotMessage`. O botão de hover some quando o ponteiro sai, e o diálogo aberto pelo menu morreria junto.
  3. O menu de contexto, a ação de acessibilidade e o botão chamam o mesmo caminho: `if model.redoOrExplain(id) { model.regenerateDropsChanges(id) ? (isConfirmingRedo = true) : model.regenerateLastReply(id, animated: true) }`.
  4. Os itens novos entram sob `if offersRedo`.
  5. A recusa é checada na ação, não em `.disabled`, porque o arquivo evita observar o estado do Orb no `body` da resposta.
- **Risco:** baixo. `RewindTests` cobre o modelo, e um teste novo cobre `redoOrExplain` (recusa e caminho livre).
- **Esforço:** P.

**Item 11: compositor do grupo.** **Em parte.**

- **Parar e anexos.** Parar já existe: o "Parar grupo" do cabeçalho e o ⌘. (`Views/Groups/GroupChatView.swift:12-19`). Anexos não são falta de interface: o motor do grupo só aceita texto (`GroupHub.postUserMessage` grava `attachments: []`).
- **Onde:** `Views/Groups/GroupComposer.swift:11-49`.
- **Como (P), copiando o compositor individual sem acoplar a `BotSession`:**
  - **Esc:** um `@State isPickerDismissed`, zerado no `.onChange(of: text)`. `isPicking` passa a exigir `!isPickerDismissed`, e `.onKeyPress(.escape)` fecha a lista, como faz `isSlashDismissed`.
  - **Tab:** `.onKeyPress(keys: [.tab])` aceita a menção destacada com o `choose` que já existe (`:79`).
  - **Foco:** `.onAppear { isFocused = true }`, mais `.id(group.id)` no compositor, porque trocar de grupo não recria a view.
- **Fica de fora:** anexos (G: `postUserMessage`, `GroupPrompt` e persistência). Por ora, apague o parâmetro morto `attachmentCount` de `GroupUserBubble` (`GroupMessageBubble.swift:158`) e o `attachments.count` que `GroupChatView.swift:214` passa.
- **Risco:**
  - Baixo: os testes cobrem só `MentionCandidates`.
  - Cuide do `.return` já tratado em `:33`.
- **Esforço:** P.

---

## 2. Por componente

### 2.1 Casca: lateral, paleta, menus, barra de menus

- **Lateral.**
  - Ações das linhas ("+" de conversa, recolher, ⌘1–9) só aparecem no hover (`SidebarView.swift:363, 564-583`).
    - **Parecer: Discordo da prioridade.** Elas já têm outros caminhos: as ações de VoiceOver (`:371-376`), "Nova conversa" no menu de contexto (`:378`) e ⇧⌘N. Ficam como estão. Se quiser, mostre o "+" só no Orb selecionado.
  - O não lido é um ponto de 7 pt, sem número (`:611`). Proposta: badge numérico a partir de 2 (M/P).
    - **Parecer: Concordo.**
      - **Onde:** `Views/SidebarView.swift:611-616`.
      - **Como:**
        - `row.unread` já é `Int`, e `SidebarText.unread(n)` já fala o número.
        - Com `unread >= 2`, desenhe `Text("\(n)").font(.system(size: 10, weight: .semibold).monospacedDigit())` em cápsula `Palette.accentText`, com texto `Palette.onInk`.
        - Com 1, mantenha o ponto.
      - **Risco:** a cápsula é mais larga e aperta a prévia em `lineLimit(1)`. Confira com `--snapshot`.
      - **Esforço:** P.
  - Os três menus de contexto não batem: Orb não tem "Renomear" (só "Personalizar…"), Grupo também não, e Categoria não pode ser reordenada (M/P).
    - **Parecer: Em parte.**
      - **Renomear Orb ou grupo:** vale um item que seleciona o Orb e pede ao painel para focar o nome. Use o canal de pedidos ao painel (`model.request(…)`, ver `Views/BotInspector.swift:191`). Isso dispensa um campo inline na linha.
      - **Reordenar categoria:** é função nova no modelo, com "Mover para cima/baixo" no menu e `normalizeCategories` preservado (`SidebarCategories.swift:320`). A ordem já é a do array persistido, então não precisa de migração. Deixe para depois.
      - **Esforço:** M para cada um.
- **Contraste.** `Palette.hint` (opacidade 0,36, documentado como "decorativo, ~3:1" em `Theme.swift:43`) é usado em texto: a hora das conversas e "Nova conversa" em repouso (`SidebarChatList.swift:109, 144`) **[conferido]**. Trocar por `faint` (M/P).
  - **Parecer: Concordo.**
    - **Onde:** três textos, em `Views/SidebarChatList.swift:109`, em `:144` (que vira `isHovering ? Palette.muted : Palette.faint`) e em `Views/MemoryViews.swift:186`. A definição fica em `Theme.swift:44`. Os outros usos de `hint` são ícones ou estado desabilitado, e ficam.
    - **Risco:** só visual.
    - **Esforço:** P.
- **Paleta.**
  - A entrada "Nova categoria…" usa a keyword "pasta", que é vocabulário reservado.
    - **Parecer: Em parte.** É só um sinônimo de busca, e não aparece na tela. Se for tirar, remova "pasta" das keywords em `Views/CommandPalette.swift:127`. `SystemCommandsTests.swift:199-200` continua valendo.
    - **Esforço:** P.
  - Grupos aparecem na seção "Espaço de trabalho". Melhor ter uma seção "Grupos" própria.
    - **Parecer: Concordo.** Crie `case groups` ("Grupos") em `PaletteEntry.Section` (`:18-30`), logo depois de `.orbs`, e use-o em `:143`. O teste de ordem só exige `.orbs` primeiro.
    - **Esforço:** P.
  - O estado vazio não oferece nada (ex.: "Criar Orb chamado x").
    - **Parecer: Em parte.** Pré-preencher o nome exige um campo temporário no `AppModel`, limpo no `onDismiss` (`Views/RootView.swift:45`). Fica para depois. Mais barato: um botão "Novo Orb" sob "Nada encontrado…" (`:188`), que faz `model.showNewBot = true`.
    - **Esforço:** P.
  - Hover e seleção de teclado são dois destaques independentes (suspeita: dois itens acesos ao mesmo tempo).
    - **Parecer: Concordo.** A leitura confirma (`:339-341`).
      - **Como:** tire o `hoverFill` da `PaletteRow` e deixe só a seleção. Fazer o hover mover a seleção cria laço com o `scrollTo` de `:219-222`, porque as linhas passam sob o ponteiro parado.
      - **Esforço:** P.
- **Menus.**
  - Há um `Toggle` dentro do menu "Orbs" para o atalho global (`OrbApp.swift:250`), fora do padrão do macOS. Ele cabe melhor em Ajustes.
    - **Parecer: Concordo.** O mesmo interruptor já existe em `Views/SettingsView.swift:276`.
      - **Como:** apague o `Divider`, o `Toggle` (`OrbApp.swift:249-250`) e o `@AppStorage` de `AppCommands` (`:164`). Em `Shortcuts.swift:198`, o texto fica só "em Ajustes → Geral".
      - **Esforço:** P.
  - O sheet de atalhos não tem atalho próprio. Proposta: ⌘/ (B/P).
    - **Parecer: Concordo.** ⌘/ está livre.
      - **Como:** em `Shortcuts.swift`, crie `AppShortcut.shortcuts = KeyboardShortcut("/")` e ponha-o em `AppShortcut.all` (`:84`) **antes** dos nove ⌘1–9. Crie também `case shortcuts` em `ShortcutCommand` e um `ShortcutItem` no grupo "Geral". Depois, `.keyboardShortcut` no botão de `OrbApp.swift:197` e `shortcut:` na entrada da paleta (`CommandPalette.swift:130`).
      - **Risco:** `SystemCommandsTests.swift:83-123` (tecla única, catálogo completo) passa a cobrir a tecla nova.
      - **Esforço:** P.
- **Painel da barra de menus (QuickAsk).**
  - Não tem botão de enviar, só ↩ (ruim para VoiceOver).
    - **Parecer: Concordo.** Ponha um botão `arrow.up.circle.fill` ao lado do campo (`Views/QuickAskView.swift:182-186`), com `.iconTip` e desabilitado com texto vazio. Reaproveite o desenho de `WizardChatView.swift:136-140`. O painel tem 340 pt.
    - **Esforço:** P.
  - Não lista grupos.
    - **Parecer: Discordo por ora.** Exigiria um destino de envio novo e mexer em `QuickAskSend.action`. É G.
  - O erro "modelo não conectado" não tem botão.
    - **Parecer: Discordo do fato, mas há outro defeito.** O aviso "Conecte um modelo." tem o botão "Abrir Ajustes" (`:207-216`) **[conferido]**. O defeito é que ele usa `SettingsRouter.show` sem aba. A condição vale por Orb, e com outro provedor pronto o Ajustes abre na última aba usada. **Como:** troque por `SettingsRouter.open(.models, using: openSettings)`, como o `FirstRunCard` (`:446, 762`). **Esforço:** P.
  - "Abrir Ajustes" usa `SettingsRouter.show` sem aba, enquanto o FirstRunCard usa `.open(.models)`, e os dois podem cair em abas diferentes (M/P).
    - **Parecer:** é o mesmo defeito do subitem anterior, e a mesma troca resolve os dois.

### 2.2 Ajustes

- **"Sair" quer dizer desconectar a conta** (`ProviderSettings.swift:298,306`, `ClaudeCodeSettings.swift:26,52`) **[conferido]**. Num app de Mac, "Sair" lembra encerrar o app. Use "Desconectar" (M/P).
  - **Parecer: Em parte.**
    - **Por que não "Desconectar".** "Sair" faz par com o "Entrar" ao lado (`ClaudeCodeSettings.swift:33`), e o conector já usa "Sair da conta" (`ConnectorsView.swift:259`).
    - **Como:** troque "Sair" por "Sair da conta" nos botões e títulos de diálogo de `ProviderSettings.swift:298, 305-306` e `ClaudeCodeSettings.swift:26, 51-52`. Mantenha o corpo, que já diz "desconecta".
    - **Risco:** nenhum teste de interface. Os testes de `ToolIntentTests` são de outro "Sair da conta".
    - **Esforço:** P.
- **A aba "Permissões" é do macOS, mas o Orb também tem permissões próprias.** Renomeie para "Acesso ao Mac" (M/P).
  - **Parecer: Concordo.**
    - **Como:** em `Views/SettingsView.swift:18`, troque o título. O link de `BotInspector.swift:470` lê `SettingsTab.permissions.title` e acompanha.
    - **Risco:** quebra `AjustesPolishTests.swift:230`, que fixa a lista de abas. O texto **para o modelo** em `MacPermissions.swift:492` cita a aba "Permissões" e precisa mudar junto, assim como o comentário de `MacPermissionsView.swift:5`. `MacToolTests.swift:35` continua valendo.
    - **Esforço:** P.
- **"Pasta dos Orbs" e "Pasta de dados" colidem com "Pasta"** (`SettingsView.swift:254,262`). Use "Local dos dados" e "Local padrão das pastas" (B/P).
  - **Parecer: Em parte.**
    - **O que muda:** "Pasta dos Orbs" é mesmo onde ficam as pastas dos Orbs, e fica. "Pasta de dados" é a pasta do app e confunde: troque por "Local dos dados" (`:262`).
    - **Risco:** `ResetOrbSheet.swift:190` cita "Ajustes → Geral → Pasta de dados" e muda junto. Confira `Tip.dataFolder` (`Tips.swift:244`), que tem limite de tamanho testado.
    - **Esforço:** P.
- **A chave de busca na web fica na aba Navegador, longe das outras chaves.** Deixe ao menos uma frase apontando para lá (B/P).
  - **Parecer: Concordo.** Em `Views/ProviderSettings.swift:89`, troque o `Section { addMenu }` por `Section { addMenu } footer: { FormFootnote { Text("A chave da busca na web fica na aba Navegador.") } }`. `FormFootnote` já existe (`SheetKit.swift:222`).
  - **Esforço:** P.
- **A janela tem largura fixa de 640 pt e todas as abas têm 720 de altura.** Os textos `.caption` longos rolam.
  - **Parecer: Discordo.** O tamanho único é decisão documentada, para a janela não pular entre abas (`SettingsView.swift:32-34`). Rolar dentro do `Form` é o esperado, e nada fica cortado. Não mexer.

### 2.3 Chat

- **Linha de trabalho invisível ao VoiceOver.** Tempo, contagem para tentar de novo e gasto estão em `accessibilityHidden` ou `children: .ignore` (`ChatView.swift:1013,1129`). Leve isso para o `accessibilityValue` (M/P).
  - **Parecer: Em parte.**
    - **O que já existe.** A linha já tem rótulo, `accessibilityValue` com a frase e ações (`Views/ChatView.swift:1013-1029`). O relógio é escondido de propósito, para o VoiceOver não ler cada segundo (comentário em `:1101-1103`).
    - **Como:**
      - O `accessibilityValue` ganha só o que muda pouco, com `WorkMeter.text(elapsed: "", actions:spend:)`, que dá "3 ações · 180 mil tokens".
      - O tempo vira uma ação sob demanda em `:1019`: `Button("Dizer o tempo e o gasto")`, que anuncia o texto completo do medidor.
      - A contagem regressiva fica de fora.
    - **Risco:** o valor muda a cada ação e pode falar demais. Confira com VoiceOver.
    - **Esforço:** P.
- **Confirmação de Editar/Refazer.** Ela sempre abre um diálogo modal. Basta confirmar quando houve passos com efeito no Mac depois da mensagem (M/M).
  - **Parecer: Já resolvido.** O diálogo só abre com `editDropsChanges` ou `regenerateDropsChanges` (`ComposerView.swift:523`, `TranscriptViews.swift:558`) **[conferido]**. Os dois usam `Conversation.dropsChanges(from:)` (`Rewind.swift:249-264`), coberto em `RewindTests`. Sai da fila.
- **Erro com duas aparências.** O `NoticeRow` tem "Tentar de novo", "Trocar modelo" e "Detalhes". O erro de envio do compositor é um `Label` `.caption` sem ação (`ComposerView.swift:88-96`). Unificar (B/P).
  - **Parecer: Em parte. Não unificar.**
    - **Por que são erros diferentes.** O `lane.error` do compositor (`Views/ComposerView.swift:147-155`) carrega outros erros: imagem demais ou ilegível, falha do ditado e recusa de Editar. Para eles, "Tentar de novo" e "Outro modelo" não fazem sentido.
    - **O defeito real.** O erro só some ao enviar, anexar, ditar ou editar, e digitar não o limpa.
    - **Como:**
      - Ponha um `xmark` de dispensar no `Label` (`Button { lane.error = nil }`).
      - Limpe o erro ao digitar, em `editDraft` (`AppModel.swift:814`).
      - Opcional: com `Dictation.deniedMessage`, um botão "Abrir Ajustes do Sistema".
    - **Risco:** o snapshot de `SnapshotComposerScenes.swift:58` mostra esse erro.
    - **Esforço:** P.
- **Plano.** O anel do plano some quando o turno acaba e não sobra resumo. Ele também usa a mesma forma de anel do medidor de contexto, com outro significado (M/M e B/P).
  - **Parecer: Em parte, e discordo da forma.**
    - **O anel não some.** Com etapas abertas, `IdlePlanRing` fica depois do turno (`ChatView.swift:321-323`). Ele só some com o plano todo feito.
    - **Não se confundem.** O anel do plano tem 10 pt, rótulo "2/5" e mora no chat. O `ContextRing` tem porcentagem e mora na barra do compositor.
    - **O que sobra.** Falta um resumo do plano concluído, que seria um item novo no transcript, com `TranscriptItem.Kind` e migração. Fica para depois.
- **Pergunta.** Uma pergunta pulada aparece como "Sem resposta". Melhor "Pulada" (B/P).
  - **Parecer: Discordo.** `answer == nil` vale tanto para pular quanto para Parar (`Engine/ApprovalGate.swift:63`) **[conferido]**, e "Pulada" mentiria no segundo caso. Fica "Sem resposta" (`QuestionCard.swift:158, 263`).

### 2.4 Compositor

- **Dica de teclas.** Ela está em `accessibilityHidden` (`ComposerView.swift:72`), e é lá que moram ↩, ⇥ e ⌘↩. Leve para o `accessibilityHint` do campo (A/P).
  - **Parecer: Concordo.**
    - **Como:**
      - A dica visual continua escondida, para não ser lida duas vezes.
      - O `TextField` (cadeia de `:162-171`) ganha `.accessibilityHint(spokenKeys(hintText))`.
      - `spokenKeys` é uma função pequena que troca ↩, ⇥, ⇧ e ⌘ por "Return", "Tab", "Shift" e "Command". Não existe helper para isso.
    - **Risco:** as strings de `ComposerHint` são testadas (`ComposerSupportTests:20-56`). A troca fica numa camada à parte e não as altera.
    - **Esforço:** P.
- **Pilha de faixas acima do campo.** Rotina ou outro chat, processos, edição, anexos, erro e sugestões de `/` podem se empilhar e comer a altura do transcript. Funda numa linha com contagem (M/M).
  - **Parecer: Em parte. Não fundir.**
    - **Onde cresce de verdade.** Só o `JobsStrip` cresce sem limite, com uma linha por processo e até 8 processos (`ComposerChips.swift:398-426`, `BackgroundJobs.swift:60`). As outras faixas raramente aparecem juntas. Fundir tudo tiraria o "Parar" de cada faixa.
    - **Como:** acima de 2 processos, mostre os dois primeiros e uma linha "+N em segundo plano" que expande.
    - **Esforço:** P.
- **⇥ não tem botão.** Quem nunca digitou durante um turno não descobre a fila. Opção: um menu no botão enviar ("Orientar agora" / "Depois da tarefa") (M/M).
  - **Parecer: Em parte. Um `Menu` mexe demais no botão redondo.**
    - **Como:**
      - Só com `action == .queue`, o `mainButton` (`ComposerView.swift:331-345`) ganha um `.contextMenu` com "Direcionar agora" e "Depois da tarefa". O segundo chama `send(delivery: .afterTask)`.
      - O botão também ganha `.accessibilityAction(named: "Enviar para depois da tarefa")`.
      - O `.help` (`:764`) cita o clique com o botão direito.
      - Esconda "Direcionar agora" quando o modelo já força `afterTask`, em rotina ou com a conversa noutro lugar (`AppModel+Steering.swift:265`).
    - **Esforço:** P.
- **Chip de permissão só com ícone.** Mostre o nome do modo quando for diferente do padrão (M/P).
  - **Parecer: Concordo, só para os modos fora do comum.** A decisão de mostrar só o ícone está comentada em `ComposerChips.swift:37`, e `PermissionChipText.label` (`ComposerSupport.swift:11`) já existe e é testado, sem uso.
    - **Como:** o `PermissionChip` ganha `compact` (como `ModelChip`). Fora do modo compacto, e só com `.bypass` ou `.readOnly`, ele mostra `Text(mode.label)` na cor do ícone.
    - **Risco:** largura da barra, com `compactBelow = 520`. Confira em 460 pt.
    - **Esforço:** P.
- **Microcopy.** "Ver" na faixa de outro chat deve virar "Voltar para a conversa". Na tela ao vivo, "Privado" e "Mostrar" devem virar "Ocultar tela" e "Mostrar tela", e "Parar", que para o Orb inteiro, deve virar "Parar Orb" (M/P).
  - **Parecer, "Ver": Concordo, mais curto.**
    - **Como:** em `ComposerChips.swift:382`, `Button("Voltar")`, com `.accessibilityLabel("Voltar para a conversa “\(chatTitle)”")`. A frase longa já está no `.help` (`:386`). Com `needsYou`, use "Responder".
  - **Parecer, "Privado"/"Mostrar": Em parte.**
    - **Como:** só os botões mudam, para "Ocultar tela" e "Mostrar tela" (`LiveScreen/LiveScreenViews.swift:171, 173, 366, 369`). O chip de estado "Privado" (`LiveScreenLogic.swift:192`) fica, porque como estado funciona.
  - **Parecer, "Parar": Concordo só na tela ao vivo.**
    - **Como:** em `LiveScreenViews.swift:169`, "Parar Orb", porque esse botão chama `model.stop`, que também corta as cadeias entre Orbs.
    - **Não mexer:** o "Parar" do compositor para só o turno e está fixado em testes (`ComposerSupportTests:118, 161`, `MotionControlsTests:123`).
  - **Risco:** o cartão da tela ao vivo usa `ViewThatFits`, que corta botões na coluna de 244 pt (`LiveScreenViews.swift:149-158`). Confira com `--snapshot`.
  - **Esforço:** P.

### 2.5 Painel do Orb

- **"Apagar Orb…" escondido.** Ele mora no rodapé do card "Pode usar", que vem fechado (`BotInspector.swift:420,496`). Leve para o fim da aba Geral ou para um menu "⋯" no cabeçalho (M/P).
  - **Parecer: Em parte.**
    - **O que já existe.** O rodapé é `footer:` da `Section`, fora do `if isOpen`, então já está sempre no fim da aba Geral. Ele é só apagado demais: `Palette.faint` 12 pt, vermelho no hover (`QuietDeleteStyle`, `:1339`).
    - **Como:** suba para `Palette.muted` (`:496-509`). O menu "⋯" no `InspectorHeader` (`:857`) disputaria foco com o campo do nome, e fica para depois.
    - **Esforço:** P.
- **Renomear falha em silêncio.** Quando dá errado, o campo volta ao nome antigo sem dizer por quê (`:934`) (M/P).
  - **Parecer: Em parte.** Só falha com nome vazio (`OrbFolder.swift:173-178`). O corte silencioso em 60 caracteres (`:186-191`) é o outro caso.
    - **Como:** quando `rename` devolve `false`, `commitName` (`BotInspector.swift:934-936`) liga um `@State nameError` ("O nome não pode ficar vazio"). Ele aparece como `.caption` `Palette.warn` sob o campo, com anúncio. Acima do limite, mostre "Até 60 caracteres".
    - **Risco:** não mexa em `rename`, testado em `OrbFolderTests.swift:282-295`.
    - **Esforço:** P.
- **O link "Como funciona" da Memória** é `onTapGesture`, e o Tab não chega nele (`MemoryViews.swift:87`). Use `Button(.link)` (M/P).
  - **Parecer: Concordo, e o mesmo padrão aparece em mais lugares.** O `LearnMoreNote` (`SettingsView.swift:511-533`) faz igual e é usado em `MacPermissionsView.swift:333` e `BrowserSettings.swift:28, 210`.
    - **Por que não `Button(.link)` direto.** O link é um trecho dentro de `Text + Text`.
    - **Como:** extraia um `InlineLinkNote` usado nos dois lugares. Ele ganha `.focusable()`, `.onKeyPress(.return)` e `.onKeyPress(.space)` abrindo a ajuda, e `.accessibilityAction`.
    - **Risco:** o anel de foco do macOS. Confira com "Acesso total pelo teclado" ligado.
    - **Esforço:** P.
- **A aparência abre numa folha sem "Cancelar".** Falta "Restaurar o que estava" (M/M).
  - **Parecer: Concordo.** O `OrbEditor` grava ao vivo e a folha só tem "Pronto" (`BotInspector.swift:152-166`).
    - **Como:** guarde `orbAtOpen` quando a folha abre. Um botão fantasma "Desfazer mudanças", habilitado se `bot.orb != orbAtOpen`, faz `model.update(bot.id) { $0.orb = orbAtOpen }`. O Esc continua fechando e mantendo.
    - **Risco:** o `OrbEditor` também é usado no wizard (`SheetsAndSettings.swift:210`), que não ganha o botão.
    - **Esforço:** M.
- **Cinco abas numa coluna de 244 pt** com `minimumScaleFactor(0.85)` (suspeita de corte).
  - **Parecer: Suspeita mantida.**
    - **O que já existe.** O mínimo vem de `RootView.swift:146`, e "Pasta e acessos" já encurta para "Pasta" (`InspectorSupport.swift:27-29`).
    - **Como:** confira com `--snapshot` em 244 pt. Se cortar, esconda o rótulo das abas não selecionadas abaixo de cerca de 260 pt. Subir o mínimo tira espaço do chat.

### 2.6 Criar Orb (wizard, Orb cria Orb, importar)

- **"Toque" num app de Mac.** Aparece em 4 lugares (`WizardChatView.swift:120-121`, `WizardPreviewPane.swift:338,357`) **[conferido]**. Troque por "clique" (M/P).
  - **Parecer: Concordo. São seis ocorrências:** as quatro da tabela, `Engine/Browser/BrowserLocator.swift:103` ("toque em Instalar", mensagem real ao usuário) **[conferido]** e o texto de amostra `Views/Multi/WizardSnapshots.swift:61`. Uma passada só, sem teste que as fixe.
  - **Esforço:** P.
- **O cartão de proposta não chega ao formulário completo.** Ele não escolhe modelo nem pasta. Proposta: um "Abrir no assistente" que reaproveite `passDraftToForm` (M/M).
  - **Parecer: Discordo. É G, não M.**
    - **O que já existe.** O cartão já mostra o modelo e a pasta (`OrbProposalCard.swift:297, 307`).
    - **Por que não passar ao formulário.** O `orb_propose` do Orb criador espera a resposta no gate, e o formulário perderia `createdBy`. Além disso, exigiria um caso novo em `ProposalOutcome`, que mexe nos testes de proposta.
    - **Decisão:** não fazer. Se a queixa for escolher pasta e modelo, é recurso novo do cartão.
- **O botão "Criar" do cartão é desenhado à mão** (`OrbProposalCard.swift:456-481`) em vez de usar `PrimaryPillStyle` (B/P).
  - **Parecer: Discordo.** O desenho à mão mostra o "pressionado" que o ⌘↩ aciona (`pressed == .allow`, `:474-476`), como o `ApprovalCard` (`TranscriptViews.swift:1831`). Trocar perderia esse retorno e separaria os dois cartões.
- **A folha do wizard tem 820 pt fixos e o texto diz "revise ao lado".** Suspeita de folha maior que a janela no mínimo.
  - **Parecer: Já resolvido.** A janela tem `minWidth: 1000` (`OrbApp.swift:38`), e a altura da folha se limita à janela (`NewBotSheetLayout.height`, `InspectorSupport.swift:225-239`). Sai da fila.

### 2.7 Grupos

- **Membros sem ação principal.** Clicar num membro não abre o Orb (`GroupPanel.swift:129-183`) (M/P).
  - **Parecer: Concordo.**
    - **Como:** em `Views/Groups/GroupPanel.swift:139-150`, embrulhe avatar, nome e papel num `Button { model.selection = .bot(look.id) }`, com `.buttonStyle(.plain)`, `.contentShape(.rect)` e `.help("Abrir a conversa de \(look.name)")`. Os botões de ícone à direita ficam fora, porque não pode haver botão dentro de botão.
    - **Esforço:** P.
- **Menções pobres.** O `MentionPicker` não mostra avatar nem papel (M/P).
  - **Parecer: Concordo.**
    - **Como:** passe `model.groupLooks(group)` ao `GroupComposer` e ao `MentionPicker` (`Views/Groups/MentionPicker.swift:37-79`). Cada linha desenha `BotAvatar(size: 20)` e `look.role`. `MentionCandidates.options(query:names:)` continua só com nomes, e os testes (`GroupScreensTests.swift:132-150`) ficam intactos. A linha "todos" não tem avatar.
    - **Esforço:** P.
- **"Adicionar Orb" desabilitado com motivo errado.** O help diz "até 8 Orbs" mesmo quando o motivo é "todos já estão" (`GroupPanel.swift:83`) (M/P).
  - **Parecer: Concordo.** Em `:82-83`, o help passa a ser `looks.count >= upper ? "Um grupo tem até 8 Orbs" : candidates.isEmpty ? "Todos os seus Orbs já estão neste grupo" : "Põe mais um Orb neste grupo"`.
  - **Esforço:** P.
- **Novo grupo com menos de 2 Orbs.** ⌥⌘G e a paleta abrem a folha, que não tem como ser concluída (M/P).
  - **Parecer: Em parte. O ⌥⌘G já está resolvido.** O ⌥⌘G e o "Criar grupo com…" já ficam desabilitados com menos de 2 Orbs (`OrbApp.swift:215-217`).
    - **O que falta:** na paleta, só incluir `new-group` com `orbs.count >= 2` (`CommandPalette.swift:123-125`). No "+" da seção Grupos (`Views/Groups/SidebarGroupRow.swift:30`), `.disabled(model.botIDs.count < 2)` com o help "Crie ao menos 2 Orbs para formar um grupo".
    - **Esforço:** P.
- **A faixa de presença aparece e some** (0 ↔ 30 pt), empurrando o compositor. Reserve a altura (M/P).
  - **Parecer: Em parte.** O compositor não se move: quem encolhe é o fio (`GroupChatView.swift:74-81`), e a última mensagem sobe.
    - **Como:** em `GroupPresenceStrip.swift:115`, `.frame(height: 30)` sempre, com `.opacity(text == nil ? 0 : 1)` e `accessibilityHidden(text == nil)`. O custo são 30 pt fixos.
    - **Decisão:** faça junto com a barra de pedidos do item 2, que muda essa mesma região, e decida as duas alturas olhando a captura.
    - **Esforço:** P.
- **`Palette.warn` com três sentidos.** É alerta, orquestrador e "esperando você" ao mesmo tempo (B/P).
  - **Parecer: Em parte.** Alerta e "esperando você" são a mesma família ("precisa de você", `Theme.swift:62-64`). Só a estrela do orquestrador destoa.
    - **Como:** troque por `Palette.accentText` em `GroupPanel.swift:155` e `NewGroupSheet.swift:192, 214`.
    - **Esforço:** P.

### 2.8 Rotinas

- **"Expressão cron" exposta.** Mostre a regra em português sob o campo ("Segunda a sexta, às 9h") e renomeie para "Agenda avançada" (A/M).
  - **Parecer: Concordo.**
    - **O que já existe.** `CronExpression.swift` só valida e calcula a próxima execução, mas expõe `minutes`, `hours`, `weekdays`, `anyDay` e os demais campos. Hoje o campo mostra apenas "Próxima execução…" (`RoutinesView.swift:835`).
    - **Como:**
      - `CronExpression.plainText() -> String?` cobre os casos comuns e devolve nil no resto, quando fica só a próxima execução:
        - um minuto e uma hora, com todo dia e todo mês, viram "às 9h";
        - os dias da semana 2 a 6 viram "de segunda a sexta";
        - 1 e 7 viram "aos fins de semana".
      - O texto entra como `.caption` sob o campo.
      - O rótulo de `RoutinesView.swift:805` vira "Agenda avançada".
      - No cartão, use uma propriedade nova (`Schedule.plainLabel`) e **não** mexa em `Schedule.label`, que vai ao modelo e ao chat (`AppModel+Schedule.swift:42, 65, 75`, `ScheduleToolTests.swift:170`).
    - **Risco:** baixo. Teste novo para `plainText`, com os casos comuns e a volta a nil.
    - **Esforço:** M.
- **Fuso em texto livre.** O erro não diz que o problema é o fuso (M/M).
  - **Parecer: Discordo do fato.** O erro diz: "Fuso desconhecido: “x”. Use um nome como America/Sao_Paulo." (`Models.swift:714`) **[conferido]**. Mas ele só aparece no rodapé da folha (`RoutinesView.swift:891`).
    - **Como:** repita a frase como `.caption` `Palette.warn` sob o campo Fuso (`:829`) quando `TimeZone(identifier:)` falhar.
    - **Esforço:** P. Um seletor com os ~400 fusos seria M e pede busca.
- **O cartão não leva ao Orb dono.** A falha só aparece dentro da folha. Proposta: selo "Falhou" no cabeçalho do cartão (M/P).
  - **Parecer: Em parte.** A última execução já aparece no cartão com ícone vermelho (`RunLine`, `:450-498`). Falta o selo de relance e o link ao Orb.
    - **Como:**
      - Em `RoutinesView.swift:224-249`, avatar e nome viram `Button` (`.plain`, `.help("Abrir \(bot.name) e suas rotinas")`). O botão faz `model.setInspector(true); model.request(.showTab(.routines), of: bot.id)`, o mesmo par de `showPermissions` (`AppModel+Commands.swift`).
      - Com `routine.runs.first?.succeeded == false`, mostre `CatalogBadge(text: "Falhou", tint: Palette.danger)` ao lado do nome.
    - **Esforço:** P.
- **Pausada = opacidade 0,6 no cartão inteiro.** O contraste cai. Atenue só o avatar e o título (M/P).
  - **Parecer: Concordo.** O rótulo "Pausada" já é `muted`, e com a opacidade do cartão fica perto de 0,36.
    - **Como:** em `RoutinesView.swift:310-312`, tire o `.opacity` do cartão e aplique-o só ao nome (`:251`) e ao avatar com o nome do Orb (`:225-230`). O avatar já fica `.sleepy`.
    - **Esforço:** P. Conectores (`ConnectorsView.swift:278`) e Skills (`SkillsView.swift:230`) têm o mesmo padrão e entram juntos (3.4).
- **Sem ordem nem agrupamento.** Ordene pela próxima execução ou agrupe por Orb (M/M).
  - **Parecer: Concordo, agrupando por Orb.** Ordenar pela próxima execução faz os cartões pularem a cada execução, com `animateChanges` animando tudo (`:54`).
    - **Como:** agrupe `model.routines` por `botID`, com um cabeçalho por Orb, e pegue o binding por id.
    - **Esforço:** M.

### 2.9 Conectores

- **"Testar conexão" escondido.** Ele fica no menu "…". O resultado some em 6 s, até quando é falha (M/P).
  - **Parecer: Em parte.** A falha do servidor (`status == .failed`) fica no cartão, com "Tentar de novo". O que some em 6 s é a falha **do teste** com o servidor bem.
    - **Como:**
      - Apague a limpeza da falha (`ConnectorsView.swift:383-384`), deixando só a do sucesso.
      - Ponha um botão `Button("Testar", action: runTest)` (`GhostStyle`, `.small`) ao lado do menu (`:250`).
      - Cancele o `Task` de espera quando o cartão sair (`:371-385`).
    - **Esforço:** P.
- **"Conectar assim mesmo" em vermelho.** Ele usa o slot `destructiveTitle` sem destruir nada (`LocalConnectorSheet.swift:189`) **[conferido]**. Proposta: um `secondaryTitle` neutro no `SheetFooter` (M/P).
  - **Feito** em `97c510b` (`leadingIsDestructive`).
- **"Desligado" com dois sentidos.** O mesmo texto vale para o interruptor e para o servidor parado. Proposta: "Desativado" para o interruptor e "Parado" para o servidor (M/P).
  - **Parecer: Discordo do fato. A troca de termo vale.**
    - **O fato.** `MCPStatus.stopped` é "desligado pelo usuário" (`Engine/MCPTool.swift:116-117`) **[conferido]**, o mesmo sentido do interruptor. O servidor parado e pronto já se chama "Pronto". O desencontro é com o interruptor "Ativo".
    - **Como:** troque "Desligado" por "Desativado" em `ConnectorsView.swift:472, 489` e em `ConnectorGalleryView.swift:4, 205, 232`. É o par único da 3.4.
    - **Esforço:** P.
- **Galeria e Instalados gerenciam o mesmo conector.** A galeria deveria só mostrar "Instalado ✓" e levar à aba Instalados (M/M).
  - **Parecer: Em parte.** A galeria já mostra o estado ("Conectado", "Desligado", "Resolver") e, ao clicar, abre o editor do mesmo conector (`ConnectorGalleryView.swift:42-56`).
    - **Como:** em `open(...)`, com conector instalado, troque de aba por um closure, como `explore` já faz, e ajuste `help` e `spoken` (`:239`).
    - **Esforço:** M, porque muda o comportamento do clique. Deixe para depois.
- **O "+" da barra abre direto o formulário técnico.** Proposta: um menu com "Da galeria", "Do registro" e "Manualmente" (M/P).
  - **Parecer: Concordo.** Troque o botão de `ConnectorsView.swift:40-42` por `Menu { Da galeria · Do registro · Manualmente } primaryAction: { tab = .gallery }`. O padrão está em `RoutinesView.swift:66-79`.
  - **Esforço:** P.
- **O caminho de erro depende de texto.** Ele faz `message.contains("app registrado")` (`ConnectorsView.swift:935`), o que é frágil (M/P).
  - **Parecer: Concordo.** Não existe enum de erro: o erro viaja como `String` por `MCPStatus.failed` e `ConnectorTestOutcome.failed`.
    - **Como:** crie uma constante `MCPAuth.needsAppPhrase`, usada tanto em `needsApp(...)` (`Engine/MCPAuth.swift:448-451`) quanto no `contains`. Os textos e os testes (`MCPAuthTests.swift:278, 313`) não mudam.
    - **Esforço:** P. Um tipo de erro de verdade seria G.

### 2.10 Skills

- **Skill desligada só fica translúcida (0,55), sem selo** (M/P).
  - **Parecer: Concordo.**
    - **Como:** na linha de selos (`SkillsView.swift:184-200`), `if !skill.isEnabled { CatalogBadge(text: "Desativada", symbol: "pause.circle") }`. A opacidade de `:230` passa só para o ícone e o título.
    - **Esforço:** P.
- **Clicar na linha não faz nada.** Para ler, é preciso "Editar…", que avisa nada sobre descolar da origem (M/P).
  - **Parecer: Concordo.**
    - **Como:**
      - O bloco de texto da linha (`:157-232`) vira `Button(action: onEdit)`, com `.plain`. Copiar e o interruptor ficam fora.
      - No rodapé do `SkillEditor` (`:579-589`), para skill com `source` de catálogo, entra a frase "Veio de owner/repo. A edição fica só neste Mac". `applyingEdits` mantém `source` (`Models.swift:813-820`).
    - **Esforço:** P.
- **⌘F vai sempre para Explorar.** Não há como buscar nas instaladas (M/M).
  - **Parecer: Concordo, mas é M por causa do dono do ⌘F.**
    - **Como:**
      - `InstalledSkills` ganha um filtro (`@State query`) por nome, slug e resumo, visível a partir de cerca de 8 skills.
      - O botão oculto do `CatalogTabBar` (`CatalogParts.swift:36-44`) passa a focar esse campo quando a aba for Instalados.
      - O texto de `Shortcuts.swift:177` muda junto.
    - **Esforço:** M.
- **Erro cru na prévia.** A prévia mostra `localizedDescription` (`SkillsView.swift:420,461`), enquanto o cartão usa `CatalogError.cardText` (M/P).
  - **Parecer: Em parte. Não use `cardText`.**
    - **Por quê.** `CatalogError` já tem `errorDescription` em pt-BR (`Catalog/SkillCatalog.swift:235-243`), e `cardText` diz "abra para tentar de novo" com a prévia já aberta. Só o `URLError` sai cru.
    - **Como:** em `:460-463`, o texto ganha `Button("Tentar de novo")`, que chama um `load()` extraído do `.task`. O `URLError` vira "Sem conexão com o catálogo.".
    - **Esforço:** P.

---

## 3. Coexistência

### 3.1 Teclas que mudam de sentido

- **⌘↩ tem quatro sentidos:** enviar, parar e enviar, permitir o pedido e, com pedido aberto e texto no compositor, recusar e enviar. O caso perigoso é o item 1 da tabela.
  - **Parecer: Já resolvido** em `97c510b`. Sobram três sentidos coerentes: enviar ou parar e enviar no compositor, permitir no cartão e responder na pergunta.
- **Esc tem seis donos:** recusar o cartão, pular a pergunta, fechar `/`, cancelar a edição, cancelar a entrega da tela ao vivo e fechar a busca. A precedência é coerente no código, mas invisível. No banner "Editando · Esc cancela", às vezes é preciso apertar Esc duas vezes (`ComposerView.swift:692`).
  - **Parecer: Em parte. Não mexer.** O Esc duplo só ocorre editando uma mensagem que é um `/comando` sozinho, ou com o ditado aberto (`ComposerView.swift:433-447`, `694-698`). É raro, está documentado (`docs/MANUAL.md:212`) e fixado em `ComposerSupportTests:97-100`. O cartão de pedido não compete: ele ignora o Esc com texto no campo, e Editar não abre com pedido pendente.

### 3.2 Chat individual × chat de grupo

| | Individual | Grupo |
|---|---|---|
| Pedido de permissão | cartão com ⌘↩/Esc | some do fio |
| Compositor | anexos, ditado, `/`, fila, parar | só texto e menções |
| Bolha do usuário | Copiar, Editar | sem menu |
| Mensagem entre Orbs | `OrbMessageRow` com estado e "Ver troca" | `GroupAssignmentLine` sem estado |
| Fala de outro Orb | `OrbSpeechBubble` (nome a 45% de luz, Markdown só inline) | `GroupMessageBubble` (contraste WCAG, Markdown completo) |
| Margem direita da resposta | 90 | 40 |

A proposta é um só componente para cada linha: o `ExchangeSheet` passa a usar `GroupMessageBubble`, e a linha do grupo
reaproveita `ExchangeStateMark`.

**Parecer, linha a linha:**

- **Pedido de permissão e compositor:** ver os itens 2 e 11.
- **Bolha do usuário: Em parte.** Editar não cabe no grupo, que não tem como voltar atrás. Copiar cabe. **Como:** `.contextMenu { Button("Copiar") { Clipboard.copy(text) } }` em `GroupUserBubble` (`Views/Groups/GroupMessageBubble.swift:153-178`). **Esforço:** P.
- **Estado da troca: Concordo.**
  - **O que já existe.** O estado já é mantido no grupo (`GroupHub` `setAssignment`, `AppModel+Groups.swift:58-59`).
  - **Como:** em `GroupAssignmentLine` (`GroupMessageBubble.swift:184-234`), insira `ExchangeStateMark(state: message.state, showsWord: false)` entre o texto (`:203`) e a seta (`:209`). O contêiner (`:232`) ganha `.accessibilityValue(ExchangeStateMark.spoken(message.state))`. A palavra fica de fora porque a linha não tem `isNarrow`, e o `.help` a cobre.
  - **Esforço:** P.
- **`ExchangeSheet` com `GroupMessageBubble`: Concordo, com três ajustes.**
  - **Como:** troque o `OrbSpeechBubble` (`Views/Multi/ExchangeSheet.swift:50-53`, seu único uso) por `GroupMessageBubble(message:look:isOrchestrator: false, isLastSpeaker: false, showsHeader: !continues)` e apague `OrbSpeechBubble.swift`.
  - **Os ajustes:**
    - o papel aparece em todo cabeçalho, e não só na primeira fala;
    - o rótulo fixo "Resposta de X" (`OrbSpeechBubble.swift:108`) passa a derivar do tipo da mensagem;
    - o recuo da legenda de estado (`ExchangeSheet.swift:58`) se alinha à bolha nova.
  - **Esforço:** M. Confira com o snapshot da troca.
- **Margem 90 × 40: Discordo de que seja defeito.** Os 90 pt reservam a coluna de botões de hover da resposta individual (`TranscriptViews.swift:111, 408`), e o grupo só tem Copiar.
- **Cor de falha: achado novo.** `ExchangeSheet.swift:158` pinta "Não deu certo" de `Palette.warn` **[conferido]**, e `OrbMessageRow.swift:131-134` pinta o mesmo estado de `Palette.danger`. A regra do `Theme.swift:60-61` diz que falha é vermelho. **Como:** troque a cor de `.failed` por `Palette.danger`. **Esforço:** P.

### 3.3 Painel do Orb × painel do grupo

Os dois ocupam a mesma coluna, mas o Orb usa abas com ícone e `Form`, e o grupo usa `Picker` segmentado e `ScrollView`.
O nome do Orb grava ao perder o foco, e o objetivo do grupo só no ↩. Apagar o Orb abre uma folha, e apagar o grupo
abre um `confirmationDialog`, copiado em dois lugares (`SidebarGroupRow.swift:119`, `GroupPanel.swift:237`).
Padronize o momento de gravar e a forma de confirmar.

**Parecer: Em parte.**

- **Momento de gravar:** já resolvido. O nome do Orb, o nome do grupo e, desde o item 12, o objetivo gravam ao sair do campo.
- **Abas × segmentado:** justificado. São cinco abas no Orb e três no grupo.
- **Folha × diálogo para apagar:** justificado. O Orb pergunta pela memória e pelos grupos desfeitos, e o grupo não tem o que perguntar.
- **A cópia do diálogo de grupo, que é o que vale fazer:**
  - Crie um modificador `deleteGroupDialog(_:isPresented:)` em `Views/Groups/`, com o texto único.
  - Crie `AppModel.deleteGroupAndLeave(_:)`: `deleteGroup(id)` e, se o grupo estava selecionado, seleciona o primeiro Orb.
  - `SidebarGroupRow.swift:119-126` e `GroupPanel.swift:235-241, 257-260` passam a usar os dois.
  - Hoje o painel sempre pula para o primeiro Orb, e a lateral só pula se o grupo estava selecionado. Fica a regra da lateral.
- **Esforço:** P.

### 3.4 Rotinas × Conectores × Skills: três telas irmãs, três padrões

| | Rotinas | Conectores | Skills |
|---|---|---|---|
| Layout | grade de cartões | grade de cartões | lista de linhas |
| Ações | botões visíveis, sem "…" | tudo no "…" | "Usar" visível, resto no "…" |
| Apagar | só dentro do editor | pelo "…" | pelo "…" (o editor não tem) |
| "+" da barra | menu com modelos | formulário manual | "Nova skill" |
| Estado desligado | "Pausada" + opacidade | "Desligado" | só opacidade |
| Vazio | modelos prontos | um botão | um botão |
| Espaçamento/raio | `Spacing.card*`, raio 12 | 14/12, raio 14 | 14/11, raio 14 |

A proposta é um padrão único: uma ação principal visível, o menu "…" com Editar e Apagar, "+" com "Do catálogo / Do
zero / Modelo" e o par "Ativa/Pausada" nas três telas.

**Parecer, linha a linha.** Tudo foi confirmado, e cada linha é um passo P independente, sem campo persistido.

- **Layout: Discordo de unificar.** Skills são texto longo. A grade fica onde está.
- **Ações: Concordo.** Conectores ganham "Testar" visível (2.9). O "…" das três telas fica com Editar e Apagar.
- **Apagar: Concordo.**
  - Os cartões de Rotinas ganham "…" com Editar e Apagar, mais um `confirmationDialog` que chama `model.deleteRoutine(id)` (`AppModel.swift:2015`).
  - No `SkillEditor`, o slot destrutivo já é "Descartar" no modo proposta (`SkillsView.swift:610`). Fica sem "Apagar".
- **"+" da barra: Em parte.** Conectores e Skills viram `Menu` que troca de aba (2.9). "Modelo" para Skills não existe como tipo, e as skills incluídas já fazem esse papel. Fica de fora.
- **Estado desligado: Concordo com um par único, mas "Ativa/Desativada".** "Pausada" sugere retomada, e as Rotinas já têm "Concluída".
  - Hoje o selo muda de nome em cada tela ("Pausada", "Desligado", nenhum). O interruptor diz "Ativa" em Rotinas e Skills e "Ativo" em Conectores (`ConnectorsView.swift:210`).
  - Selo e interruptor usam o par nas três telas, e a opacidade passa só para ícone e título (2.8, 2.10).
  - Em Rotinas, o selo "Pausada" pode ficar, porque lá a rotina é retomada mesmo. Decida uma vez.
- **Vazio: Discordo da necessidade.** O valor é baixo.
- **Espaçamento e raio: Concordo.**
  - **Como:** `Spacing.cardPadding` nas três (`ConnectorsView.swift:276`, `SkillsView.swift:227-228`) e raio 14 nas três, com `RoutinesView.swift:310` passando de 12 para 14.
  - **Depois:** com o token da 3.8, o raio vira `Radius.large`.

### 3.5 Ligação com o Orb

- **Rotina:** aparece na aba do painel do Orb, mas o cartão da página não leva de volta ao Orb.
  - **Parecer: Concordo.** É o mesmo botão do 2.8: avatar e nome levam à aba Rotinas do painel do Orb. **Esforço:** P.
- **Conector:** o painel do Orb só mostra "N ativos", sem dizer quais.
  - **Parecer: Concordo.** O helper já existe: `model.connectorNames(for:)` (`Catalog/OrbScope.swift:64`), escrito para isso. **Como:** use-o no `inlineLink` de conectores do painel (`BotInspector.swift`, por volta de `:470-480`), como `.help` ou como uma linha `.caption` com `OrbScopeText.list(names, limit: 3)`. **Esforço:** P.
- **Skill:** não aparece no painel do Orb em lugar nenhum. Só chega ao Orb pelo `/` do compositor.
  - **Parecer: Concordo.** `model.skills(for:)` (`OrbScope.swift:53`) dá a lista. **Como:** uma linha "Skills" no mesmo padrão do `inlineLink`, com os nomes e "Gerenciar", que faz `model.selection = .skills`. A lista é calculada fora do `body`. **Esforço:** P a M.

A proposta é uma seção "Skills e conectores deste Orb", só de leitura, no painel, com link para a página (A/M).

**Parecer:** as duas linhas acima formam essa seção, no fim do card "Pode usar".

### 3.6 Caminhos duplicados que divergem

- **Novo Orb** tem quatro entradas: ⌘N, "+" da lateral, paleta e convite da lateral. O convite se comporta de jeito diferente conforme a tela atual, e o "+" escreve o atalho no rótulo (`SidebarView.swift:191`).
  - **Parecer: Discordo.** As entradas fazem o mesmo (`showNewBot = true`). A diferença do convite é intencional e comentada (`SidebarView.swift:33-34`). O rótulo lê `AppShortcut.newBot.label`, então a tecla tem uma fonte só. Não mexer.
- **Ajustes** abre de cinco formas, e só `SettingsRouter.open(aba)` garante a aba certa.
  - **Parecer: Em parte.** Só o QuickAsk está errado (2.1). A engrenagem abrir na última aba é razoável.
- **Atalhos** aparecem em três listas: o sheet, Ajustes → Geral e o menu.
  - **Parecer: Em parte.** As três leem o mesmo `ShortcutCatalog` e não divergem. A repetição se resolve no item 9.
- **Criar Orb** tem três fluxos (wizard, cartão de proposta, importar) com campos diferentes.
  - **Parecer:** ver 2.6. Fica como está.
- **Apagar** usa quatro formas de confirmação (folha, `confirmationDialog`, só no editor, e categoria vazia sem perguntar).
  - **Parecer: Em parte.** As diferenças são de propósito: a categoria vazia não perde nada (`SidebarCategoryViews.swift:213-215`). A cópia do diálogo de grupo e o Apagar das Rotinas se resolvem em 3.3 e 3.4.

### 3.7 Vocabulário

| Conceito | Termos em uso | Sugestão |
|---|---|---|
| Nível de autonomia | Modo, Permissões | "Permissões", com o modo como valor |
| Sortear aparência | Sortear, Aleatório, Sortear aparência | "Sortear" |
| Editar aparência | Personalizar…, Desenhar, aba Aparência | "Personalizar" |
| Instruções do Orb | Como funciona, Instruções do Orb, Identidade | "Instruções" |
| Preferências | Preferências (Orb), Combinados (grupo) | manter, com subtítulo no grupo |
| Desconectar conta | Sair | "Desconectar" |
| Ir ao catálogo | Abrir a galeria, Explorar catálogo, Explorar o registro | "Explorar" |
| Erro | Erro, Não conectou, Não deu certo | "Não deu certo" + motivo |
| Parar | turno, Orb inteiro (tela ao vivo), conversa entre Orbs, grupo | verbo + objeto: "Parar Orb", "Parar grupo" |
| Ação de clique | toque | "clique" |

O vocabulário reservado (Pasta, Grupo, Espaço de trabalho, Categoria) tem dois vazamentos: a keyword "pasta" na
paleta, e "Pasta dos Orbs/de dados" em Ajustes.

**Parecer, linha a linha.** As ocorrências foram contadas com grep no texto da interface.

- **Nível de autonomia: Concordo.**
  - **Como:** troque `Picker("Modo")` (`BotInspector.swift:361`) e `Text("Modo")` (`Views/Multi/OrbProposalCard.swift:409, 413`) por "Permissões", e o card "Modelo e modo" (`BotInspector.swift:321`) por "Modelo e permissões".
  - **Atenção:** o texto **para o modelo** `Engine/SystemPrompt.swift:50` manda dizer "Geral → Permissões → Modo" **[conferido]**, e esse caminho já hoje não bate com o painel. `SystemPromptTests.swift:219` fixa essa frase. Atualize os dois para o caminho novo ("Geral → Modelo e permissões").
- **Sortear: Concordo.** Há cinco lugares **[conferido]**:
  - `Views/SheetsAndSettings.swift:210`: tire o argumento `randomTitle: "Aleatório"`;
  - `Views/Multi/WizardPreviewPane.swift:158`: troque por "Sortear";
  - `OrbProposalCard.swift:433` ("Sortear aparência") pode ficar.
- **Personalizar: Concordo.** "Desenhar" só aparece em `WizardPreviewPane.swift:152`, com o `.help` de `:155`. **Como:** "Personalizar", e o help vira "Abre a aba Aparência para personalizar o Orb".
- **Instruções: Discordo de "Instruções".**
  - **Por quê.** O termo colide no mesmo painel com "Instruções da pasta" (`BotInspector.swift:529, 541`) e com as instruções das skills (`SkillsView.swift:449`).
  - **Como:** unifique em "Como funciona", que já é o campo, o editor e o wizard. O único "Instruções do Orb" é um rótulo de acessibilidade em `OrbProposalCard.swift:364`, que vira "Como funciona". "Identidade" é o nome interno da página de memória e fica.
- **Preferências e Combinados: Concordo em manter.** O subtítulo é opcional.
- **Desconectar conta:** ver 2.2. Fica "Sair da conta".
- **Ir ao catálogo: Discordo.**
  - **Por quê.** Os termos levam a destinos diferentes. "Galeria" é a aba curada e "Explorar" é a busca no registro (`ConnectorsView.swift:22`, `CatalogParts.swift:29`).
  - **Como:** só "Explorar catálogo" (`SkillsView.swift:114`) pode virar "Explorar", e isso é opcional.
- **Erro: Discordo.** "Não deu certo: motivo" já é o padrão, e é persistido e lido com `hasPrefix`. Trocá-lo quebra `TurnReliabilityTests.swift:323-340`, `TranscriptActionsTests.swift:32-70`, `MemoryTests.swift:150` e o histórico salvo. "Não conectou" é específico e fica. No máximo, o selo "Erro" de `ConnectorsView.swift:481` vira "Não conectou".
- **Parar: Em parte.** Só o botão da tela ao vivo muda (2.4). Os outros "Parar" têm objeto claro no contexto, e o do compositor é fixado em testes.
- **Clique:** ver 2.6, seis ocorrências.
- **Vazamentos.** A keyword "pasta" é só sinônimo de busca (2.1). Em Ajustes, só "Pasta de dados" muda (2.2). Há um terceiro, mais brando: o subtítulo "Pasta de trabalho" da paleta (`CommandPalette.swift:114`), ao lado da seção "Espaço de trabalho". Ele pode virar só "Pasta".

### 3.8 Sistema visual

Medido em `Sources/Orb`:

- **608 `.system(size:)` fixos.** Os mais comuns são 12 pt (223) e 11 pt (153). Não há token de fonte além de `conversationFont` e `narrationFont`, e nada acompanha o tamanho de texto do sistema. A proposta começa pelos dois tokens de leitura (P) e depois cria tokens de legenda e rótulo (G).
  - **Parecer: Em parte. O total bate e a divisão não.**
    - **As contagens.** São 610 ocorrências em 69 arquivos: 12 pt são cerca de 230, 11 pt cerca de 175 e 13 pt 90. Há também 126 fontes semânticas (`.caption` e afins), então nem tudo é fixo.
    - **Como:**
      - Em `Theme.swift`, perto de `:68-72`, crie três tokens para 11, 12 e 13 pt, com nomes que não colidam com `.caption` e `.body` do SwiftUI.
      - Troque só os usos exatos, sem `weight`. O valor não muda.
      - Ícones e títulos ficam como estão.
    - **Risco:** só o tamanho do diff.
    - **Esforço:** P para os tokens. Fazer a fonte escalar com o sistema é G e fica para depois.
- **Cantos arredondados sem token.** Há 10 raios literais diferentes: 8 (36 usos), 10 (29), 12 (20), 14, 7, 6, 3, 16, 18. A proposta é `Radius.small/medium/card/bubble` no `Theme`.
  - **Parecer: Concordo com o token. Os números do relatório estão errados.**
    - **As contagens.** São 14 valores distintos, com 8 (43), 12 (29), 10 (29) e 14 (9) como os principais. Fora isso, `.card(radius:)` recebe 12, 14, 10 e 16.
    - **Como:** `enum Radius { small = 8, medium = 10, card = 12, large = 14 }` ao lado de `Spacing` (`Theme.swift:86-125`). Troque primeiro os argumentos de `.card`, de `.hoverCard` e de `.rect(cornerRadius:)` com esses quatro valores. Os raros (1–4, 6, 7, 9, 16, 18, 20) são formas pontuais e ficam.
    - **Esforço:** M, por ser mecânico e longo.
- **25 cores literais fora do `Theme` e de `Orbs/`.** São `Color.white.opacity(…)` em CatalogParts, OrbEditor, WizardPreviewPane e WelcomeView, sombras `.black.opacity(0,3)` repetidas e `0x070707` copiado em `OrbInk`. A proposta é criar `Palette.chipFill` e `Shadow.popover`.
  - **Parecer: Em parte.**
    - **A recontagem.** O `OrbEditor` está dentro de `Orbs/`, e o relatório o contou mesmo assim. Fora de `Orbs/`, há 10 `white.opacity`, 7 `black.opacity` e vários `Color(hex:)`, por exemplo em `MarketplaceGallery.swift:146-156` e `UsageSettings.swift:257`.
    - **Como:**
      - `Palette.chipFill = Color.white.opacity(0.06)`, usado em `CatalogParts.swift:34, 103, 239`. O modelo é `Palette.ghostHover`.
      - `Shadow.popover = Color.black.opacity(0.35)` nas cinco sombras: `ComposerView.swift:852`, `FindViews.swift:56`, `MentionPicker.swift:70`, `MemoryViews.swift:459` e `GroupBoardView.swift:149`. As duas de 0,3 passam a 0,35.
      - `Palette.canvasHex = 0x070707`, usado por `Palette.canvas` e por `OrbInk.canvas` (`GroupMessageBubble.swift:18`). `GroupScreensTests.swift:111-115` continua compilando.
    - **Esforço:** P.
- **`Palette.warn` acumula três significados** (alerta, orquestrador, esperando você).
  - **Parecer:** ver 2.7. Só a estrela muda. Junto, corrija a cor de falha do `ExchangeSheet` (3.2).
- **Três estilos para "ação secundária":** `.link`, `chipButton` e texto.
  - **Parecer: Em parte. Documente em vez de refatorar.**
    - **Por quê.** `chipButton()` é o `SecondaryPillStyle` pequeno (`SheetKit.swift:241-243`), e os estilos têm papéis diferentes: pílula para ação, `GhostStyle` para abrir algo, `.link` para endereço externo.
    - **Como:** escreva a regra num comentário em `Theme.swift`, ao lado dos estilos. A auditoria dos 16 `.link` fica para depois.
- **Pontos fortes que devem ficar:** Reduce Motion respeitado em cerca de 350 pontos, 321 `.help`, `SheetKit` unificando folhas, `OrbScopePicker` compartilhado, catálogo único de atalhos e boas-vindas em etapas.
  - **Parecer:** confirmado, com 341 `.help`.

---

## 4. Ordem sugerida (revista em 24/10)

1. **Segurança de decisão:** feito em `97c510b`.
2. **Pedidos de membro no grupo (item 2, M).** É o próximo. Junto vêm a faixa de presença com altura reservada, o ramo morto de `showApprovalOwner` e a frase de `REVISAO-GRUPOS-2026-10-16`.
3. **Descoberta e acessibilidade (P, um commit por tela).**
   - **Chat e compositor:** "Refazer" no menu e no VoiceOver (10), dica de teclas no `accessibilityHint` e erro do compositor dispensável.
   - **Grupo:** Esc, Tab e foco no compositor (11), membros clicáveis, menções com avatar, help do "Adicionar Orb", estado na linha de tarefa e Copiar na bolha.
   - **Casca:** QuickAsk abrindo em Modelos, `hint` → `faint`, "Ajustes" e "Grupos" na paleta, `new-group` só com 2 Orbs e ⌘/.
   - **Painel do Orb:** link "Como funciona" alcançável pelo Tab, erro ao renomear e "Apagar Orb…" mais visível.
4. **Vocabulário (P, uma passada).**
   - **Na interface:**
     - "toque" vira "clique" (6 ocorrências);
     - "Aleatório" vira "Sortear";
     - "Desenhar" vira "Personalizar";
     - "Modo" vira "Permissões";
     - a aba "Permissões" vira "Acesso ao Mac";
     - "Pasta de dados" vira "Local dos dados";
     - "Sair" vira "Sair da conta";
     - "Desligado" vira "Desativado";
     - os botões da tela ao vivo, e "Ver" vira "Voltar".
   - **Fora da interface, mudam junto:** `SystemPrompt.swift:50`, `SystemPromptTests.swift:219`, `MacPermissions.swift:492`, `AjustesPolishTests.swift:230` e `ResetOrbSheet.swift:190`.
5. **Fluxos (M).**
   - **Wizard:** confirmar o descarte e sair do limite (5).
   - **Skills:** propostas na página (6), selo "Desativada", linha clicável e prévia com "Tentar de novo".
   - **Ajustes:** atalhos recolhidos (9, etapa 1).
6. **Espaço de trabalho com padrão único (P em passos).**
   - **Rotinas:** "…" com Apagar, opacidade só no título, selo "Falhou", link ao Orb e cron legível.
   - **Conectores:** "+" em menu, "Testar" visível e falha de teste que fica.
   - **As três telas:** o par "Ativa/Desativada" e o raio 14.
   - **Painel do Orb:** skills e conectores listados.
7. **Tokens (M).** `Radius`, `chipFill`, `Shadow.popover`, `canvasHex` e os tokens de 11, 12 e 13 pt.
8. **Depois, ou só se pedirem (M/G).**
   - **Ajustes e paleta:** aba "Orbs" (9, etapa 2) e conversas na paleta (8).
   - **Grupos e trocas:** `ExchangeSheet` com `GroupMessageBubble` e anexos no grupo.
   - **Catálogos e listas:** busca nas skills instaladas, a galeria levando a Instalados e rotinas agrupadas por Orb.
   - **Painel do Orb e lateral:** "Desfazer mudanças" na aparência, renomear e reordenar pela lateral, resumo do plano concluído.

**Fora da fila, porque o parecer discorda ou o problema já foi resolvido:**

- confirmação de Editar/Refazer;
- anel do plano igual ao medidor;
- "Pulada";
- folha do wizard de 820 pt;
- ⌥⌘G com menos de 2 Orbs;
- "Desligado com dois sentidos" (fica só a troca de termo);
- janela de Ajustes de tamanho fixo;
- caminhos duplicados do Novo Orb;
- botão "Criar" do cartão desenhado à mão;
- "Abrir no assistente";
- QuickAsk com grupos;
- "Instruções" e "Explorar" no vocabulário;
- prefixo "Não deu certo";
- unificar o layout das três telas;
- "Modelo" de skill;
- margem de 90 × 40;
- Esc duplo na edição.

## 5. O que não foi verificado

- **Capturas.** Nenhuma tela foi capturada. Os itens que dependem de largura pedem `--snapshot` em 460 e 1100 pt: as abas em 244 pt, o rodapé da lateral em 240 pt, o chip de permissão com rótulo, os botões da tela ao vivo, a barra de pedidos do grupo e o badge numérico.
- **Leitura parcial.** Ficaram de fora `ImportPanel`, `OrbEditor` depois da linha 300, `SelectableProse`, `MarkdownBlockViews`, `AttachmentViews`, `ModelPopover`, `Tips`, `ProfileSettings` e `LiveScreenLayerView`.
- **Testes.** Nenhum teste rodou, porque nada de código mudou. O parecer de 24/10 também foi só leitura.
- **Números de linha.** São os de `97c510b` e podem andar com a próxima mudança.
