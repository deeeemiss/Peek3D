#import <Foundation/Foundation.h>
#import <SceneKit/SceneKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One playable clip extracted from an FBX file: a name (the FBX anim-stack /
/// take name) and a ready-to-attach `SCNAnimationPlayer`. The player's
/// `SCNAnimation` wraps a `CAAnimationGroup` whose channels address the target
/// nodes by absolute key path (`/<nodeName>.position|orientation|scale`), the
/// same shape GLTFKit2 produces — so the player is added straight to
/// `scene.rootNode` and drives the matching nodes, and the rest of the app
/// (timeline, play/pause, wireframe-during-playback) treats it identically to a
/// glTF clip. Bridges to Swift's `ModelAnimation`.
@interface FBXAnimationClip : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, strong, readonly) SCNAnimationPlayer *player;
@end

/// Result of a successful FBX load: the scene, any playable animation clips, and
/// any external texture files that referenced files ufbx couldn't read
/// (typically an App Sandbox permission gap — the model file itself was granted
/// access via the open panel/drag-drop, but sibling texture files were not). A
/// non-empty unreadable list doesn't mean the load failed: geometry and
/// materials still built fine, just without those specific textures. The caller
/// can use it to offer the user a folder-access prompt and retry.
@interface FBXLoadResult : NSObject
@property (nonatomic, strong, readonly) SCNScene *scene;
@property (nonatomic, strong, readonly) NSArray<FBXAnimationClip *> *animations;
@property (nonatomic, strong, readonly) NSArray<NSURL *> *unreadableExternalTextureURLs;
@end

/// Objective-C++ bridge between the vendored `ufbx` C library and SceneKit.
///
/// Scope: geometry + materials/textures (embedded and external) + correct unit
/// conversion + NODE-TRANSFORM (rigid/hierarchical) animation. The scene mirrors
/// the FBX node hierarchy so each node's local transform can be keyed; clips are
/// baked with `ufbx_bake_anim` into per-node translation/rotation/scale
/// keyframes and returned as `SCNAnimationPlayer`s aligned with the app's other
/// loaders (glTF/Model I/O), which converge on a single `SCNScene`.
///
/// Skinning: a skinned mesh becomes a node with an `SCNSkinner` whose bones are
/// the real hierarchy nodes (so the baked clip moves them); its vertices are
/// stored in world bind space at the scene root. Blend shapes become an
/// additive `SCNMorpher` whose weights the clip animates via
/// `morpher.weights[i]`. NOT covered: property animation (visibility, material
/// params), dual-quaternion skinning, blend-shape in-betweens.
///
/// All ufbx pointer handling lives inside the `.mm` implementation; Swift only
/// ever sees a finished, ARC-managed `SCNScene` + `SCNAnimationPlayer`s.
@interface FBXSceneBuilder : NSObject

/// Loads an `.fbx` file and returns a scene + load-result metadata, or `nil`
/// on failure with `error` populated. Safe to call off the main thread (pure
/// data work).
+ (nullable FBXLoadResult *)loadFileURL:(NSURL *)url
                                   error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(load(fileURL:));

@end

NS_ASSUME_NONNULL_END
