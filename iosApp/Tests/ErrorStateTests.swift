import XCTest
@testable import Silo

/// `ErrorState` keeps the status of a v2 failure, so a v2 401 or 404 gets the
/// same headline, actions and retry treatment as the v1 `HTTPError` did. A 403
/// is a permission or policy denial: it never reads as an expired session and
/// never offers sign-in.
final class ErrorStateTests: XCTestCase {
    private func problem(_ status: Int, _ identifier: String, detail: String) -> APIv2Error {
        .problem(APIv2Problem(type: "https://siloserver.org/docs/api/v2/problems/\(identifier)",
            title: identifier, status: status, detail: detail, instance: nil, errors: nil))
    }

    private typealias Plan = ErrorView.RecoveryPlan

    private var unauthorizedMessage: String {
        ErrorState(HTTPError.http(statusCode: 401, body: nil)).message
    }

    func testForbiddenIsNotAnAuthFailureFromAnySource() {
        let sources: [(String, Error)] = [
            ("v1 HTTPError", HTTPError.http(statusCode: 403, body: nil)),
            ("v2 httpStatus", APIv2Error.httpStatus(403)),
            ("v2 permission_denied without detail", problem(403, "permission_denied", detail: "")),
            ("APIError", APIError.httpError(statusCode: 403)),
        ]
        for (source, error) in sources {
            let state = ErrorState(error)
            XCTAssertEqual(state.statusCode, 403, source)
            XCTAssertFalse(state.isAuthFailure, source)
            XCTAssertTrue(state.isForbidden, source)
            XCTAssertFalse(state.isTransient, source)
            XCTAssertNotEqual(state.message, unauthorizedMessage, source)
        }
    }

    func testPermissionDeniedProblemShowsServerDetail() {
        let state = ErrorState(problem(403, "permission_denied", detail: "Downloads are not allowed."))
        XCTAssertEqual(state.message, "Downloads are not allowed.")
    }

    func testForbiddenProblemsWithProtocolDetailUseLocalCopy() {
        let localCopy = ErrorState(APIv2Error.httpStatus(403)).message
        let problems = [
            problem(403, "profile_verification_required",
                detail: "The declared profile is locked; verify it and retry with X-Profile-Token."),
            problem(403, "password_change_required",
                detail: "The account holds a temporary password; change it, then refresh the session."),
        ]
        for error in problems {
            let message = ErrorState(error).message
            XCTAssertEqual(message, localCopy)
            XCTAssertNotEqual(message, unauthorizedMessage)
        }
    }

    func testForbiddenNeverOffersSignIn() {
        let state = ErrorState(APIv2Error.httpStatus(403))
        XCTAssertEqual(ErrorView.recoveryPlan(for: state, canRetry: true, canGoBack: true),
            Plan(primary: .goBack, secondary: [.tryAgain]))
        XCTAssertEqual(ErrorView.recoveryPlan(for: state, canRetry: true, canGoBack: false),
            Plan(primary: .tryAgain, secondary: []))
        XCTAssertEqual(ErrorView.recoveryPlan(for: state, canRetry: false, canGoBack: true),
            Plan(primary: .goBack, secondary: []))
        XCTAssertEqual(ErrorView.recoveryPlan(for: state, canRetry: false, canGoBack: false),
            Plan(primary: nil, secondary: []))

        let unauthorized = ErrorState(APIv2Error.httpStatus(401))
        XCTAssertNotEqual(ErrorView.headline(for: state), ErrorView.headline(for: unauthorized))
    }

    func testUnauthorizedStillOffersSignInAgain() {
        let state = ErrorState(APIv2Error.httpStatus(401))
        XCTAssertEqual(ErrorView.recoveryPlan(for: state, canRetry: true, canGoBack: true),
            Plan(primary: .signInAgain, secondary: [.tryAgain]))
        XCTAssertEqual(ErrorView.recoveryPlan(for: state, canRetry: false, canGoBack: true),
            Plan(primary: .signInAgain, secondary: []))

        let generic = ErrorState(APIv2Error.httpStatus(500))
        XCTAssertNotEqual(ErrorView.headline(for: state), ErrorView.headline(for: generic))
    }

    func testNotFoundAndGenericRecoveryPlansAreUnchanged() {
        let notFound = ErrorState(APIv2Error.httpStatus(404))
        XCTAssertEqual(ErrorView.recoveryPlan(for: notFound, canRetry: true, canGoBack: true),
            Plan(primary: .goBack, secondary: [.tryAgain]))
        XCTAssertEqual(ErrorView.recoveryPlan(for: notFound, canRetry: true, canGoBack: false),
            Plan(primary: .tryAgain, secondary: []))
        XCTAssertEqual(ErrorView.recoveryPlan(for: notFound, canRetry: false, canGoBack: true),
            Plan(primary: .goBack, secondary: []))

        let serverError = ErrorState(APIv2Error.httpStatus(500))
        XCTAssertEqual(ErrorView.recoveryPlan(for: serverError, canRetry: true, canGoBack: true),
            Plan(primary: .tryAgain, secondary: []))
        XCTAssertEqual(ErrorView.recoveryPlan(for: serverError, canRetry: false, canGoBack: true),
            Plan(primary: .goBack, secondary: []))

        let updateRequired = ErrorState(APIv2Error.serverUpdateRequired)
        XCTAssertEqual(ErrorView.recoveryPlan(for: updateRequired, canRetry: true, canGoBack: true),
            Plan(primary: .tryAgain, secondary: []))
        XCTAssertEqual(ErrorView.headline(for: updateRequired), "Update required")
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
