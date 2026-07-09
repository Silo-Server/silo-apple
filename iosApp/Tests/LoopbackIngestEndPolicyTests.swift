import XCTest
@testable import Silo

final class LoopbackIngestEndPolicyTests: XCTestCase {
    private let avErrorEOF = -Int32(bitPattern: 0x20464F45)
    private let avErrorTimedOut = -Int32(ETIMEDOUT)

    private func classify(
        readResult: Int32? = nil,
        bytePosition: Int64? = nil,
        fileSizeBytes: Int64? = nil,
        reachedPlanSeconds: Double? = nil,
        plannedTotalSeconds: Double? = nil,
        deadlineAborted: Bool = false
    ) -> LoopbackIngestEndPolicy.Verdict {
        LoopbackIngestEndPolicy.classify(
            readResult: readResult ?? avErrorEOF,
            bytePosition: bytePosition,
            fileSizeBytes: fileSizeBytes,
            reachedPlanSeconds: reachedPlanSeconds,
            plannedTotalSeconds: plannedTotalSeconds,
            deadlineAborted: deadlineAborted
        )
    }

    // MARK: - Genuine ends stay clean

    func testEOFAtFileEndIsFinished() {
        XCTAssertEqual(
            classify(bytePosition: 4_000_000_000, fileSizeBytes: 4_000_000_000),
            .finished
        )
    }

    func testEOFWithinByteToleranceIsFinished() {
        // 4 MiB of unread trailing cues/tags on a 4 GB file.
        XCTAssertEqual(
            classify(
                bytePosition: 4_000_000_000 - 4 * 1024 * 1024,
                fileSizeBytes: 4_000_000_000
            ),
            .finished
        )
    }

    func testBytesCompleteOverridesOverstatedContainerDuration() {
        // Bad metadata: header duration overstates the media by minutes,
        // but every byte was consumed — must finalize exactly as before.
        XCTAssertEqual(
            classify(
                bytePosition: 1_000_000_000,
                fileSizeBytes: 1_000_000_000,
                reachedPlanSeconds: 6_800,
                plannedTotalSeconds: 7_200
            ),
            .finished
        )
    }

    func testPlanCompleteOverridesShortBytes() {
        // Plan axis reached its end fence; trailing attachment data beyond
        // the byte tolerance must not turn a finished title into an error.
        XCTAssertEqual(
            classify(
                bytePosition: 900_000_000,
                fileSizeBytes: 1_000_000_000,
                reachedPlanSeconds: 7_195,
                plannedTotalSeconds: 7_200
            ),
            .finished
        )
    }

    func testLastSegmentShortfallWithinPlanToleranceIsFinished() {
        // Genuine EOF sits one segment short of the end fence (reached is
        // the closing segment's start).
        XCTAssertEqual(
            classify(reachedPlanSeconds: 7_196, plannedTotalSeconds: 7_200),
            .finished
        )
    }

    func testNoSignalsPreservesLegacyEOF() {
        XCTAssertEqual(classify(readResult: avErrorTimedOut), .finished)
    }

    func testInterruptExitIsNeverPremature() {
        XCTAssertEqual(
            classify(
                readResult: LoopbackIngestEndPolicy.avErrorExit,
                bytePosition: 100,
                fileSizeBytes: 4_000_000_000,
                reachedPlanSeconds: 10,
                plannedTotalSeconds: 7_200
            ),
            .finished
        )
    }

    // MARK: - Truncations are premature

    func testEOFMidFileIsPremature() {
        // The outage case: proxy truncated the body at the cache edge.
        let verdict = classify(
            bytePosition: 1_600_000_000,
            fileSizeBytes: 4_000_000_000,
            reachedPlanSeconds: 2_500,
            plannedTotalSeconds: 7_200
        )
        XCTAssertEqual(
            verdict,
            .prematureSourceEnd(shortfallBytes: 2_400_000_000, shortfallSeconds: 4_700)
        )
    }

    func testReadErrorMidFileIsPremature() {
        // rw_timeout expiry surfaces as ETIMEDOUT, not EOF.
        let verdict = classify(
            readResult: avErrorTimedOut,
            bytePosition: 1_600_000_000,
            fileSizeBytes: 4_000_000_000
        )
        XCTAssertEqual(
            verdict,
            .prematureSourceEnd(shortfallBytes: 2_400_000_000, shortfallSeconds: nil)
        )
    }

    func testPlanShortfallAloneIsPremature() {
        // Transport never learned a total (no byte signal); the plan axis
        // is clearly short.
        XCTAssertEqual(
            classify(reachedPlanSeconds: 1_200, plannedTotalSeconds: 7_200),
            .prematureSourceEnd(shortfallBytes: nil, shortfallSeconds: 6_000)
        )
    }

    func testDeadlineAbortedExitMidFileIsPremature() {
        // The interrupt token aborted a wedged/outage-exhausted read: the
        // AVERROR_EXIT is a source failure and must classify like any error.
        let verdict = classify(
            readResult: LoopbackIngestEndPolicy.avErrorExit,
            bytePosition: 1_600_000_000,
            fileSizeBytes: 4_000_000_000,
            deadlineAborted: true
        )
        XCTAssertEqual(
            verdict,
            .prematureSourceEnd(shortfallBytes: 2_400_000_000, shortfallSeconds: nil)
        )
    }

    func testDeadlineAbortedExitAtFileEndIsFinished() {
        XCTAssertEqual(
            classify(
                readResult: LoopbackIngestEndPolicy.avErrorExit,
                bytePosition: 4_000_000_000,
                fileSizeBytes: 4_000_000_000,
                deadlineAborted: true
            ),
            .finished
        )
    }

    // MARK: - Tolerance shape

    func testByteToleranceScalesWithLargeFiles() {
        // 2% of 40 GB = 800 MB; a 500 MB shortfall on that file is within
        // tolerance (index/cues territory), not a truncation.
        let fortyGB: Int64 = 40_000_000_000
        XCTAssertEqual(
            classify(bytePosition: fortyGB - 500_000_000, fileSizeBytes: fortyGB),
            .finished
        )
    }

    func testByteToleranceFloorAppliesToSmallFiles() {
        // 2% of 100 MB is 2 MB, but the 8 MiB floor governs small files.
        let hundredMB: Int64 = 100_000_000
        XCTAssertEqual(
            classify(bytePosition: hundredMB - 7 * 1024 * 1024, fileSizeBytes: hundredMB),
            .finished
        )
        XCTAssertEqual(
            classify(bytePosition: hundredMB - 20 * 1024 * 1024, fileSizeBytes: hundredMB),
            .prematureSourceEnd(shortfallBytes: 20 * 1024 * 1024, shortfallSeconds: nil)
        )
    }
}
