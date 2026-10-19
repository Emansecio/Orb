# Orbs

No app Orb, cada assistente é um **Orb**: uma esfera **acetinada**, como vinil de toque macio, iluminada como um objeto
3D (luz difusa do alto à esquerda com sombra de forma, aro fosco fino, um lustro largo e baixo; sem reflexo de janela,
ponto de luz, aura nem brilho saindo pela base) e animada ao vivo no app. Todos os Orbs têm o mesmo formato redondo; a identidade vem da cor, do rosto, do cabelo e dos acessórios.

Este documento cobre o lado do app: opções, atividades, jeito, movimento, onde os Orbs aparecem e o sistema de animação
(desempenho incluído). **A arte e o gerador estão descritos em [art/README.md](../art/README.md)**; é lá que se vê como as
camadas são feitas e como acrescentar uma opção nova.

![Orbs × atividades](orbs-activities.png)

---

## 1. Como o app usa a arte

```
art/orbs.py + art/orbkit/          Blender 5.2: traços planos (olhos, bocas, sobrancelhas, bigodes,
        │  orbs.py layers          visemas, acessórios) -> art/orbgen/flat
        ▼
art/orbgen (Swift, CPU)            orbgen all: corpo iluminado (18 cores), cabelos por campos de distância
        │                          (+ -brilho e -chapeu), traços assentados com sombra de contato, options.json
        ▼
Sources/Orb/Resources/Orbs/     PNGs de 640 px em camadas (corpo, traços, cabelo, acessórios, visemas) + options.json (~4 MB)
        │  scripts/bundle.sh copia para Orb.app/Contents/Resources/Orbs
        ▼
OrbCatalog / OrbImages          lê options.json; decodifica, reduz e tinge as camadas (cache limitado), fora da thread principal (inclusive ao mudar de tela ou de tamanho: as camadas antigas ficam esticadas até as novas chegarem)
        │
        ├─ OrbFrame (Canvas)                        Orb estático: listas, miniaturas, ImageRenderer
        └─ AnimatedOrb → OrbAnimationView           Orb vivo: Core Animation, passos dados por um OrbDriver por tela
                                                    (um CADisplayLink compartilhado por todos os Orbs da tela)
```

O 3D é pré-renderizado. O app só **compõe camadas** (corpo + traços do rosto + cabelo + acessórios) e as anima com
transformações 2D. Assim fica leve e com qualidade de render. Toda a luz (reflexo, sombra de forma, sombra do cabelo na
testa, sombra de contato dos traços) já vem nas imagens: nada é desenhado por quadro. `OrbCatalog` procura `Orbs/`
primeiro no pacote do app e, sem ele (`swift run`, testes), na árvore de fontes (`Sources/Orb/Resources/Orbs`).

## 2. Opções de personalização

Os ids e rótulos vêm de `options.json` (gerado junto com as imagens); a tabela é o que existe hoje.

| Categoria | Qtde | Ids |
|---|---|---|
| Cor (`color`) | 18 | indigo, ceu, oceano, menta, lima, sol, pessego, coral, cereja, rosa, lavanda, ametista, aurora, algodao, chocolate, noite, grafite, perola |
| Olhos (`eyes`) | 12 | pilulas, pontos, ovais, grandes, fendas, felizes, sono, piscadela, estrelas, coracoes, tontos, bravos |
| Boca (`mouth`) | 10 | nenhuma, sorriso, sorrisao, surpresa, neutra, gatinho, lingua, dentinho, triste, assobio |
| Visemas (`visemes`, só para falar) | 4 | fala-a (aberta), fala-o (redonda), fala-e (larga), fala-m (fechada) |
| Sobrancelhas (`brows`) | 5 | nenhuma, retas, arqueadas, bravas, preocupadas |
| Bochechas (`cheeks`) | 4 | nenhuma, blush, sardas, coracoes |
| Bigode (`mustache`) | 6 | nenhum, classico, enrolado, fino, chevron, cavanhaque |
| Cabelo (`hair`) | 13 | nenhum, franja, ondulado, cachos, black-power, coque, rabo-de-cavalo, chiquinhas, topete, espetado, moicano, tufinho, antena |
| Acessórios (`accessories`, vários) | 15 | oculos-redondos, oculos-quadrados, oculos-sol, monoculo, chapeu-festa, bone, gorro, cartola, coroa, laco, fones, aureola, chifres, orelhas-gato, flor |
| Jeito (`temperament`) | 5 | calmo, equilibrado, animado, timido, curioso (ver 3a) |

Cores livres (sRGB) para **cabelo**, **bigode** e **acessórios tingíveis** (boné, gorro, laço,
fones, chifres, flor, orelhas de gato). `nil` = cor automática: o cabelo usa a cor desenhada para a paleta
(`"hair"` em cada cor do options.json; um tom mais fundo do corpo que ainda aparece no fundo escuro), o bigode
acompanha a cor de cabelo escolhida (senão é branco, e da cor do cabelo nos corpos claros: `OrbPalette.isPale`, branco
com contraste abaixo de 2,2:1 sobre o corpo, uma linha longe de todas as paletas, entre menta 2,35 e pêssego 2,08), os
fones são brancos, as orelhas de gato têm a cor do corpo sobre cabelo (senão a do cabelo) e cada outro acessório
tem o seu padrão. **Orbs salvos antes disso não mudam de cor:** `OrbConfig.autoColors` é `.original` para um
visual sem essa chave (cabelo em tom escuro do `deep`, bigode branco, orelhas no `deep`) e `.designed` para os
novos; só os fones ficaram brancos para todos (os escuros sumiam no fundo). Atenção: uma versão anterior do app que
regravar o estado não conhece a chave e a descarta, então esses Orbs voltam às cores `.original` (nada se perde além
disso; escolher uma cor no editor fixa a cor de vez).
O editor oferece cores com nome (`OrbSwatch`: Preto, Castanho, Ruivo, Loiro, Platinado… e algumas divertidas).

**Cabelo em duas camadas.** `hair/<id>` é branco e sombreado (luz, oclusão, textura de fios) e o app o multiplica
pela cor; `hair/<id>-brilho` vem por cima sem tinta: a faixa de brilho dos fios, o aro de luz, elásticos e a
sombra que o cabelo faz na testa. As duas são camadas soltas (balançam juntas). **Chapéus:** com boné, gorro,
cartola, coroa ou chapéu de festa (`"hats"` no options.json), os estilos altos usam `hair/<id>-chapeu`
(coque, topete e moicano penteados para trás, sem nada atravessando o chapéu).

**Ids antigos e de versões mais novas.** Os ids ficam salvos como vieram; só ao desenhar (`layers()`) um id que o
catálogo não conhece vira o padrão (acessórios desconhecidos não são desenhados) e um id renomeado vira o sucessor
listado em `OrbConfig.legacyIDs`. Assim um Orb criado numa versão mais nova não perde nada ao passar por esta.
O redesenho do cabelo manteve todos os ids anteriores.

Modelo: `OrbConfig` em [`Orbs/OrbModel.swift`](../Sources/Orb/Orbs/OrbModel.swift), salvo em `Bot.orb`.

