# Movimento da interface — especificação

Para implementar nas views. **Estado (§2.13: páginas, painéis, folhas e estados também seguem estes tokens):** o vocabulário (os tokens de `Motion` e as transições `rise`/`unfold`) está em
[`Motion.swift`](../Sources/Orb/Motion.swift) e já é usado pela barra lateral, pelas mensagens e ferramentas, pelos
cartões de aprovação, pelo chat vazio, pela linha de trabalho e pelo compositor (§2.5); cada seção diz o que ainda
falta nela. Os ganchos de estado do Orb (§3) seguem o padrão atual de `speaking`, que
vive em `BotSession`/`BotLive` (veja [ORBS.md](ORBS.md)). Alvo: macOS 14+, SwiftUI. Tudo aqui é sutil de propósito: o app já é calmo e refinado; o movimento deve deixar claro
**o que mudou e por quê**, nunca chamar atenção para si. Quem tem personalidade e brincadeira é o Orb.

## 0. Princípios

1. **Causa e efeito.** Todo movimento nasce de algo que a pessoa fez ou de algo que o Orb fez. Nada se mexe sozinho
   na interface (o Orb é a exceção, e é dele que vem a vida).
2. **Uma família de curvas.** Poucos tokens (abaixo), sempre os mesmos. O app já tem um: `animateChanges(of:)` =
   `.smooth(duration: 0.25)`, instantâneo com Reduzir movimento. Ele vira `Motion.content`.
3. **Conteúdo entra devagar e sai rápido.** Entradas com mola amortecida (0,3–0,45 s); saídas em 0,12–0,18 s, só
   opacidade. (Retorno de hover é o contrário: responde rápido e se desfaz devagar, §2.7.)
4. **Distâncias curtas.** Translações de 4–10 pt, escalas de 0,97–1,0. Nada atravessa a tela.
5. **Interrompível.** Molas do SwiftUI herdam a velocidade; nunca usar sequências com `DispatchQueue.asyncAfter` para
   encadear etapas — usar `phaseAnimator`/`keyframeAnimator` ou transições.
6. **Reduzir movimento.** Sem translação, escala, giro, pulso ou rebote; vira troca de opacidade de 0,15 s (ou
   nada, quando a mudança já é óbvia). Ler `@Environment(\.accessibilityReduceMotion)` uma vez por componente e
   escolher a animação/transição (padrão: `Motion.content` já faz isso).
7. **Desempenho.** Só opacidade e transformações (o compositor faz sozinho). Nunca animar por token durante o
   streaming, nem layout de listas inteiras, nem `blur` em superfícies grandes. Laços contínuos ficam em Core
   Animation (como o brilho de status em `Theme.swift`, `ShimmerBandView`), nunca em `TimelineView`/`phaseAnimator` sem fim.

## 1. Tokens

O `enum Motion` (em `Motion.swift`; `animateChanges` fica em `Theme.swift`):

| Token | Curva | Uso |
|---|---|---|
| `Motion.press` | `.snappy(duration: 0.12)` | botão pressionado, chip escolhido |
| `Motion.hoverIn` / `hoverOut` | `.easeOut(duration: 0.10)` / `.easeOut(duration: 0.22)` | fundo de hover (entra rápido, sai devagar) |
| `Motion.content` | `.smooth(duration: 0.25)` (o atual `animateChanges`) | estados que mudam no lugar |
| `Motion.enter` | `.spring(response: 0.38, dampingFraction: 0.86)` | algo que aparece (mensagem, cartão, linha) |
| `Motion.emphasis` | `.spring(response: 0.45, dampingFraction: 0.72)` | o que precisa de você (aprovação) |
| `Motion.exit` | `.easeOut(duration: 0.16)` | algo que some |
| `Motion.stagger` | 0,035 s por item, no máximo 6 itens (0,21 s) | listas curtas que entram juntas |
| `Motion.crossFade` | `.easeInOut(duration: 0.18)` | uma página, Orb, aba ou categoria trocada por outra (§2.13) |
| `Motion.fade` | `.easeOut(duration: 0.15)` | o que toma o lugar de todo movimento com Reduzir movimento |
| `Motion.panel(reduceMotion:)` | `Motion.content`; nada com Reduzir movimento | a coluna do painel do Orb abrindo e fechando; uma seta que gira |
| `Motion.spinnerDelay` | 150 ms | um spinner só aparece depois disso (`DelayedSpinner`) |

Transições prontas (todas com versão Reduzir movimento = `.opacity`):

```swift
extension AnyTransition {
    /// Sobe 6 pt e aparece; sai só apagando.
    static var rise: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity)
    }
    /// Uma frase trocada por outra no lugar (linha de trabalho): a nova sobe 4 pt e aparece; a antiga só apaga, em 0,16 s.
    static var swap: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 4)), removal: .opacity.animation(Motion.exit))
    }
    /// Uma linha que chega com o turno (linha de trabalho): sobe 6 pt em `Motion.enter`; sai só apagando, em `Motion.exit`.
    static var arrive: AnyTransition {
        .asymmetric(insertion: AnyTransition.rise.animation(Motion.enter), removal: .opacity.animation(Motion.exit))
    }
    /// Desce do item de cima (detalhes que abrem).
    static var unfold: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: -4)), removal: .opacity)
    }
    /// Só opacidade, com a própria animação (`Motion.fade`, 0,15 s): para onde o contêiner não deve animar a altura
    /// (janela da barra de menus, popover, linhas de `Form`). O contêiner toma a altura nova de uma vez.
    static var quiet: AnyTransition { .opacity.animation(Motion.fade) }
    /// A marca de estado do app inteiro (✓, aviso, o que vem depois de um spinner): cresce de 0,6 e aparece.
    static var mark: AnyTransition { .scale(scale: 0.6).combined(with: .opacity) }
    /// `transition`, ou `.quiet` com Reduzir movimento (uma linha que chega num `animateChanges`, que é instantâneo,
    /// ainda faz fade de 0,15 s em vez de aparecer seca).
    static func adapted(_ transition: AnyTransition, reduceMotion: Bool) -> AnyTransition
}
```

