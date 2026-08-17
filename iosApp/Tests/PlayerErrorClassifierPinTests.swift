import XCTest
@testable import Silo

/// Characterization ("pin") tests for the string/threshold classifiers that
/// steer `PlayerViewModel`'s error-recovery ladder.
///
/// These were instance methods purely by habit; they are now `static` so the
/// classification rules can be pinned without standing up a view model. The
/// bodies are unchanged — this file records what they decide today so the
/// one-player refactor cannot quietly reroute a failure class.
final class PlayerErrorClassifierPinTests: XCTestCase {

    // MARK: - protocolV3FailureClassification

    func testProtocolV3FailureClassificationTable() {
        let expected: [(String, String)] = [
            ("VideoToolbox decode failed", "decoder_error"),
            ("Decoder gave up", "decoder_error"),
            ("kVTVideoDecoderBadDataErr -129", "decoder_error"),
            ("Unsupported stream", "unsupported_stream"),
            ("Cannot decode this title", "unsupported_stream"),
            ("Network unreachable", "network_degraded"),
            ("The request timed out", "network_degraded"),
            ("Lost connection to server", "network_degraded"),
            ("HTTP 404 from origin", "source_unavailable"),
            ("Playback session not found", "source_unavailable"),
            ("source ended prematurely", "source_unavailable"),
            ("Something else entirely", "playback_error"),
            ("", "playback_error")
        ]
        for (message, want) in expected {
            XCTAssertEqual(
                PlayerViewModel.protocolV3FailureClassification(message),
                want,
                "message=\(message)"
            )
        }
    }

    /// PIN: current behavior; likely bug, see cleanup notes.
    /// The checks run in a fixed order, so an unambiguous transport failure
    /// that happens to mention a decoder is classified as a decoder error,
    /// and "connection" beats "404" in a message that carries both.
    func testProtocolV3FailureClassificationOrderingWins() {
        XCTAssertEqual(
            PlayerViewModel.protocolV3FailureClassification("network timeout in decoder thread"),
            "decoder_error"
        )
        XCTAssertEqual(
            PlayerViewModel.protocolV3FailureClassification("connection closed: HTTP 404"),
            "network_degraded"
        )
        // "-129" matches as a substring anywhere, including inside a byte count.
        XCTAssertEqual(
            PlayerViewModel.protocolV3FailureClassification("read 4-1298 bytes"),
            "decoder_error"
        )
    }

    // MARK: - shouldTreatPlaybackErrorAsNaturalEnd

    /// Corroborated near-end conversion: 8 seconds remaining, no source
    /// outage, and no runway left. The 98.5% ratio arm is gone — it made this
    /// predicate the exact negation of `handleEndOfFile`'s premature check, so
    /// the "Connection lost" branch could never run on the error path.
    private func isNaturalEnd(
        duration: Double,
        currentTime: Double,
        bufferedAhead: Double = 0,
        outage: Bool = false
    ) -> Bool {
        PlayerViewModel.shouldTreatPlaybackErrorAsNaturalEnd(
            duration: duration,
            currentTime: currentTime,
            bufferedAheadSeconds: bufferedAhead,
            isSourceOutageActive: outage
        )
    }

    func testShouldTreatPlaybackErrorAsNaturalEndTable() {
        // Threshold is 8 seconds remaining, with the buffer drained.
        XCTAssertTrue(isNaturalEnd(duration: 100, currentTime: 92))
        XCTAssertTrue(isNaturalEnd(duration: 100, currentTime: 98.5))
        XCTAssertFalse(isNaturalEnd(duration: 100, currentTime: 91.9))
        // The former ratio arm: 98.7% progress but 13 seconds still to play is
        // now a mid-stream failure for the recovery ladder, not a natural end.
        XCTAssertFalse(isNaturalEnd(duration: 1000, currentTime: 987))

        // Guard rails: non-positive or non-finite inputs are never "near end".
        XCTAssertFalse(isNaturalEnd(duration: 0, currentTime: 0))
        XCTAssertFalse(isNaturalEnd(duration: 100, currentTime: 0))
        XCTAssertFalse(isNaturalEnd(duration: .infinity, currentTime: 50))
        XCTAssertFalse(isNaturalEnd(duration: .nan, currentTime: 50))
        XCTAssertFalse(isNaturalEnd(duration: 100, currentTime: .nan))
        XCTAssertFalse(isNaturalEnd(duration: -100, currentTime: 50))
        // PIN: current behavior. currentTime past duration still counts.
        XCTAssertTrue(isNaturalEnd(duration: 100, currentTime: 150))
    }

