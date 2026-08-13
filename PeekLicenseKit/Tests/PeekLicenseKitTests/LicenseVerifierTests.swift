import XCTest
import CryptoKit
@testable import PeekLicenseKit

final class LicenseVerifierTests: XCTestCase {

    private var trustedKeys: [Curve25519.Signing.PublicKey] { [TestVectors.publicKey] }

    // MARK: - Fixture helpers (test-only mirror of the signing side, built
    // from the format spec so these tests don't depend on production code
    // for anything but the thing under test).

    private func buildPayload(
        schema: UInt8 = 1,
        product: UInt8 = 1,
        issuedAt: UInt32 = 1_700_000_000,
        polarKey: String = "POLAR-TEST-0000-0000-0000",
        email: String = "test@example.com"
    ) -> Data {
        var bytes = [UInt8]()
        bytes.append(schema)
        bytes.append(product)
        bytes.append(UInt8((issuedAt >> 24) & 0xFF))
        bytes.append(UInt8((issuedAt >> 16) & 0xFF))
        bytes.append(UInt8((issuedAt >> 8) & 0xFF))
        bytes.append(UInt8(issuedAt & 0xFF))
        let polarKeyBytes = Array(polarKey.utf8)
        bytes.append(UInt8(polarKeyBytes.count))
        bytes.append(contentsOf: polarKeyBytes)
        let emailBytes = Array(email.utf8)
        bytes.append(UInt8(emailBytes.count))
        bytes.append(contentsOf: emailBytes)
        return Data(bytes)
    }

    private func group(_ s: String) -> String {
        var result = ""
        for (index, character) in s.enumerated() {
            if index > 0 && index % 5 == 0 { result.append("-") }
            result.append(character)
        }
        return result
    }

    private func makeLicenseString(
        schema: UInt8 = 1,
        product: UInt8 = 1,
        issuedAt: UInt32 = 1_700_000_000,
        polarKey: String = "POLAR-TEST-0000-0000-0000",
        email: String = "test@example.com"
    ) -> String {
        let payload = buildPayload(schema: schema, product: product, issuedAt: issuedAt, polarKey: polarKey, email: email)
        let signature = try! TestVectors.privateKey.signature(for: payload)
        return "PK3D-" + group(Crockford32.encode(payload + signature))
    }

    // MARK: - Interop vectors

    /// The invariant that actually matters between the two sides of this
    /// system: a license string signed by the real issuing service (the
    /// licensing-worker, using @noble/ed25519) is accepted and correctly
    /// decoded by this verifier. `TestVectors.vectors` holds the worker's
    /// own canonical output for these inputs, copied verbatim from
    /// `licensing-worker/TEST_VECTORS.md` — not regenerated locally.
    ///
    /// This test deliberately does NOT assert that signing the same inputs
    /// with CryptoKit in this package reproduces the same license string
    /// byte-for-byte. It can't: CryptoKit's Ed25519 signing is randomized
    /// rather than RFC 8032's deterministic-nonce scheme, so two calls to
    /// `Curve25519.Signing.PrivateKey.signature(for:)` over the identical
    /// message yield two different (both individually valid) signatures.
    /// A "golden" vector produced by signing with CryptoKit is therefore
    /// unreproducible even from one run to the next on the same machine —
    /// it is not a fixed reference and never can be. If this ever gets
    /// "fixed" by regenerating vectors via CryptoKit signing again, that
    /// reintroduces exactly this confusion. The worker's output is the only
    /// valid source for these strings; what this test verifies is that the
    /// verifier accepts it and decodes it correctly, which is the real
    /// contract between the two implementations.
    func test_licenseSignedByIssuingService_isAccepted() {
        for vector in TestVectors.vectors {
            let result = LicenseVerifier.verify(vector.licenseString, trustedKeys: trustedKeys)
            guard case .valid(let email, let issuedAt, let polarKey) = result else {
                XCTFail("expected .valid for vector \(vector.email), got \(result)")
                continue
            }
            XCTAssertEqual(email, vector.email)
            XCTAssertEqual(polarKey, vector.polarKey)
            XCTAssertEqual(issuedAt.timeIntervalSince1970, TimeInterval(vector.issuedAtUnix))
        }
    }

