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
        /// adds to it where no reader is metered.
        var connectionTrouble: Bool
        /// Media buffered past the playhead, in milliseconds; nil when
        /// unknown, which counts as nothing buffered.
        var bufferedAheadMs: Int? = nil
        /// The engine or AVPlayer reports playing, but the clock has not
        /// moved for a second while the viewer wants to play, or on the
        /// software route not past where the last seek landed
        /// (``SoftwareSeekLanding``). AetherEngine's software host pauses its
        /// clock to rebuffer without reporting it, and AVPlayer can report
        /// `.playing` over a held frame while its media has not arrived.
        var playheadFrozen = false
        /// The engine's reader has received nothing from the origin for
        /// `OUTAGE_NO_DATA_MS` (``UpstreamReadMeter``). False on server HLS,
        /// which has no reader.
        var upstreamSilent = false
        /// The load has an engine reader whose bytes are metered, so its
        /// silence decides an outage, not the engine's `.stalled` phase.
        var readerMetered = false
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
    private(set) var planHasRun = true
    /// The wait in progress on the software route has held more than
    /// `RENDERER_WAIT_AMPLE_MS` buffered: it stays the renderer's until it
    /// ends.
    private var waitHeldAmpleBuffer = false
    /// A media request failed since the last update: an outage begins.
    private var mediaRequestFailed = false
    /// The engine's reader received media data since the last update.
    private var mediaDataArrived = false
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

    /// The engine's reader received bytes from the origin: the plan's media
    /// data arrived, which ends an outage once nothing else holds it.
    mutating func noteMediaDataArrived() {
        mediaDataArrived = true
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
        waitHeldAmpleBuffer = false
        outageAwaitsDataAboveMs = nil
        mediaRequestFailed = false
        mediaDataArrived = false
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
        if next == .waiting(.network) {
            next = classifyWait(bufferedAheadMs: snapshot.bufferedAheadMs, onAVPlayer: snapshot.nativeTransport != nil)
        } else {
            waitHeldAmpleBuffer = false
        }
        if next == .playing {
            itemStalledSincePlaying = false
            seekSincePlaying = false
            startPending = false
            planHasRun = true
        }
        let trouble = outageGoesOn(snapshot, next: next)
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
    ///
    /// On the software route, which resumes once a set lead is buffered, any
    /// wait, a start's or a stall, that comes to hold more than
    /// `RENDERER_WAIT_AMPLE_MS` is the renderer's from then until it ends:
    /// with that much buffered, the network is not what playback waits for.
    /// AVPlayer has no such rule. It waits on a link slightly slower than the
    /// bitrate until it can play through, legitimately with more than that
    /// buffered, and the rule would stop Auto lowering exactly there.
    private mutating func classifyWait(bufferedAheadMs: Int?, onAVPlayer: Bool) -> MediaState {
        let buffered = bufferedAheadMs ?? 0
        if !onAVPlayer, buffered > BufferingQualityController.rendererWaitAmpleMs { waitHeldAmpleBuffer = true }
        if waitHeldAmpleBuffer { return .waiting(.renderer) }
        if state == .waiting(.network) { return .waiting(.network) }
        return buffered > BufferingQualityController.rendererWaitBufferMs ? .waiting(.renderer) : .waiting(.network)
    }

    /// An outage begins when a media request fails, or when playback waits
    /// while the origin has sent nothing for `OUTAGE_NO_DATA_MS` (at once for
    /// a wait that begins on a link already that silent). It is signalled
    /// while the device is offline or the player reconnects, and while the
    /// engine's reader reconnects where its bytes are not metered. A metered
    /// reader that reconnects on its own stall timer while bytes keep coming,
    /// as it does on a link far below the bitrate, is a slow link: the
    /// silence rule finds a real dropout. It lasts until the plan's media
    /// data arrives again, as bytes reaching the reader or the media buffered
    /// past the playhead
    /// rising, or playback runs. No timer, and no network or API recovering
    /// on its own, ends it. A request that keeps receiving, however slowly,
    /// is no outage: that is the slow link the controller exists for.
    private mutating func outageGoesOn(_ s: Snapshot, next: MediaState) -> Bool {
        let buffered = s.bufferedAheadMs ?? 0
        let dataArrived = mediaDataArrived
        mediaDataArrived = false
        let silentWait = s.upstreamSilent && next == .waiting(.network)
        let readerReconnecting = s.phase.isSourceStalled && !s.readerMetered
        if s.connectionTrouble || readerReconnecting || mediaRequestFailed || silentWait {
            mediaRequestFailed = false
            outageAwaitsDataAboveMs = buffered
            return true
        }
        guard let standing = outageAwaitsDataAboveMs else { return false }
        if next == .playing || dataArrived || buffered > standing {
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
            if native.status == .playing, !s.playheadFrozen { return .playing }
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
        if s.nativeTransport?.status == .waitingToPlayAtSpecifiedRate || itemStalledSincePlaying || s.playheadFrozen {
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

/// Where the software route's last seek landed, until its clock moves past
/// it. AetherEngine's software host lands a seek into media it has not
/// loaded as a frozen `.playing`, its clock already on the target, so
/// playback has run again only once the clock moves on from there.
struct SoftwareSeekLanding {
    private enum Landing: Equatable {
        case inFlight
        case at(Double)
    }

    private var landing: Landing?

    /// The clock has not moved past the last seek's landing yet.
    var awaitsAdvance: Bool { landing != nil }

    /// Takes the route's current facts: a seek still out, and the clock.
    mutating func note(seekInFlight: Bool, clock: Double) {
        if seekInFlight {
            landing = .inFlight
        } else if landing == .inFlight {
            landing = clock.isFinite ? .at(clock) : nil
        } else if case .at(let landed)? = landing, clock > landed {
            landing = nil
        }
    }

    mutating func reset() {
        landing = nil
    }
}

/// Whether the clock has moved since AVPlayer began reporting `.playing`.
/// AVPlayer reports `.playing` over a frame it holds ready for display
/// before its clock moves, and on a link far below the bitrate it stays
/// there for minutes, so until a plan has run only the clock moving shows
/// that it plays. The item can publish its start position just before, too
/// recently for the frozen-clock rule to see.
struct PlayingClockAdvance {
    /// The clock when `.playing` began, until it moves past it.
    private var playingFrom: Double?
    private(set) var hasMoved = false

    /// Takes the transport's current facts: whether it reports `.playing`,
    /// and the clock.
    mutating func note(playing: Bool, clock: Double) {
        guard playing else {
            reset()
            return
        }
        guard !hasMoved, clock.isFinite else { return }
        if let playingFrom {
            hasMoved = clock > playingFrom
        } else {
            playingFrom = clock
        }
    }

    /// A plan was adopted: AVPlayer can keep its rate across the item it
    /// replaces, so the new plan's clock is watched afresh.
    mutating func reset() {
        playingFrom = nil
        hasMoved = false
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