## 2. Componentes

### 2.1 Seleção na barra lateral

- **Gatilho:** clique na linha, ⌥↑/⌥↓, ⌘1–9.
- **Movimento:** o fundo de seleção desliza da linha anterior para a nova (não some e reaparece). Só a linha escolhida
  pinta o fundo selecionado, e é a mesma vista em todas as linhas (`.matchedGeometryEffect(id: SidebarSelection.id, in: selectionSpace)`,
  com o namespace na `SidebarView`); a troca de `model.selection` anima com `Motion.content`. O hover continua por linha. O texto
  da linha nova passa de `Palette.secondary` a `Palette.ink` no mesmo tempo.
- **Orb da linha:** o Orb selecionado já sai da pausa deslizando para o movimento (comportamento atual). Somar
  um "acordei": uma piscada e um olhar rápido para a direita (para o chat) ao ser selecionado — ver §3.
- **Reduzir movimento:** o fundo troca de linha sem deslizar (`animation(nil)`); cor do texto troca na hora.
- **Desempenho:** um único fundo animado (não um por linha); a animação deve ficar presa à seleção
  (`.animation(_, value: selection)` no contêiner), para status e não lidas que mudam nas linhas não animarem
  junto. Não animar a altura das linhas.

### 2.2 Mensagens aparecendo

- **Sua mensagem (ao enviar):** a bolha entra com `.rise` e `Motion.enter` (sobe 6 pt e aparece em ~0,3 s),
  ancorada no fim da lista; a lista rola junto com `.smooth(duration: 0.3)` só se você já estava no fim.
- **Resposta do Orb:** o **bloco** da mensagem aparece com `.rise` quando o primeiro texto chega (uma vez por
  mensagem). O texto que vai chegando **não** anima (sem transição por token): o streaming tem custo constante e
  deve continuar assim (`Transaction(animation: nil)` nas atualizações de texto).
- **Fim da resposta:** nada na mensagem; quem comemora é o Orb (`happy`, em três níveis conforme o turno: leve, normal ou grande;
  parar a resposta não é erro, é uma piscada; tarefa que parou no meio, um suspiro).
- **Um Orb vivo por vez.** A resposta que é o último item do chat leva o avatar vivo (`LiveBotAvatar` com
  `restsWhenIdle`: vive no turno, no `happy` e na atenção à digitação, e descansa na pose de repouso, sem gerar
  quadros, quando o Orb fica ocioso); as de cima têm o avatar parado, na pose de repouso. Quando uma resposta deixa de
  ser a última (entra uma ferramenta ou uma mensagem), o avatar vivo pode estar numa expressão: os dois trocam com fade de
  `Motion.fade` (0,15 s), sem salto, preso a `isLastReply`, não à lista. A linha de trabalho esconde o seu
  avatar enquanto essa resposta está logo acima (só opacidade em `Motion.fade`, também com Reduzir movimento; a vaga de
  30 pt fica, e a frase não se move) e o pausa. `TranscriptRow.isLastReply` entra no `==`: só duas linhas redesenham
  quando um item entra.
- **Mensagem pendente** (direcionada ou para depois da tarefa; antes "na fila"). Entra como as outras (`.entrance(.rise)`, 6 pt em `Motion.enter`, fade de 0,15 s com Reduzir
  movimento), sem animar a lista, e sai na hora (a bolha real sobe no mesmo lugar). Tem a forma da bolha final (raio 18)
  e mostra imagens como miniaturas esmaecidas (0,75), como o `UserBubble`. Só entra na primeira vez que é feita: os ids
  já mostrados ficam numa referência barata (`PresentedOrbs`, ambiente `presentedQueued`), então reabrir o chat ou a lista
  recriar a linha não repete a entrada.
- **Copiar.** O símbolo troca com `.symbolEffect(.replace)` (identidade com Reduzir movimento); em código, "Copiar" →
  "Copiado" faz fade sem largura reservada (em repouso o botão fica na margem de 10 pt, só o símbolo desliza
  uns 8 pt). Vai para "copiado" em `Motion.press` e volta em `Motion.content`
  depois de 1,5 s; um segundo clique reinicia a contagem. A animação fica em `.animation(_, value:)` na própria view,
  porque a resposta zera as animações de tudo o que desenha.
- **Reduzir movimento:** opacidade 0,15 s no bloco; rolagem sem animação.
- **Desempenho:** a transição vale para a inserção da célula, não para a lista toda; nada de `animation(_:value:)`
  no `ScrollView` com valor = contagem de mensagens (refaria o layout de tudo).

### 2.3 Linhas de ferramenta

- **Expandir/recolher:** a divisa gira 90° e o texto usa `.unfold` (entra descendo 4 pt, sai só apagando) com
  `Motion.content`, para a altura não "quicar".
- **Rodando → feita:** enquanto roda, a linha fica parada em `Palette.faint` (o brilho é só da linha de trabalho, §2.10); ao terminar, o título volta a `Palette.muted` e a marca de estado entra com `.transition(.scale(0.6).combined(with: .opacity))`
  em `Motion.enter`. Falha: a marca vermelha entra igual, sem tremer (o Orb já mostra o erro).
