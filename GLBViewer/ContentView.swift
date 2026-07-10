import SwiftUI
import SceneKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var controller = ViewerController()
    @State private var scene: SCNScene?
    @State private var stats: ModelStats?
    @State private var showInfo = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color(white: 0.04).ignoresSafeArea()

            if let scene {
                SceneContainerView(scene: scene, controller: controller)
                    .ignoresSafeArea()

                overlays
            } else {
                DropZoneView(onPick: load)
            }

            if let errorMessage {
                errorBanner(errorMessage)
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

        // Info panel — bottom-left
        if showInfo, let stats {
            VStack {
                Spacer()
                HStack {
                    InfoPanelView(stats: stats)
                    Spacer()
                }
            }
            .padding(20)
            .transition(.opacity)
        }

        // Toolbar — right, vertically centered
        HStack {
            Spacer()
            ViewerToolbar(controller: controller, showInfo: $showInfo)
        }
        .padding(20)

        // Axis gizmo — bottom-right
        VStack {
            Spacer()
            HStack {
                Spacer()
                AxisGizmoView(controller: controller)
                    .frame(width: 96, height: 96)
                    .allowsHitTesting(false)
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

    // MARK: - Loading

    private func load(url: URL) {
        errorMessage = nil
        ModelLoader.load(url: url) { result in
            switch result {
            case .success(let (loadedScene, loadedStats)):
                self.scene = loadedScene
                self.stats = loadedStats
            case .failure(let error):
                self.errorMessage = "Errore nel caricamento: \(error.localizedDescription)"
            }
        }
    }
}
