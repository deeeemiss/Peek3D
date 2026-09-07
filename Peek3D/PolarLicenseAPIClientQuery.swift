#if DEBUG
import Foundation

/// Black-box probe that makes ONE real HTTP call through the production
/// `HTTPPolarLicenseAPIClient` and prints the outcome — this is what this
/// task's manual verification actually drives (see
/// `scripts/test_activation.sh`), deliberately bypassing
/// `LicenseActivationService` for the harness itself.
///
/// Why bypass the service: `LicenseActivationService` is `@MainActor`, and
/// bridging a synchronous `Peek3DApp.init()` into an `await` on
/// MainActor-isolated work — before this process's real run loop is
/// running — proved unreliable in practice (it hung indefinitely more
/// often than it completed; see the handoff notes). `HTTPPolarLicenseAPIClient`
/// itself is NOT actor-isolated, so its `Task` never needs to hop onto the
/// blocked main thread — it runs entirely on Swift Concurrency's own
/// background executor, making a `DispatchSemaphore` bridge safe here in a
/// way it isn't one layer up. This still exercises the exact same
/// `URLSession` calls, `PolarLicenseConfig.apiBase` override, and request/
/// response schema that `LicenseActivationService` uses internally — see
/// `HTTPPolarLicenseAPIClient.swift`.
///
/// `LicenseActivationSelfTest` separately proves the STATE MACHINE built on
/// top of this client is correct (24-hour gate, 72-hour revocation grace,
/// never-downgrade-on-failure) using a scripted fake — the two together
/// cover "the real network call happens" and "the logic built on it is
/// right" without needing both proven through the same fragile path.
enum PolarLicenseAPIClientQuery {
    static func printAndExitIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["PEEK3D_POLAR_CLIENT_QUERY"] else { return }

        let key = ProcessInfo.processInfo.environment["PEEK3D_POLAR_CLIENT_QUERY_KEY"] ?? "POLAR-TEST-KEY"
        let activationId = ProcessInfo.processInfo.environment["PEEK3D_POLAR_CLIENT_QUERY_ACTIVATION_ID"] ?? ""
        let organizationId = PolarLicenseConfig.organizationId
        let client = HTTPPolarLicenseAPIClient()

        let semaphore = DispatchSemaphore(value: 0)
        var resultDescription = "no result"

        Task {
            switch mode {
            case "activate":
                let label = MachineIdentifier.current() ?? "unknown-device"
                print("POLAR_CLIENT_QUERY: activating with label (machine identifier) = \(label)")
                let outcome = await client.activate(key: key, organizationId: organizationId, label: label)
                resultDescription = String(describing: outcome)
            case "validate":
                let outcome = await client.validate(key: key, organizationId: organizationId, activationId: activationId)
                resultDescription = String(describing: outcome)
            case "deactivate":
                let outcome = await client.deactivate(key: key, organizationId: organizationId, activationId: activationId)
                resultDescription = String(describing: outcome)
            default:
                resultDescription = "unknown mode: \(mode) (expected activate/validate/deactivate)"
            }
            semaphore.signal()
        }
        semaphore.wait()

        print("POLAR_CLIENT_QUERY_RESULT: \(resultDescription)")
        fflush(stdout)
        exit(0)
    }
}
#endif
