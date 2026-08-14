import Foundation
import CryptoKit
import PeekLicenseKit

/// Single-machine enforcement — the layer that turns "a cryptographically
/// valid license key" (already handled entirely offline by `LicenseState`/
/// `LicenseVerifier`) into "a license activated on AT MOST ONE Mac at a
/// time", by actually talking to Polar. Everything in this file is
/// additive: it has no compile-time dependency on `LicenseState` (see
/// `LicenseState.onLicenseKeyTextApplied` for the one-line closure hook
/// that connects them, wired up in `Peek3DApp.init()`) and touches none of
/// the UI files that present trial/license state to the user.
///
/// ## The one non-negotiable rule
///
/// **"Server irraggiungibile" must never become "licenza non valida".** A
/// dead/unreachable backend can never itself be the reason this app starts
/// denying access — if it could, taking the license server offline would be
/// a way to lock out every paying customer at once, which is exactly
/// backwards from what a license server is for. Concretely: every method
/// below that hits the network has exactly one path that downgrades access
/// (`handleRevocationSignal`, reached only from an explicit `revoked`/
/// `disabled`/"not found" answer that the server actually gave), and every
/// other failure path — timeout, no connection, decode failure, an
/// undocumented status code — leaves `remoteStatus` at `.unreachable` and
/// leaves the persisted `DeviceActivationRecord` completely untouched.
///
/// ## What's implemented here vs. deferred
///
/// This type implements the full state machine (activation, the 24-hour-
/// gated background reverify, the 72-hour revocation grace, the 30-day
/// offline grace, device-conflict detection, and the deactivate/retry
/// building blocks for a self-service Mac-to-Mac transfer) and exposes it
/// via `@Published remoteStatus`. It does NOT wire `.blocked` into
/// `LicenseState.canOpen` or build any UI for `.deviceConflict`/transfer —
/// those touch `TrialGateView.swift`/`LicenseEntrySheet.swift`/
/// `SettingsView.swift`, explicitly out of scope for this pass (see the
/// task brief: "il collegamento visivo del flusso self-service sarà un
/// task successivo").
///
/// ## The "4 free transfers per 90 days" allowance
///
/// `remainingFreeTransfers` below is informational bookkeeping on THIS
/// device, not enforcement — Polar's customer-portal license-key API has no
/// concept of a rolling time window, only a flat `limit_activations` cap
/// per key (see `PolarLicenseAPIClient`'s doc comment for the exact
/// endpoints this was verified against). The actual seat limit is enforced
/// server-side, by Polar, when `/activate` is called; this counter exists
/// so a future UI can tell a user "you have N free transfers left" without
/// needing a new server capability that doesn't exist yet.
@MainActor
final class LicenseActivationService: ObservableObject {
    /// `didSet` (not just `@Published`) so every assignment site below —
    /// `activate`, `validate`, `handleRevocationSignal`, `deactivateThisDevice`,
    /// `reverifyIfNeeded`'s early return — funnels through ONE place that
    /// fires `onBlockedStateChanged`, instead of every call site remembering
    /// to notify separately. Fires only on a genuine transition into/out of
    /// `.blocked`, not on every `remoteStatus` change (e.g. `.checking` →
    /// `.active` is silent here).
    @Published private(set) var remoteStatus: RemoteActivationStatus {
        didSet {
            let isBlockedNow = isBlocked
            if isBlockedNow != Self.isBlocked(oldValue) {
                onBlockedStateChanged?(isBlockedNow)
            }
        }
    }

