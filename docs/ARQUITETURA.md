# Arquitetura

Para quem vai mexer no código do Orb. App nativo em SwiftUI, Swift 6 (`swift-tools-version: 6.0`, concorrência estrita),
macOS 14+, um pacote SwiftPM com um alvo executável (`Orb`, `Sources/Orb`) e um alvo de testes (`OrbAppTests`). Não há
dependências externas: SQLite, ImageIO, Vision, Network, CryptoKit e o resto vêm do sistema.

Documentos irmãos: [CONTEXTO.md](CONTEXTO.md) (janela, compactação, economia de tokens), [PERMISSOES.md](PERMISSOES.md),
[MEMORIA.md](MEMORIA.md), [ORBS.md](ORBS.md) (avatar e animação), [MOVIMENTO.md](MOVIMENTO.md) (especificação de movimento da
interface).

## Visão geral

```
Views (SwiftUI)
   │ leem só o objeto do Orb que mostram              ┌──────────────── Memory/  MemoryBank por Orb (actor)
   ▼                                                   │
AppModel (@MainActor @Observable)  ── BotSession por Orb ── TurnRequest ──► AgentEngine (actor)
   │   lista de Orbs, rotinas, provedores,    (turno, conversa,   TurnEvent ◄──  │  clientes (OpenAI · Responses · Anthropic)
   │   catálogos, ajustes, arquivos de dados   texto em stream)                  │  ferramentas (Engine/Tools) · MCP
   │                                                                             │  PermissionPolicy · ApprovalGate
   ├─ BotLive por Orb (estado que as telas leem)                                 └─ ClaudeCodeEngine (processo `claude -p`)
   ├─ Store (JSON em disco, filas próprias) · Keychain                              + OrbToolsMCPServer (o app como servidor MCP)
   └─ Orbs/ (avatar: Core Animation, OrbDriver)
```

Três ideias organizam o resto:

1. **Cada Orb é independente.** O que um Orb faz (turno, texto em stream, aprovações, fila de mensagens, memória, uso de
   tokens) vive em um `BotSession`; o que as telas mostram dele vive em um `BotLive`. Dois Orbs trabalham ao mesmo tempo sem
   se tocar, e uma mudança num não redesenha a tela do outro.
2. **Dois motores, um contrato.** O motor nativo (`AgentEngine`) e o do Claude Code (`ClaudeCodeEngine`) recebem uma
   requisição de turno e devolvem um `AsyncStream<TurnEvent>`. Permissões, aprovações, memória e prompt passam pelas mesmas peças.
3. **O disco é a fonte da verdade e nada o bloqueia.** Estado, conversas e memória são arquivos legíveis; leitura e
   escrita ficam fora da thread principal; arquivos ilegíveis nunca são sobrescritos.

## Mapa dos módulos

Tudo em `Sources/Orb/`.

### Aplicativo e estado

| Arquivo | Papel |
|---|---|
| `OrbApp.swift` | `Launcher` (`@main`: com `--tools-mcp` roda só o servidor MCP, sem janela), `OrbApp` (janela, Ajustes, barra de menus), `AppDelegate`, `AppCommands` (menu "Orbs"), `OrbSheet` (`--render-orbs`), `Snapshot` (`--snapshot`) |
| `AppIcon.swift` | o ícone do app (`--render-icon`): CoreGraphics puro, desenhado direto em cada tamanho na grade do macOS (ladrilho de 824 em 1024, sombra padrão), o Orb índigo da marca com o `GelShader` (port de `art/orbgen/Body.swift`, por pixel na CPU), rosto sem óculos e uma variante simples até 64 px |
| `AppModel.swift` | `@MainActor @Observable`: Orbs, rotinas, skills, conectores, provedores, modelo padrão, nível de contexto das conversas; criar/apagar Orb, `send`, `runClaudeCode`, `compactNow`, rotinas e fila, conexão de provedores, salvar |
| `AppModel+Approvals / +Commands / +ContextUI / +MemoryUI / +RoutinesUI / +Schedule / +Steering / +Transcript` | o que cada área pede ao modelo: `decide` e banners; comandos, paleta e barra de menus; dados do medidor; esquecer/desfazer; modelos de rotina e listas; a ferramenta `schedule` (o Orb cria, lista, pausa e apaga as próprias rotinas); fila "enquanto trabalha"; "Tentar de novo"/"Continuar" |
| `BotSession.swift`, `BotSession+Turn.swift`, `BotSession+Conversation.swift` | a maquinaria de um Orb: conversa em memória (carregar, descarregar, salvar, estacionar durante rotina), turno (id, eventos, texto em stream, cartões), uso de tokens, trechos para a memória |
| `BotLive.swift` | o que as telas leem de um Orb: configurações, `status`, `activity` (com "digitando" e a olhada ao ser escolhido), `needsYou`, não lidas, memória, medidor. `WritesOnlyChanges` (`assign`, `writeIfChanged`) |
| `WorkLine.swift` | o que o Orb diz que está fazendo: `WorkLine` (verbo, alvo, tom, rotina, ações), `WorkPhrase` (a frase de cada ferramenta e dos status dos motores), `WorkMeter` ("16 s · 3 ações", "em 8 s"), `StatusDwell` (tempo mínimo de 0,7 s por frase) e `WorkAnnouncer` (anúncios ao VoiceOver, no máximo um a cada 8 s). `BotLive.work` é a frase; `status` continua o texto cru dos motores |
| `LiveText.swift` | `ReplyParagraphs` (parágrafos incrementais), `LiveText` (a resposta que está chegando), `OrbTranscript` (os itens que a conversa mostra) |
| `Models.swift` | `Bot`, `PermissionMode`, `Capability`, `Conversation`, `TranscriptItem`, `ToolCall`, `ApprovalRequest`, `Routine`, `Schedule`, `Skill` |
| `Store.swift`, `StoreCoordination.swift`, `ConversationCoding.swift`, `ConversationHistory.swift` | `AppState`, `Store` (leitura/escrita com filas), `Keychain`, decodificação tolerante, `FileGate`, codificação incremental da conversa, arquivo de conversas, relatórios de rotina |
| `DevRun.swift` | os modos de desenho (`--snapshot`, `--render-*`): decide a pasta de dados (temporária, a menos que `ORB_DATA_DIR`) e bloqueia o Keychain e a migração neles; apaga a pasta temporária ao sair |
| `LegacyMigration.swift` | migração do app que se chamava OpenBot (dados e preferências; as chaves do Keychain são copiadas uma a uma quando usadas; as contas já copiadas, ou removidas no Orb, ficam anotadas em `UserDefaults` (`keychainAccountsFromOpenBot`) e o item do OpenBot, mantido como backup, não é mais consultado para elas) |
| `Reset/ResetPlan.swift`, `Reset/ResetExecutor.swift`, `Reset/AppRelaunch.swift`, `AppModel+Reset.swift` | "Redefinir o Orb": o plano puro (`ResetPlan`, `ResetSummary`, `ResetGuard`), o executor com pasta, cofre e preferências injetáveis, o relançar e a orquestração (`AppModel.resetEverything`). Veja "Redefinir o Orb" abaixo |
| `OrbFolder.swift` | pasta própria `~/Orbs/<Nome>`, estado da pasta, arquivos recentes e alterados do painel |
| `MacPermissions.swift` | permissões do macOS (TCC), pré-voo de Automação (abre escondido o app conhecido que está fechado), tradução de erros |
| `ImageAttachments.swift` | imagens do usuário e de ferramentas: reduzir (com `square:`, recorte quadrado central, para a foto do perfil), guardar em `anexos/`, formato de cada API |
| `UserProfile.swift`, `AppModel+Profile.swift` | o perfil global da usuária (nome, como te chamar, sobre você, foto) em `state.json` com decodificação tolerante; `promptSection` (o texto curto que entra pelo `pinned` da memória, vazio quando não há texto) e `ProfilePhoto` (a foto em `perfil/`; só lê arquivos do Mac, nunca um link; a última escolha ou remoção vence uma troca ainda em preparo, por `profilePhotoGeneration`) |
| `ApprovalNotifications.swift` | banners "Permitir / Não permitir", roteamento do toque, um só delegate de notificações |
| `ContextGauge.swift`, `MarkdownBlocks.swift`, `MenuBarSupport.swift`, `Shortcuts.swift`, `Motion.swift`, `Theme.swift` | palavras e leitura do medidor; blocos de Markdown; ícone da barra de menus e atalho global; nomes e teclas dos comandos e o catálogo de atalhos (folha, Ajustes e paleta leem a mesma lista); vocabulário de curvas; paleta, estilos e brilho |

