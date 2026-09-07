import SwiftUI

/// Content of the app's Settings scene (`Cmd+,`, `Peek3DApp.body`'s
/// `Settings { }`) — the one place a licensed user can see their license
/// status. Not Welcome (already dense with drop-zone/formats/recents) and
/// not a document window (unreachable with zero documents open), so this
/// gets its own top-level Scene, per this feature's brief.
///
/// The brief only specifies this view's content for the `.licensed` case
/// (status, holder, masked key, "Cambia licenza"). Settings has to render
/// *something* in the other two states too, though — `Cmd+,` is reachable
/// at any point, licensed or not — so the trial/exhausted branch below is
/// this file's own interpretation call: a compact status line plus the same
/// "Inserisci licenza" entry point, not specified verbatim anywhere in the
/// brief.
struct SettingsView: View {
    @EnvironmentObject private var licenseState: LicenseState
    @EnvironmentObject private var licenseActivationService: LicenseActivationService
    @State private var showLicenseSheet = false
    @State private var isDeactivating = false
    @State private var deactivationFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch licenseState.status {
            case .licensed(let holder):
                licensedBody(holder: holder)
            case .trial(let remaining):
                unlicensedBody(statusLine: TrialCopy.remainingText(remaining))
            case .trialExhausted:
                unlicensedBody(statusLine: TrialCopy.exhaustedShort)
            }
        }
        .padding(28)
        .frame(width: 420)
        // Explicit, not inherited: Settings is a separate NSWindow-backed
        // scene from the document/Welcome windows, and the app is dark-only
        // by design (see CLAUDE.md) — without this it would pick up the
        // system's light appearance instead of matching the rest of the app.
        .background(Color(white: 0.08))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLicenseSheet) {
            LicenseEntrySheet()
        }
        // Same discipline `LicenseEntrySheet` established for its own
        // error/success banners (see `AccessibilityAnnouncer`'s doc
        // comment) — a VoiceOver user who just pressed "Disattiva questo
        // Mac" and has moved focus elsewhere should still hear the outcome.
        .onChange(of: deactivationFeedback) { newValue in
            guard let newValue else { return }
            AccessibilityAnnouncer.post(newValue)
        }
    }

    // MARK: - Licensed

    private func licensedBody(holder: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("settings.license.active", comment: "Header shown when a valid license is active")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 12) {
                settingsRow(
                    label: String(localized: "settings.license.holderLabel", defaultValue: "Licensed to", comment: "Row label above the license holder's name"),
                    value: holder
                )
                settingsRow(
                    label: String(localized: "settings.license.keyLabel", defaultValue: "Key", comment: "Row label above the masked license key"),
                    value: maskedKey,
                    monospacedValue: true,
                    accessibilityValueOverride: maskedKeyAccessibilityDescription
                )
            }

            Divider().overlay(.white.opacity(0.1))

            activationSection

            Button {
                showLicenseSheet = true
            } label: {
                Text("settings.license.changeButton", comment: "Button that reopens the license-entry sheet to replace the current license")
            }
                .buttonStyle(PeekGhostButtonStyle())
                .pointerCursor()
        }
    }

    // MARK: - This Mac's activation (single-machine enforcement)

    /// This device's status against Polar's single-machine activation
    /// system — a DIFFERENT fact from the license-holder/key rows above,
    /// which only reflect the offline, signature-verified layer. A device
    /// can be `.licensed` (valid signature) while this section shows
    /// anything from "not yet verified" to "revoked" — see
    /// `LicenseActivationService`'s own doc comment for why the two layers
    /// are deliberately independent.
    private var activationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("settings.activation.header", comment: "Section header for this device's single-machine activation status, distinct from the license-holder/key rows above it")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))

            let display = activationStatusDisplay
            HStack(spacing: 8) {
                if case .checking = licenseActivationService.remoteStatus {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: display.icon)
                        .foregroundStyle(display.tint)
                        .accessibilityHidden(true)
                }
                Text(display.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .accessibilityElement(children: .combine)

            if licenseActivationService.hasActivationToFree {
                Button {
                    deactivateThisDevice()
                } label: {
                    if isDeactivating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("settings.activation.deactivateButton", comment: "Button that frees this Mac's seat on the currently activated license — what a user does before selling or replacing this Mac")
                    }
                }
                .buttonStyle(PeekGhostButtonStyle())
                .disabled(isDeactivating)
                .pointerCursor()
            }

            if let deactivationFeedback {
                Text(deactivationFeedback)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var activationStatusDisplay: (icon: String, tint: Color, text: String) {
        switch licenseActivationService.remoteStatus {
        case .notActivated:
            return ("questionmark.circle", .white.opacity(0.4), String(localized: "settings.activation.status.notActivated", defaultValue: "Not yet verified online", comment: "This device's activation status in Settings: no activation attempt has completed yet"))
        case .checking:
            return ("circle", .white.opacity(0.4), String(localized: "settings.activation.status.checking", defaultValue: "Verifying…", comment: "This device's activation status in Settings: a check is in flight right now"))
        case .active(let lastVerifiedAt):
            let dateText = lastVerifiedAt.formatted(date: .abbreviated, time: .shortened)
            return ("checkmark.circle.fill", .green, String(localized: "settings.activation.status.active", defaultValue: "Active on this Mac (verified \(dateText))", comment: "This device's activation status in Settings: currently confirmed active, with the last successful verification timestamp"))
        case .unreachable(let lastKnownGoodAt, let withinOfflineGrace):
            if withinOfflineGrace {
                let dateText = lastKnownGoodAt?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "settings.activation.status.never", defaultValue: "never", comment: "Fallback for 'verified never' when this device has no successful verification on record yet")
                return ("wifi.slash", Color.peekAmber, String(localized: "settings.activation.status.offlineGrace", defaultValue: "Active on this Mac (offline since \(dateText), still working)", comment: "This device's activation status in Settings: can't reach the server right now, but still within the 30-day offline grace period"))
            } else {
                return ("wifi.slash", Color.peekError, String(localized: "settings.activation.status.offlineExpired", defaultValue: "Needs to reconnect to verify", comment: "This device's activation status in Settings: the 30-day offline grace period has elapsed"))
            }
        case .deviceConflict:
            return ("exclamationmark.arrow.triangle.2.circlepath", Color.peekAmber, String(localized: "settings.activation.status.deviceConflict", defaultValue: "Not active on this Mac — the license seat is taken by another Mac", comment: "This device's activation status in Settings: this device's own activation attempt was rejected because the license is already active elsewhere"))
        case .revokedGracePeriod(_, let hardBlockDeadline):
            let dateText = hardBlockDeadline.formatted(date: .abbreviated, time: .shortened)
            return ("exclamationmark.triangle.fill", Color.peekAmber, String(localized: "settings.activation.status.revokedGrace", defaultValue: "Revoked — access continues until \(dateText)", comment: "This device's activation status in Settings: revoked but still within the 72-hour grace period"))
        case .blocked:
            return ("lock.fill", Color.peekError, String(localized: "settings.activation.status.blocked", defaultValue: "Revoked — new files are blocked", comment: "This device's activation status in Settings: revoked and past the 72-hour grace period"))
        }
    }

    private func deactivateThisDevice() {
        guard let key = licenseState.licenseKeyText else { return }
        isDeactivating = true
        deactivationFeedback = nil
        Task { @MainActor in
            let success = await licenseActivationService.deactivateThisDevice(licenseKeyText: key)
            isDeactivating = false
            deactivationFeedback = success
                ? String(localized: "settings.activation.deactivateSuccess", defaultValue: "This Mac's seat was freed. You can now activate a different license here, or the same one on another Mac.", comment: "Confirmation shown after successfully deactivating this Mac's seat on the currently activated license")
                : String(localized: "settings.activation.deactivateFailure", defaultValue: "Couldn't reach the activation server — check your connection and try again.", comment: "Shown after a failed attempt to deactivate this Mac's seat. Per this feature's non-negotiable rule, this must never be worded as if the license itself were invalid.")
        }
    }

    /// Only the last four alphanumeric characters, matching "solo le ultime
    /// quattro cifre" from the brief. Filters out hyphens/spaces before
    /// taking the suffix rather than the raw string's last four characters,
    /// so formatting punctuation in the stored text never counts as one of
    /// the four.
    private var licenseKeyLastFour: String {
        guard let key = licenseState.licenseKeyText else { return "" }
        let compact = key.filter { $0.isLetter || $0.isNumber }
        return String(compact.suffix(4))
    }

    private var maskedKey: String {
        let last4 = licenseKeyLastFour
        guard !last4.isEmpty else { return "••••" }
        return "•••• " + last4
    }

    /// What VoiceOver actually speaks for the masked-key row, in place of
    /// the raw "•••• A1B2" string — read character by character, the bullets
    /// alone are eight-plus seconds of "bullet bullet bullet bullet" before
    /// anything meaningful, per this feature's brief. A full sentence
    /// ("Key ending with A1B2") says the same thing the sighted mask
    /// communicates, in the time it takes to say it once.
    private var maskedKeyAccessibilityDescription: String {
        let last4 = licenseKeyLastFour
        guard !last4.isEmpty else {
            return String(localized: "settings.license.keyUnavailable", defaultValue: "License key unavailable", comment: "VoiceOver value for the masked-key row when no license key text is stored to mask.")
        }
        return String(localized: "settings.license.keyEndingWith", defaultValue: "Key ending with \(last4)", comment: "VoiceOver value for the masked-key row, spoken instead of the bullet characters, e.g. 'Key ending with A1B2'.")
    }

    // `monospacedValue` used to be `label == "Chiave"` — a comparison against
    // the Italian literal that broke the moment that literal became a
    // resolved (and locale-dependent) string via `String(localized:)`.
    // An explicit flag at the call site is what the string content itself
    // can no longer safely encode.
    //
    // `accessibilityValueOverride` lets a caller (the masked-key row) supply
    // a VoiceOver value distinct from what's drawn on screen, while
    // `.accessibilityElement(children: .ignore)` + explicit label/value
    // collapses the label+value pair into a single stop instead of two,
    // matching how a sighted user reads the row as one fact, not two.
    private func settingsRow(label: String, value: String, monospacedValue: Bool = false, accessibilityValueOverride: String? = nil) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: monospacedValue ? .monospaced : .default))
                .foregroundStyle(.white.opacity(0.9))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(accessibilityValueOverride ?? value))
    }

    // MARK: - Trial / exhausted

    private func unlicensedBody(statusLine: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "lock")
                    .foregroundStyle(.white.opacity(0.5))
                    .accessibilityHidden(true)
                Text("settings.license.none", comment: "Header shown when no license is active (trial or trial-exhausted state)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(statusLine)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))

            Button {
                showLicenseSheet = true
            } label: {
                Text("settings.license.enterButton", comment: "Button that opens the license-entry sheet from Settings (trial/trial-exhausted state)")
            }
                .buttonStyle(PeekFilledButtonStyle())
                .pointerCursor()
        }
    }
}
