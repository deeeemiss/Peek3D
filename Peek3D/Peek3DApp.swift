import SwiftUI
import AppKit

/// Menu-bar commands post here; each document window's `ContentView` is the
/// sole listener for its own scene.
extension Notification.Name {
    static let peek3dFitToView = Notification.Name("peek3d.fitToView")
    static let peek3dToggleWireframe = Notification.Name("peek3d.toggleWireframe")
    static let peek3dToggleGrid = Notification.Name("peek3d.toggleGrid")
    static let peek3dToggleInfo = Notification.Name("peek3d.toggleInfo")
    static let peek3dTakeScreenshot = Notification.Name("peek3d.takeScreenshot")
    static let peek3dToggleFullScreen = Notification.Name("peek3d.toggleFullScreen")
    /// `userInfo["mode"]` carries `ShadingMode.rawValue`.
    static let peek3dSetShadingMode = Notification.Name("peek3d.setShadingMode")
    /// `userInfo["preset"]` carries `LightingPreset.rawValue`.
    static let peek3dSetLightingPreset = Notification.Name("peek3d.setLightingPreset")
}

/// "Window" vs "Panel" (this app's word for a native macOS window tab) is a
/// distinction SwiftUI's `openWindow`/`openDocument` don't make — both just
/// create a plain `NSWindow`, which the system's own "Prefer tabs" setting
/// then may or may not fold into the frontmost window's tab group on its
/// own. These two helpers make the outcome explicit instead of leaving it to
/// that system-wide preference: `detachFromTabGroup` guarantees "Window"
/// really opens standalone, `attach` guarantees "Panel" really joins the
/// window the command was invoked from.
private enum WindowTabbing {
    /// `openWindow`/`openDocument` don't hand back the `NSWindow` they just
    /// made, so this diffs `NSApp.windows` against a snapshot taken before
    /// the call and polls briefly — the window isn't necessarily on screen
    /// the instant the call returns.
    static func afterNewWindow(before: Set<NSWindow>, attempt: Int = 0, place: @escaping (NSWindow) -> Void) {
        if let newWindow = NSApp.windows.first(where: { !before.contains($0) }) {
            place(newWindow)
        } else if attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                afterNewWindow(before: before, attempt: attempt + 1, place: place)
            }
        }
    }

    static func detachFromTabGroup(_ window: NSWindow) {
        window.tabGroup?.removeWindow(window)
    }

    static func attach(_ window: NSWindow, toTabGroupOf target: NSWindow) {
        guard target !== window else { return }
        target.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }
}

/// A view rather than bare `Button`s inside `.commands` so `openWindow` /
/// `openDocument` can be read from the environment — `App.body` itself isn't
/// a view context.
///
/// Replaces the default `.newItem` group entirely (see the doc comment where
/// it's installed): a `DocumentGroup(viewing:)` alongside a `WindowGroup`
/// would otherwise contribute its own always-failing "New Document" command
/// there too. The native "Open…" / "Open Recent" that `DocumentGroup`
/// contributes elsewhere in the File menu can't be removed through any
/// public `CommandGroupPlacement` — they stay, alongside these explicit
/// window/panel variants.
private struct FileMenuCommands: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Button { newWindow(asPanel: false) } label: {
                Label("New Window", systemImage: "macwindow.badge.plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            Button { newWindow(asPanel: true) } label: {
                Label("New Panel", systemImage: "rectangle.stack.badge.plus")
            }
            .keyboardShortcut("t", modifiers: .command)
            Divider()
            Button { openWithPicker(asPanel: false) } label: {
                Label("Open in New Window…", systemImage: "macwindow")
            }
            Button { openWithPicker(asPanel: true) } label: {
                Label("Open in New Panel…", systemImage: "square.grid.2x2")
            }
            // No custom "Open Recent" here — `DocumentGroup` already
            // contributes a native one elsewhere in this menu, and it always
            // opens as a plain new window, which is exactly what a recent
            // file should do. (An earlier version added "in New Window" /
            // "in New Panel" variants of this, reading
            // `NSDocumentController.shared.recentDocumentURLs` — that crashed
            // `DocumentGroup`'s own document-controller bootstrap at launch.)
        }
    }

    private func newWindow(asPanel: Bool) {
        let before = Set(NSApp.windows)
        let keyBefore = NSApp.keyWindow
        openWindow(id: "welcome")
        WindowTabbing.afterNewWindow(before: before) { newWindow in
            if asPanel, let keyBefore {
                WindowTabbing.attach(newWindow, toTabGroupOf: keyBefore)
            } else {
                WindowTabbing.detachFromTabGroup(newWindow)
            }
        }
    }

    private func openWithPicker(asPanel: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ModelLoader.supportedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url, asPanel: asPanel)
    }

    private func open(url: URL, asPanel: Bool) {
        let before = Set(NSApp.windows)
        let keyBefore = NSApp.keyWindow
        // AppKit directly, not `@Environment(\.openDocument)` — combining
        // that action with a replaced `.newItem` command group crashed
        // `DocumentGroup`'s internal document-controller setup at launch.
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in
            WindowTabbing.afterNewWindow(before: before) { newWindow in
                if asPanel, let keyBefore {
                    WindowTabbing.attach(newWindow, toTabGroupOf: keyBefore)
                } else {
                    WindowTabbing.detachFromTabGroup(newWindow)
                }
            }
        }
    }
}

