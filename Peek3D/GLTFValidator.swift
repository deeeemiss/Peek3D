import Foundation

/// Structural checks on a glTF asset BEFORE it reaches GLTFKit2.
///
/// GLTFKit2 trusts the file: an accessor pointing past the end of its buffer,
/// an out-of-range index, or an unknown enum value makes it abort on an
/// assertion, crash in `memmove`, or silently read memory outside the buffer.
/// None of that can be caught from Swift, so a damaged or hostile `.glb`
/// downloaded from the internet would take the whole app down. This validator
/// rejects such files with a normal, recoverable error instead.
///
/// It checks only what GLTFKit2 relies on without checking itself: buffer
/// sizes, view and accessor ranges, enum values and object indices. It is not
/// a full glTF spec validator.
enum GLTFValidator {
    struct Invalid: LocalizedError {
        /// Developer-facing detail; the user sees `errorDescription`.
        let reason: String

        var errorDescription: String? {
            String(localized: "error.gltfInvalid",
                   defaultValue: "This glTF file is damaged or uses an invalid structure, so it can't be opened.")
        }

        var failureReason: String? { reason }
    }

    static func validate(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let json: Data
        var glbBinLength: Int?

        if data.starts(with: [0x67, 0x6C, 0x54, 0x46]) { // "glTF"
            (json, glbBinLength) = try splitGLB(data)
        } else {
            json = data
        }

        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw Invalid(reason: "JSON is not an object")
        }
        try Checker(root: root, baseURL: url.deletingLastPathComponent(), glbBinLength: glbBinLength).run()
    }

    // MARK: - GLB container

    private static func splitGLB(_ data: Data) throws -> (json: Data, binLength: Int?) {
        func u32(_ offset: Int) -> Int? {
            guard offset + 4 <= data.count else { return nil }
            return data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian) }
        }
        guard let version = u32(4), version == 2 else { throw Invalid(reason: "unsupported GLB version") }
        guard let total = u32(8), total <= data.count, total >= 20 else { throw Invalid(reason: "GLB length exceeds file") }
        guard let jsonLength = u32(12), u32(16) == 0x4E4F_534A, 20 + jsonLength <= total else {
            throw Invalid(reason: "bad JSON chunk")
        }
        let json = data.subdata(in: 20..<(20 + jsonLength))

        var binLength: Int?
        let binHeader = 20 + jsonLength
        if binHeader + 8 <= total, let length = u32(binHeader), u32(binHeader + 4) == 0x004E_4942 {
            guard binHeader + 8 + length <= total else { throw Invalid(reason: "BIN chunk exceeds file") }
            binLength = length
        }
        return (json, binLength)
    }

    // MARK: - Checks

    private struct Checker {
        let root: [String: Any]
        let baseURL: URL
        let glbBinLength: Int?

        private static let componentSizes: [Int: Int] = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4]
        private static let componentCounts: [String: Int] = [
            "SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16,
        ]
        private static let indexComponentTypes: Set<Int> = [5121, 5123, 5125]
        /// Far above any real asset, low enough that `count * stride` can't
        /// overflow and a forged count can't stall the loader for minutes.
        private static let maxCount = 1 << 28
        /// A day of animation: generous for any real clip.
        private static let maxAnimationSeconds = 86_400.0

        func run() throws {
            let buffers = array("buffers")
            let views = array("bufferViews")
            let accessors = array("accessors")
            let nodes = array("nodes")

            let bufferLengths = try buffers.enumerated().map { try bufferLength($0.element, index: $0.offset) }
            let viewLengths = try views.map { try viewLength($0, bufferLengths: bufferLengths) }
            for accessor in accessors { try check(accessor: accessor, views: views, viewLengths: viewLengths) }

            for mesh in array("meshes") {
                for primitive in objects(mesh["primitives"]) {
                    let mode = try int(primitive["mode"], default: 4)
                    guard (0...6).contains(mode) else { throw Invalid(reason: "primitive mode \(mode)") }
                    if primitive["indices"] != nil {
                        let index = try ref(primitive["indices"], count: accessors.count, "indices")
                        let indices = accessors[index]
                        guard Self.indexComponentTypes.contains(try int(indices["componentType"])),
                              indices["type"] as? String == "SCALAR"
                        else { throw Invalid(reason: "index accessor type") }
                        // GLTFKit2 asserts that index data is tightly packed.
                        if let viewIndex = indices["bufferView"] as? Int, viewIndex < views.count,
                           let stride = views[viewIndex]["byteStride"] as? Int,
                           stride != Self.componentSizes[try int(indices["componentType"])] {
                            throw Invalid(reason: "strided index buffer")
                        }
                    }
                    for attribute in (primitive["attributes"] as? [String: Any] ?? [:]).values {
                        _ = try ref(attribute, count: accessors.count, "attribute")
                    }
                    for target in objects(primitive["targets"]) {
                        for value in target.values { _ = try ref(value, count: accessors.count, "morph target") }
                    }
                }
            }

            for image in array("images") where image["bufferView"] != nil {
                _ = try ref(image["bufferView"], count: views.count, "image bufferView")
            }
            for texture in array("textures") {
                if texture["source"] != nil { _ = try ref(texture["source"], count: array("images").count, "texture source") }
                if texture["sampler"] != nil { _ = try ref(texture["sampler"], count: array("samplers").count, "texture sampler") }
            }
            for skin in array("skins") {
                let joints = skin["joints"] as? [Any] ?? []
                for joint in joints { _ = try ref(joint, count: nodes.count, "joint") }
                if skin["inverseBindMatrices"] != nil {
                    // GLTFKit2 asserts these are float 4×4 matrices, one per joint.
                    let matrices = accessors[try ref(skin["inverseBindMatrices"], count: accessors.count, "inverseBindMatrices")]
                    guard matrices["type"] as? String == "MAT4", try int(matrices["componentType"]) == 5126,
                          try int(matrices["count"]) >= joints.count
                    else { throw Invalid(reason: "inverseBindMatrices must be float MAT4, one per joint") }
                }
            }
            for node in nodes {
                if node["mesh"] != nil { _ = try ref(node["mesh"], count: array("meshes").count, "node mesh") }
                if node["skin"] != nil { _ = try ref(node["skin"], count: array("skins").count, "node skin") }
                if node["camera"] != nil { _ = try ref(node["camera"], count: array("cameras").count, "node camera") }
                for child in node["children"] as? [Any] ?? [] { _ = try ref(child, count: nodes.count, "child") }
            }
            for animation in array("animations") {
                let samplers = objects(animation["samplers"])
                for sampler in samplers {
                    let input = accessors[try ref(sampler["input"], count: accessors.count, "animation input")]
                    _ = try ref(sampler["output"], count: accessors.count, "animation output")
                    // Key times are float seconds. A forged `max` (e.g. 1e30)
                    // becomes the clip length and stalls GLTFKit2 for minutes.
                    guard input["type"] as? String == "SCALAR", try int(input["componentType"]) == 5126
                    else { throw Invalid(reason: "animation input must be float scalars") }
                    for bound in [input["min"], input["max"]].compactMap({ $0 as? [Any] }).joined() {
                        guard let seconds = (bound as? NSNumber)?.doubleValue, seconds.isFinite,
                              abs(seconds) <= Self.maxAnimationSeconds
                        else { throw Invalid(reason: "animation time bound \(bound)") }
                    }
                }
                for channel in objects(animation["channels"]) {
                    _ = try ref(channel["sampler"], count: samplers.count, "channel sampler")
                    if let target = channel["target"] as? [String: Any], target["node"] != nil {
                        _ = try ref(target["node"], count: nodes.count, "channel node")
                    }
                }
            }
            for scene in array("scenes") {
                for node in scene["nodes"] as? [Any] ?? [] { _ = try ref(node, count: nodes.count, "scene node") }
            }
            if root["scene"] != nil { _ = try ref(root["scene"], count: array("scenes").count, "default scene") }
        }

        // MARK: Buffers and views

        /// The usable length of a buffer: its declared `byteLength`, which must
        /// not exceed the bytes actually available.
        private func bufferLength(_ buffer: [String: Any], index: Int) throws -> Int {
            let declared = try int(buffer["byteLength"])
            guard declared >= 1 else { throw Invalid(reason: "buffer \(index) byteLength \(declared)") }

            let available: Int?
            if let uri = buffer["uri"] as? String {
                if uri.hasPrefix("data:") {
                    let payload = uri.split(separator: ",", maxSplits: 1).last.map(String.init) ?? ""
                    available = Data(base64Encoded: payload)?.count ?? 0
                } else if let file = URL(string: uri, relativeTo: baseURL),
                          let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    available = size
                } else {
                    // Unreadable sibling file: GLTFKit2 fails to load it with a
                    // normal error, so there is nothing to over-read.
                    available = nil
                }
            } else {
                guard index == 0, let glbBinLength else { throw Invalid(reason: "buffer \(index) has no data") }
                available = glbBinLength
            }
            if let available, declared > available {
                throw Invalid(reason: "buffer \(index) byteLength \(declared) > \(available) available")
            }
            return declared
        }

        private func viewLength(_ view: [String: Any], bufferLengths: [Int]) throws -> Int {
            let buffer = try ref(view["buffer"], count: bufferLengths.count, "bufferView buffer")
            let offset = try int(view["byteOffset"], default: 0)
            let length = try int(view["byteLength"])
            guard offset >= 0, length >= 1, offset + length <= bufferLengths[buffer] else {
                throw Invalid(reason: "bufferView range \(offset)+\(length) > \(bufferLengths[buffer])")
            }
            if view["byteStride"] != nil {
                let stride = try int(view["byteStride"])
                guard (4...252).contains(stride), stride % 4 == 0 else { throw Invalid(reason: "byteStride \(stride)") }
            }
            return length
        }

        // MARK: Accessors

        private func check(accessor: [String: Any], views: [[String: Any]], viewLengths: [Int]) throws {
            let componentType = try int(accessor["componentType"])
            guard let componentSize = Self.componentSizes[componentType] else {
                throw Invalid(reason: "componentType \(componentType)")
            }
            guard let type = accessor["type"] as? String, let components = Self.componentCounts[type] else {
                throw Invalid(reason: "accessor type")
            }
            let count = try int(accessor["count"])
            guard (1...Self.maxCount).contains(count) else { throw Invalid(reason: "accessor count \(count)") }
            let elementSize = componentSize * components

            if accessor["bufferView"] != nil {
                let view = try ref(accessor["bufferView"], count: views.count, "accessor bufferView")
                let offset = try int(accessor["byteOffset"], default: 0)
                let stride = (views[view]["byteStride"] as? Int) ?? elementSize
                guard offset >= 0, offset + stride * (count - 1) + elementSize <= viewLengths[view] else {
                    throw Invalid(reason: "accessor reads past its bufferView")
                }
            }

            if let sparse = accessor["sparse"] as? [String: Any] {
                let sparseCount = try int(sparse["count"])
                guard (1...count).contains(sparseCount) else { throw Invalid(reason: "sparse count") }
                for (key, size) in [("indices", 0), ("values", elementSize)] {
                    guard let part = sparse[key] as? [String: Any] else { throw Invalid(reason: "sparse \(key)") }
                    var itemSize = size
                    if key == "indices" {
                        let type = try int(part["componentType"])
                        guard Self.indexComponentTypes.contains(type), let s = Self.componentSizes[type] else {
                            throw Invalid(reason: "sparse index type")
                        }
                        itemSize = s
                    }
                    let view = try ref(part["bufferView"], count: views.count, "sparse bufferView")
                    let offset = try int(part["byteOffset"], default: 0)
                    guard offset >= 0, offset + itemSize * sparseCount <= viewLengths[view] else {
                        throw Invalid(reason: "sparse \(key) out of range")
                    }
                }
            }
        }

        // MARK: Helpers

        private func array(_ key: String) -> [[String: Any]] { objects(root[key]) }

        private func objects(_ value: Any?) -> [[String: Any]] {
            (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        }

        /// A JSON number that must be a whole value within Int32 range.
        private func int(_ value: Any?, default fallback: Int? = nil) throws -> Int {
            guard let value else {
                if let fallback { return fallback }
                throw Invalid(reason: "missing required number")
            }
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded() == number.doubleValue,
                  abs(number.doubleValue) <= Double(Int32.max)
            else { throw Invalid(reason: "not an integer: \(value)") }
            return number.intValue
        }

        private func ref(_ value: Any?, count: Int, _ what: String) throws -> Int {
            let index = try int(value)
            guard (0..<count).contains(index) else { throw Invalid(reason: "\(what) index \(index) of \(count)") }
            return index
        }
    }
}