### Motor (`Engine/`)

| Arquivo | Papel |
|---|---|
| `EngineTypes.swift` | contratos: `JSONValue`, `ChatMessage`, `LLMClient`/`LLMEvent`/`LLMError`, `TokenUsage`, `CacheHealth`, `AgentTool`, `ToolRisk`, `ToolContext`, `MCPServerConfig` |
| `AgentEngine.swift` | o laço do turno: modelo ↔ ferramentas, até 30 passos (60 em rotinas), retentativas, cortes por limite, grupos de aprovação, `TurnEvent`/`TurnRequest` |
| `Providers.swift` | `ProviderKind`, `ProviderAccount`, `ModelRef` (`provedor/modelo`), `ModelCatalog` (listas ao vivo), qual cliente para qual formato |
| `OpenAIClient.swift`, `ResponsesClient.swift`, `AnthropicClient.swift` | os três formatos (chat completions, Responses, Messages): corpo da requisição e mapeamento dos eventos |
| `ProviderTransport.swift`, `SSE.swift`, `Retry.swift`, `WireEncoder.swift` | o que os clientes dividem: requisição autorizada (renova 401), erros legíveis, `Retry-After`, leitor SSE incremental, retentativa com recuo, JSON ordenado |
| `ChatGPTAuth.swift` | login "Sign in with ChatGPT" (registro dinâmico, PKCE, retorno em 127.0.0.1), token no Keychain |
| `ContextBudget.swift`, `ContextWindow.swift`, `ContextCondensing.swift`, `ConversationLedger.swift`, `ContextMeter.swift`, `Compaction.swift`, `ToolDigest.swift`, `ToolOutputSpill.swift` | janela, compactação e medidor: veja [CONTEXTO.md](CONTEXTO.md) |
| `TurnPrompt.swift`, `SystemPrompt.swift`, `WorkspaceSnapshot.swift`, `WorkspaceChanges.swift`, `FolderInstructions.swift` | o prompt: sistema estável + prefácio por mensagem (`<orb_context>`: hora, pasta, memória); instruções da pasta (`ORB.md`/`AGENTS.md`/`CLAUDE.md`) |
| `PermissionPolicy.swift`, `ApprovalGate.swift`, `ApprovalBatch.swift`, `DangerousCommand.swift`, `ShellCommandLine.swift` | permissões: veja [PERMISSOES.md](PERMISSOES.md) |
| `Steering.swift` | a fila de mensagens enviadas durante um turno (`SteeringQueue`) |
| `ClaudeCode.swift`, `ClaudeCodeEngine.swift`, `ClaudeCodePrompt.swift`, `ClaudeCodeProtocol.swift` | provedor Claude Code: achar o `claude`, login/status, um processo `claude -p` por turno, protocolo `stream-json` e `can_use_tool`, prompt anexado e catch-up |
| `MCPConnection.swift`, `MCPTransport.swift`, `MCPTool.swift` | conectores MCP: stdio (com o ambiente do Terminal da usuária, de `ShellEnvironment`, para achar `npx`/`uvx` do `.zshrc`) e HTTP (Streamable HTTP com recuo para SSE). `MCPManager` só registra os conectores; o servidor sobe na primeira chamada (`ensureStarted`, uma subida compartilhada) e um ceifador (acorda a cada 60 s) desliga o que ficou 10 min sem uso e sem chamada pendente. `MCPTool` (`Servidor__ferramenta`) guarda o id do conector e chama o gerente |
| `ConnectorGateway.swift` | o porteiro dos conectores: `connector_tools` (índice dos conectores do Orb na descrição, lista as ferramentas e os argumentos) e `connector_call` (roda uma). Ficam fora de `ToolBox.all`; `AgentEngine.resolved` troca cada `connector_call` pela chamada do `MCPTool` de verdade antes da política de permissão |

### Ferramentas (`Engine/Tools/`)

`ToolBox.all` = `shellTools + fileTools + webTools + macTools + memoryTools + scheduleTools`; cada família lista as suas no próprio arquivo.
`ToolBox.offered(for:accessibilityGranted:)` filtra por capacidade do Orb e esconde `ui_read`/`ui_act` sem Acessibilidade.

| Capacidade | Ferramentas | Arquivos |
|---|---|---|
| Terminal e arquivos | `run_command` (`background: true`; saída acima de 20 KB é salva inteira em `saidas/<orb>/comando-….txt`), `job_output`, `job_list`, `job_stop`, `read_file` (texto, PDF, Word/RTF/ODT, Excel .xlsx, PowerPoint .pptx, imagens com OCR), `write_file`, `edit_file`, `list_directory`, `search_files` (Spotlight), `grep` (um arquivo informado em `path` vai até 200 MB, em streaming), `glob` (aceita padrão absoluto), `trash` (também com Controlar apps) | `ShellTool`, `BackgroundJobs`, `ProcessRunner`, `ShellEnvironment`, `FileTools`, `SearchTools`, `TextFile`, `DocumentReader`, `OfficeReader`, `ReadOnlyCommand` |
| Navegar na web | `web_fetch` (páginas, PDF, JSON, imagens; `offset`/`find` para páginas longas; `save_to`) | `WebTools`, `HTMLText` |
| Controlar apps do Mac | `applescript`, `shortcuts_list/run`, `clipboard_read/write`, `screenshot` (com OCR), `apps_list`, `processes`, `app_quit`, `trash`, `browser_tab`, `ui_read`, `ui_act` | `MacTools`, `MacAppTools`, `BrowserTools`, `ScreenshotTool`, `AccessibilityTools`/`Elements`/`Outline`, `AppleScriptSupport` |
| Sempre | `open`, `notify`, `remember`, `recall`, `schedule` | `MacTools`, `MacAppTools`, `ScheduleTool`, `ScheduleMailbox` |
| Conectores | `connector_tools`, `connector_call` (fora de `ToolBox.all`, montadas por turno) | `ConnectorGateway`, `MCPTool` |

