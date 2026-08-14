#if DEBUG
import Foundation

/// Black-box test suite for `LicenseActivationService`'s state machine —
/// same role and pattern as `LicenseSelfTest.swift` for the trial/license
/// layer: no separate test target exists in this project (see that file's
/// doc comment for why), so this is a launch-time environment-variable hook
/// read once from `Peek3DApp.init()`, exercising real production code with
/// a scripted `FakePolarLicenseAPIClient` — zero network, no live Polar
/// account needed.
///
/// Set `PEEK3D_ACTIVATION_SELFTEST=1` to run. Reuses
/// `LicenseDebugHarness.testLicenseString`/`testPublicKey` (the fixed test
/// keypair PeekLicenseKit's own suite pins) rather than maintaining a
/// fourth copy of that material.
///
/// WARNING — destructive: overwrites the real `com.seb.Peek3D.activation`
/// Keychain item, exactly like `LicenseSelfTest` does for the entitlement
/// one. Ends by wiping it back to empty.
@MainActor
enum LicenseActivationSelfTest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["PEEK3D_ACTIVATION_SELFTEST"] != nil else { return }

        var failureCount = 0
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            if pass {
                print("PASS: \(name)")
            } else {
                print("FAIL: \(name)\(detail.isEmpty ? "" : " — \(detail)")")
                failureCount += 1
            }
        }

        guard let testKey = LicenseDebugHarness.testPublicKey else {
            print("FAIL: could not parse LicenseDebugHarness.testPublicKey — aborting suite")
            print("ACTIVATION_SELFTEST_FAILED")
            fflush(stdout)
            exit(1)
        }
        let licenseText = LicenseDebugHarness.testLicenseString
        // The Polar key embedded in `testLicenseString` — see
        // `PeekLicenseKit/Tests/PeekLicenseKitTests/TestVectors.swift`,
        // the "mario.rossi@example.com" vector this string is copied from.
        let embeddedPolarKey = "POLAR-AB12-CD34-EF56-7890"

        // MARK: 1. Fresh activation succeeds and is persisted

        DeviceActivationKeychainStore.debugDeleteAll()
        do {
            let fake = FakePolarLicenseAPIClient()
            let service = LicenseActivationService(apiClient: fake, organizationId: "test-org")
            service.debugSetExtraTrustedKeys([testKey])

            fake.activateQueue = [.success(PolarActivation(activationId: "act-1", label: "selftest-device"))]
            await_ { await service.activateIfNeeded(licenseKeyText: licenseText) }

            check("fresh activate: exactly one /activate call made", fake.activateCalls.count == 1)
            check("fresh activate: request carried the real polar key, not the PK3D- text", fake.activateCalls.first?.key == embeddedPolarKey)
            if case .active = service.remoteStatus {
                check("fresh activate: remoteStatus becomes .active", true)
            } else {
                check("fresh activate: remoteStatus becomes .active", false, "got \(service.remoteStatus)")
            }
            let record = DeviceActivationKeychainStore.load()
            check("fresh activate: activationId persisted", record.activationId == "act-1")
            check("fresh activate: no transfer counted for a first-ever activation", record.transferTimestamps.isEmpty)
        }

        // MARK: 2. Re-applying the SAME key text is idempotent (no second /activate)

        DeviceActivationKeychainStore.debugDeleteAll()
        do {
            let fake = FakePolarLicenseAPIClient()
            let service = LicenseActivationService(apiClient: fake, organizationId: "test-org")
            service.debugSetExtraTrustedKeys([testKey])
            fake.activateQueue = [.success(PolarActivation(activationId: "act-1", label: "selftest-device"))]
            await_ { await service.activateIfNeeded(licenseKeyText: licenseText) }
            await_ { await service.activateIfNeeded(licenseKeyText: licenseText) }
            check("re-applying the same key text triggers exactly one /activate call, not two", fake.activateCalls.count == 1)
        }

        // MARK: 3. Device conflict (403 notPermitted) never touches the persisted activationId

        DeviceActivationKeychainStore.debugDeleteAll()
        do {
            let fake = FakePolarLicenseAPIClient()
            let service = LicenseActivationService(apiClient: fake, organizationId: "test-org")
            service.debugSetExtraTrustedKeys([testKey])
            fake.activateQueue = [.notPermitted(detail: "activation limit reached")]
            await_ { await service.activateIfNeeded(licenseKeyText: licenseText) }

            check("device conflict: remoteStatus becomes .deviceConflict", service.remoteStatus == .deviceConflict)
            check("device conflict: no activationId recorded for this device", DeviceActivationKeychainStore.load().activationId == nil)
        }

        // MARK: 4. Revoked -> grace period -> blocked after 72h, never immediately

        DeviceActivationKeychainStore.debugDeleteAll()
        do {
            let fake = FakePolarLicenseAPIClient()
            let service = LicenseActivationService(apiClient: fake, organizationId: "test-org")
            service.debugSetExtraTrustedKeys([testKey])

            var seeded = DeviceActivationRecord.empty
            seeded.activationId = "act-2"
            seeded.activatedForLicenseKeyText = licenseText
            seeded.lastSuccessfulVerificationAt = Date().addingTimeInterval(-25 * 3600) // > 24h ago: passes the reverify gate
            DeviceActivationKeychainStore.save(seeded)

            fake.validateQueue = [.success(PolarValidatedLicense(status: .revoked))]
            await_ { await service.reverifyIfNeeded(licenseKeyText: licenseText) }

            if case .revokedGracePeriod = service.remoteStatus {
                check("revoked (fresh): remoteStatus becomes .revokedGracePeriod, NOT .blocked", true)
            } else {
                check("revoked (fresh): remoteStatus becomes .revokedGracePeriod, NOT .blocked", false, "got \(service.remoteStatus)")
            }
            let afterFirstRevoke = DeviceActivationKeychainStore.load()
            check("revoked (fresh): revokedSince persisted", afterFirstRevoke.revokedSince != nil)

            // Simulate 73 hours having passed since the FIRST revoked signal.
            var pastGrace = afterFirstRevoke
            pastGrace.revokedSince = Date().addingTimeInterval(-73 * 3600)
            pastGrace.lastSuccessfulVerificationAt = Date().addingTimeInterval(-73 * 3600)
            DeviceActivationKeychainStore.save(pastGrace)

            fake.validateQueue = [.success(PolarValidatedLicense(status: .revoked))]
            await_ { await service.reverifyIfNeeded(licenseKeyText: licenseText) }

            if case .blocked = service.remoteStatus {
                check("revoked (73h later): remoteStatus becomes .blocked", true)
            } else {
                check("revoked (73h later): remoteStatus becomes .blocked", false, "got \(service.remoteStatus)")
            }

            // A SECOND consecutive revoked answer must not push revokedSince forward.
            let finalRecord = DeviceActivationKeychainStore.load()
            check(
                "revokedSince is not overwritten by a later revoked answer",
                finalRecord.revokedSince == pastGrace.revokedSince
            )
        }

        // MARK: 5. THE non-negotiable rule: transport failure never downgrades state

        DeviceActivationKeychainStore.debugDeleteAll()
        do {
            let fake = FakePolarLicenseAPIClient()
            let service = LicenseActivationService(apiClient: fake, organizationId: "test-org")
            service.debugSetExtraTrustedKeys([testKey])

            let goodTimestamp = Date().addingTimeInterval(-25 * 3600) // > 24h ago: passes the gate
            var seeded = DeviceActivationRecord.empty
            seeded.activationId = "act-3"
            seeded.activatedForLicenseKeyText = licenseText
            seeded.lastSuccessfulVerificationAt = goodTimestamp
            DeviceActivationKeychainStore.save(seeded)

            fake.validateQueue = [.transportFailure(description: "simulated timeout")]
            await_ { await service.reverifyIfNeeded(licenseKeyText: licenseText) }

            if case .unreachable(let lastKnownGoodAt, let withinGrace) = service.remoteStatus {
                check("transport failure: remoteStatus becomes .unreachable, not .blocked/.deviceConflict", true)
                check("transport failure: lastKnownGoodAt preserved", lastKnownGoodAt == goodTimestamp)
                check("transport failure: still within the 30-day offline grace", withinGrace)
            } else {
                check("transport failure: remoteStatus becomes .unreachable, not .blocked/.deviceConflict", false, "got \(service.remoteStatus)")
            }

            let afterFailure = DeviceActivationKeychainStore.load()
            check(
                "transport failure: lastSuccessfulVerificationAt is NOT touched (no write on failure)",
                afterFailure.lastSuccessfulVerificationAt == goodTimestamp
            )
            check("transport failure: revokedSince stays nil — never invented from a network error", afterFailure.revokedSince == nil)
            check("transport failure: activationId untouched", afterFailure.activationId == "act-3")
        }

        // MARK: 6. The 24-hour gate: a recent success suppresses the network call entirely

        DeviceActivationKeychainStore.debugDeleteAll()
        do {
            let fake = FakePolarLicenseAPIClient()
            let service = LicenseActivationService(apiClient: fake, organizationId: "test-org")
            service.debugSetExtraTrustedKeys([testKey])

            var seeded = DeviceActivationRecord.empty
            seeded.activationId = "act-4"
            seeded.activatedForLicenseKeyText = licenseText
            seeded.lastSuccessfulVerificationAt = Date().addingTimeInterval(-3600) // 1h ago — well under 24h
            DeviceActivationKeychainStore.save(seeded)

            fake.validateQueue = [.success(PolarValidatedLicense(status: .revoked))] // would fail the test if actually called
            await_ { await service.reverifyIfNeeded(licenseKeyText: licenseText) }

            check("24h gate: no /validate call made when last success was 1h ago", fake.validateCalls.isEmpty)
            if case .active = service.remoteStatus {
                check("24h gate: remoteStatus stays .active without a network call", true)
            } else {
                check("24h gate: remoteStatus stays .active without a network call", false, "got \(service.remoteStatus)")
            }
        }

        // MARK: 7. Queued retry: a never-completed activation is retried on reverify

        DeviceActivationKeychainStore.debugDeleteAll()
        do {
            let fake = FakePolarLicenseAPIClient()
            let service = LicenseActivationService(apiClient: fake, organizationId: "test-org")
            service.debugSetExtraTrustedKeys([testKey])
            // No seeded record at all — activationId is nil, exactly the
            // state left behind by an activation attempt that never
            // reached the server (see step 5's "no write on failure").

            fake.activateQueue = [.success(PolarActivation(activationId: "act-5", label: "selftest-device"))]
            await_ { await service.reverifyIfNeeded(licenseKeyText: licenseText) }

            check("queued retry: reverify calls /activate (not /validate) when no activationId is on record", fake.activateCalls.count == 1 && fake.validateCalls.isEmpty)
            check("queued retry: succeeds and persists the activationId", DeviceActivationKeychainStore.load().activationId == "act-5")
        }

        // MARK: Cleanup — never leave the real Keychain item in a test state

        DeviceActivationKeychainStore.debugDeleteAll()

        print(failureCount == 0 ? "ACTIVATION_SELFTEST_OK" : "ACTIVATION_SELFTEST_FAILED")
        fflush(stdout)
        exit(failureCount == 0 ? 0 : 1)
    }

    /// Every scenario above is a single, sequential `async` call inside a
    /// synchronous `runIfRequested()` — mirroring `LicenseSelfTest`'s fully
    /// synchronous style so both self-tests read the same way. A tiny
    /// sync-to-async bridge is unavoidable here (unlike `LicenseSelfTest`,
    /// which never awaits anything).
    ///
    /// Deliberately NOT a `DispatchSemaphore.wait()` on the main thread:
    /// `LicenseActivationService` is `@MainActor`, so the `Task` below must
    /// hop onto the main actor's executor to run `operation`'s body — and
    /// that executor IS the main thread. Blocking the main thread
    /// synchronously in `semaphore.wait()` would starve that exact hop and
    /// deadlock every single call. Spinning `RunLoop.main` instead keeps
    /// the main thread available to service the main queue (what
    /// `@MainActor` work is dispatched onto) between checks of `finished`.
    private static func await_(_ operation: @escaping () async -> Void) {
        var finished = false
        Task { @MainActor in
            await operation()
            finished = true
        }
        while !finished {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }
}
#endif
