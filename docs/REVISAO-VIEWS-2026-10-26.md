# Revisão das Views: polimento, RAM/CPU e design (26/10/2026)

Esta revisão cobre os 72 arquivos de `Sources/Orb/Views/` (sem as subpastas `Groups/` e `Multi/`), cerca de 27 mil linhas. Foram 10 agentes Opus 5.5 com esforço médio, um por área, todos só lendo o código. Cada lote foi revisto por três ângulos: polimento (reuso, simplificação, código morto), RAM/CPU e design (tokens, coerência, Reduzir movimento, acessibilidade).

Conferi na sessão principal estes achados, e todos estão certos:
- o cancelamento de provedor gravado como falha;
- a releitura da pasta em toda aba;
- a cópia da saída do comando a cada render;
- o composer observando a conversa.

Os demais são relatos dos agentes, com linha e arquivo. Confira no código antes de mexer.

**Escala:** impacto A (alto), M (médio), B (baixo); esforço P (pequeno), M (médio), G (grande).

## Diagnóstico geral

Nenhum lote tem problema grave de CPU: o caminho quente do streaming (`LiveText`, `TranscriptRow` `Equatable`, `TextFade`, `ParagraphStack`) foi conferido e está bem isolado. Os custos reais estão em outros caminhos:

- **Algo pesado a cada tecla ou a cada flush:**
  - cron do editor de rotina;
  - composer observando a conversa;
  - filtro do marketplace;
  - colar a resposta na importação;
  - blocos de código e tabelas em streaming;
  - saída inteira copiada em toda linha de comando.
- **Trabalho de disco ou de rede repetido:**
  - releitura da pasta com `git status` em toda aba;
  - detecção de primeira execução duplicada, a cada troca de Orb;
  - `URLSession` que nunca é invalidada;
  - Apple Event ao Mail a cada troca de aba.

O que mais se repete é design e polimento:
- **Fontes, cores e raios literais.** `.caption` e `.callout` do sistema (10 pt) aparecem ao lado de `Typography` (11/12/13). Há cerca de 35 legendas assim só em Ajustes, e `.system(size: 11, weight: .medium)` aparece 31 vezes.
- **Alvos de clique de 10 a 14 pt sem hover.** São `xmark`, lápis, ⓘ, copiar e as setas da busca, que deveriam usar `CircleGhostStyle`.
- **Helpers reimplementados à mão:** `.motion`, `.animateChanges`, `hoverFill`, `hoverCard`, `FoldChevron` e `sectionTitleStyle`.
- **Componentes copiados que já divergiram:**
  - campo de busca (3 vezes);
  - botão de enviar (3 vezes);
  - menu "…" (4 vezes);
  - linha de chave de API (2 vezes);
  - atalhos de aprovação (4 vezes);
  - chevron (5 vezes);
  - campo de nome na própria linha (2 vezes).
- **Acessibilidade:**
  - `onTapGesture` sem teclado nem ação de VoiceOver;
  - toggles sem dizer de qual item são;
  - um `combine` que esconde "Cancelar".

## Bugs encontrados de passagem

Corrigir primeiro: são poucos e pequenos.

1. **ProviderSettings:405.** Um `URLError.cancelled` é gravado como falha do provedor, e a falha é gravada duas vezes.
2. **ProviderSettings:136.** O login do ChatGPT não é cancelado ao fechar Ajustes e fica preso à porta por até 300 s.
3. **SkillsView:442/453.** Uma busca cancelada pode deixar `isLoading` preso. `ExploreSearch` duplica `RegistryQuery`.
4. **FirstRunCard:529/820.** Uma chave colada com quebra de linha habilita "Conectar", e o clique não faz nada.
5. **FirstRunCard:630-647.** No VoiceOver não dá para cancelar o login nem abrir "Como instalar".
6. **SkillsView:392 / CatalogParts:287.** "Nenhum resultado" pisca antes do carregamento em toda busca.
7. **RoutinesView:760.** A conversa ao vivo de uma rotina não acompanha o fim.
8. **ConnectorsView:312.** Um conector desligado esmaece o próprio switch que o religa.

## Ordem sugerida

| Onda | O quê | Por quê |
|---|---|---|
| 1 | Os 8 bugs acima | São pequenos, e o usuário sente. |
| 2 | RAM/CPU de impacto M: composer (L3-1, L3-2), editor de cron (L6-1), pasta só na aba Pasta (L4-1), memória sem ler todos os Orbs (L4-2), saída do comando (L1-1), detecção e `URLSession` (L10-3, L10-4), marketplace (L7-4), `ModelPopover` (L7-3), importação (L10-2), Mail (L7-14) | Custo real em cada tecla, em cada turno ou no disco. |
| 3 | Componentes comuns: `SearchBox`, `SendArrowButton`, `MoreMenu`, `SavedKeyField`, `.approvalKeys`, `FoldChevron(size:)`, `InlineNameField`, `MessageActionStyle` | Tiram as cópias que já divergiram e fecham o design de uma vez. |
| 4 | Tokens: legendas `.caption` → `capabilityCaption`/`Typography.small`; fontes literais; `Typography.code`; uma largura de popover; espaçamentos de folha | Uma passada mecânica por arquivo, conferida por `--snapshot`. |
| 5 | Acessibilidade e alvos: `CircleGhostStyle` nos ícones soltos; `accessibilityAction` nos `onTapGesture`; rótulos dos toggles; dicas de atalho por estado | Acessibilidade e consistência do hover. |
| 6 | Helpers de movimento (`.motion`, `animateChanges`, `hoverFill`, `hoverCard`), comentários desatualizados e código morto | Polimento, sem mudança visível. |

