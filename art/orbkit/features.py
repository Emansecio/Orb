"""Orb customization catalog: palettes, eyes, mouths, brows, cheeks, mustaches, hair and accessories.

Every option is (id, Portuguese label, builder). Builders receive a Ctx and add objects to the scene.
The same ids are exported to the app (options.json, in the app) so the editor and the renders stay in sync.
"""

import math

from mathutils import Vector

from . import core
import bpy

from .core import (capsule, cone, cylinder, dome, flat_shape, frame_on, glow, heart_points, knit, metal, on_surface,
                   plastic, sphere, star_points, surface, torus, tube)

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
        feature_hex = config.get("feature_color", 0x2A2540 if light else 0xF0EEFF)
        if light:
            self.feature = plastic(feature_hex, roughness=0.25, coat=0.8, subsurface=0)
        else:
            self.feature = glow(feature_hex, 1.0)
        self.ink = plastic(0x2B0F2E, roughness=0.35, coat=0.6, subsurface=0)
        self.tongue = plastic(0xFF7A9C, roughness=0.4, coat=0.4)
        self.mouth_z = -0.16 if config.get("mustache", "nenhum") != "nenhum" else -0.1

    def deep(self, emission=0.4):
        return plastic(self.palette[2], roughness=0.3, coat=0.8, emission=emission)


def arc(x, z, width, height):
    """Three-point arc (height > 0 bulges up)."""
    return [(x - width / 2, z), (x, z + height), (x + width / 2, z)]


# ---------------------------------------------------------------------------
# Eyes


def _pill(ctx, x, radius, half, roll=0.0, material=None):
    eye = capsule(radius, half, 0.018, material or ctx.feature)
    on_surface(eye, ctx.orb, x, EYE_Z, sink=-0.012, roll=roll)
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

# ---------------------------------------------------------------------------
# Mustaches


def _mustache_material(ctx):
    color = ctx.config.get("mustache_color", 0xF4F2FF)
    bright = sum((color >> s) & 0xFF for s in (16, 8, 0)) > 380
    return plastic(color, roughness=0.65, coat=0.15, emission=0.55 if bright else 0.0)


MUSTACHE_Z = -0.06


def mustache_classico(ctx):
    material = _mustache_material(ctx)
    for side in (-1, 1):
        pts = [(0.0, MUSTACHE_Z + 0.015), (0.09 * side, MUSTACHE_Z), (0.18 * side, MUSTACHE_Z - 0.03), (0.26 * side, MUSTACHE_Z - 0.035)]
        tube(pts, [1.0, 1.0, 0.8, 0.45], material, bevel=0.06, orb=ctx.orb, lift=0.045)


def mustache_enrolado(ctx):
    material = _mustache_material(ctx)
    for side in (-1, 1):
        pts = [(0.0, MUSTACHE_Z + 0.0), (0.11 * side, MUSTACHE_Z - 0.025), (0.22 * side, MUSTACHE_Z - 0.035),
               (0.29 * side, MUSTACHE_Z + 0.015), (0.27 * side, MUSTACHE_Z + 0.045), (0.23 * side, MUSTACHE_Z + 0.03)]
        tube(pts, [1.0, 0.95, 0.8, 0.6, 0.45, 0.35], material, bevel=0.045, orb=ctx.orb, lift=0.035)


def mustache_fino(ctx):
    material = _mustache_material(ctx)
    for side in (-1, 1):
        pts = [(0.025 * side, MUSTACHE_Z + 0.01), (0.12 * side, MUSTACHE_Z + 0.0), (0.21 * side, MUSTACHE_Z + 0.02)]
        tube(pts, [1.0, 0.85, 0.45], material, bevel=0.034, orb=ctx.orb, lift=0.03)


def mustache_chevron(ctx):
    material = _mustache_material(ctx)
    pts = [(-0.17, MUSTACHE_Z - 0.01), (-0.08, MUSTACHE_Z + 0.01), (0.0, MUSTACHE_Z + 0.015), (0.08, MUSTACHE_Z + 0.01),
           (0.17, MUSTACHE_Z - 0.01)]
    tube(pts, [0.6, 1.0, 1.0, 1.0, 0.6], material, bevel=0.06, orb=ctx.orb, lift=0.05)


