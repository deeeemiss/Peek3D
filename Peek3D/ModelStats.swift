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
        let decimals: Int
        switch maxExtent {
        case ..<0.01: decimals = 4
        case ..<1: decimals = 3
        case ..<10: decimals = 2
        default: decimals = 0
        }
        let format = "%.\(decimals)f × %.\(decimals)f × %.\(decimals)f"
        return String(format: format, dimensions.x, dimensions.y, dimensions.z)
    }

    var triangleCountFormatted: String { Self.grouped(triangleCount) }
    var vertexCountFormatted: String { Self.grouped(vertexCount) }

    private static func grouped(_ value: Int) -> String {
        groupFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let groupFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "."
        return f
    }()
}
