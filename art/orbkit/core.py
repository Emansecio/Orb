"""Orb core: scene, lighting, the gel body material, shared materials and geometry helpers.

Model space: orb of radius ~1 centered at the origin; the face looks toward -Y; Z is up.
Face-space coordinates (x, z) are projected onto the front of the orb with ray casts.
"""

import math

import bpy
import numpy as np
from mathutils import Matrix, Vector

# ---------------------------------------------------------------------------
# Colors


def linear(hex_value, alpha=1.0):
    def channel(c):
        c = c / 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return (*(channel((hex_value >> s) & 0xFF) for s in (16, 8, 0)), alpha)


# ---------------------------------------------------------------------------
# Scene


def reset_scene(samples, size):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    try:
        prefs.compute_device_type = "METAL"
        prefs.get_devices()
        for device in prefs.devices:
            device.use = True
        scene.cycles.device = "GPU"
    except Exception:
        scene.cycles.device = "CPU"
    scene.cycles.samples = samples
    scene.cycles.use_denoising = True
    scene.cycles.max_bounces = 16
    scene.cycles.transmission_bounces = 12
    scene.render.resolution_x = scene.render.resolution_y = size
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.view_settings.view_transform = "Standard"

    world = bpy.data.worlds.new("World")
    world.use_nodes = True
    nodes, links = world.node_tree.nodes, world.node_tree.links
    background = nodes["Background"]
    coords = nodes.new("ShaderNodeTexCoord")
    separate = nodes.new("ShaderNodeSeparateXYZ")
    ramp = nodes.new("ShaderNodeValToRGB")
    set_ramp(ramp, [(0.35, (0.05, 0.05, 0.06, 1)), (0.75, (0.6, 0.6, 0.62, 1))])
    mapping = nodes.new("ShaderNodeMapRange")
    mapping.inputs["From Min"].default_value = -1
    mapping.inputs["From Max"].default_value = 1
    links.new(coords.outputs["Normal"], separate.inputs["Vector"])
    links.new(separate.outputs["Z"], mapping.inputs["Value"])
    links.new(mapping.outputs["Result"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], background.inputs["Color"])
    background.inputs["Strength"].default_value = 0.3
    scene.world = world
    return scene


def look_at(obj, target):
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


def add_lights_and_camera(scene, framing=1.0):
    def area(name, location, energy, size):
        light = bpy.data.lights.new(name, "AREA")
        light.energy = energy
        light.size = size
        light.shape = "DISK"
        obj = bpy.data.objects.new(name, light)
        obj.location = location
        scene.collection.objects.link(obj)
        look_at(obj, (0, 0, 0))

    area("Key", (-2.6, -3.2, 3.4), 45, 7.0)
    area("Fill", (3.2, -2.4, 0.4), 18, 7.0)
    # Accessory key: a small, slightly harder light so plastic/metal parts get readable highlights
    area("Accent", (-1.8, -4.0, 2.6), 60, 2.5)

    camera = bpy.data.cameras.new("Camera")
    camera.lens = 85
    cam = bpy.data.objects.new("Camera", camera)
    cam.location = (0, -9.0 * framing, 0.35 + 0.12 * (framing - 1))
    scene.collection.objects.link(cam)
    look_at(cam, (0, 0, 0.12 * (framing - 1)))
    scene.camera = cam


# ---------------------------------------------------------------------------
# Materials


def set_ramp(node, stops):
    elements = node.color_ramp.elements
    while len(elements) > 1:
        elements.remove(elements[-1])
    elements[0].position, elements[0].color = stops[0]
    for position, color in stops[1:]:
        element = elements.new(position)
        element.color = color


