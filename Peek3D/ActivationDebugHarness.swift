#if DEBUG
import Foundation

/// Debug-only hook for forcing `LicenseActivationService`'s PERSISTED state
/// (`DeviceActivationRecord`, in the Keychain — see `LicenseDebugHarness` for
/// the equivalent on the LOCAL trial/signature layer) without waiting 72 real
/// hours or 30 real days for a transition to occur naturally. Added
/// specifically to make manual verification of the single-machine-activation
/// UI (the revocation banner, `TrialGateView`'s remote-block screen,
/// `SettingsView`'s activation section) possible in one launch.
///
/// Same pattern, same reasoning as `LicenseDebugHarness`: reads an env var
/// once at launch, called from `Peek3DApp.init()` BEFORE
/// `LicenseActivationService()` is constructed, so its `init()` (via
/// `DeviceActivationKeychainStore.load()`) picks up the seeded record
/// immediately on the very first frame. Structurally absent from Release
/// builds — this whole file is `#if DEBUG`.
enum ActivationDebugHarness {
    /// Recognised values for `PEEK3D_ACTIVATION_DEBUG_STATE`:
    /// - "reset"          — wipes the activation record (fresh install)
    /// - "active"         — a confirmed activation, verified just now
    /// - "revokedGrace"   — revoked 1 hour ago (well within the 72h grace)
    /// - "blocked"        — revoked 74 hours ago (past the 72h grace)
    /// - "offlineExpired" — last verified 31 days ago, WITH a stored
    ///                      activationId, no revocation — combine with a
    ///                      down/unreachable `PEEK3D_POLAR_API_BASE_OVERRIDE`
    ///                      so a real launch-time reverify attempt lands on
    ///                      `.unreachable(withinOfflineGrace: false)`.
    ///
    /// Does nothing (no-op) when the variable is unset or unrecognized —
    /// same contract as `LicenseDebugHarness.makeState()`.
    static func apply() {
        guard let raw = ProcessInfo.processInfo.environment["PEEK3D_ACTIVATION_DEBUG_STATE"] else { return }

        switch raw {
        case "reset":
            DeviceActivationKeychainStore.debugDeleteAll()

        case "active":
            DeviceActivationKeychainStore.save(
                DeviceActivationRecord(
                    activationId: "debug-activation-id",
                    activatedForLicenseKeyText: LicenseDebugHarness.testLicenseString,
                    lastSuccessfulVerificationAt: Date(),
                    revokedSince: nil,
                    transferTimestamps: []
                )
            )

        case "revokedGrace":
            // `lastSuccessfulVerificationAt` is deliberately > 24h ago, not a
            // couple hours like `revokedSince` — in the REAL flow, the
            // moment a revocation is first discovered is always the moment
            // an already->24h-stale `lastSuccessfulVerificationAt` finally
            // clears `reverifyIfNeeded`'s 24h gate and a live `validate()`
            // call reaches the server (that gate is what allowed the
            // discovery to happen in the first place). Seeding
            // `lastSuccessfulVerificationAt` more recently than 24h ago —
            // an earlier version of this fixture did exactly that — would
            // make `reverifyIfNeeded`'s OWN 24h gate short-circuit to
            // `.active` on the very next launch, silently erasing the
            // `.revokedGracePeriod` this state exists to demonstrate, before
            // any UI ever got a chance to render it.
            DeviceActivationKeychainStore.save(
                DeviceActivationRecord(
                    activationId: "debug-activation-id",
                    activatedForLicenseKeyText: LicenseDebugHarness.testLicenseString,
                    lastSuccessfulVerificationAt: Date().addingTimeInterval(-25 * 3600),
                    revokedSince: Date().addingTimeInterval(-1 * 3600),
                    transferTimestamps: []
                )
            )

        case "blocked":
            DeviceActivationKeychainStore.save(
                DeviceActivationRecord(
                    activationId: "debug-activation-id",
                    activatedForLicenseKeyText: LicenseDebugHarness.testLicenseString,
                    lastSuccessfulVerificationAt: Date().addingTimeInterval(-74 * 3600),
                    revokedSince: Date().addingTimeInterval(-74 * 3600),
                    transferTimestamps: []
                )
            )

        case "offlineExpired":
            DeviceActivationKeychainStore.save(
                DeviceActivationRecord(
                    activationId: "debug-activation-id",
                    activatedForLicenseKeyText: LicenseDebugHarness.testLicenseString,
                    lastSuccessfulVerificationAt: Date().addingTimeInterval(-31 * 24 * 3600),
                    revokedSince: nil,
                    transferTimestamps: []
                )
            )

        default:
            break
        }
    }
}
#endif
