# Tela ao vivo — especificação (só o navegador do Orb)

Quando o Orb usa o próprio navegador, o chat mostra um cartão com a página **ao vivo** e grande: o cursor do Orb indo ao
elemento, o clique, o texto entrando. "Assumir" passa o navegador a você ali mesmo, sem a página recarregar; "Ampliar"
abre a mesma página numa janela. Apps do Mac ficam fora por enquanto (gravação de tela contínua e indicador
de gravação do macOS ainda não medidos).

Decidido em 2026-10-20 com um time de quatro papéis (captura, computer use, design, produto) em duas rodadas e um conselho
de cinco agentes; mock em `docs/mocks/tela-ao-vivo.html`.

## 1. O que existe e é aproveitado

- **Stream do agent-browser 0.39.** Toda sessão tem um WebSocket local (`stream status` dá a porta). O Chrome só gera
  quadros com um cliente conectado e só quando a página muda. Mensagens: `frame` (JPEG base64 + `metadata` de viewport e
  rolagem), `status`, `tabs`, `url`, `command` (cada ação: `action` + `params`, sem coordenadas). Cliente pode limitar com
  `?maxFps=N`. Aceita entrada: `input_mouse`, `input_keyboard`.
  Medido: largura máx. 480 px → 23–36 KB por quadro e ~12 % de um núcleo do Chrome a 10 qps numa página animada
  (largura cheia: ~49 %). `AGENT_BROWSER_STREAM_MAX_WIDTH`/`QUALITY` são lidas quando o daemon sobe: vão no ambiente do `open`.
- **Cartão de passagem** (`ApprovalRequest.handoff`, `ApprovalGate.wait`): o "precisa de você" já para o turno e espera.
- **`BrowserHandoff.reason`** detecta login, 2FA, captcha, senha. **`WorkLine.headline`** dá a legenda curta.
- **Inspetor** (`BotInspector`, abas `InspectorTab`): onde vive a visão ampliada.
- Etapa 0 já entregue (545ef95): numa rotina, `browse_show` não espera; a rodada termina relatando o passo.

## 2. Etapas (cada uma usável sozinha)

**Etapa 1 — Ver.** Cartão ao vivo no chat, faixa não, Assumir não. Estados: ao vivo, precisa de você (o cartão de
passagem de hoje, com a nova cara; "Assumir" ainda abre a janela pelo `browse_show`), protegido, erro, terminou. Ampliar
abre a aba "Tela" no Inspetor (só ver). Toggle em Ajustes → "Mostrar a tela do navegador no chat" (ligado).
**Etapa 2 — Assumir pela tela (feita, ver 7).** Na janela ampliada, clique e teclado vão ao Chrome pelo WebSocket; a página não recarrega.
`browse_show` (janela de verdade) fica de reserva: "Abrir em uma janela" para passkey, captcha que barra clique simulado.
**Etapa 2b — Página grande e Assumir no cartão (feita em 2026-11-12, ver 3).**
**Etapa 3 — Faixa** de uma linha acima do compositor quando o cartão sai da tela (mesmo stream, sem segunda conexão).
**Etapa 4 — Passagem resolvida no cartão (aberta).** No "Precisa de você" o Orb ainda reabre o navegador numa janela de
verdade (`browse_show`) e o cartão só mostra o cadeado. O passo seguinte é a pessoa assumir ali mesmo, com a janela de
verdade como reserva para passkey e captcha que barra clique simulado.

## 3. O cartão

Desde 2026-11-12 o cartão é a página grande dentro da conversa, não mais uma miniatura de 92 pt: a comparação com o
concorrente mostrou que o cursor, a fluidez de 60 quadros/s e o Assumir ficavam escondidos atrás de um clique.

- **Item próprio da transcrição**, um por uso do navegador (do primeiro `browse_*` ao fim do turno). As linhas de
  ferramenta continuam abaixo dele.
- **Forma:** uma pequena janela de navegador, em três faixas dentro de um `.card()`.
  - **Barra de cima (36 pt):** chip de estado + site (trunca no meio, cede espaço primeiro); à direita, o que muda como se
    vê: "Ocultar tela"/"Mostrar tela" e "Ampliar".
  - **Página:** de borda a borda, inteira (`resizeAspect`), na proporção dos próprios quadros
    (`LiveFrameStore.pageAspect`, entre 1,25 e 2,2; 1,6 antes do primeiro quadro), então não há barras nem corte e o clique
    da pessoa cai no ponto certo. No máximo **320 pt de altura**: uma página mais quadrada estreita o cartão em vez de
    tomar a conversa. A largura segue a coluna, até 560 pt.
  - **Barra de baixo:** a legenda (`WorkLine.headline`) e, ao lado, o que a pessoa pode fazer: "Assumir" e "Parar Orb".
    Sem espaço para os dois numa linha, a legenda corta (o `help` traz inteira) e os rótulos encurtam; a legenda do
    "Precisa de você" não corta, sobe para cima dos botões.
