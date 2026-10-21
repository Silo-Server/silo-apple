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
        /// The player is reconnecting or lost its connection, the device is
        /// offline, or a media request failed recently. A `.stalled` phase
        /// adds to it.
        var connectionTrouble: Bool
        /// Media buffered past the playhead, in milliseconds; nil when
        /// unknown, which counts as nothing buffered.
        var bufferedAheadMs: Int? = nil
        /// The software route reports playing, but its clock has not moved
        /// for a second while the viewer wants to play. AetherEngine's
        /// software host pauses its clock to rebuffer without reporting it.
        var playheadFrozen = false
    }

    enum Call: Equatable {
        case transportTroubleChanged(Bool)
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
    /// A seek, playing or paused, since playback last ran: the buffering that
    /// follows belongs to it until playback runs.
    private var seekSincePlaying = false
    /// The adopted plan has neither run nor paused yet. Until it does, a
    /// start the viewer means to play is the plan's wait, whatever reloads
    /// its transport.
    private var startPending = false
    /// The adopted plan has run. Until it does, a seek, the player applying
    /// the start position included, does not end the start's wait.
    private var planHasRun = true
    /// A media request failed since the last update: an outage begins.
    private var mediaRequestFailed = false
    /// Once the outage's inputs clear, the media buffered past the playhead
    /// then. The outage lasts until that rises or playback runs.
    private var outageAwaitsDataAboveMs: Int?

    /// The outage's inputs cleared, but no media data has arrived since.
    var outageAwaitsData: Bool { outageAwaitsDataAboveMs != nil }

    /// The player logged a failed media request (a playlist, segment or
    /// range request, never a subtitle).
    mutating func noteMediaRequestFailed() {
        mediaRequestFailed = true
    }

    /// The current item posted `playbackStalledNotification`.
    mutating func noteItemStalled() {
        itemStalledSincePlaying = true
    }

    /// Forgets the media state last reported, so the next update reports it
    /// again.
    mutating func invalidate() {
        state = nil
    }

    /// A plan was adopted: it hears whether playback is already waiting, its
    /// start is timed until it first runs or pauses, and it starts with no
    /// outage. One still signalled begins again at the next update.
    mutating func planAdopted() {
        state = nil
        startPending = true
        planHasRun = false
        // Until it plays, a seek doesn't end the new plan's start, nor does one
        // made under the plan before it, in this title or the last.
        seekSincePlaying = false
        outageAwaitsDataAboveMs = nil
        mediaRequestFailed = false
    }

    mutating func update(_ snapshot: Snapshot) -> [Call] {
        var calls: [Call] = []
        if planHasRun, snapshot.seekInFlight || snapshot.phase == .seeking { seekSincePlaying = true }
        // A torn-down item (the app went to the background) stalls no more.
        if snapshot.nativeTransport?.hasItem == false { itemStalledSincePlaying = false }
        // The viewer pausing, or the engine tearing the video down outside a
        // reload, ends the start as a pause does.
        let tornDown = snapshot.hasActiveLoad && !snapshot.reloadInProgress
            && snapshot.nativeTransport?.hasItem == false
        if !snapshot.wantsToPlay || tornDown { startPending = false }
        var next = mediaState(snapshot)
        // Buffering after a seek stays the seek's until playback runs, even
        // once the seek has landed, and for a seek made while paused.
        if next == .waiting(.network), seekSincePlaying { next = .waiting(.seek) }
        if next == .waiting(.network) { next = classifyWait(bufferedAheadMs: snapshot.bufferedAheadMs) }
        if next == .playing {
            itemStalledSincePlaying = false
            seekSincePlaying = false
            startPending = false
            planHasRun = true
        }
        let trouble = outageGoesOn(snapshot, playing: next == .playing)
        if trouble != transportTrouble {
            transportTrouble = trouble
            calls.append(.transportTroubleChanged(trouble))
        }
        guard next != state else { return calls }
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

    /// An outage begins when a media request fails, and is signalled while
    /// the device is offline, the player reconnects or the engine's reader
    /// does. It lasts until the plan's media data arrives again, as the media
    /// buffered past the playhead rising, or playback runs. No timer, and no
    /// network or API recovering on its own, ends it.
    private mutating func outageGoesOn(_ s: Snapshot, playing: Bool) -> Bool {
        let buffered = s.bufferedAheadMs ?? 0
        if s.connectionTrouble || s.phase.isSourceStalled || mediaRequestFailed {
            mediaRequestFailed = false
            outageAwaitsDataAboveMs = buffered
            return true
        }
        guard let standing = outageAwaitsDataAboveMs else { return false }
        if playing || buffered > standing {
            outageAwaitsDataAboveMs = nil
            return false
        }
        // A seek can lower it; data arriving after that still counts.
        outageAwaitsDataAboveMs = buffered
        return true
    }

    /// A reload's wait, or before the plan first runs or pauses, the start's.
    private var reloadWait: MediaState { startPending ? .waiting(.network) : .waiting(.reload) }

    private func mediaState(_ s: Snapshot) -> MediaState {
        guard s.hasActiveLoad else { return s.wantsToPlay ? reloadWait : .paused }
        if s.reachedEnd || s.phase == .ended || !s.wantsToPlay { return .paused }
        if s.seekInFlight || s.phase == .seeking { return planHasRun ? .waiting(.seek) : .waiting(.network) }
        if let native = s.nativeTransport {
            if native.status == .playing { return .playing }
        } else if s.phase == .playing, !s.engineBuffering, !s.playheadFrozen {
            return .playing
        }
        let reason = s.nativeTransport?.status == .waitingToPlayAtSpecifiedRate
            ? s.nativeTransport?.waitingReason
            : nil
        if s.reloadInProgress || reason == .noItemToPlay { return reloadWait }
        // The engine tore the video down, as it does when the app leaves the
        // foreground: playback stopped, so a stall in progress ends uncounted.
        if s.nativeTransport?.hasItem == false { return .paused }
        if reason == .waitingForCoordinatedPlayback || reason == .interstitialEvent { return .waiting(.pause) }
        if s.nativeTransport?.status == .waitingToPlayAtSpecifiedRate || itemStalledSincePlaying {
            return .waiting(.network)
        }
        switch s.phase {
        case .loading, .rebuffering, .stalled:
            // `.loading` with play intent is a new plan's startup, which the
            // spec times as a wait (`slow_start`).
            return .waiting(.network)
        case .playing where s.engineBuffering || s.playheadFrozen:
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