Os blocos de código e tabelas em streaming (L2-1, L2-2) ficam como estão até haver uma medição: o custo cresce com o tamanho, mas só pesa em respostas longas. Vale um benchmark antes.

## Achados por lote

Cada lote traz até 15 achados, do mais ao menos valioso. As referências da ordem sugerida (L3-1 etc.) são "lote-número".

## Lote 1: transcrição, cartões de aprovação e pergunta

| # | Onde | Cat. | Imp. | Esf. | Achado | Correção |
|---|---|---|---|---|---|---|
| 1 | TranscriptViews:845-852, 932 | RAM-CPU | M | P | `ToolCallLine` calcula `lineWords` duas vezes e, em todo comando terminado, copia a saída inteira (até 20 mil caracteres) em `CommandOutput.init` a cada render, inclusive recolhida e na rolagem; `PermissionKey` compara a saída inteira. | Calcular uma vez; `CommandOutput` só aberto ou com falha; `utf8.count` na key. |
| 2 | TranscriptViews:2119-2156; QuestionCard:183-218; OrbProposalCard:585-610; LiveScreenViews:216 | Polimento | M | M | Atalhos de aprovação (guard, leitura do responder, `press`, `leaving`, pulso) copiados em 3 ou 4 cartões. | `.approvalKeys(...)` em ApprovalKeyboard; `AnyTransition.cardLeaving`. |
| 3 | TranscriptViews:1648-1661 | Polimento/Design | M | P | `NoticeActionStyle` refaz as pílulas sem hover nem estado desabilitado: são as únicas pílulas do chat mortas ao passar o ponteiro. | `PrimaryPillStyle` / `SecondaryPillStyle`. |
| 4 | TranscriptViews:896, 1250, 1390, 1601, 2087 | Polimento/Design (RM) | M | P | Chevron de dobra copiado 5 vezes; já existe `FoldChevron`. O de `providerDetail` gira mesmo com Reduzir movimento. | `FoldChevron(size:)`. |
| 5 | TranscriptViews:563-659 | Polimento/Design | M | P | Copiar, ação e "Citar" repetem o visual, sem hover nem ponteiro; o `CopyButton` não troca o rótulo do VoiceOver depois de copiar. | `MessageActionStyle(shape:)` com `hoverFill`. |
| 6 | QuestionCard:76-94 | Design (a11y) | M | P | O VoiceOver lê "Pular, esc"; ⌘↩ responde, mas "Responder" não mostra a tecla. | `accessibilityLabel("Pular")`; tecla e dica em "Responder". |
| 7 | TranscriptViews:1991-2100; QuestionCard:86-87 | Design | B | P | Dicas de atalho sempre visíveis, mesmo quando a tecla não responde aquele cartão; "Mostra o pedido" com o pedido já aberto. | Condicionar a `showsKeys`; texto por estado. |
| 8 | TranscriptViews (várias linhas); QuestionCard:63, 115 | Design | B | P | Monoespaçado em 3 tamanhos; o código inline da ação tem um fundo diferente do código das respostas. | `Typography.code` / `codeSmall`; um fundo só. |
| 9 | TranscriptViews:180-182 | Design (a11y) | B | P | O VoiceOver diz "Falhou swift build…, falhou". | Sufixo só sem o prefixo. |
| 10 | TranscriptViews:1997-2065 | Design | B | M | O pill dividido "Permitir ⌘↩" não tem hover nem estado pressionado. | Hover e pressionado como `PrimaryPillStyle`. |
| 11 | TranscriptViews:1785, 2120; AppModel+Approvals:13-25 | RAM-CPU | B | P | `pendingApprovals` percorre a conversa inteira duas vezes por render e a cada tecla. | Calcular uma vez; buscar de trás para frente. |
| 12 | TranscriptViews:322-331 | Design | B | P | "Parar e enviar" com ícone preenchido e azul ao lado de um ícone de traço. | `arrow.up.circle` e cor padrão. |
| 13 | TranscriptSamples:4 | Polimento | B | P | Comentário com a lista de modos desatualizada. | Atualizar. |

## Lote 2: lista do chat, texto em streaming, busca

