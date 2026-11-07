"""Corpo de pelúcia dos Orbs: uma imagem por cor em Sources/Orb/Resources/Orbs/body, no enquadramento do orbgen.

    nice -n 15 Blender -b --python art/pelucia.py -- [--only lavanda,coral] [--samples 64] [--out <pasta>]
    nice -n 15 Blender -b --python art/pelucia.py -- --shapes [--only nuvem,gota] [--side 320 --fur-count 200000]

Com --shapes gera os formatos (Resources/Orbs/shape/<id>.png) em cinza: o app pinta cada um com a paleta do Orb
(mapa de degradê pela luminância), então basta uma imagem por formato. O círculo continua sendo body/<cor>.png.

O pelo é o dos mockups (art/mockups/materiais.py): fios desenhados um a um, inclinados, com cacho leve e frizz
nas pontas. Cada fio pega a cor da paleta na altura dele (o mesmo degradê do corpo acetinado do orbgen), um pouco
mais saturada, porque o pelo espalha a luz e desbota. Olhos, boca e cabelo continuam sendo as camadas do app.
"""

import argparse
import colorsys
import json
import math
import os
import sys
import time

import bmesh
import bpy
import numpy as np

ART = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ART, "mockups"))
import materiais as mk  # noqa: E402
from orbkit import core  # noqa: E402

ROOT = os.path.dirname(ART)
RESOURCES = os.path.join(ROOT, "Sources", "Orb", "Resources", "Orbs")
SIDE, SCALE = 640, 168.5  # orbgen's Frame: 640 px, x radius 168.5 px
SUPERSAMPLE = 2
FUR = 0.12  # a bit shorter than the mockups
# The fur stands about 0.08 off the skin: a smaller skin puts the fuzzy outline where the satin body's edge was, the
# outline the hair and faces were fit to (and the app's footprint and stage room).
CORE = 0.92


def hex_rgb(value):
    value = int(value.lstrip("#"), 16)
    return np.array([(value >> s) & 0xFF for s in (16, 8, 0)], dtype=np.float64) / 255


def to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def plush_tone(srgb):
    """Fur reads paler than a surface of the same color: deepen saturated colors (greys and whites stay put)."""
    h, s, v = colorsys.rgb_to_hsv(*srgb)
    k = min(1.0, max(0.0, (s - 0.2) / 0.25))
    s = s + (1 - s) * 0.35 * k
    v = v * (1 - 0.06 * k)
    return np.array(colorsys.hsv_to_rgb(h, s, v))


def palette_ramp(hexes):
    """`BodyShader.ramp` of the orbgen (sRGB in, linear out) as a 256-step table over the height h 0..1."""
    rim, core_, deep, glow = (to_linear(hex_rgb(x)) for x in hexes)
    glow = glow * 0.2 + core_ * 0.8
    stops = [(0, glow), (0.12, glow * 0.6 + core_ * 0.4), (0.36, core_), (0.7, deep), (1, deep)]
    table = []
    for h in np.linspace(0, 1, 256):
        for (h0, c0), (h1, c1) in zip(stops, stops[1:]):
            if h <= h1:
                t = np.clip((h - h0) / (h1 - h0), 0, 1)
                t = t * t * (3 - 2 * t)
                c = c0 * (1 - t) + c1 * t
                break
        c = core_ * 0.6 + c * 0.4
        srgb = np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)
        table.append(to_linear(plush_tone(np.clip(srgb, 0, 1))))
    return np.array(table)


def ortho_camera(scene):
    camera = bpy.data.cameras.new("Cam")
    camera.type = "ORTHO"
    camera.ortho_scale = SIDE / SCALE
    cam = bpy.data.objects.new("Cam", camera)
    cam.location = (0, -10, 0)
    scene.collection.objects.link(cam)
    core.look_at(cam, (0, 0, 0))
    scene.camera = cam


# Shapes: a 2D outline (x right, z up, in units of the circle's radius) puffed into a plush pillow. Each outline keeps
# its bottom near the circle's (-1), so every shape sits on the same floor, and stays within about ±1.1 sideways.
PUFF = 0.8  # depth radius: the pillow is this thick at the outline's middle




