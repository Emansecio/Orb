# Revisão de polimento: leitura completa, achados confirmados e correções (17/10/2026)

Base: `main` em 20fdb69 mais o ramo `integracao-polimento` da rodada anterior (89f8868). Resultado: `integracao-polimento` com nove ramos `polimento2/*` juntados e um ajuste de teste (0b6b7e4).

Método, em duas rodadas, com agentes Sonnet e revisão final na sessão principal:

1. **Achar (só leitura).** `Sources/Orb` foi dividido em 52 fatias de até 2.500 linhas, por pasta e afinidade. Cada fatia foi lida inteira por um agente, que provou a leitura: deu o número de linhas de cada arquivo e o texto literal de duas ou três linhas de conferência (uma delas a última), conferidos por hash no script. Um segundo agente tentou derrubar cada achado, relendo o código em volta e os `docs/REVISAO-*.md`.
2. **Corrigir.** Um agente por área, cada um num worktree próprio, com no máximo 3 compilando juntos. Cada bug ganhou um teste de regressão, conferido revertendo só o fonte; comentários e código morto só precisam compilar.
3. **Revisão.** Li o diff de cada ramo antes de juntar. Nenhuma correção foi revertida.

## 1. Resumo

| | Quantidade |
|---|---|
| Fatias lidas inteiras | 52 de 52 (368 arquivos, 99.603 linhas), todas na primeira tentativa |
| Achados trazidos pelos leitores | 153 |
| Derrubados pelo cético | 8 |
| Confirmados | 145: P0 0, P1 2, P2 39, P3 104 |
| Corrigidos | 145 (nenhum ficou como proposta nem foi descartado na rodada 2) |
| Por tipo | bug 98, comentário que mente 21, código morto 16, texto 6, teste frágil 3, desempenho 1 |

## 2. Cobertura

| Fatia | Arquivos | Linhas | Achados trazidos |
|---|---|---|---|
| Raiz-1 | 18 | 2.287 | 1 |
| Raiz-2 | 6 | 1.114 | 1 |
| Raiz-3 | 1 | 2.357 | 4 |
| Raiz-4 | 7 | 2.213 | 1 |
| Raiz-5 | 10 | 2.129 | 5 |
| Raiz-6 | 8 | 2.433 | 2 |
| Raiz-7 | 10 | 2.174 | 4 |
| Raiz-8 | 6 | 2.124 | 5 |
| Raiz-9 | 3 | 568 | 0 |
| Catalog | 12 | 1.636 | 2 |
| Engine-1 | 5 | 1.949 | 1 |
| Engine-2 | 10 | 2.334 | 3 |
| Engine-3 | 4 | 2.302 | 9 |
| Engine-4 | 9 | 2.219 | 2 |
| Engine-5 | 7 | 2.122 | 2 |
| Engine-6 | 12 | 2.094 | 4 |
| Engine-7 | 6 | 1.023 | 2 |
| Engine-Browser-ClaudePipe-1 | 5 | 2.084 | 2 |
| Engine-Browser-ClaudePipe-2 | 8 | 2.099 | 5 |
| Engine-Tools-1 | 5 | 2.267 | 1 |
| Engine-Tools-2 | 1 | 2.380 | 5 |
| Engine-Tools-3 | 8 | 1.790 | 4 |
| Engine-Tools-4 | 8 | 2.134 | 5 |
| Engine-Tools-5 | 4 | 2.303 | 3 |
| Engine-Tools-6 | 8 | 1.860 | 3 |
| Engine-Tools-7 | 5 | 2.422 | 5 |
| Engine-Tools-8 | 8 | 2.217 | 2 |
| Engine-Tools-9 | 2 | 881 | 4 |
| Grupos-1 | 11 | 1.807 | 6 |
| Grupos-2 | 13 | 1.523 | 2 |
| MultiOrb-1 | 10 | 1.852 | 5 |
| MultiOrb-2 | 18 | 2.289 | 5 |
| MultiOrb-3 | 8 | 1.334 | 1 |
| Memory-1 | 4 | 1.543 | 4 |
| Memory-2 | 8 | 1.570 | 2 |
| Orbs-1 | 2 | 1.637 | 0 |
| Orbs-2 | 6 | 2.211 | 1 |
| Orbs-3 | 4 | 1.034 | 1 |
| Import-Reset-Usage-Dictation-Wizard-1 | 11 | 1.794 | 5 |
| Import-Reset-Usage-Dictation-Wizard-2 | 9 | 1.605 | 5 |
| Views-1 | 6 | 2.104 | 1 |
| Views-2 | 6 | 2.223 | 2 |
| Views-3 | 4 | 1.732 | 4 |
| Views-4 | 5 | 2.241 | 3 |
| Views-5 | 7 | 1.939 | 1 |
| Views-6 | 7 | 2.289 | 4 |
| Views-7 | 9 | 2.230 | 3 |
| Views-8 | 6 | 2.220 | 2 |
| Views-9 | 6 | 2.127 | 3 |
| Views-10 | 6 | 1.661 | 2 |
| Views-11 | 2 | 2.182 | 4 |
| Views-12 | 4 | 941 | 0 |
| **Total** | **368** | **99.603** | **153** |

## 3. Achados por área e severidade

| Área (ramo) | P1 | P2 | P3 | Total |
|---|---|---|---|---|
| Segurança (comandos, git, permissões) (`polimento2/seguranca`) | 2 | 8 | 5 | 15 |
| Motor (`polimento2/motor`) | 0 | 4 | 9 | 13 |
| Navegador e catálogo (`polimento2/navegador-catalogo`) | 0 | 2 | 5 | 7 |
| Ferramentas de interface (`polimento2/ferramentas-ui`) | 0 | 3 | 10 | 13 |
| Ferramentas de documentos e web (`polimento2/ferramentas-docs-web`) | 0 | 5 | 9 | 14 |
| App (raiz) (`polimento2/app-raiz`) | 0 | 4 | 19 | 23 |
| Grupos, multi-Orb e memória (`polimento2/grupos-multiorb-memoria`) | 0 | 4 | 18 | 22 |
| Telas A (`polimento2/telas-a`) | 0 | 5 | 12 | 17 |
| Telas B, importação e Orbs (`polimento2/telas-b-import-orbs`) | 0 | 4 | 17 | 21 |
| **Total** | **2** | **39** | **104** | **145** |

### Os dois P1

