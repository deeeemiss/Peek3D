#import "FBXSceneBuilder.h"
#import <AppKit/AppKit.h>

#include <vector>
#include <cstdint>
#include <cmath>

#include "ufbx.h"

// MARK: - Small helpers

/// Converts a `ufbx_matrix` (3x4 affine, column vectors: cols[0..2] = basis,
/// cols[3] = translation) to a SceneKit column-major `SCNMatrix4`. Translation
/// lands in m41/m42/m43, matching SceneKit's convention. `ufbx_real` is `double`
/// by default, which maps cleanly onto `SCNMatrix4`'s CGFloat components.
static SCNMatrix4 SCNMatrixFromUfbx(const ufbx_matrix *m) {
    SCNMatrix4 r;
    r.m11 = m->cols[0].x; r.m12 = m->cols[0].y; r.m13 = m->cols[0].z; r.m14 = 0.0;
    r.m21 = m->cols[1].x; r.m22 = m->cols[1].y; r.m23 = m->cols[1].z; r.m24 = 0.0;
    r.m31 = m->cols[2].x; r.m32 = m->cols[2].y; r.m33 = m->cols[2].z; r.m34 = 0.0;
    r.m41 = m->cols[3].x; r.m42 = m->cols[3].y; r.m43 = m->cols[3].z; r.m44 = 1.0;
    return r;
}

/// True if `m`'s 3x3 basis has a negative determinant, i.e. it mirrors
/// chirality (flips a right-handed basis to left-handed or vice versa).
///
/// We load with `UFBX_SPACE_CONVERSION_ADJUST_TRANSFORMS`, which — for a
/// source file whose declared axes have different handedness than our
/// `right_handed_y_up` target — folds the required mirror straight into this
/// node transform rather than into vertex positions. `scene->metadata.mirror_axis`
/// only gets set under `UFBX_SPACE_CONVERSION_MODIFY_GEOMETRY`, so it stays
/// `UFBX_MIRROR_AXIS_NONE` here even when a mirror really was applied — this
/// determinant check is what actually detects it for our loader. Confirmed
/// empirically: a hand-built ASCII FBX with Maya-style left-handed
/// `GlobalSettings` axes loads with `geometry_to_world` determinant -1, while
/// a normal right-handed export loads with +1.
static bool MirrorsChirality(const ufbx_matrix *m) {
    double det =
          m->cols[0].x * (m->cols[1].y * m->cols[2].z - m->cols[1].z * m->cols[2].y)
        - m->cols[1].x * (m->cols[0].y * m->cols[2].z - m->cols[0].z * m->cols[2].y)
        + m->cols[2].x * (m->cols[0].y * m->cols[1].z - m->cols[0].z * m->cols[1].y);
    return det < 0.0;
}

static NSString *NSStringFromUfbx(ufbx_string s) {
    if (s.length == 0 || s.data == NULL) return @"";
    return [[NSString alloc] initWithBytes:s.data length:s.length encoding:NSUTF8StringEncoding] ?: @"";
}

/// A key-path-safe, collision-free name for a node. Animation channels address
/// nodes by name via absolute key paths (`/<name>.orientation`), and `.`/`/`/
/// whitespace in a raw FBX name would break that grammar (FBX names routinely
/// contain spaces and `|`, e.g. `"AnimatedCube|Action"`). We keep only
/// `[A-Za-z0-9_]`, replace the rest with `_`, and prefix the node's typed_id so
/// two nodes can never share a name even if their source names collide or are
/// empty. The same string is used for `SCNNode.name` and in the key path, so
/// the two always agree.
static NSString *SanitizedUniqueNodeName(const ufbx_node *node) {
    NSString *raw = NSStringFromUfbx(node->name);
    NSMutableString *clean = [NSMutableString stringWithCapacity:raw.length];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        BOOL ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == '_';
        [clean appendString:ok ? [NSString stringWithCharacters:&c length:1] : @"_"];
    }
    return [NSString stringWithFormat:@"fbxNode_%u_%@", node->typed_id, clean];
}

/// Resolves a ufbx texture to an `NSImage`: embedded content first (works inside
/// the App Sandbox with no extra file access), then the resolved external file
/// path (only readable if the sandbox has granted access to that location).
/// When the external path exists but can't be read, its URL is appended to
/// `unreadableExternalURLs` so the caller can offer a folder-access retry.
static NSImage *ImageForTexture(const ufbx_texture *tex, NSMutableArray<NSURL *> *unreadableExternalURLs) {
    if (tex == NULL) return nil;
    if (tex->content.size > 0 && tex->content.data != NULL) {
        NSData *data = [NSData dataWithBytes:tex->content.data length:tex->content.size];
        NSImage *img = [[NSImage alloc] initWithData:data];
        if (img) return img;
    }
    NSString *path = NSStringFromUfbx(tex->filename);
    if (path.length > 0) {
        // `[NSImage initWithContentsOfFile:]` can return a non-nil image even
        // when the sandbox denies the actual read: some `NSImageRep` backends
        // defer decoding the file until first draw, so construction alone
        // doesn't prove the bytes were readable — it silently renders blank
        // later instead of failing here. Read the bytes explicitly first (the
        // same way the embedded-content branch above already does) so an
        // unreadable file is caught right here, not as a mysteriously blank
        // material with no reported error.
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data) {
            NSImage *img = [[NSImage alloc] initWithData:data];
            if (img) return img;
        }
        // A file that doesn't exist isn't a permissions problem: granting the
        // folder wouldn't fix it, so don't offer that. The sandbox reports
        // EPERM for missing paths too, so ask `stat`, which it allows.
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
            [unreadableExternalURLs addObject:[NSURL fileURLWithPath:path]];
        }
    }
    return nil;
}

