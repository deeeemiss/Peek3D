import SwiftUI
import SceneKit
import AppKit
import UniformTypeIdentifiers

/// Renders one open document. `url` comes from `DocumentGroup(viewing:)`'s
/// `FileDocumentConfiguration.fileURL` — always a real file (`.viewing`
/// documents have no blank/untitled state), loaded once on appear. Dropping a
/// different file over an already-loaded scene still swaps the model in place
/// rather than opening a new window — that part is unchanged from before the
/// document-based rewrite.
struct ContentView: View {
    let url: URL

    @StateObject private var controller = ViewerController()
    @StateObject private var session = ModelSession()
    @State private var showInfo = UserDefaults.standard.object(forKey: SettingsKey.showInfo) as? Bool ?? true
    @State private var gizmoHoverLabel: String?


    private var window: some View {
        ZStack {
            Color(white: 0.04).ignoresSafeArea()

            if let scene = session.scene {
                SceneContainerView(scene: scene, animations: session.animations, controller: controller)
                    .accessibilityElement()
                    .accessibilityLabel(Text("3D viewport"))
                    .ignoresSafeArea()
                    .grabCursor()

                overlays
            }

            // With a model on screen the notices sit in the top row (see
            // `overlays`), clear of the info panel and timeline at the bottom.
            if session.scene == nil {
                VStack {
                    Spacer()
                    notices
                }
                .padding(.bottom, 40)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .task(id: url) { load(url: url) }
        .onChange(of: session.stats?.fileName) { name in
            controller.currentModelName = ((name ?? "Peek3D") as NSString).deletingPathExtension
        }
        // A failed replacement leaves the previous model on screen: the error
        // is a notice then, not a state, so it goes away on its own.
        .task(id: session.errorMessage) {
            guard session.errorMessage != nil, session.scene != nil else { return }
            try? await Task.sleep(for: .seconds(8))
            session.errorMessage = nil
        }
        .onAppear(perform: closeWelcomeWindows)
        // Tells the "Scene" menu (Peek3DApp.swift) this window is a viewer,
        // not the Welcome window — see `peek3dViewerFocused`. Scene-level, not
        // `.focusedValue`: that one requires an actual SwiftUI-focused control
        // (`@FocusState`) somewhere in this hierarchy, which nothing here has;
        // `.focusedSceneValue` only needs this window to be key, which is what
        // "menu applies to the frontmost viewer" actually means.
        // Only once a model is on screen: before that (loading, failed) the
        // Scene menu's commands have nothing to act on.
        .focusedSceneValue(\.peek3dViewerFocused, session.scene != nil)
        // Same rationale as above: lets the "Scene" menu's Shading/Lighting
        // submenus show a checkmark + live icon for whichever mode/preset is
        // active on the frontmost viewer, mirroring `ViewerToolbar`'s own
        // menu buttons.
        .focusedSceneValue(\.peek3dShadingMode, controller.shadingMode)
        .focusedSceneValue(\.peek3dLightingPreset, controller.lightingPreset)
        // Allow replacing the model by dropping a new file over the loaded
        // scene — this does NOT open a new document/window, it just swaps
        // this window's content; the document itself keeps pointing at `url`.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { droppedURL, _ in
                guard let droppedURL else { return }
                DispatchQueue.main.async { load(url: droppedURL) }
            }
            return true
        }
    }

    // Split from `body` only so the compiler can type-check the long chains.
    var body: some View {
        window
        // Menu-bar commands (Peek3DApp.swift) post to `NotificationCenter.default`,
        // which every open document window's `ContentView` subscribes to — with
        // several windows open, an unguarded handler here would apply the
        // command to ALL of them at once instead of just the one the user is
        // looking at. `guardKeyWindow` drops the notification unless this
        // window is actually key, matching what the "Scene" menu's disabled
        // state (`peek3dViewerFocused`) already implies: these commands act on
        // the focused viewer only.
        .onReceive(NotificationCenter.default.publisher(for: .peek3dFitToView)) { _ in guardKeyWindow { controller.fitToView() } }
        .onReceive(NotificationCenter.default.publisher(for: .peek3dToggleWireframe)) { _ in guardKeyWindow { controller.toggleWireframe() } }
        .onReceive(NotificationCenter.default.publisher(for: .peek3dToggleGrid)) { _ in guardKeyWindow { controller.toggleGrid() } }
        .onReceive(NotificationCenter.default.publisher(for: .peek3dToggleInfo)) { _ in guardKeyWindow { showInfo.toggle() } }
        .onReceive(NotificationCenter.default.publisher(for: .peek3dTakeScreenshot)) { _ in guardKeyWindow { controller.takeScreenshot() } }
        .onReceive(NotificationCenter.default.publisher(for: .peek3dSetShadingMode)) { note in
            guard let raw = note.userInfo?["mode"] as? String, let mode = ShadingMode(rawValue: raw) else { return }
            guardKeyWindow { controller.setShadingMode(mode) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .peek3dSnapToAxis)) { note in
            guard let axis = note.userInfo?["axis"] as? String, let direction = GizmoSceneFactory.axisDirections[axis] else { return }
            guardKeyWindow { controller.snapToAxis(direction) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .peek3dZoom)) { note in
            guard let delta = note.userInfo?["delta"] as? Double else { return }
            guardKeyWindow { controller.zoom(by: Float(delta)) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .peek3dSetLightingPreset)) { note in
            guard let raw = note.userInfo?["preset"] as? String, let preset = LightingPreset(rawValue: raw) else { return }
            guardKeyWindow { controller.setLightingPreset(preset) }
        }
    }

