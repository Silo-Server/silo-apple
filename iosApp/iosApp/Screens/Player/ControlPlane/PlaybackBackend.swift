import Foundation

/// The control plane's view of a playback backend.
///
/// This is the surface `PlayerViewModel` already drives on `AVPlayerBackend`
/// (Stage 2 inventory-3 §1.2/§1.3/§1.4/§1.6), lifted to a protocol so the
/// control plane can be exercised against a test double and, from wave 2, so
/// `PlaybackEngineSession` can hold `any PlaybackBackend`. It is a *seam*, not
/// a redesign: every member below is copied from `AVPlayerBackend` verbatim,
/// including the callback closures, which wave 2 replaces with an
/// `EngineEvent` stream.
///
/// Deliberately **not** on this protocol: the view-layer surface (`avPlayer`,
/// `subtitleOverlay`, `attachSubtitleOverlay(_:owner:)`,
/// `detachSubtitleOverlay(owner:)`, `subtitleRendererForOverlay`,
/// `videoSurfaceBecameReadyForDisplay()`), which `AVPlayerSurface` reaches on
/// the concrete `AVPlayerBackend`, and the pure static helpers.
///
/// Isolation: nonisolated, like `AVPlayerBackend` itself and like the
/// `PlaybackEngineSession` that holds `any PlaybackBackend` from wave 2b
/// (design §2.8 as-built, same reason `LocalHLSHost` is a plain class). Every
/// caller still drives it from the main queue; making the protocol
/// `@MainActor` would have forced a hop into the backend's own notification
/// observers and `RunLoop.main` timers, which is exactly what the in-route
/// recovery rungs must not gain.
protocol PlaybackBackend: AnyObject {

    // MARK: - Load / transport (inventory-3 §1.2)

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

    // MARK: - Recovery (wave 2b)
    //
    // The wave-1 two-owner recovery handshake is gone: suspension is
    // `RecoveryContext.suspendedReasons`, held by the one `RecoveryDriver`, and
    // the post-outage kick is `RecoveryAction.endOutageRideThrough(kick:)`
    // performed below. The backend observes and executes; it never decides.

    /// Every in-route recovery signal, emitted where a ladder used to decide.
    var onRecoveryObservation: ((RecoveryObservation) -> Void)? { get set }
    /// A live transport sample, pulled by the recovery owner immediately before
    /// each decision so the notification-driven rungs read what they read when
    /// they lived inside the backend.
    var recoveryPlayheadSample: PlayheadSample? { get }
    /// Runs one engine-level `RecoveryAction`. Session- and transport-level
    /// actions are the shell's and are ignored here.
    func perform(_ action: RecoveryAction)

    // MARK: - Tracks / subtitles / chapters (inventory-3 §1.4)

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

    // MARK: - Callbacks (inventory-3 §1.6)

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

    // MARK: - Inbound providers (inventory-3 §1.6)

    var isPictureInPictureActiveProvider: (() -> Bool)? { get set }
    var sourceOutageStateProvider: (() -> Bool)? { get set }
}
