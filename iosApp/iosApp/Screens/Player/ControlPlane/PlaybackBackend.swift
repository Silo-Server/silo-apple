import Foundation

/// The control plane's view of a playback backend.
///
/// This is the surface the control plane drives on `AVPlayerBackend`, lifted
/// to a protocol so `PlaybackEngineSession` can hold `any PlaybackBackend` and
/// so the control plane can be exercised against a test double. It is a *seam*,
/// not a redesign: every member below is `AVPlayerBackend`'s own, including the
/// callback closures, which the engine session turns into an `EngineEvent`
/// stream.
///
/// Deliberately **not** on this protocol: the view-layer surface (`avPlayer`,
/// `subtitleOverlay`, `attachSubtitleOverlay(_:owner:)`,
/// `detachSubtitleOverlay(owner:)`, `subtitleRendererForOverlay`,
/// `videoSurfaceBecameReadyForDisplay()`), which `AVPlayerSurface` reaches on
/// the concrete `AVPlayerBackend`, and the pure static helpers.
///
/// Isolation: nonisolated, like `AVPlayerBackend` itself and like the
/// `PlaybackEngineSession` that holds `any PlaybackBackend` (the same reason
/// `LocalHLSHost` is a plain class). Every caller still drives it from the main
/// queue; making the protocol
/// `@MainActor` would have forced a hop into the backend's own notification
/// observers and `RunLoop.main` timers, which is exactly what the in-route
/// recovery rungs must not gain.
protocol PlaybackBackend: AnyObject {

    // MARK: - Load / transport

    func load(sessionSpec: LoopbackSessionSpec, startTime: Double)
    func loadRemoteHLS(url: URL, headers: [String: String], startTime: Double)
    func loadDirectFile(url: URL, headers: [String: String], startTime: Double)
    func play()
    func pause()
    func isPaused() -> Bool
    func currentTime() -> Double
    func seek(to seconds: Double)
    func setSpeed(_ rate: Double)
    func setUserVolume(_ v: Float)
    func setUserMuted(_ m: Bool)
    var currentUserVolume: Float { get }
    func setMediaTimelineOffset(_ offset: Double)
    func dispose()

    // MARK: - Recovery
    //
    // There is no two-owner recovery handshake: suspension is
    // `RecoveryContext.suspendedReasons`, held by the one `RecoveryDriver`, and
    // the post-outage kick is `RecoveryAction.endOutageRideThrough` performed
    // below. The backend observes and executes; it never decides. Everything
    // `PlaybackEngineSession` needs to drive recovery is here, so the seam holds
    // for any conformer.

    /// Every in-route recovery signal, emitted where a ladder used to decide.
    var onRecoveryObservation: ((RecoveryObservation) -> Void)? { get set }
    /// A live transport sample, pulled by the recovery owner immediately before
    /// each decision so the notification-driven rungs read what they read when
    /// they lived inside the backend.
    var recoveryPlayheadSample: PlayheadSample? { get }
    /// Runs one engine-level `RecoveryAction`. Session- and transport-level
    /// actions are the shell's and are ignored here.
    func perform(_ action: RecoveryAction)
    /// A new engine load started on this backend, including the in-session
    /// reloads a reanchor, a rebuild or a deferred `play()` recovery performs.
    /// The recovery owner resets exactly the per-load state that path reset when
    /// it owned those fields.
    var onEngineReloaded: (() -> Void)? { get set }
    /// The loopback startup ladder was (re-)armed; the payload is the local HLS
    /// server's served-request baseline, which seeds
    /// `RecoveryContext.StartupState`.
    var onStartupLadderArmed: ((UInt64) -> Void)? { get set }
    /// Diagnostic mirror of `RecoveryContext.suspendedReasons`, written by the
    /// engine session whenever the driver's latch changes so the backend's
    /// periodic telemetry can keep naming the holders. Nothing branches on it.
    var suspendedRecoveryReasons: Set<String> { get set }
    /// The recovery owner's `stationaryFor`, for that same telemetry line.
    var recoveryStationarySecondsProvider: (() -> Double)? { get set }

    // MARK: - Tracks / subtitles / chapters

    func selectAudioTrack(_ trackId: Int64)
    func selectSubtitleTrack(_ trackId: Int64?)
    func setSecondarySubtitleTrack(_ trackId: Int64?)
    func registerSidecarSubtitles(_ descriptors: [SidecarSubtitleDescriptor])
    func openLiveSubtitleTrack(slot: SubtitleSlot, label: String?, language: String?)
    func feedLiveSubtitleCue(
        slot: SubtitleSlot,
        eventText: String,
        startMs: Int64,
        durationMs: Int64
    )
    func closeLiveSubtitleTrack(slot: SubtitleSlot)
    func setSubtitleDelay(_ seconds: Double)
    func applySubtitleAppearance(_ appearance: SubtitleAppearance)
    func setServerChapters(_ chapters: [PlayerChapterInfo])
    var hasControlledSubtitleSelection: Bool { get }

    // MARK: - External playback

    var isExternalPlaybackActive: Bool { get }
    var isExternalPlaybackAllowed: Bool { get }

    // MARK: - Callbacks

    var onTimeChange: ((Double) -> Void)? { get set }
    var onDurationChange: ((Double) -> Void)? { get set }
    var onPauseChange: ((Bool) -> Void)? { get set }
    /// Carries the initial-video-display gate's release reason.
    var onFileLoaded: ((String) -> Void)? { get set }
    var onFirstFrame: ((Int) -> Void)? { get set }
    var onError: ((PlaybackFailure) -> Void)? { get set }
    var onEndOfFile: (() -> Void)? { get set }
    var onBufferingChange: ((Bool) -> Void)? { get set }
    var onBufferedAheadChange: ((PlaybackBufferedAhead) -> Void)? { get set }
    var onPlaybackStatsChange: ((PlaybackStats) -> Void)? { get set }
    var onTracksChange: (([PlayerTrack]) -> Void)? { get set }
    var onChaptersChange: (([PlayerChapterInfo]) -> Void)? { get set }
    var onTimelineOffsetChange: ((Double) -> Void)? { get set }
    var onExternalPlaybackActiveChange: ((Bool) -> Void)? { get set }
    var onExternalPlaybackAllowedChange: ((Bool) -> Void)? { get set }
    var onExternalPlaybackUnavailable: (() -> Void)? { get set }
    var onSidecarTracksRegistered: (([SidecarSubtitleDescriptor]) -> Void)? { get set }

    // MARK: - Inbound providers

    var isPictureInPictureActiveProvider: (() -> Bool)? { get set }
    var sourceOutageStateProvider: (() -> Bool)? { get set }
}
