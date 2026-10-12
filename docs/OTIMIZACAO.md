# Otimização do código (levantamento de 12/10/2026)

17 analisadores em modo somente leitura: 12 Codex Luna (xhigh), 3 Haiku e 2 Sonnet. Cada achado abaixo foi conferido no
código; os itens descartados estão no fim. Os achados estão agrupados: um item pode juntar vários locais com a mesma causa.

**Total confirmado: 68 itens**

| Grupo | Itens |
|---|---|
| A. Performance, prioridade alta | 9 |
| B. Performance, prioridade baixa (micro-otimizações) | 30 |
| C. Código morto | 10 |
| D. Duplicação de código no app | 7 |
| E. Testes (duplicação de helpers e testes) | 7 |
| F. Docs e lixo | 5 |

Descartados (falsos ou irrelevantes): 6.

---

## Andamento

Ordem de implementação: limpeza de risco baixo (C, E, F), duplicação (D), performance alta (A), micro-otimizações (B).
Cada item fica marcado aqui quando entra na `main`.

| Leva | Itens | Estado |
|---|---|---|
| 1 | C40–C49, E57–E63, F64–F68 | feita; fora: 61 (stubs com comportamentos distintos), parte do 49 (`BrowserHub.closeAll` fica) |
| 2 | D50–D56 | feita; fora: 51 (os dois switches não são o mesmo mapeamento), `leftOff` do 56 |
| 3 | A1–A9 (+ B10–B12) | feita: 1, 2, 4, 5, 8, 3 (só a delegação), 10, 11 (só o limite de larguras), 12; fora: 3 nos grupos (`groupSession` síncrono com 15 chamadores), 6 (ganho desprezível; o `==` profundo evita reavaliar), 7 (Editar já só existe no hover; Refazer precisa ficar montado pelo diálogo), 9 (o cache é da main; aquecer exigiria mudar o fechamento do turno) |
| 4 | B13–B39 | feita: 15, 16, 17, 19, 22, 26 (contagem da outline), 27 (contagem guardada no cache de páginas), 33 (parte), 37; fora: 13, 14, 18, 20, 21, 23, 24, 25, 28, 29, 30, 31, 32, 34, 35, 36, 38, 39 (ganho pequeno demais para o risco, mudariam comportamento ou mexeriam em gravação, abertura do app ou envio; o 30 não procede: são tamanhos diferentes de propósito) |


## A. Performance, prioridade alta (9)

1. **O compositor reavalia o body inteiro a cada tecla.** `Views/ComposerView.swift:35-55` lê
   `model.drafts[botID]`, que é o dicionário inteiro do `AppModel`. Qualquer rascunho que muda invalida o compositor, com
   chips, menu, `stripIDs` e `skills(for:)`. `GreetingReplies` (`Views/TranscriptViews.swift:330`) também lê o dicionário.
   *Correção:* isolar o campo numa subview e passar só um `Bool` `hasText` para o resto.
2. **O streaming reprocessa o parágrafo final inteiro a cada flush de 33 ms.** O tail usa `cached: false`
   (`Views/MarkdownBlockViews.swift:31`, `SelectableProse.swift:332`), então refaz `AttributedString(markdown:)` de todos os
   itens de uma lista longa e o layout do TextKit. `CodeBlockView.pieces` e as tabelas refazem `split` a cada flush.
   *Correção:* cachear os blocos já fechados e reprocessar só o último item.
3. **Leitura síncrona de conversa na main em caminhos de fundo.** `ensureLoaded` (`BotSession+Conversation.swift:16`) é
   assim de propósito para o envio. Mas também é chamada por `DelegationHub` (`MultiOrb/DelegationHub.swift:210, 233`),
   grupos (`Groups/AppModel+Groups.swift:38`) e `mutateItems`, para Orbs que não estão na tela. Essas leituras ainda esperam,
   via `NSCondition`, as escritas na fila `.utility` (`StoreCoordination.swift:80`), o que causa inversão de prioridade.
   *Correção:* usar `readSideConversationAsync` e criar uma variante assíncrona para grupos.
