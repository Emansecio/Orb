# Arquitetura

Para quem vai mexer no código do Orb. App nativo em SwiftUI, Swift 6 (`swift-tools-version: 6.0`, concorrência estrita),
macOS 14+, um pacote SwiftPM com o app inteiro numa biblioteca (`Orb`, `Sources/Orb`), o executável que só chama `Launcher.main()` (`OrbMain`, `Sources/OrbMain`, produto `Orb`), o ajudante do Keychain (`OrbKeychainHelper`), um app de fixture só para o smoke de Acessibilidade (`OrbAXFixture`, `Tests/OrbAXFixture`) e um alvo de testes (`OrbAppTests`). O app é biblioteca para o `swift test` compilá-lo uma vez só: um alvo executável importado pelos testes é compilado duas vezes (produto e módulo "testable"), o que dobrava o tempo de cada mudança. Não há
dependências externas: SQLite, ImageIO, Vision, Network, CryptoKit e o resto vêm do sistema. A única exceção é de recursos, não de pacotes: `Sources/Orb/Resources/Rich` leva `mermaid` e `katex` com versão e hash fixos (`VERSIONS.md`, `scripts/vendor-rich.sh`), para desenhar sem rede.

Documentos irmãos: [CONTEXTO.md](CONTEXTO.md) (janela, compactação, economia de tokens), [PERMISSOES.md](PERMISSOES.md),
[MEMORIA.md](MEMORIA.md), [ORBS.md](ORBS.md) (avatar e animação), [MOVIMENTO.md](MOVIMENTO.md) (especificação de movimento da
interface), [FERRAMENTAS.md](FERRAMENTAS.md) (ferramentas do motor), [COLABORACAO.md](COLABORACAO.md) (Orbs juntos),
[PERSISTENCIA.md](PERSISTENCIA.md) (dados em disco), [TESTES.md](TESTES.md) e [DESENVOLVIMENTO.md](DESENVOLVIMENTO.md)
(argumentos, variáveis de ambiente, `--snapshot` e scripts).

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

### Índice por responsabilidade

Por onde começar em cada área. Os caminhos de código abreviados são relativos a `Sources/Orb/`. Caminhos iniciados por `Sources/`, `Tests/`, `docs/`, `scripts/`, `art/` ou `.github/` partem da raiz do repositório; `Package.swift`, `README.md` e `AGENTS.md` também ficam na raiz.

