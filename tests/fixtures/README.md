# Test fixtures

Used by `scripts/test.py`, which expects:

- **`valid/`** (and everything in `../../testmodels/`): must open.
- **`invalid/`**: must fail with a normal error, not crash or hang.

## Where they come from

`valid/SimpleSparseAccessor.gltf` + `.bin`: from the Khronos
[glTF Sample Assets](https://github.com/KhronosGroup/glTF-Sample-Assets), by
Marco Hutter, CC BY 4.0. Covers sparse accessors and an external buffer.

`invalid/`: files that crashed or hung Peek3D before its glTF validator
existed, found by fuzzing. Each one is a sample model from `testmodels/` with a
single number in its JSON changed; the file name says which source, which
field, and whether it crashed or hung. They inherit the source model's license
and credit (see `../../testmodels/README.md`):

| Prefix | Source | License |
|--------|--------|---------|
| `Box-` | Box.glb, Cesium | CC BY 4.0 |
| `BoxAnimated-` | BoxAnimated.glb, Cesium | CC BY 4.0 |
| `Fox-` | Fox.glb, PixelMannen / @tomkranis / @AsoboStudio / @scurest | CC BY 4.0 |

`Box-nodes-depth10000-crash.glb` nests Box 10 000 nodes deep, past what
SceneKit can handle. `garbage.glb` (random bytes) and `empty.glb` are made for
Peek3D and covered by the project's MIT license.

`valid/skinned_bend.fbx` and `valid/morph_cube.fbx`: made for Peek3D by
`make_fbx_fixtures.py` (run it with Blender in background mode to regenerate),
CC0 1.0. A skinned tube whose child bones bend it while the root bone stays
still, and a cube with an animated shape key. `scripts/test.py` renders both
and checks that the mesh really deforms.