```swift
var orb = OrbConfig()
orb.color = "rosa"; orb.eyes = "ovais"; orb.cheeks = "blush"
orb.hair = "tufinho"; orb.accessories = ["laco"]; orb.accentColor = 0xFF4F8B
```

### Onde o usuário edita
- **Novo Orb** (⌘N): o formulário (nome, papel, modelo, pasta e opções avançadas) à esquerda e o editor à direita.
- **Painel do Orb** (⌥⌘B): no cabeçalho, **"Personalizar…"** abre o mesmo editor numa folha. O menu de contexto do Orb na
  barra lateral também tem "Personalizar…" (`AppModel.showLookEditor`).
- O editor (`OrbEditor`) tem um palco ao vivo de 144 pt com holofote neutro (clicável, com prévia de
  cada atividade), categorias em três grupos (**Corpo**: Cor, Jeito; **Rosto**: Olhos, Boca, Sobrancelhas,
  Bochechas, Bigode; **Estilo**: Cabelo, Acessórios), miniaturas que enquadram o que mudam (close do rosto para
  os traços, cabeça com espaço em cima para cabelo e chapéus; animam ao passar o mouse), cores com nome (anel
  visível em cores claras e escuras, cor personalizada aparece como amostra, bigode pode ser branco),
  **Sortear** (sorteio harmonioso que mantém o jeito, `OrbConfig.random(using:)`, sem antena sob chapéu, cartola
  afundada no black power nem tufinho atravessando boné, gorro ou coroa), **Pular** e **Desfazer** pelo gerenciador de desfazer da janela
  (`OrbEditUndo`: ⌘Z, ⇧⌘Z e Editar ▸ Desfazer). As categorias quebram em duas linhas quando o editor é estreito.
  O VoiceOver lê o visual inteiro do palco (`OrbConfig.summary`).
- **Palco compacto** (folha Novo Orb, ou o editor com menos de 680 pt de altura): Orb de 112 pt, Sortear,
  Desfazer e Pular no alto, ao lado da cabeça (onde nem chapéu nem pulo chegam), a prévia de atividade num menu no
  canto de baixo, sem o nome (o formulário ao lado já mostra) e as categorias numa linha de ícones (a escolhida com o
  nome). Assim as opções ficam com ~180 pt na folha de 520 pt e ~360 pt na de 700 pt.
- **Espaço para o Orb** (`OrbStageRoom`): o palco deixa 0,82 do tamanho do Orb em cima e 0,2 embaixo. Pulos que se
  somam (um clique durante o pulinho do jeito ou os pulos do Feliz) são suavizados abaixo de um teto (subida 0,19,
  esticada 0,06; um pulo normal fica igual), e um teste mede nos PNGs o chapéu mais alto no ponto mais alto possível
  (teto, crescimento do hover, cabelo atrasado, inclinação): 0,817 com o chapéu de festa.

## 3. Atividades: o Orb mostra o que está fazendo

A atividade de cada Orb é calculada no `BotLive` do Orb (`BotLive.activity`, uma função pura de poucos sinais:
`AppModel.activity(for:)` só a lê), e o Orb muda expressão, olhar, corpo e balão. Definições em
[`Orbs/OrbActivity.swift`](../Sources/Orb/Orbs/OrbActivity.swift).

| Situação no app | Atividade | Olhos / boca / sobrancelhas | Olhar | Corpo | Balão |
|---|---|---|---|---|---|
| Nada acontecendo | `idle` | do Orb | passeia devagar; segue o mouse | respira e flutua | — |
| Você está digitando para ele (parado) | `attentive` (até 3 s depois da última tecla) | do Orb; pisca menos | para baixo, para o campo; sacadas a 20 %, mouse a 30 % | respira e flutua (sem pulo) | — |
| A resposta está chegando | `speaking` | do Orb; a boca **fala** | para você, com pequenas sacadas | balança no ritmo da fala | — |
| Você acabou de enviar um prompt | `listening` (1,4 s) + **aceno** de envio (`.ack`) | do Orb | olha para baixo (para o texto) | aceno curto de 0,35 s, sem balanço | — |
| Pensando / conectores / memória | `thinking` | boca “assobio” | para cima e para o lado | balança | … |
| Ferramenta de terminal | `typing` | olhos “fendas”, boca neutra, sobrancelhas retas | para baixo, tremendo | vibra (digitando) | — |
| Navegador / controlar o Mac | `browsing` | do Orb | varre esquerda ↔ direita | balança | — |
| Lendo arquivos | `reading` | do Orb | lê linha por linha | balança | — |
| Buscando | `searching` | olhos “ovais” | círculos | balança | — |
| Pedindo aprovação | `waiting` | “grandes”, boca “surpresa”, “preocupadas” | para você | em ciclos: 3 pulos nos primeiros 3 s, depois 2 pulinhos a cada 7 s e só a respiração no intervalo (altura × 0,6 depois de 60 s) | ? |
| Terminou o turno | `happy` em três níveis (1,6 / 2,2 / 3 s) | “felizes”, “sorrisão” | para você | alegria que acalma: pulos cada vez mais baixos, depois um balanço contente (leve: um pulo só) | — |
| Deu erro (falha do motor ou do setup) | `error` (2,5 s) | “tontos”, “triste”, “preocupadas” | treme | um “não” de 3 Hz que se apaga em ~1,2 s; depois fica caído (−3°) | ! |
| Você parou a resposta | uma piscada (`OrbCue.blink`), sem mudar de atividade | — | — | — | — |
| Tarefa que parou no meio, resposta cortada | um suspiro (`OrbCue.sigh`), sem alegria | — | — | respira fundo | — |
| Rotina pausada (cartão na página Rotinas) | `sleepy` | “sono” | baixo | inclinado, respirando | z |

A sombra no chão (neutra, preta, não na cor do Orb; `OrbShadow.stops`) pulsa enquanto o Orb trabalha (`0,89 + 0,11·sin(2,4 t)`: abaixo de 1, para a opacidade
não saturar, e devagar o bastante para um quadro a 10 fps mudar menos de ¼ de pixel). "Conectores" e "memória" (`remember`/`recall`) mostram
`thinking`, como o raciocínio; ler arquivos mostra `reading`; `search_files`, `grep` e `glob` mostram `searching`.

Prioridade em `BotLive.activity`: esperando > erro > feliz > ferramenta > falando > ouvindo/pensando > atento > parado.
Um Orb trabalhando continua trabalhando enquanto você escreve para ele. Os rastros curtos (`listening` 1,4 s, `happy`
1,6 / 2,2 / 3 s, `error` 2,5 s) são sinais que a sessão liga por um prazo (`BotSession.flash`): cada sinal tem a sua
`Task`, e ligar o mesmo de novo cancela a anterior (a velha apagaria o novo antes da hora). Começar um turno
(`BotSession.clearBeats`, ao enviar e em `beginTurn`) limpa a alegria e o erro do turno anterior.

