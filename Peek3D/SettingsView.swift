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
    @State private var showLicenseSheet = false

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
    }

    // MARK: - Licensed

    private func licensedBody(holder: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
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
                    monospacedValue: true
                )
            }

            Button {
                showLicenseSheet = true
            } label: {
                Text("settings.license.changeButton", comment: "Button that reopens the license-entry sheet to replace the current license")
            }
                .buttonStyle(PeekGhostButtonStyle())
                .pointerCursor()
        }
    }

    /// Only the last four alphanumeric characters, matching "solo le ultime
    /// quattro cifre" from the brief. Filters out hyphens/spaces before
    /// taking the suffix rather than the raw string's last four characters,
    /// so formatting punctuation in the stored text never counts as one of
    /// the four.
    private var maskedKey: String {
        guard let key = licenseState.licenseKeyText else { return "••••" }
        let compact = key.filter { $0.isLetter || $0.isNumber }
        return "•••• " + compact.suffix(4)
    }

    // `monospacedValue` used to be `label == "Chiave"` — a comparison against
    // the Italian literal that broke the moment that literal became a
    // resolved (and locale-dependent) string via `String(localized:)`.
    // An explicit flag at the call site is what the string content itself
    // can no longer safely encode.
    private func settingsRow(label: String, value: String, monospacedValue: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: monospacedValue ? .monospaced : .default))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    // MARK: - Trial / exhausted

    private func unlicensedBody(statusLine: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "lock")
                    .foregroundStyle(.white.opacity(0.5))
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
