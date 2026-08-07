import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The window shown at launch and via File ▸ New Window — Xcode/Pages-style
/// "home" screen: logo, an Open button, and the recent-files list. Every
/// document window is opened from here (or from Open Recent / Finder / the
/// Dock icon), never blank — `DocumentGroup(viewing:)` has no "untitled"
/// state for a read-only viewer, so this replaces it.
struct WelcomeView: View {
    @Environment(\.openDocument) private var openDocument
    @State private var recents: [URL] = []
    @State private var isTargeted = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color(white: 0.04).ignoresSafeArea()

            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    isTargeted ? Color.green : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .padding(20)

            VStack(spacing: 28) {
                header
                openButton
                if !recents.isEmpty {
                    recentsList
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.85))
                }
            }
            .padding(40)
            .frame(maxWidth: 420)
        }
        // Was a fixed `.frame(width: 560, height: 480)` back when this
        // window used `.windowResizability(.contentSize)` (a real fixed-size
        // dialog). Peek3DApp.swift now sets `.contentMinSize` with a
        // 900×620 outer minimum instead — a fixed inner size smaller than
        // that minimum left the ZStack's black background (560×480) stranded
        // in the middle of a bigger, resizable window, exposing the raw
        // NSWindow chrome color around it. Matching the same min here lets
        // the ZStack (and its background) actually fill the window.
        .frame(minWidth: 900, minHeight: 620)
        .onAppear(perform: refreshRecents)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.white.opacity(0.7))
            Text("Peek3D")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var openButton: some View {
        Button(action: openPanel) {
            Text("Choose a file…")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.15)))
        .pointerCursor()
    }

    // MARK: - Recents

    private var recentsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("welcome.recents", comment: "Section header above the recent-files list")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(recents, id: \.self) { url in
                        RecentRow(url: url) { open(url: url) }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private func refreshRecents() {
        recents = NSDocumentController.shared.recentDocumentURLs
    }

    // MARK: - Opening

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ModelLoader.supportedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { open(url: url) }
        }
        return true
    }

    private func open(url: URL) {
        errorMessage = nil
        Task {
            do {
                try await openDocument(at: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct RecentRow: View {
    let url: URL
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(url.deletingLastPathComponent().path)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .background(isHovering ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.1)) { isHovering = inside }
        }
    }
}
