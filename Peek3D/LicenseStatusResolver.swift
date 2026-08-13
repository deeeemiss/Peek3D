import Foundation
import CryptoKit
import PeekLicenseKit

/// Turns a persisted `LicenseRecord` into the three-case `LicenseStatus` the
/// UI is allowed to see. This is the ONLY place that calls
/// `LicenseVerifier.verify` — every other type in this layer moves
/// `LicenseRecord` values around without ever asking whether the license
/// text inside one is valid.
enum LicenseStatusResolver {
    /// `extraTrustedKeys` is always empty in a shipped build: nothing in
    /// this app ever populates it outside `LicenseDebugHarness`, which is
    /// wrapped entirely in `#if DEBUG`. Passing it here (rather than a
    /// separate DEBUG-only resolver function) keeps the one real
    /// verification call site identical between Debug and Release.
    static func resolve(_ record: LicenseRecord, extraTrustedKeys: [Curve25519.Signing.PublicKey] = []) -> LicenseStatus {
        if let text = record.licenseKeyText {
            let trusted = extraTrustedKeys.isEmpty
                ? LicenseVerifier.trustedPublicKeys
                : LicenseVerifier.trustedPublicKeys + extraTrustedKeys
            if case .valid(let email, _, _) = LicenseVerifier.verify(text, trustedKeys: trusted) {
                return .licensed(holder: email)
            }
            // .validFutureSchema / .validWrongProduct / .signatureInvalid /
            // .malformed all fall through to the trial calculation below —
            // "fail-closed" here means never granting `.licensed`, not
            // denying access outright. A demonstrably-invalid or
            // unrecognized license text doesn't retroactively erase a
            // trial the user has already been using.
        }

        let used = record.seenFileHashes.count
        let remaining = LicenseRecord.trialLimit - used
        return remaining > 0 ? .trial(opensRemaining: remaining) : .trialExhausted
    }
}