| # | Onde | Cat. | Imp. | Esf. | Achado | Correção |
|---|---|---|---|---|---|---|
| 1 | MarkdownBlockViews:213, 227 | RAM-CPU | M | M | Num bloco de código em streaming, cada flush quebra o código inteiro em linhas e compara os pedaços fechados com `String ==`: o custo do flush cresce com o código (o comentário diz o contrário). | Guardar os pedaços fechados e recalcular só a cauda. |
| 2 | MarkdownBlockViews:313, 341, 379 | RAM-CPU | M | M | Numa tabela em streaming, cada flush mede todas as células (`NSString.size`), copia as linhas e monta o grid duas vezes no `ViewThatFits`. | Cachear as larguras das linhas fechadas; `max` só na cauda. |
| 3 | FindViews:96-107 | Design | M | P | Setas, lista e fechar da busca em `.plain`, sem hover nem resposta ao clique. | `CircleGhostStyle(side: 24)`. |
| 4 | QueuedMessages:121, 138 | Design | M | P | A dica dos botões só aparece na primeira bolha de um grupo: nas outras (inclusive "Parar e enviar") o hover não mostra nada. | Mostrar a linha também no hover. |
| 5 | QueuedMessages:115-133 | Design (a11y) | M | P | Os botões invisíveis continuam expostos e repetem as `accessibilityActions`: o VoiceOver acha cada ação duas vezes. | `accessibilityHidden` nos botões. |
| 6 | SelectableProse:343 | RAM-CPU | B-M | P | `textStorage.string as NSString` copia o texto a cada fragmento de linha (O(linhas × tamanho) por layout, caminho quente). | `textStorage.mutableString`. |
| 7 | SelectableProse:81-181 | RAM-CPU | B | P | `NSColor(Palette.*)` e a imagem de checkbox recriados a cada flush. | `static let`. |
| 8 | ChatView:141 | Design | B | P | O hover da linha de compactação troca de cor sem fade. | `hoverFill`. |
| 9 | ChatView:45, 999 | Polimento | B | P | Reimplementam `.motion`; o overlay de soltar aparece seco com Reduzir movimento. | `.motion`. |
| 10 | ChatView:913 | Design (a11y) | B | P | O VoiceOver lê o nome do símbolo da sugestão. | `accessibilityHidden`. |
| 11 | EmptyChatContent:38 | Design (texto) | B | P | Frase de ~110 caracteres com troca de sujeito. | "Conversa nova: o Orb não vê as outras, mas mantém a memória, a pasta e as ferramentas." |
| 12 | ChatView:55-57 | Polimento | B | P | Folha de trabalho paralelo de outro Orb abriria vazia (risco latente). | `Binding` filtrado pelo `botID`. |
| 13 | ChatView, FindViews, MarkdownBlockViews (várias linhas) | Design | B | P | `.system(size: 11, weight: .medium)` literal (31 vezes no projeto); `.foregroundColor` obsoleto. | `Typography.small.weight(.medium)`; `.foregroundStyle`. |
| 14 | ChatView:81 | RAM-CPU | B | P | O body inteiro do chat depende de `showInspector` por causa de uma dica. | Botão do painel numa view própria. |

## Lote 3: campo de mensagem, anexos, ditado, medidor de contexto

| # | Onde | Cat. | Imp. | Esf. | Achado | Correção |
|---|---|---|---|---|---|---|
| 1 | ComposerView:404-408, 83 | RAM-CPU | M | P | `unansweredSteered` roda a cada tecla e faz o composer inteiro observar os itens da conversa: ele se redesenha a cada passo do turno. | Atalhos numa subview `ComposerShortcuts(botID:)`. |
| 2 | ComposerView:130-349 | RAM-CPU | B-M | P | A cada tecla: `workingChatTitle` até 4 vezes, `runningRoutineName` 2 vezes e `live(botID)` cerca de 8 vezes. | Calcular uma vez no início do body. |
| 3 | ComposerView:669-684, 373 | Polimento | B | P | Regra de habilitação duplicada; `pressVisual` calculado duas vezes. | `@Environment(\.isEnabled)`; um `let`. |
| 4 | ComposerView:223-228, 243-247 | Design (a11y) | M | P | "Fechar aviso" e "Cancelar edição" com alvo de 11 a 13 pt e sem hover. | `CircleGhostStyle(side: 24)`. |
| 5 | ComposerView:3-4, 19; ContextMeterViews:3-5 | Polimento | B | P | Comentários citam um cartão "conversa longa" que não existe e dizem que o composer não lê os ajustes do Orb, mas lê. | Corrigir. |
| 6 | ComposerChips:3-26; ComposerSupport:12-16 | Polimento | B | P | Comentários errados sobre o chip de permissão; `PermissionChipText.label` só é usado em teste. | Remover e corrigir. |
| 7 | ContextMeterViews:319-325 | Polimento | B | P | O campo refaz `popoverSearchField`. | Usar o helper. |
| 8 | ComposerView:190, 314, 362, 439; ContextMeterViews:150, 169; DictationButton:37 | Polimento | B | P | Reimplementam `.motion`, `.quiet` e `.adapted`. | Helpers. |
| 9 | ComposerChips:397 | Design | B | P | O tooltip diz "Voltar para" quando o botão diz "Responder". | Tooltip por estado. |
| 10 | ComposerView, ComposerChips, ContextMeterViews | Design | B | P | Fontes literais; títulos de popover da mesma barra com 11 e 12 pt. | Tokens; um tamanho só. |
| 11 | ComposerView:601-648 | Polimento | B | P | Overlay de remover copiado em dois chips. | Padrão no `RemoveButton`. |
| 12 | ContextMeterViews:160 | Polimento | B | P | Ternário redundante. | `reading.tone.color`. |
| 13 | DictationButton:11-31 | RAM-CPU | B | P | O botão inteiro redesenha a cada buffer do microfone (10 a 12 por segundo) enquanto se dita. | Halo em subview própria. |
| 14 | ComposerView:863; AttachmentViews:181 | RAM-CPU | B | P | Dicionário criado a cada tecla; `isPicture` filtrado duas vezes. | `static let`; um laço só. |
| 15 | ModelPopover:84; ComposerChips:131, 250; ContextMeterViews:234 | Design | B | P | Popovers da mesma barra com 320, 330 e 340 de largura. | Uma constante. |

