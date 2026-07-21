import Foundation
import SceneKit
import Metal
import AppKit

/// Headless verification hook. Set `GLBVIEWER_SELFTEST=/path/to/model` to load a
/// file through the real `ModelLoader`, print the computed stats, and exit —
/// no window required. Used to verify the load path from the command line.
enum SelfTest {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["GLBVIEWER_SELFTEST"] else { return }
        let url = URL(fileURLWithPath: path)
        do {
            let model = try ModelLoader.loadSync(url: url)
            let stats = model.stats
            print("SELFTEST_OK")
            print("file: \(stats.fileName)")
            print("triangles: \(stats.triangleCount)")
            print("vertices: \(stats.vertexCount)")
            print("meshes: \(stats.meshCount)")
            print("materials: \(stats.materialCount)")
            print(String(format: "dimensions: %.4f x %.4f x %.4f",
                         stats.dimensions.x, stats.dimensions.y, stats.dimensions.z))
            print("fileSize: \(stats.fileSizeBytes) bytes (\(stats.fileSizeFormatted))")

            // Animation report + empirical scene-time scrubbing check.
            print("animations: \(model.animations.count)")
            for (i, anim) in model.animations.enumerated() {
                let name = anim.name.isEmpty ? "<unnamed>" : anim.name
                print(String(format: "  [%d] '%@' duration=%.4fs", i, name, anim.player.animation.duration))
            }
            if !model.animations.isEmpty {
                verifyScrubbing(url: url)
                if let out = ProcessInfo.processInfo.environment["GLBVIEWER_SELFTEST_RENDER"] {
                    verifyWireframeDuringPlayback(url: url, baseOutput: URL(fileURLWithPath: out))
                    verifyWireframeLiveSCNView(url: url, baseOutput: URL(fileURLWithPath: out))
                    verifyWireframeWithShadingReal(url: url, baseOutput: URL(fileURLWithPath: out))
                }
            }

            if let out = ProcessInfo.processInfo.environment["GLBVIEWER_SELFTEST_RENDER"] {
                let ok = renderOffscreen(scene: model.scene, to: URL(fileURLWithPath: out))
                print(ok ? "render: OK -> \(out)" : "render: FAILED")
                verifyLightingPresets(url: url, baseOutput: URL(fileURLWithPath: out))
                verifyShadingModes(url: url, baseOutput: URL(fileURLWithPath: out))
            }
            fflush(stdout)
            exit(0)
        } catch {
            print("SELFTEST_FAIL: \(error.localizedDescription)")
            fflush(stdout)
            exit(1)
        }
    }

    /// Ground-truth check for the scrubbing mechanism, using RENDERED PIXELS
    /// (not `node.presentation`, which an offscreen `SCNRenderer` never writes
    /// back — that gave an earlier false "static"). Renders real frames at
    /// several times under BOTH candidate mechanisms and hashes the raw bitmap:
    /// if the frame bytes change with time, that mechanism actually animates.
    private static func verifyScrubbing(url: URL) {
        for (label, sceneTimeBase) in [("SCNRenderer scene-time", true), ("SCNRenderer wall-clock", false)] {
            report(label, renderHashes(url: url, sceneTimeBase: sceneTimeBase))
        }
        // Decisive test: the app renders through a real SCNView, so measure
        // whether SCNView.sceneTime actually drives the animation via the same
        // snapshot() path the app's screenshot feature uses.
        report("SCNView scene-time", renderHashesSceneView(url: url))
        // Candidate scrubber: freeze the wall-clock player (speed = 0) and pick
        // the frame with the animation's timeOffset — the classic CA freeze trick.
        report("SCNView timeOffset", renderHashesTimeOffset(url: url))
        // Candidate scrubber: bypass the player, add the SCNAnimation directly
        // with scene-time base, and drive SCNView.sceneTime.
        report("SCNView addAnimation+sceneTime", renderHashesAddAnimation(url: url))

        // Diagnostic: does mutating player.animation stick, or is it a copy?
        if let model = try? ModelLoader.loadSync(url: url), let a = model.animations.first {
            a.player.animation.usesSceneTimeBase = true
            a.player.animation.timeOffset = 1.0
            print("DIAG: after-set usesSceneTimeBase=\(a.player.animation.usesSceneTimeBase) "
                  + "timeOffset=\(a.player.animation.timeOffset) (false/0 => .animation is a copy)")
        }
    }

    /// Reproduces the exact reported bug: wireframe toggled WHILE a clip is
    /// actively playing (mid-deformation), not on the bind pose. Mutates
    /// `material.fillMode` in place on the ORIGINAL materials — exactly what
    /// `ViewerController.applyWireframe()` does — while the wall-clock player
    /// is running, then renders a mid-clip frame and checks whether the mesh
    /// is still visible.
    private static func verifyWireframeDuringPlayback(url: URL, baseOutput: URL) {
        guard let model = try? ModelLoader.loadSync(url: url),
              let anim = model.animations.first,
              let device = MTLCreateSystemDefaultDevice() else {
            print("PLAYBACK_WIREFRAME: setup failed"); return
        }
        let scene = model.scene
        let player = anim.player
        let duration = player.animation.duration
        guard duration > 0 else { print("PLAYBACK_WIREFRAME: no duration"); return }

        scene.rootNode.addAnimationPlayer(player, forKey: "verify")
        player.play()

        // Mutate fillMode in place on the ORIGINAL materials, same as the live
        // controller's applyWireframe() — no material replacement.
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials { material.fillMode = .lines }
        }

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = true
        let camera = CameraFit.makeFittedCamera(for: scene)
        scene.rootNode.addChildNode(camera)
        renderer.pointOfView = camera

        let t = duration * 0.5
        let image = renderer.snapshot(atTime: t, with: CGSize(width: 320, height: 320), antialiasingMode: .multisampling4X)
        let blank = isBlank(image)
        let dir = baseOutput.deletingLastPathComponent()
        let stem = baseOutput.deletingPathExtension().lastPathComponent
        writePNG(image, to: dir.appendingPathComponent("\(stem)-wireframe-during-playback.png"))
        print("PLAYBACK_WIREFRAME: t=\(t) blank=\(blank) -> \(stem)-wireframe-during-playback.png")
    }

    /// Highest-fidelity repro of the live bug: uses a real `SCNView` configured
    /// EXACTLY like `ViewerController.attach()` (`allowsCameraControl`,
    /// `rendersContinuously`, wall-clock player already running for real elapsed
    /// wall-clock time via `Thread.sleep`), then toggles wireframe mid-playback
    /// — the actual button-press sequence a user hits — and snapshots before and
    /// after. `SCNRenderer`-based checks above did NOT reproduce a disappearance;
    /// this isolates whether `SCNView`'s continuous-rendering path is the cause.
    private static func verifyWireframeLiveSCNView(url: URL, baseOutput: URL) {
        guard let model = try? ModelLoader.loadSync(url: url),
              let anim = model.animations.first else {
            print("LIVE_WIREFRAME: setup failed"); return
        }
        let scene = model.scene
        let player = anim.player
        guard player.animation.duration > 0 else { print("LIVE_WIREFRAME: no duration"); return }

        let view = SCNView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
        view.scene = scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true

        let camera = CameraFit.makeFittedCamera(for: scene)
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera

        scene.rootNode.addAnimationPlayer(player, forKey: "glbviewer.activeAnimation")
        player.play()

        Thread.sleep(forTimeInterval: 0.6) // let it actually play a bit, like a real user would see

        let dir = baseOutput.deletingLastPathComponent()
        let stem = baseOutput.deletingPathExtension().lastPathComponent

        let before = view.snapshot()
        writePNG(before, to: dir.appendingPathComponent("\(stem)-live-before-wireframe.png"))
        print("LIVE_WIREFRAME: before blank=\(isBlank(before))")

        // Toggle wireframe exactly like ViewerController.applyWireframe(): mutate
        // fillMode in place on the model's own node hierarchy's materials.
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials { material.fillMode = .lines }
        }

        let immediatelyAfter = view.snapshot()
        writePNG(immediatelyAfter, to: dir.appendingPathComponent("\(stem)-live-immediately-after-wireframe.png"))
        print("LIVE_WIREFRAME: immediately-after blank=\(isBlank(immediatelyAfter))")

        Thread.sleep(forTimeInterval: 0.6) // continue playing under wireframe, like a user watching it

        let after = view.snapshot()
        writePNG(after, to: dir.appendingPathComponent("\(stem)-live-after-wireframe.png"))
        print("LIVE_WIREFRAME: after (playing under wireframe) blank=\(isBlank(after))")
    }

    /// Exercises the QA-reported bug through the REAL production path (unlike
    /// `verifyShadingModes`, which re-implements the material swap for testing
    /// convenience — that duplication is exactly what let this regress
    /// unnoticed). Uses the actual `ViewerController` attached to a live,
    /// continuously-rendering `SCNView`, exactly as `ContentView` does, then
    /// drives it through `setShadingMode`/`toggleWireframe` like a real button
    /// press and snapshots the result.
    private static func verifyWireframeWithShadingReal(url: URL, baseOutput: URL) {
        guard let model = try? ModelLoader.loadSync(url: url) else {
            print("REAL_WIREFRAME: load failed"); return
        }
        let dir = baseOutput.deletingLastPathComponent()
        let stem = baseOutput.deletingPathExtension().lastPathComponent

        for mode: ShadingMode in [.standard, .normals, .matcap, .unlit, .uvChecker] {
            let controller = ViewerController()
            let view = SCNView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
            controller.attach(scnView: view, scene: model.scene, animations: model.animations)
            if let anim = model.animations.first {
                anim.player.play()
            }
            controller.setShadingMode(mode)
            controller.toggleWireframe()
            Thread.sleep(forTimeInterval: 0.3) // let continuous rendering + playback actually run

            let image = view.snapshot()
            writePNG(image, to: dir.appendingPathComponent("\(stem)-real-\(mode.rawValue)-wireframe.png"))
            print("REAL_WIREFRAME[\(mode.rawValue)]: blank=\(isBlank(image)) -> \(stem)-real-\(mode.rawValue)-wireframe.png")
        }
    }

    private static func report(_ label: String, _ hashes: [UInt64]?) {
        guard let hashes else { print("VERIFY[\(label)]: no animation / no Metal"); return }
        let distinct = Set(hashes).count
        let hexes = hashes.map { String($0, radix: 16) }.joined(separator: ", ")
        print("VERIFY[\(label)]: frames=\(hexes) distinct=\(distinct) -> "
              + (distinct > 1 ? "MOVES" : "STATIC"))
    }

    /// Scene-time scrubbing through a real `SCNView` (not `SCNRenderer`) — the
    /// exact render path the app uses. This is the authoritative check.
    private static func renderHashesSceneView(url: URL) -> [UInt64]? {
        guard let model = try? ModelLoader.loadSync(url: url),
              let anim = model.animations.first else { return nil }
        let scene = model.scene
        let player = anim.player
        let duration = player.animation.duration
        guard duration > 0 else { return nil }

        player.animation.usesSceneTimeBase = true
        scene.rootNode.addAnimationPlayer(player, forKey: "verify")

        let view = SCNView(frame: NSRect(x: 0, y: 0, width: 160, height: 160))
        view.scene = scene
        let camera = CameraFit.makeFittedCamera(for: scene)
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera

        return [0.0, duration * 0.5, duration * 0.9].map { t in
            view.sceneTime = t
            return pixelHash(view.snapshot())
        }
    }

    /// Wall-clock scrubber candidate: freeze playback (`speed = 0`) and select
    /// the displayed frame purely with `SCNAnimation.timeOffset`, rendered
    /// through a real `SCNView`.
    private static func renderHashesTimeOffset(url: URL) -> [UInt64]? {
        guard let model = try? ModelLoader.loadSync(url: url),
              let anim = model.animations.first else { return nil }
        let scene = model.scene
        let player = anim.player
        let duration = player.animation.duration
        guard duration > 0 else { return nil }

        scene.rootNode.addAnimationPlayer(player, forKey: "verify")
        player.play()
        player.speed = 0 // freeze; timeOffset now selects the phase

        let view = SCNView(frame: NSRect(x: 0, y: 0, width: 160, height: 160))
        view.scene = scene
        let camera = CameraFit.makeFittedCamera(for: scene)
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera

        return [0.0, duration * 0.5, duration * 0.9].map { t in
            player.animation.timeOffset = t
            return pixelHash(view.snapshot())
        }
    }

    /// Scene-time scrubber that bypasses the SCNAnimationPlayer entirely: it
    /// adds the raw SCNAnimation (scene-time base) to the node and drives
    /// SCNView.sceneTime.
    private static func renderHashesAddAnimation(url: URL) -> [UInt64]? {
        guard let model = try? ModelLoader.loadSync(url: url),
              let anim = model.animations.first else { return nil }
        let scene = model.scene
        let scnAnimation = anim.player.animation
        let duration = scnAnimation.duration
        guard duration > 0 else { return nil }

        scnAnimation.usesSceneTimeBase = true
        scene.rootNode.addAnimation(scnAnimation, forKey: "verify")

        let view = SCNView(frame: NSRect(x: 0, y: 0, width: 160, height: 160))
        view.scene = scene
        let camera = CameraFit.makeFittedCamera(for: scene)
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera

        return [0.0, duration * 0.5, duration * 0.9].map { t in
            view.sceneTime = t
            return pixelHash(view.snapshot())
        }
    }

    /// Loads a fresh copy of the model, attaches its first clip under the given
    /// mechanism, and returns a pixel hash of an offscreen frame at 0%, 50% and
    /// 90% of the clip duration.
    private static func renderHashes(url: URL, sceneTimeBase: Bool) -> [UInt64]? {
        guard let model = try? ModelLoader.loadSync(url: url),
              let anim = model.animations.first,
              let device = MTLCreateSystemDefaultDevice() else { return nil }

        let scene = model.scene
        let player = anim.player
        let duration = player.animation.duration
        guard duration > 0 else { return nil }

        player.animation.usesSceneTimeBase = sceneTimeBase
        scene.rootNode.addAnimationPlayer(player, forKey: "verify")
        if !sceneTimeBase { player.play() } // wall-clock needs an explicit start

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = true
        let camera = CameraFit.makeFittedCamera(for: scene)
        scene.rootNode.addChildNode(camera)
        renderer.pointOfView = camera

        let size = CGSize(width: 160, height: 160)
        return [0.0, duration * 0.5, duration * 0.9].map { t in
            if sceneTimeBase { renderer.sceneTime = t }
            // `atTime` drives system-time (wall-clock) animations; harmless for
            // the scene-time case where sceneTime is already pinned to t.
            let image = renderer.snapshot(atTime: t, with: size, antialiasingMode: .none)
            return pixelHash(image)
        }
    }

    /// FNV-1a hash over a snapshot's raw RGBA bytes. Identical poses hash
    /// identically; any real motion changes pixels and thus the hash.
    private static func pixelHash(_ image: NSImage) -> UInt64 {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pixels = rep.bitmapData else { return 0 }
        let count = rep.bytesPerRow * rep.pixelsHigh
        var hash: UInt64 = 1469598103934665603
        for i in 0..<count {
            hash = (hash ^ UInt64(pixels[i])) &* 1099511628211
        }
        return hash
    }

    /// Renders every `LightingPreset` to its own PNG (next to `baseOutput`, e.g.
    /// `out.png` → `out-studio.png`) and hashes each frame. Four distinct hashes
    /// prove the presets actually change the image — the ground-truth check that
    /// the lighting rigs differ. A FRESH scene is loaded per preset so light
    /// rigs never accumulate, exactly mirroring the live teardown/rebuild.
    private static func verifyLightingPresets(url: URL, baseOutput: URL) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("LIGHTING: no Metal device"); return
        }
        let dir = baseOutput.deletingLastPathComponent()
        let stem = baseOutput.deletingPathExtension().lastPathComponent
        var hashes: [UInt64] = []

        for preset in LightingPreset.allCases {
            guard let model = try? ModelLoader.loadSync(url: url) else { continue }
            let scene = model.scene
            let bounds = SceneBounds.compute(for: scene.rootNode)
            LightingRig.apply(preset, to: scene,
                              center: bounds?.center ?? .zero,
                              radius: bounds?.radius ?? 1)

            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = scene
            renderer.autoenablesDefaultLighting = preset.usesDefaultLighting
            let camera = CameraFit.makeFittedCamera(for: scene)
            scene.rootNode.addChildNode(camera)
            renderer.pointOfView = camera

            let image = renderer.snapshot(atTime: 0, with: CGSize(width: 320, height: 320),
                                          antialiasingMode: .multisampling4X)
            let hash = pixelHash(image)
            hashes.append(hash)

            let presetURL = dir.appendingPathComponent("\(stem)-\(preset.rawValue).png")
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: presetURL)
            }
            print("LIGHTING[\(preset.rawValue)]: hash=\(String(hash, radix: 16)) -> \(presetURL.lastPathComponent)")
        }

        let distinct = Set(hashes).count
        print("LIGHTING: presets=\(LightingPreset.allCases.count) distinctHashes=\(distinct) -> "
              + (distinct == LightingPreset.allCases.count ? "ALL DIFFERENT" : "COLLISION"))
    }

    /// Renders every `ShadingMode` to its own PNG (next to `baseOutput`, e.g.
    /// `out.png` → `out-shade-normals.png`) and hashes each frame. Five distinct
    /// hashes prove the modes actually change the image. Then renders wireframe
    /// combos (both `.standard` — the plain toggle a user clicks — and
    /// `.normals`) and proves each differs from its non-wireframe counterpart —
    /// the ground-truth that the two axes compose, on THIS model's real geometry
    /// (skinned meshes can behave differently from static ones under `.lines`).
    ///
    /// A FRESH scene is loaded per case so overrides never accumulate, mirroring
    /// the live per-model capture/rebuild in `ViewerController`. This intentionally
    /// re-implements the controller's material swap (the controller is UI-bound);
    /// both funnel through `ShadingMaterialFactory`, the single source of truth.
    private static func verifyShadingModes(url: URL, baseOutput: URL) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("SHADING: no Metal device"); return
        }
        let dir = baseOutput.deletingLastPathComponent()
        let stem = baseOutput.deletingPathExtension().lastPathComponent
        var hashByMode: [ShadingMode: UInt64] = [:]

        for mode in ShadingMode.allCases {
            guard let model = try? ModelLoader.loadSync(url: url) else { continue }
            let scene = model.scene
            applyShadingForTest(mode, to: scene, wireframe: false)
            let image = renderShading(scene: scene, device: device)
            let hash = pixelHash(image)
            hashByMode[mode] = hash
            writePNG(image, to: dir.appendingPathComponent("\(stem)-shade-\(mode.rawValue).png"))
            print("SHADING[\(mode.rawValue)]: hash=\(String(hash, radix: 16)) -> \(stem)-shade-\(mode.rawValue).png")
        }

        let distinct = Set(hashByMode.values).count
        print("SHADING: modes=\(ShadingMode.allCases.count) distinctHashes=\(distinct) -> "
              + (distinct == ShadingMode.allCases.count ? "ALL DIFFERENT" : "COLLISION"))

        // Wireframe + shading compose, checked for BOTH `.standard` (the file's
        // real materials — what the plain "Wireframe" toolbar button toggles)
        // and `.normals`. `.standard` is the case a skinned model's own
        // materials/shader setup can behave differently under `.lines`.
        for mode: ShadingMode in [.standard, .normals] {
            guard let model = try? ModelLoader.loadSync(url: url) else { continue }
            let scene = model.scene
            applyShadingForTest(mode, to: scene, wireframe: true)
            let image = renderShading(scene: scene, device: device)
            let wfHash = pixelHash(image)
            let blank = isBlank(image)
            writePNG(image, to: dir.appendingPathComponent("\(stem)-shade-\(mode.rawValue)-wireframe.png"))
            let plain = hashByMode[mode] ?? 0
            print("SHADING[\(mode.rawValue)+wireframe]: hash=\(String(wfHash, radix: 16)) vs \(mode.rawValue)=\(String(plain, radix: 16)) "
                  + "blank=\(blank) -> "
                  + (wfHash != plain ? "COMPOSE (wireframe over shading)" : "SAME (wireframe lost!)"))
        }
    }

    /// True if every pixel is the exact same value (a flat/empty render — the
    /// symptom of a mesh that failed to draw at all, as opposed to one that drew
    /// correctly as thin wireframe lines over a mostly-background frame).
    private static func isBlank(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pixels = rep.bitmapData else { return true }
        let count = rep.bytesPerRow * rep.pixelsHigh
        guard count > 0 else { return true }
        let first = pixels[0]
        for i in 1..<count where pixels[i] != first { return false }
        return true
    }

    /// Replicates `ViewerController.applyShadingMode` for the harness: for each
    /// model geometry, swaps in the mode's factory materials (or leaves the
    /// originals for `.standard`) and, if requested, stamps the wireframe fill
    /// mode on top — exactly the ordering the live controller uses.
    private static func applyShadingForTest(_ mode: ShadingMode, to scene: SCNScene, wireframe: Bool) {
        for node in scene.rootNode.childNodes {
            node.enumerateHierarchy { child, _ in
                guard let geometry = child.geometry else { return }
                if mode != .standard {
                    geometry.materials = ShadingMaterialFactory.materials(for: mode, original: geometry.materials)
                }
                if wireframe {
                    for m in geometry.materials { m.fillMode = .lines }
                }
            }
        }
    }

    /// Offscreen render of a shaded scene with default lighting ON, matching the
    /// live viewer's default preset. `normals`/`matcap`/`unlit` ignore lights by
    /// design; only `uvChecker` reads them.
    private static func renderShading(scene: SCNScene, device: MTLDevice) -> NSImage {
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = true
        let camera = CameraFit.makeFittedCamera(for: scene)
        scene.rootNode.addChildNode(camera)
        renderer.pointOfView = camera
        return renderer.snapshot(atTime: 0, with: CGSize(width: 320, height: 320),
                                 antialiasingMode: .multisampling4X)
    }

    private static func writePNG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    /// Renders the loaded scene offscreen (Metal, no window) and writes a PNG.
    /// Verifies the render pipeline + camera fit produce a visible image.
    private static func renderOffscreen(scene: SCNScene, to url: URL) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = true

        let camera = CameraFit.makeFittedCamera(for: scene)
        scene.rootNode.addChildNode(camera)
        renderer.pointOfView = camera

        let size = CGSize(width: 900, height: 600)
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
