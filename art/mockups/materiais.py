"""Mockups de material dos Orbs (nada disto entra no app): massinha, fosco, gelatina, pelucia e o atual.

    nice -n 15 Blender -b --python art/mockups/materiais.py -- [--only massinha,gelatina] [--colors lavanda,coral]
        [--size 900] [--samples 128] [--out docs/mocks/orbs-materiais] [--no-close]

Cada material usa o mesmo rosto (olhos em pilula + sorriso pequeno), so o material muda. Reaproveita a
geometria do art/orbkit sem alterar nada dele. Gera o PNG sobre fundo escuro e sobre fundo claro.
"""

import argparse
import math
import os
import random
import sys
import time

import bpy
import bmesh
import numpy as np
from mathutils import Vector

ART = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ART)
from orbkit import core, features  # noqa: E402

ROOT = os.path.dirname(ART)
DARK_BG = (0x10 / 255, 0x10 / 255, 0x12 / 255)
LIGHT_BG = (0xF1 / 255, 0xEF / 255, 0xF4 / 255)
COLORS = {"lavanda": 0xA77BFF, "coral": 0xF2533F, "menta": 0x14C08C}
MATERIALS = ["atual", "massinha", "fosco", "gelatina", "pelucia"]
# Fur absorbs light along the strand and reads darker than a surface of the same color: the plush starts from a
# deeper, more saturated tone of each color, closer to the photos.
PLUSH_COLORS = {0xA77BFF: 0x7444EA, 0xF2533F: 0xE8432E, 0x14C08C: 0x1FC777}
EYE_X, EYE_Z = features.EYE_X, features.EYE_Z
MOUTH_Z = -0.1


# ---------------------------------------------------------------------------
# Node helpers

def new_material(name):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    n = m.node_tree.nodes
    return m, n["Principled BSDF"], n, m.node_tree.links


def setv(node, **values):
    for key, value in values.items():
        node.inputs[key.replace("_", " ")].default_value = value


def shade(hex_value, k=1.0):
    r, g, b, _ = core.linear(hex_value)
    return (r * k, g * k, b * k, 1.0)


def clay_bump(nodes, links, bsdf, scale=1.0, strength=0.5, fingerprints=True):
    """Bump height = lumps + fine grain + streaks from the modeling tool + a few fingerprint patches."""
    coord = nodes.new("ShaderNodeTexCoord")

    def noise(scale_, detail, rough, mapping_scale=(1, 1, 1)):
        mp = nodes.new("ShaderNodeMapping")
        mp.inputs["Scale"].default_value = mapping_scale
        links.new(coord.outputs["Object"], mp.inputs["Vector"])
        nz = nodes.new("ShaderNodeTexNoise")
        nz.inputs["Scale"].default_value = scale_ * scale
        nz.inputs["Detail"].default_value = detail
        nz.inputs["Roughness"].default_value = rough
        links.new(mp.outputs["Vector"], nz.inputs["Vector"])
        return nz.outputs["Fac"]

    def mix(a, b, factor):
        m = nodes.new("ShaderNodeMath")
        m.operation = "MULTIPLY_ADD"
        links.new(a, m.inputs[0])
        m.inputs[1].default_value = factor
        links.new(b, m.inputs[2])
        return m.outputs[0]

    height = noise(5, 3, 0.55)                       # soft lumps
    height = mix(noise(70, 5, 0.6), height, 0.45)     # fine grain
    height = mix(noise(14, 2, 0.5, (1, 1, 9)), height, 0.35)  # streaks left by a tool
    if fingerprints:
        mp = nodes.new("ShaderNodeMapping")
        mp.inputs["Scale"].default_value = (1, 1, 1)
        mp.inputs["Location"].default_value = (0.3, 0.0, 0.2)
        links.new(coord.outputs["Object"], mp.inputs["Vector"])
        wave = nodes.new("ShaderNodeTexWave")
        wave.wave_type = "RINGS"
        wave.inputs["Scale"].default_value = 38 * scale
        wave.inputs["Distortion"].default_value = 3.0
        wave.inputs["Detail"].default_value = 2.0
        wave.inputs["Detail Scale"].default_value = 3.0
        links.new(mp.outputs["Vector"], wave.inputs["Vector"])
        patch = noise(2.2, 1, 0.5)
        ramp = nodes.new("ShaderNodeMapRange")
        ramp.inputs["From Min"].default_value = 0.52
        ramp.inputs["From Max"].default_value = 0.62
        links.new(patch, ramp.inputs["Value"])
        prod = nodes.new("ShaderNodeMath")
        prod.operation = "MULTIPLY"
        links.new(wave.outputs["Fac"], prod.inputs[0])
        links.new(ramp.outputs["Result"], prod.inputs[1])
        height = mix(prod.outputs[0], height, 0.5)
    bump = nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = strength
    bump.inputs["Distance"].default_value = 0.012
    links.new(height, bump.inputs["Height"])
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])


