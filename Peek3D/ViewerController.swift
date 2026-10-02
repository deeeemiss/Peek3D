import SwiftUI
import SceneKit
import AppKit
import simd

/// Bridge between the SwiftUI toolbar and the real `SCNView`. Buttons talk to
/// this object, never to SceneKit directly.
final class ViewerController: ObservableObject {
    weak var scnView: SCNView?

    @Published var isWireframe = false
    @Published var isGridVisible = UserDefaults.standard.bool(forKey: SettingsKey.showGrid)

    /// Active lighting/environment preset. Persists across model swaps and is
    /// re-applied to each newly attached scene (see `attach` / `applyLighting`).
    @Published private(set) var lightingPreset: LightingPreset =
        UserDefaults.standard.string(forKey: SettingsKey.lightingPreset).flatMap(LightingPreset.init) ?? .standard

    /// Active shading (material) mode. Like the lighting preset it persists across
    /// model swaps and is re-applied to each newly attached scene (see `attach` /
    /// `applyShadingMode`). Orthogonal to `isWireframe` and `lightingPreset`.
    @Published private(set) var shadingMode: ShadingMode =
        UserDefaults.standard.string(forKey: SettingsKey.shadingMode).flatMap(ShadingMode.init) ?? .standard

    // MARK: - Animation state (see the Animation section below)

    /// Clips available on the current model; empty for static models — the
    /// timeline UI keys its entire visibility off `hasAnimations`.
    @Published private(set) var animations: [ModelAnimation] = []
    @Published private(set) var currentAnimationIndex: Int = 0
    @Published private(set) var isPlaying: Bool = false
    /// Playhead position, in seconds, of the active clip. Advanced by a timer in
    /// lockstep with the wall-clock player; drives the progress bar readout.
    @Published private(set) var animationTime: TimeInterval = 0
    @Published private(set) var animationDuration: TimeInterval = 0

    var hasAnimations: Bool { !animations.isEmpty }

    /// Base name of the currently loaded model (no extension), used to name
    /// the screenshot file. Set by `ContentView` after a successful load.
    var currentModelName = "Peek3D"

    private var gridNode: SCNNode?
    private var cameraNode: SCNNode?
    private var currentBounds: SceneBounds?
    /// The model's own top-level nodes, captured before camera/grid are added,
    /// so wireframe can be scoped to just the model (see `applyWireframe`).
    private var modelNodes: [SCNNode] = []

    /// Every geometry reachable from `modelNodes`, paired with its ORIGINAL
    /// materials array, captured in `attach` (before camera/grid). A shading mode
    /// replaces a geometry's `materials`; the `standard` mode reassigns the saved
    /// originals to restore the file's real look EXACTLY. Deduped by geometry
    /// identity so instanced meshes are handled once. Never mutated here (unlit
    /// clones; other modes build fresh), so the snapshot stays authoritative.
    private var capturedGeometries: [(geometry: SCNGeometry, originalMaterials: [SCNMaterial])] = []

    /// Container holding the current preset's procedural lights. Torn down and
    /// rebuilt on every preset change and every model load, so lights authored
    /// by one preset/model never leak into the next.
    private var presetLightsNode: SCNNode?
    /// Lights authored by the loaded file (e.g. glTF KHR_lights_punctual),
    /// captured in `attach` like `modelNodes`. Non-Default presets switch these
    /// off (`node.light = nil`) so only the preset rig lights the model; Default
    /// restores them. Storing the `SCNLight` lets us toggle just the light
    /// contribution without hiding the node's geometry subtree.
    private var fileLights: [(node: SCNNode, light: SCNLight)] = []

    private let activeAnimationKey = "peek3d.activeAnimation"
    private var activePlayer: SCNAnimationPlayer?
    private var playbackTimer: Timer?
    private var lastTick: CFTimeInterval = 0

    deinit { stopTimer() }

    // MARK: - Attach

