import XCTest
@testable import Silo

/// Redaction is asserted through `DiagLog.renderedLine`, the same path every
/// captured log line takes before it reaches the ring.
final class DiagnosticsRedactionTests: XCTestCase {
    private func rendered(_ message: String) -> String {
        DiagLog.renderedLine(level: .info, category: .other, tag: "Test", message: message) ?? ""
    }

    func testHTTPSURLHostIsHashedAndQueryDropped() {
        let line = rendered("HTTP 404 GET https://media.example.com/api/v1/settings/card_overlays?probe=1")
        XCTAssertFalse(line.contains("media.example.com"))
        XCTAssertFalse(line.contains("probe=1"))
        XCTAssertTrue(line.contains("[host:"))
        XCTAssertTrue(line.contains("/api/v1/settings/card_overlays"))
    }

    func testWebSocketURLHostIsHashed() {
        let line = rendered(#"loop failed UserInfo={NSErrorFailingURLStringKey=wss://media.example.com/api/v1/playback/sessions/abc/realtime}"#)
        XCTAssertFalse(line.contains("media.example.com"))
        XCTAssertTrue(line.contains("wss://[host:"))
    }

    func testLoopbackURLStaysLiteral() {
        let line = rendered("local playlist ready http://127.0.0.1/master.m3u8")
        XCTAssertTrue(line.contains("http://127.0.0.1/master.m3u8"))
    }

    func testEmailIsRedacted() {
        let line = rendered("signup failed for person@example.org retrying")
        XCTAssertFalse(line.contains("person@example.org"))
        XCTAssertTrue(line.contains("[redacted_email]"))
    }

    func testUsernameKeyValueIsRedacted() {
        let equalsLine = rendered("login rejected username=admin2 attempts=3")
        XCTAssertFalse(equalsLine.contains("admin2"))
        XCTAssertTrue(equalsLine.contains("username=[redacted]"))

        let colonLine = rendered("login: someperson failed")
        XCTAssertFalse(colonLine.contains("someperson"))
    }

    func testRegisteredBareHostnameIsHashed() {
        DiagLog.registerSensitiveHost("bare-host.example.net")
        let line = rendered("reachability probe for bare-host.example.net timed out")
        XCTAssertFalse(line.contains("bare-host.example.net"))
        XCTAssertTrue(line.contains("[host:"))
    }

    func testBearerTokenStaysRedacted() {
        let line = rendered("request sent Authorization: Bearer abcdefghijklmnop")
        XCTAssertFalse(line.contains("abcdefghijklmnop"))
    }
}