**`schedule`.** Uma tarefa agendada **é** uma `Routine` do Orb (a mesma página, o mesmo agendador de 30 s, a mesma fila e o mesmo
relatório): a ferramenta só dá ao Orb o jeito de criá-la, listá-la, pausá-la, retomá-la e apagá-la. `ScheduleCommand` confere a
chamada (`daily`, `weekly`, `every_minutes` de 15 a 720, `every_hours` de 1 a 24; nome, prompt de até 4.000 caracteres); quem
executa é `AppModel.schedule(_:orb:)`, que só vê as rotinas do Orb que chamou, recusa o 21º, o nome repetido e a criação vinda
de dentro de uma rotina, e responde em português ("Agendei “X”: a cada 30 minutos. Próxima execução: …"), que é também o que o
chat mostra como resultado da ferramenta. No motor nativo a chamada chega por `ToolContext.schedule` (um fecho preso ao Orb); no
Claude Code, o servidor de ferramentas é **outro processo** e não alcança o modelo, então ele deixa `<id>.json` na pasta
`agendamentos/` do app e espera o `<id>.reply` (`ScheduleMailbox`: o app acorda com a pasta mudando, sem sondar, e responde com o
mesmo código; 20 s de limite; o app começa a ouvir no primeiro turno do Claude Code e limpa a pasta ao começar). O servidor
recebe a pasta e o Orb por `--schedule-mailbox <pasta> --orb <id>`. Uma execução que passa do próprio intervalo (a cada 15 min,
levando 20) conta a próxima a partir do fim dela (`finishRoutineRun`), então nada se acumula.

**`web_fetch`.** Lê HTTP(S) com o User-Agent do Safari (gzip/br, `Accept-Language: pt-BR`, 20 s de limite) e decodifica pelo BOM,
pelo cabeçalho, pelo `<meta charset>` e por UTF-8/Windows-1252. HTML (até 5 MB) vira um Markdown leve (`HTMLText`): só o
conteúdo principal (`<main>`, o único `<article>`, `role="main"` ou um id conhecido, desde que tenha ao menos 500
caracteres e 20% do texto; senão a página inteira), sem menus, rodapés, `<aside>`, elementos ocultos (`hidden`,
`aria-hidden`, `display:none`), landmarks ARIA e algumas classes da Wikipedia; títulos em `#`, código em cercas
com a indentação intacta, tabelas em linhas `| a | b |`, `alt` de imagens e links `texto (url)`, com os do mesmo site
só pelo caminho (`texto (/wiki/X)`) e o endereço do site no cabeçalho. Se o resultado ficar quase vazio e a página tiver
scripts, vem uma nota dizendo que ela precisa de JavaScript (com o texto do `<noscript>`). JSON, XML e texto vêm como
estão; PDF vira texto (até 25 MB) com marcador de página; imagem vira imagem quando o modelo enxerga (`runWithImages`).
A resposta é paginada (12 000 caracteres, até 24 000) cortando na última quebra de linha ou espaço, e a página convertida
fica 10 minutos em memória (`WebPageCache`, 8 páginas) para `offset` e `find` (trechos com o offset de cada um) não
baixarem de novo. `save_to` baixa até 100 MB num arquivo temporário e move no fim; recusa antes se o `Content-Length` já
passa do limite. Erros de rede e de HTTP voltam em português, com o endereço e uma dica. O `Info.plist` do app traz
`NSAllowsArbitraryLoads` para o macOS não bloquear `http://`.

**Sem ferramenta de busca.** Não há `web_search` nativo: raspar DuckDuckGo, Bing ou Google não é confiável (CAPTCHA, páginas de
bloqueio, links de rastreamento) nem respeita o `robots.txt`. O prompt manda o Orb usar a busca/API do próprio site
(`api.php` da Wikipedia, `api.github.com/search`, registros de pacotes, a documentação oficial). Com o Claude Code há o
`WebSearch` dele. A busca do provedor (ferramenta de servidor da Anthropic, `web_search` da OpenAI) ou uma chave Brave
opcional seriam o caminho se isso virar requisito.

Os nomes e as descrições das ferramentas para o modelo são em inglês; o que aparece para você (título e detalhe de cada
linha, cartões) é em português (`AgentTool.summary`).

### Memória (`Memory/`)

`MemoryBank` (um actor por Orb) + `MemoryIndex` (SQLite/FTS5) + `MemoryPage`/`MemoryText`/`MemorySanitizer` +
`SessionSummary` + `MemoryIntent` + `KeptMemories` (memórias guardadas e o perfil de cada uma) + `OrbToolsMCPServer`.
Detalhes em [MEMORIA.md](MEMORIA.md).

### Catálogos (`Catalog/`)

`MCPRegistry` (registro oficial do MCP), `ConnectorTemplates` (conectores em destaque), `ConnectorCatalog` (o que cada conector ofereceu
da última vez, em `conectores/<id>.json`: serve ao índice, à resolução das chamadas, às anotações do Claude Code, à contagem do cartão e
a "Ver ferramentas"), `SkillCatalog` (Skills.sh + GitHub),
`ConnectorSecrets` (segredos de conectores no Keychain, `@keychain` no `state.json`), `OrbScope` (conectores e skills por
Orb: "Usar com").

### Orbs (`Orbs/`)

O avatar e seu sistema de animação: `OrbModel` (config, catálogo, imagens), `OrbActivity`, `OrbAnimationView` + `OrbDriver`
(Core Animation, um display link por tela), `OrbMotion`, `OrbTemperament`, `OrbSpeech`, `OrbView`, `OrbEditor`. Veja [ORBS.md](ORBS.md).

### Telas (`Views/`)