4. **Imagens do histórico relidas a cada requisição.** `ImageWire.payload` (`ImageAttachments.swift:232`) faz
   `Data(contentsOf:)` e `base64EncodedString()` de toda imagem de todas as mensagens, em cada passo do agente.
   *Correção:* cache limitado de base64 por caminho, tamanho e data.
5. **Cada ferramenta concluída varre a conversa inteira.** `BotSession+Turn.swift:215-223` percorre `items.indices` do
   início, sem `break`, para achar a chamada. *Correção:* percorrer de trás para frente e parar na primeira, ou indexar por id.
6. **Grupo de ações com custo O(k²) por turno.** `ToolGroupRow` (`Views/TranscriptViews.swift:730-748`) compara `items`
   inteiros no `==` e recalcula `summary`, `failures`, `span`, `symbol` e `keptInView`, cada um numa passada própria, a cada
   ação nova. *Correção:* um resumo agregado numa passada só e igualdade por id e estado.
7. **Recusa de edição e de refazer calculada no body.** `Views/TranscriptViews.swift:190, 374` chamam `editRefusal` e
   `regenerateRefusal`, que fazem `firstIndex`, `rewindPoint` e `lastTurnStart` sobre a conversa inteira a cada
   reavaliação (`AppModel+Rewind.swift:31-52`). *Correção:* calcular no hover ou no clique, ou cachear por revisão.
8. **Transcrição do ClaudePipe com custo O(n²).** `Engine/ClaudePipe/ClaudePipeSession.swift:249`: para cada chamada,
   `list.indices.first { $0 > index ... }` varre do início. *Correção:* indexar os resultados `.tool` por `toolCallID`.
9. **Pico no fim de uma resposta longa.** A troca de `ParagraphStack` por `MarkdownChunk(source: text)`
   (`Views/TranscriptViews.swift:285, 448`) faz o parse do texto todo e o layout de um `NSTextView` novo na main.
   *Correção:* aquecer `MarkdownCache.blocks` fora da main antes de fechar o streaming. Confiança média.

## B. Performance, prioridade baixa (30)

10. `SelectableProse.drawBackground` (`Views/SelectableProse.swift:282`) enumera atributos de citação no texto todo a
    cada redesenho, mesmo sem nenhuma citação.
11. `SelectableProse.sizeThatFits` mede em largura 10.000 quando não há largura (`:336`), e `heights` cresce com cada
    largura (`:204`).
12. `MarkdownBlocks.isRule` (`MarkdownBlocks.swift:202`) aloca uma String por linha, e o regex de fechamento de título
    (`:198`) é compilado a cada título.
13. `OrbTranscript.refold` (`LiveText.swift:158`) monta um `Set` do prefixo a cada mudança. Na tela de grupo
    (`Groups/GroupSession.swift:74, 79`), `rows` é calculado sem uso.
14. `ContextGaugeDriver` usa debounce de 150 ms e remede o histórico todo durante turnos com muitas ferramentas
    (`Views/ContextMeterViews.swift:40`).
15. Regex recompiladas a cada chamada:
    - `AutomationPreflight.appNames` (`MacPermissions.swift:524`)
    - regras de script em `Engine/DangerousCommand.swift:691-715`
    - `Engine/ContextBudget.swift:264`
    - `DownloadProgressLine.parse` (`Engine/Browser/BrowserInstallTypes.swift:285`)
16. Formatters recriados a cada uso:
    - `LocalDates` (`Engine/LocalConnector.swift:158-170, 207`), até 5 por chamada
    - `Memory/SessionSummary.swift:88, 118`
    - `ConversationHistory.swift:42, 116`
17. `MemoryBank.brief` chama `identity()` duas vezes, e cada chamada lê o arquivo (`Memory/MemoryBank.swift:336, 344`).
18. `saveSkills` relê o arquivo inteiro só para comparar antes de gravar (`Memory/MemoryBank+Skills.swift:67`).
19. `Set(keys)` é recriado dentro de loops de até 5.000 arquivos (`Engine/WorkspaceSnapshot.swift:205`,
    `Engine/ToolOutputSpill.swift:30`), e `Set(words)` duas vezes (`Engine/PermissionPolicy.swift:480`).