## Lote 4: painel do Orb

| # | Onde | Cat. | Imp. | Esf. | Achado | Correção |
|---|---|---|---|---|---|---|
| 1 | BotInspector:91-96 | RAM-CPU | M | P | A `.task(id: FilesKey)` relê a pasta com `refresh: true` (varredura e `git status`) a cada troca de Orb, em qualquer aba; só a aba Pasta usa o resultado. O comentário está velho. | `guard tab == .folder`, como em `FolderWatch`. |
| 2 | MemoryViews:29 | RAM-CPU | M | P | `model.bot(botID)` lê a lista de todos os Orbs: a aba Memória refaz o body (grupos e resumo) quando qualquer Orb muda. | Receber `canSummarize` do pai, ou usar `liveBot`. |
| 3 | BotInspector:1015-1027 | Design (a11y) | M | P | O papel em repouso é um `Text` com `onTapGesture`: sem teclado. | `Button` plano, ou `focusable` com Return/Espaço. |
| 4 | MemoryViews:276-277; BotInspector:1311-1312 | Design (a11y) | M | P | Abrir uma lembrança ou o relatório de uma rotina só funciona com clique: o VoiceOver não chega aos detalhes. | `accessibilityAction(named:)`. |
| 5 | BotInspector:1100-1102 | Design | M | M | Clique simples e duplo empilhados: o "Mostrar no Finder" espera o tempo do duplo clique (0,3 a 0,5 s), e a linha não tem foco. | `Button` com `hoverFill` e `simultaneousGesture`, ou "Abrir" só no menu. |
| 6 | TaskPlanRing:27, 33-34 | Polimento | M | P | Hover reimplementado, animando também o número e o anel. | `.hoverFill(... resting:)`. |
| 7 | TaskPlanRing:22, 35 | Design (RM) | B | P | `.animation` crua e `numericText` sem Reduzir movimento. | `.motion` e `.opacity` com RM. |
| 8 | TaskPlanRing:20, 104 | Design | B | P | Fontes literais. | `Typography.small` / `label`. |
| 9 | InspectorFold:26 | Polimento | B | P | `FoldChevron` repete a curva de `FoldMotion`. | `FoldMotion.animation(reduceMotion:)`. |
| 10 | BotInspector:1149 | RAM-CPU | B | P | Cada `RoutineRow` observa a lista inteira de rotinas e repete a busca do pai. | Usar `routine` direto. |
| 11 | BotInspector:851 | Polimento | B | P | `.id(bot.id)` redundante com `contentKey`. | Remover. |
| 12 | BotInspector:403-408 | Design (a11y) | B | P | ⓘ com alvo de ~11 pt, sem hover. | `CircleGhostStyle(side: 20)`. |
| 13 | BotInspector:728 | Design + RAM-CPU | B | P | Frase confusa ("escreve sem perguntar em 'Perguntar antes'") e `availableURL` com `fileExists` em laço na main a cada render. | Reescrever; calcular uma vez na task. |
| 14 | BotInspector:86/109, 105-107 | Polimento | B | P | Dois `onChange(of: tab)`; releitura completa no fim do turno, que o `FolderWatcher` já cobre. | Juntar; conferir o watcher e remover. |
| 15 | MemoryViews:125-127 | Design | B | P | Frase de preferências que não cabem, com plurais em linha, difícil de ler. | Helper testável e texto mais simples. |

## Lote 5: lateral esquerda, raiz, entradas, paleta, pergunta rápida