- **#37, `Engine/GitRepoTrust.swift`: logicalLines junta a linha seguinte a um comentário que termina em barra invertida, e uma chave perigosa some dentro do comentário.** Um repositório baixado traz .git/config com `[core]\n\t# x \\\n\tfsmonitor = ./evil.sh\n`. O git (config.c, git_parse_source) termina o comentário no fim da linha física: a barra invertida não conta em comentário, então `fsmonitor = ./evil.sh` é uma chave real e `git status` executa ./evil.sh. Aqui logicalLines junta as duas linhas em `\t# x \tfsmonitor = ./evil.sh`, que começa com `#` e é ignorada. isSafe devolve true, o `git status` é liberado como leitura em 'Só leitura' e executa código do repositório sem pedir. O mesmo vale para comentário depois de valor: `fsmonitor = false # c \\` seguido de `fsmonitor = /tmp/x` (unquoted corta em `#`, vira `false`). O teste existente 'line continuation' só cobre continuação dentro de um valor (`fsmonitor = /tmp/\\\nx`), que o git também junta. Corrigido em 60d13f5 (ProgramSettingsTests.configsThatRunProgramsAreNotExempt (casos 'comment continuation' e 'value comment continuation')).
- **#38, `Engine/GitRepoTrust.swift`: BOM UTF-8 no começo do config faz o primeiro cabeçalho ser ignorado e a seção ficar vazia.** O .git/config baixado começa com o BOM (EF BB BF) seguido de `[core]\n\tfsmonitor = /tmp/x\n` (ou `[include]\n\tpath = /tmp/mais`). O git ignora o BOM do começo do arquivo (config.c pula utf8_bom na primeira posição) e lê `[core]` normalmente. Aqui a primeira linha é `\u{FEFF}[core]`: U+FEFF não é espaço nem '[' nem letra, então não cai no ramo de cabeçalho e o key fica vazio, o que dá `continue`. `section` fica "" e `fsmonitor = /tmp/x` não passa pelo teste `section == "core"`; `[include]` nem é visto. isSafe devolve true e `git status` roda o programa sem perguntar. Chaves como textconv/command/pager continuam pegas porque programKeys não depende da seção; escapam as que dependem (core.fsmonitor, core.worktree, e as seções include/includeif/filter/pager do primeiro cabeçalho). Corrigido em 60d13f5 (ProgramSettingsTests.configsThatRunProgramsAreNotExempt (casos 'bom core fsmonitor' e 'bom include') e aByteOrderMarkDoesNotHideTheFirstHeaderButCleanSettingsStayExempt).

## 4. O que foi corrigido

Cada linha: número do achado, severidade, título, commit e teste de regressão. "compila" vale para comentário e código morto. ✔ = o teste foi conferido falhando sem a correção.

### Segurança (comandos, git, permissões) (`polimento2/seguranca`)

- **#37 P1** logicalLines junta a linha seguinte a um comentário que termina em barra invertida, e uma chave perigosa some dentro do comentário (`Engine/GitRepoTrust.swift:184`). 60d13f5 · ProgramSettingsTests.configsThatRunProgramsAreNotExempt (casos 'comment continuation' e 'value comment continuation') ✔
- **#38 P1** BOM UTF-8 no começo do config faz o primeiro cabeçalho ser ignorado e a seção ficar vazia (`Engine/GitRepoTrust.swift:127`). 60d13f5 · ProgramSettingsTests.configsThatRunProgramsAreNotExempt (casos 'bom core fsmonitor' e 'bom include') e aByteOrderMarkDoesNotHideTheFirstHeaderButCleanSettingsStayExempt ✔
- **#22 P2** Selo "Oficial" do registro MCP é dado por prefixo de texto e pode ser falsificado (`Catalog/MCPRegistry.swift:29`). 2025aeb · CatalogTests.theOfficialSealNeedsTheWholeNamespace ✔
- **#28 P2** Cada `cd` relativo dobra a lista de pastas possíveis: linha com vários `cd` trava a checagem de perigo (`Engine/DangerousCommand.swift:181`). ca92fb1 · DangerousCommandTests.manyRelativeCdsDoNotBlowUpTheCheck
- **#29 P2** `effective` desiste depois de 12 palavras puladas e devolve nil: comando perigoso passa sem aviso (`Engine/DangerousCommand.swift:363`). ca92fb1 · DangerousCommandTests.aLongRunOfPrefixesDoesNotHideTheCommand ✔
- **#30 P2** `find` só confere o primeiro `-exec`: um segundo `-exec rm` passa (`Engine/DangerousCommand.swift:265`). ca92fb1 · DangerousCommandTests.destructiveCommandsAreRecognized e wordsInArgumentsAreNotCommands ✔
- **#31 P2** `diskutil apfs deleteVolume/deleteContainer/eraseVolume` não é reconhecido como apagar disco (`Engine/DangerousCommand.swift:285`). ca92fb1 · DangerousCommandTests.destructiveCommandsAreRecognized e wordsInArgumentsAreNotCommands ✔
- **#42 P2** Um & final não marca o comando como segundo plano: "ls &" passa como só leitura (`Engine/ShellCommandLine.swift:122`). c0bae3d · ReadOnlyCommandTests.anythingThatWritesRunsOrHidesWhatItDoesIsNot e aClosingAmpersandMarksTheCommandItEnds ✔
- **#60 P2** BrowseRunRules.words converte número JSON grande com Int() e derruba o app (`Engine/Tools/BrowseMoreTools.swift:463`). 76ad039 · BrowseMoreToolTests.aHugeNumberInTheArgsIsTextNotACrash ✔
- **#64 P2** group_remember: tipo com maiúscula grava preferência fixa sem pedir aprovação (`Engine/Tools/GroupMemoryTools.swift:27`). 76ad039 · MultiOrbCodableTests.aKindWrittenWithCapitalsIsStillAPreferenceThatAsks ✔
- **#33 P3** Comentário de `messagingApps` está colado em cima de `compiledScriptRules` (`Engine/DangerousCommand.swift:659`). ca92fb1 · compila
- **#36 P3** `let lowered = name` é apelido sem função (`Engine/DangerousCommand.swift:107`). ca92fb1 · compila
- **#39 P3** Migração de "Sempre permitir WebSearch" vira permissão para qualquer site (alarga a permissão) (`Engine/PermissionPolicy.swift:643`). 5f4a44b · PermissionRulePersistenceTests.anOldWebSearchGrantDoesNotBecomeAnySite e oldAllowedToolsBecomeRulesForBothEnginesNames (agora 9 regras) ✔
- **#40 P3** Comentário da lista de verbos de conector não bate com o dicionário outwardVerbs (`Engine/PermissionPolicy.swift:468`). 5f4a44b · compila
- **#61 P3** browse_find: a trava de campo de senha olha o name em vez do value quando o localizador não é role (`Engine/Tools/BrowseMoreTools.swift:109`). 76ad039 · BrowseMoreToolTests.aNameThatIsNotARoleDoesNotHideAPasswordField ✔

### Motor (`polimento2/motor`)