    /// Closure hook symmetrical to `LicenseState.onLicenseKeyTextApplied`,
    /// just in the opposite direction — wired once in `Peek3DApp.init()`.
    /// This type has no compile-time dependency on `LicenseState` (see this
    /// file's own top doc comment), so a plain closure taking a `Bool`
    /// rather than a stored reference to it. `nil` by default; every
    /// existing behavior here is unaffected whether or not anything sets it.
    ///
    /// IMPORTANT for the caller: `didSet` above only fires on a CHANGE after
    /// this closure is assigned — it does NOT retroactively fire for
    /// whatever `remoteStatus` already was at construction time (e.g. a
    /// persisted `.blocked` record from a previous launch). `Peek3DApp.init()`
    /// does one explicit `setRemoteAccessBlocked(resolvedActivationService.isBlocked)`
    /// call right after wiring this, specifically to cover that case.
    var onBlockedStateChanged: ((Bool) -> Void)?

    /// Whether the 72-hour revocation grace period has elapsed — the exact
    /// condition `LicenseState.isRemotelyBlocked` mirrors. Exposed as a
    /// plain computed property (not just via the closure) so `Peek3DApp.init()`
    /// can read the CURRENT value once, synchronously, for the initial-sync
    /// call described above.
    var isBlocked: Bool { Self.isBlocked(remoteStatus) }

    private static func isBlocked(_ status: RemoteActivationStatus) -> Bool {
        if case .blocked = status { return true }
        return false
    }

    private let apiClient: PolarLicenseAPIClient
    private let organizationId: String

    #if DEBUG
    /// Same purpose and pattern as `LicenseState.extraTrustedKeys`: the
    /// production `LicenseVerifier.trustedPublicKeys` is empty until a real
    /// signing key is baked in (see that constant's own doc comment), which
    /// would make `extractPolarKey` unable to verify ANY license text —
    /// including the fixed test license `LicenseActivationSelfTest` needs to
    /// drive real activation calls. Set once by that self-test before it
    /// runs; `nil` effect on every other code path, and structurally absent
    /// from Release builds.
    private var extraTrustedKeys: [Curve25519.Signing.PublicKey] = []

    func debugSetExtraTrustedKeys(_ keys: [Curve25519.Signing.PublicKey]) {
        extraTrustedKeys = keys
    }
    #endif

    private static let reverifyInterval: TimeInterval = 24 * 3600
    private static let revocationGracePeriod: TimeInterval = 72 * 3600
    private static let offlineGracePeriod: TimeInterval = 30 * 24 * 3600
    private static let freeTransfersPer90Days = 4
    private static let transferWindow: TimeInterval = 90 * 24 * 3600

    init(
        apiClient: PolarLicenseAPIClient = HTTPPolarLicenseAPIClient(),
        organizationId: String = PolarLicenseConfig.organizationId
    ) {
        self.apiClient = apiClient
        self.organizationId = organizationId
        self.remoteStatus = Self.initialStatus(from: DeviceActivationKeychainStore.load())
    }

    // MARK: - Entry points (see Peek3DApp.init() for exactly how these are wired)

    /// Call once, right when a license key is newly accepted — see
    /// `LicenseState.onLicenseKeyTextApplied`. ALWAYS attempts activation in
    /// the background, with no 24-hour gate: entering a key is a one-time
    /// user action, not a periodic check. Never blocks the caller — the
    /// local, offline unlock (already granted by the verified signature
    /// before this is ever called) is not this method's concern.
    func licenseKeyWasApplied(_ licenseKeyText: String) {
        Task { [weak self] in
            await self?.activateIfNeeded(licenseKeyText: licenseKeyText)
        }
    }

    /// Call once at launch, after `LicenseState` has already resolved
    /// synchronously — see `Peek3DApp.init()`. Schedules a background
    /// `Task` and returns immediately; the caller never awaits this.
    /// Internally a no-op unless more than 24 hours have passed since the
    /// last SUCCESSFUL check (never gated on the last attempt — see
    /// `reverifyIfNeeded`'s doc comment for why that distinction matters).
    func launchTimeCheck(licenseKeyText: String?) {
        guard let licenseKeyText else { return }
        Task { [weak self] in
            await self?.reverifyIfNeeded(licenseKeyText: licenseKeyText)
        }
    }

