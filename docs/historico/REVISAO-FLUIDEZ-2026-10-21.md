# Revisão de fluidez e aparência (levantamento de 21/10/2026)

Somente diagnóstico: nenhum código mudou e não houve commit. Este arquivo une três revisões feitas em paralelo sobre a `main` em
`603aade`, com o mesmo pedido:

- **Claude** (Claude Code, com três analisadores Sonnet só de leitura);
- **Codex** (sem subagentes);
- **Devin**.

Cada uma gravou o arquivo inteiro por cima da anterior: Codex às 01:17, Devin às 01:19, Claude às 01:34. As duas primeiras foram
recuperadas dos registros das sessões e unidas aqui.

**Como ler a origem.** Cada achado diz entre colchetes quem o trouxe, por exemplo [Claude, Codex, Devin]. O que só um ou dois
trouxeram foi conferido de novo no código antes de entrar; os números de linha são do `603aade`. Caminhos relativos a `Sources/Orb`.

**O que é medição e o que é leitura.**
- Medição só existe para as abas laterais (`PanelsBench`) e para o perfil dos dados da cópia.
- Rolagem, streaming, troca de Orb e cartões que recolhem **não foram medidos** por nenhuma das três: o que se diz deles vem do
  código, com impacto estimado.
- Nenhuma rodou o `SwitchBench`, pelo mesmo motivo: ele não põe o app como acessório nem esconde a janela, e abriria o Orb na
  frente. Rodá-lo junto com o `PanelsBench` faria dois laços mexerem na seleção ao mesmo tempo.

## Andamento (21/10)

`ScrollBench` criado (`ORB_DATA_DIR=<cópia> ORB_BENCH_SCROLL=<rodadas> Orb --bench-scroll`; opções `_UNFOLD`, `_OPEN`,
`_LONGEST`, `_EVENTS`, `_WIDTH`, `_DISTANCE`, `_SPEED` no cabeçalho do arquivo). O que ele mostrou, com a máquina carregada (load 4
a 14), na cópia dos dados:

- **Compactação:** as conversas longas (664, 2.174 e 2.220 itens) mostram só 30 a 39 itens.
- **Rolagem da conversa longa aberta (172.838 pt):** 94 a 102 fps, 7 a 15% dos quadros acima de 16,7 ms. A volta não fica mais
  leve que a ida.
- **R3 descartado:** o `LazyVStack` descarta as linhas fora da tela; sobram 2 a 4 `NSTextView` vivos no fim.
- **Onde vai o tempo ao rolar:** quase tudo no layout do `LazyStack` do SwiftUI. Montar e medir o texto do Orb soma uns 4%.
- **Ações do Orb no fim da conversa longa:** cerca de 30 ms por ação até o quadro, mesmo dobrada. No perfil, o `scrollTo`
  atrasado (S2) dá cerca de 12% da thread principal e `OrbTranscript.show` (S1) cerca de 10%.
- **R6 desfeito:** antes e depois deram o mesmo, dentro do ruído.

Feito sem medição nova, por ser menos trabalho com o mesmo resultado ou alinhamento direto com a especificação:

- **S1 + R5:**
  - `items` e `rows` avisam sem comparar os arrays elemento a elemento;
  - avatares e candidato a "Refazer" são calculados por revisão no `OrbTranscript`;
  - separadores de hora e o id de cada linha não montam arrays.
- **S2:** o segundo `scrollTo` (150 ms depois) é um só por rajada.
- **S3 (parcial):** o display link do `TextFade` fica em no máximo 60 Hz.
- **T2:** cartões do painel em `.quiet`, sem animar a altura do `Form` (a divisa gira sozinha).
- **T4:** contêineres que mudam de altura no chat ficam sem animação com Reduzir movimento.
- **T5:** `ColumnSizing` recebe o painel como está na tela.
- **Aparência:** A2 (tinta do "Papel" vazio), A3 (dica com o modelo inteiro), A4 (data do arquivo em `faint`), A6 (dica com o
  nome na lateral), A7 (resumo da aprovação cortado no meio).

Fica para depois: R1, R2, R4, S4 a S7, T1, T3, T6 a T9, O1 a O3 e o resto da aparência. A medição do antes e depois deve ser feita
com o Mac parado: cada rodada abre a janela por um instante antes de escondê-la.

## Resumo

Os gargalos que mais explicam o que você sente, em linguagem simples:

1. **Cada ação do Orb refaz a conversa inteira e rola até o fim duas vezes.** [Claude, Codex, Devin]
   - O texto que chega a cada 33 ms está bem isolado e não mexe na lista.
   - Cada ferramenta que começa ou termina (e cada cartão ou nota) muda os itens. O Orb então reagrupa a conversa toda do zero e
     faz um `scrollTo` animado até o fim, mais outro 150 ms depois, sem juntar os pedidos.
   - Num turno com muitas ferramentas numa conversa longa, isso se repete dezenas de vezes: é o engasgo durante o streaming e o
     "puxão" para o fim.
2. **As palavras que chegam acendem a 120 quadros por segundo.** [Claude, Codex, Devin] O `TextFade` usa um relógio de tela na
   thread principal durante a resposta inteira e não confere se o texto está visível. Concorre com a rolagem e contraria a
   `MOVIMENTO.md` ("nunca animar por token").
3. **A lista é preguiçosa por linha, mas o que existe dentro de uma linha não é.** [Claude, Codex, Devin]
   - Uma resposta mede o texto inteiro ao aparecer.
   - Um grupo de ações aberto monta todas as ações de uma vez. Na cópia há uma sequência de 84.
   - As linhas já vistas continuam montadas, e uma largura nova refaz o layout de todas.
4. **As respostas ficaram de fora da proteção de largura de 20/10.** [Codex, Devin] A bolha da resposta pede largura exata, por
   exceção deliberada. Ao abrir uma lateral, ela ainda mede o texto em cada largura nova.