- **Assumir no próprio cartão:** o botão passa o navegador à pessoa ali mesmo. A página recebe clique, rolagem e teclado
  (o teclado vai para ela na hora, sem um primeiro clique), o cartão ganha contorno `Palette.accent` e a barra de baixo
  mostra "Devolver ao Orb". Um clique na página enquanto o Orb dirige só amplia: assumir é sempre um botão, para um
  clique perdido na conversa não parar o Orb. Sair da conversa (abrir outro Orb, grupo ou página) devolve o que foi
  assumido no cartão (`LiveFeedHub.chatLeft`); rolar a conversa não devolve. Se a janela ampliada abrir, o controle passa
  a ser dela e termina quando ela fecha.
- **Cursor do Orb** desenhado em camada sobre a imagem (seta + bolinha na cor do Orb). Com a animação ligada (Ajustes →
  Navegador, "Animar o cursor e a rolagem na tela do navegador", padrão), viaja 0,2 s com curva de entrada e saída até o
  ponto da ação, e **a ação espera esse tempo** (`BrowserHub.point(at:)`, cancelável por Parar): ao chegar, o cursor "aperta"
  (escala 0,8 e volta, 0,16 s) e o anel de 0,3 s abre junto do clique. Entre duas ações, com o cursor parado há mais de 0,6 s e
  o cartão ao vivo, ele pulsa (opacidade, animação repetida da camada; para com a próxima ação, ao sair da tela ou ao
  esconder o ponteiro). Desligada a animação: desliza 0,25 s como antes, sem espera, sem aperto e sem pulso. Reduzir
  movimento do sistema: salta com fade, sem anel, sem espera, sem pulso. O ponto vem da caixa do
  elemento que o driver já resolve (`ref` → caixa) + `metadata` de rolagem do quadro.
- **Quadros fora da lista:** a linha da transcrição é `Equatable` pelo id e pelo estado; a imagem vem de um objeto
  observável próprio (`LiveFrameStore`), então um quadro novo redesenha só a página. A proporção é observada, mas só é
  escrita quando muda (viewport novo), nunca por quadro.

| Estado | Chip | Página | Legenda | Em cima | Embaixo |
|---|---|---|---|---|---|
| Ao vivo | ● Ao vivo (`Palette.ok`, pulso leve) | página + cursor | o que o Orb faz | Ocultar tela · Ampliar | Assumir · Parar Orb |
| Conectando | Conectando | vazia, ou o último quadro esmaecido | "Abrindo o navegador…" | Ocultar tela · Ampliar | Parar Orb |
| Precisa de você | Precisa de você (`Palette.warn`, parado) | **opaca**: cadeado + "Página de login" | o que fazer ("Entre na sua conta para o Orb continuar") | — | Terminei · Cancelar |
| Você no controle | Você no controle (`Palette.accentText`) | página, sem cursor do Orb, recebe a entrada | "O Orb espera você devolver" | Ampliar | Devolver ao Orb |
| Protegido | — | opaca: cadeado | "Página protegida: assuma para ver" | Ampliar | Assumir |
| Oculto pela pessoa | ● Ao vivo | borrada + cadeado "Privado" | o que o Orb faz | Mostrar tela | Parar Orb |
| Pausado | Pausado | último quadro esmaecido | "Pausado: outro Orb está na tela" | Ampliar | Parar Orb |
| Erro | — | último quadro esmaecido | "O navegador fechou · última ação: …" | — | — |
| Terminou | linha de uma altura de ferramenta | sem imagem | "Usou o navegador · checkout.acessosfit · 2 min · 14 ações · terminou em /pagamentos" | | Ver última tela (só se ainda na memória) |

"Precisa de você" entra uma vez com `Motion.emphasis` e contorno `Palette.warn` a 40 %; sem pulso contínuo nem som (a
notificação do sistema que já existe para o cartão de passagem continua).

**Privado:** botão no cartão que borra a miniatura e a ampliada até ser desligado (por Orb, só na memória). Serve para
reunião com tela compartilhada.

## 4. Privacidade (regras fixas)

1. Nenhum quadro vai a disco, histórico, log ou modelo. O `command` do stream também não (pode trazer texto digitado).
2. Página que casa com `BrowserHandoff.reason` ou tem campo de senha visível → miniatura e ampliada opacas (cadeado),
   sem toggle. Em "Você no controle", o cartão e a janela mostram a página (você precisa ver para digitar); a aba Tela
   do painel, que é só para ver, continua opaca.
3. "Ver última tela": cache só em memória, as **10** últimas imagens do app inteiro, nunca de página protegida; some ao
   fechar o app ou sair do cache (o botão some junto).
4. `NSWindow.sharingType = .none` **não** é usado (o usuário manda capturas do app; e desde o macOS 15.4 a captura
   moderna não o respeita — fórum da Apple, thread 792152).
5. Teclas que você digita na ampliada (etapa 2) vão direto ao WebSocket, sem buffer, nunca a log, histórico ou modelo.

## 5. Custo e ciclo de vida

- `LiveFeedHub` (actor, um por app) com `acquire`/`release` por Orb; `BrowserFeed` = `URLSessionWebSocketTask` na porta do
  `stream status`, lida a cada conexão e nunca escrita em log ou prompt.