- **Contadores** ("3 ações", tempos): `.contentTransition(.numericText())` com `Motion.content`.
- **Reduzir movimento:** marca troca por opacidade; expandir sem deslocamento.
- **Trabalho de um pedido** (`WorkGroupRow`): ao terminar o pedido, a linha toma o lugar do trabalho sem animar a lista; aberta, o conteúdo entra com `.unfold` e a divisa gira como nas outras.
- **Ações seguidas** (`ToolGroupRow`): uma linha no lugar delas, com a mesma divisa que gira 90°; aberta, as linhas entram com `.unfold` escalonado (`Motion.stagger`, ≤ 6), recuadas sob as palavras da linha. A contagem rola (`.numericText()`) uma vez por ação; "1 falhou" e o tempo entram como a marca de estado. Reduzir movimento: opacidade.
- **Anexos** (cartões de arquivo, grade de imagens, arquivos que o Orb fez): só opacidade. O cartão tem hover com `Motion.hoverIn`/`hoverOut` (`hoverFill`) e não encolhe ao pressionar (o clique é um gesto de toque, não um `Button`, para o arrastar para fora funcionar), e o tamanho ou o "ausente" que chegam do disco entram com `Motion.fade`. A miniatura entra por fade sobre o fundo. A entrada é só a da linha (`RowEntrance`).

### 2.4 Cartões de aprovação

- **Entrada:** `Motion.emphasis` com escala 0,98 → 1, 10 pt → 0 e opacidade 0 → 1. Logo depois, **um** pulso suave
  na borda (cor de aviso, opacidade 0 → 0,35 → 0,12 em 0,9 s) com `phaseAnimator([0, 1, 2], trigger: request.id)`,
  e para. O Orb, ao mesmo tempo, faz `waiting` (pulinhos) — o cartão não precisa pular.
- **Atalhos de teclado** (⌘↩ permite, Esc nega — `ApprovalShortcut`): o botão correspondente mostra o estado pressionado por 0,12 s
  (`Motion.press`, escala 0,97), para a pessoa ver o que o atalho fez.
- **Decisão:** o corpo do cartão recolhe (altura) com `Motion.content` e o rótulo da decisão ("Permitido",
  "Negado") entra com `.contentTransition(.opacity)`; o cartão não some (fica o registro).
- **Lote com 8+ itens:** "mostrar mais" abre com `.unfold`, itens em `Motion.stagger` (no máximo 6 animados; o resto
  aparece junto).
- **Reduzir movimento:** sem escala, deslocamento e pulso; opacidade 0,15 s; borda já na cor final.

### 2.5 Compositor (foco, digitação, envio)

- **Foco:** a borda já troca de `Palette.line` para `Palette.lineStrong` (`ComposerView`, `.card(stroke:)`), mas
  seca. Animar com `Motion.hoverIn` ao ganhar foco e `Motion.hoverOut` ao perder, e clarear o fundo 2 % junto.
  Sem brilho colorido (o Orb já é a cor da tela).
- **Botão enviar:** habilita com opacidade (`Motion.content`) quando há texto; pressionado = `Motion.press`
  (escala 0,92). É um botão só (`ComposerAction`: enviar, enfileirar ou parar) cujo ícone troca com
  `.contentTransition(.symbolEffect(.replace))`, e cada estado mantém rótulo, ajuda e atalho.
- **Altura do campo** crescendo com linhas: sem animação (segue a digitação; animar dá sensação de atraso).
- **O Orb reage** à digitação e ao envio — ver §3.
- **Reduzir movimento:** borda e cor trocam sem animação; símbolo troca direto.
- **O que o cartão contém e como entra e sai** (implementado em `ComposerView.swift`):
  - A **sombra** fica só no fundo (`ComposerSurface`), nunca no cartão inteiro: na forma antiga cada tecla passava texto, chips e botões por um passe offscreen. O realce do soltar arquivo usa `Motion.hover`.
  - **Ditando**, a borda do cartão fica vermelha suave (`ComposerSurface.stroke`, cor que muda em `Motion.hover`, também com Reduzir movimento); o cartão lê só a fase do ditado, nunca o nível da voz. **Ajustando** (o modelo revisa o texto ao parar), o microfone vira `sparkles` com `.pulse` e a dica diz que Esc mantém o texto ditado.
  - **Parar** (redondo e transparente como o "+" e o microfone, para o botão branco ser o único destaque) entra e sai com `.opacity`, e a linha da barra (chips de modelo e medidor) desliza junto em `Motion.content`, presa a `action.showsSecondaryStop`; com Reduzir movimento só o Parar faz fade (`Motion.fade`) e os chips trocam de lugar na hora.
  - **Chegada do medidor** (fim da primeira resposta) e o percentual ganhando um dígito (`9%` → `10%`) também movem a barra: o `ContextGaugeDriver` entrega a leitura dentro de `withAnimation(Motion.content)` só quando a presença ou o percentual mudam (uma vez por turno, nunca por token); com Reduzir movimento o chip só faz fade e o resto troca de lugar na hora.
  - **Sugestões de `/`, faixa de anexos e linha de erro** entram com `.opacity` + 4 pt (`unfold` para a faixa e o erro) e o cartão cresce uma vez em `Motion.content`, presa a um valor discreto (`CardParts`: existe lista, existe faixa, existe erro), nunca à contagem de itens nem à digitação. A altura do campo segue sem animação. Cada chip que entra ou sai da faixa faz fade e os vizinhos deslizam (`Motion.content`, presa aos ids); com Reduzir movimento os vizinhos trocam de lugar na hora e só o chip faz fade (`Motion.fade`).
  - **Miniaturas**: nascem do cache (`Thumbnails.cached`) e, se precisarem decodificar, entram por cima do ícone em `Motion.fade` (só opacidade, vale com Reduzir movimento). A miniatura de 96 pt da bolha é aquecida ao anexar. O `PreparingChip` é um ladrilho de 56 pt, para a faixa não mudar de altura na troca.
  - **Dica sob o campo** troca com `.contentTransition(.opacity)` em `Motion.fade`: o texto só muda ao ganhar ou perder foco, na primeira letra e ao enfileirar. Abaixo de 520 pt usa a forma curta (`ComposerHint.queueing(compact:)`).
  - **Medidor de contexto**: o percentual rola (`.numericText()`, `.identity` com Reduzir movimento), o anel e o aviso de conversa longa usam `Motion.content` e `rise` (nada de `.move(edge:)`).
  - **Foco**: volta ao campo depois de anexar, de escolher o modelo e de fechar a lista de permissões.

