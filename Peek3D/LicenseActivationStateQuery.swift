#if DEBUG
import Foundation

/// Read-only black-box probe: set `PEEK3D_ACTIVATION_STATE_QUERY=1` to print
/// the persisted `DeviceActivationRecord` and exit immediately — no window
/// drawn, no network call made by this probe itself.
///
/// Meant to run as a SEPARATE, second process launch, AFTER a normal app
/// run already made its real HTTP call (via `launchTimeCheck`/
/// `licenseKeyWasApplied`, exactly like a real launch) and persisted the
/// result — the same two-launch pattern `LicenseStateQuery` already uses
/// for the uninstall/reinstall check in `scripts/test_license.sh`. See
/// `scripts/test_activation.sh` for the driving script.
///
/// Deliberately does NOT trigger or await a network call itself, and is
/// NOT `@MainActor`: `LicenseActivationService` is, and a real
/// `URLSession` call genuinely suspends across threads before resuming on
/// the main actor — bridging that synchronously from inside
/// `Peek3DApp.init()`, before this process's real run loop is even
/// running, is not a safe thing to build a verification tool on (it hung
/// indefinitely in testing — see the handoff notes). Letting the real app
/// run normally instead means its REAL run loop services the background
/// `Task` exactly like production does, and this probe only ever reads
/// what got persisted as a result.
enum LicenseActivationStateQuery {
    static func printAndExitIfRequested() {
        guard ProcessInfo.processInfo.environment["PEEK3D_ACTIVATION_STATE_QUERY"] != nil else { return }

        let record = DeviceActivationKeychainStore.load()
        print("ACTIVATION_RECORD: activationId=\(record.activationId ?? "nil")")
        print("ACTIVATION_RECORD: hasLicenseKeyText=\(record.activatedForLicenseKeyText != nil)")
        print("ACTIVATION_RECORD: lastSuccessfulVerificationAt=\(record.lastSuccessfulVerificationAt.map { "\($0)" } ?? "nil")")
        print("ACTIVATION_RECORD: revokedSince=\(record.revokedSince.map { "\($0)" } ?? "nil")")
        print("ACTIVATION_RECORD: transferCount=\(record.transferTimestamps.count)")
        fflush(stdout)
        exit(0)
    }
}
#endif