/// Set (to `true`) by `ContentView` while a document window is key, so the
/// "Scene" menu can tell a viewer window from the Welcome window. `nil` (the
/// unset default) means no document window is focused — e.g. only Welcome is
/// open, or Welcome itself is key even with a document window behind it.
private struct ViewerFocusedKey: FocusedValueKey {
    typealias Value = Bool
}

/// Mirrors the focused viewer's `ViewerController.shadingMode`/`.lightingPreset`
/// so the "Scene" menu can show a checkmark and a live icon on its own
/// "Shading"/"Lighting" submenu items — same purpose as `peek3dViewerFocused`,
/// just carrying a value instead of a flag.
private struct ShadingModeFocusedKey: FocusedValueKey {
    typealias Value = ShadingMode
}

private struct LightingPresetFocusedKey: FocusedValueKey {
    typealias Value = LightingPreset
}

extension FocusedValues {
    var peek3dViewerFocused: Bool? {
        get { self[ViewerFocusedKey.self] }
        set { self[ViewerFocusedKey.self] = newValue }
    }

    var peek3dShadingMode: ShadingMode? {
        get { self[ShadingModeFocusedKey.self] }
        set { self[ShadingModeFocusedKey.self] = newValue }
    }

    var peek3dLightingPreset: LightingPreset? {
        get { self[LightingPresetFocusedKey.self] }
        set { self[LightingPresetFocusedKey.self] = newValue }
    }
}

/// Wraps a single "Licenze open source…" menu item so `@Environment(\.openWindow)`
/// can be read — like `FileMenuCommands` above, `.commands` itself isn't a
/// view context. Lives in the app menu (`CommandGroup(after: .appInfo)`,
/// right below "About Peek3D") rather than Help, since it's about this
/// specific binary's third-party notices, not general assistance.
private struct LicensesMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "licenses")
        } label: {
            Text("ossLicenses.menuItem", comment: "App-menu item that opens the open-source licenses window")
        }
    }
}

/// Wraps the "Scene" menu's content so `@FocusedValue` can be read — like
/// `openWindow` above, `.commands` itself isn't a view context.
private struct SceneCommands: View {
    @FocusedValue(\.peek3dViewerFocused) private var isViewerFocused
    @FocusedValue(\.peek3dShadingMode) private var focusedShadingMode
    @FocusedValue(\.peek3dLightingPreset) private var focusedLightingPreset