def sd_soft_ngon(p, n, apothem, k, rotate=0.0, cz=0.0):
    """Regular n-gon as a smooth max of its edges (log-sum-exp): rounded corners and, unlike the exact distance, no
    crease from each corner to the middle, which the puffing would turn into a ridge. rotate=0: an edge on top."""
    q = p - np.array([0.0, cz])
    terms = [(q[:, 0] * math.sin(t) + q[:, 1] * math.cos(t) - apothem) / k
             for t in (rotate + 2 * math.pi * i / n for i in range(n))]
    top = np.max(terms, axis=0)
    return k * (top + np.log(np.sum([np.exp(t - top) for t in terms], axis=0)))


def sd_circle(p, cx, cz, r):
    return np.hypot(p[:, 0] - cx, p[:, 1] - cz) - r


def drop(p, r, length, cz=0.0, k=0.06):
    """A drop: a circle and the cone of its two tangents up to a point `length` above its center, the tip rounded by
    the soft max of the cone's sides."""
    q = p - np.array([0.0, cz])
    sin_a = r / length
    cos_a = math.sqrt(1 - sin_a * sin_a)
    sides = [(q[:, 0] * sx * cos_a + (q[:, 1] - length) * sin_a) / k for sx in (1, -1)]
    sides.append((r * sin_a - q[:, 1]) / k)  # only above where the sides touch the circle
    top = np.max(sides, axis=0)
    cone = k * (top + np.log(np.sum([np.exp(t - top) for t in sides], axis=0)))
    return smin(np.linalg.norm(q, axis=1) - r, cone, 0.15)