| Categoria | Onde procurar | Responsabilidade |
| --- | --- | --- |
| Inicialização e configuração do pacote | `Package.swift`, `Sources/OrbMain/main.swift`, `Sources/Orb/OrbApp.swift`, `DevRun.swift` | Alvos, janela, menus, entrada do app e modos de desenvolvimento. O app é a biblioteca `Orb`; o executável `OrbMain` só chama `Launcher.main()`. |
| Estado e execução de cada Orb | `AppModel.swift`, `AppModel+*.swift`, `BotSession.swift`, `BotSession+*.swift`, `BotLive.swift` | Orquestração, eventos de turno, estado observado pelas telas e operações por tema. Prefira a extensão da área afetada. |
| Conversa e apresentação de atividades | `LiveText.swift`, `ToolTally.swift`, `ToolIntent.swift`, `WorkLine.swift`, `MultiOrb/TranscriptFolding.swift`, `Views/ChatView.swift`, `Views/TranscriptViews.swift` | Streaming, agrupamento por pedido e etapa, resumos de ações, status e expansão. `TranscriptFolding` decide os grupos; as views os apresentam. |
| Interface e identidade visual | `Views/`, `Theme.swift`, `Motion.swift`, `Shortcuts.swift` | Chat, compositor, painel, ajustes, estilos, movimento e atalhos. `Views/Multi/` contém colaboração; `Views/Groups/`, conversas em grupo. |
| Catálogos e buscas na interface | `Views/CatalogParts.swift`, `Views/ConnectorGalleryView.swift`, `Views/ConnectorsView.swift`, `Views/SkillsView.swift`, `Views/MarketplaceGallery.swift`, `Catalog/BrandGlyph.swift` | Busca compartilhada, estados de carga, cards, ferramentas e marcas. O catálogo de dados fica em `Catalog/`; filtros e layout pertencem às views. |
| Folhas, campos e seleção de modelos | `Views/SheetKit.swift`, `Views/SharedControls.swift`, `Views/ModelPicker.swift`, `Views/ModelPopover.swift`, `Views/ProviderSettings.swift` | Molduras e rodapés, edição de nomes, foco, listas de modelos e configuração dos provedores. Reuse os controles existentes. |
| Motor e provedores | `Engine/` | Loop do agente, clientes de modelos, eventos, plano, prompt, contexto, compactação e política de permissões. `Engine/ClaudePipe/` integra o CLI Claude Code. |
| Ferramentas e controle do computador | `Engine/Tools/`, `MacPermissions.swift` | Terminal, arquivos, web, Acessibilidade, automação de apps, captura e passagem do controle. |
| Navegador e conectores | `Engine/Browser/`, `Engine/MCP*.swift`, `Engine/ConnectorGateway.swift`, `AppModel+Browser.swift`, `AppModel+*Connector*.swift` | Sessões e abas, instalação do navegador, ferramentas MCP, autenticação e conectores locais. |
| Tela ao vivo | `LiveScreen/`, `BotSession+LiveScreen.swift` | Frames, fonte do navegador, transmissão, prévia, histórico visual e intervenção da pessoa. Não confundir a apresentação da tela com a execução das ferramentas em `Engine/`. |
| Persistência e segredos | `Models.swift`, `Store.swift`, `StoreCoordination.swift`, `ConversationCoding.swift`, `ConversationHistory.swift`, `InicioHistory.swift`, `LegacyMigration.swift`, `Sources/OrbKeychainHelper/` | Tipos persistidos, JSON, histórico, migrações e acesso estável ao Keychain. Campos novos precisam de defaults e decodificação tolerante. |
| Memória | `Memory/`, `AppModel+Memory*.swift`, `AppModel+SessionNotes.swift`, `AppModel+ChunkSummaries.swift`, `Views/MemoryViews.swift`, `Views/InspectorSupport.swift`, `Views/Groups/GroupBoardView.swift` | Recuperação e consolidação no modelo; agrupamento, filtros e cache de busca em `MemoryGroups`/`FoldedTextCache`; apresentação nas views de memória e quadro do grupo. |
| Colaboração | `MultiOrb/`, `Groups/`, `MultiOrb/AppModel+Delegation.swift` | Mensagens e delegação entre Orbs, pedidos paralelos, grupos e seus estados. O agrupamento visual do transcript também fica em `MultiOrb/TranscriptFolding.swift`. |
| Rotinas e agendamento | `AppModel+Schedule.swift`, `AppModel+RoutinesUI.swift`, `RoutineGoal.swift`, `CronExpression.swift`, `RoutinePrecheck.swift`, `RoutineFollowUps.swift`, `RoutineWake.swift`, `Engine/Tools/ScheduleTool.swift`, `Views/RoutinesView.swift` | Criação, execução, repetição, pré-checagem, acompanhamentos, despertar por sinal externo, relatórios e apresentação das rotinas. Confira os nomes existentes com `rg` antes de criar arquivos. |
| Catálogos, importação e criação | `Catalog/`, `Import/`, `Wizard/` | Skills e conectores disponíveis, importação de outros assistentes e assistente de criação de Orb. |
| Avatares e arte | `Orbs/`, `Resources/Orbs/`, `AppIcon.swift`, `art/` | Modelos, animação, renderização dos avatares e ícone. `art/orbgen/` e `art/orbkit/` são ferramentas de geração; veja `art/README.md` antes de regenerar recursos. |
| Uso e custos | `Usage/` | Registros, preços de modelos, agregação e relatórios de consumo. |
| Ditado e anexos | `Dictation/`, `AppModel+Dictation.swift`, `ImageAttachments.swift`, `AttachmentInfo.swift`, `Views/Attachment*.swift` | Microfone, transcrição, imagens, arquivos anexados e arquivos produzidos. |
| Redefinição de dados | `Reset/`, `AppModel+Reset.swift` | Plano de redefinição, execução e relançamento. |
| Testes | `Tests/OrbAppTests/`, `Tests/OrbAppTests/TestSupport/`, `Tests/OrbAXFixture/` | Suítes por tema, fakes e sincronização compartilhados; app separado para smoke de Acessibilidade. |
| Scripts e CI | `scripts/`, `.github/workflows/` | Bundle e assinatura, modelo falso, capturas do README e verificações de CI. |
| Documentação e referências | `docs/`, `README.md`, `AGENTS.md` | Arquitetura, manual e documentos por tema (a lista está na seção "Documentação" de `AGENTS.md`). `docs/historico/` guarda os relatórios datados: valide no código. `docs/mocks/` e `docs/readme/` contêm referências visuais. |

