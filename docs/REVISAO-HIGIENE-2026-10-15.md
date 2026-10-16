# Revisão de higiene de código (15/10/2026)

Base: `main` em fe3bed8, com as mudanças não commitadas que estavam no disco durante a leitura. O commit 509b3c6 (resposta em bolha) entrou no meio da revisão, então as linhas citadas em `TranscriptViews.swift`, `GroupMessageBubble.swift` e nas telas de conversa podem ter mudado de lugar; confira pelo nome do símbolo. Esta revisão foi só de leitura: nada no código foi alterado.

Pedido: achar pelo menos 10% de redução de código sem mudar o comportamento e, se isso não fosse possível, dizer que não é.

## 1. Veredito

**Não dá para chegar a 10% só com limpeza.** Somando tudo o que é limpeza segura (confiança alta ou média), saem cerca de **3,2 mil linhas de 166 mil, ou 1,9%**. Mesmo aceitando todas as decisões de produto da seção 5 (apagar as telas de `--snapshot`, as migrações de formato antigo e os ganchos só de teste), o total fica em **~6,8 mil linhas, ou ~4%**.

O código já é enxuto:

- **Pouco código morto.** Uma varredura de todos os símbolos declarados em `Sources` encontrou 72 com uma única ocorrência, e quase todos são usados pelos testes ou pelo sistema (delegates, `@objc`, `@main`). Os leitores conferiram mais de mil símbolos com grep e acharam uns 30 mortos de verdade, a maioria de 1 a 10 linhas.
- **Pouca cópia.** Blocos idênticos de 6 linhas ou mais entre arquivos somam 359 linhas (0,4%). Clones estruturais (mesma forma, nomes diferentes) somam ~1,8 mil, e parte disso é falso positivo (declarações de enum).
- **Muito comentário, mas comentário útil.** Há 12,6 mil linhas de comentário em `Sources` (13%), e quase todas explicam o porquê. Os leitores acharam umas 200 linhas para cortar (marcadores de pacote de trabalho, frases históricas, comentários fora do lugar). Cortar o resto não seria limpeza.

## 2. Números

| Área | Linhas | Código | Comentário | Branco |
|---|---:|---:|---:|---:|
| `Sources` (356 arquivos) | 96.455 | 74.841 | 12.610 | 9.004 |
| `Tests` (222 arquivos) | 69.701 | 58.171 | 3.743 | 7.787 |
| **Total** | **166.156** | **133.012** | **16.353** | **16.791** |

| Redução | `Sources` | `Tests` | Total | % de 166 mil |
|---|---:|---:|---:|---:|
| Confiança alta | ~390 | ~880 | ~1.270 | 0,8% |
| Confiança média | ~700 | ~1.260 | ~1.960 | 1,2% |
| **Limpeza (alta + média)** | **~1.090** | **~2.140** | **~3.230** | **1,9%** |
| Decisões de produto (seção 5) | ~3.150 | ~420 | ~3.570 | 2,1% |
| **Teto com tudo** | **~4.240** | **~2.560** | **~6.800** | **~4,1%** |

Por fatia de `Sources` (cerca de 6,5 mil linhas cada), a limpeza segura variou de 0,25% a 2,4%. Nos testes, de 0,3% a 3,5%. Nenhuma das 26 fatias passou de 5%.

**Confiança.** "Alta" quer dizer conferido por grep e leitura, com troca mecânica. "Média" pede compilar e rodar os testes, porque depende de um detalhe do Swift ou de um helper novo. Nada foi compilado.

## 3. Método

- `Sources` foi dividido em 15 fatias e `Tests` em 9. Cada fatia teve um leitor próprio, que leu todos os arquivos inteiros e conferiu cada afirmação com grep em `Sources` e `Tests`.
- Três fatias de testes perderam detalhe por falta de contexto e foram relidas em metades menores. Os números de testes vêm das releituras.
- Por cima das fatias rodaram três varreduras do projeto inteiro: símbolos declarados e nunca usados, blocos copiados (literais e estruturais) e inits memberwise escritos à mão.
- Conferi pessoalmente os achados de alta confiança mais importantes. Um número de testes estava inflado (`SteeringTests`, ~60 a 90 linhas em vez de 110 a 130) e foi corrigido.

## 4. Limpeza segura, por tema

### 4.1 Inits memberwise escritos à mão (~300 linhas, média)