// MARK: - Material conversion

/// Builds an `SCNMaterial` from a ufbx material. Prefers a base-color/diffuse
/// texture (embedded or external); falls back to the flat base/diffuse color.
/// Uses the Blinn lighting model so a plain diffuse texture renders predictably
/// under the app's default lighting and presets (FBX materials are commonly
/// non-PBR). Double-sided so a viewer never drops back faces to winding quirks.
static SCNMaterial *MaterialFromUfbx(const ufbx_material *umat, NSMutableArray<NSURL *> *unreadableExternalURLs) {
    SCNMaterial *mat = [SCNMaterial material];
    mat.lightingModelName = SCNLightingModelBlinn;
    mat.doubleSided = YES;

    if (umat == NULL) {
        mat.diffuse.contents = [NSColor colorWithWhite:0.8 alpha:1.0];
        return mat;
    }

    // Prefer the PBR base color slot, then the classic FBX diffuse slot.
    const ufbx_material_map *colorMap = &umat->pbr.base_color;
    if (!colorMap->has_value && colorMap->texture == NULL) {
        colorMap = &umat->fbx.diffuse_color;
    }

    NSImage *texImage = ImageForTexture(colorMap->texture, unreadableExternalURLs);
    if (texImage) {
        mat.diffuse.contents = texImage;
        mat.diffuse.wrapS = SCNWrapModeRepeat;
        mat.diffuse.wrapT = SCNWrapModeRepeat;
    } else if (colorMap->has_value) {
        ufbx_vec4 c = colorMap->value_vec4;
        mat.diffuse.contents = [NSColor colorWithRed:c.x green:c.y blue:c.z alpha:(c.w > 0 ? c.w : 1.0)];
    } else {
        mat.diffuse.contents = [NSColor colorWithWhite:0.8 alpha:1.0];
    }

    return mat;
}

// MARK: - Mesh conversion

/// Expanded (non-indexed) attribute buffers for one material group of a mesh.
struct GroupBuffers {
    std::vector<float> positions; // xyz per corner
    std::vector<float> normals;   // xyz per corner
    std::vector<float> uvs;       // uv per corner
    // Skinning (only filled for a skinned mesh): the `kMaxBoneInfluences`
    // heaviest bone influences of each corner, weights renormalised to sum 1.
    std::vector<float> boneWeights;    // kMaxBoneInfluences floats per corner
    std::vector<uint16_t> boneIndices; // kMaxBoneInfluences indices into the cluster list per corner
    // Blend shapes (only filled for a morphed mesh): one entry per morph
    // target, holding that target's position / normal OFFSET for each corner.
    std::vector<std::vector<float>> morphPositions;
    std::vector<std::vector<float>> morphNormals;
};

/// SceneKit's skinner takes a fixed number of influences per vertex; 4 is what
/// glTF and every real-time pipeline use. The heaviest 4 are kept and
/// renormalised (ufbx already sorts a vertex's weights by decreasing weight).
static const size_t kMaxBoneInfluences = 4;

/// The first `count` vectors of `values` as a tightly packed float source.
static SCNGeometrySource *FloatSource(const std::vector<float> &values, size_t count, NSInteger components,
                                      SCNGeometrySourceSemantic semantic) {
    NSData *data = [NSData dataWithBytes:values.data() length:count * components * sizeof(float)];
    return [SCNGeometrySource geometrySourceWithData:data
                                            semantic:semantic
                                         vectorCount:(NSInteger)count
                                     floatComponents:YES
                                 componentsPerVector:components
                                   bytesPerComponent:sizeof(float)
                                          dataOffset:0
                                          dataStride:components * sizeof(float)];
}

@implementation FBXAnimationClip
- (instancetype)initWithName:(NSString *)name player:(SCNAnimationPlayer *)player {
    if ((self = [super init])) {
        _name = [name copy];
        _player = player;
    }
    return self;
}
@end

@implementation FBXLoadResult
- (instancetype)initWithScene:(SCNScene *)scene
                    animations:(NSArray<FBXAnimationClip *> *)animations
 unreadableExternalTextureURLs:(NSArray<NSURL *> *)urls {
    if ((self = [super init])) {
        _scene = scene;
        _animations = animations;
        _unreadableExternalTextureURLs = urls;
    }
    return self;
}
@end

// MARK: - Animation conversion
//
// Playback model matches GLTFKit2's exactly (see `GLTFSceneKit.m`), so the
// resulting `SCNAnimationPlayer` behaves identically to a glTF clip in
// `ViewerController`: one `CAAnimationGroup` per clip, whose child
// `CAKeyframeAnimation`s address target nodes by absolute key path
// (`/<nodeName>.position|orientation|scale`); the group loops via
// `repeatDuration = FLT_MAX`, and its `duration` is the finite clip length the
// timeline reads. The player is added to `scene.rootNode`, and SceneKit resolves
// each `/name` path against the root's subtree — so every animated node is
// driven from a single attached player, no matter how deep it sits.

