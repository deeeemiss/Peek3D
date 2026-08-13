import Foundation

/// The three — and only three — renderable states of Peek3D's trial/license
/// system. No error case by design: `LicenseStatusResolver` resolves every
/// unreadable, corrupt, or ambiguous persisted state into one of these
/// before it ever reaches the UI layer. See `LicenseStore` for how.
enum LicenseStatus: Equatable {
    /// Still inside the trial. `opensRemaining` is always > 0 — once a new
    /// distinct file would bring it to 0 the state becomes
    /// `.trialExhausted` instead, never `.trial(opensRemaining: 0)`.
    case trial(opensRemaining: Int)

    /// The distinct-file trial has been used up. Opening a file whose hash
    /// isn't already in the persisted record is blocked; a previously
    /// counted file stays reachable forever.
    case trialExhausted

    /// A cryptographically valid license was found and verified. `holder`
    /// is the email address embedded in the signed license payload.
    /// Unconditional and permanent — no expiry is ever checked.
    case licensed(holder: String)
}
