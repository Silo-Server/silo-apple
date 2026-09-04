import XCTest
@testable import Silo

final class MediaLogRedactorTests: XCTestCase {
    /// Every line the leak audit found, plus the cases already pinned below.
    /// Shared so the idempotency property covers exactly what the rules claim.
    private static let auditedSamples: [String] = [
        "load url=https://media.example/stream?id=4&st=secret-token "
            + "fallback=file:///private/var/mobile/movie.mkv rate=1.000 frames=42",
        "Authorization: Bearer header-secret, Cookie=session=cookie-secret "
            + "token=plain-secret path=/Users/person/Movies/title.mkv",
        #"headers=["X-Profile-Token": "profile-secret", "X-Silo-Auth": "auth-secret"] frames=42"#,
        #"cache="/var/mobile/Containers/Data/Downloads/Show Name S01E01.mkv" sidecar=Movie Title (2024).en.srt retries=3"#,
        "Authorization: Bearer abc",
        "token=short",
        "headers X-Emby-Token 9f83ba21c0de44aa77b1 device=tvos",
        "origin silo.example.com:8096/Videos/abc/Movie.Name.2019.mkv?k=1",
        "origin 192.168.1.42:8096/Videos/abc/Movie.mkv",
        "origin [2001:db8::1]:8096/Videos/abc/Movie.mkv",
        #"path=\\media-nas\Movies\Show Name S01E01.mkv"#,
        "cache ~/Documents/Silo/Show Name S02E03.mkv loaded",
        "cache /Library/Caches/com.silo/Downloads/title.mkv loaded",
        "playing [redacted-url] Movie.mkv",
        "hls ready url=master.m3u8 seq=4",
        "session started successfully after 3 retries",
        "refresh accessToken=aaa.bbb.ccc done",
    ]

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

    // MARK: - Audited leaks

    /// Jellyfin-compatible clients send `X-Emby-Token` with a space, not `:`,
    /// so the key/value rules never saw it.
    func testRedactsSpaceDelimitedCredentialHeaders() {
        let redacted = MediaLogRedactor.sanitize("headers X-Emby-Token 9f83ba21c0de44aa77b1 device=tvos")

        XCTAssertFalse(redacted.contains("9f83ba21c0de44aa77b1"))
        XCTAssertTrue(redacted.contains("[redacted]"))
        XCTAssertTrue(redacted.contains("device=tvos"))
    }

    /// Prose that merely follows a credential-shaped word is not a credential;
    /// redacting it would cost telemetry without buying privacy.
    func testSpaceDelimitedRuleLeavesOrdinaryProseIntact() {
        let redacted = MediaLogRedactor.sanitize("session started successfully after 3 retries")
        XCTAssertEqual(redacted, "session started successfully after 3 retries")
    }

    func testRedactsSchemeLessOriginsWithPaths() {
        let host = MediaLogRedactor.sanitize("origin silo.example.com:8096/Videos/abc/Movie.Name.2019.mkv?k=1")
        XCTAssertFalse(host.contains("silo.example.com"))
        XCTAssertFalse(host.contains("Movie.Name.2019"))

        let ipv4 = MediaLogRedactor.sanitize("origin 192.168.1.42:8096/Videos/abc/Movie.mkv")
        XCTAssertFalse(ipv4.contains("192.168.1.42"))
        XCTAssertFalse(ipv4.contains("Movie.mkv"))

        let ipv6 = MediaLogRedactor.sanitize("origin [2001:db8::1]:8096/Videos/abc/Movie.mkv")
        XCTAssertFalse(ipv6.contains("2001:db8"))
        XCTAssertFalse(ipv6.contains("Movie.mkv"))
    }

    /// A bare `File.swift:42` source reference is not an origin; requiring a
    /// path after the port is what keeps the scheme-less rule from eating it.
    func testSchemeLessOriginRuleLeavesSourceReferencesIntact() {
        let redacted = MediaLogRedactor.sanitize("DiagLog.swift:42 assertion rate=1.000")
        XCTAssertEqual(redacted, "DiagLog.swift:42 assertion rate=1.000")
    }

