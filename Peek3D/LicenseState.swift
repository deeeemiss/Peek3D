import Foundation
import CryptoKit

/// The single shared source of truth for trial/license status, resolved
/// from `LicenseStore` once at launch and kept in sync after every
/// successful file open. macOS 13 deployment target, so `ObservableObject`
/// + `@Published` rather than `@Observable` (macOS 14+).
///
/// Exactly one instance exists, created in `Peek3DApp.init()` — not one per
/// Scene/document window — so every window (Welcome and every open
/// document) agrees on the same trial count and the first frame ever drawn
/// already has a stable status instead of flashing from an initial default.
///
/// `@MainActor`-isolated, and NOT incidentally — see `recordSuccessfulOpen`.
/// Every call this app makes today happens to land on the main thread
/// already (SwiftUI view bodies, and `ModelLoader.load`'s completion which
/// is explicitly hopped to `DispatchQueue.main`), but that was a convention,
/// not something the compiler checked. Multiple document windows in the
/// same process is the whole reason this type exists as a single shared
/// instance rather than per-window state — without real isolation, two
/// windows finishing a load at close enough proximity could interleave
/// `cachedRecord = updated` writes and lose one of the two file hashes, or
/// worse, race on the same stored property (undefined behavior, not just a
/// stale read). `@MainActor` on the type makes that impossible by
/// construction: every method below runs on the same serial executor as
/// every other, so two calls from two windows are always fully ordered, one
/// completing before the next starts. It is also the right kind of
/// isolation for the pattern used here — a single actor-isolated `func`, no
/// `await` inside it, so no reentrancy — unlike a reentrant `actor`, which
/// would need an explicit queue if it ever awaited mid-read-modify-write.
@MainActor
final class LicenseState: ObservableObject {
    @Published private(set) var status: LicenseStatus

    private let store: LicenseStore
    private var cachedRecord: LicenseRecord
    #if DEBUG
    private var extraTrustedKeys: [Curve25519.Signing.PublicKey] = []
    #endif

    /// Additive hook for `LicenseActivationService` (a separate subsystem —
    /// see its own doc comment, this file has and needs no compile-time
    /// dependency on it) to learn synchronously, on the main actor, the
    /// instant a new license key text is accepted. A plain optional closure
    /// rather than Combine/NotificationCenter specifically so this stays a
    /// private, one-to-one wire between the two types instead of a
    /// broadcast anything in the process could listen to. `nil` by default —
    /// every existing behavior in this file is unaffected whether or not
    /// anything ever sets it.
    var onLicenseKeyTextApplied: ((String) -> Void)?

    /// True once `LicenseActivationService` has confirmed the 72-hour
    /// revocation grace period has elapsed (`RemoteActivationStatus.blocked`)
    /// — see `Peek3DApp.init()` for the wiring (a closure hook symmetrical to
    /// `onLicenseKeyTextApplied` above, just in the opposite direction, for
    /// the same reason: neither type needs a compile-time dependency on the
    /// other). Independent of `status`: a revoked-but-still-in-grace, or a
    /// revoked-and-now-blocked, device still has a perfectly valid LOCAL
    /// signature, so `status` stays `.licensed` throughout — this is a
    /// second, orthogonal gate `canOpen` consults, not a replacement for the
    /// first. `@Published` so `TrialGateView` can read it directly to choose
    /// between the trial paywall and a distinct "access blocked" screen,
    /// rather than both paths reading the same misleading trial-exhausted copy.
    @Published private(set) var isRemotelyBlocked: Bool = false

    /// Only setter — called from the closure hook above, never read/written
    /// anywhere else. A plain `Bool`, not the full `RemoteActivationStatus`
    /// enum: this file has no reason to know Polar's grace-period timestamps,
    /// device-conflict state, etc. — only the single yes/no fact that changes
    /// what `canOpen` returns.
    func setRemoteAccessBlocked(_ blocked: Bool) {
        isRemotelyBlocked = blocked
    }

    init(store: LicenseStore = LicenseStore()) {
        self.store = store
        let record = store.loadMergedRecord()
        self.cachedRecord = record
        #if DEBUG
        self.status = LicenseStatusResolver.resolve(record, extraTrustedKeys: extraTrustedKeys)
        #else
        self.status = LicenseStatusResolver.resolve(record)
        #endif
    }