def mat_clay(hex_value, scale=1.0, bump=0.9, fingerprints=True):
    m, b, nodes, links = new_material("Massinha")
    setv(b, Base_Color=shade(hex_value, 0.95), Roughness=0.88, Subsurface_Weight=0.22, Subsurface_Scale=0.05,
         Specular_IOR_Level=0.25)
    b.inputs["Subsurface Radius"].default_value = (1.0, 0.55, 0.4)
    clay_bump(nodes, links, b, scale, bump, fingerprints)
    return m


def mat_matte(hex_value, roughness=0.82, sheen=0.25, grain=0.05, subsurface=0.05):
    m, b, nodes, links = new_material("Fosco")
    setv(b, Base_Color=shade(hex_value), Roughness=roughness, Sheen_Weight=sheen, Sheen_Roughness=0.6,
         Specular_IOR_Level=0.2, Subsurface_Weight=subsurface, Subsurface_Scale=0.04)
    if grain:
        coord = nodes.new("ShaderNodeTexCoord")
        nz = nodes.new("ShaderNodeTexNoise")
        nz.inputs["Scale"].default_value = 420
        nz.inputs["Detail"].default_value = 3
        links.new(coord.outputs["Object"], nz.inputs["Vector"])
        bump = nodes.new("ShaderNodeBump")
        bump.inputs["Strength"].default_value = grain
        bump.inputs["Distance"].default_value = 0.004
        links.new(nz.outputs["Fac"], bump.inputs["Height"])
        links.new(bump.outputs["Normal"], b.inputs["Normal"])
    return m


def mat_satin(hex_value):
    """Approximation of the current look: soft vinyl, broad low sheen, no sharp reflection."""
    m, b, nodes, links = new_material("Atual")
    setv(b, Base_Color=shade(hex_value), Roughness=0.5, Coat_Weight=0.35, Coat_Roughness=0.45,
         Sheen_Weight=0.15, Sheen_Roughness=0.5, Subsurface_Weight=0.15, Subsurface_Scale=0.08,
         Specular_IOR_Level=0.5)
    return m


def mat_jelly(hex_value):
    m, b, nodes, links = new_material("Gelatina")
    setv(b, Base_Color=(1, 1, 1, 1), Roughness=0.035, Transmission_Weight=1.0, Specular_IOR_Level=0.8)
    b.inputs["IOR"].default_value = 1.38
    out = nodes["Material Output"]
    absorb = nodes.new("ShaderNodeVolumeAbsorption")
    absorb.inputs["Color"].default_value = shade(lighten(hex_value, 0.12), 1.0)
    absorb.inputs["Density"].default_value = 3.3
    scatter = nodes.new("ShaderNodeVolumeScatter")
    scatter.inputs["Color"].default_value = shade(hex_value, 1.0)
    scatter.inputs["Density"].default_value = 0.6
    scatter.inputs["Anisotropy"].default_value = 0.35
    add = nodes.new("ShaderNodeAddShader")
    links.new(absorb.outputs[0], add.inputs[0])
    links.new(scatter.outputs[0], add.inputs[1])
    links.new(add.outputs[0], out.inputs["Volume"])
    return m


def lighten(hex_value, amount):
    r, g, b = ((hex_value >> s) & 0xFF for s in (16, 8, 0))
    return (int(r + (255 - r) * amount) << 16) | (int(g + (255 - g) * amount) << 8) | int(b + (255 - b) * amount)