- **#24 P2** Texto só com espaços/quebras de linha antes de um tool_use vira bloco de texto que a API da Anthropic recusa (400) e envenena a conversa (`Engine/AnthropicClient.swift:167`). 8390918 · AnthropicClientTests.whitespaceOnlyAssistantTextIsNotSentAsATextBlock ✔
- **#25 P2** installation() não acha o claude instalado via npm/nvm/fnm/Volta (PATH vem do .zshrc) (`Engine/ClaudeCode.swift:62`). 9131f22 · ClaudeCodeProcessTests.aClaudeInstalledThroughTheZshrcPathIsFound (ClaudeCodeTests.swift) ✔
- **#32 P2** `lastQuestion` corta a pergunta em qualquer ponto (nome de arquivo, versão, URL), guardando só um pedaço (`Engine/ConversationLedger.swift:468`). 5ecd802 · LedgerDecisionTests.aQuestionKeepsItsFileNamesAndVersionsWhole ✔
- **#41 P2** Skill não é expandida quando o /slug vem seguido de quebra de linha ou tab (`Engine/SystemPrompt.swift:331`). 294f741 · ModelTests.aSkillIsExpandedWhenALineBreakOrTabFollowsTheSlug (AgentEngineTests.swift) ✔
- **#26 P3** reportedWindow não lê 'context length of only 4096 tokens' (recusa do LM Studio) (`Engine/ContextBudget.swift:245`). 6b09312 · ReportedWindowTests.windowsAreReadFromTheWordingOfSeveralProviders ✔
- **#27 P3** connector_tools com `tools` como texto JSON ou lista separada por vírgula vira um nome só e não lista nada (`Engine/ConnectorGateway.swift:191`). ac92401 · ConnectorGatewayTests.theListingGivesNameDescriptionAndArguments ✔
- **#34 P3** Mensagem só com imagem vira o objetivo atual: "(imagem anexada)" substitui a tarefa (`Engine/ConversationLedger.swift:245`). 5ecd802 · LedgerOriginalTests.aPictureAloneDoesNotReplaceTheGoal ✔
- **#35 P3** `ToolReference.name` é gravado e nunca lido (`Engine/ConversationLedger.swift:578`). 5ecd802 · compila
- **#43 P3** Comentário diz que o backoff nunca passa de maxBackoff (30 s), mas o limite de uso espera até 60 s (`Engine/Retry.swift:79`). a7c4f85 · RetryTests.aUsageLimitWaitsLongerThanTheCapOfPassingFailures
- **#44 P3** aSlowButLiveResponseIsNeverCutOff depende de tempo real com folga de 350 ms (`Tests/TurnReliabilityTests.swift:167`). 39c11a5 · TurnReliabilityTests.aSlowButLiveResponseIsNeverCutOff
- **#45 P3** Com o mesmo hash, bloco de edições grande demais vira .nothing e a edição se perde para sempre (`Engine/WorkspaceChanges.swift:22`). 62f96a5 · WorkspaceChangesTests: anEditInATinyFolderIsNotLostWhenItsBlockIsAsLongAsTheSnapshot ✔
- **#46 P3** hasSnapshot procura a tag na mensagem inteira, não só no preface (`Engine/TurnPrompt.swift:139`). 62f96a5 · WorkspaceChangesTests: aSnapshotTagInTheMessageItselfIsNotASnapshot ✔
- **#53 P3** Arquivo de sessão em ~/.claude/projects fica para sempre se o app cair no meio do turno (`Engine/ClaudePipe/ClaudeCodeClient.swift:278`). 1eeff35 · ClaudeCodeClientTests.sessionFilesAKilledAppLeftInTheProjectFolderAreSwept ✔

### Navegador e catálogo (`polimento2/navegador-catalogo`)

- **#23 P2** Falha de rede ao ler um SKILL.md fica guardada como "não existe" até reiniciar o app (`Catalog/SkillCatalog.swift:146`). cb30b85 · SkillLocatingTests.aTransientFileFailureIsTriedAgain e aFileThatIsNotThereIsNotAskedForAgain ✔
- **#47 P2** close(botID:) não registra o close em closings: uma chamada de session durante o close abre o navegador novo e o close antigo o fecha (`Engine/Browser/BrowserHub.swift:674`). 9d26611 · BrowserHubReplacementTests.aCallDuringCloseBotIDWaitsForTheCloseToFinish ✔
- **#48 P3** Checksum.parseDigest nunca é chamado (`Engine/Browser/BrowserInstallNetwork.swift:24`). 821ec94 · compila
- **#49 P3** Marca de limpeza no futuro desliga a limpeza do cache até o relógio alcançá-la (`Engine/Browser/BrowserProfileCache.swift:29`). be25a2d · BrowserProfileCacheTests.aNoteFromTheFutureDoesNotSwitchTheCleaningOff ✔
- **#50 P3** Falha ao atualizar mostra "Foi removido", mas a versão antiga continua instalada (updateRolledBack nunca é lançado) (`Engine/Browser/BrowserInstallTypes.swift:143`). 8e404cb · BrowserInstallerTests.aFailedUpdateLeavesTheInstalledOneAsItWas (ajustado para esperar .updateRolledBack) e aFirstInstallThatDoesNotStartIsToldAsBroken ✔
- **#51 P3** BrowserInstallError.unsupportedMac e .assetMissing nunca são lançados (`Engine/Browser/BrowserInstallTypes.swift:138`). 821ec94 · compila
- **#52 P3** BrowserSetup.isBusy e lastCheck sem leitor (`Engine/Browser/BrowserSetup.swift:91`). 821ec94 · compila

### Ferramentas de interface (`polimento2/ferramentas-ui`)

