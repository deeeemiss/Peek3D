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

`valid/Box-Draco.glb` and `valid/RiggedSimple-Draco.glb`: the `glTF-Draco`
variants of Box and RiggedSimple from the Khronos
[glTF Sample Assets](https://github.com/KhronosGroup/glTF-Sample-Assets),
© 2017 Cesium, CC BY 4.0, with the `.gltf` and `.bin` packed into one `.glb`
(the Draco data and the JSON are untouched; only the buffer URI is gone).
They have the same triangle and vertex counts as the uncompressed originals;
RiggedSimple also puts its skin joints and weights through Draco.
`scripts/test.py` renders both and checks they show up.

`valid/ktx2_cube.glb`: a cube whose two halves use `KHR_texture_basisu`
textures, one of each Basis Universal flavour: UASTC with Zstd
(`carbonfiber_normal.ktx2`, 256×256) and ETC1S / BasisLZ
(`band_occlusion.ktx2`, 2048×2048). Both textures come from the glTF Sample
Asset ChronographWatch: "Asset © 2025 Darmstadt Graphics Group GmbH, CC BY 4.0
International, adapted by Eric Chadwick. Original asset Chronograph Watch
Mudmaster (https://skfb.ly/oAsPA) by graphiccompressor, licensed under
Creative Commons Attribution", CC BY 4.0. The cube is made for Peek3D (CC0 1.0)
by `make_ktx2_fixture.py`, which takes the two `.ktx2` files as arguments.
Because the textures are CC BY 4.0, so is the file as a whole. `scripts/test.py`
renders it and checks the textures are visible, neither black nor magenta.
(The same asset has Khronos and DGG logos in other textures; those are
deliberately not used.)

`invalid/*Draco*` and `invalid/ktx2_cube-*`: made by
`make_invalid_fixtures.py` from the three files above (same licenses). Draco
streams damaged on purpose (`stream-truncated`, `stream-magic`,
`stream-garbage`) and an attribute id the stream doesn't have must be refused
by the decoder; `indices-removed`, `mode-strip` and `attribute-not-compressed`
are glTF structures the validator must refuse; `ktx2_cube-textures-basisu-source-crash`
named a missing image from `KHR_texture_basisu` and crashed GLTFKit2 before the
validator checked it.

`valid/skinned_bend.fbx` and `valid/morph_cube.fbx`: made for Peek3D by
`make_fbx_fixtures.py` (run it with Blender in background mode to regenerate),
CC0 1.0. A skinned tube whose child bones bend it while the root bone stays
still, and a cube with an animated shape key. `scripts/test.py` renders both
and checks that the mesh really deforms.
