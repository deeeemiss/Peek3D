#import <Foundation/Foundation.h>
#import <SceneKit/SceneKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Result of a successful FBX load: the scene plus any external texture files
/// that referenced files ufbx couldn't read (typically an App Sandbox
/// permission gap — the model file itself was granted access via the open
/// panel/drag-drop, but sibling texture files were not). A non-empty list
/// doesn't mean the load failed: geometry and materials still built fine,
/// just without those specific textures. The caller can use this list to
/// offer the user a folder-access prompt and retry.
@interface FBXLoadResult : NSObject
@property (nonatomic, strong, readonly) SCNScene *scene;
@property (nonatomic, strong, readonly) NSArray<NSURL *> *unreadableExternalTextureURLs;
@end

/// Objective-C++ bridge between the vendored `ufbx` C library and SceneKit.
///
/// Scope (v1): geometry + materials/textures (embedded and external) + correct
/// unit conversion. Skeletal animation is intentionally NOT parsed here — ufbx
/// is loaded with `ignore_animation = true`, so the returned scene carries no
/// animation players. This keeps the FBX path aligned with the app's other
/// loaders (glTF/Model I/O) which converge on a single `SCNScene`.
///
/// All ufbx pointer handling lives inside the `.mm` implementation; Swift only
/// ever sees a finished, ARC-managed `SCNScene`.
@interface FBXSceneBuilder : NSObject

/// Loads an `.fbx` file and returns a scene + load-result metadata, or `nil`
/// on failure with `error` populated. Safe to call off the main thread (pure
/// data work).
+ (nullable FBXLoadResult *)loadFileURL:(NSURL *)url
                                   error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(load(fileURL:));

@end

NS_ASSUME_NONNULL_END