def mat_plush(hex_value, strand_colors=False):
    """Fur on Principled Hair (Chiang): a saturated strand, a touch darker at the root and paler at the tip, with a
    little random hue per strand so the coat doesn't read as one flat color. The skin under it is the root tone.
    With `strand_colors` each strand takes its color from the "cor" attribute (the app's palettes are gradients)."""
    m, b, nodes, links = new_material("Pelucia")
    # The skin shows between strands: close to the fur, or the coat reads as carpet over a dark backing.
    setv(b, Base_Color=shade(hex_value, 0.75), Roughness=1.0, Sheen_Weight=0.6, Sheen_Roughness=0.5)
    h = bpy.data.materials.new("Pelo")
    h.use_nodes = True
    hn, hl = h.node_tree.nodes, h.node_tree.links
    hn.remove(hn["Principled BSDF"])
    hair = hn.new("ShaderNodeBsdfHairPrincipled")
    hair.model = "CHIANG"
    hair.parametrization = "COLOR"
    hair.inputs["Roughness"].default_value = 0.55
    hair.inputs["Radial Roughness"].default_value = 0.75
    hair.inputs["Coat"].default_value = 0.1
    hair.inputs["IOR"].default_value = 1.45
    hair.inputs["Random Roughness"].default_value = 0.3
    info = hn.new("ShaderNodeHairInfo")
    ramp = hn.new("ShaderNodeValToRGB")
    core.set_ramp(ramp, [(0.0, shade(hex_value, 0.55)), (0.45, shade(hex_value, 0.9)),
                         (1.0, shade(lighten(hex_value, 0.08), 1.0))])
    hl.new(info.outputs["Intercept"], ramp.inputs["Fac"])
    strand = ramp.outputs["Color"]
    if strand_colors:
        core.set_ramp(ramp, [(0.0, (0.6, 0.6, 0.6, 1)), (0.45, (0.92, 0.92, 0.92, 1)), (1.0, (1.03, 1.03, 1.03, 1))])
        cor = hn.new("ShaderNodeAttribute")
        cor.attribute_name = "cor"
        tinted = hn.new("ShaderNodeVectorMath")
        tinted.operation = "MULTIPLY"
        hl.new(cor.outputs["Color"], tinted.inputs[0])
        hl.new(ramp.outputs["Color"], tinted.inputs[1])
        strand = tinted.outputs["Vector"]
    # Per-strand variation: a few strands a shade lighter or darker.
    jitter = hn.new("ShaderNodeVectorMath")
    jitter.operation = "SCALE"
    vary = hn.new("ShaderNodeMapRange")
    vary.inputs["To Min"].default_value = 0.8
    vary.inputs["To Max"].default_value = 1.15
    hl.new(info.outputs["Random"], vary.inputs["Value"])
    # Patch tone from the strands' "patch" attribute: whole areas a bit lighter or darker, as on a worn toy.
    attr = hn.new("ShaderNodeAttribute")
    attr.attribute_name = "patch"
    patchy = hn.new("ShaderNodeMath")
    patchy.operation = "MULTIPLY"
    hl.new(vary.outputs["Result"], patchy.inputs[0])
    hl.new(attr.outputs["Fac"], patchy.inputs[1])
    hl.new(strand, jitter.inputs["Vector"])
    hl.new(patchy.outputs[0], jitter.inputs["Scale"])
    hl.new(jitter.outputs["Vector"], hair.inputs["Color"])
    hl.new(hair.outputs[0], hn["Material Output"].inputs["Surface"])
    return m, h


def mat_feature(kind, light_bg_name=None):
    """Eyes and mouth: same off-white everywhere except where the material asks for another finish."""
    if kind == "atual":
        m, b, nodes, links = new_material("Feature")
        setv(b, Base_Color=shade(0xF0EEFF), Emission_Color=shade(0xF0EEFF), Emission_Strength=0.9, Roughness=0.3)
        return m
    if kind == "pelucia":
        m, b, nodes, links = new_material("Feature")
        # Soft off-white vinyl, like the photos: a broad gentle highlight, a little light under the skin.
        # Albedo below white so the key light shades the pill (top lit, a soft grey underside) instead of clipping
        # flat like a sticker; a soft coat gives the photos' gentle highlight.
        setv(b, Base_Color=shade(0xD6D0C6), Roughness=0.4, Coat_Weight=0.55, Coat_Roughness=0.14,
             Specular_IOR_Level=0.4, Subsurface_Weight=0.35, Subsurface_Scale=0.03, Sheen_Weight=0.3,
             Sheen_Roughness=0.4)
        b.inputs["Subsurface Radius"].default_value = (1.0, 0.85, 0.7)
        return m
    if kind == "gelatina":
        m, b, nodes, links = new_material("Feature")
        setv(b, Base_Color=shade(0xF6F3FF), Roughness=0.5, Emission_Color=shade(0xF6F3FF), Emission_Strength=1.1)
        return m
    if kind == "massinha":
        return mat_clay(0xF3EFE6, scale=2.6, bump=0.45, fingerprints=False)
    return mat_matte(0xF4F1FA, roughness=0.7, sheen=0.1, grain=0.03, subsurface=0)


# ---------------------------------------------------------------------------
# Geometry

def sphere_body(material, segments=128, rings=64):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segments, v_segments=rings, radius=1.0)
    mesh = bpy.data.meshes.new("Orb")
    bm.to_mesh(mesh)
    bm.free()
    orb = bpy.data.objects.new("Orb", mesh)
    bpy.context.scene.collection.objects.link(orb)
    bpy.context.view_layer.objects.active = orb
    orb.select_set(True)
    orb.scale = (1.0, 0.98, 0.97)
    bpy.ops.object.shade_smooth()
    orb.data.materials.append(material)
    return orb


