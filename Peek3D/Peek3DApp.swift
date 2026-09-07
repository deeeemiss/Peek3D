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
    /// Single shared instance, not one per Scene — resolved here so the
    /// very first frame any window draws already has a stable trial/license
    /// status instead of flashing from an initial default.
    @StateObject private var licenseState: LicenseState

    /// Single-machine enforcement — talks to Polar in the background, never
    /// blocking anything `licenseState` already decided locally/offline.
    /// See `LicenseActivationService`'s own doc comment for the full
    /// design; wired to `licenseState` below via
    /// `onLicenseKeyTextApplied`, not a compile-time dependency between the
    /// two types.
    @StateObject private var licenseActivationService: LicenseActivationService

    init() {
        #if DEBUG
        // Makes ONE real HTTP call through HTTPPolarLicenseAPIClient and
        // exits when PEEK3D_POLAR_CLIENT_QUERY is set — see
        // PolarLicenseAPIClientQuery. Checked first, before anything else,
        // since it has no dependency on license state at all.
        PolarLicenseAPIClientQuery.printAndExitIfRequested()

        // Runs (and exits) the black-box license/trial self-test suite when
        // PEEK3D_LICENSE_SELFTEST is set — see LicenseSelfTest. Checked
        // first, before anything below touches the Keychain/UserDefaults
        // state a normal launch would leave alone.
        LicenseSelfTest.runIfRequested()

        // Runs (and exits) the single-machine activation state-machine
        // self-test when PEEK3D_ACTIVATION_SELFTEST is set — see
        // LicenseActivationSelfTest. Same pattern as LicenseSelfTest just
        // above: a scripted FakePolarLicenseAPIClient, zero network, no
        // live Polar account.
        LicenseActivationSelfTest.runIfRequested()

        // Forces an arbitrary trial/license state for manual QA when
        // PEEK3D_LICENSE_DEBUG_STATE is set — see LicenseDebugHarness for
        // the recognised values. Structurally absent from Release builds
        // (this whole call is behind #if DEBUG, and LicenseDebugHarness's
        // own file is too), never an obscure-but-reachable backdoor.
        let resolvedLicenseState = LicenseDebugHarness.makeState() ?? LicenseState()
        _licenseState = StateObject(wrappedValue: resolvedLicenseState)

        // LicenseStateQuery.printAndExitIfRequested(resolvedLicenseState) is
        // deliberately NOT called here anymore — see where it's called
        // further down, after the LicenseActivationService wiring, and the
        // comment there for why.

        // Read-only probe: prints MachineIdentifier.current() and exits when
        // PEEK3D_MACHINE_ID_QUERY is set — see MachineIdentifierQuery. Checked
        // last among the read-only probes; order between them doesn't matter,
        // none of them touch shared state the others depend on.
        MachineIdentifierQuery.printAndExitIfRequested()
        #else
        let resolvedLicenseState = LicenseState()
        _licenseState = StateObject(wrappedValue: resolvedLicenseState)
        #endif

        #if DEBUG
        // Forces the PERSISTED activation record for manual QA when
        // PEEK3D_ACTIVATION_DEBUG_STATE is set — see ActivationDebugHarness.
        // Must run before LicenseActivationService() below, since its
        // init() reads this same persisted record synchronously.
        // Structurally absent from Release builds.
        ActivationDebugHarness.apply()
        #endif

        // Single-machine activation layer — see LicenseActivationService's
        // top doc comment. Wired to resolvedLicenseState via a plain
        // closure hook (LicenseState.onLicenseKeyTextApplied), not a
        // constructor dependency, so neither type needs to know the other
        // exists at compile time beyond this one line.
        let resolvedActivationService = LicenseActivationService()
        #if DEBUG
        // Same test keypair PEEK3D_LICENSE_DEBUG_STATE=licensed already
        // trusts on the LicenseState side (see LicenseDebugHarness) — without
        // this, LicenseVerifier.verify would reject that manufactured
        // license against this service's own (empty in production)
        // trustedPublicKeys, and PEEK3D_LICENSE_DEBUG_STATE=licensed could
        // never actually exercise a real /activate call for manual
        // verification against a local fake Polar server. Harmless no-op
        // for every other PEEK3D_LICENSE_DEBUG_STATE value (there's no
        // license key text to check against it), and structurally absent
        // from Release builds.
        if let testKey = LicenseDebugHarness.testPublicKey {
            resolvedActivationService.debugSetExtraTrustedKeys([testKey])
        }
        #endif
        resolvedLicenseState.onLicenseKeyTextApplied = { [weak resolvedActivationService] text in
            resolvedActivationService?.licenseKeyWasApplied(text)
        }

        // Opposite-direction hook — see LicenseActivationService.onBlockedStateChanged's
        // own doc comment for why the explicit sync call below is required
        // in addition to wiring the closure: `didSet` only fires on a CHANGE
        // after this closure exists, so a `.blocked` state already persisted
        // from a previous launch (resolved synchronously above, in
        // LicenseActivationService.init()) would otherwise never reach
        // resolvedLicenseState at all.
        resolvedActivationService.onBlockedStateChanged = { [weak resolvedLicenseState] blocked in
            resolvedLicenseState?.setRemoteAccessBlocked(blocked)
        }
        resolvedLicenseState.setRemoteAccessBlocked(resolvedActivationService.isBlocked)

        #if DEBUG
        // Read-only probe: prints the state resolved above (INCLUDING
        // isRemotelyBlocked) and exits when PEEK3D_LICENSE_STATE_QUERY is
        // set — see LicenseStateQuery. Moved here, after the
        // LicenseActivationService wiring right above, rather than
        // immediately after `resolvedLicenseState` is constructed: before
        // this point, `isRemotelyBlocked` couldn't yet reflect a persisted
        // `.blocked` record (see `LicenseActivationService.onBlockedStateChanged`'s
        // own doc comment on the initial-sync ordering requirement) — a
        // query run any earlier would silently always report `false`,
        // regardless of what's actually on disk. Still exits well before
        // `launchTimeCheck` below, so this probe never triggers a real
        // network call.
        LicenseStateQuery.printAndExitIfRequested(resolvedLicenseState)
        #endif

        _licenseActivationService = StateObject(wrappedValue: resolvedActivationService)

        #if DEBUG
        // Read-only probe: prints the PERSISTED DeviceActivationRecord and
        // exits when PEEK3D_ACTIVATION_STATE_QUERY is set — see
        // LicenseActivationStateQuery. Meant for a SEPARATE process launch
        // after a normal run already made the real HTTP call; checked here
        // (before launchTimeCheck below) purely so that separate launch
        // exits immediately without also kicking off a network attempt of
        // its own.
        LicenseActivationStateQuery.printAndExitIfRequested()
        #endif

        // Background, 24-hour-gated reverify — never awaited here, never
        // blocks app launch. See LicenseActivationService.launchTimeCheck.
        resolvedActivationService.launchTimeCheck(licenseKeyText: resolvedLicenseState.licenseKeyText)

        SelfTest.runIfRequested()
    }

    var body: some Scene {
        // The "home" window: shown at launch and via File ▸ New Window. A
        // `.viewing` `DocumentGroup` has no blank/untitled document state, so
        // this is what fills that gap — Open button, recent files, drag&drop.
        WindowGroup(id: "welcome") {
            WelcomeView()
                .environmentObject(licenseState)
                .environmentObject(licenseActivationService)
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
            //
            // This closure is the ONE point every open path funnels through
            // — Finder double-click, Dock drop, Open Recent, and
            // WelcomeView's own `openDocument`/`NSDocumentController` calls
            // all end up here, never straight at `ContentView`. It's
            // therefore where the trial gate belongs for brand-new document
            // windows. The other path a new file can enter through — dropping
            // a file onto an ALREADY-open document window, which never
            // re-enters this closure — is gated separately, inside
            // `ContentView.load(url:)`.
            if let url = file.fileURL {
                // `TrialGateView` owns the trial-gate branch itself (not a
                // `Group { if ... }` here) — see its own doc comment for why
                // that's what makes an in-place license activation actually
                // unblock this exact window instead of leaving it stuck.
                TrialGateView(url: url)
                    .environmentObject(licenseState)
                    .environmentObject(licenseActivationService)
                    .preferredColorScheme(.dark)
                    .frame(minWidth: 900, minHeight: 620)
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
            // These used to be replaced with nothing, on the reasoning that a
            // read-only viewer has no text fields and the items would sit
            // permanently disabled. That stopped being true when licensing
            // added a key-entry field: removing the pasteboard group also
            // removes ⌘V, so a customer who copied their key from the
            // purchase email could not paste it — the one interaction the
            // entire purchase depends on. Keep the standard groups.
            // Named "Scene", not "View" — macOS already injects its own
            // native "View" menu (Show Tab Bar / Show All Tabs / Full Screen,
            // from the window-tabbing feature) once any DocumentGroup app has
            // more than one window; a second, same-named menu here would sit
            // right next to it and confuse the two.
            CommandMenu("Scene") {
                SceneCommands()
            }
        }

        // License status/entry (see SettingsView) — the third Scene this
        // app needed: not Welcome (already dense) and not a document window
        // (unreachable with none open). `Cmd+,` is wired up automatically
        // by SwiftUI for any `Settings` scene.
        Settings {
            SettingsView()
                .environmentObject(licenseState)
                .environmentObject(licenseActivationService)
        }

        // Third-party license notices (see OpenSourceLicensesView), opened
        // via the "Licenze open source…" app-menu item wired up above. Its
        // own Scene rather than a sheet on Welcome/Settings — it needs to be
        // reachable regardless of which window (if any) is currently key.
        // Stays resizable (default `.automatic`), unlike the Welcome window
        // above: license texts are long and users scroll and widen them.
        // `OpenSourceLicensesView`'s own `.frame(minWidth:minHeight:)`
        // enforces the minimum.
        WindowGroup(id: "licenses") {
            OpenSourceLicensesView()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
