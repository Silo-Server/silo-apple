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
/// Isolation: `AVPlayerBackend` is a plain `final class` whose members are
/// nonisolated except `kickPlaybackAfterExternalStallCleared()`, but every
/// caller drives it from the main actor. Declaring the protocol `@MainActor`
/// keeps that convention explicit for new code while leaving `AVPlayerBackend`
/// untouched — a nonisolated member is a valid witness for a main-actor
/// requirement, and the conformance is stated in an extension so no isolation
/// is inferred onto the class itself.
@MainActor
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

    // MARK: - Recovery handshake (inventory-3 §1.3)
    //
    // Kept as-is in wave 1; deleted in wave 2 when the in-route ladders move
    // behind `RecoveryPolicy`.

    func setRecoverySuspended(_ suspended: Bool, reason: String)
    func setExternalStallSuppression(_ active: Bool)
    func kickPlaybackAfterExternalStallCleared()

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
    var proxyStatsProvider: (() -> PlaybackSourceProxyStats?)? { get set }
    var sourceOutageStateProvider: (() -> Bool)? { get set }
}
