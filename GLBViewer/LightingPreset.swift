import SceneKit
import AppKit
import simd

/// The four selectable lighting / environment presets.
///
/// `standard` is the app's original behavior (SceneKit's automatic default
/// light plus whatever lights the file itself authored). The other three are
/// procedural rigs built entirely in code — no external HDRI or asset — that
/// **replace** scene illumination (see `LightingRig` and `ViewerController`).
enum LightingPreset: String, CaseIterable, Identifiable {
    case standard   // "Default"
    case studio     // "Studio"
    case outdoor    // "Outdoor"
    case darkMood   // "Dark mood"

    var id: String { rawValue }

    /// Localized label shown in the toolbar menu. `standard` gets its own key
    /// (`lighting.default`) — see `ShadingMode.displayName` for why.
    var displayName: String {
        switch self {
        case .standard: return String(localized: "lighting.default", defaultValue: "Default")
        case .studio:   return String(localized: "Studio")
        case .outdoor:  return String(localized: "Outdoor")
        case .darkMood: return String(localized: "Dark mood")
        }
    }

    /// SF Symbol used on the toolbar trigger; reflects the active preset as a
    /// quick visual cue. The tile is a fixed size, so this never shifts layout.
    var iconName: String {
        switch self {
        case .standard: return "lightbulb"
        case .studio:   return "light.max"
        case .outdoor:  return "sun.max"
        case .darkMood: return "moon.stars"
        }
    }

    /// Only `standard` leans on SceneKit's automatic default light. Every other
    /// preset supplies its own rig and must therefore turn it off. Read by both
    /// the live viewer (`SCNView`) and the headless self-test (`SCNRenderer`),
    /// which share the `autoenablesDefaultLighting` flag.
    var usesDefaultLighting: Bool { self == .standard }
}

/// Builds the procedural light rig and lighting environment for a preset.
///
/// Deliberately view-independent: it mutates a plain `SCNScene`, so the live
/// viewer and the offscreen self-test light models identically (mirroring how
/// `CameraFit` is shared for framing). The caller owns `autoenablesDefaultLighting`
/// and, for the live viewer, the lifecycle of the returned container node.
enum LightingRig {
    private static let neutralWhite = NSColor(calibratedWhite: 1.0, alpha: 1.0)

    /// Configures `scene.lightingEnvironment` for `preset` and, for non-Default
    /// presets, installs a fresh `presetLights` container (returned so the
    /// caller can remove it later). `standard` clears the environment, adds no
    /// rig, and returns `nil` — it relies on the automatic light plus file lights.
    ///
    /// `center` / `radius` come from the *model-only* bounds so light placement
    /// ignores helper geometry such as the grid.
    @discardableResult
    static func apply(_ preset: LightingPreset, to scene: SCNScene,
                      center: simd_float3, radius: Float) -> SCNNode? {
        configureEnvironment(preset, scene: scene)

        guard !preset.usesDefaultLighting else { return nil }

        let container = SCNNode()
        container.name = "presetLights"
        buildLights(preset, into: container, center: center, radius: max(radius, 0.0001))
        scene.rootNode.addChildNode(container)
        return container
    }

    // MARK: - Environment (image-based ambient)

    private static func configureEnvironment(_ preset: LightingPreset, scene: SCNScene) {
        let env = scene.lightingEnvironment
        switch preset {
        case .standard:
            // Restore the untouched baseline.
            env.contents = nil
            env.intensity = 1
        case .studio:
            // Light neutral ambient so PBR materials read cleanly.
            env.contents = NSColor(calibratedWhite: 0.5, alpha: 1)
            env.intensity = 0.6
        case .outdoor:
            // Procedural azure sky gradient (no external HDRI).
            env.contents = skyGradientImage()
            env.intensity = 1.2
        case .darkMood:
            // Near-black environment → low overall exposure.
            env.contents = NSColor(calibratedWhite: 0.03, alpha: 1)
            env.intensity = 0.4
        }
    }

