#import <Foundation/Foundation.h>
#import <SceneKit/SceneKit.h>

NS_ASSUME_NONNULL_BEGIN

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

/// Loads an `.fbx` file and returns a SceneKit scene, or `nil` on failure with
/// `error` populated. Safe to call off the main thread (pure data work).
+ (nullable SCNScene *)sceneFromFileURL:(NSURL *)url
                                  error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