def smooth_tube(points, radii, material, orb, bevel, lift):
    return core.tube(points, radii, material, bevel=bevel, orb=orb, lift=lift)


def face(orb, kind, feature, wink=False):
    """Same pill eyes and small smile for every material; only depth and sink change with the finish."""
    if kind == "pelucia":
        plush_face(orb, feature, wink)
        return
    depth, sink, lift, bevel = {
        "massinha": (0.034, 0.0, 0.01, 0.027),
        "gelatina": (0.04, 0.065, -0.05, 0.022),
    }.get(kind, (0.018, -0.012, 0.008, 0.024))
    for side in (-1, 1):
        eye = core.capsule(0.068, 0.085, depth, feature)
        core.on_surface(eye, orb, EYE_X * side, EYE_Z, sink=sink if kind != "atual" else -0.012)
    mouth = features.arc(0, MOUTH_Z + 0.03, 0.24, -0.075)
    core.tube(mouth, [1, 1, 1], feature, bevel=bevel, orb=orb, lift=lift)


FUR = 0.15  # strand length on a unit sphere (the strands lean, so the pile stands about 0.7 of that)
FUR_DENSITY = {}  # --fur-count, for quick drafts


FACE_SHAPES = []  # the plush face in face space, (a, b, radius) segments: the fur parts around them
EYE_R, EYE_HALF, EYE_DEPTH = 0.092, 0.1, 0.07
SMILE_W, SMILE_SAG, SMILE_Z, SMILE_R = 0.24, 0.07, MOUTH_Z - 0.035, 0.036


def smile_curve(samples=24):
    """Face-space points of the smile: a parabola, the corners up."""
    xs = np.linspace(-SMILE_W / 2, SMILE_W / 2, samples)
    return [(x, SMILE_Z + SMILE_SAG * (2 * x / SMILE_W) ** 2) for x in xs]


def soft_bean(points, radius, flatten, orb, lift, material, rings=72, sides=28):
    """Tube along face-space `points` on the orb, with round ends (the radius eases to 0 over the last `radius`, so
    each end is a half sphere) and flattened against the surface like the pills, so the smile is the same soft
    piece as the eyes instead of a pipe with cut ends."""
    centers, normals = [], []
    for x, z in points:
        location, normal = core.surface(orb, x, z)
        centers.append(np.array(location))
        normals.append(np.array(normal))
    centers, normals = np.array(centers), np.array(normals)
    seg = np.linalg.norm(np.diff(centers, axis=0), axis=1)
    arc = np.concatenate([[0], np.cumsum(seg)])
    total = arc[-1] + 2 * radius
    # Extend the path by a radius past each corner so the round end grows out of it.
    t0 = centers[1] - centers[0]
    t1 = centers[-1] - centers[-2]
    path_s = np.linspace(0, total, rings)
    verts = []
    for s_ in path_s:
        a = s_ - radius
        if a < 0:
            c, n, tan = centers[0] + t0 / np.linalg.norm(t0) * a, normals[0], t0
        elif a > arc[-1]:
            c, n, tan = centers[-1] + t1 / np.linalg.norm(t1) * (a - arc[-1]), normals[-1], t1
        else:
            i = min(np.searchsorted(arc, a, side="right") - 1, len(seg) - 1)
            f = (a - arc[i]) / seg[i]
            c = centers[i] * (1 - f) + centers[i + 1] * f
            n = normals[i] * (1 - f) + normals[i + 1] * f
            tan = centers[i + 1] - centers[i]
        n = n / np.linalg.norm(n)
        tan = tan - n * np.dot(tan, n)
        tan /= np.linalg.norm(tan)
        bi = np.cross(tan, n)
        edge = min(s_, total - s_)
        r = radius * math.sqrt(max(0.0, 1 - ((radius - edge) / radius) ** 2)) if edge < radius else radius
        for k in range(sides):
            phi = 2 * math.pi * k / sides
            verts.append(c + n * lift + r * (math.cos(phi) * bi + flatten * math.sin(phi) * n))
    faces = [(i * sides + k, i * sides + (k + 1) % sides, (i + 1) * sides + (k + 1) % sides, (i + 1) * sides + k)
             for i in range(rings - 1) for k in range(sides)]
    mesh = bpy.data.meshes.new("Boca")
    mesh.from_pydata([tuple(v) for v in verts], [], faces)
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new("Boca", mesh)
    bpy.context.scene.collection.objects.link(obj)
    for poly in mesh.polygons:
        poly.use_smooth = True
    obj.data.materials.append(material)
    obj.modifiers.new("Liso", "SUBSURF").levels = 1
    return obj