**Parar não é erro.** `finishTurn(…, userStopped: true)` (Parar e Parar e enviar) não liga `hasFailed`: o Orb só pisca
uma vez (`BotLive.cued(.blink)`). Só falha do motor (`.failed`) e do setup (`failSetup`) mostram o erro. Quem tem a vista
em movimento recebe o sinal (`OrbAnimationView.cueNow`): um avatar que ainda está assentando (o que acaba de ser
solto pelo fim do turno) pisca por cima da pose de repouso; um que já descansa não tem quem o veja e ignora.

**Comemoração por tamanho** (`OrbCelebration.level`, com a duração do turno, as ações e se era rotina):

| Nível | Quando | Duração | Corpo |
|---|---|---|---|
| Leve | menos de 8 s e no máximo 1 ação; rotina com o Orb não selecionado | 1,6 s | rosto feliz e um único pulo de 0,05 |
| Normal | o resto | 2,2 s | pulos até 1,6 s depois do amassado, pulo de 0,08 |
| Grande | mais de 45 s, 8 ações ou mais, ou rotina concluída com o Orb selecionado | 3 s | o de sempre: pulo de 0,1, calma em 2,2 s |

Tarefa que parou no meio (`isTaskPaused`) ou resposta cortada pelo limite do modelo (`AgentEngine.cutShortNotice`) não
comemora: só o suspiro (`OrbFlourish.sigh`). O clique num Orb parado, atento, ouvindo ou falando mostra só o rosto feliz
(`OrbCelebration.smile`, 1,4 s, sem os pulos do feliz); em pensando, espera ou erro o Orb mantém a cara.

### Reagindo à interface

- **Atento** (`attentive`): `BotLive.noteComposing` liga na primeira tecla do compositor e desliga 3 s depois
  da última, ou na hora quando o campo fica vazio (apagou tudo, enviou ou o Orb foi apagado). Como `speaking`, só o
  começo e o fim da rajada mudam o que as views leem; cada tecla só empurra um prazo que ninguém observa
  (`ComposingDeadline`, conferido por uma `Task` por Orb). O gancho é o setter do campo do compositor
  (`AppModel.editDraft`): só o que você digita (ou completa com `/`) liga; o que o app escreve no rascunho
  (`setDraft`: mensagem da fila devolvida, habilidade inserida) não. Custa o mesmo que `idle` (piso de 10 fps).
  Parado, atento e ouvindo têm o mesmo rosto (`hasSameFace`): trocar entre eles só mistura olhar e corpo, sem
  piscada (só uma ao começar a olhar o campo), sem balanço e sem reconstruir camadas, então as rajadas de digitação
  não dão tique. Só o avatar segue a atividade (`LiveBotAvatar`): o painel do Orb e o chat vazio não se redesenham
  quando você começa ou para de digitar.
- **Selecionado**: ao escolher um Orb, `BotLive.glance` aumenta e o Orb da barra lateral olha rápido para o chat, à
  direita, e pisca ao chegar (`OrbGlance`: vira em 0,16 s, olha 0,6 para o lado, segura, volta até 0,6 s; os olhos
  chegam 50 ms antes da cabeça e o cabelo 70 ms depois). Uma seleção que vem menos de 1,2 s depois da última olhada é
  ignorada (descer a lista com as setas não faz os Orbs olharem o tempo todo). A olhada é aplicada por cima do assentamento, então aparece inteira mesmo no Orb
  que estava pausado e acabou de acordar. Um Orb pausado ignora a olhada (não a repete ao voltar).
- **Três pulos** (`OrbJump`): o **envio** (`ack`, `BotLive.poke`) é um aceno de 0,35 s com elevação de 0,08 e amassado de
  0,05, sem balanço; o **clique** (`play`) fica com o pulo de 0,16, 0,55 s, e o balanço de 1,6; a **aterrissagem** do chat
  vazio e da boas-vindas (`landing`) é só um amassado de 0,06 em 0,08 s, 0,12 s depois de pedida, com balanço de 1,0 e sem
  subida. Quem pede para o chat rolar até a bolha "na fila" ou até a mensagem entregue ao modelo (steering) usa o contador
  `BotLive.scrollNudge`, que não faz o Orb pular.
- **Ferramentas em paralelo**: `runningTool` é a última chamada ainda aberta (`BotSession.openTool`), então terminar uma
  das duas não devolve o Orb a "pensando". E o Orb só confirma "pensando" depois de 0,6 s sem ferramenta
  (`OrbActivityHold`): entre uma ferramenta e a seguinte ele guarda a pose da primeira. Espera, erro e feliz entram na hora.
- Com **Reduzir movimento**, o Orb é estático: atento fica igual a parado (não tem expressão própria), e a olhada, os
  pulos, o suspiro e a piscada de parar não acontecem.
- Folha de revisão: `Orb --render-orbs reacoes.png reacoes` (parado, atento e a olhada quadro a quadro).

### Falando

`BotSession.markSpeaking` marca o Orb como falando (`BotLive.isSpeaking`) quando chega um trecho de texto da resposta
(que não seja só espaço) e `stopSpeaking` desmarca depois de 1,2 s sem texto novo (`BotSession.speakingQuiet`), ao
começar uma ferramenta, ao pedir aprovação e ao terminar o turno. O estado só muda no começo e no fim de cada rajada de
texto (um prazo por Orb, conferido por uma única `Task`), então o streaming não ganha nenhuma invalidação de SwiftUI por
token. Uma resposta de um Orb já apagado não cria vigia nova.

No Orb, tudo acontece em `OrbAnimationView`:
- **Sílabas procedurais** (`Syllables`, em [`Orbs/OrbSpeech.swift`](../Sources/Orb/Orbs/OrbSpeech.swift)):
  formas abertas `fala-a` / `fala-e` / `fala-o` a ~4–7 trocas por segundo, em “palavras” de 1–4 sílabas
  separadas por pausas curtas com a boca fechada (`fala-m`) e, às vezes, uma pausa de vírgula. A boca fechada
  só aparece nas pausas: em corpos escuros ela é uma linha clara e alternar com as aberturas escuras piscaria.
- A troca é só de `contents` da camada da boca, entre bitmaps já decodificados (pré-aquecidos em segundo
  plano junto com as expressões). Uma mola de “mandíbula” faz cada forma nova começar com a abertura da
  anterior e esticar até o lugar (escala vertical a partir do lábio de cima, `OrbGeometry.mouthLine`), então não
  parece um flipbook. Trocas entre aberta e fechada/normal ganham um crossfade de 0,06 s.
- Quando a fala para, a boca fecha (`fala-m`) e volta para a boca normal do Orb.
- **Sem boca** (`nenhuma`): não aparece boca falando; os olhos apertam e sobem um pouquinho no ritmo das sílabas.
- **Sem as imagens** `visemes/`: usa as bocas normais (surpresa ≈ o, sorrisão ≈ a, sorriso ≈ e, neutra ≈ m).
  Paletas claras usam a variante `-dark`, como as bocas.
- Ritmo e tamanho variam com o jeito: animado fala mais rápido e abre mais a boca; calmo, mais devagar.

## 3a. Jeito (personalidade)

