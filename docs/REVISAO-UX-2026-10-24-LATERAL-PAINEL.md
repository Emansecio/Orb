# Revisão de UI/UX: lateral e painel do Orb (24/10/2026)

Leitura do código sobre `fd44dd6`, conferida com capturas `--snapshot` dos modos abaixo:
- lateral: `sidebar`, `sidebar-categories`, `groups-sidebar`, `sidebar-talking`, `sidebar-profile`, `orb-created-sidebar`;
- painel: `inspector`, `inspector-memory`, `inspector-folder`, `inspector-routines`, `inspector-screen`.

O foco é polimento sem poluição: tirar sinais repetidos e textos que repetem a interface, e acertar alinhamento e escala. Nada aqui acrescenta seção nova.

Notação:
- **Impacto e esforço:** A/M/B e P/M/G.
- **[conferido]:** visto no código ou na captura.
- **[suspeita]:** depende de ver na largura mínima (244 pt no painel, 240 pt na lateral), que as capturas não cobrem.

Os caminhos são relativos a `Sources/Orb/Views/`.

Critérios, tirados das regras de tela de app da skill `design-taste-frontend` e da HIG:
- a navegação recua;
- cor só em estado e na ação principal;
- um marcador por estado;
- contagem só em fila que pede ação, com substantivo;
- alvo de clique de cerca de 28 a 32 pt;
- texto numa borda só;
- tamanhos só da escala `Typography`.

## 1. As dez primeiras

| # | O quê | Onde | Imp. | Esf. |
|---|---|---|---|---|
| 1 | **Texto de 10 pt no painel.** `.font(.caption)` vale 10 pt no macOS, abaixo do menor token (11). Aparece 20 vezes, inclusive no aviso do navegador e no rodapé "Skills:". Trocar por `Typography.small`. [conferido] | `BotInspector` (10), `BrowserPickers` (5), `MemoryViews` (4), `SheetKit` (1) | M | P |
| 2 | **"Precisa de você" com três sinais na linha do Orb:** anel âmbar, texto âmbar e ícone `exclamationmark.bubble.fill`. Tirar o ícone das linhas de Orb e de grupo e deixá-lo só na categoria recolhida, que não tem texto. [conferido] | `SidebarView.swift:534, 608, 626`; `Groups/SidebarGroupRow.swift:74, 85` | M | P |
| 3 | **Trabalhando e não lida são o mesmo ponto azul** (5 e 6 pt). Com Reduzir Movimento ficam iguais, e o grupo chega a mostrar dois pontos lado a lado. Trabalhando vira anel (`strokeBorder`), e cada linha mostra um marcador só. [conferido] | `SidebarChatList.swift:98-105`; `Groups/SidebarGroupRow.swift:83, 89` | M | P |
| 4 | **Aviso do navegador grita.** São duas linhas inteiras em laranja, mais ⚠ e um link com seta, em todo Orb sem `agent-browser`. Fica só "Falta instalar agent-browser" em `warn`. A consequência vai em `muted`, e o link fica sem ícone. [conferido] | `BrowserPickers.swift:61, 260-282` | M | P |
| 5 | **Número da categoria sem substantivo.** "Pesquisa ● 2" lê como 2 não lidas. Mostrar o número só com a categoria recolhida, com o rótulo "2 Orbs" no `help` e no VoiceOver. [conferido] | `SidebarCategoryViews.swift:196-199` | M | P |
| 6 | **Explicação repetida na aba Pasta.** A legenda do interruptor "Confiar nas instruções" e o rodapé dizem a mesma coisa. Fica só o rodapé, que já muda com o estado. [conferido] | `BotInspector.swift:580` e `:1328` | M | P |
| 7 | **Lixeiras invisíveis no foco.** O "Esquecer" da memória e o apagar da rotina só aparecem no hover, mas recebem Tab. Somar o foco à condição (`isHovering \|\| isFocused`). [conferido] | `MemoryViews.swift:277`; `BotInspector.swift:1193` | M | P |
| 8 | **Abas do painel em 244 pt.** Cada aba tem cerca de 39 pt, e o rótulo troca de peso ao selecionar, o que muda a largura. Usar peso fixo `.medium`; se ainda cortar abaixo de ~280 pt, mostrar o rótulo só na aba ativa. [suspeita] | `BotInspector.swift:862-870` | M | P |
| 9 | **"Modelo e permissões" fechado em 244 pt.** O título não tem `lineLimit` nem prioridade e pode quebrar ou espremer o nome do modelo. Pôr `.lineLimit(1).layoutPriority(1)` no título. [suspeita] | `InspectorFold.swift:55` | M | P |
| 10 | **Conversas da lateral com cerca de 23 pt de altura**, abaixo do alvo de clique. Pôr `minHeight: 28` nas conversas e `32` no cabeçalho de categoria. [conferido] | `SidebarChatList.swift:115`; `SidebarCategoryViews.swift:169` | M | P |

## 2. Lateral

