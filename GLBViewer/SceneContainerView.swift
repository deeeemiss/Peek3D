import SwiftUI
import SceneKit

/// Hosts the real `SCNView` inside SwiftUI and hands it to the controller.
struct SceneContainerView: NSViewRepresentable {
    let scene: SCNScene
    @ObservedObject var controller: ViewerController

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        controller.attach(scnView: view, scene: scene)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        // Re-attach only when the model actually changed (replace flow).
        if nsView.scene !== scene {
            controller.attach(scnView: nsView, scene: scene)
        }
    }
}