    /// A small vertical gradient (pale horizon → azure sky) used as a spherical
    /// lighting environment. Generated in code so no asset ships with the app.
    private static func skyGradientImage() -> NSImage {
        let size = NSSize(width: 8, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        let horizon = NSColor(calibratedRed: 0.78, green: 0.82, blue: 0.86, alpha: 1)
        let sky = NSColor(calibratedRed: 0.34, green: 0.55, blue: 0.86, alpha: 1)
        NSGradient(starting: horizon, ending: sky)?
            .draw(in: NSRect(origin: .zero, size: size), angle: 90)
        image.unlockFocus()
        return image
    }

    // MARK: - Light rigs

    private static func buildLights(_ preset: LightingPreset, into container: SCNNode,
                                    center: simd_float3, radius: Float) {
        switch preset {
        case .standard:
            break // handled by autoenablesDefaultLighting

        case .studio:
            // Neutral, balanced 3-point rig for inspecting form.
            container.addChildNode(ambient(NSColor(calibratedWhite: 0.55, alpha: 1), 250))
            container.addChildNode(directional(neutralWhite, 900, from: simd_float3(-0.6, 0.8, 0.7),
                                                center: center, radius: radius, castsShadow: true))   // key
            container.addChildNode(directional(neutralWhite, 350, from: simd_float3(0.8, 0.2, 0.6),
                                                center: center, radius: radius))                       // fill
            container.addChildNode(directional(neutralWhite, 650, from: simd_float3(0.1, 0.7, -0.9),
                                                center: center, radius: radius))                       // rim

        case .outdoor:
            // Warm "sun" + cool sky fill over an azure ambient.
            container.addChildNode(ambient(NSColor(calibratedRed: 0.55, green: 0.65, blue: 0.85, alpha: 1), 300))
            container.addChildNode(directional(NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.84, alpha: 1),
                                                1300, from: simd_float3(0.35, 0.9, 0.35),
                                                center: center, radius: radius, castsShadow: true))    // sun
            container.addChildNode(directional(NSColor(calibratedRed: 0.70, green: 0.80, blue: 1.0, alpha: 1),
                                                450, from: simd_float3(-0.5, 0.25, -0.5),
                                                center: center, radius: radius))                       // cool sky fill

        case .darkMood:
            // Cupo: a whisper of cool ambient and one dramatic rim/backlight.
            container.addChildNode(ambient(NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1), 60))
            container.addChildNode(directional(NSColor(calibratedRed: 0.90, green: 0.93, blue: 1.0, alpha: 1),
                                                1100, from: simd_float3(-0.7, 0.55, -0.75),
                                                center: center, radius: radius, castsShadow: true))    // key rim
        }
    }

    private static func ambient(_ color: NSColor, _ intensity: CGFloat) -> SCNNode {
        let light = SCNLight()
        light.type = .ambient
        light.color = color
        light.intensity = intensity
        let node = SCNNode()
        node.light = light
        return node
    }

    /// A directional light shining *toward* `center` from the `from` direction
    /// (a unit-ish vector pointing to where the light sits). Position only fixes
    /// orientation — directional lights are distance-independent — so any radius
    /// multiple works; we scale it so the node sits comfortably outside the model.
    private static func directional(_ color: NSColor, _ intensity: CGFloat,
                                    from: simd_float3, center: simd_float3, radius: Float,
                                    castsShadow: Bool = false) -> SCNNode {
        let light = SCNLight()
        light.type = .directional
        light.color = color
        light.intensity = intensity
        if castsShadow {
            light.castsShadow = true
            light.shadowMode = .deferred
            light.shadowSampleCount = 8
            light.shadowRadius = 3
            light.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.45)
        }
        let node = SCNNode()
        node.light = light
        node.simdPosition = center + simd_normalize(from) * Swift.max(radius * 4, 4)
        node.look(at: SCNVector3(center))
        return node
    }
}