| # | Onde | Cat. | Imp. | Esf. | Achado | Correção |
|---|---|---|---|---|---|---|
| 1 | QuickAskView:408-413 | Design (a11y) | M | P | "Fechar resposta" com alvo de ~10 pt e sem hover. | `CircleGhostStyle(side: 20)`. |
| 2 | QuickAskView:368-373 vs 396-401 | Design | M | P | Duas linhas "Nome: fazendo X" no mesmo painel, com estilos diferentes (10 pt sem brilho contra 12 pt com shimmer). | Mesmo estilo, shimmer e cor. |
| 3 | QuickAskView:197-202; WizardChatView:141; GroupComposer:90 | Polimento | M | M | Botão de enviar copiado em 3 lugares e já divergente (22 ou 24 pt, `hint` ou `faint`). | `SendArrowButton` comum. |
| 4 | SidebarChatList:187-227; SidebarCategoryViews:254-311 | Polimento | M | M | `ChatTitleField` e `CategoryNameField` repetem a mesma lógica de edição. | `InlineNameField` comum. |
| 5 | CommandPalette (várias linhas); QuickAskView (várias linhas) | Design | M | P | Fontes literais, três variações de tecla e `.caption` de 10 pt. | Tokens; `Font.keyCap`; `Radius`. |
| 6 | CommandPalette:225-231, 385-387 | Polimento/Design | M | P | Cabeçalhos de seção feitos à mão (11 pt) contra `sectionTitleStyle` (12 pt). | `.sectionTitleStyle()`. |
| 7 | QuickAskView:438-449 | RAM-CPU | B/M | P | `ReplyExcerpt` refaz o recorte, o parse de markdown e as concatenações a cada token. | Montar uma vez; fallback preguiçoso. |
| 8 | CommandPalette:327-371 | Design | M | P | As linhas da paleta não reagem ao ponteiro. | `hoverFill`. |
| 9 | SidebarView:652; SidebarCategoryViews:171, 278; QuickAskView:412 | Polimento | B | P | Fonte do chevron literal repetida. | Token ao lado de `SectionPlus.glyph`. |
| 10 | SidebarView:56-110 | RAM-CPU | B | P | `Set`s e seções recalculados mais de uma vez por body (teórico). | `let` no início. |
| 11 | SidebarCategoryViews:195; SidebarChatList:151 | Polimento | B | P | Reimplementa `.motion`; `.animation` redundante com o `hoverFill`. | Helper; remover. |
| 12 | SidebarCategoryViews:213, 216 | Design (texto) | B | P | "Expandir/Recolher" e "Renomear" sem reticências destoam do menu do Orb. | "Mostrar Orbs"/"Recolher Orbs", "Renomear…". |
| 13 | SidebarCategoryViews:169, 175, 320 | Design | B | P | O nome da categoria começa em 44 pt, e os Orbs em 46. | Coluna de 28 pt. |
| 14 | ColumnSizing:41; ChatsSnapshots:51; SidebarView:630 | Polimento | B | P | Comentário que não bate; captura que ignora `paneWidth`; "14:30" que não vira "Ontem" à meia-noite numa linha `Equatable`. | Corrigir o comentário; `paneWidth`; incluir o dia no valor comparado. |

## Lote 6: Rotinas e Conectores

| # | Onde | Cat. | Imp. | Esf. | Achado | Correção |
|---|---|---|---|---|---|---|
| 1 | RoutinesView:860-866, 976, 995, 1004 | RAM-CPU | M | P | O editor avalia `scheduleProblem` duas vezes e `next()` mais uma a cada tecla. No modo cron isso percorre até 8×366 dias: dezenas de ms por tecla numa expressão rara. | `@State` atualizado em `onChange(of: draftSchedule)`. |
| 2 | ConnectorsView:157 | Design (RM) | M | P | `scrollTo` animado mesmo com Reduzir movimento. | `ScrollMotion.animation(reduceMotion:)`. |
| 3 | RoutinesView:58, 238, 284 | Polimento | M | P | O toggle refaz `setRoutineEnabled`; é só por isso que existe o `@Binding` e o laço em `$model.routines`. | Callback `onToggle`, `Routine` por valor. |
| 4 | RoutinesView (várias linhas) | Design | M | M | O cartão de rotina usa `.caption`/`.callout` do sistema; o de conector, ao lado, usa `Typography`: duas escalas em páginas irmãs. | `Typography.small/label/text`. |
| 5 | ConnectorsView:312 | Design | M | P | Um conector desligado esmaece o cartão inteiro, inclusive o switch que o religa (a rotina esmaece só o nome, de propósito). | Opacidade só no bloco de ícone, nome e comando. |
| 6 | RoutinesView:284; ConnectorsView:251 (também SkillsView:337, BotInspector:1169) | Design (a11y) | M | P | Toggles "Ativa"/"Ativo" sem dizer de qual item são. | `accessibilityLabel("Ativar \(nome)")`. |
| 7 | RoutinesView:760 | Design | M | P | A conversa ao vivo da rotina não acompanha o fim: as mensagens novas ficam fora da tela. | `defaultScrollAnchor(.bottom)` para início e mudanças de tamanho. |
| 8 | ConnectorsView:1216-1226 | Polimento | M | P | `NSOpenPanel().runModal()` solto; o resto usa `.fileImporter`. | `.fileImporter`. |
| 9 | RoutinesView:332-346; ConnectorsView:283-304; SkillsView:350; GroupPresenceStrip:106 | Polimento | B/M | P | O menu "…" está copiado em 4 lugares, com alvo de 26×22. | `MoreMenu` com alvo de 28×28. |
| 10 | RoutinesView:274-280; ConnectorsView:541-554 | Polimento/Design | B | P | O selo de modo e o `InUseBadge` refazem o `CatalogBadge` com outro fundo. | `CatalogBadge`. |
| 11 | RoutinesView:602-715 | Polimento | B | P | `PreferenceKey` + `GeometryReader` onde o projeto usa `onGeometryChange`; um `init` só para estado. | `onGeometryChange`; apagar a key e o init. |
| 12 | ConnectorsView:828-1187 | RAM-CPU | B | P | `inputsByName` remonta o dicionário a cada acesso (O(n²) por tecla). | Guardar uma vez. |
| 13 | RoutinesView:758-784 | Design | B | P | Rotina apagada com a folha aberta deixa uma folha vazia. | `ContentUnavailableView`. |
| 14 | RoutinesView:60, 239 | Polimento (regra) | B | P | `RoutineCard` recebe o `Bot` inteiro. | Passar nome e orb. |
| 15 | ConnectorsView:1434, 1458 | Design (a11y) | B | P | O VoiceOver lê "Valor de Authorization" onde se vê "Chave de acesso"; placeholder "NOME" em caixa alta. | Mesmo texto; "Nome". |

