"""Convert local Xcode V68 artwork to GLB using Blender's Python module."""
import sys

import bpy

source, output = sys.argv[1:]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.usd_import(
    filepath=source,
    import_skeletons=True,
    import_usd_preview=True,
    import_textures_mode="IMPORT_PACK",
)
scene = bpy.context.scene
scene.frame_start = 0
scene.frame_end = 120
for action in bpy.data.actions:
    action.use_frame_range = True
    action.frame_start = 0
    action.frame_end = 120
bpy.ops.export_scene.gltf(
    filepath=output,
    export_format="GLB",
    export_animations=True,
    export_frame_range=True,
    export_nla_strips=False,
    export_cameras=False,
    export_lights=False,
    export_yup=True,
)