5. **As transições sobrepõem árvores grandes e animam altura onde a especificação manda não animar.** [Claude, Codex, Devin]
   - A troca de Orb mantém as duas conversas na tela durante o fade.
   - Os cartões novos do painel (975ae5f) animam linhas de `Form`.
   - Com Reduzir movimento, a altura dos grupos abertos ainda anima.

---

## Medições

### Abas laterais (`PanelsBench`)

Os três rodaram o medidor em cópias dos dados (2.220 itens na conversa maior, tela de 120 Hz, janela de 1396×888), com você
usando o Mac. **Os binários foram diferentes, então os números não se comparam entre as tabelas.**

**Claude: release recompilado no HEAD** (`swift build -c release -Xswiftc -DORB_DEV_TOOLS`), load average entre 6 e 9. Alternou
com a versão de antes da prévia na lateral (`ee1c6d2^`) para separar regressão de ruído.

| Rodada | Painel fecha | Painel abre | Sidebar fecha | Sidebar abre |
|---|---|---|---|---|
| atual, 2.220 itens | 110,8 fps / pior 24,7 ms | 107,7 / 46,0 | 89,7 / 29,4 | 83,8 / 27,3 |
| atual (2ª) | 100,0 / 23,9 | 98,8 / 38,5 | 87,5 / 31,3 | 87,6 / 29,8 |
| atual (3ª) | 93,1 / 20,6 | 101,4 / 25,0 | 92,2 / 18,0 | 90,2 / 22,6 |
| atual (4ª) | 100,0 / 27,6 | 98,8 / 32,3 | 91,2 / 27,4 | 87,5 / 26,9 |
| atual, 89 itens (`ORB_BENCH_EMPTY=1`) | 114,5 / 22,0 | 112,6 / 27,1 | 93,5 / 29,4 | 93,4 / 28,2 |
| `ee1c6d2^`, 2.220 itens | 114,9 / 16,7 | 105,8 / 16,7 | 95,7 / 20,2 | 96,2 / 19,3 |
| `ee1c6d2^` (2ª) | 103,3 / 16,7 | 99,4 / 16,7 | 92,2 / 22,0 | 88,9 / 25,0 |

**Codex: debug existente** (`.build/debug/Orb`, de 20/10 às 23:39, antes dos dois últimos commits), quatro rodadas.

| Conversa | Painel fecha | Painel abre | Sidebar fecha | Sidebar abre |
|---|---|---|---|---|
| 2.220 itens | 104,4 / 17,6 ms | 102,8 / 16,7 | 88,8 / 33,2 (4% > 25 ms) | 87,0 / 23,1 |
| 89 itens | 118,8 / 16,7 | 109,6 / 26,6 | 97,5 / 25,4 | 91,8 / 26,7 |

**Devin: o mesmo debug**, três rodadas.

| Conversa | Painel fecha | Painel abre | Sidebar fecha | Sidebar abre |
|---|---|---|---|---|
| 2.220 itens | 92,5 / 27,9 ms (3%) | 87,5 / 46,3 (3%) | 78,8 / 42,3 (5%) | 72,2 / 28,5 (9%) |

O que as três medições dizem juntas:
- **Painel direito:** segue no patamar do `ColumnSizing` de 20/10, com 0 a 4% de quadros acima de 25 ms no release.
- **Lateral:** ficou abaixo dos 96 a 100 fps de 20/10 nas três medições. A comparação intercalada do Claude (atual 84 a 92,
  `ee1c6d2^` 89 a 96) cai dentro do ruído da máquina carregada, então **não há evidência de que a prévia da lateral pesou**.
  Os números do debug não servem de referência de produção [Codex, Devin].
- **Tamanho da conversa:** a de 89 itens contra a de 2.220 difere pouco. Abrir e fechar as abas não depende mais do tamanho.
- **Limites do medidor** [Codex, Devin]:
  - conta ticks de display link nos primeiros 0,4 s, não quadros comprovadamente apresentados;
  - o "turno mais longo" cobre os 0,9 s inteiros e não se compara ao pior quadro;
  - o limiar de 25 ms deixa passar quadros que já perderam o orçamento de 8,3 ms;
  - com a janela transparente e fora da tela, os Orbs e os brilhos ficam parados, então não mede o custo visual completo.

### Perfil dos dados da cópia [Codex, Devin; o 84 foi reconferido pelo Claude]

| Conversa | Itens | Respostas do Orb | Maior resposta | Maior sequência de ferramentas |
|---|---:|---:|---:|---:|
| 1 | 89 | 29 | 1.781 B | 5 |
| 2 | 664 | 213 | 2.529 B | 8 |
| 3 | 2.174 | 487 | 2.668 B | 24 |
| 4 | 2.220 | 534 | 4.224 B | 84 |

- Nenhuma resposta passa de 64 KiB (o limite do `MarkdownCache`). O maior trecho sem linha em branco tem 1.301 B.
- Ou seja, "conversa longa" aqui quer dizer **muitos itens**, não respostas gigantes. Isso enfraquece a hipótese de parágrafo
  enorme (S4) nos seus dados atuais, mas não a do custo de montar muitas linhas.

### O que não produziu resultado

- **`SwitchBench`, quente e frio:** não rodou em nenhuma das três (ver o topo).
- **Time Profiler via `xctrace`** [Codex]: o trace carregou `build/Orb.app` em vez do binário do medidor e o processo morreu
  por SIGKILL no limite. A captura foi descartada.
  - Não repetir esse lançamento automático: anexar ao PID do medidor já aberto e conferir o binário carregado.
  - O Devin confirmou que os modelos `SwiftUI`, `Time Profiler` e `Animation Hitches` existem no `xctrace`, mas não capturou.
- **Medidor que não sai** [Claude]: a versão `ee1c6d2^` ficou 9 min presa em `NSApp.terminate` depois de imprimir o total, uma
  vez em duas, até ser encerrada. A atual saiu sozinha em todas as rodadas.
