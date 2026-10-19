# Arquitetura

Para quem vai mexer no código do Orb. App nativo em SwiftUI, Swift 6 (`swift-tools-version: 6.0`, concorrência estrita),
macOS 14+, um pacote SwiftPM com um alvo executável (`Orb`, `Sources/Orb`), um app de fixture só para o smoke de Acessibilidade (`OrbAXFixture`, `Tests/OrbAXFixture`) e um alvo de testes (`OrbAppTests`). Não há
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
   ├─ BotLive por Orb (estado que as telas leem)                                 └─ ClaudeCodeClient (o CLI `claude -p` só como cano até o modelo)
   ├─ Store (JSON em disco, filas próprias) · Keychain                              + `--pipe-tools` (o app declara as ferramentas ao CLI)
   └─ Orbs/ (avatar: Core Animation, OrbDriver)
```

Três ideias organizam o resto:

1. **Cada Orb é independente.** O que um Orb faz (turno, texto em stream, aprovações, fila de mensagens, memória, uso de
   tokens) vive em um `BotSession`; o que as telas mostram dele vive em um `BotLive`. Dois Orbs trabalham ao mesmo tempo sem
   se tocar, e uma mudança num não redesenha a tela do outro.
2. **Um motor só.** Todo Orb, seja qual for o modelo, roda no `AgentEngine`: recebe uma requisição de turno e devolve um
   `AsyncStream<TurnEvent>`. Prompt, ferramentas, permissões, aprovações, memória e contexto são do Orb. Para os modelos do Claude
   Code o que muda é só o cliente de modelo (`ClaudeCodeClient`, em `Engine/ClaudePipe/`): o CLI `claude` entra apenas como cano até o
   modelo, usando o login que a pessoa já fez nele.
3. **O disco é a fonte da verdade e nada o bloqueia.** Estado, conversas e memória são arquivos legíveis; leitura e
   escrita ficam fora da thread principal; arquivos ilegíveis nunca são sobrescritos.

## Mapa dos módulos

Tudo em `Sources/Orb/`.

### Aplicativo e estado

| Arquivo | Papel |
|---|---|
| `OrbApp.swift` | `Launcher` (`@main`: com `--pipe-tools` roda só o servidor que declara as ferramentas ao CLI, sem janela), `OrbApp` (janela, Ajustes, barra de menus), `AppDelegate`, `AppCommands` (menu "Orbs"), `OrbSheet` (`--render-orbs`), `Snapshot` (`--snapshot`) |
| `AppIcon.swift` | o ícone do app (`--render-icon`): CoreGraphics puro, desenhado direto em cada tamanho na grade do macOS (ladrilho de 824 em 1024, sombra padrão; desde o macOS 26 o sistema põe qualquer outro formato num quadrado cinza), vidro perolado claro e o Orb índigo da marca o maior possível (690), com o `GelShader` (port de `art/orbgen/Body.swift`, por pixel na CPU), rosto sem óculos e uma variante simples até 64 px |
| `AppModel.swift` | `@MainActor @Observable`: Orbs, rotinas, skills, conectores, provedores, modelo padrão, nível de contexto das conversas; criar/apagar Orb, `send`, `compactNow`, rotinas e fila, conexão de provedores, salvar |
| `AppModel+Approvals / +Commands / +ContextUI / +MemoryUI / +RoutinesUI / +Schedule / +Steering / +Transcript` | o que cada área pede ao modelo: `decide` e banners; comandos, paleta e barra de menus; dados do medidor; esquecer/desfazer; modelos de rotina e listas; a ferramenta `schedule` (o Orb cria, lista, pausa e apaga as próprias rotinas); fila "enquanto trabalha"; "Tentar de novo"/"Continuar" |
| `BotSession.swift`, `BotSession+Turn.swift`, `BotSession+Conversation.swift` | a maquinaria de um Orb: conversa em memória (carregar, descarregar, salvar, estacionar durante rotina), turno (id, eventos, texto em stream, cartões), uso de tokens, trechos para a memória |
| `BotLive.swift` | o que as telas leem de um Orb: configurações, `status`, `activity` (com "digitando" e a olhada ao ser escolhido), `needsYou`, não lidas, memória, medidor. `WritesOnlyChanges` (`assign`, `writeIfChanged`) |
| `WorkLine.swift` | o que o Orb diz que está fazendo: `WorkLine` (verbo, alvo, tom, rotina, ações), `WorkPhrase` (a frase de cada ferramenta e dos status dos motores), `WorkMeter` ("16 s · 3 ações", "em 8 s"), `StatusDwell` (tempo mínimo de 0,7 s por frase) e `WorkAnnouncer` (anúncios ao VoiceOver, no máximo um a cada 8 s). `BotLive.work` é a frase; `status` continua o texto cru dos motores |
| `LiveText.swift` | `ReplyParagraphs` (parágrafos incrementais), `LiveText` (a resposta que está chegando), `OrbTranscript` (os itens que a conversa mostra, e quantos do começo a compactação recolheu) |
| `CompactedFold.swift` | o que a última compactação recolhe na conversa: tudo antes do pedido em que ela aconteceu, lido só dos itens (o aviso "Compactei a conversa:"), então desfazer até antes do aviso desfaz a faixa e conversas compactadas antes disso também recolhem |
| `ConversationSearch.swift`, `ConversationFind.swift` | a busca na conversa aberta (⌘F): a parte pura (`ScalarFolder`/`SearchPattern`/`TextSearcher` comparam sem maiúscula nem acento numa passada pelos escalares, sem copiar o texto; `ConversationSearch.search` é `@concurrent`, cancelável, lê só o texto guardado dos itens, nunca linhas, e devolve `Hit`s leves com trecho; `FindCursor` anda entre eles dando a volta) e o controlador `@MainActor @Observable` (`ConversationFind`: pausa na digitação, uma busca por vez, relê quando a conversa muda sem rolar, diz à lista para qual mensagem ir, `FindFocus` marca a linha escolhida) |
| `Models.swift` | `Bot`, `PermissionMode`, `Capability`, `Conversation`, `TranscriptItem`, `ToolCall`, `ApprovalRequest`, `Routine`, `Schedule`, `Skill` |
| `Store.swift`, `StoreCoordination.swift`, `ConversationCoding.swift`, `ConversationHistory.swift` | `AppState`, `Store` (leitura/escrita com filas), `Keychain`, decodificação tolerante, `FileGate`, codificação incremental da conversa, arquivo de conversas, relatórios de rotina |
| `DevRun.swift` | os modos de desenho (`--snapshot`, `--render-*`): decide a pasta de dados (temporária, a menos que `ORB_DATA_DIR`) e bloqueia o Keychain e a migração neles; apaga a pasta temporária ao sair |
| `SwitchBench.swift` | medida da troca de Orb: `ORB_DATA_DIR=<cópia dos dados> ORB_BENCH_SWITCH=<voltas> Orb` passa por todos os Orbs, mede até o quadro seguinte à troca ser desenhado e confere se o campo de mensagem ficou com o foco e se o chat abriu no fim da conversa; com `ORB_BENCH_COLD=1` as outras conversas saem da memória antes de cada troca, como depois de 5 min paradas; escreve mediana e pior caso e fecha o app |
| `LegacyMigration.swift` | migração do app que se chamava OpenBot (dados e preferências; as chaves do Keychain são copiadas uma a uma quando usadas; as contas já copiadas, ou removidas no Orb, ficam anotadas em `UserDefaults` (`keychainAccountsFromOpenBot`) e o item do OpenBot, mantido como backup, não é mais consultado para elas) |
| `Reset/ResetPlan.swift`, `Reset/ResetExecutor.swift`, `Reset/AppRelaunch.swift`, `AppModel+Reset.swift` | "Redefinir o Orb": o plano puro (`ResetPlan`, `ResetSummary`, `ResetGuard`), o executor com pasta, cofre e preferências injetáveis, o relançar e a orquestração (`AppModel.resetEverything`). Veja "Redefinir o Orb" abaixo |
| `OrbFolder.swift` | pasta própria `~/Orbs/<Nome>`, estado da pasta, arquivos recentes e alterados do painel |
| `MacPermissions.swift` | permissões do macOS (TCC), pré-voo de Automação (abre escondido o app conhecido que está fechado), tradução de erros |
| `AttachmentInfo.swift` | o que o chat mostra de um anexo, em valores puros: `AttachmentLayout` (separar imagens de arquivos, o plano da grade: 232 pt, 1 / 2 / 3 colunas, até 9), `AttachmentInfo` (nome, extensão, ícone, tamanho e estado `ok`/`missing`/`legacy`; `quick` sem disco, `load` fora da thread principal, com cache de 500) e `ProducedFile` (arquivo que o Orb criou ou alterou, guardado em `ToolCall.files`, opcional e tolerante) |
| `ImageAttachments.swift` | imagens do usuário e de ferramentas: reduzir (com `square:`, recorte quadrado central, para a foto do perfil), guardar em `anexos/`, apagar as que nenhum arquivo salvo cita (`removeOrphans`), formato de cada API |
| `UserProfile.swift`, `AppModel+Profile.swift` | o perfil global da usuária (nome, como te chamar, sobre você, foto) em `state.json` com decodificação tolerante; `promptSection` (o texto curto que entra pelo `pinned` da memória, vazio quando não há texto) e `ProfilePhoto` (a foto em `perfil/`; só lê arquivos do Mac, nunca um link; a última escolha ou remoção vence uma troca ainda em preparo, por `profilePhotoGeneration`) |
| `ApprovalNotifications.swift` | banners "Permitir / Não permitir", roteamento do toque, um só delegate de notificações |
| `ContextGauge.swift`, `MarkdownBlocks.swift`, `MenuBarSupport.swift`, `Shortcuts.swift`, `Motion.swift`, `Theme.swift` | palavras e leitura do medidor; blocos de Markdown (com `.image`: `![…](/caminho)` numa linha só, arquivo do Mac, nunca endereço da web); ícone da barra de menus e atalho global; nomes e teclas dos comandos e o catálogo de atalhos (folha, Ajustes e paleta leem a mesma lista); vocabulário de curvas; paleta, estilos de botão e brilho, e a escala de espaçamento (`Spacing`: 2/4/8/12/16/20/24, borda das folhas, folga entre botões; `ControlHeight`: 30 normal, 24 compacto, 44 hero; `.controlSize(.small)` torna as pílulas compactas; `hangsOnLeadingEdge()` alinha o texto de um botão fantasma no início de uma linha com o conteúdo) |

### Motor (`Engine/`)

| Arquivo | Papel |
|---|---|
| `EngineTypes.swift` | contratos: `JSONValue`, `ChatMessage`, `LLMClient`/`LLMEvent`/`LLMError`, `TokenUsage`, `CacheHealth`, `AgentTool`, `ToolRisk`, `ToolContext`, `MCPServerConfig` |
| `AgentEngine.swift` | o laço do turno: modelo ↔ ferramentas, até 100 passos (150 em rotinas), retentativas, cortes por limite, grupos de aprovação, `TurnEvent`/`TurnRequest` |
| `CompletionWatch.swift` | confere, sem chamar modelo, a resposta que fecharia o turno contra o que as chamadas mostraram: se o último build/teste/lint (`run_command`, no começo de um passo e sem pipe que esconda o código de saída) falhou e a resposta diz que está pronto sem admitir a falha, ou se ela diz ter salvo um caminho do Mac que não existe, o modelo recebe um lembrete (da mesma cota do `stopReminder`) para corrigir ou contar a verdade |
| `Providers.swift` | `ProviderKind`, `ProviderAccount`, `ModelRef` (`provedor/modelo`), `ModelCatalog` (listas ao vivo), qual cliente para qual formato |
| `OpenAIClient.swift`, `ResponsesClient.swift`, `AnthropicClient.swift` | os três formatos (chat completions, Responses, Messages): corpo da requisição e mapeamento dos eventos |
| `ProviderTransport.swift`, `SSE.swift`, `Retry.swift`, `WireEncoder.swift` | o que os clientes dividem: requisição autorizada (renova 401), erros legíveis, `Retry-After`, leitor SSE incremental, retentativa com recuo, JSON ordenado |
| `ChatGPTAuth.swift` | login "Sign in with ChatGPT" (registro dinâmico, PKCE, retorno em 127.0.0.1), token no Keychain |
| `OAuthLoopback.swift` | o que os logins dividem: `randomToken`, o desafio PKCE `S256` e o `LoopbackCallback` (ouvinte único em 127.0.0.1, com portas preferidas e a opção de não aceitar outra; abre sem prender uma thread) |
| `MCPAuth.swift` | `actor` do login OAuth 2.1 dos conectores remotos. O `HTTPTransport` recebe um `MCPTokenProvider` e põe `Authorization: Bearer` em todo pedido; um 401 renova uma vez e repete, depois vira `MCPAuthRequired` (`signIn`, `expired`, `moreScope`), que o `MCPManager` transforma em `MCPStatus.needsSignIn`/`.needsMorePermission`. O 401 sem token lê o `WWW-Authenticate` (`MCPChallenge`). `signIn` sonda o servidor, descobre a PRM (RFC 9728: o endereço do desafio, depois o caminho do endpoint, depois a raiz) e os metadados do servidor de login (RFC 8414 e OIDC, na ordem da spec), recusa sem `S256`, usa o app pré-registrado do modelo ou do editor (`MCPServerConfig.oauth`), reaproveita o que o Orb registrou antes (mesmo issuer e mesma porta) ou registra de novo (RFC 7591: `application_type` native, `token_endpoint_auth_method` none), monta a URL (`state`, `code_challenge`, `resource`, parâmetros extras), espera o retorno, confere `iss` (RFC 9207, pela tabela da spec 2026-07-28) e `state` antes de usar o código, e troca. A credencial (`MCPOAuthCredential`: issuer, cliente, segredo, porta registrada, tokens, validade, escopos, endpoint, método, resource) é um JSON só na conta `mcp.<id>.oauth` do Keychain. A renovação é única por conector (as chamadas simultâneas compartilham uma), grava a rotação e, quando o serviço encerra o login (`invalid_grant`, `invalid_client`, `unauthorized_client`, `invalid_refresh_token`), apaga os tokens e pede o login; um `invalid_client` apaga também o cliente que o Orb registrou. Um erro passageiro não apaga nada, e um token que ainda não venceu continua valendo quando não há como renová-lo. Um login que termina depois de "Sair da conta" ou de apagar o conector é cancelado (nada é gravado). Só entra em HTTPS (ou loopback): o conector `http://` fora do loopback não faz login nem recebe Bearer, e um redirect nunca desce de HTTPS para HTTP. Sair da conta e apagar o conector pedem a revogação (RFC 7009) em segundo plano quando o servidor de login anuncia `revocation_endpoint`. Sem escopo no desafio vale o do modelo ou do editor, depois o `scopes_supported` da PRM (a escolha explícita da pessoa vence um palpite do servidor) |
| `ContextBudget.swift`, `ContextWindow.swift`, `ContextCondensing.swift`, `ConversationLedger.swift`, `ContextMeter.swift`, `Compaction.swift`, `ToolDigest.swift`, `ToolOutputSpill.swift` | janela, compactação e medidor: veja [CONTEXTO.md](CONTEXTO.md) |
| `TurnPrompt.swift`, `SystemPrompt.swift`, `WorkspaceSnapshot.swift`, `WorkspaceChanges.swift`, `FolderInstructions.swift` | o prompt: sistema estável + prefácio por mensagem (`<orb_context>`: hora, pasta, memória); instruções da pasta (`ORB.md`/`AGENTS.md`/`CLAUDE.md`) |
| `PermissionPolicy.swift`, `ApprovalGate.swift`, `ApprovalBatch.swift`, `DangerousCommand.swift`, `ShellCommandLine.swift` | permissões: veja [PERMISSOES.md](PERMISSOES.md) |
| `Steering.swift` | a fila de mensagens enviadas durante um turno (`SteeringQueue`) e o modo de cada uma (`SteeringDelivery`: `.steer`, entregue no próximo passo, ou `.afterTask`, que espera o fim; `drainSteering` só leva as `.steer`, sob o mesmo lock) |
| `ClaudeCode.swift`, `ClaudeCodeProtocol.swift`, `ClaudePipe/` | provedor Claude Code: achar o `claude`, login/status e ambiente do CLI (`ClaudeCode.swift`); as linhas `stream-json` que o app escreve, o texto de erro de um `result` e os modelos do plano (`ClaudeCodeProtocol.swift`); `ClaudeCodeClient` (o CLI como cano até o modelo, sem ferramentas próprias) e `ClaudePipe*` (o servidor `--pipe-tools` que só declara as ferramentas do Orb, e a caixa de correio com os resultados que o motor do Orb deixa para ele) |
| `MCPConnection.swift`, `MCPTransport.swift`, `MCPTool.swift` | conectores MCP: stdio (com o ambiente do Terminal da usuária, de `ShellEnvironment`, para achar `npx`/`uvx` do `.zshrc`) e HTTP (Streamable HTTP com recuo para SSE). `MCPManager` só registra os conectores; o servidor sobe na primeira chamada (`ensureStarted`, uma subida compartilhada) e um ceifador (acorda a cada 60 s) desliga o que ficou 10 min sem uso e sem chamada pendente. Duas chamadas seguidas sem nenhuma resposta (`MCPConnection.stuckAfter`; qualquer mensagem do servidor, até a resposta tardia de uma chamada que já estourou, zera a conta, e chamadas paralelas que estouram juntas contam como uma), ou um `tools/list` que estoura o prazo, fecham a conexão (o servidor está vivo mas travado; as outras chamadas pendentes ouvem que o conector foi reiniciado, não o timeout delas) e a próxima sobe um processo novo; o timeout manda `notifications/cancelled`. O prazo de uma chamada é 60 s, ou o `LocalConnector.callTimeout` quando o conector é local (Gmail: 200 s, mais que os dois scripts de 90 s). Um 404 de sessão HTTP (`MCPSessionExpired`) repete uma vez numa sessão nova só a chamada que recebeu o 404 (ou que chegou depois, sem ter sido enviada); as demais já em andamento no servidor falham com "pode ter sido executada" e não são repetidas, para não duplicar efeitos. `StdioTransport` escreve no stdin fora do actor (um servidor que não lê não impede o `close`), acha o fim da linha só nos bytes novos, lê uma resposta que veio depois de lixo sem quebra de linha e fecha a conexão se passar de 32 MB sem `\n` (`HTTPTransport` tem o mesmo teto por resposta e por evento SSE, com o erro "resposta grande demais"); `StdioServerRegistry` guarda os servidores, cada um líder de um grupo de processos próprio (`SpawnedProcess`), e os sinais vão ao grupo, para que o que fica no grupo (o node que o `npx`/`uvx` abriu e os filhos dele) não sobreviva; quem cria sessão própria (o Chromium do Playwright, por exemplo) sai do grupo e depende de o servidor fechá-lo ao receber o SIGTERM: `close` manda SIGTERM e, 3 s depois, SIGKILL, e `killAllNow` (no `willTerminate`) encerra todos ao fechar o app. O pedido de "Permitir mais" fica na entrada do conector (`asksMoreScope`) até `scopeGranted`, em vez de se perder quando o servidor reinicia. `MCPTool` (`Servidor__ferramenta`) guarda o id do conector e chama o gerente |
| `LocalConnector.swift`, `Tools/CalendarConnector.swift`, `Tools/MailConnector.swift` | conectores que rodam dentro do app (Google Agenda e Lembretes por EventKit, Gmail pelo Mail.app com AppleScript), atrás do mesmo porteiro. `MCPServerConfig.local` os marca; `LocalTransport` responde o JSON-RPC em processo (`LocalConnectorServer.respond`), então catálogo, cartão, ceifador e permissões funcionam como em qualquer conector. `LocalConnectorEnvironment` agrupa o que eles tocam (`CalendarBackend`, `MailBackend`): testes e capturas põem fakes e nenhuma permissão do macOS é pedida |
| `ConnectorGateway.swift` | o porteiro dos conectores: `connector_tools` (índice dos conectores do Orb na descrição, lista as ferramentas e os argumentos) e `connector_call` (roda uma). Ficam fora de `ToolBox.all`; `AgentEngine.resolved` troca cada `connector_call` pela chamada do `MCPTool` de verdade antes da política de permissão |

