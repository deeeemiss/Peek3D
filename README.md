<div align="center">

# Peek3D

**Drop a 3D file. Look at it.**

A tiny, native macOS viewer — no editing, no export, no format conversion.
Free and open source.

[![macOS](https://img.shields.io/badge/macOS-13%2B-blue?style=flat-square)]()
[![Swift](https://img.shields.io/badge/Swift-SwiftUI%20%2B%20SceneKit-orange?style=flat-square)]()
[![glTF](https://img.shields.io/badge/glTF-GLTFKit2-brightgreen?style=flat-square)](https://github.com/warrenm/GLTFKit2)
[![FBX](https://img.shields.io/badge/FBX-ufbx-9cf?style=flat-square)](https://github.com/ufbx/ufbx)
[![License: MIT](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE.md)

[Install](#install) · [Formats](#formats) · [Features](#features) · [Privacy](#privacy) · [Build](#build) · [Sandbox](#sandbox) · [Known limits](#known-limits)

</div>

![Peek3D screenshot](assets/screenshot.png)

![Peek3D demo](assets/demo.gif)

---

## Install

```sh
brew install --cask deeeemiss/tap/peek3d
```

Or download the DMG from [Releases](https://github.com/deeeemiss/Peek3D/releases/latest).
Signed with a Developer ID and notarized by Apple. Requires macOS 13 or later.

## Formats

| Loader | Formats | Animation |
|--------|---------|-----------|
| [GLTFKit2](https://github.com/warrenm/GLTFKit2) (SPM) | `.glb` `.gltf` | Skeletal (skinned) + node-transform |
| [ufbx](https://github.com/ufbx/ufbx) (vendored) | `.fbx` | Node-transform (rigid/hierarchical) |
| Apple Model I/O | `.obj` `.stl` `.usd` `.usdz` `.usda` `.usdc` `.dae` `.ply` `.abc` | — |

All three converge into one `SCNScene`, so the viewer, wireframe, shading
modes, and stats never need to know where a model came from.

## Features

### Viewing
- Drag & drop (empty state **and** to replace a loaded model), or file picker
- Camera orbit / pan / zoom, fit-to-view
- Colored XYZ axis gizmo (bottom-right), click an axis to snap the camera
- Fullscreen toggle
- Viewport screenshot → PNG

### Shading
- **Default** — the file's own materials/textures
- **Normals** — color-coded view-space normals
- **Matcap** — procedural matcap by view-space normal
- **Unlit** — base colour only, no lighting
- **UV checker** — procedural checkerboard on the real UVs
- Wireframe overlay, readable in every shading mode above

### Lighting
- **Default** / **Studio** / **Outdoor** / **Dark mood** presets

### Animation
- Timeline with play / pause and clip selection for animated `.glb`/`.gltf`
  (skinned) and `.fbx` (node-transform) models
- Wireframe stays correct while an animation plays

### Info
- Triangles, vertices, meshes, materials, bounding-box size, file size, file name

### Localization
- English (primary) and Italian, via a native Xcode String Catalog — follows
  the per-app language set in macOS System Settings → General → Language &
  Region. More languages (incl. non-Latin scripts) planned.

## Privacy

Peek3D makes no network connections and collects no data. Files you open
are read locally and never leave your Mac.

## Build

Requires Xcode 16+ (developed on 26.6), macOS 13+.

```sh
xcodebuild -scheme Peek3D -project Peek3D.xcodeproj \
  -destination 'platform=macOS' build
```

Or just open `Peek3D.xcodeproj` in Xcode and hit Run.

## Sandbox

The app runs sandboxed with the **User Selected File (Read Only)** entitlement.
Files opened via drag & drop or the file picker get security-scoped access
automatically; arbitrary paths are (by design) denied. External textures
referenced by an `.fbx`/`.gltf` file (not embedded) need that access too — the
app prompts for folder access and retries automatically if it's missing.

## Known limits

- Draco-compressed geometry and KTX2/BasisU textures are **not** wired up.
  A `.glb` using them surfaces a load error rather than a silent failure.
- FBX skinned/skeletal **deformation** (`SCNSkinner`) and blend shapes are
  not supported yet — a skinned FBX loads and shows its bind pose; bones still
  receive their transform animation, but the mesh doesn't deform.
- Timeline drag-to-seek isn't offered (for either format): both loaders bake
  clips as looping `CAAnimationGroup`s on a wall-clock player, which has no
  API for jumping to an arbitrary time. Play / pause / clip selection work
  fully; the bar is a synchronized progress readout, not a scrubber.

## License

[MIT](LICENSE.md). Third-party attributions are listed in the same file and
in the app (Peek3D ▸ Open Source Licenses…).
