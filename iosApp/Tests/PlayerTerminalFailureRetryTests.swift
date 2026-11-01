import XCTest
@testable import Silo

final class PlayerTerminalFailureRetryTests: XCTestCase {
    func testServerTerminalFailureMarkedNotRetryableHidesRetry() {
        let unreadable = PlaybackV3TerminalFailure(
            reason: "source_unreadable",
            message: "The source file could not be read; it appears to be empty or damaged.",
            retryable: false
        )
        XCTAssertFalse(PlayerViewModel.isRetryablePlaybackFailure(unreadable))
    }

    func testServerTerminalFailureMarkedRetryableKeepsRetry() {
        let incomplete = PlaybackV3TerminalFailure(
            reason: "source_metadata_incomplete",
            message: "This file hasn't finished scanning.",
            retryable: true
        )
        XCTAssertTrue(PlayerViewModel.isRetryablePlaybackFailure(incomplete))
    }

    func testRecoveryDeadEndsKeepRetry() {
        // A flaky network can exhaust the replan ladder or trip loop
        // detection. Retry starts a fresh session with a fresh ladder, so it
        // must stay available.
        for reason in ["attempt_limit_reached", "replan_loop_detected", "invalid_replan"] {
            let deadEnd = PlaybackSessionBridge.replanDeadEnd(reason: reason, message: "Recovery failed.")
            XCTAssertTrue(PlayerViewModel.isRetryablePlaybackFailure(deadEnd), reason)
        }
    }

    func testReplanRefusalsThatFailAFreshStartHideRetry() {
        // The start path refuses both with retryable: false, so a fresh
        // session from Retry would fail the same way.
        for reason in ["server_upgrade_required", PlaybackSessionBridge.fixedSourceFailure().reason] {
            let deadEnd = PlaybackSessionBridge.replanDeadEnd(reason: reason, message: "Playback can't continue.")
            XCTAssertFalse(deadEnd.retryable, reason)
            XCTAssertFalse(PlayerViewModel.isRetryablePlaybackFailure(deadEnd), reason)
        }
    }

    /// A subtitle the server can't deliver ends only the switch that asked
    /// for it; the session keeps playing. Any other refusal, or a subtitle
    /// refusal outside a track change, is still a dead end.
    func testOnlyATrackChangesSubtitleRefusalKeepsTheSession() {
        let trackChange = PlaybackProtocolV3.ReplanOperation.trackChange
        for reason in [
            "subtitle_codec_unsupported", "subtitle_conversion_unsupported",
            "subtitle_burn_in_source_unsupported", "subtitle_track_unavailable", "subtitle_track_invalid",
        ] {
            XCTAssertTrue(PlaybackSessionBridge.isSubtitleSwitchRefusal(operation: trackChange, reason: reason), reason)
        }
        XCTAssertFalse(PlaybackSessionBridge.isSubtitleSwitchRefusal(
            operation: trackChange, reason: "adaptation_unavailable"))
        XCTAssertFalse(PlaybackSessionBridge.isSubtitleSwitchRefusal(
            operation: PlaybackProtocolV3.ReplanOperation.failureRecovery, reason: "subtitle_codec_unsupported"))
    }

    func testTransportFailureStaysRetryable() {
        XCTAssertTrue(PlayerViewModel.isRetryablePlaybackFailure(URLError(.cannotConnectToHost)))
    }
}
