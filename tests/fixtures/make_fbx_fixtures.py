"""Generates the skinned / blend-shape FBX fixtures in tests/fixtures/valid/.

    /Applications/Blender.app/Contents/MacOS/Blender -b --python tests/fixtures/make_fbx_fixtures.py

Written for Peek3D and released under CC0 1.0 (public domain), like the
files it makes. Needs Blender 4+; written against 5.2.

  skinned_bend.fbx   a 3 m tall tube (13 rings) with a
                     3-bone chain. The root bone never moves; the two child
                     bones bend the cylinder sideways (rotation about X) over a
                     48-frame clip. Only deformation can change the silhouette.
  morph_cube.fbx     a subdivided cube with one shape key ("Stretch") whose
                     value animates 0 -> 1 -> 0. Only the morph target can
                     change the silhouette: no node ever moves.
"""
import math
import os

import bpy
from mathutils import Vector

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "valid")
FPS = 24


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    scn.render.fps = FPS
    scn.frame_start = 1
    scn.frame_end = 49


def export(name):
    bpy.ops.export_scene.fbx(
        filepath=os.path.join(OUT, name),
        use_selection=False,
        object_types={"MESH", "ARMATURE"},
        add_leaf_bones=False,
        bake_anim=True,
        bake_anim_use_all_bones=True,
        bake_anim_use_nla_strips=False,
        bake_anim_use_all_actions=False,
        bake_anim_force_startend_keying=True,
        bake_anim_simplify_factor=0.0,
        mesh_smooth_type="FACE",
        embed_textures=False,
        path_mode="STRIP",
    )


def skinned_bend():
    reset()
    # Tube along +Z from 0 to 3: 13 rings x 12 sides, capped. Built by hand so
    # the mesh stays light (a bend needs rings, not a dense grid) and the
    # wireframe stays readable.
    sides, rings, radius, height = 12, 13, 0.4, 3.0
    verts = [(radius * math.cos(2 * math.pi * i / sides), radius * math.sin(2 * math.pi * i / sides),
              height * r / (rings - 1)) for r in range(rings) for i in range(sides)]
    faces = [(r * sides + i, r * sides + (i + 1) % sides, (r + 1) * sides + (i + 1) % sides, (r + 1) * sides + i)
             for r in range(rings - 1) for i in range(sides)]
    faces.append(tuple(reversed(range(sides))))                                  # bottom cap
    faces.append(tuple(range((rings - 1) * sides, rings * sides)))               # top cap
    mesh = bpy.data.meshes.new("Tube")
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    mesh_obj = bpy.data.objects.new("Tube", mesh)
    bpy.context.collection.objects.link(mesh_obj)
    bpy.context.view_layer.objects.active = mesh_obj
    bpy.ops.object.shade_smooth()

    bpy.ops.object.armature_add(location=(0, 0, 0))
    arm_obj = bpy.context.active_object
    arm_obj.name = "Rig"
    arm = arm_obj.data
    bpy.ops.object.mode_set(mode="EDIT")
    root = arm.edit_bones[0]
    root.name = "Root"
    root.head, root.tail = Vector((0, 0, 0)), Vector((0, 0, 1))
    mid = arm.edit_bones.new("Mid")
    mid.head, mid.tail, mid.parent, mid.use_connect = Vector((0, 0, 1)), Vector((0, 0, 2)), root, True
    top = arm.edit_bones.new("Top")
    top.head, top.tail, top.parent, top.use_connect = Vector((0, 0, 2)), Vector((0, 0, 3)), mid, True
    bpy.ops.object.mode_set(mode="OBJECT")

    mesh_obj.select_set(True)
    arm_obj.select_set(True)
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")

    # Bend: Root stays still; Mid and Top rotate about X. Key at 1, 25, 49.
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="POSE")
    for bone, angle in (("Mid", 50.0), ("Top", 50.0)):
        pb = arm_obj.pose.bones[bone]
        pb.rotation_mode = "XYZ"
        pb.rotation_euler = (0, 0, 0)
        pb.keyframe_insert("rotation_euler", frame=1)
        pb.rotation_euler = (math.radians(angle), 0, 0)
        pb.keyframe_insert("rotation_euler", frame=25)
        pb.rotation_euler = (0, 0, 0)
        pb.keyframe_insert("rotation_euler", frame=49)
    pb = arm_obj.pose.bones["Root"]
    pb.rotation_mode = "XYZ"
    pb.keyframe_insert("rotation_euler", frame=1)  # constant key: the root provably never moves
    pb.keyframe_insert("rotation_euler", frame=49)
    bpy.ops.object.mode_set(mode="OBJECT")
    export("skinned_bend.fbx")


def morph_cube():
    reset()
    bpy.ops.mesh.primitive_cube_add(size=2.0, location=(0, 0, 1))
    obj = bpy.context.active_object
    obj.name = "MorphCube"
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.subdivide(number_cuts=3)
    bpy.ops.object.mode_set(mode="OBJECT")
    obj.shape_key_add(name="Basis", from_mix=False)
    key = obj.shape_key_add(name="Stretch", from_mix=False)
    # Stretch the top half upward and thin it: clearly different silhouette.
    for i, v in enumerate(obj.data.vertices):
        if v.co.z > 0.0:
            key.data[i].co = Vector((v.co.x * 0.4, v.co.y * 0.4, v.co.z + 1.5))
    key.value = 0.0
    key.keyframe_insert("value", frame=1)
    key.value = 1.0
    key.keyframe_insert("value", frame=25)
    key.value = 0.0
    key.keyframe_insert("value", frame=49)
    export("morph_cube.fbx")


os.makedirs(OUT, exist_ok=True)
skinned_bend()
morph_cube()
print("FIXTURES_DONE", OUT)