- **#55 P2** keys do ui_act quebra a tecla vírgula (cmd+, = Ajustes) ao separar os atalhos por vírgula (`Engine/Tools/AccessibilityTools.swift:1158`). 16a2cd4 · AccessibilityEngineTests.theCommaIsAKeyWhenItIsTheShortcutNotTheSeparator ✔
- **#56 P2** set_value com texto vazio no caminho por digitação seleciona tudo mas não apaga nada, e diz que escreveu (`Engine/Tools/AccessibilityTools.swift:1897`). 16a2cd4 · AccessibilityEngineTests.clearingAFieldThatRefusesAXValueDeletesWithTheKeyboard ✔
- **#57 P2** Regra de perigo 'esvaziar lixeira' não reconhece 'Esvaziar Lixo…', o nome do item no macOS em pt-BR (`Engine/Tools/AccessibilityTools.swift:982`). 16a2cd4 · AccessibilityToolTests.destructiveWordsAreRecognizedWhateverTheLanguageOrAccent e pickMenuIsJudgedByItsLastItem ✔
- **#54 P3** AXEvent.receivedAt é gravado mas nunca lido (`Engine/Tools/AccessibilityContracts.swift:49`). 40606ee · compila
- **#58 P3** wait vazio ("") em ui_act desliga o assentamento mas nenhuma espera é feita (`Engine/Tools/AccessibilityTools.swift:1400`). 16a2cd4 · AccessibilityEngineTests.anEmptyWaitIsNoWaitAndTheActionStillSettles ✔
- **#59 P3** UIWaitCondition: modo com espaço ('appears ') vira disappears (`Engine/Tools/AccessibilityTools.swift:395`). 16a2cd4 · AccessibilityEngineTests.waitConditionsNeedWhatTheyWatch (casos " Appears\t" e " disappears ") ✔
- **#62 P3** ShortcutNamesCache apaga os nomes bons quando uma releitura falha (`Engine/Tools/AppControlInfo.swift:78`). 675813e · AppControlInfoTests.aFailedRereadKeepsTheNamesAlreadyKnown ✔
- **#63 P3** read_file de imagem não para no ⌘. e não tem prazo para o OCR (`Engine/Tools/FileTools.swift:56`). 54f895a · FileToolTests.readImageStopsWaitingWhenTheTurnIsCancelled ✔
- **#67 P3** read_file nunca lê .rtfd: o pacote é recusado como pasta (`Engine/Tools/FileTools.swift:41`). 54f895a · FileToolTests.readAnRTFDPackageAsADocumentNotAFolder ✔
- **#70 P3** Cabeçalho diz que tudo exige "Controlar apps do Mac" menos notify, mas a Lixeira roda com "Terminal e arquivos" (`Engine/Tools/MacAppTools.swift:5`). a73965b · compila
- **#74 P3** UCKeyTranslate recebe kUCKeyTranslateNoDeadKeysBit (0) em vez da Mask (1): teclas mortas somem do mapa (`Engine/Tools/ScreenTakeover.swift:617`). 8957308 · ScreenTakeoverTests.theLayoutTranslationAsksForNoDeadKeys ✔
- **#75 P3** waitUntil gira sem pausa e troca o cancelamento por couldNotBringToFront (`Engine/Tools/ScreenTakeover.swift:416`). 8957308 · ScreenTakeoverTests.cancellingWhileTheAppComesForwardIsCancellationNotCouldNotBringToFront ✔
- **#76 P3** OCR que estoura o prazo ou falha vira "Não achei texto legível na imagem" (`Engine/Tools/ScreenshotTool.swift:391`). 9125766 · ToolEconomyTests.aReadingThatFailedDoesNotClaimThereIsNoText ✔

### Ferramentas de documentos e web (`polimento2/ferramentas-docs-web`)

- **#65 P2** update_event encolhe evento de dia inteiro com vários dias para um dia só (`Engine/Tools/CalendarConnector.swift:391`). 3d3b5bb · CalendarConnectorTests.updatingAMultiDayAllDayEventKeepsItsLength ✔
- **#68 P2** SpreadsheetML: aba com mais de 20 mil linhas aborta o parser e descarta todas as abas seguintes, sem aviso (`Engine/Tools/LegacyExcelReader.swift:916`). 2ed4b56 · LegacyExcelReaderTests.spreadsheetMLWithAHugeFirstSheetStillReadsTheNextSheets ✔
- **#71 P2** Notas do apresentador do .pptx são ligadas ao slide pelo número do arquivo, não pela relação do slide (`Engine/Tools/OfficeReader.swift:75`). 1b9cd00 · OfficeReaderTests.readPowerPointNotesFollowTheSlideRelationship ✔
- **#73 P2** grep descarta os acertos já achados no arquivo em que o prazo estoura (`Engine/Tools/SearchTools.swift:282`). a276ebf · SearchToolTests.grepKeepsMatchesFoundBeforeTheTimeBudgetRanOut ✔
- **#78 P2** O "+" da consulta não é codificado: "C++" chega ao buscador como "C" + espaços (`Engine/Tools/WebSearchTool.swift:420`). d493da6 · WebSearchToolTests.aPlusInTheQueryReachesTheSearchEngineEncoded ✔
- **#66 P3** Nome do elemento no cartão de aprovação vem do último snapshot do Orb, de qualquer conversa, e sobra depois de voltar ou trocar de aba (`Engine/Tools/BrowseTools.swift:148`). 5b2b083 · BrowseToolTests.theApprovalCardNamesTheRefOfItsOwnConversation ✔
- **#69 P3** web_fetch deixa &deg;, &times;, &rarr; etc. literais e converte &#150; em caractere de controle (`Engine/Tools/HTMLText.swift:645`). 3f615a6 · ToolTests.htmlTextDecodesDegreeTimesArrowAndWindows1252References ✔
- **#72 P3** enabled e run_now só valem como booleano JSON; "false" em texto cria a tarefa ligada (`Engine/Tools/ScheduleTool.swift:30`). 7857b67 · ScheduleCommandTests.aCreateReadsEnabledAndRunNowGivenAsText; MacToolTests.everythingOpensInTheBackgroundUnlessFrontIsAsked ✔
- **#77 P3** Concordância: "1 arquivos" / "1 linhas" nas respostas do grep (`Engine/Tools/SearchTools.swift:332`). a276ebf · SearchToolTests.grepAnswersInTheSingularForOneFileOrOneLine ✔
- **#79 P3** As strings do argv vazam quando o ambiente tem um byte nulo (`Engine/Tools/SpawnedProcess.swift:27`). 139f51f · SpawnedProcessTests.aNullByteInTheEnvironmentIsRefused
- **#80 P3** Prazo do save_to só é conferido a cada 1024 bytes recebidos; fluxo lento não expira (`Engine/Tools/WebTools.swift:410`). 7b157c0 · TurnReliabilityTests.aDownloadTrickingInAByteAtATimeIsGivenUpAtTheDeadline ✔
- **#81 P3** Mensagem de conteúdo não textual fica 'de (não é texto)' quando o servidor não informa o tamanho (`Engine/Tools/WebTools.swift:142`). 7b157c0 · EndlessResponseTests.theNotTextAnswerReadsWellWithAndWithoutASize ✔
- **#82 P3** Doc de explain(_:url:) está colado em cima do doc de redirectMessage (`Engine/Tools/WebTools.swift:351`). 7b157c0 · compila
- **#83 P3** WebPageCache.clear() não tem nenhum chamador (`Engine/Tools/WebTools.swift:482`). 7b157c0 · compila

### App (raiz) (`polimento2/app-raiz`)