- **Temporários:**
  - Devin deixou a cópia e os logs em `/tmp/orb-revisao-2026-10-21-_o6u3dj4/`.
  - Claude deixou os seus no scratchpad da sessão.
  - Nada disso está no repositório.

---

## R. Rolagem

R1. **O que existe dentro de uma linha não é preguiçoso** (impacto médio; alto em respostas, tabelas ou saídas grandes)
[Claude, Codex, Devin].
- O `LazyVStack` (`Views/ChatView.swift:260`) é preguiçoso por linha, mas cada `MarkdownChunk` é um `VStack`
  (`Views/MarkdownBlockViews.swift:19-37`).
- Uma sequência de prosa vira um único `ProseTextView`, e `size(forWidth:)` chama `ensureLayout` e enumera todas as linhas
  (`Views/SelectableProse.swift:267-288`). Uma tabela é um `Grid` inteiro.
- Entrar numa linha alta mede tudo o que ela tem, mesmo que só um pedaço apareça. O cache de tamanhos é da instância
  (`:466`, LRU de 16), não global.
- Correção: medir primeiro a primeira passagem e a volta à mesma linha; só então limitar o trabalho por trecho. Não trocar a
  prosa por vários `Text`.
- Risco: alto (seleção corrida, copiar e citar, busca, estimativa de altura).

R2. **Um grupo aberto monta todos os filhos de uma vez** (impacto alto ao abrir um grupo grande) [Devin, Codex].
- `ToolGroupRow` abre um `ForEach` dentro de `VStack` (`Views/TranscriptViews.swift:947-956`). `WorkGroupRow` põe `content()`
  num `VStack` (`:1148-1151`) e recalcula `TranscriptFolding.rows(for:)` ao abrir (`Views/ChatView.swift:459`).
- Cada saída aberta é um `Text` inteiro. A cópia tem uma sequência de 84 ações.
- O limite de 6 do stagger (`Motion.swift:35-38`) limita o **atraso**, não quantos filhos são criados e animados: os demais
  entram com o atraso do sexto [Codex].
- É diferente do A6 de 12/10 (resumo do grupo fechado), que continua recusado.
- Correção: revelar grupos grandes aos poucos, preservando os ids que a busca usa; animar só o cabeçalho e um fade.
- Risco: médio a alto (a busca precisa abrir a parte certa, e a rolagem não pode pular ao carregar mais).

R3. **As linhas já vistas ficam montadas, e uma largura nova refaz o layout de todas** (impacto médio, suspeita) [Claude].
- Na prática, o `LazyVStack` do macOS não descarta as linhas criadas. Depois de rolar até o começo de uma conversa de 2.000
  itens, centenas de `NSTextView` ficam vivos.
- Abrir o painel ou arrastar o divisor mede todos de novo na largura nova. O degrau de 16 pt (48df7e0) poupa os quadros do meio
  do movimento, mas a largura final paga tudo de uma vez.
- Correção, se o `ScrollBench` confirmar: cache de altura por (texto, largura) fora da instância; em último caso,
  `List`/`NSTableView`, que reciclam linhas.
- Risco: alto.

R4. **Uma imagem ainda não vista muda a altura da linha depois de aparecer** (impacto médio na primeira passagem, baixo depois)
[Codex; também visto pelo analisador do Claude].
- `Views/MarkdownBlockViews.swift:79-90`: sem tamanho em cache, a imagem começa em 240×150 pt.
- A tarefa assíncrona (`:117-131`) publica depois o tamanho real, até 420×300. Isso desloca a leitura mesmo sem travar a CPU.
- Correção: guardar as dimensões ao carregar a conversa, ou reservar uma caixa estável até conhecê-las.
- Risco: médio.

R5. **Começar e terminar de rolar reavalia o corpo inteiro da lista** (impacto baixo a médio em conversas longas)
[Claude, Codex, Devin].
- `Views/ChatView.swift:717` e `:721` escrevem no `@State followsBottom`.
- Cada escrita reavalia o `body` de `TranscriptList` (`:224-251`):
  - `ReplyAvatars(items)` (`Views/EntranceMotion.swift:384-398`, uma passada inteira mais um `Set`, código novo do 97a79b1);
  - `RewindRows.redoTarget` e `entrances.observe`;
  - o diff dos ids do `ForEach` e a troca do `defaultScrollAnchor` (`:578`).
- Acontece uma vez no início e outra no fim do gesto, nunca por pixel nem por token.
- Correção: calcular os avatares e o "Refazer" junto da projeção da conversa, por revisão (ver S1), para o estado da rolagem só
  consultar o resultado.
- Risco: baixo a médio (editar, refazer, trocar de conversa).

R6. **Toda linha carrega opacidade, escala e deslocamento mesmo depois de entrar** (impacto baixo) [Claude].
- `Views/EntranceMotion.swift:255-265` (`RowEntrance`) aplica `Entrance` e um `onAppear` em todas as linhas.
- Correção: aplicar só enquanto `isNew`, mas sem trocar a cadeia de modificadores por um `if` (isso recriaria a view).
- Risco: baixo.

## S. Streaming

S1. **Cada mudança de item refaz a dobra da conversa inteira** (impacto médio a alto em conversas longas) [Claude; o Devin
registra o mesmo caminho, sem priorizar].
- `LiveText.swift:164-169`: `show(_:)` chama `refold()` a cada mutação de itens (início e fim de ferramenta, aprovação, nota,
  evento).
- `refold()` (`:177-190`) refaz tudo do zero:
  - `CompactedFold.of`;
  - `TranscriptFolding.foldedRows` (`MultiOrb/TranscriptFolding.swift:35`), com cópias `Array(items[index..<next])`;
  - `TimeSeparators.breaks` sobre `rows.map { $0.items.map(\.date) }`;
  - com compactação, um `Set` de ids.