## Lote 7: Skills, galerias, marketplace, escolha de modelo

| # | Onde | Cat. | Imp. | Esf. | Achado | Correção |
|---|---|---|---|---|---|---|
| 1 | SkillsView:392; CatalogParts:287 | Design | A | P | "Nenhum resultado" pisca por 350 a 450 ms antes do esqueleto, a cada busca do zero (`isLoading` só liga quando a busca começa). | `.loading` até o termo atual ter sido buscado. |
| 2 | SkillsView:453; CatalogParts:306 | Polimento (bug) | M | P | `ExploreSearch` e `RegistryQuery` são a mesma função; o `search()` de Skills não trata cancelamento no `defer`, e `isLoading` pode ficar preso. | Apagar `ExploreSearch`; copiar o `defer`; juntar os testes. |
| 3 | ModelPopover:65 | RAM-CPU | M | P | `onGeometryChange` grava a altura a cada remedição e refaz a listagem de centenas de modelos. | Limitar a 320 no transform. |
| 4 | MarketplaceGallery:58 | RAM-CPU | M | M | O filtro dobra os textos de todos os bots a cada `body` (cada tecla); as categorias são recontadas sempre. | Guardar os textos dobrados e as categorias ao carregar. |
| 5 | SkillsView:179; CatalogParts:175; MarketplaceGallery:93 | Design/Polimento | M | M | Campo de busca copiado 3 vezes e já divergente (padding, raio, fonte). | `SearchBox` comum. |
| 6 | ConnectorGalleryView:172-181 | Design | M | P | Hover feito à mão; com Reduzir movimento a cor salta; animação larga demais. | `.hoverCard`. |
| 7 | ModelPicker:153-191 | Design/Polimento | M | P | Os cabeçalhos da lista de Ajustes diferem dos do composer (mesma linha); o filtro refaz `groups`. | Estilo de cabeçalho do `ModelPopover`; tokens. |
| 8 | ModelPicker:14 | Polimento | M | P | `inMenu` é código morto, e o doc descreve um caminho que não existe. | Remover. |
| 9 | SkillsView:291-300 | Design (a11y) | M | P | Botão de copiar com alvo de ~12 pt. | `CircleGhostStyle(side: 22)`. |
| 10 | LocalConnectorSheet:54, 158 | Polimento | B | P | `if` sempre verdadeiro; ramo `nil` que nunca roda. | Remover. |
| 11 | LocalConnectorSheet:35, 149-156 | Polimento | B | P | Reimplementa `animateChanges`; URL de privacidade montada à mão. | Helper; `MacPrivacyPane`. |
| 12 | ModelPopover:98-102; ModelPicker:16-21 | Polimento | B | P | Repetem `modelName` / `modelInfo`. | Usar os helpers. |
| 13 | CatalogParts:235-246 | Design | B | P | `ChipStyle` com cor literal e sem hover. | `chipFill` + `hoverFill`. |
| 14 | ConnectorGalleryView:36 | RAM-CPU | B | P | Cada volta à aba manda um Apple Event ao Mail; grava estado sem mudança. | Subir o `.task`; gravar só se mudou. |
| 15 | ConnectorGalleryView:164 | Polimento | B | P | O ícone é escolhido comparando o texto da interface. | Símbolo no modelo. |

## Lote 8: Ajustes, uso, perfil, contexto, kit de folhas

