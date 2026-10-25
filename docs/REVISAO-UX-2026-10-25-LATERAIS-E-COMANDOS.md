# Revisão de UI/UX: comandos, mensagens surgindo e as duas laterais (25/10/2026)

Leitura do código sobre `77c8d91`, conferida com capturas `--snapshot` em 1100 e 760 pt:
- comandos: `transcript-work-open`, `transcript-tools-open`, `transcript-long-command`, `transcript-outputs`, `chat-working`;
- laterais: `sidebar`, `sidebar-categories`, `inspector`, `inspector-memory`, `inspector-folder`, `inspector-routines`, `inspector-screen`.

O que é movimento (mensagens surgindo, hover, troca de Orb) foi lido no código e não visto rodando: `--snapshot` só mostra um quadro parado. Onde o efeito depende do SwiftUI em execução está marcado **[provável]**.

Notação:
- **Impacto e esforço:** A/M/B e P/M/G.
- **[decisão]:** muda a cara do app; precisa do seu ok antes.

Os caminhos são relativos a `Sources/Orb/`: `TV` = `Views/TranscriptViews.swift`, `CV` = `Views/ChatView.swift`, `SV` = `Views/SidebarView.swift`, `BI` = `Views/BotInspector.swift`.

Protótipo dos comandos (não commitado, em `build/`):
- `build/revisao/comandos-hoje.png`: a tela de hoje;
- `build/revisao/comandos-proposta.png`: a proposta dos itens 1 a 7.

## 0. O que pesa hoje

- **Comandos.** A linha diz "Rodou ls Downloads" em fonte proporcional, com o comando resumido a ponto de quatro linhas seguidas dizerem "Rodou python3.14 historico.py". O tempo e a contagem só aparecem no hover, e quem roda agora é o item mais apagado da lista (52 %). Aberto, o comando e a saída são um bloco cinza só, sem limite de altura, começando por "Código de saída: 0" e às vezes com uma nota em inglês escrita para o modelo.
- **Mensagens surgindo.** As entradas em si seguem o `docs/MOVIMENTO.md`. Os trancos vêm das trocas:
  - a narração some de uma vez quando o trabalho dobra em "Trabalhando · N ações";
  - o texto em streaming é trocado por views novas no fim da resposta;
  - a lista muda de altura duas vezes ao enviar.
- **Laterais.** Cada uma tem seu estilo de título de seção. O mesmo "+" aparece em quatro tamanhos, e a mesma seta em dois tons e três larguras. No painel, ícones de traço e preenchidos ficam lado a lado. Na lateral, o hover da linha do Orb mexe no layout. No painel, a troca de Orb não tem transição.

## 1. Comandos (o maior efeito)

