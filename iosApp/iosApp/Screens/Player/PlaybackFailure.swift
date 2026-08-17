import Foundation

/// The typed failure channel out of `AVPlayerBackend`.
///
/// Review §4 item 4: `String` used to be the *only* failure channel out of the
/// backend (`onError: (String) -> Void`), and `PlayerViewModel` re-derived four
/// separate decisions from that string with unanchored substring matches. The
/// case now carries the failure's identity, so the backend states what happened
/// instead of describing it and hoping the view model reads the description the
/// same way.
///
/// The legacy strings did not go away, because they are load-bearing in two
/// places that are not ours to change here:
///
/// * `legacyMessage` is the text shown to the user by
///   `finalizeTerminalPlaybackError`, and it is the `message` field sent to the
///   server on a Protocol V3 replan (`PlaybackSessionBridge.replanProtocolV3`).
/// * `classification` and `stableToken` are the wire classification and the
///   diagnostics token. Both are still derived by the *same ordered substring
///   ladders* that lived in `PlayerViewModel`, run over `legacyMessage`, so this
///   migration is provably behaviour-preserving: identical inputs produce
///   identical wire output. Those ladders now have exactly one owner (this
///   file) instead of being open-coded in the view model.
///
/// Where the typed case makes a decision unambiguous — `isPrematureSourceEnd`
/// for a writer that reported `LoopbackWriterError.prematureSourceEnd` — the
/// case answers directly and the substring ladder is only the fallback for
/// failures that arrived as raw text.
enum PlaybackFailure: Equatable {

    /// `AVPlayerItem.status == .failed`. Mirrors the fields the backend used to
    /// interpolate into one string, so `legacyMessage` reproduces it exactly.
    struct ItemFailure: Equatable {
        var description: String
        var domain: String
        var code: Int
        var failingURL: String?
        var underlying: String?
        var errorLog: String?

        init(
            description: String,
            domain: String,
            code: Int,
            failingURL: String? = nil,
            underlying: String? = nil,
            errorLog: String? = nil
        ) {
            self.description = description
            self.domain = domain
            self.code = code
            self.failingURL = failingURL
            self.underlying = underlying
            self.errorLog = errorLog
        }
    }

    /// What the loopback writer failed at. Mapped from `LoopbackWriterError`
    /// cases at the reporting site — never parsed out of a description.
    enum WriterFailureKind: Equatable {
        /// Ingest ended clearly short of the known content: an origin outage,
        /// not an engine defect. Routes into server-outage recovery.
        case prematureSourceEnd
        /// Media was muxed before any `moov`, so no init segment exists.
        case initSegmentMissing
        /// The selected audio codec has no route into fMP4.
        case unsupportedSelectedAudioCodec
        /// Software decode + encode fell below realtime for good.
        case videoBridgeTooSlow
        /// The source could not be opened, seeked, or probed at all.
        case sourceUnavailable
        /// The mux side produced no usable output.
        case remux
        case other
    }

    /// The AVPlayer item failed.
    case itemFailed(ItemFailure)
    /// The local HLS segment server could not bind.
    case loopbackServerBindFailed(detail: String)
    /// The local HLS segment server bound but produced no playable URL.
    case loopbackPlaylistURLUnavailable
    /// The session rebuild ladder ran out of budget (review §3 #15).
    case loopbackRebuildBudgetExhausted(reason: String, rebuilds: Int)
    /// The loopback startup absolute backstop expired.
    case loopbackStartupBackstop(seconds: Int, requestsServed: UInt64, stage: String)
    /// The loopback startup ladder exhausted nudge + item reload.
    case loopbackStartupStalled(trigger: String)
    /// The loopback startup ladder wanted to reload the item but had no URL.
    case loopbackStartupItemUnreloadable
    /// The loopback writer finished with an error.
    case writerFailed(kind: WriterFailureKind, detail: String)
    /// A failure that only ever existed as text. The escape hatch for callers
    /// (and tests) that still hold a legacy string.
    case unknown(String)