/// Builds a linearly-interpolated position/scale channel from ufbx's baked vec3
/// keys. `keyTimes` are normalized into [0,1] over the clip's playback window so
/// every channel shares one timeline regardless of its own key spacing.
static CAKeyframeAnimation *Vec3Channel(NSString *keyPath, ufbx_baked_vec3_list keys,
                                        double begin, double duration) {
    CAKeyframeAnimation *anim = [CAKeyframeAnimation animationWithKeyPath:keyPath];
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:keys.count];
    NSMutableArray *times = [NSMutableArray arrayWithCapacity:keys.count];
    for (size_t i = 0; i < keys.count; i++) {
        ufbx_baked_vec3 k = keys.data[i];
        [values addObject:[NSValue valueWithSCNVector3:SCNVector3Make(k.value.x, k.value.y, k.value.z)]];
        double t = duration > 0.0 ? (k.time - begin) / duration : 0.0;
        [times addObject:@(t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t))];
    }
    anim.values = values;
    anim.keyTimes = times;
    anim.calculationMode = kCAAnimationLinear;
    anim.duration = duration;
    return anim;
}

/// Builds a (spherically) interpolated rotation channel from ufbx's baked quats.
/// SceneKit's `orientation` key path takes an `SCNVector4` (x, y, z, w) — the
/// same component order ufbx uses — and interpolates it as a quaternion.
static CAKeyframeAnimation *QuatChannel(NSString *keyPath, ufbx_baked_quat_list keys,
                                        double begin, double duration) {
    CAKeyframeAnimation *anim = [CAKeyframeAnimation animationWithKeyPath:keyPath];
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:keys.count];
    NSMutableArray *times = [NSMutableArray arrayWithCapacity:keys.count];
    for (size_t i = 0; i < keys.count; i++) {
        ufbx_baked_quat k = keys.data[i];
        [values addObject:[NSValue valueWithSCNVector4:SCNVector4Make(k.value.x, k.value.y, k.value.z, k.value.w)]];
        double t = duration > 0.0 ? (k.time - begin) / duration : 0.0;
        [times addObject:@(t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t))];
    }
    anim.values = values;
    anim.keyTimes = times;
    anim.calculationMode = kCAAnimationLinear;
    anim.duration = duration;
    return anim;
}

/// Bakes one FBX anim stack into an `SCNAnimationPlayer`, or `nil` if the stack
/// drives no node transforms (e.g. a stack that only animates material or
/// visibility properties, which are out of scope). `nodeNames[typed_id]` maps a
/// baked node back to the `SCNNode.name` we assigned it, closing the loop
/// between the key path and the live scene graph.
///
/// Every baked channel with keys is emitted, including channels ufbx flags as
/// constant: doing so keeps the animated pose fully self-defined and avoids any
/// dependence on whether the node's rest/bind transform happens to equal the
/// clip's value at t=0.
static FBXAnimationClip *ClipFromStack(ufbx_scene *scene, ufbx_anim_stack *stack,
                                       NSArray<NSString *> *nodeNames,
                                       NSDictionary<NSNumber *, NSArray<NSArray *> *> *morphTargets) {
    ufbx_error berr;
    memset(&berr, 0, sizeof(berr));
    ufbx_baked_anim *bake = ufbx_bake_anim(scene, stack->anim, NULL, &berr);
    if (bake == NULL) return nil;

    const double begin = bake->playback_time_begin;
    const double duration = bake->playback_duration;
    if (duration <= 0.0) { ufbx_free_baked_anim(bake); return nil; }

    NSMutableArray<CAAnimation *> *channels = [NSMutableArray array];
    for (size_t i = 0; i < bake->nodes.count; i++) {
        ufbx_baked_node *bn = &bake->nodes.data[i];
        if (bn->typed_id >= nodeNames.count) continue;
        NSString *root = [@"/" stringByAppendingString:nodeNames[bn->typed_id]];
        if (bn->translation_keys.count > 0)
            [channels addObject:Vec3Channel([root stringByAppendingString:@".position"],
                                            bn->translation_keys, begin, duration)];
        if (bn->rotation_keys.count > 0)
            [channels addObject:QuatChannel([root stringByAppendingString:@".orientation"],
                                            bn->rotation_keys, begin, duration)];
        if (bn->scale_keys.count > 0)
            [channels addObject:Vec3Channel([root stringByAppendingString:@".scale"],
                                            bn->scale_keys, begin, duration)];
    }

    // Blend-shape weights: ufbx bakes a blend channel's weight as the
    // "DeformPercent" property (0..100) of the channel element. Each target the
    // channel feeds (one per mesh instance) gets a `morpher.weights[i]` channel,
    // the same key path GLTFKit2 uses for glTF weight animation.
    for (size_t i = 0; i < bake->elements.count; i++) {
        ufbx_baked_element *be = &bake->elements.data[i];
        NSArray<NSArray *> *targets = morphTargets[@(be->element_id)];
        if (targets == nil) continue;
        for (size_t pi = 0; pi < be->props.count; pi++) {
            ufbx_baked_prop *bp = &be->props.data[pi];
            if (bp->keys.count == 0 || ![NSStringFromUfbx(bp->name) isEqualToString:@"DeformPercent"]) continue;
            for (NSArray *target in targets) {
                NSString *keyPath = [NSString stringWithFormat:@"/%@.morpher.weights[%d]", target[0], [target[1] intValue]];
                CAKeyframeAnimation *anim = [CAKeyframeAnimation animationWithKeyPath:keyPath];
                NSMutableArray *values = [NSMutableArray arrayWithCapacity:bp->keys.count];
                NSMutableArray *times = [NSMutableArray arrayWithCapacity:bp->keys.count];
                for (size_t k = 0; k < bp->keys.count; k++) {
                    ufbx_baked_vec3 key = bp->keys.data[k];
                    [values addObject:@(key.value.x / 100.0)];
                    double t = duration > 0.0 ? (key.time - begin) / duration : 0.0;
                    [times addObject:@(t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t))];
                }
                anim.values = values;
                anim.keyTimes = times;
                anim.calculationMode = kCAAnimationLinear;
                anim.duration = duration;
                [channels addObject:anim];
            }
        }
    }
    ufbx_free_baked_anim(bake);

    if (channels.count == 0) return nil;

    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = channels;
    group.duration = duration;
    group.repeatDuration = FLT_MAX; // loop like the glTF path
    SCNAnimation *scnAnim = [SCNAnimation animationWithCAAnimation:group];
    SCNAnimationPlayer *player = [SCNAnimationPlayer animationPlayerWithAnimation:scnAnim];
    return [[FBXAnimationClip alloc] initWithName:NSStringFromUfbx(stack->name) player:player];
}