Este é o maior bloco único de limpeza. O padrão se repete no projeto inteiro: um `init(from:)` tolerante fica no corpo da struct, o que suprime o init memberwise que o Swift sintetiza, e alguém reescreveu esse init à mão. Para resolver, mova o `init(from:)` para uma `extension` e dê o valor padrão na própria propriedade. `Models.swift` já faz assim em `Bot`, `Routine`, `Skill` e `ApprovalRequest`, e `ProviderModel` e `SteeredMessage` também.

A varredura achou **80 inits** desse tipo, que somam **551 linhas**. Depois das 2 linhas de `extension` por tipo e dos casos que não dá para trocar (rótulo omitido, ordem diferente, `let` com padrão), devem sobrar ~300 linhas líquidas. Os maiores:

- `MultiOrb/OrbEnvelope.swift:39-55` e `MultiOrb/OrbProposal.swift:29-44`, mais `OrbEvent`, `OrbGroup`, `OrbMessageItem`, `GroupPauseItem`, `DelegationRequest`, `MultiOrbOffering` e `OrbCreationSupport`: ~100 linhas.
- `Import/GrokMarketplace.swift:18-22` e `:52-68` (`MarketplaceBot` e `Entry`): ~18 linhas.
- Sete structs de Acessibilidade em `AccessibilityContracts.swift:261-319`, `AccessibilityElements.swift:117-131` e `AccessibilityOutline.swift:381-446`: ~51 linhas.
- `Views/ConnectorsView.swift:71-81` (`ConnectorDraft`), `TaskPlan.swift:23-58`, `Compaction.swift:44-52` e `ChunkSummary.swift:20-25`.
- `ModelPricing`, `UsageRecord`, `UserProfile` e `KeptProfile`.
- `StoreCoordination.swift:154-172`: o `init(from:)` de `ConversationMeta` é idêntico ao sintetizado, então pode sair inteiro.

Para a lista completa, rode a varredura de novo; é um script de 30 linhas que procura `init` cujo corpo é só `self.x = x`.

### 4.2 Código morto confirmado (~120 linhas, alta)

| Onde | O quê | Linhas |
|---|---|---:|
| `Catalog/ConnectorTemplates.swift:3-18, 32, 56` + 8 `category:` | `ConnectorCategory`, `.category` e `matches(_:)`: os chips do Explorar que liam isso não existem mais | 23 |
| `Engine/Browser/BrowserInstallTypes.swift:8-31` | `BrowserComponent.engine` e `Identifiable` nunca lidos | 10 |
| `Groups/GroupSession.swift:45-54` | `update(_:_:)` sem chamador | 9 |
| `Engine/Browser/BrowserInstallTypes.swift:172,199`, `BrowserDriver.swift:49-58` | `unsupportedMac` e `.unsupported` nunca lançados | 6 |
| `Views/LocalConnectorSheet.swift:54, 158-175` | `if` sempre verdadeiro e ramo `ProgressView` inalcançável | 6 |
| `Views/Multi/MultiOrbSnapshotsFinal.swift` | enum que só devolve `nil`, mais 1 linha da cadeia em `MultiOrbSnapshots.swift:14` | 6 |
| `Engine/Browser/BrowserSetup.swift:70,91,237` | `isBusy` sem uso; `lastCheck` gravado e nunca lido | 3 |
| `Engine/Tools/AccessibilityTools.swift:826` | `UIMenu.listing(under:)` | 3 |
| `Engine/Tools/BackgroundJobs.swift:26,238,260` | `Snapshot.endedAt` gravado e nunca lido | 3 |
| `Engine/Tools/AccessibilitySession.swift:369` | `UILiveElements.removeAll()` | 3 |
| `MultiOrb/DelegationService.swift:50-54` | `resumeHeldWork` padrão; os dois conformadores implementam | 3 |
| `Engine/Tools/WebSearchTool.swift:206`, `WebTools.swift:470`, `Import/ImportPrompt.swift:8` | `SearchKeys.live`, `WebPageCache.clear()`, `ImportPrompt.version` | 3 |
| `Engine/Tools/ScreenTakeover.swift:524`, `Views/WelcomeView.swift:128`, `Views/EntranceMotion.swift:157,302` | `init() {}` vazios | 8 |
| `Wizard/WizardRunner.swift:75` e `:223-258` | `canConverse` sem chamador; ramo de `tracksHistory` sempre `true` | 4 |
| `Catalog/SkillCatalog.swift:206,215`, `MultiOrb/DelegationTypes.swift:45,61` | `CatalogError.unreadable` e `orbBusyDeleting` nunca lançados | 3 |
| `Engine/ConversationLedger.swift:575-583` | `ToolReference.name` gravado e nunca lido | 2 |
| `Theme.swift:106`, `Engine/Tools/OrbsTool.swift:7`, `Engine/Tools/DocumentTextCache.swift:52` | `Spacing.section`, `OrbsTool.messageLimit`, `DocumentTextCache.clear()` | 3 |
| Outros de 1 linha | `Engine/DangerousCommand.swift:107` (`lowered`), `Engine/Tools/AccessibilityTools.swift:1340` (`pickMenu` repetido) e parâmetros não lidos em `Groups/GroupBoard.swift:44`, `Views/Groups/GroupMessageBubble.swift:175` e `Views/Groups/GroupHeader.swift:48` | ~6 |

