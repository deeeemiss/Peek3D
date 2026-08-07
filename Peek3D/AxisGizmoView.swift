import SwiftUI
import SceneKit
import AppKit
import simd

/// Small SCNView whose axes mirror the main camera's orientation each frame,
/// and whose dots are clickable to snap the main camera onto that axis.
///
/// A world axis `d` seen from a camera with world orientation `q` appears at
/// `q⁻¹ · d`, so we set the gizmo's axes to `simd_inverse(q)`. The gizmo camera
/// itself stays fixed looking down −Z. The main `SCNView` is read from the
/// controller every frame (it is created asynchronously, so a one-shot capture
/// could miss it).
struct AxisGizmoView: NSViewRepresentable {
    @ObservedObject var controller: ViewerController
    var onHoverLabel: (String?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, onHoverLabel: onHoverLabel) }

    func makeNSView(context: Context) -> GizmoSCNView {
        let view = GizmoSCNView(frame: .zero)
        view.backgroundColor = .clear
        view.scene = GizmoSceneFactory.makeScene()
        view.allowsCameraControl = false
        view.rendersContinuously = true
        view.coordinator = context.coordinator

        context.coordinator.axesRoot = view.scene?.rootNode.childNode(
            withName: GizmoSceneFactory.axesRootName, recursively: true)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: GizmoSCNView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.onHoverLabel = onHoverLabel
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        weak var controller: ViewerController?
        weak var axesRoot: SCNNode?
        var onHoverLabel: (String?) -> Void
        /// The dot currently scaled up for hover, so it can be scaled back
        /// down the moment the pointer leaves it (or the whole gizmo).
        private weak var hoveredNode: SCNNode?

        init(controller: ViewerController, onHoverLabel: @escaping (String?) -> Void) {
            self.controller = controller
            self.onHoverLabel = onHoverLabel
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let q = controller?.scnView?.pointOfView?.simdWorldOrientation,
                  let axesRoot else { return }
            axesRoot.simdOrientation = simd_inverse(q)
        }

        func handleClick(at point: CGPoint, in view: SCNView) {
            guard let node = axisNode(at: point, in: view),
                  let name = node.name,
                  let direction = GizmoSceneFactory.axisDirections[name] else { return }
            controller?.snapToAxis(direction)
        }

        func handleHover(at point: CGPoint?, in view: SCNView) {
            let node = point.flatMap { axisNode(at: $0, in: view) }
            setHoveredNode(node)
            let label = node?.name.flatMap { GizmoSceneFactory.axisTooltips[$0] }
            onHoverLabel(label)
            (node != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
        }

        /// Scales the newly-hovered dot up and the previously-hovered one
        /// back down — a quick, explicit nudge so hovering the gizmo feels
        /// clickable even though nothing else on it looks interactive.
        private func setHoveredNode(_ node: SCNNode?) {
            guard node !== hoveredNode else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.12
            hoveredNode?.simdScale = .init(repeating: 1)
            node?.simdScale = .init(repeating: 1.35)
            SCNTransaction.commit()
            hoveredNode = node
        }

        /// The dots render at roughly 10px on screen in a 96x96 view — an
        /// exact-pixel hit test misses on a slightly-off click. Sample a
        /// small cross of points around the click instead of just the one.
        private func axisNode(at point: CGPoint, in view: SCNView) -> SCNNode? {
            let offsets: [CGVector] = [
                .zero, CGVector(dx: 6, dy: 0), CGVector(dx: -6, dy: 0),
                CGVector(dx: 0, dy: 6), CGVector(dx: 0, dy: -6),
            ]
            for offset in offsets {
                let testPoint = CGPoint(x: point.x + offset.dx, y: point.y + offset.dy)
                if let node = view.hitTest(testPoint, options: [:])
                    .first(where: { $0.node.name?.hasPrefix("axis") == true })?.node {
                    return node
                }
            }
            return nil
        }
    }
}

/// SCNView subclass so raw mouse events can be hooked for axis clicks/hover —
/// SwiftUI's `.onTapGesture`/`.onHover` have no way to tell WHICH 3D dot was hit.
final class GizmoSCNView: SCNView {
    weak var coordinator: AxisGizmoView.Coordinator?

    // Without this, a click that also has to bring the window to focus
    // first is sometimes swallowed by that focus-click instead of reaching
    // the axis hit test — one plausible source of "doesn't work every time".
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        coordinator?.handleClick(at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func mouseMoved(with event: NSEvent) {
        coordinator?.handleHover(at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.handleHover(at: nil, in: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self, userInfo: nil))
    }
}
