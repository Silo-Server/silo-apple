import Foundation
import XCTest
@testable import Silo

/// `ServerNeedsSetupMessage.forError` decides what "Check again" on the
/// needs-setup screen says when the re-check fails. A v1-only verdict must
/// name the update, not blame connectivity.
final class ServerNeedsSetupMessageTests: XCTestCase {
    private static let unreachable = "Couldn't reach the server."

    func testServerUpdateRequiredShowsUpdateMessage() {
        let message = ServerNeedsSetupMessage.forError(
            APIv2Error.serverUpdateRequired,
            unreachable: Self.unreachable
        )
        XCTAssertEqual(message, APIv2Error.serverUpdateRequiredMessage)
    }

    func testTransportErrorShowsGenericMessage() {
        let message = ServerNeedsSetupMessage.forError(
            URLError(.notConnectedToInternet),
            unreachable: Self.unreachable
        )
        XCTAssertEqual(message, Self.unreachable)
    }

    func testOtherAPIv2ErrorShowsGenericMessage() {
        let message = ServerNeedsSetupMessage.forError(
            APIv2Error.httpStatus(503),
            unreachable: Self.unreachable
        )
        XCTAssertEqual(message, Self.unreachable)
    }
}