def gel_material(palette):
    """Self-lit gel body: vertical gradient (glow at the bottom), frosted fresnel rim."""
    rim, core, deep, glow = (linear(c) for c in palette)
    material = bpy.data.materials.new("Gel")
    material.use_nodes = True
    nodes, links = material.node_tree.nodes, material.node_tree.links
    bsdf = nodes["Principled BSDF"]

    coords = nodes.new("ShaderNodeTexCoord")
    separate = nodes.new("ShaderNodeSeparateXYZ")
    height = nodes.new("ShaderNodeMapRange")
    height.inputs["From Min"].default_value = -1
    height.inputs["From Max"].default_value = 1
    links.new(coords.outputs["Object"], separate.inputs["Vector"])
    links.new(separate.outputs["Z"], height.inputs["Value"])

    vertical = nodes.new("ShaderNodeValToRGB")
    set_ramp(vertical, [
        (0.0, glow),
        (0.12, tuple(0.6 * g + 0.4 * c for g, c in zip(glow, core))),
        (0.36, core),
        (0.7, deep),
        (1.0, deep),
    ])
    vertical.color_ramp.interpolation = "B_SPLINE"
    links.new(height.outputs["Result"], vertical.inputs["Fac"])

    layer = nodes.new("ShaderNodeLayerWeight")
    layer.inputs["Blend"].default_value = 0.5
    rim_curve = nodes.new("ShaderNodeValToRGB")
    set_ramp(rim_curve, [
        (0.0, (0.1, 0.1, 0.1, 1)),
        (0.36, (0, 0, 0, 1)),
        (0.66, (0.32, 0.32, 0.32, 1)),
        (0.9, (0.72, 0.72, 0.72, 1)),
        (1.0, (0.95, 0.95, 0.95, 1)),
    ])
    rim_curve.color_ramp.interpolation = "EASE"
    links.new(layer.outputs["Facing"], rim_curve.inputs["Fac"])
    rim_mix = nodes.new("ShaderNodeMix")
    rim_mix.data_type = "RGBA"
    rim_mix.inputs["B"].default_value = rim
    links.new(rim_curve.outputs["Color"], rim_mix.inputs["Factor"])
    links.new(vertical.outputs["Color"], rim_mix.inputs["A"])

    dim = nodes.new("ShaderNodeMix")
    dim.data_type = "RGBA"
    dim.blend_type = "MULTIPLY"
    dim.inputs["Factor"].default_value = 1.0
    dim.inputs["B"].default_value = (0.55, 0.55, 0.55, 1)
    links.new(vertical.outputs["Color"], dim.inputs["A"])
    links.new(dim.outputs["Result"], bsdf.inputs["Base Color"])
    links.new(rim_mix.outputs["Result"], bsdf.inputs["Emission Color"])
    bsdf.inputs["Emission Strength"].default_value = 1.05
    bsdf.inputs["Roughness"].default_value = 0.55
    bsdf.inputs["Specular IOR Level"].default_value = 0.04
    bsdf.inputs["Sheen Weight"].default_value = 0.08
    bsdf.inputs["Sheen Tint"].default_value = rim
    return material


def glow(hex_value=0xF0EEFF, strength=1.0):
    """Self-lit feature material (eyes, light mouths)."""
    material = bpy.data.materials.new("Glow")
    material.use_nodes = True
    bsdf = material.node_tree.nodes["Principled BSDF"]
    color = linear(hex_value)
    bsdf.inputs["Base Color"].default_value = color
    bsdf.inputs["Roughness"].default_value = 0.3
    bsdf.inputs["Emission Color"].default_value = color
    bsdf.inputs["Emission Strength"].default_value = strength
    return material


def plastic(hex_value, roughness=0.32, coat=0.6, emission=0.0, subsurface=0.15):
    material = bpy.data.materials.new("Plastic")
    material.use_nodes = True
    bsdf = material.node_tree.nodes["Principled BSDF"]
    color = linear(hex_value)
    bsdf.inputs["Base Color"].default_value = color
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Coat Weight"].default_value = coat
    bsdf.inputs["Coat Roughness"].default_value = 0.12
    bsdf.inputs["Subsurface Weight"].default_value = subsurface
    if emission:
        bsdf.inputs["Emission Color"].default_value = color
        bsdf.inputs["Emission Strength"].default_value = emission
    return material