def mustache_cavanhaque(ctx):
    material = _mustache_material(ctx)
    z = ctx.mouth_z - 0.08
    tube([(0.0, z), (0.0, z - 0.06), (0.0, z - 0.12)], [1.0, 0.8, 0.35], material, bevel=0.05, orb=ctx.orb, lift=0.04)


MUSTACHES = [
    ("nenhum", "Nenhum", None),
    ("classico", "Clássico", mustache_classico),
    ("enrolado", "Enrolado", mustache_enrolado),
    ("fino", "Fino", mustache_fino),
    ("chevron", "Escovinha", mustache_chevron),
    ("cavanhaque", "Cavanhaque", mustache_cavanhaque),
]

# ---------------------------------------------------------------------------
# Hair (world coordinates; crown at z ≈ 0.97, face toward -Y)


def _hair_material(ctx):
    color = ctx.config.get("hair_color")
    if color is None:
        deep = ctx.palette[2]
        color = sum(int(((deep >> s) & 0xFF) * 0.55) << s for s in (16, 8, 0))
        return plastic(color, roughness=0.3, coat=0.9, emission=0.25)
    return plastic(color, roughness=0.3, coat=0.8, emission=0.15)


def hair_topete(ctx):
    m = _hair_material(ctx)
    tube([(-0.2, 0.0, 0.93), (-0.12, -0.05, 1.18), (0.08, -0.06, 1.3), (0.28, -0.04, 1.22), (0.3, -0.03, 1.08),
          (0.2, -0.02, 1.04)], [1.0, 1.0, 0.85, 0.65, 0.45, 0.3], m, bevel=0.085)
    tube([(0.05, 0.05, 0.94), (0.14, 0.0, 1.12), (0.3, 0.0, 1.16)], [0.9, 0.6, 0.25], m, bevel=0.06)


def hair_tufinho(ctx):
    m = _hair_material(ctx)
    for base_x, tip in ((-0.06, (0.1, -0.04, 1.26)), (0.02, (0.26, -0.03, 1.2)), (0.1, (0.36, -0.02, 1.08))):
        base, tip = Vector((base_x, 0.0, 0.96)), Vector(tip)
        mid = Vector((base.x * 0.4 + tip.x * 0.6 - 0.04, (base.y + tip.y) / 2, (base.z + tip.z) / 2 + 0.07))
        tube([base, mid, tip], [1.0, 0.7, 0.12], m, bevel=0.07)


def hair_franja(ctx):
    m = _hair_material(ctx)
    for i in range(6):
        x = -0.32 + i * 0.128
        length = 0.6 if i % 2 else 0.66
        tube([(x * 0.55, 0.93), (x * 0.9, 0.78), (x * 1.0, length)], [1.0, 0.9, 0.4], m, bevel=0.075, orb=ctx.orb, lift=0.05)


def hair_cachos(ctx):
    m = _hair_material(ctx)
    for i in range(7):
        angle = 2 * math.pi * i / 7
        location = (0.3 * math.cos(angle), 0.3 * math.sin(angle), 0.94)
        torus(0.085, 0.04, location, m, rotation=(math.pi / 2, 0, angle))
    sphere(0.12, (0, 0, 1.02), m)


def hair_coque(ctx):
    m = _hair_material(ctx)
    sphere(0.21, (0, 0.06, 1.14), m)
    torus(0.15, 0.035, (0, 0.06, 1.0), plastic(0xFF5A7A, roughness=0.35, coat=0.6))


def hair_moicano(ctx):
    m = _hair_material(ctx)
    for i, angle in enumerate((-0.42, -0.21, 0.0, 0.21, 0.42)):
        x, z = math.sin(angle) * 0.97, math.cos(angle) * 0.97
        tilt = Vector((x, -0.15, z)).normalized()
        location = Vector((x, -0.05, z)) + tilt * 0.14
        height = 0.4 - abs(angle) * 0.3
        c = cone(0.1, 0.0, height, location, m)
        c.rotation_euler = tilt.to_track_quat("Z", "Y").to_euler()


def hair_antena(ctx):
    m = _hair_material(ctx)
    tube([(0.0, 0.0, 0.95), (0.03, 0.0, 1.15), (0.14, 0.0, 1.3), (0.24, 0.0, 1.32)], [1.0, 0.8, 0.7, 0.6], m, bevel=0.025)
    sphere(0.06, (0.27, 0.0, 1.32), glow(0x9FF0FF, 3.0))