- O `rows` novo faz o `ForEach` (`Views/ChatView.swift:274-285`) comparar todos os ids, e cada `ToolGroupRow` comparar os itens
  em profundidade (`Views/TranscriptViews.swift:927-928`).
- É maior que o B13 de 12/10, que tratava só do `Set` do prefixo: aqui é a projeção inteira, refeita duas vezes por ferramenta.
- Correção: refold incremental, refazendo só a cauda a partir da linha anterior à do primeiro item alterado, e guardando ali
  `ReplyAvatars` e `redoTarget` (R5).
- Risco: médio (as regras de troca entre Orbs e de pedido olham para trás; há testes da dobra).

S2. **Cada mudança de item rola até o fim por id, com animação, e de novo 150 ms depois** (impacto médio, alto em rajadas)
[Claude, Codex, Devin].
- `Views/ChatView.swift:366-375`: `onChange(of: transcript.revision)` chama `followResumedTurn` (`:538-546`), que faz um
  `scrollTo` animado e cria uma `Task` para repetir em 150 ms. Não há cancelamento nem junção dos pedidos [Codex, Devin].
- Uma revisão nem sempre muda a altura: fechar texto ou mudar o estado de um item também conta [Codex].
- O comentário do próprio arquivo (`:567-570`) diz que o `scrollTo` por id "custa tanto quanto a conversa é longa", e o
  `defaultScrollAnchor` (`:578`) já segura o fim no caso comum.
- Não acontece por flush de texto: `live.append` não muda `revision`.
- Correção: uma única correção pendente, cancelável, só quando nasce uma linha inteira (cartão, resposta de outro Orb, evento)
  ou quando a distância até o fim passa de um limite. Manter o empurrão do envio.
- Risco: médio (o segundo `scrollTo` corrige alturas estimadas; testar a conversa que chega do disco, o cartão alto e a retomada
  por outro Orb).

S3. **`TextFade` roda na taxa da tela durante todo o streaming e não confere se está visível** (impacto médio, talvez alto ao
rolar durante a resposta) [Claude, Codex, Devin].
- O `CADisplayLink` é criado sem `preferredFrameRateRange` (`Views/TextFade.swift:125-129`): 120 Hz numa tela ProMotion.
- `run()` só exige `view.window != nil` [Codex, Devin]: não confere app ativo, oclusão, ancestral oculto nem a área visível.
- Cada palavra leva 0,4 s mais até 0,1 s de escalonamento (`:12-16`). Com um flush a cada 33 ms, o link não para.
- O limite de 160 palavras vale por chegada, não para a fila toda [Codex].
- Cada quadro aplica `addTemporaryAttribute` palavra a palavra e redesenha. A cada flush, `setAttributedString` apaga os
  atributos e `restore()` (`:107-110`) os reaplica.
- Veio do `a770a65` (13/10), depois do levantamento de 12/10 [Codex, Devin]. Diverge da `MOVIMENTO.md` §0.7 e §2.2, que nem cita
  o `TextFade`. Reduzir movimento desliga o efeito (`Views/SelectableProse.swift:433`).
- Correção: primeiro um A/B só com esse efeito. Se ele ficar:
  - parar fora da área visível e com o app inativo, como o Orb e o brilho já fazem;
  - 30 a 60 Hz e 0,25 s.
  Se sair, o texto simplesmente aparece, como a especificação pede.
- Risco: baixo (cosmético). É uma decisão de produto.

S4. **O parágrafo final é refeito inteiro a cada flush** (impacto baixo nos seus dados, alto num trecho longo sem linha em
branco) [Claude, Codex, Devin].
- `LastParagraph` (`Views/TranscriptViews.swift:642-653`) usa `MarkdownChunk(source: live.tail, streaming: true, cached:
  false)`.
- O parse inline dos itens fechados já tem cache (33e22bf, A2 de 12/10). Mas `ProseText.make` ainda monta um
  `NSAttributedString` novo, e `show` troca o `textStorage` inteiro e zera as medidas (`Views/SelectableProse.swift:57-102,
  246-262`).
- O "custo constante" da `ARQUITETURA.md` é uma meta mais forte que a garantia atual [Codex].
- Correção, só se o perfil mostrar esse caminho:
  - fechar o trecho também por tamanho;
  - ou atualizar só o sufixo no `textStorage`.
- Risco: médio para o primeiro, alto para o segundo (lista, cercas de código, cursor, faixas do fade, seleção).

S5. **No macOS 14, rolar para cima durante a resposta não para o acompanhamento** (impacto alto no macOS 14, nulo no seu Mac)
[Codex, Devin].
- O pacote declara `.macOS(.v14)` (`Package.swift:6`), mas `BottomFollowing` só detecta o gesto no macOS 15+
  (`Views/ChatView.swift:701-730`); no 14 devolve o conteúdo.
- `BottomFollower.follows` começa `true` e o crescimento continua chamando `scrollTo` até 5 vezes por segundo (`:585-620`).
- O próprio comentário admite: "on macOS 14 the chat always follows". A `ARQUITETURA.md:575` promete "segue só enquanto você
  não rolou para cima".
- Correção: observar o início e o fim da rolagem no `NSScrollView` nessa versão, ou subir o mínimo do app para o macOS 15.
- Risco: médio.

S6. **Uma subida curta perto do fim volta a seguir** (impacto médio perto do fim, suspeita de comportamento) [Devin; o Codex o
cita como não confirmado].
- `FollowRule` (`Views/ChatView.swift:661-680`) volta a seguir quando o fim está a menos de 48 pt, mesmo depois de uma subida
  intencional maior que o jitter de 8 pt.
- Exemplo: o fim a 24 pt e uma subida de 24 pt dão `follows == true`. O próximo crescimento (S2) leva você de volta ao fim.
- Correção: retomar só por volta deliberada ao fim, envio ou comando, preservando o caso do dedo parado enquanto a lista
  cresce.