| Área | Arquivos |
|---|---|
| Janela | `RootView` (`NavigationSplitView`, painel que se recolhe em janela estreita), `SidebarView`, `ChatView` (lista da conversa), `EmptyChatContent` (e `OrbGreeting`, a saudação de um Orb novo), `FirstRunCard`, `WelcomeView` (a tela sem Orbs: `WelcomeStage`, `WelcomeCopy`, `WelcomeLooks`, `WelcomeSelection`, `WelcomeLedger`, `WelcomeBackdrop`, `KeptStartCard`; o que ela pede ao modelo está em `AppModel+Welcome.swift`) |
| Conversa | `TranscriptViews` (`TranscriptRow` Equatable, ferramentas, `ApprovalCard`, `WorkingLine`), `MarkdownBlockViews`, `QueuedMessages`, `ImageThumbnails`, `ApprovalKeyboard` |
| Compositor | `ComposerView`, `ComposerChips` (permissões, skills, modelo), `ComposerSupport`, `ModelPopover`, `ModelPicker`, `ContextMeterViews` |
| Painel do Orb | `BotInspector` (abas Geral, Memória, Pasta e acessos, Rotinas), `InspectorSupport`, `MemoryViews`, `DeleteOrbDialog`, `PermissionConfirmation` |
| Ajustes | `SettingsView` (Geral, Modelos, Permissões do Mac), `ProfileSettings` (a seção "Você" e `ProfileAvatar`, que a barra lateral também usa), `ResetOrbSheet` ("Redefinir o Orb?" e o alerta), `ProviderSettings`, `ProviderPresentation`, `CustomProviderFields`, `ClaudeCodeSettings`, `MacPermissionsView`, `ContextSettings` |
| Páginas | `RoutinesView`, `ConversationsMenu`, `SkillsView`, `ConnectorsView`, `CatalogParts` |
| Sistema | `CommandPalette` (⌘K e a folha de atalhos; as teclas vêm de `ShortcutCatalog`, em `Shortcuts.swift`, a mesma lista que Ajustes → Geral mostra), `QuickAskView` (painel da barra de menus), `SheetKit` |
| Para revisão (só `--snapshot`) | `WelcomeSnapshots`, `CatalogSnapshots`, `ContextSnapshots`, `SystemSnapshots`, `TranscriptSamples`, e `SnapshotComposerScenes.swift` (na raiz de `Sources/Orb/`) |

## O caminho de um turno

```
ComposerView ── AppModel.submit ─┬─ Orb livre ─► AppModel.send ─┬─ Claude Code ─► runClaudeCode ──► ClaudeCodeEngine.run
                                 └─ Orb trabalhando ─► fila     └─ nativo ───────► AgentEngine.run
                                    (ComposerLane / SteeringQueue)                          │
                                                                       AsyncStream<TurnEvent>│
                                                                                             ▼
                           BotSession.play ─► apply(evento) ─► conversa (itens + mensagens), BotLive, LiveText ─► telas
```

1. **Envio.** `ComposerView.send` chama `AppModel.submit`. Com o Orb trabalhando na sua conversa, a mensagem entra numa fila
   (`ComposerLane.enqueue`) e aparece como "Na fila"; senão vai para `AppModel.send`. Uma rotina trabalhando bloqueia o envio
   (o compositor avisa).
2. **`AppModel.send`** valida (texto, turno em andamento, provedor pronto; sem provedor, `setupNudge` faz o cartão de primeiro
   uso pulsar e o texto fica no compositor), trata `/compactar`, grava a mensagem do usuário na conversa, limpa o rascunho,
   põe o status "Pensando" e a "agitação" do Orb (`poke`, `isListening`), detecta pedido de memória (`MemoryIntent`), expande
   `/skill`, acrescenta os caminhos dos anexos e a nota das imagens e, numa rotina, o aviso de que ninguém está presente.
3. **Histórico.** `Conversation.prepareHistory(budget:reserving:)` corta e condensa se passou do orçamento (um aviso
   na conversa e a memória gravada antes de esquecer). O turno ganha um id (`beginTurn`).
4. **Montagem (em `Task`, fora da thread principal quando custa).** `MemoryBank.brief` (memória), `TurnPromptInputs.gather`
   (snapshot da pasta, em cache de 60 s, e instruções da pasta), `TurnPrompt.native` (prompt do sistema estável + prefácio
   por mensagem), o cliente (`ProviderAccount.client` pelo formato do modelo), as ferramentas (`ToolBox.offered` + as dos
   conectores permitidos) e o `TurnRequest` (`Sendable`). Se o turno foi parado nesse meio-tempo (`isCurrent`), nada segue.
5. **Laço** (`AgentEngine.play`, até 30 passos): entrega mensagens da fila; ajusta a janela (`ContextWindow.fit` com o
   `ContextCut` do turno); chama o modelo com até 4 tentativas e recuo (`withRetries`, status "Provedor ocupado", "Limite do provedor" ou
   "Conexão caiu, tentando de novo em N s", conforme o erro); trata o motivo de parada (recusa, resposta cortada, estouro de contexto); roda as chamadas
   (`runCalls`: um cartão para o que pergunta junto, leituras em paralelo, o resto em ordem); registra cada mensagem. O
   Claude Code faz o análogo num processo `claude -p`, com os pedidos `can_use_tool` vindo para o mesmo `ApprovalGate`.
6. **Eventos.** `TurnEvent`: `status`, `text`, `toolStarted`/`toolFinished`, `approval`, `message` (vai para o histórico do
   modelo), `notice`, `failed`, `usage`/`requestUsage`, `compacted`, `taskPaused`, `steered`, `session`.
7. **Aplicação** (`BotSession.apply`, na thread principal): o texto vai para `pendingText` e é publicado em `LiveText` a cada
   33 ms, **sem tocar na lista de itens**; ferramentas e cartões viram itens da conversa; `message` entra em
   `Conversation.messages`; o `BotLive` recebe status, ferramenta em uso, "falando" e "esperando você", e a frase da linha de trabalho (`work`,
   uma por passo, nunca por token, cada uma por ao menos 0,7 s).
8. **Fim** (`finishTurn`): zera status; agenda a página de sessão da memória (30 min depois); fecha a execução da rotina;
   notifica (se o app está em segundo plano) e conta não lidas; o Orb comemora (`happy`) ou erra (`error`); entrega a fila que
   ficou; grava a conversa de uma vez; começa a próxima rotina que esperava por este Orb.

## Persistência

Pasta de dados: `~/Library/Application Support/Orb/` (a variável `ORB_DATA_DIR` troca).

