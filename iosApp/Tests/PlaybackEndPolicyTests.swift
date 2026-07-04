import XCTest
@testable import Silo

final class PlaybackEndPolicyTests: XCTestCase {

    private func inputs(
        eof: Bool = true,
        observed: Double = 100,
        duration: Double = 100,
        audioPackets: Int = 0,
        videoPackets: Int = 0,
        decodedFrames: Int = 0,
        audioChunks: Int = 0
    ) -> PlaybackEndPolicy.Inputs {
        .init(
            reachedInputEOF: eof,
            observedSeconds: observed,
            durationSeconds: duration,
            audioPacketsQueued: audioPackets,
            videoPacketsQueued: videoPackets,
            decodedVideoFramesQueued: decodedFrames,
            audioChunksQueued: audioChunks
        )
    }

    func testNoInputEOFNeverCompletes() {
        XCTAssertFalse(PlaybackEndPolicy.shouldComplete(inputs(eof: false, observed: 100, duration: 100)))
    }

    func testDrainedPipelineCompletes() {
        XCTAssertTrue(PlaybackEndPolicy.shouldComplete(inputs(observed: 42, duration: 100)))
    }

    func testDrainedPipelineCompletesWithUnknownDuration() {
        XCTAssertTrue(PlaybackEndPolicy.shouldComplete(inputs(observed: 42, duration: 0)))
        XCTAssertTrue(PlaybackEndPolicy.shouldComplete(inputs(observed: 42, duration: .nan)))
    }

    func testQueuedTailBlocksCompletionNearTheEnd() {
        // The truncation case the old clock-only rule got wrong: input EOF,
        // clock within half a second of duration, but audio still queued.
        XCTAssertFalse(PlaybackEndPolicy.shouldComplete(
            inputs(observed: 99.6, duration: 100, audioChunks: 3)
        ))
        XCTAssertFalse(PlaybackEndPolicy.shouldComplete(
            inputs(observed: 99.6, duration: 100, audioPackets: 2)
        ))
        XCTAssertFalse(PlaybackEndPolicy.shouldComplete(
            inputs(observed: 99.6, duration: 100, decodedFrames: 1)
        ))
        XCTAssertFalse(PlaybackEndPolicy.shouldComplete(
            inputs(observed: 99.6, duration: 100, videoPackets: 1)
        ))
    }

    func testUnknownDurationWaitsForDrain() {
        // The old rule completed immediately on unknown duration even with
        // a full pipeline.
        XCTAssertFalse(PlaybackEndPolicy.shouldComplete(
            inputs(observed: 42, duration: 0, videoPackets: 100, audioChunks: 8)
        ))
    }

    func testClockPastDurationCompletesDespiteWedgedDrain() {
        XCTAssertTrue(PlaybackEndPolicy.shouldComplete(
            inputs(observed: 100.0, duration: 100, decodedFrames: 1)
        ))
        XCTAssertTrue(PlaybackEndPolicy.shouldComplete(
            inputs(observed: 103.2, duration: 100, audioChunks: 1)
        ))
    }

    func testClockBeforeDurationWithQueuedDataDoesNotComplete() {
        XCTAssertFalse(PlaybackEndPolicy.shouldComplete(
            inputs(observed: 50, duration: 100, videoPackets: 500)
        ))
    }
}
