import Foundation

/// The entire persisted state of the trial/license system, serialized as one
/// JSON blob and written as a single atomic item to both the Keychain and
/// its UserDefaults mirror — see `LicenseStore`.
struct LicenseRecord: Codable, Equatable {
    /// Trial limit: 10 *distinct* files. Reopening an already-counted file
    /// (its hash already in `seenFileHashes`) never consumes another slot.
    static let trialLimit = 10

    /// Truncated, salted SHA-256 hashes of every file counted against the
    /// trial so far (see `FileIdentityHasher`). Never the raw path — this
    /// blob lives in the Keychain, and a plaintext path list there would be
    /// a list of the user's folder structure sitting in their own
    /// credential store.
    var seenFileHashes: [String]

    /// Raw pasted/typed license key text, if one was ever entered. Verified
    /// fresh against `LicenseVerifier` on every read (see
    /// `LicenseStatusResolver`) — this struct never caches a validity
    /// verdict, only the bytes needed to recompute one.
    var licenseKeyText: String?

    static let empty = LicenseRecord(seenFileHashes: [], licenseKeyText: nil)
}
