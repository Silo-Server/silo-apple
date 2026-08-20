import XCTest
@testable import Silo

/// `StartupContentPrefetcher.prefetchFailureReason` is the only genuinely
/// lossy logic in the startup instrumentation: it maps an open-ended `Error`
/// onto the closed vocabulary a reader groups reports by. Two ways for it to be
/// wrong matter, and neither is visible from a log line:
///
/// 1. A classification that drifts silently makes historical reports
///    incomparable — the token has to mean the same thing in every build, and
///    the same thing as the `network.error_code` the same failure produced one
///    line earlier.
/// 2. A fall-through that leaks the error's own text would put server-authored
///    strings into `reason`, which the emission contract does not allow.
///
/// These cases pin both. They do not assert that any line was emitted.
@MainActor
final class StartupPrefetchFailureReasonTests: XCTestCase {
    private func reason(_ error: Error) -> String {
        StartupContentPrefetcher.prefetchFailureReason(error)
    }

    /// The one classification that already drives recovery
    /// (`recoverFromInvalidProfile`), and the reason a launch can bounce to
    /// Who's Watching. It must outrank the generic status arm below, which is
    /// what these errors would otherwise fall into.
    func testInvalidProfileOutranksTheGenericHTTPBucket() {
        for code in ["profile_unverified", "profile_not_found"] {
            let error = HTTPError.http(statusCode: 403, body: #"{"error":"\#(code)"}"#)
            XCTAssertTrue(StartupContentPrefetcher.indicatesInvalidProfile(error))
            XCTAssertEqual(reason(error), "invalid_profile")
        }

        // Same status, unrelated server code: the shared status token, not
        // recovery.
        XCTAssertEqual(
            reason(HTTPError.http(statusCode: 403, body: #"{"error":"forbidden"}"#)),
            HTTPDiagnosticsErrorCode.http(status: 403)
        )
    }

    /// Cancellation is a generation bump (profile switch, sign-out, server
    /// change), not a failure. Every spelling reaches this code, which is why
    /// `HTTPError.indicatesCancellation` is the single owner of the rule.
    func testEveryCancellationSpellingClassifiesAsCancelled() {
        XCTAssertEqual(reason(CancellationError()), HTTPDiagnosticsOutcome.cancelled)
        XCTAssertEqual(
            reason(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)),
            HTTPDiagnosticsOutcome.cancelled
        )
        XCTAssertEqual(reason(URLError(.cancelled)), HTTPDiagnosticsOutcome.cancelled)
        // A real transport failure from the same domain must not be swallowed
        // as a cancellation.
        XCTAssertEqual(
            reason(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)),
            HTTPDiagnosticsErrorCode.classify(transport: URLError(.timedOut))
        )
    }

    /// The shape that actually reaches a prefetch in production, and the one
    /// that regressed: `HTTPClient.perform` rethrows *every* transport error as
    /// `HTTPError.network(underlying:)`, so a cancellation arrives wrapped and
    /// the outer case alone cannot distinguish "we cancelled this" from "the
    /// network failed". Classifying the wrapper without unwrapping turns every
    /// routine server or profile switch into a warning-level connectivity
    /// failure in the report — phantom evidence in the exact instrumentation
    /// meant to diagnose real connectivity problems.
    ///
    /// This mirrors `HTTPClient.noteServerUnreachable`, which excludes
    /// cancellation from reachability for the same reason.
    func testWrappedCancellationClassifiesAsCancelledNotTransportFailure() {
        let cancellations: [(label: String, error: Error)] = [
            ("URLError.cancelled", URLError(.cancelled)),
            ("NSURLErrorCancelled", NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)),
            ("CancellationError", CancellationError()),
        ]
        for (label, underlying) in cancellations {
            XCTAssertEqual(
                reason(HTTPError.network(underlying: underlying)),
                HTTPDiagnosticsOutcome.cancelled,
                "wrapped \(label) must not read as a transport failure"
            )
        }
    }

