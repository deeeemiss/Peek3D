import SwiftUI
import SceneKit
import UniformTypeIdentifiers

struct ContentView: View {
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

    var body: some View {
        ZStack {
            Color(white: 0.04).ignoresSafeArea()

            if let scene {
                SceneContainerView(scene: scene, animations: animations, controller: controller)
                    .ignoresSafeArea()
                    .grabCursor()

                overlays
            } else {
                DropZoneView(onPick: load)
            }

            if let errorMessage {
                errorBanner(errorMessage)
            }

            if let missingTexturePrompt {
                missingTextureBanner(missingTexturePrompt)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        // Allow replacing the model by dropping a new file over a loaded scene.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { load(url: url) }
            }
            return true
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
                .pointerCursor()
                .overlay(alignment: .top) {
                    if let gizmoHoverLabel {
                        Text(gizmoHoverLabel)
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
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Text(prompt.count == 1
                     ? "1 texture esterna non caricata (permessi cartella)."
                     : "\(prompt.count) texture esterne non caricate (permessi cartella).")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                Button("Concedi accesso alla cartella") { grantFolderAccessAndRetry(modelURL: prompt.modelURL) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                Button("Ignora") { missingTexturePrompt = nil }
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
        ModelLoader.load(url: url) { result in
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
            case .failure(let error):
                self.errorMessage = "Errore nel caricamento: \(error.localizedDescription)"
            }
        }
    }

    /// Lets the user grant read access to the model's containing folder (the
    /// App Sandbox only auto-grants the model file itself), then reloads it so
    /// external textures resolve. The granted access lasts for this app session.
    private func grantFolderAccessAndRetry(modelURL: URL) {
        let panel = NSOpenPanel()
        panel.message = "Seleziona la cartella che contiene \"\(modelURL.lastPathComponent)\" per abilitarne le texture esterne."
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
