import SwiftUI
import AppKit

/// Which `RemoteActivationStatus` cases are worth interrupting the user
/// about, and how urgent each one reads. A UI-facing classification — kept
/// here, not on `RemoteActivationStatus` itself, so that type (see its own
/// doc comment) stays free of presentation concerns and only describes what
/// Polar actually said.
///
/// Deliberately silent for `.notActivated`, `.checking`, `.active`, and
/// `.unreachable` while still within the 30-day offline grace — per this
/// feature's non-negotiable rule (`LicenseActivationService`'s top doc
/// comment), an unreachable server must never itself read as "invalid
/// license", and none of these four have anything actionable to tell the
/// user right now.
enum BannerSeverity {
    case warning, critical
}

extension RemoteActivationStatus {
    /// Not `private`/`fileprivate` — `ContentView` reads this too, to decide
    /// whether to mount the top-pinned positioning wrapper around
    /// `RemoteActivationBanner` at all (same reason `WelcomeView` needs it:
    /// an always-present `EmptyView()` inside a spaced `VStack` still costs
    /// a `spacing` gap on either side, see `RemoteActivationBanner`'s own
    /// doc comment).
    var bannerSeverity: BannerSeverity? {
        switch self {
        case .notActivated, .checking, .active:
            return nil
        case .unreachable(_, let withinOfflineGrace):
            return withinOfflineGrace ? nil : .warning
        case .deviceConflict, .revokedGracePeriod:
            return .warning
        case .blocked:
            return .critical
        }
    }
}