Fora da tabela: `Catalog/ConnectorCatalog.swift:16-31`. Os campos `protocolVersion`, `serverName`, `serverVersion` e `instructions` são gravados e nunca lidos em produção; só um teste lê dois deles. São ~9 linhas, com confiança média, porque talvez você queira mostrar o nome do servidor na tela.

### 4.3 Cópias que viram uma versão só (~350 linhas, alta e média)

**Alta:**

- `Engine/Browser/BrowserHub.swift:33-50, 77-88`: `AsyncMutex` é o `AsyncGate(limit: 1)` de `Engine/Tools/WindowCapture.swift:15-43`. **22 linhas.**
- `Store.swift:320-322, 438-445, 499-506`: `routineConversationURL`, `saveRoutineConversation` e `deleteRoutineConversation` copiam as funções de conversa lateral com `prefix: "routine"`. **19 linhas.**
- `Views/Groups/GroupMessageBubble.swift:153-169`: `copyButton` copia o `CopyButton` de `Views/TranscriptViews.swift:561-591`. A cópia só não tem o `symbolEffect`. **16 linhas.**
- `Views/Groups/NewGroupSheet.swift:161`, `GroupPanel.swift:232` e `GroupBoardView.swift:117`: o mesmo helper "título 11 pt + conteúdo" aparece três vezes. **18 linhas.**
- `Views/CustomProviderFields.swift:233-248`: um rodapé feito à mão que é igual a `SheetFooter(showsCancel: false)`. **13 linhas.**
- `Views/ConversationFind.swift:102-118`: `close()` refaz o que `clearResults()` já faz. **8 linhas.**
- `Engine/Tools/ScreenTakeover.swift:558-565`: `flags(_:)` copia `SyntheticEventBuilder.flags(for:)`. **8 linhas.**
- `Memory/MemoryLibrary+Groups.swift:11-18` copia `MemoryBank.swift:907-914`, que só muda o diretório. **6 linhas.**
- Wrappers de 1 linha que só repassam a chamada: `runningRoutineName` (= `routineName(for:)`), `QueuedMessages.whenText`, `ProviderStatus.relative`, `GroupPresence.list`/`names`, `SearchText.fold`, `MemoryBank.relatedHeader`, `Motion.availability` (= `Motion.panel`), `MCPManager.status()` e `Store.readConversation`. **~25 linhas.**

**Média:**

