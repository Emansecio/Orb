# Uso do computador em segundo plano — desenho

Os Orbs operam apps **sem tomar a tela** de quem usa o Mac: sem roubar o foco, sem mover o cursor real e sem digitar no
foco do usuário. Este documento é o contrato da implementação (pacotes WP0, WP-A, WP-B, WP-C) e o que a revisão confere.

## 0. Problemas do código atual que este desenho corrige

1. `LiveAccessibilitySystem.root(of:)` chama `AXUIElementSetMessagingTimeout(ref, 2)` achando que vale para os filhos; o
   header (`AXUIElement.h`) diz que vale só para aquele objeto (o global é no elemento system-wide). Cada filho de um app
   travado espera o padrão (~6 s).
2. `attributes()` engole `.cannotComplete` (volta `[:]`) e a leitura segue com o app travado até o relógio de 20 s.
3. `ui_act` rouba o foco: `pick_menu`/`show_menu` chamam `system.activate` (`NSRunningApplication.activate()`, cooperativa
   e pouco confiável desde o 14) e o fallback de `focus` usa `AXRaise`.
4. `ui_act` sem `app` age no app da frente (`UIAppResolver`) — o app em que o usuário está.
5. IPC bloqueante no pool cooperativo (`runDetached`): vários Orbs ou um app travado esgotam o pool.
6. Espera fixa de 300 ms (`settle`) depois de cada ação; nenhuma notificação AX é usada.
7. O servidor MCP stdio que então servia as ferramentas do Orb ao Claude Code, atendia uma requisição por vez
   na thread do stdin, não tratava `notifications/cancelled` e só via o EOF quando a ferramenta terminava: parar o turno não
   interrompia uma espera longa. (Hoje as ferramentas rodam no motor do Orb, em processo, e param com a tarefa do turno, também com o
   Claude Code.)
8. `screenshot` usa `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` (não acha janelas em outro Space), pega a primeira
   janela da lista e não a janela AX, e chama `CGRequestScreenCaptureAccess()` a cada captura enquanto falta permissão.
9. O teto de caracteres das specs (`ToolSpecEconomyTests`) está praticamente cheio — conflito com o navegador.

## 1. Escada por ação

- **N0 — AX, silencioso.** Acessibilidade pura.
- **N1 — evento ao pid.** `CGEvent.postToPid`: não move o cursor nem toca o foco do usuário.
- **N2 — assumir a tela.** Só com consentimento: traz o app, usa mouse e teclado reais, depois devolve app da frente e cursor.

Cada degrau só é tentado se o anterior não for suportado ou não produzir efeito observável (diff de estado ou notificação
AX). N2 nunca é automático.