### 2.6 Folhas (Novo Orb, Personalizar Orb, Identidade)

- A apresentação da folha é do sistema: não mexer.
- **Conteúdo:** na primeira aparição, as seções sobem 6 pt e aparecem em `Motion.stagger` (no máximo 6), começando
  0,08 s depois da folha. No editor do Orb, o palco entra primeiro (`.sheetSection(0)`) e, ao pousar, o Orb dá um
  pulinho de "oi" (`poke`, nada com Reduzir movimento); a barra de categorias e as opções vêm em `.sheetSection(1)` e o
  rodapé em `.sheetSection(2)` (o "Pronto" da Personalizar e o "Criar Orb" do Novo Orb). No Novo Orb o formulário entra com o palco.
- **Formulário e importar** (Novo Orb) trocam num `ZStack`, não num `Group` (que entregaria os modificadores a cada
  filho: os dois painéis lado a lado e a cascata repetida).
- **Trocar de categoria no editor** (Cor → Olhos…): as grades se cruzam em `Motion.crossFade` (0,18 s, num `ZStack` com
  `.id(category)`); o destaque da categoria desliza (`matchedGeometryEffect`, `Motion.selection`) nas duas barras, e o
  rótulo da barra compacta cresce na mesma curva.
- **Reduzir movimento:** tudo aparece junto em fade de 0,15 s, sem poke; o destaque pula de lugar.

### 2.7 Hover

- Linhas, chips, cartões de sugestão, células do editor: fundo `ghostHover` entra em 0,10 s e sai em 0,22 s
  (assimétrico: responde rápido, não pisca ao passar o mouse por cima de várias).
- Sem escala no hover (macOS não "levanta" controles); exceção: miniaturas do editor animam o Orb (já existe).
- Cursor sobre o Orb: ele cresce e encara (já existe).
- **Reduzir movimento:** igual (troca de cor não é movimento).

### 2.8 Chat vazio (entrada)

- **Orb:** entra caindo de 10 pt acima, escala 0,92 → 1, opacidade 0 → 1, em `.spring(response: 0.55,
  dampingFraction: 0.68)`; ao tocar o "chão", amassa e balança (a aterrissagem, `landing`: só um amassado de 0,06, sem subida, 0,12 s depois do fim da entrada).
- **Nome e papel:** 0,08 s depois, `.rise` em `Motion.enter`.
- **Sugestões:** em seguida, `Motion.stagger` (0,035 s cada), `.rise`.
- **Quando:** só na primeira vez que o chat vazio de um Orb aparece na sessão (trocar de Orb e voltar não repete;
  guardar um `Set<UUID>` de "já apresentados" no estado da view raiz).
- **Reduzir movimento:** tudo aparece junto em 0,15 s, Orb parado.
- **Saudação do Orb novo.** Um Orb recém-criado não tem chat vazio: o chat começa com a saudação dele (`GreetingMessage`, uma
  resposta como as outras, com o avatar vivo) e, enquanto ela é o último item, três respostas rápidas (`GreetingReplies`,
  os mesmos botões das sugestões). A saudação sobe (`.rise`) e as respostas entram em `Motion.stagger`, uma vez por sessão (o
  mesmo `PresentedOrbs` do chat vazio). Elas saem em `.opacity` com `Motion.exit` quando uma é escolhida, quando algo é dito
  depois ou quando a pessoa começa a escrever (voltam só em `.opacity` se o rascunho for apagado, sem a subida escalonada de
  novo); só a view das respostas lê os rascunhos.

### 2.9 Troca de Orb ou de conversa

- O conteúdo do chat troca com `.opacity` em 0,18 s (sem deslizar: navegação lateral não tem direção espacial
  clara aqui). O compositor não pisca (fica fora da troca).
- **Troca de página** (Orb, Rotinas, Conectores, Skills, boas-vindas): o mesmo fade cruzado, num `ZStack` com
  `.id(DetailPage)` e `.motion(Motion.crossFade, value: page)` (`RootView.swift`). A chave `DetailPage` não leva o id do
  Orb: de um Orb para outro a página é a mesma e só a transcrição faz o fade. A saída das boas-vindas continua mais curta
  (`Motion.exit`). O `.inspector` mora no `DetailView`, só na página do Orb, e fecha junto com ela.

### 2.10 Linha de trabalho (o que o Orb está fazendo)

Implementado em `WorkLine.swift` e `ChatView.swift` (`WorkingLine`). Existe **um só lugar para o "agora"**: a linha no fim
do chat, ao lado do Orb. O transcript acima dela é o histórico (a linha de uma ferramenta que roda fica parada, em
`Palette.faint`, sem brilho; ao terminar, o título volta a `Palette.muted` e a duração entra como em §2.3).

- **O que ela diz.** Verbo e alvo ("Rodando" `swift build`, "Lendo" README.md, "Procurando" “TODO”, "Abrindo"
  github.com), tirados do título e da 1ª linha do detalhe da chamada (`WorkPhrase`); sem alvo, o verbo com reticências
  ("Pensando…"). Um passo por vez: a frase muda quando uma ferramenta começa ou termina, nunca por token. Do alvo, o
  comando e o nome do arquivo vão em fonte monoespaçada de 12 pt, cortados no meio quando falta espaço (e acima de
  56 caracteres).
- **Tempo mínimo.** Cada frase fica ao menos 0,7 s (`StatusDwell`, `BotLive.workDwell`): uma que chega antes espera, e
  de várias só a mais nova entra (uma `Task` por Orb, que só existe enquanto há frase esperando). Entram na hora: o fim
  do turno, a espera por você (e a saída dela) e a primeira frase do turno. É legibilidade, não movimento: **vale
  também com Reduzir movimento**. O Orb (atividade) segue o evento real, sem esse ritmo.
