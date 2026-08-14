#if DEBUG
import Foundation

/// In-memory test double for `PolarLicenseAPIClient` — used by
/// `LicenseActivationSelfTest` (see `PEEK3D_ACTIVATION_SELFTEST`) to drive
/// `LicenseActivationService` through every server outcome deterministically,
/// with zero network and no live Polar account. Same role as
/// `licensing-worker/src/polar.ts`'s `FakePolarClient`.
///
/// Scripted per-call via a queue: each `activate`/`validate`/`deactivate`
/// call pops the next entry from its own queue (or falls back to
/// `defaultOutcome` once the queue is empty), so a self-test can lay out an
/// exact sequence — e.g. "first activate call: notPermitted; second
/// (after the seat is freed): success" — without any conditional logic
/// inside the fake itself.
///
/// This class is intentionally `#if DEBUG`-only, exactly like every other
/// test/debug harness in this app (`LicenseDebugHarness`, `LicenseSelfTest`)
/// — it must not exist in a shipped binary, and structurally can't.
final class FakePolarLicenseAPIClient: PolarLicenseAPIClient {
    private(set) var activateCalls: [(key: String, organizationId: String, label: String)] = []
    private(set) var validateCalls: [(key: String, organizationId: String, activationId: String)] = []
    private(set) var deactivateCalls: [(key: String, organizationId: String, activationId: String)] = []

    var activateQueue: [PolarAPIOutcome<PolarActivation>] = []
    var validateQueue: [PolarAPIOutcome<PolarValidatedLicense>] = []
    var deactivateQueue: [PolarAPIOutcome<Void>] = []

    /// Used once the corresponding queue above is empty. Defaults to a
    /// generic transport failure — a self-test that forgets to script an
    /// expected call finds out immediately (as an unreachable-server
    /// outcome) rather than the fake silently inventing a success.
    var defaultActivateOutcome: PolarAPIOutcome<PolarActivation> = .transportFailure(description: "unscripted activate call")
    var defaultValidateOutcome: PolarAPIOutcome<PolarValidatedLicense> = .transportFailure(description: "unscripted validate call")
    var defaultDeactivateOutcome: PolarAPIOutcome<Void> = .transportFailure(description: "unscripted deactivate call")

    func activate(key: String, organizationId: String, label: String) async -> PolarAPIOutcome<PolarActivation> {
        activateCalls.append((key, organizationId, label))
        return activateQueue.isEmpty ? defaultActivateOutcome : activateQueue.removeFirst()
    }

    func validate(key: String, organizationId: String, activationId: String) async -> PolarAPIOutcome<PolarValidatedLicense> {
        validateCalls.append((key, organizationId, activationId))
        return validateQueue.isEmpty ? defaultValidateOutcome : validateQueue.removeFirst()
    }

    func deactivate(key: String, organizationId: String, activationId: String) async -> PolarAPIOutcome<Void> {
        deactivateCalls.append((key, organizationId, activationId))
        return deactivateQueue.isEmpty ? defaultDeactivateOutcome : deactivateQueue.removeFirst()
    }
}
#endif