| # | Onde | Cat. | Imp. | Esf. | Achado | Correção |
|---|---|---|---|---|---|---|
| 1 | SettingsView:167-174, 383-424 e ~35 lugares (UsageSettings, ContextSettings, SheetsAndSettings, ClaudeCodeSettings) | Design/Polimento | A | M | Cerca de 35 legendas em `.caption` + `.secondary` (10 pt, cinza do sistema) contra `FormFootnote`/`capabilityCaption` (11 pt, `Palette.muted`): dois cinzas e dois tamanhos no mesmo Form. O rótulo do toggle está copiado 5 vezes. | `.capabilityCaption()` em todas; helper `toggleLabel(title, detail)`. |
| 2 | UsageSettings:456-488 (`PriceEditor`) | Design | M | P | Botões no estilo do sistema, `.roundedBorder` e `.headline`/`.callout`: destoa de todas as folhas. | `ActionRow` com `GhostStyle`/`PrimaryPillStyle`; campos `.plain` sobre `raised`; `Typography`. |
| 3 | SheetsAndSettings:238-303; UsageSettings:91-290 | Polimento | M | P | Reimplementam `.motion(value:)` e `.animateChanges(of:)`. | Usar os helpers. |
| 4 | UsageSettings:344-350 | Design | M | P | Lápis "Corrigir o preço" com `.borderless`: alvo de uns 14 pt, sem hover. | `CircleGhostStyle(side: 24)`. |
| 5 | ContextSettings:70 | Design | M | P | "Esquecer" com bordered padrão, enquanto os vizinhos usam `chipButton`. | `.chipButton()`. |
| 6 | SettingsView:571 | Design | M | P | O `linkColor` padrão é `.accentColor`; o app usa `Palette.accentText` (61 usos), mais legível. | Padrão `Palette.accentText`. |
| 7 | SheetsAndSettings:127-319 | Design | B-M | P | Paddings e larguras literais; `modePicker` com 16 e `tabPicker` com 20: as pílulas não alinham. | Tokens de `Spacing` e constantes de layout. |
| 8 | ProfileSettings:117-121, 86 | RAM-CPU | B | P | `LimitedTextField` regrava o mesmo valor em `model.profile` (didSet, gravação de estado, invalidação). | Gravar só se mudou. |
| 9 | ProfileSettings:61-64 | Polimento | B | P | `about.count` três vezes por render; limiar 320 literal, solto do limite de 400. | Contar uma vez; derivar o limiar. |
| 10 | SheetKit:298 | RAM-CPU | B | P | `text.count` O(n) a cada tecla em `PlaceholderTextEditor`. | `text.utf8.count < 90 && !contains("\n")`. |
| 11 | SettingsView:208-219 | Design | B | P | O título dos atalhos refaz `sectionTitleStyle`; fonte monoespaçada literal. | `.sectionTitleStyle()`, `Typography.label.monospaced()`. |
| 12 | ClaudeCodeSettings:22, 74 | Design | B | P | `Link` azul do sistema ao lado de um chip cinza; espaçamento padrão. | `Spacing.controlGap`; `accentText` ou `chipButton`. |
| 13 | UsageSettings:133-139, 297 | Design | B | P | Vazio e régua com fontes do sistema fora da escala. | `Typography` + `Palette`. |
| 14 | ProfileSettings:138 | RAM-CPU | B | P | `Thumbnails.cached` avaliado a cada init do avatar (custo teórico). | Começar com `nil` e deixar o `task(id:)` resolver. |

## Lote 9: provedores, navegador, permissões, apagar e redefinir Orb

| # | Onde | Cat. | Imp. | Esf. | Achado | Correção |
|---|---|---|---|---|---|---|
| 1 | ProviderSettings:405 | Polimento (bug) | A | P | `URLError.cancelled` com a Task viva é gravado como falha do provedor; o caminho `inStatus` grava a falha duas vezes. | `ProviderHealth.isCancellation(error)`; não gravar de novo. |
| 2 | BrowserSettings:75 | Design (RM) | M | P | `.animation(.default)` literal, ignora Reduzir movimento. | `.animateChanges(of:)`. |
| 3 | ProviderSettings:341-384; BrowserSettings:166-201 | Polimento | M | M | A linha de chave (salva, trocar, apagar, colar, salvar, obter) está copiada nos dois arquivos. | `SavedKeyField` comum. |
| 4 | ProviderSettings:136-137 | Polimento (bug) | M | P | Nada cancela o `signInTask` ao fechar Ajustes: a espera do login fica presa à porta por até 300 s. O comentário diz o contrário. | `.onDisappear { signInTask?.cancel() }`. |
| 5 | CustomProviderFields:137-141; DeleteOrbDialog:170-175 | Design (a11y) | M | P | "x" de chip e "Fechar" do banner com alvo de ~10 pt. | `CircleGhostStyle(side: 18/20)`. |
| 6 | CustomProviderFields:237-250 | Polimento | M | P | Rodapé de `AllModelsSheet` refeito à mão, com botão invisível para o Return. | `SheetFooter(... showsCancel: false)`. |
| 7 | CustomProviderFields:216-217 | Design | B | P | Busca com `.roundedBorder`, destoa; a contagem aparece repetida. | `ModelSearchField` / `popoverSearchField`. |
| 8 | ProviderSettings:285-286 | RAM-CPU | B | M | A "URL base" grava em `model.providers` a cada tecla e invalida todas as linhas. | Rascunho em `@State`; gravar no submit ou ao perder o foco. |
| 9 | CustomProviderFields:45-49 | Design (texto) | B | P | Parágrafo de 3 linhas sempre visível. | `LearnMoreNote`. |
| 10 | CustomProviderFields:136; DeleteOrbDialog:160; MacPermissionsView:390 | Design | B | P | Fontes literais. | Tokens. |
| 11 | ResetOrbSheet:22-27; DeleteOrbDialog:118-128 | Design | B | P | Espaçamentos literais nas folhas destrutivas. | `Spacing.sheetEdge/m/l`. |
| 12 | ProviderSettings:197, 203 | RAM-CPU/Design | B | P | `summary()` roda duas vezes por render, e a animação fica presa a um texto com relógio. | Calcular uma vez; `.motion(value: status)`. |
| 13 | MacPermissionsView:481-483 | Design | B | P | A legenda de notificações é cortada em 460 pt (falta `fixedSize`). | `.fixedSize(horizontal: false, vertical: true)`. |
| 14 | ProviderPresentation:32, 167; MacPermissionsView:191 | Polimento | B | P | Símbolos usados só em teste; a lista de permissões está repetida. | Constante única; avaliar remover. |
| 15 | ProviderSettings:72-77 | Polimento | B | P | Ternário aninhado duplicado. | Calcular uma vez. |