20. `Store.flush()` faz `queue.sync {}` na main no quit e no reset (`Store.swift:516`).
21. `UsageStore` relê, mescla e regrava o arquivo do mês inteiro a cada flush (`Usage/UsageStore.swift:19-40`).
22. Buscas que normalizam a lista toda por tecla:
    - `Views/CommandPalette.swift:147`
    - `Views/MarketplaceGallery.swift:57` com `Import/GrokMarketplace.swift:303`
    - `ModelSearch.matches`, que divide a consulta por modelo (`Views/ModelPicker.swift:100`)
23. O ditado remonta o texto inteiro a cada resultado parcial (`Dictation/SpeechCapture.swift:29`,
    `Dictation/Dictation.swift:130`).
24. `QuickAskView.excerpt` divide o tail inteiro duas vezes a cada flush (`Views/QuickAskView.swift:85, 407`).
25. A captura de tela decodifica o mesmo PNG duas vezes, para checar se está em branco e para o OCR
    (`Engine/Tools/ScreenshotTool.swift:146`).
26. `AccessibilityOutline` conta a árvore em duas passadas com `filter` por nível (`:255, 337`). A poda LRU recalcula o
    mínimo a cada remoção (`AccessibilitySession.swift:374`).
27. `web_fetch`:
    - `page()` percorre o texto inteiro a cada continuação (`Engine/Tools/WebTools.swift:248`)
    - um PDF acima de 3 MB é baixado de novo a cada `offset` (`:443`)
    - a leitura é feita byte a byte (`:203`)
28. `ContextMeter.fill` e `compact` refazem vários `ContextWindow.fit` completos (`Engine/ContextMeter.swift:63-118`,
    `Engine/Compaction.swift:101`). `requestCount` é chamado duas vezes (`ContextGauge.swift:140`).
29. Cada chamada de ferramenta é localizada (`tools.first`) e tem o JSON decodificado três vezes (`ApprovalBatch.swift:24`,
    `AgentEngine.swift:490-666`).
30. A mesma miniatura é decodificada duas vezes, por `ImageThumbnail` e por `PictureChip` (`Views/ComposerView.swift:522, 532`).
31. Cópias COW do array de itens inteiro:
    - `withLiveText` a cada salvamento no streaming (`BotSession+Turn.swift:513`)
    - `editConversation` (`AppModel.swift:1659`)
32. `AttachmentTextCache.Key` faz `stat` do arquivo a cada consulta, na main (`AttachmentText.swift:139`).
33. Varreduras pequenas repetidas no body:
    - `RoutineRow` busca a rotina global de novo (`Views/BotInspector.swift:786`)
    - `inputsByName` (`Views/ConnectorsView.swift:800`)
    - `ExchangeSheet` usa `firstIndex` por mensagem (`Views/Multi/ExchangeSheet.swift:39`)
    - `Array(items.enumerated())` (`Views/Groups/GroupChatView.swift:107`)
    - `modelChoices` duas vezes (`Views/ProviderSettings.swift:57, 65`)
    - `modelName` duas vezes (`AppModel+ContextUI.swift:37`)
    - `reasoning` duas vezes (`Engine/ProviderTransport.swift:34`)
34. Abertura do app: na `init` rodam síncronos `readState`, a resolução de segredos no Keychain e `restoreDrafts`
    (`AppModel.swift:324-348`, `AppModel+Steering.swift:163`), e também a migração legada (`LegacyMigration.swift:29`, só
    com dados antigos).
35. `prepareHistory` e `compact` rodam síncronos na main a cada envio (`AppModel.swift:1469, 1269`).
36. I/O pequeno na main:
    - `RoutineReport.write` (`AppModel.swift:1852`)
    - `FolderInstructions.load` no toggle (`Views/BotInspector.swift:585`)
    - `fileExists` no Quick Look (`Views/QuickLookPreview.swift:29`)
