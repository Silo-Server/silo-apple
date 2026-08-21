import XCTest
@testable import Silo

/// Characterization for the two string ladders that turn a backend failure into
/// a wire classification and a diagnostics token.
///
/// The backend's failure channel is now typed (`onError: (PlaybackFailure) ->
/// Void`), but the ladders themselves did not change: they run over
/// `PlaybackFailure.legacyMessage`, which reproduces the pre-migration string
/// byte-for-byte. That is what makes the migration provably behaviour-
/// preserving, so this file does two things:
///
/// 1. pins both ladders across ~30 messages each, drawn from the shapes the
///    backend, the loopback writer and Foundation actually emit; and
/// 2. runs the *old* `PlayerViewModel` implementations, copied in verbatim as
///    oracles, against every typed case's `legacyMessage` and asserts the new
///    code agrees.
///
/// Where the ladders produce a surprising answer it is pinned as `PIN:` and
/// left alone — this file must not change production behavior.
final class PlayerErrorClassificationMatrixTests: XCTestCase {

    // MARK: - Oracles (the pre-migration PlayerViewModel implementations)

    private func oracleClassification(_ message: String) -> String {
        let value = message.lowercased()
        if value.contains("decoder") || value.contains("videotoolbox") || value.contains("-129") {
            return "decoder_error"
        }
        if value.contains("unsupported") || value.contains("cannot decode") {
            return "unsupported_stream"
        }
        if value.contains("network") || value.contains("timed out") || value.contains("connection") {
            return "network_degraded"
        }
        if value.contains("http 404") || value.contains("not found") || value.contains("source ended") {
            return "source_unavailable"
        }
        return "playback_error"
    }

    private func oracleStableToken(_ message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("timed out") || lowered.contains("timeout") { return "timeout" }
        if lowered.contains("404") || lowered.contains("not found") { return "not_found" }
        if lowered.contains("401") || lowered.contains("403") || lowered.contains("unauthorized") || lowered.contains("forbidden") {
            return "auth"
        }
        if lowered.contains("cancel") { return "cancelled" }
        if lowered.contains("decode") { return "decode" }
        if lowered.contains("remux") || lowered.contains("mux") { return "remux" }
        if lowered.contains("network") || lowered.contains("connection") { return "network" }
        return "playback_error"
    }

    private func oracleIsSessionMissing(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("playback_session_not_found")
            || lowered.contains("playback session not found")
    }

    private func oracleIsPrematureSourceEnd(_ message: String) -> Bool {
        message.lowercased().contains("prematuresourceend")
    }

    // MARK: - Every failure the backend can report today

    /// One instance of each `PlaybackFailure` case, with the arguments the
    /// backend's reporting sites actually pass.
    private var everyBackendFailure: [PlaybackFailure] {
        [
            .itemFailed(PlaybackFailure.ItemFailure(
                description: "The operation could not be completed",
                domain: "CoreMediaErrorDomain",
                code: -12889,
                failingURL: "http://127.0.0.1:51234/seg00007.m4s",
                underlying: "NSOSStatusErrorDomain(-12889): unknown",
                errorLog: "uri=http://127.0.0.1:51234/seg00007.m4s status=-12889 domain=CoreMediaErrorDomain comment=nil"
            )),
            .itemFailed(PlaybackFailure.ItemFailure(
                description: "AVPlayer item failed",
                domain: "unknown",
                code: 0
            )),
            .loopbackServerBindFailed(detail: "bindFailed(48)"),
            .loopbackPlaylistURLUnavailable,
            .loopbackRebuildBudgetExhausted(reason: "loopback_item_death", rebuilds: 3),
            .loopbackStartupBackstop(seconds: 45, requestsServed: 0, stage: "reloaded"),
            .loopbackStartupStalled(trigger: "fetches_frozen"),
            .loopbackStartupItemUnreloadable,
            .writerPrematureSourceEnd(detail: "prematureSourceEnd(readRC: -541478725, shortfallBytes: Optional(4096), shortfallSeconds: Optional(12.5))"),
            .writerFailed(detail: "initSegmentMissing"),
            .writerFailed(detail: "unsupportedSelectedAudioCodec(\"dts\")"),
            .writerFailed(detail: "openInput(-2)"),
            .writerFailed(detail: "vodMoovBlocked(closingSegment: 7, audioRouted: true)"),
            .writerFailed(detail: "someFutureWriterError"),
            .unknown("Something else entirely")
        ]
    }

