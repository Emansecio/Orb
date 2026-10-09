# Movimento da interface — especificação

Para implementar nas views. **Estado:** o vocabulário (os tokens de `Motion` e as transições `rise`/`unfold`) está em
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
}
```

## 2. Componentes

### 2.1 Seleção na barra lateral

- **Gatilho:** clique na linha, ⌥↑/⌥↓, ⌘1–9.
- **Movimento:** o fundo de seleção desliza da linha anterior para a nova (não some e reaparece). Hoje cada
  `SidebarRow` pinta o próprio fundo (`isSelected ? ghostSelected : …`); passar a pintar o fundo selecionado só na
  linha escolhida, com `.matchedGeometryEffect(id: "selecao", in: namespace)` (namespace na `SidebarView`), e
  animar a troca de `model.selection` com `Motion.content`. O hover continua por linha. O texto da linha nova passa
  de `Palette.secondary` a `Palette.ink` no mesmo tempo.
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
- **Fim da resposta:** nada na mensagem; quem comemora é o Orb (`happy`).
- **Um Orb vivo por vez.** A resposta que é o último item do chat leva o avatar vivo (`LiveBotAvatar` com
  `restsWhenIdle`: vive no turno, no `happy` e na atenção à digitação, e descansa na pose de repouso, sem gerar
  quadros, quando o Orb fica ocioso); as de cima têm o avatar parado, na pose de repouso. Quando uma resposta deixa de
  ser a última (entra uma ferramenta ou uma mensagem), o avatar vivo pode estar numa expressão: os dois trocam com fade de
  `Motion.fade` (0,15 s), sem salto, preso a `isLastReply`, não à lista. A linha de trabalho esconde o seu
  avatar enquanto essa resposta está logo acima (só opacidade em `Motion.fade`, também com Reduzir movimento; a vaga de
  30 pt fica, e a frase não se move) e o pausa. `TranscriptRow.isLastReply` entra no `==`: só duas linhas redesenham
  quando um item entra.
- **Mensagem na fila.** Entra como as outras (`.entrance(.rise)`, 6 pt em `Motion.enter`, fade de 0,15 s com Reduzir
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

- **Expandir/recolher:** já existe (`.snappy(0.2)`, divisa gira 90°). Ajustar a saída do texto para `.unfold`
  (entra descendo 4 pt, sai só apagando) e trocar a curva por `Motion.content` para a altura não "quicar".
- **Rodando → feita:** enquanto roda, a linha fica parada em `Palette.faint` (o brilho é só da linha de trabalho, §2.10); ao terminar, o título volta a `Palette.muted` e a marca de estado entra com `.transition(.scale(0.6).combined(with: .opacity))`
  em `Motion.enter`. Falha: a marca vermelha entra igual, sem tremer (o Orb já mostra o erro).
- **Contadores** ("3 ações", tempos): `.contentTransition(.numericText())` com `Motion.content`.
- **Reduzir movimento:** marca troca por opacidade; expandir sem deslocamento.
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
  (escala 0,92). Hoje "Enviar" e "Parar" são dois botões num `if isWorking` (troca seca); juntar num só botão
  cujo ícone troca com `Image(systemName: isWorking ? "stop.fill" : "arrow.up").contentTransition(.symbolEffect(.replace))`
  (macOS 14), mantendo rótulo, ajuda e atalho de cada estado.
- **Altura do campo** crescendo com linhas: sem animação (segue a digitação; animar dá sensação de atraso).
- **O Orb reage** à digitação e ao envio — ver §3.
- **Reduzir movimento:** borda e cor trocam sem animação; símbolo troca direto.
- **O que o cartão contém e como entra e sai** (implementado em `ComposerView.swift`):
  - A **sombra** fica só no fundo (`ComposerSurface`), nunca no cartão inteiro: na forma antiga cada tecla passava texto, chips e botões por um passe offscreen. O realce do soltar arquivo usa `Motion.hover`.
  - **Parar** entra e sai com `.opacity`, e a linha da barra (chips de modelo e medidor) desliza junto em `Motion.content`, presa a `action.showsSecondaryStop`; com Reduzir movimento só o Parar faz fade (`Motion.fade`) e os chips trocam de lugar na hora.
  - **Chegada do medidor** (fim da primeira resposta) e o percentual ganhando um dígito (`9%` → `10%`) também movem a barra: o `ContextGaugeDriver` entrega a leitura dentro de `withAnimation(Motion.content)` só quando a presença ou o percentual mudam (uma vez por turno, nunca por token); com Reduzir movimento o chip só faz fade e o resto troca de lugar na hora.
  - **Sugestões de `/`, faixa de anexos e linha de erro** entram com `.opacity` + 4 pt (`unfold` para a faixa e o erro) e o cartão cresce uma vez em `Motion.content`, presa a um valor discreto (`CardParts`: existe lista, existe faixa, existe erro), nunca à contagem de itens nem à digitação. A altura do campo segue sem animação. Cada chip que entra ou sai da faixa faz fade e os vizinhos deslizam (`Motion.content`, presa aos ids); com Reduzir movimento os vizinhos trocam de lugar na hora e só o chip faz fade (`Motion.fade`).
  - **Miniaturas**: nascem do cache (`Thumbnails.cached`) e, se precisarem decodificar, entram por cima do ícone em `Motion.fade` (só opacidade, vale com Reduzir movimento). A miniatura de 96 pt da bolha é aquecida ao anexar. O `PreparingChip` é um ladrilho de 56 pt, para a faixa não mudar de altura na troca.
  - **Dica sob o campo** troca com `.contentTransition(.opacity)` em `Motion.fade`: o texto só muda ao ganhar ou perder foco, na primeira letra e ao enfileirar. Abaixo de 520 pt usa a forma curta (`ComposerHint.queueing(compact:)`).
  - **Medidor de contexto**: o percentual rola (`.numericText()`, `.identity` com Reduzir movimento), o anel e o aviso de conversa longa usam `Motion.content` e `rise` (nada de `.move(edge:)`).
  - **Foco**: volta ao campo depois de anexar, de escolher o modelo e de fechar a lista de permissões.

### 2.6 Folhas (Novo Orb, Personalizar Orb, Identidade)

- A apresentação da folha é do sistema: não mexer.
- **Conteúdo:** na primeira aparição, as seções sobem 6 pt e aparecem em `Motion.stagger` (no máximo 6), começando
  0,08 s depois da folha. No editor do Orb, o palco entra primeiro e o Orb dá um pulinho de "oi" (`poke`).
- **Trocar de aba no editor** (Cor → Olhos…): a grade troca com `.opacity` em 0,15 s; o indicador da aba desliza
  (`matchedGeometryEffect`) com `Motion.content`.
- **Reduzir movimento:** tudo aparece junto, sem deslocamento.

### 2.7 Hover

- Linhas, chips, cartões de sugestão, células do editor: fundo `ghostHover` entra em 0,10 s e sai em 0,22 s
  (assimétrico: responde rápido, não pisca ao passar o mouse por cima de várias).
- Sem escala no hover (macOS não "levanta" controles); exceção: miniaturas do editor animam o Orb (já existe).
- Cursor sobre o Orb: ele cresce e encara (já existe).
- **Reduzir movimento:** igual (troca de cor não é movimento).

### 2.8 Chat vazio (entrada)

- **Orb:** entra caindo de 10 pt acima, escala 0,92 → 1, opacidade 0 → 1, em `.spring(response: 0.55,
  dampingFraction: 0.68)`; ao tocar o "chão", amassa (um `poke` no fim da entrada, já com a mola de pouso do Orb).
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
  (equilibrado, tímido, curioso): respiram, piscam, seguem o cursor; um clique faz o Orb pular e ficar feliz por 1,4 s. Nenhum laço
  novo de animação. Pausam com a janela inativa e fora da parte visível (o `OrbView` já faz).
- **Entrada** (`WelcomeEntrance`, cerca de 0,8 s). Atlas: `.drop` sem atraso; Lia: 0,06 s; Bento: 0,10 s, cada um pousa com um
  `poke`. Título `.rise` em 0,16 s, subtítulo em 0,20 s, pontos em `Motion.stagger` a partir de 0,26 s, cartão ou ações
  `.rise` em 0,40 s e o cartão de memórias em 0,44 s.
- **Quando a entrada toca.** Na primeira aparição da sessão e cada vez que a lista acaba de ficar vazia. Voltar de Rotinas,
  Conectores ou Skills não repete: o `WelcomeLedger` (referência no estado da `RootView`, como o `PresentedOrbs`) guarda que
  já tocou e é zerado quando `botIDs` deixa de ser vazio. O que nasce depois do primeiro segundo (a lista de memórias que
  terminou de carregar, as ações depois do cartão) entra por transição, não pela entrada.
- **Trocas.** Entrar e sair da tela segue o §2.9 (`.opacity` em 0,18 s); depois de criar um Orb ela só apaga (`Motion.exit`) e o chat
  vazio do Orb novo toca a própria queda (§2.8), então o Atlas "cai" no chat. Do cartão de modelo para as ações: o cartão sai
  com `.opacity` em `Motion.exit` e as ações entram com `.rise` em `Motion.enter`, presas à mudança de estágio, não à lista.
- **Causa e efeito.** Passar o ponteiro em "ou comece com o Atlas" faz o Atlas dar um pulinho (no máximo um a cada 1,5 s).
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

## 3. O Orb reagindo à interface (sistema do Orb)

> **Implementado** em design-orbs: `OrbActivity.attentive`, `BotLive.noteComposing` (com `ComposingDeadline`;
> o conjunto ficou em `BotLive`, não em `AppModel`, depois da divisão do modelo) e `BotLive.glance` + `OrbGlance`.
> Detalhes em [ORBS.md](ORBS.md#reagindo-à-interface).

O motor já tem atividades e pulos (`listening`, `poke`, `happy`, `waiting`). Faltam dois ganchos de estado, que
devem seguir o padrão de `speaking` (o conjunto só muda no começo e no fim da rajada, nunca por tecla):

| Evento | Reação do Orb | Gancho |
|---|---|---|
| Começou a digitar no compositor | olha para baixo, para o campo (`look.y = -0,45`), sacadas reduzidas, pisca menos; como `listening` mas sem pulo | um sinal em `BotLive`, ligado como `isSpeaking` (`BotSession.markSpeaking`): entra na 1ª tecla, sai 1,5 s depois da última (um prazo por Orb, conferido por uma única `Task`) |
| Apagou tudo | volta ao normal | o mesmo conjunto |
| Enviou | pulo + `listening` (já existe) | — |
| Selecionado na barra | piscada + olhar rápido para o chat (0,6 s) | `pokes` com um tipo (`.glance`) ou um contador separado |
| Resposta terminou | `happy` (alegria que acalma, já existe) | — |
| Pediu aprovação | `waiting` (já existe) | — |

A atividade "atento" seria um caso novo em `OrbActivity` (`attentive`: olhar para baixo, `wander` 0,2,
`pointerWeight` 0,3, sem expressão própria, `minFrameRate` 10). Custo: igual a `listening`. Prioridade em
`activity(for:)`: abaixo de trabalhando (se o Orb está trabalhando, continua trabalhando).

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
| Orb | vivo | estático (já é assim) |

## 5. Ordem de implementação sugerida

1. Tokens + transições (`Motion.swift`, já feito) — adotar nas views.
2. Mensagens e ferramentas (maior frequência de uso) — 2 h, medir com o teste de streaming.
3. Aprovação (maior importância) — 1 h.
4. Compositor + gancho `composing` + atividade `attentive` — 3 h com testes (padrão de `speaking`).
5. Seleção, folhas, chat vazio — 2 h.

Validar cada um com Instruments (SwiftUI + Animation Hitches) numa conversa longa em streaming: nenhum quadro
acima de 16 ms e nenhum aumento de atualizações de corpo por token.