- `Engine/Tools/LegacyExcelReader.swift:790-834`: a decodificação de entidades HTML copia `HTMLText.decodeEntities` (`HTMLText.swift:633-666`). Para usar uma versão só, leve para `HTMLText` as entidades `deg` e `sect` e a leitura de 0x80-0x9F como Windows-1252. **~38 linhas.**
- `Engine/MCPTransport.swift:462-493`: `readEvents` refaz o `SSEDecoder` de `Engine/SSE.swift`. O decoder precisa ganhar um teto de bytes. **~20 linhas.**
- `Views/Multi/WizardChatView.swift:264-310` (`WizardWrap`) e `Views/CustomProviderFields.swift:151-182` (`WrappingLayout`) são dois layouts de quebra de linha para chips. **~40 linhas.** Confira com captura de tela antes.
- O teclado e o realce dos três cartões de aprovação (`OrbProposalCard.swift:553-588`, `QuestionCard.swift:180-216` e `TranscriptViews.swift:1659-1692`, mais o `leaving` e o realce do botão negar) podem ir para `ApprovalKeyboard.swift`. **~40 linhas.**
- `Views/CatalogParts.swift:25-76` (`CatalogTabBar`) é quase igual a `PillTabs` (81-123). **~30 linhas.** A largura do ícone muda um pouco.
- Um `CaptionedToggle` para o toggle com legenda, que aparece 8 vezes (`SettingsView.swift:144-190`, `ResetOrbSheet.swift:38` e `ImportPanel.swift:528` e `:564`). **~35 linhas.**
- `ConversationCoding.swift:150-196`: `encode` repete o bloco para `items` e para `messages`. **~24 linhas.** É caminho quente de gravação, então rode `StoreIOTests` depois.
- `Views/BrowserSettings.swift:145-221` (`SearchKeySection`) e `Views/ProviderSettings.swift:323-363` (`keyRow`) são a mesma tela de chave. **~22 linhas.**
- Laço "resposta curta do modelo" em quatro lugares: `MemoryConsolidation.swift:109`, `MemoryMerge.swift:118`, `ChunkSummary.swift:250` e `DictationReview.swift:93`. **~20 linhas líquidas.**
- `SideWorkSheet` (`ExchangeSheet.swift:139-184`) e `RoutineConversationSheet` (`RoutinesView.swift:657-715`) são a mesma folha de conversa só para ler. **~18 linhas.**
- `LiveAccessibilityElement.attributes` (`AccessibilityElements.swift:303-354`) repete `read()`. **~16 linhas.** Um caso raro de falha no meio do lote muda.
- Repetições pequenas, de 3 a 12 linhas cada:
  - um `DisclosureChevron` no lugar do chevron repetido 7 vezes;
  - um `hiddenShortcut` no lugar do botão invisível de atalho repetido 8 vezes;
  - `String.removingControlCharacters()` no lugar do filtro de controle copiado 4 vezes;
  - `PortugueseList.join` no lugar das 5 listas "A, B e C" montadas à mão;
  - o template "Bearer" do GitHub, Slack e Supabase;
  - o `auxiliaryClient` montado 5 vezes no AppModel.

### 4.4 Testes (~2,1 mil linhas, alta e média)

Nos testes, a repetição está no preparo de cada teste (setup e limpeza) e em fakes reimplementados. Os testes em si quase sempre cobrem casos únicos. **Nenhum leitor achou teste de símbolo que não existe mais.**

- **Fakes de modelo reimplementados.** Pelo menos 12 arquivos têm um `LLMClient` privado que refaz `Recorder`/`ReplayLLM` (`TestSupport/ContextTestSupport.swift:43-80`) ou `CallScript`/`CallScriptModel`. Exemplos: `AskUserTests.swift:8-26`, `AttachmentPresentationTests.swift:258-276`, `BrowserHandoffTests.swift:9-27`, `CacheMetricsTests.swift:93-119`, `ImageAttachmentTests.swift:503-530`, `MacToolTests.swift:624`, `OrbProposalTests.swift:171`, `PrefaceFlowTests.swift:8` e `ConnectorGatewayTests.swift:253`. Os dois pares de TestSupport também se sobrepõem. **~250 linhas.**
- **`defer { removeTestFolder(root) }` em cada teste** em vez de `final class` com `deinit`, que é o padrão do projeto. Aparece 31 vezes em `RewindTests`, 19 `rig.cleanUp()` em `ClaudeCodeClientTests`, 19 `removeItem` em `WindowCaptureTests` e várias suítes de Context. **~120 linhas.**
- **Preparo de teste copiado:**
  - `SteeringTests`: 32 preâmbulos de 5 linhas e 26 pares `gate.open()` + `waitUntilIdle`;
  - `RewindTests`: 30 pares `model(with:)` + `loadedConversation`;
  - `RoutineTests`: 13 trincas;
  - `StretchNoteFlowTests`: ~15 preâmbulos;
  - `MCPAuthTests`: o trio vault/auth/sessão, 41 vezes.

  **~350 linhas.**