| Ação | N0 (AX) | N1 (evento ao pid) | N2 / ressalvas |
|---|---|---|---|
| Ler árvore | `AXUIElementCopyMultipleAttributeValues` com `AXChildren` e `AXPosition` no mesmo lote; funciona coberta, em outro Space, minimizada, app oculto. Electron: `AXManualAccessibility=true` e nova tentativa após 300 ms se vier < 3 filhos. Nunca `AXEnhancedUserInterface`. | — | Canvas/jogos: árvore vazia → screenshot + OCR. |
| Pressionar | `AXPress`, depois `AXConfirm`/`AXPick`; linhas: `AXSelected`. | Clique no centro do elemento sem mover o cursor. | Folha modal aberta: AX na janela-mãe é ignorado → tratar a folha primeiro. Controles sem ação → N1 → N2. |
| Definir texto | `AXValue` substitui; `AXSelectedTextRange` + `AXSelectedText` insere no cursor. | Campos controlados por JS ignoram `AXValue` → digitar. | Campo de senha: nunca ler; preencher só com perigo. |
| Digitar | — | `CGEvent(keyboardEventSource:…)` + `keyboardSetUnicodeString` em pedaços de ≤ 20 UTF-16, `postToPid`; antes `AXFocused` no alvo e conferir `AXFocusedUIElement` do app; conferir de novo a cada pedaço. | Secure Input (`IsSecureEventInputEnabled()`) pode descartar: avisar. Chromium/jogos às vezes só com app ativo → N2. |
| Atalhos | Primeiro achar no menu o item com `AXMenuItemCmdChar`/`CmdModifiers`/`CmdVirtualKey` iguais e `AXPress` nele (independe do layout, funciona em segundo plano). | Evento com `flags` explícitos; keycode via `UCKeyTranslate` no layout atual (ABNT2 ≠ US). | — |
| Menus | `AXPress` no caminho `AXMenuBar → AXMenu → item` sem abrir o menu e sem ativar o app; menus de status por `AXExtrasMenuBar`. | — | Habilitado pode estar defasado; menus dinâmicos (Recentes, Janela, Serviços) só se preenchem abertos. Menu de contexto (`AXShowMenu`) e abrir menu são visíveis e modais → N2. |
| Rolar | `AXScrollToVisible`; `AXValue` 0…1 da `AXScrollBar`. | `CGEvent(scrollWheelEvent2Source:units:.pixel…)` na janela, `postToPid`. | — |
| Focar campo | `AXFocused=true` só no elemento. Nunca `AXMain`/`AXFocused` em janela, nem `AXRaise`. | — | Se o app se ativar sozinho: devolver o app anterior na hora e marcar o app como "rouba foco" na sessão (focar/digitar nele passa a pedir N2). |
| Listas e tabelas | `AXSelected` na linha; `AXSelectedRows`; `AXSelectedChildren`; `AXDisclosing`; combobox `AXValue`. | — | Popup (`AXPopUpButton`): tentar `AXChildren → AXMenu → item`; a maioria só expõe o menu aberto → N2. |
| Arrastar e soltar | Não há; oferecer alternativa semântica (arquivos, AppleScript). | Não funciona (`NSDraggingSession` exige HID real). | Só N2, movimento interpolado em 15 passos. |
| Clicar em coordenada | Hit-test local nos frames do snapshot (menor área que contém o ponto), confirmado por `AXUIElementCopyElementAtPosition` (usa ordem z: falha com janela coberta, por isso o local vem antes); sobe até o ancestral acionável (≤ 5 níveis) e `AXPress`. | Mouse down/up com `mouseEventClickState` e `.mouseEventWindowUnderMousePointer`/`…ThatCanHandleThisEvent` = `CGWindowID`, `postToPid`; só se a janela aceitar first mouse. | Hover/tooltips não existem em segundo plano (usar `AXHelp`) → N2. |
| Capturar janela | — | `SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow:), configuration:)` (14.0+), `ignoreShadowsSingleWindow`, `captureResolution = .nominal`, `includeChildWindows` (14.2+), `showsCursor=false`. | Coberta ok; outro Space ok (pode vir defasada); minimizada/app oculto não (oferecer `AXMinimized=false`, visível, pede cartão). Fallback `screencapture -o -l`. Nunca `CGWindowListCreateImage`. |
| Observar mudanças | `AXObserver`: `AXValueChanged`, `AXUIElementDestroyed`, `AXCreated`, `AXWindowCreated`, `AXFocusedUIElementChanged`, `AXFocusedWindowChanged`, `AXTitleChanged`, `AXSelectedChildrenChanged`, `AXSelectedRowsChanged`, `AXSelectedTextChanged`, `AXLayoutChanged`, `AXSheetCreated`, `AXRowCountChanged`, `AXLoadComplete`. | Polling a 250 ms quando `notificationUnsupported`. | Canvas: diff de screenshot 32×32 a 2 Hz, só se pedido. |

**Versões.** 14: ativação cooperativa — em N2 usar `AXFrontmost=true` no elemento do app. 15: sem
`CGWindowListCreateImage`; o macOS reconfirma Gravação de Tela periodicamente (o manual avisa). 26: não usar a captura HDR.
27: smoke roda aqui.