- **Troca de frase.** Um `ZStack` com a frase marcada por `.id(phraseKey)` e `AnyTransition.swap` em `Motion.enter`:
  a nova sobe 4 pt e aparece, a antiga só apaga em `Motion.exit` (0,16 s). O `ZStack` é um `.geometryGroup()`: quando a
  linha é empurrada por uma linha que entra acima, a frase que sai acompanha o pai em vez de ficar desenhada onde a linha estava. O medidor ao lado desliza junto com a largura
  da frase (`Motion.content`). A frase nova não reinicia o brilho: a varredura é um relógio global.
- **Entrada e saída da linha.** `AnyTransition.arrive`: sobe 6 pt em `Motion.enter`; sai só apagando em `Motion.exit`.
  A lista continua animando só o início e o fim do turno (`isWorking`), nunca a contagem de itens.
- **Um brilho só**, na frase inteira (uma máscara), e só no tom de trabalho. Espera por você: parada em `Palette.warn`,
  sem reticências. Espera para tentar de novo: parada em `Palette.secondary`, e a contagem regressiva ("em 8 s") ocupa o
  lugar do relógio, no mesmo `TimelineView` de 1 s.
- **Medidor.** "16 s · 3 ações" em 12 pt, `Palette.faint`. A contagem de ações aparece da 2ª ferramenta em diante e muda
  uma vez por ferramenta, com `.contentTransition(.numericText())` em `Motion.content`. O relógio troca a cada segundo
  sem animação (nada de animação contínua fora do Core Animation).
- **Desempenho.** `BotLive.work` é um valor pequeno e `Equatable`, escrito só quando muda; o texto em stream não passa
  por ele (`LiveText` continua à parte). Barra lateral e painel da barra de menus leem o mesmo `work.text`.
- **Reduzir movimento.** Brilho vira texto parado em `Palette.muted`; a troca de frase vira opacidade em `Motion.fade`
  (sem deslocamento); o medidor não desliza; o contador não rola (`.identity`); a linha entra só com opacidade.
- **VoiceOver.** A linha é um elemento ("Lia está trabalhando", valor = frase, sem o relógio; "Lia precisa de você" na
  espera), com o traço `updatesFrequently`. As mudanças são anunciadas com prioridade baixa (`WorkAnnouncer`): só com o
  VoiceOver ligado, o app ativo e o Orb escolhido, só frases com alvo, no máximo uma a cada 8 s. A espera já é
  anunciada pelo cartão de aprovação (prioridade alta); o fim do turno não ganha anúncio novo.

### 2.11 Tela de boas-vindas (sem Orbs)

Implementada em `WelcomeView.swift`. Aparece quando `botIDs` está vazio (primeiro uso com a lista vazia, ou depois de apagar todos).
Só usa tokens que já existem; o fundo é estático (um gradiente desenhado uma vez, sem blur) e **só os Orbs se mexem**.

- **Herói.** Lia (72 pt), Atlas (104 pt) e Bento (72 pt) são `OrbView` vivos e interativos, cada um com o seu jeito
  (equilibrado, tímido, curioso): respiram, piscam, seguem o cursor; um clique faz o Orb pular e mostrar o rosto feliz por 1,4 s (só o rosto). Nenhum laço
  novo de animação. Pausam com a janela inativa e fora da parte visível (o `OrbView` já faz).
- **Entrada** (`WelcomeEntrance`, cerca de 0,8 s). Atlas: `.drop` sem atraso; Lia: 0,06 s; Bento: 0,10 s, cada um pousa com uma
  aterrissagem (`landing`). Título `.rise` em 0,16 s, subtítulo em 0,20 s, pontos em `Motion.stagger` a partir de 0,26 s, cartão ou ações
  `.rise` em 0,40 s e o cartão de memórias em 0,44 s.
- **Quando a entrada toca.** Na primeira aparição da sessão e cada vez que a lista acaba de ficar vazia. Voltar de Rotinas,
  Conectores ou Skills não repete: o `WelcomeLedger` (referência no estado da `RootView`, como o `PresentedOrbs`) guarda que
  já tocou e é zerado quando `botIDs` deixa de ser vazio. O que nasce depois do primeiro segundo (a lista de memórias que
  terminou de carregar, as ações depois do cartão) entra por transição, não pela entrada.
- **Trocas.** Entrar e sair da tela segue o §2.9 (`.opacity` em 0,18 s); depois de criar um Orb ela só apaga (`Motion.exit`) e o chat
  vazio do Orb novo toca a própria queda (§2.8), então o Atlas "cai" no chat. Do cartão de modelo para as ações: o cartão sai
  com `.opacity` em `Motion.exit` e as ações entram com `.rise` em `Motion.enter`, presas à mudança de estágio, não à lista.
- **Causa e efeito.** Passar o ponteiro em "Começar com o Atlas" faz o Atlas dar um pulinho (no máximo um a cada 1,5 s).
  Ao conectar o modelo, o Atlas pula e fica `.happy` por 3 s, o prazo do flash da sessão.
- **Botão principal** (`HeroPillStyle`). Cápsula branca com um halo índigo (sombra de 16 pt, opacidade 0,35); no hover só a opacidade do halo
  anima (0,5, `Motion.hoverIn`/`hoverOut`); pressionado, escala 0,97 em `Motion.press`.
- **Reduzir movimento.** Tudo entra junto em `Motion.fade` (0,15 s), sem queda nem pulos. Os Orbs ficam estáticos (o `OrbView`
  já faz); a comemoração vira só o rosto `.happy` parado por 3 s; o halo do botão não anima; a troca cartão → ações é só opacidade.