HAIR = [
    ("nenhum", "Nenhum", None),
    ("topete", "Topete", hair_topete),
    ("tufinho", "Tufinho", hair_tufinho),
    ("franja", "Franja", hair_franja),
    ("cachos", "Cachinhos", hair_cachos),
    ("coque", "Coque", hair_coque),
    ("moicano", "Moicano", hair_moicano),
    ("antena", "Antena", hair_antena),
]

# ---------------------------------------------------------------------------
# Accessories (any number at once)


def _eye_anchor(ctx, side, lift=0.06):
    location, normal = surface(ctx.orb, EYE_X * side, EYE_Z)
    return location + normal * lift, normal


def _glasses(ctx, frame, lens, shape="round"):
    anchors = []
    for side in (-1, 1):
        center, normal = _eye_anchor(ctx, side)
        anchors.append((center, normal))
        rotation = frame_on((normal * 0.6 + Vector((0, -1, 0)) * 0.4).normalized()).to_euler()
        if shape == "round":
            ring = torus(0.125, 0.016, center, frame)
            ring.rotation_euler = rotation
            disc = cylinder(0.118, 0.006, center, lens)
            disc.rotation_euler = rotation
        else:
            x = EYE_X * side
            pts = []
            for i in range(40):
                t = 2 * math.pi * i / 40
                c, s = math.cos(t), math.sin(t)
                px = 0.14 * math.copysign(abs(c) ** 0.45, c)
                pz = 0.105 * math.copysign(abs(s) ** 0.45, s)
                pts.append((x + px, EYE_Z + pz))
            pts.append(pts[0])
            tube(pts, [1] * len(pts), frame, bevel=0.016, orb=ctx.orb, lift=0.065, resolution=6)
    (left, _), (right, _) = anchors
    inner = 0.125 if shape == "round" else 0.14
    tube([left + Vector((inner, 0, 0.0)), (left + right) / 2 + Vector((0, -0.02, 0.03)), right - Vector((inner, 0, 0.0))],
         [1, 1, 1], frame, bevel=0.014)
    for (center, _), side in zip(anchors, (-1, 1)):
        start = center + Vector((inner * side, 0, 0.01))
        tube([start, Vector((0.92 * side, -0.1, EYE_Z + 0.02)), Vector((0.98 * side, 0.25, EYE_Z))], [1, 1, 1], frame, bevel=0.013)


def acc_oculos_redondos(ctx):
    _glasses(ctx, metal(0xD9A441, 0.25), core.glass(), "round")


def acc_oculos_quadrados(ctx):
    _glasses(ctx, plastic(0x18161F, roughness=0.25, coat=1.0, subsurface=0), core.glass(), "square")


def acc_oculos_sol(ctx):
    _glasses(ctx, plastic(0x18161F, roughness=0.25, coat=1.0, subsurface=0), core.glass(darkness=0.92), "round")


def acc_monoculo(ctx):
    gold = metal(0xD9A441, 0.2)
    center, normal = _eye_anchor(ctx, 1)
    ring = torus(0.13, 0.017, center, gold)
    ring.rotation_euler = frame_on(normal).to_euler()
    disc = cylinder(0.122, 0.006, center, core.glass())
    disc.rotation_euler = ring.rotation_euler
    tube([center + Vector((0.08, 0, -0.1)), center + Vector((0.2, -0.05, -0.35)), Vector((0.62, -0.62, -0.5))], [1, 1, 1],
         gold, bevel=0.008)


def acc_chapeu_festa(ctx):
    hat = cone(0.32, 0.0, 0.62, (0.12, 0.0, 1.18), core.striped(0xFFD24D, 0xFF5A7A, scale=8), rotation=(0, 0.28, 0))
    sphere(0.075, (0.2, 0.0, 1.48), plastic(0xFFFFFF, roughness=0.9, coat=0.0))
    torus(0.3, 0.03, (0.04, 0.0, 0.9), plastic(0xFF5A7A), rotation=(0, 0.28, 0))


