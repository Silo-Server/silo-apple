import AetherEngine
import Foundation

/// Whether the player presents as loading (the "Loading…" capsule, hidden
/// controls) for an engine playback phase.
///
/// Aether reports a source outage as `.stalled` the moment its reader starts
/// reconnecting, ahead of every other phase, while the player keeps playing
/// from its read-ahead buffer. A direct-play buffer can last minutes, so the
/// outage alone is not a stall the viewer can see. Over a stalled source the
/// player is loading only while it means to play and either the playhead has
/// stopped or the engine has held no media ahead of its clock for a moment.
/// The second case is a seek past the buffer: Aether's clock then runs on
/// without a frame, so a moving playhead alone does not prove playback.
enum PlayerStallPresentation {
    /// How long the playhead may stand still, or the clock run with nothing
    /// buffered ahead of it, over a stalled source before the player counts
    /// as loading. Steady playback moves the playhead every 0.1 s.
    static let frozenPlayheadThreshold: Duration = .seconds(1)
    /// Media buffered ahead of the clock below this counts as none. The
    /// buffered position never trails the clock, so a starved reader reports
    /// exactly zero; the margin absorbs the two values updating separately.
    static let minimumBufferedAheadSeconds: Double = 0.1

    static func isLoading(
        phase: PlaybackPhase,
        isPlaying: Bool,
        playheadMovedAt: ContinuousClock.Instant?,
        bufferEmptySince: ContinuousClock.Instant? = nil,
        now: ContinuousClock.Instant
    ) -> Bool {
        switch phase {
        case .loading, .rebuffering:
            return true
        case .stalled:
            guard isPlaying else { return false }
            guard let playheadMovedAt else { return true }
            if playheadMovedAt.duration(to: now) >= frozenPlayheadThreshold { return true }
            guard let bufferEmptySince else { return false }
            return bufferEmptySince.duration(to: now) >= frozenPlayheadThreshold
        case .idle, .playing, .paused, .seeking, .ended, .error:
            return false
        }
    }

    /// Whether the engine holds media ahead of its clock. Both values are on
    /// the engine clock's axis (`AetherEngine.bufferedPosition` and
    /// `currentTime`).
    static func hasMediaAhead(bufferedPosition: Double, clockTime: Double) -> Bool {
        guard bufferedPosition.isFinite, clockTime.isFinite else { return true }
        return bufferedPosition - clockTime >= minimumBufferedAheadSeconds
    }
}
