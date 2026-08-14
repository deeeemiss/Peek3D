import Foundation
import CryptoKit
import IOKit

/// The identifier Peek3D sends to the license service to count and
/// gate device activations.
///
/// This is deliberately NOT the raw hardware UUID. It is:
///
///     HMAC-SHA256(IOPlatformUUID, applicationKey)
///
/// expressed as lowercase hex. Two things about that shape matter more than
/// they look like they should:
///
/// 1. **The key is a fixed, compiled-in constant — never a random salt
///    generated per-launch or per-install.** The whole point of this value
///    is that the SAME machine produces the SAME identifier every time, so
///    the license service can count "how many distinct machines has this
///    key activated". A random salt would make every launch look like a
///    brand-new machine and silently break activation counting entirely —
///    this is the one mistake in this file that would matter and not be
///    obvious from a quick read, so it gets its own paragraph.
///
/// 2. **Hashing here is defense-in-depth, not anonymization.** HMAC with a
///    fixed key is a deterministic, one-to-one function of its input: given
///    the output and knowledge of the key (which is trivially extractable
///    from the shipped binary — it is not a secret), the input is not
///    recoverable, but as a *machine identifier* this hash discriminates
///    machines exactly as precisely as the raw `IOPlatformUUID` would. Its
///    only job is keeping a real Apple-issued hardware UUID out of server
///    logs and the license database in plaintext. It must never be
///    represented to a user, or relied upon in code review, as providing
///    anonymity — it doesn't.
enum MachineIdentifier {
    /// Compiled into the binary, not a secret (see doc above). Must stay
    /// byte-for-byte constant across every future build: changing it
    /// reassigns a new identifier to every Mac that has ever activated
    /// Peek3D, which the license service would read as a mass hardware
    /// replacement event.
    private static let applicationKey = SymmetricKey(
        data: Data("Peek3D.machineIdentifier.hmacKey.v1.9f1c6a2e4b7d8035".utf8)
    )

    /// `HMAC-SHA256(IOPlatformUUID, applicationKey)` as 64 lowercase hex
    /// characters, or `nil` if `IOPlatformUUID` could not be read.
    ///
    /// `nil` is a legitimate, expected outcome a caller must handle without
    /// crashing or blocking app launch — see `platformUUID()` below for why
    /// this read can fail even though it normally won't.
    static func current() -> String? {
        guard let uuid = platformUUID() else { return nil }
        let digest = HMAC<SHA256>.authenticationCode(for: Data(uuid.utf8), using: applicationKey)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Reads `IOPlatformUUID` from the IORegistry via
    /// `IOServiceMatching("IOPlatformExpertDevice")`.
    ///
    /// This is a property lookup on an existing IORegistry entry, not the
    /// opening of an IOKit user client — App Sandbox mediates the latter
    /// (via `com.apple.security.device.*` entitlements) but does not gate
    /// plain IORegistry property reads, so this call needs, and requests,
    /// no additional entitlement beyond the sandbox itself. Verified against
    /// a real sandboxed build, not just asserted: see
    /// `MachineIdentifierQuery` and the handoff notes for how.
    ///
    /// Returns `nil` — never crashes, never blocks the caller — if the
    /// matching service can't be found or the property is missing or not a
    /// string, so a caller that can't get a machine identifier still lets
    /// the app launch normally and can decide what to do (retry later,
    /// treat as "identity unknown yet") rather than failing hard on
    /// something a user has no way to fix.
    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }

        return property.takeRetainedValue() as? String
    }
}
