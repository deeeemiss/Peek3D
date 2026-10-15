#if DEBUG
import Foundation
import SceneKit
import Metal
import AppKit

/// Headless verification hook. Set `PEEK3D_SELFTEST=/path/to/model` to load a
/// file through the real `ModelLoader`, print the computed stats, and exit —
/// no window required. Used to verify the load path from the command line.
/// Debug builds only: the shipped app has no hidden test entry points.
enum SelfTest {
    static func runIfRequested() {
        if let sequence = ProcessInfo.processInfo.environment["PEEK3D_SELFTEST_SEQUENCE"] {
            runSequence(sequence, rapid: ProcessInfo.processInfo.environment["PEEK3D_SELFTEST_RAPID"] == "1")
        }
        guard let path = ProcessInfo.processInfo.environment["PEEK3D_SELFTEST"] else { return }
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

            // Animation report (+ the opt-in scrub check below).
            print("animations: \(model.animations.count)")
            for (i, anim) in model.animations.enumerated() {
                let name = anim.name.isEmpty ? "<unnamed>" : anim.name
                print(String(format: "  [%d] '%@' duration=%.4fs", i, name, anim.player.animation.duration))
            }
            if !model.animations.isEmpty {
                if ProcessInfo.processInfo.environment["PEEK3D_SELFTEST_SCRUB"] == "1", !verifyScrub(url: url) {
                    print("SELFTEST_FAIL: scrub")
                    fflush(stdout)
                    exit(1)
                }
                if let out = ProcessInfo.processInfo.environment["PEEK3D_SELFTEST_RENDER"] {
                    verifyAnimationVsBindPose(url: url, baseOutput: URL(fileURLWithPath: out))
                    verifyWireframeDuringPlayback(url: url, baseOutput: URL(fileURLWithPath: out))
                    verifyWireframeLiveSCNView(url: url, baseOutput: URL(fileURLWithPath: out))
                    verifyWireframeWithShadingReal(url: url, baseOutput: URL(fileURLWithPath: out))
                }
            }

            // `PEEK3D_SELFTEST_DEFORM=<png base path>`: proves that a skinned /
            // morphed model really DEFORMS (see `verifyDeformation`). Exits 1
            // with SELFTEST_FAIL if it doesn't.
            if let out = ProcessInfo.processInfo.environment["PEEK3D_SELFTEST_DEFORM"] {
                let failures = verifyDeformation(url: url, baseOutput: URL(fileURLWithPath: out))
                if !failures.isEmpty {
                    print("SELFTEST_FAIL: deformation check failed: " + failures.joined(separator: "; "))
                    fflush(stdout)
                    exit(1)
                }
                print("DEFORM_OK")
            }

            if let out = ProcessInfo.processInfo.environment["PEEK3D_SELFTEST_RENDER"] {
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

    /// Opens `|`-separated files one after another in one `ModelSession`, the
    /// same object a viewer window uses, then prints what it ends up showing:
    /// which file, its triangle count (to tell two models apart) and the
    /// error, if any. `rapid` issues every load at once, like quick repeated
    /// drops; otherwise each load finishes before the next starts.
    private static func runSequence(_ spec: String, rapid: Bool) {
        let session = ModelSession()
        let deadline = Date().addingTimeInterval(30)
        func settle() {
            // Loads complete on the main queue, which only drains while the
            // run loop turns — and this runs before the app's own loop starts.
            while session.isLoading {
                guard Date() < deadline else { print("SEQUENCE_TIMEOUT"); fflush(stdout); exit(2) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        for path in spec.split(separator: "|") {
            session.load(url: URL(fileURLWithPath: String(path)))
            if !rapid { settle() }
        }
        settle()
        print("SEQUENCE_DONE")
        print("shown: \(session.stats?.fileName ?? "none")")
        print("triangles: \(session.stats?.triangleCount ?? 0)")
        print("error: \(session.errorMessage ?? "none")")
        fflush(stdout)
        exit(0)
    }

    /// Ground-truth for the FBX node-transform animation path: attaches the
    /// wall-clock player and takes two sequential frames off ONE renderer — at
    /// t=0 (the clip's start pose == the node's rest/bind transform for these
    /// files) and at 50%% of the clip — writing both as PNGs, then asserts they
    /// differ and neither is blank. A difference proves the baked keyframes
    /// actually move the node; the non-blank guard rules out a mesh that
    /// vanished. This is the "cube rotated vs bind pose" check.
    ///
    /// The two snapshots MUST come sequentially from the same renderer (t=0
    /// first): a lone `snapshot(atTime: 0.5*d)` on a just-played wall-clock
    /// player renders the start pose instead — the same ordering the scrub
    /// check relies on. Loader-agnostic (goes through `ModelLoader`), but it's the FBX
    /// clips this was added to cover.
    private static func verifyAnimationVsBindPose(url: URL, baseOutput: URL) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("BINDPOSE: no Metal device"); return
        }
        guard let model = try? ModelLoader.loadSync(url: url),
              let anim = model.animations.first else {
            print("BINDPOSE: no animation to play"); return
        }
        let dir = baseOutput.deletingLastPathComponent()
        let stem = baseOutput.deletingPathExtension().lastPathComponent
        let duration = anim.player.animation.duration
        guard duration > 0 else { print("BINDPOSE: no duration"); return }

        model.scene.rootNode.addAnimationPlayer(anim.player, forKey: "verify")
        anim.player.play()
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = model.scene
        renderer.autoenablesDefaultLighting = true
        let camera = CameraFit.makeFittedCamera(for: model.scene)
        model.scene.rootNode.addChildNode(camera)
        renderer.pointOfView = camera

        let size = CGSize(width: 320, height: 320)
        let bindImage = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        writePNG(bindImage, to: dir.appendingPathComponent("\(stem)-anim-bind.png"))
        let midImage = renderer.snapshot(atTime: duration * 0.5, with: size, antialiasingMode: .multisampling4X)
        writePNG(midImage, to: dir.appendingPathComponent("\(stem)-anim-midplay.png"))

        let bindHash = pixelHash(bindImage)
        let midHash = pixelHash(midImage)
        let ok = (bindHash != midHash) && !isBlank(bindImage) && !isBlank(midImage)
        print("BINDPOSE: bind=\(String(bindHash, radix: 16)) mid=\(String(midHash, radix: 16)) "
              + "bindBlank=\(isBlank(bindImage)) midBlank=\(isBlank(midImage)) -> "
              + (ok ? "ANIMATES (mid-play differs from bind pose)" : "NO MOTION / BLANK"))
    }

    // MARK: - Deformation (skinning / blend shapes)

    /// Fraction of pixels whose colour differs between two same-size snapshots.
    private static func differingPixelFraction(_ a: NSImage, _ b: NSImage) -> Double {
        guard let ta = a.tiffRepresentation, let ra = NSBitmapImageRep(data: ta), let pa = ra.bitmapData,
              let tb = b.tiffRepresentation, let rb = NSBitmapImageRep(data: tb), let pb = rb.bitmapData,
              ra.pixelsWide == rb.pixelsWide, ra.pixelsHigh == rb.pixelsHigh,
              ra.bitsPerPixel == rb.bitsPerPixel else { return 1 }
        let bytesPerPixel = ra.bitsPerPixel / 8
        var differing = 0
        for y in 0..<ra.pixelsHigh {
            for x in 0..<ra.pixelsWide {
                let ia = y * ra.bytesPerRow + x * bytesPerPixel
                let ib = y * rb.bytesPerRow + x * bytesPerPixel
                for c in 0..<min(3, bytesPerPixel) where abs(Int(pa[ia + c]) - Int(pb[ib + c])) > 8 {
                    differing += 1
                    break
                }
            }
        }
        return Double(differing) / Double(ra.pixelsWide * ra.pixelsHigh)
    }

    /// Bind-pose then mid-clip frames, both off ONE renderer in that order (a
    /// lone mid-clip snapshot on a fresh wall-clock player renders the start
    /// pose). `prepare` runs on the freshly loaded scene before anything is
    /// drawn, to strip a deformer or pose the model.
    private static func bindAndMidFrames(url: URL, size: CGSize = CGSize(width: 320, height: 320),
                                         prepare: (SCNScene) -> Void = { _ in }) -> (bind: NSImage, mid: NSImage)? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let model = try? ModelLoader.loadSync(url: url),
              let anim = model.animations.first else { return nil }
        let duration = anim.player.animation.duration
        guard duration > 0 else { return nil }
        prepare(model.scene)
        model.scene.rootNode.addAnimationPlayer(anim.player, forKey: "verify")
        anim.player.play()
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = model.scene
        renderer.autoenablesDefaultLighting = true
        let camera = CameraFit.makeFittedCamera(for: model.scene)
        model.scene.rootNode.addChildNode(camera)
        renderer.pointOfView = camera
        let bind = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        let mid = renderer.snapshot(atTime: duration * 0.5, with: size, antialiasingMode: .multisampling4X)
        return (bind, mid)
    }

    /// A model without a clip, rendered once at the bind pose.
    private static func restFrame(url: URL, size: CGSize = CGSize(width: 320, height: 320),
                                  prepare: (SCNScene) -> Void) -> NSImage? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let model = try? ModelLoader.loadSync(url: url) else { return nil }
        prepare(model.scene)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = model.scene
        renderer.autoenablesDefaultLighting = true
        let camera = CameraFit.makeFittedCamera(for: model.scene)
        model.scene.rootNode.addChildNode(camera)
        renderer.pointOfView = camera
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }

    /// Proves a skinned or morphed FBX DEFORMS, with rendered pixels:
    ///
    /// skin  - (1) the skinned bind pose looks exactly like the same mesh with
    ///         the skinner removed (the bind matrices are right); (2) mid-clip
    ///         the skinned mesh differs from the bind pose; (3) and from the
    ///         same clip played with the skinner removed. Bones render nothing
    ///         and the fixture's root bone never moves, so only a deformed mesh
    ///         can account for (2) and (3): a rigid mesh would match (3).
    /// morph - weight 0 equals the model without its morpher, weight 1 differs
    ///         from it, and the clip's weight animation moves the mesh mid-clip.
    ///
    /// Returns the failures (empty = pass). Writes the frames as PNGs.
    private static func verifyDeformation(url: URL, baseOutput: URL) -> [String] {
        let dir = baseOutput.deletingLastPathComponent()
        let stem = baseOutput.deletingPathExtension().lastPathComponent
        guard let model = try? ModelLoader.loadSync(url: url) else { return ["load failed"] }
        var hasSkin = false, hasMorph = false
        model.scene.rootNode.enumerateHierarchy { node, _ in
            if node.skinner != nil { hasSkin = true }
            if node.morpher != nil { hasMorph = true }
        }
        var failures: [String] = []
        func check(_ label: String, _ ok: Bool, _ detail: String) {
            print("DEFORM[\(label)]: \(detail) -> \(ok ? "OK" : "FAIL")")
            if !ok { failures.append("\(label) (\(detail))") }
        }
        if !hasSkin && !hasMorph { return ["model has neither a skinner nor a morpher"] }
        let stripSkinners: (SCNScene) -> Void = { scene in
            scene.rootNode.enumerateHierarchy { node, _ in node.skinner = nil }
        }
        let stripMorphers: (SCNScene) -> Void = { scene in
            scene.rootNode.enumerateHierarchy { node, _ in node.morpher = nil }
        }

        if hasSkin {
            guard let frames = bindAndMidFrames(url: url),
                  let rigidFrames = bindAndMidFrames(url: url, prepare: stripSkinners),
                  let rest = restFrame(url: url, prepare: stripSkinners) else { return ["render setup failed"] }
            writePNG(frames.bind, to: dir.appendingPathComponent("\(stem)-skin-bind.png"))
            writePNG(frames.mid, to: dir.appendingPathComponent("\(stem)-skin-mid.png"))
            writePNG(rigidFrames.mid, to: dir.appendingPathComponent("\(stem)-skin-mid-rigid-control.png"))
            let bindVsRest = differingPixelFraction(frames.bind, rest)
            let midVsBind = differingPixelFraction(frames.mid, frames.bind)
            let midVsRigid = differingPixelFraction(frames.mid, rigidFrames.mid)
            check("skin bind==rest", bindVsRest < 0.005, String(format: "%.4f of pixels differ", bindVsRest))
            check("skin mid!=bind", midVsBind > 0.02 && !isBlank(frames.mid), String(format: "%.4f of pixels differ", midVsBind))
            check("skin mid!=rigid", midVsRigid > 0.02, String(format: "%.4f of pixels differ", midVsRigid))
        }

        if hasMorph {
            guard let frames = bindAndMidFrames(url: url),
                  let restNoMorph = restFrame(url: url, prepare: stripMorphers),
                  let weight0 = restFrame(url: url, prepare: { scene in
                      scene.rootNode.enumerateHierarchy { node, _ in
                          guard let m = node.morpher else { return }
                          for i in 0..<m.targets.count { m.setWeight(0, forTargetAt: i) }
                      }
                  }),
                  let weight1 = restFrame(url: url, prepare: { scene in
                      scene.rootNode.enumerateHierarchy { node, _ in
                          guard let m = node.morpher else { return }
                          for i in 0..<m.targets.count { m.setWeight(1, forTargetAt: i) }
                      }
                  }) else { return ["render setup failed"] }
            writePNG(weight0, to: dir.appendingPathComponent("\(stem)-morph-weight0.png"))
            writePNG(weight1, to: dir.appendingPathComponent("\(stem)-morph-weight1.png"))
            writePNG(frames.bind, to: dir.appendingPathComponent("\(stem)-morph-clip-start.png"))
            writePNG(frames.mid, to: dir.appendingPathComponent("\(stem)-morph-clip-mid.png"))
            let zeroVsRest = differingPixelFraction(weight0, restNoMorph)
            let oneVsZero = differingPixelFraction(weight1, weight0)
            let midVsStart = differingPixelFraction(frames.mid, frames.bind)
            check("morph weight0==rest", zeroVsRest < 0.005, String(format: "%.4f of pixels differ", zeroVsRest))
            check("morph weight1!=weight0", oneVsZero > 0.02 && !isBlank(weight1), String(format: "%.4f of pixels differ", oneVsZero))
            check("morph clip mid!=start", midVsStart > 0.02 && !isBlank(frames.mid), String(format: "%.4f of pixels differ", midVsStart))
        }

        // Wireframe and shading modes swap the geometry's materials; that must
        // not detach the skinner / morpher. The real `ViewerController` (same
        // code path as the app) applies the mode to the live scene, then two
        // offscreen frames (bind pose, mid-clip) must still differ, and the
        // deformers must still be on their nodes. (A headless SCNView doesn't
        // advance its wall-clock players, so frames come from an SCNRenderer.)
        for (mode, wireframe) in [(ShadingMode.standard, true), (ShadingMode.normals, true), (ShadingMode.matcap, false)] {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let live = try? ModelLoader.loadSync(url: url), let clip = live.animations.first else {
                failures.append("live render setup failed"); continue
            }
            let controller = ViewerController()
            let view = SCNView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
            controller.attach(scnView: view, scene: live.scene, animations: live.animations)
            controller.setShadingMode(mode)
            if wireframe { controller.toggleWireframe() }
            clip.player.play()
            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = live.scene
            renderer.autoenablesDefaultLighting = true
            let camera = CameraFit.makeFittedCamera(for: live.scene)
            live.scene.rootNode.addChildNode(camera)
            renderer.pointOfView = camera
            let size = CGSize(width: 320, height: 320)
            let early = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
            let later = renderer.snapshot(atTime: clip.player.animation.duration * 0.5, with: size,
                                          antialiasingMode: .multisampling4X)
            var skinners = 0, morphers = 0
            live.scene.rootNode.enumerateHierarchy { node, _ in
                if node.skinner != nil { skinners += 1 }
                if node.morpher != nil { morphers += 1 }
            }
            let label = "\(mode.rawValue)\(wireframe ? "+wireframe" : "")"
            writePNG(early, to: dir.appendingPathComponent("\(stem)-controller-\(label)-start.png"))
            writePNG(later, to: dir.appendingPathComponent("\(stem)-controller-\(label)-mid.png"))
            let moved = differingPixelFraction(early, later)
            check("controller \(label) keeps deforming",
                  moved > 0.005 && !isBlank(later) && (!hasSkin || skinners > 0) && (!hasMorph || morphers > 0),
                  String(format: "%.4f of pixels differ, skinners=%d morphers=%d", moved, skinners, morphers))
        }
        return failures
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

        scene.rootNode.addAnimationPlayer(player, forKey: "peek3d.activeAnimation")
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

    /// Mean absolute per-byte difference between two snapshots, 0...1.
    private static func pixelDifference(_ a: NSImage, _ b: NSImage) -> Double {
        func bytes(_ image: NSImage) -> (UnsafeMutablePointer<UInt8>, Int)? {
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let pixels = rep.bitmapData else { return nil }
            return (pixels, rep.bytesPerRow * rep.pixelsHigh)
        }
        guard let (pa, na) = bytes(a), let (pb, nb) = bytes(b), na == nb, na > 0 else { return 1 }
        var sum = 0
        for i in 0..<na { sum += abs(Int(pa[i]) - Int(pb[i])) }
        return Double(sum) / Double(na * 255)
    }

    /// DEM-69 ground truth: drives the REAL `ViewerController` (the object the
    /// timeline slider talks to) on a live, continuously rendering `SCNView`, and
    /// judges seeking by RENDERED PIXELS.
    ///   • two different scrub times must give clearly different frames;
    ///   • the same scrub time visited twice must give (nearly) the same frame;
    ///   • while paused the frame must not drift;
    ///   • play after a scrub must continue from the scrubbed time, not from 0.
    /// Run with `PEEK3D_SELFTEST_SCRUB=1`; returns false (and prints why) on failure.
    private static func verifyScrub(url: URL) -> Bool {
        guard let model = try? ModelLoader.loadSync(url: url), !model.animations.isEmpty else {
            print("SCRUB: no animation"); return false
        }
        let controller = ViewerController()
        let view = SCNView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        // An SCNView that is not in an on-screen window has no display link, so
        // its wall-clock animations never advance between snapshots; give it one.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        controller.attach(scnView: view, scene: model.scene, animations: model.animations)
        let d = controller.animationDuration
        guard d > 0 else { print("SCRUB: zero duration"); return false }

        /// Spins the run loop (timers + continuous rendering) instead of blocking it.
        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        controller.pause()
        spin(0.1)
        func frame(at fraction: Double) -> NSImage {
            controller.seek(to: d * fraction)
            spin(0.12)
            return view.snapshot()
        }

        let early = 0.25, late = 0.9
        let a1 = frame(at: early)
        let b1 = frame(at: late)
        let a2 = frame(at: early)
        let b2 = frame(at: late)
        let different = pixelDifference(a1, b1)
        let sameA = pixelDifference(a1, a2)
        let sameB = pixelDifference(b1, b2)
        let notBlank = !isBlank(a1) && !isBlank(b1)

        // Paused frames must not drift.
        let held1 = view.snapshot()
        spin(0.3)
        let held2 = view.snapshot()
        let drift = pixelDifference(held1, held2)

        // Play after a scrub: must continue from the scrubbed point. The frame
        // grabbed while playing must match the frozen frame at the tracked
        // playhead at least as well as ANY other time on a 20-step scan (a plain
        // "closer to start than to zero" test is fooled by looping/periodic clips).
        let start = 0.6
        _ = frame(at: start)
        controller.play()
        spin(0.3)
        let playing = view.snapshot()
        let t = controller.animationTime
        let advanced = t > d * start + 0.15 && t < d * start + 0.7
        controller.pause()
        spin(0.12)
        let pausedSnap = view.snapshot()
        controller.seek(to: t)
        spin(0.12)
        let atTracked = pixelDifference(playing, view.snapshot())
        var best = Double.greatestFiniteMagnitude
        var bestIndex = 0
        for i in 0..<20 {
            controller.seek(to: d * Double(i) / 20)
            spin(0.1)
            let diff = pixelDifference(playing, view.snapshot())
            if diff < best { best = diff; bestIndex = i }
        }
        let resumedFromScrub = atTracked <= best + 0.01
        // Pausing re-freezes at the tracked playhead: no jump bigger than the
        // genuine difference between the two scrub poses.
        let pauseJump = pixelDifference(pausedSnap, playing)
        let pauseHolds = pauseJump < different

        // Scrubbing under wireframe (CLAUDE.md: skinned meshes must survive it):
        // the model must still be there, and still move with the playhead.
        controller.toggleWireframe()
        let wire1 = frame(at: early)
        let wire2 = frame(at: late)
        let wireframeOK = !isBlank(wire1) && !isBlank(wire2) && pixelDifference(wire1, wire2) > 0.0005

        let eps = 0.0005, minDiff = 0.002
        let ok = notBlank && different > minDiff && sameA < eps && sameB < eps
            && drift < eps && advanced && resumedFromScrub && pauseHolds && wireframeOK
        print(String(format: "SCRUB[%@]: different=%.5f sameA=%.5f sameB=%.5f drift=%.5f t_after_play=%.3f/%.3f "
                     + "atTracked=%.5f bestScan=%.5f@%d pauseJump=%.5f blank=%@ wireframe=%@ -> %@",
                     url.lastPathComponent, different, sameA, sameB, drift, t, d,
                     atTracked, best, bestIndex, pauseJump, "\(!notBlank)", "\(wireframeOK)", ok ? "PASS" : "FAIL"))
        return ok
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
#endif
