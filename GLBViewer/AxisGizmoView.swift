import SwiftUI
import SceneKit
import simd

/// Small SCNView whose axes mirror the main camera's orientation each frame.
///
/// A world axis `d` seen from a camera with world orientation `q` appears at
/// `q⁻¹ · d`, so we set the gizmo's axes to `simd_inverse(q)`. The gizmo camera
/// itself stays fixed looking down −Z. The main `SCNView` is read from the
/// controller every frame (it is created asynchronously, so a one-shot capture
/// could miss it).
struct AxisGizmoView: NSViewRepresentable {
    @ObservedObject var controller: ViewerController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.scene = GizmoSceneFactory.makeScene()
        view.allowsCameraControl = false
        view.rendersContinuously = true

        context.coordinator.axesRoot = view.scene?.rootNode.childNode(
            withName: GizmoSceneFactory.axesRootName, recursively: true)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.controller = controller
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        weak var controller: ViewerController?
        weak var axesRoot: SCNNode?

        init(controller: ViewerController) {
            self.controller = controller
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let q = controller?.scnView?.pointOfView?.simdWorldOrientation,
                  let axesRoot else { return }
            axesRoot.simdOrientation = simd_inverse(q)
        }
    }
}
