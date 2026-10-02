import SwiftUI

/// Bottom-left info pill. Grey labels, monospaced values, matching reference-ui.
struct InfoPanelView: View {
    let stats: ModelStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model info")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .foregroundStyle(.white)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 8) {
                row("Triangles", stats.triangleCountFormatted)
                row("Vertices", stats.vertexCountFormatted)
                row("Mesh", stats.meshCount.formatted())
                row("Materials", stats.materialCount.formatted())
                row("Size", stats.dimensionsFormatted)
                row("File size", stats.fileSizeFormatted, numbersOnly: false)
            }
        }
        .padding(16)
        // Grows for long values (tiny models need four decimals per axis)
        // instead of wrapping the Size row.
        .frame(minWidth: 260, alignment: .leading)
        .hudPanel(cornerRadius: 14)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, numbersOnly: Bool = true) -> some View {
        GridRow {
            Text(LocalizedStringKey(label))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
            // Numbers are isolated left-to-right: the Bidi algorithm otherwise
            // reorders "25 × 79 × 155" to "155 × 79 × 25" in Arabic, and
            // Apple's RTL guidance is to never reverse a number's parts. A
            // value with a unit ("163 ك.ب.") takes its direction from its
            // own letters instead (first-strong isolate), or the unit's
            // final period jumps to the wrong end.
            Text(numbersOnly ? "\u{2066}\(value)\u{2069}" : "\u{2068}\(value)\u{2069}")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
