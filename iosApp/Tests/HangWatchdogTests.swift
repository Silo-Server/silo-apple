import XCTest
@testable import Silo

/// The watchdog's timing rules: when a blocked main thread counts as a hang,
/// and why a suspended process never does.
final class HangWatchdogTests: XCTestCase {
    func testPromptAnswerIsNotAHang() {
        var detector = HangDetector()
        XCTAssertEqual(detector.tick(at: 0), .sendPing)
        XCTAssertEqual(detector.pong(sentAt: 0, at: 0.01), .none)
        XCTAssertEqual(detector.tick(at: 0.5), .sendPing)
    }

    func testBlockShorterThanTheThresholdIsNotReported() {
        var detector = HangDetector()
        XCTAssertEqual(detector.tick(at: 0), .sendPing)
        XCTAssertEqual(detector.tick(at: 0.5), .none)
        XCTAssertEqual(detector.tick(at: 1.0), .none)
        XCTAssertEqual(detector.tick(at: 1.5), .none)
        XCTAssertEqual(detector.pong(sentAt: 0, at: 1.9), .none)
    }

    func testOngoingHangIsRecordedThenReportedWhenItEnds() {
        var detector = HangDetector()
        XCTAssertEqual(detector.tick(at: 10), .sendPing)
        for time in stride(from: 10.5, through: 11.5, by: 0.5) {
            XCTAssertEqual(detector.tick(at: time), .none)
        }
        XCTAssertEqual(detector.tick(at: 12), .hangOngoing(startedAt: 10, duration: 2))
        XCTAssertEqual(detector.tick(at: 12.5), .hangOngoing(startedAt: 10, duration: 2.5))
        XCTAssertEqual(detector.pong(sentAt: 10, at: 12.75), .hangEnded(startedAt: 10, duration: 2.75))
        XCTAssertEqual(detector.tick(at: 13), .sendPing)
    }

    /// The watchdog's own timer stopping is a suspended process (background,
    /// device sleep), not a blocked main thread.
    func testGapBetweenTicksDiscardsTheMeasurement() {
        var detector = HangDetector()
        XCTAssertEqual(detector.tick(at: 0), .sendPing)
        XCTAssertEqual(detector.tick(at: 30), .none)
        XCTAssertNil(detector.pingSentAt)
        // The ping sent before the suspension is answered late; it is stale.
        XCTAssertEqual(detector.pong(sentAt: 0, at: 30.1), .none)
        XCTAssertEqual(detector.tick(at: 30.5), .sendPing)
    }

    func testSuspensionDuringARecordedHangDiscardsIt() {
        var detector = HangDetector()
        _ = detector.tick(at: 0)
        for time in stride(from: 0.5, through: 2.5, by: 0.5) {
            _ = detector.tick(at: time)
        }
        XCTAssertEqual(detector.tick(at: 60), .hangDiscarded)
    }

    /// After a resume the main thread can answer before the watchdog ticks
    /// again; the answer alone must not turn the suspension into a hang.
    func testLateAnswerWithoutRecentTickIsNotAHang() {
        var detector = HangDetector()
        XCTAssertEqual(detector.tick(at: 0), .sendPing)
        XCTAssertEqual(detector.pong(sentAt: 0, at: 20), .none)
        XCTAssertEqual(detector.tick(at: 20.2), .none)
        XCTAssertEqual(detector.tick(at: 20.7), .sendPing)
    }

    func testAnswerToAnOlderPingIsIgnored() {
        var detector = HangDetector()
        XCTAssertEqual(detector.tick(at: 0), .sendPing)
        XCTAssertEqual(detector.pong(sentAt: -5, at: 0.1), .none)
        XCTAssertEqual(detector.pingSentAt, 0)
    }

    func testHangAttributesAreRegisteredLifecycleKeys() throws {
        let line = try XCTUnwrap(DiagLog.renderedLine(
            level: .warning,
            category: .lifecycle,
            tag: "MainThreadHang",
            message: "main thread did not respond",
            attrs: HangWatchdog.hangAttributes(duration: 3.25, residentMB: 412)
        ))
        XCTAssertTrue(line.contains(#""duration_ms":3250"#))
        XCTAssertTrue(line.contains(#""resident_mb":412"#))
        XCTAssertNotNil(HangWatchdog.residentMB())
    }

    func testWatchdogHangSummary() {
        XCTAssertEqual(
            DiagnosticsCoordinator.watchdogHangSummary(duration: 3.4, residentMB: 412),
            "Silo did not respond for 3.4 s, using 412 MB of memory"
        )
        XCTAssertEqual(
            DiagnosticsCoordinator.watchdogHangSummary(duration: 2, residentMB: nil),
            "Silo did not respond for 2.0 s"
        )
    }
}