### Ferramentas (`Engine/Tools/`)

`ToolBox.all` = `shellTools + fileTools + webTools + searchTools + browseTools + macTools + memoryTools + scheduleTools`; cada família lista as suas no próprio arquivo.
`ToolBox.offered(for:accessibilityGranted:browser:)` filtra por capacidade do Orb, esconde `ui_read`/`ui_act` sem Acessibilidade e as `browse_*` sem o navegador instalado (`BrowserAvailability.browser`).

| Capacidade | Ferramentas | Arquivos |
|---|---|---|
| Terminal e arquivos | `run_command` (`background: true`; saída acima de 20 KB é salva inteira em `saidas/<orb>/comando-….txt`), `job_output` (sem `id`, lista todos), `job_stop`, `read_file` (texto, PDF, Word/RTF/ODT, Excel .xlsx e .xls, PowerPoint .pptx, imagens com OCR), `write_file`, `edit_file`, `list_directory`, `search_files` (Spotlight), `grep` (um arquivo informado em `path` vai até 200 MB, em streaming), `glob` (aceita padrão absoluto), `trash` (também com Controlar apps); o ambiente vem do shell `-lic` da usuária (5 s) e, se ele estoura, o perfil de login responde na hora e a nova tentativa roda em segundo plano (15 s), com espera que dobra de 30 s até 5 min | `ShellTool`, `BackgroundJobs`, `CommandRelease`, `ProcessRunner`, `ShellEnvironment`, `FileTools`, `SearchTools`, `TextFile`, `DocumentReader`, `OfficeReader`, `LegacyExcelReader`, `ReadOnlyCommand` |
| Navegar na web | `web_fetch` (páginas, PDF, JSON, imagens; `offset`/`find` para páginas longas; `save_to`), `web_search` (DuckDuckGo, Google, TinyFish), e com o navegador instalado `browse_open/snapshot/read/screenshot/click/fill/select/press/scroll/back/tabs/show/close` e, no `BrowseMoreTools`, `browse_wait/find/dialog/files/page/run`, `browse_proxy` (`BrowseProxyTool`, `BrowserProxy`; o proxy é `Bot.browserProxy` sem a senha, que fica no `SecretVault` na conta `BrowserProxy.keychainAccount` (`AppModel.saveBrowserProxy`/`browserProxy(of:vault:)`); vai ao `BrowserHub.setProxy` no começo de cada turno e ao agent-browser pela variável `AGENT_BROWSER_PROXY` (nunca em argv), com só um hash na impressão digital do lançamento, e a sessão com outro proxy é trocada; os erros passam por `BrowserProxy.redacting`; `BrowserAccess.scope` é o id da conversa e dá a ela uma aba própria: `BrowserSession.scoped` e o `TabBook` (por geração do navegador, `BrowserDriver.generation`) trocam de aba dentro do `exclusive` só quando muda quem chama, `browse_tabs` só vê as abas da conversa, `AppModel.endBrowserConversation` fecha a de uma rotina ou pedido que terminou (com proxy com login a aba fica, como sobra) e `relaunchKeepingTabs`/`restoreTabs` reabrem as páginas depois de trocar o proxy ou o modo; `BrowserProfileCache` limpa os caches do perfil uma vez por semana, com o navegador fechado no hub e no `SingletonLock` do perfil) (`BrowserDriver.command` e `manual`; as regras do `browse_run`, o que recusa, o risco e os arquivos, ficam em `BrowseRunRules`) | `WebTools`, `HTMLText`, `WebSearchTool`, `BrowseTools`, `Engine/Browser/` |
| Controlar apps do Mac | `applescript`, `shortcuts_list/run`, `clipboard_read/write`, `screenshot` (janela com marcas numeradas e OCR), `apps_list`, `app_quit`, `trash`, `browser_tab`, `ui_read`, `ui_act` | `MacTools`, `MacAppTools`, `BrowserTools`, `ScreenshotTool`, `WindowCapture`, `UIMarks`, `SyntheticInput`, `AccessibilityTools`/`Elements`/`Outline`/`Session`/`Events`/`Contracts`, `ScreenTakeover`, `AppleScriptSupport` |
| Sempre | `open`, `notify`, `remember`, `recall`, `schedule` | `MacTools`, `MacAppTools`, `ScheduleTool` |
| Conectores | `connector_tools`, `connector_call` (fora de `ToolBox.all`, montadas por turno) | `ConnectorGateway`, `MCPTool` |