- Risco: médio (os testes de `FollowRule` cobrem o caso).

S7. **O subtítulo da janela reavalia o `ChatView` a cada passo** (impacto baixo) [Claude].
- `Views/ChatView.swift:71` lê `live.shownWork?.headline`, que acompanha o `WorkLine` inteiro (muda a cada ferramenta, mesmo
  com a frase igual).
- Correção: `live.headline: String?` gravado com `assign`. Risco baixo.

## T. Transições

T1. **A troca de Orb compõe duas conversas inteiras durante o fade, e a troca de conversa usa um fade mais longo** (impacto
médio a alto, não medido) [Claude; a parte da troca de conversa, Codex].
- `Views/ChatView.swift:26-31`: `TranscriptList(...).id(botID).transition(.pageSwap)` com `Motion.crossFade`. Enquanto a velha
  sai (`Motion.swapOut`, `Motion.swift:58-60`), as duas `ScrollView` com seus `NSTextView`s passam por opacidade animada.
- A troca de conversa do mesmo Orb (`Views/ChatView.swift:243-249`) usa `.transition(.opacity)` simétrico, com cross-fade de
  0,18 s, em vez do `.pageSwap`. As duas árvores ficam juntas por mais tempo, e isso diverge do padrão A da §2.13 [Codex].
- O `SwitchBench` mede até o primeiro quadro: os quadros do fade nunca foram medidos.
- Correção: só a entrada faz fade e a velha sai na hora; no mínimo, alinhar a troca de conversa ao `.pageSwap`.
- Risco: baixo a médio (ajustar a §2.9).

T2. **Os cartões novos do painel animam linhas de `Form`** (impacto médio de acabamento, baixo a médio de CPU) [Claude, Devin].
- `Views/InspectorFold.swift:71-78` aplica `.adapted(.unfold, …)`, e o clique faz `withAnimation(Motion.content)`
  (`Views/BotInspector.swift:306-309`).
- Vale para "Modelo e modo", "Pode usar" e "Navegar na web" (`.foldContent()` entre `:340` e `:370`, e
  `Views/BrowserPickers.swift:124-158`).
- O `Form` agrupado é uma tabela AppKit: abrir reanima as alturas e reavalia o painel. A `MOVIMENTO.md` padrão H (`:336`) e
  "Seções dentro de `Form`" (`:363-364`) pedem `.quiet`, com a altura mudando de uma vez.
- O Reduzir movimento destes cartões está certo: `FoldMotion` devolve `nil` [Devin, Codex].
- Correção: `.quiet` no `FoldContent` e animação só na divisa; ou documentar e medir a exceção.
- Risco: baixo.

T3. **As respostas ficaram de fora do degrau de largura** (impacto médio, depende da largura e do texto visível) [Codex, Devin].
- `replyBubble()` define `proseHugsText = true` (`Views/TranscriptViews.swift:112-115`).
- `sizeThatFits` passa `steps: !proseHugsText` (`Views/SelectableProse.swift:438`), ou seja `false` para toda resposta,
  inclusive em streaming. O cache LRU de 16 larguras não evita as faltas numa sequência de larguras novas.
- A exceção é deliberada e documentada em 20/10: a bolha abraça a linha mais longa.
- Enquanto a coluna está acima do teto de 760 pt (`Views/ChatView.swift:318`), abrir o painel nem muda a largura do texto
  [Devin].
- Correção: perfilar primeiro; se dominar, uma largura de layout estável durante o movimento, separada da largura da bolha,
  voltando à exata ao assentar. Não basta trocar `steps` para `true`.
- Risco: alto (quebras, corte, altura, seleção).

T4. **Com Reduzir movimento, a altura dos grupos ainda anima** (impacto médio de acessibilidade) [Codex, Devin].
- `Motion.adapted` devolve `Motion.fade`, não `nil` (`Motion.swift:40-42`).
- Usado no contêiner que muda de altura, a transação continua animando o layout, mesmo com o filho em `.quiet`:
  - expandir uma ferramenta (`Views/TranscriptViews.swift:802`);
  - o grupo aberto (`:959`);
  - o trabalho de um pedido (`:1154`);
  - a lista no início e no fim do turno (T6).
- Correção: `nil` no contêiner com Reduzir movimento e fade só nos filhos, como `FoldMotion` já faz. Não mudar `Motion.adapted`
  no app inteiro: quebraria fades legítimos.
- Risco: médio se for global, baixo caso a caso.

T5. **O `ColumnSizing` pode não cortar a medida do painel ao voltar para a página do Orb** (impacto médio quando acontece,
suspeita) [Claude].
- `Views/ColumnSizing.swift:20-24` só refaz o corte quando `panelIsOpen` muda, e recebe `model.showInspector`
  (`Views/RootView.swift:122`).
- Ao ir para Rotinas, Conectores ou Skills, o `.inspector` fecha pela página (`:126-129`), sem mexer em `showInspector`. Se a
  coluna voltar com um `NSHostingView` novo, ela volta ao `sizingOptions` padrão.
- Correção: passar o `Bool` efetivo (`showInspector && page == .orb && …`). Risco baixo.

T6. **A lista inteira entra numa transação animada no início e no fim de cada turno** (impacto baixo a médio) [Claude; o Devin
o cita como pedido pela especificação].
- `Views/ChatView.swift:313`: `.motion(Motion.content, value: isWorking)` no `LazyVStack`, embora só a `WorkingLine`
  (`:306-307`) precise.
- O pico coincide com o fechamento do texto e com o refold [Devin]. Medir separadamente.
- Correção: animar só a `WorkingLine`. Risco médio.

T7. **Trocar de aba do painel monta dois `Form` em fade** (impacto baixo a médio, conforme a especificação) [Claude].
`Views/BotInspector.swift:59-74`: `Form { switch tab }.id(tab).transition(.pageSwap)`. A saída sem fade (como em T1) vale aqui,
com risco baixo.

