import Foundation
import QuartzCore
import SceneKit
import simd

/// World-space axis-aligned bounding box for a whole node hierarchy.
///
/// `SCNNode.boundingBox` only covers a single node's own geometry and ignores
/// child transforms, so for a loaded model (a container node with many
/// transformed children) it is unreliable. Here we union every geometry node's
/// local bounding box after transforming its 8 corners into world space.
struct SceneBounds {
    let min: simd_float3
    let max: simd_float3
    /// True when a mesh deforms in a way the box could not measure (no clip
    /// given, or vertex data in a format we don't read): the radius then gets
    /// a fixed 30% headroom so an animated pose stays in frame.
    var unmeasuredDeformation = false

    var center: simd_float3 { (min + max) * 0.5 }
    var extents: simd_float3 { max - min }
    /// Radius of the bounding sphere that encloses the box.
    var radius: Float { simd_length(extents) * 0.5 * (unmeasuredDeformation ? 1.3 : 1) }

    /// Rest-pose bounds. A skinned or morphed mesh is flagged as unmeasured:
    /// pass the clips to `compute(for:clips:)` to measure its poses instead.
    static func compute(for root: SCNNode) -> SceneBounds? {
        var box = Box()
        var deforms = false
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            if node.skinner != nil || node.morpher != nil { deforms = true }
            box.add(Box(geometry.boundingBox), transformedBy: node.simdWorldTransform)
        }
        guard !box.isEmpty else { return nil }
        return SceneBounds(min: box.lo, max: box.hi, unmeasuredDeformation: deforms)
    }

    /// Bounds that hold the rest pose and every pose the clips reach.
    ///
    /// The clips are sampled on the CPU (no renderer): node transforms are
    /// evaluated from the clips' keyframes, a skinned mesh is bounded per bone
    /// (a skinned vertex is a weighted average of its bones' transforms, so it
    /// lies inside the union of the boxes of the vertices each bone moves,
    /// carried by that bone), and a morphed vertex is bounded by the range its
    /// target weights take over the clips.
    static func compute(for root: SCNNode, clips: [CAAnimation]) -> SceneBounds? {
        guard let bounds = compute(for: root) else { return nil }
        guard bounds.unmeasuredDeformation || !clips.isEmpty else { return bounds }

        let animation = ClipSampler(root: root, clips: clips)
        var meshes: [DeformedMesh] = []
        var rigid: [SCNNode] = []
        var unreadable = false
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            if node.skinner == nil, node.morpher == nil { rigid.append(node); return }
            if let mesh = DeformedMesh(node: node, weightRanges: animation.weightRanges[ObjectIdentifier(node)] ?? [:]) {
                meshes.append(mesh)
            } else {
                unreadable = true
            }
        }

        // Not seeded with the rest bounds: those place a skinned mesh by its
        // node transform, which SceneKit ignores when skinning.
        var box = Box()
        for pose in [Pose(overrides: [:])] + animation.poses() {
            for node in rigid {
                box.add(Box(node.geometry!.boundingBox), transformedBy: pose.world(node))
            }
            for mesh in meshes { mesh.add(to: &box, pose: pose) }
        }
        guard !box.isEmpty else { return bounds }
        return SceneBounds(min: box.lo, max: box.hi, unmeasuredDeformation: unreadable)
    }
}

// MARK: - Box

private struct Box {
    var lo = simd_float3(repeating: .greatestFiniteMagnitude)
    var hi = simd_float3(repeating: -.greatestFiniteMagnitude)
    var isEmpty: Bool { lo.x > hi.x }

    init() {}
    init(lo: simd_float3, hi: simd_float3) { self.lo = lo; self.hi = hi }
    init(_ b: (min: SCNVector3, max: SCNVector3)) { lo = simd_float3(b.min); hi = simd_float3(b.max) }

    mutating func add(_ p: simd_float3) { lo = simd_min(lo, p); hi = simd_max(hi, p) }