- **VoiceOver.** O herói é uma imagem ("Três Orbs sorrindo: Atlas, de óculos, no meio; Lia, com um laço; Bento, com fones"); a ordem de
  leitura é título, subtítulo, os três pontos, cartão ou botão, alternativa e memórias. Ao conectar o modelo é anunciado "Pronto. Agora
  crie seu primeiro Orb." e o foco vai para o botão principal.
- **Abrir o app já com modelo.** `model.connected` só é preenchido por `refreshConnections` (Keychain, ChatGPT, `claude auth status`),
  que leva de centenas de ms a alguns segundos. Até `hasCheckedConnections` ficar verdadeiro, o estágio é `.checking`: herói, texto e
  pontos aparecem e só o lugar da ação é reservado. Depois a ação entra por transição (`.rise`), cartão ou botões, conforme o
  resultado. Nada de mostrar o cartão de conectar e trocar. A comemoração e o anúncio do VoiceOver só valem quando o modelo foi
  conectado no cartão (`WelcomeStage.celebrates(old:new:viaCard:)`), nunca quando a verificação inicial termina.
  O mesmo vale para o banner e o cartão do chat (`SetupPrompt.shows`), para o aviso do atalho rápido e para o envio: enquanto a verificação
  não termina nada pulsa nem avisa, e o compositor espera por ela. Depois dela, `AppModel.hasModelSetup(for:)` (modelo do Orb ou padrão utilizável) decide se o cartão e o banner aparecem.
