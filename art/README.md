# Orbs: personagens 3D do app Orb

Bolas de pelúcia: pelo fino e denso, cada fio inclinado para um lado, com cacho leve e frizz nas pontas, e a borda
felpuda. O corpo de pelúcia sai do Blender (`pelucia.py`); até 2026-11 era a esfera acetinada do orbgen
(`orbgen body` ainda a gera, mas o `orbgen all` não a regrava mais). O cabelo e os acessórios saíram em 2026-11
(não combinavam com a pelúcia). A arte das camadas vem de três ferramentas:

- **`pelucia.py`** (Blender, Cycles, ~1 min por cor): o **corpo** de cada cor, no enquadramento do orbgen (640 px,
  raio de 168,5 px). Cada fio pega a cor do degradê da paleta na altura dele, um pouco mais saturada; o miolo é 8 %
  menor para a borda felpuda cair no contorno de antes, onde os traços foram encaixados. O pelo vem dos
  mockups (`mockups/materiais.py`).

  ```bash
  nice -n 15 /Applications/Blender.app/Contents/MacOS/Blender -b --python art/pelucia.py [-- --only lavanda,coral]   # -> Sources/Orb/Resources/Orbs/body (~18 min)
  ```

  Com `--shapes`, gera os **formatos** (seixo, almofada, cápsula, triângulo, hexágono, nuvem, gota) em tons de cinza,
  um por formato, em `Resources/Orbs/shape/` (~7 min). Cada formato é um contorno 2D "estufado" como almofada, com o
  pé na mesma linha do círculo; o app pinta com a paleta pela luminância (`OrbRecolor.stops`). O círculo continua
  sendo `body/<cor>.png`. A posição do rosto em cada formato fica no `"face"` da chave `shape` do `options.json`.
  Rascunho rápido (~1 min para os 7): `-- --shapes --side 320 --fur-count 150000 --samples 16 --out <pasta>`.

  ```bash
  nice -n 15 /Applications/Blender.app/Contents/MacOS/Blender -b --python art/pelucia.py -- --shapes [--only nuvem,gota]
  ```


- **`orbgen/`** (Swift, CPU, reproduzível): o **assentamento** dos traços planos (sombra de
  contato) e uma folha de prévia dos corpos. Não precisa de Blender.
- **Blender (Cycles)** por script (`orbs.py`): os **traços planos** (olhos, bocas, sobrancelhas, bochechas,
  visemas), gravados em `orbgen/flat/`.

O gel brilhante de antes foi calibrado com `reference/orb-ref.png`; o acetinado (2026-10) troca o reflexo, o ponto de luz e a luz da base por luz difusa e um lustro baixo (`Body.swift`).

```bash
G="swift run -c release --package-path art/orbgen orbgen"
$G all                                  # assenta os traços planos -> Sources/Orb/Resources/Orbs
$G preview /tmp/corpos.png              # folha com todos os corpos, olhos e sorriso
```

Detalhes, luz e como adicionar opções: `docs/ORBS.md`, seção 8.

## Blender (traços planos e prévias)

```bash
B=/caminho/para/Blender.app/Contents/MacOS/Blender

# Um orb sob medida
$B -b --python art/orbs.py -- render --name meu-orb \
  --config '{"color": "rosa", "eyes": "ovais", "mouth": "sorriso", "cheeks": "blush"}'

# Catálogo com legendas (uma categoria ou todas) e personagens de exemplo
$B -b --python art/orbs.py -- catalog [--category eyes]
$B -b --python art/orbs.py -- personas

# Traços planos para o orbgen assentar (o corpo é o da pelúcia e fica de fora)
$B -b --python art/orbs.py -- layers [--category eyes] --size 640   # -> art/orbgen/flat (+ options.json do app, mantendo a chave shape)
# Os traços claros são peças 3D sombreadas (plástico branco com verniz), não adesivos que brilham sozinhos

# Manifesto com ids e rótulos para o editor do app
$B -b --python art/orbs.py -- manifest      # -> options.json do app
```

Cada render gera um PNG transparente (para o app) e as prévias `-dark` e `-light`.

## Opções

| Categoria | Qtde | Opções |
|---|---|---|
| Cor (`color`) | 18 | Índigo, Céu, Oceano, Menta, Lima, Sol, Pêssego, Coral, Cereja, Rosa, Lavanda, Ametista, Aurora, Algodão-doce, Chocolate, Noite, Grafite, Pérola |
| Olhos (`eyes`) | 12 | Pílulas, Pontos, Ovais, Grandões, Fendas, Felizes, Sono, Piscadela, Estrelas, Corações, Tontos, Bravos |
| Boca (`mouth`) | 10 | Nenhuma, Sorriso, Sorrisão, Surpresa, Neutra, Gatinho :3, Língua, Dentinho, Triste, Assobio |
| Sobrancelhas (`brows`) | 5 | Nenhuma, Retas, Arqueadas, Bravas, Preocupadas |
| Bochechas (`cheeks`) | 4 | Nenhuma, Rosadas, Sardas, Coraçõezinhos |

Cor extra opcional: `feature_color` (olhos e boca).
O bigode, os acessórios de cabeça (chapéus, laço, auréola, chifrinhos, orelhas de gato, flor), o cabelo e os óculos e fones saíram em 2026-11.
As cores claras (Pérola e Algodão-doce) trocam os olhos e a boca para escuros automaticamente.

## Visemas (boca falando)

Quatro formas de boca para o Orb "falar" enquanto a resposta chega: `fala-a` (aberta média),
`fala-o` (o redondo), `fala-e` (fenda larga sorrindo) e `fala-m` (lábios fechados, linha suave).
Não são opções do usuário: ficam em `VISEMES` (`orbkit/features.py`), fora de `MOUTHS`.
Mesmo material, traço e posição das bocas (`ctx.mouth_z`), todas centradas em x = 0 e com os cantos de
cima na mesma linha, para a troca rápida não "pular".

```bash
$B -b --python art/orbs.py -- catalog --category visemes             # folha de prévia
$B -b --python art/orbs.py -- layers --category visemes --size 640   # -> Resources/Orbs/visemes/<id>.png e <id>-dark.png
$B -b --python art/orbs.py -- render --config '{"color": "rosa", "viseme": "fala-a"}' --name teste
```

`layers` também regrava `options.json`, que lista os ids em `"visemes"`. Prévia: [`docs/visemes.png`](../docs/visemes.png).

## Estrutura
- `orbkit/core.py`: cena, luz, material de gel, materiais (plástico) e geometria (projeção na superfície, cápsulas, tubos, formas 2D).
- `orbkit/features.py`: o catálogo. Cada opção é um `(id, rótulo, construtor)`; para adicionar uma, basta incluí-la na lista.
- `orbs.py`: linha de comando (render, catalog, personas, layers, manifest).
- `orbgen/`: pacote Swift do orbgen (`Body.swift` corpo e luz, `Decals.swift` sombra de contato dos traços,
  `Preview.swift` folhas rápidas) e `flat/` (traços planos do Blender).
