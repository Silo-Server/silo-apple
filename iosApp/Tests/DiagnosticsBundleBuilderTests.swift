import XCTest
@testable import Silo

final class DiagnosticsBundleBuilderTests: XCTestCase {
    func testExactTokenScrubReplacesLiveTokensInTextualData() throws {
        let data = Data("access=access-token-123 profile=profile-token-456 access-token-123".utf8)

        let scrubbed = DiagnosticsBundleBuilder.scrubExactTokenMatches(
            in: data,
            tokens: ["access-token-123", "profile-token-456", "access-token-123"]
        )
        let rendered = try XCTUnwrap(String(bytes: scrubbed, encoding: .utf8))

        XCTAssertFalse(rendered.contains("access-token-123"))
        XCTAssertFalse(rendered.contains("profile-token-456"))
        XCTAssertEqual(
            rendered,
            "access=[redacted_token] profile=[redacted_token] [redacted_token]"
        )
    }

    func testExactTokenScrubLeavesBinaryDataUnchanged() {
        let data = Data([0xff, 0xfe, 0xfd, 0x00])

        let scrubbed = DiagnosticsBundleBuilder.scrubExactTokenMatches(
            in: data,
            tokens: ["token"]
        )

        XCTAssertEqual(scrubbed, data)
    }
}