```
state.json                       AppState: Orbs, rotinas, skills, conectores (segredos viram "@keychain"), provedores,
                                 modelo padrão, não lidas, nível de contexto das conversas, janelas aprendidas
conversations/<Orb>.json         conversa atual: itens da tela + mensagens do modelo + resumo/ledger + marcas
conversations/<Orb>.meta.json    nota ao lado: quantos itens, quantos já foram para a memória, impressão digital do arquivo
conversations/<Orb>/<id>.json    conversas anteriores ("Nova conversa"), com index.json (cache corrigido pelos arquivos)
conversations/<Orb>/routine-<rotina>.json   a conversa de cada rotina
conectores/<id>.json             catálogo do conector (`ConnectorCatalog`): o que o servidor ofereceu da última vez, sem segredos
memoria/<Orb>/…                  a memória (páginas .md + index.sqlite); memoria/_guardadas/<nome> – <data>/ de Orbs apagados ou
                                 redefinidos, com perfil.json (nome, papel e aparência) ao lado das páginas
anexos/<Orb>/<uuid>.jpg|png      imagens reduzidas (a conversa guarda o caminho); saem com o Orb ou com a conversa anterior que só elas usava (as cópias `.corrupt-…` também contam como uso)
perfil/foto-<8 hex>.jpg|png      a foto da usuária (quadrada, até 256 px; nome novo a cada troca, a antiga é apagada); nunca vai a provedor nem a ferramenta; o Redefinir apaga a pasta
saidas/<Orb>/*.txt               saídas grandes de ferramentas; limpas por idade (14 dias) e tamanho (200 MB)
agendamentos/                    a caixa de correio do `schedule` no Claude Code (`<id>.json` pedido, `<id>.reply` resposta); vazia
                                 fora de uma chamada, e limpa quando o app começa a ouvir
*.corrupt-<aaaammdd-hhmmss>      cópia de um arquivo que não pôde ser lido (nunca sobrescrito)
.migrado-do-openbot              marca de que a migração do OpenBot já foi feita
```

Fora dela: o **Keychain** (serviço `app.orb.mac`; uma conta por provedor com chave, `chatgpt` com o JSON do login e
`mcp.<id do conector>.<NOME>` para segredos de conectores), as **preferências** (`UserDefaults`: `notifyWhenDone`,
`quickAskGlobalShortcut`, `keychainAccountsFromOpenBot`, aba de Ajustes e do painel de cada Orb, modelos recentes…) e a **pasta de cada Orb**
(`~/Orbs/<Nome>/`, com `Rotinas/<nome>/…md`), que o app não apaga ao apagar o Orb. Há ainda um arquivo temporário por turno do
Claude Code, `$TMPDIR/orb-mcp-p<pid>-<uuid>.json` (0600), com a configuração dos conectores já com os segredos: o fim do turno o apaga, e
na abertura o app apaga os que sobraram de uma saída no meio do turno (`ClaudeCodeEngine.removeStaleMCPConfigs`): os que levam o
`pid` de um processo que não existe mais, e os de versões antigas (sem `pid`) parados há mais de 2 minutos. O `$TMPDIR` é o mesmo
do app real, então os modos de desenvolvedor (`--snapshot`…) não fazem essa limpeza.

### Redefinir o Orb

Ajustes → Geral → Seus dados → "Redefinir o Orb…" leva o app ao primeiro uso. A ordem importa, porque o app continua rodando
até o fim:

1. **Recusa** (`ResetGuard.refusal`): nos modos de desenvolvedor (`--snapshot`, `--render-*`); numa pasta que não pode ser a
   de dados (a raiz, a pasta pessoal ou uma que a contenha); e, quando a pasta não é a padrão (`~/Library/Application Support/Orb`,
   por exemplo `ORB_DATA_DIR`), se ela for, ficar dentro de ou conter `~/Orbs` ou a pasta de algum Orb (arquivos dos Orbs
   nunca são apagados) ou se não tiver `state.json` (não parece dados do Orb: `~/Documents`, um disco externo). Nada é tocado.
2. **Sela o estado** (`isResetting`, `Store.sealWrites`): `scheduleStateSave` e `saveNow` (que o término do app chama) não fazem
   nada, o `Store` descarta tudo o que já estava na fila e tudo o que vier (`WriteSeals`, em `enqueue` e `writeFile`). Nenhuma
   gravação atrasada, nem a do término, regrava o estado antigo depois da limpeza. Com `isResetting` a janela, o painel da
   barra de menus e Ajustes ficam cobertos (`resetShield`) e o modelo recusa `send`, rotinas e adotar uma memória guardada.
3. **Para tudo** (`AppModel.stopForReset`): agendador, turnos de todos os Orbs (cancelar o turno termina o processo do Claude
   Code), rotinas e a fila delas, cartões de aprovação e banners, conectores (MCP). Espera os turnos acabarem, no máximo 3 s.
4. **Guarda o último trecho** (`saveLastStretches`, só em "Guardar as memórias"): a conversa depois da última página de sessão de
   cada Orb vira página em `sessoes/`, como em `deleteBot(keepMemory:)`, e a espera termina (no máximo 5 s) **antes** de
   `MemoryLibrary.seal`, que fecha os bancos para que nenhuma tarefa atrasada recrie uma pasta depois de movida.
5. **Limpa fora da thread principal** (`ResetExecutor.run`, em `Task.detached`): `store.flush()` (o que estava sendo gravado
   termina), `BackgroundJobs.killAllNow()`, e então, na ordem: move a memória de cada Orb para `_guardadas` com o perfil (ou, em
   "Apagar tudo", remove `memoria/` inteira); remove **só o que o app grava** na pasta de dados (`ResetGuard.removes(entry:)`:
   `state.json` e suas cópias `state.json.…`, `conversations/`, `memoria/`, `anexos/`, `saidas/`, `perfil/`; qualquer outro arquivo, como
   `.migrado-do-openbot`, fica); apaga os segredos pelo cofre injetável (`SecretVault.remove` = `Keychain.set("")`, o mesmo
   caminho público de apagar chave: conectores e, com "Também sair dos provedores", uma conta por provedor mais `chatgpt`;
   nunca o Claude Code); devolve as preferências ao padrão (`UserDefaults` do próprio app, menos `LegacyKeychainLedger.key`);
   grava um `state.json` novo só com os provedores, o modelo padrão e as janelas aprendidas quando eles ficam; e, se a pasta do
   OpenBot ainda tem dados e o marcador faltava, cria o marcador. Cada passo continua se outro falhou; o relatório
   (`ResetReport`) diz o que sobrou.
6. **Fecha e reabre** (`AppRelaunch.finish`): um `sh` espera o processo acabar (até 20 s) e roda `open` no `.app` (sem `-n`; se o
   processo não acabou, não abre nada); fora de um `.app` (SwiftPM) só fecha.

**Por que o OpenBot não volta.** O Keychain do OpenBot (`app.openbot.mac`) é só backup: `Keychain.lookup` copia uma conta dele
na primeira leitura e anota a conta em `LegacyKeychainLedger` (`keychainAccountsFromOpenBot`, nas preferências); depois disso o
item antigo não é mais consultado. Apagar uma chave pelo `Keychain.write` já anota a conta, então a redefinição só precisa
(a) apagar pelo caminho público e (b) deixar essa chave das preferências em paz (`ResetGuard.keepsPreference`, a mesma
constante). Sem isso, "Também sair dos provedores" seria desfeito na reabertura, que copiaria as chaves do OpenBot de volta.
Os testes usam um Keychain de mentira com os itens do OpenBot.

