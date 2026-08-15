import XCTest
@testable import Silo

/// Covers the two classification helpers behind the playback diagnostics
/// `reason` attribute. Both collapse open-ended input into a small closed set
/// of stable tokens, and both are order-dependent, so a plausible-looking edit
/// can silently re-file a whole class of failures under the wrong token
/// without any call site changing. Nothing here asserts that a log line was
/// emitted — only that the tokens are what they claim to be.
final class PlayerCoreDiagnosticsClassificationTests: XCTestCase {

    // MARK: - engineErrorReason

    /// Every literal `reportError` message in PlayerCore, pinned to the token
    /// it must classify as. If a message is reworded, this fails and the
    /// rewording is either reflected here or the classifier is fixed.
    func testEveryEngineErrorMessageClassifies() {
        let cases: [(String, String)] = [
            ("Seek stalled: stream I/O did not complete", "seek_stalled"),
            (
                "Dolby Vision Profile 5 requires a Dolby Vision display connected via HDMI"
                    + " with 'Match Content: Dynamic Range' enabled (Settings → Video and Audio → Match Content).",
                "dolby_vision_display_unavailable"
            ),
            (
                "Audio media services were reset; restart playback to resume audio",
                "audio_services_reset"
            ),
            ("Audio output failed: engine start threw", "audio_output_failed"),
            ("No supported video stream", "no_video_stream"),
            ("Failed to open file: Connection timed out", "source_open_failed"),
            ("Failed to read stream info: Invalid data found when processing input", "source_open_failed"),
            ("Unsupported video codec / failed to build format description", "unsupported_codec"),
            ("Video decoder unavailable", "decoder_unavailable"),
            ("avformat_alloc_context failed", "engine_error"),
        ]
        for (message, expected) in cases {
            XCTAssertEqual(
                PlayerCore.engineErrorReason(message),
                expected,
                "\(message.prefix(48))… should classify as \(expected)"
            )
        }
    }

    /// The ordering guarantee that is easiest to break: FFmpeg appends
    /// `av_strerror` text to the open/stream-info messages, and that text can
    /// mention a codec. The message's own prefix must win over a substring
    /// anywhere in the appended part, or a dead network gets filed as an
    /// unsupported codec.
    func testSourceOpenFailureOutranksCodecSubstringFromFFmpegText() {
        XCTAssertEqual(
            PlayerCore.engineErrorReason("Failed to open file: Decoder not found for codec"),
            "source_open_failed"
        )
        XCTAssertEqual(
            PlayerCore.engineErrorReason("Failed to read stream info: no decoder for this codec"),
            "source_open_failed"
        )
    }

    /// "Seek stalled" is checked first because the rest of that sentence
    /// ("stream I/O did not complete") is generic enough to be reachable from
    /// other arms if the order were relaxed.
    func testSeekStallOutranksLaterArms() {
        XCTAssertEqual(
            PlayerCore.engineErrorReason("Seek stalled: stream I/O did not complete"),
            "seek_stalled"
        )
    }

    func testUnrecognizedMessageFallsBackToGenericToken() {
        XCTAssertEqual(PlayerCore.engineErrorReason(""), "engine_error")
        XCTAssertEqual(PlayerCore.engineErrorReason("something new went wrong"), "engine_error")
    }

    /// Classification must not depend on the message's casing; the sources
    /// range from sentence-cased UI prose to lowercase FFmpeg text.
    func testClassificationIsCaseInsensitive() {
        XCTAssertEqual(
            PlayerCore.engineErrorReason("VIDEO DECODER UNAVAILABLE"),
            "decoder_unavailable"
        )
    }

    // MARK: - stallCause

    /// The shallower track is the one that caused the stall.
    func testStallCauseNamesTheShallowerTrack() {
        XCTAssertEqual(
            PlayerCore.stallCause(videoBufferedSeconds: 0.05, audioBufferedSeconds: 2.0),
            "video_starved"
        )
        XCTAssertEqual(
            PlayerCore.stallCause(videoBufferedSeconds: 2.0, audioBufferedSeconds: 0.05),
            "audio_starved"
        )
    }

    /// Both tracks equally dry means neither is the culprit — the source
    /// stopped feeding. Notably this is the common case at exactly 0.0, which
    /// a naive `<=` comparison would misattribute to one track.
    func testStallCauseReportsSourceWhenTracksAreEqual() {
        XCTAssertEqual(
            PlayerCore.stallCause(videoBufferedSeconds: 0, audioBufferedSeconds: 0),
            "source_starved"
        )
        XCTAssertEqual(
            PlayerCore.stallCause(videoBufferedSeconds: 1.5, audioBufferedSeconds: 1.5),
            "source_starved"
        )
    }

    /// A missing track is absent, not starved: video-only and audio-only
    /// content must be attributed to the track that actually exists.
    func testStallCauseWithOnlyOneTrackPresent() {
        XCTAssertEqual(
            PlayerCore.stallCause(videoBufferedSeconds: 0.1, audioBufferedSeconds: nil),
            "video_starved"
        )
        XCTAssertEqual(
            PlayerCore.stallCause(videoBufferedSeconds: nil, audioBufferedSeconds: 0.1),
            "audio_starved"
        )
        XCTAssertEqual(
            PlayerCore.stallCause(videoBufferedSeconds: nil, audioBufferedSeconds: nil),
            "source_starved"
        )
    }

    // MARK: - positionMilliseconds

    /// `position_ms` is an integer attribute, and the registry rejects a
    /// non-integer value outright. An unusable clock (NaN before the first
    /// frame, a negative from a pre-anchor seek) must collapse to zero rather
    /// than crash the conversion or emit a rejected line.
    func testPositionMillisecondsClampsUnusableClocks() {
        XCTAssertEqual(PlayerCore.positionMilliseconds(.nan), 0)
        XCTAssertEqual(PlayerCore.positionMilliseconds(-1), 0)
        XCTAssertEqual(PlayerCore.positionMilliseconds(.infinity), 0)
        XCTAssertEqual(PlayerCore.positionMilliseconds(0), 0)
        XCTAssertEqual(PlayerCore.positionMilliseconds(12.3456), 12_346)
    }

    /// The two position helpers (this one and the bridge's) must agree, or a
    /// report's positions are not comparable across the lines that use them.
    func testPositionMillisecondsMatchesTheSessionBridgeHelper() {
        for seconds: Double in [0, 0.4995, 1, 61.5, 7_200.999, -3, .nan] {
            XCTAssertEqual(
                PlayerCore.positionMilliseconds(seconds),
                PlaybackSessionBridge.diagnosticsPositionMilliseconds(seconds),
                "position rounding diverged at \(seconds)"
            )
        }
    }
}