**Apps em segundo plano (`ui_read`/`ui_act`, desenho em `docs/USO-DO-COMPUTADOR.md`).** Nada rouba o foco, move o cursor ou
digita onde a usuária digita. Toda chamada ao AX é IPC que bloqueia: roda na fila serial do app (`actor AXAppSession`, com
`unownedExecutor` numa `DispatchSerialQueue`, em `AXSessions.shared`, `AccessibilitySession.swift`), no máximo 4 apps ao mesmo
tempo, com prazo (leitura 4 s, 8 s com `query`; ação 2 s; `wait` = timeout + 0,5 s). Estourado o prazo, a ferramenta responde
"não respondeu" e o app fica ocupado até a chamada presa voltar (novas falham na hora). O timeout de mensagem do AX é 1 s,
posto uma vez por processo no elemento system-wide (o do app vale só para ele) e na raiz; o primeiro `.cannotComplete` encerra a
leitura (`read(_:) -> AXRead`, corte `.hung`). Em debug, o elemento vivo para com `dispatchPrecondition` se chamado na main.
A leitura pede num lote só papel, título, filhos, posição e tamanho (≤ 2 IPC por elemento, +1 para valor), corta em 400 linhas
ou 14.000 caracteres e lê só 3 níveis dentro de `AXWebArea` sem `query`; o `UISnapshot` ganha `generation`, frames relativos à
janela e `actionable`, e herda marcas e geometria do screenshot da mesma janela (< 60 s). `UILiveElements` guarda as
referências AX vivas de cada leitura (por Orb e app, 6 leituras, 4.000 referências, 10 min): a ação confere o elemento num lote
(papel, nome, processo, janela) em vez de refazer o caminho. `ui_act` sobe uma escada: AX (N0), evento ao processo do app
(N1, `system.input`), e a tela real só com `takeover` e confirmação (N2, `system.screen`); sem N1 o erro leva o marcador
`[precisa_assumir_tela]`. Sem `app`, age no app da leitura mais nova do Orb, nunca no da frente; recusa digitar com o app em
uso pela pessoa (tecla ou clique há < 3 s) ou com o foco do app fora do campo, refaz o juízo de perigo com o rótulo vivo, e
devolve com `AXFrontmost` o app da frente se o alvo se ativar sozinho. As notificações vêm do `AXEventHub`
(`AccessibilityEvents.swift`): uma thread "Orb.AXEvents" com run loop próprio, um `AXObserver` por app com contagem de
assinaturas, desmontagem pela thread do hub (`CFRunLoopPerformBlock`), fim do processo por `DispatchSource`, app ocioso sai em
30 s, até 16 apps. Depois de agir, `UISettle` espera a primeira notificação (≤ 400 ms) e 60 ms de silêncio (150 ms sem
notificações); `wait` relê a cada notificação ou a cada 250 ms.

**Visão e entrada sintética** (`docs/USO-DO-COMPUTADOR.md`, pacote WP-B). `WindowCapture.swift`: `LiveWindowCapturer.shared` (o `capturer` de `LiveAccessibilitySystem`) lista e captura janelas por um `CaptureBackend`: ScreenCaptureKit (`SCShareableContent` em cache de 1,5 s, `SCScreenshotManager.captureImage` de uma `desktopIndependentWindow`, `.nominal`, sem sombra, com janelas-filhas, sem cursor, redimensionada a `max_side`) e, quando ele falha por outro motivo que a permissão, `screencapture -o -l <id>`; no máximo 2 capturas ao mesmo tempo (`AsyncGate`) e `CGRequestScreenCaptureAccess` uma vez por processo (`RequestOnce`). `WindowMatcher` casa a janela da árvore AX com a do ScreenCaptureKit por frame (±2 pt) e título. `UIMarks.swift`: `UIMarkCollector` percorre a janela (ids iguais aos do `ui_read`, um controle não é aberto por dentro, o que está fora da janela é pulado, 4 s e 3.000 elementos), `UIMarkSelector` escolhe até 60 marcas (acionáveis, ≥ 6×6 pt dentro da janela, em ordem de leitura), `UIOverlay` desenha contornos e selos numerados com Core Graphics e `ScreenshotJPEG` grava JPEG q0,8 (≤ 450 KB: baixa a qualidade e depois o tamanho), `UIMarkLegend` escreve `[12] w1.3.2 button “Salvar”` (≤ 4.000 caracteres), `ShotGeometry` ganha as conversões pixel ↔ ponto da janela ↔ ponto global (`DisplayLayout` cuida de várias telas, origem negativa e do espelho do AppKit) e `UISnapshot.merging` junta marcas, geometria e frames ao snapshot do `ui_read` da mesma janela (< 60 s). `ScreenshotTool` junta tudo: legenda sem Gravação de Tela, só a imagem sem Acessibilidade, OCR (Vision `.fast`, uma imagem por vez, `(x,y) texto` em pixels da imagem) só com `ocr: on` ou com menos de 8 elementos nomeados. `SyntheticInput.swift`: `LiveSyntheticInput.shared` (o `input`) monta eventos com `SyntheticEventBuilder` (teclado `CGEvent` com `keyboardSetUnicodeString` em pedaços de ≤ 20 unidades UTF-16 sem partir caractere; atalhos com flags explícitas e o código da tecla do layout em uso por `UCKeyTranslate`, `LiveKeyLayout`; mouse com `mouseEventClickState` e a janela nos campos do evento; rolagem em pixels, em passos) e entrega por um `SyntheticEventSink` (`PidEventSink`: `postToPid`, nunca o tap HID, nunca o próprio Orb, nunca a área de transferência); cancelar a tarefa entre os pedaços devolve quantos caracteres saíram.

**Apps em segundo plano: tomada de tela.** O desenho completo está em [USO-DO-COMPUTADOR.md](USO-DO-COMPUTADOR.md). `ScreenTakeover.swift`
é o único lugar que traz outro app para a frente e usa mouse e teclado de verdade (`.cghidEventTap`). `LiveScreenOwner` (o
`ScreenOwner` ao vivo, entregue por `LiveAccessibilitySystem.screen`) pega a trava do app (`TakeoverLock.shared`, em memória e não bloqueante: um takeover por vez, o segundo recebe "ocupado" em vez de esperar), guarda o app da frente, a janela focada e o cursor, traz o alvo com `AXFrontmost` (espera `AXApplicationActivated` até
500 ms, com sondagem do app da frente por baixo), roda o corpo com um `LiveTakeoverHand` (`CGEventSource(.privateState)`, arrasto
em 15 passos, texto em pedaços de 20 unidades UTF-16; aborta se o cursor real se afastar mais de 3 pt do lugar em que foi posto,
solta o botão se o arrasto para no meio; 10 s no total e 2 s por etapa) e **sempre** devolve, numa `Task.detached` aguardada (a
restauração não é cancelável): `AXFrontmost` no app anterior, `AXMain` na janela anterior, `CGWarpMouseCursorPosition` +
`CGAssociateMouseAndMouseCursorPosition(1)` e conferência (se a pessoa pegou o mouse para parar, o cursor fica onde ela o
pôs). Tudo o que toca o macOS fica atrás de `TakeoverPlatform`/`TakeoverEventPoster` (testes com um mundo falso), e as chamadas
bloqueantes rodam numa fila própria (`TakeoverQueue`), nunca no pool cooperativo. O aviso "Orb está usando a tela — mexa o mouse
para parar" é um `NSPanel` não ativante (`TakeoverHUD`) que o app mostra ao receber uma notificação distribuída
(`TakeoverBroadcast`) de qualquer processo que segure a tomada.

**Servidor MCP do cano: uma tarefa por requisição.** `ClaudePipeServer.Loop` (em `ClaudePipe/ClaudePipeTools.swift`) atende cada linha de
stdin em uma `Task`, com a escrita em stdout serializada. As `tools/call` correm lado a lado (cada uma espera, por polling, o arquivo do
seu `tool_use_id` na caixa de correio, até 30 min); o handshake e a listagem respondem em ordem. `notifications/cancelled` encerra a espera
de uma chamada (que não recebe resposta) e o fim de stdin faz `exit(0)`. As respostas de `initialize`, `ping` e `tools/list` são as de
`MCPStdioServer.respond`.

**Codificação dos arquivos de texto.** `TextFile.decode` tenta UTF-8, depois BOM (UTF-16/32), UTF-16 sem marca e por fim Windows-1252
(Latin-1 se houver byte indefinido). Um arquivo UTF-8 com poucos bytes soltos (um caractere cortado no fim de um log) continua
UTF-8: se as sequências multibyte válidas superam em 3 para 1 os bytes inválidos, o texto sai com U+FFFD no lugar deles e
`invalidUTF8Bytes` conta quantos são. `read_file` avisa e o `grep` acha os acentos; o `edit_file` guarda cada byte solto
como um caractere de uso privado (U+F780–U+F7FF, como o `surrogateescape` do Python) e o devolve como estava ao gravar: só muda o
trecho editado, e recusa (com a dica de `run_command`) um `old_text` que inclua U+FFFD ou esses caracteres.
`read_file`, `edit_file` e o `grep` com `path` recusam o que não é arquivo comum (dispositivo, pipe, socket; `requireRegularFile`): um
FIFO sem escritor trava a leitura sem que Parar a solte, e `/dev/zero` não acaba.
O texto convertido de Word/RTF/ODT, Excel (.xlsx e .xls) e PowerPoint fica em `DocumentTextCache` (6 documentos, 50 milhões de caracteres, chave
caminho + data + tamanho): ler uma planilha por páginas (`offset`) converte uma vez, não a cada página.

**Processos filhos ao sair.** Cada comando e cada `claude` lidera um grupo de processos próprio (`SpawnedProcess`), então não morre
junto com o app. `ChildProcessGroups` registra os grupos do `ProcessRunner` (até o comando voltar) e do `LineProcess` (até o
processo sair; `SpawnedProcess.watch` espera a saída por um `DispatchSource`, sem prender uma thread por filho); no `willTerminate`, `killAllNow` manda SIGTERM a todos, mais os dos jobs em segundo plano, e SIGKILL ao que sobrar
meio segundo depois. Sobras de um `cmd &` que o `run_command` já devolveu, avisadas no resultado, continuam fora do registro.

**Comando que vai para o segundo plano no meio.** Um `run_command` em primeiro plano não prende a conversa: enquanto ele roda, a
linha "agora" do chat mostra **Segundo plano**, e uma mensagem para a tarefa (o ↩ do compositor) faz o mesmo se o comando já passou
de 3 s (`CommandRelease.messageGrace`; um comando rápido só termina). O `ProcessRunner` confere o pedido a cada 250 ms
(`Detach.when`); ao soltar, a saída lida até ali e o resto passam a ir para um log em `orb-jobs/<orb>/comando-….log`, e
`BackgroundJobs.adopt` assume o processo como um job comum (`job_output`/`job_stop`, aviso ao terminar). O modelo recebe o id do job
e a instrução de atender a usuária. Quem ouve a saída do processo é decidido sob uma trava só (`ChildEnd`): ou o comando volta com o
código de saída, ou o job registra o fim, nunca os dois nem nenhum. Rotinas e pedidos de outro Orb, que ninguém acompanha, esperam
seus comandos até o fim (`ToolContext.release` é nil).

**Continuar sozinho quando o processo termina.** Se um job que o Orb abriu depois da sua última mensagem termina com o Orb
parado, `AppModel.showJobs` manda o mesmo "continue" do botão Continuar (aparece como sua mensagem), para ele ler o resultado e
seguir. Só vale sem rascunho no compositor, fora de rotinas, até você apertar Parar e até 3 vezes por mensagem sua
(`resumesAfterJobs`); um job que
termina no meio de um turno só vira aviso, como antes.

**Erros que dizem o que fazer.** Arquivo ou pasta que não existe (`read_file`, `edit_file`, `list_directory`, buscas, o `cwd` do
`run_command`) volta com até 3 caminhos parecidos (`ToolError.notFound`, `URL.lookalikes`: mesmo nome com outra caixa ou extensão,
ou 1 letra de diferença, 2 em nomes de 8 ou mais, na pasta mais próxima que existe). Os códigos 127 e 126 do shell explicam a causa
(`RunCommandTool.hint`). Argumentos que não são JSON válido voltam com os campos da ferramenta (`ToolSpec.argumentsHint`). Toda
ferramenta que falha chega ao modelo marcada como erro (`ToolOutcome.isError`).