- **#2 P2** ⌥↑/⌥↓ (Orb anterior/próximo) andam na ordem de `bots`, não na ordem da lateral com categorias (`AppModel.swift:1197`). 55089a7 · SidebarCategoryTests.nextAndPreviousOrbWalkTheSidebarNotTheOrderOfCreation e deletingTheSelectedOrbSelectsTheOneAtTheTopOfTheSidebar ✔
- **#7 P2** Citação clicada com a barra de busca aberta deixa a mancha (wash) ligada para sempre (`ConversationFind.swift:265`). 6e7e2ce · ConversationSearchTests.aQuoteClickedWithTheBarOpenGivesTheMarksBackToTheHitWhenTheWashFades ✔
- **#8 P2** Busca sem resultados limpa a marca mas deixa pausesFollowing ligado: o chat para de seguir o fim (`ConversationFind.swift:173`). 6e7e2ce · ConversationSearchTests.aSearchThatFindsNothingLetsTheChatFollowAgain ✔
- **#84 P2** Ao voltar para o app, a bolinha de não lido do grupo aberto não some (`AppModel.swift:487`). 55089a7 · GroupRunTests.comingBackToTheAppReadsTheGroupThatIsOpen ✔
- **#0 P3** nameMismatch não pega "a cada Nh": a alternativa "a cada" ganha da que captura as horas (`AppModel+RoutinesUI.swift:191`). df96a0c · RoutinesUITests.aNameThatPromisesARhythmTheScheduleDoesNotKeepIsFlagged ✔
- **#1 P3** isSettingsProblem trata "modelo recusado, chave certa" como problema de chave e põe "Abrir Ajustes" na frente (`AppModel+Transcript.swift:144`). df96a0c · TranscriptActionsTests.aModelTheProviderRefusedWithAGoodKeyOnlyOffersToTryAgain ✔
- **#3 P3** Apagar um Orb não descarta as conversas de rotina que ficaram só na memória, e o ⌘Q as grava de novo (`AppModel.swift:1146`). 55089a7 · RoutineTests.aDeletedOrbDoesNotGetItsUnwrittenRoutineConversationBackOnQuit ✔
- **#4 P3** Comentário de `clientOverride` está colado em `homeFolder` (`AppModel.swift:249`). 55089a7 · compila
- **#5 P3** `modelName(for bot:)` não tem nenhum chamador (`AppModel.swift:642`). 55089a7 · compila
- **#6 P3** Banner "Parar" de turno em círculos nunca é recolhido e, tocado depois, para um turno que não é o do aviso (`ApprovalNotifications.swift:185`). 415b744 · ApprovalNotificationTests.theStopBannerOfATurnIsTakenDownLikeTheOthersAndIsOnePerOrb ✔
- **#9 P3** Intervalo mínimo entre execuções ignora as horas: "0,50 8 * * *" é recusada por 'menos de 15 minutos' (`CronExpression.swift:31`). 0e7843f · ScheduleToolTests.theMinimumGapBetweenRunsCountsTheHoursToo ✔
- **#10 P3** Trecho (snippet) fica sem nenhum contexto quando o único espaço da janela encosta no resultado (`ConversationSearch.swift:316`). 6e7e2ce · ConversationSearchTests.aSnippetKeepsSomeContextWhenTheOnlySpaceTouchesTheMatch ✔
- **#11 P3** Parâmetro `announcing` de reveal(announcing:) é sempre true (`ConversationFind.swift:232`). 6e7e2ce · compila
- **#12 P3** Descrição das permissões de Automação concorda errado: "Controlar o Notas / Mensagens / Lembretes / Música" (`MacPermissions.swift:81`). 7aeb05d · MacPermissionsTests.theAutomationLinesNameTheAppWithoutAnArticleThatDisagreesWithIt ✔
- **#13 P3** Comentário de documentação de appNames(in:) está colado na regex, e a função fica sem documentação (`MacPermissions.swift:589`). 7aeb05d · compila
- **#14 P3** Comentário de newLineKeys diz o contrário do que a constante e o app fazem (`Shortcuts.swift:32`). 7aeb05d · compila
- **#15 P3** Comentário de textSwap se corrige no meio da frase (`MotionControls.swift:41`). 7aeb05d · compila
- **#16 P3** Dictation.showsInSnapshots = true repetido dentro do case (`SnapshotComposerScenes.swift:42`). 25a004c · compila
- **#17 P3** Teste de aviso fechado espera 300 ms de relógio real para provar uma ausência (`Tests/SystemCommandsTests.swift:420`). 3f672ce · SystemCommandsTests.aNoticeThatWasClosedIsNotBroughtBackByTheMove
- **#18 P3** Arquivo lido com itens pulados segue sem cópia e sem aviso quando a cópia falha (`Store.swift:523`). e73be97 · StoreTests.anItemSkippedWhenNoCopyCanBeKeptBlocksTheWritesAndSaysSo ✔
- **#19 P3** Ramo keepsColors do shimmer nunca é usado (e fillsBackground: false junto) (`Theme.swift:197`). 25a004c · compila
- **#20 P3** Comentário de Palette.faint dá razões de contraste que não batem (`Theme.swift:40`). 25a004c · AjustesPolishTests.faintsContrastIsWhatItsCommentSays
- **#21 P3** Tip.all esquece dicas que cumprem o estilo, então o teste de estilo não as cobre (`Tips.swift:299`). 7cf6764 · HoverTipsTests.everyTipIsInTheListThatHoldsThemToTheStyle ✔

### Grupos, multi-Orb e memória (`polimento2/grupos-multiorb-memoria`)