def plush_face(orb, feature, wink):
    """Puffy pills pressed into the fur, as on a plush toy: each piece sits low, the fur around it is shorter and
    parts away from it (see `add_fur`), so it looks set into the coat rather than floating over it. `wink` is the
    photos' face: one tall pill, one lying down, no mouth."""
    FACE_SHAPES.clear()
    for side in (-1, 1):
        lying = wink and side == 1
        half = 0.045 if lying else EYE_HALF
        x, z = EYE_X * side + (0.04 if lying else 0), EYE_Z - (0.02 if lying else 0)
        eye = core.capsule(EYE_R, half, EYE_DEPTH, feature)
        core.on_surface(eye, orb, x, z, sink=-0.03, roll=math.pi / 2 if lying else 0)
        if lying:
            FACE_SHAPES.append(((x - half, z), (x + half, z), EYE_R))
        else:
            FACE_SHAPES.append(((x, z - half), (x, z + half), EYE_R))
    if not wink:
        points = smile_curve()
        soft_bean(points, SMILE_R, 0.9, orb, 0.04, feature)
        FACE_SHAPES.extend((a, b, SMILE_R) for a, b in zip(points, points[1:]))


def add_bubbles(count=22, seed=7):
    rng = random.Random(seed)
    m, b, nodes, links = new_material("Bolha")
    setv(b, Base_Color=(1, 1, 1, 1), Roughness=0.02, Transmission_Weight=1.0)
    b.inputs["IOR"].default_value = 0.78
    placed = 0
    while placed < count:
        p = Vector((rng.uniform(-0.8, 0.8), rng.uniform(-0.6, 0.8), rng.uniform(-0.8, 0.8)))
        if p.length > 0.78 or (p.y < -0.25 and abs(p.z) < 0.4 and abs(p.x) < 0.5):
            continue  # inside the orb and clear of the face
        r = rng.choice([0.012, 0.016, 0.02, 0.026, 0.034])
        bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=12, radius=r, location=p)
        bpy.ops.object.shade_smooth()
        bpy.context.active_object.data.materials.append(m)
        placed += 1


def noise_field(points, freq, rng, waves=12):
    """Smooth pseudo-noise over 3D points (a sum of random plane waves), about -1..1."""
    k = rng.normal(size=(waves, 3))
    k *= (freq * rng.uniform(0.7, 1.3, (waves, 1))) / np.linalg.norm(k, axis=1, keepdims=True)
    phase = rng.uniform(0, 2 * math.pi, waves)
    return np.sin(points @ k.T + phase).sum(axis=1) / math.sqrt(waves / 2)


def face_parting(root, normal, margin=0.085):
    """For each root: how close it is to a face piece (1 at/under its edge, easing to 0 at `margin` out) and the
    surface direction away from the piece."""
    count = len(root)
    near = np.zeros(count)
    away = np.zeros((count, 3))
    if not FACE_SHAPES:
        return near, away
    front = root[:, 1] < 0
    p = root[:, [0, 2]]
    best = np.full(count, np.inf)
    best_vec = np.zeros((count, 2))
    for a, b, r in FACE_SHAPES:
        a, b = np.array(a), np.array(b)
        ab = b - a
        f = np.clip(((p - a) @ ab) / max(ab @ ab, 1e-12), 0, 1)
        vec = p - (a + f[:, None] * ab)
        d = np.linalg.norm(vec, axis=1) - r
        better = d < best
        best[better] = d[better]
        best_vec[better] = vec[better]
    k = np.clip(best / margin, 0, 1)
    near = np.where(front, 1 - k * k * (3 - 2 * k), 0.0)
    away[:, 0], away[:, 2] = best_vec[:, 0], best_vec[:, 1]
    away -= normal * np.sum(away * normal, axis=1, keepdims=True)
    away /= np.maximum(np.linalg.norm(away, axis=1, keepdims=True), 1e-9)
    return near, away


