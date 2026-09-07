import Foundation

/// This device's persisted state in the single-machine activation system —
/// separate from `LicenseRecord` (the trial/signature layer) on purpose:
/// losing THIS record is graceful (worst case, `LicenseActivationService`
/// re-activates from scratch on the next launch) where losing
/// `LicenseRecord` would be a real problem (an unverifiable license or a
/// reset trial counter). That difference in blast radius is why this gets a
/// single Keychain item with no UserDefaults-mirror/merge complexity, unlike
/// `LicenseStore`'s dual-store design.
struct DeviceActivationRecord: Codable, Equatable, Sendable {
    /// Polar's activation ID for this device, once `/activate` has
    /// succeeded. `nil` means "never successfully activated yet" — which
    /// `LicenseActivationService.reverifyIfNeeded` reads as "there's a
    /// queued activation attempt to retry", not as an error.
    var activationId: String?

    /// The exact license key TEXT (the `PK3D-...` string, not the embedded
    /// Polar key) that `activationId` above belongs to. Lets the service
    /// detect "the user just entered a DIFFERENT license" — e.g. after
    /// buying a fresh one — and correctly start a new activation instead of
    /// treating the stale `activationId` as still valid for a key it was
    /// never actually granted against.
    var activatedForLicenseKeyText: String?

    /// Last time `/validate` or `/activate` returned an unambiguous
    /// success. This is the ONLY clock `reverifyIfNeeded`'s 24-hour gate and
    /// the 30-day offline grace period (see `docs/FAQ.en.md`) read — never
    /// the last ATTEMPT, so a run of network failures doesn't reset either
    /// window early.
    var lastSuccessfulVerificationAt: Date?

    /// First time the server said `revoked`/`disabled`/"key not found" for
    /// this device's own activation. `nil` means no revocation is currently
    /// in effect. Set once and left alone until a later success clears it —
    /// see `LicenseActivationService.handleRevocationSignal` for why it must
    /// never be overwritten on a SECOND consecutive revoked response (that
    /// would keep pushing the 72-hour grace deadline forward forever and the
    /// grace period would never actually end).
    var revokedSince: Date?

    /// Successful (re)activations recorded as genuine transfer events (i.e.
    /// NOT the very first activation ever for a license, and NOT a routine
    /// 24-hour reverify) — the informational counter behind "a small number
    /// of free reactivations" in `docs/FAQ.en.md`. Pruned to the trailing 90
    /// days on every read; see `LicenseActivationService.remainingFreeTransfers`.
    ///
    /// This is bookkeeping for a future UI, NOT enforcement — Polar's own
    /// `limit_activations` on the license key is the actual, server-side
    /// enforcement point. See `LicenseActivationService`'s doc comment for
    /// why this counter can't be made authoritative from the client alone.
    var transferTimestamps: [Date]

    static let empty = DeviceActivationRecord(
        activationId: nil,
        activatedForLicenseKeyText: nil,
        lastSuccessfulVerificationAt: nil,
        revokedSince: nil,
        transferTimestamps: []
    )
}
