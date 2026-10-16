import Foundation
import SceneKit
import simd

/// World-space axis-aligned bounding box for a whole node hierarchy.
///
/// `SCNNode.boundingBox` only covers a single node's own geometry and ignores
/// child transforms, so for a loaded model (a container node with many
/// transformed children) it is unreliable. Here we union every geometry node's
/// local bounding box after transforming its 8 corners into world space.
struct SceneBounds {
    let min: simd_float3
    let max: simd_float3
    /// True when a mesh is skinned or has blend shapes: the box is measured on
    /// the rest pose, and the animation can reach outside it.
    var deforms = false

    var center: simd_float3 { (min + max) * 0.5 }
    var extents: simd_float3 { max - min }
    /// Radius of the bounding sphere that encloses the box.
    /// Deforming meshes get 30% headroom so an animated pose stays in frame.
    // ponytail: fixed headroom, sample the clip's poses if a model still clips.
    var radius: Float { simd_length(extents) * 0.5 * (deforms ? 1.3 : 1) }

    static func compute(for root: SCNNode) -> SceneBounds? {
        var minB = simd_float3(repeating: .greatestFiniteMagnitude)
        var maxB = simd_float3(repeating: -.greatestFiniteMagnitude)
        var found = false
        var deforms = false

        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            if node.skinner != nil || node.morpher != nil { deforms = true }
            let (lmin, lmax) = node.boundingBox
            let lo = simd_float3(lmin)
            let hi = simd_float3(lmax)
            let world = node.simdWorldTransform

            // Transform all 8 corners; keep the world-space AABB of the result.
            for xi in [lo.x, hi.x] {
                for yi in [lo.y, hi.y] {
                    for zi in [lo.z, hi.z] {
                        let corner = world * simd_float4(xi, yi, zi, 1)
                        let p = simd_float3(corner.x, corner.y, corner.z)
                        minB = simd_min(minB, p)
                        maxB = simd_max(maxB, p)
                        found = true
                    }
                }
            }
        }

        guard found else { return nil }
        return SceneBounds(min: minB, max: maxB, deforms: deforms)
    }
}
