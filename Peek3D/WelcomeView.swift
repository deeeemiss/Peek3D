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
    @EnvironmentObject private var licenseState: LicenseState
    @State private var recents: [URL] = []
    @State private var isTargeted = false
    @State private var errorMessage: String?
    @State private var showLicenseSheet = false

    var body: some View {
        ZStack {
            Color(white: 0.04).ignoresSafeArea()

            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    isTargeted ? Color.green : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .padding(20)

            ScrollView {
                VStack(spacing: 30) {
                    header
                    dropZone
                    formatsRow
                    recentsSection
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.red.opacity(0.85))
                    }
                    trialStatusFooter
                    footer
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 40)
                .frame(maxWidth: 560)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // Trial exhausted: a dropped file would only reach the paywall
            // in a brand-new document window (see `TrialGateView`) after a
            // real load attempt — the same dead end the drop zone's button
            // avoids below. Route straight to license entry instead, and
            // still return true so the drag doesn't show a "rejected" cursor.
            guard !isTrialExhausted else {
                showLicenseSheet = true
                return true
            }
            return handleDrop(providers)
        }
        .sheet(isPresented: $showLicenseSheet) {
            LicenseEntrySheet()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            Image("Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            VStack(spacing: 6) {
                Text("Peek3D")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0.35, green: 0.68, blue: 1.0), .white],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                // "Drop a 3D file. Look at it." is an invitation to do the
                // one thing that's currently blocked — swap in a tagline
                // that doesn't dangle a carrot the trial-exhausted state
                // won't let the user reach. `isTrialExhausted` is declared
                // further down in this file; Swift resolves it fine since
                // both are members of the same type.
                Text(
                    isTrialExhausted ? "welcome.tagline.trialExhausted" : "welcome.tagline",
                    comment: "Short tagline under the app name on the Welcome screen. The trial-exhausted variant must NOT invite the drag/drop action the exhausted state blocks."
                )
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    // MARK: - Drop zone

    /// True once the distinct-file trial is used up. Read-only here — the
    /// gate itself (`LicenseState.canOpen(url:)`, enforced by `TrialGateView`
    /// at document-open time) stays the single source of truth; this only
    /// decides what the Welcome screen shows and where its drop zone/button
    /// send the user, so the dead-end of loading a file into a fresh window
    /// just to hit the paywall there is avoided.
    private var isTrialExhausted: Bool {
        if case .trialExhausted = licenseState.status { return true }
        return false
    }

    @ViewBuilder
    private var dropZone: some View {
        if isTrialExhausted {
            exhaustedDropZone
        } else {
            openDropZone
        }
    }

    private var openDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color(red: 0.35, green: 0.68, blue: 1.0).opacity(0.85))
            Text("welcome.dropHint", comment: "Instructs the user they can drag a 3D file onto the window")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
        )
    }

    /// Same container chrome as `openDropZone`, but the copy, icon, and
    /// action all come from the trial-exhausted register already established
    /// by `TrialGateView` — a neutral lock (not the inviting accent blue), a
    /// sentence naming the trial limit, and a filled CTA straight into
    /// `LicenseEntrySheet` instead of `NSOpenPanel`.
    private var exhaustedDropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
            Text(
                String(
                    localized: "welcome.trial.exhaustedMessage",
                    defaultValue: "You've used all your trial opens (\(LicenseRecord.trialLimit)/\(LicenseRecord.trialLimit)).",
                    comment: "Welcome screen's exhausted-trial drop zone message. Both %lld are the same trial-limit constant, shown as an N/N ratio."
                )
            )
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            Button {
                showLicenseSheet = true
            } label: {
                Text("welcome.trial.unlockButton", comment: "CTA in the Welcome screen's exhausted-trial drop zone")
            }
            .buttonStyle(PeekFilledButtonStyle())
            .pointerCursor()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
        )
    }

    // MARK: - Supported formats

    private static let supportedFormatLabels = [
        "glb", "gltf", "fbx", "obj", "usdz", "usd", "stl", "dae", "ply", "abc",
    ]

    private var formatsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("welcome.formats", comment: "Section header above the row of supported file format chips")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            FlowLayout(spacing: 6) {
                ForEach(Self.supportedFormatLabels, id: \.self) { format in
                    Text(format.uppercased())
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }

    // MARK: - Recents

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("welcome.recents", comment: "Section header above the recent-files list")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            if recents.isEmpty {
                Text("welcome.recents.empty", comment: "Shown in the recents section when no file has been opened yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 2) {
                    ForEach(recents, id: \.self) { url in
                        RecentRow(url: url) { open(url: url) }
                    }
                }
            }
        }
    }

    // MARK: - Trial status

    /// Invisible above 5 opens remaining. Quiet (11pt, white 40%) from 5
    /// down to 4; from 3 down to 1 it escalates to 12pt amber medium-weight
    /// with a clickable "· Sblocca Peek3D" straight into license entry —
    /// the critical phase where the user is about to hit `TrialGateView`
    /// for real.
    @ViewBuilder
    private var trialStatusFooter: some View {
        if case .trial(let remaining) = licenseState.status, remaining <= 5 {
            if remaining <= 3 {
                HStack(spacing: 4) {
                    Text(TrialCopy.remainingText(remaining))
                    Button {
                        showLicenseSheet = true
                    } label: {
                        Text("welcome.trial.unlockLink", comment: "Inline underlined link appended after the critical-phase countdown, e.g. '· Unlock Peek3D'. Leading separator is part of the localized string since some languages may punctuate differently.")
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.peekAmber)
            } else {
                Text(TrialCopy.remainingText(remaining))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var footer: some View {
        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.2))
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

/// Wraps its children onto multiple rows, left-to-right, breaking to a new
/// row when the next child would overflow the available width — used for
/// the format-chip list, whose count/widths aren't known up front.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + (rowWidth > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