def acc_bone(ctx):
    color = ctx.config.get("accent_color", 0xFF5A3D)
    material = plastic(color, roughness=0.45, coat=0.3)
    dome(1.035, 0.5, (0, 0, 0), material)
    brim = cylinder(0.5, 0.03, (0, -0.95, 0.5), material, rotation=(-0.22, 0, 0))
    brim.scale = (1.0, 0.7, 1.0)
    sphere(0.06, (0, 0, 1.04), material)


def acc_gorro(ctx):
    color = ctx.config.get("accent_color", 0xFF6B4A)
    material = knit(color)
    dome(1.05, 0.44, (0, 0, 0), material)
    torus(0.92, 0.1, (0, 0, 0.45), material)
    sphere(0.2, (0, 0, 1.13), knit(0xFFFFFF))


def acc_coroa(ctx):
    gold = metal(0xF2C14E, 0.18)
    cylinder(0.42, 0.2, (0, 0, 0.98), gold)
    for i in range(5):
        angle = 2 * math.pi * i / 5 + math.pi / 2
        cone(0.09, 0.0, 0.22, (0.42 * math.cos(angle) * 0.95, 0.42 * math.sin(angle) * 0.95, 1.18), gold)
    for i, hex_value in enumerate((0xFF3B5C, 0x3BB8FF, 0x5CFF8A)):
        angle = -math.pi / 2 + (i - 1) * 0.6
        sphere(0.045, (0.43 * math.cos(angle), 0.43 * math.sin(angle), 0.98), glow(hex_value, 1.5))


def acc_laco(ctx):
    color = ctx.config.get("accent_color", 0xFF4F8B)
    material = plastic(color, roughness=0.35, coat=0.7)
    center = Vector((0.52, -0.42, 0.78))
    for side in (-1, 1):
        lobe = cone(0.13, 0.02, 0.24, center + Vector((0.11 * side, 0, 0)), material, rotation=(0, -side * math.pi / 2, 0))
        lobe.scale = (1.0, 0.55, 1.0)
    sphere(0.06, center + Vector((0, -0.02, 0)), material)


def acc_fones(ctx):
    color = ctx.config.get("accent_color", 0x2B2B36)
    shell = plastic(color, roughness=0.3, coat=0.8, subsurface=0)
    tube([(-1.04, 0.0, 0.15), (-0.75, 0.0, 0.85), (0.0, 0.0, 1.16), (0.75, 0.0, 0.85), (1.04, 0.0, 0.15)],
         [1, 1, 1, 1, 1], shell, bevel=0.045)
    for side in (-1, 1):
        cylinder(0.24, 0.16, (1.02 * side, 0.0, 0.05), shell, rotation=(0, math.pi / 2, 0))
        torus(0.19, 0.06, (0.95 * side, 0.0, 0.05), plastic(0x55556A, roughness=0.8, coat=0), rotation=(0, math.pi / 2, 0))


def acc_aureola(ctx):
    torus(0.42, 0.04, (0, 0.05, 1.32), glow(0xFFE27A, 3.0))


def acc_chifres(ctx):
    material = plastic(ctx.config.get("accent_color", 0xE0303F), roughness=0.3, coat=0.8)
    for side in (-1, 1):
        cone(0.1, 0.0, 0.32, (0.4 * side, 0.0, 0.98), material, rotation=(0, 0.45 * side, 0))


def acc_orelhas_gato(ctx):
    accent = ctx.config.get("accent_color")
    material = plastic(accent, roughness=0.3, coat=0.8, emission=0.35) if accent is not None else ctx.deep(0.35)
    inner = plastic(0xFF9CC2, roughness=0.5, coat=0.3, emission=0.3)
    for side in (-1, 1):
        ear = cone(0.24, 0.02, 0.36, (0.5 * side, 0.0, 0.92), material, rotation=(0, 0.42 * side, 0))
        ear.scale = (1.0, 0.45, 1.0)
        pad = cone(0.15, 0.01, 0.24, (0.48 * side, -0.07, 0.9), inner, rotation=(0, 0.42 * side, 0))
        pad.scale = (1.0, 0.25, 1.0)


