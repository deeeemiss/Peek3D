import SceneKit
import AppKit

/// What one viewer window shows, and the load that gets it there. Lives
/// outside `ContentView` so the Debug self-test can drive exactly the code a
/// drop runs and check what ends up on screen (see `SelfTest.runSequence`).
final class ModelSession: ObservableObject {
    @Published private(set) var scene: SCNScene?
    @Published private(set) var stats: ModelStats?
    @Published private(set) var animations: [ModelAnimation] = []
    @Published var errorMessage: String?
    /// Set when a model references external files the sandbox wouldn't let
    /// it read (or, for a .gltf, can't load without them). Offers a
    /// folder-access prompt + reload instead of silently showing a
    /// textureless model.
    @Published var missingTexturePrompt: (modelURL: URL, count: Int)?
    /// True from a `load(url:)` call until the latest one has applied its
    /// result.
    @Published private(set) var isLoading = false

    /// Bumped on every `load(url:)` call and captured by that call's
    /// completion handler. `ModelLoader.load` runs off-main and offers no
    /// ordering guarantee — if the user drops a second file while the first
    /// is still decoding, the two completions can land in either order. Without
    /// this guard, a slow first load finishing AFTER a fast second load would
    /// silently overwrite the newer model/stats with the stale one. Only the
    /// completion whose token still matches the latest `loadGeneration` is
    /// allowed to apply its result.
    private var loadGeneration = 0

    func load(url: URL) {
        errorMessage = nil
        missingTexturePrompt = nil
        isLoading = true
        loadGeneration += 1
        let generation = loadGeneration
        ModelLoader.load(url: url) { result in
            // A newer load (e.g. a second file dropped before this one
            // finished decoding) has already started or completed — discard
            // this stale result instead of clobbering the newer state.
            guard generation == self.loadGeneration else { return }
            self.isLoading = false
            switch result {
            case .success(let model):
                // Set animations before the scene so the new list is in place
                // by the time `SceneContainerView` re-attaches on the scene swap.
                self.animations = model.animations
                self.scene = model.scene
                self.stats = model.stats
                Self.announce(String(localized: "a11y.loaded \(model.stats.fileName)"))
                if !model.missingExternalTextureURLs.isEmpty {
                    self.missingTexturePrompt = (url, model.missingExternalTextureURLs.count)
                    Self.announce(String(localized: "missingTexture.count \(model.missingExternalTextureURLs.count)"))
                }
            case .failure(ModelLoadError.needsFolderAccess(let urls)):
                self.missingTexturePrompt = (url, urls.count)
                Self.announce(String(localized: "missingTexture.count \(urls.count)"))
            case .failure(let error):
                self.errorMessage = Self.userMessage(for: error)
                Self.announce(self.errorMessage ?? "")
            }
        }
    }

    /// Banners and load results appear without focus moving, so VoiceOver
    /// wouldn't notice them on its own.
    private static func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Peek3D's own load errors are already localized, user-facing sentences.
    /// Errors from GLTFKit2 and ufbx are English technical text ("The asset
    /// contains invalid JSON data."), so those get a localized generic
    /// message instead, with the detail kept in the log for diagnosis.
    private static func userMessage(for error: Error) -> String {
        if error is GLTFValidator.Invalid || error is ModelLoadError {
            return error.localizedDescription
        }
        NSLog("Peek3D: load failed: %@", String(describing: error))
        return String(localized: "error.openFailed",
                      defaultValue: "This file couldn't be opened. It may be damaged or use a feature Peek3D doesn't support yet.")
    }
}
