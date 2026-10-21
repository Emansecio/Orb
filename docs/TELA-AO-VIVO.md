# Tela ao vivo — especificação (só o navegador do Orb)

Quando o Orb usa o próprio navegador, o chat mostra um cartão compacto com a página **ao vivo**: o cursor do Orb indo ao
elemento, o clique, o texto entrando. Clicar amplia no Inspetor; quando a página precisa de você (login, código, captcha),
você assume ali mesmo, sem a página recarregar. Apps do Mac ficam fora por enquanto (gravação de tela contínua e indicador
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
**Etapa 2 — Assumir pela tela.** Na visão ampliada, clique e teclado vão ao Chrome pelo WebSocket; a página não recarrega.
`browse_show` (janela de verdade) fica de reserva: "Abrir em uma janela" para passkey, captcha que barra clique simulado.
**Etapa 3 — Faixa** de uma linha acima do compositor quando o cartão sai da tela (mesmo stream, sem segunda conexão).

## 3. O cartão (etapa 1)

- **Item próprio da transcrição**, um por uso do navegador (do primeiro `browse_*` ao fim do turno). As linhas de
  ferramenta continuam abaixo dele.
- **Tamanho:** largura da coluna até 560 pt, **altura fixa 92 pt** em todos os estados (o layout nunca pula).
  Miniatura 160 × 100 pt (proporção da página), raio 8, `Palette.line`. Fundo `Palette.surface`, raio 12, padding 10.
- **À direita da miniatura:** linha 1 = chip de estado + host (11 pt); linha 2 = legenda (`WorkLine.headline`, 12 pt,
  `Palette.secondary`, shimmer só trabalhando); linha 3 = botões pílula pequenos.
- **Cursor do Orb** desenhado em camada sobre a imagem (seta + bolinha na cor do Orb), desliza 0,25 s (`Motion.content`)
  até o ponto da ação; anel de 0,3 s no clique. Reduzir movimento: salta com fade, sem anel. O ponto vem da caixa do
  elemento que o driver já resolve (`ref` → caixa) + `metadata` de rolagem do quadro.
- **Quadros fora da lista:** a linha da transcrição é `Equatable` pelo id e pelo estado; a imagem vem de um objeto
  observável próprio (`LiveFrameStore`), então um quadro novo redesenha só a miniatura.

| Estado | Chip | Miniatura | Legenda | Botões |
|---|---|---|---|---|
| Ao vivo | ● Ao vivo (`Palette.ok`, pulso leve) | página + cursor | o que o Orb faz | Ampliar · Parar · Privado |
| Precisa de você | Precisa de você (`Palette.warn`, parado) | **opaca**: cadeado + "Página de login" | motivo do modelo ("Entre na sua conta para eu continuar") | Assumir · Terminei · Cancelar |
| Você no controle (etapa 2) | Você está no controle (`Palette.accentText`) | página, sem cursor do Orb, contorno azul 1,5 pt | "O Orb espera você" | Terminei · Devolver ao Orb |
| Protegido | — | borrada + cadeado | "Conteúdo protegido" | Ampliar |
| Erro | — | último quadro esmaecido | "O navegador fechou · última ação: …" | — |
| Terminou | linha de uma altura de ferramenta | sem imagem | "Usou o navegador · checkout.acessosfit · 2 min · 14 ações · terminou em /pagamentos" | Ver última tela (só se ainda na memória) |

"Precisa de você" entra uma vez com `Motion.emphasis` e contorno `Palette.warn` a 40 %; sem pulso contínuo nem som (a
notificação do sistema que já existe para o cartão de passagem continua).

**Privado:** botão no cartão que borra a miniatura e a ampliada até ser desligado (por Orb, só na memória). Serve para
reunião com tela compartilhada.

## 4. Privacidade (regras fixas)

1. Nenhum quadro vai a disco, histórico, log ou modelo. O `command` do stream também não (pode trazer texto digitado).
2. Página que casa com `BrowserHandoff.reason` ou tem campo de senha visível → miniatura e ampliada opacas (cadeado),
   sem toggle. Na etapa 2, em "Você no controle" a ampliada mostra a página (você precisa ver para digitar), a miniatura não.
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
- `?maxFps=10`; largura máx. 480 px, qualidade 60 (ampliada: reconecta com 960). Decodificação fora da main
  (`CGImageSource` numa fila própria), quadro atrasado é descartado.
- No máximo 1 stream por vez (o do Orb em vista); os outros mostram o último quadro com "pausado".
- **Critérios de pronto:** zero quadros processados sem cartão visível (contador em teste); CPU do app abaixo de 3 % de
  um núcleo com o cartão visível a 10 qps; rolagem da conversa de 2.173 itens em 114–118 fps (PanelsBench / medição
  equivalente); toggle desligado = comportamento idêntico ao de hoje.

## 6. Segurança da porta

O WebSocket do agent-browser é local (127.0.0.1), porta efêmera, **sem token**: um processo do mesmo usuário poderia
ver a página e mandar entrada. É o mesmo nível do CDP que o Chrome já abre. Aceito e documentado; o Orb só conecta com o
cartão visível e não divulga a porta. Pedir token ao upstream se o agent-browser oferecer depois.

## 7. Etapa 2 em detalhe (Assumir pela tela)

- Trava por sessão: em "Você no controle" o motor recusa `browse_*` do Orb ("o usuário está no controle") na entrada da
  ferramenta; a ação em curso termina antes.
- Clique dentro do quadro dá o foco do teclado à página (contorno azul, compositor com placeholder "O teclado está na
  página"); ⌘ fica com o app; sair: Terminei, clique fora do quadro ou ⌘⎋.
- Coordenadas: `x_viewport = x_imagem × viewportWidth / larguraDaImagem` (+ rolagem do `metadata`).
- Teclado: `UCKeyTranslate` para respeitar ABNT2; colar vira `input_keyboard` com o texto.
- Terminei → o Orb recebe o texto de hoje do `browse_show` ("tire um browse_snapshot novo").

## 8. Fora de escopo

Apps do Mac (SCStream); gravação ou replay; quadros para o modelo; controle pela miniatura compacta; tela ao vivo na
lateral; stream sem ninguém olhando; esconder a janela em capturas.
