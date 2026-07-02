import XCTest
@testable import Silo

final class RequestErrorCopyTests: XCTestCase {
    func testKnownTokens() {
        XCTAssertEqual(RequestErrorCopy.message(forToken: "already_requested"), "Already requested")
        XCTAssertEqual(RequestErrorCopy.message(forToken: "already_available"), "Already in your library")
        XCTAssertEqual(RequestErrorCopy.message(forToken: "quota_exceeded"), "Request limit reached")
        XCTAssertEqual(RequestErrorCopy.message(forToken: "requests_disabled"), "Requests are turned off")
        XCTAssertEqual(RequestErrorCopy.message(forToken: "requesting_blocked"), "You can't request media right now")
        XCTAssertEqual(RequestErrorCopy.message(forToken: "validation_failed"), "That request couldn't be submitted")
    }

    func testUnknownTokenHumanizes() {
        // A newly-added server reason must never render as a raw token or
        // a blank chip.
        XCTAssertEqual(RequestErrorCopy.message(forToken: "waiting_for_release"), "Waiting For Release")
        XCTAssertEqual(RequestErrorCopy.message(forToken: "some-dash-reason"), "Some Dash Reason")
    }

    func testBlankTokenIsNil() {
        XCTAssertNil(RequestErrorCopy.message(forToken: nil))
        XCTAssertNil(RequestErrorCopy.message(forToken: ""))
    }

    func testHTTPErrorPrefersServerToken() {
        let body = #"{"error":"quota_exceeded","message":"limit hit"}"#
        let error = HTTPError.http(statusCode: 429, body: body)
        XCTAssertEqual(RequestErrorCopy.message(for: error), "Request limit reached")
    }

    func testNonHTTPErrorFallsBackToErrorState() {
        struct Boom: Error {}
        XCTAssertFalse(RequestErrorCopy.message(for: Boom()).isEmpty)
    }
}