## Lote 10: primeira execução, boas-vindas, importação

| # | Onde | Cat. | Imp. | Esf. | Achado | Correção |
|---|---|---|---|---|---|---|
| 1 | FirstRunCard:630-647 | Design (a11y) | A | P | O `accessibilityElement(.combine)` vem depois do overlay e engole "Cancelar" e "Como instalar": no VoiceOver não dá para cancelar o login nem abrir o link. | Aplicar combine, rótulo e traço só no `Button`, antes do overlay. |
| 2 | ImportPanel:155, 517, 607 | RAM-CPU | M | M | A prévia recebe um `Binding(get:set:)` novo a cada render e refaz `plan()` e `shown()` a cada tecla do editor da resposta. | Editor em subview com o estado; passar `$draft`; guardar o resumo do plano e recalcular só em `onChange(of: imported)`. |
| 3 | WelcomeView:242-243, 311 | RAM-CPU | M | P | Detecção dupla no caso lento: a tela e o card rodam `detect()` ao mesmo tempo (`claude auth status` e duas sondas). | `detectsOnAppear: false` no Welcome, ou guarda `isDetecting` no modelo. |
| 4 | FirstRunCard:16-21, 686, 777-780; ChatView:60-61 | RAM-CPU | M | P | O banner, sob `.id(botID)`, refaz a detecção a cada troca de Orb, e cada sonda cria uma `URLSession` efêmera que nunca é invalidada. | Sessão estática ou `finishTasksAndInvalidate`; resultado da detecção guardado e reaproveitado por alguns segundos. |
| 5 | FirstRunCard:621-623 | Polimento/Design | M | P | O hover troca o fundo sem curva (pisca) e refaz `hoverCard`/`hoverFill`. | `.hoverCard` / `.hoverFill`. |
| 6 | WelcomeView:535-538; WelcomeOffer:149-150 | Design | M | P | Cards feitos à mão com `Color.white.opacity` literal. | `.card(...)` e `hoverCard` com tokens. |
| 7 | FirstRunCard:466-472, 781-787 | Polimento/RAM-CPU | M | P | Pulso do `setupNudge` copiado nos dois lugares, curva literal, `Task` sem cancelamento. | Um modificador com `.task(id:)` e `animateChanges`. |
| 8 | FirstRunCard:637-640; WelcomeOffer:70-74 | Design | M | P | "Cancelar" azul e literal, mas `GhostStyle` no banner: dois desenhos para a mesma ação. | `QuietTextStyle` ou `GhostStyle` small nos dois lugares. |
| 9 | ImportPanel:668, 164-371; FirstRunCard:769 | Polimento/Design | B | P | Uma animação ignora Reduzir movimento; cinco reimplementam `.motion`. | `.animateChanges` / `.motion`. |
| 10 | FirstRunCard:737, 848-853 | Polimento | B | P | `AnyButtonStyle` com `AnyView` para um uso só. | `if` com dois `Button`; apagar o tipo. |
| 11 | FirstRunCard, ImportPanel, WelcomeView (várias linhas) | Design | B | P | Fontes literais onde há token; o título de 17 semibold está repetido. | `Typography.*` e um token de título de painel. |
| 12 | WelcomeView:376-392 | Polimento | B | P | `VStack` interno que só envolve o botão. | Remover. |
| 13 | FirstRunCard:421-425; WelcomeOffer:27-31 | Polimento | B | P | Rótulo "Pronto: X conectado." copiado. | `FirstRunReadyLabel(name:)`. |
| 14 | FirstRunCard:529, 820 vs 236 | Polimento (validação) | B | P | O botão habilita com `.whitespaces`, mas o modelo apara `.whitespacesAndNewlines`: uma chave só com quebra de linha habilita "Conectar", e o clique não faz nada. | `.whitespacesAndNewlines` no `disabled`. |
| 15 | WelcomeView:238 | Polimento | B | P | O `onDisappear` grava `welcomeReason = nil` sempre. | Gravar só se mudou. |

