import XCTest
@testable import Silo

final class DiagnosticsPIIRedactionTests: XCTestCase {
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

    func testUppercaseURLSchemeAndBracketedIPv6AreRedacted() throws {
        let accessKey = ["access", "token"].joined(separator: "_")
        let apiKey = ["api", "key"].joined(separator: "_")
        let accessValue = UUID().uuidString
        let apiKeyValue = UUID().uuidString
        let uppercase = try rendered("request HTTPS://Media.Example.com/path?\(accessKey)=\(accessValue)")
        XCTAssertFalse(uppercase.localizedCaseInsensitiveContains("media.example.com"))
        XCTAssertFalse(uppercase.contains(accessValue))
        XCTAssertTrue(uppercase.contains("[host:"))

        let ipv6 = try rendered("request https://[2001:db8::1234]/path?\(apiKey)=\(apiKeyValue)")
        XCTAssertFalse(ipv6.contains("2001:db8::1234"))
        XCTAssertFalse(ipv6.contains(apiKeyValue))
        XCTAssertTrue(ipv6.contains("[host:"))
    }

    func testQuotedAndEscapedJSONSecretsAreRedacted() throws {
        let accessKey = ["access", "token"].joined(separator: "_")
        let apiKey = ["api", "key"].joined(separator: "_")
        let refreshKey = ["refresh", "token"].joined(separator: "_")
        let userKey = ["user", "name"].joined(separator: "")
        let mailKey = ["e", "mail"].joined()
        let accessValue = UUID().uuidString
        let apiKeyValue = UUID().uuidString
        let usernameValue = UUID().uuidString + "\"" + UUID().uuidString
        let refreshValue = UUID().uuidString
        let emailValue = "\(UUID().uuidString)@example.org"
        let rawPayload = try JSONSerialization.data(withJSONObject: [
            accessKey: accessValue,
            apiKey: apiKeyValue,
            userKey: usernameValue,
        ])
        let rawBody = try XCTUnwrap(String(data: rawPayload, encoding: .utf8))
        let rawJSON = try rendered("body=\(rawBody)")
        XCTAssertFalse(rawJSON.contains(accessValue))
        XCTAssertFalse(rawJSON.contains(apiKeyValue))
        XCTAssertFalse(rawJSON.contains(usernameValue))

        let escapedPayload = try JSONSerialization.data(withJSONObject: [
            refreshKey: refreshValue,
            mailKey: emailValue,
        ])
        let escapedBody = try XCTUnwrap(String(data: escapedPayload, encoding: .utf8))
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedJSON = try rendered("error body=\(escapedBody)")
        XCTAssertFalse(escapedJSON.contains(refreshValue))
        XCTAssertFalse(escapedJSON.contains(emailValue))
    }

    func testHTTPErrorDescriptionNeverContainsURLOrResponseBody() throws {
        let invalidURL = String(describing: HTTPError.invalidURL("https://private.example/api"))
        XCTAssertEqual(invalidURL, "invalid_url")

        let accessKey = ["access", "token"].joined(separator: "_")
        let mailKey = ["e", "mail"].joined()
        let accessValue = UUID().uuidString
        let emailValue = "\(UUID().uuidString)@example.org"
        let payload = try JSONSerialization.data(withJSONObject: [
            accessKey: accessValue,
            mailKey: emailValue,
        ])
        let body = try XCTUnwrap(String(data: payload, encoding: .utf8))
        let response = HTTPError.http(statusCode: 401, body: body)
        XCTAssertEqual(String(describing: response), "http_error(status: 401)")

        let line = try XCTUnwrap(DiagLog.renderedLine(
            level: .error,
            category: .playback,
            tag: "HTTP",
            message: "request failed",
            attrs: ["reason": .error(response)]
        ))
        XCTAssertFalse(line.contains(accessValue))
        XCTAssertFalse(line.contains(emailValue))
    }
}
