import Foundation
import XCTest
@testable import Silo

/// The one classifier every v2 write lane uses to decide whether a failed
/// mutation reached the server.
final class APIv2MutationOutcomeTests: XCTestCase {
    func testAnswersAreDefiniteExceptAnUnexpectedSuccess() {
        let problem = APIv2Problem(type: "https://silo.example/problems/validation_failed", title: "Invalid",
            status: 422, detail: "", instance: nil, errors: nil)
        XCTAssertEqual(APIv2MutationOutcome(APIv2Error.problem(problem)), .definite)
        XCTAssertEqual(APIv2MutationOutcome(APIv2Error.httpStatus(500)), .definite)
        XCTAssertEqual(APIv2MutationOutcome(APIv2Error.httpStatus(404)), .definite)
        XCTAssertEqual(APIv2MutationOutcome(APIv2Error.serverUpdateRequired), .definite)
        XCTAssertEqual(APIv2MutationOutcome(APIv2Error.httpStatus(200)), .uncertain)
        XCTAssertEqual(APIv2MutationOutcome(APIv2Error.httpStatus(204)), .uncertain)
        XCTAssertEqual(APIv2MutationOutcome(APIv2Error.unexpectedSettingReceipt), .uncertain)
    }

    func testTransportFailuresUseOneNeverSentList() {
        for code in [URLError.Code.notConnectedToInternet, .cannotConnectToHost, .badURL, .unsupportedURL,
                     .secureConnectionFailed] {
            XCTAssertEqual(APIv2MutationOutcome(URLError(code)), .notSent, "\(code)")
            XCTAssertEqual(APIv2MutationOutcome(HTTPError.network(underlying: URLError(code))), .notSent, "\(code)")
        }
        for code in [URLError.Code.timedOut, .networkConnectionLost, .cancelled] {
            XCTAssertEqual(APIv2MutationOutcome(HTTPError.network(underlying: URLError(code))), .uncertain, "\(code)")
        }
        XCTAssertEqual(APIv2MutationOutcome(HTTPError.serverUrlNotConfigured), .notSent)
        XCTAssertEqual(APIv2MutationOutcome(HTTPError.invalidURL("x")), .notSent)
        XCTAssertEqual(APIv2MutationOutcome(HTTPError.invalidResponse), .uncertain)
        XCTAssertEqual(APIv2MutationOutcome(CancellationError()), .uncertain)
    }

    func testOwnerChangesSplitOnTheDispatchRecord() {
        XCTAssertEqual(APIv2MutationOutcome(APIv2OwnerChangedBeforeDispatch()), .ownerChanged(beforeDispatch: true))
        for error in [HTTPError.requestIdentityChanged, HTTPError.authorityChanged] {
            XCTAssertEqual(APIv2MutationOutcome(error, dispatched: false), .ownerChanged(beforeDispatch: true))
            XCTAssertEqual(APIv2MutationOutcome(error, dispatched: true), .ownerChanged(beforeDispatch: false))
            XCTAssertEqual(APIv2MutationOutcome(error), .ownerChanged(beforeDispatch: false),
                           "without a record the answer may have been discarded")
        }
        XCTAssertFalse(APIv2MutationOutcome.ownerChanged(beforeDispatch: true).mayHaveApplied)
        XCTAssertTrue(APIv2MutationOutcome.ownerChanged(beforeDispatch: false).mayHaveApplied)
        XCTAssertTrue(APIv2MutationOutcome.uncertain.mayHaveApplied)
        XCTAssertFalse(APIv2MutationOutcome.definite.mayHaveApplied)
        XCTAssertFalse(APIv2MutationOutcome.notSent.mayHaveApplied)
    }
}