O alerta de confirmação é um `NSAlert` (`ResetConfirmation`): Esc aperta "Cancelar", Return não aperta nada e o botão
destrutivo não tem tecla. Nos testes, `AppModel.resetEnvironment` (argumentos, preferências, pasta do OpenBot, o último passo)
é "inerte" quando o modelo não é o app (`runsBackgroundWork: false`), então um teste nunca toca nas preferências reais.

### Decodificação tolerante

Campo novo precisa de valor padrão: `container.value(_:default:)`, listas com `lossyArray` (um item ilegível é pulado, não
derruba a lista) e enums de texto com `Decoder.rawValue(_:fallback:)`. O que se perdeu vira aviso: `DecodeLoss` conta os itens
pulados e o `Store` guarda uma cópia do original (`.corrupt-…`) antes de regravar. Um arquivo que não decodifica é **movido**
para essa cópia (nunca fica no caminho de uma escrita); se nem isso dá, o `FileGate` bloqueia as gravações naquele arquivo até
o app abrir de novo. Falha ao gravar avisa uma vez. Os avisos aparecem no alerta "Atenção com seus dados"
(`AppModel.dataNotices`), que trocam o nome do arquivo pelo que ele guarda ("a conversa de Lia", "os ajustes do app";
`StoreNotice.file` + `AppModel.described`); falha ao gravar o `.meta.json` não avisa (ele se refaz da conversa). Enums de
texto de versões novas (`OrbTemperament`, `APIFormat`, modo de permissão…) caem no padrão em vez de derrubar o Orb; um
modelo de provedor com formato desconhecido sai da lista. A gravação incremental da conversa mantém o formato do arquivo, legível por versões anteriores.

### Filas e gravação

- Gravações: **uma fila serial por pasta de dados** (`WriterQueues`), em ordem, fora da thread principal. O estado é salvo
  400 ms depois da última mudança (`scheduleStateSave`); uma conversa, no máximo a cada 5 s enquanto uma resposta chega (um
  pouco mais em conversas longas) e na hora ao fim do turno; ao sair, só o que mudou (`saveNow`).
- Leituras: fila concorrente própria, coordenada por arquivo (`FileGate`): uma leitura espera as gravações *daquele* arquivo
  (nunca vê um arquivo pela metade nem uma versão velha) e não espera as dos outros.
- Gravação incremental: `ConversationEncoder` reaproveita o JSON dos itens que não mudaram desde a última gravação do
  arquivo (cache por arquivo, no máximo 4 arquivos e 48 MB) e não grava quando nada mudou. Ao gravar, saídas antigas de
  ferramentas (anteriores à penúltima mensagem do usuário) ficam com começo e fim (~4 000 caracteres).
- Só a conversa do Orb aberto é lida na abertura (`beginLoading`, com marcador de carregamento); as outras, ao trocar de Orb ou
  quando algo precisa delas (`ensureLoaded`, na thread principal, só quando não dá para esperar). Reabrir uma conversa
  arquivada (`reopenConversation`) e começar uma rotina (a leitura da conversa dela, `startRoutine`) também leem fora da thread
  principal e conferem depois que o Orb, a rotina e a conversa ainda existem e que nenhum turno começou. Uma conversa parada há mais
  de 5 min, sem nada para gravar, volta ao disco (`unloadIdleConversations`, a cada 30 s), o que a nota `.meta.json` ao lado
  permite verificar sem reler.

## Concorrência

| O que | Onde roda |
|---|---|
| `AppModel`, `BotSession`, `BotLive`, `LiveText`, `OrbTranscript`, `ComposerLane`, `ConnectorSecrets`, as telas | `@MainActor` |
| `AgentEngine`, `ClaudeCodeEngine`, `ApprovalGate`, `MCPManager`/`MCPConnection`/transportes, `ChatGPTAuth`, `ClaudeCode`, `WorkspaceSnapshots`, `BackgroundJobs`, `ShellEnvironment`, `SkillCatalog` | `actor` |
| `MemoryBank` | um `actor` por Orb: todas as escritas daquele Orb em fila; `MemoryLibrary` (sem estado mutável fora do lock) guarda os bancos |
| Disco, Keychain, SQLite, decodificação de imagens, leitura de pasta e git | fila do `Store`, tarefas desprendidas (`Task.detached`), `DispatchQueue` próprias, `runDetached` (cancelável) para `grep`/`glob`/documentos, `Blocking.run` para chamadas bloqueantes do TCC |

- Os valores que atravessam fronteiras são `Sendable` e imutáveis: `TurnRequest` captura tudo de que o turno precisa
  (inclusive `PermissionSource`, uma closure que lê o modo e as liberações **no momento** de cada chamada), e o turno não lê
  estado da interface.
- Um turno tem um **id** (`BotSession.turnID`). Um turno parado ainda pode estar terminando a montagem ou escoando eventos
  enquanto o próximo roda: só o turno atual (`isCurrent`) muda o estado do Orb.
- Parar (`BotSession.stop`) cancela a `Task` do turno, nega os cartões abertos, fecha a resposta, acrescenta "Você
  interrompeu esta resposta" e encerra o turno. Os motores respeitam `Task.isCancelled` (e o processo do Claude Code recebe
  `interrupt`, fecha a entrada e é terminado se não sair).
- Em rotina, a conversa da rotina assume o lugar da conversa do chat (que fica "estacionada" em `parkedChat`) enquanto ela
  roda: um Orb faz uma coisa por vez, e a rotina espera (fila de uma por rotina) se o Orb está ocupado.
- As poucas exceções à isolação (`nonisolated(unsafe)` em caches `NSCache` e tabelas de filas) estão marcadas e guardadas por
  lock ou por serem seguras por construção.

## Princípios de desempenho

Estes princípios nasceram de medições (a mais conhecida: a CPU durante uma resposta longa caiu de ~96% para ~20%; veja o
histórico do repositório, `git log --grep "streaming"`, e as seções de desempenho de [ORBS.md](ORBS.md)).

