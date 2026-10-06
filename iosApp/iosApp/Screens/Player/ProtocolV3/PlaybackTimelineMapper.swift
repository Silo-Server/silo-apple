import Foundation

/// The engine-facing interpretation of Playback Protocol V3's timeline.
///
/// Aether's load and clock use the transport/player axis. Silo progress,
/// chapters, markers, and server commands use the source-media axis. Keeping
/// this conversion in one value prevents an HLS reanchor from leaking into the
/// rest of the player as an ad-hoc offset.
struct PlaybackTimelineMapper: Equatable, Sendable {
    enum ValidationError: Error, Equatable {
        case nonFinite(field: String)
        case negative(field: String)
        case invalidSeekWindow
        case unsupportedSeekRestoration(String)
    }

    enum SeekDisposition: Equatable {
        /// Aether can execute this seek against the currently loaded source.
        case local(playerSeconds: Double)
        /// The server must issue a plan whose transport contains this source
        /// position before Aether is loaded again.
        case replan(sourceSeconds: Double)
    }

    let sourceStartSeconds: Double
    let playerStartSeconds: Double
    let timelineOffsetSeconds: Double
    let seekWindowStartSeconds: Double?
    let seekWindowEndSeconds: Double?
    let canSeekAnywhere: Bool

    init(directStartSeconds: Double) {
        let start = directStartSeconds.isFinite ? max(0, directStartSeconds) : 0
        sourceStartSeconds = start
        playerStartSeconds = start
        timelineOffsetSeconds = 0
        seekWindowStartSeconds = nil
        seekWindowEndSeconds = nil
        canSeekAnywhere = true
    }

    init(validating timeline: PlaybackV3Timeline) throws {
        let required: [(String, Double)] = [
            ("source_start_seconds", timeline.sourceStartSeconds),
            ("stream_origin_seconds", timeline.streamOriginSeconds),
            ("player_start_seconds", timeline.playerStartSeconds),
            ("timeline_offset_seconds", timeline.timelineOffsetSeconds),
        ]
        for (field, value) in required {
            guard value.isFinite else { throw ValidationError.nonFinite(field: field) }
            guard value >= 0 else { throw ValidationError.negative(field: field) }
        }
        for (field, value) in [
            ("seek_window_start_seconds", timeline.seekWindowStartSeconds),
            ("seek_window_end_seconds", timeline.seekWindowEndSeconds),
        ] {
            guard let value else { continue }
            guard value.isFinite else { throw ValidationError.nonFinite(field: field) }
            guard value >= 0 else { throw ValidationError.negative(field: field) }
        }
        if let start = timeline.seekWindowStartSeconds,
           let end = timeline.seekWindowEndSeconds,
           start > end {
            throw ValidationError.invalidSeekWindow
        }
        guard ["player_position", "source_position"].contains(timeline.seekRestoration) else {
            throw ValidationError.unsupportedSeekRestoration(timeline.seekRestoration)
        }

        sourceStartSeconds = timeline.sourceStartSeconds
        playerStartSeconds = timeline.playerStartSeconds
        timelineOffsetSeconds = timeline.timelineOffsetSeconds
        seekWindowStartSeconds = timeline.seekWindowStartSeconds
        seekWindowEndSeconds = timeline.seekWindowEndSeconds
        canSeekAnywhere = timeline.canSeekAnywhere
    }

    /// The position supplied to `AetherEngine.load`. It is deliberately the
    /// plan's player coordinate, not its source coordinate.
    var aetherStartPosition: Double { playerStartSeconds }

    func sourcePosition(forPlayerTime playerSeconds: Double) -> Double {
        guard playerSeconds.isFinite else { return sourceStartSeconds }
        return max(0, playerSeconds + timelineOffsetSeconds)
    }

    func playerPosition(forSourceTime sourceSeconds: Double) -> Double {
        guard sourceSeconds.isFinite else { return playerStartSeconds }
        return max(0, sourceSeconds - timelineOffsetSeconds)
    }

    /// The earliest source position this transport can express.
    ///
    /// Player time is `source - timelineOffsetSeconds`, so a target below the
    /// offset has no non-negative player coordinate at all. It is a property of
    /// the loaded transport, not of the advertised seek window, which is why the
    /// check below does not depend on one being published.
    var earliestLocalSourceSeconds: Double { timelineOffsetSeconds }

    func seekDisposition(forSourceTime requestedSeconds: Double) -> SeekDisposition {
        let sourceSeconds = requestedSeconds.isFinite ? max(0, requestedSeconds) : sourceStartSeconds
        // A target before the offset has no player coordinate, and
        // `playerPosition` would clamp it to the transport's origin. Only the
        // server can produce a transport that contains it, so replan even when
        // no seek window was published or `can_seek_anywhere` is set.
        if sourceSeconds < earliestLocalSourceSeconds {
            return .replan(sourceSeconds: sourceSeconds)
        }
        guard canSeekAnywhere else { return .replan(sourceSeconds: sourceSeconds) }
        if let start = seekWindowStartSeconds, sourceSeconds < start {
            return .replan(sourceSeconds: sourceSeconds)
        }
        if let end = seekWindowEndSeconds, sourceSeconds > end {
            return .replan(sourceSeconds: sourceSeconds)
        }
        return .local(playerSeconds: playerPosition(forSourceTime: sourceSeconds))
    }
}
