# Orbs: personagens 3D do app Orb

Esferas acetinadas (vinil de toque macio) com luz de objeto 3D: difusa, sombra de forma, aro fosco fino e um lustro largo, sem reflexo nem brilho saindo pela base; o brilho dos fios do cabelo é um terço do antigo (`HairRenderer.satin`). A arte das camadas vem de duas ferramentas:

- **`orbgen/`** (Swift, CPU, reproduzível): o **corpo** iluminado de cada cor, os **cabelos** (campos de
  distância, com camada `-brilho` sem tinta e versão `-chapeu`), o **assentamento** dos traços planos (sombra de
  contato) e as entradas de `options.json` que são dele. Não precisa de Blender.
- **Blender (Cycles)** por script (`orbs.py`): os **traços planos** (olhos, bocas, sobrancelhas, bochechas,
  bigodes, visemas, acessórios), gravados em `orbgen/flat/`.

O gel brilhante de antes foi calibrado com `reference/orb-ref.png`; o acetinado (2026-10) troca o reflexo, o ponto de luz e a luz da base por luz difusa e um lustro baixo (`Body.swift`).

```bash
G="swift run -c release --package-path art/orbgen orbgen"
$G all                                  # tudo que é do orbgen -> Sources/Orb/Resources/Orbs (~2 min)
$G hair franja && $G zoom /tmp/z.png rosa franja   # um cabelo e um close para conferir
```

Detalhes, luz e como adicionar opções: `docs/ORBS.md`, seção 8.

## Blender (traços planos e prévias)

```bash
B=/caminho/para/Blender.app/Contents/MacOS/Blender

# Um orb sob medida
$B -b --python art/orbs.py -- render --name meu-orb \
  --config '{"color": "rosa", "eyes": "ovais", "mouth": "sorriso", "hair": "tufinho", "accessories": ["fones"]}'

# Catálogo com legendas (uma categoria ou todas) e personagens de exemplo
$B -b --python art/orbs.py -- catalog [--category eyes]
$B -b --python art/orbs.py -- personas

# Traços planos para o orbgen assentar (corpo e cabelo são do orbgen e ficam de fora)
$B -b --python art/orbs.py -- layers [--category eyes]   # -> art/orbgen/flat (+ options.json do app)

# Manifesto com ids e rótulos para o editor do app (mantém cabelo, chapéus e cores de cabelo do orbgen)
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
| Bigode (`mustache`) | 6 | Nenhum, Clássico, Enrolado, Fino, Escovinha, Cavanhaque |
| Cabelo (`hair`, orbgen) | 13 | Nenhum, Franja, Ondulado, Cachinhos, Black power, Coque, Rabo de cavalo, Maria-chiquinha, Topete, Espetado, Moicano, Tufinho, Antena |
| Acessórios (`accessories`, vários) | 15 | Óculos redondos / quadrados / de sol, Monóculo, Chapéu de festa, Boné, Gorro, Cartola, Coroa, Laço, Fones, Auréola, Chifrinhos, Orelhas de gato, Flor |

Cores extras opcionais: `feature_color` (olhos e boca), `mustache_color`, `hair_color` e `accent_color` (boné, gorro, laço, fones, chifres, flor).
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
- `orbkit/core.py`: cena, luz, material de gel, materiais (plástico, metal, tricô, vidro, listrado) e geometria (projeção na superfície, cápsulas, tubos, formas 2D).
- `orbkit/features.py`: o catálogo. Cada opção é um `(id, rótulo, construtor)`; para adicionar uma, basta incluí-la na lista.
- `orbs.py`: linha de comando (render, catalog, personas, layers, manifest).
- `orbgen/`: pacote Swift do orbgen (`Body.swift` corpo e luz, `Hair.swift` estilos, `HairRenderer.swift` marcha de
  raios e sombreamento, `SDF.swift` primitivas, `Decals.swift` sombra de contato dos traços, `Manifest.swift`
  options.json, `Preview.swift` folhas rápidas) e `flat/` (traços planos do Blender).
- O cabelo de `orbkit/features.py` só aparece nas prévias do Blender; o do app é o do orbgen.