    func testNearEndConversionRequiresCorroboratingTransportEvidence() {
        // Same position, three verdicts: only the drained, outage-free player
        // is treated as a finished title.
        XCTAssertTrue(isNaturalEnd(duration: 100, currentTime: 95))
        XCTAssertFalse(isNaturalEnd(duration: 100, currentTime: 95, outage: true))
        XCTAssertFalse(isNaturalEnd(duration: 100, currentTime: 95, bufferedAhead: 5))
        // A residual second of queued media is still a drain.
        XCTAssertTrue(isNaturalEnd(duration: 100, currentTime: 95, bufferedAhead: 1))
        // A non-finite buffer report carries no evidence either way and must
        // not veto the conversion.
        XCTAssertTrue(isNaturalEnd(duration: 100, currentTime: 95, bufferedAhead: .nan))

        // Short titles: the 8-second window still covers most of a 10-second
        // item's runtime, so position alone would call an error at 2.1 s a
        // natural end. With a live runway it now stays on the ladder.
        XCTAssertFalse(isNaturalEnd(duration: 10, currentTime: 2.1, bufferedAhead: 5))
        XCTAssertFalse(isNaturalEnd(duration: 10, currentTime: 2.1, outage: true))
        // PIN: with the buffer genuinely drained the short-title case is
        // unchanged — narrowing the window is a product decision (review §10
        // P10), not part of this fix.
        XCTAssertTrue(isNaturalEnd(duration: 10, currentTime: 2.1))
    }

    // MARK: - isPlaybackSessionMissingMessage

    func testIsPlaybackSessionMissingMessageTable() {
        XCTAssertTrue(PlayerViewModel.isPlaybackSessionMissingMessage("playback_session_not_found"))
        XCTAssertTrue(PlayerViewModel.isPlaybackSessionMissingMessage(
            "server said: PLAYBACK_SESSION_NOT_FOUND"
        ))
        XCTAssertTrue(PlayerViewModel.isPlaybackSessionMissingMessage("Playback session not found"))
        XCTAssertFalse(PlayerViewModel.isPlaybackSessionMissingMessage("session not found"))
        XCTAssertFalse(PlayerViewModel.isPlaybackSessionMissingMessage("HTTP 404"))
        XCTAssertFalse(PlayerViewModel.isPlaybackSessionMissingMessage(""))
    }

    // MARK: - isPrematureSourceEndMessage

    func testIsPrematureSourceEndMessageIsCaseInsensitive() {
        XCTAssertTrue(PlayerViewModel.isPrematureSourceEndMessage(
            "LoopbackWriterError.prematureSourceEnd(expected: 120)"
        ))
        // Matches its siblings now: casing cannot make a premature-source-end
        // report miss server-outage recovery.
        XCTAssertTrue(PlayerViewModel.isPrematureSourceEndMessage("PrematureSourceEnd"))
        XCTAssertTrue(PlayerViewModel.isPrematureSourceEndMessage("PREMATURESOURCEEND"))
        // Still a single token — the spaced-out spelling is not this error.
        XCTAssertFalse(PlayerViewModel.isPrematureSourceEndMessage("premature source end"))
        XCTAssertFalse(PlayerViewModel.isPrematureSourceEndMessage(""))
    }

    // MARK: - stablePlaybackFailureToken

    func testStablePlaybackFailureTokenTable() {
        let expected: [(String, String)] = [
            ("The request timed out", "timeout"),
            ("Read timeout after 30s", "timeout"),
            ("Server returned 404 Not Found", "not_found"),
            ("resource not found", "not_found"),
            ("HTTP 401 Unauthorized", "auth"),
            ("HTTP 403", "auth"),
            ("Forbidden by policy", "auth"),
            ("Operation was cancelled", "cancelled"),
            ("Failed to decode frame", "decode"),
            ("remux writer failed", "remux"),
            ("mux error", "remux"),
            ("Network is down", "network"),
            ("connection reset by peer", "network"),
            ("Unclassifiable failure", "playback_error"),
            ("", "playback_error")
        ]
        for (message, want) in expected {
            XCTAssertEqual(
                PlayerViewModel.stablePlaybackFailureToken(for: message),
                want,
                "message=\(message)"
            )
        }
    }

    /// PIN: current behavior; likely bug, see cleanup notes.
    /// Substring matching is unanchored and order-dependent: "mux" matches
    /// inside "demuxer", and a 404 that also mentions a timeout is a timeout.
    func testStablePlaybackFailureTokenOrderingAndSubstringQuirks() {
        XCTAssertEqual(PlayerViewModel.stablePlaybackFailureToken(for: "demuxer failed"), "remux")
        XCTAssertEqual(
            PlayerViewModel.stablePlaybackFailureToken(for: "timed out fetching 404"),
            "timeout"
        )
        XCTAssertEqual(
            PlayerViewModel.stablePlaybackFailureToken(for: "decoder cancelled"),
            "cancelled"
        )
        // PIN: current behavior; likely bug, see cleanup notes.
        // The decode check matches the literal substring "decode", so
        // "decoder failed" is a decode failure but the equally common
        // "decoding failed" falls through to the generic bucket.
        XCTAssertEqual(
            PlayerViewModel.stablePlaybackFailureToken(for: "decoder failed"),
            "decode"
        )
        XCTAssertEqual(
            PlayerViewModel.stablePlaybackFailureToken(for: "decoding failed"),
            "playback_error"
        )
    }
}
