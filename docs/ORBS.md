# Orbs

Cada bot do OpenBot é um **Orb**: uma esfera de gel translúcido e brilhante, renderizada em 3D
no Blender e animada ao vivo no app. Todos os Orbs têm o mesmo formato redondo; a identidade
vem da cor, do rosto e dos acessórios.

![Orbs × atividades](orbs-activities.png)

---

## 1. Visão geral do pipeline

```
art/orbs.py + art/orbkit/          Blender 5.2 (Cycles, headless)
        │  orbs.py layers
        ▼
Sources/OpenBotMac/Resources/Orbs/  98 PNGs 640 px em camadas + options.json
        │  scripts/bundle.sh copia para OpenBot.app/Contents/Resources/Orbs
        ▼
OrbCatalog / OrbImages             lê options.json, carrega e reduz as camadas (com cache)
        │
        ├─ OrbFrame (Canvas)        Orb estático: listas, miniaturas, ImageRenderer
        └─ AnimatedOrb (Core Animation + display link)   Orb vivo
```

O 3D é pré-renderizado. O app só **compõe camadas** (corpo + traços do rosto + cabelo +
acessórios) e as anima com transformações 2D. Assim fica leve e com qualidade de render.

## 2. Opções de personalização

| Categoria | Qtde | Ids |
|---|---|---|
| Cor (`color`) | 18 | indigo, ceu, oceano, menta, lima, sol, pessego, coral, cereja, rosa, lavanda, ametista, aurora, algodao, chocolate, noite, grafite, perola |
| Olhos (`eyes`) | 12 | pilulas, pontos, ovais, grandes, fendas, felizes, sono, piscadela, estrelas, coracoes, tontos, bravos |
| Boca (`mouth`) | 10 | nenhuma, sorriso, sorrisao, surpresa, neutra, gatinho, lingua, dentinho, triste, assobio |
| Sobrancelhas (`brows`) | 5 | nenhuma, retas, arqueadas, bravas, preocupadas |
| Bochechas (`cheeks`) | 4 | nenhuma, blush, sardas, coracoes |
| Bigode (`mustache`) | 6 | nenhum, classico, enrolado, fino, chevron, cavanhaque |
| Cabelo (`hair`) | 8 | nenhum, topete, tufinho, franja, cachos, coque, moicano, antena |
| Acessórios (`accessories`, vários) | 15 | oculos-redondos, oculos-quadrados, oculos-sol, monoculo, chapeu-festa, bone, gorro, cartola, coroa, laco, fones, aureola, chifres, orelhas-gato, flor |

Cores livres (sRGB) para **cabelo**, **bigode** e **acessórios tingíveis** (boné, gorro, laço,
fones, chifres, flor, orelhas de gato). `nil` = cor automática (cabelo puxa um tom escuro da
cor do Orb, bigode é branco e cada acessório tem o seu padrão).

Modelo: `OrbConfig` em [`Orbs/OrbModel.swift`](../Sources/OpenBotMac/Orbs/OrbModel.swift), salvo em `Bot.orb`.

```swift
var orb = OrbConfig()
orb.color = "rosa"; orb.eyes = "ovais"; orb.cheeks = "blush"
orb.hair = "tufinho"; orb.accessories = ["laco"]; orb.accentColor = 0xFF4F8B
```

### Onde o usuário edita
- **Novo bot** (⌘N): editor completo à esquerda, nome/função/modelo/permissões à direita.
- **Painel do bot → Orb → “Personalizar Orb…”**: o mesmo editor numa folha.
- O editor (`OrbEditor`) tem palco ao vivo (clicável, com prévia de cada atividade), abas por
  categoria, grade de miniaturas renderizadas (animam ao passar o mouse), seletor de cor e **Sortear**.

## 3. Atividades: o Orb mostra o que o bot está fazendo

`AppModel.activity(for:)` decide a atividade de cada bot, e o Orb muda expressão, olhar,
corpo e balão. Definições em [`Orbs/OrbActivity.swift`](../Sources/OpenBotMac/Orbs/OrbActivity.swift).