    /// Runs `action` only if this window is the key window — see the
    /// `.onReceive` chain above for why this guard exists.
    private func guardKeyWindow(_ action: () -> Void) {
        guard controller.scnView?.window?.isKeyWindow == true else { return }
        action()
    }

    /// The Welcome screen is a launcher, like Xcode's: once a document window
    /// exists it has done its job, whichever way the file was opened (Welcome
    /// itself, Finder, the Dock, ⌘O). `dismissWindow` would be the SwiftUI way
    /// but needs macOS 14; the deployment target is 13, so match the window by
    /// the identifier SwiftUI gives every instance of the "welcome" scene.
    private func closeWelcomeWindows() {
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("welcome") == true {
            window.close()
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlays: some View {
        // Top row — file badge (left) and notices (center). Notices lived at
        // the bottom center and covered the info panel on normal-width
        // windows; up here nothing else competes for the space except the
        // toolbar's column, which is reserved on the right.
        VStack {
            HStack(alignment: .top, spacing: 0) {
                fileBadge
                Spacer(minLength: 12)
                notices
                Spacer(minLength: 12)
                Color.clear.frame(width: 66, height: 1) // toolbar column + its padding
            }
            Spacer()
        }
        .padding(20)

        // Bottom row — info panel (left), timeline (center) and a reserved
        // gizmo-width column (right) share ONE HStack so they never overlap.
        // Each floated independently before with a hardcoded side padding
        // guessed for typical window widths; below that width the info panel
        // and the timeline could collide. Sharing the row lets SwiftUI's own
        // layout (the two Spacers compress first) keep them apart instead.
        //
        // Pinned to the bottom edge with the same `VStack { Spacer(); row }`
        // idiom the file badge / gizmo overlays use elsewhere in this ZStack —
        // a bare `.frame(maxHeight: .infinity, alignment: .bottom)` on the row
        // itself did NOT reliably reach the bottom edge here (it floated at
        // mid-height, overlapping the model instead of clearing it).
        //
        // `alignment: .bottom` on the HStack itself matters too: an HStack's
        // default is `.center`, so the short timeline pill was vertically
        // centered against the much-taller info panel — i.e. floating at the
        // info panel's MIDDLE, not flush with its bottom edge (the actual bug
        // in this screenshot). Bottom-aligning both makes their bottom edges
        // match, regardless of the info panel's height.
        VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: 16) {
                if showInfo, let stats = session.stats {
                    InfoPanelView(stats: stats)
                        .arrowCursor()
                        .transition(.opacity)
                        .fixedSize()
                }
                Spacer(minLength: 12)
                if controller.hasAnimations {
                    TimelineControlsView(controller: controller)
                        // Playback controls keep left-to-right even in Arabic
                        // (Apple HIG, Right to left): they follow the direction
                        // time moves, not the reading direction.
                        .environment(\.layoutDirection, .leftToRight)
                        .frame(maxWidth: 460)
                        .transition(.opacity)
                }
                Spacer(minLength: 12)
                Color.clear.frame(width: 96) // reserves the axis gizmo's footprint
            }
        }
        .padding(20)

        // Toolbar — right edge, vertically centered in the space ABOVE the
        // axis gizmo's corner. A plain center (no bottom reservation) let the
        // toolbar's last icons (camera / fullscreen) sink into the gizmo's
        // 96pt corner on short windows — the reported "broken gizmo" was
        // actually the fullscreen icon's rounded corner bleeding over it.
        // Same class of bug as the info panel / timeline row above; fixed the
        // same way, by reserving the corner instead of centering blindly.
        HStack {
            Spacer()
            VStack {
                Spacer()
                ViewerToolbar(controller: controller, showInfo: $showInfo)
                Spacer()
            }
            .padding(.bottom, 132) // clears the gizmo's reserved corner (96 + margins)
        }
        .padding(20)

        // Axis gizmo — bottom-right. Dots are clickable (snap camera to that
        // axis), so it needs real hit-testing, a pointer cursor, and its own
        // tooltip for the three bright positive ends.
        VStack {
            Spacer()
            HStack {
                Spacer()
                AxisGizmoView(controller: controller) { label in
                    withAnimation(.easeOut(duration: 0.15)) { gizmoHoverLabel = label }
                }
                .frame(width: 96, height: 96)
                .accessibilityElement()
                .accessibilityLabel(Text("Axis gizmo"))
                .modifier(GizmoViewActions(controller: controller))
                // Cursor is set per-dot inside AxisGizmoView's own mouse
                // handling (pointing hand only over an actual axis dot,
                // arrow otherwise) — a blanket `.pointerCursor()` here would
                // show the hand over the whole 96x96 box, including the
                // mostly-empty space between dots.
                .overlay(alignment: .top) {
                    if let gizmoHoverLabel {
                        Text(LocalizedStringKey(gizmoHoverLabel))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.12)))
                            .offset(y: -36)
                            .transition(.opacity)
                    }
                }
            }
        }
        .padding(16)
    }

    private var fileBadge: some View {
        HStack(spacing: 7) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 12))
                .accessibilityHidden(true)
            Text(session.stats?.fileName ?? "")
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .hudPanel(cornerRadius: 10)
        .arrowCursor()
    }

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 8) {
            if let errorMessage = session.errorMessage {
                errorBanner(errorMessage)
            }
            if let prompt = session.missingTexturePrompt {
                missingTextureBanner(prompt)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.system(size: 13))
            Button("Dismiss") { session.errorMessage = nil }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Opaque colors: white on the old translucent red/orange fell
        // under WCAG AA (4.48:1 and 2.78:1).
        .background(Color(red: 0.72, green: 0.12, blue: 0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func missingTextureBanner(_ prompt: (modelURL: URL, count: Int)) -> some View {
        // One key with plural variants: languages like Russian and Arabic
        // need several forms, and Japanese/Chinese no space after the number.
        let message = String(localized: "missingTexture.count \(prompt.count)")
        return HStack(spacing: 12) {
            Text(message)
                .font(.system(size: 13))
            Button("Grant folder access") { grantFolderAccessAndRetry(modelURL: prompt.modelURL) }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            Button("Dismiss") { session.missingTexturePrompt = nil }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 1.0, green: 0.68, blue: 0.2), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Loading

    private func load(url: URL) {
        session.load(url: url)
    }

    /// Lets the user grant read access to the model's containing folder (the
    /// App Sandbox only auto-grants the model file itself), then reloads it so
    /// external textures resolve. The granted access lasts for this app session.
    private func grantFolderAccessAndRetry(modelURL: URL) {
        let panel = NSOpenPanel()
        panel.message = String(localized: "folderAccess.message \(modelURL.lastPathComponent)")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = modelURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        // A URL fresh from the panel is already readable for this session;
        // this can return false and still work, so it mustn't block the reload.
        _ = folderURL.startAccessingSecurityScopedResource()
        session.missingTexturePrompt = nil
        load(url: modelURL)
    }
}

/// The gizmo's dots are only reachable with a mouse; VoiceOver gets the six
/// views as named actions on the gizmo element instead.
private struct GizmoViewActions: ViewModifier {
    let controller: ViewerController

    func body(content: Content) -> some View {
        // Reversed: each wrap lands in front of the previous one in the list.
        GizmoSceneFactory.views.reversed().reduce(AnyView(content)) { view, entry in
            AnyView(view.accessibilityAction(named: Text(LocalizedStringKey(entry.label))) {
                if let direction = GizmoSceneFactory.axisDirections[entry.axis] { controller.snapToAxis(direction) }
            })
        }
    }
}

/// Dark backing shared by the overlays floating on the 3D view. Opaque
/// enough that grey text stays readable over a white model (WCAG AA);
/// solid with Reduce Transparency, stronger edge with Increase Contrast.
private struct HUDPanel: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .background(.black.opacity(reduceTransparency ? 0.95 : 0.8), in: shape)
            .background(.ultraThinMaterial.opacity(reduceTransparency ? 0 : 0.5), in: shape)
            .overlay(shape.stroke(.white.opacity(contrast == .increased ? 0.5 : 0.12)))
    }
}

extension View {
    func hudPanel(cornerRadius: CGFloat) -> some View {
        modifier(HUDPanel(cornerRadius: cornerRadius))
    }
}