- **Foco de teclado nas linhas de Orb (M/M).** A linha usa `onTapGesture`, por causa do arrasto, e não `Button`. Com Acesso Total por Teclado ela não deve receber Tab, mas o VoiceOver funciona. Proposta: `.focusable()` mais `.onKeyPress(.return, .space)` chamando a mesma ação, com o anel de foco do sistema. [suspeita] (`SidebarView.swift:286-297`)
- **Três bordas à esquerda (B/P).** Os títulos "Orbs" e "Espaço de trabalho" começam em 18 pt, os avatares dos Orbs em 16 pt e o perfil em cerca de 10 pt. Proposta: alinhar títulos e perfil à borda do avatar. [conferido na captura] (`SidebarView.swift:133-142, 168`)
- **"+" de Orbs e de Grupos com tons diferentes (B/P).** O de Orbs está num `Menu` e sai claro, e o de Grupos sai em `hint`. O próprio `Theme` diz que `hint` é só decorativo. Proposta: os dois em `faint`, com `secondary` no hover. [conferido na captura] (`SidebarView.swift:184`)
- **Rodapé "Espaço de trabalho" (B/P).** "Conectores" fica cerca de 1 pt acima de "Rotinas" e "Skills", porque os símbolos têm alturas diferentes. A legenda usa 10 pt, fora da escala. Proposta: `.frame(height: 16)` no ícone e `Typography.small` no texto. [conferido] (`SidebarView.swift:230-231`)
- **Fontes fora da escala (B/P).** Há tamanhos 10,5, 11,5, 10 e 11 escritos à mão. Os títulos de seção em 11 pt sobem para `Typography.label` (12). [conferido] (`SidebarChatList.swift:108, 143`; `SidebarView.swift:162, 231, 579`)
- **"N mais…" sem substantivo (B/P).** Proposta: "3 conversas mais antigas" e "Mostrar menos". [conferido] (`SidebarChatList.swift:42`)
- **Duas bordas de texto na mesma coluna (B/M).** O nome do Orb começa em 46 pt e o do grupo em cerca de 70 pt, por causa da pilha de 54 pt. Proposta: pilha de grupo com no máximo dois avatares menores, para o nome cair na mesma borda. [conferido na captura] (`Groups/StackedAvatars.swift:25`)
- **Nome reflui no hover (B/M).** Ao passar o mouse, entram o "+" e o chevron, e o ponto de truncamento de nomes longos muda. Proposta: os dois em overlay com fade, sem mexer no layout. [suspeita] (`SidebarView.swift:572-603`)
- **Grupos vazio (B/P).** Com 2 Orbs ou mais e nenhum grupo, a seção fica só com o título. Proposta: uma linha `faint` "Nenhum grupo ainda", como o "Arraste um Orb para cá" das categorias. [conferido] (`SidebarView.swift:86`)
- **Código morto (B/P).** `@Environment(\.sidebarListChanged)` não é usado em `SidebarRow`. [conferido] (`SidebarView.swift:266`)

## 3. Painel do Orb

- **Títulos que repetem a aba (M/P).** A aba Rotinas já omite o título, de propósito (`:761`). A aba Pasta abre com a seção "Pasta" (`:568`). Proposta: tirar esse título ou trocar por "Onde trabalha". Na Memória, a segunda seção pode virar "O que Atlas guardou" (`MemoryViews.swift:49`). [conferido]
- **Caminho da pasta pessoal por extenso (B/P).** O painel mostra `/Users/thiagomacbookpro`, enquanto os Conectores já usam `~`. Proposta: `abbreviatingWithTildeInPath`. [conferido] (`BotInspector.swift:647`)
- **Cartão com um botão só, na Memória (B/P).** "Abrir pasta da memória" ocupa um cartão inteiro abaixo de "Nada guardado ainda". Proposta: com a memória vazia, ele vai para o rodapé da seção, como link discreto. [conferido na captura] (`MemoryViews.swift:101, 399`)
- **Textos que repetem a interface (M/P):** [conferido]
  - as legendas sobre o "Mudar…" da pasta (`BotInspector.swift:705, 710`), que já têm `help`;
  - "Clique para mostrar no Finder…" (`:747`), igual ao `help` de `:1054`;
  - "São arquivos .md na sua pasta de dados" (`MemoryViews.swift:85`), ao lado do botão que abre a pasta;
  - as três frases fixas das liberações (`Models.swift:47`), que podem virar uma e ir para o `help`.