Cada Orb tem um **jeito** (`OrbConfig.temperament`, aba **Jeito** do editor). Ele não muda o que o Orb faz,
só *como*: o ritmo das piscadas e sacadas, a rapidez do olhar, a altura dos pulos, como reage ao ponteiro e
pequenos gestos espontâneos. Tudo passa pelo mesmo pipeline de movimento (`OrbTemperament.Traits` em
[`Orbs/OrbTemperament.swift`](../Sources/Orb/Orbs/OrbTemperament.swift) alimenta `Blinker`, `Saccades`,
as molas e `OrbActivity.motion`). Ao escolher um jeito, o Orb faz o seu gesto característico.

| Jeito | Piscadas | Sacadas | Molas | Pulos / balanço | Ponteiro | Gestos espontâneos | Ao escolher |
|---|---|---|---|---|---|---|---|
| Calmo | 3,5–9 s, raramente duplas (~12/min) | raras e curtas, fixação × 1,8 (~19/min) | 1,5× mais lentas | 0,7× / balanço baixo e lento | menos interesse | suspiro (40–90 s) | suspiro |
| **Equilibrado** (padrão) | 2,5–8 s, expoente 1,5 (~14/min) | normais, fixação × 1,25 (~29/min) | normais | normais | normal | — | pulinho |
| Animado | 1,8–5,5 s, duplas de 0,15 (~21/min) | frequentes e largas, fixação × 0,75 (~50/min) | mais rápidas | 1,4× / mais vivo | um pouco mais | pulinho ou rebolado de 7° (18–40 s) | rebolado |
| Tímido | 2,2–7 s, duplas nervosas de 0,25 (~19/min) | curtas, fixação × 1,25 (~28/min) | um pouco mais lentas | 0,65× | **desvia o olhar** para baixo e para o lado quando o ponteiro chega perto, espia de volta por 0,4–0,7 s a cada 1,6–3,8 s; inclina-se para trás no hover e cresce menos | gesto tímido (45–90 s) | olha para baixo e espia |
| Curioso | 2–6,5 s (~19/min) | mais frequentes, fixação × 0,95 (~40/min) | mais rápidas | 1,1× | nota o ponteiro de 1,7× mais longe, com mais vontade, **inclina a cabeça** para ele e cresce mais no hover | olha em volta (14–30 s) | olha em volta |

Calmo e Curioso mantêm a piscada de antes (expoente 2, `Traits.blinkSkew`); os outros pedem gaps curtos um pouco menos
(expoente 1,5). As frequências por minuto da tabela são as medidas em `OrbRhythmTests` (duas horas simuladas de cada jeito). Orbs salvos antes desta versão (sem a chave
`temperament`) carregam como equilibrados: `OrbConfig` decodifica de forma tolerante.
O Orb aplica os traços do jeito já na primeira configuração (também o Equilibrado: antes só quem mudava de jeito os recebia
e o Equilibrado ficava com a fixação × 1,0 dos auxiliares).

## 4. Interação com o mouse

- **Os olhos seguem o cursor** em toda a janela, num raio de `max(320 pt, 5 × tamanho)`.
  Olhos, sobrancelhas, boca, cabelo e acessórios se deslocam em profundidades diferentes
  (paralaxe), então o Orb parece virar a cabeça. Óculos e monóculo (`OrbLayer.isEyewear`) andam com os olhos, e as lentes
  não escorregam para fora deles.
- Cada atividade define o quanto o cursor pode “roubar” o olhar (`pointerWeight`): parado obedece
  totalmente; digitando no terminal quase não tira o olho do trabalho; com erro ou dormindo, ignora.
- **Passar o mouse por cima**: o Orb cresce um pouco (com uma leve sobra de mola), encara o ponteiro e,
  enquanto o ponteiro se mexe, roda a 60 fps (grandes) ou 30 fps (pequenos).
- **Clicar** (Orbs interativos: painel do Orb, estado vazio do chat, editor): pula e, se está parado, atento, ouvindo ou
  falando, mostra o rosto feliz por 1,4 s (sem os pulos do feliz). O hover só sobe a taxa de quadros quando o mouse andou
  mais de 3 pt desde a última subida e passaram 100 ms (`HoverGate`); o olhar segue o mouse de qualquer jeito.

### Movimento natural

Tudo em [`Orbs/OrbMotion.swift`](../Sources/Orb/Orbs/OrbMotion.swift) (funções puras, testadas em `OrbTests`):

- **Molas** (`Spring`, `SpringPoint`) no lugar de suavização exponencial: olhar, hover, balão e “gelatina”.
  Integradas em passos fixos de 1/240 s, então o resultado é o mesmo a 10 ou a 60 fps.
- **Olhos × cabeça**: os olhos pulam rápido para o alvo (mola de 0,07 s) e a cabeça (paralaxe do rosto)
  vem atrás (0,4 s); durante o movimento os olhos “lideram” (`eyeLead`).
- **Sacadas** (`Saccades`) quando parado: fixa um ponto por 0,8–2,8 s, salta para outro (quase sempre
  perto do centro, às vezes uma olhada mais longe) e tem uma deriva mínima durante a fixação. Ouvindo,
  esperando e feliz usam 30 % disso; as demais atividades seguem só o próprio padrão.
- **Piscadas** (`Blinker`): intervalo irregular de 2,5–8 s (expoente 1,5: os curtos são mais prováveis), fecha em
  0,06 s e abre em 0,14 s, e 12 % das vezes pisca duas vezes. Também pisca quando a expressão muda (esconde a troca de
  camadas) e, parado, em ~35 % das olhadas largas (`Saccades.isGlance`), como as pessoas fazem; esses pedidos só piscam se
  a última piscada terminou há mais de 1,5 s (`Blinker.minimumGap`), e a troca de rosto só dá o balanço de gelatina se o
  rosto novo é mais agitado (`OrbActivity.energy`: de parado para feliz sim, de feliz para parado não) e se o Orb pode mostrar quadros: com a
  janela oculta ou o Orb rolado para fora o chute não vale, porque a mola só anda em quadros e os chutes se acumulariam e
  estourariam na volta (a mola também zera quando o Orb para de rodar). Olhos fechados
  não piscam: felizes e sono 0, tontos 35 %, os demais 1 (`Blinker.factor`), e quem não pisca também não pede os 30 fps.
- **Sombra no chão** (`OrbShadow`): fica mais estreita, mais achatada e mais fraca conforme o Orb sobe, e mais
  larga quando ele amassa no pouso ou cresce no hover. Em repouso é igual à de antes; o Orb estático usa a mesma.
- **Troca de atividade sem saltos**: corpo, olhar, brilho e peso do ponteiro misturam a atividade anterior e
  a nova por 0,35 s (`OrbBodyMotion.mix`), a expressão faz crossfade de 0,18 s e o corpo dá um balanço leve. O
  crossfade é só da feição que mudou (olhos, boca e sobrancelhas trocam a imagem na mesma camada): fundir o Orb inteiro
  misturaria o corpo, que se move, com uma foto parada dele. Só um Orb que aparece ou muda de tamanho funde inteiro.
  Uma troca que chega no meio de outra parte do corpo que estava na tela naquele instante (`OrbActivityBlend`),
  não da atividade que pesava pouco: ferramentas rápidas entre dois pensamentos não dão salto.