**Proibidas:** `_AXUIElementGetWindow`, `CGS*`, `SLS*`/SkyLight, `CGEventPostToPSN`, `AXUIElementPostKeyboardEvent`,
`CGWindowListCreateImage`. `.cghidEventTap` só dentro de N2.

## 2. Ferramentas do modelo

Evoluir `ui_read`, `ui_act` e `screenshot` (sem ferramenta nova, sem família de permissão nova; `PermissionPolicy.swift`
não muda). Manter as frases que `ToolSpecEconomyTests` exige: ui_read "Accessibility", "400 lines", "passwords",
"w1.3.2", "valid for this reading only"; ui_act "ui_read", "interface mudou", "always asks the user first", "pick_menu",
"Accessibility"; screenshot "OCR", "Screen Recording", "window".

**`ui_read`** (`.safe`): `wait` (`appears` | `disappears` | `changes`), `timeout` (padrão 5, 1–30); `appears`/`disappears`
usam `query`, `changes` usa `id` ou a janela. Espera e depois lê; acrescenta `(esperei 1,2 s: apareceu …)` ou
`(não aconteceu em 5 s)`. Orçamentos: 400 linhas, valor de 80 caracteres, 3.000 elementos visitados, teto de 14.000
caracteres (`ToolOutputBudget.fit`), relógio de 4 s sem query e 8 s com query, no máximo 2 IPC por elemento (+1 para
papéis com valor), profundidade 3 dentro de `AXWebArea` sem query (com aviso para usar o navegador).

**`ui_act`** (`.sensitive`): ações `press, focus, set_value, type, key, select, scroll, click, increment, decrement,
show_menu, pick_menu`; argumentos `keys` ("cmd+s", "return"…), `ids`, `x`/`y` (pixels do último screenshot com marcas
daquela janela), `button`, `count` (1–2), `direction`/`amount` (1–10 páginas), `wait`/`timeout` (substituem o settle
fixo), `steps` (≤ 8, param na primeira falha; schema `{"type":"object"}`), `takeover`. `id` aceita `"#12"`. `app` ausente
= app do snapshot mais novo **deste Orb**, nunca o da frente; sem snapshot, `pick_menu`/`key` exigem `app`. Saída diz o
método (`[segundo plano · AX]`, `[segundo plano · evento ao app]`, `[assumi a tela 2,1 s · devolvi ao Safari]`) + diff
(≤ 600 caracteres) + resultado do `wait`. Escalada: `ToolError` com o marcador estável `[precisa_assumir_tela]` e o motivo
("repetir pode duplicar"). Takeover: `danger()` sempre (cartão em Perguntar antes e Automático, recusa em Só leitura,
roda em Sem pedir com o HUD); o cartão lista os `steps`.

**`screenshot`** (`.safe`): `window` (seletor de `ui_read`), `marks` (padrão true com janela + Acessibilidade),
`max_side` 640–1568 (padrão 1280), `ocr` `auto|on|off` (`auto` só com < 8 elementos rotulados; Vision `.fast`). Janela
resolvida por janelas AX → `SCShareableContent` (cache 1,5 s) casando pid, frame (±2 pt) e título. Saída: cabeçalho com
tamanho e px/pt, legenda `[12] w1.3.2 button “Salvar”` (≤ 60 marcas, ≤ 4.000 caracteres), OCR ≤ 1.500 caracteres. Salva
um `UISnapshot` com marcas e geometria, mesclado com o anterior (mesma janela, < 60 s). JPEG q0,8, ≤ 450 KB. Marcas:
acionáveis, visíveis, ≥ 6×6 pt, dentro da janela, em ordem de leitura. Degrada: sem Gravação de Tela só a legenda; sem
Acessibilidade só a imagem; `CGRequestScreenCaptureAccess` no máximo uma vez por processo.

**Specs:** teto total 17.500 caracteres, sub-teto testado de 4.800 para `ui_read`+`ui_act`+`screenshot`.

## 3. Desempenho e confiabilidade