    /// The point of the delegation: the lifecycle line's `reason` and the
    /// network line's `error_code` describe one failure with one token, so a
    /// report can be grouped by cause across the two categories.
    func testTransportDecodeAndStatusArmsUseTheSharedVocabulary() {
        for code: URLError.Code in [.timedOut, .cannotConnectToHost, .networkConnectionLost] {
            XCTAssertEqual(
                reason(HTTPError.network(underlying: URLError(code))),
                HTTPDiagnosticsErrorCode.classify(transport: URLError(code))
            )
        }
        // A non-`URLError` payload still classifies, without its text.
        XCTAssertEqual(
            reason(HTTPError.network(underlying: NSError(domain: "x", code: 1))),
            HTTPDiagnosticsErrorCode.classify(transport: NSError(domain: "x", code: 1))
        )

        let decodingError = DecodingError.valueNotFound(
            Int.self,
            DecodingError.Context(codingPath: [], debugDescription: "missing")
        )
        XCTAssertEqual(
            reason(HTTPError.decodingFailed(type: "SectionsResponse", underlying: decodingError)),
            HTTPDiagnosticsErrorCode.classify(decoding: decodingError)
        )

        for status in [401, 404, 429, 500, 503] {
            XCTAssertEqual(
                reason(HTTPError.http(statusCode: status, body: nil)),
                HTTPDiagnosticsErrorCode.http(status: status)
            )
        }

        XCTAssertEqual(reason(HTTPError.requestIdentityChanged), HTTPDiagnosticsOutcome.identityChanged)
    }

    /// The two tokens that stay local, because neither vocabulary has a
    /// counterpart: a launch with no server configured never reached the
    /// transport at all, and an invalid profile is a recovery trigger rather
    /// than a transport classification.
    func testPrefetchSpecificTokensStayLocal() {
        XCTAssertEqual(reason(HTTPError.serverUrlNotConfigured), "no_server")
        XCTAssertEqual(
            reason(HTTPError.http(statusCode: 403, body: #"{"error":"profile_not_found"}"#)),
            "invalid_profile"
        )
    }

    /// The contract this file exists to protect: an unrecognized error yields a
    /// fixed token, never any part of the error's own text. A body echoed into
    /// `reason` is exactly the leak the registry's closed vocabulary prevents.
    func testUnrecognizedErrorsCollapseToAFixedTokenWithoutEchoingTheError() {
        struct SecretBearingError: LocalizedError {
            var errorDescription: String? { "user alice@example.com token=abc123 rejected" }
        }
        XCTAssertEqual(reason(SecretBearingError()), "other")
        XCTAssertEqual(reason(HTTPError.invalidResponse), "other")
        XCTAssertEqual(reason(HTTPError.invalidURL("https://example.invalid")), "other")
        XCTAssertEqual(
            reason(HTTPError.encodingFailed(underlying: NSError(domain: "x", code: 1))),
            "other"
        )
    }

    /// Every token this classifier can produce has to survive the hosted
    /// collector's text scan, since `reason` is a string attribute value: a
    /// token matching `PRIVATE_ID_IN_TEXT` (`request_…`, `session_…`, …) is not
    /// a bad log line, it is the user's whole report discarded.
    func testEveryProducibleTokenIsCollectorSafe() {
        let samples: [Error] = [
            CancellationError(),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost),
            NSError(domain: NSURLErrorDomain, code: -99_999),
            NSError(domain: "com.example.other", code: 7),
            HTTPError.serverUrlNotConfigured,
            HTTPError.requestIdentityChanged,
            HTTPError.invalidURL("x"),
            HTTPError.invalidResponse,
            HTTPError.network(underlying: NSError(domain: "x", code: 1)),
            HTTPError.network(underlying: URLError(.cancelled)),
            HTTPError.network(underlying: URLError(.secureConnectionFailed)),
            HTTPError.encodingFailed(underlying: NSError(domain: "x", code: 1)),
            HTTPError.decodingFailed(type: "T", underlying: NSError(domain: "x", code: 1)),
            HTTPError.http(statusCode: 400, body: nil),
            HTTPError.http(statusCode: 401, body: nil),
            HTTPError.http(statusCode: 404, body: #"{"error":"profile_not_found"}"#),
            HTTPError.http(statusCode: 500, body: nil),
        ]
        for sample in samples {
            CollectorPrivacyOracle.assertMessageAccepted(reason(sample))
        }
    }
}
