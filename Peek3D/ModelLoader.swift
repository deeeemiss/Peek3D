import Foundation
import SceneKit
import ModelIO
import SceneKit.ModelIO
import UniformTypeIdentifiers
import simd
import GLTFKit2

enum ModelLoadError: LocalizedError {
    /// The file loaded without an error but holds nothing to draw. Model I/O
    /// in particular reports success for empty, unreadable or non-3D files
    /// (it only logs to the console), which left a blank window and a
    /// "0 triangles" info panel with no explanation.
    case noGeometry
    /// A .gltf whose geometry lives in sibling .bin files the App Sandbox
    /// won't let us read: nothing can be drawn until the user grants the
    /// folder, so the UI offers that instead of an error.
    case needsFolderAccess([URL])

    var errorDescription: String? {
        switch self {
        case .noGeometry:
            return String(localized: "error.noGeometry",
                          defaultValue: "This file can't be read or contains no 3D model to show.")
        case .needsFolderAccess(let urls):
            return String(localized: "missingTexture.count \(urls.count)")
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
    /// External files (textures, .mtl) the model references that exist but
    /// the App Sandbox didn't grant access to (the model file itself was
    /// picked/dropped, but sibling files weren't). The UI can offer to grant
    /// access to the model's folder and reload.
    var missingExternalTextureURLs: [URL] = []
}

/// Dual-path loader. `.glb`/`.gltf` go through GLTFKit2; everything else goes
/// through Apple's Model I/O. Both converge to a single `SCNScene`, so the rest
/// of the app never needs to know where the model came from.
enum ModelLoader {

    /// Extensions we advertise to the open panel / drag & drop.
    static let supportedExtensions: Set<String> = [
        "glb", "gltf", "obj", "stl", "usd", "usdz", "usda", "usdc", "dae", "ply", "abc", "fbx"
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

        var missingExternalTextureURLs = unreadableReferences(of: url)

        switch ext {
        case "glb", "gltf":
            let buffers = missingExternalTextureURLs.filter { $0.pathExtension.lowercased() == "bin" }
            if !buffers.isEmpty { throw ModelLoadError.needsFolderAccess(missingExternalTextureURLs) }
            // Throwing bridge of +assetWithURL:options:error:. Draco/KTX2
            // compressed assets need extra plugins (not wired in v1) and will
            // surface as a thrown error here rather than a silent failure.
            // GLTFKit2 crashes (instead of throwing) on structurally broken
            // files: reject those first with a normal error.
            try GLTFValidator.validate(url: url)
            let asset = try GLTFAsset(url: url, options: [:])
            // The `SCNScene(gltfAsset:)` convenience routes through this same
            // source but keeps only `defaultScene` and drops the animations;
            // go through the source directly so we can pull the players too.
            let source = GLTFSCNSceneSource(asset: asset)
            scene = source.defaultScene ?? SCNScene()
            animations = source.animations.map {
                ModelAnimation(name: $0.name, player: $0.animationPlayer)
            }
        case "fbx":
            // Third backend: the vendored ufbx C library via an Objective-C++
            // bridge. Produces the same `SCNScene` shape as the other loaders,
            // and — like the glTF path — carries any playable clips as
            // `SCNAnimationPlayer`s so the timeline/wireframe UI treats FBX
            // identically. Scope is node-transform (rigid/hierarchical)
            // animation; skinned/skeletal deformation is not applied (the bridge
            // documents the boundary).
            let result = try FBXSceneBuilder.load(fileURL: url)
            scene = result.scene
            animations = result.animations.map {
                ModelAnimation(name: $0.name, player: $0.player)
            }
            missingExternalTextureURLs += result.unreadableExternalTextureURLs
        default:
            let mdlAsset = MDLAsset(url: url)
            mdlAsset.loadTextures()
            scene = SCNScene(mdlAsset: mdlAsset)
        }

        guard hasDrawableGeometry(scene) else { throw ModelLoadError.noGeometry }

        let stats = computeStats(scene: scene, url: url)
        return LoadedModel(scene: scene, stats: stats, animations: animations,
                            missingExternalTextureURLs: missingExternalTextureURLs)
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

    /// Sibling files a .gltf or .obj points to that exist but can't be read
    /// (sandbox). Files that simply don't exist aren't listed: granting the
    /// folder wouldn't bring them back. FBX reports its own from the bridge.
    // ponytail: DAE/USD sibling textures not scanned; add if users hit it.
    static func unreadableReferences(of url: URL) -> [URL] {
        let base = url.deletingLastPathComponent()
        var names: [String] = []
        switch url.pathExtension.lowercased() {
        case "gltf":
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            for key in ["buffers", "images"] {
                for item in json[key] as? [[String: Any]] ?? [] {
                    if let uri = item["uri"] as? String, !uri.hasPrefix("data:") {
                        names.append(uri.removingPercentEncoding ?? uri)
                    }
                }
            }
        case "obj":
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            for mtl in objStatements(text, prefixes: ["mtllib"]) {
                names.append(mtl)
                guard let mtlText = try? String(contentsOf: base.appendingPathComponent(mtl), encoding: .utf8) else { continue }
                // Texture map options ("-bm 1 file.png") come first: the file is the last token.
                names += objStatements(mtlText, prefixes: ["map_", "bump", "disp", "decal", "norm"])
                    .compactMap { $0.split(separator: " ").last.map(String.init) }
            }
        default:
            return []
        }
        var seen = Set<URL>()
        return names.map { base.appendingPathComponent($0).standardizedFileURL }
            .filter { seen.insert($0).inserted && isUnreadable($0) }
    }

    private static func objStatements(_ text: String, prefixes: [String]) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard let keyword = line.split(separator: " ").first,
                  prefixes.contains(where: { keyword.lowercased().hasPrefix($0) }) else { return nil }
            let rest = line.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
    }

    /// The sandbox answers EPERM even for paths that don't exist, so the
    /// read error can't tell the two apart; `stat` (allowed) can.
    private static func isUnreadable(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) && (try? FileHandle(forReadingFrom: url).close()) == nil
    }

    /// True if any node carries a geometry with at least one primitive —
    /// triangles, lines or points (a point-cloud PLY is a valid model).
    private static func hasDrawableGeometry(_ scene: SCNScene) -> Bool {
        var found = false
        scene.rootNode.enumerateHierarchy { node, stop in
            if node.geometry?.elements.contains(where: { $0.primitiveCount > 0 }) == true {
                found = true
                stop.pointee = true
            }
        }
        return found
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