| Situação no app | Atividade | Olhos / boca / sobrancelhas | Olhar | Corpo | Balão |
|---|---|---|---|---|---|
| Nada acontecendo | `idle` | do bot | passeia devagar; segue o mouse | respira e flutua | — |
| Você acabou de enviar um prompt | `listening` (1,4 s) + **pulo** | do bot | olha para baixo (para o texto) | pulo com amassa-e-estica | — |
| Pensando / conectores / memória | `thinking` | boca “assobio” | para cima e para o lado | balança | … |
| Ferramenta de terminal | `typing` | olhos “fendas”, boca neutra, sobrancelhas retas | para baixo, tremendo | vibra (digitando) | — |
| Navegador / controlar o Mac | `browsing` | do bot | varre esquerda ↔ direita | balança | — |
| Lendo arquivos | `reading` | do bot | lê linha por linha | balança | — |
| Buscando | `searching` | olhos “ovais” | círculos | balança | — |
| Pedindo aprovação | `waiting` | “grandes”, boca “surpresa”, “preocupadas” | para você | pulinhos | ? |
| Terminou o turno | `happy` (3 s) | “felizes”, “sorrisão” | para você | pula e gira | — |
| Você parou / deu erro | `error` (2,5 s) | “tontos”, “triste”, “preocupadas” | treme | chacoalha | ! |
| Rotina pausada | `sleepy` | “sono” | baixo | inclinado, respirando | z |

O brilho (aura e sombra no chão) pulsa enquanto o bot trabalha.

## 4. Interação com o mouse

- **Os olhos seguem o cursor** em toda a janela, num raio de `max(320 pt, 5 × tamanho)`.
  Olhos, sobrancelhas, boca, cabelo e acessórios se deslocam em profundidades diferentes
  (paralaxe), então o Orb parece virar a cabeça.
- Cada atividade define o quanto o cursor pode “roubar” o olhar (`pointerWeight`): parado obedece
  totalmente; digitando no terminal quase não tira o olho do trabalho; com erro ou dormindo, ignora.
- **Passar o mouse por cima**: o Orb cresce um pouco (com uma leve sobra de mola), encara o ponteiro e,
  enquanto o ponteiro se mexe, roda a 60 fps (grandes) ou 30 fps (pequenos).
- **Clicar** (Orbs interativos: painel do bot, estado vazio do chat, editor): pula e fica feliz por 1,4 s.

### Movimento natural

Tudo em [`Orbs/OrbMotion.swift`](../Sources/OpenBotMac/Orbs/OrbMotion.swift) (funções puras, testadas em `OrbTests`):

- **Molas** (`Spring`, `SpringPoint`) no lugar de suavização exponencial: olhar, hover, balão e “gelatina”.
  Integradas em passos fixos de 1/240 s, então o resultado é o mesmo a 10 ou a 60 fps.
- **Olhos × cabeça**: os olhos pulam rápido para o alvo (mola de 0,07 s) e a cabeça (paralaxe do rosto)
  vem atrás (0,4 s); durante o movimento os olhos “lideram” (`eyeLead`).
- **Sacadas** (`Saccades`) quando parado: fixa um ponto por 0,8–2,8 s, salta para outro (quase sempre
  perto do centro, às vezes uma olhada mais longe) e tem uma deriva mínima durante a fixação. Ouvindo,
  esperando e feliz usam 30 % disso; as demais atividades seguem só o próprio padrão.
- **Piscadas** (`Blinker`): intervalo irregular de 2–7 s, fecha em 0,06 s e abre em 0,14 s, e 12 % das
  vezes pisca duas vezes. Também pisca quando a expressão muda (esconde a troca de camadas).
- **Troca de atividade sem saltos**: corpo, olhar, brilho e peso do ponteiro misturam a atividade anterior e
  a nova por 0,35 s (`OrbBodyMotion.mix`), a expressão faz crossfade de 0,18 s e o corpo dá um balanço leve.
- **Movimento secundário**: cabelo e acessórios de cabeça (não os óculos, `OrbLayer.isLoose`) atrasam um
  pouco nas viradas e nos pulos; o pouso do pulo vira uma mola subamortecida (amassa, estica, assenta).
  Nos pulinhos de `waiting`/`happy` o amassado no chão passa suave para o esticado no ar (`bounce`).
- **Balão** entra e sai com escala e opacidade em mola, em vez de aparecer de uma vez.
- **Reduzir movimento** continua mostrando o Orb estático.
- Orbs pequenos não interativos deixam o clique passar (selecionar a linha da barra lateral continua funcionando).

## 5. Onde aparecem

| Lugar | Tamanho | Animado |
|---|---|---|
| Barra lateral | 30 | o selecionado e os que estão trabalhando |
| Estado vazio do chat | 96 | sim, interativo |
| Linha “trabalhando” | 30 | sim |
| Mensagens do bot | 30 | não (estático) |
| Painel do bot | 60 | sim, interativo |
| Editor | 132 palco / 40 miniaturas | palco sempre; miniaturas ao passar o mouse |
| Rotinas | 26 | não; `sleepy` se a rotina está pausada |
| Pergunta rápida (barra de menus) | 28 seletor / 18 status | sim, segue a atividade |