- **#91 P2** orbDeleted descarta a conversa suspensa do destino sem fechar as linhas abertas no arquivo (`MultiOrb/DelegationHub.swift:642`). b1c6463 · DelegationHubTests.deletingTheAskerClosesTheLinesOfAWaitingTarget ✔
- **#102 P2** startFromKept apaga a entrevista pendente ao gravar o que a pessoa escreveu para o Orb novo (`Memory/MemoryBank.swift:158`). 04699c1 · KeptMemoryTests.startingFromAFolderWithNothingLearnedKeepsTheInterviewEvenWithNotes ✔
- **#103 P2** A consolidação corta para 240 caracteres as notas de 'Como funcionar' mais longas, e a ponta se perde da memória viva (`Memory/MemoryConsolidation.swift:87`). 04699c1 · MemoryConsolidationTests.aLongNoteSurvivesAPass ✔
- **#105 P2** Pedido para memorizar perde a pontuação final do conteúdo (10%, C#, parênteses, aspas) (`Memory/MemoryIntent.swift:67`). 9728711 · MemoryIntentTests (MemoryTests.explicitRequestsAreRecognizedWithWhatToKeep) ✔
- **#85 P3** Objetivo ou combinado recusado/que falhou ao gravar some sem nenhum aviso (`Groups/AppModel+GroupBoard.swift:17`). 32b4900 · GroupBoardSavingTests.anObjectiveTheBankRefusesSaysSo, anAgreementThatCouldNotBeWrittenSaysSo ✔
- **#86 P3** Página de sessão do quadro come o '#' do fim das linhas que começam com '#' (C#, #1) (`Groups/GroupBoard.swift:57`). 32b4900 · GroupSupportTests.aHeadingKeepsItsTrailingHashInTheSessionPage ✔
- **#87 P3** Contador de tokens do grupo diz '1000 mil tokens' / '2000 mil tokens' a partir de 1 milhão (`Groups/GroupBoard.swift:73`). 32b4900 · GroupSupportTests.aMillionTokensIsNotSaidAsAThousandThousand ✔
- **#88 P3** Comentário fala em 'header with the budget' mas o orçamento do grupo foi removido (`Views/Groups/GroupChatView.swift:38`). 0321d47 · compila
- **#89 P3** O nome do grupo digitado em Ajustes só é gravado com Return e se perde ao trocar de aba ou clicar fora (`Views/Groups/GroupPanel.swift:220`). 0321d47 · GroupNameEditTests.aTypedNameIsKeptTrimmedAndAnEmptyOrSameOneIsNot
- **#90 P3** GroupPresence.names duplica GroupPresence.list (as duas só repassam PortugueseList.join) (`Views/Groups/GroupPresenceStrip.swift:60`). 0321d47 · compila
- **#92 P3** AppModel.servingRequest(of:) não tem nenhum chamador (`MultiOrb/AppModel+Delegation.swift:81`). bc1da4a · compila
- **#93 P3** Comentário diz que DelegationHub é 'uma casca até o runtime chegar', mas o runtime já existe (`MultiOrb/DelegationService.swift:10`). bc1da4a · compila
- **#94 P3** Dois comentários de documentação empilhados em waiting(_:inChain:), o primeiro é resto de versão antiga (`MultiOrb/DelegationHub.swift:757`). b1c6463 · compila
- **#95 P3** 'Criado por' mostra o nome antigo do criador depois que ele é renomeado (`Views/Multi/CreatedByLine.swift:16`). a1213bc · CreatedByLineTests.theLineNamesTheCreatorAsItIsCalledNowAndAsItWasOnceItIsGone
- **#96 P3** Cartão respondido mostra a pasta errada ("Pesquisador 2") depois que o Orb foi criado (`Views/Multi/OrbProposalCard.swift:281`). a1213bc · OrbProposalTests.aCreatedCardDoesNotNameTheNextFreeFolder
- **#97 P3** ⌘↩ cria o Orb com nome vazio mesmo com o botão Criar desabilitado (`Views/Multi/OrbProposalCard.swift:450`). a1213bc · OrbProposalTests.aNameThatClipsToNothingCannotBeCreated
- **#98 P3** ProposalSpeech.excerpt apaga pontuação do início do texto ("- ", "(", "“", "*", "¿") (`Views/Multi/OrbProposalCard.swift:49`). a1213bc · ProposalSpeechTests.theExcerptKeepsWhatOpensTheText ✔
- **#99 P3** Linha "X pediu ajuda ao Y" abre troca vazia, com título em branco e botão "Voltar ao " (`Views/Multi/EventLineView.swift:38`). a1213bc · ExchangePartiesTests.anExchangeWithNothingToReadNamesTheTwoOrbsOfTheEventLine
- **#100 P3** Comentário diz que "Ver o trabalho" só aparece com onOpenWork, mas o código também o mostra com `work` (`Views/Multi/ExchangeSheet.swift:5`). a1213bc · compila
- **#101 P3** Troca só com avisos (tell) a 2 Orbs é intitulada "Pediu ajuda a 2 Orbs" (`MultiOrb/TranscriptFolding.swift:247`). a1213bc · TranscriptFoldingTests.exchangeTitles ✔
- **#104 P3** applyConsolidation não respeita o banco fechado e pode recriar a pasta de um Orb apagado ou guardado (`Memory/MemoryConsolidation.swift:148`). 04699c1 · MemoryConsolidationTests.aClosedBankWritesNoArchive ✔
- **#106 P3** flatten apaga CR solto e junta as palavras ao redor (`Memory/MemoryPage.swift:376`). 9728711 · MemorySafetyTests.theSanitizerLeavesProseAlone ✔

### Telas A (`polimento2/telas-a`)

- **#117 P2** Return no campo vazio de "Trocar" apaga a chave do TinyFish em silêncio (e uma falha ao salvar descarta a chave colada) (`Views/BrowserSettings.swift:171`). 2f42365 · WebSearchTests.anEmptyFieldNeverReachesTheKeychain
- **#124 P2** Editor salva comando, nome e URL sem aparar os espaços, mas valida aparados (`Views/ConnectorsView.swift:1272`). 00a0fd3 · ConnectorGalleryTests.theEditorStoresTheName...
- **#127 P2** Soltar arquivo na aba do marketplace é cancelado pelo onChange(of: source) (`Views/ImportPanel.swift:134`). 4f79ddf · GrokMarketplaceTests (ImportSourceSwitch.after)
- **#128 P2** Prévia de importação do assistente fica escondida na aba do marketplace, mas 'Usar esta importação' continua habilitado (`Views/ImportPanel.swift:116`). 4f79ddf · GrokMarketplaceTests (ImportSource.opening)
- **#132 P2** Return no popover de modelos do compositor troca o modelo do Orb sem nada digitado (`Views/ModelPopover.swift:24`). 1bfa98c · ComposerSupportTests.returnInTheComposersModelSearchPicksNothingUntilSomethingIsTyped; ModelSearchTests.returnWithNothingTypedPicksTheDefaultWhenThereIsOne ✔
- **#118 P3** Dica de demora (slowHint) aparece na hora na busca seguinte: o .task seta isSlow = true até quando é cancelado e isSlow nunca volta a false (`Views/CatalogParts.swift:306`). 00a0fd3 · CatalogTests.theSlowHintOnlyComesFromAWaitThatRanToTheEnd
- **#119 P3** installsLabel mostra "1.000 mil instalações" para contagens entre 999.500 e 999.999 (`Views/CatalogParts.swift:413`). 00a0fd3 · CatalogTests.installCountsReadNaturally
- **#120 P3** Skill com slug exato pode ficar fora das 5 sugestões e o Return completa outra em vez de enviar (`Views/ComposerSupport.swift:66`). a970939 · ComposerSupportTests.aSlugTypedInFullIsNotCutFromTheFiveSuggestions
- **#121 P3** Comentário de CardParts diz três coisas, mas o struct tem cinco campos (`Views/ComposerView.swift:525`). 8ebdbbd · compila
- **#122 P3** Doc de PasteGate está colada em cima de NewLineKey; PasteGate fica sem doc (`Views/ComposerView.swift:758`). 8ebdbbd · compila
- **#123 P3** Doc de SkillsPopover.height está em cima da constante chrome e cita 46 pt enquanto o valor é 48 (`Views/ComposerChips.swift:246`). 8ebdbbd · compila
- **#125 P3** "Tentar de novo" da busca no registro não é cancelado e pode sobrescrever o resultado de uma busca mais nova (`Views/ConnectorsView.swift:653`). 00a0fd3 · ConnectorGalleryTests.aSearchRetriedBefore...
- **#126 P3** Orb cuja pasta de trabalho é a pasta pessoal escrita por extenso aparece como "Trabalha em ~" e ganha as sugestões de pasta própria (`Views/EmptyChatContent.swift:87`). 5b342da · EmptyChatContentTests.theHomeFolderWrittenOutIsStillTheHomeFolder
- **#129 P3** Trocar de aba apaga a prévia, mas o texto colado (ou o link) continua no campo e nada lê de novo (`Views/ImportPanel.swift:153`). 4f79ddf · GrokMarketplaceTests
- **#130 P3** A leitura cancelada apaga o readingLink da leitura nova da mesma página (o spinner some com a requisição ainda em andamento) (`Views/ImportPanel.swift:367`). 4f79ddf · GrokMarketplaceTests (LinkReading)
- **#131 P3** ProviderHealth.refresh grava o cancelamento da tarefa como falha do provedor (`Views/ProviderSettings.swift:21`). 9e63698 · ModelRefreshBackoffTests.aCheckThatWasCancelledIsNotRecordedAsTheProvidersFailure ✔
- **#133 P3** Trocar a chave: se a atualização de modelos falha, a linha fica presa no modo de troca (`Views/ProviderSettings.swift:369`). 9e63698 · ModelRefreshBackoffTests.theRowLeavesTheReplaceModeEvenWhenLoadingTheModelsFails ✔

