import XCTest
@testable import Silo

/// Stage-0 characterization: the two string classifiers that turn the
/// backend's only failure channel (`onError: (String) -> Void`) into a wire
/// classification and a diagnostics token.
///
/// `PlayerErrorClassifierPinTests` already pins a short table for each. This
/// file widens both to ~30 messages, drawn from the shapes the backend, the
/// loopback writer and Foundation actually emit, so a typed-failure rewrite
/// has a full mapping to answer to rather than a sample of one.
///
/// Both functions are ordered substring matches over a lowercased message.
/// Where that produces a surprising answer it is pinned as `PIN:` and left
/// alone — this file must not change production behavior.
final class PlayerErrorClassificationMatrixTests: XCTestCase {

    // MARK: - protocolV3FailureClassification × 30

    func testProtocolV3FailureClassificationWideMatrix() {
        let expected: [(String, String)] = [
            // decoder_error — rung 1
            ("kVTVideoDecoderMalfunctionErr -12909", "decoder_error"),
            ("kVTVideoDecoderBadDataErr", "decoder_error"),
            ("VideoToolbox session invalidated", "decoder_error"),
            ("videotoolbox encoder could not be opened", "decoder_error"),
            ("Hardware decoder unavailable for vc1", "decoder_error"),
            ("AVPlayer item failed: decoder malfunction domain=AVFoundationErrorDomain", "decoder_error"),

            // unsupported_stream — rung 2
            ("Unsupported codec vc1 in this container", "unsupported_stream"),
            ("The server selected an unsupported V3 delivery: burn_in.", "unsupported_stream"),
            ("Cannot decode this title on this device", "unsupported_stream"),

            // network_degraded — rung 3
            ("The network connection was lost.", "network_degraded"),
            ("The Internet connection appears to be offline.", "network_degraded"),
            ("NETWORK UNREACHABLE", "network_degraded"),
            ("The request timed out.", "network_degraded"),
            ("Read timed out after 30s", "network_degraded"),
            ("connection reset by peer", "network_degraded"),

            // source_unavailable — rung 4
            ("HTTP 404 while fetching the source", "source_unavailable"),
            ("Playback session not found", "source_unavailable"),
            ("Segment not found on the local server", "source_unavailable"),
            ("source ended prematurely at 42.0s", "source_unavailable"),

            // playback_error — the default rung, and the shapes that land there
            ("Local HLS server failed to start: bindFailed(48)", "playback_error"),
            ("Remuxer failed: vodMoovBlocked", "playback_error"),
            ("Local playback server could not produce a playable URL.", "playback_error"),
            ("Local loopback startup stalled after nudge and item reload (trigger=fetches_frozen)", "playback_error"),
            ("Local loopback startup never became ready within 45s (requestsServed=0 stage=reloaded)", "playback_error"),
            ("SiloPlayer loopback requires a loopback session.", "playback_error"),
            ("AVPlayer item failed: The operation could not be completed domain=CoreMediaErrorDomain code=-11800", "playback_error"),
            ("AVPlayer item failed: domain=CoreMediaErrorDomain code=-17223", "playback_error"),
            ("HTTP 401 Unauthorized", "playback_error"),
            ("HTTP 403 Forbidden while fetching segment 12", "playback_error"),
            ("Operation was cancelled", "playback_error"),
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
    /// The writer's own premature-source-end token spells the words without a
    /// separator, so it misses the `"source ended"` substring the classifier
    /// looks for and reports as a generic playback error — even though
    /// `isPrematureSourceEndMessage` recognises exactly this string.
    func testWriterPrematureSourceEndTokenDoesNotReachSourceUnavailable() {
        let message = "LoopbackWriterError.prematureSourceEnd(expected: 120)"
        XCTAssertTrue(PlayerViewModel.isPrematureSourceEndMessage(message))
        XCTAssertEqual(
            PlayerViewModel.protocolV3FailureClassification(message),
            "playback_error"
        )
    }

    /// PIN: current behavior; likely bug, see cleanup notes.
    /// Rung order decides every ambiguous message: an HTTP 404 that mentions a
    /// decoder is a decoder error, an unsupported codec reported over a lost
    /// connection is unsupported rather than network, and a 404 delivered as a
    /// timeout is network rather than source-unavailable.
    func testProtocolV3ClassificationRungOrderWins() {
        let expected: [(String, String)] = [
            ("HTTP 404: decoder stream missing", "decoder_error"),
            ("connection lost: unsupported codec", "unsupported_stream"),
            ("timed out fetching HTTP 404", "network_degraded"),
            ("not found: connection refused", "network_degraded"),
            ("source ended, network unreachable", "network_degraded")
        ]
        for (message, want) in expected {
            XCTAssertEqual(
                PlayerViewModel.protocolV3FailureClassification(message),
                want,
                "message=\(message)"
            )
        }
    }

    // MARK: - stablePlaybackFailureToken × 30

    func testStablePlaybackFailureTokenWideMatrix() {
        let expected: [(String, String)] = [
            // timeout — rung 1
            ("The request timed out.", "timeout"),
            ("Read timed out after 30s", "timeout"),
            ("Timeout while awaiting the first frame", "timeout"),
            ("segment fetch timeout", "timeout"),

            // not_found — rung 2
            ("HTTP 404", "not_found"),
            ("Server returned 404", "not_found"),
            ("manifest not found", "not_found"),
            ("Playback session not found", "not_found"),

            // auth — rung 3
            ("HTTP 401", "auth"),
            ("HTTP 403 Forbidden while fetching segment 12", "auth"),
            ("Request rejected: unauthorized", "auth"),
            ("Forbidden by profile policy", "auth"),

            // cancelled — rung 4
            ("Operation was cancelled", "cancelled"),
            ("Task was canceled", "cancelled"),
            ("cancellation requested during load", "cancelled"),

            // decode — rung 5
            ("Failed to decode frame", "decode"),
            ("Hardware decoder unavailable for vc1", "decode"),
            ("kVTVideoDecoderMalfunctionErr -12909", "decode"),

            // remux — rung 6
            ("Remuxer failed: vodMoovBlocked", "remux"),
            ("remux writer produced no init segment", "remux"),
            ("mux queue overflow", "remux"),

            // network — rung 7
            ("The network connection was lost.", "network"),
            ("The Internet connection appears to be offline.", "network"),
            ("network is unreachable", "network"),

            // playback_error — default
            ("Local HLS server failed to start: bindFailed(48)", "playback_error"),
            ("Local playback server could not produce a playable URL.", "playback_error"),
            ("Local loopback startup stalled after nudge and item reload (trigger=fetches_frozen)", "playback_error"),
            ("AVPlayer item failed: domain=CoreMediaErrorDomain code=-17223", "playback_error"),
            ("Unsupported codec vc1 in this container", "playback_error"),
            ("source ended prematurely at 42.0s", "playback_error"),
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
    /// Rung order again: whichever bucket appears first in the ladder wins,
    /// regardless of which term describes the actual failure.
    func testStableTokenRungOrderWins() {
        let expected: [(String, String)] = [
            ("decoder timed out", "timeout"),
            ("404 while decoding", "not_found"),
            ("unauthorized network request", "auth"),
            ("cancelled remux", "cancelled"),
            ("decode failed on the network", "decode"),
            ("demux error on a network stream", "remux")
        ]
        for (message, want) in expected {
            XCTAssertEqual(
                PlayerViewModel.stablePlaybackFailureToken(for: message),
                want,
                "message=\(message)"
            )
        }
    }

    // MARK: - The two classifiers disagree

    /// The wire classification and the diagnostics token are computed by two
    /// independent ladders over the same string, so the same failure can be
    /// filed as two different things. Pinned so a typed-failure rewrite has to
    /// decide which of the two it is preserving.
    func testTheTwoClassifiersDisagreeOnTheSameMessage() {
        let disagreements: [(message: String, classification: String, token: String)] = [
            ("Failed to decode frame", "playback_error", "decode"),
            ("VideoToolbox session invalidated", "decoder_error", "playback_error"),
            ("Unsupported codec vc1 in this container", "unsupported_stream", "playback_error"),
            ("source ended prematurely at 42.0s", "source_unavailable", "playback_error"),
            ("HTTP 403 Forbidden while fetching segment 12", "playback_error", "auth"),
            ("Operation was cancelled", "playback_error", "cancelled"),
            ("Remuxer failed: vodMoovBlocked", "playback_error", "remux"),
            ("HTTP 404 while fetching the source", "source_unavailable", "not_found")
        ]
        for entry in disagreements {
            XCTAssertEqual(
                PlayerViewModel.protocolV3FailureClassification(entry.message),
                entry.classification,
                "message=\(entry.message)"
            )
            XCTAssertEqual(
                PlayerViewModel.stablePlaybackFailureToken(for: entry.message),
                entry.token,
                "message=\(entry.message)"
            )
        }
    }
}