    /// Adds `b` carried by the affine transform `m` (exact AABB of the
    /// transformed box: center moves by `m`, half-extents by `|m|`).
    mutating func add(_ b: Box, transformedBy m: simd_float4x4) {
        guard !b.isEmpty else { return }
        let c = (b.lo + b.hi) * 0.5, e = (b.hi - b.lo) * 0.5
        let mc = m * simd_float4(c, 1)
        let a = simd_float3x3(abs(simd_make_float3(m.columns.0)), abs(simd_make_float3(m.columns.1)),
                              abs(simd_make_float3(m.columns.2)))
        let me = a * e
        add(simd_make_float3(mc) - me)
        add(simd_make_float3(mc) + me)
    }
}

// MARK: - Clip sampling

/// Evaluates the clips' keyframe channels at sampled instants. GLTFKit2 and the
/// FBX bridge both bake a clip as a `CAAnimationGroup` of `CAKeyframeAnimation`s
/// addressed by absolute key path (`/<node>.position|orientation|scale`,
/// `/<node>.morpher.weights[i]`), which is all this reads.
private struct ClipSampler {
    enum Property { case position, orientation, scale }

    struct Channel {
        let node: SCNNode
        let property: Property
        let begin: Double
        let duration: Double
        let keyTimes: [Double]
        let values: [simd_float4]
        let discrete: Bool

        func value(at t: Double) -> simd_float4 {
            let f = duration > 0 ? Swift.min(Swift.max((t - begin) / duration, 0), 1) : 0
            guard values.count > 1, keyTimes.count >= values.count else { return values[0] }
            // Last key at or before `f`.
            var i = 0
            while i + 1 < keyTimes.count, keyTimes[i + 1] <= f { i += 1 }
            if discrete || i + 1 >= values.count { return values[Swift.min(i, values.count - 1)] }
            let span = keyTimes[i + 1] - keyTimes[i]
            let u = Float(span > 0 ? (f - keyTimes[i]) / span : 0)
            var a = values[i], b = values[i + 1]
            // ponytail: nlerp for rotations and linear for cubic channels;
            // sampling is approximate anyway, a few % margin would cover it.
            if property == .orientation {
                if simd_dot(a, b) < 0 { b = -b }
                a = simd_mix(a, b, simd_float4(repeating: u))
                return simd_normalize(a)
            }
            return simd_mix(a, b, simd_float4(repeating: u))
        }
    }

    struct Clip { var channels: [Channel] = []; var duration: Double = 0 }

    let root: SCNNode
    private(set) var clips: [Clip] = []
    /// Per morphed node, per target index: lowest and highest weight any clip sets.
    private(set) var weightRanges: [ObjectIdentifier: [Int: ClosedRange<Float>]] = [:]
    private var nodesByName: [String: SCNNode] = [:]

    init(root: SCNNode, clips: [CAAnimation]) {
        self.root = root
        root.enumerateHierarchy { node, _ in
            if let name = node.name, nodesByName[name] == nil { nodesByName[name] = node }
        }
        for animation in clips {
            var clip = Clip(duration: animation.duration)
            collect(animation, offset: 0, into: &clip)
            self.clips.append(clip)
        }
    }

    private mutating func collect(_ animation: CAAnimation, offset: Double, into clip: inout Clip) {
        let begin = offset + animation.beginTime
        if let group = animation as? CAAnimationGroup {
            for child in group.animations ?? [] { collect(child, offset: begin, into: &clip) }
            return
        }
        guard let keyframes = animation as? CAKeyframeAnimation,
              let path = keyframes.keyPath, path.hasPrefix("/"),
              let values = keyframes.values, !values.isEmpty else { return }

        if let range = path.range(of: ".morpher.weights[") {
            guard let node = nodesByName[String(path[path.index(after: path.startIndex)..<range.lowerBound])],
                  let index = Int(path[range.upperBound...].dropLast()) else { return }
            let weights = values.compactMap { ($0 as? NSNumber)?.floatValue }
            guard let lo = weights.min(), let hi = weights.max() else { return }
            let old = weightRanges[ObjectIdentifier(node), default: [:]][index]
            weightRanges[ObjectIdentifier(node), default: [:]][index] =
                Swift.min(lo, old?.lowerBound ?? lo)...Swift.max(hi, old?.upperBound ?? hi)
            return
        }

        let suffixes: [(String, Property)] = [(".position", .position), (".orientation", .orientation), (".scale", .scale)]
        guard let (suffix, property) = suffixes.first(where: { path.hasSuffix($0.0) }),
              let node = nodesByName[String(path.dropFirst().dropLast(suffix.count))] else { return }
        let vectors: [simd_float4] = values.compactMap {
            guard let v = $0 as? NSValue else { return nil }
            if property == .orientation { let q = v.scnVector4Value; return simd_float4(Float(q.x), Float(q.y), Float(q.z), Float(q.w)) }
            let p = v.scnVector3Value
            return simd_float4(Float(p.x), Float(p.y), Float(p.z), 0)
        }
        guard vectors.count == values.count else { return }
        let keyTimes = keyframes.keyTimes?.map(\.doubleValue)
            ?? (0..<vectors.count).map { Double($0) / Double(Swift.max(vectors.count - 1, 1)) }
        clip.channels.append(Channel(node: node, property: property, begin: begin,
                                     duration: keyframes.duration, keyTimes: keyTimes, values: vectors,
                                     discrete: keyframes.calculationMode == .discrete))
    }