**`schedule`.** Uma tarefa agendada **é** uma `Routine` do Orb (a mesma página, o mesmo agendador de 30 s, a mesma fila e o mesmo
relatório; logo depois de o Mac acordar, `runDueRoutines` espera 45 s pela rede, `AppModel.wakeSettleTime`; ele sabe que o Mac dormiu pelo aviso de sono, pelo despertar ou por uma volta do agendador muito distante da anterior, porque o cronômetro pode voltar antes da notificação): a ferramenta dá ao Orb o jeito de criá-la (já ativa ou pausada, e opcionalmente rodando uma vez na hora, `run_now`), alterá-la (`update`: só o que vier de prompt, horário e meta; um horário novo conta a partir de agora), listá-la, pausá-la, retomá-la, rodá-la agora (`run`, como o botão da página Rotinas: entra na fila se o Orb estiver ocupado) e apagá-la. Quando você descreve algo a fazer com regularidade, a descrição da ferramenta orienta o Orb a propor a tarefa (com `ask_user`) e só criá-la depois do seu sim, a menos que você já tenha pedido. `ScheduleCommand` confere a
chamada (`daily`, `weekly`, `every_minutes` de 15 a 720, `every_hours` de 1 a 24; nome, prompt de até 4.000 caracteres); quem
executa é `AppModel.schedule(_:orb:)`, que só vê as rotinas do Orb que chamou, recusa o 21º, o nome repetido e criar, alterar, disparar,
retomar ou apagar tarefas de dentro de uma rotina (ela só pode pausar), e responde em português ("Agendei “X”: a cada 30 minutos. Próxima execução: …"), que é também o que o
chat mostra como resultado da ferramenta. A chamada chega por `ToolContext.schedule` (um fecho preso ao Orb), com qualquer modelo. Uma execução que passa do próprio intervalo (a cada 15 min,
levando 20) conta a próxima a partir do fim dela (`finishRoutineRun`), então nada se acumula.

