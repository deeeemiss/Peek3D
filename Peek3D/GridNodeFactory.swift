import SceneKit
import AppKit
import simd

/// Builds a flat reference grid on the ground plane (XZ), sized to the model.
enum GridNodeFactory {
    /// - Parameters:
    ///   - size: full width/depth of the grid in world units.
    ///   - divisions: number of cells per side.
    static func makeGrid(size: Float, divisions: Int) -> SCNNode {
        let container = SCNNode()
        let step = size / Float(max(divisions, 1))
        let half = size / 2

        for i in 0...divisions {
            let offset = -half + Float(i) * step
            container.addChildNode(SCNNode(geometry: line(
                from: simd_float3(-half, 0, offset), to: simd_float3(half, 0, offset))))
            container.addChildNode(SCNNode(geometry: line(
                from: simd_float3(offset, 0, -half), to: simd_float3(offset, 0, half))))
        }
        return container
    }

    private static func line(from a: simd_float3, to b: simd_float3) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: [SCNVector3(a), SCNVector3(b)])
        let element = SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = NSColor.white.withAlphaComponent(0.12)
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
}