def add_fur(orb, hair_mat, count=800000, steps=10, strand_color=None):
    """Plush coat as real curves, built strand by strand: each strand leans a little in its own direction (with only
    a faint downward comb), curls softly, barely clumps and frizzes at the tip. Straight radial strands read as a
    plasma ball; strongly combed ones as an animal pelt; a plush toy is in between, dense, soft and fuzzy-tipped."""
    count = FUR_DENSITY.get("count", count)
    rng = np.random.default_rng(11)
    scale = np.array(orb.scale, dtype=np.float64)
    unit = rng.normal(size=(count, 3))
    unit /= np.linalg.norm(unit, axis=1, keepdims=True)
    root = unit * scale
    normal = unit / scale
    normal /= np.linalg.norm(normal, axis=1, keepdims=True)

    # Flow: combed downward, bent by slow swirls; projected on the surface.
    swirl = np.stack([noise_field(root, 2.2, rng) for _ in range(3)], axis=1)
    flow = np.array([0.0, 0.0, -0.35]) + 0.25 * swirl + rng.normal(scale=0.8, size=(count, 3))
    flow -= normal * np.sum(flow * normal, axis=1, keepdims=True)
    flow += rng.normal(scale=1e-3, size=flow.shape)  # the poles have no tangent of their own
    flow /= np.linalg.norm(flow, axis=1, keepdims=True)
    side = np.cross(normal, flow)

    # Around the face the fur is pressed down and parts away from each piece, like fibers around a glued-on eye.
    near, away = face_parting(root, normal)
    flow = flow * (1 - near[:, None]) + away * (1.6 * near[:, None])
    flow -= normal * np.sum(flow * normal, axis=1, keepdims=True)
    flow /= np.maximum(np.linalg.norm(flow, axis=1, keepdims=True), 1e-9)
    side = np.cross(normal, flow)

    lean = np.clip(0.6 + 0.08 * noise_field(root, 3.0, rng) + rng.normal(scale=0.18, size=count), 0.1, 1.1)
    length = FUR * (1 + 0.08 * noise_field(root, 4.5, rng)) * rng.uniform(0.7, 1.0, count)
    length *= 1 - 0.62 * near
    lean = np.clip(lean + 0.45 * near, 0.1, 1.35)
    # A few longer, unruly strands soften the silhouette; none around the face, where they'd lie across the pills.
    near_face = (root[:, 1] < 0) & (np.abs(root[:, 0]) < 0.5) & (np.abs(root[:, 2] - 0.05) < 0.4)
    stray = (rng.random(count) < 0.04) & ~near_face
    length[stray] *= 1.4
    lean[stray] = rng.uniform(0.2, 1.3, stray.sum())

    t = np.linspace(0.0, 1.0, steps)
    angle = lean[:, None] + 0.35 * t[None, :]  # each strand arcs over a little as it grows
    seg = (length / (steps - 1))[:, None, None]
    step_dir = normal[:, None, :] * np.cos(angle)[..., None] + flow[:, None, :] * np.sin(angle)[..., None]
    offsets = np.concatenate([np.zeros((count, 1, 3)), np.cumsum(step_dir[:, :-1] * seg, axis=1)], axis=1)
    pos = root[:, None, :] - normal[:, None, :] * 0.004 + offsets

    # Soft curl (before the clump, so each strand curls and then the tufts gather them).
    phase = rng.uniform(0, 2 * math.pi, count)[:, None]
    turns = rng.uniform(1.2, 2.2, count)[:, None]
    theta = 2 * math.pi * turns * t[None, :] + phase
    curl = (0.005 * t ** 0.8)[None, :, None]
    pos += curl * (side[:, None, :] * np.cos(theta)[..., None] + flow[:, None, :] * np.sin(theta)[..., None])

    # Tufts, kept faint: each strand leans toward a nearby guide strand, more toward the tip.
    from mathutils import kdtree
    guides = rng.choice(count, 14000, replace=False)
    tree = kdtree.KDTree(len(guides))
    for i, g in enumerate(guides):
        tree.insert(root[g], i)
    tree.balance()
    nearest = np.fromiter((guides[tree.find(p)[1]] for p in root), dtype=np.int64, count=count)
    pull = (0.3 * rng.uniform(0.3, 1.0, count))[:, None, None] * (t ** 1.6)[None, :, None]
    pos += pull * (pos[nearest] - pos)

    # Frizz, strongest at the tip: the fuzzy ends are what make it read as plush.
    pos += rng.normal(scale=0.003, size=pos.shape) * (t ** 1.8)[None, :, None]

    curves = bpy.data.hair_curves.new("Pelo")
    curves.add_curves([steps] * count)
    curves.attributes["position"].data.foreach_set("vector", pos.astype(np.float32).ravel())
    radius = curves.attributes.new("radius", "FLOAT", "POINT")
    radius.data.foreach_set("value", np.tile((0.0011 * (1 - 0.85 * t)).astype(np.float32), count))
    patch = curves.attributes.new("patch", "FLOAT", "CURVE")
    shade_ = 1 + 0.04 * noise_field(root, 5.0, rng) + rng.normal(scale=0.05, size=count)
    patch.data.foreach_set("value", shade_.astype(np.float32))
    if strand_color is not None:
        colors = np.concatenate([strand_color(root), np.ones((count, 1))], axis=1).astype(np.float32)
        curves.attributes.new("cor", "FLOAT_COLOR", "CURVE").data.foreach_set("color", colors.ravel())
    curves.materials.append(hair_mat)
    obj = bpy.data.objects.new("Pelo", curves)
    bpy.context.scene.collection.objects.link(obj)
    return obj