- **Movimento secundário**: cabelo e acessórios de cabeça (não os óculos, `OrbLayer.isLoose`) atrasam um
  pouco nas viradas e nos pulos e **giram atrás da inclinação do corpo** em torno do alto da cabeça
  (`OrbGeometry.crownLine`), como cabelo pendurado: rabo de cavalo, chiquinhas e chapéus balançam (mola com sobra,
  até 3°, `OrbSprings`); o pouso do pulo vira uma mola subamortecida (amassa, estica, assenta).
- **Respiração**: elevação 0,018 (ω 1,3, ~4,8 s), amassado 0,016 (~3,1 s); o cabelo e os chapéus voltam com amortecimento 0,5.
- **Parado**: além da respiração e da flutuação, um balanço de ~1° com período de ~11 s, fora de fase com os
  dois, então o Orb nunca parece estar em loop (lento demais para mudar a taxa de quadros).
- **Reações de uma vez** (`OrbActivity.motion(at:elapsed:celebration:)`): `happy` usa o tempo desde que começou: o primeiro
  pulo vem depois de 0,3 s de amassado (a antecipação, que aparece apesar da mistura de 0,35 s entre atividades),
  cada pulo é mais baixo e no fim volta à flutuação de repouso com um balanço contente, já no piso de 10 fps
  (`minFrameRate(elapsed:size:celebration:)`): a prévia do editor não fica a 30 fps para sempre. `waiting` conta em
  segundos de parede (`OrbWaiting`): 3 pulos que perdem energia nos primeiros 3 s, depois 2 pulinhos de 0,4 da altura a
  cada 7 s e só a respiração no intervalo, com o amassado do pouso entrando e saindo suave em volta de cada grupo; só
  nos pulos o piso é 30 fps (10 no resto). `error` é um "não" de 3 Hz que se apaga com exp(−2,2 e), cai a −3° e fica com
  o brilho fixo em 0,85, a 10 fps depois de 1,3 s.
  Nos pulinhos de `waiting`/`happy` o amassado no chão passa suave para o esticado no ar (`bounce`).
- **Balão** entra e sai com escala e opacidade em mola, em vez de aparecer de uma vez. Trocar de símbolo com
  ele aberto (… → ?) dá um pulinho de escala em vez de só trocar o texto. O fundo é quase opaco (cor do chrome,
  `OrbGeometry.bubbleFill`), para o laço e a aba dos chapéus não aparecerem através dele. Um Orb em repouso
  (janela inativa) recebe o balão e a boca da nova atividade na hora, sem esperar quadros. Quem decide se há balão é a
  caixa do avatar (a partir de `OrbGeometry.bubbleBox`, 26 pt), não o Orb: um black power ou uma cartola encolhem o
  Orb dentro dos 30 pt da barra lateral (`OrbFootprint`), e o `?` de "precisa de você" continua aparecendo.
- **Pausar e voltar sem salto**: um Orb animado que deve ficar quieto (`OrbView(paused:)`, ou janela inativa)
  não é mais trocado pelo `OrbFrame` estático: ele desliza até a pose de repouso (a mesma do estático, mola de
  0,45 s, `OrbPose.mix`), para o display link e volta deslizando ao retomar. Um Orb novo também começa em
  repouso e entra em movimento suavemente. Antes, trocar de app ou de Orb na barra lateral fazia os olhos e o
  corpo pularem para o centro e recriava a view.
- **Reduzir movimento** continua mostrando o Orb estático.
- Orbs pequenos não interativos deixam o clique passar (selecionar a linha da barra lateral continua funcionando).

- Os gestos do jeito (`OrbFlourish`: pulinho, rebolado de 7°, olhar em volta, timidez, suspiro) são funções puras do
  tempo, começam e terminam em repouso e só acontecem com o Orb parado e sem o mouse em cima.

## 5. Onde aparecem

| Lugar | Tamanho | Animado |
|---|---|---|
| Barra lateral | 30 | o selecionado e os que não estão parados; os outros ficam pausados em repouso (sem frames) |
| Estado vazio do chat | 96 | sim, interativo |
| Linha “trabalhando” | 30 | sim |
| Mensagens do Orb | 30 | não (estático) |
| Painel do Orb | 60 | sim, interativo |
| Editor | 144 palco (112 no compacto) / miniaturas 44–80 (close do rosto) | palco sempre (com prévia de “Falando” e do jeito); miniaturas ao passar o mouse |
| Rotinas (cartões) | 30 | não; `sleepy` se a rotina está pausada |
| Pergunta rápida (barra de menus) | 28 seletor / 18 status e cartões | só o escolhido e os que estão trabalhando se mexem |

## 6. Desempenho

O primeiro protótipo animava em SwiftUI (`TimelineView`), o que consumia ~37 % de CPU com 2 Orbs
na tela: cada frame refazia o grafo de views e o layout das linhas de `List`/`Form`. A versão
atual:

- **Core Animation, sem SwiftUI por frame.** `AnimatedOrb` é um `NSViewRepresentable` com uma `OrbAnimationView`. Os
  frames só movem camadas (posição, escala, rotação, opacidade) dentro de uma `CATransaction` sem animações implícitas. O
  SwiftUI só é avisado quando a configuração ou a atividade muda. Tamanhos, `anchorPoint`, cores dos gradientes e texto do
  balão são definidos uma vez (ao montar, mudar o tamanho ou a atividade). Ao trocar de expressão, as camadas que não
  mudam (corpo, bochechas, cabelo…) são reaproveitadas.
- **Um display link por tela, compartilhado** (`OrbDriver`). Em vez de um `CADisplayLink` e um commit de Core Animation
  por Orb, todos os Orbs de uma tela são passos de um só link, e os passos de um tick ficam numa única `CATransaction`.
  Cada Orb decide o próprio ritmo (`OrbFrameClock`: um Orb que quer 10 fps num link de 30 Hz toma um tick em três, sem
  rajada de quadros atrasados depois de uma pausa). O link roda na menor taxa de 10/15/20/30/60 que todas as taxas dos Orbs
  em movimento dividem (`OrbLinkRate`): 20 fps num link de 30 Hz alternaria intervalos de 33 e 67 ms. Até 30 fps o
  link nunca passa de 30 Hz: um Orb cuja taxa o link não divide (20 num link de 30) anda na taxa de cima que o divide
  (`OrbLinkRate.stepRate`: 30; mais suave, nunca mais travado), em vez de o link subir a 60 Hz. Ele pausa quando
  nenhum Orb roda, segue o Orb que muda de tela (`NSWindow.didChangeScreenNotification`) e some com o último Orb da tela.