## 6. Desempenho

O primeiro protótipo animava em SwiftUI (`TimelineView`), o que consumia ~37 % de CPU com 2 Orbs
na tela: cada frame refazia o grafo de views e o layout das linhas de `List`/`Form`. A versão
atual:

- **`AnimatedOrb`** é um `NSViewRepresentable` com uma `OrbAnimationView` em Core Animation. Um
  `CADisplayLink` (`NSView.displayLink`) só move as camadas (posição, escala, rotação, opacidade)
  dentro de uma `CATransaction` sem animações implícitas. O SwiftUI só é avisado quando a
  configuração ou a atividade muda.
- Por frame só se mudam posição, transformação e opacidade. Tamanhos, `anchorPoint`, cores dos
  gradientes e texto do balão são definidos uma vez (ao montar, mudar o tamanho ou a atividade).
  Ao trocar de expressão, as camadas que não mudam (corpo, bochechas, cabelo…) são reaproveitadas.
- **Taxa guiada pelo movimento** (`OrbFrameRate`): a cada frame mede-se quanto a pose andou na tela
  (`OrbPose.pixelDistance`, em pixels do dispositivo) e escolhe-se a menor taxa entre 10/15/20/30/60 fps
  em que cada passo fica abaixo de ~0,8 px. Sobe na hora, desce depois de 0,3 s calmo. Piscadas sobem para
  30 fps só enquanto duram; clique, hover com o ponteiro mexendo e troca de atividade vão ao máximo
  (60 grandes / 30 pequenos) por 0,4 s. Cada atividade tem um piso (`minFrameRate`): digitando/erro
  tremem a ~6 Hz e pulos precisam de 30 fps, senão a vibração vira um balanço lento (aliasing).
- **Frames sem mudança visível não são enviados**: se a pose mudou menos de 0,25 px desde o último frame
  desenhado, nada é tocado (sem `CATransaction`).
- **Pausa quando ninguém vê**: o display link para com a janela coberta ou minimizada
  (`NSWindow.occlusionState`) ou a view escondida, além de virar estático com a janela inativa
  (`appearsActive`). Respeita **Reduzir movimento**.
- **Imagens**: `OrbImages` decodifica com ImageIO direto no tamanho do balde (96/128/192/256/384/512/640 px;
  sem guardar o PNG inteiro decodificado), assa a tinta e guarda num cache thread-safe. Ao montar um Orb,
  todas as expressões das atividades são pré-decodificadas em segundo plano, então trocar de atividade
  não decodifica nada na thread principal. O `OrbFrame` estático usa os mesmos bitmaps (sem filtro de cor).

Frames por segundo (simulação da lógica real com tempo virtual, 120 s; 3 Orbs: 30, 96 e 60 pt):

| Cenário | Antes (frames = commits) | Agora: frames | Agora: commits |
|---|---|---|---|
| Parado (30 / 96 / 60 pt) | 15 / 30 / 15 = 60 | 12 / 18 / 14 = 44 | 6 / 13 / 10 = 30 |
| Trabalhando (terminal / pensando / buscando) | 30 / 60 / 30 = 120 | 30 / 24 / 20 = 74 | 21 / 23 / 20 = 63 |

CPU do processo, medido com os mesmos 3 Orbs numa janela invisível que não ativa o app (média de 20 s,
4 rodadas alternadas): parado **~1,0 % → ~0,7 %**, trabalhando **~1,6 % → ~1,4 %**. A maior parte do custo
restante é acordar a cada frame; o que cai pela metade (commits) também deixa de ser composto pelo
WindowServer, que não entra nesse número.

`OPENBOT_STATIC_ORBS=1` desliga toda a animação. `OPENBOT_ANIMATE_INACTIVE=1` mantém os Orbs animando com a
janela inativa ou coberta, só para medir CPU sem trazer o app para a frente.

## 7. Ferramentas de desenvolvimento

```bash
./scripts/bundle.sh && open build/OpenBot.app

# Folha de referência: Orbs de exemplo × atividades (usa o renderizador estático)
./build/OpenBot.app/Contents/MacOS/OpenBot --render-orbs docs/orbs-activities.png

# Envia um prompt ao abrir, para ver ouvir → tarefas → aprovação → feliz (use com scripts/fake-llm.py)
open -n build/OpenBot.app --env OPENBOT_SEND="Como está meu Mac?"

# Sem animação (comparar CPU)
OPENBOT_STATIC_ORBS=1 ./build/OpenBot.app/Contents/MacOS/OpenBot

# Medir CPU sem roubar o foco: anima mesmo com a janela inativa/coberta
open -g -n build/OpenBot.app --env OPENBOT_ANIMATE_INACTIVE=1 --env OPENBOT_DATA_DIR=/tmp/openbot-perf
ps -o %cpu= -p <pid>; sample <pid> 5
```

