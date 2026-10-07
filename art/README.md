# Orbs: personagens 3D do OpenBot

Esferas de gel translúcido, modeladas e renderizadas no **Blender (Cycles)** por script.
O visual foi calibrado lado a lado com `reference/orb-ref.png`.

```bash
B=/caminho/para/Blender.app/Contents/MacOS/Blender

# Um orb sob medida
$B -b --python art/orbs.py -- render --name meu-bot \
  --config '{"color": "rosa", "eyes": "ovais", "mouth": "sorriso", "hair": "tufinho", "accessories": ["fones"]}'

# Catálogo com legendas (uma categoria ou todas) e personagens de exemplo
$B -b --python art/orbs.py -- catalog [--category eyes]
$B -b --python art/orbs.py -- personas

# Manifesto com ids e rótulos para o editor do app
$B -b --python art/orbs.py -- manifest      # -> art/orb_options.json
```

Cada render gera um PNG transparente (para o app) e as prévias `-dark` e `-light`.

## Opções

| Categoria | Qtde | Opções |
|---|---|---|
| Cor (`color`) | 18 | Índigo, Céu, Oceano, Menta, Lima, Sol, Pêssego, Coral, Cereja, Rosa, Lavanda, Ametista, Aurora, Algodão-doce, Chocolate, Noite, Grafite, Pérola |
| Olhos (`eyes`) | 12 | Pílulas, Pontos, Ovais, Grandões, Fendas, Felizes, Sono, Piscadela, Estrelas, Corações, Tontos, Bravos |
| Boca (`mouth`) | 10 | Nenhuma, Sorriso, Sorrisão, Surpresa, Neutra, Gatinho :3, Língua, Dentinho, Triste, Assobio |
| Sobrancelhas (`brows`) | 5 | Nenhuma, Retas, Arqueadas, Bravas, Preocupadas |
| Bochechas (`cheeks`) | 4 | Nenhuma, Blush, Sardas, Coraçõezinhos |
| Bigode (`mustache`) | 6 | Nenhum, Clássico, Enrolado, Fino, Escovinha, Cavanhaque |
| Cabelo (`hair`) | 8 | Nenhum, Topete, Tufinho, Franja, Cachinhos, Coque, Moicano, Antena |
| Acessórios (`accessories`, vários) | 15 | Óculos redondos / quadrados / de sol, Monóculo, Chapéu de festa, Boné, Gorro, Cartola, Coroa, Laço, Fones, Auréola, Chifrinhos, Orelhas de gato, Flor |

Cores extras opcionais: `feature_color` (olhos e boca), `mustache_color`, `hair_color` e `accent_color` (boné, gorro, laço, fones, chifres, flor).
As cores claras (Pérola e Algodão-doce) trocam os olhos e a boca para escuros automaticamente.

## Estrutura
- `orbkit/core.py`: cena, luz, material de gel, materiais (plástico, metal, tricô, vidro, listrado) e geometria (projeção na superfície, cápsulas, tubos, formas 2D).
- `orbkit/features.py`: o catálogo. Cada opção é um `(id, rótulo, construtor)`; para adicionar uma, basta incluí-la na lista.
- `orbs.py`: linha de comando (render, catalog, personas, manifest).
