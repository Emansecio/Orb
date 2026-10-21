# Tela ao vivo — plano de implementação da etapa 1 (ver)

Contexto e desenho: `docs/TELA-AO-VIVO.md`; mock: `docs/mocks/tela-ao-vivo.html`. Esta etapa entrega o cartão ao vivo do
navegador no chat, o estado "Precisa de você" na cara nova, a aba "Tela" no Inspetor (só ver), o "Ver última tela", o
"Privado" e o toggle em Ajustes. Assumir pela tela (etapa 2) e a faixa (etapa 3) ficam para depois.

## Decisões de implementação

1. **Item da transcrição novo:** `TranscriptItem.Kind.browserView(BrowserViewItem)`, só texto (id, host, início, fim,
   nº de ações, último caminho, desfecho `running|done|failed|stopped`). Nenhuma imagem no item. Um por uso do
   navegador num turno: criado em `BotSession.apply` no primeiro `.toolStarted` com `kind == .browser`, atualizado a cada
   ferramenta do navegador (conta ações) e fechado no fim do turno, em `stop()` e em `closingInterruptedTurn`.
   Versões antigas descartam o item sem quebrar a conversa (`lossyOptionals`).
2. **Dobras:** o item entra como "aviso" em `TranscriptFolding.isNotice` → fica fora de "Rodou N comandos", não impede o
   "Trabalhou por…" e aparece logo depois dele. Enquanto o turno roda (`liveTail`) nada dobra, então o cartão fica visível.
3. **Quadros fora da lista:** `LiveFrameStore` (`@Observable`, um por Orb, criado preguiçosamente como `groupLive`) com
   `frame: CGImage?`, `url`, `isStale`, `cursor`, `phase`. A linha (`TranscriptRow`) só compara o item; a miniatura lê o store.
4. **Conexão:** `LiveFeedHub` (actor, um por app) com `acquire(botID)`/`release(botID)`; `BrowserFeed` usa
   `URLSessionWebSocketTask` em `ws://127.0.0.1:<porta>?maxFps=10`. A porta vem de `BrowserDriver.streamPort()` (novo,
   `stream status`, dentro de `session.exclusive`), relida quando `driver.generation` muda (relaunch = porta nova).
   Decodificação JPEG com `CGImageSource` numa fila própria; quadro atrasado é descartado. Um stream por vez: um
   `acquire` de outro Orb pausa o anterior (mostra o último quadro com "pausado").
5. **Quando conecta:** o cartão (ou a aba Tela) está na tela (`onAppear`/`onDisappear` + janela não minimizada nem
   ocluída via `NSWindow.occlusionState`) e o Orb está usando o navegador. Solta 3 s depois de sair da tela.
6. **Ambiente do daemon:** `AGENT_BROWSER_STREAM_MAX_WIDTH` e `AGENT_BROWSER_STREAM_QUALITY` em
   `AgentBrowserConfig.extraEnvironment`. Isso muda o `launchFingerprint`: sessões abertas relançam uma vez (esperado).
   Largura: 480 se o protocolo não aceitar largura por cliente; o WP-A confere (ver abaixo) e, se aceitar, a aba Tela
   pede 960.
7. **Cursor do Orb:** antes de `browse_click/fill/select/find` agirem num `ref`, o driver pede a caixa
   (`get box @ref`, formato conferido no WP-A) e o `BrowserHub` publica `onPointer(botID, rect, kind)`; o app converte
   com o `metadata` (escala e rolagem) do quadro. Falhou a caixa → sem cursor, nada quebra.
8. **Protegido:** opaco quando há cartão de passagem pendente, quando `BrowserHandoff.reason(url:title:text:)` casa com
   a URL/título do stream ou com o texto do último snapshot, ou quando o último snapshot tem `SecretField`. Sem toggle.
9. **"Precisa de você":** o cartão de passagem pendente (`ApprovalRequest.isHandoff`) passa a ser desenhado pelo cartão
   ao vivo (estado âmbar, opaco, botões Terminei = Pronto e Cancelar, mesmos `model.decide` e atalhos ⌘↩/Esc); o
   `ApprovalCard` não aparece em duplicata. Respondido, volta ao resumo de hoje. Sem toggle ligado, tudo como hoje.
10. **Última tela:** LRU só em memória no `LiveFeedHub`, 10 JPEGs no app inteiro, chave = id do item; nunca de página
    protegida. A linha final mostra "Ver última tela" só se a chave existe.
11. **Privado:** flag por Orb só em memória no `LiveFrameStore`; borra miniatura e aba Tela.
12. **Toggle:** Ajustes → Navegador, "Mostrar a tela do navegador no chat" (UserDefaults, ligado), com `FormFootnote`
    e `Tip`. Desligado: nenhum item novo, nenhuma conexão.

## Pacotes (agentes Sonnet em worktrees, `nice -n 15`, só testes filtrados)

**WP-0 — Interfaces (eu, na main, antes dos agentes).** `BrowserDriver.streamPort()` (padrão `nil` na extensão),
`BrowserViewItem` + caso do `Kind` com os `switch` exaustivos mínimos (renderiza `EmptyView` por ora), protocolo/stub de
`LiveFrameStore` e `LiveFeedHub`, `InspectorTab.screen` com aba vazia. Compila e testa; commit. Assim os três pacotes
seguintes partem do mesmo contrato e não se tocam.