def metal(hex_value, roughness=0.22):
    material = bpy.data.materials.new("Metal")
    material.use_nodes = True
    bsdf = material.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = linear(hex_value)
    bsdf.inputs["Metallic"].default_value = 1.0
    bsdf.inputs["Roughness"].default_value = roughness
    return material


def knit(hex_value):
    material = bpy.data.materials.new("Knit")
    material.use_nodes = True
    nodes, links = material.node_tree.nodes, material.node_tree.links
    bsdf = nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = linear(hex_value)
    bsdf.inputs["Roughness"].default_value = 0.9
    bsdf.inputs["Sheen Weight"].default_value = 0.7
    bsdf.inputs["Emission Color"].default_value = linear(hex_value)
    bsdf.inputs["Emission Strength"].default_value = 0.12
    # Rib texture via bump
    wave = nodes.new("ShaderNodeTexWave")
    wave.wave_type = "BANDS"
    wave.bands_direction = "X"
    wave.inputs["Scale"].default_value = 28
    bump = nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.35
    links.new(wave.outputs["Fac"], bump.inputs["Height"])
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return material


def glass(tint=0xFFFFFF, darkness=0.0):
    material = bpy.data.materials.new("Glass")
    material.use_nodes = True
    bsdf = material.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = linear(tint)
    bsdf.inputs["Roughness"].default_value = 0.04
    bsdf.inputs["Transmission Weight"].default_value = 1.0 - darkness
    bsdf.inputs["IOR"].default_value = 1.45
    bsdf.inputs["Coat Weight"].default_value = 1.0
    if darkness:
        bsdf.inputs["Base Color"].default_value = linear(0x101016)
    return material