| # | O quê | Onde | Imp. | Esf. |
|---|---|---|---|---|
| 1 | **Verbo + o comando como código.** "Rodou `ls ~/Downloads`", com o comando em monoespaçada num fundo discreto, inteiro e cortado no meio. O resumo de hoje ("ls Downloads") corta o caminho e iguala linhas diferentes. Com descrição do modelo, a linha continua sendo a frase dele ("Conferiu se a vaga do Marcus já saiu"). [decisão] | `ToolIntent.swift:379-415`; `TV:855-861` | A | M |
| 2 | **Tempo verbal e caminho.** "Lendo arquivo /Users/…/SKILL.md" numa ação já feita vira "Leu `SKILL.md`". O título das ferramentas passa a ser conjugado como o dos comandos, e o caminho inteiro fica no aberto. | `ToolIntent.swift:392-397` | A | P |
| 3 | **Estado à vista.** Hoje quem roda agora é a linha mais apagada e não tem sinal de andamento, e o tempo só aparece no hover. Proposta: rodando ganha um indicador no lugar do ícone e texto em `secondary`; feito mostra o tempo em `faint`, sem hover; falhou troca o ícone do tipo por um vermelho, diz "Falhou" e mostra "código N" ao lado. | `TV:851-880, 943-953` | A | M |
| 4 | **Comando aberto como bloco de terminal.** Na largura dos cartões (560 pt), o bloco tem pasta, `$ comando`, uma divisória e a saída. O rodapé mostra "Concluído · 12,4 s" ou "Saiu com código 1 · 2,1 s", e há um botão de copiar. A linha "Código de saída: N", que o `ShellTool` põe no começo da saída, sai do texto e vira esse rodapé. [decisão] | `TV:904-929`; `Engine/Tools/ShellTool.swift:119-121` | A | M |
| 5 | **Comando e saída longos cortados.** O comando usa o mesmo corte da aprovação (9 linhas do começo e 3 do fim), e a saída mostra 8 linhas com "Mostrar tudo (mais N linhas)". Hoje até 4.000 caracteres entram inteiros no meio da conversa. A nota "[full output saved at …]", escrita para o modelo, não aparece no chat. | `TV:918-923, 1484-1508`; `Engine/ContextWindow.swift:676-720` | A | M |
| 6 | **Grupo aberto com um trilho, não em escada.** Uma linha de 1 pt liga as ações ao título do grupo, e o bloco aberto de cada ação fica na coluna delas. Hoje são três níveis de seta iguais (pedido → grupo → ação → cartão), com cartões que começam em 44 ou 66 pt conforme o caso. | `TV:991-1002, 931` | M | P |
| 7 | **Contagem e tempo do grupo à vista.** "Rodou 8 comandos · 1 com erro · 41 s", sem depender do hover. | `TV:1045-1057`; `ToolTally.swift:165-168` | M | P |
| 8 | **Um bloco de código de comando só.** A aprovação usa `raised`, raio 8 e padding 10; a saída usa `surface` com borda, raio 10 e padding 12. Os dois passam a ser o mesmo componente do item 4. | `TV:1700-1722` contra `TV:925` | M | P |
| 9 | **Ícone do pedido.** "Trabalhou por… · N ações" usa `checklist`, o mesmo símbolo do plano da tarefa. Ele passa a ter um símbolo próprio, ou nenhum. | `TV:1228-1246`; `Models.swift:389-401` | B | P |

## 2. Mensagens surgindo

| # | O quê | Onde | Imp. | Esf. |
|---|---|---|---|---|
| 10 | **A narração some ao dobrar o trabalho ao vivo.** Com duas linhas de trabalho, o pedido em andamento vira "Trabalhando · N ações" e o texto que você estava lendo desaparece sem transição. Proposta: dobrar só quando o pedido termina; enquanto roda, o trabalho fica aberto. [decisão] | `MultiOrb/TranscriptFolding.swift:245-250`; `CV:472-486` | A | M |
| 11 | **Fim do streaming refaz o texto.** O `if` entre o texto em streaming e os blocos finais cria `NSTextView`s novas. As palavras no meio do fade pulam para a cor cheia, o cursor some e um parágrafo pode mudar de altura. Isso também acontece cada vez que um parágrafo fecha (`.id(live.closed.count)`). Proposta: uma árvore só, com `streaming` virando falso. [provável] | `TV:487-493, 695` | A | G |
| 12 | **A lista anda duas vezes ao enviar e ao terminar.** Ao enviar, entram a bolha, 12 pt de vão, 12 pt de `TurnGap` e a linha "trabalhando". O ancoramento no fim cola o fim de uma vez, e o `smooth(0.3)` quase não aparece. Ao terminar, a linha "trabalhando" sai e o conteúdo desce cerca de 42 pt. Proposta: reservar a altura da linha "trabalhando" e pôr inserção e rolagem na mesma transação. [provável] | `CV:347-351, 383-393, 547-571, 596-608` | A | M |
| 13 | **Da fila para a conversa, a bolha pisca e desce 12 pt.** A bolha da fila sai na hora e a real nasce transparente. A real também ganha os 12 pt do `TurnGap` da revisão anterior, que a da fila não tem. Proposta: a bolha real nasce visível quando veio da fila, e a da fila ganha o mesmo vão. | `Views/QueuedMessages.swift:28-30`; `CV:428, 442, 1158-1163` | M | P |
| 14 | **"●" solto e fade duplo.** Um parágrafo novo começa com um "●" sozinho numa linha. No primeiro texto, as palavras fazem fade (0,4 s) dentro de uma linha que também faz fade (0,38 s). | `Views/MarkdownBlockViews.swift:22`; `Views/TextFade.swift:42` | M | P |
| 15 | **O avatar salta da linha "trabalhando" para a resposta.** Um some em 0,15 s enquanto o outro sobe 6 pt em 0,38 s. Proposta: a primeira resposta do turno entra só com opacidade, no mesmo tempo. | `CV:972-975`; `TV:438-458` | M | P |
| 16 | **Chat de grupo sem movimento.** As mensagens aparecem secas, a rolagem pula, e a troca de avatar vivo e parado não tem o fade da conversa. Proposta: usar o mesmo `RowEntrance` e a mesma rolagem do chat. | `Views/Groups/GroupChatView.swift:225-256`; `Views/Groups/GroupMessageBubble.swift:153-163` | M | P |
| 17 | **Contador que rola sem respeitar Reduzir movimento** nos cartões de aprovação (`numericText` sem a guarda que o resto usa). | `TV:1683, 1759, 1819` | B | P |
| 18 | **`docs/MOVIMENTO.md` desatualizado.** Ele diz que o texto que chega não anima, mas o `TextFade` faz fade por palavra. Também não descreve a dobra ao vivo e fala de uma marca de sucesso que não existe. Atualizar o doc, mantendo o fade por palavra. | `docs/MOVIMENTO.md:26, 97-100, 111-112` | B | P |