| Princípio | Como é feito | Por quê |
|---|---|---|
| **Observação por Orb** | `BotLive`, `BotSession`, `OrbTranscript` e `LiveText` são `@Observable` separados; as telas recebem o **id** (ou um `BotLook` pequeno e `Equatable`), nunca o `Bot` inteiro; `botIDs` só muda ao criar, apagar ou reordenar | Um evento de outro Orb não pode redesenhar a barra lateral, o compositor nem o painel |
| **Escrever só se mudou** | `assign` / `writeIfChanged` (`WritesOnlyChanges`) comparam antes de escrever | Escrever numa propriedade `@Observable` avisa os leitores mesmo sem mudança (e em coleções, até em `+=`) |
| **Streaming de custo constante** | O texto chega em `pendingText`, é publicado a cada 33 ms em um `LiveText` fora da lista de itens; `ReplyParagraphs` divide por linhas em branco de forma incremental (offsets em bytes UTF-8, sem reler); só o último parágrafo é interpretado e medido; os fechados mantêm identidade e cache | O custo de um flush não pode crescer com o tamanho da resposta nem da conversa. Um bloco de código longo (mais de 40 linhas) em stream é desenhado em pedaços fechados de 40 linhas (`CodeLines`, `Equatable`) e só o último muda; sem streaming é um `Text` único |
| **Linhas `Equatable`** | `TranscriptRow` com `.equatable()`, `SidebarBotRow`, cartões recebem ids; `LazyVStack` | Só a linha que mudou é refeita |
| **Nada de trabalho no `body`** | Filtros, buscas e agrupamentos ficam em `.task`/estado (`FoldedTextCache`, `ModelListing`, `ConversationListing`); o medidor de contexto é medido fora da thread principal com debounce (`ContextGaugeDriver`) | O `body` roda com frequência e na thread principal |
| **Rolagem barata** | macOS 15: `defaultScrollAnchor` mantém o fim; macOS 14: `scrollTo` com no máximo um a cada 200 ms; segue só enquanto você não rolou para cima | Um `scrollTo` por flush custa o tamanho da conversa |
| **Trocar de Orb recria o `ChatView`** | Prender o `.id` só à lista foi medido e ficou ~7× pior em conversas longas | Comentário em `RootView` |
| **E/S fora da thread principal** | Veja "Filas e gravação" | Abrir um Orb não pode esperar disco |
| **Animação** | Core Animation, um link por tela, taxa guiada pelo movimento, pausa quando ninguém vê, imagens decodificadas em segundo plano | Veja [ORBS.md](ORBS.md) |
| **Prefixo estável** | Requisições determinísticas, prompt sem data, prefácio por diferença | Cache de prompt do provedor; veja [CONTEXTO.md](CONTEXTO.md) |

Reduzir movimento (`accessibilityReduceMotion`) é respeitado onde há movimento (`animateChanges`, transições, cartões e
linhas de ferramenta, brilho, Orbs): sem translação, escala nem pulso; o Orb fica estático e o brilho vira texto fixo.

## Testes

```bash
swift test                                   # a suíte inteira, em paralelo
swift test --filter ContextWindowTests       # um arquivo/suíte
ORB_LIVE_TESTS=1 swift test --filter LiveCatalogTests      # catálogos reais (internet)
ORB_LIVE_TESTS=1 swift test --filter ClaudeCodeLiveTests   # o `claude` real, deslogado (flags, handshake, modelos)
```

São mais de 2.000 testes em `Tests/OrbAppTests`, em Swift Testing (`@Test`, `@Suite`, `#expect`, `#require`).

- **Determinismo.** Nada de dormir um tempo fixo para "dar tempo": `waitUntil(_:timeout:poll:_:)` (em `TestSupport/Waiting.swift`)
  espera uma **condição** (com limite generoso e `Issue` descritiva se estourar). Para afirmações negativas, espere primeiro
  um sinal positivo de que o sistema assentou. Os testes do modelo chamam `flushText` direto em vez de esperar os 33 ms.
- **Isolamento.** Cada suíte usa pastas temporárias próprias (`Store(directory:)` tem a sua fila de escrita), e
  `AppModel(store:runsBackgroundWork: false, asyncLoading:, secretVault:)` (e `devRun: true`, que também pula os conectores) não inicia agendador, Keychain nem observadores
  do app (o cofre de segredos é um `MemoryVault`). `QuietNotifications.hold()` impede banners do processo de teste.
- **Modelo falso.** Os testes injetam um `LLMClient` próprio: `AppModel.clientOverride`, ou um `ScriptedLLM`/`RecordingLLM`
  passado direto ao `AgentEngine.run`. Cada arquivo define o seu, pequeno (respostas roteirizadas, portas que só abrem quando
  o teste manda, gravação das requisições). O Claude Code é testado com um `claude` falso, um script que o
  próprio teste grava (`ORB_CLAUDE_PATH` faz o app usar outro executável).
- **Fixtures sem binários**: PDFs e PNGs são desenhados na hora (`Fixtures`), e o AX (Acessibilidade) é uma árvore falsa
  injetável (`AccessibilitySystem`).
- **Contratos de fio**: `ProviderWireGoldenTests` fixa a requisição e os eventos de cada formato.

### Modelo falso para uso manual

`scripts/fake-llm.py [porta] [--long]` serve uma API compatível com OpenAI em `http://127.0.0.1:8765/v1`: cada mensagem
recebe um texto curto, uma chamada `run_command` (para ver o cartão de aprovação) e, depois do resultado, uma resposta final
(`--long`: ~2 000 palavras de Markdown, uma a cada 15 ms, para medir o streaming). Para usar: abra o app com dados isolados e
aponte um provedor "Gateway próprio" para a URL.

```bash
python3 scripts/fake-llm.py 8765 --long
open -n build/Orb.app --env ORB_DATA_DIR=/tmp/orb-teste --env ORB_SEND="Como está meu Mac?"
# Ajustes → Modelos → Adicionar provedor → Gateway próprio → http://127.0.0.1:8765/v1 → modelo fake-model
```

## Ferramentas de desenvolvimento

### Argumentos

| Argumento | Efeito |
|---|---|
| `--tools-mcp <memória> [--mac] [--folder <pasta>] [--accessibility\|--no-accessibility] [--schedule-mailbox <pasta> --orb <id>]` | roda só o servidor MCP de ferramentas do Orb para o Claude Code (`--memory-mcp` ainda vale); sem janela |
| `--snapshot <modo> <arquivo.png>` | desenha uma tela fora da vista e sai (abaixo) |
| `--render-orbs <arquivo.png>` | folha de Orbs × atividades (`docs/orbs-activities.png`) |
| `--render-icon <arquivo.png> [pixels]` | o ícone do app, desenhado no tamanho pedido (padrão 1024; `scripts/bundle.sh` chama um por tamanho do iconset) |

Os três modos de desenho (`--snapshot`, `--render-orbs`, `--render-icon`) usam uma pasta de dados temporária nova, nunca a sua
(`DevRun.dataFolder`), a menos que você defina `ORB_DATA_DIR` de propósito. Neles o Keychain não é lido, gravado nem migrado do
OpenBot, e a migração de dados do OpenBot não roda. Também não há trabalho de fundo com efeito fora do processo, mesmo com
`ORB_DATA_DIR` apontando para uma cópia de dados reais: nada de agendador de rotinas, servidores dos conectores (MCP) nem
verificação do Claude Code (`AppModel(devRun:)`); `ORB_SEND` continua funcionando. A pasta temporária é apagada ao terminar.

### Variáveis de ambiente