    /// Gate for both integration points (see `Peek3DApp`'s `DocumentGroup`
    /// closure and `ContentView.load(url:)`): true if `url` can be opened
    /// right now — licensed, trial not yet exhausted, or a file this trial
    /// already counted before (reopening never re-blocks).
    ///
    /// `isRemotelyBlocked` is checked FIRST and unconditionally denies —
    /// deliberately with no "already-seen-file" exception like
    /// `.trialExhausted` gets below. That exception exists for the trial
    /// specifically because a distinct-file COUNT was what ran out, and a
    /// file already counted doesn't consume anything further; a remote
    /// revocation is a different kind of fact (the license itself, not a
    /// counter) and reopening a specific file doesn't make it less revoked.
    func canOpen(url: URL) -> Bool {
        if isRemotelyBlocked { return false }
        switch status {
        case .licensed, .trial:
            return true
        case .trialExhausted:
            return cachedRecord.seenFileHashes.contains(FileIdentityHasher.hash(for: url))
        }
    }

    /// Call ONLY after `ModelLoader` has returned a valid model for `url`.
    /// Never for a failed load, never speculatively before the load
    /// completes — see `LicenseStore.recordFileOpened` for why that
    /// ordering matters (it's what makes automatic window restoration and
    /// failed loads both no-ops on the counter).
    func recordSuccessfulOpen(of url: URL) {
        let updated = store.recordFileOpened(url, currentRecord: cachedRecord)
        cachedRecord = updated
        #if DEBUG
        status = LicenseStatusResolver.resolve(updated, extraTrustedKeys: extraTrustedKeys)
        #else
        status = LicenseStatusResolver.resolve(updated)
        #endif
    }

    /// Called by the license-entry sheet after `LicenseVerifier.verify` has
    /// already confirmed `text` decodes to `.valid` — never speculatively on
    /// unverified text, the sheet checks first and this only records the
    /// outcome. Persists through the existing `LicenseStore.saveLicenseKeyText`
    /// and re-resolves `status` immediately (same pattern as
    /// `recordSuccessfulOpen` above) so a document window stuck on
    /// `TrialGateView` can unblock itself on this very frame instead of
    /// waiting for the next file open.
    func applyLicenseKeyText(_ text: String) {
        let updated = store.saveLicenseKeyText(text)
        cachedRecord = updated
        #if DEBUG
        status = LicenseStatusResolver.resolve(updated, extraTrustedKeys: extraTrustedKeys)
        #else
        status = LicenseStatusResolver.resolve(updated)
        #endif
        onLicenseKeyTextApplied?(text)
    }

    /// Raw key text behind an active `.licensed` status, for UI that needs to
    /// display (a masked form of) it — see `SettingsView`. `nil` whenever
    /// `status` isn't `.licensed`, even if `cachedRecord` still holds some
    /// leftover key text (e.g. an invalid one from before a reset) — this
    /// never surfaces text the resolver itself didn't judge valid.
    var licenseKeyText: String? {
        guard case .licensed = status else { return nil }
        return cachedRecord.licenseKeyText
    }

    #if DEBUG
    /// Only path that ever populates `extraTrustedKeys` — see
    /// `LicenseDebugHarness`. Re-resolves `status` immediately so a forced
    /// "licensed" debug state takes effect without waiting for the next
    /// open.
    func debugSetExtraTrustedKeys(_ keys: [Curve25519.Signing.PublicKey]) {
        extraTrustedKeys = keys
        status = LicenseStatusResolver.resolve(cachedRecord, extraTrustedKeys: keys)
    }

    /// Debug-only convenience: builds a `LicenseState` whose persisted
    /// record (already forced into `store` by the caller) is trusted using
    /// `extraTrustedKeys` from the very first read, so a forced "licensed"
    /// state is correct on the first frame instead of only after a later
    /// `debugSetExtraTrustedKeys` call.
    convenience init(store: LicenseStore, extraTrustedKeys: [Curve25519.Signing.PublicKey]) {
        self.init(store: store)
        debugSetExtraTrustedKeys(extraTrustedKeys)
    }
    #endif
}
