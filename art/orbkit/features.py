"""Orb customization catalog: palettes, eyes, mouths, brows, and cheeks.

Every option is (id, Portuguese label, builder). Builders receive a Ctx and add objects to the scene.
The same ids are exported to the app (options.json, in the app) so the editor and the renders stay in sync.
"""

import math

from .core import capsule, flat_shape, glow, heart_points, on_surface, plastic, star_points, tube

# ---------------------------------------------------------------------------
# Palettes: (rim, core, deep, glow), sRGB hex. "light" palettes get dark features.

PALETTES = [
    ("indigo", "Índigo", (0xE4DEFF, 0x4A34F2, 0x3D2BE4, 0x86DFFF)),
    ("ceu", "Céu", (0xD6F1FF, 0x2E9BFF, 0x1D63D6, 0xB5FFF6)),
    ("oceano", "Oceano", (0xC9FFF6, 0x0FB5B0, 0x07706F, 0x9EF0FF)),
    ("menta", "Menta", (0xB8FFE6, 0x14C08C, 0x0A7A59, 0xD8FF6B)),
    ("lima", "Lima", (0xF3FFC2, 0x9BE02E, 0x5FA30E, 0xFFF59E)),
    ("sol", "Sol", (0xFFF0B8, 0xFFB21F, 0xC97A00, 0xFFF6C2)),
    ("pessego", "Pêssego", (0xFFE6D6, 0xFF9A6B, 0xE0603A, 0xFFE3A3)),
    ("coral", "Coral", (0xFFB3A0, 0xF2533F, 0xB8281B, 0xFFD36B)),
    ("cereja", "Cereja", (0xFFC2C9, 0xE11D3F, 0x9C0A24, 0xFF9E7A)),
    ("rosa", "Rosa", (0xFFC4E6, 0xE8409A, 0xA81D66, 0xFF9DF2)),
    ("lavanda", "Lavanda", (0xF1E6FF, 0xA77BFF, 0x7A4FE0, 0xFFC7F5)),
    ("ametista", "Ametista", (0xE9C9FF, 0x8A2BE2, 0x5A1196, 0xFF8AD8)),
    ("aurora", "Aurora", (0xE0FFF5, 0x37D4C0, 0x7A3CF0, 0xFF7AD9)),
    ("algodao", "Algodão-doce", (0xFFFFFF, 0xFFB3E1, 0x9FD3FF, 0xFFF0B3)),
    ("chocolate", "Chocolate", (0xF2D3B8, 0x8B5A3C, 0x4E2E1C, 0xFFB86B)),
    ("noite", "Noite", (0x9FA8FF, 0x1B1F5E, 0x0D0F33, 0x6F7BFF)),
    ("grafite", "Grafite", (0xB9BED0, 0x3A3F52, 0x1C1F2A, 0x7CE3FF)),
    ("perola", "Pérola", (0xFFFFFF, 0xECE8F6, 0xC4BDD9, 0xFFFFFF)),
]
LIGHT_PALETTES = {"perola", "algodao"}
PALETTE = {pid: colors for pid, _, colors in PALETTES}

# Face layout (face-space x, z on the orb front)
EYE_X, EYE_Z = 0.27, 0.17
BROW_Z = EYE_Z + 0.2


class Ctx:
    def __init__(self, config, orb):
        self.config = config
        self.orb = orb
        self.palette_id = config.get("color", "indigo")
        self.palette = PALETTE[self.palette_id]
        light = self.palette_id in LIGHT_PALETTES
        feature_hex = config.get("feature_color", 0x2A2540 if light else 0xFFFFFF)
        # Features are solid little pieces sewn onto the plush: lit and shaded, with a coat highlight, not self-lit
        # stickers. A touch of emission keeps the white white in the shade.
        if light:
            self.feature = plastic(feature_hex, roughness=0.25, coat=0.8, subsurface=0)
        else:
            self.feature = plastic(feature_hex, roughness=0.3, coat=0.8, emission=0.55, subsurface=0.2)
        self.ink = plastic(0x2B0F2E, roughness=0.35, coat=0.6, subsurface=0)
        self.tongue = plastic(0xFF7A9C, roughness=0.4, coat=0.4)
        self.mouth_z = -0.1

    def deep(self, emission=0.4):
        return plastic(self.palette[2], roughness=0.3, coat=0.8, emission=emission)


def arc(x, z, width, height):
    """Three-point arc (height > 0 bulges up)."""
    return [(x - width / 2, z), (x, z + height), (x + width / 2, z)]


# ---------------------------------------------------------------------------
# Eyes


def _pill(ctx, x, radius, half, roll=0.0, material=None):
    eye = capsule(radius, half, 0.042, material or ctx.feature)
    on_surface(eye, ctx.orb, x, EYE_Z, sink=-0.02, roll=roll)
    return eye


