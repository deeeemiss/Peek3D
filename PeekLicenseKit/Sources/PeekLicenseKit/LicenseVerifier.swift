import Foundation
import CryptoKit

/// Outcome of verifying a Peek3D license key string. Five distinct cases,
/// not a Bool, because each becomes a different message and a different
/// suggested action in the UI (e.g. `.validFutureSchema` means "your license
/// is real, update the app"; `.signatureInvalid` means "this key is fake or
/// corrupted").
public enum LicenseVerificationResult: Equatable {
    /// Signature verified, schema known, product matches Peek3D. Payload
    /// fields are decoded and ready to use.
    case valid(email: String, issuedAt: Date, polarKey: String)

    /// Signature verified against a trusted key, but `schema_version` is
    /// newer than this build understands. The license is authentic — an app
    /// update is what's needed, not a new key.
    case validFutureSchema

    /// Signature verified, schema known, but `product_id` doesn't match
    /// Peek3D. Authentic key, wrong product.
    case validWrongProduct

    /// Decoded successfully and long enough to contain a signature, but the
    /// signature doesn't match any trusted public key.
    case signatureInvalid

    /// Not even decodable as Crockford Base32, or too short to contain a
    /// signature at all (fewer than 65 bytes).
    case malformed
}

/// Verifies Peek3D license keys against the binary format shared with the
/// license-signing side. This type only verifies — it never signs, persists,
/// or fetches anything over the network.
///
/// Binary payload layout (schema_version 1), all multi-byte integers
/// big-endian:
///
/// ```
/// offset  size  field
/// 0       1     schema_version   u8, currently 1
/// 1       1     product_id       u8, 1 for Peek3D
/// 2       4     issued_at        u32, unix seconds
/// 6       1     polar_key_len    u8
/// 7       n     polar_key        UTF-8
/// 7+n     1     email_len        u8
/// 8+n     m     email            UTF-8
/// last    64    signature        Ed25519 over every byte before it
/// ```
///
/// The signature is always the last 64 bytes, regardless of schema, so a key
/// issued by a future schema version stays *verifiable* (authenticity can
/// still be checked) even when this build can't *interpret* its fields.
public enum LicenseVerifier {

    // MARK: - Trusted keys

    /// Public keys trusted to have signed a genuine Peek3D license. A public
    /// key is not a secret — Ed25519 public keys can only verify signatures,
    /// never produce them — so there's nothing to hide or obfuscate here.
    ///
    /// This is an array, not a single key, so the signing key can be rotated
    /// in the future (e.g. after a suspected compromise) without invalidating
    /// licenses already sold under a previous key: verification accepts a
    /// match against *any* key in this set.
    ///
    /// Populated 2026-09-05 with the production key. Its private half exists
    /// in exactly two places — the `LICENSE_ED25519_PRIVATE_KEY` secret of
    /// the `peek3d-licensing` Cloudflare Worker, and a password manager —
    /// and never in this repository.
    public static let trustedPublicKeys: [Curve25519.Signing.PublicKey] = [
        "4a6a650d397fab8a2b6c3932093a657aee7c3427ca461b8a276e6dcdd4423b09",
    ].compactMap(publicKey(fromHex:))

