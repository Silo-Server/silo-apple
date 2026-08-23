import XCTest
@testable import Silo

/// The live AI cue buffer is fed by a translator that does not run in playback
/// lockstep, so its bound must never evict a cue the playhead has not reached.
@MainActor
final class LiveSubtitleCueEvictionTests: XCTestCase {
    private func cue(startMs: Int64, endMs: Int64) -> LiveSubtitleCue {
        LiveSubtitleCue(text: "cue-\(startMs)", startMs: startMs, endMs: endMs)
    }

    func testBufferUnderLimitIsUntouched() {
        let cues = (0..<5).map { cue(startMs: Int64($0) * 1_000, endMs: Int64($0) * 1_000 + 900) }

        let kept = PlayerViewModel.evictingLiveSubtitleCues(cues, position: 0, limit: 8)

        XCTAssertEqual(kept, cues)
    }

    func testEvictsAlreadyPassedCuesBeforeAnythingAtThePlayhead() {
        // 0..<4 are behind the playhead at 10s; 4..<8 are at or ahead of it.
        let cues = (0..<8).map { cue(startMs: Int64($0) * 2_500, endMs: Int64($0) * 2_500 + 2_000) }

        let kept = PlayerViewModel.evictingLiveSubtitleCues(cues, position: 10, limit: 5)

        // Three oldest already-passed cues go; every future cue survives.
        XCTAssertEqual(kept.count, 5)
        XCTAssertEqual(kept.map(\.startMs), [7_500, 10_000, 12_500, 15_000, 17_500])
    }

    func testFutureOnlyBufferDropsFurthestFutureNotNearest() {
        // Fast translator: every cue is ahead of a playhead still at 0.
        let cues = (0..<8).map { cue(startMs: Int64($0) * 1_000, endMs: Int64($0) * 1_000 + 900) }

        let kept = PlayerViewModel.evictingLiveSubtitleCues(cues, position: 0, limit: 5)

        XCTAssertEqual(kept.map(\.startMs), [0, 1_000, 2_000, 3_000, 4_000])
    }

    func testPassedCuesAreEvictedOldestFirstRegardlessOfArrivalOrder() {
        // Out-of-order arrival: the newest-ending passed cue must outlive the
        // oldest-ending one even though it was appended first.
        let cues = [
            cue(startMs: 8_000, endMs: 9_000),
            cue(startMs: 1_000, endMs: 2_000),
            cue(startMs: 20_000, endMs: 21_000),
        ]

        let kept = PlayerViewModel.evictingLiveSubtitleCues(cues, position: 10, limit: 2)

        XCTAssertEqual(kept.map(\.startMs), [8_000, 20_000])
    }
}
