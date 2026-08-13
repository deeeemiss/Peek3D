#if DEBUG
import Foundation
import CryptoKit
import PeekLicenseKit

/// Black-box test suite for the trial/license persistence layer
/// (`LicenseStore`, `LicenseState`, `LicenseStatusResolver`), run against the
/// REAL compiled binary — not a test target, because this project doesn't
/// have one and adding one means hand-editing `project.pbxproj` (fragile,
/// out of scope). Same pattern as `SelfTest.swift`'s `GLBVIEWER_SELFTEST`:
/// a launch-time environment variable, read once from `Peek3DApp.init()`,
/// that runs a sequence of assertions against the app's own production
/// code and exits — no window, no UI automation needed for THIS layer
/// (crypto verification itself is covered separately and more thoroughly by
/// `PeekLicenseKitTests`; the online re-verification / seat-management flow
/// described in README.md is a different feature and out of scope here).
///
/// Set `PEEK3D_LICENSE_SELFTEST=1` to run. See `scripts/test_license.sh` for
/// the full black-box suite this is one part of (the other part is the
/// uninstall/reinstall persistence check, which needs real process restarts
/// and Keychain/container manipulation a single in-process run can't do).
///
/// WARNING — destructive: this overwrites the SAME Keychain item and
/// UserDefaults key the real app uses (`com.seb.Peek3D.entitlement` /
/// `com.seb.Peek3D.entitlementMirror`), exactly like every other
/// `PEEK3D_LICENSE_DEBUG_STATE` value already does. It ends by resetting
/// both stores to "fresh install" — it will NOT restore whatever real trial/
/// license state existed before the run. Never run this against a machine
/// whose trial/license state you care about.
@MainActor
enum LicenseSelfTest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["PEEK3D_LICENSE_SELFTEST"] != nil else { return }

        var failureCount = 0
        func check(_ name: String, _ pass: Bool) {
            if pass {
                print("PASS: \(name)")
            } else {
                print("FAIL: \(name)")
                failureCount += 1
            }
        }
        func isLicensed(_ status: LicenseStatus) -> Bool {
            if case .licensed = status { return true }
            return false
        }

        let store = LicenseStore()
        // Known baseline — every prior debug/manual-QA state is irrelevant
        // from here on. This is the "fresh install" the rest of this run
        // measures deltas against.
        store.debugReset()

        // Real temp files, not synthetic hash strings — exercises
        // `FileIdentityHasher`'s actual canonicalization path (resolved,
        // standardized path), the same code the real app runs on a real
        // drag & drop.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Peek3DLicenseSelfTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        func makeFile(_ name: String) -> URL {
            let url = tmpDir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data("selftest-fixture".utf8))
            return url
        }

        // MARK: 1. Fresh trial — 0 of 10 used

        var record = store.loadMergedRecord()
        check("fresh install has zero seen files", record.seenFileHashes.isEmpty)
        check(
            "fresh install resolves to trial(opensRemaining: 10)",
            LicenseStatusResolver.resolve(record) == .trial(opensRemaining: LicenseRecord.trialLimit)
        )

        // MARK: 2. The border — 9 distinct opens leaves exactly 1 remaining

        let files = (0..<10).map { makeFile("model-\($0).glb") }
        for file in files.prefix(9) {
            record = store.recordFileOpened(file, currentRecord: record)
        }
        check("9 distinct opens are counted as 9 seen files", record.seenFileHashes.count == 9)
        check(
            "9/10 resolves to trial(opensRemaining: 1) — the last slot, not 0 and not 2",
            LicenseStatusResolver.resolve(record) == .trial(opensRemaining: 1)
        )

        // MARK: 3. Reopening an already-seen file never consumes a slot
        //
        // This is also the mechanism that makes macOS's automatic window
        // restoration safe (see `LicenseStore.recordFileOpened`'s doc
        // comment): a restored window replays the same file URL it had
        // before, which hashes to something already in `seenFileHashes` —
        // there's no separate "is this a restore" code path to test, the
        // dedup check IS the safety net for both cases.

        record = store.recordFileOpened(files[0], currentRecord: record)
        check("reopening file #0 does not consume a new slot", record.seenFileHashes.count == 9)
        check(
            "status is unchanged after the reopen (still opensRemaining: 1)",
            LicenseStatusResolver.resolve(record) == .trial(opensRemaining: 1)
        )

        // Same check again, but through the exact entry points a real
        // document window uses (`LicenseState.canOpen` / `.recordSuccessfulOpen`),
        // not `LicenseStore` directly.
        let state = LicenseState(store: store)
        check("LicenseState agrees: 9/10 seen, opensRemaining: 1", state.status == .trial(opensRemaining: 1))
        state.recordSuccessfulOpen(of: files[0])
        check(
            "LicenseState.recordSuccessfulOpen on an already-seen file is a no-op",
            state.status == .trial(opensRemaining: 1)
        )

        // MARK: 4. The 10th DISTINCT file exhausts the trial — never opensRemaining: 0

        state.recordSuccessfulOpen(of: files[9])
        check("the 10th distinct file exhausts the trial", state.status == .trialExhausted)

        // MARK: 5. Exhausted: previously-seen files still open; new ones are blocked

        check("exhausted trial still allows a previously-counted file", state.canOpen(url: files[3]))
        let neverSeen = makeFile("never-seen.glb")
        check("exhausted trial blocks a file never opened before", state.canOpen(url: neverSeen) == false)

        // MARK: 6. Corrupted persisted state fails OPEN, not closed
        //
        // Deliberate product decision (see `LicenseStore`'s doc comment): an
        // unreadable store must never look indistinguishable from "trial
        // exhausted" to a paying — or simply unlucky — customer.

        store.debugForceCorrupted()
        let corruptedState = LicenseState(store: store)
        check(
            "corrupted state resolves to a FRESH trial, not exhausted (fail-open)",
            corruptedState.status == .trial(opensRemaining: LicenseRecord.trialLimit)
        )
        check("corrupted state is never trialExhausted", corruptedState.status != .trialExhausted)

        // MARK: 7. A valid license unlocks everything, permanently
        //
        // Reuses the exact same TEST keypair/license string
        // `LicenseDebugHarness`'s own "licensed" debug state signs with —
        // real production verification code (`LicenseStatusResolver` /
        // `LicenseVerifier`), just with a test key manually added to the
        // trusted set the same way `LicenseDebugHarness` does, since
        // `LicenseVerifier.trustedPublicKeys` is intentionally empty until
        // release (see `test_trustedPublicKeys_neverContainsTheTestKey` in
        // PeekLicenseKitTests for why that must stay true in production).

        if let testKey = LicenseDebugHarness.testPublicKey {
            store.debugForceRecord(LicenseRecord(seenFileHashes: [], licenseKeyText: LicenseDebugHarness.testLicenseString))
            let licensedState = LicenseState(store: store, extraTrustedKeys: [testKey])
            check("a valid license resolves to .licensed", isLicensed(licensedState.status))
            check("a licensed state opens a file it has never seen before", licensedState.canOpen(url: neverSeen))
        } else {
            print("FAIL: could not parse the test public key — see LicenseDebugHarness.testPublicKey")
            failureCount += 1
        }

        // MARK: 8. Malformed license text never resolves to .licensed
        //
        // The single most important negative check in this file.
        // `LicenseStatusResolver.resolve` is the ONLY call site for
        // `LicenseVerifier.verify` in the whole app — everything else just
        // moves `LicenseRecord` values around trusting its answer. The
        // sabotage this guards against: someone "simplifies" `resolve()` to
        // "any non-nil `licenseKeyText` -> .licensed", deleting the call to
        // `verify()` entirely. That refactor compiles, every OTHER test in
        // this file still passes (they all use either no license text or the
        // one known-good test string), and the effect in production is that
        // pasting literally any string permanently unlocks the app.
        //
        // Garbage text isn't even valid Crockford Base32 / too short to hold
        // a signature, so `LicenseVerifier.verify` returns `.malformed` for
        // it — a real "fail closed" resolver must fall through to the trial
        // calculation, never `.licensed`.
        let garbageRecord = LicenseRecord(seenFileHashes: [], licenseKeyText: "not-a-real-license-at-all")
        check(
            "garbage license text never resolves to .licensed",
            isLicensed(LicenseStatusResolver.resolve(garbageRecord)) == false
        )
        check(
            "garbage license text still resolves to a normal trial status",
            LicenseStatusResolver.resolve(garbageRecord) == .trial(opensRemaining: LicenseRecord.trialLimit)
        )

        // MARK: 9. A single altered character in an otherwise-valid license
        // never resolves to .licensed either
        //
        // Deliberately a DIFFERENT failure mode than #8: this string decodes
        // fine (right Crockford alphabet, right byte length, right structure
        // — `LicenseVerifier.verify` gets past `.malformed` entirely) but the
        // Ed25519 signature no longer matches because one payload byte
        // changed. This catches a resolver that decodes/pattern-matches
        // shape without ever checking the signature the same way #8 catches
        // one that skips `verify()` altogether — a decode-shape check alone
        // would pass this string, only real signature verification catches
        // it. Uses the same test keypair as section 7 so the ONLY variable
        // is the one flipped character, not "this key isn't trusted".
        if let testKey = LicenseDebugHarness.testPublicKey {
            var tamperedChars = Array(LicenseDebugHarness.testLicenseString)
            var flipIndex = tamperedChars.count / 2
            while tamperedChars[flipIndex] == "-" {
                flipIndex += 1
            }
            let original = tamperedChars[flipIndex]
            tamperedChars[flipIndex] = (original == "0") ? "1" : "0" // guaranteed different decoded value
            let tamperedString = String(tamperedChars)

            let tamperedRecord = LicenseRecord(seenFileHashes: [], licenseKeyText: tamperedString)
            let tamperedStatus = LicenseStatusResolver.resolve(tamperedRecord, extraTrustedKeys: [testKey])
            check(
                "a tampered license (1 char altered, otherwise well-formed) never resolves to .licensed",
                isLicensed(tamperedStatus) == false
            )
            check(
                "tampered license falls through to a normal trial status, same as any invalid key",
                tamperedStatus == .trial(opensRemaining: LicenseRecord.trialLimit)
            )
        } else {
            print("FAIL: could not parse the test public key — see LicenseDebugHarness.testPublicKey")
            failureCount += 1
        }

        // MARK: 10. In-process proxy for "uninstall/reinstall keeps the trial count"
        //
        // The Keychain item is the authoritative store and lives OUTSIDE the
        // sandbox container; the UserDefaults mirror lives INSIDE it and is
        // exactly what an uninstall wipes. Simulating that by deleting only
        // the mirror and re-reading is a fast, real exercise of the actual
        // recovery code path (`LicenseStore.merge` + `repairIfNeeded`) — but
        // it is NOT a substitute for the full filesystem-level check in
        // `scripts/test_license.sh`, which deletes the real
        // `~/Library/Containers/com.seb.Peek3D` directory and relaunches a
        // second, independently-built copy of the app. This in-process
        // version can't catch a bug where some OTHER container-local file
        // secretly also tracks the count; the script-level version can.

        store.debugReset()
        var survivorRecord = LicenseRecord.empty
        for file in files.prefix(9) {
            survivorRecord = store.recordFileOpened(file, currentRecord: survivorRecord)
        }
        check("setup: 9 files recorded before the simulated uninstall", survivorRecord.seenFileHashes.count == 9)
        LicenseDefaultsMirror.debugDeleteAll() // Keychain item is untouched — simulates container removal only.
        let afterSimulatedReinstall = store.loadMergedRecord()
        check(
            "Keychain alone (mirror wiped) still reports all 9 seen files",
            afterSimulatedReinstall.seenFileHashes.count == 9
        )
        check(
            "...and resolves to trial(opensRemaining: 1), not a reset 10",
            LicenseStatusResolver.resolve(afterSimulatedReinstall) == .trial(opensRemaining: 1)
        )

        // Leave the machine in a known, harmless state.
        store.debugReset()

        print(failureCount == 0 ? "LICENSE_SELFTEST_OK" : "LICENSE_SELFTEST_FAIL (\(failureCount) failed)")
        fflush(stdout)
        exit(failureCount == 0 ? 0 : 1)
    }
}
#endif
