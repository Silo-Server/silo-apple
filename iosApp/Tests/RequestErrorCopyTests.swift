import XCTest
@testable import Silo

final class RequestErrorCopyTests: XCTestCase {
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

    func testNonHTTPErrorFallsBackToErrorState() {
        struct Boom: Error {}
        XCTAssertFalse(RequestErrorCopy.message(for: Boom()).isEmpty)
    }
}
