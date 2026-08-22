import XCTest
@testable import Silo

final class MediaLogRedactorTests: XCTestCase {
    func testRedactsRemoteAndLocalMediaIdentityWithoutDroppingMetrics() {
        let source = "load url=https://media.example/stream?id=4&st=secret-token "
            + "fallback=file:///private/var/mobile/movie.mkv rate=1.000 frames=42"
        let redacted = MediaLogRedactor.sanitize(source)

        XCTAssertFalse(redacted.contains("media.example"))
        XCTAssertFalse(redacted.contains("secret-token"))
        XCTAssertFalse(redacted.contains("movie.mkv"))
        XCTAssertTrue(redacted.contains("rate=1.000"))
        XCTAssertTrue(redacted.contains("frames=42"))
    }

    func testRedactsHeadersBareTokensAndFilesystemPaths() {
        let source = "Authorization: Bearer header-secret, Cookie=session=cookie-secret "
            + "token=plain-secret path=/Users/person/Movies/title.mkv"
        let redacted = MediaLogRedactor.sanitize(source)

        for secret in ["header-secret", "cookie-secret", "plain-secret", "person", "title.mkv"] {
            XCTAssertFalse(redacted.contains(secret))
        }
    }

    func testBoundsUntrustedErrorText() {
        XCTAssertLessThanOrEqual(
            MediaLogRedactor.sanitize(String(repeating: "x", count: 10_000), maxLength: 128).count,
            128
        )
    }
}