    var body: some View {
        Group {
            Button { NotificationCenter.default.post(name: .peek3dFitToView, object: nil) } label: {
                Label("Fit to view", systemImage: "viewfinder")
            }
            .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button { NotificationCenter.default.post(name: .peek3dToggleWireframe, object: nil) } label: {
                Label("Wireframe", systemImage: "triangle")
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            Button { NotificationCenter.default.post(name: .peek3dToggleGrid, object: nil) } label: {
                Label("Grid", systemImage: "circle.grid.3x3")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            Button { NotificationCenter.default.post(name: .peek3dToggleInfo, object: nil) } label: {
                Label("Model info", systemImage: "info.circle")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            // Same icon set `ShadingMode`/`LightingPreset` already use for the
            // toolbar's own menu triggers — one per case, checkmark on the
            // active mode and the parent menu's own icon mirroring it, same
            // pattern as `ShadingMenuButton`/`LightingMenuButton` in
            // `ViewerToolbar.swift`.
            Menu {
                ModeMenuItems(current: focusedShadingMode ?? .standard, iconName: \.iconName, displayName: \.displayName) { mode in
                    NotificationCenter.default.post(name: .peek3dSetShadingMode, object: nil, userInfo: ["mode": mode.rawValue])
                }
            } label: {
                Label("Shading", systemImage: (focusedShadingMode ?? .standard).iconName)
            }
            // KNOWN LIMITATION, not fixable from here: AppKit never calls
            // `validateMenuItem` on a menu item that only hosts a submenu (no
            // target/action of its own), so the `.disabled` this Group
            // applies below — which correctly grays out every leaf item —
            // has no effect on the "Shading"/"Lighting" entries' own enabled
            // appearance: their submenu still opens (all-greyed, harmless)
            // even while the Welcome window is focused. Confirmed by testing
            // that applying `.disabled` directly on the `Menu` itself changes
            // nothing either — same root cause, same platform ceiling.
            Menu {
                ModeMenuItems(current: focusedLightingPreset ?? .standard, iconName: \.iconName, displayName: \.displayName) { preset in
                    NotificationCenter.default.post(name: .peek3dSetLightingPreset, object: nil, userInfo: ["preset": preset.rawValue])
                }
            } label: {
                Label("Lighting", systemImage: (focusedLightingPreset ?? .standard).iconName)
            }
            Divider()
            Button { NotificationCenter.default.post(name: .peek3dTakeScreenshot, object: nil) } label: {
                Label("Screenshot", systemImage: "camera")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            Button { NotificationCenter.default.post(name: .peek3dToggleFullScreen, object: nil) } label: {
                Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
        .disabled(isViewerFocused != true)
    }
}

@main
struct Peek3DApp: App {
    init() {
        #if DEBUG
        SelfTest.runIfRequested()
        #endif
    }

    var body: some Scene {
        // The "home" window: shown at launch and via File ▸ New Window. A
        // `.viewing` `DocumentGroup` has no blank/untitled document state, so
        // this is what fills that gap — Open button, recent files, drag&drop.
        WindowGroup(id: "welcome") {
            WelcomeView()
                .environment(\.layoutDirection, AppLanguage.layoutDirection)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        // Sized to its content, deliberately: this screen holds a handful of
        // fixed elements, and letting it be dragged to full screen would just
        // strand them in the middle of a black expanse. An earlier note here
        // described `.contentSize` pinning the height as a defect to avoid —
        // it is now precisely the wanted behaviour, so WelcomeView reports
        // one finite size (no ScrollView, fixed width, capped recents list).
        // Document windows keep `.automatic` below and stay freely resizable
        // and full-screenable, which is where a large window actually helps.
        .windowResizability(.contentSize)

        // One document window per open 3D file. `.viewing` (read-only, no
        // Save/Save As — this app never writes files) gives Open, Open
        // Recent, Finder double-click and Dock-icon drop for free, and macOS
        // merges these into native tabs on its own (Window ▸ Merge All
        // Windows / the "Prefer tabs" system setting) — no custom tab code.
        DocumentGroup(viewing: Peek3DDocument.self) { file in
            // `.viewing` documents have no "New"/untitled state, so every
            // window this closure builds is for a real, already-opened file —
            // `fileURL` is non-nil in practice for every case that reaches here.
            if let url = file.fileURL {
                ContentView(url: url)
                    .environment(\.layoutDirection, AppLanguage.layoutDirection)
                    .preferredColorScheme(.dark)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                LicensesMenuCommand()
            }
            CommandGroup(replacing: .newItem) {
                FileMenuCommands()
            }
            // Named "Scene", not "View" — macOS already injects its own
            // native "View" menu (Show Tab Bar / Show All Tabs / Full Screen,
            // from the window-tabbing feature) once any DocumentGroup app has
            // more than one window; a second, same-named menu here would sit
            // right next to it and confuse the two.
            CommandMenu("Scene") {
                SceneCommands()
            }
        }

        // ⌘, and the app-menu "Settings…" item come for free with this scene.
        // It's a separate scene, so it shares nothing with document windows
        // except UserDefaults — which is all it needs (see SettingsKey).
        Settings {
            SettingsView()
                .environment(\.layoutDirection, AppLanguage.layoutDirection)
        }

        // Third-party license notices (see OpenSourceLicensesView), opened
        // via the "Licenze open source…" app-menu item wired up above. Its
        // own Scene rather than a sheet on Welcome — it needs to be
        // reachable regardless of which window (if any) is currently key.
        // Stays resizable (default `.automatic`), unlike the Welcome window
        // above: license texts are long and users scroll and widen them.
        // `OpenSourceLicensesView`'s own `.frame(minWidth:minHeight:)`
        // enforces the minimum.
        WindowGroup(id: "licenses") {
            OpenSourceLicensesView()
                .environment(\.layoutDirection, AppLanguage.layoutDirection)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