## 3. Lateral esquerda

| # | O quê | Onde | Imp. | Esf. |
|---|---|---|---|---|
| 19 | **O hover da linha do Orb mexe no layout.** O "+" e a seta entram por `if` e encurtam um nome longo a cada passada do mouse. Proposta: uma faixa de largura fixa à direita, só com opacidade animada. | `SV:597-628` | A | P |
| 20 | **Conversas abrem e fecham sem animação.** Recolher a lista e "Mostrar menos" não têm animação: a seta gira e a lista pula. A transição `.unfold` já existe; falta a animação que a dispare. | `AppModel+Chats.swift:30`; `Views/SidebarChatList.swift:45` | M | P |
| 21 | **Seleções que pulam.** A seleção da linha do Orb desliza, mas a do rodapé (Rotinas, Conectores, Skills) e a da conversa trocam de uma vez. | `SV:247`; `Views/SidebarChatList.swift:135` | M | P |
| 22 | **Grupos sem entrada e saída.** Criar ou apagar um grupo aparece seco, ao contrário dos Orbs. | `Views/Groups/SidebarGroupRow.swift:46-57` | B | P |
| 23 | **Um elemento, um estilo.** São quatro casos: | | M | P |
| | - "+" em quatro tamanhos e pesos: fica um só, o `SectionPlus`. | `SV:188, 486`; `Views/SidebarCategoryViews.swift:277`; `Views/SidebarChatList.swift:158` | | |
| | - Seta em `muted` na lateral e `faint` no painel: fica um tom só. | `SV:621`; `Views/InspectorFold.swift:23` | | |
| | - Rotinas com `clock` no menu e `clock.arrow.circlepath` no rodapé: fica um símbolo só. | `SV:438` | | |
| | - Raios literais 6 e 7: passam a `Radius.small`. | `SV:192`; `Views/SidebarChatList.swift:135-205` | | |
| 24 | **Fontes por token.** O nome de linha aparece como literal 13 medium em cinco lugares e como token só no perfil. O contador está em 10 semibold. O grupo começa o texto em 70 pt e o Orb em 46. | `SV:492, 592, 657`; `Views/SidebarCategoryViews.swift:178, 283`; `Views/Groups/SidebarGroupRow.swift:87`; `Views/Groups/StackedAvatars.swift:30, 36` | B | P |
| 25 | **Contador sem a transição da casa.** Ele usa `.scale` crua, e não o `.mark` com fade em Reduzir movimento. | `SV:668` | B | P |

## 4. Painel do Orb (lateral direita)