    func attach(scnView: SCNView, scene: SCNScene, animations: [ModelAnimation]) {
        self.scnView = scnView
        scnView.scene = scene
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = (UserDefaults.standard.string(forKey: SettingsKey.background)
            .flatMap(SceneBackground.init) ?? .dark).color
        scnView.rendersContinuously = true

        modelNodes = scene.rootNode.childNodes

        // Snapshot each model geometry's original materials before camera/grid are
        // added, so shading modes can override and `standard` can restore exactly.
        captureOriginalMaterials()

        // Capture file-authored lights before camera/grid are added (same point
        // as `modelNodes`) so presets can switch them on/off. Discard the old
        // preset container reference here — it belonged to the previous scene.
        fileLights = []
        scene.rootNode.enumerateHierarchy { node, _ in
            if let light = node.light { fileLights.append((node, light)) }
        }
        presetLightsNode = nil

        let bounds = SceneBounds.compute(for: scene.rootNode)
        currentBounds = bounds

        setupCamera(in: scene, bounds: bounds)
        setupGrid(in: scene, bounds: bounds)

        // Re-establish the active shading mode on the new scene; this also
        // re-applies the wireframe fill mode on top of the resulting materials.
        applyShadingMode()
        applyLighting() // re-establish the active preset on the new scene
        fitToView(animated: false)

        configureAnimations(animations, in: scene)
    }

    // MARK: - Camera

    private let fieldOfView: Float = 50

    private func setupCamera(in scene: SCNScene, bounds: SceneBounds?) {
        let node = SCNNode()
        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(fieldOfView)
        camera.projectionDirection = .vertical
        node.camera = camera
        scene.rootNode.addChildNode(node)
        scnView?.pointOfView = node
        cameraNode = node
    }

    /// Frames the whole model. Uses the bounding sphere so extreme aspect
    /// ratios still fit inside the vertical field of view.
    func fitToView(animated: Bool = true) {
        guard let bounds = currentBoundsOrCompute else { return }
        applyCamera(solution: CameraFit.solve(bounds: bounds, fieldOfViewDegrees: fieldOfView), animated: animated)
    }

    /// Snaps the camera to look straight down one of the gizmo's axes (e.g.
    /// clicking the green +Y ball gives a top view), keeping the model framed.
    func snapToAxis(_ direction: simd_float3) {
        guard let bounds = currentBoundsOrCompute else { return }
        applyCamera(solution: CameraFit.solve(bounds: bounds, fieldOfViewDegrees: fieldOfView, direction: direction), animated: true)
    }

    private var currentBoundsOrCompute: SceneBounds? {
        currentBounds ?? SceneBounds.compute(for: scnView?.scene?.rootNode ?? SCNNode())
    }

