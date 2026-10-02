import Foundation
import simd

/// Numeric facts about a loaded model, shown in the info panel.
struct ModelStats {
    var triangleCount: Int
    var vertexCount: Int
    var meshCount: Int
    var materialCount: Int
    var dimensions: simd_float3
    var fileSizeBytes: Int64
    var fileName: String

    var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    /// `%.0f` on all three axes used to be fine for the integer-scale test
    /// fixtures (a 2-unit cube), but real-world glTF assets are routinely
    /// authored in meters — e.g. Avocado.glb is ~0.04 × 0.06 × 0.03 — and
    /// rounding those to zero decimals silently printed "0 × 0 × 0", making a
    /// correctly-loaded model look broken/empty. Scale the precision to the
    /// model's largest extent instead of using a fixed decimal count.
    var dimensionsFormatted: String {
        let maxExtent = Swift.max(dimensions.x, dimensions.y, dimensions.z)
        // Very large or very small models: three significant digits in
        // scientific notation instead of "3000000…" or "0.0000".
        let style: FloatingPointFormatStyle<Double> = switch maxExtent {
        case 100_000...: .number.notation(.scientific).precision(.significantDigits(3))
        case ..<0.0001 where maxExtent > 0: .number.notation(.scientific).precision(.significantDigits(3))
        case ..<0.01: .number.precision(.fractionLength(4))
        case ..<1: .number.precision(.fractionLength(3))
        case ..<10: .number.precision(.fractionLength(2))
        default: .number.precision(.fractionLength(0))
        }
        return [dimensions.x, dimensions.y, dimensions.z]
            .map { Double($0).formatted(style) }
            .joined(separator: " × ")
    }

    // Locale's own grouping: a forced "." read as a decimal point in English.
    var triangleCountFormatted: String { triangleCount.formatted() }
    var vertexCountFormatted: String { vertexCount.formatted() }
}