37. `ToolOutputCap.apply` faz `output.count`, que é O(n) em caracteres, duas vezes (`Engine/ContextWindow.swift:652`).
    Usar `utf8.count`.
38. `.task(id:)` por linha de ferramenta varre a saída inteira atrás de um problema de permissão
    (`Views/TranscriptViews.swift:677, 762`). Confiança baixa.
39. Escritas de conversa não são coalescidas na fila serial: saves intermediários se empilham quando o disco está lento
    (`Store.swift:598`).

## C. Código morto (10)

40. **Ramos inalcançáveis em `MarkdownBlockView`** (`Views/MarkdownBlockViews.swift:46-70`, mais `ListItemRow` em `:121`,
    cerca de 50 linhas). O único uso (`:33`) recebe só blocos `.code`, `.table` e `.rule`, porque
    `ProseSegment.isProse` manda parágrafo, título, lista e citação para `SelectableProse`. Os casos
    `.paragraph/.heading/.list/.quote` e o `ListItemRow` com `.equatable()` nunca rodam. O comentário em
    `SelectableProse.swift:281` cita esse caminho morto.
41. `BotSession.clearRequestUsage()` (`BotSession.swift:196`): 0 usos.
42. `Spacing.cardGap` (`Theme.swift:94`): 0 usos.
43. `RootView.reduceMotion` (`Views/RootView.swift:5`): declarado e nunca lido.
44. `ClaudePipeSession.serverName` (`Engine/ClaudePipe/ClaudePipeSession.swift:55`): 0 usos e duplica
    `ClaudePipeServer.serverName`.
45. `DangerousCommand.reason(forReading:)` (`Engine/DangerousCommand.swift:55`): só usado em testes.
46. `ConversationLedger.isEmpty` (`Engine/ConversationLedger.swift:181`): só usado em testes.
47. A sobrecarga `onlyPID` de `WindowCandidate.front` (`Engine/Tools/ScreenshotTool.swift:510`): só usada em testes.
48. Em `Engine/Tools/UIMarks.swift`, só usados em testes: `DisplayLayout` (`screenPoint`, `appKitRect`, `screenRect`),
    as conversões `windowPoint`/`globalPoint`/`pixel(fromGlobal:)` (`:18-33`) e `UIMarkReference` (`:302`).
49. Outros símbolos de produção só usados em testes:
    - `QueuedMessages.switchTitle` (`:53`)
    - `OrbProposal.folderDisplay` (`MultiOrb/OrbProposal+Make.swift:170`)
    - `BrowserInstaller.hasEverythingInstalled` (`:86`)
    - `BrowserHub.closeAll` (`:352`)
    - `Store.saveGroupSideConversation`/`readGroupSideConversation` (`:493, 498`)
    - `GroupSnapshotsData` (`Groups/GroupSnapshotsData.swift`, fixture dentro do alvo do app)

    Antes de remover, decidir se cada um é uma API em uso ou só sobrou. Os pontos de entrada assumidos para teste
    (`saveAndWait`, `evictForTesting`, `existingSession`, `queuedWrites`, `beginConnectionCheck`) ficaram de fora.

## D. Duplicação de código no app (7)

50. `PortugueseList.join` já existe (`MultiOrb/TranscriptFolding.swift:223`), mas `Groups/GroupHub.swift:492` e
    `Views/Groups/GroupPresenceStrip.swift:56` reimplementam a mesma junção "A, B e C".
51. Os títulos das ferramentas são classificados em dois `switch` de strings literais: `WorkLine.line`
    (`WorkLine.swift:102`) e `ToolTally.Act` (`ToolTally.swift:11`, arquivo novo ainda não commitado). Uma tabela única
    evita que os dois divirjam.
52. O mapa de teclado US está duplicado, com coberturas diferentes: `USKeyLayout.keys` (`Engine/Tools/SyntheticInput.swift:68`)
    e `LiveTakeoverPoster.usLayout` (`Engine/Tools/ScreenTakeover.swift:639`).