As subseções seguintes detalham arquivo por arquivo. Tudo em `Sources/Orb/`.

### Aplicativo e estado

| Arquivo | Papel |
|---|---|
| `OrbApp.swift` | `Launcher` (`@main`: com `--pipe-tools` roda só o servidor que declara as ferramentas ao CLI, sem janela), `OrbApp` (janela, Ajustes, barra de menus), `AppDelegate`, `AppCommands` (menu "Orbs"), `OrbSheet` (`--render-orbs`), `Snapshot` (`--snapshot`) |
| `AppIcon.swift` | o ícone do app (`--render-icon`): CoreGraphics puro, desenhado direto em cada tamanho na grade do macOS (ladrilho de 824 em 1024, sombra padrão; desde o macOS 26 o sistema põe qualquer outro formato num quadrado cinza), ladrilho grafite sem filete na borda (o macOS 26+ já desenha um reflexo claro na borda de todo ícone, e um filete nosso o deixava mais forte que nos outros), Orb índigo chapado com olhos em pílula e um anel inclinado que passa pela frente e continua, mais apagado, por trás (o único degradê, nas pontas do anel); o traço do anel engrossa nos tamanhos menores, e em 16 px sai o Orb sozinho, maior |
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
| `Phone/PhoneWire.swift`, `Phone/PhoneNetwork.swift`, `Phone/PhoneServer.swift`, `Phone/PhoneAccess.swift`, `Views/PhoneSettings.swift` | acesso pelo celular (`docs/CELULAR.md`): quadros JSON e a conversão dos itens do chat; quem pode entrar (só Tailscale e loopback), token, link do QR e limite de tentativas; o servidor WebSocket (`Network.framework`, na fila principal); a ponte com o `AppModel` (lista e conversa observadas com `withObservationTracking` e enviadas só quando mudam, envio como o painel rápido, cartões, avatares em PNG) e Ajustes → Celular. O app Android fica em `android/` |
| `ContextGauge.swift`, `MarkdownBlocks.swift`, `MenuBarSupport.swift`, `Shortcuts.swift`, `Motion.swift`, `Theme.swift` | palavras e leitura do medidor; blocos de Markdown (com `.image`: `![…](/caminho)` numa linha só, arquivo do Mac, nunca endereço da web); ícone da barra de menus e atalho global; nomes e teclas dos comandos e o catálogo de atalhos (folha, Ajustes e paleta leem a mesma lista); vocabulário de curvas; paleta, estilos de botão e brilho, e a escala de espaçamento (`Spacing`: 2/4/8/12/16/20/24, borda das folhas, folga entre botões; `ControlHeight`: 30 normal, 24 compacto, 44 hero; `.controlSize(.small)` torna as pílulas compactas; `hangsOnLeadingEdge()` alinha o texto de um botão fantasma no início de uma linha com o conteúdo) |

### Motor (`Engine/`)