O display link só dispara com a tela ligada: com o monitor em repouso o custo é zero e a medição não
diz nada. `open -g` pode não criar a janela principal enquanto o app não é ativado; nesse caso, hospede
os Orbs numa janela própria sem borda, `alphaValue = 0`, `ignoresMouseEvents = true` e
`orderFrontRegardless()` (não ativa o app), com `OPENBOT_ANIMATE_INACTIVE=1`.

## 8. Arte: gerar e adicionar opções (Blender)

Requer Blender 5.2+ (`/Applications/Blender.app`). Tudo roda sem interface:

```bash
B=/Applications/Blender.app/Contents/MacOS/Blender
$B -b --python art/orbs.py -- catalog --category eyes   # folha de prévia de uma categoria
$B -b --python art/orbs.py -- personas                  # 12 personagens de exemplo
$B -b --python art/orbs.py -- render --config '{"color":"rosa","eyes":"ovais"}' --name teste
$B -b --python art/orbs.py -- layers                    # exporta TODAS as camadas para o app
$B -b --python art/orbs.py -- layers --category hair    # só uma categoria
$B -b --python art/orbs.py -- manifest                  # regrava options.json
```

Como as camadas são feitas:
- **Corpo**: um PNG por cor (`body/<cor>.png`).
- **Traços**: cada opção é renderizada sozinha, com o Orb como *holdout*: o que ficaria atrás da
  cabeça é recortado e a camada encaixa sobre qualquer corpo.
- Olhos, boca e sobrancelhas têm duas variantes: brilhante (cores escuras) e `-dark` (cores claras
  `perola`/`algodao`).
- Cabelo, bigode e acessórios tingíveis são renderizados **brancos** e multiplicados pela cor no app.
- Mesmo enquadramento em todas: câmera 85 mm, Orb ocupa ~51 % do quadro (sobra espaço para chapéus e auréola).

**Adicionar uma opção nova** (ex.: um chapéu):
1. Em `art/orbkit/features.py`, escreva o construtor e registre em `ACCESSORIES` como `("chapeu-x", "Chapéu X", build_fn)`.
2. Se ela deve aceitar cor, inclua o id em `TINTED_ACCESSORIES` (`art/orbs.py`) e dê um padrão em `OrbConfig.defaultAccent`.
3. Teste com `catalog --category accessories`, compare com as outras e depois rode `layers --category accessories` e `manifest`.
4. `./scripts/bundle.sh`: a opção aparece no editor sem mexer em Swift.

Para mudar a ordem das camadas ou a paralaxe: `OrbConfig.layers(...)` (ordem) e `OrbLayer.depth` (profundidade), aplicada em `OrbAnimationView.apply` e `OrbPainter.parallax`.

## 9. Mapa dos arquivos

| Arquivo | Papel |
|---|---|
| `art/orbs.py` | CLI do Blender: render, catálogo, personas, camadas, manifesto |
| `art/orbkit/core.py` | cena, luzes, câmera, materiais (gel, plástico, metal, tricô, vidro), primitivas |
| `art/orbkit/features.py` | paletas e todas as opções de rosto/cabelo/acessórios |
| `Resources/Orbs/` | camadas PNG + `options.json` (gerados) |
| `Orbs/OrbModel.swift` | `OrbConfig`, `OrbCatalog`, `OrbImages` (cache/redução/tinta), ordem das camadas |
| `Orbs/OrbActivity.swift` | atividades: expressão, olhar, movimento, brilho, balão |
| `Orbs/OrbView.swift` | `OrbView` (escolhe animado ou estático), `OrbFrame` (Canvas), `BotAvatar` |
| `Orbs/OrbAnimationView.swift` | `AnimatedOrb`: Core Animation, display link, ritmo de frames, mouse, pulo |
| `Orbs/OrbMotion.swift` | `OrbPose`, molas, piscadas, sacadas, escolha da taxa de frames (puro, testado em `OrbTests`) |
| `Orbs/OrbEditor.swift` | editor de personalização |
| `AppModel.swift` | `activity(for:)`, pulo ao enviar, feliz ao terminar, erro ao parar |
