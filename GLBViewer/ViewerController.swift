import SwiftUI
import SceneKit
import AppKit
import simd

/// Bridge between the SwiftUI toolbar and the real `SCNView`. Buttons talk to
/// this object, never to SceneKit directly.
final class ViewerController: ObservableObject {
    weak var scnView: SCNView?

    @Published var isWireframe = false
    @Published var isGridVisible = false

    private var gridNode: SCNNode?
    private var cameraNode: SCNNode?
    private var currentBounds: SceneBounds?

    // MARK: - Attach

    func attach(scnView: SCNView, scene: SCNScene) {
        self.scnView = scnView
        scnView.scene = scene
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1.0)
        scnView.rendersContinuously = true

        let bounds = SceneBounds.compute(for: scene.rootNode)
        currentBounds = bounds

        setupCamera(in: scene, bounds: bounds)
        setupGrid(in: scene, bounds: bounds)

        scnView.debugOptions = isWireframe ? [.showWireframe] : []
        fitToView(animated: false)
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
        guard let scnView, let cameraNode, let camera = cameraNode.camera else { return }
        let bounds = currentBounds ?? SceneBounds.compute(for: scnView.scene?.rootNode ?? SCNNode())
        guard let bounds else { return }

        let solution = CameraFit.solve(bounds: bounds, fieldOfViewDegrees: fieldOfView)

        // Adapt clipping planes so tiny and huge models both render.
        camera.zNear = solution.zNear
        camera.zFar = solution.zFar

        let apply = {
            self.cameraNode?.simdPosition = solution.position
            self.cameraNode?.look(at: SCNVector3(solution.target))
        }

        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.35
            apply()
            SCNTransaction.commit()
        } else {
            apply()
        }
    }

    func zoom(by factor: Float) {
        guard let pov = scnView?.pointOfView else { return }
        // Move along the camera's forward axis; scale step by model size.
        let step = (currentBounds?.radius ?? 1) * factor
        pov.simdWorldPosition += pov.simdWorldFront * step
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
        scnView?.debugOptions = isWireframe ? [.showWireframe] : []
    }

    // MARK: - Screenshot

    func takeScreenshot() {
        guard let scnView else { return }
        let image = scnView.snapshot()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "glbviewer-screenshot.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: url)
        }
    }

    // MARK: - Fullscreen

    func toggleFullScreen() {
        scnView?.window?.toggleFullScreen(nil)
    }
}