| Arquivo | Papel |
|---|---|
| `EngineTypes.swift` | contratos: `JSONValue`, `ChatMessage`, `LLMClient`/`LLMEvent`/`LLMError`, `TokenUsage`, `CacheHealth`, `AgentTool`, `ToolRisk`, `ToolContext`, `MCPServerConfig` |
| `AgentEngine.swift` | o laço do turno: modelo ↔ ferramentas, sem limite de passos no turno do chat (vai até o modelo responder ou você parar; o assistente de criação e a revisão de skills têm limite próprio), retentativas, cortes por limite, grupos de aprovação, `TurnEvent`/`TurnRequest` |
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
| `Tools/ConnectorInstallTool.swift`, `AppModel+ConnectorInstall.swift` | `connector_install`: o Orb instala um conector (sempre com cartão de aprovação, até no Automático). `ConnectorInstallRequest` valida a chamada; o app grava como o formulário (`connectors`, segredos no Keychain), liga a chave Conectores do Orb, sobe o servidor (`connectAndWait`) e devolve as ferramentas; um que não sobe é retirado. O `ConnectorRoster` do turno recebe o conector, e `connector_call` já o alcança no mesmo turno (a descrição de `connector_tools` não muda). Fora de execuções laterais (`multi.sideRun`) |

### Ferramentas (`Engine/Tools/`)

As famílias de ferramentas (terminal e arquivos, web e navegador, apps do Mac, agenda, conectores), os limites de cada uma e o que
acontece com processos, codificação de texto e erros: [FERRAMENTAS.md](FERRAMENTAS.md).

### Trabalho de programação

O que deixa um Orb (ou um grupo) programar, testar e entregar sem cliques além do primeiro:

- **Acesso pelo chat (`request_access`, `Engine/Tools/AccessTool.swift`, `AppModel+Access.swift`, `Views/Multi/AccessCard.swift`).**
  Só no chat do próprio Orb. O cartão "Liberar / Agora não" usa o caminho do `orb_propose` (`ApprovalRequest.access`,
  `ApprovalGate.requestAccess`, `alwaysAsks` e `isHandoff`), e "Liberar" aplica capacidades, Automático e pasta por `AppModel.update`.
  Como as ferramentas são fixadas no começo do turno, o turno que pediu termina e o app manda a continuação uma vez
  (`BotSession.accessGranted`, `resumeAfterAccess`, no molde de `showJobs`). Detalhes em [PERMISSOES.md](PERMISSOES.md).
- **Critério de aceite (`TaskPlan.criteria`).** `task_plan set` aceita `done_when` (até 6) e `update` aceita `checks` (`met` exige
  `evidence`). No fim do turno, depois do `CompletionWatch`, `PlanReminder.unmetCriteria` lembra os critérios que faltam quando a
  resposta diz que acabou. O `CompletionWatch` também lembra de rodar o check de novo quando houve `write_file`/`edit_file`
  depois do último check que passou.
- **Fim do plano (`TaskPlan.isActive`).** O plano só acompanha a conversa (prefácio, recital, anel, pulso) enquanto tem etapa
  aberta e não foi deixado de lado. `finishTurn` conta em `passedOver` os turnos do chat que terminaram com o plano aberto e
  intocado; em `passedOverLimit` (3) ele sai de cena, guardado como estava, e um `update` o traz de volta. O pulso que retoma um
  plano e responde NOTHING sem tocá-lo também o deixa de lado (`finishPulse`). A ferramenta aceita o que os modelos mandam de
  fato: sem `action` (deduzida dos campos), `list`/`get` (lê o plano, `show`), `done`/`complete` (fecha todas as etapas) e os
  estados `completed` e `met` (`TaskPlan.Action.of`, `State.named`).
- **Revisão no grupo (`Groups/GroupReview.swift`).** O prompt do orquestrador manda definir `done_when`, construir com um membro,
  revisar com outro (até 3 rodadas) e dar o veredito na resposta final. O revisor começa com `APPROVED` ou `CHANGES:`;
  `ReviewVerdict.read` conta a rodada (`GroupRun.round`, `verdict`), põe "Revisão: …" no fio e na página da sessão do quadro.
