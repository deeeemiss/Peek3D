# Changelog

All notable changes to Peek3D are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## 1.1 — 2026-10-02

Bug-fix release from a full debugging pass of the app.

### Fixed
- Malformed glTF/GLB files (broken buffers, accessors, skins, animation
  ranges) could crash or hang the app; they now show an error. Empty or
  non-3D files say so instead of showing a blank window.
- Absurdly deep node hierarchies no longer crash the app.
- External files: a .gltf with a separate .bin, or an .obj with its .mtl
  and textures, now offers "Grant folder access" like FBX did; textures
  that don't exist are no longer blamed on folder permissions.
- Untranslated messages, plurals (Russian, Arabic…), numbers, sizes and
  durations now follow the app language and region.
- VoiceOver: labeled toolbar, viewport, gizmo and timeline; load results
  and banners are announced. The six gizmo views are in Scene ▸ Views
  (⌃⌘1…6); ⌘+ / ⌘− zoom.
- Readable overlays and banners over light models (WCAG AA), Esc closes
  banners; Reduce Motion, Reduce Transparency and Increase Contrast are
  honored.
- ⌘T from Settings no longer tabs a Welcome screen into Settings.
- FBX: correct vertex and mesh counts; instanced meshes load several times
  faster with a fraction of the memory.
- Smoother playback: the timeline no longer redraws the whole window 60
  times a second.
- Error and folder-access notices no longer cover the model info panel.
- Smaller fixes: duplicate Fullscreen command removed, zoom limits, Welcome
  fits 900 pt screens, file type names localized in Finder.

## 1.0 — 2026-10-02 (first public release)

### Added
- Peek3D is free and open source under the MIT license. It makes no network
  connections and collects no data.

### Fixed
- Welcome window wasn't actually resizable in height (`.windowResizability`
  derived resizability from Welcome's content, which had no flexible element).
- Welcome window's black background didn't cover the full window on larger
  sizes.
- Wireframe toggle could leave a skinned/animated model invisible or
  restore it to solid white instead of its real materials.
- "0×0×0" dimensions shown for small, metric-scale models (e.g. Avocado.glb).
- Scene menu commands (Wireframe, Shading, etc.) applied to every open
  document window instead of only the focused one.
- Load race: dropping a second file while the first was still decoding could
  let a slower completion handler overwrite the more recent one.

### Added
- Hover feedback on the axis gizmo's dots (slight scale-up + pointer cursor),
  scoped to the dots rather than the whole gizmo hit area.
- `ModeMenuItems`, a shared generic view for the Shading/Lighting
  icon+checkmark lists, used by both the toolbar and the Scene menu.

### Changed
- Migrated from `WindowGroup` to `DocumentGroup(viewing:)` — enables
  Open Recent, Finder "Open With", and Dock drop; added a custom Welcome
  window since a read-only viewer has no "untitled document" state.

## 0.9 — first native build (private)

### Added
- Native macOS viewer (SwiftUI + SceneKit) for `.glb`/`.gltf` via GLTFKit2,
  and `.obj`/`.stl`/`.usd`/`.usdz`/`.usda`/`.usdc`/`.dae`/`.ply`/`.abc` via
  Model I/O.
- Camera orbit/pan/zoom, fit-to-view, colored XYZ axis gizmo with
  click-to-snap.
- Shading modes: Default, Normals, Matcap, Unlit, UV checker; wireframe
  overlay on top of any mode.
- Lighting presets: Default, Studio, Outdoor, Dark mood.
- Animation timeline (play/pause, clip selection) for glTF skinned
  animations.
- Model info panel: triangles, vertices, meshes, materials, bounding box,
  file size.
- Viewport screenshot export.
- FBX support via vendored [ufbx](https://github.com/ufbx/ufbx):
  static geometry, then node-transform (rigid/hierarchical) animation.
- English/Italian localization via a native Xcode String Catalog.

