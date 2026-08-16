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

    func testShouldTreatPlaybackErrorAsNaturalEndTable() {
        // Threshold is 8 seconds remaining, or 98.5% progress.
        XCTAssertTrue(PlayerViewModel.shouldTreatPlaybackErrorAsNaturalEnd(
            duration: 100, currentTime: 92
        ))
        XCTAssertTrue(PlayerViewModel.shouldTreatPlaybackErrorAsNaturalEnd(
            duration: 100, currentTime: 98.5
        ))
        XCTAssertFalse(PlayerViewModel.shouldTreatPlaybackErrorAsNaturalEnd(
            duration: 100, currentTime: 91.9
        ))
        // PIN: current behavior. On a short title the 8-second window swallows
        // most of the runtime, so almost any error reads as a natural end.
        XCTAssertTrue(PlayerViewModel.shouldTreatPlaybackErrorAsNaturalEnd(
            duration: 10, currentTime: 2.1
        ))

        // Guard rails: non-positive or non-finite inputs are never "near end".
        XCTAssertFalse(PlayerViewModel.shouldTreatPlaybackErrorAsNaturalEnd(
            duration: 0, currentTime: 0
        ))
        XCTAssertFalse(PlayerViewModel.shouldTreatPlaybackErrorAsNaturalEnd(
            duration: 100, currentTime: 0
        ))
        XCTAssertFalse(PlayerViewModel.shouldTreatPlaybackErrorAsNaturalEnd(
            duration: .infinity, currentTime: 50
        ))
        XCTAssertFalse(PlayerViewModel.shouldTreatPlaybackErrorAsNaturalEnd(
            duration: .nan, currentTime: 50
        ))
        XCTAssertFalse(PlayerViewModel.shouldTreatPlaybackErrorAsNaturalEnd(
            duration: 100, currentTime: .nan
        ))
        XCTAssertFalse(PlayerViewModel.shouldTreatPlaybackErrorAsNaturalEnd(
            duration: -100, currentTime: 50
        ))
        // PIN: current behavior. currentTime past duration still counts.
        XCTAssertTrue(PlayerViewModel.shouldTreatPlaybackErrorAsNaturalEnd(
            duration: 100, currentTime: 150
        ))
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

    func testIsPrematureSourceEndMessageIsCaseSensitive() {
        XCTAssertTrue(PlayerViewModel.isPrematureSourceEndMessage(
            "LoopbackWriterError.prematureSourceEnd(expected: 120)"
        ))
        // PIN: current behavior; likely bug, see cleanup notes.
        // Unlike its siblings, this one does not lowercase the message, so a
        // differently-cased spelling silently misses server-outage recovery.
        XCTAssertFalse(PlayerViewModel.isPrematureSourceEndMessage("PrematureSourceEnd"))
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
