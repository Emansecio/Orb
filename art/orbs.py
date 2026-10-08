"""Orbs (app Orb): render customizable glowing-gel orbs in Blender (headless).

    Blender -b --python art/orbs.py -- <command> [options]

Commands:
    render  --config '{"color": "rosa", "eyes": "ovais", "hair": "tufinho", "accessories": ["fones"]}'
            --name rosa-dj        -> art/renders/<name>.png (+ -dark/-light previews)
    catalog [--category eyes]     -> one labeled tile per option + a contact sheet per category
                                     (--category visemes: the talking mouths, not user options)
    layers [--category mouth]     -> app layers in Sources/Orb/Resources/Orbs (+ options.json)
                                     (--category visemes -> visemes/<id>.png and <id>-dark.png)
    manifest                      -> art/orb_options.json (ids + labels for the app editor)
"""

import argparse
import json
import math
import os
import sys

import bpy
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from orbkit import core, features  # noqa: E402

ART = os.path.dirname(os.path.abspath(__file__))
DARK = (0.027, 0.027, 0.027)


def build(config, samples, size, label=None):
    scene = core.reset_scene(samples, size)
    palette = features.PALETTE[config.get("color", "indigo")]
    orb = core.orb_body(core.gel_material(palette))
    features.build_features(features.Ctx(config, orb))
    core.add_lights_and_camera(scene, framing=1.12 if label else 1.0)
    if label:
        text = bpy.data.curves.new("Label", "FONT")
        text.body = label
        text.align_x = "CENTER"
        text.size = 0.26
        obj = bpy.data.objects.new("Label", text)
        obj.location = (0, -1.6, -1.62)
        obj.rotation_euler = (math.pi / 2, 0, 0)
        obj.data.materials.append(core.glow(0xBDBACC, 1.0))
        scene.collection.objects.link(obj)
    return scene


def render(config, path, samples, size, label=None):
    scene = build(config, samples, size, label)
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    rgba = core.load_rgba(path)
    glow_hex = features.PALETTE[config.get("color", "indigo")][1]
    core.save_rgba(path.replace(".png", "-dark.png"), core.composite(rgba, glow_hex, DARK))
    if not label:
        core.save_rgba(path.replace(".png", "-light.png"), core.composite(rgba, glow_hex, (1, 1, 1)))


def contact_sheet(paths, out, columns=6):
    tiles = [core.load_rgba(p) for p in paths]
    height, width = tiles[0].shape[:2]
    rows = math.ceil(len(tiles) / columns)
    sheet = np.ones((rows * height, columns * width, 4), dtype=np.float32)
    sheet[..., :3] = DARK
    for i, tile in enumerate(tiles):
        r, c = i // columns, i % columns
        y0 = (rows - 1 - r) * height     # image rows are bottom-up
        sheet[y0:y0 + height, c * width:(c + 1) * width] = tile
    core.save_rgba(out, sheet)


CATALOG_BASE = {"color": "indigo", "eyes": "pilulas"}
CATALOG_OVERRIDES = {
    # Show mustaches/hair/brows on a neutral face, accessories on a smiling one
    "mouth": {},
    "mustache": {"mouth": "sorriso"},
    "accessories": {"mouth": "sorriso"},
}


def options_of(category):
    return features.VISEMES if category == "visemes" else features.CATEGORIES[category]


def catalog(category, samples, size):
    out_dir = os.path.join(ART, "renders", "catalog", category)
    os.makedirs(out_dir, exist_ok=True)
    tiles = []
    for option_id, label, _ in options_of(category):
        config = dict(CATALOG_BASE, **CATALOG_OVERRIDES.get(category, {}))
        if category == "accessories":
            config["accessories"] = [option_id]
        elif category == "visemes":
            config["viseme"] = option_id
        else:
            config[category] = option_id
        path = os.path.join(out_dir, f"{option_id}.png")
        render(config, path, samples, size, label=label)
        tiles.append(path.replace(".png", "-dark.png"))
        print("tile", category, option_id)
    contact_sheet(tiles, os.path.join(ART, "renders", "catalog", f"{category}.png"))


PERSONAS = [
    ("professor", "Professor", {"color": "chocolate", "eyes": "pontos", "brows": "arqueadas", "mustache": "classico",
                                "mouth": "sorriso", "accessories": ["oculos-redondos"]}),
    ("dj", "DJ", {"color": "aurora", "eyes": "fendas", "mouth": "neutra", "accessories": ["fones", "oculos-sol"]}),
    ("princesa", "Realeza", {"color": "rosa", "eyes": "grandes", "cheeks": "blush", "mouth": "sorriso", "accessories": ["coroa"]}),
    ("festa", "Festeiro", {"color": "sol", "eyes": "felizes", "mouth": "sorrisao", "cheeks": "blush",
                           "accessories": ["chapeu-festa"]}),
    ("gato", "Gatinho", {"color": "lavanda", "eyes": "ovais", "mouth": "gatinho", "cheeks": "coracoes",
                         "accessories": ["orelhas-gato"]}),
    ("capeta", "Travesso", {"color": "cereja", "eyes": "bravos", "brows": "bravas", "mouth": "dentinho",
                            "accessories": ["chifres"]}),
    ("anjo", "Anjinho", {"color": "perola", "eyes": "sono", "mouth": "sorriso", "cheeks": "blush", "accessories": ["aureola"]}),
    ("cavalheiro", "Cavalheiro", {"color": "noite", "eyes": "pilulas", "mustache": "enrolado",
                                  "accessories": ["cartola", "monoculo"]}),
    ("skater", "Skatista", {"color": "lima", "eyes": "piscadela", "mouth": "lingua", "cheeks": "sardas",
                            "accessories": ["bone"]}),
    ("inverno", "Inverno", {"color": "ceu", "eyes": "pontos", "mouth": "assobio", "cheeks": "blush", "accessories": ["gorro"]}),
    ("rock", "Roqueiro", {"color": "grafite", "eyes": "estrelas", "mouth": "sorrisao", "hair": "moicano"}),
    ("jardim", "Jardineira", {"color": "menta", "eyes": "coracoes", "mouth": "sorriso", "hair": "franja",
                              "accessories": ["flor"]}),
]