- `actor AXAppSession` por pid com `unownedExecutor` = `DispatchSerialQueue` (IPC bloqueia GCD, não o pool cooperativo),
  em `AXSessions.shared` (`AccessibilitySession.swift`): no máximo 4 sessões em voo; prazos leitura 4/8 s, ação 2 s, espera
  = timeout + 0,5 s; estourado → "\(app) não respondeu", o trabalho é **cancelado** (o token da chamada: para no próximo
  elemento e uma ação que ainda não saiu nunca sai depois do aviso) e a sessão fica `busy` até ele voltar; chamadas novas
  falham em < 20 ms ("ainda ocupado"). As buscas longas têm relógio próprio, menor que o prazo: atalho no menu 1 s (passado
  isso a tecla vai como evento), linha de tabela 500 linhas e 1,2 s, marcas do `screenshot` 3,5 s, e o `wait` espaça as
  olhadas caras (pausa do tamanho da olhada, no máximo 1 s).
- `AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)` uma vez por processo + 1,0 s na raiz.
- Primeiro `.cannotComplete` aborta a leitura com corte `.hung`: `read(_:) -> AXRead` expõe a falha.
- `UILiveElements` em memória (bot, pid, geração): `id → referência AX viva`; ≤ 4.000 referências, LRU de 6 snapshots por
  (bot, pid), validade 10 min; resolve pela referência viva (conferência barata) e cai no percurso por caminho;
  `.invalidElement` → id vencido com mensagem útil; recuperação conservadora opcional (única correspondência, ação não
  perigosa → age e avisa).
- `AXEventHub` por processo numa thread dedicada "Orb.AXEvents" com `CFRunLoopRun` (nunca a main); uma entrada por pid;
  `AXObserverAddNotification` pela fila da sessão; assinaturas com refcount; `AsyncStream` `.bufferingNewest(64)`;
  desmontagem removendo a fonte via `CFRunLoopPerformBlock` na thread do hub antes de soltar o refcon; fim do app por
  `DispatchSource.makeProcessSource(.exit)`; entrada ociosa 30 s sai; ≤ 16 apps.
- `settle`: assina antes de agir, espera a primeira notificação (≤ 400 ms) + 60 ms de silêncio, então lê; sem suporte, 150 ms.
- ScreenCaptureKit só avulso (sem stream).
- Cancelamento: pela tarefa do turno. O servidor MCP do cano (`ClaudePipeServer.Loop`) atende cada requisição numa `Task` e
  trata `notifications/cancelled`. `type` para entre pedaços e informa quanto digitou.
- Concorrência: por pid em série; por processo ≤ 4 sessões AX, 2 capturas SCK, 1 Vision; takeover 1 por vez no app
  (`TakeoverLock.shared`, em memória, não bloqueante).

| Medida | Meta |
|---|---|
| Outline de 3.000 nós falsos (CPU) | ≤ 60 ms local; asserção ≤ 250 ms |
| IPC por elemento (contado no fake) | ≤ 2 (+1 por papel com valor) |
| `ui_act press` com referência em cache (IPC) | ≤ 6 |
| Overlay 1280×800 com 60 marcas | ≤ 30 ms |
| JPEG | ≤ 30 ms |
| App travado | retorno ≤ prazo + 150 ms; segunda chamada ≤ 20 ms |
| Main thread com app travado | maior intervalo ≤ 50 ms |
| Smoke `ui_read` 1.000 elementos | p95 ≤ 800 ms |
| Smoke `press` ponta a ponta | p95 ≤ 250 ms |
| Smoke captura de janela | quente ≤ 120 ms p95; fria ≤ 500 ms |
| Smoke `wait` | notificação → retorno ≤ 100 ms |
| Smoke `type` | 2.000 caracteres ≤ 400 ms |

## 4. Segurança

- Identidade antes de cada ação: pid vivo com mesmo `bundleID` e `launchDate` (novo opcional em `AccessibilityApp`,
  decodificação tolerante); `AXUIElementGetPid(elemento)` = pid do snapshot; `AXWindow` do elemento `CFEqual` à janela do
  snapshot e mesmo título; por coordenada, `CGWindowID` e tamanho batem (mudou > 2 pt → id vence; ponto relativo à
  janela). Nunca agir no pid do próprio Orb.
