import SwiftUI

/// Bottom-left info pill. Grey labels, monospaced values, matching reference-ui.
struct InfoPanelView: View {
    let stats: ModelStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model info")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 8) {
                row("Triangles", stats.triangleCountFormatted)
                row("Vertices", stats.vertexCountFormatted)
                row("Mesh", "\(stats.meshCount)")
                row("Materials", "\(stats.materialCount)")
                row("Size", stats.dimensionsFormatted)
                row("File size", stats.fileSizeFormatted)
            }
        }
        .padding(16)
        .frame(width: 260, alignment: .leading)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(LocalizedStringKey(label))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