- **Taxa guiada pelo movimento** (`OrbFrameRate`): a cada frame mede-se quanto a pose andou na tela
  (`OrbPose.pixelDistance`, em pixels do dispositivo) e escolhe-se a menor taxa entre 10/15/20/30/60 fps
  em que cada passo fica abaixo de ~0,8 px. Sobe na hora, desce depois de 0,3 s calmo. Piscadas sobem para
  30 fps só enquanto duram; clique, hover com o ponteiro mexendo e troca de atividade vão ao máximo
  (60 grandes / 30 pequenos) por 0,4 s. Cada atividade tem um piso (`minFrameRate(elapsed:size:celebration:)`), o que o
  movimento precisa *agora*, senão a vibração vira um balanço lento (aliasing): digitando tremia a ~6 Hz e agora a
  ~4,5 Hz (sin(28 t)), então 20 fps bastam abaixo de 80 pt (30 acima); o erro precisa de 20/30 só durante o "não" e
  10 depois de 1,3 s; "precisa de você" e `happy` precisam de 30 só nos pulos (o feliz leve e o sorriso do clique, nem
  isso); pensando, lendo, buscando e navegando ficam em 10 abaixo de 40 pt (onde um passo é uma fração de pixel) e em
  15 acima. O brilho de status em movimento pesava 8 no `pixelDistance` e saturava em 1; com a amplitude de 0,11 não
  satura e, a 10 fps, muda ~0,21 px por quadro, abaixo do limiar de 0,25 px. **Orbs grandes** (80 pt ou
  mais: estado vazio do chat e editor) ficam limitados a 30 fps e só chegam a 60 durante algo vivo.
- **A lista de Orbs que rodam** fica no `OrbDriver` e é refeita quando algo muda (`refresh`), não a cada tick do link;
  o brilho do texto (`ShimmerBandView`) pede de 24 a 30 fps ao Core Animation; a resposta de 18 pt na barra de menus
  descansa quando o Orb está parado.
- **Frames sem mudança visível não são enviados**: se a pose mudou menos de 0,25 px desde o último frame
  desenhado, nada é tocado.
- **Pausa quando ninguém vê.** Um Orb só "roda" (`isRunning`) com a janela visível (não coberta nem minimizada,
  `NSWindow.occlusionState`), a view sem estar escondida **e o Orb dentro da parte visível do `ScrollView`** em que mora
  (barra lateral, conversa; `OrbVisibility`), mesmo sendo o selecionado ou um que trabalha. Quem sai da vista confere de
  novo duas vezes por segundo (um timer com tolerância, só enquanto rodaria se estivesse à vista), então janela coberta,
  app escondido e Orb parado não acordam a CPU. Com a janela inativa (`appearsActive`) ou `paused`, o Orb assenta na pose
  de repouso e para (0 % de CPU medido, a mesma view continua montada). Na barra lateral só o selecionado e os que não
  estão parados rodam; no painel da barra de menus, só o escolhido e os que trabalham. Respeita **Reduzir movimento**.
  Um Orb que ficou pausado enquanto estava fora da vista vai direto ao repouso (sem quadros ele nunca assentaria e o timer
  de 0,5 s ficaria ligado), e ao entrar em repouso o sorriso do clique e a pose segurada da ferramenta, se ainda não
  venceram, são descartados: com os quadros parados nada reavaliaria o prazo e o rosto congelaria.
- **Imagens decodificadas fora da thread principal.** `OrbImages.cached` nunca decodifica; `OrbImages.load` decodifica em
  segundo plano (`.needed`, em paralelo; `.prewarm`, um por vez em prioridade baixa) e avisa na thread principal
  entregando os próprios bitmaps: quem montar as camadas usa esses, e o cache despejar um no meio não vira decodificação
  na thread principal. A view
  mantém o que mostra até as camadas novas chegarem, e o `OrbFrame` estático nunca desenha parte de um conjunto: mostra o
  último conjunto completo (ou nada). Ele guarda as próprias imagens desse conjunto (o cache é limitado e pode despejá-las). Depois da abertura, `OrbImages.prewarmResting` prepara as camadas de repouso de
  todos os Orbs nos tamanhos das primeiras telas (o Orb selecionado primeiro); ao montar um Orb animado, as expressões das
  atividades são pré-decodificadas (um Orb grande, só as prováveis: parado, pensando, falando, feliz, esperando).
- **Imagens no tamanho exato.** `OrbImages` decodifica com ImageIO direto no tamanho em pixels em que a camada é desenhada
  (`bitmapSide`, até 640 px; sem guardar o PNG inteiro), assa a tinta (multiplica os canais pré-multiplicados e mantém o
  alfa, então a borda suave escurece como o resto, sem contorno claro) e guarda num `NSCache` limitado a 96 MB (e as camadas
  sem tinta, que o seletor de cor reaproveita, em outro de 24 MB). O lado das imagens (`OrbGeometry.imageSide`) é um número
  inteiro de pixels, centrado no Orb com deslocamento inteiro, então um Orb parado mapeia 1:1 na tela, com filtro linear e
  sem mipmaps. Mudar a janela para uma tela com outra escala reconstrói bitmaps e texto.
- **O brilho de "trabalhando" também é Core Animation.** `shimmer()` (barra lateral, linha "Pensando… 12 s", linhas de
  ferramenta) mantém o texto parado e passa por cima uma faixa animada pelo render server (`ShimmerBandView`): o SwiftUI
  não muda nada por frame. A faixa para com a janela coberta e fica texto fixo com Reduzir movimento.
- **Estado por Orb.** A atividade, o status e o "falando" vivem no `BotLive` do Orb e só mudam quando o valor muda: um
  Orb trabalhando não redesenha a linha de outro (veja [ARQUITETURA.md](ARQUITETURA.md)).

**Medições.** Os números abaixo são da rodada que introduziu o ritmo guiado pelo movimento (então com um link por Orb).
O link compartilhado, a decodificação fora da thread principal e a pausa por rolagem vieram depois, para reduzir acordadas e
commits; estes números não foram refeitos com eles.

Frames por segundo (simulação da lógica real com tempo virtual, 120 s; 3 Orbs: 30, 96 e 60 pt):

| Cenário | Antes (frames = commits) | Agora: frames | Agora: commits |
|---|---|---|---|
| Parado (30 / 96 / 60 pt) | 15 / 30 / 15 = 60 | 12 / 18 / 14 = 44 | 6 / 13 / 10 = 30 |
| Trabalhando (terminal / pensando / buscando) | 30 / 60 / 30 = 120 | 30 / 24 / 20 = 74 | 21 / 23 / 20 = 63 |

CPU do processo, medido com os mesmos 3 Orbs numa janela invisível que não ativa o app (média de 20 s,
4 rodadas alternadas): parado **~1,0 % → ~0,7 %**, trabalhando **~1,6 % → ~1,4 %**. A maior parte do custo
restante é acordar a cada frame; o que cai pela metade (commits) também deixa de ser composto pelo
WindowServer, que não entra nesse número.

**Jeitos e fala** (mesma simulação de 120 s, 3 Orbs 30/96/60 pt, frames / commits por segundo somados):

