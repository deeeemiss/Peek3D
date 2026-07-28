import SwiftUI
import AppKit

/// Vertical toolbar on the right edge. Active toggles glow green (see reference).
struct ViewerToolbar: View {
    @ObservedObject var controller: ViewerController
    @Binding var showInfo: Bool

    var body: some View {
        VStack(spacing: 6) {
            iconButton("plus.magnifyingglass", label: "Zoom in") { controller.zoom(by: 0.25) }
            iconButton("minus.magnifyingglass", label: "Zoom out") { controller.zoom(by: -0.25) }

            divider

            iconButton("viewfinder", label: "Fit to view") { controller.fitToView() }

            divider

            iconButton("triangle", label: "Wireframe", active: controller.isWireframe) { controller.toggleWireframe() }
            iconButton("circle.grid.3x3", label: "Grid", active: controller.isGridVisible) { controller.toggleGrid() }
            ShadingMenuButton(controller: controller)
            LightingMenuButton(controller: controller)
            iconButton("info.circle", label: "Model info", active: showInfo) { showInfo.toggle() }

            divider

            iconButton("camera", label: "Screenshot") { controller.takeScreenshot() }
            iconButton("arrow.up.left.and.arrow.down.right", label: "Fullscreen") { controller.toggleFullScreen() }
        }
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
        .arrowCursor()
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.1))
            .frame(width: 22, height: 1)
    }

    private func iconButton(_ symbol: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        ToolbarIconButton(symbol: symbol, label: label, active: active, action: action)
    }
}

private struct ToolbarIconButton: View {
    let symbol: String
    let label: String
    var active: Bool = false
    let action: () -> Void

    @State private var isHovering = false
    @State private var tooltipWidth: CGFloat = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(active ? .black : .white.opacity(0.85))
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = inside }
        }
        .overlay(alignment: .leading) {
            if isHovering {
                // `.overlay(alignment: .leading)` aligns the tooltip's own
                // left edge to the button's left edge by default, so it
                // rendered on top of / to the right of the button instead of
                // outside it. Measure its real width and shift it left by
                // exactly that much (+ gap) instead of relying on a custom
                // alignment guide, which didn't take effect here.
                tooltip
                    .offset(x: -(tooltipWidth + 10))
                    .transition(.opacity)
            }
        }
    }

    private var tooltip: some View {
        Text(LocalizedStringKey(label))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                GeometryReader { proxy in
                    Color.black.opacity(0.8)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.12)))
                        .onAppear { tooltipWidth = proxy.size.width }
                }
            )
    }

    private var backgroundColor: Color {
        if active { return Color(red: 0.72, green: 0.9, blue: 0.28) }
        return isHovering ? .white.opacity(0.14) : .clear
    }
}

/// Same hover tooltip `ToolbarIconButton` draws inline, factored out so the two
/// `Menu`-based selectors below (which aren't `Button`s, so they never got that
/// code) show an identical tooltip instead of falling back to the native,
/// slower `.help()` popover.
private struct SidebarTooltip: ViewModifier {
    let label: String
    @State private var isHovering = false
    @State private var tooltipWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.15)) { isHovering = inside }
            }
            .overlay(alignment: .leading) {
                if isHovering {
                    tooltip
                        .offset(x: -(tooltipWidth + 10))
                        .transition(.opacity)
                }
            }
    }

    private var tooltip: some View {
        Text(LocalizedStringKey(label))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                GeometryReader { proxy in
                    Color.black.opacity(0.8)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.12)))
                        .onAppear { tooltipWidth = proxy.size.width }
                }
            )
    }
}

private extension View {
    func sidebarTooltip(_ label: String) -> some View {
        modifier(SidebarTooltip(label: label))
    }
}

/// Transparent hover-only catcher, click-through. `Menu` (`.menuStyle(.borderlessButton)`)
/// doesn't forward enter/exit events to SwiftUI's `.onHover`/`.help()` — confirmed by
/// QA: no tooltip and no pointing-hand cursor ever appeared on either Menu-based
/// toolbar icon. `NSTrackingArea` fires independently of hit-testing, so overriding
/// `hitTest` to return nil (letting clicks fall through to the Menu underneath)
/// still lets this view see mouse enter/exit.
private struct HoverCatcher: NSViewRepresentable {
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverCatcherView {
        let view = HoverCatcherView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: HoverCatcherView, context: Context) {
        nsView.onHover = onHover
    }
}

private final class HoverCatcherView: NSView {
    var onHover: (Bool) -> Void = { _ in }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

/// Shading-mode selector: an icon tile styled like the other toolbar buttons that
/// opens a `Menu` of the five modes with a checkmark on the active one (same
/// pattern as `LightingMenuButton`). Glows green while any non-Default mode is
/// active. The tile icon mirrors the active mode for a quick at-a-glance cue.
/// Independent of the separate wireframe toggle — the two compose freely.
private struct ShadingMenuButton: View {
    @ObservedObject var controller: ViewerController
    @State private var isHovering = false

    private var active: Bool { controller.shadingMode != .standard }

    var body: some View {
        Menu {
            Section("Shading") {
                ForEach(ShadingMode.allCases) { mode in
                    Button {
                        controller.setShadingMode(mode)
                    } label: {
                        if mode == controller.shadingMode {
                            Label(mode.displayName, systemImage: "checkmark")
                        } else {
                            Text(mode.displayName)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: controller.shadingMode.iconName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? .black : .white.opacity(0.85))
        }
        // Applied to the Menu itself, not just the label's Image: an
        // NSMenu-backed borderless Menu carries its own chrome/padding that
        // ignores a frame set only on the inner content, so it rendered
        // taller than the plain `Button`-based icons and threw off the
        // sidebar's vertical rhythm. Constraining the outer control directly
        // matches the 34x34 box every other icon uses.
        .frame(width: 34, height: 34)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 9))
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .overlay(HoverCatcher { inside in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = inside }
            if inside { NSCursor.pointingHand.set() }
        })
        .sidebarTooltip("Shading")
    }

    private var backgroundColor: Color {
        if active { return Color(red: 0.72, green: 0.9, blue: 0.28) }
        return isHovering ? .white.opacity(0.14) : .clear
    }
}

/// Lighting-preset selector: an icon tile styled like the other toolbar buttons
/// that opens a `Menu` of the four presets with a checkmark on the active one
/// (same pattern as `TimelineControlsView`'s animation menu). Glows green while
/// any non-Default preset is active, matching the toggle buttons. The tile icon
/// mirrors the active preset for a quick at-a-glance cue.
private struct LightingMenuButton: View {
    @ObservedObject var controller: ViewerController
    @State private var isHovering = false

    private var active: Bool { controller.lightingPreset != .standard }

    var body: some View {
        Menu {
            ForEach(LightingPreset.allCases) { preset in
                Button {
                    controller.setLightingPreset(preset)
                } label: {
                    if preset == controller.lightingPreset {
                        Label(preset.displayName, systemImage: "checkmark")
                    } else {
                        Text(preset.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: controller.lightingPreset.iconName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? .black : .white.opacity(0.85))
        }
        // See ShadingMenuButton's comment: frame must sit on the Menu itself.
        .frame(width: 34, height: 34)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 9))
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .overlay(HoverCatcher { inside in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = inside }
            if inside { NSCursor.pointingHand.set() }
        })
        .sidebarTooltip("Lighting")
    }

    private var backgroundColor: Color {
        if active { return Color(red: 0.72, green: 0.9, blue: 0.28) }
        return isHovering ? .white.opacity(0.14) : .clear
    }
}