- **`do { …; Issue.record(…) } catch` em vez de `#expect(throws:)`**: 14 blocos em `MCPAuthTests`, 14 de `LLMError` nos testes de provedor e 13 de `ToolError` nos de web e captura. **~120 linhas.**
- **Helpers copiados entre arquivos:**
  - `Gate`, `Latch` e `TakeoverGate` são o mesmo actor;
  - `failure(_:)` aparece 4 vezes, `conversation(turns:characters:)` 4, `notices` ~12, `utcDate` 3 e `mac` 6;
  - `writeExecutable` aparece ~19 vezes e um `savedModel` com `Store`, ~16;
  - uma sessão de `URLProtocol` stub é montada 10 vezes, e há 8 classes de `URLProtocol` stub;
  - `ToolTests.swift:6-25` refaz `ToolWorkspace`;
  - `DictionaryPreferences` e `NoPreferences` repetem `FakePreferences` e `IgnoredPreferences`.

  **~300 linhas.**
- **Testes redundantes** (mesma asserção pelo mesmo caminho):
  - `BrowserMCPTests.swift:18-52` repete `BrowsePermissionTests`. O nome do arquivo também já não diz a verdade, porque não há mais MCP de navegador;
  - `BrowserInstallerTests.swift:635` repete o teste da linha 281;
  - `ContextWindowTests.swift:645` repete `ContextEngineBatchingTests.swift:171`;
  - `StretchNoteFlowTests.swift:456` repete o teste da linha 211;
  - `ResponsesClientTests.swift:37` repete o teste da linha 183;
  - outros ~10 de 1 a 9 linhas.

  **~150 linhas.**
- **Fixture que não serve a nada.** `TestSupport/GroupSnapshotsData.swift` (87 linhas) e o teste dela (`GroupSupportTests.swift:282-295`) são dados para um `--snapshot` de grupos que nunca existiu em `Sources`. O teste só testa a própria fixture. **101 linhas, alta.** Sem ele, `GroupSession.seedConversation` vira código morto em `Sources`.

### 4.5 Comentários (~200 linhas, à parte)

- **Marcadores de pacote de trabalho.** São 64 linhas que contêm só `// MARK: MultiOrb (WPn)` ou `// end MultiOrb (WPn)`, e a etiqueta "(WPn)" aparece mais de 100 vezes. Elas citam `docs/historico/MULTI-ORBS.md` e não explicam o código. Onde a linha também tem texto útil, tire só a etiqueta.
- **Comentários desatualizados ou fora do lugar** (corrigir, não apagar):
  - `AppModel.swift:249`: o comentário de `clientOverride` está em cima de `homeFolder`;
  - `AppModel.swift:1481` e `:1498` descrevem a linha errada;
  - `RootView.swift:92` diz "once the group screens exist", mas essas telas já existem;
  - `DelegationService.swift:8` diz "a shell until the runtime lands", mas o `DelegationHub` já existe;
  - `AccessibilityContracts.swift:4-6` diz "até uma implementação real substituir", mas o `Live*` já existe;
  - `ComposerView.swift:525` fala em "the three things", mas `CardParts` tem 5 campos;
  - `ComposerView.swift:758`, `WebTools.swift:344`, `DangerousCommand.swift:659` e `TranscriptViews.swift:653` são docs colados na declaração errada;
  - `UsageReport.swift:46` cita um campo de outro tipo.
- **Histórico nos testes.** A tabela de medições em `ToolEconomyTests.swift:13-20` e o comentário de `SystemPromptTests.swift:90-98` ("it was 3,270 characters before…") repetem o `git log`.

## 5. Decisões que são suas (não são limpeza)

Estes cortes reduzem bastante, mas cada um tira uma ferramenta ou uma compatibilidade.

### 5.1 Telas de revisão `--snapshot` no app (~2,6 mil linhas)

O código que desenha telas para revisão visual vai junto no app de release, sem `#if DEBUG`:

- arquivos dedicados (`*Snapshots.swift`, `TranscriptSamples.swift`, `SnapshotComposerScenes.swift`, `DelegationSnapshots.swift`, `GroupSnapshots.swift` e outros): ~1,6 mil linhas;
- enums dentro de telas reais (`SettingsSnapshots`, `ProfileSnapshots`, `RoutinesSnapshots` e `NewBotSnapshots`): 244 linhas;
- `Snapshot`, `OrbSheet` e `ApprovalCardsSample` em `OrbApp.swift`: 153 linhas;
- ganchos espalhados (`forcedStage`, `alwaysShown`, `preloaded`, `initialPhase`, `init(sample:)`): ~50 linhas.

Só `OrbDesignSheets` e `OrbBench` (525 linhas) já ficam atrás de `#if DEBUG || ORB_DEV_TOOLS`. As saídas possíveis:

- (a) **Manter.** É a ferramenta que você usa nas revisões de interface.
- (b) **Pôr atrás de `#if DEBUG || ORB_DEV_TOOLS`**, como o bench. Tira ~2 mil linhas do binário de release, mas não do repositório.
- (c) **Mover para um alvo separado.** Também não reduz o repositório.
- (d) **Apagar.** É a única opção que reduz linhas, e você perde a revisão por captura.

### 5.2 Migrações de formato antigo (~300 linhas em `Sources` e ~250 em `Tests`)

O repositório tem 8 dias (07 a 15/10), então todo "legado" tem de 4 a 7 dias. Cada item só pode sair se nenhuma instalação ainda tiver arquivos daquele formato:

| Onde | O quê | Desde | `Sources` |
|---|---|---|---:|
| `LegacyMigration.swift` + `Store.swift:99-103, 782-851` | Pasta e Keychain do OpenBot. **Risco alto:** uma chave que só existe no item antigo se perde | 08/10 | ~90 |
| `Store.swift:383-423` + `ConversationHistory.swift:169-206` | Conversas arquivadas do antigo "Nova conversa" (`ConversationMergeTests`, 173 linhas, sai junto) | 11/10 | ~70 |
| `Engine/LegacyTemporaryFiles.swift` + `AppModel.swift:425` | `orb-mcp-*.json` do motor antigo do Claude Code | 11/10 | ~33 |
| `Engine/PermissionPolicy.swift:628-660` + `Models.swift:126,141-143` | Nomes antigos de ferramenta em `allowedTools` | 08/10 | ~35 |
| `Store.swift:927-990` | `Counted` (não lidas dentro do Orb) e `migrateSingleProvider` | 08/10 | 32 |
| `Models.swift:111-157` + `AppModel.swift:1266-1273` | `Bot.memory`/`MemoryFact` do protótipo | 07/10 | ~17 |
| Outros | `removeLegacyCloakEnvironment`, `RetryPlan.isMessage` por palavras, `AttachmentInfo.legacy` e `ConversationLedger(legacy:)` | 08 a 11/10 | ~25 |

### 5.3 Ganchos só de teste em `Sources` (~200 linhas)

Propriedades e sobrecargas que só os testes usam:

- `ApprovalGate.resolve(approvalID:)`;
- `BrowserHub.closeAll` e `existingSession`;
- `ContextWindow.fit` sem `cut` e `ContextSummary.make`;
- a cadeia `AppModel.contextFill(for:)`;
- `ConversationFind.settled` e `probe`;
- os `Unavailable*` de `AccessibilityContracts.swift:334-363`;
- `SSEEvent.name`;
- `ResponsesClient.init(apiKey:)`;
- `StdioServers.count`;
- os 11 ganchos de `OrbAnimationView.swift:147-167`;
- `AppShortcut.all` e `contextual`;
- `BrandMark.Treatment`.

Tirar exige reescrever os testes que dependem deles. A maioria é ponto de injeção barato e legítimo, então eu não tiraria em bloco.

### 5.4 Ferramentas de desenvolvimento

- `SwitchBench.swift`: 46 linhas, ativado por `ORB_BENCH_SWITCH` e sem teste.
- `ConnectorGallery` `.soon` ("Em breve"): nenhum serviço usa, e um teste garante isso. São ~12 linhas, contando a tela.

## 6. O que parece cortável mas não é

- `AppIcon.swift:208-371` (`GelShader`) é uma cópia intencional de `art/orbgen/.../Body.swift`, protegida por teste de pixels. Só sai se o `orbgen` virar dependência do pacote.
- O caminho de macOS 14 em `ChatView.swift:570-726`: o app ainda suporta 14.
- Os protocolos com um conformador de produção e um fake (`DelegationService`, `ResettablePreferences`, `KeychainItems`, `CalendarBackend` e as portas de Acessibilidade) são costuras de teste deliberadas.
- `ReadOnlyCommand`, `DangerousCommand`, `GitRepoTrust` e `ShellCommandLine` são densos por segurança. A lista de configs git que executam programas aparece em `DangerousCommand.swift:484` e em `GitRepoTrust.swift:116`, mas as duas diferem de propósito.
- `@State isHovering` + `.onHover` aparece 34 vezes. Um modificador economizaria ~2 linhas por uso, mas muda o padrão do projeto.
- `.animation(Motion.adapted(Motion.content, reduceMotion:), value:)` aparece ~30 vezes, e já existe `.motion(value:)`. Trocar dá 0 linhas, mas remove o `@Environment(reduceMotion)` de alguns lugares.

