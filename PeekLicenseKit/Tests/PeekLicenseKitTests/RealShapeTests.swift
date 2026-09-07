import XCTest
import CryptoKit
@testable import PeekLicenseKit

/// A license carrying data shaped like the real thing: a 30-character email
/// and the 43-character Polar key format actually issued in production
/// (`PEEK3D-` + a UUID in dashed uppercase), rather than the shorter
/// placeholders used in the hand-written vectors. Signed with the same test
/// keypair, by the worker's own signing code.
final class RealShapeTests: XCTestCase {
    private static let signedByWorker =
        "PK3D-REDACTED"

    func test_productionShapedLicense_roundTripsWithFullPolarKey() {
        let result = LicenseVerifier.verify(Self.signedByWorker, trustedKeys: [TestVectors.publicKey])

        guard case .valid(let email, _, let polarKey) = result else {
            return XCTFail("expected .valid, got \(result)")
        }
        XCTAssertEqual(email, "56798846+deeeemiss@users.noreply.github.com")
        // The whole point: the Polar key must survive intact, not truncated.
        XCTAssertEqual(polarKey, "PEEK3D-19B144F1-4950-45B6-B8A4-6ED4F5B0501F")
        XCTAssertEqual(polarKey.count, 43)
    }
}