- **Um clique com o Claude Code pronto.** O estágio `.checking` também cobre a procura pelo Claude Code e pelos servidores locais
  (`FirstRunModel.hasDetected`, no máximo `WelcomeEntrance.detectionPatience`), então o botão `HeroPillStyle` ("Usar meu Claude Code e
  começar", em `WelcomeOffer.swift`) ou o cartão aparece uma vez e fica. Enquanto o clique cria o Atlas (`isStarting`) o estágio segue
  `.connect`: sem o "Pronto" de 1,4 s e sem piscar "Criar meu primeiro Orb". "Outras formas de conectar" abre com `Motion.panel` e
  `.unfold` (só opacidade sob Reduzir movimento). Um aviso (`WelcomeReason`) sobe junto com o cartão quando algo mandou a pessoa para cá.
- **Botão Novo Orb da barra lateral.** Sai com a lista vazia (o convite faz o mesmo papel) e volta com `.rise` em `Motion.enter`
  quando nasce o primeiro Orb; Ajustes fica no canto direito nos dois casos.
- **Memória guardada que chega depois.** Ao apagar o último Orb guardando a memória, a cópia roda em segundo plano. A lista é lida
  de novo quando ela termina (`keptMemoriesVersion`), e o cartão entra por transição.
- **Texto da lista esvaziada.** A marca `orb.welcome.criouOrb` também é gravada quando o app abre com Orbs que já existem (feitos por
  versões anteriores), então quem apaga todos vê "Hora de um Orb novo". "Redefinir" limpa a marca e volta sem Orbs (como uma instalação nova): a tela abre com o texto de primeiro uso.
- **Convite na barra lateral.** Segue o texto da tela ("Criar seu primeiro Orb" ou "Criar um novo Orb"). Um clique mostra a boas-vindas;
  com ela já na tela, o clique abre a folha Novo Orb.
- **Fundo.** Vai atrás da coluna que rola, então a luz acompanha os Orbs quando o conteúdo é mais alto que a janela.
- **Desempenho.** O Orb de 104 pt é "grande" (no máximo 30 fps, cerca de 14 parado) e os de 72 pt ficam perto de 12 fps; o
  `OrbDriver` é compartilhado. Nada de `TimelineView`, `phaseAnimator` sem fim ou blur de superfície grande.

### 2.12 Rotinas no painel do Orb

Implementado em `BotInspector.swift` (`RoutineRow`) e `AppModel+Schedule.swift`. Só tokens que já existem; nada contínuo.

- **Entrar e sair.** Uma linha nova (a tarefa que o Orb criou no chat, ou "Nova rotina…") chega com `AnyTransition.arrive` (sobe 6 pt em
  `Motion.enter`) e uma que sai (apagar, no painel ou no chat) só apaga em `Motion.exit`; as vizinhas deslizam com
  `Motion.content`, presa aos ids das rotinas do Orb (`animateChanges(of:)` na seção da aba Rotinas, então só ela observa), nunca a cada execução ou relógio.
- **Destaque da nova.** Só a tarefa criada pelo Orb: um fundo de acento a 12% que aparece em `Motion.content` e some sozinho depois de
  2,5 s (`AppModel.freshRoutine`, uma `Task` curta, nenhum laço). Só se o painel do Orb que pediu está à vista (nada é marcado nem vibra no painel de outro Orb): a aba Rotinas abre.
- **Interruptor.** Ativa/Pausada troca a opacidade da linha (0,6) e a linha "Pausada" em `Motion.content`; um toque no trackpad
  (`.sensoryFeedback(.alignment)`). Criar pelo chat dá outro (`.levelChange`), uma vez, só com o painel à vista.
- **Apagar.** O ícone de lixeira troca a barra de botões por "Apagar esta rotina? Cancelar · Apagar" na própria linha
  (`.opacity` em `Motion.content`; "Apagar" em vermelho), sem diálogo e sem mudar a altura; apagar tira a linha como acima.
- **Reduzir movimento.** Nada desliza nem sobe: a linha aparece e some por opacidade (`AnyTransition.adapted`) e o destaque, o
  interruptor e a confirmação trocam na hora (`animateChanges` já é instantâneo).

### 2.13 Páginas, painéis, folhas e estados

Cada tipo de mudança tem um só jeito de se mover. A resposta começa no quadro do clique; nada espera, a não ser a
cascata das folhas (0,08 s). Só opacidade e transformações; nada anima por token, por tecla digitada nem a altura de
listas longas.

| Padrão | Quando | Como | Reduzir movimento |
|---|---|---|---|
| **A. Troca de conteúdo** | página, Orb, aba, categoria, vazio e cheio | fade cruzado sem direção, num `ZStack { conteúdo.id(chave).transition(.opacity) }` (nunca num stack ou `Group`) com `.motion(Motion.crossFade, value: chave)` | fade de 0,15 s |
| **B. Algo novo num fluxo** | linha, cartão, aviso, campo | `.arrive`/`.rise`, saída só por opacidade em `Motion.exit`, vizinhas deslizam em `Motion.content`; preso a ids ou a um booleano, nunca à contagem | só opacidade, vizinhas trocam na hora (`.adapted` devolve `.quiet`) |
| **C. Troca no lugar** | texto, selo, rótulo | `.transition(.opacity)`/`.contentTransition(.opacity)` e `animateChanges`/`textSwap` | na hora (ou fade) |
| **D. Carregando, depois pronto** | spinner que vira conteúdo | `DelayedSpinner` (150 ms) e o conteúdo por `.opacity` em `ZStack`, `.motion(Motion.content, value: fase)` | fade de 0,15 s |
| **E. Hover** | fundo ao passar o mouse | `hoverFill`/`hoverCard` (0,10 s dentro, 0,22 s fora) | igual (é cor) |
| **F. Seleção que desliza** | abas, pílulas, categorias | um fundo só, `matchedGeometryEffect`, `Motion.selection(reduceMotion:)` | pula de lugar |
| **G. Aviso flutuante** | toast | `.arrive` (sobe 6 pt em `Motion.enter`, sai em `Motion.exit`) | fade de 0,15 s |
| **H. Onde o contêiner não deve animar a altura** | janela da barra de menus, popover, linhas de `Form` | `.transition(.quiet)`: a altura muda de uma vez e o conteúdo aparece em 0,15 s | igual |

O que usa cada padrão:

- **Painel do Orb.** Abre e fecha por `AppModel.setInspector(_:)`/`toggleInspector()` em `Motion.panel` (a coluna desliza em 0,25 s, sem animação
  com Reduzir movimento) a partir de todos os caminhos: botão da barra, o atalho do painel, paleta, "Ver na memória", "Gerenciar", "Personalizar" e o
  fechamento automático por largura. Ao trocar de Orb o painel faz o mesmo fade cruzado de 0,18 s do chat. As abas (Geral, Memória, Pasta e
  acessos, Rotinas) são um `Form` cada, trocado em fade cruzado (a rolagem volta ao topo), e o destaque desliza (F).
- **Conectores e Skills.** Galeria, Instalados e Explorar em fade cruzado (A), pílula que desliza (F). Explorar tem uma fase só
  (`ExplorePhase`: dica, carregando, erro, nenhum resultado, resultados), e o texto digitado nunca é uma fase. Selo de status e "Copiar /slug" trocam no lugar (C).
- **Rotinas.** Vazio e grade em fade cruzado; um cartão que nasce ou some usa `.arrive` preso aos ids; "Rodar agora", "Rodando…" e "Na fila"
  trocam no lugar; o cartão pausado esmaece (`animateChanges(of: isEnabled)`).
- **Barra lateral.** Um Orb novo sobe 6 pt e um apagado some em fade, com os vizinhos deslizando, preso à lista de ids. O destaque não desliza
  nessa hora (`sidebarListChanged`). O convite some em fade.
- **Banner "Conecte um modelo".** Sobe e some com o compositor acompanhando, preso a `shows`; as frases e os botões trocam no lugar (C). Na troca de Orb ele
  é uma vista nova e aparece na hora. Se travar com uma conversa muito longa, ficar só com o fade (`.quiet`).
- **Cartão de aprovação.** O campo de "Dizer o que fazer em vez disso" desce 4 pt (`unfold`) e o link some em fade; o cartão cresce em `Motion.content`.
- **Barra de menus (QuickAsk).** Nota, "Conecte um modelo", resposta, aprovações e linhas de "outros trabalhando" em `.quiet` (H);
  o anel do Orb escolhido usa `Motion.press`.
- **Carregando, depois pronto nas folhas.** Ferramentas do conector, prévia de skill ("Instalar skill" vira "Instalada"), conversa e relatório da rotina,
  importar e a contagem do "Some:" do Apagar Orb (D). A folha de Rotina que fecha e reabre ao virar conversa (ids diferentes) segue do sistema.
- **Seções dentro de `Form`.** Dia, passos e relógio da folha de Rotina, "Gerenciar conectores" e "Permissões do macOS" do painel, "Usar com", o rodapé
  de "Começar de" e o resumo da importação entram em `.quiet` (H, por ser tabela); rodapés e mensagens trocam de texto por `textSwap` (C), inclusive o
  `SheetFooter`. Escolher uma memória no Novo Orb troca o Orb do palco com `.snappy`, como uma edição.
- **Pasta e acessos e Memória.** As leituras do disco (instruções, arquivos, "Pasta não encontrada") entram em `.quiet` sem animar a altura da lista;
  remover uma liberação, "Esquecer" e apagar uma conversa saem em `Motion.exit`. **A busca filtra na hora** (a saída por fade só vale sem busca) e expandir a
  linha usa `Motion.content` no `lineLimit`. Na folha Memória, "Mostrar" troca o filtro em `Motion.crossFade`.
- **Avisos flutuantes** ("Atlas esqueceu isso", "Memória de … guardada") em `.arrive`, no lugar do `.move(edge:)` e da curva literal; com Reduzir movimento fazem fade.
- **Editor de conector.** As fases são uma só vista de resultado (o spinner vira a marca ✓ ou o aviso, com `.mark` em `Motion.enter`) e o conteúdo muda em `Motion.content`.
- **Hover.** `OptionCell`, `TemperamentRow`, cartões do catálogo, do registro e dos modelos de rotina (`hoverCard`), linhas do popover de modelos e da paleta
  (só no mouse; as setas movem a seleção na hora). Nos cartões e nas células a seleção troca em `Motion.press`.
- **Ajustes.** Avisos de Geral e do cartão ↔ modelo padrão em `.quiet`; linhas de provedor em `Motion.exit`; expandir um provedor ou "Apps que o Orb controla" em
  `Motion.content` (fade com Reduzir movimento); selos das Permissões com `.mark` (spinner para ✓ ou aviso); véu do Redefinir em fade.
- **Paleta ⌘K e popover de modelos.** "Nada encontrado" e a lista em `.quiet`; recolher um provedor gira a seta em `Motion.content` (sem giro com Reduzir
  movimento) e as linhas saem em `.quiet`. A digitação e as setas seguem instantâneas.
- **Botões do aviso do chat** (`NoticeLine`): a transição já existia, agora há o gatilho (`offersActions && !actions.isEmpty`).
- **Curvas literais.** Saíram todas as de página; ficam só o pulso do banner e do cartão de conectar (`easeOut(0.25)`, raro), o holofote do Orb no editor
  (0,45 s) e o `.snappy` do próprio Orb, que são da zona do Orb.

**Do sistema, sem mexer:** apresentação de toda `.sheet`; `NSAlert`, alertas e `confirmationDialog`; paleta ⌘K abrindo e fechando; a janela e as abas de
Ajustes (incluindo o redimensionamento); popovers; `Menu` e `contextMenu`; `fileImporter`, `NSOpenPanel`, Quick Look e notificações; o `MenuBarExtra`; tooltips;
o disclosure "Opções avançadas".

## 3. O Orb reagindo à interface (sistema do Orb)

> **Implementado** em design-orbs: `OrbActivity.attentive`, `BotLive.noteComposing` (com `ComposingDeadline`;
> o conjunto ficou em `BotLive`, não em `AppModel`, depois da divisão do modelo) e `BotLive.glance` + `OrbGlance`.
> Detalhes em [ORBS.md](ORBS.md#reagindo-à-interface).

O motor tem atividades e pulos (`listening`, `poke`, `happy`, `waiting`) e os ganchos de estado abaixo, que seguem o
padrão de `speaking` (o conjunto só muda no começo e no fim da rajada, nunca por tecla):

| Evento | Reação do Orb | Gancho |
|---|---|---|
| Começou a digitar no compositor | olha para baixo, para o campo (`look.y = -0,45`), sacadas reduzidas, pisca menos; como `listening` mas sem pulo | um sinal em `BotLive`, ligado como `isSpeaking` (`BotSession.markSpeaking`): entra na 1ª tecla, sai 3 s depois da última (um prazo por Orb, conferido por uma única `Task`) |
| Apagou tudo | volta ao normal | o mesmo conjunto |
| Enviou | aceno de 0,35 s (`ack`, sem balanço) + `listening` | — |
| Selecionado na barra | piscada + olhar rápido para o chat (0,6 s, ignorado se vier menos de 1,2 s depois do anterior) | um contador separado (`glance`) |
| Resposta terminou | `happy` no nível do turno (leve 1,6 s, normal 2,2 s, grande 3 s) | `OrbCelebration.level` |
| Parou a resposta | uma piscada | `BotLive.cued(.blink)` |
| Tarefa parou no meio | um suspiro | `BotLive.cued(.sigh)` |
| Pediu aprovação | `waiting` em ciclos: 3 pulos, depois 2 pulinhos a cada 7 s | — |

A atividade "atento" é `OrbActivity.attentive` (olhar para baixo, `wander` 0,2, `pointerWeight` 0,3, sem expressão
própria, `minFrameRate` 10). Custo: igual a `listening`. Prioridade em `activity(for:)`: abaixo de trabalhando (se o
Orb está trabalhando, continua trabalhando).

## 4. Reduzir movimento — resumo

| Componente | Normal | Reduzir movimento |
|---|---|---|
| Seleção | fundo desliza | troca na hora |
| Mensagens | sobe 6 pt + aparece | aparece em 0,15 s |
| Ferramentas | marca com escala; detalhes descem | opacidade |
| Aprovação | escala + deslocamento + 1 pulso na borda | opacidade, borda fixa |
| Compositor | borda/fundo animados, símbolo troca com efeito; cartão cresce com lista, anexos e erro; chips deslizam com o Parar; percentual rola | troca direta; só fade de 0,15 s (Parar, miniatura, dica) |
| Folhas | seções em cascata | tudo junto |
| Chat vazio | Orb cai e amassa, cascata | tudo junto, Orb parado |
| Rotinas no painel | linha sobe 6 pt, destaque de 2,5 s, vizinhas deslizam | linha só aparece e some por opacidade |
| Boas-vindas | três Orbs caem em sequência, pontos em cascata, cartão sobe | tudo junto em 0,15 s, Orbs parados, halo fixo |
| Linha de trabalho | frase sobe 4 pt, medidor desliza, contador rola | frase troca por opacidade (0,15 s), sem deslizar nem rolar |
| Troca de página, aba, categoria | fade cruzado de 0,18 s, destaque que desliza | fade de 0,15 s, destaque que pula |
| Painel do Orb abrindo e fechando | a coluna desliza em 0,25 s | sem animação |
| Estados no lugar (texto, selo, interruptor) | fade em 0,25 s | na hora (ou fade de 0,15 s) |
| Linha que nasce ou some (Rotinas, barra lateral, memória) | sobe 6 pt e aparece; sai por fade; vizinhas deslizam | fade de 0,15 s, vizinhas trocam na hora |
| Janela da barra de menus, popovers, linhas de `Form` | fade de 0,15 s, altura de uma vez | igual |
| Avisos flutuantes | sobem 6 pt | fade de 0,15 s |
| Orb | vivo | estático (já é assim) |