| Variável | Efeito |
|---|---|
| `ORB_DATA_DIR` | pasta de dados alternativa (use sempre que testar). Nos modos `--snapshot`/`--render-*`, sem ela vale uma pasta temporária nova |
| `ORB_SEND="texto"` | envia o texto ao Orb selecionado ao abrir (ponta a ponta) |
| `ORB_STATIC=1` | desliga a animação dos Orbs |
| `ORB_ANIMATE_INACTIVE=1` | Orbs e brilho animam mesmo com a janela inativa ou coberta (medir CPU sem trazer o app para a frente) |
| `ORB_MEMORY_IDLE=<segundos>` | tempo de pausa até a conversa virar página de sessão (padrão 1 800) |
| `ORB_CLAUDE_PATH=/caminho/claude` | outro executável como Claude Code (um falso, nos testes) |
| `ORB_DEBUG_USAGE=1` | uma linha por chamada ao modelo no stderr: tokens, cache lido/escrito |
| `ORB_SNAPSHOT_WIDTH` / `ORB_SNAPSHOT_HEIGHT` / `ORB_SNAPSHOT_WAIT` | tamanho (1100×760) e espera em segundos (8) de `--snapshot` |
| `ORB_LIVE_TESTS=1` | liga as suítes que usam a rede ou o `claude` real |
| `ORB_SIGN_IDENTITY="Nome"` | (em `scripts/bundle.sh`) assina com outra identidade |

### `--snapshot`

Renderiza a tela com dados de exemplo numa janela fora da tela, sem tirar o foco
(`NSApp.setActivationPolicy(.accessory)`), e grava o PNG. Os Orbs saem estáticos (o Core Animation não é capturado). Os dados
vêm de uma pasta temporária nova (os Orbs iniciais) ou, se você definir `ORB_DATA_DIR`, dessa pasta. O Keychain não é tocado.

> O modo `conversations` grava seis conversas de exemplo (`RoutinesSnapshots.seedArchive` usa `Store.standard`): por isso o
> `--snapshot` nunca usa a sua pasta real. Só escreve em `ORB_DATA_DIR` se você o definir (aponte para uma pasta de teste).

Modos (qualquer outro nome mostra o chat do primeiro Orb):

| Área | Modos |
|---|---|
| Janela e painéis | `app`, `sidebar`, `sidebar-profile` (com o perfil de exemplo), `inspector` (= `inspector-general`), `inspector-memory`, `inspector-folder`, `inspector-routines`, `memory-sheet`, `new-orb`, `new-orb-kept` (com memórias guardadas, uma escolhida), `welcome` (sem modelo), `welcome-checking` (conexões ainda não verificadas), `welcome-ready`, `welcome-kept` (com duas memórias guardadas), `welcome-returning` (lista esvaziada), `welcome-narrow` (a pronta; use `ORB_SNAPSHOT_WIDTH=1000 ORB_SNAPSHOT_HEIGHT=620`) — todas com `ORB_DATA_DIR` numa pasta com `{"bots":[]}`, senão o modo de desenvolvedor cria o Atlas —, `editor`, `delete-orb`, `palette`, `shortcuts`, `menubar-icons` |
| Conversa | `chat-working`, `chat-working-wait`, `chat-working-retry`, `chat-typed`, `chat-attachments`, `chat-slash`, `popover-permissions`, `popover-model`, `popover-skills`, `approvals`, `transcript`, `transcript-approvals`, `transcript-notices`, `transcript-failed`, `transcript-retry` |
| Contexto | `context-meter`, `context-nudge`, `context-popover`, `context-popover-result`, `context-popover-short`, `context-popover-claude`, `settings-context` |
| Ajustes | `settings-general`, `settings-profile` (Geral com um perfil de exemplo e foto desenhada na hora), `settings-reset` (a folha "Redefinir o Orb?"), `settings-models`, `settings-perms`, `first-run-banner`, `models` |
| Barra de menus | `quickask`, `quickask-approvals`, `quickask-reply` |
| Rotinas e conversas | `routines`, `routine-editor`, `routine-editor-new`, `routine-run`, `routine-run-failed`, `routine-conversation`, `conversations` |
| Skills e conectores | `skills`, `skills-explore`, `skill-editor`, `skill-editor-new`, `skill-preview`, `skill-preview-installed`, `connectors`, `connectors-explore`, `connectors-lazy`, `conn-tools`, `conn-editor-github`, `conn-editor-files`, `conn-editor-slack`, `conn-editor-manual`, `conn-editor-edit`, `conn-editor-edit-registry`, `conn-editor-connecting`, `conn-editor-connected`, `conn-editor-failed` |

Com `ORB_SEND`, o snapshot envia o prompt e espera `ORB_SNAPSHOT_WAIT` segundos antes de fotografar. Para medir o streaming sem
abrir janela, use o modelo falso com `--long`, `ORB_SEND` e `ORB_SNAPSHOT_WAIT=40` e observe o processo (`ps -o %cpu=`,
`sample`).

### Scripts

| Script | O que faz |
|---|---|
| `scripts/bundle.sh [debug\|release]` | compila (padrão `release`), monta `build/Orb.app` (executável, `Resources/Orbs`, `Info.plist` com `app.orb.mac` e `NSAllowsArbitraryLoads` (sem isso o macOS bloqueia `http://` no app empacotado), ícone gerado pelo próprio app) e assina |
| `scripts/make-signing-identity.sh` | cria uma vez o certificado local "Orb Local" no chaveiro de login e o marca como confiável para assinar |
| `scripts/fake-llm.py` | o modelo falso acima |

A arte (camadas dos Orbs) tem o seu próprio gerador, descrito em [art/README.md](../art/README.md).

## Como estender

- **Nova ferramenta.** Um `struct` que implementa `AgentTool` (`spec`, `kind`, `capability`, `risk`, `summary`, `run`; `danger`
  se alguma chamada é destrutiva), na lista da família em `ToolBox` (`fileTools`, `shellTools`…). Decida a **família de
  permissão** em `PermissionPolicy.family(ofTool:kind:)` (sem isso ela cai pelo `kind`) e o `legacyRule` se precisar. Se o
  Claude Code deve ter a ferramenta, ela entra em `ToolBox.macTools`, `memoryTools` ou `scheduleTools` (o que `OrbToolsMCPServer` serve); uma que muda o estado do app precisa de um jeito de chegar até ele (veja `schedule`). Texto
  da ferramenta para o modelo em inglês, curto (cada palavra é cobrada em toda requisição); título e detalhe para o usuário em português.
- **Novo provedor.** Um `case` em `ProviderKind` com `label`, `summary`, `defaultBaseURL`, `keyPage`, `shortName`, `tagline` e
  `group`; a lista de modelos em `ModelCatalog.fetch`; o formato de cada modelo decide o cliente (`ProviderAccount.client`).
- **Novo campo persistido.** Valor padrão na decodificação tolerante; nunca renomeie nem remova uma chave sem migração.
- **Nova tela para revisar.** Um `case` em `Snapshot.render` (ou em um dos auxiliares), com dados de exemplo, nunca reais.
- **Novo comando de teclado.** Nome em `CommandName`, tecla em `AppShortcut` (o teste confere que nenhuma tecla se repete),
  item em `AppCommands`, linha em `ShortcutCatalog` e, se couber, entrada na paleta (`PaletteBuilder`).