**WP-A — Navegador (Engine/Browser, BrowseTools).**
- Conferir no 0.39 real (sessão isolada, como no teste do time): formato de `stream status` (chave da porta), se a URL
  do WebSocket aceita largura/qualidade por cliente, formato de `get box`.
- `streamPort()` no `AgentBrowserDriver`; variáveis em `extraEnvironment`; atualizar testes que fixam o ambiente
  (`BrowserSetupTests`, `AgentBrowserHardeningTests`, `BrowserLocatorTests`, `BrowserProxyTests`).
- `onPointer` no `BrowserHub` + caixa antes das ações com `ref`. Fakes atualizados (`FakeBrowser.swift`).

**WP-B — Feed (pasta nova `Sources/Orb/LiveScreen/`).**
- `LiveFeedHub`, `BrowserFeed` (parse de `frame/status/url/tabs`, reconexão por geração, 1 stream por vez, pausa,
  descarte de quadro atrasado), decodificação fora da main, `LiveFrameStore`, LRU da última tela, regra de protegido,
  contador `framesProcessed`.
- Testes com um servidor WebSocket falso local (ou transporte injetável): zero quadros sem `acquire`; troca de Orb pausa
  o anterior; geração nova reconecta; quadro protegido nunca entra no LRU; LRU limita em 10.

**WP-C — Interface (Views, BotSession, dobras, Ajustes, Inspetor).**
- `LiveScreenCard` (92 pt, miniatura 160×100, estados ao vivo / precisa de você / protegido / pausado / erro), linha
  final com "Ver última tela", cursor com `Motion.content` e anel (Reduzir movimento respeitado), VoiceOver
  (`children: .contain`, anuncia só mudança de estado).
- `BotSession.apply`/`stop`/fim de turno criando e fechando o item; `closingInterruptedTurn`; `isNotice`; busca,
  memória e `RetryPlan` ignoram o item.
- Handoff desenhado pelo cartão; aba "Tela" no Inspetor (`PanelUITests` atualizado); toggle em `BrowserSettings`;
  cenas de snapshot `transcript-browser-live`, `-need`, `-done`, `inspector-screen` semeando o `LiveFrameStore`.

Ordem: WP-0 → A, B e C juntos (três agentes, no limite combinado) → revisão minha dos diffs → merge na main.

## Regras de desempenho (valem para os três pacotes)

- Um quadro novo redesenha **só a miniatura**: nada de quadro, URL ou cursor em `@Published`/`@Observable` lido pela
  lista, pela linha (`TranscriptRow ==`), por `BotLive`, pela lateral ou pelo cabeçalho. A miniatura é uma `NSView` com
  `CALayer.contents = CGImage` (sem `Image(nsImage:)` recriado a cada quadro), atualizada fora do ciclo do SwiftUI.
- Main thread: só a troca do `contents` e do cursor (CATransaction sem animação implícita). WebSocket, base64, JPEG e
  descarte de quadros em fila/actor própria. Nenhuma espera síncrona (`DispatchQueue.main.sync`, semáforo) em nada.
- Um quadro em memória por Orb (o último); o LRU guarda JPEG comprimido, nunca bitmap decodificado.
- O item da conversa muda no máximo a cada ação do navegador (contagem), nunca por quadro; o salvamento segue o
  `scheduleSave` de hoje.
- Sem timers rodando com o cartão fora da tela; o ponto "ao vivo" pulsa em Core Animation, não em `TimelineView`.
- Desligar é completo: `release` cancela a tarefa de recepção, fecha o socket e solta o quadro.

## Revisão (depois do merge, antes do push)

Cinco revisores Sonnet independentes, cada um com um ângulo, só leitura, com evidência `arquivo:linha`:
1. **Re-renderização SwiftUI:** o que observa o quê; prova de que um quadro não toca a lista, a linha, a lateral nem o
   cabeçalho (e de que o `Equatable` das linhas não mudou de custo).
2. **Thread principal e concorrência:** isolamento de actors, cancelamento, corridas entre relaunch/geração/acquire,
   Swift 6.3.3 estrito (CI).
3. **Memória e recursos:** vazamentos de socket/tarefa/quadro, LRU, Orb apagado, app fechando, conversa de 2.173 itens.
4. **Rede e CPU:** conexões só quando visível, reconexão sem tempestade, 1 stream por vez, custo por quadro.
5. **Correção e privacidade:** estados do cartão, handoff (Terminei/Cancelar/Parar), item fechado em crash/parada,
   protegido nunca vaza (miniatura, LRU, aba), nada em disco/log/modelo.
Cada achado confirmado por mim no código antes de corrigir; depois, medições da seção abaixo.

## Verificação

1. Testes filtrados de cada pacote; depois a suíte inteira **com o app fechado e com seu ok** (ou no CI).
2. Capturas com `--snapshot` (dados temporários, sem tirar o foco) das cenas novas, comparadas ao mock.
3. Medições, com o app real e um Orb abrindo uma página animada:
   - `framesProcessed` = 0 com o cartão fora da tela e com a janela minimizada;
   - CPU do Orb < 3 % de um núcleo com o cartão visível a 10 qps (`top -pid`);
   - rolagem da conversa grande em 114–118 fps (método do `PanelsBench`).
4. No app (`bundle.sh`, você reabre): um Orb abre o checkout → cartão ao vivo com cursor; uma página de login →
   "Precisa de você" opaco, Terminei continua o turno; fim → linha com "Ver última tela"; toggle desligado → igual a hoje.
5. Push e CI.
