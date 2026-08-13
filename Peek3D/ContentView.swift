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

    /// Injected by `Peek3DApp`'s `DocumentGroup` closure. `load(url:)` uses
    /// this for the SECOND trial-gate integration point: dropping a new
    /// file onto an already-open document window never re-enters that
    /// closure, so the gate has to live here too. See the closure's own
    /// comment for the full picture.
    @EnvironmentObject private var licenseState: LicenseState

    @StateObject private var controller = ViewerController()
    @State private var scene: SCNScene?
    @State private var stats: ModelStats?
    @State private var animations: [ModelAnimation] = []
    @State private var showInfo = true
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

    /// Critical-phase (3-1 opens remaining) trial nudge — an ephemeral toast,
    /// never a permanent overlay: toolbar/gizmo/info panel are already at
    /// the limit of available space on small windows (see this project's
    /// CLAUDE.md). Shown after each successful load while the trial is in
    /// its critical phase, self-dismisses after ~4s, and a local event
    /// monitor (installed in `.onAppear`) dismisses it early on the user's
    /// first click/scroll/pinch on the scene.
    @State private var showTrialToast = false
    @State private var trialToastDismissWorkItem: DispatchWorkItem?
    @State private var trialToastEventMonitor: Any?

    var body: some View {
        ZStack {
            Color(white: 0.04).ignoresSafeArea()

            if let scene {
                SceneContainerView(scene: scene, animations: animations, controller: controller)
                    .ignoresSafeArea()
                    .grabCursor()

                overlays
                trialToastBanner
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
        .onAppear(perform: installTrialToastEventMonitor)
        .onDisappear(perform: teardownTrialToast)
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

    // MARK: - Trial toast

    /// Top-pinned, informational only — `.allowsHitTesting(false)` so it
    /// never intercepts a camera-orbit drag that happens to start near the
    /// top of the window. Dismissal on user input is handled independently
    /// by the local event monitor below, which watches the window's raw
    /// event stream rather than SwiftUI hit-testing.
    @ViewBuilder
    private var trialToastBanner: some View {
        if showTrialToast, case .trial(let remaining) = licenseState.status {
            VStack {
                Text(TrialCopy.remainingText(remaining))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.peekAmber.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15)))
                    .padding(.top, 16)
                Spacer()
            }
            .allowsHitTesting(false)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Installed once per window lifetime (`.onAppear`); watches for the
    /// user's first mouse-down/scroll/pinch on the whole window — not
    /// SwiftUI gesture recognizers, which would risk stealing events from
    /// `SCNView`'s own native `allowsCameraControl` handling. Returns the
    /// event unchanged so nothing downstream (camera control, menu
    /// shortcuts) is ever affected by this monitor's presence.
    private func installTrialToastEventMonitor() {
        trialToastEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify]
        ) { event in
            dismissTrialToastEarly()
            return event
        }
    }

    private func teardownTrialToast() {
        if let trialToastEventMonitor {
            NSEvent.removeMonitor(trialToastEventMonitor)
        }
        trialToastEventMonitor = nil
        trialToastDismissWorkItem?.cancel()
    }

    /// Called after each successful load — see `load(url:)` — so the nudge
    /// reappears (with a fresh 4s timer) every time a new file is opened
    /// while the trial is in its critical phase, not just once per window.
    private func presentTrialToastIfCritical() {
        guard case .trial(let remaining) = licenseState.status, remaining <= 3 else { return }
        trialToastDismissWorkItem?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { showTrialToast = true }
        let dismissal = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.2)) { showTrialToast = false }
        }
        trialToastDismissWorkItem = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: dismissal)
    }

    private func dismissTrialToastEarly() {
        guard showTrialToast else { return }
        trialToastDismissWorkItem?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { showTrialToast = false }
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
        let message = prompt.count == 1
            ? String(localized: "missingTexture.singular", defaultValue: "1 external texture not loaded (folder permissions).")
            : "\(prompt.count) " + String(localized: "missingTexture.pluralSuffix", defaultValue: "external textures not loaded (folder permissions).")
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
        // Trial gate, second integration point (the first is the
        // `DocumentGroup` closure in Peek3DApp.swift, which covers every
        // BRAND-NEW window). This one covers dropping a different file onto
        // an already-open document window, which reaches this function
        // directly without ever going back through that closure. A reopen
        // of an already-counted file, or any file while the trial still has
        // room, or anything at all once licensed, always passes.
        guard licenseState.canOpen(url: url) else {
            let message = String(
                localized: "error.trialExhausted",
                defaultValue: "Trial limit reached — this file can't be opened."
            )
            errorMessage = message
            return
        }

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
                // Only now — a real, successfully loaded model — does this
                // count against the trial. Never for a failed load, and
                // never before this point (e.g. speculatively at gate time).
                licenseState.recordSuccessfulOpen(of: url)
                presentTrialToastIfCritical()
                // Set animations before the scene so the new list is in place
                // by the time `SceneContainerView` re-attaches on the scene swap.
                self.animations = model.animations
                self.scene = model.scene
                self.stats = model.stats
                controller.currentModelName = (model.stats.fileName as NSString).deletingPathExtension
                if !model.missingExternalTextureURLs.isEmpty {
                    self.missingTexturePrompt = (url, model.missingExternalTextureURLs.count)
                }
            case .failure(let error):
                let prefix = String(localized: "error.loadPrefix", defaultValue: "Error loading:")
                self.errorMessage = "\(prefix) \(error.localizedDescription)"
            }
        }
    }

    /// Lets the user grant read access to the model's containing folder (the
    /// App Sandbox only auto-grants the model file itself), then reloads it so
    /// external textures resolve. The granted access lasts for this app session.
    private func grantFolderAccessAndRetry(modelURL: URL) {
        let panel = NSOpenPanel()
        let prefix = String(localized: "folderAccess.prefix", defaultValue: "Select the folder that contains")
        let suffix = String(localized: "folderAccess.suffix", defaultValue: "to enable its external textures.")
        panel.message = "\(prefix) \"\(modelURL.lastPathComponent)\" \(suffix)"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = modelURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        guard folderURL.startAccessingSecurityScopedResource() else { return }
        missingTexturePrompt = nil
        load(url: modelURL)
    }
}
