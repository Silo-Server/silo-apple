import XCTest
@testable import Silo

/// `StartupContentPrefetcher.prefetchFailureReason` is the only genuinely
/// lossy logic in the startup instrumentation: it maps an open-ended `Error`
/// onto a closed vocabulary that a reader groups reports by. Two ways for it
/// to be wrong matter, and neither is visible from a log line:
///
/// 1. A classification that drifts silently makes historical reports
///    incomparable — the token has to mean the same thing in every build.
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
    /// Who's Watching. It must outrank the plain 4xx bucketing below, which is
    /// what these errors would otherwise fall into.
    func testInvalidProfileOutranksTheGenericHTTPBucket() {
        for code in ["profile_unverified", "profile_not_found"] {
            let error = HTTPError.http(statusCode: 403, body: #"{"error":"\#(code)"}"#)
            XCTAssertTrue(StartupContentPrefetcher.indicatesInvalidProfile(error))
            XCTAssertEqual(reason(error), "invalid_profile")
        }

        // Same status, unrelated server code: the generic bucket, not recovery.
        XCTAssertEqual(
            reason(HTTPError.http(statusCode: 403, body: #"{"error":"forbidden"}"#)),
            "unauthorized"
        )
    }

    /// Cancellation is a generation bump (profile switch, sign-out, server
    /// change), not a failure. Both spellings reach this code: the prefetcher's
    /// own `CancellationError` from its generation guards, and URLSession's
    /// `NSURLErrorCancelled` when the transport is torn down first.
    func testBothCancellationSpellingsClassifyAsCancelled() {
        XCTAssertEqual(reason(CancellationError()), "cancelled")
        XCTAssertEqual(
            reason(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)),
            "cancelled"
        )
        XCTAssertEqual(reason(URLError(.cancelled)), "cancelled")
        // A real transport failure from the same domain must not be swallowed
        // as a cancellation.
        XCTAssertEqual(
            reason(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)),
            "network"
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
    /// `URLError.cancelled` from reachability for the same reason.
    func testWrappedCancellationClassifiesAsCancelledNotNetwork() {
        let cancellations: [(label: String, error: Error)] = [
            ("URLError.cancelled", URLError(.cancelled)),
            ("NSURLErrorCancelled", NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)),
            ("CancellationError", CancellationError()),
        ]
        for (label, underlying) in cancellations {
            XCTAssertEqual(
                reason(HTTPError.network(underlying: underlying)),
                "cancelled",
                "wrapped \(label) must not read as a network failure"
            )
        }

        // The wrapper must still classify a genuine transport failure as
        // `network`: the unwrapping is a cancellation carve-out, not a change
        // to what `.network` means.
        for underlying: URLError.Code in [.timedOut, .cannotConnectToHost, .networkConnectionLost] {
            XCTAssertEqual(
                reason(HTTPError.network(underlying: URLError(underlying))),
                "network"
            )
        }
    }

    func testHTTPStatusesBucketByClass() {
        XCTAssertEqual(reason(HTTPError.http(statusCode: 401, body: nil)), "unauthorized")
        XCTAssertEqual(reason(HTTPError.http(statusCode: 403, body: nil)), "unauthorized")
        XCTAssertEqual(reason(HTTPError.http(statusCode: 404, body: nil)), "http_4xx")
        XCTAssertEqual(reason(HTTPError.http(statusCode: 429, body: nil)), "http_4xx")
        XCTAssertEqual(reason(HTTPError.http(statusCode: 500, body: nil)), "server_error")
        XCTAssertEqual(reason(HTTPError.http(statusCode: 503, body: nil)), "server_error")
    }

    func testTypedTransportFailuresKeepTheirOwnTokens() {
        XCTAssertEqual(reason(HTTPError.serverUrlNotConfigured), "no_server")
        XCTAssertEqual(reason(HTTPError.requestIdentityChanged), "identity_changed")
        XCTAssertEqual(
            reason(HTTPError.network(underlying: NSError(domain: "x", code: 1))),
            "network"
        )
        XCTAssertEqual(
            reason(HTTPError.decodingFailed(type: "SectionsResponse", underlying: NSError(domain: "x", code: 1))),
            "decode_failed"
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

    /// Every token this classifier can produce, enumerated. A new branch added
    /// without updating this set is the drift case in (1) above.
    func testVocabularyIsClosed() {
        let allowed: Set<String> = [
            "cancelled",
            "invalid_profile",
            "no_server",
            "identity_changed",
            "network",
            "decode_failed",
            "unauthorized",
            "server_error",
            "http_1xx", "http_2xx", "http_3xx", "http_4xx", "http_5xx",
            "other",
        ]
        let samples: [Error] = [
            CancellationError(),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost),
            NSError(domain: "com.example.other", code: 7),
            HTTPError.serverUrlNotConfigured,
            HTTPError.requestIdentityChanged,
            HTTPError.invalidURL("x"),
            HTTPError.invalidResponse,
            HTTPError.network(underlying: NSError(domain: "x", code: 1)),
            HTTPError.network(underlying: URLError(.cancelled)),
            HTTPError.encodingFailed(underlying: NSError(domain: "x", code: 1)),
            HTTPError.decodingFailed(type: "T", underlying: NSError(domain: "x", code: 1)),
            HTTPError.http(statusCode: 400, body: nil),
            HTTPError.http(statusCode: 401, body: nil),
            HTTPError.http(statusCode: 404, body: #"{"error":"profile_not_found"}"#),
            HTTPError.http(statusCode: 500, body: nil),
        ]
        for sample in samples {
            XCTAssertTrue(
                allowed.contains(reason(sample)),
                "unexpected reason token \(reason(sample))"
            )
        }
    }
}