| Cenário | Antes | Calmo | Equilibrado | Animado | Tímido | Curioso |
|---|---|---|---|---|---|---|
| Parado | 43,5 / 29,2 | 36,6 / 20,2 | 42,2 / 28,6 | 62,5 / 45,3 | 41,6 / 26,9 | 59,7 / 39,3 |
| Falando | — | 61,9 / 31,3 | 63,8 / 44,9 | 73,7 / 58,8 | 64,0 / 39,6 | 65,1 / 47,1 |

Pensando/terminal/buscando ficaram iguais (57 / 120 / 66 frames). Equilibrado parado não muda; calmo e tímido
ficam mais baratos; animado e curioso custam mais porque piscam, olham e se mexem mais (é o jeito deles; os
gestos espontâneos só sobem a taxa enquanto duram). Falando custa como “pensando”: as trocas de forma da boca
e a mola da mandíbula não contam como velocidade (assim como as piscadas) e a fala tem piso de 20 fps; sem
isso a mandíbula mantinha o Orb grande a 60 fps (110 frames/s somados). CPU com a tela ligada (uma rodada,
janela invisível): parado ~0,9 % antes → ~0,75 % equilibrado (ruído; a tela apagou antes das demais rodadas).

**Polimento das reações** (`--render-orbs bench`, release com `ORB_DEV_TOOLS`, janela invisível, 12 s por cenário depois de
3 s de assentamento, 2 rodadas por versão; "antes" é a `main` de antes do polimento, "depois" é esta). O contador mais
estável é instruções por segundo (`instr/s`); a CPU em % varia de rodada para rodada em um Mac em uso.

Tela ligada (link real), um Orb de 96 pt ocupado e o resto parado (média das 2 rodadas):

| Cenário | instr/s antes → depois | frames/s antes → depois |
|---|---|---|
| 1 Orb parado | 3,94 M → 3,42 M (−13 %) | 15,1 → 13,9 |
| 5 Orbs parados | 7,71 M → 7,28 M (−6 %) | 62,6 → 63,5 |
| 12 Orbs parados | 13,53 M → 11,95 M (−12 %) | 155,9 → 144,2 |
| 12 Orbs, o grande pensando | 14,81 M → 13,92 M (−6 %) | 164,3 → 157,5 |
| 5 Orbs, o grande no terminal | 10,61 M → 9,80 M (−8 %) | 81,3 → 80,0 |

Tela apagada (o bench faz o papel do `OrbDriver`), os 12 Orbs fazendo a mesma atividade (`bench 12 <atividade> all`: o
grande, o de 60 pt e dez de 30 pt; `draws/s` são os quadros que de fato moveram camadas):

| Os 12 Orbs | instr/s antes → depois | frames/s | draws/s |
|---|---|---|---|
| pensando | 28,7 M → 25,3 M (−12 %) | 206 → 150 (−27 %) | 184 → 133 |
| no terminal | 33,6 M → 32,6 M (−3 %) | 360 → 268 (−25 %) | 265 → 212 |
| pedindo aprovação | 39,0 M → 25,2 M (−36 %) | 360 → 150 (−58 %) | 313 → 130 |
| em erro (depois do "não") | 40,1 M → 27,2 M (−32 %) | 360 → 165 (−54 %) | 330 → 153 |

Antes desse ajuste, no terminal o ganho era pequeno porque o piso de 20 fps (Orbs de 30 pt) não divide os 30 fps das
piscadas (nem os 15 do "pensando" grande): quando um Orb piscava, o link compartilhado subia a 60 Hz e acordava a
thread principal o dobro das vezes. Agora o link fica em 30 Hz e o Orb de 20 fps anda a 30 (`OrbLinkRate.stepRate`).
Medido com o link real (tela ligada, 3 rodadas alternadas de 12 s, `bench 12 typing all`): 27,1 M → 24,5 M instr/s
(−9 %), CPU de ~0,93 % → ~0,67 %, ao custo de mais quadros (268 → 360/s: cada Orb de 20 fps passa a 30). `bench 12 working all`:
16,9 M → 16,0 M (−5 %), mesmos quadros. Com a tela apagada o bench não mede isso (o relógio emulado de 240 Hz acorda
sempre): lá os ticks caem de 60 para 30/s, mas as instruções sobem ~3 % pelos quadros extras.

`ORB_STATIC=1` desliga toda a animação. `ORB_ANIMATE_INACTIVE=1` mantém os Orbs animando com a
janela inativa ou coberta, só para medir CPU sem trazer o app para a frente.

**Arte nova (luz, cabelo em duas camadas, balanço do cabelo).** Toda a luz está nas imagens; por quadro o
cabelo acrescenta uma camada (`-brilho`) que se move junto. Para não custar mais, o corpo (que nunca se move dentro
do Orb) deixou de ser reposicionado a cada quadro e a rotação das camadas soltas só é reaplicada quando a borda do
cabelo andaria ¼ de pixel (parado, nunca). Medido com `--render-orbs bench` (tela apagada: o bench faz o papel do
`OrbDriver`), base `orb-melhorias` × este visual, medianas de 3 rodadas alternadas de 20 s, instruções do processo
por segundo (o piso do bench sem Orbs é ~9,5 M):

| Cenário | Base | Novo visual | Frames/s (base → novo) |
|---|---|---|---|
| 1 Orb parado (96 pt) | 11,95 M | 12,05 M | 14,1 → 14,2 |
| 5 Orbs parados (96, 60, 3 × 30 pt) | 15,41 M | 15,56 M | 64,4 → 65,3 |
| 12 Orbs parados | 20,07 M | 20,79 M | 154 → 158 |
| 5 Orbs, o de 96 pt pensando | 17,01 M | 17,22 M | 75,6 → 75,4 |
| 12 Orbs, o de 96 pt pensando | 21,52 M | 21,62 M | 165 → 164 |
| 5 Orbs, o de 96 pt no terminal | 17,38 M | 17,44 M | 84,8 → 81,7 |

Diferenças de 0 a +3 %, dentro da variação entre rodadas (as mesmas configurações variam ±2 % de uma rodada para
outra). Bitmaps: uma camada a mais por Orb com cabelo (54 KB a 30 pt, 552 KB a 96 pt, 1,35 MB no palco de 150 pt
do editor). Arte no app: 12 MB → 3,9 MB.

## 7. Ferramentas de desenvolvimento

