import XCTest
@testable import Silo

/// Which rejected person refresh dispatches still leave the person page's
/// read-only poll running. Viewing a person queues a provider refresh when one
/// is due, so only answers that rule that out end the poll.
final class PersonMetadataRefreshPolicyTests: XCTestCase {
    private func problem(_ status: Int, _ code: String) -> APIv2Error {
        .problem(APIv2Problem(type: "https://siloserver.org/problems/\(code)", title: code,
            status: status, detail: "", instance: nil, errors: nil))
    }

    func testRateLimitAndTransientServerErrorsKeepPolling() {
        for error in [problem(429, "rate_limited"), problem(500, "internal_error"),
                      .httpStatus(502), .httpStatus(200), .incompleteCatalogRead] {
            XCTAssertTrue(PersonDetailViewModel.pollsAfterRejectedRefresh(error), "\(error)")
        }
    }

    func testAnswersThatRuleOutAQueuedRefreshEndThePoll() {
        for error in [problem(404, "not_found"), problem(503, "capability_not_configured"),
                      problem(401, "unauthorized"), problem(403, "forbidden"),
                      problem(422, "validation_failed"), problem(410, "client_upgrade_required"),
                      .httpStatus(401), .serverUpdateRequired, .invalidCatalogQuery] {
            XCTAssertFalse(PersonDetailViewModel.pollsAfterRejectedRefresh(error), "\(error)")
        }
    }
}