    // MARK: - Self-service building blocks (no UI wired to these yet)

    /// Frees this Mac's seat server-side — the mechanism behind "free up
    /// its seat yourself before activating on the new one"
    /// (`docs/FAQ.en.md`). Meant to be called from the OLD Mac, while it
    /// still holds a recorded `activationId`, before the license is ever
    /// entered on a new one.
    @discardableResult
    func deactivateThisDevice(licenseKeyText: String) async -> Bool {
        guard let polarKey = extractPolarKey(from: licenseKeyText) else { return false }
        var record = DeviceActivationKeychainStore.load()
        guard let activationId = record.activationId else { return false }

        let outcome = await apiClient.deactivate(key: polarKey, organizationId: organizationId, activationId: activationId)
        switch outcome {
        case .success, .notFound:
            // .notFound here means Polar already has no record of this
            // activation — the seat is free either way, so this is treated
            // as success rather than surfaced as a failure to the caller.
            record.activationId = nil
            record.activatedForLicenseKeyText = nil
            DeviceActivationKeychainStore.save(record)
            remoteStatus = .notActivated
            return true
        case .notPermitted, .validationError, .transportFailure:
            return false
        }
    }

    /// Direct user-initiated retry — the building block behind a future
    /// "Try again" / "Transfer license to this Mac" action after
    /// `.deviceConflict`, once the user has freed the old seat (e.g. via
    /// `deactivateThisDevice` run on their other Mac). Unlike
    /// `reverifyIfNeeded`, this always attempts, with no 24-hour gate — the
    /// user just asked for it explicitly.
    func retryActivation(licenseKeyText: String) {
        Task { [weak self] in
            await self?.activate(polarKey: nil, licenseKeyText: licenseKeyText, isTransfer: true)
        }
    }

    /// Informational only — see this type's top doc comment, "The '4 free
    /// transfers per 90 days' allowance", for why this can't be
    /// enforcement.
    var remainingFreeTransfers: Int {
        let record = DeviceActivationKeychainStore.load()
        return max(0, Self.freeTransfersPer90Days - Self.pruned(record.transferTimestamps).count)
    }

    /// Whether this device currently has anything for `deactivateThisDevice`
    /// to free — i.e. a stored `activationId` — regardless of what
    /// `remoteStatus`'s current case happens to be (even `.unreachable`/
    /// `.checking` can have one; `.deviceConflict` never does, since that
    /// case is only reachable from a device that never successfully
    /// activated in the first place). Read fresh from the Keychain each
    /// call, same pattern as `remainingFreeTransfers` just above, rather
    /// than cached — `SettingsView` uses this to decide whether "Disattiva
    /// questo Mac" has anything to do before showing it.
    var hasActivationToFree: Bool {
        DeviceActivationKeychainStore.load().activationId != nil
    }

    // MARK: - Activation

    /// Not `private` — deliberately module-internal so
    /// `LicenseActivationSelfTest` (DEBUG-only, same target — this project
    /// has no separate test target to grant special access to, see
    /// `LicenseSelfTest`'s doc comment for why) can `await` this directly
    /// instead of only being able to fire-and-forget it through
    /// `licenseKeyWasApplied`. Every other caller should use
    /// `licenseKeyWasApplied`/`launchTimeCheck` above, never this or
    /// `reverifyIfNeeded` directly.
    func activateIfNeeded(licenseKeyText: String) async {
        let record = DeviceActivationKeychainStore.load()
        if record.activationId != nil, record.activatedForLicenseKeyText == licenseKeyText {
            // Already activated for this EXACT key text — re-entering the
            // same key (e.g. reopening Settings ▸ Cambia licenza… without
            // changing anything) must not spam a fresh /activate call.
            remoteStatus = .active(lastVerifiedAt: record.lastSuccessfulVerificationAt ?? Date())
            return
        }
        // A different (or first-ever) key text: `record.activationId != nil`
        // here means this device previously activated a DIFFERENT license
        // and is now switching — recorded as a transfer event.
        await activate(polarKey: nil, licenseKeyText: licenseKeyText, isTransfer: record.activationId != nil)
    }