- **Rotinas do painel diferentes da página Rotinas (M/M).** No painel, cada rotina tem um ícone em quadrado tingido, "Rodar agora" à esquerda e "Editar" à direita. Na página, o cartão tem o Orb, "Editar", "Ver conversa" e "…", com "Rodar agora" à direita. Proposta: mesma ordem e mesmo lugar do "Rodar agora", e sem o ícone em quadrado, que só repete o horário escrito ao lado. [conferido na captura] (`BotInspector.swift:1116-1260`)
- **Pausa dita três vezes por rotina (M/P):** o glifo ⏸, o interruptor desligado e a linha "Pausada: não roda até você ligar de novo". Proposta: a linha diz só "Pausada", sem ícone. Vale o mesmo para "Concluída". [conferido] (`BotInspector.swift:1219, 1253, 1257`)
- **Ícones repetidos (B/P).** A aba Pasta e o botão "Abrir no Finder" do cabeçalho usam o mesmo `folder`. O botão de terminal do cabeçalho repete o ícone da linha "Terminal e arquivos". Proposta: trocar o ícone dos botões do cabeçalho. [conferido] (`InspectorSupport.swift:35`; `BotInspector.swift:271`)
- **Alinhamento em "Pode usar" (B/P).** Os ícones ficam centralizados num quadro de 20 pt e começam a 5 pt da borda do título. As sublinhas (Navegador, Pesquisa) têm recuo fixo de 28 pt, e o texto começa em 30,5 pt. Proposta: quadro com `alignment: .leading` e recuo derivado do mesmo espaçamento. [conferido na captura] (`BotInspector.swift:482`; `BrowserPickers.swift:121`)
- **Azul demais em links de configuração (B/P).** "Acesso ao Mac", "Gerenciar", "Instalar em Ajustes", "Ver todas" e "Desfazer" saem todos em azul. Proposta: o `QuietTextStyle` do cabeçalho (cinza, azul no hover) para links de rodapé e inline. O azul fica só na ação principal da aba. [suspeita]
- **Cinzas misturados (B/P).** Há `.secondary` do sistema ao lado de `Palette.muted` e `Palette.faint`. Proposta: só tokens. [conferido] (`BotInspector.swift:148, 287, 583`; `MemoryViews.swift:133-145, 194`; `SheetKit.swift:256`)
- **Interruptores de dois tamanhos (B/P):** normais em "Pode usar", `.mini` nas Rotinas. Proposta: um tamanho só no painel. [conferido] (`BotInspector.swift:1116`)
- **Raio fora da escala (B/P):** `cornerRadius: 6` na faixa de ícones de "Pode usar", e `caption2` em `:1031`. [conferido] (`BotInspector.swift:463`)
- **Aba Tela (M/M).** A prévia fica dentro de um cartão de seção e encolhe a uns 172 pt, numa aba que existe para ver a tela. Proposta: prévia na largura inteira, sem o cartão. O estado "Conectando" (`faint`) também fica mais apagado que o botão secundário "Ocultar tela" ao lado, e pode subir para `secondary`. [conferido] (`LiveScreen/LiveScreenViews.swift:326-339, 365-373`)
- **Uso ao vivo invisível fora da aba Tela (M/M).** Quem está em outra aba não percebe que o Orb está usando a tela. Proposta: o `BreathingDot` que já existe, de 6 pt, sobre o ícone da aba Tela enquanto o Orb usa a tela. [suspeita]
- **Cópia "o Orb" (B/P).** O aviso do navegador e a Tela dizem "o Orb", enquanto o resto do painel usa o nome. Proposta: usar o nome do Orb. [conferido] (`BrowserPickers.swift:61`; `LiveScreenViews.swift:389`)

## 4. As sete que ficaram da revisão de 23/10

1. **Busca no texto das conversas na paleta (M/M).** Hoje acha só pelo título. [mais barato]
2. **Conferir os 16 `.link`** contra a regra das ações secundárias em `Theme.swift` (B/P). Combina com o item "Azul demais" da seção 3.
3. **Nome já preenchido no Novo Orb a partir da paleta (B/M).**
4. **Menu "⋯" no cabeçalho do painel (B/M).** Com os ícones de pasta e terminal trocados (seção 3), ele pode juntar "Abrir no Finder", "Abrir no Terminal" e "Apagar…" sem disputar o foco do nome.
5. **Imagens repassadas entre Orbs no grupo (M/M).** Falta um campo no `OrbEnvelope`.
6. **QuickAsk com grupos (M/G).**
7. **Texto que acompanha o tamanho de fonte do sistema (M/G).** O item 1 da seção 1 é o primeiro passo.

## 5. Ordem sugerida

1. **Escala e ruído (P, uma passada):** itens 1, 2, 4, 6 e 7 da seção 1; títulos e textos repetidos do painel; pausa; fontes da lateral.
2. **Estados (P):** itens 3, 5 e 10; "+" com o mesmo tom; Grupos vazio; "N mais…".
3. **Larguras mínimas (P/M):** itens 8 e 9 e a linha "Controlar apps do Mac". Pedem capturas em 244 e 240 pt, ou seja, um modo de `--snapshot` com o painel nessa largura.
4. **Coerência entre telas (M):** cartão de rotina do painel igual ao da página, aba Tela sem cartão, alinhamento de "Pode usar", bordas da lateral e pilha do grupo.
5. **Teclado (M):** foco nas linhas de Orb e lixeiras visíveis no foco.
6. **Depois:** as sete da seção 4.

## 6. Não verificado

- Larguras mínimas: os modos de captura desenham a lateral com 280 pt e o painel com 360 pt.
- VoiceOver e Acesso Total por Teclado não foram testados de fato.
- O estado "trabalhando" do painel não tem modo de captura.