## 7. Achados de passagem (não são economia)

- **Teste que quase sempre passa.** Em `ConnectorGalleryTests.swift:15`, a expressão `!a.isEmpty && !b.isEmpty && symbol != nil || !monogram.isEmpty` não agrupa o `||` como deveria. A asserção fica verdadeira sempre que há monograma.
- `ConnectorGallery.summary` (`ConnectorGallery.swift:66-94`) e `ConnectorTemplate.summary` têm quase o mesmo texto para os mesmos 9 serviços, com redação diferente.
- `SyntheticInputTests.swift:394-400` tem um bloco que só faz `print`, sem `#expect`.
- `UsageRecordingTests.swift:224-235` (`theBatchGoesOutOnItsOwnAfterTheDelay`) chama `flush()` à mão, então não testa o timer que o nome promete.
- Oito funções `clip` cortam texto de jeitos diferentes, e há sete variantes de "dobrar sem acento". Não são cópias exatas: juntar muda a saída.

## 8. Ordem sugerida, se você for limpar

1. Código morto (4.2) e cópias de alta confiança (4.3). São ~390 linhas, trocas mecânicas e risco baixo.
2. Inits memberwise (4.1). São ~300 linhas; o compilador pega qualquer erro.
3. Testes: fakes de modelo, `deinit` e `#expect(throws:)` (4.4). São ~700 linhas, e a suíte confirma cada passo.
4. Cópias de confiança média que mexem em tela (`WrappingLayout`, cartões de aprovação, `CatalogTabBar`). Confira cada uma com `--snapshot` antes e depois.
5. Marcadores WP e comentários desatualizados (4.5).
6. Só depois disso, as decisões da seção 5.

Os relatórios completos de cada fatia, com as linhas exatas, ficaram fora do repositório. Se quiser algum, peça que eu reconstruo a partir das notas.

## 9. Soluções para três casos (investigação de 15/10)

### 9.1 TestSupport que ficou para trás (−700 a −760 linhas, em 18 levas pequenas)

O problema: cada arquivo de teste foi criando o seu modelo falso, a sua trava e a sua pasta temporária, porque a regra em `ARQUITETURA.md:562-565` manda "cada arquivo define o seu". `CallScript`/`CallScriptModel`, `Recorder` e `ReplayLLM` fazem quase a mesma coisa.

A solução:

- **Um modelo roteirizado só.** `CallScript` absorve `Recorder` e `ReplayLLM`: respostas `say`, `calling` e `failing`; ao acabar o roteiro, `.repeatLast` ou `.fim`; `before:` para segurar uma chamada; `Call.sent`/`messages`/`system`/`tools`/`toolChoice` para conferir o que foi enviado; `init(always:)` para respostas fixas.
- **Uma trava só.** `actor TestGate { wait(); open() }` no lugar de `Gate`, `Latch`, `Valve` e `TakeoverGate`.
- **Uma pasta temporária só.** `final class TempFolder`, guardada como propriedade da suíte e apagada no `deinit` com `removeTestFolder(sealing:)`.
- **Erro esperado com `#expect(throws:)`.** 101 blocos seguem o padrão `do { try …; Issue.record("expected an error") } catch {…}`. O formato de `WebRedirectTests.swift:76-83` faz o mesmo em metade das linhas. Esses blocos **não engolem falha**: conferi e todos registram erro quando nada é lançado. A troca só deixa o teste mais curto.
- **Helpers soltos movidos para `TestSupport/`.** Entram aqui `LockedBox` (hoje em `RealBrowserTests`), `utcCalendar`/`utcDate`, `failureMessage`, `writeExecutable`, `StoreFixtures` e `FakePreferences` no lugar de `DictionaryPreferences`, além do `ToolTestSupport.swift` inteiro.

O que **não** entra no modelo único: `Brain`, `GatedModel`, `WritingModel`, `StuckModel`, `FakeModel`, `StubModel` e `HeldModel`. Cada um testa um comportamento próprio (fila, cancelamento, escrita parcial), e generalizar esconderia o que o teste quer provar.

Riscos:

- O fallback "fim" do `ReplayLLM` e o `appendsFinished` precisam ficar idênticos.
- O cancelamento dentro de `before:` precisa ser testado à parte.
- As esperas locais com prazo próprio não devem virar `waitUntil`.

