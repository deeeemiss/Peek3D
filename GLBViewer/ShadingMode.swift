import SceneKit
import AppKit
import CoreGraphics
import simd

/// The five selectable shading (material) modes.
///
/// `standard` is the model's real, file-authored materials untouched. The other
/// four override the materials of the model's own nodes to inspect a specific
/// aspect (surface orientation, curvature, base colour, UV mapping). They are an
/// axis ORTHOGONAL to both the wireframe toggle (`material.fillMode`) and the
/// lighting preset — see `ViewerController` for how they coexist.
///
/// - `normals`, `matcap`, `unlit` deliberately ignore scene lights (that is the
///   point of each): normals/matcap fully replace the fragment colour, unlit uses
///   the `.constant` lighting model.
/// - `uvChecker` DOES respond to lights (uses `.blinn`) so surface shape still
///   reads while the checker exposes the UV layout.
enum ShadingMode: String, CaseIterable, Identifiable {
    case standard    // "Predefinito" — the file's own materials
    case normals     // color-coded view-space normals
    case matcap      // procedural matcap sampled by view-space normal
    case unlit       // base colour only, no lighting (.constant)
    case uvChecker   // procedural checkerboard on the real UVs (lit)

    var id: String { rawValue }

    /// Italian label shown in the toolbar menu.
    var displayName: String {
        switch self {
        case .standard:  return "Predefinito"
        case .normals:   return "Normali"
        case .matcap:    return "Matcap"
        case .unlit:     return "Unlit"
        case .uvChecker: return "UV checker"
        }
    }

    /// SF Symbol used on the toolbar trigger; reflects the active mode as a quick
    /// visual cue. All exist on macOS 13. The tile is a fixed size so this never
    /// shifts layout.
    var iconName: String {
        switch self {
        case .standard:  return "circle.lefthalf.filled"
        case .normals:   return "move.3d"
        case .matcap:    return "circle.righthalf.filled"
        case .unlit:     return "lightbulb.slash"
        case .uvChecker: return "checkerboard.rectangle"
        }
    }
}

/// Produces the SceneKit materials that realise a `ShadingMode` for one geometry.
///
/// Deliberately view-independent (mirrors `LightingRig`): it maps a geometry's
/// ORIGINAL materials to the override materials for a mode, so the live viewer
/// and the offscreen self-test shade models identically. It never mutates the
/// originals — `unlit` clones them; the other modes build fresh materials — so
/// restoring `standard` just reassigns the saved originals.
enum ShadingMaterialFactory {

    /// Override materials for `mode`, given a geometry's original materials.
    /// `standard` returns the originals unchanged (the caller normally restores
    /// them directly, but this keeps the mapping total).
    static func materials(for mode: ShadingMode, original: [SCNMaterial]) -> [SCNMaterial] {
        switch mode {
        case .standard:
            return original
        case .normals:
            // One material suffices: SceneKit clamps a geometry's element→material
            // index, so every element renders the same normal-coloured override.
            return [makeNormalsMaterial()]
        case .matcap:
            return [makeMatcapMaterial()]
        case .uvChecker:
            return [makeCheckerMaterial()]
        case .unlit:
            // Keep one override PER original slot so each slot's own base colour /
            // diffuse texture is preserved — only the lighting model changes.
            return original.map(makeUnlitMaterial(from:))
        }
    }

    // MARK: - Per-mode materials

