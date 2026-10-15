#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Decoder for `KHR_draco_mesh_compression`, plugged into GLTFKit2's
/// `GLTFDracoMeshDecompressor` hook. GLTFKit2 ships no Draco code of its own:
/// without this class a Draco `.glb` fails with "unsupported extension".
///
/// GLTFKit2 cannot be told that a decode failed. Handed `nil` it carries on
/// building the asset with the primitive's original accessors, which for a
/// Draco primitive have no data behind them. So a failure is recorded per
/// thread (GLTFKit2 decodes on the calling thread) and the loader must check
/// `takeFailureReason` right after `GLTFAsset` is created and discard the
/// asset, before anything converts it to SceneKit.
@interface Peek3DDracoDecompressor : NSObject

/// Registers the class with GLTFKit2. The setting is process-wide and
/// idempotent; call it before loading any glTF.
+ (void)registerWithGLTFKit;

/// Forgets any failure recorded on this thread. Call before loading.
+ (void)clearFailure;

/// The first reason a Draco primitive failed to decode on this thread since
/// the last `clearFailure` / `takeFailureReason`, or nil if every one decoded.
/// Developer-facing English text (for logs), not for the user.
+ (nullable NSString *)takeFailureReason;

@end

NS_ASSUME_NONNULL_END
