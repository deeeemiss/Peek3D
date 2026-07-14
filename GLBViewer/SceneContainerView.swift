import SwiftUI
import SceneKit
import AppKit

/// Hosts the real `SCNView` inside SwiftUI and hands it to the controller.
struct SceneContainerView: NSViewRepresentable {
    let scene: SCNScene
    let animations: [ModelAnimation]
    @ObservedObject var controller: ViewerController

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        controller.attach(scnView: view, scene: scene, animations: animations)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        // Re-attach only when the model actually changed (replace flow).
        if nsView.scene !== scene {
            controller.attach(scnView: nsView, scene: scene, animations: animations)
        }
    }
}

// Cursor management deliberately avoids both AppKit cursor rects and
// NSCursor.push/pop. Cursor rects only re-fire on a genuine view-bounds
// enter/exit; since the 3D view's bounds span the whole window (the toolbar
// is just a SwiftUI overlay drawn on top of it, not a real clipping region),
// that only ever happens once, letting any later `.set()` from the UI chrome
// permanently override it. Push/pop has the opposite problem: `pop()` only
// undoes our own `push()` calls, so it can never restore a cursor that was
// last set by that one-time native cursor-rect callback either way — either
// approach leaves the grab cursor stuck as whatever the UI last set once you
// hover a single button. Instead every hoverable region here just sets its
// own cursor directly on entry, exhaustively tiling the whole window (3D
// view everywhere as the base layer, chrome on top) — whichever region you
// enter next always sets what it needs, so nothing needs restoring on exit.
extension View {
    /// Grab cursor for the 3D viewport (the drag-to-orbit area).
    func grabCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.openHand.set() }
        }
    }

    /// Standard arrow cursor for non-interactive UI chrome (panels, badges).
    func arrowCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.arrow.set() }
        }
    }

    /// Pointing-hand cursor for clickable controls (toolbar icons, buttons).
    func pointerCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.set() }
        }
    }
}
