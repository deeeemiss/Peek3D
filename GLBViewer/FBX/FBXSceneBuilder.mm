#import "FBXSceneBuilder.h"
#import <AppKit/AppKit.h>

#include <vector>
#include <cstdint>

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
        [unreadableExternalURLs addObject:[NSURL fileURLWithPath:path]];
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
};

@implementation FBXLoadResult
- (instancetype)initWithScene:(SCNScene *)scene
   unreadableExternalTextureURLs:(NSArray<NSURL *> *)urls {
    if ((self = [super init])) {
        _scene = scene;
        _unreadableExternalTextureURLs = urls;
    }
    return self;
}
@end

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

    // v1 scope: geometry + materials/textures only. Skeletal animation is out of
    // scope, so we tell ufbx not to load animation curves at all.
    opts.ignore_animation = true;

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
            *error = [NSError errorWithDomain:@"com.seb.GLBViewer.FBX"
                                         code:(NSInteger)uerr.type
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                                     desc.length ? desc : @"FBX load failed" }];
        }
        return nil;
    }

    SCNScene *scnScene = [SCNScene scene];
    NSMutableArray<NSURL *> *unreadableExternalURLs = [NSMutableArray array];

    for (size_t ni = 0; ni < scene->nodes.count; ni++) {
        ufbx_node *node = scene->nodes.data[ni];
        if (node == NULL || node->mesh == NULL) continue;
        ufbx_mesh *mesh = node->mesh;
        if (mesh->num_faces == 0) continue;

        SCNNode *meshNode = [SCNNode node];
        meshNode.name = NSStringFromUfbx(node->name);
        meshNode.transform = SCNMatrixFromUfbx(&node->geometry_to_world);

        // See `MirrorsChirality`: a handedness-mismatched source file bakes a
        // mirror into this node's transform rather than into vertex positions,
        // so the UVs (authored before that mirror) read backwards on one axis.
        // Flip U to compensate; a normal right-handed file is untouched.
        const bool uvNeedsMirrorCompensation = MirrorsChirality(&node->geometry_to_world);

        const size_t groupCount = mesh->materials.count > 0 ? mesh->materials.count : 1;
        std::vector<GroupBuffers> groups(groupCount);

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
                g.positions.push_back((float)p.x);
                g.positions.push_back((float)p.y);
                g.positions.push_back((float)p.z);

                if (hasNormals) {
                    ufbx_vec3 n = ufbx_get_vertex_vec3(&mesh->vertex_normal, ix);
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
            }
        }

        for (size_t gi = 0; gi < groupCount; gi++) {
            GroupBuffers &g = groups[gi];
            const NSInteger vertexCount = (NSInteger)(g.positions.size() / 3);
            if (vertexCount == 0) continue;

            NSMutableArray<SCNGeometrySource *> *sources = [NSMutableArray array];

            NSData *posData = [NSData dataWithBytes:g.positions.data()
                                            length:g.positions.size() * sizeof(float)];
            [sources addObject:[SCNGeometrySource geometrySourceWithData:posData
                                                               semantic:SCNGeometrySourceSemanticVertex
                                                            vectorCount:vertexCount
                                                        floatComponents:YES
                                                    componentsPerVector:3
                                                      bytesPerComponent:sizeof(float)
                                                             dataOffset:0
                                                             dataStride:3 * sizeof(float)]];

            if (!g.normals.empty()) {
                NSData *nData = [NSData dataWithBytes:g.normals.data()
                                              length:g.normals.size() * sizeof(float)];
                [sources addObject:[SCNGeometrySource geometrySourceWithData:nData
                                                                   semantic:SCNGeometrySourceSemanticNormal
                                                                vectorCount:vertexCount
                                                            floatComponents:YES
                                                        componentsPerVector:3
                                                          bytesPerComponent:sizeof(float)
                                                                 dataOffset:0
                                                                 dataStride:3 * sizeof(float)]];
            }
            if (!g.uvs.empty()) {
                NSData *uvData = [NSData dataWithBytes:g.uvs.data()
                                               length:g.uvs.size() * sizeof(float)];
                [sources addObject:[SCNGeometrySource geometrySourceWithData:uvData
                                                                   semantic:SCNGeometrySourceSemanticTexcoord
                                                                vectorCount:vertexCount
                                                            floatComponents:YES
                                                        componentsPerVector:2
                                                          bytesPerComponent:sizeof(float)
                                                                 dataOffset:0
                                                                 dataStride:2 * sizeof(float)]];
            }

            // Vertices are already expanded per triangle corner, so the index
            // buffer is simply 0,1,2,...
            std::vector<uint32_t> indices((size_t)vertexCount);
            for (uint32_t i = 0; i < (uint32_t)vertexCount; i++) indices[i] = i;
            NSData *idxData = [NSData dataWithBytes:indices.data()
                                            length:indices.size() * sizeof(uint32_t)];
            SCNGeometryElement *element =
                [SCNGeometryElement geometryElementWithData:idxData
                                              primitiveType:SCNGeometryPrimitiveTypeTriangles
                                             primitiveCount:vertexCount / 3
                                              bytesPerIndex:sizeof(uint32_t)];

            SCNGeometry *geometry = [SCNGeometry geometryWithSources:sources elements:@[element]];

            // Per-instance material at this group index (falls back to the mesh's).
            ufbx_material *umat = NULL;
            if (gi < node->materials.count) umat = node->materials.data[gi];
            else if (gi < mesh->materials.count) umat = mesh->materials.data[gi];
            geometry.firstMaterial = MaterialFromUfbx(umat, unreadableExternalURLs);

            SCNNode *groupNode = [SCNNode nodeWithGeometry:geometry];
            [meshNode addChildNode:groupNode];
        }

        [scnScene.rootNode addChildNode:meshNode];
    }

    ufbx_free_scene(scene);
    return [[FBXLoadResult alloc] initWithScene:scnScene
                  unreadableExternalTextureURLs:unreadableExternalURLs];
}

@end