- Conecta só com o cartão (ou a aba Tela) visível na janela do Orb na tela, e o Orb com o navegador em uso; desconecta
  3 s depois de sair da tela, ao fim do uso ou com a janela minimizada. Ao conectar, o quadro em cache chega antigo:
  esmaecido até o primeiro novo.
- `?maxFps=0` (sem limite): 60,3 quadros/s medidos no agent-browser 0.39.1, o teto do Chrome (com `maxFps=60` vieram 55, com
  intervalos irregulares). O Chrome gasta o mesmo em 10, 30 ou 60, porque pinta todos os quadros e o limite só os descarta no
  processo de fundo; no Orb cada quadro custa ~1 ms fora da thread principal (~6 % de um núcleo a 60/s, e nada com a página
  parada). O `LiveInbox` descarta o quadro atrasado antes de decodificar. Largura máx. 960 px, qualidade 60. Decodificação fora da main
  (`CGImageSource` numa fila própria), quadro atrasado é descartado.
- **Custo do movimento (só com a tela à vista):** o Orb só pede a caixa do elemento quando há ouvinte; sem ouvinte, nada
  muda e nada custa (zero comandos a mais, zero espera; coberto em teste). Com ouvinte e a animação ligada, cada
  clique, preenchimento ou escolha espera 0,2 s, e `browse_scroll` (100 px ou mais) vira um único `batch` de até 7 `scroll`
  com `wait 35` entre eles (curva suave, soma exata dos pixels, ~200 ms; medido no agent-browser 0.39.1: 5 passos em 192 ms
  num só processo). A espera é injetável (`BrowserHub.pause`), então os testes não esperam tempo real.
- No máximo 1 stream por vez (o do Orb em vista); os outros mostram o último quadro com "pausado".
- **Critérios de pronto:** zero quadros processados sem cartão visível (contador em teste); CPU do app em torno de 6 % de
  um núcleo com o cartão visível e a página se mexendo (60 qps); rolagem da conversa de 2.173 itens em 114–118 fps (PanelsBench / medição
  equivalente); toggle desligado = comportamento idêntico ao de hoje.

## 6. Segurança da porta

O WebSocket do agent-browser é local (127.0.0.1), porta efêmera, **sem token**: um processo do mesmo usuário poderia
ver a página e mandar entrada. É o mesmo nível do CDP que o Chrome já abre. Aceito e documentado; o Orb só conecta com o
cartão visível e não divulga a porta. Pedir token ao upstream se o agent-browser oferecer depois.

## 7. Etapa 2 em detalhe (Assumir pela tela) — feita em 2026-11-05

Decidido com o usuário: a visão ampliada é uma **janela própria** (`LiveScreenWindow`, `WindowGroup` por Orb), não a aba
do Inspetor, que tem no máximo 420 pt. A aba Tela continua para "Ver última tela".

- Abrir: clique na miniatura ou "Ampliar" no cartão. A janela mostra a página inteira (`resizeAspect`), sem cortar.
- Assumir: clique na página (esse clique não vai à página, para não apertar nada por engano) ou o botão "Assumir", com a
  página ao vivo ou protegida. Devolver: "Devolver ao Orb", no cartão ou na janela, ou fechar a janela.
- Trava: `BrowserControl` (no `BrowserHub`). Enquanto a pessoa controla, toda ferramenta `browse_*` espera na entrada
  (`BrowseSupport.session`), assim como o `web_search` pelo navegador e o `browse_proxy`. Parar encerra a espera. A
  ferramenta que esperou não age sobre refs velhas: devolve ao modelo `BrowserControl.handedBack` ("tire um
  browse_snapshot novo").
- Entrada: `input_mouse` e `input_keyboard` no mesmo WebSocket do stream (`LiveOutbox`). São as mensagens do painel do
  próprio agent-browser, conferidas num navegador real em 0.39.1: clique, letra, acento, Backspace, roda e Tab.
  Coordenadas no viewport, sem somar a rolagem: `x = (ponto − borda da imagem) / largura mostrada × viewportWidth`.
- Teclado: o texto vem de `NSEvent.characters`, que já aplica o layout (ABNT2, ç, letras com acento). Teclas com nome vão
  por `keyCode`, e ⌘ fica com o app. ⌘V digita um caractere por tecla, com quebra de linha como Enter e no máximo 20.000
  caracteres: o stream recusa texto longo numa tecla só e o evento `char` (medido).
- Privacidade: com a pessoa no controle, a página protegida aparece no cartão e na janela (seção 3), e o quadro não vira
  "última tela". Ao devolver, o quadro é solto.
- Resolução: o stream passou de 480 para 960 px, para o texto ficar legível na janela. Medido numa página animada a
  10 qps: Chrome com ~27 % de um núcleo, contra ~16 % a 480 px. Página parada não custa nada. Vale para navegadores
  abertos depois da mudança.
- No "Precisa de você" (login pedido pelo Orb) continua a janela real do `browse_show`, com Terminei e Cancelar.

## 8. Fora de escopo

Apps do Mac (SCStream); gravação ou replay; quadros para o modelo; tela ao vivo na
lateral; stream sem ninguém olhando; esconder a janela em capturas.
