import Foundation
import CryptoKit

/// Turns a file URL into a short, salted, one-way identifier suitable for
/// storing in the Keychain to detect "have we counted this file against the
/// trial before". Never store the raw path — see `LicenseRecord`.
enum FileIdentityHasher {
    /// Not a secret (compiled into the binary, trivially extractable) — its
    /// only job is keeping the stored hash from matching a plain, unsalted
    /// SHA-256 of a common path, not resisting a determined attacker.
    /// Constant across installs so the same file always hashes the same way
    /// for the same user.
    private static let salt = "Peek3D.entitlement.v1."

    /// 16 bytes (32 hex chars) of a SHA-256 digest over the salted,
    /// canonical path — enough that accidental collisions between a real
    /// user's own files are practically impossible, short enough to keep
    /// the stored record small, and non-reversible either way.
    ///
    /// Uses the resolved, standardized path (not the raw `URL` as handed
    /// in) so the same file opened via a symlink, an alias, or a
    /// differently-cased mount point still hashes identically — otherwise a
    /// harmless indirection could look like "a new file" and burn a trial
    /// slot it shouldn't.
    static func hash(for url: URL) -> String {
        let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data((salt + canonicalPath).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