def acc_flor(ctx):
    petals = plastic(ctx.config.get("accent_color", 0xFFFFFF), roughness=0.4, coat=0.5, emission=0.2)
    center = Vector((-0.55, -0.5, 0.68))
    normal = center.normalized()
    for i in range(6):
        angle = 2 * math.pi * i / 6
        offset = Vector((math.cos(angle) * 0.1, 0, math.sin(angle) * 0.1))
        petal = sphere(0.075, center + offset, petals, scale=(1.0, 0.45, 1.0))
        petal.rotation_euler = normal.to_track_quat("Y", "Z").to_euler()
    sphere(0.05, center + normal * 0.03, plastic(0xFFC83D, roughness=0.4, coat=0.5, emission=0.4))


def acc_cartola(ctx):
    black = plastic(0x17151D, roughness=0.35, coat=0.5, subsurface=0)
    cylinder(0.36, 0.52, (0, 0.04, 1.2), black)
    cylinder(0.62, 0.03, (0, 0.04, 0.93), black)
    cylinder(0.365, 0.09, (0, 0.04, 1.0), plastic(0xD93A4A, roughness=0.4, coat=0.4))


ACCESSORIES = [
    ("oculos-redondos", "Óculos redondos", acc_oculos_redondos),
    ("oculos-quadrados", "Óculos quadrados", acc_oculos_quadrados),
    ("oculos-sol", "Óculos de sol", acc_oculos_sol),
    ("monoculo", "Monóculo", acc_monoculo),
    ("chapeu-festa", "Chapéu de festa", acc_chapeu_festa),
    ("bone", "Boné", acc_bone),
    ("gorro", "Gorro", acc_gorro),
    ("cartola", "Cartola", acc_cartola),
    ("coroa", "Coroa", acc_coroa),
    ("laco", "Laço", acc_laco),
    ("fones", "Fones", acc_fones),
    ("aureola", "Auréola", acc_aureola),
    ("chifres", "Chifrinhos", acc_chifres),
    ("orelhas-gato", "Orelhas de gato", acc_orelhas_gato),
    ("flor", "Flor", acc_flor),
]

CATEGORIES = {
    "color": PALETTES,
    "eyes": EYES,
    "mouth": MOUTHS,
    "brows": BROWS,
    "cheeks": CHEEKS,
    "mustache": MUSTACHES,
    "hair": HAIR,
    "accessories": ACCESSORIES,
}


FEATURE_SCALE = {
    "hair": 1.35,
    "laco": 1.6, "flor": 2.0, "chifres": 1.45, "orelhas-gato": 1.25, "chapeu-festa": 1.25, "coroa": 1.1,
}
PIVOTS = {"hair": (0, 0, 0.96), "laco": (0.52, -0.42, 0.78), "flor": (-0.55, -0.5, 0.68), "chifres": (0, 0, 0.95),
          "orelhas-gato": (0, 0, 0.9), "chapeu-festa": (0.05, 0, 0.92), "coroa": (0, 0, 0.92)}


def _scaled(builder, ctx, key):
    before = set(bpy.data.objects)
    builder(ctx)
    factor = FEATURE_SCALE.get(key)
    if not factor:
        return
    pivot = Vector(PIVOTS[key])
    for obj in set(bpy.data.objects) - before:
        obj.location = pivot + (obj.location - pivot) * factor
        obj.scale = obj.scale * factor


def build_features(ctx, only=None):
    """All features from ctx.config, or just `only=(category, option)`. A config "viseme" replaces the mouth."""
    config = ctx.config
    lookup = {name: {oid: builder for oid, _, builder in options} for name, options in CATEGORIES.items() if name != "color"}
    lookup["visemes"] = {oid: builder for oid, _, builder in VISEMES}
    if only is not None:
        category, option = only
        builder = lookup[category].get(option)
        if builder:
            _scaled(builder, ctx, option if category == "accessories" else category)
        return
    if "viseme" in config:
        config = dict(config, mouth=None)
        _scaled(lookup["visemes"][config["viseme"]], ctx, "visemes")
    lookup["eyes"][config.get("eyes", "pilulas")](ctx)
    for category, default in (("mouth", "nenhuma"), ("brows", "nenhuma"), ("cheeks", "nenhuma"),
                              ("mustache", "nenhum"), ("hair", "nenhum")):
        builder = lookup[category].get(config.get(category, default))
        if builder:
            _scaled(builder, ctx, category)
    for accessory in config.get("accessories", []):
        _scaled(lookup["accessories"][accessory], ctx, accessory)