T8. **O painel não faz o fade que a especificação promete ao trocar de Orb** (impacto baixo, é contrato) [Devin, Codex; também
visto pelo analisador do Claude].
- `Views/RootView.swift:130-136` reaproveita o mesmo `BotInspector` sem `.id(botID)`, de propósito: recriá-lo "levava um terço
  da troca".
- O `.transition(.opacity)` ali não faz nada. A §2.13 da `MOVIMENTO.md` (`:340-343`) promete o fade cruzado.
- Correção: ajustar a especificação e tirar a transição morta. Não pôr `.id(botID)` no painel.

T9. **Orbs que não descansam** (impacto baixo) [Claude]. O d409ff5 cobre o chat vazio, as boas-vindas, o palco do grupo e a
proposta. Ficaram de fora:
- o Orb de 28 pt da barra de menus (`Views/QuickAskView.swift:326`);
- os palcos interativos do editor (`Orbs/OrbEditor.swift:128`, `Views/Multi/WizardPreviewPane.swift:135`), exceção da
  especificação.

Correção, se quiser: `SettlingOrb` no da barra de menus.

## O. Observação

O caminho do streaming está bem isolado, e as três revisões chegaram a isso [Claude, Codex, Devin]:
- `AppModel.sessions` e `lives` são `@ObservationIgnored` (`AppModel.swift:58, 173`);
- o texto vivo fica em `LiveText`;
- as linhas são `.equatable()`;
- a lateral não reavalia as linhas dos outros Orbs (`SidebarBotRow` lê só o `live` do seu Orb).

O que sobra:

O1. **O compositor reavalia o corpo inteiro a cada tecla** (impacto médio) [Claude].
- O A1 de 12/10 foi resolvido entre Orbs, mas não dentro do compositor.
- `Views/ComposerView.swift:35-58`: `draft.wrappedValue` alimenta `hasText`, `hasContent`, `canSend` e `hint(lane)` no `body`.
  `slashMatches` (`:367-369`) e o `.onChange` (`:169`) também dependem dele.
- Correção: campo, `onChange` e lista de "/" numa subview; o pai recebe só um `Bool hasText`.
- Risco: médio (foco, `onKeyPress`, ↑↓/Tab/Esc, `ComposerCaretFollower`).

O2. **Pequenos custos repetidos no corpo da lateral** (impacto baixo) [Claude].
- `Views/SidebarView.swift`: `Set(...)` duas vezes por render (`:103, 108`), `order.firstIndex(of:)` por linha (`:55`) e
  `SidebarDrop.sections` sem arrasto (`:69-74`).
- `Views/SidebarCategoryViews.swift:29`: `filter { model.botIDs.contains($0) }`.
- Só roda na troca de Orb, no arrasto e na criação. Risco baixo.

O3. **O chat do assistente de criação não segue as regras do chat principal** (impacto baixo, outra superfície) [Devin].
- `Views/Multi/WizardChatView.swift:28-73` usa `VStack`, chama `scrollTo` animado a cada mensagem (`onChange(of:
  runner.messages.count)`) e não tem a regra de "você rolou para cima".
- Medir em sessões longas de criação antes de mexer.

## A. Aparência

Tudo aqui é leitura de código, sem capturas. Confirmar no CI antes de mexer.

A1. **Os cabeçalhos dos cartões que recolhem não respondem ao ponteiro** (impacto médio de descoberta) [Claude, Codex, Devin].
- `FoldRowStyle` (`Views/InspectorFold.swift:30-35`) só apaga a 0,7 ao pressionar. O mesmo vale para o cabeçalho de "Navegar na
  web" (`Views/BrowserPickers.swift:177-187`) [Devin].
- As linhas vizinhas acendem com `hoverFill`. A faixa de compactação (`Views/ChatView.swift:130-135`) tem hover, mas muda o fundo
  sem as curvas de entrada e saída [Codex].
- Correção: `hoverFill` no `FoldHeader`, com os tokens existentes, conferindo o foco por teclado. Risco baixo.

A2. **"Papel" usa tinta decorativa e não recebe foco pelo teclado** (impacto médio de legibilidade e acesso) [Claude, Codex,
Devin].
- `Views/BotInspector.swift:899-912`: vazio, o texto usa `Palette.hint`, que o tema reserva à decoração (`Theme.swift:43-44`);
  pede `faint` para placeholders.
