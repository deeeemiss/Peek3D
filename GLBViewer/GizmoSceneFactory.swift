import SceneKit
import AppKit
import simd

/// Builds the little XYZ orientation gizmo scene (bottom-right corner).
/// Red = X, Green = Y, Blue = Z. Positive ends are bright labelled balls,
/// negative ends are small dim dots — same idea as the reference screenshot.
enum GizmoSceneFactory {
    static let axesRootName = "axesRoot"

    /// World-space unit direction for each clickable axis node, keyed by
    /// node name (see `addAxis`). Used to snap the main camera on click.
    static let axisDirections: [String: simd_float3] = [
        "axis+X": simd_float3(1, 0, 0), "axis-X": simd_float3(-1, 0, 0),
        "axis+Y": simd_float3(0, 1, 0), "axis-Y": simd_float3(0, -1, 0),
        "axis+Z": simd_float3(0, 0, 1), "axis-Z": simd_float3(0, 0, -1),
    ]

    /// Tooltip text for the bright, positive-end nodes only. The dim
    /// negative ends are just as clickable but stay unlabeled by design.
    static let axisTooltips: [String: String] = [
        "axis+X": "Side view",
        "axis+Y": "Top view",
        "axis+Z": "Front view",
    ]

    static func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        let axesRoot = SCNNode()
        axesRoot.name = axesRootName
        addAxis(to: axesRoot, direction: simd_float3(1, 0, 0), color: NSColor(red: 0.93, green: 0.24, blue: 0.36, alpha: 1), label: "X")
        addAxis(to: axesRoot, direction: simd_float3(0, 1, 0), color: NSColor(red: 0.40, green: 0.82, blue: 0.40, alpha: 1), label: "Y")
        addAxis(to: axesRoot, direction: simd_float3(0, 0, 1), color: NSColor(red: 0.29, green: 0.56, blue: 0.98, alpha: 1), label: "Z")
        scene.rootNode.addChildNode(axesRoot)

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 1.5
        cameraNode.camera = camera
        cameraNode.simdPosition = simd_float3(0, 0, 4)
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.name = "gizmoRoot"

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 1000
        scene.rootNode.addChildNode(ambient)

        return scene
    }

    private static func addAxis(to root: SCNNode, direction: simd_float3, color: NSColor, label: String) {
        // Shaft
        let shaft = SCNCylinder(radius: 0.035, height: 0.7)
        shaft.firstMaterial?.diffuse.contents = color
        shaft.firstMaterial?.lightingModel = .constant
        let shaftNode = SCNNode(geometry: shaft)
        shaftNode.simdPosition = direction * 0.35
        shaftNode.simdOrientation = orientation(forYAlignedTo: direction)
        root.addChildNode(shaftNode)

        // Positive tip: bright labelled ball
        let tip = SCNSphere(radius: 0.16)
        tip.firstMaterial?.diffuse.contents = color
        tip.firstMaterial?.lightingModel = .constant
        let tipNode = SCNNode(geometry: tip)
        tipNode.name = "axis+\(label)"
        tipNode.simdPosition = direction * 0.7
        root.addChildNode(tipNode)

        if let letter = makeLabel(label) {
            letter.simdPosition = direction * 0.7
            letter.constraints = [SCNBillboardConstraint()]
            root.addChildNode(letter)
        }

        // Negative tip: small dim dot
        let neg = SCNSphere(radius: 0.11)
        let dim = color.withAlphaComponent(0.9).blended(withFraction: 0.55, of: .black) ?? color
        neg.firstMaterial?.diffuse.contents = dim
        neg.firstMaterial?.lightingModel = .constant
        let negNode = SCNNode(geometry: neg)
        negNode.name = "axis-\(label)"
        negNode.simdPosition = -direction * 0.7
        root.addChildNode(negNode)
    }

    private static func makeLabel(_ text: String) -> SCNNode? {
        let t = SCNText(string: text, extrusionDepth: 0)
        t.font = NSFont.systemFont(ofSize: 1.1, weight: .bold)
        t.flatness = 0.05
        t.firstMaterial?.diffuse.contents = NSColor.white
        t.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: t)
        // Center the text on its own origin.
        let (minB, maxB) = node.boundingBox
        node.pivot = SCNMatrix4MakeTranslation(
            (minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, 0)
        node.simdScale = simd_float3(repeating: 0.18)
        return node
    }

    /// Quaternion that rotates the cylinder's default +Y axis onto `dir`.
    private static func orientation(forYAlignedTo dir: simd_float3) -> simd_quatf {
        let up = simd_float3(0, 1, 0)
        let d = simd_normalize(dir)
        let dot = simd_dot(up, d)
        if dot > 0.9999 { return simd_quatf(angle: 0, axis: up) }
        if dot < -0.9999 { return simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0)) }
        let axis = simd_normalize(simd_cross(up, d))
        return simd_quatf(angle: acos(dot), axis: axis)
    }
}