**O navegador do Orb (`Engine/Browser/`).** Um protocolo, `BrowserDriver` (abrir, snapshot com refs, clicar, preencher, ler, captura,
abas, janela), e um driver real, `AgentBrowserDriver`, que roda a linha de comando do [agent-browser](https://github.com/vercel-labs/agent-browser)
(`agent-browser --session <s> --json <comando>`) por `ProcessRunner`, com o PATH do shell de login da usuária (`ShellEnvironment`), prazo
e cancelamento; o processo em segundo plano do próprio agent-browser mantém o navegador aberto entre os comandos. Há **um navegador só**, um
Chromium (o Chrome ou o Brave de Applications; sem eles, o Chrome for Testing que o app instalou), em dois modos (`BrowserMode`): `background`
(headless, o padrão: não abre janela nem tira o foco) e `visible` (`--headed`). `AgentBrowserConfig.launchArguments` monta o lançamento:
`--executable-path <lançador>`, `--args --disable-blink-features=AutomationControlled`, `--profile <pasta do Orb>` e, no modo visível, `--headed`.
O lançador (`navegador/lancadores/<navegador>-<versão>.sh`, `AgentBrowserConfig.launcherScript`) é um `exec '<navegador>' "$@" '--user-agent=<Chrome N>'`:
o `--args` do agent-browser divide na vírgula e um user agent tem uma ("KHTML, like Gecko"), e o `--user-agent` do próprio agent-browser vai pelo
protocolo DevTools e deixa os service workers dizendo "HeadlessChrome" (medido em docs/REVISAO-NAVEGADOR-2026-10-16.md); o blink flag é o que
faz `navigator.webdriver` ser falso, sem o que o DuckDuckGo e o Google respondem com captcha. O texto de um campo que é exatamente uma opção da
linha de comando (`--json`) seria comido por ela, e `--` não impede: esse texto vai por `batch`, com aspas simples. Só `open` lança um navegador, com as
opções do Orb: o agent-browser inicia um navegador à escolha dele (o Brave ou o Chrome de Applications, sem perfil nem opções) para qualquer comando que não encontra processo em segundo plano (`get url`, `snapshot`,
`tab`… conferido), então `send` pergunta `session list` antes de todo comando que não é `open`, `close` ou `session` (a resposta vale por 3 s depois de qualquer comando que deu certo) e, sem a sessão, lança `noPage`
("chame browse_open") sem mandar o comando; se mesmo assim a resposta de um comando disser `lifecycle.launched`, o navegador que ele iniciou é fechado na hora e o resultado também é `noPage`. Uma sessão que já roda não
relança o navegador com as opções de um `open` novo; por isso o `open` do driver compara a impressão das opções do lançamento (`launchFingerprint`: `--executable-path`, perfil, args e ambiente;
a janela `--headed` fica de fora) com a que está em `navegador/sessoes/<sessão>.launch` e, se a sessão roda com outra (ou sem registro, como as de versões antigas), fecha, espera sumir e só então abre. Os comandos rodam
com `--config navegador/agent-browser.json` (vazio, do app), com `navegador/` como pasta de trabalho e com o ambiente do shell de login sem as `AGENT_BROWSER_*` nem a chave do TinyFish (`AgentBrowserConfig.sanitized`);
os proxies ficam. Um seletor de `browse_snapshot` ou um id de aba que começaria com `-` seria uma opção da linha de comando: o seletor que começa com `-` é recusado e o id de aba tem de ser `t<número>`.
`BrowserLocator` procura o `agent-browser` primeiro em `navegador/bin` (o que o app instalou), depois no PATH do shell, Homebrew, npm e cargo, e o navegador em Applications (Chrome, Brave, Chromium, Canary,
nessa ordem; `BrowserProgram`) e só depois no Chrome for Testing; devolve um `BrowserStatus`: pronto, ou o que falta (o Orb manda instalar em Ajustes → Navegador).

**Instalação (`BrowserInstaller`).** Instala dentro de `navegador/` na pasta de dados (`BrowserInstallLayout`): `bin/agent-browser`, `chrome/chrome-<versão>/` (só sem Chrome nem Brave no Mac) e
`instalados.json`. O agent-browser é **fixo** (`BrowserPlatform.agentBrowserVersion`, 0.39.1): o app baixa `releases/download/v0.39.1/agent-browser-darwin-<arm64|x64>` e confere o SHA-256 gravado no código
(`BrowserPlatform.pinnedHashes`); nada de "latest". O Chrome for Testing é o `agent-browser install` rodado com um `HOME` da pasta de trabalho (ele não tem variável para a pasta de
destino), e a pasta `chrome-<versão>` é movida para `navegador/chrome`. Tudo roda fora da main, por `ProcessRunner` (que ganhou `onOutput` para ler "42/184 MB" como progresso) e por `URLSession` (download com progresso, só segue
redirecionamento para `https`); nada com `sudo`. Cada peça é baixada e testada (`--version`) numa pasta `.instalando-<id>` e só então trocada pela antiga (`replaceItemAt`), então cancelar (`Task.cancel`, que mata o processo e a
transferência) ou falhar não estraga o que havia. `uninstall` remove os arquivos do componente; os perfis nunca saem aqui. `removeLegacyEngines` apaga o que versões antigas instalaram do Obscura e do CloakBrowser
(só no `navegador/` do app). `checkForUpdates` consulta o índice de versões do Chrome for Testing no máximo uma vez por dia (`atualizacoes.json`); o agent-browser só "tem atualização" quando um app novo trouxer outra versão fixa.
`BrowserSetup` é o modelo de Ajustes → Navegador (`BrowserComponentRow`: estado, versões, o que cada botão pode); uma instalação por vez.

Limpeza: ao sair (`willTerminate`) `BrowserHub.terminateAllNow` roda `agent-browser close` de cada sessão que o hub guarda e, depois, de **cada sessão `orb-*` que `session list` mostra** (as que uma execução anterior do
app deixou: o processo em segundo plano do navegador sobrevive ao app), e espera (até 4 s); `close(botID:)`, `closeAll()` (atualizar ou remover algo em Ajustes) e `deleteData` também fecham por nome (`deleteData`
espera o navegador sumir antes de apagar o perfil), e `browse_close` sempre manda fechar a sessão do Orb; `AppModel.update` fecha o navegador do Orb quando o modo muda ou "Navegar na web" é desligado; o agent-browser
fecha sozinho um navegador parado há 30 minutos (`AGENT_BROWSER_IDLE_TIMEOUT_MS`).
`BrowserHub` guarda um `BrowserSession` por Orb (sessão `orb-<id>-chrome`, o sufixo que as primeiras versões chamavam de motor; perfil em `navegador/<orb>/chrome` na pasta de dados; `adoptOldProfile` renomeia o `cloak` de um
Orb que usava o CloakBrowser), serializa
os comandos (`AsyncMutex`: ferramentas que só olham rodam juntas no turno) e lembra os refs do último snapshot, para dar nome ao clique no cartão e
recusar senha. A janela (`browse_show`), no modo segundo plano, fecha a sessão e a reabre no mesmo endereço com `--headed` e o mesmo perfil, e então **espera a pessoa**; no modo visível a janela já está aberta e
`browse_show` só espera (`BrowseShowTool.keepsWindow`):
`ToolContext.handoff` (que o motor define a cada chamada) abre um cartão de aprovação com `ApprovalRequest.isHandoff` ("Pronto" = `.once`, "Cancelar" = `.deny`)
pelo mesmo `ApprovalGate` (`ApprovalGate.handoff`), então Parar, o selo "precisa de você", o aviso (categoria `orb.approval.handoff`) e o painel da barra de menus
valem sem código novo; só `applyModeChange` o ignora (uma troca de modo não responde por ela). Trocar o modo de um Orb (`AppModel.setBrowserMode`) fecha o
navegador que ele deixa (`BrowserHub.close(botID:)`, também quando a sessão foi aberta por uma execução anterior do app). A sessão e o `BrowserAccess` do turno
chegam às ferramentas por `ToolContext.browser`; `AppModel` monta isso a cada turno com o modo do Orb (`Bot.browserMode`, `Bot.searchProvider`) e acrescenta ao prompt a
seção `BrowserPrompt` (ou a linha de "falta instalar"). A busca (`web_search`) abre a página de resultados numa aba própria do navegador (e a fecha), lê o resultado por
script e cai no DuckDuckGo pelo HTTP simples quando não há navegador; o TinyFish é uma API (`SearchKeys` guarda a chave no Keychain) com queda para o DuckDuckGo.

**`web_fetch`.** Lê HTTP(S) com o User-Agent do Safari (gzip/br, `Accept-Language: pt-BR`, 20 s de limite) e decodifica pelo BOM,
pelo cabeçalho, pelo `<meta charset>` e por UTF-8/Windows-1252. HTML (até 5 MB) vira um Markdown leve (`HTMLText`): só o
conteúdo principal (`<main>`, o único `<article>`, `role="main"` ou um id conhecido, desde que tenha ao menos 500
caracteres e 20% do texto; senão a página inteira), sem menus, rodapés, `<aside>`, elementos ocultos (`hidden`,
`aria-hidden`, `display:none`), landmarks ARIA e algumas classes da Wikipedia; títulos em `#`, código em cercas
com a indentação intacta, tabelas em linhas `| a | b |`, `alt` de imagens e links `texto (url)`, com os do mesmo site
só pelo caminho (`texto (/wiki/X)`) e o endereço do site no cabeçalho. Se o resultado ficar quase vazio e a página tiver
scripts, vem uma nota dizendo que ela precisa de JavaScript (com o texto do `<noscript>`). JSON, XML e texto vêm como
estão; PDF vira texto (até 25 MB) com marcador de página; imagem vira imagem quando o modelo enxerga (`runWithImages`).
A leitura do corpo tem prazo total de 30 s (`readDeadline`; o limite de 20 s é só de silêncio): um stream que não acaba (eventos
do servidor, rádio) devolve o que chegou, com uma nota no cabeçalho (e no fim da página, nas leituras com `offset`). Um corpo com
tamanho anunciado (`Content-Length`, PDF ou tipo genérico) acaba sozinho e tem 180 s (`finiteReadDeadline`), para um PDF
grande numa conexão lenta; um PDF cortado por tempo ou por tamanho erra com a dica de `save_to` (sem a chave Terminal, a
resposta diz que o arquivo é grande demais, ou, se foi só o tempo, sugere tentar de novo). Áudio, vídeo, arquivos
compactados e outros tipos que só se salvam são respondidos pelos cabeçalhos ("não é texto"), sem baixar nada; tipos genéricos
(`octet-stream`, `binary/…`, `…download…`, ou nenhum) são lidos e o PDF é reconhecido pelos primeiros bytes (`%PDF`): até lá o limite é o de PDF (25 MB) e, se não for PDF, volta aos 5 MB.
A resposta é paginada (12 000 caracteres, até 24 000) cortando na última quebra de linha ou espaço, e a página convertida
fica 10 minutos em memória (`WebPageCache`, 8 páginas) para `offset` e `find` (trechos com o offset de cada um) não
baixarem de novo. `save_to` baixa até 100 MB num arquivo temporário e move no fim; recusa antes se o `Content-Length` já
passa do limite. Erros de rede e de HTTP voltam em português, com o endereço e uma dica. O `Info.plist` do app traz
`NSAllowsArbitraryLoads` para o macOS não bloquear `http://`.

**Busca.** `web_search` (`WebSearchTool`) devolve títulos, endereços e trechos pelo provedor que o Orb escolheu (DuckDuckGo, Google pelo
navegador do Orb ou TinyFish, com chave); a página de resultados não é uma API, então quando o formato muda a ferramenta diz que não achou
nada em vez de inventar. Vale para qualquer modelo, o do Claude Code incluído: o `claude` não tem ferramenta de busca própria no cano. Veja o
[manual](MANUAL.md#navegador) ("Pesquisa").

Os nomes e as descrições das ferramentas para o modelo são em inglês; o que aparece para você (título e detalhe de cada
linha, cartões) é em português (`AgentTool.summary`).

### Uso e custos (`Usage/`)

| Arquivo | Papel |
|---|---|
| `UsageRecord.swift` | o que se guarda: `UsageKey` (hora × Orb × modelo × origem), `UsageTotals` (pedidos, tokens de entrada, de cache lido e gravado, de saída, custo informado pelo CLI), `UsageBucket`, `UsageMonth` (o arquivo de um mês: linhas, nomes dos Orbs, `maxBuckets` = 20 000) com decodificação tolerante. Toda contagem de `UsageTotals` fica em 0...`TokenUsage.maxCount` (10¹²), na criação, na soma e na leitura do arquivo, e os clientes de provedor tratam como desconhecida (`TokenUsage.sane`) uma contagem fora dessa faixa: um servidor com números absurdos não estoura nenhuma soma, nem a da página de Uso |
| `UsageStore.swift` | `Store.addUsage` / `readUsage` (`uso/aaaa-mm.json`, na fila de gravação e na de leitura do `Store`) e o `UsageRecorder` (`@MainActor`, junta o que os turnos usaram e entrega em lote, a cada 10 s e ao fim de cada turno e ao sair) |
| `AppModel+Usage.swift` | `AppModel.recordUsage`, o ponto único de registro; `recordAuxiliaryUsage` para chamadas do app fora de um turno; `priceBook` e `correctPrice` |
| `ModelPricing.swift` | `ModelPrice` (US$ por milhão), `PriceTable` (tabela embutida, com o dia da consulta), `UsageBilling` (por uso, plano, local), `PriceBook` e `UsageCost` |
| `UsageReport.swift` | a agregação pura da página: `UsagePeriod`, `UsageReport.make` (totais, por Orb, por modelo, séries do gráfico, 24 horas) |
| `Views/UsageSettings.swift`, `Views/UsageSnapshots.swift` | a aba Uso (`UsageModel` lê e soma fora da thread principal), a folha de correção de preço e a cena de captura |

### Memória (`Memory/`)

`MemoryBank` (um actor por Orb) + `MemoryIndex` (SQLite/FTS5) + `MemoryPage`/`MemoryText`/`MemorySanitizer` +
`SessionSummary` + `MemoryIntent` + `KeptMemories` (memórias guardadas e o perfil de cada uma).
Detalhes em [MEMORIA.md](MEMORIA.md). As skills que o Orb propõe vivem aí também (`SkillProposal`, `MemoryBank+Skills`,
`_propostas/`, `_skills.json`); a revisão que as propõe é `Engine/SkillReview.swift` + `AppModel+SkillReview.swift`, e o contador
(`stepsSinceSkill`, de passos do modelo), o pedido guardado (`reviewBase`, com `reviewFrom`) e a tarefa (`skillReview`) ficam no `BotSession`.

### Importar de outro assistente (`Import/`)

`OrbImport` (Sendable: fonte, nome, papel, identidade, itens com caixa de seleção, skills; `plan()` aplica a seleção e os
limites e devolve o que será gravado) + `ImportGuard`/`ImportSanitizer` + `OrbImportReader` e `OrbImportFormats` (puro, sem
UI, `nonisolated`: o Cartão do Orb, Character Card JSON, pastas do Hermes/OpenClaw por lista fechada sem seguir links, texto
livre; `detectLocal(home:devRun:)`) + `ImportPrompt` + `GrokMarketplace` (o marketplace do Grok Bot: os dados vêm dos
scripts `self.__next_f.push` das páginas públicas; a lista, `catalog`, tem só os cartões e fica 15 min em `CatalogCache`; a
página de um bot tem o conteúdo, `read`; `filter`/`categories`/`categoryLabel` servem a galeria). A interface é
`Views/ImportPanel.swift` (com `Views/MarketplaceGallery.swift`), dentro de `NewBotSheet`; a gravação é
`AppModel.createBot(importing:)` + `MemoryBank.importPages`. Só a aba do marketplace faz rede, e importar nunca produz
permissões, modo, capacidades, conectores ou rotinas. Nos modos de desenvolvedor a detecção de `~/.hermes` e `~/.openclaw` fica desligada
(`AppModel.readsRealMac`).

### Catálogos (`Catalog/`)

`MCPRegistry` (registro oficial do MCP), `ConnectorTemplates` (modelos prontos; `retired` guarda os que a galeria não oferece mais, só para reconhecer
conectores já instalados), `ConnectorGallery` (a grade de serviços e o estado de cada cartão: disponível, conectado, desligado, precisa de
atenção, em breve), `LocalConnectorSetup` (estados "sem permissão", "negado", "sem conta", "pronto" e o "Conectar", que é o único que mostra o
diálogo do macOS), `SlackApp` (manifesto e link de criação do app do Slack, presets de escopos), `BrandMarks` (os logotipos dos serviços da galeria, do Simple Icons, CC0, embutidos como caminhos SVG: slug → caminho + cor; `withoutLogo` lista os que o Simple Icons não tem, que ficam com o símbolo (hoje nenhum: o Slack vem da 13.21.0, a última versão que o tinha)), `SVGPathData` (leitor de `d` de SVG para `Path`: M L H V C S Q T A Z, relativos, números colados e flags de arco sem separador) e `BrandGlyph` (o caminho já lido, os limites reais e o tratamento: cor da marca sobre o escuro, branco sobre o escuro para marcas quase pretas ou branco sobre a cor da marca para as escuras; `BrandShape` desenha, centralizando e dimensionando pelo limite real; `ConnectorIcon` e o `icon` de `orbSheet` usam o mesmo cartão), `ConnectorCatalog` (o que cada conector ofereceu
da última vez, em `conectores/<id>.json`: serve ao índice, à resolução das chamadas, às anotações que a permissão lê, à contagem do cartão e
a "Ver ferramentas"), `SkillCatalog` (Skills.sh + GitHub),
`ConnectorSecrets` (segredos de conectores no Keychain, `@keychain` no `state.json`; `oauthAccount` é a conta do login), `AppModel+ConnectorLogin` (`signIn(connector:)`, `signOut`, `removeConnector`, que apaga a conta do login), `OrbScope` (conectores e skills por
Orb: "Usar com").

### Orbs (`Orbs/`)

O avatar e seu sistema de animação: `OrbModel` (config, catálogo, imagens), `OrbActivity`, `OrbAnimationView` + `OrbDriver`
(Core Animation, um display link por tela), `OrbMotion`, `OrbTemperament`, `OrbSpeech`, `OrbView`, `OrbEditor`. Veja [ORBS.md](ORBS.md).

### Telas (`Views/`)

| Área | Arquivos |
|---|---|
| Janela | `RootView` (`NavigationSplitView`, painel que se recolhe em janela estreita), `SidebarView`, `ChatView` (lista da conversa), `EmptyChatContent` (e `OrbGreeting`, a saudação de um Orb novo), `FirstRunCard`, `WelcomeView` (a tela sem Orbs: `WelcomeStage`, `WelcomeCopy`, `WelcomeLooks`, `WelcomeSelection`, `WelcomeLedger`, `WelcomeBackdrop`, `KeptStartCard`; o que ela pede ao modelo está em `AppModel+Welcome.swift`) |
| Conversa | `FindViews` (a barra de busca e a lista de resultados), `TranscriptViews` (`TranscriptRow` Equatable, ferramentas, `ApprovalCard`, `WorkingLine`), `MarkdownBlockViews`, `SelectableProse` (parágrafos, títulos, listas e citações seguidos de uma resposta num `NSTextView` só leitura, para a seleção atravessar todos; código, tabelas e linhas ficam em views próprias; a cópia sai com "• " e quebras, sem as tabulações), `QueuedMessages`, `ImageThumbnails`, `AttachmentViews` (`AttachmentStack` e `FileCard`, o mesmo componente na bolha, na fila, no compositor e sob a linha da ferramenta; `AttachmentGrid`, `ImageTile`, `ProducedFilesView`, cliques, menu e arrastar), `QuickLookPreview`, `ApprovalKeyboard` |
| Compositor | `ComposerView`, `ComposerChips` (menu do "+" com anexar e skills, permissões, modelo), `ComposerSupport`, `ModelPopover`, `ModelPicker`, `ContextMeterViews`, `DictationButton` |
| Ditado | `Dictation` (estado, permissão do microfone, escreve no rascunho; digitar o encerra), `SpeechCapture` (AVAudioEngine → SpeechAnalyzer/SpeechTranscriber do macOS 26, no aparelho), `DictationText` (frases do reconhecedor exato + o rascunho pontuado dele + palavras do rápido além delas), `DictationReview` (ao parar, o modelo menor do Orb ajusta o texto; travas contra resposta em vez de revisão) |
| Painel do Orb | `BotInspector` (abas Geral, Memória, Pasta e acessos, Rotinas), `InspectorSupport`, `MemoryViews`, `DeleteOrbDialog`, `PermissionConfirmation` |
| Ajustes | `SettingsView` (Geral, Modelos, Uso, Permissões), `ProfileSettings` (a seção "Você" e `ProfileAvatar`, que a barra lateral também usa), `ResetOrbSheet` ("Redefinir o Orb?" e o alerta), `ProviderSettings`, `ProviderPresentation`, `CustomProviderFields`, `ClaudeCodeSettings`, `MacPermissionsView`, `ContextSettings` |
| Páginas | `RoutinesView`, `SkillsView`, `ConnectorsView`, `CatalogParts` |
| Sistema | `CommandPalette` (⌘K e a folha de atalhos; as teclas vêm de `ShortcutCatalog`, em `Shortcuts.swift`, a mesma lista que Ajustes → Geral mostra), `QuickAskView` (painel da barra de menus), `SheetKit` (folhas: `orbSheet`, `SheetFooter`/`SheetFooterBar`, `ActionRow` das linhas de botões dos cartões), `ImportPanel` (a importação de outro assistente, dentro da folha Novo Orb) |
| Para revisão (só `--snapshot`, só em debug ou `ORB_DEV_TOOLS`) | `WelcomeSnapshots`, `CatalogSnapshots` (com as cenas `skill-proposal`, `skill-proposal-update`), `ContextSnapshots`, `SystemSnapshots`, `TranscriptSamples` (`transcript-skill-proposal`), `AttachmentSnapshots`, e `SnapshotComposerScenes.swift` (na raiz de `Sources/Orb/`) |

## O caminho de um turno

```
ComposerView ── AppModel.submit ─┬─ Orb livre ─► AppModel.send ───► AgentEngine.run
                                 └─ Orb trabalhando ─► fila              (qualquer modelo; o cliente varia)
                                    (ComposerLane / SteeringQueue)                          │
                                                                       AsyncStream<TurnEvent>│
                                                                                             ▼
                           BotSession.play ─► apply(evento) ─► conversa (itens + mensagens), BotLive, LiveText ─► telas
```

1. **Envio.** `ComposerView.send` chama `AppModel.submit`. Com o Orb trabalhando na sua conversa, a mensagem entra numa fila
   (`ComposerLane.enqueue`) com um modo: ↩ = `.steer` (o `AgentEngine` a entrega no próximo passo, `deliverSteering`, e o app a
   mostra no ponto em que o Orb a recebeu, com `TranscriptItem.duringTask`), ⇥ = `.afterTask` (`ComposerAction.tab` decide a
   tecla: só com o Orb trabalhando e algo no campo; com as sugestões de skill abertas o ⇥ completa a skill). Quem não entregou até o
   fim, e as `.afterTask`, seguem juntas como o próximo pedido em `settleSteering`. Falha ou parada devolvem tudo ao campo;
   `switchDelivery` troca o modo de uma pendente (a fila e a lista do balão mudam juntas; uma já entregue não muda). Senão a mensagem vai
   para `AppModel.send`. Uma rotina trabalhando bloqueia o envio (o compositor avisa).
2. **`AppModel.send`** valida (texto ou anexo, turno em andamento, provedor pronto; sem provedor, `setupNudge` faz o cartão de primeiro
   uso pulsar e o texto fica no compositor; enquanto `hasCheckedConnections` é falso nada pulsa nem avisa: o compositor espera
   `connectionsChecked()` e envia; arquivos sozinhos recebem `attachmentsOnlyPrompt`), trata `/compactar`, grava a mensagem do usuário na conversa, limpa o rascunho,
   põe o status "Pensando" e a "agitação" do Orb (`poke`, `isListening`), detecta pedido de memória (`MemoryIntent`), expande
   `/skill`, acrescenta os caminhos dos anexos e a nota das imagens e, numa rotina, o aviso de que ninguém está presente.
3. **Histórico.** `Conversation.prepareHistory(budget:reserving:)` corta e condensa se passou do orçamento (um aviso
   na conversa e a memória gravada antes de esquecer). O turno ganha um id (`beginTurn`).
4. **Montagem (em `Task`, fora da thread principal quando custa).** `MemoryBank.brief` (memória), `TurnPromptInputs.gather`
   (snapshot da pasta, em cache de 60 s, e instruções da pasta), `TurnPrompt.native` (prompt do sistema estável + prefácio
   por mensagem), o cliente (`ProviderAccount.client` pelo formato do modelo), as ferramentas (`ToolBox.offered` + as dos
   conectores permitidos) e o `TurnRequest` (`Sendable`). Se o turno foi parado nesse meio-tempo (`isCurrent`), nada segue.
5. **Laço** (`AgentEngine.play`, até 100 passos): entrega mensagens da fila; ajusta a janela (`ContextWindow.fit` com o
   `ContextCut` do turno); chama o modelo com até 4 tentativas e recuo (`withRetries`, status "Provedor ocupado", "Limite do provedor" ou
   "Conexão caiu, tentando de novo em N s", conforme o erro); trata o motivo de parada (recusa, resposta cortada, estouro de contexto); roda as chamadas
   (`runCalls`: um cartão para o que pergunta junto, leituras em paralelo, o resto em ordem); registra cada mensagem. Com
   um modelo do Claude Code o laço é o mesmo: só a chamada ao modelo muda (`ClaudeCodeClient.stream`, que mantém o processo `claude -p` do turno
   parado entre um passo e outro); as ferramentas, as permissões e o `ApprovalGate` são do Orb.
6. **Eventos.** `TurnEvent`: `status`, `text`, `toolStarted`/`toolFinished` (com `files`: o que a ferramenta criou ou alterou, `write_file`/`edit_file`, mais as imagens que a ferramenta devolve; `BotSession.takeOver` deixa o arquivo só na última chamada do turno que o tocou), `approval`, `message` (vai para o histórico do
   modelo), `notice`, `failed`, `usage`/`requestUsage`/`pendingUsage`, `compacted`, `taskPaused`, `steered`.
7. **Aplicação** (`BotSession.apply`, na thread principal): o texto vai para `pendingText` e é publicado em `LiveText` a cada
   33 ms, **sem tocar na lista de itens**; ferramentas e cartões viram itens da conversa; `message` entra em
   `Conversation.messages`; o `BotLive` recebe status, ferramenta em uso, "falando" e "esperando você", e a frase da linha de trabalho (`work`,
   uma por passo, nunca por token, cada uma por ao menos 0,7 s).
8. **Fim** (`finishTurn`): zera status; agenda a página de sessão da memória (30 min depois); fecha a execução da rotina;
   notifica (se o app está em segundo plano) e conta não lidas; o Orb comemora (`happy`) ou erra (`error`); entrega a fila que
   ficou; grava a conversa de uma vez; começa a próxima rotina que esperava por este Orb. Por último (fora de rotinas): avisa
   da skill que o turno propôs e, se os passos do modelo com ferramentas chegaram a 10 (e a tarefa não parou no limite), começa em segundo plano a
   revisão da conversa (`reviewSkillsIfDue`: mesmo pedido e histórico do turno, só `recall`/`remember` skill, cancelada por qualquer
   mensagem e por redefinir; o prompt da revisão só orienta o turno, `promptOnlySteers`, então as saídas do turno seguem inteiras
   como na última chamada dele; com 5 propostas esperando, a revisão nem chama o modelo).

## Persistência

Pasta de dados: `~/Library/Application Support/Orb/` (a variável `ORB_DATA_DIR` troca).

```
state.json                       AppState: Orbs, rotinas, skills, conectores (segredos viram "@keychain"), provedores,
                                 modelo padrão, não lidas, nível de contexto das conversas, janelas aprendidas, correções de preço
conversations/<Orb>.json         a conversa do Orb (uma só, nunca some): itens da tela + mensagens do modelo + resumo/ledger + marcas
conversations/<Orb>.meta.json    nota ao lado: quantos itens, quantos já foram para a memória, impressão digital do arquivo
conversations/<Orb>/<id>.json    só de versões antigas ("Nova conversa"): `Store.mergeArchive` as junta à conversa na abertura, em ordem, e apaga
conversations/<Orb>/routine-<rotina>.json   a conversa de cada rotina
rascunhos.json                   o que cada compositor guarda sem enviar (`ComposerDraft`: texto e caminhos de arquivos e imagens); gravado ao sair, depois que o turno interrompido devolveu a fila, e a cada rodada do agendador; lido na abertura
conectores/<id>.json             catálogo do conector (`ConnectorCatalog`): o que o servidor ofereceu da última vez, sem segredos
memoria/<Orb>/…                  a memória (páginas .md + index.sqlite, _propostas/ e _skills.json das skills); memoria/_guardadas/<nome> – <data>/ de Orbs apagados ou
                                 redefinidos, com perfil.json (nome, papel e aparência) ao lado das páginas
anexos/<Orb>/<uuid>.jpg|png      imagens reduzidas (a conversa guarda o caminho); saem com o Orb, ou na abertura do app quando nenhum arquivo salvo (estado, rascunhos, conversas, arquivadas, rotinas, pedidos, grupos; as cópias `.corrupt-…` também contam como uso) cita o nome e a imagem tem mais de 7 dias (`ImageStore.removeOrphans`; um arquivo que não abre cancela a limpeza)
perfil/foto-<8 hex>.jpg|png      a foto da usuária (quadrada, até 256 px; nome novo a cada troca, a antiga é apagada); nunca vai a provedor nem a ferramenta; o Redefinir apaga a pasta
saidas/<Orb>/*.txt               saídas grandes de ferramentas; limpas por idade (14 dias) e tamanho (200 MB)
claude-pipe/cwd/                 a pasta (vazia) em que o `claude` roda como cano até o modelo; nenhum projeto à vista
claude-pipe/runs/<uuid>/         os arquivos de um processo do `claude` (prompt do sistema, declaração das ferramentas, configuração do MCP, caixa de correio dos resultados);
                                 apagada quando o processo termina, e as que um app que caiu deixou somem depois de um dia
uso/aaaa-mm.json                 histórico de uso: uma linha por hora × Orb × modelo × origem, só números (veja "Uso e custos")
*.corrupt-<aaaammdd-hhmmss>      cópia de um arquivo que não pôde ser lido (nunca sobrescrito)
.migrado-do-openbot              marca de que a migração do OpenBot já foi feita
```

Fora dela: o **Keychain** (serviço `app.orb.mac`; uma conta por provedor com chave, `chatgpt` com o JSON do login e
`mcp.<id do conector>.<NOME>` para segredos de conectores e `mcp.<id>.oauth` para o login de um conector), as **preferências** (`UserDefaults`: `notifyWhenDone`,
`quickAskGlobalShortcut`, `keychainAccountsFromOpenBot`, aba de Ajustes e do painel de cada Orb, modelos recentes…) e a **pasta de cada Orb**
(`~/Orbs/<Nome>/`, com `Rotinas/<nome>/…md`), que o app não apaga ao apagar o Orb.

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
   `state.json` e suas cópias `state.json.…`, `rascunhos.json`, `conversations/`, `memoria/`, `anexos/`, `conectores/`, `saidas/`, `perfil/`, `uso/`; qualquer outro arquivo, como
   `.migrado-do-openbot`, fica); e, em `navegador/`, só os dados dos navegadores dos Orbs (uma pasta por id de Orb, com perfil, logins,
   cookies e estados salvos, e `sessoes/`), como apagar um Orb faz: `bin/`, `chrome/` (Chrome for Testing), `instalados.json`,
   `atualizacoes.json`, `agent-browser.json` e `lancadores/` são ferramentas e ficam; apaga os segredos pelo cofre injetável (`SecretVault.remove` = `Keychain.set("")`, o mesmo
   caminho público de apagar chave: conectores e, com "Também sair dos provedores", uma conta por provedor mais `chatgpt`;
   nunca o Claude Code); devolve as preferências ao padrão (`UserDefaults` do próprio app, menos `LegacyKeychainLedger.key`);
   grava um `state.json` novo só com os provedores, o modelo padrão e as janelas aprendidas quando eles ficam; e, se a pasta do
   OpenBot ainda tem dados e o marcador faltava, cria o marcador. Cada passo continua se outro falhou; o relatório
   (`ResetReport`) diz o que sobrou e, se sobrou algo, um aviso (`ResetWarning`, injetável em `ResetEnvironment.warn`) lista os itens
   antes de o app fechar.
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

### Uso e custos

Cada resposta do provedor traz os tokens do pedido (`TokenUsage`); o app os soma por hora, e o custo é calculado na hora de mostrar.

- **Registro.** `BotSession.apply` entrega a `AppModel.recordUsage` cada `TurnEvent.requestUsage` (uma chamada ao modelo, também com o Claude Code: o cano lê os tokens
  do fluxo do CLI). O modelo é o do turno (`BotSession.turnModel`); a origem é `routine` se há uma rotina rodando,
  senão `chat`; `auxiliary` é para chamadas do próprio app fora de um turno: hoje a revisão de skills em segundo plano (`reviewSkillsIfDue` repassa cada
  `.requestUsage` a `recordUsage`; o resumo da compactação é por regras e não gasta nada). Um pedido interrompido
  pelo botão Parar também é cobrado: o transporte anuncia os tokens de entrada assim que o provedor os informa (`LLMEvent.usage`,
  o `message_start` da Anthropic, antes de qualquer saída), o motor repassa como `TurnEvent.pendingUsage` e `BotSession.play`, que
  é quem ainda lê o fluxo depois do Parar, registra o último que não foi seguido de um `.requestUsage`.
  O `UsageRecorder` guarda o que chega num dicionário e o entrega ao `Store` a cada 10 s, ao fim do turno e no `saveNow`.
- **Arquivo.** `Store.addUsage` lê o mês (decodificação tolerante, `.corrupt-…` se não decodifica), soma e grava na fila de
  gravação, então lotes e leituras (que esperam as gravações do mesmo arquivo) ficam em ordem. Um mês nunca passa de 20 000 linhas
  (as que não cabem são contadas em `dropped`). A hora é a hora local do relógio (`Calendar.current`) e o mês do arquivo, o do relógio.
  Um Orb apagado continua no histórico: o arquivo guarda o nome que ele tinha.
- **Preço.** `PriceBook.price(for:)`: correção da usuária (`AppState.priceCorrections`, lida entrada por entrada: uma estragada não leva as outras) → preço da lista do provedor
  (`ProviderModel.price`, lido de OpenRouter `pricing` e de models.dev `cost`, os mesmos que o app já baixava) → `PriceTable`
  (id normalizado: sem prefixo de provedor, data, `:thinking`, `-latest`; pontos viram traços; um id que a tabela não tem acha a
  família mais longa só quando o que sobra são sufixos que não mudam o preço, `PriceTable.sameFamilySuffixes`: `codex`, `preview`,
  `customtools`…, nunca uma versão nem `-pro`/`-mini`/`-deep-research`; a data só fica para `gpt-4o-2024-05-13`, que tem preço próprio).
  Preços que mudam com o tempo ficam em `PriceTable.adjustments` (fator sobre o preço da tabela, escolhido pela hora da linha:
  DeepSeek fora do pico = metade; Gemini Flash 3.6-3.8 = dobro a partir de 2027-01-01). A gravação de cache de 1 h
  (`TokenUsage.cacheWrite1h`, lida de `usage.cache_creation` da Anthropic; subconjunto de `cacheWrite`) tem preço próprio
  (`ModelPrice.cacheWrite1h`, 2× a entrada). A correção vence também sobre o equivalente calculado nos planos. `PriceDraft` é o texto do editor
  e conserva o que ele não mostra (a escrita de 1 h) para que salvar sem mudar nada não altere o preço. `UsageBilling.of(provedor)` diz se é por uso, plano (ChatGPT,
  Claude Code, OpenCode Go: `incluído`, com o equivalente da tabela de preços) ou local (Ollama, LM Studio, gateway em localhost: grátis).
  O custo não é gravado (a não ser o `reportedCost` que linhas antigas do Claude Code trazem): corrigir um preço corrige o passado.
- **Página.** `UsageModel.reload` descarrega o recorder, lê os meses do período no `Store` e soma em `Task.detached`
  (`UsageReport.make`, pura); um resultado de uma leitura mais velha nunca substitui o de uma mais nova. Só roda ao abrir, ao
  trocar de período, ao corrigir um preço e ao voltar ao app; nada contínuo. Animações: `Motion.content` em valores e barras, nada com Reduzir movimento.
- **Tabela de preços.** `PriceTable.consultedOn` é o dia em que as páginas oficiais foram lidas (a nota da página o mostra). Para
  atualizar: leia as páginas citadas no comentário da tabela, troque os valores e o dia; `UsagePricingTests` confere o formato, não os números.

### Decodificação tolerante

Campo novo precisa de valor padrão: `container.value(_:default:)`, listas com `lossyArray` (um item ilegível é pulado, não
derruba a lista) e enums de texto com `Decoder.rawValue(_:fallback:)`. O que se perdeu vira aviso: `DecodeLoss` conta os itens
pulados e o `Store` guarda uma cópia do original (`.corrupt-…`) antes de regravar. Um arquivo que não decodifica é **movido**
para essa cópia (nunca fica no caminho de uma escrita); se nem isso dá, o `FileGate` bloqueia as gravações naquele arquivo até
o app abrir de novo. Falha ao gravar avisa uma vez. Na conversa, uma mensagem ou item pulado faz os números que apontam para as listas
(`summaryCoveredCount`, `condensedCount`, as faixas de `chunkSummaries`, `memorySavedCount`) recuarem junto, e um resultado
de ferramenta cuja chamada foi pulada sai também (o provedor recusa um resultado sem a chamada; `lossyOptionals`). Os avisos aparecem no alerta "Atenção com seus dados"
(`AppModel.dataNotices`), que trocam o nome do arquivo pelo que ele guarda ("a conversa de Lia", "os ajustes do app";
`StoreNotice.file` + `AppModel.described`); falha ao gravar o `.meta.json` não avisa (ele se refaz da conversa). Enums de
texto de versões novas (`OrbTemperament`, `APIFormat`, modo de permissão…) caem no padrão em vez de derrubar o Orb; um
modelo de provedor com formato desconhecido sai da lista. A gravação incremental da conversa mantém o formato do arquivo, legível por versões anteriores.

### Convenção: inits dos tipos de dados

- Não escreva `init` memberwise à mão: o Swift gera um, e só deixa de gerar quando algum `init` está declarado no corpo do tipo.
- `init(from:)` e inits de conveniência vão numa `extension` do tipo, no mesmo arquivo (o `CodingKeys` privado exige o mesmo
  arquivo), para o Swift continuar gerando o memberwise. Tipo aninhado pede a extension qualificada (`extension TaskPlan.Step`).
  Mover o `init(from:)` para a extension não muda o formato em disco.
- O valor padrão fica na propriedade (`var state: State = .queued`), não no init. Um `let` com valor inicial não entra no
  memberwise, e a ordem dos parâmetros é a ordem de declaração das propriedades.
- Init manual só com motivo, explicado num comentário de uma linha: rótulo `_`, validação ou conversão, propriedade `private`
  sem valor inicial, dependência injetada em `let`, classe ou actor.

### Filas e gravação

- Gravações: **uma fila serial por pasta de dados** (`WriterQueues`), em ordem, fora da thread principal. O estado é salvo
  400 ms depois da última mudança (`scheduleStateSave`); uma conversa, no máximo a cada 5 s enquanto uma resposta chega (um
  pouco mais em conversas longas) e na hora ao fim do turno; ao sair, só o que mudou (`saveNow`). Uma gravação que falha marca a
  conversa como não salva de novo (`reportSaveFailure`), para o `saveNow` ao sair tentar outra vez. A conversa de uma execução de
  rotina que já terminou (o chat voltou) fica em `unsavedRoutineConversations` se a gravação falha, e é gravada de novo ao sair; a próxima execução da rotina parte dela, não do arquivo mais antigo.
- Ao sair (`willTerminate`): `stopTurnsForQuit` interrompe os turnos (os cartões fecham e a conversa diz "Você interrompeu"), o estado e os rascunhos são salvos, e `ChildProcessGroups.killAllNow` e `BackgroundJobs.killAllNow()` encerram os grupos de processos que o app iniciou: os comandos em
  segundo plano, o `claude` do Claude Code e o `run_command` em primeiro plano (cada um lidera um grupo próprio, que a morte do app não alcança).
- Leituras: fila concorrente própria, coordenada por arquivo (`FileGate`): uma leitura espera as gravações *daquele* arquivo
  (nunca vê um arquivo pela metade nem uma versão velha) e não espera as dos outros. O nome de um arquivo para o `FileGate`,
  as filas de escrita e os selos (`FileKey`) sai só do texto do caminho: `standardizedFileURL` olha o disco (tira o `/private`
  de um caminho que existe), então um arquivo que ainda não existia ao registrar a gravação ganhava outro nome ao terminá-la,
  e uma leitura esperava para sempre ("Carregando a conversa" sem fim em `--snapshot` com `ORB_DATA_DIR` em `/private/tmp`).
  Uma leitura que passa de 3 s esperando registra no log o que a segura.
- Gravação incremental: `ConversationEncoder` reaproveita o JSON dos itens que não mudaram desde a última gravação do
  arquivo (cache por arquivo, no máximo 4 arquivos e 48 MB) e não grava quando nada mudou. Ao gravar, saídas antigas de
  ferramentas (anteriores à penúltima mensagem do usuário) ficam com começo e fim (~4 000 caracteres).
- Só a conversa do Orb aberto é lida na abertura (`beginLoading`, com marcador de carregamento); as outras, ao trocar de Orb ou
  quando algo precisa delas (`ensureLoaded`, na thread principal, só quando não dá para esperar). Começar uma rotina (a leitura
  da conversa dela, `startRoutine`) também lê fora da thread
  principal e conferem depois que o Orb, a rotina e a conversa ainda existem e que nenhum turno começou. Uma conversa parada há mais
  de 5 min, sem nada para gravar, volta ao disco (`unloadIdleConversations`, a cada 30 s), o que a nota `.meta.json` ao lado
  permite verificar sem reler.

## Concorrência

| O que | Onde roda |
|---|---|
| `AppModel`, `BotSession`, `BotLive`, `LiveText`, `OrbTranscript`, `ComposerLane`, `ConnectorSecrets`, as telas | `@MainActor` |
| `AgentEngine`, `ApprovalGate`, `MCPManager`/`MCPConnection`/transportes, `ChatGPTAuth`, `MCPAuth`, `ClaudeCode`, `WorkspaceSnapshots`, `BackgroundJobs`, `ShellEnvironment`, `SkillCatalog` | `actor` |
| `MemoryBank` | um `actor` por Orb: todas as escritas daquele Orb em fila; `MemoryLibrary` (sem estado mutável fora do lock) guarda os bancos |
| Disco, Keychain, SQLite, decodificação de imagens, leitura de pasta e git | fila do `Store`, tarefas desprendidas (`Task.detached`), `DispatchQueue` próprias, `runDetached` (cancelável) para `grep`/`glob`/documentos, `Blocking.run` para chamadas bloqueantes do TCC |

- Os valores que atravessam fronteiras são `Sendable` e imutáveis: `TurnRequest` captura tudo de que o turno precisa
  (inclusive `PermissionSource`, uma closure que lê o modo e as liberações **no momento** de cada chamada), e o turno não lê
  estado da interface.
- Um turno tem um **id** (`BotSession.turnID`). Um turno parado ainda pode estar terminando a montagem ou escoando eventos
  enquanto o próximo roda: só o turno atual (`isCurrent`) muda o estado do Orb.
- Parar (`BotSession.stop`) cancela a `Task` do turno, nega os cartões abertos, fecha a resposta, acrescenta "Você
  interrompeu esta resposta" e encerra o turno. O motor respeita `Task.isCancelled` (e o processo do Claude Code recebe
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
| **Streaming de custo constante** | O texto chega em `pendingText`, é publicado a cada 33 ms em um `LiveText` fora da lista de itens; `ReplyParagraphs` divide por linhas em branco de forma incremental (offsets em bytes UTF-8, sem reler); só o último parágrafo é interpretado e medido; os fechados mantêm identidade e cache | O custo de um flush não pode crescer com o tamanho da resposta nem da conversa. Um bloco de código longo (mais de 40 linhas) em stream é desenhado em pedaços fechados de 40 linhas (`CodeLines`, `Equatable`) e só o último muda; sem streaming é um `Text` único. Uma tabela longa (mais de 20 linhas) segue a mesma ideia: as linhas fechadas viram pedaços `Equatable` de 20 linhas dentro do mesmo `Grid` (as colunas continuam alinhadas) e as células da linha em escrita não entram no `MarkdownCache`; os itens de lista são `Equatable` |
| **Linhas `Equatable`** | `TranscriptRow` com `.equatable()`, `SidebarBotRow`, cartões recebem ids; `LazyVStack` | Só a linha que mudou é refeita |
| **Nada de trabalho no `body`** | Filtros, buscas e agrupamentos ficam em `.task`/estado (`FoldedTextCache`, `ModelListing`, as buscas da conversa); o medidor de contexto é medido fora da thread principal com debounce (`ContextGaugeDriver`); uma medição que um sinal novo substituiu é cancelada e `ContextMeter.fill(isCancelled:)` para antes da próxima passagem pelo histórico | O `body` roda com frequência e na thread principal |
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
```

São mais de 3.900 testes em `Tests/OrbAppTests`, em Swift Testing (`@Test`, `@Suite`, `#expect`, `#require`).

- **Determinismo.** Nada de dormir um tempo fixo para "dar tempo": `waitUntil(_:timeout:poll:_:)` (em `TestSupport/Waiting.swift`)
  espera uma **condição** (com limite generoso e `Issue` descritiva se estourar). Para afirmações negativas, espere primeiro
  um sinal positivo de que o sistema assentou. Os testes do modelo chamam `flushText` direto em vez de esperar os 33 ms.
- **Isolamento.** Cada suíte usa pastas temporárias próprias (`Store(directory:)` tem a sua fila de escrita), e
  `AppModel(store:runsBackgroundWork: false, asyncLoading:, secretVault:)` (e `devRun: true`, que também pula os conectores) não inicia agendador, Keychain nem observadores
  do app (o cofre de segredos é um `MemoryVault`). `QuietNotifications.hold()` impede banners do processo de teste.
- **Modelo falso e auxiliares.** Os testes injetam um `LLMClient` próprio: `AppModel.clientOverride`, ou um modelo passado
  direto ao `AgentEngine.run`. O que mais de um arquivo precisa mora em `TestSupport/`, e só lá: antes de escrever um fake,
  um portão ou uma limpeza, procure. A convenção:
  1. **Modelo falso roteirizado é sempre `CallScript` (+ `CallScriptModel`).** O roteiro dá as respostas em ordem
     (`ModelReply.say`, `.calling`, `.failing`), diz o que fazer quando acabam (`whenExhausted`: `.repeatLast` ou `.fim`, sempre
     explícito), pode esperar (`holdsCall`, `before:`) e grava o que recebeu (`calls`, `received`). Um tipo novo só se
     testar algo que o roteiro não expressa (um modelo que nunca termina, portão por chave, rota pelo prompt), com um
     comentário dizendo o quê.
  2. **Esperar um passo é `TestGate`; esperar um estado é `waitUntil`** (`TestSupport/Waiting.swift`). Nada de laço com
     `Task.sleep` calado.
  3. **Pasta temporária é `TempFolder`, como propriedade da suíte** (apaga no `deinit` com `removeTestFolder`, selando as
     gravações tardias). Nunca como variável local nem em tupla: o ARC solta o objeto no meio do teste. Nada de
     `defer { removeTestFolder }` por teste numa suíte que já tem a raiz.
  4. **Erro esperado é `#expect(throws:)`** (`#expect(throws: Tipo.self)` ou `#expect(throws: valor)`), nunca
     `do { …; Issue.record } catch`. Para conferir a mensagem: `let error = try #require(await #expect(throws: ToolError.self) { … })`.
  5. **O que um segundo arquivo precisar vai para `TestSupport/` na hora.** A segunda cópia de um helper já é motivo
     para subir; a terceira não passa na revisão.

  Estão lá, entre outros: `LockedBox`, `utcCalendar`/`utcDate`, `failureMessage`, `writeExecutable`, `notices`, `FakePreferences`, `StoreFixtures`, `RaisedFlag`,
  `notifies(reading:whenYouDo:)`, `hasPython` e as visões do `AppModel` que só os testes leem. O Claude Code é testado com um `claude` falso, um script que o
  próprio teste grava e passa ao `ClaudeCodeClient` (`ORB_CLAUDE_PATH` faz o app usar outro executável).
- **Fixtures sem binários**: PDFs e PNGs são desenhados na hora (`Fixtures`), e o AX (Acessibilidade) é uma árvore falsa
  injetável (`AccessibilitySystem`, com `TestSupport/AccessibilityFakes.swift`; a tomada de tela tem o seu mundo falso em
  `ScreenTakeoverTests`).
- **Smoke de Acessibilidade** (`AXSmokeTests`, desligado por padrão): `ORB_AX_SMOKE=1` roda `ui_read`/`ui_act`/`screenshot` contra o app
  `OrbAXFixture` (AppKit, nunca se ativa, registra em JSON no stdout o que recebeu) e confere que o app da frente e o cursor não
  mudam; precisa da Acessibilidade para quem roda os testes (o Terminal do Mac, não um terminal sem ela). `ORB_AX_TAKEOVER=1` liga
  os que assumem a tela de verdade, `ORB_AX_SMOKE_SYSTEM=1` uma leitura do Finder, e a captura exige Gravação de Tela. Não mexa no
  mouse enquanto rodam.
- **Contratos de fio**: `ProviderWireGoldenTests` fixa a requisição e os eventos de cada formato.

### Modelo falso para uso manual

`scripts/fake-llm.py [porta] [--long]` serve uma API compatível com OpenAI em `http://127.0.0.1:8765/v1`: cada mensagem
recebe um texto curto, uma chamada `run_command` (para ver o cartão de aprovação) e, depois do resultado, uma resposta final
(`--long`: ~2 000 palavras de Markdown, uma a cada 15 ms, para medir o streaming). Ele também informa o uso de cada chamada
(1 200 tokens de prompt, 800 do cache, 30 de saída), então a aba Uso tem números. Para usar: abra o app com dados isolados e
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
| `--pipe-tools <declarações.json> --pipe-mailbox <pasta>` (montado pelo `ClaudeCodeClient`) | roda só o servidor MCP que declara as ferramentas do Orb ao CLI do Claude Code (que é apenas o cano até o modelo); os resultados vêm da caixa de correio que o motor do Orb preenche; sem janela |
| `--snapshot <modo> <arquivo.png>` | desenha uma tela fora da vista e sai (abaixo; só em build de desenvolvimento) |
| `--render-orbs <arquivo.png>` | folha de Orbs × atividades (`docs/orbs-activities.png`) |
| `--render-icon <arquivo.png> [pixels]` | o ícone do app, desenhado no tamanho pedido (padrão 1024; `scripts/bundle.sh` chama um por tamanho do iconset) |

`--snapshot` e `--render-orbs` só existem em build de desenvolvimento (`swift build`, que é debug, ou um release com
`-Xswiftc -DORB_DEV_TOOLS`, p. ex. `ORB_DEV_TOOLS=1 scripts/bundle.sh`): ficam atrás de `#if DEBUG || ORB_DEV_TOOLS`, junto com as
cenas (`*Snapshots.swift`, `TranscriptSamples`, `SnapshotComposerScenes`, `SwitchBench`). No app distribuído, os dois avisam no stderr
e saem com código 64 em `Launcher.main`, antes de existir modelo, janela ou pasta de dados. `--render-icon` fica em todos os
builds (o `bundle.sh` o usa em release). Para gerar uma tela: `.build/debug/Orb --snapshot skills /tmp/skills.png`.

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
| `ORB_LIVE_TESTS=1` | liga as suítes que usam a rede (catálogos reais) |
| `ORB_SIGN_IDENTITY="Nome"` | (em `scripts/bundle.sh`) assina com outra identidade |

### `--snapshot`

Renderiza a tela com dados de exemplo numa janela fora da tela, sem tirar o foco
(`NSApp.setActivationPolicy(.accessory)`), e grava o PNG. Os Orbs saem estáticos (o Core Animation não é capturado). Os dados
vêm de uma pasta temporária nova (os Orbs iniciais) ou, se você definir `ORB_DATA_DIR`, dessa pasta. O Keychain não é tocado.

> O `--snapshot` nunca usa a sua pasta real: só escreve em `ORB_DATA_DIR` se você o definir (aponte para uma pasta de teste).

Modos (qualquer outro nome mostra o chat do primeiro Orb):

| Área | Modos |
|---|---|
| Janela e painéis | `app`, `sidebar`, `sidebar-profile` (com o perfil de exemplo), `inspector` (aba Geral), `inspector-memory`, `inspector-folder`, `inspector-routines`, `memory-sheet`, `new-orb`, `new-orb-kept` (com memórias guardadas, uma escolhida), `new-orb-import` (o painel de importação vazio), `new-orb-import-preview` (a prévia de um exemplo, com um item suspeito desmarcado; use `ORB_SNAPSHOT_HEIGHT=1300` para vê-la inteira), `new-orb-imported` (de volta ao formulário, com a importação confirmada), `new-orb-marketplace` (a galeria do marketplace do Grok Bot com bots de exemplo e um deles na prévia; use `ORB_SNAPSHOT_HEIGHT=1300`), `welcome` (sem modelo), `welcome-checking` (conexões ainda não verificadas), `welcome-ready`, `welcome-kept` (com duas memórias guardadas), `welcome-returning` (lista esvaziada), `welcome-narrow` (a pronta; use `ORB_SNAPSHOT_WIDTH=1000 ORB_SNAPSHOT_HEIGHT=620`) — todas com `ORB_DATA_DIR` numa pasta com `{"bots":[]}`, senão o modo de desenvolvedor cria o Atlas —, `editor`, `editor-<categoria>` (o editor numa categoria, com um visual que tem cabelo e chapéu), `delete-orb`, `palette`, `shortcuts`, `menubar-icons` |
| Conversa | `chat-greeting`, `chat-greeting-returning`, `chat-greeting-typed`, `chat-working` (uma mensagem direcionada, uma para depois da tarefa e uma entregue no meio, com a marca), `chat-working-wait`, `chat-working-retry`, `chat-typed`, `chat-attachments`, `chat-attachments-queued`, `chat-drop` (arquivos arrastados sobre o chat, antes de soltar), `chat-slash`, `popover-permissions`, `popover-model`, `popover-skills`, `approvals`, `transcript`, `transcript-approvals`, `transcript-notices`, `transcript-compacted` (o que a compactação resumiu, recolhido numa faixa com "Mostrar"), `transcript-failed`, `transcript-retry`, `transcript-find` (a barra ⌘F aberta sobre o começo da conversa), `transcript-edit` (a primeira mensagem de volta no campo, em edição), `transcript-attachments` (uma, duas, cinco e doze imagens, arquivos longos, ausente e antigo), `transcript-outputs` (arquivo novo, alterado e captura sob a linha da ferramenta), `transcript-tools` e `transcript-tools-open` (ações seguidas recolhidas numa linha, com um aviso e uma falha no meio; e abertas), `transcript-work` e `transcript-work-open` (o mesmo pedido terminado: o trabalho numa linha acima da resposta), `chat-long-draft` (mensagem maior que o campo, que rola) |
| Contexto | `context-meter`, `context-nudge`, `context-popover`, `context-popover-result`, `context-popover-short`, `settings-context` |
| Ajustes | `settings-general`, `settings-profile` (Geral com um perfil de exemplo e foto desenhada na hora), `settings-reset` (a folha "Redefinir o Orb?"), `settings-models`, `settings-usage` (um mês de uso de exemplo escrito na pasta de dados; `-usagePeriod today\|week\|month30\|thisMonth` e `-usageChartBy model`, antes de `--snapshot`, escolhem outra vista sem salvar nada), `settings-usage-empty` (sem exemplo: mostra o que a pasta tiver), `settings-perms`, `settings-perms-tested` e `settings-perms-stale` (linhas fixas depois do "Testar" e com a gravação de tela esperando reabrir), `first-run-banner`, `models` |
| Barra de menus | `quickask`, `quickask-approvals`, `quickask-reply` |
| Rotinas e conversas | `routines`, `routine-editor`, `routine-editor-new`, `routine-run`, `routine-run-failed`, `routine-conversation` |
| Skills e conectores | `skills`, `skills-explore`, `skill-editor`, `skill-editor-new`, `skill-preview`, `skill-preview-installed`, `connectors` (instalados), `connectors-gallery`, `connectors-explore`, `connectors-lazy`, `conn-tools`, `conn-signin`, `conn-needs-signin`, `conn-editor-notion`, `conn-google-intro`, `conn-google-account`, `conn-google-account-agenda`, `conn-google-denied`, `conn-google-working`, `conn-google-done`, `conn-editor-supabase`, `conn-editor-github`, `conn-editor-files`, `conn-editor-slack`, `conn-editor-manual`, `conn-editor-edit`, `conn-editor-edit-registry`, `conn-editor-connecting`, `conn-editor-connected`, `conn-editor-failed`, `conn-editor-retired-slack` |

Com `ORB_SEND`, o snapshot envia o prompt e espera `ORB_SNAPSHOT_WAIT` segundos antes de fotografar. Para medir o streaming sem
abrir janela, use o modelo falso com `--long`, `ORB_SEND` e `ORB_SNAPSHOT_WAIT=40` e observe o processo (`ps -o %cpu=`,
`sample`).

### Scripts

| Script | O que faz |
|---|---|
| `scripts/bundle.sh [debug\|release]` | compila (padrão `release`), monta `build/Orb.app` (executável, `Resources/Orbs`, `Info.plist` com `app.orb.mac`, `NSAllowsArbitraryLoads` (sem isso o macOS bloqueia `http://` no app empacotado) e os textos de permissão de Agenda (`NSCalendarsFullAccessUsageDescription`), Lembretes (`NSRemindersFullAccessUsageDescription`) e Apple Events, ícone gerado pelo próprio app) e assina |
| `scripts/make-signing-identity.sh` | cria uma vez o certificado local "Orb Local" no chaveiro de login e o marca como confiável para assinar |
| `scripts/fake-llm.py` | o modelo falso acima |

A arte (camadas dos Orbs) tem o seu próprio gerador, descrito em [art/README.md](../art/README.md).

## Pendências de arquitetura

Duplicações conhecidas que ficaram para depois:

- **Fluxo de aprovação.** O trecho que abre o `ApprovalGate`, emite `.approval` e `.status`, espera e resolve a resposta
  (`.deny`/`.review`/`.task`/`.always`/`.once`) existe duas vezes (`AgentEngine`), e a frase
  "Esperando sua resposta" é repetida em vários arquivos, com `WorkLine` comparando o texto. A ideia é uma função só em
  `ApprovalGate` e uma constante para a frase. Não foi feito ainda.

## Como estender

- **Nova ferramenta.** Um `struct` que implementa `AgentTool` (`spec`, `kind`, `capability`, `risk`, `summary`, `run`; `danger`
  se alguma chamada é destrutiva), na lista da família em `ToolBox` (`fileTools`, `shellTools`…). Decida a **família de
  permissão** em `PermissionPolicy.family(ofTool:kind:)` (sem isso ela cai pelo `kind`) e o `legacyRule` se precisar. Uma
  que muda o estado do app precisa de um jeito de chegar até ele (veja `schedule`: um fecho em `ToolContext`). Com os modelos do Claude Code a ferramenta chega ao CLI
  pelo `--pipe-tools` sem trabalho extra: ele declara tudo o que o motor oferece naquele turno. Texto
  da ferramenta para o modelo em inglês, curto (cada palavra é cobrada em toda requisição); título e detalhe para o usuário em português.
- **Novo provedor.** Um `case` em `ProviderKind` com `label`, `summary`, `defaultBaseURL`, `keyPage`, `shortName`, `tagline` e
  `group`; a lista de modelos em `ModelCatalog.fetch`; o formato de cada modelo decide o cliente (`ProviderAccount.client`).
- **Novo campo persistido.** Valor padrão na decodificação tolerante; nunca renomeie nem remova uma chave sem migração.
- **Nova tela para revisar.** Um `case` em `Snapshot.render` (ou em um dos auxiliares), com dados de exemplo, nunca reais.
- **Novo comando de teclado.** Nome em `CommandName`, tecla em `AppShortcut` (o teste confere que nenhuma tecla se repete),
  item em `AppCommands`, linha em `ShortcutCatalog` e, se couber, entrada na paleta (`PaletteBuilder`).