    /// Poses sampled across every clip (60 per clip, ends included).
    func poses(samplesPerClip: Int = 60) -> [Pose] {
        clips.flatMap { clip in
            (0...samplesPerClip).map { i in
                let t = clip.duration * Double(i) / Double(samplesPerClip)
                var overrides: [ObjectIdentifier: (SCNNode, [Property: simd_float4])] = [:]
                for c in clip.channels {
                    overrides[ObjectIdentifier(c.node), default: (c.node, [:])].1[c.property] = c.value(at: t)
                }
                return Pose(overrides: overrides.mapValues(\.1))
            }
        }
    }
}

/// One sampled instant: animated nodes' local TRS, everything else at rest.
private final class Pose {
    let overrides: [ObjectIdentifier: [ClipSampler.Property: simd_float4]]
    private var cache: [ObjectIdentifier: simd_float4x4] = [:]

    init(overrides: [ObjectIdentifier: [ClipSampler.Property: simd_float4]]) { self.overrides = overrides }

    func world(_ node: SCNNode) -> simd_float4x4 {
        let id = ObjectIdentifier(node)
        if let m = cache[id] { return m }
        let local: simd_float4x4
        if let o = overrides[id] {
            let p = o[.position].map { simd_make_float3($0) } ?? node.simdPosition
            let q = o[.orientation].map { simd_quatf(vector: $0) } ?? node.simdOrientation
            let s = o[.scale].map { simd_make_float3($0) } ?? node.simdScale
            var t = matrix_identity_float4x4
            t.columns.3 = simd_float4(p, 1)
            local = t * simd_float4x4(q) * simd_float4x4(diagonal: simd_float4(s, 1)) * node.simdPivot.inverse
        } else {
            local = node.simdTransform
        }
        let m = node.parent.map { world($0) * local } ?? local
        cache[id] = m
        return m
    }
}

// MARK: - Deformed meshes

/// A skinned and/or morphed mesh, reduced to boxes that a pose only has to
/// transform: one per bone for a skinned mesh, one in node space otherwise.
private struct DeformedMesh {
    let node: SCNNode
    /// Per bone: the bone, its inverse bind matrix and the box (bind-shape space)
    /// of the vertices it moves.
    var bones: [(node: SCNNode, inverseBind: simd_float4x4, box: Box)] = []
    var localBox = Box()

