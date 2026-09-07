import Foundation

/// This device's state in the single-machine activation system, as
/// `LicenseActivationService` understands it right now. Deliberately NOT
/// the same enum as `LicenseStatus` (trial/local-signature layer,
/// `LicenseState.swift`) — those two answer different questions
/// ("can this file be opened right now, based on what's on disk") vs.
/// ("what does Polar currently say about this Mac's seat"), and collapsing
/// them would force a network-shaped case onto a type that today never
/// needs one.
enum RemoteActivationStatus: Equatable {
    /// No license key entered yet, or a key was entered but activation
    /// hasn't been attempted (or has been explicitly freed via
    /// `LicenseActivationService.deactivateThisDevice`).
    case notActivated

    /// An `/activate` or `/validate` call is in flight right now.
    case checking

    /// Last known-good state: this device's activation is confirmed as of
    /// `lastVerifiedAt`. Whether that confirmation is "fresh enough" against
    /// the 30-day offline grace period is `LicenseActivationService`'s job,
    /// not this case's — see `.unreachable` below for when it stops being
    /// silently fine.
    case active(lastVerifiedAt: Date)

    /// The last attempt to reach the activation service failed at the
    /// transport level (no connection, timeout, unexpected response) — NOT
    /// a server-given answer. `withinOfflineGrace` mirrors the "up to 30
    /// days since the last successful check" window from `docs/FAQ.en.md`:
    /// `true` means the app should keep working exactly as if `.active`;
    /// `false` means the grace period has run out and the user should be
    /// asked to reconnect. Either way this case is never itself a
    /// downgrade of local access — see this file's owner,
    /// `LicenseActivationService`, for the non-negotiable rule this exists
    /// to protect.
    case unreachable(lastKnownGoodAt: Date?, withinOfflineGrace: Bool)

    /// This device tried to activate and Polar said the key's activation
    /// limit is already reached (or activation isn't supported for this
    /// key). This case is reachable ONLY from a device that just attempted
    /// `/activate` for itself — an already-active device validating its own
    /// existing activation can never land here, by construction (see
    /// `LicenseActivationService.reverifyIfNeeded`, which calls `/validate`
    /// with its OWN `activationId`, never `/activate`, once one exists).
    case deviceConflict

    /// The server said this device's own activation is
    /// `revoked`/`disabled`, or no longer exists, less than 72 hours ago
    /// (`hardBlockDeadline`). The app must show a banner but keep working
    /// until that deadline passes.
    case revokedGracePeriod(since: Date, hardBlockDeadline: Date)

    /// Same signal as `.revokedGracePeriod`, but more than 72 hours have
    /// now passed since it first appeared. This is the only case in which
    /// `LicenseActivationService` itself considers the device's remote
    /// activation invalid — wiring this to an actual file-open block is
    /// deferred, see `LicenseActivationService`'s top doc comment for why.
    case blocked(since: Date)
}
