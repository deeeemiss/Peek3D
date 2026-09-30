import SwiftUI

/// Settings window (⌘,). Same structure as MacPortal's: a native `Settings`
/// scene holding a `TabView`, which macOS renders as a Safari-style icon
/// toolbar — a TabView in a sheet would render as pill segments instead.
///
/// Fixed width; the height follows the selected tab, with the animated,
/// top-anchored resize Safari's and Xcode's Settings do. SwiftUI would snap the
/// window to each tab's size instantly, so the content is decoupled from the
/// window height (`maxHeight: .infinity`) and the window itself is resized
/// with `NSWindow.setFrame(_:display:animate:)` once the new tab has been
/// measured.
struct SettingsView: View {
    @State private var window: NSWindow?

    var body: some View {
        TabView {
            tab { GeneralSettings() }
                .tabItem { Label("settings.tab.general", systemImage: "gearshape") }
            tab { ViewerSettings() }
                .tabItem { Label("settings.tab.viewer", systemImage: "cube") }
            tab { AboutSettings() }
                .tabItem { Label("settings.tab.about", systemImage: "info.circle") }
        }
        .frame(width: 620)
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor { found in
            guard window !== found, let found else { return }
            found.styleMask.remove(.resizable)
            window = found
        })
    }

    private func tab<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            content()
        }
        .frame(width: 560, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { resizeWindow(toContentHeight: proxy.size.height) }
                .onChange(of: proxy.size.height) { resizeWindow(toContentHeight: $0) }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Grows or shrinks the window by the difference in content height,
    /// keeping its top edge where it is (AppKit's origin is bottom-left).
    private func resizeWindow(toContentHeight height: CGFloat) {
        // Deferred one runloop turn: on first appearance the window isn't
        // attached yet, and the tab switch itself is still being laid out.
        DispatchQueue.main.async {
            // contentLayoutRect, not contentView.frame: the Settings window
            // draws its toolbar over a full-size content view, so the content
            // view's height includes the toolbar and would overshoot.
            guard let window else { return }
            let delta = height - window.contentLayoutRect.height
            guard abs(delta) > 0.5 else { return }
            var frame = window.frame
            frame.size.height += delta
            frame.origin.y -= delta
            window.setFrame(frame, display: true, animate: window.isVisible)
        }
    }
}

/// Hands back the `NSWindow` hosting a SwiftUI view, which SwiftUI itself
/// doesn't expose.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @State private var language = AppLanguage.current
    /// The language the app was launched with, so the restart prompt only
    /// appears once the choice actually differs from what's on screen.
    private let launchLanguage = AppLanguage.current

    var body: some View {
        SettingsSection(String(localized: "settings.language", defaultValue: "Language"), showsDivider: false) {
            LabeledContent(String(localized: "settings.language.label", defaultValue: "App language")) {
                Picker("", selection: $language) {
                    Text("settings.language.system").tag("")
                    Divider()
                    ForEach(AppLanguage.supported, id: \.self) { code in
                        Text(AppLanguage.endonym(code)).tag(code)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            .onChange(of: language) { AppLanguage.set($0) }

            // Outside LabeledContent: inside it the caption would be squeezed
            // into the right-hand column next to the picker.
            Caption("settings.language.caption")

            if language != launchLanguage {
                HStack {
                    Caption("settings.language.restartNeeded")
                    Spacer()
                    Button("settings.language.restart") { AppLanguage.relaunch() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}

// MARK: - Viewer

private struct ViewerSettings: View {
    @AppStorage(SettingsKey.shadingMode) private var shading = ShadingMode.standard
    @AppStorage(SettingsKey.lightingPreset) private var lighting = LightingPreset.standard
    @AppStorage(SettingsKey.background) private var background = SceneBackground.dark
    @AppStorage(SettingsKey.showGrid) private var showGrid = false
    @AppStorage(SettingsKey.showInfo) private var showInfo = true
    @AppStorage(SettingsKey.autoplay) private var autoplay = true

    var body: some View {
        SettingsSection(String(localized: "settings.viewer.defaults", defaultValue: "New windows")) {
            // A Grid, not one LabeledContent per row: separate LabeledContents
            // each size their own label column, so the pickers don't line up.
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                picker("Shading", selection: $shading, options: ShadingMode.allCases, label: \.displayName)
                picker("Lighting", selection: $lighting, options: LightingPreset.allCases, label: \.displayName)
                picker(String(localized: "settings.viewer.background", defaultValue: "Background"),
                       selection: $background, options: SceneBackground.allCases, label: \.displayName)
            }
            Caption("settings.viewer.defaults.caption")
        }

        SettingsSection(String(localized: "settings.viewer.onOpen", defaultValue: "When a file opens"), showsDivider: false) {
            Toggle("settings.viewer.showGrid", isOn: $showGrid)
            Toggle("settings.viewer.showInfo", isOn: $showInfo)
            Toggle("settings.viewer.autoplay", isOn: $autoplay)
        }
    }

    private func picker<T: Hashable & Identifiable>(
        _ title: String, selection: Binding<T>, options: [T], label: KeyPath<T, String>
    ) -> some View {
        GridRow {
            Text(LocalizedStringKey(title))
            Picker("", selection: selection) {
                ForEach(options) { Text($0[keyPath: label]).tag($0) }
            }
            .labelsHidden()
            .frame(width: 220, alignment: .leading)
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    @Environment(\.openWindow) private var openWindow

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        SettingsSection("Peek3D", showsDivider: false) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("settings.about.version \(version)")
                    Caption("settings.about.tagline")
                }
            }
            HStack(spacing: 10) {
                Link(destination: URL(string: "https://github.com/deeeemiss/Peek3D")!) {
                    Text("settings.about.github")
                }
                .buttonStyle(.bordered)
                Button("ossLicenses.menuItem") { openWindow(id: "licenses") }
                    .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Building blocks

/// Title + content + divider, as in MacPortal. Plain VStack rather than
/// `Form`, whose grouped style looks out of place in a macOS Settings window.
private struct SettingsSection<Content: View>: View {
    let title: String
    /// Off for a tab's last section: a divider there separates it from nothing.
    var showsDivider = true
    let content: Content

    init(_ title: String, showsDivider: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.showsDivider = showsDivider
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
            if showsDivider {
                Divider().padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Caption: View {
    let key: LocalizedStringKey
    init(_ key: LocalizedStringKey) { self.key = key }

    var body: some View {
        Text(key)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
