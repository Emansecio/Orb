# Movimento da interface — especificação

Para implementar nas views. **Estado:** o vocabulário (os tokens de `Motion` e as transições `rise`/`unfold`) já existe em
[`Motion.swift`](../Sources/Orb/Motion.swift), mas só `Motion.content` está em uso (por `animateChanges`); os componentes
descritos abaixo ainda não foram implementados. Os ganchos de estado do Orb (§3) seguem o padrão atual de `speaking`, que
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
- **Reduzir movimento:** opacidade 0,15 s no bloco; rolagem sem animação.
- **Desempenho:** a transição vale para a inserção da célula, não para a lista toda; nada de `animation(_:value:)`
  no `ScrollView` com valor = contagem de mensagens (refaria o layout de tudo).

### 2.3 Linhas de ferramenta

- **Expandir/recolher:** já existe (`.snappy(0.2)`, divisa gira 90°). Ajustar a saída do texto para `.unfold`
  (entra descendo 4 pt, sai só apagando) e trocar a curva por `Motion.content` para a altura não "quicar".
- **Rodando → feita:** o brilho para (já existe) e a marca de estado entra com `.transition(.scale(0.6).combined(with: .opacity))`
  em `Motion.enter`. Falha: a marca vermelha entra igual, sem tremer (o Orb já mostra o erro).
- **Contadores** ("3 ações", tempos): `.contentTransition(.numericText())` com `Motion.content`.
- **Reduzir movimento:** marca troca por opacidade; expandir sem deslocamento.

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

### 2.9 Troca de Orb ou de conversa

- O conteúdo do chat troca com `.opacity` em 0,18 s (sem deslizar: navegação lateral não tem direção espacial
  clara aqui). O compositor não pisca (fica fora da troca).

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
| Compositor | borda/fundo animados, símbolo troca com efeito | troca direta |
| Folhas | seções em cascata | tudo junto |
| Chat vazio | Orb cai e amassa, cascata | tudo junto, Orb parado |
| Orb | vivo | estático (já é assim) |

## 5. Ordem de implementação sugerida

1. Tokens + transições (`Motion.swift`, já feito) — adotar nas views.
2. Mensagens e ferramentas (maior frequência de uso) — 2 h, medir com o teste de streaming.
3. Aprovação (maior importância) — 1 h.
4. Compositor + gancho `composing` + atividade `attentive` — 3 h com testes (padrão de `speaking`).
5. Seleção, folhas, chat vazio — 2 h.

Validar cada um com Instruments (SwiftUI + Animation Hitches) numa conversa longa em streaming: nenhum quadro
acima de 16 ms e nenhum aumento de atualizações de corpo por token.
