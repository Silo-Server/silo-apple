import XCTest
@testable import Silo

/// The shared two-tier verbosity predicate every instrumented subsystem
/// (playback, focus, network, lifecycle) routes through.
///
/// `DiagnosticsReviewFixesTests.testCMPLogCaptureRequiresDiagnosticsGateAndVerboseOptIn`
/// still covers the player's `shouldCaptureCMPLog` spelling; these cases pin the
/// generalized helper it now delegates to, including the deliberate difference
/// between the two destinations' gating.
final class DiagTraceTests: XCTestCase {
    func testRingCaptureRequiresBothTheCaptureGateAndTheVerboseOptIn() {
        // Verbatim the historical cmpLog truth table:
        // captureEnabled && (!verbose || debugLoggingEnabled).
        XCTAssertFalse(DiagTrace.shouldCapture(.essential, debugLoggingEnabled: false, captureEnabled: false))
        XCTAssertFalse(DiagTrace.shouldCapture(.essential, debugLoggingEnabled: true, captureEnabled: false))
        XCTAssertFalse(DiagTrace.shouldCapture(.verbose, debugLoggingEnabled: false, captureEnabled: false))
        XCTAssertFalse(DiagTrace.shouldCapture(.verbose, debugLoggingEnabled: true, captureEnabled: false))

        XCTAssertTrue(DiagTrace.shouldCapture(.essential, debugLoggingEnabled: false, captureEnabled: true))
        XCTAssertTrue(DiagTrace.shouldCapture(.essential, debugLoggingEnabled: true, captureEnabled: true))
        XCTAssertFalse(DiagTrace.shouldCapture(.verbose, debugLoggingEnabled: false, captureEnabled: true))
        XCTAssertTrue(DiagTrace.shouldCapture(.verbose, debugLoggingEnabled: true, captureEnabled: true))
    }

    func testTierPredicateIgnoresTheCaptureGate() {
        // The breadcrumb journal applies consent itself inside
        // appendRenderedLine — and purges the journal when capture is off.
        // Pre-checking capture here would skip that purge, so this predicate is
        // deliberately the verbosity half only. Do not "unify" it with
        // shouldCapture.
        XCTAssertTrue(DiagTrace.isTierEnabled(.essential, debugLoggingEnabled: false))
        XCTAssertTrue(DiagTrace.isTierEnabled(.essential, debugLoggingEnabled: true))
        XCTAssertFalse(DiagTrace.isTierEnabled(.verbose, debugLoggingEnabled: false))
        XCTAssertTrue(DiagTrace.isTierEnabled(.verbose, debugLoggingEnabled: true))
    }

    func testPlayerHelperDelegatesToTheSharedPredicate() {
        // PlayerLog kept its own spelling; it must stay a pure alias so the
        // player and every new subsystem make the same decision.
        for verbose in [false, true] {
            for debugLoggingEnabled in [false, true] {
                for captureEnabled in [false, true] {
                    XCTAssertEqual(
                        shouldCaptureCMPLog(
                            verbose: verbose,
                            debugLoggingEnabled: debugLoggingEnabled,
                            captureEnabled: captureEnabled
                        ),
                        DiagTrace.shouldCapture(
                            verbose ? .verbose : .essential,
                            debugLoggingEnabled: debugLoggingEnabled,
                            captureEnabled: captureEnabled
                        ),
                        "verbose=\(verbose) debug=\(debugLoggingEnabled) capture=\(captureEnabled)"
                    )
                }
            }
        }
    }

    func testSuppressedVerboseLineDoesNotEvaluateItsMessage() {
        // Verbose call sites are high-frequency by definition; the autoclosure
        // is what keeps a disabled tier free, so its laziness is behavior.
        var evaluations = 0
        func expensiveMessage() -> String {
            evaluations += 1
            return "trace"
        }

        DiagTrace.log(
            .verbose,
            category: .playback,
            tag: "Test",
            message: expensiveMessage()
        )

        // Read the live gate rather than assuming it: whether capture is on
        // depends on process-wide consent state another test may have set up.
        // Either way the message is built exactly when the line is recorded.
        let expected = DiagTrace.shouldCapture(.verbose) ? 1 : 0
        XCTAssertEqual(evaluations, expected)
    }
}