    /// Color-codes the view-space surface normal into RGB. Written at the FRAGMENT
    /// stage so it fully replaces the output colour and is immune to the active
    /// lighting model / preset. `.constant` is a belt-and-suspenders fallback.
    private static func makeNormalsMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.shaderModifiers = [
            .fragment: "_output.color = vec4(normalize(_surface.normal) * 0.5 + 0.5, 1.0);"
        ]
        return m
    }

    /// Samples the procedural matcap texture by the view-space normal's XY,
    /// producing a fixed studio-sphere look that tracks orientation as the camera
    /// orbits. The matcap rides the built-in `diffuse` slot and is read through
    /// SceneKit's guaranteed built-in sampler `u_diffuseTexture` — a custom
    /// `#pragma arguments sampler2D` bound via KVC resolved to the default
    /// (magenta) texture in the offscreen render path, so this uses the built-in
    /// binding instead. The fragment stage fully replaces the colour, so the
    /// normal diffuse contribution (and lighting) is bypassed by design.
    private static func makeMatcapMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = matcapImage
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.shaderModifiers = [
            .fragment: """
            vec3 mcn = normalize(_surface.normal);
            vec2 mcuv = mcn.xy * 0.5 + 0.5;
            _output.color = texture2D(u_diffuseTexture, vec2(mcuv.x, 1.0 - mcuv.y));
            """
        ]
        return m
    }

    /// Base colour only, no lighting. Clones the original so its diffuse
    /// (texture or colour) is preserved and just switches to `.constant`.
    private static func makeUnlitMaterial(from original: SCNMaterial) -> SCNMaterial {
        let m = original.copy() as! SCNMaterial
        m.lightingModel = .constant
        m.shaderModifiers = nil // defensive: originals carry none
        return m
    }

    /// Procedural checkerboard on the real UVs, still lit (so form reads while the
    /// grid exposes UV stretching). `.repeat` + nearest filtering keep the cells
    /// crisp and correct when UVs run outside [0,1].
    private static func makeCheckerMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = checkerImage
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.magnificationFilter = .nearest
        m.diffuse.minificationFilter = .linear
        m.isDoubleSided = true
        return m
    }

    // MARK: - Procedural textures (generated once, no shipped asset)

    /// A shaded sphere (radial body gradient + upper-left specular) used as the
    /// matcap. Only the inscribed disk is ever sampled (|normal.xy| <= 1); the
    /// dark corners fill the unreachable remainder.
    static let matcapImage: NSImage = makeMatcapImage()

    /// An 8x8 two-tone checkerboard for UV inspection.
    static let checkerImage: NSImage = makeCheckerImage()

    private static func makeMatcapImage(_ dim: Int = 256) -> NSImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: dim, height: dim,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage()
        }
        let d = CGFloat(dim)
        let center = CGPoint(x: d / 2, y: d / 2)

        // Dark backdrop for the never-sampled corners.
        ctx.setFillColor(NSColor(calibratedWhite: 0.05, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: d, height: d))

        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: 0, y: 0, width: d, height: d))
        ctx.clip()

        // Body: bright core fading to a dark rim (spherical shading).
        let bodyColors = [
            NSColor(calibratedRed: 0.58, green: 0.62, blue: 0.70, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.30, green: 0.33, blue: 0.40, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.11, alpha: 1).cgColor
        ] as CFArray
        let bodyGrad = CGGradient(colorsSpace: cs, colors: bodyColors,
                                  locations: [0.0, 0.68, 1.0])!
        ctx.drawRadialGradient(bodyGrad, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: d / 2,
                               options: [.drawsAfterEndLocation])

        // Specular highlight, upper-left (CG origin is bottom-left, so high y = top).
        let hlColors = [
            NSColor(calibratedWhite: 1.0, alpha: 0.95).cgColor,
            NSColor(calibratedWhite: 1.0, alpha: 0.0).cgColor
        ] as CFArray
        let hlGrad = CGGradient(colorsSpace: cs, colors: hlColors, locations: [0.0, 1.0])!
        let hl = CGPoint(x: d * 0.34, y: d * 0.68)
        ctx.drawRadialGradient(hlGrad, startCenter: hl, startRadius: 0,
                               endCenter: hl, endRadius: d * 0.32, options: [])
        ctx.restoreGState()

        guard let cg = ctx.makeImage() else { return NSImage() }
        return NSImage(cgImage: cg, size: NSSize(width: d, height: d))
    }

    private static func makeCheckerImage(_ dim: Int = 256, cells: Int = 8) -> NSImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: dim, height: dim,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage()
        }
        let cell = CGFloat(dim) / CGFloat(cells)
        let light = NSColor(calibratedWhite: 0.86, alpha: 1).cgColor
        let dark = NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.30, alpha: 1).cgColor
        for row in 0..<cells {
            for col in 0..<cells {
                ctx.setFillColor((row + col) % 2 == 0 ? light : dark)
                ctx.fill(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                                width: cell, height: cell))
            }
        }
        guard let cg = ctx.makeImage() else { return NSImage() }
        return NSImage(cgImage: cg, size: NSSize(width: dim, height: dim))
    }
}