# ---------------------------------------------------------------------------
# Scene

def setup_scene(size, samples, kind):
    scene = core.reset_scene(samples, size)
    scene.cycles.max_bounces = 24 if kind == "gelatina" else 8
    scene.cycles.transmission_bounces = 24
    scene.cycles.volume_bounces = 8
    scene.cycles.caustics_reflective = False
    scene.cycles.caustics_refractive = False
    scene.cycles.sample_clamp_indirect = 8
    if kind == "pelucia":
        scene.cycles_curves.shape = "THICK"
        scene.cycles_curves.subdivisions = 2
        # The denoiser reads single strands as noise and smooths the coat into velvet; fur noise reads as fur.
        scene.cycles.use_denoising = False
        scene.cycles.max_bounces = 6
        # Strands thinner than a pixel sparkle: clamp the bright paths that make single strands flash.
        scene.cycles.sample_clamp_direct = 3
        scene.cycles.sample_clamp_indirect = 1.5
    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.85, 0.86, 1.0, 1)
    bg.inputs["Strength"].default_value = 0.55 if kind != "gelatina" else 1.2
    scene.world = world

    def light(name, kind_, loc, energy, size_, shape="DISK", color=(1, 1, 1), size_y=None):
        data = bpy.data.lights.new(name, "AREA")
        data.energy, data.size, data.shape, data.color = energy, size_, shape, color
        if size_y:
            data.size_y = size_y
        obj = bpy.data.objects.new(name, data)
        obj.location = loc
        scene.collection.objects.link(obj)
        core.look_at(obj, (0, 0, 0))

    light("Key", 0, (-3.0, -4.2, 4.2), 700, 3.5, "DISK", (1.0, 0.97, 0.94))
    if kind != "gelatina":  # on jelly a disk fill shows up as a round blob in the reflection
        # Fur scatters light around on its own: a weaker fill keeps the ball's shading, as in the photos.
        light("Fill", 0, (4.0, -3.0, 0.6), 90 if kind == "pelucia" else 220, 5.0, "DISK", (0.9, 0.93, 1.0))
    # Backlight shines through fur tips and turns the whole silhouette white: the plush gets a faint one.
    light("Rim", 0, (2.6, 3.6, 3.0), 140 if kind == "pelucia" else 600, 4.0, "DISK", (1, 1, 1))
    if kind == "gelatina":
        light("Top", 0, (-0.6, -2.2, 5.0), 900, 2.2, "RECTANGLE", (1, 1, 1), 1.4)
        light("Back", 0, (0, 4.5, 0.5), 1500, 4.0, "DISK", (1, 1, 1))
    return scene


def set_camera(scene, target=(0, 0, 0.0), distance=7.6, lens=85):
    camera = bpy.data.cameras.new("Cam")
    camera.lens = lens
    cam = bpy.data.objects.new("Cam", camera)
    cam.location = (target[0], target[1] - distance, target[2] + 0.35 * distance / 9.0)
    scene.collection.objects.link(cam)
    core.look_at(cam, target)
    scene.camera = cam


def build(kind, hex_value, size, samples, close, wink=False):
    scene = setup_scene(size, samples, kind)
    feature = mat_feature(kind)
    if kind == "atual":
        orb = sphere_body(mat_satin(hex_value))
    elif kind == "massinha":
        orb = sphere_body(mat_clay(hex_value), 192, 96)
        disp = bpy.data.textures.new("Amassado", "CLOUDS")
        disp.noise_scale = 0.45
        disp.noise_depth = 2
        mod = orb.modifiers.new("Amassado", "DISPLACE")
        mod.texture, mod.strength, mod.mid_level = disp, 0.035, 0.5
    elif kind == "fosco":
        orb = sphere_body(mat_matte(hex_value))
    elif kind == "gelatina":
        orb = sphere_body(mat_jelly(hex_value))
    else:
        skin, fur = mat_plush(PLUSH_COLORS.get(hex_value, hex_value))
        orb = sphere_body(skin, 256, 128)
    bpy.context.view_layer.update()
    face(orb, kind, feature, wink)
    if kind == "gelatina":
        add_bubbles()
    if kind == "pelucia":
        add_fur(orb, fur)
    if close:
        target = {"pelucia": (0.35, -0.95, 0.25), "gelatina": (0.0, -0.8, 0.28)}.get(kind, (0.0, -1.0, 0.02))
        set_camera(scene, target, 2.7 if kind != "pelucia" else 2.6)
    else:
        set_camera(scene)
    return scene