    init(legacyMessage: String) {
        self = .unknown(legacyMessage)
    }

    // MARK: - Legacy surface

    /// The exact string this failure used to be reported as. Reproduced
    /// byte-for-byte: it reaches the user as `PlayerViewModel.error` and the
    /// server as the replan `message`.
    var legacyMessage: String {
        switch self {
        case .itemFailed(let failure):
            var details = "AVPlayer item failed: \(failure.description)"
                + " domain=\(failure.domain) code=\(failure.code)"
            if let failingURL = failure.failingURL, !failingURL.isEmpty {
                details += " failingURL=\(failingURL)"
            }
            if let underlying = failure.underlying, !underlying.isEmpty {
                details += " underlying=\(underlying)"
            }
            if let errorLog = failure.errorLog, !errorLog.isEmpty {
                details += " errorLog=\(errorLog)"
            }
            return details
        case .loopbackServerBindFailed(let detail):
            return "Local HLS server failed to start: \(detail)"
        case .loopbackPlaylistURLUnavailable:
            return "Local playback server could not produce a playable URL."
        case .loopbackRebuildBudgetExhausted(let reason, let rebuilds):
            return "loopback_rebuild_budget_exhausted (reason=\(reason) rebuilds=\(rebuilds))"
        case .loopbackStartupBackstop(let seconds, let requestsServed, let stage):
            return "Local loopback startup never became ready within \(seconds)s "
                + "(requestsServed=\(requestsServed) stage=\(stage))"
        case .loopbackStartupStalled(let trigger):
            return "Local loopback startup stalled after nudge and item reload (trigger=\(trigger))"
        case .loopbackStartupItemUnreloadable:
            return "Local loopback startup stalled with no reloadable item URL"
        case .writerFailed(_, let detail):
            return "Remuxer failed: \(detail)"
        case .unknown(let message):
            return message
        }
    }

    // MARK: - Derived decisions

    /// Protocol V3 replan classification. Same vocabulary and same ladder the
    /// view model used, so the server sees no change.
    var classification: String {
        Self.classification(forLegacyMessage: legacyMessage)
    }

    /// Diagnostics token for the route-fallback log line.
    var stableToken: String {
        Self.stableToken(forLegacyMessage: legacyMessage)
    }

    /// The server no longer knows this playback session (its 404 semantics).
    var isPlaybackSessionMissing: Bool {
        Self.isPlaybackSessionMissing(legacyMessage: legacyMessage)
    }

    /// Ingest ended short of the known content. Typed when the writer said so;
    /// the substring fallback covers failures that arrived as raw text.
    var isPrematureSourceEnd: Bool {
        if case .writerFailed(.prematureSourceEnd, _) = self { return true }
        return Self.isPrematureSourceEnd(legacyMessage: legacyMessage)
    }

    // MARK: - The legacy ladders (single owner)

    /// Moved verbatim from `PlayerViewModel.protocolV3FailureClassification`.
    /// Ordered substring matching, quirks included: this decides what the
    /// server is told, so it must keep answering exactly as it did.
    static func classification(forLegacyMessage message: String) -> String {
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

    /// Moved verbatim from `PlayerViewModel.stablePlaybackFailureToken(for:)`.
    static func stableToken(forLegacyMessage message: String) -> String {
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

    /// Moved verbatim from `PlayerViewModel.isPlaybackSessionMissingMessage`.
    static func isPlaybackSessionMissing(legacyMessage message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("playback_session_not_found")
            || lowered.contains("playback session not found")
    }

    /// Moved verbatim from `PlayerViewModel.isPrematureSourceEndMessage`.
    /// Case-insensitive on purpose: the token reaches us as a raw
    /// `LoopbackWriterError` description on one path and as a re-cased server
    /// string on another, and a spelling miss silently skips outage recovery.
    static func isPrematureSourceEnd(legacyMessage message: String) -> Bool {
        message.lowercased().contains("prematuresourceend")
    }
}