- Contraste nominal sobre `chrome` (#111111): 3,27:1 com `hint` e 5,56:1 com `faint` [Codex, Devin].
- Fora da edição é um `Text` com `onTapGesture` [Codex, Devin]. Tem traço de botão e ação para o VoiceOver, mas não entra no
  Tab nem abre com Return.
- Correção: `Palette.faint` e um `Button` que abre o campo, testando o commit ao perder o foco e a troca de Orb. Risco baixo.

A3. **O nome do modelo, cortado no cartão fechado, não aparece inteiro no ponteiro** (impacto baixo, mais perto de 244 pt)
[Codex].
- `Views/BotInspector.swift:321-337`: `lineLimit(1)` com corte no fim, e a dica do cabeçalho (`Tip.toggleModelCard`) só fala de
  abrir e fechar. O nome inteiro está só no valor de acessibilidade.
- Correção: `.help(modelName)` no resumo. Risco baixo.

A4. **Data do arquivo em `.tertiary` do sistema** (impacto baixo a médio) [Claude]. `Views/BotInspector.swift:966` fica mais
apagado que `Palette.faint` no escuro. Correção: `Palette.faint`.

A5. **Linhas clicáveis só com `onTapGesture`, sem hover nem foco** [Claude]:
- arquivo do painel (`Views/BotInspector.swift:971-972`, onde dois gestos ainda atrasam o clique simples);
- "última execução" da rotina (`:1208`).
- Correção: `Button` `.plain` com `hoverFill`, e o duplo clique por `simultaneousGesture`.

A6. **Nome do Orb na lateral cortado sem dica** [Claude]. `SidebarBotRow` não passa `help:` a `SidebarRow`, cujo padrão é vazio
(`Views/SidebarView.swift:236`). Correção: `help:` com o nome e a prévia.

A7. **Resumo de aprovação decidida cortado, com dica que só diz "abrir/fechar"** [Claude]. `Views/TranscriptViews.swift:1736,
1748`. Correção: `.truncationMode(.middle)` e o detalhe na dica.

A8. **`+` da seção da lateral em `Palette.hint` em repouso** [Claude]. `Views/SidebarView.swift:174`: é ícone sem rótulo, no
limite de 3:1. Correção: `Palette.faint` em repouso.

A9. **Brancos com opacidade solta e nenhuma escala de raio** (impacto baixo) [Claude].
- `Views/WelcomeView.swift:494, 535, 656` e `Views/TranscriptViews.swift:1318` usam `Color.white.opacity(...)` quase igual a
  `ghostHover`/`ghostSelected`.
- Não há `Radius` no `Theme.swift`: bolha 16, compositor 20, drop 18, cartões 8/10/12. Criar os tokens e migrar aos poucos.

## Onde a especificação pede trabalho caro ou está desatualizada [Devin, Codex; conferido pelo Claude]

- **Lateral que muda a largura por 0,25 s** (`MOVIMENTO.md:340-343`): é movimento geométrico real, e o texto reflui ao cruzar o
  teto de largura. Não cabe na regra "só opacidade e transformação" (`:24-26`). Vale manter, mas com orçamento de layout e a
  exceção das bolhas explícita (T3).
- **Detalhes que abrem com as vizinhas deslizando** (`:126-134`, `:330`): bom em árvores pequenas, caro num grupo de dezenas de
  ações. Falta um limite de tamanho para passar a fade com altura instantânea (R2, T4), além do limite de atraso do stagger.
- **Fade cruzado do painel ao trocar de Orb** (`:340-343`): o código reaproveita o painel de propósito (T8).
- **Alvo da linha de trabalho** (`MOVIMENTO.md:227`): ainda pede fonte monoespaçada de 12 pt. O f53a6e8 passou, de propósito,
  para a fonte do sistema.
- **`ARQUITETURA.md:576`** diz que trocar de Orb recria o `ChatView`. Hoje `Views/RootView.swift:159-164` conserva o `ChatView` e
  troca só a conversa (cea9d28; mediana de ~340 para ~200 ms, número histórico). Não restaurar o `.id` na árvore inteira com base
  na frase antiga.

---

## Ordem sugerida de implementação

1. **Medir antes de refatorar** [Codex, Devin; Claude concorda para os itens de risco médio ou alto]:
   - criar o `ScrollBench` (abaixo);
   - dar ao `SwitchBench` o modo acessório e oculto do `PanelsBench`;
   - medir sempre num release com `ORB_DEV_TOOLS`, identificado pelo commit.
2. **Correções localizadas e de risco baixo, que não dependem de medição:**
   - **T2:** `.quiet` nos cartões do painel;
   - **T5:** `ColumnSizing` com o `Bool` efetivo;
   - **T4:** `nil` no contêiner dos grupos com Reduzir movimento.
3. **S3:** A/B do `TextFade`. Removê-lo é a intervenção de menor risco entre as centrais; se ficar, parar fora de vista e limitar
   a taxa.
4. **S2 e S6:** uma única correção de rolagem pendente e cancelável, com testes de abertura no fim, dedo parado, subida curta e
   rajada de ferramentas. **S5** à parte, conforme houver usuários no macOS 14.
5. **S1 com R5:** refold incremental, com avatares e "Refazer" calculados ali.
6. **R2:** grupos grandes revelados aos poucos, validados com a sequência de 84 ações e com a busca abrindo um filho oculto.
7. **T1, T3, R1, R3 e S4, guiados pelo perfil:** um de cada vez. Têm risco alto e causas diferentes.
8. **O1, S7, T6, T7, R4, R6, O2 e O3,** se as medições mostrarem que ainda pesam.
9. **Aparência A1 a A9 em lote,** conferida com captura no CI (nunca `--snapshot` local), e a especificação reconciliada.

## Descartados e itens que não reabrimos

- **"A lista não é preguiçosa" ou muda de id a cada render** [Claude, Codex, Devin]. Não procede.
  - Há `LazyVStack`, ids estáveis e `.equatable()` (`Views/ChatView.swift:260, 295-298, 415-422`).
  - `.id(botID)`, `.id(generation)` e `.id(isLoading)` só mudam em trocas reais.
  - `.id(live.closed.count)` troca o trecho final só quando um parágrafo fecha.
- **"Um `scrollTo` por token no macOS atual"** [Codex, Devin]. Falso: `replyGrew` é `nil` no macOS 15+
  (`Views/ChatView.swift:514-517`). O S2 é por revisão estrutural.
- **"Rolar para cima sempre puxa de volta no macOS 15+"** [Codex]. Não confirmado: o gesto suspende `followsBottom` e as tarefas
  conferem o estado antes de rolar. Os casos reais estão em S2, S5 e S6.
- **"O `AppModel` invalida todas as linhas a cada flush"** [Claude, Codex, Devin]. Não procede (ver O).
- **Itens de 12/10 que não reabrimos sem medição nova:**
  - A2 (cache do parse dos itens fechados, já feito; o S4 é o custo que sobra, não o mesmo item);
  - A6 (`ToolGroupRow` com `==` profundo);
  - A7 (recusa de edição no hover);
  - A9 / item 9 (pico no fim de uma resposta longa, `Views/TranscriptViews.swift:439-441`: procede, mas foi recusado; medir antes);
  - B13 / B24 / B31 / B38.
  [Claude, Codex, Devin]
- **Abas laterais lentas de novo e prévia da lateral pesando:** medido acima, sem evidência [Claude, Codex, Devin].
- **Orbs e brilhos rodando sem ninguém ver** [Claude, Codex, Devin]. `SettlingOrb` descansa depois de 6 s
  (`Orbs/SettlingOrb.swift:24-31`), o `OrbDriver` compartilha o relógio e o brilho confere app ativo e área visível
  (`Theme.swift:299-344`). O `TextFade` é outro mecanismo (S3).
- **`TimelineView` e `Canvas` como problema** [Claude, Codex, Devin]: meia-noite, 60 s e 1 s; o `Canvas` do Orb é estático.
- **Imagens e Orbs decodificados na main** [Claude, Codex, Devin]: fora dela, com cache (`Views/ImageThumbnails.swift:61-99`,
  `Orbs/OrbModel.swift:397-517`). O pré-aquecimento ainda cita 60 pt enquanto o cabeçalho usa 46 pt [Codex]: cobertura
  imperfeita, mas assíncrona e sem peso visível.
- **`ViewThatFits` dos títulos das ferramentas** [Codex, Devin]: até três variantes, e só com mais de uma
  (`Views/TranscriptViews.swift:1064-1080`). Pode multiplicar medidas ao estreitar, mas não há prova de peso.
- **Tela ao vivo redesenhando o chat** [Codex, Devin]: quadros e ponteiro ficam em camadas próprias, e a superfície solta o feed
  fora da área visível (`LiveScreen/LiveScreenLayerView.swift:240-297`). O blur do modo privado é deliberado.
- **Sombra, blur, material e `matchedGeometryEffect` caros** [Claude, Codex, Devin]: nenhum por linha. A sombra do compositor fica
  só no fundo.
- **Formatadores no `body`** [Claude, Codex]: nenhum `DateFormatter` ou `NumberFormatter` novo por render nesses caminhos.
- **Espaçamentos literais, cortes deliberados e contraste geral** [Codex, Devin; o Claude manteve só A9 como sistema]:
  - gutter de 44 pt, reserva de 90 pt e papel numa linha com dica são escolhas locais;
  - `faint` dá 5,56:1 sobre `chrome` e 5,52:1 sobre a bolha;
  - a ressalva é o uso de `hint` em texto (A2, A8).

## Lacunas e como medir depois

1. **`ScrollBench`** (proposta unida das três, não implementada):
   - **Isolamento:**
     - `ORB_DATA_DIR=<cópia> ORB_BENCH_SCROLL=<rodadas> Orb --bench-scroll`, só em `DEBUG || ORB_DEV_TOOLS`;
     - a flag entra em `DevRun.flags` e no `.accessory` do `Launcher`, e a janela já nasce invisível [Codex];
     - sem Keychain, rotinas, provedores nem `ORB_SEND`;
     - nunca junto com os outros medidores;
     - sai com limite de tempo, para não repetir a trava do quit.
   - **Cenários:**
     - as conversas de 89, 664, 2.174 e 2.220 itens da cópia, mais uma sintética de 5.000;
     - topo, meio e fim, na primeira passagem e na volta;
     - grupos fechados e o de 84 ações aberto;
     - prosa, código, tabela e imagens frias e quentes;
     - registrar itens e linhas depois da dobra [Codex, Devin].
   - **Dois caminhos separados** [Claude, Codex, Devin]:
     - mover o `NSClipView` a velocidade fixa por tick de `CADisplayLink`: mede layout e desenho;
     - mandar eventos de roda com fase à janela: só esses passam por `onScrollPhaseChange` e testam "ler acima sem ser puxado".
       Não vender o primeiro como teste do segundo.
   - **Streaming local:**
     - `scripts/fake-llm.py --long` como provedor da cópia, ou replay de deltas a 33 ms;
     - casos: texto puro, trecho sem linha em branco, lista, tabela e rajada de ferramentas;
     - rolar 24 pt, 100 pt e uma tela para cima e conferir que a posição não é retomada sem intenção [Devin].
   - **Variantes:**
     - abrir o painel depois da passada (R3, T3);
     - com e sem `TextFade` (S3);
     - Reduzir movimento.
   - **Métricas:**
     - intervalos p50/p95/p99/máximo, frações acima de 8,3/16,7/25 ms e ocupação da main;
     - quantos `scrollTo`, `sizeThatFits`, `ProseText.make` e refolds houve;
     - `NSTextView` vivos no fim;
     - signposts para correlacionar com SwiftUI, Time Profiler e Hitches [Codex, Devin].
   - **Protocolo:** release com o commit registrado, aquecimento descartado, condições alternadas (A/B/A) e uma variável por vez.
2. **`SwitchBench` seguro e o fade da troca (T1):** o modo acessório e oculto do `PanelsBench` mais um `measure` com display
   link nos 0,4 s depois da troca, quente e frio (`ORB_BENCH_COLD=1`).
3. **Abas depois de mudar de página (T5):** uma variante do `PanelsBench` que vá a Rotinas e volte antes de medir.
4. **Perfil:** `xctrace` anexado ao PID do medidor, nunca ao Orb que você usa. Conferir o binário carregado antes de ler a
   amostra.
5. **macOS 14 (S5) e mouse de roda, barra e teclado no macOS atual:** teste manual durante uma resposta longa.
6. **Pico do fim da resposta (item 9):** turno mais longo da main ao fechar uma resposta de 3.000 palavras.
7. **Lateral entre 84 e 93 fps:** repetir o atual e o `ee1c6d2^` com a máquina parada.
8. **Aparência:**
   - captura autorizada do painel a 244, 300 e 420 pt;
   - nomes, modelos e papéis longos;
   - grupo de 84 ações;
   - imagens na primeira passagem;
   - teclado e Reduzir movimento.