def composite(rgba, bg, glow_hex, close):
    height, width = rgba.shape[:2]
    out = np.ones((height, width, 3), dtype=np.float32) * np.array(bg, dtype=np.float32)
    if not close:
        ys, xs = np.mgrid[0:height, 0:width]
        dx = (xs / width - 0.5) / 0.27
        dy = (ys / height - 0.17) / 0.04
        falloff = (np.exp(-(dx * dx + dy * dy) * 1.8))[..., None]
        light = np.mean(bg) > 0.5
        if light:
            out = out * (1 - falloff * 0.35)
        else:
            rgb = np.array([((glow_hex >> s) & 0xFF) / 255 for s in (16, 8, 0)], dtype=np.float32)
            out = out + rgb * falloff * 0.12
    alpha = rgba[..., 3:4]
    out = rgba[..., :3] * alpha + out * (1 - alpha)
    return np.concatenate([np.clip(out, 0, 1), np.ones_like(alpha)], axis=2)


def downscale(rgba, factor):
    """Box-filter by `factor`, averaging premultiplied color so the soft edge doesn't pick up a dark fringe.
    Strands thinner than a pixel average into a smooth coat instead of a crumbly one."""
    if factor <= 1:
        return rgba
    height, width = rgba.shape[0] // factor, rgba.shape[1] // factor
    rgba = rgba[:height * factor, :width * factor]
    alpha = rgba[..., 3:4]
    premult = np.concatenate([rgba[..., :3] * alpha, alpha], axis=2)
    small = premult.reshape(height, factor, width, factor, 4).mean(axis=(1, 3))
    a = small[..., 3:4]
    rgb = np.where(a > 1e-6, small[..., :3] / np.maximum(a, 1e-6), 0)
    return np.concatenate([rgb, a], axis=2).astype(np.float32)


def save_srgb(path, rgba):
    # Blender stores pixels linear for non-color-managed buffers; encode to display values ourselves
    core.save_rgba(path, rgba)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--only", default=",".join(MATERIALS))
    p.add_argument("--colors", default=",".join(COLORS))
    p.add_argument("--size", type=int, default=900)
    p.add_argument("--samples", type=int, default=128)
    p.add_argument("--out", default=os.path.join(ROOT, "docs", "mocks", "orbs-materiais"))
    p.add_argument("--no-close", action="store_true")
    p.add_argument("--close-only", action="store_true")
    p.add_argument("--no-wink", action="store_true", help="skip the plush's extra wink face (as in the photos)")
    p.add_argument("--supersample", type=int, default=2, help="plush only: render N x larger and average down")
    p.add_argument("--fur-count", type=int)
    a = p.parse_args(argv)
    if a.fur_count:
        FUR_DENSITY["count"] = a.fur_count
    os.makedirs(a.out, exist_ok=True)
    jobs = []
    for kind in a.only.split(","):
        if not a.close_only:
            jobs += [(kind, c, False) for c in a.colors.split(",")]
        if not a.no_close:
            jobs.append((kind, a.colors.split(",")[0], True))
    jobs = [(kind, color, close, False) for kind, color, close in jobs]
    if "pelucia" in a.only.split(",") and not a.no_wink and not a.close_only:
        jobs.append(("pelucia", a.colors.split(",")[0], False, True))
    for kind, color, close, wink in jobs:
        t0 = time.time()
        samples = a.samples * (2 if kind == "gelatina" else 1)
        factor = a.supersample if kind == "pelucia" else 1
        build(kind, COLORS[color], a.size * factor, samples, close, wink)
        scratch = os.path.join(a.out, f".tmp-{kind}.png")
        bpy.context.scene.render.filepath = scratch
        bpy.ops.render.render(write_still=True)
        rgba = downscale(core.load_rgba(scratch), factor)
        os.remove(scratch)
        name = f"{kind}-close" if close else f"{kind}-piscando" if wink else f"{kind}-{color}"
        for suffix, bg in (("", DARK_BG), ("-claro", LIGHT_BG)):
            core.save_rgba(os.path.join(a.out, name + suffix + ".png"), composite(rgba, bg, COLORS[color], close))
        print(f"RENDER {name}: {time.time() - t0:.1f}s", flush=True)


if __name__ == "__main__":
    main()