| # | O quê | Onde | Imp. | Esf. |
|---|---|---|---|---|
| 26 | **A troca de Orb não tem transição.** O painel é reaproveitado de propósito, por desempenho, mas a chave da transição é só a aba. Nome e conteúdo mudam de uma vez, e o `MOVIMENTO.md` pede um fade cruzado de 0,18 s. Proposta: a chave passa a ser aba + Orb, sem refazer o painel. | `BI:75, 244`; `Views/RootView.swift:135` | M | P |
| 27 | **Um estilo de título de seção nas duas barras.** O painel usa o cabeçalho padrão do `Form` (13 semibold branco), e a lateral usa 12 medium `faint`. A rotina e a nota vazia usam 13 semibold, e a lateral 13 medium. [decisão] | `BI:594, 613, 646, 762, 1148, 1450`; `Views/MemoryViews.swift:49` | M | P |
| 28 | **Cinzas e fontes do sistema no meio dos tokens.** São 15 usos de `.secondary` e 8 de `.callout`/`.headline`, ao lado de `Palette.muted`/`faint` e `Typography`. Eles passam aos tokens. | `BI:426, 672, 723, 732, 997-1009, 1111`; `Views/MemoryViews.swift:124-375`; `Views/BrowserPickers.swift:273, 308`; `Views/SheetKit.swift:278` | M | P |
| 29 | **Ícones do painel.** São quatro problemas: | | M | P |
| | - **Cabeçalho:** a pasta e o terminal repetem a aba Pasta e a capacidade Terminal, e desligados ficam em `hint`, que o tema reserva para decoração. | `BI:271-286` | | |
| | - **Rotinas, ícones:** traço e preenchido ficam lado a lado, e o quadrado de 30 pt só repete o horário escrito ao lado. | `BI:1265-1288, 1308, 1338` | | |
| | - **Rotinas, botões:** "Rodar agora" é pílula e "Editar" é texto, na mesma fileira. | | | |
| | - **Lixeira:** é um círculo na rotina e um ícone solto na memória. | `BI:1247`; `Views/MemoryViews.swift:279-285` | | |
| 30 | **Links azuis do sistema.** São seis `.buttonStyle(.link)`, que a revisão de 24/10 já pedia trocar pelo `QuietTextStyle`. Os resumos dos folds têm `.transition(.opacity)` sem animação que a dispare, e o cabeçalho do fold não tem hover. | `BI:548, 561`; `Views/MemoryViews.swift:63, 454`; `Views/BrowserPickers.swift:243, 276, 320`; `Views/InspectorFold.swift:37, 63` | B | P |

## 5. O que fica como está

- **O fade por palavra do texto em streaming.** Ele é barato (só a cor muda, sem refazer o layout), desliga em Reduzir movimento e deixa a chegada do texto macia. O que muda é o doc (item 18) e a troca do fim (item 11).
- **As entradas da sua mensagem, das linhas de ferramenta e dos cartões** (`.rise`, `.emphasis`, uma vez por item e nunca ao reabrir). Elas estão certas; os trancos vêm das trocas.
- **A hierarquia de fontes da lateral** (nome em 13, conversa em 12, legenda em 11). Ela está coerente; falta só passar os literais a token (item 24).
- **O anel e o ponto de estado na lateral e o seletor de abas do painel**, feitos na revisão de 24/10.

## 6. Ordem sugerida

1. **Comandos (itens 1 a 9).** É a reclamação mais forte e muda uma área só (`TV`, `ToolIntent`, `ToolTally`). Primeiro o protótipo, para você aprovar o desenho; depois a implementação, conferida com `--snapshot`. Falta um modo de captura para o comando aberto, e ele entra junto.
2. **Mensagens surgindo: itens 10, 13, 14, 15 e 17**, que são pequenos. Os itens 11 e 12 mexem no streaming e na rolagem, então vão depois, com medida pelo `ScrollBench` e conferência no app aberto.
3. **Lateral esquerda: itens 19 a 25**, e **painel: itens 26 a 30.** São independentes entre si e podem correr em paralelo.
4. **Item 18 (doc)** no fim, com o que tiver entrado.

## 7. Não verificado

- Movimento em execução: nada foi gravado em vídeo, e os itens 11, 12 e 15 vêm do código.
- O comando aberto não tem modo de `--snapshot`. O item 4 foi lido no código e desenhado no protótipo.
- VoiceOver e navegação por teclado nas laterais.
- 760 pt com o painel aberto.