    // MARK: - Required coverage

    func test_validKey_decodesAllFields() {
        let issuedAt: UInt32 = 1_735_000_000
        let license = makeLicenseString(issuedAt: issuedAt, polarKey: "POLAR-ABCD-1234-EFGH-5678", email: "utente@peek3d.app")

        let result = LicenseVerifier.verify(license, trustedKeys: trustedKeys)

        guard case .valid(let email, let issuedAtDate, let polarKey) = result else {
            return XCTFail("expected .valid, got \(result)")
        }
        XCTAssertEqual(email, "utente@peek3d.app")
        XCTAssertEqual(polarKey, "POLAR-ABCD-1234-EFGH-5678")
        XCTAssertEqual(issuedAtDate.timeIntervalSince1970, TimeInterval(issuedAt))
    }

    func test_oneCharacterChanged_isSignatureInvalid_notMalformed() {
        let license = makeLicenseString()
        var chars = Array(license)

        // Walk back from near the end (well inside the encoded signature
        // tail) to the nearest real data character, skipping any hyphen.
        var flipIndex = chars.count - 10
        while chars[flipIndex] == "-" { flipIndex -= 1 }

        let original = chars[flipIndex]
        let replacement: Character = (original == "0") ? "1" : "0"
        chars[flipIndex] = replacement
        let tampered = String(chars)
        XCTAssertNotEqual(tampered, license)

        let result = LicenseVerifier.verify(tampered, trustedKeys: trustedKeys)
        XCTAssertEqual(result, .signatureInvalid)
    }

    func test_truncatedKey_isMalformed() {
        let license = makeLicenseString()
        let truncated = String(license.prefix(20))

        let result = LicenseVerifier.verify(truncated, trustedKeys: trustedKeys)
        XCTAssertEqual(result, .malformed)
    }

    func test_schema2_isValidFutureSchema() {
        let license = makeLicenseString(schema: 2)

        let result = LicenseVerifier.verify(license, trustedKeys: trustedKeys)
        XCTAssertEqual(result, .validFutureSchema)
    }

    func test_differentProductID_isValidWrongProduct() {
        let license = makeLicenseString(product: 99)

        let result = LicenseVerifier.verify(license, trustedKeys: trustedKeys)
        XCTAssertEqual(result, .validWrongProduct)
    }

    func test_dirtyInput_spacesNewlinesLowercaseAndAmbiguousCrockfordChars_stillVerifies() {
        let license = makeLicenseString(email: "dirty@peek3d.app")
        let body = String(license.dropFirst("PK3D-".count))

        // Sanity: the fixture must actually contain '0' and '1' for this
        // test to exercise the ambiguous-character aliasing at all.
        XCTAssertTrue(body.contains("0"))
        XCTAssertTrue(body.contains("1"))

        var dirtyBody = body
        dirtyBody = dirtyBody.replacingOccurrences(of: "0", with: "O") // Crockford alias for 0
        dirtyBody = dirtyBody.replacingOccurrences(of: "1", with: "I") // Crockford alias for 1
        dirtyBody = dirtyBody.lowercased()
        dirtyBody = dirtyBody.replacingOccurrences(of: "-", with: " - ") // stray spaces around body separators

        // Prefix kept contiguous ("pk3d-") since only its case is part of
        // the sanitization contract — a space wedged inside the prefix
        // itself isn't a case the spec asks to handle.
        let dirty = "  \n\t pk3d-" + dirtyBody + " \n\t  "

        let result = LicenseVerifier.verify(dirty, trustedKeys: trustedKeys)
        guard case .valid(let email, _, _) = result else {
            return XCTFail("expected .valid for sanitized dirty input, got \(result)")
        }
        XCTAssertEqual(email, "dirty@peek3d.app")
    }

    func test_emptyInput_isMalformed() {
        XCTAssertEqual(LicenseVerifier.verify("", trustedKeys: trustedKeys), .malformed)
        XCTAssertEqual(LicenseVerifier.verify("   \n\t  ", trustedKeys: trustedKeys), .malformed)
    }

