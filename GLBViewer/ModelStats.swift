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

    var dimensionsFormatted: String {
        String(format: "%.0f × %.0f × %.0f", dimensions.x, dimensions.y, dimensions.z)
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