- **Pasta do projeto e worktrees (`MultiOrb/WorkFolders.swift`, `Groups/GroupHub+WorkFolders.swift`).** `OrbGroup.projectFolder`
  (por `group_create folder`) e `OrbEnvelope.folder` (por `orbs ask folder`). Num repositório git, cada membro ganha um worktree em
  `<dados>/trabalho/<projeto>-<hash>/<membro>-<execução>` no ramo `orb/<membro>/<execução>`; o orquestrador fica no checkout
  principal e faz o merge. A pasta entra só na cópia do `Bot` do turno (`AppModel.send(workFolder:)`), então `ToolContext`,
  snapshot, instruções da pasta, prompt e `ownFolder` a veem sem mudar o Orb salvo. No fim da execução do grupo, o que já entrou
  no HEAD é removido sem `--force`; o resto fica, com aviso no fio.
- **Trava de escrita velha (`Engine/Tools/FileStamps.swift`).** Por Orb, até 500 caminhos: depois de ler ou gravar, guarda data e
  tamanho; `write_file`/`edit_file` recusam quando o arquivo mudou desde então (outro Orb ou você).

### Orbs juntos (`MultiOrb/`, `Groups/`)

As ferramentas de delegação e de grupo (`orbs`, `group_create`, `group_edit`, `group_recall`, `orb_propose`, `orb_delete`),
os pedidos e os grupos: [COLABORACAO.md](COLABORACAO.md).

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
(`stepsSinceSkill`, de passos do modelo, e `reviewSince`, onde ele começou), o pedido guardado (`reviewBase`, com `reviewFrom`) e a tarefa (`skillReview`) ficam no `BotSession`.

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
| Conversa | `FindViews` (a barra de busca e a lista de resultados), `CodeHighlight` (na raiz de `Sources/Orb/`: as cores do código em uma passada sobre os bytes, por `Grammar` ou leitor próprio, fora da main e guardadas no `MarkdownCache`; `EditDiff` colore a mudança de um `edit_file`), `JumpToEnd`/`AwayFromEnd`/`JumpToEndButton` (em `ChatView`: a volta ao fim, com o que chegou), `NewItemsLine` (o divisor "Novas", de `OrbTranscript.newFrom`), `RequestRail`/`PlanCard`/`TurnTrailView` (o trilho de pedidos, o cartão do plano e, sob a última resposta do turno, o `TurnTrail`: fontes e mudanças lidas das chamadas de ferramenta), `PathLinks` (caminhos que existem viram link, com o disco consultado fora da main), `ChartSpec`/`ChartBlockView` (fence `chart`, com Swift Charts), `RichRenderer`/`RichDisk` (Mermaid e KaTeX num `WKWebView` escondido; a linha só mostra a imagem em cache), `PageSandbox` (o único jeito de criar uma página: sem armazenamento, com `WKContentRuleList`, CSP antes do texto e nenhuma navegação depois da primeira), `RichBlockViews` (moldura dos blocos ricos, `EnlargedBlockSheet`, página viva só na folha), `SideQuestion`/`SideQuestionSheet` (pergunta lateral: sem ferramentas, fora do histórico, uso `auxiliary`), `TranscriptViews` (`TranscriptRow` Equatable, ferramentas, `ApprovalCard`, `WorkingLine`), `MarkdownBlockViews`, `SelectableProse` (parágrafos, títulos, listas e citações seguidos de uma resposta num `NSTextView` só leitura, para a seleção atravessar todos; código, tabelas e linhas ficam em views próprias; a cópia sai com "• " e quebras, sem as tabulações), `QueuedMessages`, `ImageThumbnails`, `AttachmentViews` (`AttachmentStack` e `FileCard`, o mesmo componente na bolha, na fila, no compositor e sob a linha da ferramenta; `AttachmentGrid`, `ImageTile`, `ProducedFilesView`, cliques, menu e arrastar), `QuickLookPreview`, `ApprovalKeyboard` |
| Compositor | `ComposerView`, `ComposerChips` (menu do "+" com anexar e skills, permissões, modelo), `ComposerSupport`, `ModelPopover`, `ModelPicker`, `ContextMeterViews`, `DictationButton` |
| Ditado | `Dictation` (estado, permissão do microfone, escreve no rascunho; digitar o encerra), `SpeechCapture` (AVAudioEngine → SpeechAnalyzer/SpeechTranscriber do macOS 26, no aparelho), `DictationText` (frases do reconhecedor exato + o rascunho pontuado dele + palavras do rápido além delas), `DictationReview` (ao parar, o modelo menor do Orb ajusta o texto; travas contra resposta em vez de revisão) |
| Painel do Orb | `BotInspector` (abas Geral, Memória, Pasta e acessos, Rotinas), `InspectorSupport`, `MemoryViews`, `DeleteOrbDialog`, `PermissionConfirmation` |
| Início | `InicioView` projeta pedidos, trabalho, resultados e acompanhamentos; `InicioHistory` guarda um índice limitado de origens e o marcador de visita em `AppState`; `AppModel+Inicio` encaminha aos chats e execuções. O índice é derivado e não substitui as conversas ou as rotinas. `inicio-journal.json` mantém uma cópia limitada para recuperar entradas que não chegaram ao estado principal: a conversa é gravada antes do registro, a recuperação preserva a sequência e o cursor do estado, confere as origens conhecidas e não ressuscita entradas anteriores ao próximo número já salvo. O reset remove essa cópia. |
| Ajustes | `SettingsView` (Geral, Orbs, Modelos, Navegador, Uso, Acesso ao Mac; `OrbsSettings` reúne o que os Orbs fazem entre si e sozinhos), `ProfileSettings` (a seção "Você" e `ProfileAvatar`, que a barra lateral também usa), `ResetOrbSheet` ("Redefinir o Orb?" e o alerta), `ProviderSettings`, `ProviderPresentation`, `CustomProviderFields`, `ClaudeCodeSettings`, `MacPermissionsView`, `ContextSettings` |
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
5. **Laço** (`AgentEngine.play`, sem limite de passos no chat): entrega mensagens da fila; ajusta a janela (`ContextWindow.fit` com o
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
   da skill que o turno propôs e, se os passos do modelo com ferramentas chegaram a 10, ou a 4 num trecho com correção sua ou skill usada (e a tarefa não parou no limite), começa em segundo plano a
   revisão da conversa (`reviewSkillsIfDue`: mesmo pedido e histórico do turno, só `recall`/`remember` skill, cancelada por qualquer
   mensagem e por redefinir; o prompt da revisão só orienta o turno, `promptOnlySteers`, então as saídas do turno seguem inteiras
   como na última chamada dele; com 5 propostas esperando, a revisão nem chama o modelo).

## Persistência

Arquivos de dados, retomar sozinho, "Redefinir o Orb", uso e custos, decodificação tolerante, convenção de `init` e filas
de gravação: [PERSISTENCIA.md](PERSISTENCIA.md). Regra que vale em todo campo novo: valor padrão na decodificação;
renomear ou remover chave exige migração.

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
  A primeira mensagem da execução leva no topo `<orb_recent_chat>` (`RoutineBackground`, via `outsideContext`): o trecho do
  chat estacionado depois de `memorySavedCount` (pedidos, respostas e ações, mais recentes primeiro até 3.000 caracteres,
  segredos removidos). O que já virou página de sessão chega pelo "onde paramos" e pelas notas relacionadas.
  Cada execução continua o histórico do modelo das anteriores (`Conversation.startingRoutineRun` guarda mensagens, resumo e
  sessão; `prepareHistory` dobra o histórico como no chat, e as mensagens já cobertas pelo resumo saem do arquivo da rotina):
  o `RoutinePrompt` repete as instruções e a tarefa e diz para aproveitar o que já foi lido. Só uma execução sem histórico
  (a primeira, ou um arquivo perdido) recebe o último relatório, até três outros registros recentes e, de `RoutineActivity`,
  até 12.000 caracteres de ações, respostas e avisos da execução anterior. O pulso começa do zero a cada vez
  (`forgettingContext`). O relatório é
  orientado a carregar os acompanhamentos abertos para a próxima execução; cada relatório armazenado tem até 8.000 caracteres.
  `routine_follow_up` mantém um item aberto por contato (`RoutineFollowUp.contact`, o telefone ou e-mail do canal, nunca do
  assunto, onde um lote cita um lead entre outros) e `collapse` resolve os gêmeos mais antigos a cada chamada.
  `update` e `resolve` acham o item pelo id ou pela mesma identidade (`sameness`: contato ou assunto). `RoutineFollowUp.list`
  entrega os 50 mais recentes; numa lista maior, os 10 parados há mais tempo (`lastMoved`) ocupam as últimas vagas, e todo item
  sem movimento há `quietAfter` (7 dias) vai marcado com os dias, para o modelo concluir ou atualizar.
  `runDueRoutines` pula, como a pré-checagem, um horário que `Routine.missedSlot` acha vencido pelo próprio ritmo da agenda.
- Um turno de outra conversa do mesmo Orb (a que você deixou com ele trabalhando, ou a que pediu algo a outro Orb e recebeu a
  resposta) usa o mesmo estacionamento: `workingChatID` é a conversa do turno, em `conversation`, e a que está na tela fica em
  `parkedChat` até o turno acabar (`BotSession.workElsewhere` / `endWorkElsewhere`). `conversationChat` diz qual conversa está em
  `conversation` (nil durante rotina, pedido ou grupo). O envelope de um pedido guarda a conversa que pediu (`OrbEnvelope.chat`) e
  a resposta volta para ela; avisos, rotinas, processos e grupos vão para a mais recente (`AppModel.latestChat`). O que muda numa
  conversa fora da memória vai direto ao arquivo, na fila de gravação (`BotSession.changeChat` → `Store.amend`); uma leitura que
  estava a caminho é refeita (`AppModel.readChat`, contador `amends`), para nunca instalar uma cópia mais velha.
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

Como rodar a suíte e as suítes afetadas, as flags dos testes de Acessibilidade, internet e
navegador real, e o modelo falso para uso manual: [TESTES.md](TESTES.md).

## Ferramentas de desenvolvimento

Argumentos, variáveis de ambiente, modos de `--snapshot` e scripts: [DESENVOLVIMENTO.md](DESENVOLVIMENTO.md).

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
- **Novo bloco de resposta.** Um `case` em `MarkdownBlock`, lido em `richBlock` só com o fence fechado (aberto, ele fica `.code` e troca uma vez), texto puro em `plainText` e vista em `MarkdownBlockView`, com `RichBlockFrame`. O desenho nunca é salvo: a resposta guarda o Markdown. Web só por `PageSandbox`, e fora do `LazyVStack`. Texto novo no prompt é fixo (`SystemPrompt.richReplies`).
- **Nova ferramenta multi-Orb.** Além da receita acima: o `struct` fica em `Engine/Tools/` mas entra por `MultiOrbOffering`, não em `ToolBox.all`; a ação nova vai ao `DelegationHub` pelo `action` de `ToolContext.orbs` (uma ação `…_plan` quando há cartão: o app confere, a ferramenta pergunta por `context.confirm` e só então confirma). Preferência nova em `AppModel+MultiOrbSettings`, com padrão e linha em Ajustes → Orbs.
- **Novo campo persistido.** Valor padrão na decodificação tolerante; nunca renomeie nem remova uma chave sem migração.
- **Nova tela para revisar.** Um `case` em `Snapshot.render` (ou em um dos auxiliares), com dados de exemplo, nunca reais.
- **Novo comando de teclado.** Nome em `CommandName`, tecla em `AppShortcut` (o teste confere que nenhuma tecla se repete),
  item em `AppCommands`, linha em `ShortcutCatalog` e, se couber, entrada na paleta (`PaletteBuilder`).
