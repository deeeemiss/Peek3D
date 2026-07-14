import SceneKit
import simd

/// Single source of truth for framing a model. Used by the live viewer and by
/// the offscreen render self-test, so both frame models identically.
enum CameraFit {
    /// Camera position + near/far that fit `bounds` inside a camera with the
    /// given vertical field of view (degrees).
    static func solve(
        bounds: SceneBounds, fieldOfViewDegrees: Float,
        direction: simd_float3 = simd_normalize(simd_float3(0.55, 0.45, 1.0))
    )
        -> (position: simd_float3, target: simd_float3, zNear: Double, zFar: Double)
    {
        let radius = max(bounds.radius, 0.0001)
        let fov = fieldOfViewDegrees * .pi / 180
        let distance = radius / sin(fov / 2) * 1.05

        let position = bounds.center + simd_normalize(direction) * distance
        let zNear = Double(radius) * 0.001
        let zFar = Double(distance + radius) * 4
        return (position, bounds.center, zNear, zFar)
    }

    /// Builds a fresh camera node already framed on the scene. `fieldOfView` is
    /// treated as vertical so framing is stable across window aspect ratios.
    static func makeFittedCamera(for scene: SCNScene, fieldOfViewDegrees: Float = 50)
        -> SCNNode
    {
        let node = SCNNode()
        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(fieldOfViewDegrees)
        camera.projectionDirection = .vertical
        node.camera = camera

        if let bounds = SceneBounds.compute(for: scene.rootNode) {
            let s = solve(bounds: bounds, fieldOfViewDegrees: fieldOfViewDegrees)
            camera.zNear = s.zNear
            camera.zFar = s.zFar
            node.simdPosition = s.position
            node.look(at: SCNVector3(s.target))
        } else {
            node.simdPosition = simd_float3(0, 0, 5)
        }
        return node
    }
}
