#if DEBUG
import Foundation

/// Read-only black-box probe: set `PEEK3D_LICENSE_STATE_QUERY=1` to print
/// whatever `Peek3DApp.init()` resolved as the license state and exit
/// immediately, no window drawn. Composes with `PEEK3D_LICENSE_DEBUG_STATE`
/// (see `LicenseDebugHarness`) rather than duplicating it: if that variable
/// is ALSO set, this prints the state it forces; if it's absent, this prints
/// whatever `LicenseState()`'s normal Keychain/UserDefaults merge finds on
/// disk right now, through the exact same code path the real UI uses.
///
/// That second mode is the whole point for `scripts/test_license.sh`'s
/// uninstall/reinstall check: launch once with `PEEK3D_LICENSE_DEBUG_STATE=
/// trial9 PEEK3D_LICENSE_STATE_QUERY=1` to seed 9 seen files AND confirm the
/// seed took; delete the sandbox container (Keychain survives — see
/// `LicenseKeychainStore`); launch a second, independently-built copy with
/// ONLY `PEEK3D_LICENSE_STATE_QUERY=1` (no forced state) and check the
/// printed count still says 1 remaining, proving persistence came from the
/// Keychain and not from anything container-local.
enum LicenseStateQuery {
    @MainActor
    static func printAndExitIfRequested(_ state: LicenseState) {
        guard ProcessInfo.processInfo.environment["PEEK3D_LICENSE_STATE_QUERY"] != nil else { return }

        switch state.status {
        case .trial(let opensRemaining):
            print("LICENSE_STATE: trial opensRemaining=\(opensRemaining)")
        case .trialExhausted:
            print("LICENSE_STATE: trialExhausted")
        case .licensed(let holder):
            print("LICENSE_STATE: licensed holder=\(holder)")
        }
        fflush(stdout)
        exit(0)
    }
}
#endif