Comece pelos arquivos que a outra sessão não está mexendo. `Waiting.swift`, `ChildProcess.swift`, `WaitingTests.swift`, `BrowserSetupTests`, `DelegationRulesTests` e `FirstLaunchFlowTests` ficam por último.

Regra nova para `ARQUITETURA.md`, no lugar das linhas 562-565:

1. Modelo falso roteirizado é sempre `CallScript`. Um tipo novo só entra se testar um comportamento que o roteiro não expressa, com comentário dizendo qual.
2. Para esperar um passo, use `TestGate`. Para esperar um estado, use `waitUntil`.
3. Pasta temporária é `TempFolder`, guardada como propriedade da suíte.
4. Erro esperado se testa com `#expect(throws:)`.
5. O que um segundo arquivo precisar vai para `TestSupport/` na hora, não depois.

### 9.2 Inits memberwise escritos à mão (−275 linhas, 4 levas)

O problema: o Swift só deixa de gerar o init memberwise quando existe um `init` **no corpo** do tipo. Em cerca de 80 tipos, alguém escreveu um `init(from:)` ou um init de conveniência no corpo e depois teve que reescrever o memberwise à mão. Confirmei com `swiftc`: com o `init` no corpo, a chamada memberwise falha com "incorrect argument label". Com o mesmo `init` numa `extension`, ela compila.

A solução: mover esses inits para uma `extension` no mesmo arquivo, levar os valores padrão para as propriedades e apagar o memberwise manual.

- **A (30 tipos):** remoção direta.
- **Bv (15 tipos):** remoção movendo os defaults para a propriedade.
- **Bl/Bo (+−68 linhas, decisão sua):** só funciona trocando `let` por `var` em dependências injetadas. Não recomendo.
- **C (25 tipos):** não mexer. Esses inits validam, convertem ou têm rótulo diferente.

Levas, cada uma fechada com `swift build && swift test --filter '…'`:

1. Dados Codable (MultiOrb, Usage, Memory, Import, `Models.swift:410`, SidebarCategories, UserProfile, Store, StoreCoordination).
2. Tipos de dados do Engine.
3. Tools de acessibilidade.
4. Views (`ConnectorsView`, `DeleteOrbDialog:12`).

Convenção para não voltar:

- Não escrever init memberwise à mão.
- `init(from:)` e inits de conveniência vão numa `extension`.
- Valor padrão fica na propriedade.
- Init manual só com motivo, num comentário de uma linha.

### 9.3 Telas `--snapshot` no app de release (0 linhas do repositório, ~2 mil do binário)

O problema: cerca de 2 mil linhas existem só para gerar capturas de revisão e entram no app que o usuário recebe. São os arquivos dedicados, os enums `SettingsSnapshots`/`ProfileSnapshots`/`RoutinesSnapshots`/`NewBotSnapshots` e, em `OrbApp.swift`, `Snapshot`, `OrbSheet` e `ApprovalCardsSample`. `OrbBench` e `OrbDesignSheets` já usam `#if DEBUG || ORB_DEV_TOOLS`; as telas de snapshot ficaram de fora.

A solução: envolver esse código no mesmo `#if DEBUG || ORB_DEV_TOOLS`. No release, o ramo `--snapshot` ganha um `#else` que avisa "build de desenvolvimento necessário" e sai com erro.

O que fica de fora do `#if`:

- `--render-icon`: o `bundle.sh` roda em release.
- `DevRun`.
- Os ganchos de view com parâmetro padrão.
- `seedConversation`, `setWorkDwell` e `backdateWork`, que os testes usam.

Passos:

1. **Antes de tudo:** acrescentar `swift build -c release` ao CI. Hoje o CI (`tests.yml:57,69,119`) só compila debug, e um `#if` mal posto quebraria só o release, sem ninguém ver.
2. Envolver os arquivos e `OrbApp.swift` juntos.
3. Envolver os enums.
4. Multi.
5. Uma captura de fumaça.
6. `ORB_DEV_TOOLS=1` no `bundle.sh`, opcional.
7. Atualizar `ORBS.md:476-484` e `ARQUITETURA.md:598-651`.
8. Suíte completa.

O ganho é pequeno: o repositório não encolhe, e o binário de ~42 MB perde algumas centenas de KB. O custo é que `readme-shots.sh` e as capturas passam a usar build debug. Vale pela higiene (código de revisão não chega ao usuário), não pelo tamanho.
