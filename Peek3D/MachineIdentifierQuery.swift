#if DEBUG
import Foundation

/// Read-only black-box probe: set `PEEK3D_MACHINE_ID_QUERY=1` to print what
/// `MachineIdentifier.current()` resolves to, from inside the REAL compiled
/// app binary, and exit immediately — no window drawn. Same pattern as
/// `LicenseStateQuery`/`PEEK3D_LICENSE_STATE_QUERY`, and for the same
/// reason: this project has no test target (adding one means hand-editing
/// `project.pbxproj`, see CLAUDE.md), so a launch-time environment variable
/// read once from `Peek3DApp.init()` is how production code gets exercised
/// end-to-end from a shell script instead of only compiled.
///
/// This is the ONLY way to know whether `IOServiceGetMatchingService` /
/// `IORegistryEntryCreateCFProperty` actually succeed under a REAL sandboxed
/// launch (`flags=0x10000(runtime)`, ad-hoc/Development-signed, not just
/// running under Xcode's debugger) — this project has already been burned
/// once by an access path that worked under Xcode and failed silently in a
/// distributed build (see build_codesign_gltfkit2 in memory), so this
/// identifier is never declared "working" on the strength of compiling.
enum MachineIdentifierQuery {
    static func printAndExitIfRequested() {
        guard ProcessInfo.processInfo.environment["PEEK3D_MACHINE_ID_QUERY"] != nil else { return }

        if let identifier = MachineIdentifier.current() {
            print("MACHINE_ID: \(identifier)")
        } else {
            print("MACHINE_ID: nil (IOPlatformUUID unreadable)")
        }
        fflush(stdout)
        exit(0)
    }
}
#endif