    /// Decodes a 32-byte hex string into an Ed25519 public key, returning nil
    /// instead of trapping. A typo in the constant above therefore yields an
    /// *empty* trust store — fail-closed, no license verifies — rather than a
    /// crash on every launch. That silent breakage is caught in CI by
    /// `test_productionTrustedPublicKeys_pinsTheProductionKey`, which is
    /// where it should be caught, not by a user.
    private static func publicKey(fromHex hex: String) -> Curve25519.Signing.PublicKey? {
        guard hex.count == 64 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: Data(bytes))
    }

    // MARK: - Format constants

    private static let currentSchemaVersion: UInt8 = 1
    private static let peek3DProductID: UInt8 = 1
    private static let signatureLength = 64
    private static let minimumPayloadLength = 65 // at least 1 byte before the 64-byte signature
    private static let licensePrefix = "PK3D-"

    // MARK: - Public API

    /// Verifies a pasted/typed license string. `trustedKeys` defaults to the
    /// production `trustedPublicKeys` constant; tests inject their own set so
    /// test fixtures never need to touch (or be mistaken for) the production
    /// trust store.
    public static func verify(
        _ rawInput: String,
        trustedKeys: [Curve25519.Signing.PublicKey] = trustedPublicKeys
    ) -> LicenseVerificationResult {
        // 1. Decode. Never read a single field from a buffer we haven't
        //    authenticated yet.
        guard let payload = decodePayload(rawInput) else {
            return .malformed
        }

        // 2. Minimum length: at least one payload byte plus a full signature.
        guard payload.count >= minimumPayloadLength else {
            return .malformed
        }

        // 3. Split off the signature — always the last 64 bytes.
        let signedRange = payload.startIndex..<(payload.endIndex - signatureLength)
        let signatureRange = (payload.endIndex - signatureLength)..<payload.endIndex
        let signedBytes = payload[signedRange]
        let signature = payload[signatureRange]

        // 4. Verify against the trusted key set. Accept if any key matches.
        let signatureIsTrusted = trustedKeys.contains { key in
            key.isValidSignature(signature, for: signedBytes)
        }
        guard signatureIsTrusted else {
            return .signatureInvalid
        }

        // 5. Only now, with an authenticated buffer, read schema_version.
        let bytes = [UInt8](signedBytes)
        let schemaVersion = bytes[0]

        // 6. Unknown-newer schema: authentic, but not interpretable here.
        guard schemaVersion <= currentSchemaVersion else {
            return .validFutureSchema
        }

        // 7. Only schema_version 1 has a known layout. A signed buffer
        //    claiming an older-than-baseline version (0) never legitimately
        //    exists — treat it the same as any other structural mismatch.
        guard schemaVersion == currentSchemaVersion else {
            return .malformed
        }

        // 8. Interpret schema 1 fields, bounds-checking every offset before
        //    reading it.
        guard bytes.count >= 7 else { return .malformed } // schema+product+issuedAt+polarKeyLen
        let productID = bytes[1]
        let issuedAtRaw = UInt32(bytes[2]) << 24 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 8 | UInt32(bytes[5])
        let polarKeyLen = Int(bytes[6])

        let polarKeyStart = 7
        let polarKeyEnd = polarKeyStart + polarKeyLen
        guard bytes.count >= polarKeyEnd + 1 else { return .malformed } // + email_len byte
        let emailLenIndex = polarKeyEnd
        let emailLen = Int(bytes[emailLenIndex])

        let emailStart = emailLenIndex + 1
        let emailEnd = emailStart + emailLen
        guard bytes.count == emailEnd else { return .malformed } // exact length, no trailing junk

        guard let polarKey = String(bytes: bytes[polarKeyStart..<polarKeyEnd], encoding: .utf8) else {
            return .malformed
        }
        guard let email = String(bytes: bytes[emailStart..<emailEnd], encoding: .utf8) else {
            return .malformed
        }

        // 9. Product check comes last, after the buffer is fully validated
        //    and parsed.
        guard productID == peek3DProductID else {
            return .validWrongProduct
        }

        let issuedAt = Date(timeIntervalSince1970: TimeInterval(issuedAtRaw))
        return .valid(email: email, issuedAt: issuedAt, polarKey: polarKey)
    }

    // MARK: - Sanitization

    /// Applies the required sanitization order, then Crockford-decodes:
    /// trim edge whitespace/newlines -> strip a case-insensitive "PK3D-"
    /// prefix -> strip all internal hyphens and spaces -> uppercase ->
    /// decode.
    static func decodePayload(_ rawInput: String) -> Data? {
        var working = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)

        if let prefixRange = working.range(
            of: licensePrefix,
            options: [.caseInsensitive, .anchored]
        ) {
            working.removeSubrange(prefixRange)
        }

        working = working.replacingOccurrences(of: "-", with: "")
        working = working.replacingOccurrences(of: " ", with: "")
        working = working.uppercased()

        return Crockford32.decode(working)
    }
}