    func testRedactsCachesAndTildeHomePaths() {
        let caches = MediaLogRedactor.sanitize("cache /Library/Caches/com.silo/Downloads/title.mkv loaded")
        XCTAssertFalse(caches.contains("title.mkv"))
        XCTAssertFalse(caches.contains("/Library/Caches"))
        XCTAssertTrue(caches.contains("loaded"))

        let home = MediaLogRedactor.sanitize("cache ~/Documents/Silo/Show Name S02E03.mkv loaded")
        XCTAssertFalse(home.contains("Show Name"))
        XCTAssertFalse(home.contains("S02E03"))
        XCTAssertFalse(home.contains("~/Documents"))
        XCTAssertTrue(home.contains("loaded"))
    }

    func testRedactsUNCSharesIncludingServerAndShareName() {
        let redacted = MediaLogRedactor.sanitize(#"path=\\media-nas\Movies\Show Name S01E01.mkv"#)

        for secret in ["media-nas", "Movies", "Show Name", "S01E01"] {
            XCTAssertFalse(redacted.contains(secret))
        }
        XCTAssertTrue(redacted.contains("[redacted-path]"))
    }

    /// The media-name rule used to start at the first word of the line and run
    /// through an already-inserted marker, collapsing everything.
    func testMediaNameRuleReplacesOnlyTheFilenameToken() {
        let redacted = MediaLogRedactor.sanitize("playing [redacted-url] Movie.mkv")

        XCTAssertEqual(redacted, "playing [redacted-url] [redacted-media-name]")
    }

    /// `master.m3u8` names a manifest position, not a title. A user-chosen name
    /// that merely begins with the same word still goes.
    func testGenericManifestNamesSurviveButUserTitlesDoNot() {
        let manifest = MediaLogRedactor.sanitize("hls ready url=master.m3u8 seq=4")
        XCTAssertTrue(manifest.contains("master.m3u8"))
        XCTAssertTrue(manifest.contains("seq=4"))

        let title = MediaLogRedactor.sanitize("master copy of movie.mkv")
        XCTAssertFalse(title.contains("movie.mkv"))
    }

    /// Redaction is a projection: applying it twice must change nothing.
    func testSanitizeIsIdempotent() {
        for source in Self.auditedSamples {
            let once = MediaLogRedactor.sanitize(source)
            let twice = MediaLogRedactor.sanitize(once)
            XCTAssertEqual(once, twice, "not idempotent for: \(source)")
        }
    }

    /// Rules 2 and 9 used to re-match rule 1's own output, so a single pass
    /// over `Authorization: Bearer abc` already yielded `[redacted]]]` — one
    /// stray bracket per rule that re-consumed the marker.
    func testRedactionMarkerDoesNotAccreteBrackets() {
        let header = MediaLogRedactor.sanitize("Authorization: Bearer abc")
        XCTAssertEqual(header, "Authorization: [redacted]")

        let query = MediaLogRedactor.sanitize("open url?token=abc123, retries=1")
        XCTAssertEqual(query, "open url?token=[redacted], retries=1")
    }

    func testAetherDiagnosticsHandlerMasksMediaIdentityAndCredentialsBeforeSink() throws {
        let source = "[AetherEngine] load url=https://private.example/items/movie.mkv?st=signed-secret "
            + #"headers=["X-Profile-Token": "profile-secret"]"#
        var captured: String?
        let handler = AetherDiagnosticsBridge.makeHandler { captured = $0() }

        handler(source)
        let redacted = try XCTUnwrap(captured)

        for secret in ["private.example", "movie.mkv", "signed-secret", "profile-secret"] {
            XCTAssertFalse(redacted.contains(secret))
        }
        XCTAssertTrue(redacted.contains("[AetherEngine] load"))
    }

    /// Aether emits verbose host lines continuously and `DiagTrace`'s capture
    /// gate drops nearly all of them. The sink therefore receives a provider,
    /// not a string, so a suppressed line never pays for the regex sweep. A
    /// revert to an eager `(String) -> Void` sink stops compiling here.
    func testAetherDiagnosticsHandlerHandsTheSinkADeferredProvider() {
        var invocations = 0
        var redacted: String?
        let handler = AetherDiagnosticsBridge.makeHandler { provider in
            invocations += 1
            // A gated sink simply never calls `provider`; no regex sweep runs.
            redacted = provider()
        }

        handler("[AetherEngine] load url=https://private.example/items/movie.mkv")

        XCTAssertEqual(invocations, 1)
        XCTAssertEqual(redacted?.contains("private.example"), false)
        XCTAssertEqual(redacted?.contains("movie.mkv"), false)
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