53. O predicado "mensagem do usuário que não é resumo" está repetido em 4 lugares (`ContextCondensing.swift:24`,
    `ContextMeter.swift:130`, `ContextWindow.swift:367`, `AgentEngine.swift:469`).
54. `ByteCountFormatter(... .file)` está espalhado em cerca de 12 locais (ComposerSupport, FileTools, DocumentReader,
    ShellTool, WebTools). `AttachmentKind.size` já encapsula essa formatação.
55. A restauração de anexos que ainda existem está duplicada (`AppModel+Rewind.swift:234`, `AppModel+Steering.swift:161`).
    O mesmo formato de data `yyyy-MM-dd HH:mm` também aparece em dois lugares (`LocalConnector.swift:208`,
    `FileTools.swift:393`).
56. Pequenas simplificações:
    - `leftOff` varre o corpo 4 vezes (`Memory/MemoryBank.swift:720-728`)
    - `importPages` usa `filter` só para contar com efeito colateral (`:151`)

## E. Testes (7)

57. `waitUntil` privado em `ClaudeCodeClientTests.swift:246` duplica o global de `TestSupport/Waiting.swift:16`.
58. `waitUntilIdle` está repetido em 5 arquivos (SkillFlow, TurnContext, BotSession, Steering, Routine).
59. `actor Script` e `ScriptedLLM` estão em 5 arquivos; já existe `ReplayLLM` em TestSupport.
60. Helpers repetidos em vários arquivos:
    - `LookTool` (3 arquivos)
    - `Folder` (3 arquivos; o de `WorkspaceSnapshotTests.swift:14` não usa `removeTestFolder`, ao contrário da regra de TestSupport)
    - `Preferences` (2)
    - `call()`/`assistant()` (6)
    - `lines()` (2)
61. Há 6 subclasses de `URLProtocol` para stub HTTP que poderiam virar uma só.
62. `AgentEngineTests.swift:1020` `destructiveCommandsAreRecognized`: todos os comandos dele já estão em `DangerousCommandTests`.
63. Arquivos pequenos do mesmo assunto, que podem ser unidos:
    - `DevRunTests` + `DevRunBackgroundTests`
    - `LegacyTemporaryFilesTests` → `LegacyMigrationTests`
    - `PrefaceFlowTests` + `PrefaceHistoryContractTests`
    - `KeyValueRowTests`

## F. Docs e lixo (5)

64. `docs/MULTI-ORBS.md` (91 KB) é o contrato da implementação já entregue e cita arquivos e tipos que não existem mais
    (`ConversationsMenu.swift`, `MultiOrbSettingsSection.swift`, `ReadyCardStub`...). Arquivar.
65. `docs/ARQUITETURA.md` cita `BrandTile` (linha 260) e `ConversationListing` (linha 512), que não existem.
66. `.github/workflows/tests.yml:50` diz "~3000 testes"; hoje são cerca de 3.900.
67. TODO esquecido em `Views/Multi/WizardPreviewPane.swift:320`.
68. `build/icon/` (11 MB, 25 arquivos de iterações do ícone) está fora do git, mas ocupa disco à toa.

---

## Descartados na verificação (6)

- `DocumentTextCache` "recalcula `utf8.count`": falso. Em String nativa, `utf8.count` é O(1).
- `SteeredMessage.merged` O(n²): procede, mas n é o número de anexos (poucos), então é irrelevante.
- `OrbFootprint.fit` no body do avatar: custo desprezível (cerca de 10 camadas e um dicionário).
- `ContextWindow.fit` em todo passo do agente: procede, mas o custo é ínfimo perto da latência da rede e o esforço é
  alto. Não recomendo.
- Recursos (`Resources/Orbs`): nenhum PNG sem uso (os nomes são montados dinamicamente).
- `saveAndWait`, `evictForTesting`, `existingSession`, `queuedWrites`, `beginConnectionCheck`: ganchos de teste
  intencionais, não código morto.
