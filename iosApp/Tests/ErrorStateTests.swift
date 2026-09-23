import XCTest
@testable import Silo

/// `ErrorState` keeps the status of a v2 failure, so a v2 401 or 404 gets the
/// same headline, actions and retry treatment as the v1 `HTTPError` did.
final class ErrorStateTests: XCTestCase {
    private func problem(_ status: Int, _ identifier: String, detail: String) -> APIv2Error {
        .problem(APIv2Problem(type: "https://siloserver.org/docs/api/v2/problems/\(identifier)",
            title: identifier, status: status, detail: detail, instance: nil, errors: nil))
    }

    func testV2UnauthorizedProblemIsAnAuthFailureNotATransientError() {
        let state = ErrorState(problem(401, "unauthorized", detail: "Token expired."))
        XCTAssertEqual(state.statusCode, 401)
        XCTAssertTrue(state.isAuthFailure)
        XCTAssertFalse(state.isTransient)
        XCTAssertEqual(state.message, ErrorState(HTTPError.http(statusCode: 401, body: nil)).message)
    }

    func testV2NotFoundStatusIsNotFound() {
        let state = ErrorState(APIv2Error.httpStatus(404))
        XCTAssertEqual(state.statusCode, 404)
        XCTAssertTrue(state.isNotFound)
        XCTAssertFalse(state.isTransient)

        let problemState = ErrorState(problem(404, "not_found", detail: "Profile not found."))
        XCTAssertTrue(problemState.isNotFound)
        XCTAssertFalse(problemState.isTransient)
    }

    func testV2ServerErrorStaysTransient() {
        XCTAssertTrue(ErrorState(APIv2Error.httpStatus(503)).isTransient)
        let state = ErrorState(problem(500, "internal_error", detail: "Scanner unavailable."))
        XCTAssertTrue(state.isTransient)
        XCTAssertEqual(state.message, "Scanner unavailable.")
    }

    func testV2UpgradeProblemKeepsItsStatus() {
        let state = ErrorState(problem(410, UpdateRequirement.clientUpgradeRequiredProblem, detail: "Upgrade."))
        XCTAssertEqual(state.updateRequirement, .app)
        XCTAssertEqual(state.statusCode, 410)
        XCTAssertEqual(state.message, UpdateRequirement.appMessage)
        XCTAssertFalse(state.isTransient)
    }
}