    /// The typed cases must reproduce the exact strings the backend used to
    /// interpolate: they are the user-visible error text and the `message`
    /// field sent to the server on a replan.
    func testLegacyMessagesAreReproducedByteForByte() {
        let expected: [(PlaybackFailure, String)] = [
            (
                .itemFailed(PlaybackFailure.ItemFailure(
                    description: "The operation could not be completed",
                    domain: "CoreMediaErrorDomain",
                    code: -12889,
                    failingURL: "http://127.0.0.1:51234/seg00007.m4s",
                    underlying: "NSOSStatusErrorDomain(-12889): unknown",
                    errorLog: "uri=x status=-12889 domain=CoreMediaErrorDomain comment=nil"
                )),
                "AVPlayer item failed: The operation could not be completed domain=CoreMediaErrorDomain code=-12889"
                    + " failingURL=http://127.0.0.1:51234/seg00007.m4s"
                    + " underlying=NSOSStatusErrorDomain(-12889): unknown"
                    + " errorLog=uri=x status=-12889 domain=CoreMediaErrorDomain comment=nil"
            ),
            (
                .itemFailed(PlaybackFailure.ItemFailure(
                    description: "AVPlayer item failed",
                    domain: "unknown",
                    code: 0
                )),
                "AVPlayer item failed: AVPlayer item failed domain=unknown code=0"
            ),
            (
                // Empty optional parts are omitted, exactly as before.
                .itemFailed(PlaybackFailure.ItemFailure(
                    description: "d",
                    domain: "dom",
                    code: 1,
                    failingURL: "",
                    underlying: "",
                    errorLog: ""
                )),
                "AVPlayer item failed: d domain=dom code=1"
            ),
            (
                .loopbackServerBindFailed(detail: "bindFailed(48)"),
                "Local HLS server failed to start: bindFailed(48)"
            ),
            (
                .loopbackPlaylistURLUnavailable,
                "Local playback server could not produce a playable URL."
            ),
            (
                .loopbackRebuildBudgetExhausted(reason: "loopback_item_death", rebuilds: 3),
                "loopback_rebuild_budget_exhausted (reason=loopback_item_death rebuilds=3)"
            ),
            (
                .loopbackStartupBackstop(seconds: 45, requestsServed: 0, stage: "reloaded"),
                "Local loopback startup never became ready within 45s (requestsServed=0 stage=reloaded)"
            ),
            (
                .loopbackStartupStalled(trigger: "fetches_frozen"),
                "Local loopback startup stalled after nudge and item reload (trigger=fetches_frozen)"
            ),
            (
                .loopbackStartupItemUnreloadable,
                "Local loopback startup stalled with no reloadable item URL"
            ),
            (
                .writerFailed(detail: "vodMoovBlocked"),
                "Remuxer failed: vodMoovBlocked"
            ),
            (
                // The premature-source-end case is reported as the same
                // "Remuxer failed:" string it always was.
                .writerPrematureSourceEnd(detail: "prematureSourceEnd(readRC: -1)"),
                "Remuxer failed: prematureSourceEnd(readRC: -1)"
            ),
            (.unknown("raw text"), "raw text")
        ]
        for (failure, want) in expected {
            XCTAssertEqual(failure.legacyMessage, want)
        }
    }

    /// The migration's core claim: for every failure the backend can report,
    /// the typed properties answer exactly what the four `PlayerViewModel`
    /// substring classifiers answered for the same failure.
    func testTypedFailuresAgreeWithTheRetiredViewModelClassifiers() {
        for failure in everyBackendFailure {
            let message = failure.legacyMessage
            XCTAssertEqual(
                failure.classification,
                oracleClassification(message),
                "classification message=\(message)"
            )
            XCTAssertEqual(
                failure.stableToken,
                oracleStableToken(message),
                "stableToken message=\(message)"
            )
            XCTAssertEqual(
                failure.isPlaybackSessionMissing,
                oracleIsSessionMissing(message),
                "sessionMissing message=\(message)"
            )
            // `isPrematureSourceEnd` is the one decision the typed case is
            // allowed to answer on its own — and for the writer's real
            // description it agrees with the old substring match anyway.
            if case .writerPrematureSourceEnd = failure {
                XCTAssertTrue(failure.isPrematureSourceEnd)
                XCTAssertTrue(oracleIsPrematureSourceEnd(message))
            } else {
                XCTAssertEqual(
                    failure.isPrematureSourceEnd,
                    oracleIsPrematureSourceEnd(message),
                    "prematureSourceEnd message=\(message)"
                )
            }
        }
    }

    // MARK: - classification × 30

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
                PlaybackFailure.classification(forLegacyMessage: message),
                want,
                "message=\(message)"
            )
        }
    }

    /// PIN: current behavior; likely bug, see cleanup notes.
    /// The writer's own premature-source-end token spells the words without a
    /// separator, so it misses the `"source ended"` substring the classifier
    /// looks for and reports as a generic playback error — even though the
    /// premature-source-end predicate recognises exactly this string.
    ///
    /// The typed channel does not paper over it: the wire classification is
    /// deliberately unchanged, and the routing decision that matters
    /// (`isPrematureSourceEnd`) is now made by the case, not the spelling.
    func testWriterPrematureSourceEndTokenDoesNotReachSourceUnavailable() {
        let message = "LoopbackWriterError.prematureSourceEnd(expected: 120)"
        XCTAssertTrue(PlaybackFailure.isPrematureSourceEnd(legacyMessage: message))
        XCTAssertEqual(
            PlaybackFailure.classification(forLegacyMessage: message),
            "playback_error"
        )
        XCTAssertEqual(
            PlaybackFailure.writerPrematureSourceEnd(detail: "prematureSourceEnd(readRC: -1, shortfallBytes: nil, shortfallSeconds: nil)").classification,
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
                PlaybackFailure.classification(forLegacyMessage: message),
                want,
                "message=\(message)"
            )
        }
    }

    // MARK: - stableToken × 30

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
                PlaybackFailure.stableToken(forLegacyMessage: message),
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
                PlaybackFailure.stableToken(forLegacyMessage: message),
                want,
                "message=\(message)"
            )
        }
    }

    // MARK: - The two ladders disagree

    /// The wire classification and the diagnostics token are computed by two
    /// independent ladders over the same string, so the same failure can be
    /// filed as two different things. Pinned because the typed channel
    /// preserves both verdicts rather than reconciling them — reconciling is a
    /// wire-contract change, not part of this migration.
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
                PlaybackFailure.classification(forLegacyMessage: entry.message),
                entry.classification,
                "message=\(entry.message)"
            )
            XCTAssertEqual(
                PlaybackFailure.stableToken(forLegacyMessage: entry.message),
                entry.token,
                "message=\(entry.message)"
            )
        }
    }
}
