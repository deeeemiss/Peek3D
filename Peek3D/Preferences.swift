import AppKit
import SwiftUI

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
    static let supported = ["en", "it", "es", "fr", "de", "pt-BR", "ru", "ar", "ja", "ko", "zh-Hans"]

    private static let key = "AppleLanguages"

    /// The chosen override, or "" when following the system.
    static var current: String {
        (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String])?.first ?? ""
    }

    static func set(_ code: String) {
        let defaults = UserDefaults.standard
        if code.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set([code], forKey: key)
        }
        // AppKit mirrors windows, title bars and toolbars (including the
        // Settings tab order) only when the SYSTEM language is right-to-left.
        // For a per-app choice it needs these two switches — the same ones
        // Xcode sets for its right-to-left test language — read at launch,
        // hence alongside the restart the language change already requires.
        let rtl = !code.isEmpty
            && Locale.Language(identifier: code).characterDirection == .rightToLeft
        for rtlKey in ["AppleTextDirection", "NSForceRightToLeftWritingDirection"] {
            if rtl { defaults.set(true, forKey: rtlKey) } else { defaults.removeObject(forKey: rtlKey) }
        }
    }

    /// The language's own name for itself ("English", "Italiano", "日本語"),
    /// so someone who can't read the current UI language can still find theirs.
    static func endonym(_ code: String) -> String {
        // forIdentifier, not forLanguageCode: keeps the region/script that
        // tells "português (Brasil)" and "中文（简体）" apart.
        Locale(identifier: code).localizedString(forIdentifier: code).map {
            $0.prefix(1).uppercased() + $0.dropFirst()
        } ?? code
    }

    /// Right-to-left for Arabic (and any future RTL language). Read from the
    /// localization the bundle actually resolved, not `Locale.current`, whose
    /// language comes from the system region rather than the app's language.
    /// SwiftUI doesn't derive this on its own for a per-app language choice:
    /// with Arabic selected the whole UI stayed left-to-right.
    static var layoutDirection: LayoutDirection {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.Language(identifier: code).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
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