```bash
./scripts/bundle.sh && open build/Orb.app

# Folha de referência: Orbs de exemplo × atividades (usa o renderizador estático)
# (--render-orbs e --snapshot só existem em build de desenvolvimento: use o binário de debug, ou
# `ORB_DEV_TOOLS=1 ./scripts/bundle.sh` para um bundle de release com as telas de revisão)
.build/debug/Orb --render-orbs docs/orbs-activities.png

# Uma tela do editor, fora da vista (os outros modos de --snapshot estão em ARQUITETURA.md);
# editor-<categoria> abre numa categoria (editor-hair, editor-eyes, editor-color…)
.build/debug/Orb --snapshot editor /tmp/editor.png
ORB_DATA_DIR=/tmp/orb-design .build/debug/Orb --snapshot editor-hair /tmp/editor.png

# Folhas de revisão de design (composição idêntica à do app): cabelos, cabelo-padrao, cabelo-acessorio,
# acessorios, olhos, bocas, detalhes, cores, tamanhos (18/30/60/96/132 pt, fundo escuro e claro), quadros, reacoes, polimento, icone
ORB_DATA_DIR=/tmp/orb-design .build/debug/Orb --render-orbs /tmp/cabelos.png cabelos

# O ícone do app é desenhado pelo próprio app (AppIcon): `--render-icon <png> [pixels]` (padrão 1024; em 16 px sai a variante
# sem anel, com o Orb e os olhos maiores). A folha "icone" mostra 1024/512/256/128/64/32/16 no tamanho real e ampliados, sobre
# papel de parede claro e escuro.
ORB_DATA_DIR=/tmp/orb-design .build/debug/Orb --render-icon /tmp/icone-128.png 128
ORB_DATA_DIR=/tmp/orb-design .build/debug/Orb --render-orbs /tmp/icone.png icone

# Bench de CPU: N Orbs vivos numa janela invisível; imprime CPU do processo e da thread principal, instruções
# (proc_pid_rusage), ticks do link e frames por segundo. Com a tela apagada, faz o papel do OrbDriver.
# Folhas e bench só existem em debug ou num release feito com ORB_DEV_TOOLS (o app distribuído não os leva).
# Num release sem ORB_DEV_TOOLS, `--render-orbs bench` ou `--render-orbs saída.png <folha>` avisa e sai com erro.
swift build -c release -Xswiftc -DORB_DEV_TOOLS
ORB_DATA_DIR=/tmp/orb-bench ORB_ANIMATE_INACTIVE=1 .build/release/Orb --render-orbs bench 12 [working|typing|waiting|error] [all] [segundos]   # imprime instr/s, frames/s e draws/s

# Envia um prompt ao abrir, para ver ouvir → tarefas → aprovação → feliz (use com scripts/fake-llm.py)
open -n build/Orb.app --env ORB_SEND="Como está meu Mac?"

# Sem animação (comparar CPU)
ORB_STATIC=1 ./build/Orb.app/Contents/MacOS/Orb

# Medir CPU sem roubar o foco: anima mesmo com a janela inativa/coberta
open -g -n build/Orb.app --env ORB_ANIMATE_INACTIVE=1 --env ORB_DATA_DIR=/tmp/orb-perf
ps -o %cpu= -p <pid>; sample <pid> 5
```

O display link só dispara com a tela ligada: com o monitor em repouso o custo é zero e a medição não
diz nada. `open -g` pode não criar a janela principal enquanto o app não é ativado; nesse caso, hospede
os Orbs numa janela própria sem borda, `alphaValue = 0`, `ignoresMouseEvents = true` e
`orderFrontRegardless()` (não ativa o app), com `ORB_ANIMATE_INACTIVE=1`.

## 8. Arte

As camadas, as opções e os geradores (`art/orbgen` em Swift para o corpo, os cabelos e o assentamento dos traços;
o Blender para os traços planos; como acrescentar um penteado, um chapéu ou um acessório; o manifesto `options.json`)
estão descritos em [art/README.md](../art/README.md). O app só depende do que sai de lá: os PNGs em
`Sources/Orb/Resources/Orbs/` e o `options.json` com os ids, rótulos e cores. Acrescentar uma opção nova não exige mexer em
Swift, exceto quando ela precisa de uma cor padrão (`OrbConfig.autoAccentColor(_:palette:)`) ou de uma ordem de camadas diferente
(`OrbConfig.layers(...)`; a profundidade da paralaxe está em `OrbLayer.depth`, aplicada em `OrbAnimationView.apply` e
`OrbPainter.parallax`).

## 9. Mapa dos arquivos

| Arquivo | Papel |
|---|---|
| `art/orbgen/` | arte procedural em Swift: corpo (`Body.swift`), cabelos (`Hair.swift`, `HairRenderer.swift`, `SDF.swift`), traços assentados (`Decals.swift`), `options.json` (`Manifest.swift`), prévias |
| `art/orbs.py`, `art/orbkit/` | Blender: traços planos (gravados em `art/orbgen/flat/`), catálogo, personas |
| `Resources/Orbs/` | camadas PNG + `options.json` (gerados; veja [art/README.md](../art/README.md)) |
| `Orbs/OrbModel.swift` | `OrbConfig` (cores automáticas, ids antigos, sorteio), `OrbCatalog`, `OrbSwatch`, `OrbImages` (decodificação, cache, tinta), `OrbLayer`, `OrbGeometry`, ordem das camadas |
| `Orbs/OrbActivity.swift` | atividades: expressão, olhar, movimento, brilho, balão; `OrbCelebration` (níveis do feliz), `OrbWaiting` (ciclos de "precisa de você"), `OrbActivityHold` (pausa entre ferramentas), `OrbCue` |
| `Orbs/OrbView.swift` | `OrbView` (escolhe animado ou estático), `OrbFrame` (Canvas), `BotAvatar` |
| `Orbs/OrbAnimationView.swift` | `AnimatedOrb` e `OrbAnimationView`: Core Animation, ritmo de frames, mouse, pulo, visibilidade |
| `Orbs/OrbDriver.swift` | `OrbDriver` (um link por tela), `OrbFrameClock`, `OrbLinkRate`, `OrbVisibility` |
| `Orbs/OrbMotion.swift` | `OrbPose`, molas, piscadas, sacadas, os três pulos (`OrbJump`), `HoverGate`, `OrbFrameRate` (puro, testado em `OrbTests`, `OrbRhythmTests`, `OrbPolishTests` e `OrbDriverTests`) |
| `Orbs/OrbTemperament.swift` | jeitos (`Traits`), gestos (`OrbFlourish`, `Flourishes`), olhar tímido (`shyGaze`, `Glances`) |
| `Orbs/OrbSpeech.swift` | visemas (`OrbViseme`, com boca reserva) e ritmo das sílabas (`Syllables`) |
| `Orbs/OrbEditor.swift` | editor de personalização |
| `Orbs/OrbDesignSheets.swift` | folhas de revisão de design (`--render-orbs saída.png <folha>`) |
| `AppIcon.swift` | o ícone do app: Orb índigo chapado com anel inclinado num ladrilho grafite |
| `Orbs/OrbBench.swift` | bench de CPU dos Orbs (`--render-orbs bench`) |
| `BotLive.swift` | `BotLive.activity` (a atividade de cada Orb), "digitando" (`noteComposing`, `ComposingDeadline`), a olhada ao ser escolhido (`glance`), o nível da comemoração (`celebration`), os sinais de parar e de suspirar (`cue`) e o contador que rola o chat (`scrollNudge`) |
| `Views/LiveBotAvatar.swift` | avatar que lê só a atividade, o envio, a comemoração e os sinais do Orb (painel, chat vazio, linha "trabalhando") |
| `BotSession+Turn.swift` | `markSpeaking` / `stopSpeaking`, `flash` com um prazo por sinal (ouvindo, feliz, erro), `celebrate`, `finishTurn(userStopped:)` |
| `Theme.swift` | `shimmer()` e `ShimmerBandView` (brilho em Core Animation) |
