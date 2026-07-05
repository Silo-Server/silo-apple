import XCTest
@testable import Silo

final class PlaybackSourceResponseEndTests: XCTestCase {
    func testShortOpenEndedStreamClassifiesPrematureEOF() {
        // The 2026-06-28 living-room incident shape: open-ended GET over a
        // ~69 GB source, origin stopped producing at ~4.31 GB.
        let cause = PlaybackSourceResponseEnd.classify(
            cursor: 4_312_002_555,
            responseEnd: 69_135_378_484,
            totalLength: 69_135_378_485,
            wasCancelled: false,
            sawEmptyFetch: true,
            sawFetchError: false
        )
        XCTAssertEqual(
            cause,
            .prematureEOF(offset: 4_312_002_555, expectedEnd: 69_135_378_484)
        )
    }

    func testEmptyFetchAtExactTotalIsComplete() {
        // Origin returned empty exactly at the end of the file: cursor sits
        // one past the last byte, so nothing was cut short.
        let cause = PlaybackSourceResponseEnd.classify(
            cursor: 1000,
            responseEnd: 999,
            totalLength: 1000,
            wasCancelled: false,
            sawEmptyFetch: true,
            sawFetchError: false
        )
        XCTAssertEqual(cause, .complete)
    }

    func testNormalRangeCompletionIsComplete() {
        let cause = PlaybackSourceResponseEnd.classify(
            cursor: 512,
            responseEnd: 511,
            totalLength: 4096,
            wasCancelled: false,
            sawEmptyFetch: false,
            sawFetchError: false
        )
        XCTAssertEqual(cause, .complete)
    }

    func testCancellationWinsOverEmptyFetch() {
        let cause = PlaybackSourceResponseEnd.classify(
            cursor: 100,
            responseEnd: 999,
            totalLength: 1000,
            wasCancelled: true,
            sawEmptyFetch: true,
            sawFetchError: false
        )
        XCTAssertEqual(cause, .cancelled)
    }

    func testFetchErrorIsNotPrematureEOF() {
        // Fetch failures already notify through their own interruption path;
        // classification must not double-report them as premature EOF.
        let cause = PlaybackSourceResponseEnd.classify(
            cursor: 100,
            responseEnd: 999,
            totalLength: 1000,
            wasCancelled: false,
            sawEmptyFetch: false,
            sawFetchError: true
        )
        XCTAssertEqual(cause, .fetchFailed)
    }

    func testUnknownLengthCannotProvePremature() {
        // Chunked origin with no Content-Length and an open-ended request:
        // an empty fetch may be a genuine EOF, so stay conservative.
        let cause = PlaybackSourceResponseEnd.classify(
            cursor: 100,
            responseEnd: nil,
            totalLength: nil,
            wasCancelled: false,
            sawEmptyFetch: true,
            sawFetchError: false
        )
        XCTAssertEqual(cause, .complete)
    }

    func testRangePromisingPastRealEOFIsComplete() {
        // An exact range issued while the total was still unknown can
        // promise bytes past the real EOF; reaching the true end must
        // classify as complete once the total is known.
        let cause = PlaybackSourceResponseEnd.classify(
            cursor: 1000,
            responseEnd: 1999,
            totalLength: 1000,
            wasCancelled: false,
            sawEmptyFetch: true,
            sawFetchError: false
        )
        XCTAssertEqual(cause, .complete)
    }

    func testExpectedEndFallsBackToTotalLength() {
        let cause = PlaybackSourceResponseEnd.classify(
            cursor: 100,
            responseEnd: nil,
            totalLength: 1000,
            wasCancelled: false,
            sawEmptyFetch: true,
            sawFetchError: false
        )
        XCTAssertEqual(cause, .prematureEOF(offset: 100, expectedEnd: 999))
    }
}
