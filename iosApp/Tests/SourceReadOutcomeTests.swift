import XCTest
@testable import Silo

final class SourceReadOutcomeTests: XCTestCase {

    func testEOFFinalizes() {
        XCTAssertEqual(SourceReadOutcome.classify(SourceReadOutcome.avErrorEOF), .endOfInput)
        // Pin the raw bit pattern: FFERRTAG('E','O','F',' ') — a wrong
        // constant here reintroduces silent truncation.
        XCTAssertEqual(SourceReadOutcome.avErrorEOF, -0x20464F45)
    }

    func testEAGAINRetries() {
        XCTAssertEqual(SourceReadOutcome.classify(-Int32(EAGAIN)), .retry)
    }

    func testInterruptAbortIsCancelled() {
        XCTAssertEqual(SourceReadOutcome.classify(SourceReadOutcome.avErrorExit), .cancelled)
        XCTAssertEqual(SourceReadOutcome.avErrorExit, -0x54495845)
    }

    func testNetworkAndGenericErrorsFail() {
        // The silent-truncation bug: every one of these used to finalize
        // the playlist as a complete VOD.
        XCTAssertEqual(SourceReadOutcome.classify(-Int32(EIO)), .failure)
        XCTAssertEqual(SourceReadOutcome.classify(-Int32(ETIMEDOUT)), .failure)
        XCTAssertEqual(SourceReadOutcome.classify(-Int32(ECONNRESET)), .failure)
        XCTAssertEqual(SourceReadOutcome.classify(-Int32(EPIPE)), .failure)
        // AVERROR_INVALIDDATA
        XCTAssertEqual(SourceReadOutcome.classify(Int32(-1094995529)), .failure)
        // AVERROR_HTTP_SERVER_ERROR (5xx)
        XCTAssertEqual(SourceReadOutcome.classify(-Int32(bitPattern: 0x35303554)), .failure)
        XCTAssertEqual(SourceReadOutcome.classify(-1), .failure)
    }
}
