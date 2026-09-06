import SwiftUI
import AppKit

/// The document window's entire content once the distinct-file trial is
/// exhausted and the requested file was never opened before — Peek3D's
/// paywall moment. Lives *instead of* `ContentView`, not as an overlay on
/// top of it: the overlay-pinning rules in this project's CLAUDE.md (about
/// reserving space between concurrently-visible panels) don't apply here,
/// because nothing else is on screen to collide with.
///
/// This view also owns the gate check itself (`licenseState.canOpen(url:)`),
/// not just the "what to show when blocked" body. That's deliberate: this
/// struct declares `@EnvironmentObject private var licenseState`, so SwiftUI
/// re-invokes ITS body whenever `licenseState.status` changes. The
/// `DocumentGroup(viewing:)` closure in `Peek3DApp.swift` that builds this
/// view only runs once per window and is not guaranteed to re-run on a later
/// license activation. Putting the branch here — swap to `ContentView(url:)`
/// the instant `canOpen` flips to true — is what makes "activate a license
/// from this exact screen and the file you were blocked on just opens"
/// actually work, instead of leaving the window stuck until closed and
/// reopened.
struct TrialGateView: View {
    let url: URL

    @EnvironmentObject private var licenseState: LicenseState
    @EnvironmentObject private var licenseActivationService: LicenseActivationService
    @State private var showLicenseSheet = false

    /// TODO(release): point at the real purchase page once one exists —
    /// nothing else in this codebase defines a product URL yet, so this is
    /// this feature's own placeholder, not a value carried over from
    /// elsewhere.
    /// Checkout ospitato da Polar ("App e README" nei Checkout Links). Il
    /// prodotto è *private*: non esiste una vetrina pubblica, si vende solo
    /// da questo link.
    private static let purchaseURL = URL(string: "https://buy.polar.sh/polar_cl_eAHc1m1lpTGYyUnVgE9TomrotIHM76hUXRm7e1g2VRP")!

    var body: some View {
        Group {
            if licenseState.canOpen(url: url) {
                ContentView(url: url)
            } else if licenseState.isRemotelyBlocked {
                // Distinct from `paywall` below on purpose: that screen's
                // copy ("you've used all your trial opens", "buy a
                // license") is actively wrong for someone who already owns
                // one — showing it here would tell a paying customer whose
                // activation was revoked (rightly or wrongly) that they
                // never bought anything at all.
                remoteBlockedScreen
            } else {
                paywall
            }
        }
    }

    private var paywall: some View {
        ZStack {
            Color(white: 0.04).ignoresSafeArea()
            VStack(spacing: 32) {
                whatHappened
                pricing
                actions
                Text("trialGate.refundNote", comment: "Small print at the bottom of the paywall screen")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(48)
            .frame(maxWidth: 460)
        }
        .sheet(isPresented: $showLicenseSheet) {
            LicenseEntrySheet()
        }
    }

    // MARK: - 1. What happened

    private var whatHappened: some View {
        VStack(spacing: 14) {
            // A neutral lock, not the accent blue used for the drop-zone
            // invitation elsewhere in the app: this screen is a boundary,
            // not an invitation.
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
                .accessibilityHidden(true)
            Text(TrialCopy.exhaustedShort)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
            // The reassurance is the most important sentence on this screen:
            // the file the user just tried to open still exists, untouched,
            // and will open the moment a license is activated (see this
            // view's own body — the `canOpen` re-check makes that literal).
            Text(
                String(
                    localized: "trialGate.reassurance",
                    defaultValue: "You've used all your trial opens (\(LicenseRecord.trialLimit)/\(LicenseRecord.trialLimit)). The file you tried to open hasn't been lost — it's still there, and you'll be able to reopen it as soon as you unlock Peek3D.",
                    comment: "TrialGateView paywall reassurance. Both %lld are the same trial-limit constant, shown as an N/N ratio."
                )
            )
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 2. What it costs

    private var pricing: some View {
        VStack(spacing: 4) {
            // Fixed marketing copy, not a computed price — the product sells
            // in euro in both locales (see this task's brief), so this stays
            // a literal string pair rather than routing through
            // NumberFormatter/`Decimal.FormatStyle.Currency` for a value
            // that never actually varies by locale.
            Text("trialGate.price", comment: "One-time price line on the paywall screen, e.g. '€19.99 · one-time'")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
            Text("trialGate.updatesIncluded", comment: "Small print under the price, reassuring updates aren't a separate purchase")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
        // Two `Text` siblings read as one sentence to a sighted user
        // ("€19.99 · one-time, updates included") — combine them into one
        // VoiceOver stop instead of two so the pause between price and
        // reassurance doesn't read as two unrelated facts.
        .accessibilityElement(children: .combine)
    }

    // MARK: - 3. Two actions, never ambiguous about which one applies

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                NSWorkspace.shared.open(Self.purchaseURL)
            } label: {
                Text("trialGate.buyButton", comment: "Primary CTA on the paywall screen, opens the purchase page")
            }
            .buttonStyle(PeekFilledButtonStyle(fillWidth: true))
            .keyboardShortcut(.defaultAction)
            .pointerCursor()

            Button {
                showLicenseSheet = true
            } label: {
                Text("trialGate.haveLicenseButton", comment: "Secondary CTA on the paywall screen, opens the license-entry sheet")
            }
            .buttonStyle(PeekGhostButtonStyle(fillWidth: true))
            .pointerCursor()
        }
        .frame(maxWidth: 320)
    }

    // MARK: - Remote block (revoked, 72h+ past grace)

    /// Shown instead of `paywall` once `licenseState.isRemotelyBlocked` is
    /// true — see `body`'s own comment for why the two can't share copy.
    /// The local signature is still perfectly valid here (`status` stays
    /// `.licensed` throughout a revocation — see `LicenseState.isRemotelyBlocked`'s
    /// doc comment), so this screen never suggests re-entering the same key
    /// would help; the two actions it offers are "try the activation check
    /// again" (in case the revocation was a mistake already fixed
    /// server-side) and "enter a different key" (in case it wasn't).
    private var remoteBlockedScreen: some View {
        ZStack {
            Color(white: 0.04).ignoresSafeArea()
            VStack(spacing: 32) {
                VStack(spacing: 14) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.white.opacity(0.5))
                        .accessibilityHidden(true)
                    Text("trialGate.remoteBlocked.title", comment: "Headline on the screen shown once a revoked license's 72-hour grace period has ended")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("trialGate.remoteBlocked.body", comment: "Explanation under the remote-block headline — the local license signature is still valid, only the remote activation check failed")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 10) {
                    Button {
                        retryActivation()
                    } label: {
                        Text("activation.banner.retry", comment: "Button on the device-conflict banner, retries activation for this Mac")
                    }
                    .buttonStyle(PeekFilledButtonStyle(fillWidth: true))
                    .keyboardShortcut(.defaultAction)
                    .pointerCursor()

                    Button {
                        showLicenseSheet = true
                    } label: {
                        Text("trialGate.remoteBlocked.enterDifferentLicense", comment: "Secondary CTA on the remote-block screen, opens the license-entry sheet to enter a different key")
                    }
                    .buttonStyle(PeekGhostButtonStyle(fillWidth: true))
                    .pointerCursor()
                }
                .frame(maxWidth: 320)
            }
            .padding(48)
            .frame(maxWidth: 460)
        }
        .sheet(isPresented: $showLicenseSheet) {
            LicenseEntrySheet()
        }
    }

    private func retryActivation() {
        guard let text = licenseState.licenseKeyText else { return }
        licenseActivationService.retryActivation(licenseKeyText: text)
    }
}