- Nunca digitar no foco do usuário: teclado só via `postToPid(alvo)`; alvo = `AXFocusedUIElement` do app antes de cada
  pedaço; se o alvo for o app da frente e houve tecla/clique do usuário nos últimos 3 s
  (`CGEventSource.secondsSinceLastEventType(.hidSystemState, …)`), recusar ("o usuário está usando este app agora") ou
  pedir N2; depois de cada ação conferir que o pid da frente não mudou (se mudou, restaurar e avisar); nunca usar a área de
  transferência para digitar.
- Senhas: valor de campo seguro nunca lido (nem na legenda nem em `AXSelectedText`); `set_value`/`type`/`key` em campo
  seguro têm perigo.
- Rechecagem de perigo na execução: depois de resolver o elemento real, recalcular `UIDanger` com o rótulo vivo; se for
  perigoso e o cartão não mostrou, recusar e orientar a repetir por `id` ou `pick_menu`. Ampliar `UIDanger`: Return/Enter
  em app de mensagem (envia), `cmd+delete` no Finder (apaga); em `steps` vale a primeira etapa perigosa.
- Takeover (`ScreenOwner` ao vivo): trava; guarda pid da frente, janela focada e cursor; `AXFrontmost=true` no alvo e
  `AXRaise`/`AXMain` na janela-alvo, espera `AXApplicationActivated` ≤ 500 ms; etapas com `CGEventSource(.privateState)`
  em `.cghidEventTap`; aborta se o cursor real se afastar > 3 pt; teto 10 s total e 2 s por etapa (no texto, por pedaço de
  20 unidades, para um texto longo não parar no meio); restauração não
  cancelável (`Task.detached` aguardada): `AXFrontmost` no app anterior, `AXMain` na janela anterior,
  `CGWarpMouseCursorPosition` + `CGAssociateMouseAndMouseCursorPosition(1)`, e conferência. HUD opcional (`NSPanel` não
  ativante) "Orb está usando a tela — mexa o mouse para parar".
- Permissões: AX e postar eventos exigem Acessibilidade; SCK exige Gravação de Tela; mensagens de `MacPermissionProblem`.

## 5. Testes

Fakes (estender `FakeElement`/`FakeAccessibility`): `pid`, `frame`, contador de IPC, `stall`, `failures`; fakes de
`SyntheticInput`, `WindowCapturer`, `ScreenOwner`, `AccessibilityEvents`. Casos: cada degrau; recusas (usuário ativo, foco
errado, campo seguro, perigo na execução); mescla de snapshots; `#12` e `x,y`; id vencido; takeover restaura cancelado;
MCP `notifications/cancelled` e EOF; snapshot antigo decodifica. Mudam de propósito: `rig.system.activated == [100]` →
`[]`; enum de `theSchemasNameTheirArguments`; `focusFallsBackToRaise…` passa a recusar `AXRaise`.

Harness real: alvo executável `OrbAXFixture` (AppKit, nunca se ativa: botão+contador, `NSTextField` "Nome",
`NSSecureTextField`, `NSTextView`, tabela de 200 linhas, rolagem alta, popup, menu "Ações" com "Marcar" (⌘K) e "Excluir",
canvas sem AX com first mouse, botão que muda um rótulo após 500 ms; registra o que recebeu em JSON no stdout). Suíte
`AXSmokeTests` `.serialized`, `.timeLimit(.minutes(1))`, `.enabled(if: ORB_AX_SMOKE=="1" && AXIsProcessTrusted())`;
captura exige `CGPreflightScreenCaptureAccess`; takeover exige `ORB_AX_TAKEOVER=1`. Asserções: app da frente e cursor
inalterados depois de press/type/select/scroll/menu/key/click N1; captura de janela coberta não sai em branco; SIGSTOP no
fixture → `ui_read` volta ≤ 1,5 s; `wait` ≤ 700 ms; 1.000 assinaturas/cancelamentos deixam o hub vazio; takeover restaura
app e cursor (≤ 2 pt). Opcional Finder/TextEdit só leitura com `ORB_AX_SMOKE_SYSTEM=1`. CI: tudo desligado.

