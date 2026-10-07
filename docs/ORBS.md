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
- **Passar o mouse por cima**: o Orb cresce um pouco, encara o ponteiro e acelera para 60 fps (grandes) ou 30 fps (pequenos).
- **Clicar** (Orbs interativos: painel do bot, estado vazio do chat, editor): pula e fica feliz por 1,4 s.
- Piscadas a cada ~4,3 s, com fase aleatória por Orb.
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
- Camadas são `CGImage` **pré-tingidas** e reduzidas ao tamanho na tela (baldes 96/160/256/384/640 px, em cache).
- Taxa adaptativa: 15 fps parado (pequenos) / 30 fps (grandes); 30/60 fps ao passar o mouse,
  depois de um pulo ou enquanto o bot trabalha.
- Pausa quando a janela fica inativa (`appearsActive`) e respeita **Reduzir movimento**.

Medido no app empacotado: **~1 % de CPU** parado com a janela em foco (antes ~37 %) e ~17 % no meio
de um turno (Orbs ocupados + brilhos do transcript). `OPENBOT_STATIC_PETS=1` desliga toda a animação.

## 7. Ferramentas de desenvolvimento

```bash
./scripts/bundle.sh && open build/OpenBot.app

# Folha de referência: Orbs de exemplo × atividades (usa o renderizador estático)
./build/OpenBot.app/Contents/MacOS/OpenBot --render-orbs docs/orbs-activities.png

# Envia um prompt sozinho 2 s após abrir, para ver ouvir → tarefas → aprovação → feliz
OPENBOT_DEMO=1 ./build/OpenBot.app/Contents/MacOS/OpenBot

# Sem animação (comparar CPU)
OPENBOT_STATIC_PETS=1 ./build/OpenBot.app/Contents/MacOS/OpenBot
```

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

Para mudar a ordem das camadas ou a paralaxe: `OrbConfig.layers(...)` (ordem) e `OrbAnimationView.applyPose` / `OrbPainter.parallax` (profundidade).

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
| `Orbs/OrbAnimationView.swift` | `AnimatedOrb`: Core Animation, display link, mouse, pulo |
| `Orbs/OrbEditor.swift` | editor de personalização |
| `AppModel.swift` | `activity(for:)`, pulo ao enviar, feliz ao terminar, erro ao parar |
