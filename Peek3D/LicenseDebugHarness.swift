#if DEBUG
import Foundation
import CryptoKit
import PeekLicenseKit

/// Debug-only hook for forcing the trial/license system into an arbitrary
/// state without opening ten real files by hand. Reads
/// `PEEK3D_LICENSE_DEBUG_STATE` once at launch from `Peek3DApp.init()`,
/// right alongside `SelfTest.runIfRequested()` — same pattern, same reason:
/// a launch-time environment variable that structurally doesn't exist as
/// code in a Release build (this whole file is wrapped in `#if DEBUG`), not
/// an obscure name relying on nobody guessing it.
///
/// A `UserDefaults` key was deliberately NOT used for this: it would
/// persist across launches, show up under `defaults read`, and be exactly
/// the kind of trivial reset this whole design exists to prevent.
enum LicenseDebugHarness {
    /// Recognised values for `PEEK3D_LICENSE_DEBUG_STATE`:
    /// - "trial0"    — fresh trial, 0 of 10 files opened
    /// - "trial9"    — 9 of 10 files opened (one open away from exhausted)
    /// - "exhausted" — trial fully used (10 of 10)
    /// - "licensed"  — a valid license is present
    /// - "corrupted" — both stores hold undecodable bytes
    /// - "reset"     — wipes both stores back to a fresh install
    ///
    /// Returns nil (do nothing, use the normal `LicenseState()` path) when
    /// the variable is unset or unrecognized.
    ///
    /// `@MainActor` purely as a mechanical consequence of `LicenseState`
    /// itself becoming `@MainActor` (see its doc comment) — this function's
    /// only caller is `Peek3DApp.init()`, itself main-actor-isolated via
    /// `App`'s `body` requirement, so this changes no runtime behavior.
    @MainActor
    static func makeState() -> LicenseState? {
        guard let raw = ProcessInfo.processInfo.environment["PEEK3D_LICENSE_DEBUG_STATE"] else {
            return nil
        }

        let store = LicenseStore()
        switch raw {
        case "trial0":
            store.debugForceRecord(.empty)
            return LicenseState(store: store)

        case "trial9":
            let hashes = (0..<9).map { "debug-seen-\($0)" }
            store.debugForceRecord(LicenseRecord(seenFileHashes: hashes, licenseKeyText: nil))
            return LicenseState(store: store)

        case "exhausted":
            let hashes = (0..<LicenseRecord.trialLimit).map { "debug-seen-\($0)" }
            store.debugForceRecord(LicenseRecord(seenFileHashes: hashes, licenseKeyText: nil))
            return LicenseState(store: store)

        case "licensed":
            let record = LicenseRecord(seenFileHashes: [], licenseKeyText: testLicenseString)
            store.debugForceRecord(record)
            guard let testKey = testPublicKey else {
                assertionFailure("LicenseDebugHarness: test public key failed to parse")
                return LicenseState(store: store)
            }
            return LicenseState(store: store, extraTrustedKeys: [testKey])

        case "corrupted":
            store.debugForceCorrupted()
            return LicenseState(store: store)

        case "reset":
            store.debugReset()
            return LicenseState(store: store)

        default:
            return nil
        }
    }

    // MARK: - Test material for the "licensed" state

    /// The exact same fixed test keypair PeekLicenseKit's own test suite
    /// pins in `PeekLicenseKitTests/TestVectors.swift` — copied here as
    /// literals because the app target can't `@testable import` a Swift
    /// package's test target. TEST MATERIAL, never a real signing key: it
    /// secures nothing and must never be treated as production trust.
    private static let testPublicKeyHex = "e60868d30765ae875f1fa9317197f3328cff10935386011dfb42470d05a6e741"

    /// One of `TestVectors.vectors` (mario.rossi@example.com), copied
    /// verbatim — a real, valid, schema-1 product-1 license string signed
    /// by the key above.
    ///
    /// Internal (not `private`), not because anything outside this file
    /// forces a "licensed" debug *state* — `LicenseSelfTest.swift` reuses
    /// this exact string and `testPublicKey` below to exercise "a valid
    /// license unlocks everything, permanently" through the same real
    /// `LicenseState`/`LicenseStatusResolver` path, without maintaining a
    /// third copy of this TEST-ONLY material alongside this file and
    /// `PeekLicenseKitTests/TestVectors.swift`.
    static let testLicenseString =
        "PK3D-040PE-F1S00-CN0KT-C8592-TGA26-4S2TG-T46CT-2THA6-6MV2T-DSR74-R1EVB-1E9MP-YBKJD-XSQ6T-A0CNW-62VBG-DHJJW-RVFDM-YM364-33MH9-0JFXZ-8X667-9FDN4-6MX64-15EH3-2HXWF-8F2CE-K15PG-1H28N-X13N1-HE97R-H344N-J9XTC-6TW5B-MEH2N-4SHZ5-0KQ0R-W3T7S-05"

    /// Internal for the same reason as `testLicenseString` above —
    /// `LicenseSelfTest.swift` is the other reader.
    static var testPublicKey: Curve25519.Signing.PublicKey? {
        guard let data = Data(hexString: testPublicKeyHex) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }
}

private extension Data {
    /// Minimal hex decoder — only used to turn `testPublicKeyHex` above
    /// into bytes, and only in DEBUG builds.
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
#endif