## 6. Pacotes

- **WP0 — contratos** (primeiro, mesclado antes de B e C): `AccessibilityContracts.swift` + acréscimos em
  `AccessibilityElements.swift`/`AccessibilityOutline.swift`: `AccessibilityElement.pid`, `isSame(as:)`,
  `read(_:) -> AXRead`; `AXAttributeValue.range(AXTextRange)`; `AccessibilitySystem` + `hitTest(_:at:)`,
  `frontmostPID()`, `secondsSinceUserInput()`, `events`, `input`, `capturer`, `screen`; protocolos `AccessibilityEvents`,
  `SyntheticInput`, `WindowCapturer`, `ScreenOwner`/`TakeoverHand`/`TakeoverReport`; `UISnapshot` + `generation`,
  `Entry.frame` (relativo à janela), `Entry.actionable`, `marks`, `shot: ShotGeometry?`; `KeyStroke.parse`; extensões com
  implementação padrão que lançam "indisponível" (fakes seguem compilando).
- **WP-A — núcleo AX em segundo plano:** `AccessibilityElements.swift`, novo `AccessibilitySession.swift`, novo
  `AccessibilityEvents.swift`, `AccessibilityOutline.swift`, `AccessibilityTools.swift`; testes `AccessibilityToolTests` e
  novo `AccessibilityEngineTests`. Aceite: testes de fakes e contagens de IPC; travamento; nenhuma chamada AX na main
  (`dispatchPrecondition` em debug).
- **WP-B — visão e entrada sintética:** `ScreenshotTool.swift`, novos `WindowCapture.swift`, `UIMarks.swift`,
  `SyntheticInput.swift`; testes `MacToolTests`, `UIMarksTests`, `SyntheticInputTests`. Aceite: orçamentos de overlay e
  JPEG; ida e volta de coordenadas exata (2×, origem negativa); `#n` sobrevive à mescla; smoke de captura coberta.
- **WP-C — tomada de tela, cancelamento, harness e textos:** novo `ScreenTakeover.swift`; `MCPStdioServer.swift`
  (concorrência, cancelamento, EOF/SIGTERM); HUD opcional; `Package.swift` + `Tests/OrbAXFixture/`; `AXSmokeTests`;
  `SystemPrompt.swift` (`PromptParts.appControl` só nas linhas de `computerUse`, mantendo as frases testadas);
  `ToolEconomyTests` (tetos); o manual ("Apps em segundo plano") e `docs/PERMISSOES.md`. Aceite: restauração sob
  cancelamento; testes de cancelamento do MCP; smoke completo verde neste Mac; CI verde com smoke desligado.

**Coordenação com o navegador:** `PermissionPolicy.swift` não muda aqui; tetos de specs combinados (17.500 / sub-tetos);
`SystemPrompt.swift` só nas linhas de `computerUse`; `MCPStdioServer.swift` muda o modelo de concorrência (uma `Task` por requisição,
cancelável); o prompt diz que conteúdo web vai para as ferramentas do navegador.

**Revisão final:** `grep` sem `activate(`, `AXRaise`, `AXMain`, `.cghidEventTap` fora de `ScreenTakeover.swift`; sem
`_AX`, `CGS`, `SLS`, `CGWindowListCreateImage`, `PostToPSN`; nenhuma chamada AX na main nem em `runDetached`; timeout
global no app; toda saída de takeover passa pela restauração; `UISnapshot` antigo decodifica; rechecagem de
perigo em `click`, `key` e `steps`; nenhum valor de campo seguro em logs, legenda ou cartão; tetos de specs; testes antigos
alterados só onde manda; smoke neste Mac.