def personas(samples, size):
    out_dir = os.path.join(ART, "renders", "personas")
    os.makedirs(out_dir, exist_ok=True)
    tiles = []
    for pid, label, config in PERSONAS:
        path = os.path.join(out_dir, f"{pid}.png")
        render(config, path, samples, size, label=label)
        tiles.append(path.replace(".png", "-dark.png"))
        print("persona", pid)
    contact_sheet(tiles, os.path.join(ART, "renders", "personas.png"))


# Layers whose material is rendered white and tinted in the app (multiply)
TINTED = {"hair", "mustache"}
TINTED_ACCESSORIES = {"bone", "gorro", "laco", "fones", "chifres", "flor", "orelhas-gato"}
VARIANT_CATEGORIES = {"eyes", "mouth", "brows"}   # light (glowing) + dark (for light palettes)
LAYER_CATEGORIES = [name for name in features.CATEGORIES if name != "color"] + ["visemes"]   # visemes: like mouth


def layers(samples, size, out, only_category=None):
    """Export composable layers for the app: body per color + one layer per feature option.

    The body is present as a holdout while rendering features, so anything behind the head is cut out.
    """
    def render_scene(config, path, only=None, holdout=True):
        scene = core.reset_scene(samples, size)
        palette = features.PALETTE[config.get("color", "indigo")]
        orb = core.orb_body(core.gel_material(palette))
        if only is not None:
            orb.is_holdout = holdout
            features.build_features(features.Ctx(config, orb), only=only)
        core.add_lights_and_camera(scene)
        scene.render.filepath = path
        bpy.ops.render.render(write_still=True)

    def wanted(category):
        return only_category is None or only_category == category

    if wanted("color"):
        os.makedirs(os.path.join(out, "body"), exist_ok=True)
        for pid, _, _ in features.PALETTES:
            render_scene({"color": pid}, os.path.join(out, "body", f"{pid}.png"))
            print("layer body", pid)

    for category in LAYER_CATEGORIES:
        if not wanted(category):
            continue
        os.makedirs(os.path.join(out, category), exist_ok=True)
        for option_id, _, builder in options_of(category):
            if builder is None:
                continue
            # Neutral (white) body light for non-variant layers so tints stay true in the app
            has_variants = category in VARIANT_CATEGORIES or category == "visemes"
            variants = [("", "indigo"), ("-dark", "perola")] if has_variants else [("", "perola")]
            for suffix, color in variants:
                config = {"color": color}
                if category == "hair":
                    config["hair_color"] = 0xFFFFFF
                if category == "mustache":
                    config["mustache_color"] = 0xFFFFFF
                if category == "accessories" and option_id in TINTED_ACCESSORIES:
                    config["accent_color"] = 0xFFFFFF
                render_scene(config, os.path.join(out, category, f"{option_id}{suffix}.png"), only=(category, option_id))
                print("layer", category, option_id + suffix)

    manifest(os.path.join(out, "options.json"))


def manifest(path=None):
    data = {name: [{"id": oid, "label": label} for oid, label, _ in options]
            for name, options in features.CATEGORIES.items()}
    data["color"] = [{"id": pid, "label": label, "hex": [f"#{c:06X}" for c in colors]}
                     for pid, label, colors in features.PALETTES]
    data["tinted"] = sorted(TINTED)
    data["tintedAccessories"] = sorted(TINTED_ACCESSORIES)
    data["variants"] = sorted(VARIANT_CATEGORIES)
    data["visemes"] = [oid for oid, _, _ in features.VISEMES]
    with open(path or os.path.join(ART, "orb_options.json"), "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
    print("manifest written")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["render", "catalog", "manifest", "personas", "layers"])
    parser.add_argument("--out", default=os.path.join(os.path.dirname(ART), "Sources", "Orb", "Resources", "Orbs"))
    parser.add_argument("--config", default="{}")
    parser.add_argument("--name", default="orb")
    parser.add_argument("--category", default=None)
    parser.add_argument("--samples", type=int, default=96)
    parser.add_argument("--size", type=int, default=600)
    args = parser.parse_args(argv)

    if args.command == "render":
        os.makedirs(os.path.join(ART, "renders"), exist_ok=True)
        render(json.loads(args.config), os.path.join(ART, "renders", f"{args.name}.png"), args.samples, args.size)
    elif args.command == "catalog":
        for category in ([args.category] if args.category else list(features.CATEGORIES) + ["visemes"]):
            catalog(category, args.samples, args.size)
    elif args.command == "layers":
        layers(args.samples, args.size, args.out, args.category)
    elif args.command == "personas":
        personas(args.samples, args.size)
    else:
        manifest()


main()
