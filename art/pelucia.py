"""Corpo de pelúcia dos Orbs: uma imagem por cor em Sources/Orb/Resources/Orbs/body, no enquadramento do orbgen.

    nice -n 15 Blender -b --python art/pelucia.py -- [--only lavanda,coral] [--samples 64] [--out <pasta>]

O pelo é o dos mockups (art/mockups/materiais.py): fios desenhados um a um, inclinados, com cacho leve e frizz
nas pontas. Cada fio pega a cor da paleta na altura dele (o mesmo degradê do corpo acetinado do orbgen), um pouco
mais saturada, porque o pelo espalha a luz e desbota. Olhos, boca e cabelo continuam sendo as camadas do app.
"""

import argparse
import colorsys
import json
import os
import sys
import time

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


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--only", default="")
    p.add_argument("--samples", type=int, default=64)
    p.add_argument("--out", default=os.path.join(RESOURCES, "body"))
    a = p.parse_args(argv)
    with open(os.path.join(RESOURCES, "options.json")) as f:
        colors = json.load(f)["color"]
    only = set(filter(None, a.only.split(",")))
    os.makedirs(a.out, exist_ok=True)
    for entry in colors:
        if only and entry["id"] not in only:
            continue
        t0 = time.time()
        build(entry["hex"], a.samples)
        scratch = os.path.join(a.out, f".tmp-{entry['id']}.png")
        bpy.context.scene.render.filepath = scratch
        bpy.ops.render.render(write_still=True)
        rgba = mk.downscale(core.load_rgba(scratch), SUPERSAMPLE)
        os.remove(scratch)
        core.save_rgba(os.path.join(a.out, f"{entry['id']}.png"), rgba)
        print(f"CORPO {entry['id']}: {time.time() - t0:.1f}s", flush=True)


main()