    /// Shared by `activateIfNeeded`, `reverifyIfNeeded` (when there's a
    /// queued activation to retry), and `retryActivation`. `polarKey` is an
    /// optional pre-extracted value purely to avoid re-verifying the
    /// signature at call sites that already have it; pass `nil` and this
    /// re-derives it from `licenseKeyText` itself.
    private func activate(polarKey: String?, licenseKeyText: String, isTransfer: Bool) async {
        guard let polarKey = polarKey ?? extractPolarKey(from: licenseKeyText) else { return }

        remoteStatus = .checking
        let label = MachineIdentifier.current() ?? "unknown-device"
        let outcome = await apiClient.activate(key: polarKey, organizationId: organizationId, label: label)
        let now = Date()
        var record = DeviceActivationKeychainStore.load()

        switch outcome {
        case .success(let activation):
            record.activationId = activation.activationId
            record.activatedForLicenseKeyText = licenseKeyText
            record.lastSuccessfulVerificationAt = now
            record.revokedSince = nil
            if isTransfer {
                record.transferTimestamps = Self.pruned(record.transferTimestamps + [now])
            }
            DeviceActivationKeychainStore.save(record)
            remoteStatus = .active(lastVerifiedAt: now)

        case .notPermitted:
            // Activation limit reached elsewhere (or unsupported for this
            // key). This device, specifically, never becomes active — the
            // local, signature-based unlock is untouched either way.
            remoteStatus = .deviceConflict

        case .notFound, .validationError, .transportFailure:
            // A definitive-but-unexpected server answer, or no answer at
            // all. NEVER treated as "this license is invalid" — only an
            // explicit revoked/disabled/not-found answer from /validate
            // does that (see handleRevocationSignal). Falls back to the
            // same "try again later" posture as an outright network
            // failure; the persisted record is left untouched.
            remoteStatus = .unreachable(
                lastKnownGoodAt: record.lastSuccessfulVerificationAt,
                withinOfflineGrace: Self.withinOfflineGrace(record, now: now)
            )
        }
    }

    // MARK: - Reverify

    /// Gated on the 24-hour window since the last SUCCESS — never the last
    /// attempt. That distinction is deliberate: if the server has been down
    /// for a week, this app should keep retrying on every subsequent
    /// launch (that's the "resta in coda e riprova" requirement), not go
    /// silent because a recent FAILED attempt reset a naive "last checked"
    /// clock.
    /// Not `private` — see `activateIfNeeded`'s doc comment just above for
    /// why.
    func reverifyIfNeeded(licenseKeyText: String) async {
        guard let polarKey = extractPolarKey(from: licenseKeyText) else { return }
        let record = DeviceActivationKeychainStore.load()
        let now = Date()

        if let lastSuccess = record.lastSuccessfulVerificationAt,
           now.timeIntervalSince(lastSuccess) < Self.reverifyInterval {
            remoteStatus = .active(lastVerifiedAt: lastSuccess)
            return
        }

        if let activationId = record.activationId, record.activatedForLicenseKeyText == licenseKeyText {
            await validate(polarKey: polarKey, activationId: activationId)
        } else {
            // No confirmed activation for this key yet (a previous attempt
            // never completed, e.g. because the network was down at the
            // time it was entered) — this IS the queued retry.
            await activate(polarKey: polarKey, licenseKeyText: licenseKeyText, isTransfer: false)
        }
    }

