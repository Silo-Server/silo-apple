import AetherEngine
import AVFoundation
import Foundation

/// Turns the player's playback facts into ``BufferingQualityController``'s
/// media events, so only the network's own buffering can count as a stall
/// (the spec's "Stall" term and its exclusions).
///
/// The player hands it a ``Snapshot`` whenever a fact may have moved, and it
/// returns the controller calls for what changed: a repeated state returns
/// nothing, and a change of transport trouble always comes before the media
/// call it accompanies. It holds no clock and performs no I/O.
struct BufferingSignalMapper {
    struct Snapshot: Equatable {
        /// A load is installed in the engine.
        var hasActiveLoad: Bool
        /// The viewer's transport intent: play, not pause.
        var wantsToPlay: Bool
        var phase: PlaybackPhase
        /// The engine's `isBuffering`.
        var engineBuffering: Bool
        /// The native route's AVPlayer; nil on the software route.
        var nativeTransport: AetherPlaybackController.NativeTransport?
        /// A seek, scrub commit or hold-seek has not landed yet.
        var seekInFlight: Bool
        /// The source is being reloaded rather than a new plan starting: a
        /// replacement that is not adopted yet, a credential reload, a
        /// reconnect hand-off or a background restore.
        var reloadInProgress: Bool
        var reachedEnd: Bool
        /// The player is reconnecting or lost its connection, or the device
        /// or server is offline. A `.stalled` phase adds to it.
        var connectionTrouble: Bool
        /// Media buffered past the playhead, in milliseconds; nil when
        /// unknown, which counts as nothing buffered.
        var bufferedAheadMs: Int? = nil
    }

    enum Call: Equatable {
        case transportTroubleChanged(Bool)
        case seeked
        case playing
        case waiting(BufferingQualityController.WaitCause)
        case paused
    }

    enum MediaState: Equatable {
        case playing
        case waiting(BufferingQualityController.WaitCause)
        case paused
    }

    /// The media state last reported; nil before the first update or after
    /// ``invalidate()``.
    private(set) var state: MediaState?
    private(set) var transportTrouble = false
    /// `AVPlayerItem.playbackStalledNotification` arrived since playback last
    /// ran.
    private var itemStalledSincePlaying = false

    /// The current item posted `playbackStalledNotification`.
    mutating func noteItemStalled() {
        itemStalledSincePlaying = true
    }

    /// Forgets the media state last reported, so the next update reports it
    /// again: a newly adopted plan needs to hear whether it is already
    /// waiting.
    mutating func invalidate() {
        state = nil
    }

    mutating func update(_ snapshot: Snapshot) -> [Call] {
        var calls: [Call] = []
        let trouble = snapshot.connectionTrouble || snapshot.phase.isSourceStalled
        if trouble != transportTrouble {
            transportTrouble = trouble
            calls.append(.transportTroubleChanged(trouble))
        }
        var next = mediaState(snapshot)
        if next == .waiting(.network) { next = classifyWait(bufferedAheadMs: snapshot.bufferedAheadMs) }
        if next == .playing { itemStalledSincePlaying = false }
        guard next != state else { return calls }
        if next == .waiting(.seek), state == .playing || state == .paused {
            calls.append(.seeked)
        }
        state = next
        switch next {
        case .playing: calls.append(.playing)
        case .waiting(let cause): calls.append(.waiting(cause))
        case .paused: calls.append(.paused)
        }
        return calls
    }

    /// The spec's renderer wait: a wait that begins with more than
    /// `RENDERER_WAIT_BUFFER_MS` buffered past the playhead is the decoder or
    /// renderer falling behind, not the network. It becomes a stall once the
    /// buffer falls to the threshold, and a stall stays one until playback
    /// resumes.
    private func classifyWait(bufferedAheadMs: Int?) -> MediaState {
        if state == .waiting(.network) { return .waiting(.network) }
        let buffered = (bufferedAheadMs ?? 0) > BufferingQualityController.rendererWaitBufferMs
        return buffered ? .waiting(.renderer) : .waiting(.network)
    }

    private func mediaState(_ s: Snapshot) -> MediaState {
        guard s.hasActiveLoad else { return s.wantsToPlay ? .waiting(.reload) : .paused }
        if s.reachedEnd || s.phase == .ended || !s.wantsToPlay { return .paused }
        if s.seekInFlight || s.phase == .seeking { return .waiting(.seek) }
        if let native = s.nativeTransport {
            if native.status == .playing { return .playing }
        } else if s.phase == .playing, !s.engineBuffering {
            return .playing
        }
        let reason = s.nativeTransport?.status == .waitingToPlayAtSpecifiedRate
            ? s.nativeTransport?.waitingReason
            : nil
        if s.reloadInProgress || reason == .noItemToPlay { return .waiting(.reload) }
        if reason == .waitingForCoordinatedPlayback || reason == .interstitialEvent { return .waiting(.pause) }
        if s.nativeTransport?.status == .waitingToPlayAtSpecifiedRate || itemStalledSincePlaying {
            return .waiting(.network)
        }
        switch s.phase {
        case .loading, .rebuffering, .stalled:
            // `.loading` with play intent is a new plan's startup, which the
            // spec times as a wait (`slow_start`).
            return .waiting(.network)
        case .playing where s.engineBuffering:
            return .waiting(.network)
        case .idle, .playing, .paused, .seeking, .ended, .error:
            return .paused
        }
    }
}

private extension PlaybackPhase {
    /// The reader is reconnecting, or gave up and is being reopened: media
    /// requests are failing.
    var isSourceStalled: Bool {
        if case .stalled = self { return true }
        return false
    }
}
