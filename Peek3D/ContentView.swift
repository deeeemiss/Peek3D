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
    @State private var scene: SCNScene?
    @State private var stats: ModelStats?
    @State private var animations: [ModelAnimation] = []
    @State private var showInfo = UserDefaults.standard.object(forKey: SettingsKey.showInfo) as? Bool ?? true
    @State private var errorMessage: String?
    @State private var gizmoHoverLabel: String?
    /// Set when an FBX load found external texture references the sandbox
    /// wouldn't let it read — the model itself still loaded fine. Offers a
    /// folder-access prompt + reload instead of silently showing a textureless
    /// model.
    @State private var missingTexturePrompt: (modelURL: URL, count: Int)?
    /// Bumped on every `load(url:)` call and captured by that call's
    /// completion handler. `ModelLoader.load` runs off-main and offers no
    /// ordering guarantee — if the user drops a second file while the first
    /// is still decoding, the two completions can land in either order. Without
    /// this guard, a slow first load finishing AFTER a fast second load would
    /// silently overwrite the newer model/stats with the stale one. Only the
    /// completion whose token still matches the latest `loadGeneration` is
    /// allowed to apply its result.
    @State private var loadGeneration = 0


    var body: some View {
        ZStack {
            Color(white: 0.04).ignoresSafeArea()

            if let scene {
                SceneContainerView(scene: scene, animations: animations, controller: controller)
                    .ignoresSafeArea()
                    .grabCursor()

                overlays
            }

            if let errorMessage {
                errorBanner(errorMessage)
            }

            if let missingTexturePrompt {
                missingTextureBanner(missingTexturePrompt)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .task(id: url) { load(url: url) }
        .onAppear(perform: closeWelcomeWindows)
        // Tells the "Scene" menu (Peek3DApp.swift) this window is a viewer,
        // not the Welcome window — see `peek3dViewerFocused`. Scene-level, not
        // `.focusedValue`: that one requires an actual SwiftUI-focused control
        // (`@FocusState`) somewhere in this hierarchy, which nothing here has;
        // `.focusedSceneValue` only needs this window to be key, which is what
        // "menu applies to the frontmost viewer" actually means.
        .focusedSceneValue(\.peek3dViewerFocused, true)
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
        .onReceive(NotificationCenter.default.publisher(for: .peek3dToggleFullScreen)) { _ in guardKeyWindow { controller.toggleFullScreen() } }
        .onReceive(NotificationCenter.default.publisher(for: .peek3dSetShadingMode)) { note in
            guard let raw = note.userInfo?["mode"] as? String, let mode = ShadingMode(rawValue: raw) else { return }
            guardKeyWindow { controller.setShadingMode(mode) }
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
        // File badge — top-left
        VStack {
            HStack {
                fileBadge
                Spacer()
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
                if showInfo, let stats {
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
            Text(stats?.fileName ?? "")
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)))
        .arrowCursor()
    }

    private func errorBanner(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 40)
        }
    }

    private func missingTextureBanner(_ prompt: (modelURL: URL, count: Int)) -> some View {
        // One key with plural variants: languages like Russian and Arabic
        // need several forms, and Japanese/Chinese no space after the number.
        let message = String(localized: "missingTexture.count \(prompt.count)")
        return VStack {
            Spacer()
            HStack(spacing: 12) {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                Button("Grant folder access") { grantFolderAccessAndRetry(modelURL: prompt.modelURL) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                Button("Dismiss") { missingTexturePrompt = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 40)
        }
    }

    // MARK: - Loading

    private func load(url: URL) {
        errorMessage = nil
        missingTexturePrompt = nil
        loadGeneration += 1
        let generation = loadGeneration
        ModelLoader.load(url: url) { result in
            // A newer load (e.g. a second file dropped before this one
            // finished decoding) has already started or completed — discard
            // this stale result instead of clobbering the newer state.
            guard generation == self.loadGeneration else { return }
            switch result {
            case .success(let model):
                // Set animations before the scene so the new list is in place
                // by the time `SceneContainerView` re-attaches on the scene swap.
                self.animations = model.animations
                self.scene = model.scene
                self.stats = model.stats
                controller.currentModelName = (model.stats.fileName as NSString).deletingPathExtension
                if !model.missingExternalTextureURLs.isEmpty {
                    self.missingTexturePrompt = (url, model.missingExternalTextureURLs.count)
                }
            case .failure(ModelLoadError.needsFolderAccess(let urls)):
                self.missingTexturePrompt = (url, urls.count)
            case .failure(let error):
                self.errorMessage = Self.userMessage(for: error)
            }
        }
    }

    /// Peek3D's own load errors are already localized, user-facing sentences.
    /// Errors from GLTFKit2 and ufbx are English technical text ("The asset
    /// contains invalid JSON data."), so those get a localized generic
    /// message instead, with the detail kept in the log for diagnosis.
    private static func userMessage(for error: Error) -> String {
        if error is GLTFValidator.Invalid || error is ModelLoadError {
            return error.localizedDescription
        }
        NSLog("Peek3D: load failed: %@", String(describing: error))
        return String(localized: "error.openFailed",
                      defaultValue: "This file couldn't be opened. It may be damaged or use a feature Peek3D doesn't support yet.")
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
        missingTexturePrompt = nil
        load(url: modelURL)
    }
}