@implementation FBXSceneBuilder

+ (nullable FBXLoadResult *)loadFileURL:(NSURL *)url
                                   error:(NSError * _Nullable * _Nullable)error {
    ufbx_load_opts opts;
    memset(&opts, 0, sizeof(opts));

    // Normalize the scene into SceneKit's world: 1 unit == 1 meter, right-handed
    // Y-up. `ADJUST_TRANSFORMS` bakes the unit/axis conversion into node
    // transforms (geometry stays in its own space, which we place via
    // `geometry_to_world`). This is what fixes the "model is huge / tiny"
    // problem: an FBX authored in centimetres comes back at the right size.
    opts.target_unit_meters = 1.0f;
    opts.target_axes = ufbx_axes_right_handed_y_up;
    opts.space_conversion = UFBX_SPACE_CONVERSION_ADJUST_TRANSFORMS;

    // Animation curves are now parsed (see `ClipFromStack`). `ADJUST_TRANSFORMS`
    // folds the unit/axis conversion into the node transforms, so the baked
    // per-node keyframes come out already in SceneKit's target space — no
    // separate conversion of the animation data is needed.

    // Fill in normals if the file omits them, and pull in external assets
    // (e.g. sibling texture files) when the sandbox allows reading them.
    opts.generate_missing_normals = true;
    opts.load_external_files = true;

    ufbx_error uerr;
    memset(&uerr, 0, sizeof(uerr));
    ufbx_scene *scene = ufbx_load_file(url.fileSystemRepresentation, &opts, &uerr);
    if (scene == NULL) {
        if (error) {
            NSString *desc = NSStringFromUfbx(uerr.description);
            *error = [NSError errorWithDomain:@"com.seb.Peek3D.FBX"
                                         code:(NSInteger)uerr.type
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                                     desc.length ? desc : @"FBX load failed" }];
        }
        return nil;
    }

    // SceneKit updates world transforms recursively on a thread of its own
    // and overflows its stack somewhere past 5000 levels: refuse up front.
    for (size_t ni = 0; ni < scene->nodes.count; ni++) {
        if (scene->nodes.data[ni]->node_depth > 4000) {
            ufbx_free_scene(scene);
            if (error) {
                *error = [NSError errorWithDomain:@"com.seb.Peek3D.FBX" code:-2
                                         userInfo:@{ NSLocalizedDescriptionKey: @"Node hierarchy deeper than 4000 levels" }];
            }
            return nil;
        }
    }

    SCNScene *scnScene = [SCNScene scene];
    NSMutableArray<NSURL *> *unreadableExternalURLs = [NSMutableArray array];

    // The scene graph MIRRORS the FBX node hierarchy (rather than flattening
    // every mesh onto the root with its `geometry_to_world` baked in, as the
    // static-only version did). This is what makes node-transform animation
    // possible: a baked clip keys each node's LOCAL transform, so each animated
    // node must sit under its real parent chain for the composition to land in
    // the right world position. Bind pose is identical to the old flat build —
    // verified: `geometry_to_world == node_to_world * geometry_to_node`, and a
    // node's world transform is the product of the `node_to_parent` transforms
    // up the chain (see the SceneKit/ufbx column-major agreement in
    // `SCNMatrixFromUfbx`).

    // Pass 1: one SCNNode per ufbx node, with its LOCAL transform and a
    // key-path-safe unique name. `nodeForId`/`nodeNames` are indexed by
    // `typed_id` (== index into `scene->nodes`), the same id the baked animation
    // reports, so channels can find their target node by name.
    std::vector<SCNNode *> nodeForId(scene->nodes.count, nil);
    NSMutableArray<NSString *> *nodeNames =
        [NSMutableArray arrayWithCapacity:scene->nodes.count];
    for (size_t i = 0; i < scene->nodes.count; i++) [nodeNames addObject:@""];
    for (size_t ni = 0; ni < scene->nodes.count; ni++) {
        ufbx_node *node = scene->nodes.data[ni];
        SCNNode *sn = [SCNNode node];
        NSString *name = SanitizedUniqueNodeName(node);
        sn.name = name;
        sn.transform = SCNMatrixFromUfbx(&node->node_to_parent);
        nodeForId[node->typed_id] = sn;
        nodeNames[node->typed_id] = name;
    }

    // Pass 2: reconstruct parent/child links; root ufbx nodes hang off the scene
    // root. (The ufbx root node itself becomes an SCNNode too, so any conversion
    // adjustment folded into its transform is preserved.)
    for (size_t ni = 0; ni < scene->nodes.count; ni++) {
        ufbx_node *node = scene->nodes.data[ni];
        SCNNode *sn = nodeForId[node->typed_id];
        if (node->parent != NULL) {
            [nodeForId[node->parent->typed_id] addChildNode:sn];
        } else {
            [scnScene.rootNode addChildNode:sn];
        }
    }

    // Pass 3: attach geometry to each mesh node. Instances of one mesh share
    // its geometry buffers (an SCNGeometry copy shares vertex data but has
    // its own materials) and materials are built once per FBX material:
    // rebuilding both per instance made 200 instances of a 20k-triangle mesh
    // take 247 MB and decode the same textures 200 times.
    NSMutableDictionary<NSString *, NSDictionary *> *geometryCache = [NSMutableDictionary dictionary];
    NSMapTable<NSValue *, SCNMaterial *> *materialCache = [NSMapTable strongToStrongObjectsMapTable];
    // blend channel element_id -> [geometry node name, morpher target index]
    // pairs, one per mesh instance the channel drives; the animation baker uses
    // it to address `morpher.weights[i]`.
    NSMutableDictionary<NSNumber *, NSArray<NSArray *> *> *morphTargets = [NSMutableDictionary dictionary];
    for (size_t ni = 0; ni < scene->nodes.count; ni++) {
        ufbx_node *node = scene->nodes.data[ni];
        if (node == NULL || node->mesh == NULL) continue;
        ufbx_mesh *mesh = node->mesh;
        if (mesh->num_faces == 0) continue;

        SCNNode *meshNode = nodeForId[node->typed_id];

        // See `MirrorsChirality`: a handedness-mismatched source file bakes a
        // mirror into this node's transform rather than into vertex positions,
        // so the UVs (authored before that mirror) read backwards on one axis.
        // Flip U to compensate; a normal right-handed file is untouched.
        const bool uvNeedsMirrorCompensation = MirrorsChirality(&node->geometry_to_world);

        const size_t groupCount = mesh->materials.count > 0 ? mesh->materials.count : 1;
        // A skinned mesh bakes its node's `geometry_to_world` into the
        // vertices (see below), so instances can't share one buffer.
        const bool meshIsSkinned = mesh->skin_deformers.count > 0;
        NSString *meshKey = [NSString stringWithFormat:@"%p-%d-%p", (void *)mesh, (int)uvNeedsMirrorCompensation,
                             meshIsSkinned ? (void *)node : NULL];
        // Everything built once per mesh and shared by its instances: the
        // geometry, the material group of each element and, if the mesh is
        // skinned / morphed, the skin sources and morph target geometries.
        // Empty for a mesh with nothing to draw.
        NSDictionary *cached = geometryCache[meshKey];
        if (cached == nil) {
            std::vector<GroupBuffers> groups(groupCount);

            // Skin: the first deformer, if every cluster has a bone to follow.
            // A mesh with a broken skin falls back to its bind pose.
            const ufbx_skin_deformer *skin = NULL;
            if (mesh->skin_deformers.count > 0) {
                const ufbx_skin_deformer *candidate = mesh->skin_deformers.data[0];
                bool usable = candidate->clusters.count > 0 && candidate->clusters.count <= 0xFFFF;
                for (size_t ci = 0; usable && ci < candidate->clusters.count; ci++) {
                    if (candidate->clusters.data[ci]->bone_node == NULL) usable = false;
                }
                if (usable) skin = candidate;
            }
            // A skinned mesh carries its vertices in WORLD bind space (and the
            // inverse bind matrices below absorb the difference): the skinner
            // evaluates in the skinned node's frame, and keeping that node at
            // the scene root with an identity transform makes the bounds and
            // camera fit see the real bind-pose extent.
            const bool bakeWorld = skin != NULL;
            const ufbx_matrix geometryToWorld = node->geometry_to_world;
            const ufbx_matrix normalsToWorld = ufbx_matrix_for_normals(&geometryToWorld);
            auto unit = [](ufbx_vec3 v) {
                const double len = sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
                return len > 0.0 ? ufbx_vec3{ v.x / len, v.y / len, v.z / len } : v;
            };
            // Blend shapes: one morph target per channel (its final shape;
            // in-between shapes are not modelled).
            std::vector<const ufbx_blend_channel *> morphChannels;
            for (size_t di = 0; di < mesh->blend_deformers.count; di++) {
                const ufbx_blend_deformer *blend = mesh->blend_deformers.data[di];
                for (size_t ci = 0; ci < blend->channels.count; ci++) {
                    if (blend->channels.data[ci]->target_shape != NULL) morphChannels.push_back(blend->channels.data[ci]);
                }
            }
            std::vector<bool> morphHasNormals(morphChannels.size());
            for (size_t ti = 0; ti < morphChannels.size(); ti++) {
                morphHasNormals[ti] = morphChannels[ti]->target_shape->normal_offsets.count > 0;
            }
            for (GroupBuffers &g : groups) {
                g.morphPositions.resize(morphChannels.size());
                g.morphNormals.resize(morphChannels.size());
            }

            const bool hasNormals = mesh->vertex_normal.exists;
            const bool hasUV = mesh->vertex_uv.exists;

            // Scratch buffer big enough to triangulate any single face in this mesh.
            std::vector<uint32_t> triIndices(mesh->max_face_triangles * 3);

            for (size_t fi = 0; fi < mesh->num_faces; fi++) {
                ufbx_face face = mesh->faces.data[fi];
                if (face.num_indices < 3) continue;

                uint32_t groupIdx = 0;
                if (mesh->face_material.count > 0) {
                    groupIdx = mesh->face_material.data[fi];
                    if (groupIdx >= groupCount) groupIdx = 0;
                }
                GroupBuffers &g = groups[groupIdx];

                uint32_t numTris = ufbx_triangulate_face(triIndices.data(), triIndices.size(), mesh, face);
                for (uint32_t t = 0; t < numTris * 3; t++) {
                    uint32_t ix = triIndices[t];
                    ufbx_vec3 p = ufbx_get_vertex_vec3(&mesh->vertex_position, ix);
                    if (bakeWorld) p = ufbx_transform_position(&geometryToWorld, p);
                    g.positions.push_back((float)p.x);
                    g.positions.push_back((float)p.y);
                    g.positions.push_back((float)p.z);

                    if (hasNormals) {
                        ufbx_vec3 n = ufbx_get_vertex_vec3(&mesh->vertex_normal, ix);
                        if (bakeWorld) n = unit(ufbx_transform_direction(&normalsToWorld, n));
                        g.normals.push_back((float)n.x);
                        g.normals.push_back((float)n.y);
                        g.normals.push_back((float)n.z);
                    }
                    if (hasUV) {
                        ufbx_vec2 uv = ufbx_get_vertex_vec2(&mesh->vertex_uv, ix);
                        // FBX UV origin is bottom-left; SceneKit samples top-left.
                        g.uvs.push_back(uvNeedsMirrorCompensation ? (float)(1.0 - uv.x) : (float)uv.x);
                        g.uvs.push_back((float)(1.0 - uv.y));
                    }

                    // `ix` is a corner; skin weights and blend offsets are
                    // authored per logical vertex, so map back before reading.
                    const uint32_t vertex = mesh->vertex_indices.data[ix];
                    if (skin != NULL) {
                        float w[kMaxBoneInfluences] = {0, 0, 0, 0};
                        uint16_t b[kMaxBoneInfluences] = {0, 0, 0, 0};
                        float total = 0.0f;
                        if (vertex < skin->vertices.count) {
                            const ufbx_skin_vertex sv = skin->vertices.data[vertex];
                            size_t n = 0;
                            // Weights come sorted heaviest first: keep the top N.
                            for (uint32_t wi = 0; wi < sv.num_weights && n < kMaxBoneInfluences; wi++) {
                                const ufbx_skin_weight sw = skin->weights.data[sv.weight_begin + wi];
                                if (!(sw.weight > 0.0) || sw.cluster_index >= skin->clusters.count) continue;
                                w[n] = (float)sw.weight;
                                b[n] = (uint16_t)sw.cluster_index;
                                total += w[n];
                                n++;
                            }
                        }
                        if (total > 0.0f) {
                            for (size_t k = 0; k < kMaxBoneInfluences; k++) w[k] /= total;
                        } else {
                            w[0] = 1.0f; // unweighted vertex: follow the first bone
                        }
                        for (size_t k = 0; k < kMaxBoneInfluences; k++) {
                            g.boneWeights.push_back(w[k]);
                            g.boneIndices.push_back(b[k]);
                        }
                    }
                    for (size_t ti = 0; ti < morphChannels.size(); ti++) {
                        const ufbx_blend_shape *shape = morphChannels[ti]->target_shape;
                        const uint32_t oi = ufbx_get_blend_shape_offset_index(shape, vertex);
                        const bool present = oi != UFBX_NO_INDEX && oi < shape->position_offsets.count;
                        ufbx_vec3 po = present ? shape->position_offsets.data[oi] : ufbx_vec3{0, 0, 0};
                        if (bakeWorld) po = ufbx_transform_direction(&geometryToWorld, po);
                        g.morphPositions[ti].push_back((float)po.x);
                        g.morphPositions[ti].push_back((float)po.y);
                        g.morphPositions[ti].push_back((float)po.z);
                        if (morphHasNormals[ti]) {
                            ufbx_vec3 no = (present && oi < shape->normal_offsets.count)
                                ? shape->normal_offsets.data[oi] : ufbx_vec3{0, 0, 0};
                            if (bakeWorld) no = ufbx_transform_direction(&normalsToWorld, no);
                            g.morphNormals[ti].push_back((float)no.x);
                            g.morphNormals[ti].push_back((float)no.y);
                            g.morphNormals[ti].push_back((float)no.z);
                        }
                    }
                }
            }

            // One geometry per mesh, one element per material group, over a
            // single vertex buffer with duplicate corners merged: counting
            // per-corner vertices tripled the vertex count, and a node per
            // group counted one mesh per material.
            GroupBuffers all;
            all.morphPositions.resize(morphChannels.size());
            all.morphNormals.resize(morphChannels.size());
            std::vector<std::pair<size_t, size_t>> ranges; // first corner, corner count
            NSMutableArray<NSNumber *> *usedGroups = [NSMutableArray array];
            for (size_t gi = 0; gi < groupCount; gi++) {
                GroupBuffers &g = groups[gi];
                if (g.positions.empty()) continue;
                ranges.push_back({all.positions.size() / 3, g.positions.size() / 3});
                all.positions.insert(all.positions.end(), g.positions.begin(), g.positions.end());
                all.normals.insert(all.normals.end(), g.normals.begin(), g.normals.end());
                all.uvs.insert(all.uvs.end(), g.uvs.begin(), g.uvs.end());
                all.boneWeights.insert(all.boneWeights.end(), g.boneWeights.begin(), g.boneWeights.end());
                all.boneIndices.insert(all.boneIndices.end(), g.boneIndices.begin(), g.boneIndices.end());
                for (size_t ti = 0; ti < morphChannels.size(); ti++) {
                    all.morphPositions[ti].insert(all.morphPositions[ti].end(), g.morphPositions[ti].begin(), g.morphPositions[ti].end());
                    all.morphNormals[ti].insert(all.morphNormals[ti].end(), g.morphNormals[ti].begin(), g.morphNormals[ti].end());
                }
                [usedGroups addObject:@(gi)];
            }
            const size_t corners = all.positions.size() / 3;
            if (corners == 0) {
                geometryCache[meshKey] = @{};
                continue;
            }

            std::vector<uint32_t> indices(corners);
            std::vector<ufbx_vertex_stream> streams = { { all.positions.data(), corners, 3 * sizeof(float) } };
            if (hasNormals) streams.push_back({ all.normals.data(), corners, 3 * sizeof(float) });
            if (hasUV) streams.push_back({ all.uvs.data(), corners, 2 * sizeof(float) });
            // Skin and morph data take part in the merge too: two corners
            // only collapse into one vertex if they also deform identically.
            if (skin != NULL) {
                streams.push_back({ all.boneWeights.data(), corners, kMaxBoneInfluences * sizeof(float) });
                streams.push_back({ all.boneIndices.data(), corners, kMaxBoneInfluences * sizeof(uint16_t) });
            }
            for (size_t ti = 0; ti < morphChannels.size(); ti++) {
                streams.push_back({ all.morphPositions[ti].data(), corners, 3 * sizeof(float) });
                if (morphHasNormals[ti]) streams.push_back({ all.morphNormals[ti].data(), corners, 3 * sizeof(float) });
            }
            ufbx_error indexError;
            size_t vertexCount = ufbx_generate_indices(streams.data(), streams.size(), indices.data(), corners, NULL, &indexError);
            if (vertexCount == 0) {
                // Dedup failed (allocation): keep every corner as its own vertex.
                vertexCount = corners;
                for (size_t i = 0; i < corners; i++) indices[i] = (uint32_t)i;
            }

            NSMutableArray<SCNGeometrySource *> *sources = [NSMutableArray array];
            [sources addObject:FloatSource(all.positions, vertexCount, 3, SCNGeometrySourceSemanticVertex)];
            if (hasNormals) [sources addObject:FloatSource(all.normals, vertexCount, 3, SCNGeometrySourceSemanticNormal)];
            if (hasUV) [sources addObject:FloatSource(all.uvs, vertexCount, 2, SCNGeometrySourceSemanticTexcoord)];

            NSMutableArray<SCNGeometryElement *> *elements = [NSMutableArray array];
            for (const auto &range : ranges) {
                NSData *idxData = [NSData dataWithBytes:indices.data() + range.first
                                                length:range.second * sizeof(uint32_t)];
                [elements addObject:[SCNGeometryElement geometryElementWithData:idxData
                                                                  primitiveType:SCNGeometryPrimitiveTypeTriangles
                                                                 primitiveCount:(NSInteger)(range.second / 3)
                                                                  bytesPerIndex:sizeof(uint32_t)]];
            }
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            entry[@"geometry"] = [SCNGeometry geometryWithSources:sources elements:elements];
            entry[@"groups"] = usedGroups;

            if (skin != NULL) {
                // The skinner's per-vertex data lives on the skinner, not in
                // the geometry (same split GLTFKit2 makes).
                NSData *weightData = [NSData dataWithBytes:all.boneWeights.data()
                                                    length:vertexCount * kMaxBoneInfluences * sizeof(float)];
                entry[@"boneWeights"] = [SCNGeometrySource geometrySourceWithData:weightData
                                                                         semantic:SCNGeometrySourceSemanticBoneWeights
                                                                      vectorCount:(NSInteger)vertexCount
                                                                  floatComponents:YES
                                                              componentsPerVector:kMaxBoneInfluences
                                                                bytesPerComponent:sizeof(float)
                                                                       dataOffset:0
                                                                       dataStride:kMaxBoneInfluences * sizeof(float)];
                NSData *indexData = [NSData dataWithBytes:all.boneIndices.data()
                                                   length:vertexCount * kMaxBoneInfluences * sizeof(uint16_t)];
                entry[@"boneIndices"] = [SCNGeometrySource geometrySourceWithData:indexData
                                                                         semantic:SCNGeometrySourceSemanticBoneIndices
                                                                      vectorCount:(NSInteger)vertexCount
                                                                  floatComponents:NO
                                                              componentsPerVector:kMaxBoneInfluences
                                                                bytesPerComponent:sizeof(uint16_t)
                                                                       dataOffset:0
                                                                       dataStride:kMaxBoneInfluences * sizeof(uint16_t)];
                // geometry_to_bone maps a bind-pose geometry-space vertex into
                // its bone's space. The vertices are already in world space, so
                // undo geometry_to_world first: bone_world * (g2b * w2g) * (g2w * v).
                const ufbx_matrix worldToGeometry = ufbx_matrix_invert(&geometryToWorld);
                NSMutableArray<NSValue *> *inverseBind = [NSMutableArray array];
                NSMutableArray<NSNumber *> *boneIds = [NSMutableArray array];
                for (size_t ci = 0; ci < skin->clusters.count; ci++) {
                    const ufbx_skin_cluster *cluster = skin->clusters.data[ci];
                    const ufbx_matrix inverseBindMatrix = ufbx_matrix_mul(&cluster->geometry_to_bone, &worldToGeometry);
                    SCNMatrix4 m = SCNMatrixFromUfbx(&inverseBindMatrix);
                    [inverseBind addObject:[NSValue valueWithSCNMatrix4:m]];
                    [boneIds addObject:@(cluster->bone_node->typed_id)];
                }
                entry[@"inverseBind"] = inverseBind;
                entry[@"boneIds"] = boneIds;
            }

            if (!morphChannels.empty()) {
                NSMutableArray<SCNGeometry *> *targets = [NSMutableArray array];
                NSMutableArray<NSNumber *> *channelIds = [NSMutableArray array];
                NSMutableArray<NSNumber *> *initialWeights = [NSMutableArray array];
                for (size_t ti = 0; ti < morphChannels.size(); ti++) {
                    // Offsets, not absolute positions: the morpher runs in
                    // additive mode (base + sum of weight * target).
                    NSMutableArray<SCNGeometrySource *> *targetSources = [NSMutableArray array];
                    [targetSources addObject:FloatSource(all.morphPositions[ti], vertexCount, 3, SCNGeometrySourceSemanticVertex)];
                    if (morphHasNormals[ti]) {
                        [targetSources addObject:FloatSource(all.morphNormals[ti], vertexCount, 3, SCNGeometrySourceSemanticNormal)];
                    }
                    SCNGeometry *target = [SCNGeometry geometryWithSources:targetSources elements:elements];
                    target.name = NSStringFromUfbx(morphChannels[ti]->name);
                    [targets addObject:target];
                    [channelIds addObject:@(morphChannels[ti]->element_id)];
                    [initialWeights addObject:@(morphChannels[ti]->weight)];
                }
                entry[@"morphTargets"] = targets;
                entry[@"morphChannelIds"] = channelIds;
                entry[@"morphWeights"] = initialWeights;
            }
            cached = entry;
            geometryCache[meshKey] = cached;
        }
        if (cached.count == 0) continue;

        // Per-instance materials (each falls back to the mesh's).
        SCNGeometry *geometry = [cached[@"geometry"] copy];
        NSMutableArray<SCNMaterial *> *materials = [NSMutableArray array];
        for (NSNumber *group in cached[@"groups"]) {
            const size_t gi = group.unsignedIntegerValue;
            ufbx_material *umat = NULL;
            if (gi < node->materials.count) umat = node->materials.data[gi];
            else if (gi < mesh->materials.count) umat = mesh->materials.data[gi];
            NSValue *materialKey = [NSValue valueWithPointer:umat];
            SCNMaterial *material = [materialCache objectForKey:materialKey];
            if (material == nil) {
                material = MaterialFromUfbx(umat, unreadableExternalURLs);
                [materialCache setObject:material forKey:materialKey];
            }
            [materials addObject:material];
        }
        geometry.materials = materials;

        // The geometry sits under the mesh node offset by `geometry_to_node`
        // (the non-inherited geometry transform). Combined with the mesh
        // node's world transform this reproduces `geometry_to_world` exactly,
        // and — unlike baking `geometry_to_world` straight onto the mesh node
        // — it leaves the mesh node free to carry the animated local
        // transform.
        SCNNode *geometryNode = [SCNNode nodeWithGeometry:geometry];
        // Named so a morph weight channel can address it by key path.
        geometryNode.name = [meshNode.name stringByAppendingString:@"_geo"];

        if (cached[@"boneIndices"] != nil) {
            // A skinned mesh is placed by its bones alone (FBX ignores the
            // mesh node's own transform): the bind matrices map straight into
            // world space. The geometry therefore sits at the scene root with
            // an identity transform, so what the skinner produces IS the
            // world position, whatever frame SceneKit evaluates it in, and
            // the bounds / camera fit see the real bind-pose extent.
            NSMutableArray<SCNNode *> *bones = [NSMutableArray array];
            for (NSNumber *boneId in cached[@"boneIds"]) [bones addObject:nodeForId[boneId.unsignedIntValue]];
            SCNSkinner *skinner = [SCNSkinner skinnerWithBaseGeometry:geometry
                                                                bones:bones
                                            boneInverseBindTransforms:cached[@"inverseBind"]
                                                          boneWeights:cached[@"boneWeights"]
                                                          boneIndices:cached[@"boneIndices"]];
            geometryNode.skinner = skinner;
            [scnScene.rootNode addChildNode:geometryNode];
        } else {
            geometryNode.transform = SCNMatrixFromUfbx(&node->geometry_to_node);
            [meshNode addChildNode:geometryNode];
        }

        NSArray<SCNGeometry *> *morphGeometries = cached[@"morphTargets"];
        if (morphGeometries.count > 0) {
            SCNMorpher *morpher = [SCNMorpher new];
            morpher.calculationMode = SCNMorpherCalculationModeAdditive;
            morpher.targets = morphGeometries;
            NSArray<NSNumber *> *channelIds = cached[@"morphChannelIds"];
            NSArray<NSNumber *> *initialWeights = cached[@"morphWeights"];
            for (NSUInteger ti = 0; ti < morphGeometries.count; ti++) {
                [morpher setWeight:initialWeights[ti].doubleValue forTargetAtIndex:ti];
                NSArray *existing = morphTargets[channelIds[ti]] ?: @[];
                morphTargets[channelIds[ti]] = [existing arrayByAddingObject:@[geometryNode.name, @(ti)]];
            }
            geometryNode.morpher = morpher;
        }
    }

    // Bake each anim stack into a playable clip. Stacks that key no node
    // transforms (e.g. property-only animation) yield nil and are skipped.
    NSMutableArray<FBXAnimationClip *> *clips = [NSMutableArray array];
    for (size_t si = 0; si < scene->anim_stacks.count; si++) {
        FBXAnimationClip *clip = ClipFromStack(scene, scene->anim_stacks.data[si], nodeNames, morphTargets);
        if (clip != nil) [clips addObject:clip];
    }

    ufbx_free_scene(scene);
    return [[FBXLoadResult alloc] initWithScene:scnScene
                                     animations:clips
                  unreadableExternalTextureURLs:unreadableExternalURLs];
}

@end
