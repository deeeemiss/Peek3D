# Changelog

All notable changes to Peek3D are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- Peek3D is now a paid app. A free trial covers **10 distinct file opens**
  (reopening an already-seen file is always free); after that, opening a
  new file requires a **one-time €19.99 license** (updates included
  forever, no subscription), with discounted 2- and 3-license packs for
  multiple Macs and a 14-day refund window. License keys are signed and
  verified **offline**; the app then re-verifies online periodically and
  tolerates up to **30 days** without a successful check before requiring
  reconnection. One license activates one Mac, with self-service seat
  release for hardware changes. See `docs/FAQ.en.md` / `docs/FAQ.it.md` for
  the license FAQ and `docs/PRIVACY.en.md` / `docs/PRIVACY.it.md` for what
  activation data is stored and why.

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

## 1.0 — first native build

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