def striped(hex_a, hex_b, scale=9.0):
    """Two-color bands along the object's Z (party hats, candy)."""
    material = bpy.data.materials.new("Stripes")
    material.use_nodes = True
    nodes, links = material.node_tree.nodes, material.node_tree.links
    bsdf = nodes["Principled BSDF"]
    coords = nodes.new("ShaderNodeTexCoord")
    separate = nodes.new("ShaderNodeSeparateXYZ")
    math_node = nodes.new("ShaderNodeMath")
    math_node.operation = "MULTIPLY"
    math_node.inputs[1].default_value = scale
    frac = nodes.new("ShaderNodeMath")
    frac.operation = "FRACT"
    step = nodes.new("ShaderNodeMath")
    step.operation = "GREATER_THAN"
    step.inputs[1].default_value = 0.5
    mix = nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.inputs["A"].default_value = linear(hex_a)
    mix.inputs["B"].default_value = linear(hex_b)
    links.new(coords.outputs["Object"], separate.inputs["Vector"])
    links.new(separate.outputs["Z"], math_node.inputs[0])
    links.new(math_node.outputs[0], frac.inputs[0])
    links.new(frac.outputs[0], step.inputs[0])
    links.new(step.outputs[0], mix.inputs["Factor"])
    links.new(mix.outputs["Result"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.35
    bsdf.inputs["Coat Weight"].default_value = 0.6
    return material


# ---------------------------------------------------------------------------
# Geometry


def orb_body(material):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=128, ring_count=64, radius=1)
    orb = bpy.context.active_object
    orb.name = "Orb"
    orb.scale = (1.0, 0.98, 0.97)
    bpy.ops.object.shade_smooth()
    orb.data.materials.append(material)
    return orb


def surface(orb, x, z):
    """Point and normal on the orb front at face-space (x, z)."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = orb.evaluated_get(depsgraph)
    inverse = orb.matrix_world.inverted()
    hit, location, normal, _ = evaluated.ray_cast(inverse @ Vector((x, -5, z)), Vector((0, 1, 0)))
    if not hit:
        return Vector((x, -0.5, z)), Vector((0, -1, 0))
    return orb.matrix_world @ location, (orb.matrix_world.to_3x3() @ normal).normalized()


def frame_on(normal):
    """Rotation whose Z follows `normal` and whose Y stays as upright as possible."""
    up = Vector((0, 0, 1))
    y_axis = (up - normal * up.dot(normal))
    if y_axis.length < 1e-6:
        y_axis = Vector((0, 1, 0))
    y_axis.normalize()
    x_axis = y_axis.cross(normal).normalized()
    return Matrix((x_axis, y_axis, normal)).transposed()


def on_surface(obj, orb, x, z, sink=0.0, face_viewer=0.25, roll=0.0):
    location, normal = surface(orb, x, z)
    obj.location = location - normal * sink
    facing = (normal * (1 - face_viewer) + Vector((0, -1, 0)) * face_viewer).normalized()
    rotation = frame_on(facing)
    if roll:
        rotation = rotation @ Matrix.Rotation(roll, 3, "Z")
    obj.rotation_euler = rotation.to_euler()


def smooth_last(material):
    obj = bpy.context.active_object
    bpy.ops.object.shade_smooth()
    obj.data.materials.append(material)
    return obj


def sphere(radius, location, material, scale=(1, 1, 1), segments=48):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=segments // 2, radius=radius, location=location)
    obj = smooth_last(material)
    obj.scale = scale
    return obj


def dome(radius, z_cut, location, material, scale=(1, 1, 1)):
    """Upper part of a sphere above local z_cut (caps, beanies)."""
    import bmesh
    bpy.ops.mesh.primitive_uv_sphere_add(segments=96, ring_count=48, radius=radius, location=location)
    obj = bpy.context.active_object
    mesh = bmesh.new()
    mesh.from_mesh(obj.data)
    bmesh.ops.delete(mesh, geom=[v for v in mesh.verts if v.co.z < z_cut], context="VERTS")
    mesh.to_mesh(obj.data)
    mesh.free()
    obj.scale = scale
    solidify = obj.modifiers.new("Solidify", "SOLIDIFY")
    solidify.thickness = 0.03
    return smooth_last(material)


def capsule(radius, half_length, depth, material, segments=48):
    """Pill lying in the local XY plane (long axis Y), flattened along Z (the surface normal)."""
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=segments // 2, radius=radius)
    obj = bpy.context.active_object
    for vertex in obj.data.vertices:
        if abs(vertex.co.z) > 1e-6:
            vertex.co.z += half_length if vertex.co.z > 0 else -half_length
    obj.rotation_euler = (math.pi / 2, 0, 0)
    bpy.ops.object.transform_apply(rotation=True)
    obj.scale = (1, 1, depth / radius)
    return smooth_last(material)


def torus(major, minor, location, material, rotation=(0, 0, 0)):
    bpy.ops.mesh.primitive_torus_add(major_radius=major, minor_radius=minor, major_segments=96, minor_segments=24,
                                     location=location, rotation=rotation)
    return smooth_last(material)


def cone(radius1, radius2, depth, location, material, rotation=(0, 0, 0), vertices=64):
    bpy.ops.mesh.primitive_cone_add(vertices=vertices, radius1=radius1, radius2=radius2, depth=depth,
                                    location=location, rotation=rotation)
    obj = smooth_last(material)
    obj.modifiers.new("Bevel", "BEVEL").width = min(radius1, depth) * 0.08
    return obj


def cylinder(radius, depth, location, material, rotation=(0, 0, 0)):
    bpy.ops.mesh.primitive_cylinder_add(vertices=64, radius=radius, depth=depth, location=location, rotation=rotation)
    obj = smooth_last(material)
    bevel = obj.modifiers.new("Bevel", "BEVEL")
    bevel.width = min(radius, depth) * 0.2
    bevel.segments = 6
    return obj


def tube(points, radii, material, bevel=0.02, orb=None, lift=0.0, resolution=24):
    """Tapered bezier tube. With `orb`, points are face-space (x, z) projected onto the surface."""
    curve = bpy.data.curves.new("Tube", "CURVE")
    curve.dimensions = "3D"
    curve.bevel_depth = bevel
    curve.bevel_resolution = 10
    curve.resolution_u = resolution
    curve.use_fill_caps = True
    spline = curve.splines.new("BEZIER")
    spline.bezier_points.add(len(points) - 1)
    for bp, point, radius in zip(spline.bezier_points, points, radii):
        if orb is not None:
            location, normal = surface(orb, point[0], point[1])
            bp.co = location + normal * lift
        else:
            bp.co = Vector(point)
        bp.radius = radius
        bp.handle_left_type = bp.handle_right_type = "AUTO"
    obj = bpy.data.objects.new("Tube", curve)
    bpy.context.scene.collection.objects.link(obj)
    obj.data.materials.append(material)
    return obj


def flat_shape(points, material, extrude=0.012, bevel=0.004):
    """Filled 2D outline in the local XY plane (stars, hearts, open mouths)."""
    curve = bpy.data.curves.new("Shape", "CURVE")
    curve.dimensions = "2D"
    curve.fill_mode = "BOTH"
    curve.extrude = extrude
    curve.bevel_depth = bevel
    curve.bevel_resolution = 4
    spline = curve.splines.new("POLY")
    spline.points.add(len(points) - 1)
    for point, (x, y) in zip(spline.points, points):
        point.co = (x, y, 0, 1)
    spline.use_cyclic_u = True
    obj = bpy.data.objects.new("Shape", curve)
    bpy.context.scene.collection.objects.link(obj)
    obj.data.materials.append(material)
    return obj


def star_points(outer, inner, count=5, rotation=math.pi / 2):
    points = []
    for i in range(count * 2):
        radius = outer if i % 2 == 0 else inner
        angle = rotation + math.pi * i / count
        points.append((radius * math.cos(angle), radius * math.sin(angle)))
    return points


def heart_points(size, steps=64):
    points = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        x = 16 * math.sin(t) ** 3
        y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        points.append((x * size / 16, y * size / 16))
    return points


# ---------------------------------------------------------------------------
# Output


def load_rgba(path):
    image = bpy.data.images.load(path)
    width, height = image.size
    return np.array(image.pixels[:], dtype=np.float32).reshape(height, width, 4)


def save_rgba(path, rgba):
    height, width = rgba.shape[:2]
    image = bpy.data.images.new("out", width, height, alpha=True)
    image.pixels = rgba.ravel()
    image.filepath_raw = path
    image.file_format = "PNG"
    image.save()


def composite(rgba, glow_hex, background):
    """Over a flat background with the colored pool of light under the orb."""
    height, width = rgba.shape[:2]
    ys, xs = np.mgrid[0:height, 0:width]
    dx = (xs / width - 0.5) / 0.2
    dy = (ys / height - 0.25) / 0.055
    falloff = (np.exp(-(dx * dx + dy * dy) * 1.6) * 0.7)[..., None]
    rgb = np.array([((glow_hex >> s) & 0xFF) / 255 for s in (16, 8, 0)], dtype=np.float32)
    bg = np.ones((height, width, 3), dtype=np.float32) * np.array(background, dtype=np.float32)
    if np.mean(background) > 0.5:
        bg = bg * (1 - falloff * 0.55) + rgb * falloff * 0.55
    else:
        bg = bg + rgb * falloff * 0.45
    alpha = rgba[..., 3:4]
    out = rgba[..., :3] * alpha + bg * (1 - alpha)
    return np.concatenate([np.clip(out, 0, 1), np.ones_like(alpha)], axis=2)
