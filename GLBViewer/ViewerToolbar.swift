import SwiftUI

/// Vertical toolbar on the right edge. Active toggles glow green (see reference).
struct ViewerToolbar: View {
    @ObservedObject var controller: ViewerController
    @Binding var showInfo: Bool

    var body: some View {
        VStack(spacing: 6) {
            iconButton("plus.magnifyingglass") { controller.zoom(by: -0.25) }
            iconButton("minus.magnifyingglass") { controller.zoom(by: 0.25) }

            divider

            iconButton("viewfinder") { controller.fitToView() }

            divider

            iconButton("triangle", active: controller.isWireframe) { controller.toggleWireframe() }
            iconButton("circle.grid.3x3", active: controller.isGridVisible) { controller.toggleGrid() }
            iconButton("info.circle", active: showInfo) { showInfo.toggle() }

            divider

            iconButton("camera") { controller.takeScreenshot() }
            iconButton("arrow.up.left.and.arrow.down.right") { controller.toggleFullScreen() }
        }
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.1))
            .frame(width: 22, height: 1)
    }

    @ViewBuilder
    private func iconButton(_ symbol: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(active ? .black : .white.opacity(0.85))
                .background(
                    active ? Color(red: 0.72, green: 0.9, blue: 0.28) : .clear,
                    in: RoundedRectangle(cornerRadius: 9)
                )
        }
        .buttonStyle(.plain)
    }
}
