import AppKit

/// UserDefaults keys for the Settings window. Every value is a STARTING point
/// read when a document window opens (see `ViewerController.init` and
/// `ContentView.showInfo`); changing a preference never touches windows that
/// are already open, the same way Preview or Xcode treat their defaults.
enum SettingsKey {
    static let shadingMode = "defaultShadingMode"
    static let lightingPreset = "defaultLightingPreset"
    static let background = "sceneBackground"
    static let showGrid = "showGridOnOpen"
    static let showInfo = "showInfoOnOpen"
    static let autoplay = "autoplayAnimations"
}

/// Scene background behind the model. Stored by raw value in UserDefaults.
enum SceneBackground: String, CaseIterable, Identifiable {
    case dark, gray, light

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dark: return String(localized: "background.dark", defaultValue: "Dark")
        case .gray: return String(localized: "background.gray", defaultValue: "Gray")
        case .light: return String(localized: "background.light", defaultValue: "Light")
        }
    }

    var color: NSColor {
        switch self {
        case .dark: return NSColor(calibratedWhite: 0.04, alpha: 1)
        case .gray: return NSColor(calibratedWhite: 0.32, alpha: 1)
        case .light: return NSColor(calibratedWhite: 0.88, alpha: 1)
        }
    }
}

/// Per-app language override. macOS itself reads `AppleLanguages` from the
/// app's own defaults domain at launch — the same mechanism System Settings ▸
/// General ▸ Language & Region ▸ Applications uses — so a restart applies it.
enum AppLanguage {
    /// Languages the String Catalog actually has translations for. Add a code
    /// here when a new language lands in Localizable.xcstrings.
    static let supported = ["en", "it"]

    private static let key = "AppleLanguages"

    /// The chosen override, or "" when following the system.
    static var current: String {
        (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String])?.first ?? ""
    }

    static func set(_ code: String) {
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([code], forKey: key)
        }
    }

    /// The language's own name for itself ("English", "Italiano", "日本語"),
    /// so someone who can't read the current UI language can still find theirs.
    static func endonym(_ code: String) -> String {
        Locale(identifier: code).localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }

    /// Relaunches the app so the new language takes effect.
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