def eyes_pilulas(ctx):
    for side in (-1, 1):
        _pill(ctx, EYE_X * side, 0.068, 0.085)


def eyes_pontos(ctx):
    for side in (-1, 1):
        _pill(ctx, EYE_X * side, 0.075, 0.0)


def eyes_ovais(ctx):
    for side in (-1, 1):
        _pill(ctx, EYE_X * side, 0.088, 0.045)


def eyes_grandes(ctx):
    iris = glow(0x2C2A6E, 0.9)
    for side in (-1, 1):
        x = EYE_X * side
        _pill(ctx, x, 0.115, 0.03)
        pupil = capsule(0.072, 0.018, 0.014, iris)
        on_surface(pupil, ctx.orb, x + 0.01, EYE_Z - 0.015, sink=-0.026)
        dot = capsule(0.026, 0.0, 0.01, glow(0xFFFFFF, 2.0))
        on_surface(dot, ctx.orb, x - 0.025, EYE_Z + 0.03, sink=-0.036)


def eyes_fendas(ctx):
    for side in (-1, 1):
        _pill(ctx, EYE_X * side, 0.036, 0.07, roll=math.pi / 2)


def eyes_felizes(ctx):
    for side in (-1, 1):
        tube(arc(EYE_X * side, EYE_Z - 0.02, 0.17, 0.08), [1, 1, 1], ctx.feature, bevel=0.028, orb=ctx.orb, lift=0.01)


def eyes_sono(ctx):
    for side in (-1, 1):
        tube(arc(EYE_X * side, EYE_Z + 0.01, 0.17, -0.05), [1, 1, 1], ctx.feature, bevel=0.024, orb=ctx.orb, lift=0.01)


def eyes_piscadela(ctx):
    _pill(ctx, -EYE_X, 0.068, 0.085)
    tube(arc(EYE_X, EYE_Z - 0.02, 0.17, 0.08), [1, 1, 1], ctx.feature, bevel=0.028, orb=ctx.orb, lift=0.01)


def eyes_estrelas(ctx):
    for side in (-1, 1):
        star = flat_shape(star_points(0.11, 0.05), ctx.feature)
        on_surface(star, ctx.orb, EYE_X * side, EYE_Z, sink=-0.012)


def eyes_coracoes(ctx):
    for side in (-1, 1):
        heart = flat_shape(heart_points(0.1), ctx.feature)
        on_surface(heart, ctx.orb, EYE_X * side, EYE_Z, sink=-0.012)


def eyes_tontos(ctx):
    for side in (-1, 1):
        x = EYE_X * side
        for a, b in (((-0.06, -0.06), (0.06, 0.06)), ((-0.06, 0.06), (0.06, -0.06))):
            tube([(x + a[0], EYE_Z + a[1]), (x, EYE_Z), (x + b[0], EYE_Z + b[1])], [1, 1, 1], ctx.feature,
                 bevel=0.022, orb=ctx.orb, lift=0.01)


def eyes_bravos(ctx):
    for side in (-1, 1):
        _pill(ctx, EYE_X * side, 0.064, 0.05, roll=0.5 * side)


EYES = [
    ("pilulas", "Pílulas", eyes_pilulas),
    ("pontos", "Pontos", eyes_pontos),
    ("ovais", "Ovais", eyes_ovais),
    ("grandes", "Grandões", eyes_grandes),
    ("fendas", "Fendas", eyes_fendas),
    ("felizes", "Felizes ^^", eyes_felizes),
    ("sono", "Sono", eyes_sono),
    ("piscadela", "Piscadela", eyes_piscadela),
    ("estrelas", "Estrelas", eyes_estrelas),
    ("coracoes", "Corações", eyes_coracoes),
    ("tontos", "Tontos", eyes_tontos),
    ("bravos", "Bravos", eyes_bravos),
]

# ---------------------------------------------------------------------------
# Mouths


def _open_mouth(ctx, width, depth, tongue=True):
    pts = [(-width / 2 + width * i / 20, 0.0) for i in range(21)]
    pts += [(width / 2 * math.cos(math.pi * i / 20), -depth * math.sin(math.pi * i / 20)) for i in range(1, 20)]
    mouth = flat_shape(pts, ctx.ink, extrude=0.008)
    on_surface(mouth, ctx.orb, 0, ctx.mouth_z + 0.02, sink=-0.012)
    if tongue:
        t = flat_shape([(0.05 * math.cos(2 * math.pi * i / 32), 0.03 * math.sin(2 * math.pi * i / 32)) for i in range(32)],
                       ctx.tongue, extrude=0.006)
        on_surface(t, ctx.orb, 0, ctx.mouth_z + 0.02 - depth * 0.62, sink=-0.022)


