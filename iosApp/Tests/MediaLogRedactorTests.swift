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

    func testRedactsCustomCredentialHeadersWithoutDroppingLaterTelemetry() {
        let source = #"headers=["X-Profile-Token": "profile-secret", "X-Silo-Auth": "auth-secret", "X_Profile_Token": "underscore-secret"] frames=42 rate=1.000"#
        let redacted = MediaLogRedactor.sanitize(source)

        XCTAssertFalse(redacted.contains("profile-secret"))
        XCTAssertFalse(redacted.contains("auth-secret"))
        XCTAssertFalse(redacted.contains("underscore-secret"))
        XCTAssertTrue(redacted.contains("frames=42"))
        XCTAssertTrue(redacted.contains("rate=1.000"))
    }

    func testRedactsSpacedPathsAndBareMediaNamesWithoutDroppingTelemetry() {
        let source = #"cache="/var/mobile/Containers/Data/Downloads/Show Name S01E01.mkv" sidecar=Movie Title (2024).en.srt retries=3"#
        let redacted = MediaLogRedactor.sanitize(source)

        for secret in ["Show Name", "S01E01", "Movie Title", "2024", ".mkv", ".srt"] {
            XCTAssertFalse(redacted.contains(secret))
        }
        XCTAssertTrue(redacted.contains("retries=3"))
    }

    func testAetherDiagnosticsHandlerMasksMediaIdentityAndCredentialsBeforeSink() throws {
        let source = "[AetherEngine] load url=https://private.example/items/movie.mkv?st=signed-secret "
            + #"headers=["X-Profile-Token": "profile-secret"]"#
        var captured: String?
        let handler = AetherDiagnosticsBridge.makeHandler { captured = $0 }

        handler(source)
        let redacted = try XCTUnwrap(captured)

        for secret in ["private.example", "movie.mkv", "signed-secret", "profile-secret"] {
            XCTAssertFalse(redacted.contains(secret))
        }
        XCTAssertTrue(redacted.contains("[AetherEngine] load"))
    }

    func testBoundsUntrustedErrorText() {
        XCTAssertLessThanOrEqual(
            MediaLogRedactor.sanitize(String(repeating: "x", count: 10_000), maxLength: 128).count,
            128
        )
        XCTAssertEqual(MediaLogRedactor.sanitize("secret", maxLength: 2).count, 2)
    }

    func testPreboundsPathologicalInputBeforeRegexRedaction() {
        let source = String(repeating: "a", count: 100_000)
            + " token=secret-that-must-not-reach-output"

        XCTAssertLessThanOrEqual(MediaLogRedactor.sanitize(source).count, 1_024)
    }
}
