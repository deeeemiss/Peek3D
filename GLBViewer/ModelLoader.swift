import Foundation
import SceneKit
import ModelIO
import SceneKit.ModelIO
import UniformTypeIdentifiers
import simd
import GLTFKit2

enum ModelLoadError: LocalizedError {
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let name):
            return "Impossibile caricare \(name)."
        }
    }
}

/// Dual-path loader. `.glb`/`.gltf` go through GLTFKit2; everything else goes
/// through Apple's Model I/O. Both converge to a single `SCNScene`, so the rest
/// of the app never needs to know where the model came from.
enum ModelLoader {

    /// Extensions we advertise to the open panel / drag & drop.
    static let supportedExtensions: Set<String> = [
        "glb", "gltf", "obj", "stl", "usd", "usdz", "usda", "usdc", "dae", "ply", "abc"
    ]

    static var supportedContentTypes: [UTType] {
        supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Synchronous load. Safe to call off the main thread (scene graph
    /// construction is data work); attach the result to an `SCNView` on main.
    static func loadSync(url: URL) throws -> (SCNScene, ModelStats) {
        let ext = url.pathExtension.lowercased()
        let scene: SCNScene

        switch ext {
        case "glb", "gltf":
            // Throwing bridge of +assetWithURL:options:error:. Draco/KTX2
            // compressed assets need extra plugins (not wired in v1) and will
            // surface as a thrown error here rather than a silent failure.
            let asset = try GLTFAsset(url: url, options: [:])
            scene = SCNScene(gltfAsset: asset)
        default:
            let mdlAsset = MDLAsset(url: url)
            mdlAsset.loadTextures()
            scene = SCNScene(mdlAsset: mdlAsset)
        }

        let stats = computeStats(scene: scene, url: url)
        return (scene, stats)
    }

    /// Async wrapper used by the UI: loads off-main, delivers on main.
    static func load(url: URL, completion: @escaping (Result<(SCNScene, ModelStats), Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try loadSync(url: url)
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Statistics

    static func computeStats(scene: SCNScene, url: URL) -> ModelStats {
        var triangleCount = 0
        var vertexCount = 0
        var meshCount = 0
        var materialIDs = Set<ObjectIdentifier>()

        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            meshCount += 1
            vertexCount += geometry.sources(for: .vertex).first?.vectorCount ?? 0

            for element in geometry.elements {
                switch element.primitiveType {
                case .triangles:
                    triangleCount += element.primitiveCount
                case .triangleStrip:
                    // strip of N primitives ≈ N triangles as SceneKit reports it
                    triangleCount += element.primitiveCount
                default:
                    break // points / lines contribute no triangles
                }
            }

            for material in geometry.materials {
                materialIDs.insert(ObjectIdentifier(material))
            }
        }

        let bounds = SceneBounds.compute(for: scene.rootNode)
        let dimensions = bounds?.extents ?? .zero

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0

        return ModelStats(
            triangleCount: triangleCount,
            vertexCount: vertexCount,
            meshCount: meshCount,
            materialCount: materialIDs.count,
            dimensions: dimensions,
            fileSizeBytes: fileSize,
            fileName: url.lastPathComponent
        )
    }
}
