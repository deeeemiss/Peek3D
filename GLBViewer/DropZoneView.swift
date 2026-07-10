import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Empty-state view: centered dashed drop area + file picker button.
struct DropZoneView: View {
    let onPick: (URL) -> Void
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            Color(white: 0.04).ignoresSafeArea()

            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    isTargeted ? Color.green : Color.white.opacity(0.15),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .padding(40)

            VStack(spacing: 16) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 52, weight: .thin))
                    .foregroundStyle(.white.opacity(isTargeted ? 0.8 : 0.4))
                VStack(spacing: 4) {
                    Text("Trascina un modello 3D qui")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(".glb  .gltf  .obj  .stl  .usdz  .usd  .dae  .ply")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Button(action: openPanel) {
                    Text("Scegli un file…")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.15)))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { onPick(url) }
        }
        return true
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ModelLoader.supportedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            onPick(url)
        }
    }
}