/// Same `NSAccessibility.post(...announcementRequested)` pattern
/// `LicenseEntrySheet.postAccessibilityAnnouncement` established (see that
/// method's own doc comment for why this specific API, not SwiftUI's
/// macOS-14-only announcement type) — pulled out here since
/// `RemoteActivationBanner` needed the identical behavior for a second,
/// independent set of announcements. `LicenseEntrySheet`'s own copy is left
/// untouched rather than retrofitted to call this, to avoid touching
/// already-verified code for a purely cosmetic dedup.
enum AccessibilityAnnouncer {
    static func post(_ message: String) {
        guard let target = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: target,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

/// A single, self-contained status box for `LicenseActivationService.remoteStatus`
/// — reused by `WelcomeView` (stacked inline, like its existing `errorMessage`
/// block) and `ContentView` (top-pinned floating, like `trialToastBanner`,
/// except this one does NOT auto-dismiss: a revoked license or an unresolved
/// device conflict isn't something to flash past and forget). Each call site
/// owns its own positioning; this view only owns the box's content and
/// styling, plus the announcement side-effect.
///
/// Returns `EmptyView()` for any status with no `bannerSeverity` — callers
/// that stack this inline (`WelcomeView`) must still wrap it in `if
/// licenseActivationService.remoteStatus.bannerSeverity != nil { ... }`
/// themselves, the same way `WelcomeView` already conditions its
/// `errorMessage` block, so an invisible `EmptyView()` doesn't silently eat a
/// `VStack` spacing gap on either side of it.
struct RemoteActivationBanner: View {
    @EnvironmentObject private var licenseState: LicenseState
    @EnvironmentObject private var licenseActivationService: LicenseActivationService

    @State private var isRetrying = false

    var body: some View {
        Group {
            if let severity = licenseActivationService.remoteStatus.bannerSeverity {
                content(for: licenseActivationService.remoteStatus, severity: severity)
            }
        }
        .onChange(of: licenseActivationService.remoteStatus) { newStatus in
            guard let text = announcementText(for: newStatus) else { return }
            AccessibilityAnnouncer.post(text)
        }
    }

    @ViewBuilder
    private func content(for status: RemoteActivationStatus, severity: BannerSeverity) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: status))
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(message(for: status))
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if case .deviceConflict = status {
                    retryButton
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(
            (severity == .critical ? Color.peekError : Color.peekAmber).opacity(0.92),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.15)))
        .accessibilityElement(children: .combine)
    }

    private var retryButton: some View {
        Button {
            retry()
        } label: {
            if isRetrying {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Text("activation.banner.retry", comment: "Button on the device-conflict banner, retries activation for this Mac")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
        .disabled(isRetrying)
        .pointerCursor()
    }

    private func retry() {
        guard let key = licenseState.licenseKeyText else { return }
        isRetrying = true
        licenseActivationService.retryActivation(licenseKeyText: key)
        // `retryActivation` is fire-and-forget (see its own doc comment) —
        // there's no completion to await here, so this just gives the
        // button a brief, honest "something is happening" state instead of
        // claiming to track the in-flight request precisely. `remoteStatus`
        // itself (read by this same view) is the actual source of truth for
        // the outcome once it lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isRetrying = false }
    }

    private func icon(for status: RemoteActivationStatus) -> String {
        switch status {
        case .revokedGracePeriod: return "exclamationmark.triangle.fill"
        case .blocked: return "lock.fill"
        case .deviceConflict: return "exclamationmark.arrow.triangle.2.circlepath"
        case .unreachable: return "wifi.slash"
        case .notActivated, .checking, .active: return "info.circle"
        }
    }

    private func message(for status: RemoteActivationStatus) -> String {
        switch status {
        case .revokedGracePeriod(_, let hardBlockDeadline):
            return String(
                localized: "activation.banner.revokedGrace",
                defaultValue: "Your license was reported as revoked. Peek3D keeps working normally until \(hardBlockDeadline.formatted(date: .abbreviated, time: .shortened)) — contact peek3d@sebdemichelis.dev if this looks wrong.",
                comment: "Banner shown once the server reports this device's activation as revoked/disabled, during the 72-hour grace period before access is actually restricted. The embedded date/time is the moment the grace period ends."
            )
        case .blocked:
            return String(
                localized: "activation.banner.blocked",
                defaultValue: "This license's activation was revoked more than 72 hours ago. New files can no longer be opened — contact peek3d@sebdemichelis.dev if this looks wrong.",
                comment: "Banner shown once the 72-hour revocation grace period has elapsed and new file opens are now blocked."
            )
        case .deviceConflict:
            return conflictMessage
        case .unreachable:
            return String(
                localized: "activation.banner.offlineGraceExpired",
                defaultValue: "Peek3D hasn't been able to verify your license online in over 30 days. Connect to the internet briefly to keep using it.",
                comment: "Banner shown once the 30-day offline grace period has elapsed without a successful background check. This is NOT a statement that the license is invalid — only that it couldn't be re-checked."
            )
        case .notActivated, .checking, .active:
            return ""
        }
    }

    private var conflictMessage: String {
        let remaining = licenseActivationService.remainingFreeTransfers
        let lead = String(
            localized: "activation.banner.deviceConflict",
            defaultValue: "This license is already active on another Mac. If that's you, open Peek3D there, go to Settings, and deactivate it — then come back here and retry.",
            comment: "Banner shown when this device's activation attempt was rejected because the license's Mac seat is already taken elsewhere. Does NOT mean this device lost access — see this feature's non-negotiable rule about device conflicts."
        )
        let remainingLine = String(
            localized: "activation.banner.remainingTransfers",
            defaultValue: "\(remaining) free reactivation(s) left.",
            comment: "Second line under the device-conflict banner, stating how many free reactivations remain on this license — informational, not enforcement."
        )
        return lead + "\n" + remainingLine
    }

    /// What to actually speak on a genuine transition INTO a bannered state
    /// — mirrors `message(for:)` but returns `nil` for a transition OUT of
    /// one (silence, not a "never mind" announcement) or between two
    /// non-bannered states.
    private func announcementText(for newStatus: RemoteActivationStatus) -> String? {
        guard newStatus.bannerSeverity != nil else { return nil }
        let text = message(for: newStatus)
        return text.isEmpty ? nil : text
    }
}
