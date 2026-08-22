import XCTest
@testable import Silo

/// Redaction is asserted through `DiagLog.renderedLine`, the same path every
/// captured log line takes before it reaches the ring.
final class DiagnosticsRedactionTests: XCTestCase {
    // The sensitive-host registry is process-wide static state. Reset it around
    // every test so a host registered in one test (e.g. the pathological "host"
    // regression below) can't leak into another and mangle its expected tokens.
    override func setUp() {
        super.setUp()
        DiagLog.resetSensitiveHostsForTesting()
    }

    override func tearDown() {
        DiagLog.resetSensitiveHostsForTesting()
        super.tearDown()
    }

    private func rendered(_ message: String) throws -> String {
        try XCTUnwrap(
            DiagLog.renderedLine(level: .info, category: .other, tag: "Test", message: message)
        )
    }

    func testHTTPSURLHostIsHashedAndQueryDropped() throws {
        let line = try rendered("HTTP 404 GET https://media.example.com/api/v1/settings/card_overlays?probe=1")
        XCTAssertFalse(line.contains("media.example.com"))
        XCTAssertFalse(line.contains("probe=1"))
        XCTAssertTrue(line.contains("[host:"))
        XCTAssertTrue(line.contains("/api/v1/settings/card_overlays"))
    }

    func testWebSocketURLHostIsHashed() throws {
        let line = try rendered(#"loop failed UserInfo={NSErrorFailingURLStringKey=wss://media.example.com/api/v1/playback/sessions/abc/realtime}"#)
        XCTAssertFalse(line.contains("media.example.com"))
        XCTAssertTrue(line.contains("wss://[host:"))
    }

    func testLoopbackURLStaysLiteral() throws {
        let line = try rendered("local playlist ready http://127.0.0.1/master.m3u8")
        XCTAssertTrue(line.contains("http://127.0.0.1/master.m3u8"))
    }

    func testEmailIsRedacted() throws {
        let line = try rendered("signup failed for person@example.org retrying")
        XCTAssertFalse(line.contains("person@example.org"))
        XCTAssertTrue(line.contains("[redacted_email]"))
    }

    func testUsernameKeyValueIsRedacted() throws {
        let equalsLine = try rendered("login rejected username=admin2 attempts=3")
        XCTAssertFalse(equalsLine.contains("admin2"))
        XCTAssertTrue(equalsLine.contains("username=[redacted]"))

        let colonLine = try rendered("login: someperson failed")
        XCTAssertFalse(colonLine.contains("someperson"))
    }

    func testRegisteredBareHostnameIsHashed() throws {
        DiagLog.registerSensitiveHost("bare-host.example.net")
        let line = try rendered("reachability probe for bare-host.example.net timed out")
        XCTAssertFalse(line.contains("bare-host.example.net"))
        XCTAssertTrue(line.contains("[host:"))
    }

    // Regression: a registered host that is a substring of its own replacement
    // token — "host" hashes to "[host:…]", which itself contains "host" — must
    // not spin forever re-matching the freshly inserted token. Rendering
    // completes (a hang here would time out the suite) and the bare "host"
    // occurrence is tokenized exactly once.
    func testRegisteredHostThatIsSubstringOfItsTokenTerminates() throws {
        DiagLog.registerSensitiveHost("host")
        let line = try rendered("connect to host failed")
        XCTAssertTrue(line.contains("[host:"))
        // No literal bare " host " word survives outside the token; the only
        // "host" left is the token's own "[host:" prefix.
        XCTAssertFalse(line.contains("to host failed"))
    }

    func testBearerTokenStaysRedacted() throws {
        let line = try rendered("request sent Authorization: Bearer abcdefghijklmnop")
        XCTAssertFalse(line.contains("abcdefghijklmnop"))
    }

    // Mirrors HTTPClient.attachAuthHeaders' public debug string, which OSLog
    // harvesting can pull into logs.jsonl:
    //   → GET /path headers=[auth(…suffix), profileId=..., profileToken(…suffix), device=...]
    func testHTTPClientDebugHeaderProfileAndTokensAreRedacted() throws {
        let line = try rendered(
            "→ GET /api/v1/library headers=[auth(…9f8e7d), profileId=prof-abc-123, profileToken(…a1b2c3), device=tvos]"
        )
        // Token suffixes wrapped in parentheses are redacted.
        XCTAssertFalse(line.contains("9f8e7d"))
        XCTAssertFalse(line.contains("a1b2c3"))
        XCTAssertTrue(line.contains("auth(…[redacted])"))
        XCTAssertTrue(line.contains("profileToken(…[redacted])"))
        // The camelCase profile id key=value is redacted.
        XCTAssertFalse(line.contains("prof-abc-123"))
        XCTAssertTrue(line.contains("profileId=[redacted]"))
        // Non-secret header fields stay intact.
        XCTAssertTrue(line.contains("device=tvos"))
    }

    // Hashing the host left the rest of the URL verbatim, so a stream request
    // shipped the item id and the title's filename into every captured line.
    func testURLPathMediaNameAndItemIdentifierAreRedacted() throws {
        let line = try rendered(
            "stream open https://media.example.com/Videos/9f83ba21c0de44aa77b1c0de44aa77b1/Movie.Name.2019.mkv?k=1"
        )
        XCTAssertFalse(line.contains("media.example.com"))
        XCTAssertFalse(line.contains("Movie.Name.2019"))
        XCTAssertFalse(line.contains(".mkv"))
        XCTAssertFalse(line.contains("9f83ba21c0de44aa77b1c0de44aa77b1"))
        // The endpoint shape survives so the line still says what was called.
        XCTAssertTrue(line.contains("/Videos/"))
        XCTAssertTrue(line.contains("[redacted_media_name]"))
        XCTAssertTrue(line.contains("[redacted_id]"))
    }

    func testURLPathAPIVocabularyIsNotMistakenForAnIdentifier() throws {
        let line = try rendered("HTTP 200 GET https://media.example.com/api/v1/settings/card_overlays")
        XCTAssertTrue(line.contains("/api/v1/settings/card_overlays"))
    }

    // Every DiagTrace, breadcrumb, and early-boot line goes through this layer,
    // which had no filesystem-path or media-filename rule of its own.
    func testFilesystemPathsAndBareMediaNamesAreRedacted() throws {
        let path = try rendered("download finished /Users/person/Movies/Show Name S01E01.mkv ok")
        XCTAssertFalse(path.contains("person"))
        XCTAssertFalse(path.contains("Show Name"))
        XCTAssertTrue(path.contains("ok"))

        let bare = try rendered("sidecar attached Movie Title (2024).en.srt count=2")
        XCTAssertFalse(bare.contains("Movie Title"))
        XCTAssertFalse(bare.contains("2024"))
        XCTAssertTrue(bare.contains("count=2"))
    }

    func testCamelCaseTokenKeyValuesAreRedacted() throws {
        let line = try rendered("refresh accessToken=aaa.bbb.ccc refreshToken: ddd-eee-fff done")
        XCTAssertFalse(line.contains("aaa.bbb.ccc"))
        XCTAssertFalse(line.contains("ddd-eee-fff"))
        XCTAssertTrue(line.contains("accessToken=[redacted]"))
        XCTAssertTrue(line.contains("refreshToken=[redacted]"))
    }
}