    private func applyCamera(
        solution: (position: simd_float3, target: simd_float3, zNear: Double, zFar: Double),
        animated: Bool
    ) {
        // Move whatever camera is ACTUALLY on screen. The first time the user
        // orbits/pans/zooms with the mouse, `allowsCameraControl` switches
        // `pointOfView` to a camera node of its own, so moving `cameraNode`
        // from then on changed nothing: the gizmo views and Fit to view looked
        // dead after any manual orbit.
        guard let scnView, let pov = scnView.pointOfView ?? cameraNode, let camera = pov.camera else { return }
        // A flick-orbit keeps spinning the view on inertia; left running it
        // drifts the camera away from the framing set below.
        scnView.defaultCameraController.stopInertia()

        // Adapt clipping planes so tiny and huge models both render.
        camera.zNear = solution.zNear
        camera.zFar = solution.zFar

        let orientation = Self.lookOrientation(from: solution.position, to: solution.target)
        let apply = {
            pov.simdWorldPosition = solution.position
            pov.simdWorldOrientation = orientation
        }

        // `allowsCameraControl`'s built-in orbit controller keeps its own
        // cached transform state and — since we render continuously — can
        // silently overwrite a manual reposition on the very next frame,
        // making the button look like it does nothing. Disabling it around
        // the change forces a resync from the node's new transform. For the
        // animated path, `commit()` only *schedules* the animation — it does
        // not block until it finishes — so re-enabling right after commit()
        // re-syncs the orbit controller to the still-old presentation-layer
        // transform and freezes the camera there for the rest of the
        // animation. Re-enable inside the transaction's completion block
        // instead, once the new transform has actually landed.
        scnView.allowsCameraControl = false
        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.35
            SCNTransaction.completionBlock = { [weak scnView] in
                DispatchQueue.main.async {
                    scnView?.allowsCameraControl = true
                    // Re-enabling resumes any inertia the controller still
                    // held from the last flick, which would spin the view off
                    // the framing that just landed.
                    scnView?.defaultCameraController.stopInertia()
                    // Orbit around the model again, not around the pivot the
                    // user's last manual gesture left behind.
                    scnView?.defaultCameraController.target = SCNVector3(solution.target)
                }
            }
            apply()
            SCNTransaction.commit()
        } else {
            apply()
            scnView.allowsCameraControl = true
            scnView.defaultCameraController.stopInertia()
            scnView.defaultCameraController.target = SCNVector3(solution.target)
        }
    }

    /// Camera orientation looking from `eye` to `target`, built from an
    /// explicit basis rather than `SCNNode.look(at:)`. From the default
    /// front-facing camera, the back view is an exact 180° turn: `look(at:)`
    /// derives that rotation from two opposite vectors, which has no defined
    /// axis, and the camera ended up pointing nowhere — the -Z gizmo view
    /// showed an empty screen. World up is Y; for the top/bottom views, where
    /// Y is the viewing direction itself, -Z is used as screen-up instead.
    static func lookOrientation(from eye: simd_float3, to target: simd_float3) -> simd_quatf {
        let forward = simd_normalize(target - eye)
        let worldUp: simd_float3 = abs(simd_dot(forward, [0, 1, 0])) > 0.999 ? [0, 0, -1] : [0, 1, 0]
        let right = simd_normalize(simd_cross(forward, worldUp))
        let up = simd_cross(right, forward)
        // SceneKit cameras look down their local -Z axis.
        return simd_quatf(simd_float3x3(right, up, -forward))
    }

    func zoom(by factor: Float) {
        guard let scnView, let pov = scnView.pointOfView else { return }
        // Move along the camera's forward axis; scale step by model size.
        let step = (currentBounds?.radius ?? 1) * factor
        let destination = pov.simdWorldPosition + pov.simdWorldFront * step

        scnView.allowsCameraControl = false
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.18
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pov.simdWorldPosition = destination
        SCNTransaction.commit()
        scnView.allowsCameraControl = true
    }

    // MARK: - Grid

    private func setupGrid(in scene: SCNScene, bounds: SceneBounds?) {
        gridNode?.removeFromParentNode()
        let span = bounds.map { Swift.max($0.extents.x, $0.extents.z) } ?? 10
        let size = Swift.max(span * 2, 0.001)
        let grid = GridNodeFactory.makeGrid(size: size, divisions: 20)
        grid.name = "viewerGrid"
        if let bounds { grid.simdPosition = simd_float3(bounds.center.x, bounds.min.y, bounds.center.z) }
        grid.isHidden = !isGridVisible
        scene.rootNode.addChildNode(grid)
        gridNode = grid
    }

    func toggleGrid() {
        isGridVisible.toggle()
        gridNode?.isHidden = !isGridVisible
    }

    // MARK: - Wireframe

    func toggleWireframe() {
        isWireframe.toggle()
        applyWireframe()
    }

    /// Sets fill mode on the model's own materials only. Deliberately not
    /// `scnView.debugOptions = [.showWireframe]`: that overlay is view-wide
    /// and also hijacks the grid's `.line`-primitive geometry, changing its
    /// color depending on wireframe state (the bug this replaces).
    ///
    /// Reassigns fresh material COPIES rather than mutating `.fillMode` in
    /// place on the live materials. A skinned mesh's materials stay bound to
    /// an actively-updating GPU skinning pipeline while a clip plays; on a
    /// reported case (wireframe toggled on a playing animated model) the mesh
    /// went invisible, while the same toggle on a static model was fine.
    /// Mutating the live material's property could be caught mid-flight by
    /// that in-progress pipeline; handing SceneKit a genuinely new material
    /// object instead forces a clean (re)bind, matching how `applyShadingMode`
    /// already swaps in fresh materials rather than editing existing ones.
    private func applyWireframe() {
        let fillMode: SCNFillMode = isWireframe ? .lines : .fill
        // Rebuilds from `capturedGeometries`' saved originals (or the active
        // shading mode's factory output) every time, rather than restamping
        // whatever `geometry.materials` currently holds. Restamping the live
        // materials looked right going fill→lines, but going lines→fill it
        // copied the WIREFRAME material itself — still carrying the white
        // diffuse/emission/`.constant` lighting model applied below — so the
        // model came back solid white instead of its real colour/shading.
        // Always starting from the true base material makes ON→OFF an exact
        // restore regardless of how many times wireframe was toggled before.
        for entry in capturedGeometries {
            let base = (shadingMode == .standard)
                ? entry.originalMaterials
                : ShadingMaterialFactory.materials(for: shadingMode, original: entry.originalMaterials)
            entry.geometry.materials = base.map { material in
                    let copy = material.copy() as! SCNMaterial
                    copy.fillMode = fillMode
                    if fillMode == .lines {
                        // `.lines` still runs the material's own fragment shader
                        // modifier (normals/matcap fully replace the output colour
                        // from the interpolated surface normal), so the line
                        // pixels end up shaded almost like the surrounding
                        // fill instead of standing out — reads as near-invisible
                        // on a dark background. Force a flat, lighting-independent
                        // line colour so wireframe looks the same regardless of
                        // the active shading mode. `emission` is set alongside
                        // `diffuse`+`.constant`: it's ADDITIVE and ignores every
                        // lighting model / lighting-environment preset by
                        // definition, so the line stays bright even if some
                        // preset or PBR interaction dims the diffuse term.
                        copy.shaderModifiers = nil
                        copy.lightingModel = .constant
                        let lineColor = NSColor(calibratedWhite: 0.92, alpha: 1)
                        copy.diffuse.contents = lineColor
                        copy.emission.contents = lineColor
                    }
                    return copy
                }
            }
        }

    // MARK: - Shading

    func setShadingMode(_ mode: ShadingMode) {
        guard mode != shadingMode else { return }
        shadingMode = mode
        applyShadingMode()
    }

    /// Applies the active shading mode to the model's own geometries only.
    ///
    /// `standard` reassigns each geometry's SAVED original materials (an exact
    /// restore — the file's real look). Every other mode swaps in fresh override
    /// materials from `ShadingMaterialFactory`.
    ///
    /// Ends by calling `applyWireframe()`: overriding a geometry's `materials`
    /// discards the previous materials' `fillMode`, so the current wireframe state
    /// must be re-stamped onto whatever materials are now active. This is what
    /// makes wireframe and shading ORTHOGONAL in BOTH orders — toggling wireframe
    /// re-stamps over the shading materials (`toggleWireframe` → `applyWireframe`),
    /// and changing shading re-stamps the wireframe here. It touches only
    /// materials, never lights or animation players, so the lighting preset and
    /// any running clip are undisturbed.
    private func applyShadingMode() {
        for entry in capturedGeometries {
            entry.geometry.materials = (shadingMode == .standard)
                ? entry.originalMaterials
                : ShadingMaterialFactory.materials(for: shadingMode, original: entry.originalMaterials)
        }
        applyWireframe()
    }

    /// Snapshots the original materials of every geometry under `modelNodes`,
    /// deduped by geometry identity (instanced meshes appear once). Called from
    /// `attach` before any override is applied.
    private func captureOriginalMaterials() {
        capturedGeometries = []
        var seen = Set<ObjectIdentifier>()
        for node in modelNodes {
            node.enumerateHierarchy { child, _ in
                guard let geometry = child.geometry else { return }
                let id = ObjectIdentifier(geometry)
                guard seen.insert(id).inserted else { return }
                capturedGeometries.append((geometry, geometry.materials))
            }
        }
    }

    // MARK: - Lighting

    func setLightingPreset(_ preset: LightingPreset) {
        guard preset != lightingPreset else { return }
        lightingPreset = preset
        applyLighting()
    }

    /// Applies the active preset to the live scene.
    ///
    /// Policy — a non-Default preset SUBSTITUTES scene illumination: it turns off
    /// SceneKit's automatic light, switches off the file's own lights, and
    /// installs a dedicated `presetLights` container. The container is torn down
    /// and rebuilt on every change (and on each model load via `attach`), so
    /// lights never accumulate. Default puts the automatic light and file lights
    /// back and clears the lighting environment.
    ///
    /// Camera is never touched here, so this cannot fight `allowsCameraControl`;
    /// and it only adds/removes light nodes, so it never disturbs the animation
    /// players attached to `rootNode`.
    private func applyLighting() {
        guard let scnView, let scene = scnView.scene else { return }

        presetLightsNode?.removeFromParentNode()
        presetLightsNode = nil

        scnView.autoenablesDefaultLighting = lightingPreset.usesDefaultLighting
        setFileLightsEnabled(lightingPreset.usesDefaultLighting)

        presetLightsNode = LightingRig.apply(
            lightingPreset, to: scene,
            center: currentBounds?.center ?? .zero,
            radius: currentBounds?.radius ?? 1
        )
    }

    private func setFileLightsEnabled(_ enabled: Bool) {
        for entry in fileLights {
            entry.node.light = enabled ? entry.light : nil
        }
    }

    // MARK: - Animation
    //
    // Playback mechanism: WALL-CLOCK (`SCNAnimationPlayer.play()` / `.paused`).
    //
    // This was chosen empirically, not by preference. GLTFKit2 builds each clip
    // as a `CAAnimationGroup` whose child keyframe animations carry
    // `repeatDuration = FLT_MAX`. That structure ignores the two scene-time
    // scrubbing paths SceneKit normally offers:
    //   • `SCNAnimation.usesSceneTimeBase = true` + `SCNView.sceneTime`  → no motion
    //   • `speed = 0` + `SCNAnimation.timeOffset`  (the CA freeze trick)   → no motion
    // Both were verified STATIC against real rendered pixels (Fox, BoxAnimated)
    // via the `SelfTest` harness in Peek3DApp.swift; only wall-clock produced
    // distinct frames. See that harness for the reproducible evidence.
    //
    // Consequence: there is no public API to jump a wall-clock player to an
    // arbitrary time, so precise drag-to-seek is not offered. Play / pause /
    // select are rock-solid; the timeline degrades to a *synchronized progress
    // readout*: a 1/60s timer advances `animationTime` off the same real clock
    // the (non-paused, looping) player runs on, so the bar tracks the model.
    // glTF clips only touch model nodes (never our separate camera node), so
    // playback never fights `allowsCameraControl`.

    /// Wires up the clips for a freshly attached scene and, if any exist,
    /// auto-plays the first one — the natural default for a model viewer
    /// (Quick Look, three.js editor, Windows 3D Viewer all auto-play).
    private func configureAnimations(_ animations: [ModelAnimation], in scene: SCNScene) {
        // Tear down any previous model's playback first (replace flow).
        stopTimer()
        scene.rootNode.removeAnimation(forKey: activeAnimationKey)
        activePlayer = nil
        self.animations = animations
        currentAnimationIndex = 0
        animationTime = 0
        animationDuration = 0
        isPlaying = false

        guard !animations.isEmpty else { return }

        // Absent key (never touched in Settings) means autoplay, the default.
        let autoplay = UserDefaults.standard.object(forKey: SettingsKey.autoplay) as? Bool ?? true
        activateAnimation(at: 0, autoplay: autoplay)
    }

    /// Attaches exactly one clip's player to the root and (re)starts it from the
    /// beginning. Only one is ever attached: a skinned model's clips (e.g. Fox's
    /// Survey/Walk/Run) share one skeleton via absolute keyPaths, so leaving
    /// several attached would make them fight over the same nodes.
    private func activateAnimation(at index: Int, autoplay: Bool) {
        guard animations.indices.contains(index),
              let scene = scnView?.scene else { return }

        scene.rootNode.removeAnimation(forKey: activeAnimationKey)

        let player = animations[index].player
        player.stop() // rewind to t = 0 in case this clip ran before
        scene.rootNode.addAnimationPlayer(player, forKey: activeAnimationKey)
        player.play()
        activePlayer = player

        currentAnimationIndex = index
        animationDuration = player.animation.duration
        animationTime = 0

        if autoplay {
            resumePlayback()
        } else {
            // Freeze on frame 0 without leaving the timeline "playing".
            player.paused = true
            isPlaying = false
            stopTimer()
        }
    }

    func play() {
        guard hasAnimations, animationDuration > 0 else { return }
        resumePlayback()
    }

    func pause() {
        activePlayer?.paused = true
        isPlaying = false
        stopTimer()
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func selectAnimation(index: Int) {
        guard animations.indices.contains(index), index != currentAnimationIndex else { return }
        let wasPlaying = isPlaying
        stopTimer()
        activateAnimation(at: index, autoplay: wasPlaying)
    }

    /// Display label for a clip, substituting a fallback for unnamed clips
    /// (glTF allows empty names — BoxAnimated has exactly one).
    func animationName(at index: Int) -> String {
        guard animations.indices.contains(index) else { return "" }
        let raw = animations[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty else { return raw }
        let fallback = String(localized: "clip.fallback", defaultValue: "Animation")
        return "\(fallback) \(index + 1)"
    }

    private func resumePlayback() {
        activePlayer?.paused = false
        isPlaying = true
        startTimer()
    }

    private func startTimer() {
        stopTimer()
        guard animationDuration > 0 else { return }
        lastTick = CACurrentMediaTime()
        // `.common` mode so the readout keeps advancing while the user interacts
        // with menus / other tracking UI.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    private func stopTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    /// Advances the progress readout by real elapsed time, mirroring the
    /// wall-clock player (which loops via GLTFKit2's `repeatDuration = FLT_MAX`).
    private func tick() {
        guard isPlaying, animationDuration > 0 else { return }
        let now = CACurrentMediaTime()
        let delta = now - lastTick
        lastTick = now

        var t = animationTime + delta
        if t >= animationDuration {
            t = t.truncatingRemainder(dividingBy: animationDuration) // loop
        }
        animationTime = t
    }

    // MARK: - Screenshot

    func takeScreenshot() {
        guard let scnView else { return }
        let image = scnView.snapshot()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(currentModelName)-screenshot.png"

        // `runModal()`, not `begin(completionHandler:)` — the async variant
        // is unreliable here (never surfaces); `NSOpenPanel.runModal()` /
        // `NSSavePanel.runModal()` is the proven-working pattern in this app.
        guard panel.runModal() == .OK, let url = panel.url,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    // MARK: - Fullscreen

    func toggleFullScreen() {
        scnView?.window?.toggleFullScreen(nil)
    }
}