### Telas B, importação e Orbs (`polimento2/telas-b-import-orbs`)

- **#112 P2** Redefinir o Orb deixa para trás os perfis do navegador (logins e cookies de cada Orb) (`Reset/ResetExecutor.swift:64`). 8b21bf0 · ResetTests
- **#113 P2** Falha no meio da resposta deixa o texto parcial no chat e "Tentar de novo" o duplica (`Wizard/WizardRunner.swift:253`). 97e71bb · WizardRunnerTests
- **#134 P2** Ligar no cartão uma rotina "uma vez" já passada deixa o interruptor ligado, sem próxima execução e sem aviso (`Views/RoutinesView.swift:242`). c5f4c29 · RoutinesUITests, ScheduleToolTests
- **#141 P2** Editor de preço parte do preço ajustado pela hora (DeepSeek pela metade fora do pico, Gemini dobrado em 2027) e grava isso como correção fixa (`Views/UsageSettings.swift:420`). 503f375 · UsagePricingTests
- **#107 P3** Folha "icone": o ícone de 64 px ampliado 4x invade o ícone de 256 px da linha de cima (`Orbs/OrbDesignSheets.swift:274`). 7afaa95 · OrbDesignTests
- **#108 P3** Comentário do Blinker diz que a piscada pedida "espera", mas o código a descarta (`Orbs/OrbMotion.swift:179`). 7afaa95 · compila
- **#109 P3** Apelido do cartão de personagem entra como template de regex ($0, \) ao trocar {{char}} (`Import/OrbImportFormats.swift:235`). 012243d · OrbImportTests
- **#110 P3** ImportPrompt.version continua sem nenhum uso (`Import/ImportPrompt.swift:8`). 012243d · compila
- **#111 P3** bot(.share) usa o id da lista do site sem validar como token antes de montar a URL (`Import/GrokMarketplace.swift:160`). 012243d · GrokMarketplaceTests
- **#114 P3** WizardRunner.canConverse não tem nenhum chamador (`Wizard/WizardRunner.swift:76`). 97e71bb · compila
- **#115 P3** Parâmetro tracksHistory de consume é sempre true (`Wizard/WizardRunner.swift:227`). 97e71bb · compila
- **#116 P3** Comentário de UsageReport.make fala de um parâmetro `names` que não existe (`Usage/UsageReport.swift:118`). 3b84eca · compila
- **#135 P3** Painel da barra de menus diz "respondeu" e esconde o que o Orb faz enquanto ele ainda trabalha depois de uma fala intermediária (`Views/QuickAskView.swift:380`). 6b3befe · SystemCommandsTests
- **#136 P3** "Abrir ao iniciar sessão" volta para desligado sem explicar quando o macOS pede aprovação, e não relê o estado ao voltar ao app (`Views/SettingsView.swift:354`). edef84e · AjustesPolishTests
- **#137 P3** O papel do novo Orb não é aparado: só espaços viram papel em branco em vez de "Assistente pessoal" (`Views/SheetsAndSettings.swift:434`). d0edd28 · PanelUITests
- **#138 P3** O comentário dos snapshots de Ajustes não lista settings-orbs nem settings-usage, que o switch atende (`Views/SettingsView.swift:368`). edef84e · compila
- **#139 P3** Busca do catálogo: o 'Tentar de novo' roda numa Task solta e pode sobrescrever os resultados de uma busca mais nova (`Views/SkillsView.swift:263`). e268155 · InterfacePolishTests
- **#140 P3** Salvar o editor sobrescreve a skill inteira com a cópia antiga (perde uses atualizado em segundo plano) (`Views/SkillsView.swift:615`). e268155 · InterfacePolishTests
- **#142 P3** NoticeLine lê a lista de itens do chat mesmo quando o aviso não tem ação (e o comentário diz que não) (`Views/TranscriptViews.swift:1124`). 6527b7f · TranscriptActionsTests
- **#143 P3** Linha de ferramenta que falhou é lida pelo VoiceOver igual à que deu certo (`Views/TranscriptViews.swift:807`). 6527b7f · TranscriptActionsTests
- **#144 P3** Comentário do MarkdownCache está colado na constante de bytes e promete cache que o streaming não usa (`Views/TranscriptViews.swift:653`). 6527b7f · compila

## 5. Descartados

Os 8 achados que o cético derrubou na rodada 1. Nenhum foi descartado na rodada 2.