def mouth_sorriso(ctx):
    tube(arc(0, ctx.mouth_z + 0.03, 0.24, -0.075), [1, 1, 1], ctx.feature, bevel=0.024, orb=ctx.orb, lift=0.008)


def mouth_sorrisao(ctx):
    _open_mouth(ctx, 0.3, 0.15)


def mouth_surpresa(ctx):
    o = flat_shape([(0.06 * math.cos(2 * math.pi * i / 40), 0.08 * math.sin(2 * math.pi * i / 40)) for i in range(40)],
                   ctx.ink, extrude=0.008)
    on_surface(o, ctx.orb, 0, ctx.mouth_z - 0.01, sink=-0.012)


def mouth_neutra(ctx):
    tube([(-0.1, ctx.mouth_z), (0, ctx.mouth_z), (0.1, ctx.mouth_z)], [1, 1, 1], ctx.feature, bevel=0.023,
         orb=ctx.orb, lift=0.008)


def mouth_gatinho(ctx):
    z = ctx.mouth_z + 0.01
    tube([(-0.13, z + 0.015), (-0.065, z - 0.05), (0, z), (0.065, z - 0.05), (0.13, z + 0.015)], [1, 1, 1, 1, 1],
         ctx.feature, bevel=0.022, orb=ctx.orb, lift=0.008)


def mouth_lingua(ctx):
    mouth_sorriso(ctx)
    t = flat_shape([(0.06 * math.cos(math.pi * i / 16), -0.085 * math.sin(math.pi * i / 16)) for i in range(17)],
                   ctx.tongue, extrude=0.008)
    on_surface(t, ctx.orb, 0.035, ctx.mouth_z - 0.035, sink=-0.016)


def mouth_dentinho(ctx):
    mouth_sorriso(ctx)
    tooth = flat_shape([(-0.032, 0.0), (0.032, 0.0), (0.032, -0.05), (0.0, -0.06), (-0.032, -0.05)],
                       plastic(0xFFFFFF, roughness=0.2, coat=1.0, subsurface=0), extrude=0.008)
    on_surface(tooth, ctx.orb, 0, ctx.mouth_z - 0.03, sink=-0.014)


def mouth_triste(ctx):
    tube(arc(0, ctx.mouth_z - 0.04, 0.22, 0.065), [1, 1, 1], ctx.feature, bevel=0.023, orb=ctx.orb, lift=0.008)


def mouth_assobio(ctx):
    o = flat_shape([(0.035 * math.cos(2 * math.pi * i / 32), 0.042 * math.sin(2 * math.pi * i / 32)) for i in range(32)],
                   ctx.ink, extrude=0.008)
    on_surface(o, ctx.orb, 0.07, ctx.mouth_z, sink=-0.012)


MOUTHS = [
    ("nenhuma", "Nenhuma", None),
    ("sorriso", "Sorriso", mouth_sorriso),
    ("sorrisao", "Sorrisão", mouth_sorrisao),
    ("surpresa", "Surpresa", mouth_surpresa),
    ("neutra", "Neutra", mouth_neutra),
    ("gatinho", "Gatinho :3", mouth_gatinho),
    ("lingua", "Língua", mouth_lingua),
    ("dentinho", "Dentinho", mouth_dentinho),
    ("triste", "Triste", mouth_triste),
    ("assobio", "Assobio", mouth_assobio),
]

# ---------------------------------------------------------------------------
# Visemes: mouth shapes for talking (the app swaps them while a reply streams). Not user options.
# All share the mouth's center line (x = 0) and the same top corners, so the lower lip "drops"
# between shapes instead of the whole mouth jumping around.

VISEME_TOP = 0.02   # corners of the open shapes sit at ctx.mouth_z + VISEME_TOP, like `sorrisao`


def _smiling_opening(ctx, half_width, rise, smile, depth, steps=48):
    """Dark opening with soft corners: the top edge dips by `smile` in the middle, the bottom hangs `depth`."""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        z = rise * s - smile * s * s if s > 0 else depth * s
        pts.append((half_width * c, z))
    mouth = flat_shape(pts, ctx.ink, extrude=0.008)
    on_surface(mouth, ctx.orb, 0, ctx.mouth_z + VISEME_TOP, sink=-0.012)
    return mouth


def viseme_a(ctx):
    _smiling_opening(ctx, 0.12, 0.016, 0.036, 0.14)
    tongue = flat_shape([(0.052 * math.cos(2 * math.pi * i / 32), 0.03 * math.sin(2 * math.pi * i / 32)) for i in range(32)],
                        ctx.tongue, extrude=0.006)
    on_surface(tongue, ctx.orb, 0, ctx.mouth_z + VISEME_TOP - 0.104, sink=-0.022)


