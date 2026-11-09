# Ferramentas (`Engine/Tools/`)

Parte do mapa do código: veja [ARQUITETURA.md](ARQUITETURA.md) para a visão geral.


`ToolBox.all` = `shellTools + fileTools + webTools + searchTools + browseTools + macTools + memoryTools + scheduleTools`; cada família lista as suas no próprio arquivo.
`ToolBox.offered(for:accessibilityGranted:browser:)` filtra por capacidade do Orb, esconde `ui_read`/`ui_act` sem Acessibilidade e as `browse_*` sem o navegador instalado (`BrowserAvailability.browser`).

| Capacidade | Ferramentas | Arquivos |
|---|---|---|
| Terminal e arquivos | `run_command` (`background: true`; saída acima de 20 KB é salva inteira em `saidas/<orb>/comando-….txt`), `job_output` (sem `id`, lista todos), `job_stop`, `read_file` (texto, PDF, Word/RTF/ODT, Excel .xlsx e .xls, PowerPoint .pptx, imagens com OCR), `write_file`, `edit_file`, `list_directory`, `search_files` (Spotlight), `grep` (um arquivo informado em `path` vai até 200 MB, em streaming), `glob` (aceita padrão absoluto), `trash` (também com Controlar apps); o ambiente vem do shell `-lic` da usuária (5 s) e, se ele estoura, o perfil de login responde na hora e a nova tentativa roda em segundo plano (15 s), com espera que dobra de 30 s até 5 min | `ShellTool`, `BackgroundJobs`, `CommandRelease`, `ProcessRunner`, `ShellEnvironment`, `FileTools`, `SearchTools`, `TextFile`, `DocumentReader`, `OfficeReader`, `LegacyExcelReader`, `ReadOnlyCommand` |
| Navegar na web | `web_fetch` (páginas, PDF, JSON, imagens; `offset`/`find` para páginas longas; `save_to`), `web_search` (DuckDuckGo, Google, TinyFish), e com o navegador instalado `browse_open/snapshot/read/screenshot/click/fill/select/press/scroll/back/tabs/show/close` e, no `BrowseMoreTools`, `browse_wait/find/dialog/files/page/run`, `browse_proxy` (`BrowseProxyTool`, `BrowserProxy`; o proxy é `Bot.browserProxy` sem a senha, que fica no `SecretVault` na conta `BrowserProxy.keychainAccount` (`AppModel.saveBrowserProxy`/`browserProxy(of:vault:)`); vai ao `BrowserHub.setProxy` no começo de cada turno e ao agent-browser pela variável `AGENT_BROWSER_PROXY` (nunca em argv), com só um hash na impressão digital do lançamento, e a sessão com outro proxy é trocada; os erros passam por `BrowserProxy.redacting`; `BrowserAccess.scope` é o id da conversa e dá a ela uma aba própria: `BrowserSession.scoped` e o `TabBook` (por geração do navegador, `BrowserDriver.generation`) trocam de aba dentro do `exclusive` só quando muda quem chama, `browse_tabs` só vê as abas da conversa, `AppModel.endBrowserConversation` fecha a de uma rotina ou pedido que terminou (com proxy com login a aba fica, como sobra) e `relaunchKeepingTabs`/`restoreTabs` reabrem as páginas depois de trocar o proxy ou o modo; `BrowserProfileCache` limpa os caches do perfil uma vez por semana, com o navegador fechado no hub e no `SingletonLock` do perfil) (`BrowserDriver.command` e `manual`; as regras do `browse_run`, o que recusa, o risco e os arquivos, ficam em `BrowseRunRules`) | `WebTools`, `HTMLText`, `WebSearchTool`, `BrowseTools`, `Engine/Browser/` |
| Controlar apps do Mac | `applescript`, `shortcuts_list/run`, `clipboard_read/write`, `screenshot` (janela com marcas numeradas e OCR), `apps_list`, `app_quit`, `trash`, `browser_tab`, `ui_read`, `ui_act` | `MacTools`, `MacAppTools`, `BrowserTools`, `ScreenshotTool`, `WindowCapture`, `UIMarks`, `SyntheticInput`, `AccessibilityTools`/`Elements`/`Outline`/`Session`/`Events`/`Contracts`, `ScreenTakeover`, `AppleScriptSupport` |
| Sempre | `open`, `notify`, `remember`, `recall`, `schedule`, `connector_install` (menos em execução lateral) | `MacTools`, `MacAppTools`, `ScheduleTool` |
| Conectores | `connector_tools`, `connector_call` (fora de `ToolBox.all`, montadas por turno); `connector_install` vai para todo Orb, menos em execução lateral | `ConnectorGateway`, `MCPTool`, `ConnectorInstallTool` |

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
levando 20) conta a próxima a partir do fim dela (`finishRoutineRun`), então nada se acumula. Fora do agendador, `wake/<nome>.wake` na
pasta de dados acorda a rotina na hora (`RoutineWake`: a pasta é vigiada por um descritor, o arquivo é consumido ao ser lido, o seu texto vira
o motivo na conversa da execução; a fila, a pré-checagem e a pausa valem como na agenda). A mesma falha duas vezes seguidas vira banner uma
só vez (`RoutineRun.isNews`).

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

