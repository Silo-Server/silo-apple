import XCTest
import Nuke
@testable import Silo

final class ArtworkRetryPolicyTests: XCTestCase {
    func testTransportFailuresBackOffThenStop() {
        let error = loadingFailed(URLError(.networkConnectionLost))
        let delays = (1...4).map { ArtworkRetryPolicy.delay(afterFailure: error, failedAttempts: $0) }
        XCTAssertEqual(delays, [.seconds(2), .seconds(5), .seconds(15), nil])
    }

    func testTransientStatusesRetry() {
        for status in [408, 500, 502, 503, 504] {
            XCTAssertTrue(ArtworkRetryPolicy.isRetryable(loadingFailed(DataLoader.Error.statusCodeUnacceptable(status))), "\(status)")
        }
    }

    func testAuthMissingAndRateLimitedStatusesNeverRetry() {
        // 404 is also what the server returns for an expired signature.
        for status in [401, 403, 404, 429] {
            let error = loadingFailed(DataLoader.Error.statusCodeUnacceptable(status))
            XCTAssertNil(ArtworkRetryPolicy.delay(afterFailure: error, failedAttempts: 1), "\(status)")
        }
    }

    func testCancellationAndNonNetworkFailuresNeverRetry() {
        XCTAssertFalse(ArtworkRetryPolicy.isRetryable(ImagePipeline.Error.cancelled))
        XCTAssertFalse(ArtworkRetryPolicy.isRetryable(ImagePipeline.Error.imageRequestMissing))
        XCTAssertFalse(ArtworkRetryPolicy.isRetryable(ImagePipeline.Error.dataIsEmpty))
        XCTAssertFalse(ArtworkRetryPolicy.isRetryable(loadingFailed(URLError(.cancelled))))
        XCTAssertFalse(ArtworkRetryPolicy.isRetryable(loadingFailed(URLError(.badURL))))
        XCTAssertFalse(ArtworkRetryPolicy.isRetryable(URLError(.timedOut)), "unwrapped errors do not come from a load")
    }

    func testActivationRetriesOnlyARetryableFailureWhileLoadingIsAllowed() {
        let transient = loadingFailed(URLError(.timedOut))
        XCTAssertTrue(ArtworkRetryPolicy.retriesOnActivation(after: transient, loadingEnabled: true))
        XCTAssertFalse(ArtworkRetryPolicy.retriesOnActivation(after: transient, loadingEnabled: false))
        XCTAssertFalse(ArtworkRetryPolicy.retriesOnActivation(after: nil, loadingEnabled: true))
        XCTAssertFalse(ArtworkRetryPolicy.retriesOnActivation(
            after: loadingFailed(DataLoader.Error.statusCodeUnacceptable(404)),
            loadingEnabled: true
        ))
    }

    private func loadingFailed(_ error: Error) -> Error {
        ImagePipeline.Error.dataLoadingFailed(error: error)
    }
}