    init?(node: SCNNode, weightRanges: [Int: ClosedRange<Float>]) {
        self.node = node
        let geometry = node.skinner?.baseGeometry ?? node.geometry!
        guard let source = geometry.sources(for: .vertex).first,
              let base = Self.read(source, components: 3) else { return nil }
        let n = source.vectorCount

        // Per-vertex box: rest position widened by every morph target over the
        // weight range the clips (or the static weight) give it.
        var lo = (0..<n).map { simd_float3(base[$0 * 3], base[$0 * 3 + 1], base[$0 * 3 + 2]) }
        var hi = lo
        if let morpher = node.morpher {
            let additive = morpher.calculationMode == .additive
            for (k, target) in morpher.targets.enumerated() {
                let w = morpher.weight(forTargetAt: k)
                let range = weightRanges[k].map { Swift.min($0.lowerBound, Float(w))...Swift.max($0.upperBound, Float(w)) }
                    ?? Float(w)...Float(w)
                guard range != 0...0 else { continue }
                guard let ts = target.sources(for: .vertex).first, ts.vectorCount == n,
                      let t = Self.read(ts, components: 3) else { return nil }
                for i in 0..<n {
                    var d = simd_float3(t[i * 3], t[i * 3 + 1], t[i * 3 + 2])
                    if !additive { d -= simd_float3(base[i * 3], base[i * 3 + 1], base[i * 3 + 2]) }
                    let a = d * range.lowerBound, b = d * range.upperBound
                    lo[i] += simd_min(a, b)
                    hi[i] += simd_max(a, b)
                }
            }
        }

        guard let skinner = node.skinner else {
            for i in 0..<n { localBox.add(lo[i]); localBox.add(hi[i]) }
            return
        }
        let wSource = skinner.boneWeights, iSource = skinner.boneIndices
        guard wSource.vectorCount == n, iSource.vectorCount == n,
              wSource.componentsPerVector == iSource.componentsPerVector,
              let weights = Self.read(wSource, components: wSource.componentsPerVector),
              let indices = Self.read(iSource, components: iSource.componentsPerVector) else { return nil }
        let k = wSource.componentsPerVector
        let bindShape = simd_float4x4(skinner.baseGeometryBindTransform)
        let inverseBinds = skinner.boneInverseBindTransforms?.map { simd_float4x4($0.scnMatrix4Value) } ?? []
        guard inverseBinds.count == skinner.bones.count else { return nil }

        var boxes = [Box](repeating: Box(), count: skinner.bones.count)
        for i in 0..<n {
            let v = Box(lo: lo[i], hi: hi[i])
            for j in 0..<k where weights[i * k + j] > 0 {
                let b = Int(indices[i * k + j])
                guard boxes.indices.contains(b) else { return nil }
                boxes[b].add(v, transformedBy: bindShape)
            }
        }
        for (b, box) in boxes.enumerated() where !box.isEmpty {
            bones.append((skinner.bones[b], inverseBinds[b], box))
        }
    }

    func add(to box: inout Box, pose: Pose) {
        if bones.isEmpty {
            box.add(localBox, transformedBy: pose.world(node))
        } else {
            // SceneKit skins in world space: bone world × inverse bind × bind shape.
            for bone in bones { box.add(bone.box, transformedBy: pose.world(bone.node) * bone.inverseBind) }
        }
    }

    /// Flattened components of a geometry source, or nil for a layout we don't read.
    private static func read(_ s: SCNGeometrySource, components: Int) -> [Float]? {
        let bpc = s.bytesPerComponent, n = s.vectorCount
        guard s.componentsPerVector >= components, [1, 2, 4, 8].contains(bpc),
              !(s.usesFloatComponents && bpc < 4) else { return nil }
        return s.data.withUnsafeBytes { raw -> [Float]? in
            guard let base = raw.baseAddress,
                  n == 0 || s.dataOffset + (n - 1) * s.dataStride + components * bpc <= raw.count else { return nil }
            var out = [Float](repeating: 0, count: n * components)
            for i in 0..<n {
                for c in 0..<components {
                    let p = base + s.dataOffset + i * s.dataStride + c * bpc
                    switch (s.usesFloatComponents, bpc) {
                    case (true, 4): out[i * components + c] = p.loadUnaligned(as: Float.self)
                    case (true, _): out[i * components + c] = Float(p.loadUnaligned(as: Double.self))
                    case (false, 1): out[i * components + c] = Float(p.load(as: UInt8.self))
                    case (false, 2): out[i * components + c] = Float(p.loadUnaligned(as: UInt16.self))
                    case (false, 4): out[i * components + c] = Float(p.loadUnaligned(as: UInt32.self))
                    default: out[i * components + c] = Float(p.loadUnaligned(as: UInt64.self))
                    }
                }
            }
            return out
        }
    }
}
