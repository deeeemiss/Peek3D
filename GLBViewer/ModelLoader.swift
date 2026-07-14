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

/// One playable animation extracted from a model, decoupled from the loader
/// backend so nothing downstream needs to import GLTFKit2. Only glTF assets
/// currently carry these; Model I/O models return an empty list. `name` is the
/// raw glTF clip name and may be empty (e.g. BoxAnimated ships one unnamed
/// clip) — the UI supplies a fallback label.
struct ModelAnimation {
    let name: String
    let player: SCNAnimationPlayer
}

/// Everything a successful load produces. Replaces the earlier
/// `(SCNScene, ModelStats)` tuple so animations can ride along to `attach`.
struct LoadedModel {
    let scene: SCNScene
    let stats: ModelStats
    let animations: [ModelAnimation]
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
    static func loadSync(url: URL) throws -> LoadedModel {
        let ext = url.pathExtension.lowercased()
        let scene: SCNScene
        var animations: [ModelAnimation] = []

        switch ext {
        case "glb", "gltf":
            // Throwing bridge of +assetWithURL:options:error:. Draco/KTX2
            // compressed assets need extra plugins (not wired in v1) and will
            // surface as a thrown error here rather than a silent failure.
            let asset = try GLTFAsset(url: url, options: [:])
            // The `SCNScene(gltfAsset:)` convenience routes through this same
            // source but keeps only `defaultScene` and drops the animations;
            // go through the source directly so we can pull the players too.
            let source = GLTFSCNSceneSource(asset: asset)
            scene = source.defaultScene ?? SCNScene()
            animations = source.animations.map {
                ModelAnimation(name: $0.name, player: $0.animationPlayer)
            }
        default:
            let mdlAsset = MDLAsset(url: url)
            mdlAsset.loadTextures()
            scene = SCNScene(mdlAsset: mdlAsset)
        }

        let stats = computeStats(scene: scene, url: url)
        return LoadedModel(scene: scene, stats: stats, animations: animations)
    }

    /// Async wrapper used by the UI: loads off-main, delivers on main.
    static func load(url: URL, completion: @escaping (Result<LoadedModel, Error>) -> Void) {
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