    private func validate(polarKey: String, activationId: String) async {
        remoteStatus = .checking
        let outcome = await apiClient.validate(key: polarKey, organizationId: organizationId, activationId: activationId)
        let now = Date()
        var record = DeviceActivationKeychainStore.load()

        switch outcome {
        case .success(let validated):
            switch validated.status {
            case .granted:
                record.lastSuccessfulVerificationAt = now
                record.revokedSince = nil
                DeviceActivationKeychainStore.save(record)
                remoteStatus = .active(lastVerifiedAt: now)
            case .revoked, .disabled:
                handleRevocationSignal(&record, now: now)
            }

        case .notFound:
            // Polar has no record of this activation/key anymore — a
            // definitive "this seat no longer exists" answer, handled
            // identically to an explicit revoke.
            handleRevocationSignal(&record, now: now)

        case .notPermitted, .validationError:
            // Not a documented outcome for /validate — fail safe rather
            // than guess at a meaning Polar's spec doesn't define.
            remoteStatus = .unreachable(
                lastKnownGoodAt: record.lastSuccessfulVerificationAt,
                withinOfflineGrace: Self.withinOfflineGrace(record, now: now)
            )

        case .transportFailure:
            // THE non-negotiable rule in practice: no write to the
            // persisted record, no downgrade beyond "couldn't check".
            remoteStatus = .unreachable(
                lastKnownGoodAt: record.lastSuccessfulVerificationAt,
                withinOfflineGrace: Self.withinOfflineGrace(record, now: now)
            )
        }
    }

    /// `record.revokedSince` is set ONCE and never overwritten by a later
    /// revoked/disabled/not-found answer — only cleared by a subsequent
    /// `granted` response. Overwriting it on every consecutive bad answer
    /// would keep pushing the 72-hour deadline forward on every reverify
    /// cycle, and the grace period would never actually end.
    private func handleRevocationSignal(_ record: inout DeviceActivationRecord, now: Date) {
        if record.revokedSince == nil {
            record.revokedSince = now
        }
        DeviceActivationKeychainStore.save(record)

        let since = record.revokedSince ?? now
        let deadline = since.addingTimeInterval(Self.revocationGracePeriod)
        remoteStatus = now >= deadline
            ? .blocked(since: since)
            : .revokedGracePeriod(since: since, hardBlockDeadline: deadline)
    }

    // MARK: - Helpers

    private func extractPolarKey(from licenseKeyText: String) -> String? {
        #if DEBUG
        let trusted = extraTrustedKeys.isEmpty
            ? LicenseVerifier.trustedPublicKeys
            : LicenseVerifier.trustedPublicKeys + extraTrustedKeys
        #else
        let trusted = LicenseVerifier.trustedPublicKeys
        #endif
        guard case .valid(_, _, let polarKey) = LicenseVerifier.verify(licenseKeyText, trustedKeys: trusted) else { return nil }
        return polarKey
    }

    private static func withinOfflineGrace(_ record: DeviceActivationRecord, now: Date) -> Bool {
        // Never verified yet at all: the local, signature-based unlock
        // already governs access, so there is nothing here to "degrade" —
        // treated as within grace rather than surfacing a premature warning
        // before this device has ever even attempted a first check-in.
        guard let last = record.lastSuccessfulVerificationAt else { return true }
        return now.timeIntervalSince(last) < offlineGracePeriod
    }

    private static func pruned(_ timestamps: [Date]) -> [Date] {
        let cutoff = Date().addingTimeInterval(-transferWindow)
        return timestamps.filter { $0 >= cutoff }
    }

    private static func initialStatus(from record: DeviceActivationRecord) -> RemoteActivationStatus {
        let now = Date()
        if let revokedSince = record.revokedSince {
            let deadline = revokedSince.addingTimeInterval(revocationGracePeriod)
            return now >= deadline
                ? .blocked(since: revokedSince)
                : .revokedGracePeriod(since: revokedSince, hardBlockDeadline: deadline)
        }
        if let last = record.lastSuccessfulVerificationAt, record.activationId != nil {
            return .active(lastVerifiedAt: last)
        }
        return .notActivated
    }
}