def smin(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
    return b * (1 - h) + a * h - k * h * (1 - h)






SHAPES = {
    "seixo": lambda p: (np.hypot(p[:, 0] / 1.1, (p[:, 1] + 0.15) / 0.85) - 1) * 0.85,
    "almofada": lambda p: (np.abs(p[:, 0]) ** 4 + np.abs(p[:, 1] + 0.03) ** 4) ** 0.25 - 0.95,
    "capsula": lambda p: np.hypot(p[:, 0] - np.clip(p[:, 0], -0.42, 0.42), p[:, 1] + 0.3) - 0.68,
    "triangulo": lambda p: sd_soft_ngon(p, 3, 0.6, 0.16, rotate=math.pi, cz=-0.32),
    "hexagono": lambda p: sd_soft_ngon(p, 6, 0.88, 0.09),
    "nuvem": lambda p: smin(smin(smin(sd_circle(p, -0.6, -0.48, 0.48), sd_circle(p, 0.6, -0.48, 0.48), 0.18),
                                 smin(sd_circle(p, -0.32, 0.1, 0.55), sd_circle(p, 0.34, 0.18, 0.6), 0.18), 0.18),
                            sd_circle(p, 0.0, -0.3, 0.7), 0.18),
    "gota": lambda p: drop(p, 0.68, 1.24, cz=-0.3),
}


def puffed(outline):
    """3D signed distance of the outline puffed by PUFF: the silhouette is the outline, rounded front to back."""
    def sdf(q):
        d2 = outline(q[:, [0, 2]])
        return np.hypot(np.maximum(d2 + PUFF, 0), q[:, 1]) - PUFF
    return sdf


def ray_surface(sdf, unit, far=2.5, steps=40):
    """Where each ray from the center leaves the body (every shape is star-shaped around its middle)."""
    lo, hi = np.zeros(len(unit)), np.full(len(unit), far)
    for _ in range(steps):
        mid = (lo + hi) / 2
        inside = sdf(unit * mid[:, None]) < 0
        lo, hi = np.where(inside, mid, lo), np.where(inside, hi, mid)
    return unit * ((lo + hi) / 2)[:, None]


def gradient(sdf, pts, eps=1e-3):
    g = np.stack([sdf(pts + e) - sdf(pts - e) for e in np.eye(3) * eps], axis=1)
    return g / np.linalg.norm(g, axis=1, keepdims=True)


def shape_surface(sdf, scale):
    """Fur roots spread evenly over the area (a ray per root would crowd the near parts and thin out the far ends)."""
    def surface(count, rng):
        unit = rng.normal(size=(int(count * 2.2), 3))
        unit /= np.linalg.norm(unit, axis=1, keepdims=True)
        pts = ray_surface(sdf, unit)
        normal = gradient(sdf, pts)
        area = np.sum(pts ** 2, axis=1) / np.maximum(np.sum(unit * normal, axis=1), 0.2)
        keep = rng.random(len(pts)) < area / area.max()
        pts, normal = pts[keep][:count], normal[keep][:count]
        return pts * scale, normal
    return surface


def shape_body(sdf, material, scale):
    """The skin: a UV sphere pushed out to the shape along each vertex's ray."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=256, v_segments=128, radius=1.0)
    unit = np.array([v.co for v in bm.verts])
    unit /= np.linalg.norm(unit, axis=1, keepdims=True)
    for v, p in zip(bm.verts, ray_surface(sdf, unit) * scale):
        v.co = p
    mesh = bpy.data.meshes.new("Orb")
    bm.to_mesh(mesh)
    bm.free()
    orb = bpy.data.objects.new("Orb", mesh)
    bpy.context.scene.collection.objects.link(orb)
    bpy.context.view_layer.objects.active = orb
    orb.select_set(True)
    bpy.ops.object.shade_smooth()
    orb.data.materials.append(material)
    return orb


GREY = 0.3  # linear: the app maps luminance to the palette, so the coat only needs light and shade


def build_shape(shape_id, samples, side):
    mk.FUR = FUR
    mk.FACE_SHAPES.clear()
    scene = mk.setup_scene(side * SUPERSAMPLE, samples, "pelucia")
    skin, fur = mk.mat_plush(0xC4C4C4, strand_colors=True)
    skin.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (GREY * 0.75,) * 3 + (1,)
    sdf = puffed(SHAPES[shape_id])
    orb = shape_body(sdf, skin, CORE)
    mk.add_fur(orb, fur, strand_color=lambda root: np.full((len(root), 3), GREY),
               surface=shape_surface(sdf, CORE))
    ortho_camera(scene)


def build(hexes, samples):
    mk.FUR = FUR
    mk.FACE_SHAPES.clear()
    scene = mk.setup_scene(SIDE * SUPERSAMPLE, samples, "pelucia")
    table = palette_ramp(hexes)
    skin, fur = mk.mat_plush(int(hexes[1].lstrip("#"), 16), strand_colors=True)
    # The skin between strands: the core color, a little darker.
    skin.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*(table[128] * 0.75), 1)
    orb = mk.sphere_body(skin, 256, 128)
    orb.scale = tuple(v * CORE for v in orb.scale)
    bpy.context.view_layer.update()

    def strand_color(root):
        h = np.clip((root[:, 2] / orb.scale[2] + 1) / 2, 0, 1)
        return table[(h * 255).astype(int)]

    mk.add_fur(orb, fur, strand_color=strand_color)
    ortho_camera(scene)


def render(path):
    """Renders at SUPERSAMPLE× and boxes it down (premultiplied), next to the target so a failed run leaves no file."""
    scratch = os.path.join(os.path.dirname(path), ".tmp-" + os.path.basename(path))
    bpy.context.scene.render.filepath = scratch
    bpy.ops.render.render(write_still=True)
    rgba = mk.downscale(core.load_rgba(scratch), SUPERSAMPLE)
    os.remove(scratch)
    core.save_rgba(path, rgba)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--only", default="")
    p.add_argument("--samples", type=int, default=64)
    p.add_argument("--out", default="")
    p.add_argument("--shapes", action="store_true")
    p.add_argument("--side", type=int, default=SIDE, help="drafts: a smaller image (same framing)")
    p.add_argument("--fur-count", type=int, default=0, help="drafts: fewer strands")
    a = p.parse_args(argv)
    if a.fur_count:
        mk.FUR_DENSITY["count"] = a.fur_count
    only = set(filter(None, a.only.split(",")))
    if a.shapes:
        out = a.out or os.path.join(RESOURCES, "shape")
        os.makedirs(out, exist_ok=True)
        for shape_id in SHAPES:
            if only and shape_id not in only:
                continue
            t0 = time.time()
            build_shape(shape_id, a.samples, a.side)
            render(os.path.join(out, f"{shape_id}.png"))
            print(f"FORMATO {shape_id}: {time.time() - t0:.1f}s", flush=True)
        return
    a.out = a.out or os.path.join(RESOURCES, "body")
    with open(os.path.join(RESOURCES, "options.json")) as f:
        colors = json.load(f)["color"]
    os.makedirs(a.out, exist_ok=True)
    for entry in colors:
        if only and entry["id"] not in only:
            continue
        t0 = time.time()
        build(entry["hex"], a.samples)
        render(os.path.join(a.out, f"{entry['id']}.png"))
        print(f"CORPO {entry['id']}: {time.time() - t0:.1f}s", flush=True)


main()