def viseme_o(ctx):
    o = flat_shape([(0.058 * math.cos(2 * math.pi * i / 40), 0.066 * math.sin(2 * math.pi * i / 40)) for i in range(40)],
                   ctx.ink, extrude=0.008)
    on_surface(o, ctx.orb, 0, ctx.mouth_z + VISEME_TOP - 0.068, sink=-0.012)


def viseme_e(ctx):
    _smiling_opening(ctx, 0.13, 0.012, 0.032, 0.092)


def viseme_m(ctx):
    tube(arc(0, ctx.mouth_z + VISEME_TOP - 0.005, 0.21, -0.032), [1, 1, 1], ctx.feature, bevel=0.0235, orb=ctx.orb, lift=0.008)


VISEMES = [
    ("fala-a", "Fala A", viseme_a),
    ("fala-o", "Fala O", viseme_o),
    ("fala-e", "Fala E", viseme_e),
    ("fala-m", "Fala M", viseme_m),
]

# ---------------------------------------------------------------------------
# Brows


def _brows(ctx, inner_dz, outer_dz, bulge=0.0):
    for side in (-1, 1):
        x = EYE_X * side
        inner = (x - 0.075 * side, BROW_Z + inner_dz)
        outer = (x + 0.075 * side, BROW_Z + outer_dz)
        mid = (x, BROW_Z + (inner_dz + outer_dz) / 2 + bulge)
        tube([inner, mid, outer], [0.8, 1, 0.8], ctx.feature, bevel=0.018, orb=ctx.orb, lift=0.01)


BROWS = [
    ("nenhuma", "Nenhuma", None),
    ("retas", "Retas", lambda ctx: _brows(ctx, 0, 0)),
    ("arqueadas", "Arqueadas", lambda ctx: _brows(ctx, -0.01, -0.01, 0.035)),
    ("bravas", "Bravas", lambda ctx: _brows(ctx, -0.045, 0.03)),
    ("preocupadas", "Preocupadas", lambda ctx: _brows(ctx, 0.04, -0.025)),
]

# ---------------------------------------------------------------------------
# Cheeks


def cheeks_blush(ctx):
    pink = glow(0xFF8CC0, 1.1)
    for side in (-1, 1):
        disc = flat_shape([(0.07 * math.cos(2 * math.pi * i / 40), 0.035 * math.sin(2 * math.pi * i / 40)) for i in range(40)],
                          pink, extrude=0.004, bevel=0.012)
        on_surface(disc, ctx.orb, 0.47 * side, EYE_Z - 0.16, sink=-0.006)


def cheeks_sardas(ctx):
    dots = plastic(0x8A4B3A, roughness=0.4, coat=0.5, emission=0.25)
    for side in (-1, 1):
        for dx, dz in ((-0.04, 0.0), (0.03, 0.02), (0.0, -0.035), (0.05, -0.03)):
            dot = capsule(0.013, 0.0, 0.008, dots)
            on_surface(dot, ctx.orb, 0.45 * side + dx, EYE_Z - 0.14 + dz, sink=-0.006)


def cheeks_coracoes(ctx):
    pink = glow(0xFF8CC0, 1.2)
    for side in (-1, 1):
        heart = flat_shape(heart_points(0.04), pink, extrude=0.006)
        on_surface(heart, ctx.orb, 0.46 * side, EYE_Z - 0.15, sink=-0.008)


CHEEKS = [
    ("nenhuma", "Nenhuma", None),
    ("blush", "Rosadas", cheeks_blush),
    ("sardas", "Sardas", cheeks_sardas),
    ("coracoes", "Coraçõezinhos", cheeks_coracoes),
]

CATEGORIES = {
    "color": PALETTES,
    "eyes": EYES,
    "mouth": MOUTHS,
    "brows": BROWS,
    "cheeks": CHEEKS,
}


def build_features(ctx, only=None):
    """All features from ctx.config, or just `only=(category, option)`. A config "viseme" replaces the mouth."""
    config = ctx.config
    lookup = {name: {oid: builder for oid, _, builder in options} for name, options in CATEGORIES.items() if name != "color"}
    lookup["visemes"] = {oid: builder for oid, _, builder in VISEMES}
    if only is not None:
        category, option = only
        builder = lookup[category].get(option)
        if builder:
            builder(ctx)
        return
    if "viseme" in config:
        config = dict(config, mouth=None)
        lookup["visemes"][config["viseme"]](ctx)
    lookup["eyes"][config.get("eyes", "pilulas")](ctx)
    for category, default in (("mouth", "nenhuma"), ("brows", "nenhuma"), ("cheeks", "nenhuma")):
        builder = lookup[category].get(config.get(category, default))
        if builder:
            builder(ctx)