- **P3 (Raiz-8)** aReadDoesNotWaitBehindWritesToOtherFiles trava a suíte inteira se a regressão voltar. Motivo: O defer { release.signal() } existe de fato, mas se a regressão voltar o teste ainda reprova: a suíte trava e o CI estoura o timeout, então a regressão é pega, só sem mensagem boa. O padrão defer + stallWriter é usado também em RoutineTests (550, 571). O próprio autor admite que não é falha atual, e o ganho é só de ergonomia.
- **P3 (Engine-Tools-3)** theRealListStaysFast depende da máquina, de apps abertos, do `shortcuts` real e de cache global. Motivo: O teste é um teto folgado de propósito (15 s e 5 s, o comentário diz isso, e a REVISAO-USO-DO-COMPUTADOR registra os tempos medidos). Caches .shared já aquecidas só deixam o 'frio' mais rápido e não fazem o teste falhar. Sem sessão gráfica a saída é "Nenhum app aberto.", que o expect aceita, e o formato ' · ... AX bom/fraco' é o que AppControlInfo gera. Não vejo falha concreta provável.
- **P2 (Engine-Tools-6)** Aviso de perigo do open ignora o argumento app e nomes de app resolvidos pelo Spotlight fora das pastas de aplicativos. Motivo: MacToolTests:273 afirma de propósito que um nome de app sem pasta tem danger nil ("the system looks the app up"), e o argumento app usa a mesma busca por nome, então não é um buraco novo. Um caminho completo no app não funciona (application(named:) não resolve caminho), e a exploração precisa de um .app malicioso já no disco, o que passa antes por outra aprovação. A correção seria mudança de política, não bug claro.
- **P3 (Grupos-1)** Descarregar a conversa ociosa de um grupo perde a contagem de não lidos que a lateral ainda mostra. Motivo: A divergência 3 vira 1 existe no código, mas o número não aparece em lugar nenhum: SidebarGroupRow só mostra a bolinha (live.unread > 0) e a acessibilidade diz apenas 'não lido'. A bolinha continua correta (3 ou 1, ambos > 0) e some ao abrir o grupo, então não há efeito observável.
- **P3 (Memory-1)** consolidablePreferences lê do disco um arquivo por preferência curta, a cada snapshot e a cada consulta da consolidação. Motivo: snapshotIfChanged só chama snapshot quando o índice ou a identidade mudaram, então não roda a cada turno. As leituras são de arquivos pequenos de preferências curtas (cerca de 150), alguns milissegundos no ator de fundo, sem impacto perceptível. O custo já está registrado em docs/REVISAO-MEMORIA-2026-10-16.md (P2-6) e a correção sugerida é mudança de esquema sem ganho claro.
- **P3 (Import-Reset-Usage-Dictation-Wizard-1)** Teste do reconhecedor depende da máquina (voz Luciana, modelo pt-BR) e roda em tempo real. Motivo: O teste depende da máquina de propósito, como diz o cabeçalho ('Runs where macOS 26 has Portuguese installed'). O retorno antecipado é a forma de pular em Swift Testing, porque .enabled(if:) não aceita condição assíncrona (supportedLocale e installedLocales são async), então a correção sugerida não se aplica. A lógica de DictationText já tem testes puros. Não é bug do código.
- **P3 (Import-Reset-Usage-Dictation-Wizard-1)** Asserção negativa depende de uma folga de 50 ms sobre o atraso do salvamento agendado. Motivo: scheduleStateSave tem 'guard !isResetting' no início, então depois do reset nenhuma Task de 400 ms nem é criada, e o teste cobre a regressão que importa. A folga de 50 ms só importaria se o guard fosse removido e a máquina estivesse carregada, o que é especulativo. A correção sugerida (stateSaveTask exposto) exigiria mudar código de produção por causa de um teste. Não confirma como defeito.
- **P3 (Views-4)** "o Slack pede a sua licença" usa a palavra errada. Motivo: "Pedir licença" no sentido de permissão é idiomático em pt-BR, e o projeto já usa o termo em Tips.swift:227 ("Pede ao macOS licença para o Orb enviar notificações"). A autoconferência do autor errou ao dizer que só esta linha usa a palavra. Não é bug, é preferência de estilo.
## 6. Ressalvas: o que não foi provado do jeito pedido

- **Ramo telas-b (21 achados):** o agente commitou tudo, mas foi parado (bateria) antes de devolver o relatório, então não há registro de que cada teste foi visto falhando sem a correção. Li o diff inteiro, e os testes das suítes tocadas passam na integração.
- **Telas A, #117 a #130:** o agente não informou a prova de falha. O #117 foi feito por um agente anterior, e o seguinte não refez a prova.
- **Testes que não falham sem a correção, por natureza:**
  - #89, #95, #96, #97 e #99 testam funções novas, que não existem sem a correção. O gatilho de foco do #89 e o ⌘↩ do #97 só se veem na tela.
  - #79: o vazamento só aparece com `leaks`.
  - #20 e #43 eram achados de comentário. O teste prende o comportamento real.
  - #44: o teste depende do tempo. A folga por evento passou de 350 ms para mais de 1 s.
- **#17:** a premissa não se confirmou (tirar a guarda não faz o teste falhar). Mesmo assim, a espera de 300 ms de relógio virou um sinal determinístico.
- **#28:** o teste de 16 pares de `cd` não foi rodado sem a correção, porque estouraria a memória da máquina. Com 8 pares, a medição deu 0,49 s sem a correção e milissegundos com ela.

## 7. Mudanças que aparecem na tela (são correções, mas mudam o que se vê)

Nenhuma foi conferida por captura, porque `--snapshot` rouba o foco:

- **Rotina "uma vez" com a data passada:** o interruptor fica desligado e desabilitado, com a dica "A data desta rotina já passou. Edite a data para ligar de novo". A ferramenta de agendamento diz o mesmo ao Orb.
- **Ajustes → Geral, "Abrir ao iniciar sessão":** quando o macOS espera a aprovação, aparece uma linha de aviso com o botão "Abrir Ajustes do Sistema". O estado é relido ao voltar ao app.
- **Cartão de proposta de Orb:**
  - "Criar" fica desabilitado quando o nome some no corte, também fora da edição;
  - depois de criado, o cartão não mostra mais a linha "Pasta".
- **Linha de evento sem mensagens:** a troca mostra os dois Orbs do evento, e o botão diz "Voltar" quando não há nome.
- **`set_value` com texto vazio:** limpa o campo e diz "Limpei …".
- **Busca de modelos do compositor:** Return com o campo vazio não troca mais o modelo.

## 8. Propostas (não feitas)

- **#27:** `connector_tools` agora lê `tools` como lista, como texto JSON ou como nomes separados por vírgula. Ficou de fora listar tudo quando nenhum nome pedido existe; a mensagem de "não tem" continua a de antes.
- **#96:** o cartão de proposta já criado omite a pasta em vez de mostrar a pasta do Orb criado. Achar esse Orb seria ambíguo com nomes repetidos. Dá para guardar o id do Orb criado na proposta, se valer a pena.

## 9. Integração

- `nice -n 15 swift build --build-tests` em `integracao-polimento`: compila sem erro e sem aviso.
- Testes filtrados:
  - suítes dos 70 arquivos de teste tocados: 2.244 testes em 231 suítes. Falhou um, `GroupNoLimitTests.aRequestRunsAsManyTurnsAsItTakes`, que conferia o texto antigo "3000 mil tokens" corrigido no #87; acertado em 0b6b7e4;
  - suítes não tocadas que usam tipos dos arquivos de código mudados: 1.760 testes em 222 suítes passam;
  - grupos, captura de tela, dicas e permissões: 66 + 137 testes passam.
- **A suíte inteira rodou uma vez localmente, por engano** (um filtro vazio). Deu 4.517 testes e 4 problemas, dois deles conhecidos. Um dos outros dois é o do `GroupNoLimitTests` acima. O outro não foi identificado, porque a saída foi cortada, e não se repetiu nas rodadas filtradas, que cobrem cerca de 4.000 dos 4.517 testes. O CI da `main`, que roda a suíte inteira, é quem confirma.