    // MARK: - Additional edge cases worth locking in

    func test_prefixIsOptionalAndCaseInsensitive() {
        let license = makeLicenseString(email: "prefix@peek3d.app")
        let withoutPrefix = String(license.dropFirst("PK3D-".count))

        XCTAssertEqual(
            LicenseVerifier.verify("pk3d-" + withoutPrefix, trustedKeys: trustedKeys),
            LicenseVerifier.verify(license, trustedKeys: trustedKeys)
        )
    }

    func test_noTrustedKeys_isSignatureInvalid() {
        let license = makeLicenseString()
        XCTAssertEqual(LicenseVerifier.verify(license, trustedKeys: []), .signatureInvalid)
    }

    func test_signatureCheckedBeforeSchemaIsRead_tamperedFutureSchemaStillFailsSignature() {
        // Even a schema-2 buffer must still pass signature verification
        // before anything is trusted — tampering with a schema-2 license
        // must yield .signatureInvalid, not a smuggled-through .validFutureSchema.
        let license = makeLicenseString(schema: 2)
        var chars = Array(license)
        var flipIndex = chars.count - 10
        while chars[flipIndex] == "-" { flipIndex -= 1 }
        chars[flipIndex] = (chars[flipIndex] == "0") ? "1" : "0"
        let tampered = String(chars)

        XCTAssertEqual(LicenseVerifier.verify(tampered, trustedKeys: trustedKeys), .signatureInvalid)
    }

    func test_garbageNonCrockfordCharacters_isMalformed() {
        XCTAssertEqual(LicenseVerifier.verify("PK3D-!!!!!!!!!!", trustedKeys: trustedKeys), .malformed)
    }

    func test_productionTrustedPublicKeys_defaultsEmpty_failsClosed() {
        // Documents the intentional fail-closed placeholder: until a real
        // production key is populated, verification against the default
        // trust store can never succeed.
        XCTAssertTrue(LicenseVerifier.trustedPublicKeys.isEmpty)
        let license = makeLicenseString()
        XCTAssertEqual(LicenseVerifier.verify(license), .signatureInvalid)
    }

    // MARK: - Security guard: the TEST key must never become a trusted key
    //
    // Requested by the pre-release security audit. `TestVectors`'s keypair
    // (used everywhere in this file) is derived from the passphrase
    // "PeekLicenseKit-TEST-KEY-DO-NOT-USE-IN-PRODUCTION", committed in
    // cleartext in TestVectors.swift — anyone with this repository can
    // rederive its PRIVATE half. `LicenseVerifier.trustedPublicKeys` is
    // intentionally empty today with a `TODO(release)` to populate it with
    // the real production key before shipping. If that population ever
    // accidentally includes (or is entirely replaced by) this test key —
    // e.g. copy-pasted from the wrong place, or a placeholder left in by
    // mistake — every Peek3D installation would accept licenses anyone
    // could self-sign for free, indistinguishable from a real purchase.
    //
    // This test is a no-op today (the list is empty, so there's nothing to
    // find) — that's correct and expected. Its entire value is as a
    // tripwire for the day someone populates that list: it must turn red
    // the instant the test key appears there, whether alone or alongside a
    // real key. Verified by sabotage: temporarily setting
    // `trustedPublicKeys = [TestVectors.publicKey]` and confirming this
    // test fails before reverting (see the QA report for this change).
    func test_trustedPublicKeys_neverContainsTheTestKey() {
        let testKeyBytes = TestVectors.publicKey.rawRepresentation
        let productionKeyBytes = LicenseVerifier.trustedPublicKeys.map { $0.rawRepresentation }

        XCTAssertFalse(
            productionKeyBytes.contains(testKeyBytes),
            """
            LicenseVerifier.trustedPublicKeys contains the TEST public key (derived from a passphrase \
            committed in cleartext in TestVectors.swift). Anyone with this repository can derive the \
            matching private key and self-sign unlimited Peek3D licenses. Remove it and populate this \
            list with the real production Ed25519 public key instead.
            """
        )
    }
}
