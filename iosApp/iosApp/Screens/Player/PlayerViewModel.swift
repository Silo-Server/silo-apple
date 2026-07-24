import AVFoundation
import Foundation
import OSLog
import SwiftUI

/// Chapter info type published by `PlayerCore`. The typealias exists
/// so UI code (ChapterSheet, etc.) doesn't depend on the core type directly.
typealias PlayerChapterInfo = PlayerCore.ChapterInfo

private final class OneShotContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ continuation: CheckedContinuation<Void, Error>,
        with result: Result<Void, Error>
    ) {
        lock.lock()
        let shouldResume = !didResume
        if shouldResume {
            didResume = true
        }
        lock.unlock()

        guard shouldResume else { return }
        continuation.resume(with: result)
    }
}

/// Callbacks the VM wires to whichever backend is active. Factored into a
/// struct so both `PlayerCore` and `AVPlayerBackend` get the same handler
/// surface without duplicating the wire-up closures at each backend.
struct PlayerCallbacks {
    var onTimeChange: ((Double) -> Void)?
    var onDurationChange: ((Double) -> Void)?
    var onPauseChange: ((Bool) -> Void)?
    var onFileLoaded: (() -> Void)?
    var onFirstFrame: ((Int) -> Void)?
    var onError: ((String) -> Void)?
    var onEndOfFile: (() -> Void)?
    var onBufferingChange: ((Bool) -> Void)?
    /// Fill progress (0–100) toward the buffering-resume threshold while
    /// buffering. CoreMedia-only; AVPlayer surfaces no comparable signal.
    var onBufferingProgress: ((Double) -> Void)?
    /// Seconds buffered ahead of `currentTime`. AVPlayer-only today; the
    /// CoreMedia path doesn't publish a comparable metric so it stays 0.
    var onBufferedAheadChange: ((Double) -> Void)?
    var onPlaybackStatsChange: ((PlaybackStats) -> Void)?
    var onTracksChange: (([PlayerTrack]) -> Void)?
    var onChaptersChange: (([PlayerChapterInfo]) -> Void)?
}

struct PlayerNextUpEpisode: Identifiable, Hashable {
    let contentId: String
    let seriesId: String?
    let seriesTitle: String?
    let seasonNumber: Int
    let episodeNumber: Int
    let title: String
    let overview: String?
    let runtime: Int?
    let stillUrl: String?
    let stillThumbhash: String?
    let airDate: String?

    var id: String { contentId }
    var episodeLabel: String { "S\(seasonNumber):E\(episodeNumber)" }

    init(episode: EpisodeListItem, seriesId: String?, seriesTitle: String?) {
        contentId = episode.contentId
        self.seriesId = seriesId
        self.seriesTitle = seriesTitle
        seasonNumber = episode.seasonNumber
        episodeNumber = episode.episodeNumber
        let trimmedTitle = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle, !trimmedTitle.isEmpty {
            title = trimmedTitle
        } else {
            title = "Episode \(episode.episodeNumber)"
        }
        overview = episode.overview
        runtime = episode.runtime
        stillUrl = episode.stillUrl
        stillThumbhash = episode.stillThumbhash
        airDate = episode.airDate
    }
}

struct PlayerOnDeckItem: Identifiable, Hashable {
    let sectionItem: SectionItem
    let contentId: String
    let title: String
    let seriesTitle: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let positionSeconds: Double?
    let durationSeconds: Double?
    let artworkUrl: String?
    let artworkThumbhash: String?

    var id: String { contentId }

    var primaryTitle: String {
        if let seriesTitle, !seriesTitle.isEmpty {
            return seriesTitle
        }
        return title
    }

    var secondaryTitle: String? {
        guard let seasonNumber, let episodeNumber else { return nil }
        let episodeLabel = "S\(seasonNumber):E\(episodeNumber)"
        if seriesTitle?.isEmpty == false, !title.isEmpty {
            return "\(episodeLabel) · \(title)"
        }
        return episodeLabel
    }

    var progressFraction: Double {
        guard let positionSeconds,
              let durationSeconds,
              durationSeconds > 0 else {
            return 0
        }
        return min(max(positionSeconds / durationSeconds, 0), 1)
    }

    var minutesRemaining: Int? {
        guard let positionSeconds,
              let durationSeconds,
              durationSeconds > positionSeconds else {
            return nil
        }
        return max(1, Int(((durationSeconds - positionSeconds) / 60).rounded()))
    }

    init(
        item: SectionItem,
        artworkUrl preferredArtworkUrl: String? = nil,
        artworkThumbhash preferredArtworkThumbhash: String? = nil
    ) {
        sectionItem = item
        contentId = item.contentId
        title = item.title
        seriesTitle = item.seriesTitle
        seasonNumber = item.seasonNumber
        episodeNumber = item.episodeNumber
        positionSeconds = item.positionSeconds
        durationSeconds = item.durationSeconds
        artworkUrl = preferredArtworkUrl ?? item.backdropUrl
        artworkThumbhash = preferredArtworkThumbhash ?? item.backdropThumbhash
    }
}

struct PlayerBackendCapabilities: Equatable {
    let supportsBufferedAhead: Bool
    let supportsExternalPrimarySubtitles: Bool
    let supportsSecondarySubtitles: Bool
    let supportsChapters: Bool
    let supportsVideoGravity: Bool
    let supportsHDRToggle: Bool
    let supportsAudioDelay: Bool
    let supportsSubtitleDelay: Bool
    let supportsSubtitleStyling: Bool

    func withSubtitleControls(_ supported: Bool) -> PlayerBackendCapabilities {
        PlayerBackendCapabilities(
            supportsBufferedAhead: supportsBufferedAhead,
            supportsExternalPrimarySubtitles: supportsExternalPrimarySubtitles,
            supportsSecondarySubtitles: supportsSecondarySubtitles,
            supportsChapters: supportsChapters,
            supportsVideoGravity: supportsVideoGravity,
            supportsHDRToggle: supportsHDRToggle,
            supportsAudioDelay: supportsAudioDelay,
            supportsSubtitleDelay: supported,
            supportsSubtitleStyling: supported
        )
    }

    static let coreMedia = PlayerBackendCapabilities(
        supportsBufferedAhead: false,
        supportsExternalPrimarySubtitles: true,
        supportsSecondarySubtitles: true,
        supportsChapters: true,
        supportsVideoGravity: true,
        supportsHDRToggle: true,
        supportsAudioDelay: false,
        supportsSubtitleDelay: true,
        supportsSubtitleStyling: true
    )

    static let avFoundation = PlayerBackendCapabilities(
        supportsBufferedAhead: true,
        supportsExternalPrimarySubtitles: true,
        supportsSecondarySubtitles: true,
        supportsChapters: true,
        supportsVideoGravity: true,
        supportsHDRToggle: false,
        supportsAudioDelay: false,
        supportsSubtitleDelay: false,
        supportsSubtitleStyling: false
    )

    static let macAVFoundation = PlayerBackendCapabilities(
        supportsBufferedAhead: true,
        supportsExternalPrimarySubtitles: true,
        supportsSecondarySubtitles: true,
        supportsChapters: true,
        supportsVideoGravity: false,
        supportsHDRToggle: false,
        supportsAudioDelay: false,
        supportsSubtitleDelay: false,
        supportsSubtitleStyling: false
    )
}

/// Which playback backend is currently serving the loaded stream. Most content
/// goes through `.coreMedia` (FFmpeg demux + VTDecompressionSession). AVPlayer
/// now covers the native-direct allowlist, gated HLS delivery, and the Dolby
/// Vision loopback fallback when PlayerCore rejects a stream.
///
/// The VM switches between cases via `PlaybackExecutionPlan`. Call sites use
/// the shared verb methods (`play` / `pause` / `seek` / …) for operations both
/// backends support, and `core?.X()` for PlayerCore-only features — the no-op
/// on the AVPlayer route stays explicit and greppable.
enum ActivePlayer: @unchecked Sendable {
    case none
    case coreMedia(PlayerCore)
    case avPlayer(AVPlayerBackend)

    var isNone: Bool {
        if case .none = self { return true }
        return false
    }

    func play() {
        switch self {
        case .none:
            return
        case .coreMedia(let c): c.play()
        case .avPlayer(let a): a.play()
        }
    }
    func pause() {
        switch self {
        case .none:
            return
        case .coreMedia(let c): c.pause()
        case .avPlayer(let a): a.pause()
        }
    }
    func seek(to seconds: Double) {
        switch self {
        case .none:
            return
        case .coreMedia(let c): c.seek(to: seconds)
        case .avPlayer(let a): a.seek(to: seconds)
        }
    }
    func currentTime() -> Double {
        switch self {
        case .none: return 0
        case .coreMedia(let c): return c.currentTime()
        case .avPlayer(let a): return a.currentTime()
        }
    }
    func isPaused() -> Bool {
        switch self {
        case .none: return true
        case .coreMedia(let c): return c.isPaused()
        case .avPlayer(let a): return a.isPaused()
        }
    }
    func dispose() {
        switch self {
        case .none:
            return
        case .coreMedia(let c): c.dispose()
        case .avPlayer(let a): a.dispose()
        }
    }
    func prepareToBackground() {
        switch self {
        case .none:
            return
        case .coreMedia(let c): c.prepareToBackground()
        case .avPlayer(let a): a.prepareToBackground()
        }
    }
    func setSpeed(_ rate: Double) {
        switch self {
        case .none:
            return
        case .coreMedia(let c): c.setSpeed(rate)
        case .avPlayer(let a): a.setSpeed(rate)
        }
    }
    func setVolume(_ v: Float) {
        switch self {
        case .none: return
        case .coreMedia(let c): c.setUserVolume(v)
        case .avPlayer(let a): a.setUserVolume(v)
        }
    }
    func setMuted(_ m: Bool) {
        switch self {
        case .none: return
        case .coreMedia(let c): c.setUserMuted(m)
        case .avPlayer(let a): a.setUserMuted(m)
        }
    }
    func volume() -> Float {
        switch self {
        case .none: return 1.0
        case .coreMedia(let c): return c.currentUserVolume
        case .avPlayer(let a): return a.currentUserVolume
        }
    }
    func isMuted() -> Bool {
        switch self {
        case .none: return false
        case .coreMedia(let c): return c.currentUserMuted
        case .avPlayer(let a): return a.currentUserMuted
        }
    }

    /// Unwrap the `PlayerCore` if this is the .coreMedia arm. Returns nil
    /// whenever the active route is AVPlayer-backed, so PlayerCore-only
    /// operations become no-ops rather than silently running against a dead
    /// decoder.
    var core: PlayerCore? {
        if case .coreMedia(let c) = self { return c }
        return nil
    }

    /// Unwrap the `AVPlayerBackend` for UI surface rendering.
    var avBackend: AVPlayerBackend? {
        if case .avPlayer(let a) = self { return a }
        return nil
    }

    init(renderTarget: PlaybackRenderTarget) {
        switch renderTarget {
        case .none:
            self = .none
        case .coreMedia(let core):
            self = .coreMedia(core)
        case .avPlayer(let backend):
            self = .avPlayer(backend)
        }
    }
}

@Observable
class PlayerViewModel {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "Player"
    )

    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var title: String = ""
    var isLoading = true
    var isBuffering = false
    /// Fill progress (0–100) toward the buffering-resume threshold; nil
    /// when not buffering or when the active backend doesn't report it.
    var bufferingProgress: Double?
    var error: String?
    var showControls = false
    var activeNotice: PlayerNotice?
    var remoteDismissToken: UUID?
    var audioTracks: [PlayerTrack] = []
    var subtitleTracks: [PlayerTrack] = []
    /// Server-resolved preferred subtitle language for the current item,
    /// snapshotted at prepare time. Used only to float the matching
    /// language group to the top of the displayed track lists.
    private var subtitleOrderingLanguage: String?
    var chapters: [PlayerChapterInfo] = []
    var introRange: TimeRange?
    var creditsRange: TimeRange?
    var introAutoSkipCountdownSeconds: Int?
    var selectedAudioId: Int64?
    var selectedSubtitleId: Int64?
    var selectedSecondarySubtitleId: Int64?
    var qualityOptions: [ApplePlaybackQualityOption] = [ApplePlaybackQuality.auto]
    var activeQualityId: String = ApplePlaybackQuality.autoId
    var isQualitySwitching = false
    var qualitySwitchError: String?
    var isScrubbing = false
    var scrubPreviewTime: Double = 0
    /// True while the iOS touch-and-hold fast-forward gesture is engaged.
    /// The temporary rate is applied straight to the backend and never
    /// persisted, so releasing always restores `settings.playbackSpeed`.
    var isHoldFastForwarding = false
    /// Loading status of the primary + secondary subtitle slots. Set
    /// by `PlayerCore` whenever a sidecar fetch starts, completes, or
    /// errors. UI can key a spinner / silent-failure indicator off
    /// this per slot.
    var subtitleLoadStatus: [SubtitleSlot: SubtitleLoadStatus] = [
        .primary: .idle, .secondary: .idle
    ]

    /// Seconds of media buffered ahead of `currentTime`. Populated by
    /// `AVPlayerBackend` (KVO on `loadedTimeRanges`); the CoreMedia pipeline
    /// has a small demuxer queue but no comparable range, so it stays 0 and
    /// the scrubber simply doesn't draw the buffered layer.
    var bufferedAheadSeconds: Double = 0
    var playbackStats: PlaybackStats = .empty
    var showNextUpScreen = false
    var nextUpEpisode: PlayerNextUpEpisode?
    var nextUpOnDeckItems: [PlayerOnDeckItem] = []
    var isLoadingNextUpEpisode = false
    var isLoadingNextUpOnDeck = false
    var nextUpLookupError: String?
    /// Set when an autoplay-initiated `beginFreshLoad` fails (timeout or any
    /// other error during `startSession`). Surfaces a recoverable message in
    /// the Next Up screen's `finishedMessage` instead of taking over the whole
    /// player with `viewModel.error`. Cleared by `resetPublishedLoadState` on
    /// the next successful load.
    var nextUpStartError: String?
    var nextUpCountdownSeconds: Int?
    var nextUpCountdownTotalSeconds: Int = 10
    var nextUpScreenVideoEnded = false
    private enum NextUpPresentationSource {
        case automatic
        case hud
    }
    private var nextUpPresentationSource: NextUpPresentationSource = .automatic
    private var serverProvidedChapters: [PlayerChapterInfo] = []

    /// Secondary metadata surfaced to the player overlay. Populated from
    /// `WatchDetail` + `FileVersion` once `PlaybackSessionBridge.startSession`
    /// resolves. Empty until then; the overlay hides the corresponding rows.
    var metadata: PlayerMetadata = .empty

    /// True while the tvOS floating options HUD is presented. Single source
    /// of truth so both `TVPlayerControls` (presentation) and `PlayerView`
    /// (shell-level Menu / exit handling) can agree on state without relying
    /// on an indirection flag. Driven by `openHUD()` / `closeHUD()`.
    var isHUDPresented = false

    var showIntroSkip: Bool {
        guard let introRange else { return false }
        return currentTime >= introRange.start && currentTime < introRange.end
    }

    /// Signed rate of an in-flight seek session. Zero when the user isn't
    /// in seek mode. Positive = forward, negative = backward. Magnitudes
    /// are drawn from `Self.seekRates`. Entered by holding an arrow past
    /// the tap threshold; exited via Select (commit) or Menu (cancel).
    /// Within the session, D-pad Left/Right adjust the rate along the
    /// signed ladder (-8, -4, -2, -1, +1, +2, +4, +8).
    ///
    /// Observed by the tvOS shell to render the indicator chip and to
    /// keep the focus sink alive so press events aren't orphaned by a
    /// focus shift to the scrubber.
    var holdSeekRate: Int = 0
    /// Convenience — any non-zero rate means we're actively seeking.
    var isHoldSeeking: Bool { holdSeekRate != 0 }

    #if os(tvOS)
    enum TVHUDEntryPoint: Equatable {
        case settings
        case playback
    }

    var requestedTVHUDEntryPoint: TVHUDEntryPoint?
    #endif

    /// Signed speed ladder the user steps through with Left/Right taps
    /// during a seek session. No zero: "pause" is spelled as Select
    /// (commit) or Menu (cancel) rather than a neutral rate. The ladder
    /// tops out at 32× so a long file can be traversed in a few seconds
    /// of tapping; the auto-ramp on entry only reaches 8× so the faster
    /// rates require deliberate user steering.
    static let seekRates: [Int] = [-32, -16, -8, -4, -2, -1, 1, 2, 4, 8, 16, 32]

    /// Single source of truth for the playback backend. Starts empty, then
    /// follows the execution plan into CoreMedia or AVPlayer routes on every
    /// Apple platform. UI surface rendering and PlayerCore-only settings paths
    /// pattern-match on this.
    private(set) var activePlayer: ActivePlayer
    private var activeRouteKind: PlaybackEngineKind

    #if DEBUG
    /// Drives the `debugStartFakeLiveSubtitles()` stub. Repeating timer
    /// that feeds canned live cues at `currentTime+` to prove the M2 live
    /// subtitle render seam end-to-end with no server. DEBUG-only.
    private var debugLiveSubtitleTimer: Timer?
    private var debugLiveSubtitleTrack = LiveSubtitleTrack()
    #endif
    /// Canonical user volume/mute, owned by the VM rather than the backend.
    /// Backends are rebuilt on every quality switch / loopback fallback and
    /// come up at full volume, so the VM re-applies these after each swap and
    /// reports them to the cast UI — otherwise a remote-set level is lost.
    private var userVolume: Float = 1.0
    private var userMuted = false
    private(set) var activeExecutionPlan: PlaybackExecutionPlan?
    private var sourceProxy: PlaybackSourceProxy?
    private var streamLoadGeneration: UInt64 = 0
    /// Convenience for PlayerSurface attach + settings sheet poke-throughs.
    /// Returns nil whenever the active route is AVPlayer-backed.
    var player: PlayerCore? { activePlayer.core }
    /// Convenience for `AVPlayerSurface(backend:)` rendering when on the
    /// AVPlayer-backed routes.
    var avPlayerBackend: AVPlayerBackend? { activePlayer.avBackend }
    var backendCapabilities: PlayerBackendCapabilities {
        #if os(macOS)
        switch activePlayer {
        case .none:
            return .macAVFoundation
        case .coreMedia:
            return .coreMedia
        case .avPlayer(let backend):
            return PlayerBackendCapabilities.macAVFoundation
                .withSubtitleControls(backend.hasControlledSubtitleSelection)
        }
        #else
        let base = currentRouteCapabilities.backendCapabilities
        if case .avPlayer(let backend) = activePlayer {
            return base.withSubtitleControls(backend.hasControlledSubtitleSelection)
        }
        return base
        #endif
    }
    var activeRouteLabel: String {
        if let activeExecutionPlan {
            return activeExecutionPlan.appPlaybackLabel
        }
        return currentRouteCapabilities.routeLabel
    }
    /// One-line, user-facing route description for the player HUD:
    /// engine family plus delivery, e.g. "SiloPlayer · Direct Stream".
    var playbackRouteDisplay: String {
        guard let activeExecutionPlan else {
            return currentRouteCapabilities.routeLabel
        }
        return "\(activeExecutionPlan.routeFamily.displayLabel) · \(activeExecutionPlan.appPlaybackLabel)"
    }
    var routeStatusRows: [PlayerRouteStatusRow] {
        let capabilities = currentRouteCapabilities
        var rows = [
            PlayerRouteStatusRow(label: "Playback", value: activeRouteLabel),
            PlayerRouteStatusRow(label: "Route", value: capabilities.routeLabel),
            PlayerRouteStatusRow(label: "Subtitles", value: capabilities.subtitleContractSummary),
            PlayerRouteStatusRow(label: "Audio delay", value: capabilities.audioDelay.state.shortLabel),
            PlayerRouteStatusRow(label: "Subtitle styling", value: capabilities.subtitleStyling.state.shortLabel),
            PlayerRouteStatusRow(label: "Now Playing", value: capabilities.nowPlayingIntegration.state.shortLabel),
            PlayerRouteStatusRow(label: "Picture in Picture", value: capabilities.pictureInPicture.state.shortLabel),
            PlayerRouteStatusRow(label: "External playback", value: capabilities.externalPlayback.state.shortLabel),
            PlayerRouteStatusRow(label: "Premium claims", value: capabilities.premiumClaims.summary)
        ]
        if let activeExecutionPlan {
            rows.insert(
                PlayerRouteStatusRow(
                    label: "Family",
                    value: activeExecutionPlan.routeFamily.diagnosticsLabel
                ),
                at: 2
            )
            rows.insert(
                PlayerRouteStatusRow(
                    label: "Implementation",
                    value: activeExecutionPlan.implementationRoute
                ),
                at: 3
            )
        }
        return rows
    }
    var routeDecisionSummary: String? {
        guard let activeExecutionPlan else { return nil }
        return humanReadableRouteReason(activeExecutionPlan.reason)
    }
    var routeWarnings: [String] {
        activeExecutionPlan?.degradationWarnings ?? []
    }
    var hasTrackSelectionOptions: Bool { !audioTracks.isEmpty || !subtitleTracks.isEmpty }
    var supportsSecondarySubtitles: Bool { backendCapabilities.supportsSecondarySubtitles }
    /// `subtitleTracks` grouped by language and sorted by preferred format
    /// for display. The stored array stays in source/append order (the
    /// selection and track-replacement logic depends on it); ordering is a
    /// display-only projection. The two in-player pickers iterate this.
    var orderedSubtitleTracks: [PlayerTrack] {
        orderedSubtitles(subtitleTracks)
    }
    var availableSecondarySubtitleTracks: [PlayerTrack] {
        guard backendCapabilities.supportsSecondarySubtitles else { return [] }
        switch activePlayer {
        case .none:
            return []
        case .coreMedia:
            return orderedSubtitles(subtitleTracks)
        case .avPlayer:
            return orderedSubtitles(subtitleTracks.filter { SubtitleTrackIdSpace.isSidecar($0.trackId) })
        }
    }
    private func orderedSubtitles(_ tracks: [PlayerTrack]) -> [PlayerTrack] {
        SubtitleDisplayOrder.order(tracks, preferredLanguage: subtitleOrderingLanguage) { track in
            SubtitleDisplayOrder.Descriptor(
                language: track.lang,
                codec: track.codec,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                isDefault: track.isDefault
            )
        }
    }
    /// Set in `cleanup()` / `deinit`. All async callbacks into the VM gate
    /// on this so a late-landing handoff signal can't spin up a fresh
    /// pipeline on a view that's already gone.
    private var isDisposed = false
    #if os(iOS)
    /// Mirrors the last `ScenePhase` handed to `handleScenePhase`. Lets the
    /// AirPlay route observer tell "receiver disconnected while we're in the
    /// background" (pause) from a normal foreground disconnect (keep playing
    /// on the phone).
    private var isSceneBackgrounded = false
    /// Gives automatic PiP a bounded window to publish `willStart` after the
    /// scene backgrounds. If no transition arrives, normal pause policy wins.
    private var pictureInPictureBackgroundGraceTask: Task<Void, Never>?
    #endif
    /// True after the active backend reports natural EOF. Used to keep the
    /// UI in a terminal paused state without letting tail-drain callbacks
    /// overwrite it or surface a false decode error.
    private var hasReachedEndOfFile = false
    let settings = PlayerSettings.shared
    let sleepTimer = SleepTimer()
    private let nowPlaying = NowPlayingController()
    /// Optional poster / backdrop URLs supplied by the presenter so the
    /// now-playing widget can publish artwork without re-fetching the
    /// catalog item just for poster URLs. Populated via
    /// `applyArtworkURLHints`. Nil falls back to a `/catalog/items/{id}`
    /// fetch in `pushNowPlayingArtwork`.
    private var artworkPosterURLHint: String?
    private var artworkBackdropURLHint: String?

    /// Rate-limits Now Playing updates. The OS animates scrubber progress
    /// between updates based on `playbackRate`, so we only need to push an
    /// elapsed-time field once every couple of seconds.
    private var lastNowPlayingPush: Date = .distantPast

    private let sessionBridge = PlaybackSessionBridge()
    private let recoveryPlanner = PlaybackRecoveryPlanner()
    @ObservationIgnored
    private var realtimeClient: PlaybackRealtimeClient!
    @ObservationIgnored
    private var playbackCoordinator: PlaybackCoordinator!
    /// Owns the in-player AI subtitle suite (translate / transcribe over
    /// polling). Constructed in `init` with closures into this VM's session
    /// state + the sidecar-registration handoff, and `reset()` on teardown.
    /// `@ObservationIgnored` because the UI binds to the controller's own
    /// `@Observable` state, not through the VM.
    ///
    /// Lazy so the `@MainActor`-isolated controller is constructed on first
    /// access (always on the main actor — the player UI, job commands, and
    /// `cleanup()` are all main-isolated) rather than from the nonisolated
    /// `init()`, which can't synchronously build a main-actor type.
    ///
    /// The controller (and its coordinator/adapters) are `@MainActor`-isolated
    /// initializers, so they are built inside `MainActor.assumeIsolated`: the
    /// lazy initializer body runs in this Swift-5-mode type's nonisolated
    /// context, but first access is always on the main actor, so asserting that
    /// here is correct and keeps the seams' initializers properly isolated (no
    /// Swift-6 actor-isolation warnings).
    @ObservationIgnored
    private(set) lazy var subtitleAI: SubtitleAIController = MainActor.assumeIsolated {
        SubtitleAIController(
            mediaFileId: { [weak self] in self?.currentSelectedVersion?.fileId },
            currentTime: { [weak self] in self?.currentTime ?? 0 },
            sessionId: { [weak self] in self?.activePlaybackSessionId },
            realtimeUnavailable: { [weak self] in !(self?.subtitleAILiveOverlayAvailable ?? false) },
            liveCoordinator: self.makeLiveSubtitleCoordinator(),
            handoffContext: { [weak self] in self?.makeSubtitleHandoffContext() },
            registerAndSelectDescriptor: { [weak self] descriptor in
                self?.registerCompletedAISubtitle(descriptor)
            },
            registerDescriptorWithoutSelecting: { [weak self] descriptor in
                self?.registerCompletedAISubtitle(descriptor, autoSelect: false)
            }
        )
    }

    /// Last-known realtime websocket connectivity, mirrored from the actor so
    /// the synchronous subtitle-AI submit path can tell the difference between
    /// "socket connected" and "not failed yet". A fast first iOS submit can
    /// beat the websocket handshake; treating that as live-ready asks the
    /// server to stream cues into a socket that cannot receive them yet.
    private var realtimeConnectedSnapshot = false

    /// Last-known realtime websocket availability. This flips only when the
    /// circuit breaker gives up; the separate connectivity snapshot above
    /// covers normal connecting/reconnecting gaps.
    private var realtimeUnavailableSnapshot = false

    /// Whether the realtime websocket can currently receive live AI-subtitle
    /// cues. The player-surface preparing/pause flow now starts immediately on
    /// submit for both live and poll-only jobs; this flag only decides whether
    /// the request includes `session_id` for realtime cue streaming.
    var subtitleAILiveOverlayAvailable: Bool {
        realtimeConnectedSnapshot && !realtimeUnavailableSnapshot && activePlaybackSessionId != nil
    }

    /// The `observeUnavailability` token, retained so `cleanup()` can remove
    /// the observer explicitly. `unbind()` preserves observers across fresh
    /// load cycles because this snapshot is a long-lived PlayerViewModel concern.
    private var realtimeUnavailabilityObserverToken: UUID?
    private var realtimeConnectivityObserverToken: UUID?
    private var cleanupCompletionTask: Task<Void, Never>?

    /// Build the live-subtitle coordinator with adapters bound to this VM. The
    /// adapters touch the VM's playback + live-track + notice surface, so they
    /// live in this file. Called only from the `subtitleAI` lazy initializer,
    /// which already runs inside `MainActor.assumeIsolated`; the adapters and
    /// coordinator have `@MainActor` initializers, so this constructs them on
    /// the asserted main actor. It only wires immutable closures.
    @MainActor
    private func makeLiveSubtitleCoordinator() -> LiveSubtitleCoordinator {
        let controls = LiveSubtitlePlaybackAdapter(owner: self)
        let sink = LiveSubtitleSinkAdapter(owner: self)
        return LiveSubtitleCoordinator(
            controls: controls,
            sink: sink,
            // The coordinator snapshots the live `selectedSubtitleId` at
            // `started` (the selection it restores on failure).
            selectionSnapshot: { [weak self] in self?.selectedSubtitleId }
        )
    }
    private var hideControlsTask: Task<Void, Never>?
    private var noticeDismissTask: Task<Void, Never>?
    /// Id of the live-subtitle "Preparing subtitles" notice while it's on
    /// screen, so `dismissLiveSubtitlePreparingNotice()` can clear it the moment
    /// playback resumes without clobbering a newer, unrelated notice.
    private var liveSubtitlePreparingNoticeId: UUID?
    private var remoteDismissTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var staleSessionRecoveryTask: Task<Void, Never>?
    /// In-flight silent renewal of a lost direct-play session (same file,
    /// same plan, new session id — player and cache untouched). Keyed by the
    /// stale session id for single-flight; transient failures retry on the
    /// next trigger up to `backgroundRenewalTransientFailureLimit` before
    /// escalating to the visible stale-session renewal.
    private var backgroundRenewalTask: Task<Void, Never>?
    private var backgroundRenewalSessionId: String?
    private var backgroundRenewalTransientFailures = 0
    private static let backgroundRenewalTransientFailureLimit = 3
    /// Origin-outage ride-through (workstream B): while the source proxy is
    /// parked in an outage, playback rides its buffered runway with no UI
    /// change; this task polls server health (nudging an immediate re-probe
    /// when it returns) and escalates to the visible outage recovery only
    /// when the budget expires. A "Reconnecting" notice appears only if the
    /// player actually starts buffering during the outage.
    private var sourceOutageRideThroughTask: Task<Void, Never>?
    private var sourceOutageActive = false
    private var sourceOutageNoticeShown = false
    private var serverOutageRecoveryTask: Task<Void, Never>?
    private var serverOutageRecoveryGeneration: UInt64 = 0
    private var activeServerOutageRecoverySessionId: String?
    /// Held so the init-time `refreshSettingsFromServer` call can be cancelled
    /// from `cleanup()`. Without a handle the task lingered on a dismissed VM
    /// and could observe `self` after dispose.
    private var settingsRefreshTask: Task<Void, Never>?
    private var freshLoadTask: Task<Void, Never>?
    private var freshLoadGeneration: UInt64 = 0
    private var protocolV3ReplanTask: Task<Void, Never>?
    private var nextUpLookupTask: Task<Void, Never>?
    private var nextUpOnDeckTask: Task<Void, Never>?
    private var nextUpCountdownTask: Task<Void, Never>?
    private var interruptionRecoveryTask: Task<Void, Never>?
    /// Trailing-edge skip debounce: each tap updates the preview and resets
    /// this timer. The seek fires exactly once, after `skipDebounceNanos` of
    /// quiet. A leading-edge seek was tempting for responsiveness but led
    /// to visible stutter on bursts — the video would seek to tap #1, play
    /// briefly, and then jump again on the trailing commit. A single
    /// deferred seek is smooth at any burst length.
    private var skipDebounceTask: Task<Void, Never>?
    private let skipDebounceNanos: UInt64 = 200_000_000 // 200ms

    /// Drives the repeating preview advance while a seek session is
    /// active. Ticks at `holdSeekTickNanos`, advancing `scrubPreviewTime`
    /// by `holdSeekBaseStep * holdSeekRate` seconds each tick. Runs
    /// until `commitHoldSeek` / `cancelHoldSeek`.
    private var holdSeekTask: Task<Void, Never>?
    /// Auto-ramps the rate magnitude 1 → 2 → 4 → 8 during the first ~4 s
    /// of a hold so the user gets acceleration without having to manually
    /// tap up. Cancelled the moment the user manually adjusts the rate
    /// — they've taken control, stop second-guessing them.
    private var holdSeekAutoRampTask: Task<Void, Never>?
    private static let holdSeekBaseStep: Double = 2.0 // seconds per tick at 1x
    private static let holdSeekTickNanos: UInt64 = 100_000_000 // 100ms (10Hz)

    /// Seek-in-flight filter: both the pre-seek playhead and the target we
    /// asked the player to jump to. `onTimeChange` reports that are closer
    /// to `seekOriginTime` than to `seekTargetTime` are treated as stale
    /// pipeline drainage and dropped. This is direction-agnostic — works
    /// for forward and backward seeks — and handles back-to-back seeks
    /// where the pipeline is still draining from *before* the previous
    /// seek. The filter releases as soon as a report crosses the midpoint
    /// between origin and target, which is the earliest point we can
    /// confidently say the new position has landed. Safety timeout below
    /// drops the filter if no matching report arrives (e.g. transport
    /// error on HLS transcode), since a stuck filter would pin the
    /// scrubber to the optimistic target forever.
    private var seekOriginTime: Double?
    private var seekTargetTime: Double?
    private var seekFilterTimeoutTask: Task<Void, Never>?
    private static let seekFilterNanos: UInt64 = 5_000_000_000 // 5s
    /// Remux HLS manifests are generated from the requested origin and then
    /// presented to AVPlayer as a local 0-based timeline. Keep the movie-time
    /// offset here so UI/progress reporting remain full-runtime based.
    private var playbackTimelineOffset: Double = 0

    /// Identity of the active offline download when playback was prepared
    /// locally (no server session). While set, watch progress is routed to
    /// `DownloadManager.recordOfflineProgress` — which queues it for the
    /// next `/sync/progress` flush — instead of the session bridge, so
    /// nothing on this path ever hits a server session/progress endpoint.
    private struct OfflinePlaybackContext {
        let downloadId: String
        let mediaItemId: String
    }
    private var offlinePlaybackContext: OfflinePlaybackContext?
    /// Mirrors the server's default watched threshold (90%) so an offline
    /// watch latches `completed` — and with it delete-watched retention and
    /// the reclaim sheet — the same way an online session would.
    private static let offlineWatchedFraction: Double = 0.9

    /// Cached external subtitle URLs returned by the server; added to the
    /// player once the file has loaded.
    private var pendingExternalSubtitles: [SubtitleUrl] = []
    /// Full sidecar subtitle set for the current item. Unlike
    /// `pendingExternalSubtitles`, this survives the first successful
    /// registration so route recovery can re-register sidecars later.
    private var knownExternalSubtitles: [SubtitleUrl] = []
    private struct TrackSelectionSnapshot {
        let normalizedTitle: String?
        let normalizedLanguageCode: String?
        let normalizedCodec: String?
        let normalizedAudioLayout: String?
        let isForced: Bool
        let isExternal: Bool
        let isHearingImpaired: Bool

        init(track: PlayerTrack) {
            normalizedTitle = track.normalizedTitle?.lowercased()
            normalizedLanguageCode = track.normalizedLanguageCode?.lowercased()
            normalizedCodec = Self.normalized(track.codec)
            normalizedAudioLayout = Self.normalized(track.audioChannelsLayout)
            isForced = track.isForced
            isExternal = track.isExternal
            isHearingImpaired = track.isHearingImpaired
        }

        func score(against track: PlayerTrack) -> Int {
            var score = 0
            if normalizedTitle == track.normalizedTitle?.lowercased() { score += 4 }
            if normalizedLanguageCode == track.normalizedLanguageCode?.lowercased() { score += 3 }
            if normalizedCodec == Self.normalized(track.codec) { score += 2 }
            if normalizedAudioLayout == Self.normalized(track.audioChannelsLayout) { score += 2 }
            if isForced == track.isForced { score += 1 }
            if isExternal == track.isExternal { score += 1 }
            if isHearingImpaired == track.isHearingImpaired { score += 1 }
            return score
        }

        private static func normalized(_ value: String?) -> String? {
            value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
    }
    private var pendingRecoveredAudioSelection: TrackSelectionSnapshot?
    private var pendingRecoveredSubtitleSelection: TrackSelectionSnapshot?
    private var pendingRecoveredSecondarySubtitleId: Int64?
    private static let nativeDirectContainers: Set<String> = ["mp4", "mov", "m4v"]
    private static let nativeDirectVideoCodecs: Set<String> = ["h264", "hevc"]
    private static let nativeDirectAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "alac", "mp3"]
    private static let nativeDirectSubtitleCodecs: Set<String> = ["mov_text", "tx3g", "wvtt", "webvtt"]

    /// Server-supplied preferred track indices (ffmpeg stream indices). Kept
    /// until we've observed a matching track in the core's track-list and
    /// applied it, or until the user makes a manual selection.
    private var pendingAudioFfIndex: Int?
    private var pendingSubtitleFfIndex: Int?
    /// True when the most recent `loadAndPlay` came in with an explicit
    /// subtitle index from the caller (route arg / detail screen). The
    /// auto-resolver yields to the user in that case.
    private var hasExplicitSubtitleChoice: Bool = false
    /// External subtitle picks don't have an FFmpeg stream index, so a
    /// reload/resume has to remember the synthesised sidecar `trackId`
    /// and re-apply it once `subtitle_urls` have been registered again.
    private var pendingSidecarSubtitleTrackId: Int64?
    /// M5 seamless live→persisted swap: the synthetic AI-live track id whose
    /// row + libass track must be closed AFTER the handed-off persisted track is
    /// selected. Set by `armDeferredLiveSubtitleClose` when a live job completes;
    /// consumed in `appendSidecarTracks` immediately after the persisted
    /// selection is applied, so there is never a frame with no subtitle between
    /// dropping the live row and the persisted track landing.
    private var pendingLiveSubtitleCloseTrackId: Int64?
    /// Bounded fallback timer that closes a deferred live track if the persisted
    /// selection never lands. Cancelled when the seamless close fires or on
    /// cleanup.
    private var deferredLiveSubtitleCloseTask: Task<Void, Never>?
    /// Snapshot of the server-cascaded subtitle prefs for the currently
    /// loaded content. Captured from `WatchDetail.effective_*` at
    /// session-start time and consumed once the player reports its
    /// track list. Cleared on cleanup so a follow-up load doesn't apply
    /// stale prefs to a different file.
    private var prefsForCurrentItem: PrefsSnapshot?
    private struct PrefsSnapshot {
        let preferredLanguage: String?
        let mode: SubtitleMode?
        let showForced: Bool
        let trackSignature: SubtitleTrackSignature?
    }
    /// Set after the resolver has fired once for the current item so we
    /// don't keep re-evaluating (and overriding the user) on every
    /// subsequent track-list update.
    private var prefsResolvedForCurrentItem: Bool = false
    private var resolvedServerUrl: String = ""
    private var currentDeliveryStrategy: PlaybackDeliveryStrategy = .direct
    private var currentWatchDetail: WatchDetail?
    private var currentSelectedVersion: FileVersion?
    private var activePreparedProtocolV3: PreparedPlaybackV3?
    private var activePlaybackSessionId: String?
    private var autoSkippedIntroKey: String?
    private var autoSkipIntroCancelledKey: String?
    private var pendingAutoSkipIntroKey: String?
    private var autoSkipIntroCountdownTask: Task<Void, Never>?
    private var staleSessionRecoverySessionId: String?
    private var hasAttemptedNativeDirectRouteRecovery = false
    private var hasAttemptedSiloRouteCompatibilityFallback = false
    private struct LoadRequest {
        let contentId: String
        let preferredFileId: Int?
        let preferredAudioTrackIndex: Int?
        let preferredSubtitleTrackIndex: Int?
        let preferredSidecarSubtitleTrackId: Int64?
        let startFromBeginning: Bool
        /// Set for local playback of a completed download. Routes the
        /// prepare through `OfflinePlaybackBuilder` instead of a server
        /// session, so retry after an error stays on the offline path.
        var offlineDownloadId: String? = nil
        /// Explicit quality for this load (mid-stream quality-change replan);
        /// wins over `PlayerSettings.preferredQuality` in the bridge.
        var preferredQualityOverride: String? = nil
    }

    /// Where a `beginFreshLoad` invocation came from. Determines (a) whether
    /// `startSession` is bounded by a timeout and (b) how a load failure is
    /// surfaced to the user. The trigger is orthogonal to the `LoadRequest`
    /// itself, so it's threaded as a separate parameter.
    private enum LoadOrigin {
        /// User picked an item — no timeout, full-screen error on failure.
        case userInitiated
        /// Auto-play hand-off from the Next Up postroll — timeout-bounded,
        /// failures restore the postroll with `nextUpStartError` set.
        case autoplay
        /// Automatic recovery from a foreground-interruption. Failures stay on
        /// the player surface instead of using the Next Up postroll.
        case recovery
    }

    private enum BeginFreshLoadError: Error {
        case playerDisposeTimeout
        case startSessionTimeout
    }

    private static let autoplayPlayerDisposeTimeout: TimeInterval = 5
    private static let autoplayStartSessionTimeout: TimeInterval = 15
    private struct PlaybackInterruptionState {
        var wasPlaying: Bool
        var positionSeconds: Double
        var recoveryDeadline: Date
        var didAutoRecover: Bool
        var isPending: Bool
    }
    private var lastLoadRequest: LoadRequest?
    private var playbackInterruption: PlaybackInterruptionState?
    private static let interruptionRecoveryTimeout: TimeInterval = 3
    private static let interruptionResumeSuccessThresholdSeconds: Double = 0.1
    private static let serverOutageRecoveryInitialDelay: TimeInterval = 1
    private static let serverOutageRecoveryMaxDelay: TimeInterval = 8
    private static let serverOutageRecoveryTimeout: TimeInterval = 90
    private static let nextUpCountdownDefaultSeconds = 10
    private static let nextUpHUDCountdownThresholdSeconds: Double = 100
    private static let introAutoSkipCountdownDefaultSeconds = 5
    static var nextUpCountdownTotal: Int { nextUpCountdownDefaultSeconds }
    private static let nearEndPlaybackErrorThresholdSeconds: Double = 8
    private struct SuspendedPlaybackContext {
        let request: LoadRequest
        let resumePosition: Double
    }
    private var suspendedPlayback: SuspendedPlaybackContext?
    private var nextUpAutoplayCancelled = false
    /// Set when the user taps Keep Watching; suppresses re-presenting the
    /// pre-end Next Up prompt while the playhead stays inside the prompt
    /// window. Cleared when the playhead leaves the window (seek back) or a
    /// new item loads, so the prompt can appear again naturally. Does not
    /// apply to the end-of-playback screen.
    private var nextUpPromptDismissed = false
    private(set) var contentIdsNeedingDetailRefresh: Set<String> = []
    private static let suspendedPlaybackNotice = PlayerNotice(
        title: "Playback paused",
        message: "Playback stopped when Apple TV went to sleep. Press Play to resume.",
        tone: .info
    )
    private static let appleHLSRouteFeatureFlagKey = "player.apple.avplayer_hls_route_enabled"
    var isBackgroundSuspended: Bool { suspendedPlayback != nil }
    var suspendedNotice: PlayerNotice? {
        isBackgroundSuspended ? Self.suspendedPlaybackNotice : nil
    }
    var nextUpCarouselItems: [PlayerOnDeckItem] {
        let hiddenIds = Set([lastLoadRequest?.contentId, nextUpEpisode?.contentId].compactMap { $0 })
        return nextUpOnDeckItems.filter { !hiddenIds.contains($0.contentId) }
    }

    var canShowNextUpScreen: Bool {
        nextUpEpisode != nil
            || !nextUpCarouselItems.isEmpty
            || isLoadingNextUpEpisode
            || isLoadingNextUpOnDeck
    }

    private var currentRouteCapabilities: ApplePlaybackRouteCapabilities {
        return activeExecutionPlan?.routeCapabilities ?? activeRouteKind.routeCapabilities
    }

    /// Re-applies subtitle styling when the user edits the system's
    /// Subtitles & Captioning preferences mid-playback.
    private var systemCaptionObserverToken: NSObjectProtocol?
    private var audioRouteObserverToken: NSObjectProtocol?

    init() {
        activePlayer = .none
        activeRouteKind = .playerCoreDirect
        playbackCoordinator = PlaybackCoordinator(
            makeCore: { [weak self] in
                let core = PlayerCore()
                self?.configurePrimaryCore(core)
                return core
            },
            makeAVPlayer: { [weak self] _ in
                let backend = AVPlayerBackend()
                guard let self else { return backend }
                self.applyCallbacks(self.makeCallbacks(), to: backend)
                self.wireSubtitleCallbacks(to: backend)
                backend.setServerChapters(self.serverProvidedChapters)
                return backend
            }
        )
        realtimeClient = PlaybackRealtimeClient(
            commandHandler: { [weak self] command in
                guard let self else {
                    throw PlaybackRealtimeCommandExecutionError.commandFailed
                }
                try await self.handleRealtimeCommand(command)
            },
            eventHandler: { [weak self] event in
                guard let self else { return }
                await self.handleRealtimeEvent(event)
            }
        )
        // Mirror websocket connectivity so the synchronous subtitle-AI
        // controller requests live cue streaming only when the socket is
        // actually ready. If the first iOS submit beats the handshake, the job
        // still uses the shared paused preparing flow, but completes via the
        // poller instead of waiting for websocket `started`/`cues` frames.
        let client = realtimeClient
        Task { [weak self] in
            guard let self, let client else { return }
            let connectivityToken = await client.observeConnectivity { [weak self] connected in
                guard let self else { return }
                let wasConnected = self.realtimeConnectedSnapshot
                self.realtimeConnectedSnapshot = connected
                if !connected && wasConnected {
                    self.subtitleAI.realtimeDidBecomeUnavailable()
                }
            }
            let token = await client.observeUnavailability { [weak self] unavailable in
                guard let self else { return }
                let wasAvailable = !self.realtimeUnavailableSnapshot
                self.realtimeUnavailableSnapshot = unavailable
                if unavailable && wasAvailable {
                    self.subtitleAI.realtimeDidBecomeUnavailable()
                }
            }
            self.realtimeConnectivityObserverToken = connectivityToken
            self.realtimeUnavailabilityObserverToken = token
        }
        // `subtitleAI` is a lazy `@MainActor` property (see its declaration):
        // constructed on first access on the main actor, so no eager build or
        // `assumeIsolated` wrapper is needed here.
        // Choose a concrete backend only after playback bootstrap
        // resolves the execution plan, so loading HLS does not spin up and
        // immediately tear down an unused PlayerCore.

        sleepTimer.configure { [weak self] in
            self?.activePlayer.pause()
        }

        systemCaptionObserverToken = NotificationCenter.default.addObserver(
            forName: SystemCaptionAppearance.settingsChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.settings.subtitleMatchesSystemAppearance else { return }
            self.settings.refreshSubtitleSystemAppearance()
            self.applySubtitleAppearanceToPlayer()
        }
        #if !os(macOS)
        audioRouteObserverToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  self.activePreparedProtocolV3 != nil,
                  !self.isDisposed,
                  !self.isLoading else { return }
            self.attemptProtocolV3Replan(
                position: self.currentTime,
                classification: "output_route_changed",
                message: "The Apple audio output route changed."
            )
        }
        #endif
        settingsRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshSettingsFromServer()
        }
    }

    private func configurePrimaryCore(_ core: PlayerCore) {
        let callbacks = makeCallbacks()
        applyCallbacks(callbacks, to: core)
        wireSubtitleCallbacks(to: core)
        // Route rejection from PlayerCore is reported here and converted into
        // a typed fallback plan by the view model rather than by the decode
        // core.
        core.onUnsupportedStream = { [weak self] reason, url, headers, startTime in
            self?.handleUnsupportedStream(reason: reason, url: url, headers: headers, startTime: startTime)
        }

        // HDR preference is persistent; push it in at construction so the
        // option is in place before the first sig-peak event lands (iOS) or
        // before AVDisplayManager negotiates HDMI mode (tvOS).
        core.setHDREnabled(settings.hdrEnabled)
        // Dolby Vision policy must be in place before load() runs DV routing.
        core.dolbyVisionPolicy = settings.dolbyVisionPolicySnapshot
    }

    private func installFreshPrimaryCore() {
        installPlayer(for: .playerCoreDirect)
    }

    private func installPlayer(for engine: PlaybackEngineKind) {
        let installed = playbackCoordinator.installEngine(for: engine)
        activePlayer = ActivePlayer(renderTarget: installed.renderTarget)
        activeRouteKind = engine
        reapplyUserGain()
    }

    /// Read-only view of the canonical user volume for gesture overlays
    /// (the stored property stays private so all writes funnel through
    /// `applyUserVolume`).
    var currentUserVolume: Float { userVolume }

    /// Records the user's volume/mute as the VM-level source of truth and
    /// pushes it to the live backend.
    func applyUserVolume(_ v: Float) {
        userVolume = min(max(v, 0), 1)
        // Setting a volume clears mute (mirrors the backend), so keep the
        // canonical mute in sync.
        userMuted = false
        activePlayer.setVolume(userVolume)
    }
    func applyUserMuted(_ m: Bool) {
        userMuted = m
        activePlayer.setMuted(m)
    }

    /// Re-applies the canonical user volume/mute to the current backend after
    /// a swap (quality switch, loopback fallback, fresh primary core).
    private func reapplyUserGain() {
        activePlayer.setVolume(userVolume)
        activePlayer.setMuted(userMuted)
    }

    /// Subtitle-specific callbacks for PlayerCore's shared subtitle session.
    private func wireSubtitleCallbacks(to core: PlayerCore) {
        core.onSidecarTracksRegistered = { [weak self] descriptors in
            guard let self, !self.isDisposed else { return }
            self.appendSidecarTracks(descriptors)
        }
        core.onSubtitleLoadStatusChange = { [weak self] slot, status in
            guard let self, !self.isDisposed else { return }
            self.subtitleLoadStatus[slot] = status
        }
    }

    private func wireSubtitleCallbacks(to backend: AVPlayerBackend) {
        backend.onSidecarTracksRegistered = { [weak self] descriptors in
            guard let self, !self.isDisposed else { return }
            self.appendSidecarTracks(descriptors)
        }
        backend.onSubtitleLoadStatusChange = { [weak self] slot, status in
            guard let self, !self.isDisposed else { return }
            self.subtitleLoadStatus[slot] = status
        }
    }

    /// Build the VM-owned callbacks once so both backends get the exact
    /// same handler logic. Each closure weakly captures self; the backend
    /// owning them may outlive the VM in teardown races, so the
    /// `guard let self` is structural protection rather than cosmetic.
    private func makeCallbacks() -> PlayerCallbacks {
        var cb = PlayerCallbacks()
        cb.onTimeChange = { [weak self] seconds in
            guard let self, !self.isDisposed, seconds.isFinite else { return }
            guard !self.hasReachedEndOfFile else { return }
            let movieTime = seconds + self.playbackTimelineOffset
            if let origin = self.seekOriginTime, let target = self.seekTargetTime {
                // A seek is in flight. Reports closer to the pre-seek
                // position than to the target are stale drainage frames
                // — drop them and keep the optimistic `currentTime` that
                // `commitSeek` already set. Once a report crosses the
                // midpoint toward the target, the seek has effectively
                // landed and live updates resume.
                if abs(movieTime - origin) < abs(movieTime - target) {
                    // Still stale — don't overwrite the scrubber, but do
                    // keep Now Playing fresh with our optimistic target
                    // so the remote widget doesn't appear frozen.
                    self.pushNowPlayingIfDue()
                    return
                }
                self.seekOriginTime = nil
                self.seekTargetTime = nil
                self.seekFilterTimeoutTask?.cancel()
                self.seekFilterTimeoutTask = nil
            }
            self.currentTime = movieTime
            self.completeInterruptionRecoveryIfNeeded(
                observedTime: movieTime,
                requiresForwardProgress: true
            )
            self.updateNextUpPresentation(for: movieTime)
            self.autoSkipIntroIfNeeded(at: movieTime)
            self.pushNowPlayingIfDue()
        }
        cb.onDurationChange = { [weak self] seconds in
            guard let self, !self.isDisposed, seconds.isFinite, seconds > 0 else { return }
            if self.duration > 0, seconds < self.duration {
                return
            }
            self.duration = seconds
            self.updateNextUpPresentation(for: self.currentTime)
        }
        cb.onPauseChange = { [weak self] paused in
            guard let self, !self.isDisposed else { return }
            let wasPlaying = self.isPlaying
            self.isPlaying = !paused
            // A pause from any source (remote button, transport button,
            // Siri, interruption) surfaces the transport overlay and pins
            // it — no auto-hide runs while paused, so it stays up until
            // the user acts. Resuming re-arms the auto-hide so a resume
            // from an external source (Now Playing, Siri) doesn't leave
            // the overlay stuck on-screen.
            if paused, wasPlaying, !self.isLoading, !self.hasReachedEndOfFile {
                self.pinControlsVisible()
            } else if !paused, self.showControls, !self.isHUDPresented {
                self.scheduleHideControls()
            }
            self.nowPlaying.update(
                title: self.title,
                duration: self.duration,
                position: self.currentTime,
                isPlaying: !paused
            )
        }
        cb.onFileLoaded = { [weak self] in
            guard let self, !self.isDisposed else { return }
            self.handleFileLoaded()
        }
        cb.onFirstFrame = { [weak self] milliseconds in
            guard let self, !self.isDisposed else { return }
            Task { await self.sessionBridge.reportProtocolV3FirstFrame(milliseconds: milliseconds) }
        }
        cb.onError = { [weak self] message in
            guard let self, !self.isDisposed else { return }
            self.handlePlaybackError(message)
        }
        cb.onTracksChange = { [weak self] tracks in
            guard let self, !self.isDisposed else { return }
            self.applyTrackList(tracks)
        }
        cb.onChaptersChange = { [weak self] chapters in
            guard let self, !self.isDisposed else { return }
            self.chapters = chapters
        }
        cb.onBufferingChange = { [weak self] buffering in
            guard let self, !self.isDisposed else { return }
            self.isBuffering = buffering
            if buffering {
                Task { @MainActor [weak self] in
                    self?.noteBufferingDuringSourceOutage()
                }
            }
            if !buffering {
                self.bufferingProgress = nil
            }
        }
        cb.onBufferingProgress = { [weak self] progress in
            guard let self, !self.isDisposed, progress.isFinite else { return }
            self.bufferingProgress = min(100, max(0, progress))
        }
        cb.onBufferedAheadChange = { [weak self] seconds in
            guard let self, !self.isDisposed, seconds.isFinite else { return }
            self.bufferedAheadSeconds = max(0, seconds)
        }
        cb.onPlaybackStatsChange = { [weak self] stats in
            guard let self, !self.isDisposed else { return }
            var enrichedStats = stats
            self.applySourceCacheStats(&enrichedStats)
            self.applyFileBitrateStats(&enrichedStats)
            self.applySourceOriginLabel(&enrichedStats)
            self.playbackStats = enrichedStats
        }
        cb.onEndOfFile = { [weak self] in
            guard let self, !self.isDisposed else { return }
            self.handleEndOfFile()
        }
        return cb
    }

    private func applyCallbacks(_ cb: PlayerCallbacks, to core: PlayerCore) {
        core.onTimeChange      = cb.onTimeChange
        core.onDurationChange  = cb.onDurationChange
        core.onPauseChange     = cb.onPauseChange
        core.onFileLoaded      = cb.onFileLoaded
        core.onFirstFrame      = cb.onFirstFrame
        core.onError           = cb.onError
        core.onTracksChange    = cb.onTracksChange
        core.onChaptersChange  = cb.onChaptersChange
        core.onBufferingChange = cb.onBufferingChange
        core.onBufferingProgress = cb.onBufferingProgress
        core.onPlaybackStatsChange = cb.onPlaybackStatsChange
        core.onEndOfFile       = cb.onEndOfFile
    }

    private func applyCallbacks(_ cb: PlayerCallbacks, to backend: AVPlayerBackend) {
        backend.onTimeChange          = cb.onTimeChange
        backend.onDurationChange      = cb.onDurationChange
        backend.onPauseChange         = cb.onPauseChange
        backend.onFileLoaded          = cb.onFileLoaded
        backend.onFirstFrame          = cb.onFirstFrame
        backend.onError               = cb.onError
        backend.onTracksChange        = cb.onTracksChange
        backend.onChaptersChange      = cb.onChaptersChange
        backend.onBufferingChange     = cb.onBufferingChange
        backend.onBufferedAheadChange = cb.onBufferedAheadChange
        backend.onPlaybackStatsChange = cb.onPlaybackStatsChange
        backend.onEndOfFile           = cb.onEndOfFile
        backend.onTimelineOffsetChange = { [weak self] offset in
            guard let self, !self.isDisposed, offset.isFinite else { return }
            self.playbackTimelineOffset = max(0, offset)
        }
        #if os(iOS)
        backend.isPictureInPictureActiveProvider = {
            PictureInPictureCoordinator.shared.isActive
        }
        backend.onExternalPlaybackActiveChange = { [weak self] active in
            guard let self, !self.isDisposed else { return }
            self.handleExternalPlaybackActiveChange(active)
        }
        PictureInPictureCoordinator.shared.bindLifecycle(owner: self) { [weak self] in
            guard let self, !self.isDisposed else { return }
            self.handlePictureInPictureEngagementEnded()
        }
        #endif
    }

    private func handleFileLoaded() {
        hasReachedEndOfFile = false
        error = nil
        clearServerOutageRecoveryState()
        completeInterruptionRecoveryIfNeeded(
            observedTime: currentTime,
            requiresForwardProgress: false
        )
        isLoading = false
        isPlaying = true
        applySettingsToPlayer()
        Self.logger.info(
            "[CMP-SUB] file loaded route=\(self.activeRouteKind.label, privacy: .public) pendingExternal=\(self.pendingExternalSubtitles.count, privacy: .public) tracks=\(self.subtitleTracks.count, privacy: .public)"
        )
        loadPendingExternalSubtitles()
        startProgressReporting()
        hideControlsTask?.cancel()
        showControls = false
        nowPlaying.update(
            title: title,
            duration: duration,
            position: currentTime,
            isPlaying: true
        )
    }

    private func handlePlaybackError(_ message: String) {
        Self.logger.error("Player error: \(message, privacy: .public)")
        guard !hasReachedEndOfFile else {
            Self.logger.info("Ignoring playback error after EOF: \(message, privacy: .public)")
            return
        }
        if activeServerOutageRecoverySessionId != nil {
            Self.logger.info("Ignoring playback error while server outage recovery is active: \(message, privacy: .public)")
            return
        }
        if shouldTreatPlaybackErrorAsNaturalEnd() {
            Self.logger.info("Treating near-end playback error as EOF: \(message, privacy: .public)")
            handleEndOfFile()
            return
        }
        if activePreparedProtocolV3 != nil {
            attemptProtocolV3Recovery(after: message)
            return
        }
        if isPlaybackSessionMissingMessage(message) || isLikelyExpiredSessionHTTP404(message) {
            if attemptBackgroundSessionRenewal(reason: "player_error", observedPosition: currentTime) {
                return
            }
            if attemptStaleSessionRenewal(reason: "player_error", observedPosition: currentTime) {
                return
            }
        }
        if isPrematureSourceEndMessage(message) {
            Self.logger.warning(
                "Routing premature source end into server outage recovery: \(message, privacy: .public)"
            )
            Task { @MainActor [weak self] in
                guard let self, !self.isDisposed else { return }
                _ = self.attemptServerOutageRecovery(
                    reason: .networkUnavailable,
                    observedPosition: self.currentTime
                )
            }
            return
        }
        progressTask?.cancel()
        if shouldAutoRecoverFromInterruption() {
            triggerAutomaticInterruptionRecovery()
            return
        }
        if attemptNativeDirectRouteRecovery(after: message) {
            return
        }
        if attemptSiloRouteCompatibilityFallback(after: message) {
            return
        }
        finalizeTerminalPlaybackError(message)
    }

    private func attemptProtocolV3Recovery(after message: String) {
        attemptProtocolV3Replan(
            position: currentTime,
            classification: protocolV3FailureClassification(message),
            message: message
        )
    }

    private func attemptProtocolV3Replan(
        position: Double,
        classification: String,
        message: String,
        operation: String = "failure_recovery",
        qualityPreference: String? = nil,
        completesQualitySwitch: Bool = false
    ) {
        guard protocolV3ReplanTask == nil,
              let watchDetail = currentWatchDetail else {
            if completesQualitySwitch { isQualitySwitching = false }
            return
        }
        progressTask?.cancel()
        isLoading = true
        isBuffering = false
        bufferingProgress = nil
        protocolV3ReplanTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            defer {
                self.protocolV3ReplanTask = nil
                if completesQualitySwitch { self.isQualitySwitching = false }
            }
            do {
                guard let prepared = try await self.sessionBridge.replanProtocolV3(
                    watchDetail: watchDetail,
                    position: position,
                    classification: classification,
                    message: message,
                    operation: operation,
                    qualityPreference: qualityPreference,
                    audioTrackIndex: self.resolvedAudioTrackIndexForResume(),
                    subtitleTrackIndex: self.resolvedProtocolV3SubtitleIndexForResume()
                ) else {
                    self.finalizeTerminalPlaybackError(message)
                    return
                }
                guard !Task.isCancelled, !self.isDisposed else { return }

                let previousSessionId = self.activePlaybackSessionId
                self.activePlaybackSessionId = prepared.session.sessionId
                self.currentWatchDetail = prepared.watchDetail
                self.currentSelectedVersion = prepared.selectedVersion
                self.activePreparedProtocolV3 = prepared.protocolV3
                self.pendingExternalSubtitles = prepared.session.subtitleUrls ?? []
                self.knownExternalSubtitles = self.pendingExternalSubtitles
                self.duration = prepared.session.durationSeconds ?? prepared.selectedVersion.duration ?? self.duration
                self.currentTime = self.movieTime(for: prepared.session)
                self.activeQualityId = prepared.activeQualityId

                if previousSessionId != prepared.session.sessionId {
                    await self.realtimeClient.unbind()
                    await self.realtimeClient.bind(sessionId: prepared.session.sessionId)
                }
                guard let streamRequest = await self.makeStreamRequest(
                    session: prepared.session,
                    additionalHeaders: prepared.protocolV3?.plan.stream.headers ?? [:]
                ) else {
                    self.finalizeTerminalPlaybackError("The replacement V3 plan returned an invalid stream URL.")
                    return
                }
                self.resolvedServerUrl = streamRequest.serverUrl
                let plan = try self.makeExecutionPlan(prepared: prepared, streamRequest: streamRequest)
                self.currentDeliveryStrategy = plan.delivery
                self.playbackTimelineOffset = prepared.session.timelineOffsetSeconds
                self.logExecutionPlan(plan)
                await self.sessionBridge.reportProtocolV3PlanExecutionStarted()
                await self.loadStream(plan: plan)
            } catch {
                guard !Task.isCancelled, !self.isDisposed else { return }
                Self.logger.error("Protocol V3 replan failed: \(String(describing: error), privacy: .public)")
                self.finalizeTerminalPlaybackError(error.localizedDescription)
            }
        }
    }

    private func protocolV3FailureClassification(_ message: String) -> String {
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

    private func shouldTreatPlaybackErrorAsNaturalEnd() -> Bool {
        guard duration.isFinite, duration > 0, currentTime.isFinite, currentTime > 0 else {
            return false
        }
        let remaining = duration - currentTime
        let progress = currentTime / duration
        return remaining <= Self.nearEndPlaybackErrorThresholdSeconds || progress >= 0.985
    }

    private func loadNextUpCandidate(for detail: WatchDetail) {
        nextUpLookupTask?.cancel()
        nextUpLookupTask = nil
        nextUpEpisode = nil
        nextUpLookupError = nil
        isLoadingNextUpEpisode = false
        nextUpAutoplayCancelled = false
        nextUpPromptDismissed = false
        cancelNextUpCountdown()

        guard detail.type == "episode",
              let seriesId = detail.seriesId,
              let seasonNumber = detail.seasonNumber,
              let episodeNumber = detail.episodeNumber else {
            return
        }

        isLoadingNextUpEpisode = true
        nextUpLookupTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            defer {
                if !Task.isCancelled {
                    self.nextUpLookupTask = nil
                }
            }

            do {
                let episode = try await self.resolveNextUpEpisode(
                    contentId: detail.contentId,
                    seriesId: seriesId,
                    seriesTitle: detail.seriesTitle,
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber
                )
                guard !Task.isCancelled, !self.isDisposed else { return }
                self.nextUpEpisode = episode
                self.isLoadingNextUpEpisode = false
                self.nextUpLookupError = nil
                if self.showNextUpScreen {
                    self.startNextUpCountdownIfNeeded()
                } else {
                    self.updateNextUpPresentation(for: self.currentTime)
                }
            } catch {
                guard !Task.isCancelled, !self.isDisposed else { return }
                self.isLoadingNextUpEpisode = false
                self.nextUpLookupError = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                if self.showNextUpScreen {
                    self.cancelNextUpCountdown()
                }
            }
        }
    }

    private func loadNextUpOnDeckItems(for detail: WatchDetail) {
        nextUpOnDeckTask?.cancel()
        nextUpOnDeckTask = nil
        nextUpOnDeckItems = []
        isLoadingNextUpOnDeck = true

        nextUpOnDeckTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            defer {
                if !Task.isCancelled {
                    self.nextUpOnDeckTask = nil
                }
            }

            do {
                let response = try await ContinuumAPI.shared.homeSections()
                guard !Task.isCancelled, !self.isDisposed else { return }
                self.nextUpOnDeckItems = await self.resolveOnDeckItems(from: response, currentDetail: detail)
                self.isLoadingNextUpOnDeck = false
                self.updateNextUpPresentation(for: self.currentTime)
            } catch {
                guard !Task.isCancelled, !self.isDisposed else { return }
                self.nextUpOnDeckItems = []
                self.isLoadingNextUpOnDeck = false
            }
        }
    }

    private func resolveOnDeckItems(
        from response: SectionsResponse,
        currentDetail: WatchDetail
    ) async -> [PlayerOnDeckItem] {
        let allowedSectionTypes: Set<String> = ["continue_watching", "in_progress", "next_up"]
        var seenContentIds: Set<String> = []
        var sourceItems: [SectionItem] = []

        for section in response.sections where allowedSectionTypes.contains(section.sectionType) {
            for item in section.items {
                guard item.contentId != currentDetail.contentId else { continue }
                if let currentSeriesId = currentDetail.seriesId,
                   item.seriesId == currentSeriesId {
                    continue
                }
                guard seenContentIds.insert(item.contentId).inserted else { continue }
                sourceItems.append(item)
                if sourceItems.count >= 12 {
                    return await makeOnDeckItems(from: sourceItems)
                }
            }
        }

        return await makeOnDeckItems(from: sourceItems)
    }

    private func makeOnDeckItems(from sourceItems: [SectionItem]) async -> [PlayerOnDeckItem] {
        await withTaskGroup(of: (Int, PlayerOnDeckItem)?.self) { group in
            for (index, item) in sourceItems.enumerated() {
                group.addTask {
                    guard let artwork = await Self.horizontalArtwork(for: item) else {
                        return nil
                    }
                    return (
                        index,
                        PlayerOnDeckItem(
                            item: item,
                            artworkUrl: artwork.url,
                            artworkThumbhash: artwork.thumbhash
                        )
                    )
                }
            }

            var indexedItems: [(Int, PlayerOnDeckItem)] = []
            for await result in group {
                if let result {
                    indexedItems.append(result)
                }
            }
            return indexedItems
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }

    private static func horizontalArtwork(for item: SectionItem) async -> (url: String, thumbhash: String?)? {
        // Episode items: prefer the per-episode still (genuine 16:9 scene art)
        // over item.backdropUrl, which usually points at the show-level keyart.
        if let seriesId = nonEmpty(item.seriesId),
           let seasonNumber = item.seasonNumber {
            do {
                let response = try await ContinuumAPI.shared.episodes(
                    seriesId: seriesId,
                    seasonNumber: seasonNumber
                )
                if let episode = response.episodes.first(where: {
                    $0.contentId == item.contentId || $0.episodeNumber == item.episodeNumber
                }),
                   let stillUrl = nonEmpty(episode.stillUrl) {
                    return (stillUrl, episode.stillThumbhash)
                }
            } catch {
                // Fall through; artwork should never block playback choices.
            }
        }

        if let backdropUrl = nonEmpty(item.backdropUrl) {
            return (backdropUrl, item.backdropThumbhash)
        }

        do {
            let detail = try await ContinuumAPI.shared.itemDetail(contentId: item.contentId)
            if let backdropUrl = nonEmpty(detail.backdropUrl) {
                return (backdropUrl, detail.backdropThumbhash)
            }
        } catch {
            // No horizontal source — caller drops the item rather than stretching a poster.
        }

        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func resolveNextUpEpisode(
        contentId: String,
        seriesId: String,
        seriesTitle: String?,
        seasonNumber: Int,
        episodeNumber: Int
    ) async throws -> PlayerNextUpEpisode? {
        async let seasonsTask = ContinuumAPI.shared.seasons(seriesId: seriesId)
        async let currentEpisodesTask = ContinuumAPI.shared.episodes(
            seriesId: seriesId,
            seasonNumber: seasonNumber
        )

        let seasonsResponse = try await seasonsTask
        let currentEpisodesResponse = try await currentEpisodesTask
        let seasons = seasonsResponse.seasons.sortedForDisplay()
        var episodes = currentEpisodesResponse.episodes

        let nextSeason = seasons.first { season in
            !(season.isSpecials ?? false) && season.seasonNumber > seasonNumber
        }
        if let nextSeason {
            let nextSeasonEpisodes = try await ContinuumAPI.shared.episodes(
                seriesId: seriesId,
                seasonNumber: nextSeason.seasonNumber
            )
            episodes.append(contentsOf: nextSeasonEpisodes.episodes)
        }

        let orderedEpisodes = episodes.sorted { lhs, rhs in
            if lhs.seasonNumber != rhs.seasonNumber {
                return lhs.seasonNumber < rhs.seasonNumber
            }
            if lhs.episodeNumber != rhs.episodeNumber {
                return lhs.episodeNumber < rhs.episodeNumber
            }
            return lhs.contentId < rhs.contentId
        }

        let currentIndex = orderedEpisodes.firstIndex { $0.contentId == contentId }
            ?? orderedEpisodes.firstIndex {
                $0.seasonNumber == seasonNumber && $0.episodeNumber == episodeNumber
            }
        guard let currentIndex, currentIndex < orderedEpisodes.index(before: orderedEpisodes.endIndex) else {
            return nil
        }

        return PlayerNextUpEpisode(
            episode: orderedEpisodes[orderedEpisodes.index(after: currentIndex)],
            seriesId: seriesId,
            seriesTitle: seriesTitle
        )
    }

    private func updateNextUpPresentation(for movieTime: Double) {
        guard !hasReachedEndOfFile else { return }
        if showNextUpScreen {
            updateNextUpCountdownForActivePlayback(at: movieTime)
            return
        }
        guard shouldShowNextUpBeforeEnd(at: movieTime) else {
            nextUpPromptDismissed = false
            return
        }
        guard !nextUpPromptDismissed else { return }
        beginNextUpPostroll(videoEnded: false, source: .automatic)
    }

    private func shouldShowNextUpBeforeEnd(at movieTime: Double) -> Bool {
        canShowNextUpScreen
            && PlayerNextUpCompletionPolicy.isInPromptWindow(
                currentTime: movieTime,
                duration: duration,
                promptSeconds: settings.nextUpPromptSeconds
            )
    }

    func showNextUpNow() {
        guard canShowNextUpScreen else { return }
        beginNextUpPostroll(videoEnded: false, source: .hud)
    }

    private func beginNextUpPostroll(
        videoEnded: Bool,
        source: NextUpPresentationSource = .automatic
    ) {
        let wasAlreadyShowing = showNextUpScreen
        let wasShowingBeforeEnd = showNextUpScreen && !nextUpScreenVideoEnded
        if !wasAlreadyShowing {
            nextUpPresentationSource = source
        }
        showNextUpScreen = true
        nextUpScreenVideoEnded = videoEnded
        showControls = false
        activeNotice = nil
        isHUDPresented = false
        if !wasShowingBeforeEnd && !videoEnded {
            nextUpAutoplayCancelled = false
        }
        if videoEnded,
           wasShowingBeforeEnd,
           settings.autoPlayNextEpisode,
           nextUpEpisode != nil,
           !nextUpAutoplayCancelled {
            playNextEpisodeNow()
            return
        }
        startNextUpCountdownIfNeeded()
    }

    private func startNextUpCountdownIfNeeded() {
        cancelNextUpCountdown()
        guard showNextUpScreen,
              settings.autoPlayNextEpisode,
              nextUpEpisode != nil,
              !nextUpAutoplayCancelled else {
            return
        }

        if !nextUpScreenVideoEnded {
            updateNextUpCountdownForActivePlayback(at: currentTime)
            return
        }

        nextUpCountdownTotalSeconds = Self.nextUpCountdownDefaultSeconds
        nextUpCountdownSeconds = Self.nextUpCountdownDefaultSeconds
        nextUpCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = Self.nextUpCountdownDefaultSeconds
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !self.isDisposed else { return }
                remaining -= 1
                self.nextUpCountdownSeconds = remaining
            }
            guard !Task.isCancelled, !self.isDisposed else { return }
            self.playNextEpisodeNow()
        }
    }

    private func updateNextUpCountdownForActivePlayback(at movieTime: Double) {
        guard showNextUpScreen,
              !nextUpScreenVideoEnded,
              settings.autoPlayNextEpisode,
              nextUpEpisode != nil,
              !nextUpAutoplayCancelled,
              duration.isFinite,
              duration > 0,
              movieTime.isFinite else {
            return
        }

        let remaining = max(0, duration - movieTime)
        if nextUpPresentationSource == .hud,
           remaining >= Self.nextUpHUDCountdownThresholdSeconds {
            nextUpCountdownSeconds = nil
            nextUpCountdownTotalSeconds = Int(Self.nextUpHUDCountdownThresholdSeconds)
            return
        }
        nextUpCountdownTotalSeconds = nextUpPresentationSource == .hud
            ? Int(Self.nextUpHUDCountdownThresholdSeconds)
            : max(1, settings.nextUpPromptSeconds)
        nextUpCountdownSeconds = max(0, Int(ceil(remaining)))
        if remaining <= 0.35 {
            playNextEpisodeNow()
        }
    }

    private func cancelNextUpCountdown() {
        nextUpCountdownTask?.cancel()
        nextUpCountdownTask = nil
        nextUpCountdownSeconds = nil
        nextUpCountdownTotalSeconds = Self.nextUpCountdownDefaultSeconds
    }

    private func cancelNextUpFlow() {
        nextUpLookupTask?.cancel()
        nextUpLookupTask = nil
        nextUpOnDeckTask?.cancel()
        nextUpOnDeckTask = nil
        cancelNextUpCountdown()
    }

    func cancelNextUpAutoPlay() {
        nextUpAutoplayCancelled = true
        cancelNextUpCountdown()
    }

    @discardableResult
    func keepWatchingCurrentEpisode() -> Bool {
        // An autoplay load failure may restore the postroll after disposing
        // the old playback pipeline. There is no current episode to resume in
        // that state, so let the shell fall back to closing the player.
        guard !activePlayer.isNone else { return false }

        let shouldResumeAfterEnd = nextUpScreenVideoEnded || hasReachedEndOfFile
        nextUpAutoplayCancelled = true
        nextUpPromptDismissed = true
        showNextUpScreen = false
        nextUpScreenVideoEnded = false
        cancelNextUpCountdown()

        if shouldResumeAfterEnd,
           duration.isFinite,
           duration > 0,
           !activePlayer.isNone {
            // Returning from the terminal postroll needs a real playable
            // position; resuming at exact EOF would immediately present the
            // postroll again. Replay a short tail of the current episode.
            hasReachedEndOfFile = false
            let target = max(0, duration - 10)
            let reloadsPlaybackPipeline = commitSeek(to: target, source: "nextUpBack")
            if !reloadsPlaybackPipeline {
                activePlayer.play()
            }
        } else if !isPlaying {
            activePlayer.play()
        }
        scheduleHideControls()
        return true
    }

    func setNextUpAutoPlayEnabled(_ enabled: Bool) {
        settings.setAutoPlayNextEpisode(enabled)
        if enabled {
            nextUpAutoplayCancelled = false
            startNextUpCountdownIfNeeded()
        } else {
            cancelNextUpAutoPlay()
        }
    }

    func playNextEpisodeNow() {
        guard let nextUpEpisode else { return }
        let request = LoadRequest(
            contentId: nextUpEpisode.contentId,
            preferredFileId: nil,
            preferredAudioTrackIndex: nil,
            preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: nil,
            startFromBeginning: false
        )
        beginFreshLoad(
            request: request,
            progressPosition: completionProgressPositionForCurrentItem(),
            finalizeCurrentSession: true,
            origin: .autoplay
        )
    }

    func playOnDeckItemNow(_ item: PlayerOnDeckItem) {
        let request = LoadRequest(
            contentId: item.contentId,
            preferredFileId: nil,
            preferredAudioTrackIndex: nil,
            preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: nil,
            startFromBeginning: false
        )
        beginFreshLoad(
            request: request,
            progressPosition: completionProgressPositionForCurrentItem(),
            finalizeCurrentSession: true
        )
    }

    private func completionProgressPositionForCurrentItem() -> Double {
        PlayerNextUpCompletionPolicy.progressPosition(
            isNextUpPresented: showNextUpScreen,
            hasReachedEndOfFile: hasReachedEndOfFile,
            currentTime: currentTime,
            duration: duration,
            promptSeconds: settings.nextUpPromptSeconds
        )
    }

    private func attemptNativeDirectRouteRecovery(after message: String) -> Bool {
        guard !isDisposed,
              let activeExecutionPlan,
              activeExecutionPlan.engine == .avPlayerNativeDirect,
              !hasAttemptedNativeDirectRouteRecovery else {
            return false
        }

        hasAttemptedNativeDirectRouteRecovery = true
        let requirements = activeExecutionPlan.requirements
        let startTime = currentTime.isFinite && currentTime > 0
            ? currentTime
            : activeExecutionPlan.startMode.seconds
        let compatibilityFallbackPlan = makeCompatibilityFallbackPlan(
            from: activeExecutionPlan,
            requirements: requirements,
            startTime: startTime,
            traceToken: "fallback_playercore_direct",
            reason: "native_direct_avplayer_failed_playercore_fallback"
        )
        let fallbackPlan = compatibilityFallbackPlan

        Self.logger.warning(
            "[CMP-ROUTE] native-direct AVPlayer failed; retrying route=\(fallbackPlan.implementationRoute, privacy: .public) error=\(message, privacy: .public)"
        )
        let preferredAudioTrackIndex = resolvedAudioTrackIndexForResume()
        let preferredSubtitleTrackIndex = resolvedSubtitleTrackIndexForResume()
        let preferredSidecarSubtitleTrackId = resolvedSidecarSubtitleTrackIdForResume()
        let watchDetailSnapshot = currentWatchDetail
        let selectedVersionSnapshot = currentSelectedVersion
        let chapterSnapshot = serverProvidedChapters
        let subtitlePrefsSnapshot = prefsForCurrentItem
        let externalSubtitleSnapshot = knownExternalSubtitles
        let audioSelectionSnapshot = selectedAudioId
            .flatMap { selectedId in audioTracks.first(where: { $0.trackId == selectedId }) }
            .map(TrackSelectionSnapshot.init)
        let subtitleSelectionSnapshot = selectedSubtitleId
            .flatMap { selectedId in subtitleTracks.first(where: { $0.trackId == selectedId }) }
            .flatMap { track in
                // Synthetic (sidecar / AI-live) ids must not be recovered as
                // embedded tracks; sidecar has its own recovery path and
                // live re-selection is M4's responsibility.
                SubtitleTrackIdSpace.isSyntheticNonEmbedded(track.trackId) ? nil : TrackSelectionSnapshot(track: track)
            }
        let secondarySubtitleSelectionSnapshot = selectedSecondarySubtitleId
        resetPublishedLoadState(
            preferredAudioTrackIndex: preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: preferredSubtitleTrackIndex,
            preferredSidecarSubtitleTrackId: preferredSidecarSubtitleTrackId,
            resetRouteRecoveryFlags: false
        )
        currentWatchDetail = watchDetailSnapshot
        currentSelectedVersion = selectedVersionSnapshot
        serverProvidedChapters = chapterSnapshot
        prefsForCurrentItem = subtitlePrefsSnapshot
        pendingExternalSubtitles = externalSubtitleSnapshot
        knownExternalSubtitles = externalSubtitleSnapshot
        pendingRecoveredAudioSelection = audioSelectionSnapshot
        pendingRecoveredSubtitleSelection = subtitleSelectionSnapshot
        pendingRecoveredSecondarySubtitleId = secondarySubtitleSelectionSnapshot
        if subtitleSelectionSnapshot != nil {
            hasExplicitSubtitleChoice = true
        }
        activePlayer.dispose()
        logExecutionPlan(fallbackPlan)
        Task { @MainActor [weak self] in
            await self?.loadStream(plan: fallbackPlan)
        }
        return true
    }

    private func attemptSiloRouteCompatibilityFallback(after message: String) -> Bool {
        guard !isDisposed,
              let activeExecutionPlan,
              activeExecutionPlan.engine == .siloPlayerLoopback,
              !hasAttemptedSiloRouteCompatibilityFallback else {
            return false
        }
        hasAttemptedSiloRouteCompatibilityFallback = true

        let startTime = currentTime.isFinite && currentTime > 0
            ? currentTime
            : activeExecutionPlan.startMode.seconds
        let fallbackPlan = makeCompatibilityFallbackPlan(
            from: activeExecutionPlan,
            requirements: activeExecutionPlan.requirements,
            startTime: startTime,
            traceToken: "fallback_playercore_after_silo",
            reason: "silo_fallback_failed_playercore_fallback"
        )
        Self.logger.warning(
            "[CMP-ROUTE] SiloPlayer fallback failed; retrying route=\(fallbackPlan.implementationRoute, privacy: .public) failureToken=\(self.stablePlaybackFailureToken(for: message), privacy: .public)"
        )
        logExecutionPlan(fallbackPlan)
        Task { @MainActor [weak self] in
            await self?.loadStream(plan: fallbackPlan)
        }
        return true
    }

    private func makeCompatibilityFallbackPlan(
        from activeExecutionPlan: PlaybackExecutionPlan,
        requirements: PlaybackRouteRequirements,
        startTime: Double,
        traceToken: String,
        reason: String
    ) -> PlaybackExecutionPlan {
        let fallbackCapabilities = PlaybackEngineKind.playerCoreDirect.routeCapabilities
        let blockers = fallbackCapabilities.blockingReasons(for: requirements)
        return PlaybackExecutionPlan(
            delivery: .direct,
            engine: .playerCoreDirect,
            startMode: .absolutePosition(startTime),
            streamRequest: activeExecutionPlan.sourceStreamRequest,
            sourceStreamRequest: activeExecutionPlan.sourceStreamRequest,
            loopbackSession: nil,
            capabilities: fallbackCapabilities.backendCapabilities,
            routeCapabilities: fallbackCapabilities,
            requirements: requirements,
            featureFlagEnabled: true,
            parityBlockers: blockers,
            decisionTrace: activeExecutionPlan.decisionTrace
                + [traceToken]
                + blockers.map { "blocker_\($0)" },
            degradationWarnings: fallbackCapabilities.degradationNotes(for: requirements),
            reason: reason,
            playbackSessionId: activeExecutionPlan.playbackSessionId,
            sourceMetadata: activeExecutionPlan.sourceMetadata,
            normalizationSummary: PlaybackNormalizationSummary(
                containerMode: "none",
                videoMode: "compatibility_decode",
                audioMode: "compatibility_decode",
                subtitleMode: "compatibility_render"
            )
        )
    }

    private static func appleHLSRouteFeatureFlagEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: appleHLSRouteFeatureFlagKey) != nil {
            return defaults.bool(forKey: appleHLSRouteFeatureFlagKey)
        }
        return true
    }

    /// Build a typed execution plan from the bridge's session response plus
    /// the resolved stream request. This is the Workstream 1 seam: route
    /// choice, start semantics, and stream inputs are materialized once and
    /// travel as data, so the load path never re-infers them from
    /// `session.playMethod`.
    private func makeExecutionPlan(
        prepared: PreparedPlayback,
        streamRequest: StreamRequest
    ) throws -> PlaybackExecutionPlan {
        let routeRequirements = makeRouteRequirements(prepared: prepared)
        let basePlan = ApplePlaybackRoutePlanner().makeExecutionPlan(
            input: ApplePlaybackPlannerInput(
                session: prepared.session,
                selectedVersion: prepared.selectedVersion,
                streamRequest: streamRequest,
                routeRequirements: routeRequirements,
                selectedAudioTrackId: selectedAudioId,
                pendingAudioFfIndex: pendingAudioFfIndex,
                preferredAudioTrackIndex: resolvedAudioTrackIndexForResume(),
                selectedPrimarySubtitleTrackId: selectedSubtitleId,
                selectedSecondarySubtitleTrackId: selectedSecondarySubtitleId,
                hlsRouteFeatureEnabled: Self.appleHLSRouteFeatureFlagEnabled(),
                siloPlayerPrimaryEnabled: LoopbackServingMode.gated == .vodPlan,
                dolbyVisionPolicy: settings.dolbyVisionPolicySnapshot,
                displayCapabilities: ApplePlaybackDisplayCapabilities.probe()
            )
        )
        guard let protocolV3 = prepared.protocolV3 else { return basePlan }
        return try ApplePlaybackV3PlanAdapter.makeExecutionPlan(
            v3: protocolV3,
            basePlan: basePlan,
            streamRequest: streamRequest,
            routeRequirements: routeRequirements
        )
    }

    private func logExecutionPlan(_ plan: PlaybackExecutionPlan) {
        let blockers = plan.parityBlockers.isEmpty
            ? "none"
            : plan.parityBlockers.joined(separator: ",")
        let requirements = plan.requirements.summaryTokens.isEmpty
            ? "none"
            : plan.requirements.summaryTokens.joined(separator: ",")
        let degradations = plan.degradationWarnings.isEmpty
            ? "none"
            : plan.degradationWarnings.joined(separator: " | ")
        let subtitleCodecs = plan.sourceMetadata.subtitleCodecs.isEmpty
            ? "none"
            : plan.sourceMetadata.subtitleCodecs.joined(separator: ",")
        let trace = plan.decisionTrace.isEmpty
            ? "none"
            : plan.decisionTrace.joined(separator: ",")
        let playbackSessionId = plan.playbackSessionId ?? "unknown"
        let message =
            "[CMP-ROUTE] playbackSessionId=\(playbackSessionId) " +
            "delivery=\(plan.delivery.name) routeFamily=\(plan.routeFamily.diagnosticsLabel) " +
            "implementationRoute=\(plan.implementationRoute) backend=\(plan.engine.label) " +
            "appLabel=\(plan.appPlaybackLabel) " +
            "flag=\(plan.featureFlagEnabled) requirements=\(requirements) " +
            "blockers=\(blockers) reason=\(plan.reason) degradations=\(degradations) " +
            "sourceContainer=\(plan.sourceMetadata.container ?? "unknown") " +
            "sourceVideoCodec=\(plan.sourceMetadata.videoCodec ?? "unknown") " +
            "sourceAudioCodec=\(plan.sourceMetadata.audioCodec ?? "unknown") " +
            "sourceSubtitleCodecs=\(subtitleCodecs) " +
            "normalization.containerMode=\(plan.normalizationSummary.containerMode) " +
            "normalization.videoMode=\(plan.normalizationSummary.videoMode) " +
            "normalization.audioMode=\(plan.normalizationSummary.audioMode) " +
            "normalization.subtitleMode=\(plan.normalizationSummary.subtitleMode) " +
            "validationClaims=\(plan.validationClaims.logToken) " +
            "fallbackTrail=\(trace)"
        cmpLog(message)
    }

    private func loadStream(plan: PlaybackExecutionPlan) async {
        streamLoadGeneration &+= 1
        let loadGeneration = streamLoadGeneration
        activePlayer.dispose()
        activePlayer = .none
        stashSourceCacheHandoff()
        sourceProxy?.stop()
        sourceProxy = nil

        let prepared: SourceProxyPreparation
        do {
            prepared = try await prepareSourceProxy(for: plan)
        } catch {
            guard loadGeneration == streamLoadGeneration,
                  !Task.isCancelled,
                  !isDisposed else {
                return
            }
            finalizeTerminalPlaybackError("SiloPlayer local source proxy failed to start: \(error.localizedDescription)")
            return
        }
        guard loadGeneration == streamLoadGeneration,
              !Task.isCancelled,
              !isDisposed else {
            prepared.proxy?.stop()
            return
        }
        sourceProxy = prepared.proxy
        sourceProxyFileId = prepared.proxy != nil ? currentSelectedVersion?.fileId : nil
        let loadPlan = prepared.plan
        activeExecutionPlan = loadPlan
        installPlayer(for: loadPlan.engine)
        let startTime = loadPlan.startMode.seconds
        let backendTimelineOffset = avPlayerTimelineOffset(for: loadPlan, startTime: startTime)
        if loadPlan.engine == .siloPlayerLoopback {
            playbackTimelineOffset = backendTimelineOffset
        }
        activePlayer.avBackend?.setMediaTimelineOffset(backendTimelineOffset)
        // Temporary [CMP-MEM]: feed proxy cache stats into the backend's
        // periodic footprint log line.
        activePlayer.avBackend?.proxyStatsProvider = { [weak self] in
            self?.sourceProxy?.stats()
        }
        activePlayer.avBackend?.sourceOutageStateProvider = { [weak self] in
            self?.sourceProxy?.isOriginOutageActive ?? false
        }
        do {
            try playbackCoordinator.load(plan: loadPlan)
            activePlayer = ActivePlayer(renderTarget: playbackCoordinator.renderTarget)
            reapplyUserGain()
        } catch {
            finalizeTerminalPlaybackError(error.localizedDescription)
        }
    }

    private struct SourceProxyPreparation {
        let plan: PlaybackExecutionPlan
        let proxy: PlaybackSourceProxy?
    }

    /// A torn-down proxy's cache, retained across the teardown so a
    /// same-file replacement proxy can adopt it (spans stay in memory, spill
    /// stays on disk) instead of re-downloading. One slot: stashed at every
    /// proxy stop that might be followed by a same-file reload, resolved
    /// (adopted or released) by the next `prepareSourceProxy`, and released
    /// on terminal teardown. Releasing the last reference cleans the disk
    /// directory via the cache's deinit.
    private struct SourceCacheHandoff {
        let fileId: Int
        let cache: PlaybackSourceCache
    }

    private var sourceCacheHandoff: SourceCacheHandoff?
    /// File id the live `sourceProxy` was built for — the stash metadata.
    /// (`currentSelectedVersion` is already reset by the time some teardown
    /// paths stop the proxy, so the association must be recorded at install.)
    private var sourceProxyFileId: Int?

    /// Retain the outgoing proxy's cache for possible adoption by the next
    /// same-file proxy. Called immediately before `sourceProxy.stop()` on
    /// non-terminal teardown paths.
    private func stashSourceCacheHandoff() {
        guard let proxy = sourceProxy, let fileId = sourceProxyFileId else { return }
        let cache = proxy.handoffCache
        sourceCacheHandoff = SourceCacheHandoff(fileId: fileId, cache: cache)
        Self.logger.info(
            "[CMP-SOURCE-CACHE] handoff stashed fileId=\(fileId, privacy: .public) cachedBytes=\(cache.stats().cachedBytes, privacy: .public) diskBytes=\(cache.stats().diskSpillBytes, privacy: .public)"
        )
    }

    private func discardSourceCacheHandoff() {
        if sourceCacheHandoff != nil {
            Self.logger.info("[CMP-SOURCE-CACHE] handoff released")
        }
        sourceCacheHandoff = nil
    }

    /// Resolve the handoff slot against the incoming plan: adopt the cache
    /// when the adoption policy allows, release it otherwise. Either way the
    /// slot is emptied — a handoff lives for exactly one load attempt.
    private func takeAdoptableSourceCache(budgetBytes: Int, diskSpillRequested: Bool) -> PlaybackSourceCache? {
        guard let handoff = sourceCacheHandoff else { return nil }
        sourceCacheHandoff = nil
        let adopt = SourceCacheAdoptionPolicy.shouldAdopt(
            handoffFileId: handoff.fileId,
            planFileId: currentSelectedVersion?.fileId,
            handoffBudgetBytes: handoff.cache.maxBytes,
            planBudgetBytes: budgetBytes,
            handoffDiskSpill: handoff.cache.diskSpillActive,
            planDiskSpill: PlaybackSourceCache.resolveDiskSpillEnabled(diskSpillRequested),
            cachedTotalLength: handoff.cache.knownTotalLength,
            expectedFileSize: currentSelectedVersion?.fileSize
        )
        guard adopt else {
            Self.logger.info(
                "[CMP-SOURCE-CACHE] handoff rejected fileId=\(handoff.fileId, privacy: .public) planFileId=\(self.currentSelectedVersion?.fileId ?? -1, privacy: .public)"
            )
            return nil
        }
        Self.logger.info(
            "[CMP-SOURCE-CACHE] handoff adopted fileId=\(handoff.fileId, privacy: .public) cachedBytes=\(handoff.cache.stats().cachedBytes, privacy: .public)"
        )
        return handoff.cache
    }

    private enum SourceProxyPreparationError: LocalizedError {
        case missingLocalURL
        case missingLoopbackSession
        case unsupportedSourceURL

        var errorDescription: String? {
            switch self {
            case .missingLocalURL:
                return "local proxy URL was unavailable"
            case .missingLoopbackSession:
                return "loopback session was unavailable"
            case .unsupportedSourceURL:
                return "loopback source URL is not HTTP(S)"
            }
        }
    }

    private func prepareSourceProxy(
        for plan: PlaybackExecutionPlan
    ) async throws -> SourceProxyPreparation {
        guard plan.delivery == .direct,
              plan.engine != .avPlayerHLS,
              plan.engine != .playerCoreDirect,
              ["http", "https"].contains(plan.sourceStreamRequest.url.scheme?.lowercased()) else {
            // This load runs without a proxy, so any stashed cache has no
            // adopter — release it rather than hold its disk spans for the
            // rest of playback.
            discardSourceCacheHandoff()
            if plan.engine == .siloPlayerLoopback {
                throw SourceProxyPreparationError.unsupportedSourceURL
            }
            return SourceProxyPreparation(plan: plan, proxy: nil)
        }
        let cacheBudget = sourceCacheBudget(for: plan)
        let diskSpillRequested = PlayerSettings.shared.seekCacheEnabled
        let cache = takeAdoptableSourceCache(
            budgetBytes: cacheBudget,
            diskSpillRequested: diskSpillRequested
        ) ?? PlaybackSourceCache(
            maxBytes: cacheBudget,
            diskSpillEnabled: diskSpillRequested
        )
        let proxy = PlaybackSourceProxy(
            originURL: plan.sourceStreamRequest.url,
            originHeaders: plan.sourceStreamRequest.headers,
            cache: cache,
            onPlaybackSessionMissing: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.attemptBackgroundSessionRenewal(
                        reason: "source_404",
                        observedPosition: self.currentTime
                    ) {
                        return
                    }
                    _ = self.attemptStaleSessionRenewal(
                        reason: "source_404",
                        observedPosition: self.currentTime
                    )
                }
            },
            onPlaybackSourceInterrupted: { [weak self] reason in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = self.attemptServerOutageRecovery(
                        reason: reason,
                        observedPosition: self.currentTime
                    )
                }
            },
            onOriginOutageChanged: { [weak self] active in
                Task { @MainActor [weak self] in
                    self?.handleOriginOutageChanged(active)
                }
            }
        )
        do {
            try await proxy.start()
            guard let localURL = proxy.localURL else {
                proxy.stop()
                if plan.engine == .siloPlayerLoopback {
                    throw SourceProxyPreparationError.missingLocalURL
                }
                return SourceProxyPreparation(plan: plan, proxy: nil)
            }
            proxy.setSourceBitrate(sourceBitrateBps(for: plan))
            // Loopback included: opening the origin stream here overlaps the
            // TCP/TLS connect and slow-start ramp with demuxer spawn, which
            // is a full round trip saved on high-latency links.
            proxy.startPrefetch(at: initialSourcePrefetchOffset(for: plan))
            Self.logger.info("[CMP-SOURCE-CACHE] enabled route=\(plan.engine.label, privacy: .public) budgetBytes=\(cacheBudget, privacy: .public)")
            let streamRequest = StreamRequest(
                url: localURL,
                headers: [:],
                serverUrl: plan.streamRequest.serverUrl
            )
            let loopbackSession = plan.loopbackSession.map { session in
                LoopbackSessionSpec(
                    sourceURL: localURL,
                    headers: [:],
                    sourceStartTimeSeconds: session.sourceStartTimeSeconds,
                    sourceBitrateBps: session.sourceBitrateBps,
                    videoMode: session.videoMode,
                    sourceVideoFrameRate: session.sourceVideoFrameRate,
                    selectedAudio: session.selectedAudio,
                    availableAudioTracks: session.availableAudioTracks,
                    manifestMetadata: session.manifestMetadata,
                    servingMode: session.servingMode
                )
            }
            let proxiedPlan = PlaybackExecutionPlan(
                delivery: plan.delivery,
                engine: plan.engine,
                startMode: plan.startMode,
                streamRequest: streamRequest,
                sourceStreamRequest: plan.sourceStreamRequest,
                loopbackSession: loopbackSession,
                capabilities: plan.capabilities,
                routeCapabilities: plan.routeCapabilities,
                requirements: plan.requirements,
                featureFlagEnabled: plan.featureFlagEnabled,
                parityBlockers: plan.parityBlockers,
                decisionTrace: plan.decisionTrace + ["source_proxy_enabled"],
                degradationWarnings: plan.degradationWarnings,
                reason: plan.reason,
                playbackSessionId: plan.playbackSessionId,
                sourceMetadata: plan.sourceMetadata,
                normalizationSummary: plan.normalizationSummary,
                validationClaims: plan.validationClaims
            )
            if plan.engine == .siloPlayerLoopback, loopbackSession == nil {
                proxy.stop()
                throw SourceProxyPreparationError.missingLoopbackSession
            }
            return SourceProxyPreparation(plan: proxiedPlan, proxy: proxy)
        } catch {
            proxy.stop()
            if plan.engine == .siloPlayerLoopback {
                Self.logger.info("[CMP-SOURCE-CACHE] required proxy failed route=\(plan.engine.label, privacy: .public) error=\(String(describing: error), privacy: .public)")
                throw error
            }
            Self.logger.info("[CMP-SOURCE-CACHE] proxy unavailable; continuing without source cache error=\(String(describing: error), privacy: .public)")
            return SourceProxyPreparation(plan: plan, proxy: nil)
        }
    }

    private func sourceCacheBudget(for plan: PlaybackExecutionPlan) -> Int {
        switch plan.engine {
        case .siloPlayerLoopback:
            return PlaybackSourceCache.siloLoopbackMemoryBudgetBytes
        case .playerCoreDirect, .avPlayerNativeDirect, .avPlayerHLS:
            if let bps = sourceBitrateBps(for: plan), bps >= 200_000_000 {
                if PlaybackSourceCache.isConstrainedMemoryDevice {
                    return PlaybackSourceCache.siloLoopbackMemoryBudgetBytes
                }
                return 512 * 1024 * 1024
            }
            if let bps = sourceBitrateBps(for: plan), bps >= 80_000_000 {
                if PlaybackSourceCache.isConstrainedMemoryDevice {
                    return 192 * 1024 * 1024
                }
                return PlaybackSourceCache.siloLoopbackMemoryBudgetBytes
            }
            return PlaybackSourceCache.defaultMemoryBudgetBytes
        }
    }

    private func sourceBitrateBps(for plan: PlaybackExecutionPlan) -> Double? {
        if let bps = plan.loopbackSession?.sourceBitrateBps {
            return bps
        }
        guard let bitrateKbps = currentSelectedVersion?.bitrate, bitrateKbps > 0 else {
            return nil
        }
        return Double(bitrateKbps) * 1_000
    }

    private func initialSourcePrefetchOffset(for plan: PlaybackExecutionPlan) -> Int64 {
        PlaybackSourcePrefetchPolicy.initialOffset(
            sourceStartTimeSeconds: plan.loopbackSession?.sourceStartTimeSeconds ?? 0,
            sourceBitrateBps: sourceBitrateBps(for: plan)
        )
    }

    private func timelineOffset(
        for plan: PlaybackExecutionPlan,
        session: PlaybackSessionResponse,
        requestedStart: Double?
    ) -> Double {
        if plan.engine == .siloPlayerLoopback {
            let start = plan.startMode.seconds
            return start.isFinite ? max(0, start) : 0
        }
        guard plan.delivery == .remux,
              plan.engine == .avPlayerHLS,
              plan.startMode == .startOfManifest else {
            return 0
        }
        if session.timelineOffsetSeconds.isFinite, session.timelineOffsetSeconds > 0 {
            return session.timelineOffsetSeconds
        }
        if let requestedStart, requestedStart.isFinite, requestedStart > 0 {
            return requestedStart
        }
        return 0
    }

    private func avPlayerTimelineOffset(
        for plan: PlaybackExecutionPlan,
        startTime: Double
    ) -> Double {
        switch plan.engine {
        case .siloPlayerLoopback:
            return startTime.isFinite ? max(0, startTime) : 0
        case .avPlayerHLS:
            return playbackTimelineOffset
        case .avPlayerNativeDirect, .playerCoreDirect:
            return 0
        }
    }

    private func movieTime(for session: PlaybackSessionResponse) -> Double {
        let playerTime = session.position.isFinite ? session.position : 0
        let offset = session.timelineOffsetSeconds.isFinite ? session.timelineOffsetSeconds : 0
        return max(0, playerTime + offset)
    }

    private func chapterInfoList(from version: FileVersion) -> [PlayerChapterInfo] {
        (version.chapters ?? [])
            .filter { chapter in
                chapter.startSeconds.isFinite && chapter.startSeconds >= 0
            }
            .sorted { lhs, rhs in
                if lhs.startSeconds == rhs.startSeconds {
                    return lhs.index < rhs.index
                }
                return lhs.startSeconds < rhs.startSeconds
            }
            .map { chapter in
                PlayerChapterInfo(
                    index: chapter.index,
                    title: chapter.title,
                    time: chapter.startSeconds
                )
            }
    }

    /// Decide what to do when PlayerCore rejects a stream. Direct playback
    /// can still hand off to the AVPlayer DV loopback route; adaptive HLS
    /// playback must not use this escape hatch because the AVPlayer HLS
    /// route is behind an explicit parity gate.
    private func handleUnsupportedStream(
        reason: PlayerCore.StreamRejection,
        url: URL,
        headers: [String: String],
        startTime: Double
    ) {
        // `onUnsupportedStream` hops through `DispatchQueue.main.async`, so
        // by the time we land here the VM could have been torn down (e.g.
        // the user dismissed the screen between detection and dispatch).
        // Bail rather than spinning up a fresh pipeline on a dead VM.
        guard !isDisposed else { return }

        let streamRequest = activeExecutionPlan?.sourceStreamRequest
            ?? StreamRequest(url: url, headers: headers, serverUrl: resolvedServerUrl)
        let hevcLoopbackVideoRange = currentSelectedVersion.map {
            ApplePlaybackRoutePlanner.hevcLoopbackVideoRange(for: $0)
        }
        let decision = recoveryPlanner.decide(
            context: PlaybackRecoveryPlanner.Context(
                reason: reason,
                currentDelivery: currentDeliveryStrategy,
                streamRequest: streamRequest,
                startTime: startTime,
                activePlan: activeExecutionPlan,
                hevcLoopbackVideoRange: hevcLoopbackVideoRange
            ),
            makeLoopbackSession: { [weak self] request in
                self?.makeFallbackLoopbackSession(
                    streamRequest: request.streamRequest,
                    videoMode: request.videoMode,
                    videoRange: request.videoRange,
                    sourceStartTimeSeconds: request.sourceStartTimeSeconds
                )
            }
        )

        switch decision {
        case .terminal(let message, let diagnosticLine, let disposeActiveCore):
            Self.logger.error("[CMP-ROUTE] \(message, privacy: .public)")
            print(diagnosticLine)
            if disposeActiveCore {
                activePlayer.core?.dispose()
            }
            finalizeTerminalPlaybackError(message)
        case .fallback(let fallbackPlan, let diagnosticLine):
            Self.logger.info("\(diagnosticLine, privacy: .public)")
            // Tear down PlayerCore's half-built state before loading through
            // the new backend — it exited early without error but still holds
            // an AVAudioSession + allocated contexts.
            activePlayer.core?.dispose()
            logExecutionPlan(fallbackPlan)
            Task { @MainActor [weak self] in
                await self?.loadStream(plan: fallbackPlan)
            }
        }
    }

    /// Apply every persisted player preference. Called once per loaded file
    /// (from `onFileLoaded`) and after full settings refreshes. Targeted
    /// mutations should use narrower backend calls so unrelated knobs do not
    /// get re-applied during playback.
    func applySettingsToPlayer() {
        switch activePlayer {
        case .none:
            return
        case .coreMedia(let c):
            c.setHDREnabled(settings.hdrEnabled)
            c.setSpeed(settings.playbackSpeed)
            c.setAudioDelay(Double(settings.audioSyncMs) / 1000.0)
            c.setSubtitleDelay(Double(settings.subtitleSyncMs) / 1000.0)
            c.setVideoGravity(settings.videoGravity.avGravity)
            c.applySubtitleAppearance(settings.effectiveSubtitleAppearance)
        case .avPlayer(let a):
            a.setSpeed(settings.playbackSpeed)
            a.setSubtitleDelay(Double(settings.subtitleSyncMs) / 1000.0)
            a.applySubtitleAppearance(settings.effectiveSubtitleAppearance)
        }
    }

    private func applySubtitleAppearanceToPlayer() {
        switch activePlayer {
        case .none:
            return
        case .coreMedia(let c):
            c.applySubtitleAppearance(settings.effectiveSubtitleAppearance)
        case .avPlayer(let a):
            a.applySubtitleAppearance(settings.effectiveSubtitleAppearance)
        }
    }

    @MainActor
    func refreshSettingsFromServer() async {
        await settings.refreshFromServer()
        applySettingsToPlayer()
    }

    @MainActor
    func setSubtitleAppearance(_ appearance: SubtitleAppearance) async {
        await settings.setSubtitleAppearance(appearance)
        applySubtitleAppearanceToPlayer()
    }

    @MainActor
    func setSubtitlePosition(_ position: SubtitlePositionPreset) {
        var next = settings.subtitleAppearance
        guard next.position != position else { return }
        next.position = position
        settings.subtitleAppearance = next.sanitized()
        settings.subtitleUsesDeviceAppearanceOverride = true
        applySubtitleAppearanceToPlayer()
        Task { [settings] in
            await settings.setSubtitleAppearance(next)
        }
    }

    @MainActor
    func setSubtitleDeviceOverrideEnabled(_ enabled: Bool) async {
        await settings.setSubtitleDeviceOverrideEnabled(enabled)
        applySubtitleAppearanceToPlayer()
    }

    @MainActor
    func setSubtitleMatchesSystemAppearance(_ enabled: Bool) {
        settings.setSubtitleMatchesSystemAppearance(enabled)
        applySubtitleAppearanceToPlayer()
    }

    func setPlaybackSpeed(_ rate: Double) {
        settings.setPlaybackSpeed(rate)
        activePlayer.setSpeed(settings.playbackSpeed)
        scheduleHideControls()
    }

    /// Touch-and-hold fast forward (iOS). Applies `rate` directly to the
    /// backend without touching `settings.playbackSpeed`, so releasing the
    /// hold restores whatever speed the user had configured. No-op while
    /// paused — holding 2× on a paused player means nothing (both backends
    /// only apply rates to an already-running clock, so this is UX, not
    /// safety).
    func beginHoldFastForward(rate: Double = 2.0) {
        guard !isHoldFastForwarding, isPlaying else { return }
        isHoldFastForwarding = true
        activePlayer.setSpeed(rate)
    }

    /// Always restores the configured speed, even if playback paused during
    /// the hold: backends don't start a paused clock on `setSpeed`, and
    /// leaving the hold rate behind would make the next play resume at 2×.
    func endHoldFastForward() {
        guard isHoldFastForwarding else { return }
        isHoldFastForwarding = false
        activePlayer.setSpeed(settings.playbackSpeed)
    }

    func setVideoGravity(_ gravity: VideoGravity) {
        settings.setVideoGravity(gravity)
        guard backendCapabilities.supportsVideoGravity else { return }
        activePlayer.core?.setVideoGravity(settings.videoGravity.avGravity)
    }

    func setHDREnabled(_ enabled: Bool) {
        settings.setHDREnabled(enabled)
        guard backendCapabilities.supportsHDRToggle else { return }
        activePlayer.core?.setHDREnabled(settings.hdrEnabled)
    }

    func setAudioSyncMilliseconds(_ milliseconds: Int) {
        settings.setAudioSyncMs(milliseconds)
        guard backendCapabilities.supportsAudioDelay else { return }
        activePlayer.core?.setAudioDelay(Double(settings.audioSyncMs) / 1000.0)
    }

    func setSubtitleSyncMilliseconds(_ milliseconds: Int) {
        settings.setSubtitleSyncMs(milliseconds)
        guard backendCapabilities.supportsSubtitleDelay else { return }
        switch activePlayer {
        case .none:
            return
        case .coreMedia(let core):
            core.setSubtitleDelay(Double(settings.subtitleSyncMs) / 1000.0)
        case .avPlayer(let backend):
            backend.setSubtitleDelay(Double(settings.subtitleSyncMs) / 1000.0)
        }
    }

    /// Pushes the current item's poster into the Now Playing artwork field
    /// so the lock-screen, Control Center, and Apple TV "What's Playing"
    /// surface have a thumbnail. The poster URL is derived from the
    /// content's library catalog entry rather than `WatchDetail`, which
    /// doesn't expose image fields. The fetch runs in a background task on
    /// `NowPlayingController` and is best-effort: any failure leaves the
    /// existing artwork (or none) unchanged.
    private func pushNowPlayingArtwork(contentId: String) {
        guard !contentId.isEmpty else { return }
        // The presenter (e.g. ItemDetailView) already had the catalog
        // item loaded — when it routed us through `applyArtworkURLHints`
        // we can publish artwork without a second `/catalog/items/{id}`
        // round-trip. Fall through to the fetch only when no hint was
        // supplied.
        if let candidate = preferredArtworkCandidate(),
           let url = URL(string: candidate) {
            nowPlaying.setArtworkURL(url)
            return
        }
        Task { [weak self] in
            let detail: ItemDetail
            do {
                detail = try await ContinuumAPI.shared.itemDetail(contentId: contentId)
            } catch {
                Self.logger.warning(
                    "NowPlaying artwork itemDetail fetch failed for \(contentId, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                return
            }
            // Prefer poster; fall back to backdrop for items (notably some
            // episodes) that don't surface a dedicated poster.
            let posterCandidate = detail.posterUrl?.isEmpty == false ? detail.posterUrl : nil
            let backdropCandidate = detail.backdropUrl?.isEmpty == false ? detail.backdropUrl : nil
            guard let candidate = posterCandidate ?? backdropCandidate,
                  let url = URL(string: candidate) else {
                return
            }
            guard let self else { return }
            await MainActor.run {
                self.nowPlaying.setArtworkURL(url)
            }
        }
    }

    private func preferredArtworkCandidate() -> String? {
        if let poster = artworkPosterURLHint, !poster.isEmpty {
            return poster
        }
        if let backdrop = artworkBackdropURLHint, !backdrop.isEmpty {
            return backdrop
        }
        return nil
    }

    /// Caller-supplied artwork URLs piped through `PlayerView.onAppear`.
    /// Used by `pushNowPlayingArtwork` to skip its own catalog item fetch.
    func applyArtworkURLHints(posterURL: String?, backdropURL: String?) {
        artworkPosterURLHint = posterURL
        artworkBackdropURLHint = backdropURL
    }

    /// Push Now Playing at most every 2 seconds; the OS animates the
    /// scrubber between updates using `playbackRate`.
    private func pushNowPlayingIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastNowPlayingPush) > 2.0 else { return }
        lastNowPlayingPush = now
        nowPlaying.update(
            title: title,
            duration: duration,
            position: currentTime,
            isPlaying: isPlaying
        )
    }

    /// Called when the active backend reports natural EOF. Move the shell into
    /// a paused end-state immediately so the player does not look frozen if
    /// auto-play-next is unavailable.
    private func handleEndOfFile() {
        if activeServerOutageRecoverySessionId != nil {
            Self.logger.info("[CMP-RECOVERY] ignoring EOF while server outage recovery is active")
            return
        }
        // Detect a premature EOF before the autoplay hand-off. FFmpeg's
        // demuxer reports end-of-stream when the upstream HTTP connection is
        // reset, even if the file's real duration is still seconds away. The
        // player then drains its buffered packets cleanly and lands here, but
        // treating that as a natural end would trigger autoplay against the
        // same dead network that just dropped us.
        let observedPosition = currentTime
        let safeDuration = duration
        let isPremature: Bool = {
            guard safeDuration.isFinite, safeDuration > 0,
                  observedPosition.isFinite, observedPosition > 0 else {
                return false
            }
            let remaining = safeDuration - observedPosition
            let progress = observedPosition / safeDuration
            return remaining > Self.nearEndPlaybackErrorThresholdSeconds
                && progress < 0.985
        }()

        if isPremature {
            Self.logger.warning(
                "[CMP] handleEndOfFile suppressing autoplay: premature EOF at \(observedPosition, privacy: .public)/\(safeDuration, privacy: .public)"
            )
            // Cancel autoplay before we enter the postroll so the hand-off
            // to the next episode short-circuits — `beginNextUpPostroll`
            // checks `!nextUpAutoplayCancelled` before calling
            // `playNextEpisodeNow()`. The user is left on a recoverable
            // surface where they can retry via Play Now, pick from On Deck,
            // or hit Back.
            nextUpAutoplayCancelled = true
            cancelNextUpCountdown()
            // `showNotice` is `@MainActor`; this callback may not be, so
            // dispatch onto the main actor explicitly.
            Task { @MainActor [weak self] in
                self?.showNotice(
                    title: "Connection lost",
                    message: "Lost connection to the server before the episode finished.",
                    tone: .warning,
                    duration: 6
                )
            }
        }

        hasReachedEndOfFile = true
        clearServerOutageRecoveryState()
        hideControlsTask?.cancel()
        hideControlsTask = nil
        // AVPlayer reports EOF once the item is already fully drained, but
        // PlayerCore reports it while the VT/display tail is still winding
        // down. Pausing the shared CoreMedia path here can turn that tail
        // drain into a false terminal decode error on tvOS.
        if case .avPlayer = activePlayer {
            activePlayer.pause()
        }
        if duration.isFinite, duration > 0 {
            currentTime = duration
        }
        isLoading = false
        isBuffering = false
        bufferingProgress = nil
        isPlaying = false
        showControls = true
        nowPlaying.update(
            title: title,
            duration: duration,
            position: currentTime,
            isPlaying: false
        )

        // Natural end of an offline download: latch the local watched state
        // immediately (not just at close) so retention/reclaim see it even
        // if the process dies before `cleanup()` runs. DownloadManager is
        // MainActor-isolated; this callback may not be.
        if !isPremature, let offline = offlinePlaybackContext {
            let endPosition = currentTime
            Task { @MainActor [weak self] in
                self?.recordOfflineProgress(
                    context: offline,
                    position: endPosition,
                    markCompleted: true
                )
            }
        }

        beginNextUpPostroll(videoEnded: true)
    }

    private func attachNowPlayingIfNeeded() {
        // Attach Now Playing on first load. Idempotent — subsequent loads
        // just reuse the same controller; we tear down in `cleanup()`.
        // Handlers route through `activePlayer` so later route switches keep
        // driving remote commands against the current backend without a
        // re-attach step.
        nowPlaying.attach(handlers: NowPlayingController.Handlers(
            play:        { [weak self] in self?.activePlayer.play() },
            pause:       { [weak self] in self?.activePlayer.pause() },
            isPaused:    { [weak self] in
                guard let self else { return true }
                return self.hasReachedEndOfFile || self.activePlayer.isPaused()
            },
            currentTime: { [weak self] in self?.currentTime ?? 0 },
            seek:        { [weak self] t in self?.activePlayer.seek(to: t) }
        ))
    }

    private func resetPublishedLoadState(
        preferredAudioTrackIndex: Int?,
        preferredSubtitleTrackIndex: Int?,
        preferredSidecarSubtitleTrackId: Int64?,
        resetRouteRecoveryFlags: Bool = true
    ) {
        isLoading = true
        error = nil
        noticeDismissTask?.cancel()
        noticeDismissTask = nil
        remoteDismissTask?.cancel()
        remoteDismissTask = nil
        activeNotice = nil
        remoteDismissToken = nil
        hideControlsTask?.cancel()
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        seekFilterTimeoutTask?.cancel()
        seekFilterTimeoutTask = nil
        tearDownHoldSeek()
        isScrubbing = false
        scrubPreviewTime = currentTime
        seekOriginTime = nil
        seekTargetTime = nil
        showControls = false
        showNextUpScreen = false
        nextUpEpisode = nil
        nextUpOnDeckItems = []
        isLoadingNextUpEpisode = false
        isLoadingNextUpOnDeck = false
        nextUpLookupError = nil
        nextUpStartError = nil
        nextUpCountdownSeconds = nil
        nextUpCountdownTotalSeconds = Self.nextUpCountdownDefaultSeconds
        nextUpScreenVideoEnded = false
        nextUpPresentationSource = .automatic
        nextUpAutoplayCancelled = false
        nextUpPromptDismissed = false
        audioTracks = []
        subtitleTracks = []
        chapters = []
        introRange = nil
        creditsRange = nil
        cancelPendingIntroAutoSkip()
        qualityOptions = [ApplePlaybackQuality.auto]
        activeQualityId = ApplePlaybackQuality.autoId
        isQualitySwitching = false
        qualitySwitchError = nil
        serverProvidedChapters = []
        currentWatchDetail = nil
        currentSelectedVersion = nil
        activePreparedProtocolV3 = nil
        autoSkippedIntroKey = nil
        autoSkipIntroCancelledKey = nil
        selectedAudioId = nil
        selectedSubtitleId = nil
        selectedSecondarySubtitleId = nil
        bufferedAheadSeconds = 0
        stashSourceCacheHandoff()
        sourceProxy?.stop()
        sourceProxy = nil
        subtitleLoadStatus = [.primary: .idle, .secondary: .idle]
        if resetRouteRecoveryFlags {
            hasAttemptedNativeDirectRouteRecovery = false
            hasAttemptedSiloRouteCompatibilityFallback = false
        }
        knownExternalSubtitles = []
        pendingRecoveredAudioSelection = nil
        pendingRecoveredSubtitleSelection = nil
        pendingRecoveredSecondarySubtitleId = nil
        // Subtitle `-1` is the explicit "Off" sentinel; `applyTrackList`
        // disables subs when it sees a negative value.
        pendingAudioFfIndex = preferredAudioTrackIndex
        pendingSubtitleFfIndex = preferredSubtitleTrackIndex
        pendingSidecarSubtitleTrackId = preferredSidecarSubtitleTrackId
        hasExplicitSubtitleChoice =
            preferredSubtitleTrackIndex != nil || preferredSidecarSubtitleTrackId != nil
        prefsForCurrentItem = nil
        prefsResolvedForCurrentItem = false
    }

    private func resolvedAudioTrackIndexForResume() -> Int? {
        guard let selectedAudioId,
              let selected = audioTracks.first(where: { $0.trackId == selectedAudioId }),
              let selectionIndex = audioSelectionIndex(for: selected) else {
            return lastLoadRequest?.preferredAudioTrackIndex
        }
        return selectionIndex
    }

    private func resolvedSubtitleTrackIndexForResume() -> Int? {
        if let selectedSubtitleId,
           let selected = subtitleTracks.first(where: { $0.trackId == selectedSubtitleId }),
           let ffIndex = selected.ffIndex {
            return ffIndex
        }
        if let selectedSubtitleId, SubtitleTrackIdSpace.isSidecar(selectedSubtitleId) {
            // Sidecars are re-applied client-side after the playback
            // session returns `subtitle_urls`; keep embedded subtitles off
            // until that explicit sidecar selection is restored.
            return -1
        }
        if !subtitleTracks.isEmpty || lastLoadRequest?.preferredSubtitleTrackIndex == -1 {
            return -1
        }
        return lastLoadRequest?.preferredSubtitleTrackIndex
    }

    private func resolvedProtocolV3SubtitleIndexForResume() -> Int? {
        guard let selectedSubtitleId,
              !SubtitleTrackIdSpace.isAILive(selectedSubtitleId),
              let selected = subtitleTracks.first(where: { $0.trackId == selectedSubtitleId }),
              let version = currentSelectedVersion else {
            return nil
        }
        return ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
            for: selected,
            in: version
        )
    }

    private func resolvedSidecarSubtitleTrackIdForResume() -> Int64? {
        if let selectedSubtitleId, SubtitleTrackIdSpace.isSidecar(selectedSubtitleId) {
            return selectedSubtitleId
        }
        return lastLoadRequest?.preferredSidecarSubtitleTrackId
    }

    private func makeSuspendedPlaybackContext() -> SuspendedPlaybackContext? {
        guard let lastLoadRequest else { return nil }
        let request = LoadRequest(
            contentId: lastLoadRequest.contentId,
            preferredFileId: lastLoadRequest.preferredFileId,
            preferredAudioTrackIndex: resolvedAudioTrackIndexForResume(),
            preferredSubtitleTrackIndex: resolvedSubtitleTrackIndexForResume(),
            preferredSidecarSubtitleTrackId: resolvedSidecarSubtitleTrackIdForResume(),
            startFromBeginning: false,
            offlineDownloadId: lastLoadRequest.offlineDownloadId
        )
        let resumePosition = currentTime.isFinite ? max(0, currentTime) : 0
        return SuspendedPlaybackContext(
            request: request,
            resumePosition: resumePosition
        )
    }

    private func clearForegroundInterruptionState() {
        playbackInterruption = nil
        interruptionRecoveryTask?.cancel()
        interruptionRecoveryTask = nil
    }

    private func clearSuspendedPlaybackState() {
        suspendedPlayback = nil
    }

    private func beginFreshLoad(
        request: LoadRequest,
        progressPosition: Double?,
        finalizeCurrentSession: Bool = false,
        resumePositionOverride: Double? = nil,
        allowNearEndResume: Bool = false,
        preserveInterruptionState: Bool = false,
        origin: LoadOrigin = .userInitiated
    ) {
        guard !isDisposed else { return }
        #if os(tvOS)
        PosterImageCache.trimDecodedMemory()
        #endif
        lastLoadRequest = request
        offlinePlaybackContext = nil
        contentIdsNeedingDetailRefresh.insert(request.contentId)
        hasReachedEndOfFile = false
        cancelNextUpFlow()
        if origin == .userInitiated {
            clearServerOutageRecoveryState()
        }
        if !preserveInterruptionState {
            clearForegroundInterruptionState()
        }
        clearSuspendedPlaybackState()
        attachNowPlayingIfNeeded()
        resetPublishedLoadState(
            preferredAudioTrackIndex: request.preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: request.preferredSubtitleTrackIndex,
            preferredSidecarSubtitleTrackId: request.preferredSidecarSubtitleTrackId
        )

        freshLoadTask?.cancel()
        protocolV3ReplanTask?.cancel()
        protocolV3ReplanTask = nil
        freshLoadGeneration &+= 1
        let currentFreshLoadGeneration = freshLoadGeneration
        let snapshotPosition = progressPosition
        // Offline loads never start a replacement server session, so the
        // prior one must be finalized here — otherwise the bridge keeps
        // holding it and a later teardown would report the offline item's
        // position against the stale session.
        let shouldFinalizeCurrentSession = finalizeCurrentSession || request.offlineDownloadId != nil
        freshLoadTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            defer {
                if self.freshLoadGeneration == currentFreshLoadGeneration {
                    self.freshLoadTask = nil
                }
            }

            if let snapshotPosition, snapshotPosition.isFinite, snapshotPosition >= 0 {
                if shouldFinalizeCurrentSession {
                    await self.sessionBridge.stopSession(position: snapshotPosition, isPaused: true)
                } else {
                    await self.sessionBridge.reportProgress(position: snapshotPosition, isPaused: true)
                }
            }
            guard !Task.isCancelled, !self.isDisposed else { return }

            await self.realtimeClient.unbind()
            guard !Task.isCancelled, !self.isDisposed else { return }

            do {
                try await self.disposeActivePlayerForFreshLoad(
                    timeout: origin == .userInitiated ? nil : Self.autoplayPlayerDisposeTimeout
                )
                guard !Task.isCancelled, !self.isDisposed else { return }

                // The init kicked off `settingsRefreshTask` to fetch the
                // server's effective device settings before playback
                // starts. Awaiting it here (instead of issuing a fresh
                // `refreshFromServer`) avoids the race that produced two
                // back-to-back `/settings/effective` round-trips on every
                // play — the init request is already in flight and its
                // result is what we want anyway. If the task already
                // finished, this returns immediately.
                await self.settingsRefreshTask?.value
                guard !Task.isCancelled, !self.isDisposed else { return }

                let prepared: PreparedPlayback
                if let offlineDownloadId = request.offlineDownloadId {
                    // Fully local prepare from the stored record + manifest.
                    // Must keep working in airplane mode, so nothing on this
                    // branch (or downstream of it while
                    // `offlinePlaybackContext` is set) may require the server.
                    let offline = try await OfflinePlaybackBuilder.loadPreparedPlayback(
                        downloadId: offlineDownloadId,
                        startFromBeginning: request.startFromBeginning,
                        resumePositionOverride: resumePositionOverride
                    )
                    self.offlinePlaybackContext = OfflinePlaybackContext(
                        downloadId: offline.downloadId,
                        mediaItemId: offline.mediaItemId
                    )
                    self.nowPlaying.setArtworkURL(offline.posterFileURL)
                    prepared = offline.prepared
                } else {
                    // Bound the start-session call when the load was triggered
                    // by autoplay or interruption recovery. A user-initiated load
                    // keeps the unbounded behavior — a slow manual pick is
                    // annoying but doesn't wedge the UI; a hung autoplay does
                    // (the user is stuck on a half-cross-faded Next Up screen
                    // with no obvious way out).
                    prepared = try await self.runStartSession(
                        request: request,
                        resumePosition: resumePositionOverride,
                        allowNearEndResume: allowNearEndResume,
                        timeout: origin == .userInitiated ? nil : Self.autoplayStartSessionTimeout
                    )
                }
                guard !Task.isCancelled, !self.isDisposed else { return }

                let session = prepared.session
                self.activePlaybackSessionId = session.sessionId
                self.autoSkippedIntroKey = nil
                self.autoSkipIntroCancelledKey = nil
                self.cancelPendingIntroAutoSkip()
                self.staleSessionRecoverySessionId = nil
                self.backgroundRenewalTask?.cancel()
                self.backgroundRenewalTask = nil
                self.backgroundRenewalSessionId = nil
                self.backgroundRenewalTransientFailures = 0

                // Snapshot the preferred language for track-list ordering
                // unconditionally (even with an explicit choice) so the
                // displayed groups float the user's language to the top.
                self.subtitleOrderingLanguage = prepared.watchDetail.effectiveSubtitleLanguage

                // Snapshot the server-resolved subtitle policy so the
                // track-list callback (which fires post-FFmpeg-open)
                // can pick the right track without another fetch. Skip
                // entirely if the caller already passed an explicit
                // subtitle index — manual override always wins.
                if !self.hasExplicitSubtitleChoice {
                    let modeRaw = prepared.watchDetail.effectiveSubtitleMode ?? ""
                    self.prefsForCurrentItem = PrefsSnapshot(
                        preferredLanguage: prepared.watchDetail.effectiveSubtitleLanguage,
                        mode: SubtitleMode(rawValue: modeRaw),
                        showForced: prepared.watchDetail.effectiveShowForcedSubtitles ?? false,
                        trackSignature: prepared.watchDetail.effectiveSubtitleTrackSignature
                    )
                }

                self.title = prepared.displayTitle
                self.metadata = prepared.playerMetadata()
                self.pendingExternalSubtitles = session.subtitleUrls ?? []
                self.knownExternalSubtitles = self.pendingExternalSubtitles
                self.currentWatchDetail = prepared.watchDetail
                self.currentSelectedVersion = prepared.selectedVersion
                self.activePreparedProtocolV3 = prepared.protocolV3
                // Artwork and Next Up are catalog fetches; the offline path
                // already published its cached poster above and has no
                // server to resolve a next episode against.
                if request.offlineDownloadId == nil {
                    self.pushNowPlayingArtwork(contentId: prepared.watchDetail.contentId)
                    self.loadNextUpCandidate(for: prepared.watchDetail)
                    self.loadNextUpOnDeckItems(for: prepared.watchDetail)
                }
                self.qualityOptions = ApplePlaybackQuality.playbackOptions(for: prepared.selectedVersion)
                self.activeQualityId = prepared.activeQualityId
                self.isQualitySwitching = false
                self.qualitySwitchError = nil
                self.serverProvidedChapters = self.chapterInfoList(from: prepared.selectedVersion)
                self.duration = session.durationSeconds ?? prepared.selectedVersion.duration ?? 0
                self.currentTime = self.movieTime(for: session)
                self.applyMarkerRanges(
                    intro: prepared.selectedVersion.intro ?? prepared.watchDetail.intro,
                    credits: prepared.selectedVersion.credits ?? prepared.watchDetail.credits
                )

                // The realtime channel is a server websocket keyed by a real
                // session id; the synthetic offline session has neither.
                if request.offlineDownloadId == nil {
                    await self.realtimeClient.bind(sessionId: session.sessionId)
                    guard !Task.isCancelled, !self.isDisposed else { return }
                }

                guard let streamRequest = await self.makeStreamRequest(
                    session: session,
                    additionalHeaders: prepared.protocolV3?.plan.stream.headers ?? [:]
                ) else {
                    self.finalizeTerminalPlaybackError("Invalid stream URL")
                    return
                }
                self.resolvedServerUrl = streamRequest.serverUrl

                let plan = try self.makeExecutionPlan(prepared: prepared, streamRequest: streamRequest)
                self.currentDeliveryStrategy = plan.delivery
                self.playbackTimelineOffset = self.timelineOffset(
                    for: plan,
                    session: session,
                    requestedStart: resumePositionOverride
                )
                self.logExecutionPlan(plan)

                Self.logger.info("Play method: \(session.playMethod, privacy: .public)")
                // Keep the tvOS console breadcrumb useful without printing the
                // signed stream URL or any server identity.
                print("[CMP] streamPrepared playMethod=\(session.playMethod) startTime=\(plan.startMode.seconds)")

                await self.sessionBridge.reportProtocolV3PlanExecutionStarted()
                await self.loadStream(plan: plan)
            } catch let error {
                guard !Task.isCancelled, !self.isDisposed else { return }
                Self.logger.error("Load failed: \(String(describing: error), privacy: .public)")
                self.handleBeginFreshLoadFailure(error: error, origin: origin)
            }
        }
    }

    private func disposeActivePlayerForFreshLoad(timeout: TimeInterval?) async throws {
        let player = activePlayer
        activePlayer = .none
        try await Self.disposePlayerOffMain(player, timeout: timeout)
    }

    private static func disposePlayerOffMain(_ player: ActivePlayer, timeout: TimeInterval?) async throws {
        guard !player.isNone else { return }

        try await withCheckedThrowingContinuation { continuation in
            let completion = OneShotContinuation()

            DispatchQueue.global(qos: .userInitiated).async {
                player.dispose()
                completion.resume(continuation, with: .success(()))
            }

            if let timeout {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                    completion.resume(continuation, with: .failure(BeginFreshLoadError.playerDisposeTimeout))
                }
            }
        }
    }

    /// Race `sessionBridge.startSession` against an optional timeout. A nil
    /// `timeout` runs unbounded (matches the historical behavior). A non-nil
    /// timeout cancels the in-flight start when it elapses; URLSession's
    /// cancellation propagates as `CancellationError`, which we translate to
    /// `BeginFreshLoadError.startSessionTimeout` for the caller's catch block.
    /// If the surrounding `freshLoadTask` itself is cancelled (e.g. user
    /// navigated away), we propagate the cancellation unchanged.
    private func runStartSession(
        request: LoadRequest,
        resumePosition: Double?,
        allowNearEndResume: Bool,
        timeout: TimeInterval?
    ) async throws -> PreparedPlayback {
        if let timeout {
            let startTask = Task<PreparedPlayback, Error> { [sessionBridge] in
                try await sessionBridge.startSession(
                    contentId: request.contentId,
                    preferredFileId: request.preferredFileId,
                    preferredAudioTrackIndex: request.preferredAudioTrackIndex,
                    preferredSubtitleTrackIndex: request.preferredSubtitleTrackIndex,
                    startFromBeginning: request.startFromBeginning,
                    resumePosition: resumePosition,
                    allowNearEndResume: allowNearEndResume,
                    preferredQualityOverride: request.preferredQualityOverride
                )
            }
            let timeoutTask = Task<Void, Never> { [startTask] in
                try? await Task.sleep(for: .seconds(timeout))
                startTask.cancel()
            }
            defer { timeoutTask.cancel() }

            do {
                return try await startTask.value
            } catch is CancellationError {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw BeginFreshLoadError.startSessionTimeout
            }
        } else {
            return try await self.sessionBridge.startSession(
                contentId: request.contentId,
                preferredFileId: request.preferredFileId,
                preferredAudioTrackIndex: request.preferredAudioTrackIndex,
                preferredSubtitleTrackIndex: request.preferredSubtitleTrackIndex,
                startFromBeginning: request.startFromBeginning,
                resumePosition: resumePosition,
                allowNearEndResume: allowNearEndResume,
                preferredQualityOverride: request.preferredQualityOverride
            )
        }
    }

    /// Routes a `beginFreshLoad` failure based on what triggered the load.
    /// User-initiated loads keep the historical full-screen error wall.
    /// Autoplay and interruption-recovery loads instead restore the Next Up
    /// postroll with `nextUpStartError` set so the user can pick something
    /// from On Deck or hit Back without the player being taken hostage by an
    /// `error` overlay.
    @MainActor
    private func handleBeginFreshLoadFailure(error: Error, origin: LoadOrigin) {
        let message: String = {
            if case BeginFreshLoadError.playerDisposeTimeout = error {
                return "The previous playback engine didn't finish shutting down."
            }
            if case BeginFreshLoadError.startSessionTimeout = error {
                return "The server didn't respond in time."
            }
            if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
                return localized
            }
            return String(describing: error)
        }()

        switch origin {
        case .userInitiated:
            finalizeTerminalPlaybackError(message)
        case .autoplay:
            Self.logger.warning(
                "[CMP] beginFreshLoad recovered from autoplay failure: \(message, privacy: .public)"
            )
            // Tear down the disposed player + source proxy the same way
            // `finalizeTerminalPlaybackError` would, but DON'T set
            // `viewModel.error` — we want a recoverable surface, not a wall.
            sourceProxy?.stop()
            sourceProxy = nil
            isLoading = false
            isPlaying = false
            // Restore the postroll surface so the user can choose what to
            // do next. Drop the candidate episode so the panel renders the
            // "Finished" branch with the new `nextUpStartError` message.
            cancelNextUpFlow()
            nextUpStartError = message
            nextUpEpisode = nil
            nextUpAutoplayCancelled = true
            isLoadingNextUpEpisode = false
            showNextUpScreen = true
            nextUpScreenVideoEnded = true
            showNotice(
                title: "Couldn't start the next episode",
                message: message,
                tone: .warning,
                duration: 6
            )
        case .recovery:
            Self.logger.warning(
                "[CMP] beginFreshLoad recovered from playback recovery failure: \(message, privacy: .public)"
            )
            clearServerOutageRecoveryState()
            sourceProxy?.stop()
            sourceProxy = nil
            isLoading = false
            isPlaying = false
            showNotice(
                title: "Playback recovery failed",
                message: message,
                tone: .warning,
                duration: 6
            )
        }
    }

    private func completeInterruptionRecoveryIfNeeded(
        observedTime: Double,
        requiresForwardProgress: Bool
    ) {
        guard var interruption = playbackInterruption, interruption.isPending else { return }
        let didRecover: Bool
        if requiresForwardProgress {
            didRecover = observedTime.isFinite
                && observedTime >= interruption.positionSeconds
                + Self.interruptionResumeSuccessThresholdSeconds
        } else {
            didRecover = true
        }
        guard didRecover else { return }

        interruption.isPending = false
        playbackInterruption = nil
        interruptionRecoveryTask?.cancel()
        interruptionRecoveryTask = nil
        error = nil
        isLoading = false
    }

    private func shouldAutoRecoverFromInterruption() -> Bool {
        guard let interruption = playbackInterruption, interruption.isPending else { return false }
        guard !interruption.didAutoRecover else { return false }
        return Date() <= interruption.recoveryDeadline
    }

    private func triggerAutomaticInterruptionRecovery() {
        guard let lastLoadRequest, var interruption = playbackInterruption, !interruption.didAutoRecover else {
            return
        }
        interruption.didAutoRecover = true
        interruption.isPending = true
        playbackInterruption = interruption
        interruptionRecoveryTask?.cancel()
        interruptionRecoveryTask = nil
        error = nil
        isLoading = true
        isPlaying = false
        beginFreshLoad(
            request: lastLoadRequest,
            progressPosition: interruption.positionSeconds,
            resumePositionOverride: interruption.positionSeconds,
            allowNearEndResume: true,
            preserveInterruptionState: true,
            origin: .recovery
        )
    }

    private func finalizeTerminalPlaybackError(_ message: String) {
        clearForegroundInterruptionState()
        clearSuspendedPlaybackState()
        clearServerOutageRecoveryState()
        discardSourceCacheHandoff()
        activePlayer.dispose()
        sourceProxy?.stop()
        sourceProxy = nil
        activePlaybackSessionId = nil
        error = message
        isLoading = false
        isPlaying = false
    }

    /// Silently renews a lost server session in place: the bridge re-POSTs
    /// the captured start request (same file, same plan), the source proxy
    /// is retargeted at the renewed stream URL, and the player, remuxer, and
    /// cache are never touched — zero user-visible effect. Returns false
    /// when this playback cannot be renewed in place (offline, non-direct
    /// delivery, no proxy); the caller falls back to the visible renewal.
    /// A renewal that fails with a re-plan escalates to the visible renewal
    /// itself; transient failures retry on the next trigger (the 10 s
    /// progress heartbeat) up to a small cap.
    @discardableResult
    private func attemptBackgroundSessionRenewal(reason: String, observedPosition: Double) -> Bool {
        guard !isDisposed,
              offlinePlaybackContext == nil,
              currentDeliveryStrategy == .direct,
              sourceProxy != nil else {
            return false
        }
        let staleSessionId = activePlaybackSessionId ?? "unknown"
        if backgroundRenewalSessionId == staleSessionId {
            return true
        }
        backgroundRenewalSessionId = staleSessionId
        let resumePosition = observedPosition.isFinite
            ? max(0, observedPosition)
            : max(0, currentTime)

        Self.logger.warning(
            "[CMP-RECOVERY] background session renewal started session=\(staleSessionId, privacy: .public) reason=\(reason, privacy: .public) position=\(resumePosition, privacy: .public)"
        )

        backgroundRenewalTask?.cancel()
        backgroundRenewalTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            do {
                let renewed = try await self.sessionBridge.renewDirectSession(
                    position: resumePosition,
                    audioTrackIndex: self.resolvedAudioTrackIndexForResume()
                )
                guard !Task.isCancelled, !self.isDisposed else { return }
                // A fresh load may have replaced this playback while the
                // renewal was in flight; adopting the new session into it
                // would cross-wire two generations.
                guard self.activePlaybackSessionId == staleSessionId,
                      let proxy = self.sourceProxy else {
                    Self.logger.info(
                        "[CMP-RECOVERY] background renewal superseded session=\(staleSessionId, privacy: .public)"
                    )
                    return
                }
                guard let streamRequest = await self.makeStreamRequest(session: renewed) else {
                    self.failBackgroundRenewal(
                        reason: reason,
                        observedPosition: resumePosition,
                        detail: "invalid renewed stream URL"
                    )
                    return
                }
                proxy.retargetOrigin(url: streamRequest.url, headers: streamRequest.headers)
                self.activePlaybackSessionId = renewed.sessionId
                self.staleSessionRecoverySessionId = nil
                self.backgroundRenewalSessionId = nil
                self.backgroundRenewalTransientFailures = 0
                await self.realtimeClient.unbind()
                guard !Task.isCancelled, !self.isDisposed else { return }
                await self.realtimeClient.bind(sessionId: renewed.sessionId)
                Self.logger.info(
                    "[CMP-RECOVERY] background session renewal succeeded old=\(staleSessionId, privacy: .public) new=\(renewed.sessionId, privacy: .public) reason=\(reason, privacy: .public)"
                )
            } catch let error as PlaybackSessionBridge.DirectSessionRenewalError {
                guard !Task.isCancelled, !self.isDisposed else { return }
                // The server re-planned (or nothing is renewable): only a
                // full visible renewal can pick up the new plan.
                self.failBackgroundRenewal(
                    reason: reason,
                    observedPosition: resumePosition,
                    detail: String(describing: error)
                )
            } catch {
                guard !Task.isCancelled, !self.isDisposed else { return }
                self.backgroundRenewalSessionId = nil
                self.backgroundRenewalTransientFailures += 1
                if self.backgroundRenewalTransientFailures >= Self.backgroundRenewalTransientFailureLimit {
                    self.failBackgroundRenewal(
                        reason: reason,
                        observedPosition: resumePosition,
                        detail: "transient failures exhausted: \(error)"
                    )
                } else {
                    // Leave the flag clear so the next trigger (progress
                    // heartbeat or stream 404) retries; a genuinely dead
                    // server escalates through the source-interruption path
                    // independently of this renewal.
                    Self.logger.warning(
                        "[CMP-RECOVERY] background renewal transient failure #\(self.backgroundRenewalTransientFailures) session=\(staleSessionId, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
        return true
    }

    @MainActor
    private func failBackgroundRenewal(reason: String, observedPosition: Double, detail: String) {
        Self.logger.warning(
            "[CMP-RECOVERY] background renewal escalating to visible renewal reason=\(reason, privacy: .public): \(detail, privacy: .public)"
        )
        backgroundRenewalSessionId = nil
        backgroundRenewalTransientFailures = 0
        _ = attemptStaleSessionRenewal(
            reason: "\(reason)_bg_renewal_failed",
            observedPosition: observedPosition
        )
    }

    @discardableResult
    private func attemptStaleSessionRenewal(reason: String, observedPosition: Double) -> Bool {
        guard !isDisposed,
              let lastLoadRequest else {
            return false
        }

        let staleSessionId = activePlaybackSessionId ?? "unknown"
        if staleSessionRecoverySessionId == staleSessionId {
            return true
        }
        staleSessionRecoverySessionId = staleSessionId
        // A visible renewal supersedes any in-flight silent one; a late
        // retarget landing mid-teardown would cross-wire the generations.
        backgroundRenewalTask?.cancel()
        backgroundRenewalTask = nil
        backgroundRenewalSessionId = nil

        let resumePosition = observedPosition.isFinite
            ? max(0, observedPosition)
            : max(0, currentTime)
        let contentId = currentWatchDetail?.contentId ?? lastLoadRequest.contentId
        let durationHint = duration.isFinite && duration > 0
            ? duration
            : (currentSelectedVersion?.duration ?? 0)
        let renewalRequest = LoadRequest(
            contentId: lastLoadRequest.contentId,
            preferredFileId: currentSelectedVersion?.fileId ?? lastLoadRequest.preferredFileId,
            preferredAudioTrackIndex: resolvedAudioTrackIndexForResume(),
            preferredSubtitleTrackIndex: resolvedSubtitleTrackIndexForResume(),
            preferredSidecarSubtitleTrackId: resolvedSidecarSubtitleTrackIdForResume(),
            startFromBeginning: false
        )

        Self.logger.warning(
            "Renewing stale playback session \(staleSessionId, privacy: .public) reason=\(reason, privacy: .public) position=\(resumePosition, privacy: .public)"
        )

        staleSessionRecoveryTask?.cancel()
        staleSessionRecoveryTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            _ = await self.sessionBridge.syncProgress(
                contentId: contentId,
                position: resumePosition,
                duration: durationHint,
                forceOverwrite: true
            )
            guard !Task.isCancelled, !self.isDisposed else { return }

            self.progressTask?.cancel()
            self.beginFreshLoad(
                request: renewalRequest,
                progressPosition: nil,
                resumePositionOverride: resumePosition,
                allowNearEndResume: true,
                preserveInterruptionState: true,
                origin: .recovery
            )
        }
        return true
    }

    /// Origin-outage ride-through entry/exit, driven by the source proxy's
    /// `onOriginOutageChanged`. Entry keeps playback untouched (the player
    /// rides its buffered runway), suppresses the loopback watchdog
    /// escalations that would misread the quiet park as a route wedge, and
    /// starts a server-health poll whose success nudges an immediate origin
    /// re-probe. Exit restores everything. The visible outage recovery runs
    /// only when the budget expires.
    @MainActor
    private func handleOriginOutageChanged(_ active: Bool) {
        guard !isDisposed else { return }
        if active {
            // A full visible recovery already owns this outage.
            guard activeServerOutageRecoverySessionId == nil else { return }
            guard !sourceOutageActive else { return }
            sourceOutageActive = true
            sourceOutageNoticeShown = false
            activePlayer.avBackend?.setExternalStallSuppression(true)
            Self.logger.warning("[CMP-OUTAGE] ride-through started")
            if isBuffering {
                // Already out of runway when the outage was detected (e.g. a
                // seek beyond the cache raced the outage) — the notice's
                // buffering-edge trigger won't fire again.
                noteBufferingDuringSourceOutage()
            }
            sourceOutageRideThroughTask?.cancel()
            sourceOutageRideThroughTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let deadline = Date().addingTimeInterval(Self.serverOutageRecoveryTimeout)
                var delay = Self.serverOutageRecoveryInitialDelay
                while !Task.isCancelled,
                      !self.isDisposed,
                      self.sourceOutageActive,
                      Date() < deadline {
                    if await self.probeServerHealthOnce() {
                        Self.logger.info("[CMP-OUTAGE] server healthy; nudging origin re-probe")
                        self.sourceProxy?.reprobeOrigin()
                    }
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, Self.serverOutageRecoveryMaxDelay)
                }
                guard !Task.isCancelled, !self.isDisposed, self.sourceOutageActive else { return }
                Self.logger.error("[CMP-OUTAGE] ride-through budget exhausted; escalating to visible recovery")
                self.sourceOutageActive = false
                self.sourceOutageNoticeShown = false
                self.activePlayer.avBackend?.setExternalStallSuppression(false)
                self.sourceOutageRideThroughTask = nil
                _ = self.attemptServerOutageRecovery(
                    reason: .networkUnavailable,
                    observedPosition: self.currentTime
                )
            }
        } else {
            guard sourceOutageActive else { return }
            Self.logger.info("[CMP-OUTAGE] ride-through ended; origin recovered")
            let showReconnected = sourceOutageNoticeShown
            clearSourceOutageRideThroughState()
            // An item whose segment fetches died during the outage won't
            // retry them on its own — kick the stall recovery immediately
            // rather than waiting for a watchdog to misread the wedge.
            activePlayer.avBackend?.kickPlaybackAfterExternalStallCleared()
            if showReconnected {
                showNotice(
                    title: "Reconnected",
                    message: "Connection to the server was restored.",
                    tone: .info,
                    duration: 3
                )
            }
        }
    }

    private func clearSourceOutageRideThroughState() {
        sourceOutageActive = false
        sourceOutageNoticeShown = false
        activePlayer.avBackend?.setExternalStallSuppression(false)
        sourceOutageRideThroughTask?.cancel()
        sourceOutageRideThroughTask = nil
    }

    /// One server health probe (auth statuses count as reachable — the
    /// server is up even if this credential can't read /health).
    private func probeServerHealthOnce() async -> Bool {
        do {
            let _: HealthStatus = try await HTTPClient.shared.get("/api/v1/health")
            return true
        } catch {
            if let httpError = error as? HTTPError,
               let statusCode = httpError.statusCode,
               statusCode == 401 || statusCode == 403 {
                return true
            }
            return false
        }
    }

    /// Show the "Reconnecting" notice the first time the player actually
    /// runs out of runway during an origin outage — the runway gate that
    /// keeps short outages entirely invisible.
    @MainActor
    private func noteBufferingDuringSourceOutage() {
        guard sourceOutageActive, !sourceOutageNoticeShown else { return }
        sourceOutageNoticeShown = true
        Self.logger.warning("[CMP-OUTAGE] runway exhausted; showing reconnecting notice")
        showNotice(
            title: "Reconnecting",
            message: "Connection to the server was lost. Trying to reconnect…",
            tone: .warning,
            duration: Self.serverOutageRecoveryTimeout
        )
    }

    @discardableResult
    @MainActor
    private func attemptServerOutageRecovery(
        reason: PlaybackSourceInterruptionReason,
        observedPosition: Double
    ) -> Bool {
        guard !isDisposed,
              !hasReachedEndOfFile,
              let lastLoadRequest else {
            return false
        }

        let interruptedSessionId = activePlaybackSessionId ?? "unknown"
        if activeServerOutageRecoverySessionId == interruptedSessionId {
            return true
        }

        serverOutageRecoveryGeneration &+= 1
        let generation = serverOutageRecoveryGeneration
        activeServerOutageRecoverySessionId = interruptedSessionId
        // Outage recovery tears the proxy down; cancel any in-flight silent
        // renewal so its retarget can't land mid-teardown, and end the
        // ride-through (its watchdog suppression must not outlive the proxy).
        backgroundRenewalTask?.cancel()
        backgroundRenewalTask = nil
        backgroundRenewalSessionId = nil
        clearSourceOutageRideThroughState()

        let resumePosition = observedPosition.isFinite
            ? max(0, observedPosition)
            : max(0, currentTime)
        let recoveryRequest = LoadRequest(
            contentId: lastLoadRequest.contentId,
            preferredFileId: currentSelectedVersion?.fileId ?? lastLoadRequest.preferredFileId,
            preferredAudioTrackIndex: resolvedAudioTrackIndexForResume(),
            preferredSubtitleTrackIndex: resolvedSubtitleTrackIndexForResume(),
            preferredSidecarSubtitleTrackId: resolvedSidecarSubtitleTrackIdForResume(),
            startFromBeginning: false
        )

        Self.logger.warning(
            "[CMP-RECOVERY] server outage recovery started session=\(interruptedSessionId, privacy: .public) reason=\(String(describing: reason), privacy: .public) position=\(resumePosition, privacy: .public)"
        )

        progressTask?.cancel()
        progressTask = nil
        stashSourceCacheHandoff()
        sourceProxy?.stop()
        sourceProxy = nil
        activePlayer.dispose()
        isLoading = false
        isPlaying = false
        error = nil
        showNotice(
            title: "Reconnecting",
            message: "The server is updating. Playback will resume when it is ready.",
            tone: .warning,
            duration: Self.serverOutageRecoveryTimeout
        )

        serverOutageRecoveryTask?.cancel()
        serverOutageRecoveryTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            let ready = await self.waitForServerReady(
                timeout: Self.serverOutageRecoveryTimeout,
                generation: generation
            )
            guard !Task.isCancelled,
                  !self.isDisposed,
                  self.serverOutageRecoveryGeneration == generation else {
                Self.logger.info("[CMP-RECOVERY] server outage recovery cancelled session=\(interruptedSessionId, privacy: .public)")
                return
            }

            guard ready else {
                Self.logger.error(
                    "[CMP-RECOVERY] server outage recovery exhausted session=\(interruptedSessionId, privacy: .public)"
                )
                self.clearServerOutageRecoveryState()
                self.finalizeTerminalPlaybackError("The server did not come back online in time.")
                return
            }

            Self.logger.info(
                "[CMP-RECOVERY] server ready; restarting playback session=\(interruptedSessionId, privacy: .public) position=\(resumePosition, privacy: .public)"
            )
            self.beginFreshLoad(
                request: recoveryRequest,
                progressPosition: nil,
                resumePositionOverride: resumePosition,
                allowNearEndResume: true,
                preserveInterruptionState: true,
                origin: .recovery
            )
        }
        return true
    }

    private func clearServerOutageRecoveryState() {
        serverOutageRecoveryGeneration &+= 1
        activeServerOutageRecoverySessionId = nil
        serverOutageRecoveryTask?.cancel()
        serverOutageRecoveryTask = nil
    }

    @MainActor
    private func waitForServerReady(timeout: TimeInterval, generation: UInt64) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var delay = Self.serverOutageRecoveryInitialDelay

        while !Task.isCancelled,
              !isDisposed,
              serverOutageRecoveryGeneration == generation,
              Date() < deadline {
            do {
                let _: HealthStatus = try await HTTPClient.shared.get("/api/v1/health")
                Self.logger.info("[CMP-RECOVERY] server health probe succeeded")
                return true
            } catch {
                if let httpError = error as? HTTPError,
                   let statusCode = httpError.statusCode,
                   statusCode == 401 || statusCode == 403 {
                    Self.logger.info(
                        "[CMP-RECOVERY] server health probe reached auth status=\(statusCode, privacy: .public); treating server as ready"
                    )
                    return true
                }
                Self.logger.warning(
                    "[CMP-RECOVERY] server health probe failed; retrying in \(delay, privacy: .public)s error=\(String(describing: error), privacy: .public)"
                )
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            try? await Task.sleep(for: .seconds(min(delay, remaining)))
            delay = min(delay * 2, Self.serverOutageRecoveryMaxDelay)
        }

        return false
    }

    private func isPlaybackSessionMissingMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("playback_session_not_found")
            || lowered.contains("playback session not found")
    }

    /// The loopback writer's ingest ended clearly short of the known content
    /// (`LoopbackWriterError.prematureSourceEnd`) — an origin outage, not an
    /// engine defect. It must route into server-outage recovery, not the
    /// engine-fallback ladder: degrading to PlayerCore against a dead origin
    /// trades a recoverable stream for a second failure.
    private func isPrematureSourceEndMessage(_ message: String) -> Bool {
        message.contains("prematureSourceEnd")
    }

    /// The PlayerCore direct route talks to the origin without the source
    /// proxy, so an expired playback session surfaces as a bare HTTP 404 from
    /// FFmpeg ("Server returned 404 Not Found") — the server's
    /// `playback_session_not_found` body that the proxy used to parse never
    /// reaches the error message. Treat a 404 on that route as a stale
    /// session. `attemptStaleSessionRenewal` fires at most once per session,
    /// so a genuinely missing file still fails after a single renewal pass.
    private func isLikelyExpiredSessionHTTP404(_ message: String) -> Bool {
        guard activeRouteKind == .playerCoreDirect else { return false }
        return message.contains("Server returned 404")
    }

    func loadAndPlay(
        contentId: String,
        preferredFileId: Int? = nil,
        preferredAudioTrackIndex: Int? = nil,
        preferredSubtitleTrackIndex: Int? = nil,
        startFromBeginning: Bool,
        resumePositionOverride: Double? = nil,
        offlineDownloadId: String? = nil
    ) {
        let request = LoadRequest(
            contentId: contentId,
            preferredFileId: preferredFileId,
            preferredAudioTrackIndex: preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: preferredSubtitleTrackIndex,
            preferredSidecarSubtitleTrackId: nil,
            startFromBeginning: startFromBeginning,
            offlineDownloadId: offlineDownloadId
        )
        beginFreshLoad(
            request: request,
            progressPosition: currentTime,
            resumePositionOverride: resumePositionOverride
        )
    }

    /// Re-run the last `loadAndPlay` from scratch after an error. Currently a
    /// fresh session — simpler than retrying just the stream load, and
    /// tolerates stale server-side sessions that may have been reaped.
    func retry() {
        guard let last = lastLoadRequest else { return }
        Self.logger.info("Retrying playback for contentId=\(last.contentId, privacy: .public)")
        beginFreshLoad(
            request: last,
            progressPosition: currentTime,
            resumePositionOverride: currentTime,
            allowNearEndResume: true
        )
    }

    func togglePlayPause() {
        #if os(tvOS)
        if isBackgroundSuspended {
            resumeSuspendedPlayback()
            return
        }
        #endif
        // `isPlaying` is driven by the backend's `onPauseChange` callback;
        // let that be the single writer so the UI can't drift out of sync
        // with the actual pipeline state on error paths.
        if isPlaying {
            activePlayer.pause()
        } else {
            activePlayer.play()
        }
        scheduleHideControls()
    }

    #if os(tvOS)
    /// Native-player Select behavior for timeline entry: pause immediately
    /// and keep the full transport mounted. When controls were hidden,
    /// `TVPlayerControls` consumes a separate request token to focus and
    /// activate its timeline scrubber.
    func pauseForTimelineSelection() {
        guard !isBackgroundSuspended, !isLoading, !hasReachedEndOfFile else { return }
        if isPlaying {
            activePlayer.pause()
        }
        pinControlsVisible()
    }
    #endif

    func switchQuality(_ qualityId: String) {
        guard !isBackgroundSuspended else { return }
        guard let plan = activeExecutionPlan else { return }
        let normalized = ApplePlaybackQuality.normalizeStoredId(qualityId)
        let resolvedQualityId = normalized

        guard resolvedQualityId != activeQualityId || qualitySwitchError != nil else { return }
        if activePreparedProtocolV3 != nil {
            let target = currentTime.isFinite ? max(0, currentTime) : 0
            isQualitySwitching = true
            qualitySwitchError = nil
            showControls = true
            hideControlsTask?.cancel()
            attemptProtocolV3Replan(
                position: target,
                classification: "quality_changed",
                message: "User selected playback quality \(resolvedQualityId).",
                qualityPreference: resolvedQualityId,
                completesQualitySwitch: true
            )
            return
        }
        let qualityRequiresTranscode = currentSelectedVersion.map {
            ApplePlaybackQuality.shouldForceTranscode(
                preferredQualityId: resolvedQualityId,
                selectedVersion: $0
            )
        } ?? true
        if !qualityRequiresTranscode {
            if plan.delivery == .direct || plan.delivery == .remux {
                activeQualityId = resolvedQualityId
                qualitySwitchError = nil
                return
            }
            if plan.delivery == .transcode, let lastLoadRequest {
                // Currently transcoding, but the requested quality (e.g. back
                // to Auto after a manual downgrade) no longer needs it. An
                // in-place transcode restart can only produce HLS again —
                // replan the whole session so the server can hand back direct
                // play. Same pattern as interruption recovery: preserve the
                // current track selections and resume at the current position.
                var request = LoadRequest(
                    contentId: lastLoadRequest.contentId,
                    preferredFileId: lastLoadRequest.preferredFileId,
                    preferredAudioTrackIndex: resolvedAudioTrackIndexForResume(),
                    preferredSubtitleTrackIndex: resolvedSubtitleTrackIndexForResume(),
                    preferredSidecarSubtitleTrackId: resolvedSidecarSubtitleTrackIdForResume(),
                    startFromBeginning: false,
                    offlineDownloadId: lastLoadRequest.offlineDownloadId
                )
                request.preferredQualityOverride = resolvedQualityId
                let target = currentTime.isFinite ? max(0, currentTime) : 0
                qualitySwitchError = nil
                beginFreshLoad(
                    request: request,
                    progressPosition: target,
                    finalizeCurrentSession: true,
                    resumePositionOverride: target,
                    allowNearEndResume: true
                )
                return
            }
        }

        let target = currentTime.isFinite ? max(0, currentTime) : 0
        isQualitySwitching = true
        qualitySwitchError = nil
        showControls = true
        hideControlsTask?.cancel()
        _ = restartCurrentTranscodeHLS(
            to: target,
            origin: target,
            qualityId: resolvedQualityId,
            source: "quality"
        )
    }

    func handleScenePhase(_ phase: ScenePhase) {
        #if os(tvOS)
        switch phase {
        case .inactive:
            pauseForForegroundInterruptionIfNeeded()
        case .background:
            suspendForBackground()
        case .active:
            if isBackgroundSuspended {
                Self.logger.info("tvOS player woke from background suspend; awaiting explicit resume")
                print("[CMP-LIFECYCLE] tvOS active after background suspend; waiting for explicit resume")
                showControls = true
                hideControlsTask?.cancel()
                break
            }
            guard var interruption = playbackInterruption,
                  interruption.isPending,
                  interruption.wasPlaying else { break }
            Self.logger.info("tvOS player resuming after transient inactive interruption")
            print("[CMP-LIFECYCLE] tvOS active after transient inactive; resuming playback")
            interruption.recoveryDeadline = Date().addingTimeInterval(
                Self.interruptionRecoveryTimeout
            )
            playbackInterruption = interruption
            isLoading = true
            error = nil
            activePlayer.play()

            interruptionRecoveryTask?.cancel()
            interruptionRecoveryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(
                    for: .seconds(Self.interruptionRecoveryTimeout)
                )
                guard !Task.isCancelled, let self else { return }
                guard let interruption = self.playbackInterruption,
                      interruption.isPending,
                      !interruption.didAutoRecover,
                      Date() >= interruption.recoveryDeadline else { return }
                self.triggerAutomaticInterruptionRecovery()
            }
        @unknown default:
            break
        }
        #elseif os(macOS)
        switch phase {
        case .background:
            if isPlaying {
                activePlayer.pause()
            }
        case .inactive, .active:
            break
        @unknown default:
            break
        }
        #else
        isSceneBackgrounded = phase == .background
        switch phase {
        case .background:
            // AirPlay is playing on the receiver, not the phone; pausing here
            // would stop the TV. `handleExternalPlaybackActiveChange` covers
            // the route going away while we stay backgrounded.
            if avPlayerBackend?.isExternalPlaybackActive == true {
                break
            }
            // PiP keeps playing in the floating window after the app is
            // backgrounded; pausing here would defeat it.
            if PictureInPictureCoordinator.shared.isEngaged {
                break
            }
            // Automatic PiP can publish `willStart` just after ScenePhase
            // reaches background. Give it one bounded window; failure/stop
            // callbacks re-run the same pause policy immediately.
            if PictureInPictureCoordinator.shared.isPossible {
                schedulePictureInPictureBackgroundGrace()
                break
            }
            pauseBackgroundPlaybackIfUnrouted()
        case .active:
            pictureInPictureBackgroundGraceTask?.cancel()
            pictureInPictureBackgroundGraceTask = nil
        case .inactive:
            break
        @unknown default:
            break
        }
        #endif
    }

    #if os(iOS)
    /// AirPlay and PiP are the only two reasons the iOS player keeps running
    /// while the app is backgrounded. When the receiver goes away mid-session
    /// — the user picks "iPhone" in Control Center, or the Apple TV drops off
    /// the network — nothing else notices, and playback would carry on as
    /// invisible background audio. Pause instead, matching what `.background`
    /// would have done had the route already been gone.
    private func handleExternalPlaybackActiveChange(_ active: Bool) {
        if active {
            pictureInPictureBackgroundGraceTask?.cancel()
            pictureInPictureBackgroundGraceTask = nil
            return
        }
        pauseBackgroundPlaybackIfUnrouted()
    }

    private func schedulePictureInPictureBackgroundGrace() {
        pictureInPictureBackgroundGraceTask?.cancel()
        pictureInPictureBackgroundGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.pictureInPictureBackgroundGraceTask = nil
            self.pauseBackgroundPlaybackIfUnrouted()
        }
    }

    private func handlePictureInPictureEngagementEnded() {
        pictureInPictureBackgroundGraceTask?.cancel()
        pictureInPictureBackgroundGraceTask = nil
        pauseBackgroundPlaybackIfUnrouted()
    }

    private func pauseBackgroundPlaybackIfUnrouted() {
        guard isSceneBackgrounded, isPlaying else { return }
        guard avPlayerBackend?.isExternalPlaybackActive != true else { return }
        guard !PictureInPictureCoordinator.shared.isEngaged else { return }
        Self.logger.info("Background playback has no active AirPlay or PiP route; pausing")
        activePlayer.pause()
    }
    #endif

    /// Skip by ±`seconds` relative to the current preview position. By
    /// default this summons the transport overlay so the scrubber's preview
    /// gives visual feedback. The iOS double-tap gesture passes
    /// `revealingControls: false` — it draws its own flash, and popping the
    /// overlay would put the scrim on top of the gesture layer and eat the
    /// next double-tap.
    func skipForward(_ seconds: Double = 30, revealingControls: Bool = true) {
        guard !isBackgroundSuspended else { return }
        guard !hasReachedEndOfFile else { return }
        Self.logger.info(
            "[CMP-SEEK] skip forward requested seconds=\(seconds, privacy: .public) current=\(self.currentTime, privacy: .public) preview=\(self.scrubPreviewTime, privacy: .public) isScrubbing=\(self.isScrubbing, privacy: .public)"
        )
        queueSkipDebounce(delta: seconds)
        if revealingControls || showControls {
            scheduleHideControls()
        }
    }

    func skipBackward(_ seconds: Double = 10, revealingControls: Bool = true) {
        guard !isBackgroundSuspended else { return }
        guard !hasReachedEndOfFile else { return }
        Self.logger.info(
            "[CMP-SEEK] skip backward requested seconds=\(seconds, privacy: .public) current=\(self.currentTime, privacy: .public) preview=\(self.scrubPreviewTime, privacy: .public) isScrubbing=\(self.isScrubbing, privacy: .public)"
        )
        queueSkipDebounce(delta: -seconds)
        if revealingControls || showControls {
            scheduleHideControls()
        }
    }

    func skipIntro() {
        guard let introRange else { return }
        if let key = currentIntroSkipKey(for: introRange) {
            autoSkippedIntroKey = key
        }
        cancelPendingIntroAutoSkip()
        seekTo(seconds: introRange.end)
    }

    func cancelIntroAutoSkip() {
        if let introRange,
           let key = currentIntroSkipKey(for: introRange) {
            autoSkipIntroCancelledKey = key
            Self.logger.info("[CMP-MARKERS] cancelled auto-skip intro key=\(key, privacy: .public)")
        }
        cancelPendingIntroAutoSkip()
    }

    /// Enter continuous seek mode. The rate starts at ±1× (sign from
    /// `forward`) and auto-ramps 1 → 2 → 4 → 8 over the next ~4 s unless
    /// the user manually adjusts it with Left/Right, in which case the
    /// ramp yields to manual control. The session persists after the
    /// arrow is released — exit via Select (commit) or Menu (cancel).
    ///
    /// Does *not* call `scheduleHideControls()`: the tvOS focus sink
    /// needs to stay in the focus hierarchy so subsequent D-pad / Select
    /// / Menu presses route through us rather than the scrubber or the
    /// transport buttons.
    func beginHoldSeek(forward: Bool) {
        guard !isBackgroundSuspended else { return }
        guard !hasReachedEndOfFile else { return }
        if isHoldSeeking { return } // already in a session
        Self.logger.info(
            "[CMP-SEEK] hold seek begin direction=\(forward ? "forward" : "backward", privacy: .public) current=\(self.currentTime, privacy: .public)"
        )

        // A pending tap-skip debounce would commit behind our back; kill it.
        skipDebounceTask?.cancel()
        skipDebounceTask = nil

        holdSeekRate = forward ? 1 : -1
        // Seek preview always starts from the live playhead (ignore any
        // stale `scrubPreviewTime` left by a prior tap-skip preview that
        // didn't land).
        scrubPreviewTime = currentTime
        isScrubbing = true

        holdSeekTask?.cancel()
        holdSeekTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let rate = self.holdSeekRate
                if rate == 0 { break }
                let step = Self.holdSeekBaseStep * Double(rate)
                let cap = self.duration > 0 ? self.duration : self.scrubPreviewTime + abs(step)
                self.scrubPreviewTime = max(0, min(self.scrubPreviewTime + step, cap))
                try? await Task.sleep(nanoseconds: Self.holdSeekTickNanos)
            }
        }

        startHoldSeekAutoRamp()
    }

    /// Step the seek rate along the signed ladder. Positive `delta` moves
    /// toward +8× (faster / more forward), negative toward -8×. Cancels
    /// the auto-ramp — once the user touches Left/Right they're driving.
    func adjustHoldSeekRate(delta: Int) {
        guard isHoldSeeking else { return }
        holdSeekAutoRampTask?.cancel()
        holdSeekAutoRampTask = nil
        guard let currentIdx = Self.seekRates.firstIndex(of: holdSeekRate) else { return }
        let newIdx = max(0, min(Self.seekRates.count - 1, currentIdx + delta))
        holdSeekRate = Self.seekRates[newIdx]
    }

    /// Commit the current seek preview and exit seek mode. Schedules the
    /// overlay auto-hide so the user briefly sees the landed position on
    /// the scrubber before it fades.
    func commitHoldSeek() {
        guard isHoldSeeking else { return }
        Self.logger.info(
            "[CMP-SEEK] hold seek commit target=\(self.scrubPreviewTime, privacy: .public) current=\(self.currentTime, privacy: .public)"
        )
        tearDownHoldSeek()
        commitSeek(to: scrubPreviewTime, source: "holdSeek")
        scheduleHideControls()
    }

    /// Abandon the seek session without moving the playhead. Used by
    /// Menu / Exit so a curious user can back out without committing.
    func cancelHoldSeek() {
        guard isHoldSeeking else { return }
        tearDownHoldSeek()
        cancelScrub()
    }

    /// Run a short auto-ramp that steps the rate magnitude 1 → 2 → 4 → 8
    /// in ~1.2 s increments. Only runs during the initial phase of a
    /// session; cancelled the instant the user manually steers.
    private func startHoldSeekAutoRamp() {
        holdSeekAutoRampTask?.cancel()
        holdSeekAutoRampTask = Task { @MainActor [weak self] in
            let magnitudes: [Int] = [2, 4, 8]
            for magnitude in magnitudes {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled, let self else { return }
                let current = self.holdSeekRate
                guard current != 0 else { return }
                let sign = current > 0 ? 1 : -1
                self.holdSeekRate = magnitude * sign
            }
        }
    }

    private func tearDownHoldSeek() {
        holdSeekTask?.cancel()
        holdSeekTask = nil
        holdSeekAutoRampTask?.cancel()
        holdSeekAutoRampTask = nil
        holdSeekRate = 0
    }

    /// Accumulate a skip delta into `scrubPreviewTime` and schedule a
    /// trailing-edge commit. Each call cancels the prior pending commit and
    /// starts a fresh window, so rapid bursts coalesce into a single seek
    /// fired after the user stops pressing.
    private func queueSkipDebounce(delta: Double) {
        let base = isScrubbing ? scrubPreviewTime : currentTime
        let cap = duration > 0 ? duration : base + abs(delta)
        let target = max(0, min(base + delta, cap))

        isScrubbing = true
        scrubPreviewTime = target
        Self.logger.info(
            "[CMP-SEEK] skip debounce queued delta=\(delta, privacy: .public) base=\(base, privacy: .public) target=\(target, privacy: .public) duration=\(self.duration, privacy: .public)"
        )

        skipDebounceTask?.cancel()
        skipDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.skipDebounceNanos ?? 200_000_000)
            guard !Task.isCancelled, let self else { return }
            Self.logger.info(
                "[CMP-SEEK] skip debounce commit target=\(self.scrubPreviewTime, privacy: .public) current=\(self.currentTime, privacy: .public)"
            )
            self.commitSeek(to: self.scrubPreviewTime, source: "skipDebounce")
            self.skipDebounceTask = nil
        }
    }

    /// Commit a seek target. Optimistically moves `currentTime` to the
    /// target and arms the origin↔target filter so stale `onTimeChange`
    /// frames from the pipeline can't overwrite it. Without this, the
    /// scrubber visibly jumps back to the pre-seek position between the
    /// `seek` call and the first post-seek report.
    ///
    /// Back-to-back seeks are safe because we capture `seekOriginTime`
    /// from the pre-commit `currentTime` (which on a repeat commit is the
    /// prior optimistic target) — the midpoint between that and the new
    /// target still correctly rejects drainage from either the current or
    /// the prior seek.
    @discardableResult
    private func commitSeek(to target: Double, source: String = "unspecified") -> Bool {
        Self.logger.info(
            "[CMP-SEEK] commit requested source=\(source, privacy: .public) target=\(target, privacy: .public) current=\(self.currentTime, privacy: .public) preview=\(self.scrubPreviewTime, privacy: .public) isScrubbing=\(self.isScrubbing, privacy: .public) route=\(self.activeRouteKind.label, privacy: .public) offset=\(self.playbackTimelineOffset, privacy: .public)"
        )
        if reloadServerBackedHLSForSeek(to: target) {
            return true
        }

        hasReachedEndOfFile = false
        seekOriginTime = currentTime
        seekTargetTime = target
        activePlayer.seek(to: target)
        currentTime = target
        isScrubbing = false
        Self.logger.info(
            "[CMP-SEEK] commit dispatched source=\(source, privacy: .public) origin=\(self.seekOriginTime ?? -1, privacy: .public) target=\(target, privacy: .public)"
        )

        // Safety valve: if the filter doesn't release naturally (e.g. a
        // transport error means no post-seek `onTimeChange` ever arrives,
        // or an HLS transcode takes a while to deliver the first segment
        // after the new keyframe), drop it after the grace period so we
        // don't pin the scrubber to the optimistic target forever.
        seekFilterTimeoutTask?.cancel()
        seekFilterTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.seekFilterNanos)
            guard !Task.isCancelled, let self else { return }
            self.seekOriginTime = nil
            self.seekTargetTime = nil
            self.seekFilterTimeoutTask = nil
        }
        return false
    }

    private func reloadServerBackedHLSForSeek(to target: Double) -> Bool {
        if reloadLocalLoopbackForSeekBeforeAnchor(to: target) {
            return true
        }

        guard let plan = activeExecutionPlan,
              plan.engine == .avPlayerHLS,
              let lastLoadRequest else {
            return false
        }

        let clampedTarget = duration > 0 ? min(max(0, target), duration) : max(0, target)
        let origin = currentTime
        let seekDistance = abs(clampedTarget - origin)
        if plan.delivery == .transcode && seekDistance <= 30 {
            Self.logger.info(
                "[CMP-SEEK] local HLS seek allowed delivery=\(plan.delivery.name, privacy: .public) target=\(clampedTarget, privacy: .public) origin=\(origin, privacy: .public) distance=\(seekDistance, privacy: .public)"
            )
            return false
        }
        guard plan.delivery == .remux || plan.delivery == .transcode else {
            return false
        }

        if let protocolV3 = activePreparedProtocolV3,
           protocolV3.serverFeatures.contains(PlaybackProtocolV3.seekReanchorFeature) {
            hasReachedEndOfFile = false
            seekOriginTime = origin
            seekTargetTime = clampedTarget
            seekFilterTimeoutTask?.cancel()
            seekFilterTimeoutTask = nil
            currentTime = clampedTarget
            scrubPreviewTime = clampedTarget
            isScrubbing = false
            isLoading = true
            isBuffering = false
            bufferingProgress = nil
            showControls = true
            hideControlsTask?.cancel()
            attemptProtocolV3Replan(
                position: clampedTarget,
                classification: "seek_reanchor",
                message: "Reanchor the active stream at the requested source position.",
                operation: "seek_reanchor"
            )
            return true
        }

        hasReachedEndOfFile = false
        seekOriginTime = origin
        seekTargetTime = clampedTarget
        seekFilterTimeoutTask?.cancel()
        seekFilterTimeoutTask = nil
        currentTime = clampedTarget
        scrubPreviewTime = clampedTarget
        isScrubbing = false
        isLoading = true
        isBuffering = false
        bufferingProgress = nil
        showControls = true
        hideControlsTask?.cancel()
        Self.logger.info(
            "[CMP-SEEK] server-backed HLS reload seek delivery=\(plan.delivery.name, privacy: .public) target=\(clampedTarget, privacy: .public) origin=\(origin, privacy: .public) offset=\(self.playbackTimelineOffset, privacy: .public)"
        )

        if plan.delivery == .transcode,
           restartCurrentTranscodeHLSForSeek(to: clampedTarget, origin: origin) {
            return true
        }

        let seekRequest = LoadRequest(
            contentId: lastLoadRequest.contentId,
            preferredFileId: lastLoadRequest.preferredFileId,
            preferredAudioTrackIndex: lastLoadRequest.preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: lastLoadRequest.preferredSubtitleTrackIndex,
            preferredSidecarSubtitleTrackId: lastLoadRequest.preferredSidecarSubtitleTrackId,
            startFromBeginning: false
        )
        beginFreshLoad(
            request: seekRequest,
            progressPosition: origin,
            resumePositionOverride: clampedTarget,
            allowNearEndResume: true
        )
        return true
    }

    private func reloadLocalLoopbackForSeekBeforeAnchor(to target: Double) -> Bool {
        guard let plan = activeExecutionPlan,
              plan.engine == .siloPlayerLoopback,
              let loopbackSession = plan.loopbackSession else {
            return false
        }

        let clampedTarget = duration > 0 ? min(max(0, target), duration) : max(0, target)
        guard clampedTarget + 0.05 < playbackTimelineOffset else {
            return false
        }

        let origin = currentTime
        let updatedPlan = PlaybackExecutionPlan(
            delivery: plan.delivery,
            engine: plan.engine,
            startMode: .absolutePosition(clampedTarget),
            streamRequest: plan.streamRequest,
            sourceStreamRequest: plan.sourceStreamRequest,
            loopbackSession: loopbackSession.reanchored(at: clampedTarget),
            capabilities: plan.capabilities,
            routeCapabilities: plan.routeCapabilities,
            requirements: plan.requirements,
            featureFlagEnabled: plan.featureFlagEnabled,
            parityBlockers: plan.parityBlockers,
            decisionTrace: plan.decisionTrace + ["loopback_reanchor_seek"],
            degradationWarnings: plan.degradationWarnings,
            reason: plan.reason,
            playbackSessionId: plan.playbackSessionId,
            sourceMetadata: plan.sourceMetadata,
            normalizationSummary: plan.normalizationSummary,
            validationClaims: plan.validationClaims
        )

        hasReachedEndOfFile = false
        seekOriginTime = origin
        seekTargetTime = clampedTarget
        seekFilterTimeoutTask?.cancel()
        seekFilterTimeoutTask = nil
        currentTime = clampedTarget
        scrubPreviewTime = clampedTarget
        isScrubbing = false
        isLoading = true
        isBuffering = false
        bufferingProgress = nil
        showControls = true
        hideControlsTask?.cancel()
        playbackTimelineOffset = clampedTarget

        Self.logger.info(
            "[CMP-SEEK] local loopback reanchor seek target=\(clampedTarget, privacy: .public) origin=\(origin, privacy: .public) previousOffset=\(plan.loopbackSession?.sourceStartTimeSeconds ?? -1, privacy: .public)"
        )
        Task { @MainActor [weak self] in
            await self?.loadStream(plan: updatedPlan)
        }
        return true
    }

    private func restartCurrentTranscodeHLSForSeek(to target: Double, origin: Double) -> Bool {
        return restartCurrentTranscodeHLS(
            to: target,
            origin: origin,
            qualityId: activeQualityId,
            source: "seek"
        )
    }

    private func restartCurrentTranscodeHLS(
        to target: Double,
        origin: Double,
        qualityId: String,
        source: String
    ) -> Bool {
        guard let currentWatchDetail,
              let selectedVersion = currentSelectedVersion else {
            Self.logger.warning("[CMP-SEEK] in-place transcode restart skipped: missing current item snapshot")
            if source == "quality" {
                isQualitySwitching = false
                qualitySwitchError = "Quality unavailable for this item."
            }
            return false
        }

        let externalSubtitleSnapshot = knownExternalSubtitles
        let selectedSubtitleSnapshot = selectedSubtitleId
        let selectedSecondarySubtitleSnapshot = selectedSecondarySubtitleId
        // An embedded selection can't be re-established by trackId across
        // the backend rebuild (ids aren't stable), and after a switch to
        // transcode the same stream may resurface as a sidecar instead.
        // Snapshot its attributes for fuzzy re-selection — the same
        // mechanism interruption recovery and route fallback use.
        let embeddedSubtitleSelectionSnapshot = selectedSubtitleId
            .flatMap { selectedId in subtitleTracks.first(where: { $0.trackId == selectedId }) }
            .flatMap { track in
                SubtitleTrackIdSpace.isSyntheticNonEmbedded(track.trackId) ? nil : TrackSelectionSnapshot(track: track)
            }
        let previousQualityId = activeQualityId
        if source == "quality" {
            activeQualityId = qualityId
        }

        freshLoadTask?.cancel()
        freshLoadGeneration &+= 1
        let currentFreshLoadGeneration = freshLoadGeneration
        freshLoadTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            defer {
                if source == "quality" {
                    self.isQualitySwitching = false
                }
                if self.freshLoadGeneration == currentFreshLoadGeneration {
                    self.freshLoadTask = nil
                }
            }

            if origin.isFinite, origin >= 0 {
                await self.sessionBridge.reportProgress(position: origin, isPaused: true)
            }
            guard !Task.isCancelled, !self.isDisposed else { return }

            if source != "quality" {
                self.activePlayer.dispose()
            }

            do {
                let session = try await self.sessionBridge.restartCurrentTranscode(
                    selectedVersion: selectedVersion,
                    seekSeconds: target,
                    qualityId: qualityId
                )
                guard !Task.isCancelled, !self.isDisposed else { return }
                self.activePlaybackSessionId = session.sessionId
                self.autoSkippedIntroKey = nil
                self.autoSkipIntroCancelledKey = nil
                self.cancelPendingIntroAutoSkip()
                self.staleSessionRecoverySessionId = nil
                if source == "quality" {
                    self.isLoading = true
                    self.isBuffering = false
                    self.bufferingProgress = nil
                    self.activePlayer.dispose()
                }

                let prepared = PreparedPlayback(
                    watchDetail: currentWatchDetail,
                    selectedVersion: selectedVersion,
                    session: session,
                    activeQualityId: ApplePlaybackQuality.activeQualityId(
                        requestedQualityId: qualityId,
                        selectedVersion: selectedVersion,
                        delivery: PlaybackDeliveryStrategy(playMethod: session.playMethod)
                    )
                )
                self.pendingExternalSubtitles = session.subtitleUrls ?? externalSubtitleSnapshot
                self.knownExternalSubtitles = self.pendingExternalSubtitles
                // Re-establish the subtitle selection across the backend
                // rebuild. Sidecar ids are stable (urlIndex-derived) and
                // restore by id; an embedded selection restores by fuzzy
                // attribute match — against embedded tracks if the new
                // route enumerates them, or against the sidecar rows the
                // server extracts them into (see `appendSidecarTracks`).
                // An AI-live selection is intentionally dropped here (not
                // restored as sidecar and not as embedded): its cues can't
                // be replayed, so live re-selection is M4's responsibility
                // via the live coordinator.
                if let selectedSubtitleSnapshot,
                   SubtitleTrackIdSpace.isSidecar(selectedSubtitleSnapshot) {
                    self.pendingSidecarSubtitleTrackId = selectedSubtitleSnapshot
                }
                self.pendingRecoveredSubtitleSelection = embeddedSubtitleSelectionSnapshot
                if embeddedSubtitleSelectionSnapshot != nil {
                    self.hasExplicitSubtitleChoice = true
                }
                self.pendingRecoveredSecondarySubtitleId = selectedSecondarySubtitleSnapshot
                self.duration = session.durationSeconds ?? selectedVersion.duration ?? self.duration
                self.currentTime = self.movieTime(for: session)
                self.qualityOptions = ApplePlaybackQuality.playbackOptions(for: selectedVersion)
                self.activeQualityId = prepared.activeQualityId
                self.qualitySwitchError = nil

                guard let streamRequest = await self.makeStreamRequest(session: session) else {
                    self.finalizeTerminalPlaybackError("Invalid stream URL")
                    return
                }
                self.resolvedServerUrl = streamRequest.serverUrl

                let restartedPlan = try self.makeExecutionPlan(
                    prepared: prepared,
                    streamRequest: streamRequest
                )
                self.currentDeliveryStrategy = restartedPlan.delivery
                self.playbackTimelineOffset = self.timelineOffset(
                    for: restartedPlan,
                    session: session,
                    requestedStart: target
                )
                self.logExecutionPlan(restartedPlan)
                Self.logger.info(
                    "[CMP-SEEK] in-place transcode restart loaded target=\(target, privacy: .public)"
                )
                await self.loadStream(plan: restartedPlan)
            } catch {
                guard !Task.isCancelled, !self.isDisposed else { return }
                Self.logger.error("[CMP-SEEK] in-place transcode restart failed: \(String(describing: error), privacy: .public)")
                if source == "quality" {
                    self.activeQualityId = previousQualityId
                    self.qualitySwitchError = "Couldn't switch quality."
                    self.isLoading = false
                    self.isBuffering = false
                    self.bufferingProgress = nil
                } else {
                    self.finalizeTerminalPlaybackError(String(describing: error))
                }
            }
        }
        return true
    }

    func seek(to fraction: Double) {
        guard !isBackgroundSuspended else { return }
        guard !hasReachedEndOfFile else { return }
        guard duration > 0 else { return }
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        Self.logger.info(
            "[CMP-SEEK] fraction seek requested fraction=\(fraction, privacy: .public) duration=\(self.duration, privacy: .public)"
        )
        commitSeek(to: fraction * duration, source: "fraction")
        scheduleHideControls()
    }

    /// Seek to a specific timestamp. Used by the chapter sheet and the tvOS
    /// progress-bar scrubber.
    func seekTo(seconds: Double) {
        guard !isBackgroundSuspended else { return }
        guard !hasReachedEndOfFile else { return }
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        Self.logger.info(
            "[CMP-SEEK] absolute seek requested seconds=\(seconds, privacy: .public)"
        )
        commitSeek(to: max(0, seconds), source: "absolute")
        scheduleHideControls()
    }

    private func applyMarkerRanges(intro: TimeRange?, credits: TimeRange?) {
        introRange = validTimeRange(intro)
        creditsRange = validTimeRange(credits)
        if let introRange {
            Self.logger.info(
                "[CMP-MARKERS] intro range active start=\(introRange.start, privacy: .public) end=\(introRange.end, privacy: .public)"
            )
        }
        autoSkipIntroIfNeeded(at: currentTime)
    }

    private func validTimeRange(_ range: TimeRange?) -> TimeRange? {
        guard let range,
              range.start.isFinite,
              range.end.isFinite,
              range.start >= 0,
              range.end > range.start else {
            return nil
        }
        return range
    }

    private func autoSkipIntroIfNeeded(at time: Double) {
        guard settings.autoSkipIntro,
              !isLoading,
              !isBackgroundSuspended,
              !hasReachedEndOfFile,
              let introRange,
              let key = currentIntroSkipKey(for: introRange) else {
            cancelPendingIntroAutoSkip()
            return
        }

        if let pendingAutoSkipIntroKey, pendingAutoSkipIntroKey != key {
            cancelPendingIntroAutoSkip()
        }

        guard time >= introRange.start, time < introRange.end else {
            if pendingAutoSkipIntroKey == key {
                cancelPendingIntroAutoSkip()
            }
            return
        }

        guard autoSkippedIntroKey != key,
              autoSkipIntroCancelledKey != key,
              pendingAutoSkipIntroKey != key else {
            return
        }

        beginIntroAutoSkipCountdown(key: key, range: introRange)
    }

    private func beginIntroAutoSkipCountdown(key: String, range: TimeRange) {
        pendingAutoSkipIntroKey = key
        autoSkipIntroCountdownTask?.cancel()
        introAutoSkipCountdownSeconds = Self.introAutoSkipCountdownDefaultSeconds
        Self.logger.info(
            "[CMP-MARKERS] auto-skip intro countdown started target=\(range.end, privacy: .public)"
        )

        autoSkipIntroCountdownTask = Task { @MainActor [weak self] in
            var remaining = Self.introAutoSkipCountdownDefaultSeconds
            while remaining > 0 {
                guard let self,
                      !Task.isCancelled,
                      self.pendingAutoSkipIntroKey == key else {
                    return
                }
                self.introAutoSkipCountdownSeconds = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                remaining -= 1
            }

            guard let self,
                  !Task.isCancelled,
                  self.settings.autoSkipIntro,
                  !self.isLoading,
                  !self.isBackgroundSuspended,
                  !self.hasReachedEndOfFile,
                  self.pendingAutoSkipIntroKey == key,
                  self.autoSkipIntroCancelledKey != key,
                  self.autoSkippedIntroKey != key,
                  self.currentTime >= range.start,
                  self.currentTime < range.end else {
                self?.cancelPendingIntroAutoSkip()
                return
            }

            self.autoSkippedIntroKey = key
            self.pendingAutoSkipIntroKey = nil
            self.autoSkipIntroCountdownTask = nil
            self.introAutoSkipCountdownSeconds = nil
            Self.logger.info(
                "[CMP-MARKERS] auto-skip intro target=\(range.end, privacy: .public) current=\(self.currentTime, privacy: .public)"
            )
            self.seekTo(seconds: range.end)
        }
    }

    private func cancelPendingIntroAutoSkip() {
        autoSkipIntroCountdownTask?.cancel()
        autoSkipIntroCountdownTask = nil
        pendingAutoSkipIntroKey = nil
        introAutoSkipCountdownSeconds = nil
    }

    private func currentIntroSkipKey(for range: TimeRange) -> String? {
        guard let sessionId = activePlaybackSessionId,
              let fileId = currentSelectedVersion?.fileId else {
            return nil
        }
        return "\(sessionId):\(fileId):\(range.start):\(range.end)"
    }

    func beginScrub(fraction: Double) {
        guard !isBackgroundSuspended else { return }
        guard !hasReachedEndOfFile else { return }
        guard duration > 0 else { return }
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        isScrubbing = true
        scrubPreviewTime = max(0, min(fraction, 1)) * duration
        hideControlsTask?.cancel()
    }

    func updateScrub(fraction: Double) {
        guard !isBackgroundSuspended else { return }
        guard !hasReachedEndOfFile else { return }
        guard duration > 0 else { return }
        scrubPreviewTime = max(0, min(fraction, 1)) * duration
    }

    func endScrub(resumePlayback: Bool = false, shouldSeek: Bool = true) {
        guard !isBackgroundSuspended else { return }
        guard !hasReachedEndOfFile else { return }
        guard isScrubbing else { return }
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        let reloadsPlaybackPipeline: Bool
        if shouldSeek {
            Self.logger.info(
                "[CMP-SEEK] scrub ended target=\(self.scrubPreviewTime, privacy: .public) current=\(self.currentTime, privacy: .public)"
            )
            reloadsPlaybackPipeline = commitSeek(to: scrubPreviewTime, source: "scrub")
        } else {
            // Select entered and exited timeline mode without moving the
            // playhead. Keep the backend parked at its exact paused position
            // instead of issuing a redundant seek that can snap to a nearby
            // keyframe and briefly rebuffer.
            isScrubbing = false
            scrubPreviewTime = currentTime
            reloadsPlaybackPipeline = false
            Self.logger.info(
                "[CMP-SEEK] scrub ended without movement; resuming without seek at current=\(self.currentTime, privacy: .public)"
            )
        }
        if resumePlayback, !reloadsPlaybackPipeline {
            activePlayer.play()
        }
        scheduleHideControls()
    }

    /// Abandon an in-progress scrub without seeking. Used when the user
    /// transitions focus away from the scrubber for a reason that's not a
    /// commit — most commonly, opening a sheet — so the scrub preview
    /// doesn't become an accidental seek.
    func cancelScrub() {
        guard isScrubbing else { return }
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        isScrubbing = false
        scrubPreviewTime = currentTime
    }

    // MARK: - Track selection
    //
    // Primary audio/subtitle selection is shared across both backends. The
    // CoreMedia path switches tracks in-place via PlayerCore; the AVPlayer
    // path routes through AVFoundation media selection groups. Secondary
    // subtitles remain PlayerCore-only.

    func selectAudio(_ track: PlayerTrack) {
        guard !isBackgroundSuspended else { return }
        pendingAudioFfIndex = nil
        selectedAudioId = track.trackId
        persistAudioSelection(track)
        if activePreparedProtocolV3 != nil {
            attemptProtocolV3Replan(
                position: currentTime,
                classification: "audio_track_changed",
                message: "User selected audio track \(track.title ?? String(track.trackId))."
            )
            scheduleHideControls()
            return
        }
        applyAudioTrackSelection(track.trackId)
        scheduleHideControls()
    }

    func selectSubtitle(_ track: PlayerTrack) {
        guard !isBackgroundSuspended else { return }
        pendingSubtitleFfIndex = nil
        if selectedSecondarySubtitleId == track.trackId {
            selectedSecondarySubtitleId = nil
            applySecondarySubtitleTrackSelection(nil)
        }
        selectedSubtitleId = track.trackId
        Self.logger.info(
            "[CMP-SUB] select primary trackId=\(track.trackId, privacy: .public) title=\(track.title ?? "nil", privacy: .public) external=\(track.isExternal, privacy: .public) codec=\(track.codec ?? "nil", privacy: .public)"
        )
        persistSubtitleSelection(track)
        if activePreparedProtocolV3 != nil,
           !SubtitleTrackIdSpace.isAILive(track.trackId) {
            attemptProtocolV3Replan(
                position: currentTime,
                classification: "subtitle_track_changed",
                message: "User selected subtitle track \(track.title ?? String(track.trackId))."
            )
            scheduleHideControls()
            return
        }
        applySubtitleTrackSelection(track.trackId)
        scheduleHideControls()
    }

    func disableSubtitles() {
        guard !isBackgroundSuspended else { return }
        pendingSubtitleFfIndex = nil
        if selectedSecondarySubtitleId != nil {
            selectedSecondarySubtitleId = nil
            applySecondarySubtitleTrackSelection(nil)
        }
        selectedSubtitleId = nil
        Self.logger.info("[CMP-SUB] disable primary subtitles")
        persistSubtitleSelection(nil)
        if activePreparedProtocolV3 != nil {
            attemptProtocolV3Replan(
                position: currentTime,
                classification: "subtitle_track_changed",
                message: "User disabled subtitles."
            )
            scheduleHideControls()
            return
        }
        applySubtitleTrackSelection(nil)
        scheduleHideControls()
    }

    /// Server pref key for remembering explicit track picks: series id
    /// for episodes (one choice covers the series), the item's own
    /// content id for movies. Nil during offline playback — there is no
    /// server to remember anything for.
    private var trackPrefPersistKey: String? {
        guard offlinePlaybackContext == nil, let detail = currentWatchDetail else { return nil }
        return TrackSelectionPersistence.prefKey(
            seriesId: detail.seriesId,
            contentId: detail.contentId
        )
    }

    /// Best-effort write of an explicit audio pick so it sticks across
    /// player exits (web-app parity; the server only auto-persists
    /// audio on its own change endpoint, which Apple's engine-local
    /// switching never calls). Prefers the server's probed metadata for
    /// the signature so re-resolution gets an exact match.
    private func persistAudioSelection(_ track: PlayerTrack) {
        guard let key = trackPrefPersistKey else { return }
        let ordinal = audioSelectionIndex(for: track)
        let request: AudioPrefRequest
        if let ordinal,
           let version = currentSelectedVersion,
           let fromDetail = TrackSelectionPersistence.audioRequest(version: version, ordinal: ordinal) {
            request = fromDetail
        } else {
            request = TrackSelectionPersistence.audioRequest(track: track, ordinal: ordinal)
        }
        TrackSelectionPersistence.saveAudio(prefKey: key, request: request)
    }

    /// Best-effort write of an explicit subtitle pick (or explicit
    /// "Off" when `track` is nil). Live AI translation tracks are
    /// session-scoped and never persisted.
    private func persistSubtitleSelection(_ track: PlayerTrack?) {
        guard let key = trackPrefPersistKey else { return }
        if let track, SubtitleTrackIdSpace.isAILive(track.trackId) { return }
        let showForced = currentWatchDetail?.effectiveShowForcedSubtitles
        let request: SubtitlePrefRequest
        if let track {
            if !track.isExternal,
               let ffIndex = track.ffIndex,
               let version = currentSelectedVersion,
               let fromDetail = TrackSelectionPersistence.subtitleRequest(
                   version: version,
                   ffIndex: ffIndex,
                   showForced: showForced
               ) {
                request = fromDetail
            } else {
                request = TrackSelectionPersistence.subtitleRequest(track: track, showForced: showForced)
            }
        } else {
            request = TrackSelectionPersistence.subtitleOffRequest(showForced: showForced)
        }
        TrackSelectionPersistence.saveSubtitle(prefKey: key, request: request)
    }

    func selectSecondarySubtitle(_ track: PlayerTrack) {
        guard !isBackgroundSuspended else { return }
        guard backendCapabilities.supportsSecondarySubtitles else { return }
        // Secondary sub cannot equal the primary sid; guard at the UI layer
        // so the user gets an immediate no-op rather than seeing stale state.
        guard track.trackId != selectedSubtitleId else { return }
        selectedSecondarySubtitleId = track.trackId
        applySecondarySubtitleTrackSelection(track.trackId)
        scheduleHideControls()
    }

    func disableSecondarySubtitles() {
        guard !isBackgroundSuspended else { return }
        guard backendCapabilities.supportsSecondarySubtitles else { return }
        selectedSecondarySubtitleId = nil
        applySecondarySubtitleTrackSelection(nil)
        scheduleHideControls()
    }

    // MARK: - AI subtitles (translate / transcribe over polling)

    /// Start an AI translation of an existing text subtitle track into
    /// `targetLanguage`. Forwarded to ``SubtitleAIController`` which POSTs the
    /// job and polls it to completion, then hands the result back through
    /// `registerCompletedAISubtitle`.
    @MainActor
    func startSubtitleTranslation(track: PlayerTrack, to targetLanguage: String) {
        subtitleAI.translateExisting(track: track, to: targetLanguage)
    }

    /// Start an AI transcription of an audio track (`audioIndex`, `-1` =
    /// server default), optionally translating the transcript into
    /// `translateTo`.
    @MainActor
    func startSubtitleTranscription(audioIndex: Int, translateTo: String?) {
        subtitleAI.transcribe(audioIndex: audioIndex, translateTo: translateTo)
    }

    // MARK: - Subtitle provider search (synchronous, no job machinery)

    /// Whether in-player subtitle search is available: an active playback
    /// session (the synthesized stream URL is session-scoped), a known media
    /// file, and a backend that can host downloaded sidecars. False for
    /// offline/local playback. Gates the "Search Subtitles…" entry row.
    @MainActor
    var subtitleSearchAvailable: Bool {
        activePlaybackSessionId != nil
            && currentSelectedVersion?.fileId != nil
            && backendCapabilities.supportsExternalPrimarySubtitles
    }

    /// Run a provider search for the current media file. Synchronous on the
    /// server (fan-out with 20–30s per-provider timeouts) — the caller shows
    /// a long-running spinner. Throws `HTTPError` verbatim for the UI.
    @MainActor
    func searchSubtitles(languages: [String]) async throws -> SubtitleSearchResponse {
        guard let fileId = currentSelectedVersion?.fileId else {
            throw HTTPError.invalidURL("subtitle search requires an active media file")
        }
        return try await ContinuumAI.shared.searchSubtitles(
            SubtitleSearchBody(mediaFileId: fileId, languages: languages)
        )
    }

    /// Download a chosen search result and hand it to the picker (register +
    /// auto-select) with **no session restart** — the same sidecar path the AI
    /// completion uses. Returns `true` on success.
    ///
    /// Mirrors `SubtitleAIController.completePersistedHandoff` minus the
    /// job/latch/websocket machinery: the download response carries the DB
    /// `id` but no combined index or stream URL, so we re-list to find the
    /// track's *position* and synthesize both (see ``DownloadedSubtitle``).
    ///
    /// Idempotency vs the server's `subtitle_ready` broadcast that follows any
    /// download: that path is register-only (never steals selection) and
    /// `registerCompletedAISubtitle` de-dupes on combined index, so the echo
    /// is a harmless no-op — no ownership latch is needed here.
    @MainActor
    func downloadSearchedSubtitle(_ result: SubtitleSearchResult) async -> Bool {
        guard let fileId = currentSelectedVersion?.fileId else { return false }
        do {
            let subtitle = try await ContinuumAI.shared.downloadSubtitle(
                SubtitleDownloadBody(from: result, mediaFileId: fileId)
            )
            let downloaded = try await ContinuumAI.shared.downloadedSubtitles(mediaFileId: fileId)
            // Revalidate after the awaits: if playback moved to a different
            // file while the download was in flight, `makeSubtitleHandoffContext`
            // would now describe the NEW session, and registering the OLD
            // file's listing position against it would select a wrong or
            // invalid track. The download itself is persisted server-side
            // either way; the next session of that file picks it up.
            guard currentSelectedVersion?.fileId == fileId else {
                Self.logger.info(
                    "[SUB-SEARCH] media file changed during download of subtitle id=\(subtitle.id, privacy: .public); skipping live handoff"
                )
                return false
            }
            guard let position = downloaded.firstIndex(where: { $0.id == subtitle.id }) else {
                Self.logger.warning(
                    "[SUB-SEARCH] downloaded subtitle id=\(subtitle.id, privacy: .public) not in listing of \(downloaded.count, privacy: .public)"
                )
                return false
            }
            guard let context = makeSubtitleHandoffContext(),
                  let descriptor = downloaded[position].synthesizedDescriptor(
                      sessionId: context.sessionId,
                      baseTrackCount: context.baseTrackCount,
                      position: position,
                      resolveURL: context.resolveURL
                  )
            else {
                Self.logger.warning(
                    "[SUB-SEARCH] no handoff context / unresolvable URL for subtitle id=\(subtitle.id, privacy: .public)"
                )
                return false
            }
            registerCompletedAISubtitle(descriptor, autoSelect: true)
            return true
        } catch {
            Self.logger.warning(
                "[SUB-SEARCH] download failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Build the context ``SubtitleAIController`` needs to synthesize a
    /// completed subtitle's player descriptor. Returns `nil` when no active
    /// session exists or the current backend can't host downloaded sidecars —
    /// the controller treats `nil` as a soft failure so the user isn't left on
    /// a dismissed menu with no track.
    ///
    /// `baseTrackCount` mirrors Android's `SubtitleTrackMerge` `baseIndex`:
    /// `(max combined index over the session's non-downloaded subtitle_urls) + 1`
    /// — computed `+1` over the max, not the count, so server-side burn-in
    /// skipping (which can leave index gaps) is honored and the synthesized
    /// stream URL still resolves on the combined-index stream mount.
    @MainActor
    private func makeSubtitleHandoffContext() -> SubtitleAIController.HandoffContext? {
        guard backendCapabilities.supportsExternalPrimarySubtitles else {
            Self.logger.info(
                "[AI-SUB] backend \(self.activeRouteKind.label, privacy: .public) can't host downloaded subtitles; handoff unavailable"
            )
            return nil
        }
        guard let sessionId = activePlaybackSessionId, !sessionId.isEmpty else {
            Self.logger.warning("[AI-SUB] no active session id for subtitle handoff")
            return nil
        }
        let serverUrl = resolvedServerUrl
        // KNOWN LIMITATION (intentionally inherited from Android's
        // `SubtitleTrackMerge`; do NOT "fix" Apple-side — no purely-client fix is
        // correct). The server's `buildSubtitleURLs` (`playback.go:1503`) OMITS
        // non-PGS burn-in subtitle tracks from `subtitle_urls`, yet still counts
        // them in the downloaded combined-index offset (`downloadedOffset` at
        // `playback.go:1520`, served by the combined-index stream mount in
        // `stream.go:244`). So `max(visible index) + 1` here UNDERCOUNTS whenever
        // the LAST embedded track is a non-PGS bitmap sub: the synthesized stream
        // URL then targets the wrong combined index and the live→persisted handoff
        // SOFT-FAILS. This is graceful — the job already completed server-side, and
        // a fresh playback session re-indexes the persisted track correctly. The
        // robust fix is cross-repo: have the server carry the combined index (or a
        // ready-to-use stream URL) in `subtitle_translation_completed` /
        // `subtitle_ready` so the client never has to reconstruct it.
        let baseTrackCount = (
            knownExternalSubtitles
                .filter { ($0.source ?? "").caseInsensitiveCompare("downloaded") != .orderedSame }
                .map(\.index)
                .max() ?? -1
        ) + 1
        return SubtitleAIController.HandoffContext(
            sessionId: sessionId,
            baseTrackCount: baseTrackCount,
            resolveURL: { [weak self] path in self?.resolveServerUrl(path, serverUrl: serverUrl) }
        )
    }

    /// Completion handoff for a finished AI subtitle job: register the
    /// controller-synthesized descriptor through the **same** sidecar path the
    /// playback session uses, then auto-select it.
    ///
    /// The controller has already synthesized the combined index + stream URL
    /// (the server's downloaded-subtitle listing carries neither) the way
    /// Android's `SubtitleTrackMerge` does. Here we (1) record it in
    /// `knownExternalSubtitles` as a `SubtitleUrl` so a later route/quality
    /// switch re-registers it like any other sidecar (de-dupes on index),
    /// (2) seed `pendingSidecarSubtitleTrackId` so `appendSidecarTracks`
    /// auto-selects it once registered, and (3) call the active backend's
    /// `registerSidecarSubtitles`, which fires `onSidecarTracksRegistered` →
    /// `appendSidecarTracks`. No new selection plumbing.
    private func registerCompletedAISubtitle(
        _ descriptor: SidecarSubtitleDescriptor,
        autoSelect: Bool = true
    ) {
        guard backendCapabilities.supportsExternalPrimarySubtitles else {
            Self.logger.info(
                "[AI-SUB] backend \(self.activeRouteKind.label, privacy: .public) can't host downloaded subtitles; skipping handoff"
            )
            return
        }

        // Remember it (as a `SubtitleUrl`, the cache's shape) so a later
        // route/quality switch re-registers it. De-dupe on combined index.
        if !knownExternalSubtitles.contains(where: { $0.index == descriptor.index }) {
            knownExternalSubtitles.append(SubtitleUrl(
                index: descriptor.index,
                language: descriptor.language,
                codec: descriptor.codec,
                label: descriptor.label,
                source: descriptor.source,
                forced: descriptor.forced,
                url: descriptor.url.absoluteString
            ))
        }

        // Seed the pending selection so the append path selects it for us —
        // unless this is a `subtitle_ready` broadcast (M5), which registers the
        // track as selectable WITHOUT hijacking the viewer's current choice.
        let trackId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: descriptor.index)
        if autoSelect {
            pendingSidecarSubtitleTrackId = trackId
        }

        Self.logger.info(
            "[AI-SUB] registering completed subtitle index=\(descriptor.index, privacy: .public) lang=\(descriptor.language ?? "nil", privacy: .public) trackId=\(trackId, privacy: .public) autoSelect=\(autoSelect, privacy: .public)"
        )
        switch activePlayer {
        case .none:
            // No backend yet — it will be picked up on the next file load via
            // `loadPendingExternalSubtitles`/`knownExternalSubtitles`.
            break
        case .coreMedia(let core):
            core.registerSidecarSubtitles([descriptor])
        case .avPlayer(let backend):
            backend.registerSidecarSubtitles([descriptor])
        }
    }

    // MARK: - Live AI subtitle bridge (M4)
    //
    // Thin internal accessors the `LiveSubtitleCoordinator` adapters call.
    // They exist because the adapters are distinct fileprivate types and so
    // can't reach the VM's `private` playback/notice state directly. Each is a
    // one-liner over an existing primitive; the interesting logic (offset-aware
    // cue conversion, dedupe) lives in the sink adapter.

    /// The amount (seconds) to subtract from a live cue's **absolute media-time**
    /// timestamp to land it on the ACTIVE backend's libass tick clock.
    ///
    /// A streamed cue carries absolute media time, but the two backends tick the
    /// libass renderer on different clocks:
    ///   - CoreMedia (`PlayerCore`) ticks at `currentPlaybackTimeSeconds()` =
    ///     **offset-relative movie time** (`media − playbackTimelineOffset`), so
    ///     a media-time cue must be shifted by `playbackTimelineOffset`.
    ///   - `AVPlayerBackend` ticks at `mediaTime(for: playerTime)` =
    ///     `playerTime + mediaTimelineOffsetSeconds` = **absolute media time**,
    ///     so a media-time cue is fed as-is (offset 0). Subtracting
    ///     `playbackTimelineOffset` here would render cues `offset` seconds early
    ///     on an AVPlayer transcode.
    /// Routing the conversion through this single backend-aware accessor keeps
    /// live cues aligned on whichever backend is active.
    var liveSubtitleCueMediaTimeShift: Double {
        switch activePlayer {
        case .coreMedia:
            return playbackTimelineOffset
        case .avPlayer, .none:
            // AVPlayer renderer ticks in absolute media time → no shift.
            return 0
        }
    }

    /// Open the synthetic live track on the active backend and add its picker
    /// row. Returns the live track id.
    @discardableResult
    func installLiveSubtitleTrackRow(ordinal: Int, label: String?, language: String?) -> Int64 {
        openLiveSubtitleTrack(slot: .primary, label: label, language: language)
        return appendLiveSubtitleTrack(ordinal: ordinal, label: label, language: language)
    }

    /// Select the live track (no-op selection of an already-installed track is
    /// handled in the backends).
    func selectLiveSubtitleTrack(trackId: Int64) {
        if let track = subtitleTracks.first(where: { $0.trackId == trackId }) {
            selectSubtitle(track)
        }
    }

    /// Close the live track and remove its picker row. If it was selected,
    /// `restoreLiveSubtitleSelection` is expected to follow (the coordinator
    /// drives that separately).
    func closeLiveSubtitleTrackRow(trackId: Int64) {
        removeLiveSubtitleTrackRow(trackId: trackId)
        closeLiveSubtitleTrack(slot: .primary)
    }

    /// Remove only the picker row for a stale synthetic live track. Used when a
    /// newer live renderer already owns the single primary libass slot.
    func removeLiveSubtitleTrackRow(trackId: Int64) {
        subtitleTracks.removeAll { $0.trackId == trackId }
    }

    /// M5 seamless swap: arm the live track `trackId` to be closed AFTER the
    /// handed-off persisted track is selected (in `appendSidecarTracks`), rather
    /// than synchronously. A bounded fallback timer guarantees the row is never
    /// stranded if the persisted selection never lands (e.g. the handoff listing
    /// fetch failed after the server reported completion): the live track is
    /// closed anyway once the window elapses.
    func armDeferredLiveSubtitleClose(trackId: Int64) {
        // Single-slot pending id: if a DIFFERENT live track is still awaiting its
        // deferred close when a second job completes back-to-back, overwriting the
        // pending id here (and cancelling its fallback timer below) would orphan
        // the previous synthetic row forever. Close it now before re-arming so the
        // earlier track is never stranded. (Common case: nothing pending, or the
        // same id re-armed — both no-op this guard.)
        if let previousId = pendingLiveSubtitleCloseTrackId, previousId != trackId {
            removeLiveSubtitleTrackRow(trackId: previousId)
        }
        pendingLiveSubtitleCloseTrackId = trackId
        deferredLiveSubtitleCloseTask?.cancel()
        deferredLiveSubtitleCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            // Selection never landed — close the orphaned live row as a fallback
            // and clear any lingering live selection.
            guard self.pendingLiveSubtitleCloseTrackId == trackId else { return }
            self.pendingLiveSubtitleCloseTrackId = nil
            self.closeLiveSubtitleTrackRow(trackId: trackId)
            if self.selectedSubtitleId.map(SubtitleTrackIdSpace.isAILive) == true {
                self.disableSubtitles()
            }
            Self.logger.warning("[AI-SUB] deferred live-track close fired on fallback timeout (persisted selection never landed)")
        }
    }

    /// Perform the deferred live-track close, if armed. Called from
    /// `appendSidecarTracks` once the persisted AI track is selected, so the
    /// swap is seamless (selection has already moved off the live row).
    private func performDeferredLiveSubtitleCloseIfNeeded() {
        guard let trackId = pendingLiveSubtitleCloseTrackId else { return }
        pendingLiveSubtitleCloseTrackId = nil
        deferredLiveSubtitleCloseTask?.cancel()
        deferredLiveSubtitleCloseTask = nil
        closeLiveSubtitleTrackRow(trackId: trackId)
    }

    /// Restore a prior subtitle selection (or disable if there was none).
    /// Selecting an AI-live id is refused — that track is being torn down.
    func restoreLiveSubtitleSelection(_ trackId: Int64?) {
        guard let trackId,
              !SubtitleTrackIdSpace.isAILive(trackId),
              let track = subtitleTracks.first(where: { $0.trackId == trackId }) else {
            // Only actively disable if a live track is still the selection; a
            // restore to "none" shouldn't clobber a selection the user changed.
            if selectedSubtitleId.map(SubtitleTrackIdSpace.isAILive) == true {
                disableSubtitles()
            }
            return
        }
        selectSubtitle(track)
    }

    /// The "Preparing subtitles" notice shown while the first live cues land.
    /// Kind-agnostic copy (this live path serves translate, transcribe, and
    /// transcribe+translate jobs alike), so it avoids "Translating…" wording.
    @MainActor
    func showLiveSubtitlePreparingNotice() {
        showNotice(
            title: "Preparing subtitles",
            message: "Generating subtitles for the current scene — playback resumes in a moment.",
            tone: .info,
            duration: 30
        )
        // Remember which notice is the preparing one so we can retract it the
        // instant playback resumes — otherwise the 30s safety duration leaves
        // "playback resumes in a moment" on screen long after it already has,
        // which reads as a stuck/broken pause.
        liveSubtitlePreparingNoticeId = activeNotice?.id
    }

    /// Clear the live-subtitle "Preparing subtitles" notice once playback has
    /// resumed (first cues) or the job finished. No-ops if it has already been
    /// replaced by a newer notice, so an unrelated message is never clobbered.
    @MainActor
    func dismissLiveSubtitlePreparingNotice() {
        guard let id = liveSubtitlePreparingNoticeId else { return }
        liveSubtitlePreparingNoticeId = nil
        guard activeNotice?.id == id else { return }
        noticeDismissTask?.cancel()
        noticeDismissTask = nil
        activeNotice = nil
    }

    /// Soft failure notice for the live subtitle path.
    @MainActor
    func showLiveSubtitleFailureNotice(_ message: String) {
        showNotice(
            title: "Subtitles unavailable",
            message: message,
            tone: .warning,
            duration: 5
        )
    }

    func cycleAudioTrack() {
        guard !isBackgroundSuspended, !audioTracks.isEmpty else { return }
        let nextIndex: Int
        if let selectedAudioId,
           let currentIndex = audioTracks.firstIndex(where: { $0.trackId == selectedAudioId }) {
            nextIndex = audioTracks.index(after: currentIndex) % audioTracks.count
        } else {
            nextIndex = 0
        }
        selectAudio(audioTracks[nextIndex])
    }

    func cycleSubtitleTrack() {
        guard !isBackgroundSuspended, !subtitleTracks.isEmpty else { return }

        if selectedSubtitleId == nil {
            selectSubtitle(subtitleTracks[0])
            return
        }

        guard let selectedSubtitleId,
              let currentIndex = subtitleTracks.firstIndex(where: { $0.trackId == selectedSubtitleId }) else {
            disableSubtitles()
            return
        }

        let nextIndex = subtitleTracks.index(after: currentIndex)
        if nextIndex < subtitleTracks.count {
            selectSubtitle(subtitleTracks[nextIndex])
        } else {
            disableSubtitles()
        }
    }

    func toggleSubtitles() {
        guard !isBackgroundSuspended else { return }
        if selectedSubtitleId != nil {
            disableSubtitles()
        } else if let first = subtitleTracks.first {
            selectSubtitle(first)
        }
    }

    func seekToAdjacentChapter(forward: Bool) {
        guard !isBackgroundSuspended, !chapters.isEmpty else { return }
        let sorted = chapters.sorted { $0.time < $1.time }
        let target: PlayerChapterInfo?
        if forward {
            target = sorted.first { $0.time > currentTime + 1.0 }
        } else {
            target = sorted.last { $0.time < currentTime - 1.0 }
        }
        if let target {
            seekTo(seconds: target.time)
        }
    }

    func toggleControls() {
        guard !isBackgroundSuspended else {
            showControls = true
            return
        }
        showControls.toggle()
        if showControls {
            scheduleHideControls()
        }
    }

    func revealControls() {
        guard !isBackgroundSuspended else {
            showControls = true
            return
        }
        scheduleHideControls()
    }

    /// Hide the controls overlay immediately, cancelling any pending
    /// auto-hide. Wired to the Siri Remote Menu button on tvOS so the user
    /// can dismiss the overlay without waiting out the 5s timer; tapping
    /// Menu again falls through to player dismissal via `PlayerView`.
    func dismissControls() {
        guard !isBackgroundSuspended else { return }
        if isHoldSeeking {
            cancelHoldSeek()
        }
        hideControlsTask?.cancel()
        withAnimation { showControls = false }
    }

    /// Keep the controls overlay visible and cancel the pending auto-hide.
    /// Used while the HUD is presented — otherwise the auto-hide timer can
    /// tear the HUD's host out from under it.
    func pinControlsVisible() {
        hideControlsTask?.cancel()
        showControls = true
    }

    /// Resume the standard auto-hide behavior after a pin.
    func resumeAutoHide() {
        scheduleHideControls()
    }

    /// Open the tvOS options HUD. Synchronous so the shell-level Menu handler
    /// and the transport overlay see a consistent state within one run loop.
    func openHUD() {
        guard !isBackgroundSuspended else { return }
        if isHoldSeeking {
            cancelHoldSeek()
        }
        pinControlsVisible()
        isHUDPresented = true
    }

    #if os(tvOS)
    func openSettingsHUD() {
        requestedTVHUDEntryPoint = .settings
        openHUD()
    }

    func openPlaybackHUD() {
        requestedTVHUDEntryPoint = .playback
        openHUD()
    }

    func consumeTVHUDEntryRequest() {
        requestedTVHUDEntryPoint = nil
    }
    #endif

    /// Close the tvOS options HUD and resume normal auto-hide. Safe to call
    /// when the HUD is already closed.
    func closeHUD() {
        guard isHUDPresented else { return }
        isHUDPresented = false
        scheduleHideControls()
    }

    @MainActor
    func cleanup() {
        guard !isDisposed else { return }
        Self.logger.info("PlayerViewModel.cleanup()")
        isDisposed = true
        #if os(iOS)
        pictureInPictureBackgroundGraceTask?.cancel()
        pictureInPictureBackgroundGraceTask = nil
        PictureInPictureCoordinator.shared.unbindLifecycle(owner: self)
        // The PiP coordinator is a singleton and its controller strongly
        // retains the AVPlayerLayer, the AVPlayer, and everything hanging off
        // it. SwiftUI's `dismantleUIView` normally releases it, but ordering
        // there is not guaranteed relative to this teardown, so drop it here
        // too rather than risk stranding the whole playback graph.
        PictureInPictureCoordinator.shared.release()
        isSceneBackgrounded = false
        #endif
        activeExecutionPlan = nil
        hasAttemptedNativeDirectRouteRecovery = false
        hasAttemptedSiloRouteCompatibilityFallback = false
        activePlaybackSessionId = nil
        staleSessionRecoverySessionId = nil
        currentWatchDetail = nil
        currentSelectedVersion = nil
        introRange = nil
        creditsRange = nil
        cancelPendingIntroAutoSkip()
        autoSkippedIntroKey = nil
        autoSkipIntroCancelledKey = nil
        knownExternalSubtitles = []
        subtitleAI.reset()
        deferredLiveSubtitleCloseTask?.cancel()
        deferredLiveSubtitleCloseTask = nil
        pendingLiveSubtitleCloseTrackId = nil
        pendingRecoveredAudioSelection = nil
        pendingRecoveredSubtitleSelection = nil
        pendingRecoveredSecondarySubtitleId = nil
        noticeDismissTask?.cancel()
        noticeDismissTask = nil
        remoteDismissTask?.cancel()
        remoteDismissTask = nil
        activeNotice = nil
        tearDownHoldSeek()
        hideControlsTask?.cancel()
        progressTask?.cancel()
        staleSessionRecoveryTask?.cancel()
        staleSessionRecoveryTask = nil
        backgroundRenewalTask?.cancel()
        backgroundRenewalTask = nil
        backgroundRenewalSessionId = nil
        clearSourceOutageRideThroughState()
        clearServerOutageRecoveryState()
        settingsRefreshTask?.cancel()
        settingsRefreshTask = nil
        freshLoadTask?.cancel()
        protocolV3ReplanTask?.cancel()
        protocolV3ReplanTask = nil
        if let audioRouteObserverToken {
            NotificationCenter.default.removeObserver(audioRouteObserverToken)
            self.audioRouteObserverToken = nil
        }
        nextUpLookupTask?.cancel()
        nextUpOnDeckTask?.cancel()
        nextUpCountdownTask?.cancel()
        autoSkipIntroCountdownTask?.cancel()
        autoSkipIntroCountdownTask = nil
        interruptionRecoveryTask?.cancel()
        skipDebounceTask?.cancel()
        seekFilterTimeoutTask?.cancel()
        holdSeekTask?.cancel()
        holdSeekAutoRampTask?.cancel()
        sleepTimer.cancel()
        nowPlaying.detach()
        clearForegroundInterruptionState()
        clearSuspendedPlaybackState()
        #if DEBUG
        // Stop the DEBUG live-subtitle cue pump so its repeating timer can't
        // outlive the player and keep firing into a torn-down session.
        debugStopFakeLiveSubtitles()
        #endif

        // Final offline progress flush before teardown — the counterpart of
        // the online path's `stopSession` report below. Captured into locals
        // so the detached task doesn't read torn-down player state.
        // Offline playback has no server session of its own (the fresh-load
        // path finalized any prior one), so skip the server stop below —
        // it would report the offline position against a stale session.
        let stopServerSessionOnTeardown = offlinePlaybackContext == nil
        if let offline = offlinePlaybackContext {
            let finalOfflinePosition = completionProgressPositionForCurrentItem()
            let endedNaturally = PlayerNextUpCompletionPolicy.shouldFinalizeAsCompleted(
                isNextUpPresented: showNextUpScreen,
                hasReachedEndOfFile: hasReachedEndOfFile,
                currentTime: currentTime,
                duration: duration,
                promptSeconds: settings.nextUpPromptSeconds
            )
            // Strong capture on purpose: this is the last write of the
            // resume point and must not be dropped because the VM was
            // released between dismiss and the hop to the MainActor.
            Task { @MainActor in
                self.recordOfflineProgress(
                    context: offline,
                    position: finalOfflinePosition,
                    markCompleted: endedNaturally
                )
            }
        }

        let finalPosition = currentTime
        activePlayer.dispose()
        // Drop the disposed backend so any post-teardown call is an explicit
        // no-op (the `.none` case) rather than relying on each backend's
        // `isDisposed` guard. `finalPosition` is captured above, before this.
        activePlayer = .none
        discardSourceCacheHandoff()
        sourceProxy?.stop()
        sourceProxy = nil

        let connectivityToken = realtimeConnectivityObserverToken
        realtimeConnectivityObserverToken = nil
        let unavailabilityToken = realtimeUnavailabilityObserverToken
        realtimeUnavailabilityObserverToken = nil
        cleanupCompletionTask = Task {
            // Remove our availability observer before tearing down the realtime
            // client; normal fresh-load unbinds preserve this observer.
            if let connectivityToken {
                await realtimeClient.removeConnectivityObserver(connectivityToken)
            }
            if let unavailabilityToken {
                await realtimeClient.removeUnavailabilityObserver(unavailabilityToken)
            }
            await realtimeClient.unbind()
            if stopServerSessionOnTeardown {
                await sessionBridge.stopSession(position: finalPosition, isPaused: true)
            }
        }
    }

    @MainActor
    func waitForCleanupCompletion() async {
        // onDisappear calls cleanup immediately before unregistering the TV
        // receiver. Yield briefly if presentation teardown has not installed
        // the final progress task yet.
        for _ in 0..<100 where cleanupCompletionTask == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await cleanupCompletionTask?.value
    }

    /// Safety net: SwiftUI normally drives `cleanup()` from `PlayerView.onDisappear`,
    /// but if that path is missed (edge cases in sheet/NavigationStack teardown)
    /// we still need to guarantee the backend is torn down so audio can't
    /// outlive the view. `dispose()` is idempotent.
    deinit {
        print("[CMP-LIFE] deinit PlayerViewModel")
        Self.logger.info("PlayerViewModel.deinit")
        isDisposed = true
        if let systemCaptionObserverToken {
            NotificationCenter.default.removeObserver(systemCaptionObserverToken)
        }
        if let audioRouteObserverToken {
            NotificationCenter.default.removeObserver(audioRouteObserverToken)
        }
        freshLoadTask?.cancel()
        protocolV3ReplanTask?.cancel()
        staleSessionRecoveryTask?.cancel()
        serverOutageRecoveryTask?.cancel()
        interruptionRecoveryTask?.cancel()
        autoSkipIntroCountdownTask?.cancel()
        #if DEBUG
        debugLiveSubtitleTimer?.invalidate()
        debugLiveSubtitleTimer = nil
        #endif
        activePlayer.dispose()
        sourceProxy?.stop()
        let realtimeClient = self.realtimeClient
        Task {
            await realtimeClient?.unbind()
        }
    }

    @MainActor
    private func handleRealtimeEvent(_ event: PlaybackRealtimeEventEnvelope) async {
        guard event.sessionId == activePlaybackSessionId else { return }
        switch event.name {
        case .markersUpdated:
            guard let payload = PlaybackRealtimeMarkersUpdatedPayload(payload: event.payload) else {
                Self.logger.warning("[CMP-MARKERS] ignored malformed markers_updated event")
                return
            }
            if let payloadSessionId = payload.sessionId, payloadSessionId != event.sessionId {
                return
            }
            guard payload.fileId == currentSelectedVersion?.fileId else {
                return
            }
            applyMarkerRanges(
                intro: payload.introUpdate.resolving(current: introRange),
                credits: payload.creditsUpdate.resolving(current: creditsRange)
            )
        case .chapterThumbnailReady:
            break
        case .subtitleTranslationStarted,
             .subtitleTranslationCues,
             .subtitleTranslationCompleted,
             .subtitleTranslationFailed,
             .subtitleReady:
            // AI subtitle live-streaming events (M4). Decode the typed payload
            // and hand it to the controller, which scopes it to the active job
            // and drives the live coordinator.
            guard let subtitleEvent = PlaybackRealtimeSubtitleEvent(
                name: event.name,
                payload: event.payload
            ) else {
                Self.logger.warning("[AI-LIVE] ignored malformed \(event.name.rawValue, privacy: .public) event")
                return
            }
            subtitleAI.handle(subtitleEvent)
        case .unknown(let raw):
            Self.logger.debug("[CMP-RT] ignoring unknown realtime event \(raw, privacy: .public)")
        }
    }

    @MainActor
    private func handleRealtimeCommand(_ command: PlaybackRealtimeCommandEnvelope) async throws {
        switch command.name {
        case .pause:
            activePlayer.pause()
            if isAdminIssued(command) {
                showNotice(
                    title: "Playback paused by admin",
                    message: "An administrator paused this session.",
                    tone: .warning,
                    duration: 6
                )
            }
        case .unpause:
            activePlayer.play()
            if isAdminIssued(command) {
                showNotice(
                    title: "Playback resumed by admin",
                    message: "An administrator resumed this session.",
                    tone: .info,
                    duration: 6
                )
            }
        case .playPause:
            let wasPaused = activePlayer.isPaused()
            if wasPaused {
                activePlayer.play()
            } else {
                activePlayer.pause()
            }
            if isAdminIssued(command) {
                showNotice(
                    title: wasPaused ? "Playback resumed by admin" : "Playback paused by admin",
                    message: wasPaused
                        ? "An administrator resumed this session."
                        : "An administrator paused this session.",
                    tone: wasPaused ? .info : .warning,
                    duration: 6
                )
            }
        case .seek:
            guard !isLoading else {
                throw PlaybackRealtimeCommandExecutionError.playerNotReady
            }
            guard let position = command.payload.number(
                forKeys: "position",
                "position_seconds",
                "seconds"
            ) else {
                throw PlaybackRealtimeCommandExecutionError.missingSeekPosition
            }
            applyRemoteSeek(to: position)
            if isAdminIssued(command) {
                showNotice(
                    title: "Playback changed by admin",
                    message: "An administrator changed the playback position.",
                    tone: .warning,
                    duration: 5
                )
            }
        case .displayMessage:
            showNotice(
                title: command.payload.string(forKeys: "title")
                    ?? (isAdminIssued(command) ? "Message from admin" : "Playback notice"),
                message: command.payload.string(forKeys: "message")
                    ?? "A server message was received.",
                tone: isAdminIssued(command) ? .warning : .info,
                duration: isAdminIssued(command) ? 10 : 8
            )
        case .serverRestarting:
            showNotice(
                title: command.payload.string(forKeys: "title") ?? "Server restarting",
                message: command.payload.string(forKeys: "message")
                    ?? "Playback may end shortly while the server restarts.",
                tone: .warning,
                duration: 10
            )
        case .serverShuttingDown:
            showNotice(
                title: command.payload.string(forKeys: "title") ?? "Server shutting down",
                message: command.payload.string(forKeys: "message")
                    ?? "Playback may end shortly while the server shuts down.",
                tone: .warning,
                duration: 10
            )
        case .stop, .terminate:
            activePlayer.pause()
            if isAdminIssued(command) {
                let isTerminate = command.name == .terminate
                showNotice(
                    title: command.payload.string(forKeys: "title")
                        ?? (isTerminate ? "Session ended by admin" : "Playback stopped by admin"),
                    message: command.payload.string(forKeys: "message")
                        ?? (isTerminate
                            ? "An administrator ended this playback session."
                            : "An administrator stopped this playback session."),
                    tone: .warning,
                    duration: 1.2
                )
                requestRemoteDismiss(after: 0.8)
            } else {
                requestRemoteDismiss()
            }
        case .setVolume, .playMedia, .setAudioTrack, .setSubtitleTrack:
            throw PlaybackRealtimeCommandExecutionError.unsupportedCommand
        }
    }

    @MainActor
    private func applyRemoteSeek(to seconds: Double) {
        skipDebounceTask?.cancel()
        skipDebounceTask = nil

        let cappedTarget: Double
        if duration > 0 {
            cappedTarget = min(max(0, seconds), duration)
        } else {
            cappedTarget = max(0, seconds)
        }
        Self.logger.info(
            "[CMP-SEEK] remote seek requested seconds=\(seconds, privacy: .public) capped=\(cappedTarget, privacy: .public) duration=\(self.duration, privacy: .public)"
        )
        commitSeek(to: cappedTarget, source: "remoteCommand")
    }

    @MainActor
    private func showNotice(
        title: String,
        message: String,
        tone: PlayerNoticeTone,
        duration: TimeInterval
    ) {
        let notice = PlayerNotice(title: title, message: message, tone: tone)
        activeNotice = notice
        noticeDismissTask?.cancel()
        noticeDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, self.activeNotice?.id == notice.id else { return }
            self.activeNotice = nil
            self.noticeDismissTask = nil
        }
    }

    @MainActor
    private func requestRemoteDismiss() {
        requestRemoteDismiss(after: 0)
    }

    @MainActor
    private func requestRemoteDismiss(after delay: TimeInterval) {
        noticeDismissTask?.cancel()
        remoteDismissTask?.cancel()
        remoteDismissTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            self.noticeDismissTask = nil
            if delay <= 0 {
                self.activeNotice = nil
            }
            self.remoteDismissToken = UUID()
            self.remoteDismissTask = nil
        }
    }

    private func isAdminIssued(_ command: PlaybackRealtimeCommandEnvelope) -> Bool {
        command.issuedBy?.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "admin"
    }


    private func makeStreamRequest(
        session: PlaybackSessionResponse,
        additionalHeaders: [String: String] = [:]
    ) async -> StreamRequest? {
        let serverUrl = await ContinuumAPI.shared.currentServerUrl()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let token = await ContinuumAPI.shared.currentAccessToken()

        guard let url = resolveServerUrl(session.streamUrl, serverUrl: serverUrl) else {
            return nil
        }

        var headers = additionalHeaders
        if let token, !token.isEmpty, !url.isFileURL {
            headers["Authorization"] = "Bearer \(token)"
        }

        return StreamRequest(url: url, headers: headers, serverUrl: serverUrl)
    }

    /// Turns a server-supplied URL (absolute or API-relative) into an absolute URL.
    /// Local `file://` URLs (offline downloads and their cached sidecar
    /// subtitles) pass through untouched.
    private func resolveServerUrl(_ raw: String, serverUrl: String) -> URL? {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("file://") {
            return URL(string: raw)
        }

        guard !serverUrl.isEmpty else { return nil }

        let relativePath = raw.hasPrefix("/") ? raw : "/\(raw)"
        let urlString = relativePath.hasPrefix("/api/")
            ? "\(serverUrl)\(relativePath)"
            : "\(serverUrl)/api/v1\(relativePath)"
        return URL(string: urlString)
    }

    private func makeRouteRequirements(prepared: PreparedPlayback) -> PlaybackRouteRequirements {
        ApplePlaybackRoutePlanner.makeRouteRequirements(
            selectedVersion: prepared.selectedVersion,
            session: prepared.session,
            dolbyVisionPolicy: settings.dolbyVisionPolicySnapshot
        )
    }

    private struct NativeDirectAssessment {
        let isEligible: Bool
        let blockers: [String]
        let trace: [String]
    }

    private func shouldUseH264ContainerLoopback(
        selectedVersion: FileVersion,
        nativeAssessment: NativeDirectAssessment
    ) -> Bool {
        guard isH264Video(selectedVersion) else { return false }
        guard nativeAssessment.blockers.contains("container_not_allowlisted") else { return false }

        let expectedBlockers: Set<String> = [
            "container_not_allowlisted",
            "embedded_subtitles_require_compatibility"
        ]
        return Set(nativeAssessment.blockers).subtracting(expectedBlockers).isEmpty
    }

    private func assessNativeDirectRoute(
        selectedVersion: FileVersion,
        session: PlaybackSessionResponse,
        requirements: PlaybackRouteRequirements
    ) -> NativeDirectAssessment {
        var blockers: [String] = []
        var trace: [String] = ["delivery_direct"]

        let container = normalizedContainer(for: selectedVersion)
        trace.append("container_\(container ?? "unknown")")
        if let container {
            if !Self.nativeDirectContainers.contains(container) {
                blockers.append("container_not_allowlisted")
            }
        } else {
            blockers.append("container_unknown")
        }

        let videoCodec = normalizedVideoCodec(selectedVersion.codecVideo ?? session.playbackInfo?.videoCodec)
        trace.append("video_\(videoCodec ?? "unknown")")
        if let videoCodec {
            if !Self.nativeDirectVideoCodecs.contains(videoCodec) {
                blockers.append("video_codec_not_allowlisted")
            }
        } else {
            blockers.append("video_codec_unknown")
        }

        let audioCodec = normalizedAudioCodec(selectedVersion.codecAudio ?? session.playbackInfo?.audioCodec)
        trace.append("audio_\(audioCodec ?? "unknown")")
        if let audioCodec {
            if !Self.nativeDirectAudioCodecs.contains(audioCodec) {
                blockers.append("audio_codec_not_allowlisted")
            }
        } else {
            blockers.append("audio_codec_unknown")
        }

        let unsupportedSubtitleCodecs = unsupportedEmbeddedSubtitleCodecs(for: selectedVersion)
        if !unsupportedSubtitleCodecs.isEmpty {
            blockers.append("embedded_subtitles_require_compatibility")
            trace.append("embedded_subtitles_\(unsupportedSubtitleCodecs.joined(separator: "_"))")
        }

        let capabilityBlockers = PlaybackEngineKind.avPlayerNativeDirect.routeCapabilities
            .blockingReasons(for: requirements)
        blockers.append(contentsOf: capabilityBlockers)

        return NativeDirectAssessment(
            isEligible: blockers.isEmpty,
            blockers: blockers,
            trace: trace
        )
    }

    private func normalizedContainer(for version: FileVersion) -> String? {
        if let raw = normalizedToken(version.container) {
            if raw == "quicktime" { return "mov" }
            return raw
        }

        guard let fileName = version.fileName else { return nil }
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    private func normalizedVideoCodec(_ raw: String?) -> String? {
        switch normalizedToken(raw) {
        case "h264", "h.264", "avc", "avc1":
            return "h264"
        case "hevc", "h265", "h.265", "hvc1", "hev1":
            return "hevc"
        default:
            return normalizedToken(raw)
        }
    }

    private func normalizedAudioCodec(_ raw: String?) -> String? {
        switch normalizedToken(raw) {
        case "aac", "mp4a":
            return "aac"
        case "ac3":
            return "ac3"
        case "eac3", "ec3", "ec-3":
            return "eac3"
        case "truehd", "true-hd", "dolbytruehd", "mlp", "mlpa":
            return "truehd"
        case "alac":
            return "alac"
        case "mp3":
            return "mp3"
        default:
            return normalizedToken(raw)
        }
    }

    private func normalizedSubtitleCodec(_ raw: String?) -> String? {
        switch normalizedToken(raw) {
        case "mov_text", "tx3g":
            return "mov_text"
        case "wvtt", "webvtt", "web_vtt":
            return "webvtt"
        default:
            return normalizedToken(raw)
        }
    }

    private func unsupportedEmbeddedSubtitleCodecs(for version: FileVersion) -> [String] {
        (version.subtitleTracks ?? [])
            .filter { !($0.external ?? false) }
            .compactMap { track in
                guard let codec = normalizedSubtitleCodec(track.codec) else {
                    return "unknown"
                }
                return Self.nativeDirectSubtitleCodecs.contains(codec) ? nil : codec
            }
    }

    private func versionHasDolbyVision(_ version: FileVersion) -> Bool {
        (version.videoTracks ?? []).contains { track in
            normalizedToken(track.dolbyVision) != nil
        }
    }

    private func dolbyVisionProfile(for version: FileVersion) -> Int? {
        (version.videoTracks ?? []).compactMap { track in
            dolbyVisionProfile(from: track.dolbyVision)
        }.first
    }

    private func dolbyVisionProfile(from raw: String?) -> Int? {
        guard let token = normalizedToken(raw) else { return nil }

        if let profile = Int(token), profile > 0 {
            return profile
        }

        let pattern = #"(?:profile|dvhe|dvh1|dvav|dva1|dvvp|p)\D*([0-9]{1,2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        guard let match = regex.firstMatch(in: token, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: token),
              let profile = Int(token[captureRange]),
              profile > 0 else {
            return nil
        }

        return profile
    }

    private func applyFileBitrateStats(_ stats: inout PlaybackStats) {
        if stats.averageFileBitrateBps == nil,
           let bitrateKbps = currentSelectedVersion?.bitrate,
           bitrateKbps > 0 {
            stats.averageFileBitrateBps = Double(bitrateKbps) * 1_000
        }
        let currentBitrateBps = stats.sourceOriginBitrateBps ?? stats.currentDownloadBitrateBps
        if let currentDownloadBitrateBps = currentBitrateBps,
           let averageFileBitrateBps = stats.averageFileBitrateBps,
           averageFileBitrateBps > 0 {
            stats.streamSpeed = currentDownloadBitrateBps / averageFileBitrateBps
        }
    }

    /// Backends report the source they were handed, which behind the
    /// source proxy or loopback is the in-app 127.0.0.1 server — an
    /// implementation detail, not the origin. Rewrite it to the true
    /// origin host from the active plan for the HUD.
    private func applySourceOriginLabel(_ stats: inout PlaybackStats) {
        guard let source = stats.source else { return }
        let localTokens: Set<String> = ["127.0.0.1", "localhost", "::1", "local"]
        guard localTokens.contains(source), let plan = activeExecutionPlan else { return }
        let origin = plan.sourceStreamRequest.url.host
            ?? URL(string: plan.sourceStreamRequest.serverUrl)?.host
        if let origin {
            stats.source = origin
        }
    }

    private func applySourceCacheStats(_ stats: inout PlaybackStats) {
        guard let sourceProxy else { return }
        let sourceStats = sourceProxy.stats()
        stats.sourceCacheBytes = sourceStats.cachedBytes
        stats.sourceCacheBudgetBytes = sourceStats.cacheBudgetBytes
        stats.sourceCacheHighWaterBytes = sourceStats.highWaterBytes
        stats.sourceCacheLowWaterBytes = sourceStats.lowWaterBytes
        stats.sourceCacheForwardBytes = sourceStats.forwardCachedBytes
        stats.sourceCacheAheadSeconds = sourceStats.estimatedForwardCacheAheadSeconds
        stats.sourceCacheHitBytes = sourceStats.cacheHitBytes
        stats.sourceCacheMissBytes = sourceStats.cacheMissBytes
        stats.sourceActiveOriginRequestCount = sourceStats.activeOriginRequestCount
        stats.sourceDiskSpillBytes = sourceStats.diskSpillBytes
        stats.sourceDiskBytesWritten = sourceStats.diskBytesWritten
        stats.sourceOriginBytesTransferred = sourceStats.originBytesTransferred
        stats.sourceOriginBitrateBps = sourceStats.currentOriginBitrateBps
    }

    private func stablePlaybackFailureToken(for message: String) -> String {
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

    private func makeLoopbackAudioTracks(for version: FileVersion) -> [PlayerTrack] {
        (version.audioTracks ?? []).enumerated().map { audioTrackIndex, track in
            PlayerTrack(
                trackId: Int64(10_000 + audioTrackIndex),
                kind: .audio,
                title: track.title,
                lang: track.language,
                codec: track.codec,
                audioChannelsLayout: track.channelLayout,
                audioChannelCount: track.channels,
                bitrate: track.bitrate.map(Int64.init),
                isDefault: track.isDefault ?? false,
                isForced: false,
                isHearingImpaired: false,
                isVisualImpaired: false,
                isExternal: false,
                isSelected: false,
                ffIndex: track.index,
                srcId: audioTrackIndex
            )
        }
    }

    private func normalizedLoopbackAudioTracks(for version: FileVersion) -> [PlayerTrack] {
        let sourceTracks = makeLoopbackAudioTracks(for: version)
        guard !sourceTracks.isEmpty else { return [] }
        let selectedFfIndex = resolveLoopbackSelectedAudioTrack(from: sourceTracks)?.ffIndex
        return sourceTracks.map { track in
            PlayerTrack(
                trackId: track.trackId,
                kind: track.kind,
                title: track.title,
                lang: track.lang,
                codec: track.codec,
                audioChannelsLayout: track.audioChannelsLayout,
                audioChannelCount: track.audioChannelCount,
                bitrate: track.bitrate,
                isDefault: track.isDefault,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                isVisualImpaired: track.isVisualImpaired,
                isExternal: track.isExternal,
                isSelected: track.ffIndex == selectedFfIndex,
                ffIndex: track.ffIndex,
                srcId: track.srcId
            )
        }
    }

    private func resolveLoopbackSelectedAudioTrack(from tracks: [PlayerTrack]) -> PlayerTrack? {
        if let selectedAudioId,
           let track = tracks.first(where: { $0.trackId == selectedAudioId }) {
            return track
        }
        if let pendingAudioFfIndex,
           let track = tracks.first(where: { audioSelectionIndex(for: $0) == pendingAudioFfIndex }) {
            return track
        }
        if let preferredAudioTrackIndex = resolvedAudioTrackIndexForResume(),
           let track = tracks.first(where: { audioSelectionIndex(for: $0) == preferredAudioTrackIndex }) {
            return track
        }
        if let track = tracks.first(where: { $0.isDefault }) {
            return track
        }
        return tracks.first
    }

    private func audioSelectionIndex(for track: PlayerTrack) -> Int? {
        track.srcId ?? track.ffIndex
    }

    private func loopbackAudioOutputMode(for track: PlayerTrack) -> LoopbackSessionSpec.AudioOutputMode {
        switch normalizedToken(track.codec)?.replacingOccurrences(of: "-", with: "") {
        case "aac", "ac3", "eac3":
            return .copy
        case "truehd", "dolbytruehd":
            return .requireFLAC
        case "mlp", "mlpa":
            return .requireFLAC
        default:
            if let channelCount = track.audioChannelCount, channelCount > 2 {
                return .transcodeFLAC
            }
            return .transcodeAAC
        }
    }

    private func loopbackAudioPreservesAtmos(for track: PlayerTrack) -> Bool {
        guard normalizedToken(track.codec)?.replacingOccurrences(of: "-", with: "") == "eac3" else {
            return false
        }
        let titleToken = normalizedToken(track.title)
        return titleToken?.contains("atmos") == true || titleToken?.contains("joc") == true
    }

    private func makeLoopbackSessionSpec(
        for version: FileVersion,
        selectedAudioTrackIndex: Int?,
        streamRequest: StreamRequest,
        videoMode: LoopbackSessionSpec.VideoMode,
        videoRange: String = "PQ",
        sourceStartTimeSeconds: Double = 0
    ) -> LoopbackSessionSpec? {
        let tracks = normalizedLoopbackAudioTracks(for: version)
        let selectedTrack = tracks.first(where: { $0.srcId == selectedAudioTrackIndex })
            ?? resolveLoopbackSelectedAudioTrack(from: tracks)
        guard let selectedTrack,
              let selectedTrackIndex = selectedTrack.srcId ?? selectedAudioTrackIndex else {
            Self.logger.error(
                "[CMP-ROUTE] loopback session missing resolved audio track videoMode=\(videoMode.logToken, privacy: .public)"
            )
            return nil
        }

        let outputMode = loopbackAudioOutputMode(for: selectedTrack)
        let preservesAtmos = outputMode == .copy && loopbackAudioPreservesAtmos(for: selectedTrack)
        let advertisedProfile: Int? = switch videoMode {
        case .passthroughProfile5:
            5
        case .convertProfile7To81:
            8
        case .passthroughProfile8:
            8
        case .passthroughHEVC, .passthroughH264:
            nil
        }
        let compatibilityBrand: String? = switch videoMode {
        case .passthroughProfile5:
            nil
        case .convertProfile7To81:
            "db1p"
        case .passthroughProfile8(.hdr10):
            "db1p"
        case .passthroughProfile8(.hlg):
            "db4h"
        case .passthroughHEVC, .passthroughH264:
            nil
        }

        return LoopbackSessionSpec(
            sourceURL: streamRequest.url,
            headers: streamRequest.headers,
            sourceStartTimeSeconds: sourceStartTimeSeconds.isFinite
                ? max(0, sourceStartTimeSeconds)
                : 0,
            sourceBitrateBps: version.bitrate.map { Double($0) * 1_000 },
            videoMode: videoMode,
            sourceVideoFrameRate: loopbackSourceFrameRate(for: version),
            selectedAudio: LoopbackSessionSpec.SelectedAudio(
                trackIndex: selectedTrackIndex,
                ffIndex: selectedTrack.ffIndex,
                sourceCodec: selectedTrack.codec,
                sourceChannelCount: selectedTrack.audioChannelCount,
                sourceChannelLayout: selectedTrack.audioChannelsLayout,
                outputMode: outputMode,
                preservesAtmos: preservesAtmos
            ),
            availableAudioTracks: tracks,
            manifestMetadata: LoopbackSessionSpec.ManifestMetadata(
                advertisedDolbyVisionProfile: advertisedProfile,
                compatibilityBrand: compatibilityBrand,
                videoRange: videoRange,
                mayClaimAtmos: preservesAtmos
            ),
            servingMode: .gated
        )
    }

    private func makeFallbackLoopbackSession(
        streamRequest: StreamRequest,
        videoMode: LoopbackSessionSpec.VideoMode,
        videoRange: String,
        sourceStartTimeSeconds: Double
    ) -> LoopbackSessionSpec? {
        currentSelectedVersion.flatMap { version in
            makeLoopbackSessionSpec(
                for: version,
                selectedAudioTrackIndex: resolvedAudioTrackIndexForResume() ?? pendingAudioFfIndex,
                streamRequest: streamRequest,
                videoMode: videoMode,
                videoRange: videoRange,
                sourceStartTimeSeconds: sourceStartTimeSeconds
            )
        }
    }

    private func loopbackSourceFrameRate(for version: FileVersion) -> Float? {
        (version.videoTracks ?? [])
            .compactMap { parseLoopbackFrameRate($0.frameRate) }
            .first
    }

    private func parseLoopbackFrameRate(_ raw: String?) -> Float? {
        guard let raw else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        if token.contains("/") {
            let parts = token.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let numerator = Float(parts[0]),
                  let denominator = Float(parts[1]),
                  numerator > 0,
                  denominator > 0 else {
                return nil
            }
            return numerator / denominator
        }

        guard let value = Float(token), value > 0 else {
            return nil
        }
        return value
    }

    private func isH264Video(_ version: FileVersion) -> Bool {
        var tokens = [version.codecVideo]
        tokens.append(contentsOf: (version.videoTracks ?? []).map(\.codec))
        return tokens.compactMap(normalizedToken).contains { token in
            token == "h264"
                || token == "avc1"
                || token.contains("h.264")
                || token.contains("avc")
        }
    }

    private func versionHasPotentialAtmos(_ version: FileVersion) -> Bool {
        (version.audioTracks ?? []).contains { track in
            let codec = normalizedToken(track.codec)
            let title = normalizedToken(track.title)
            return codec == "truehd"
                || codec == "e-ac-3"
                || codec == "eac3"
                || title?.localizedCaseInsensitiveContains("atmos") == true
        }
    }

    private func normalizedToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let token = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return token.isEmpty ? nil : token
    }

    private func humanReadableRouteReason(_ reason: String) -> String {
        switch reason {
        case "dolby_vision_profile7_to81_loopback", "dolby_vision_profile7_to81_base_layer_loopback":
            return "Dolby Vision Profile 7 base layer selected for Profile 8.1 SiloPlayer signaling"
        case "dolby_vision_profile7_hdr10_fallback_loopback":
            return "Dolby Vision Profile 7 using HDR10 fallback"
        case "dolby_vision_disabled_base_layer_loopback":
            return "Dolby Vision is off in Settings, so the HDR base layer was selected"
        case "dolby_vision_profile5_loopback":
            return "Dolby Vision Profile 5 selected SiloPlayer normalization"
        case "h264_container_loopback", "h264_audio_normalization_loopback",
             "h264_subtitle_normalization_loopback":
            return "H.264 direct play selected SiloPlayer normalization"
        case "hevc_container_loopback", "hevc_audio_normalization_loopback",
             "hevc_subtitle_normalization_loopback":
            return "HEVC direct play selected SiloPlayer normalization"
        case "native_direct_asset":
            return "Native Player Direct allowlist matched"
        case "native_direct_avplayer_failed_playercore_fallback":
            return "Native Player Direct failed, so playback fell back to Compatibility Playback"
        case let reason where reason.hasPrefix("playercore_rejected_"):
            let token = String(reason.dropFirst("playercore_rejected_".count))
            return "Compatibility Playback rejected the stream (\(humanReadablePlayerCoreRejection(token))), so playback switched to an AVPlayer presentation route"
        case "native_direct_blocked":
            return "Stayed on Compatibility Playback because the Native Player Direct allowlist did not match"
        case "direct_play_uses_coremedia":
            return "Compatibility route selected for direct playback"
        case "apple_hls_route_enabled":
            return "Native Player HLS route selected"
        case "parity_gate_blocked":
            return "Feature gate kept HLS on the compatibility route"
        case "macOS_avfoundation_backend":
            return "macOS stays on its Native Player route"
        case "macos_direct_avplayer_fallback":
            return "macOS received a direct stream outside the native allowlist and will attempt Native Player playback"
        default:
            return reason.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func humanReadablePlayerCoreRejection(_ token: String) -> String {
        switch token {
        case "dolbyVisionProfile5":
            return "Dolby Vision Profile 5"
        case "videoToolboxUnsupportedHEVCPQ":
            return "unsupported HEVC PQ"
        case "videoToolboxUnsupportedHEVCHDR":
            return "unsupported HEVC HDR"
        case "videoToolboxBadDataHEVC":
            return "HEVC VideoToolbox bad-data"
        default:
            return token.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func loadPendingExternalSubtitles() {
        let restoredFromKnownCache = pendingExternalSubtitles.isEmpty
        let allPending = restoredFromKnownCache
            ? knownExternalSubtitles
            : pendingExternalSubtitles
        let pending = subtitleUrlsForCurrentRoute(allPending)
        pendingExternalSubtitles = []
        guard !pending.isEmpty else {
            Self.logger.info(
                "[CMP-SUB] no external subtitles to register route=\(self.activeRouteKind.label, privacy: .public) currentTracks=\(self.subtitleTracks.count, privacy: .public)"
            )
            return
        }

        Self.logger.info(
            "[CMP-SUB] resolving external subtitles count=\(pending.count, privacy: .public) route=\(self.activeRouteKind.label, privacy: .public) supportsExternal=\(self.backendCapabilities.supportsExternalPrimarySubtitles, privacy: .public) fromKnownCache=\(restoredFromKnownCache, privacy: .public)"
        )

        var descriptors: [SidecarSubtitleDescriptor] = []
        descriptors.reserveCapacity(pending.count)
        for sub in pending {
            guard let url = resolveServerUrl(sub.url, serverUrl: resolvedServerUrl) else {
                Self.logger.warning("Skipping external subtitle with unresolved URL")
                continue
            }
            descriptors.append(SidecarSubtitleDescriptor(
                index: sub.index,
                language: sub.language,
                codec: sub.codec,
                label: sub.label,
                source: sub.source,
                forced: sub.forced,
                url: url
            ))
        }
        guard !descriptors.isEmpty else {
            Self.logger.warning("[CMP-SUB] no external subtitle descriptors survived URL resolution")
            return
        }
        if backendCapabilities.supportsExternalPrimarySubtitles {
            Self.logger.info(
                "[CMP-SUB] registering sidecar subtitles descriptors=\(descriptors.count, privacy: .public) route=\(self.activeRouteKind.label, privacy: .public)"
            )
            switch activePlayer {
            case .none:
                break
            case .coreMedia(let core):
                core.registerSidecarSubtitles(descriptors)
            case .avPlayer(let backend):
                backend.registerSidecarSubtitles(descriptors)
            }
        } else {
            Self.logger.info(
                "[CMP-ROUTE] skipping sidecar subtitle registration on backend=\(self.activeRouteKind.label, privacy: .public)"
            )
        }
    }

    private func subtitleUrlsForCurrentRoute(_ urls: [SubtitleUrl]) -> [SubtitleUrl] {
        guard activeRouteUsesEmbeddedAVPlayerSubtitleExtraction else { return urls }
        let filtered = urls.filter { subtitle in
            subtitle.source?.localizedCaseInsensitiveCompare("embedded") != .orderedSame
        }
        if filtered.count != urls.count {
            Self.logger.info(
                "[CMP-SUB] skipped embedded sidecar subtitle urls count=\(urls.count - filtered.count, privacy: .public) route=\(self.activeRouteKind.label, privacy: .public)"
            )
        }
        return filtered
    }

    private var activeRouteUsesEmbeddedAVPlayerSubtitleExtraction: Bool {
        switch activeRouteKind {
        case .avPlayerNativeDirect, .siloPlayerLoopback:
            return true
        case .playerCoreDirect, .avPlayerHLS:
            return false
        }
    }

    private func applyAudioTrackSelection(_ trackId: Int64) {
        switch activePlayer {
        case .none:
            return
        case .coreMedia(let core):
            core.setAudioTrack(trackId)
        case .avPlayer(let backend):
            backend.selectAudioTrack(trackId)
        }
    }

    private func applySubtitleTrackSelection(_ trackId: Int64?) {
        Self.logger.info(
            "[CMP-SUB] apply primary selection trackId=\(trackId.map(String.init) ?? "nil", privacy: .public) route=\(self.activeRouteKind.label, privacy: .public)"
        )
        switch activePlayer {
        case .none:
            return
        case .coreMedia(let core):
            core.setSubtitleTrack(trackId)
        case .avPlayer(let backend):
            backend.selectSubtitleTrack(trackId)
        }
    }

    private func applySecondarySubtitleTrackSelection(_ trackId: Int64?) {
        switch activePlayer {
        case .none:
            return
        case .coreMedia(let core):
            core.setSecondarySubtitleTrack(trackId)
        case .avPlayer(let backend):
            backend.setSecondarySubtitleTrack(trackId)
        }
    }

    // MARK: - Live AI subtitle track seam

    /// Open a synthetic live AI subtitle track in the given slot on the
    /// active backend. Cues are then streamed in via `feedLiveSubtitleCue`.
    /// Route-agnostic so a backend switch keeps working.
    func openLiveSubtitleTrack(slot: SubtitleSlot = .primary, label: String?, language: String?) {
        switch activePlayer {
        case .none:
            return
        case .coreMedia(let core):
            core.openLiveSubtitleTrack(slot: slot, label: label, language: language)
        case .avPlayer(let backend):
            backend.openLiveSubtitleTrack(slot: slot, label: label, language: language)
        }
    }

    /// Feed a single converted live AI cue (from `LiveSubtitleTrack`) to
    /// the live track in the given slot on the active backend.
    func feedLiveSubtitleCue(
        slot: SubtitleSlot = .primary,
        eventText: String,
        startMs: Int64,
        durationMs: Int64
    ) {
        switch activePlayer {
        case .none:
            return
        case .coreMedia(let core):
            core.feedLiveSubtitleCue(slot: slot, eventText: eventText, startMs: startMs, durationMs: durationMs)
        case .avPlayer(let backend):
            backend.feedLiveSubtitleCue(slot: slot, eventText: eventText, startMs: startMs, durationMs: durationMs)
        }
    }

    /// Close the live AI subtitle track in the given slot on the active
    /// backend.
    func closeLiveSubtitleTrack(slot: SubtitleSlot = .primary) {
        switch activePlayer {
        case .none:
            return
        case .coreMedia(let core):
            core.closeLiveSubtitleTrack(slot: slot)
        case .avPlayer(let backend):
            backend.closeLiveSubtitleTrack(slot: slot)
        }
    }

    /// Append a synthetic live AI subtitle row to `subtitleTracks` so the
    /// picker can select it, and return its track id. De-dupes by id.
    @discardableResult
    func appendLiveSubtitleTrack(ordinal: Int, label: String?, language: String?) -> Int64 {
        let trackId = SubtitleTrackIdSpace.makeAILiveTrackId(ordinal)
        if !subtitleTracks.contains(where: { $0.trackId == trackId }) {
            subtitleTracks.append(PlayerTrack(
                trackId: trackId,
                kind: .sub,
                title: label,
                lang: language,
                codec: nil,
                audioChannelsLayout: nil,
                audioChannelCount: nil,
                bitrate: nil,
                isDefault: false,
                isForced: false,
                isHearingImpaired: false,
                isVisualImpaired: false,
                isExternal: false,
                isSelected: false,
                ffIndex: nil,
                srcId: nil
            ))
        }
        return trackId
    }

    #if DEBUG
    /// DEBUG-only: prove the live subtitle render seam without any server.
    /// Opens a synthetic live AI track, adds + selects its picker row, and
    /// feeds canned cues on a timer at `currentTime + offset` so synthetic
    /// captions render over the video and can be toggled via the existing
    /// picker. Call again to stop.
    func debugStartFakeLiveSubtitles() {
        if debugLiveSubtitleTimer != nil {
            debugStopFakeLiveSubtitles()
            return
        }

        let ordinal = 0
        let label = "AI Live (debug)"
        let language = "en"
        debugLiveSubtitleTrack = LiveSubtitleTrack()

        openLiveSubtitleTrack(slot: .primary, label: label, language: language)
        let trackId = appendLiveSubtitleTrack(ordinal: ordinal, label: label, language: language)
        if let track = subtitleTracks.first(where: { $0.trackId == trackId }) {
            selectSubtitle(track)
        }

        Self.logger.info("[CMP-SUB] DEBUG fake live subtitles started trackId=\(trackId, privacy: .public)")

        var lineIndex = 0
        let cannedLines = [
            "Live AI subtitle seam is working.",
            "Cue two — fed via ass_process_chunk.",
            "Multi-line cue:\nsecond line here.",
            "Escapes are stripped: {not an override}.",
            "These cues stream at currentTime+.",
        ]

        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = self.currentTime
            let start = now + 0.3
            let end = start + 2.6
            let text = cannedLines[lineIndex % cannedLines.count]
            lineIndex += 1
            if let cue = self.debugLiveSubtitleTrack.makeCue(start: start, end: end, text: text) {
                self.feedLiveSubtitleCue(
                    slot: .primary,
                    eventText: cue.eventText,
                    startMs: cue.startMs,
                    durationMs: cue.durationMs
                )
                Self.logger.info(
                    "[CMP-SUB] DEBUG fed live cue startMs=\(cue.startMs, privacy: .public) durMs=\(cue.durationMs, privacy: .public) event=\(cue.eventText, privacy: .public)"
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        debugLiveSubtitleTimer = timer
    }

    /// DEBUG-only: stop the fake-live-subtitle stub and close the track.
    func debugStopFakeLiveSubtitles() {
        debugLiveSubtitleTimer?.invalidate()
        debugLiveSubtitleTimer = nil
        if selectedSubtitleId.map(SubtitleTrackIdSpace.isAILive) == true {
            disableSubtitles()
        }
        subtitleTracks.removeAll { SubtitleTrackIdSpace.isAILive($0.trackId) }
        closeLiveSubtitleTrack(slot: .primary)
        Self.logger.info("[CMP-SUB] DEBUG fake live subtitles stopped")
    }
    #endif

    /// Append sidecar tracks to `subtitleTracks` as synthesised
    /// `PlayerTrack` rows so the picker shows every available caption
    /// track alongside embedded ones. Called on main by the session.
    private func appendSidecarTracks(_ descriptors: [SidecarSubtitleDescriptor]) {
        Self.logger.info(
            "[CMP-SUB] append sidecar tracks descriptors=\(descriptors.count, privacy: .public) existingTracks=\(self.subtitleTracks.count, privacy: .public)"
        )
        // Remove any previously appended sidecars before re-appending —
        // `loadPendingExternalSubtitles` fires once per file load, so
        // de-duplication here prevents drift on retry paths.
        var existingEmbedded = subtitleTracks.filter { track in
            !SubtitleTrackIdSpace.isSidecar(track.trackId)
        }
        for d in descriptors {
            let trackId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: d.index)
            existingEmbedded.append(PlayerTrack(
                trackId: trackId,
                kind: .sub,
                title: d.label,
                lang: d.language,
                codec: d.codec,
                audioChannelsLayout: nil,
                audioChannelCount: nil,
                bitrate: nil,
                isDefault: false,
                isForced: d.forced ?? false,
                isHearingImpaired: false,
                isVisualImpaired: false,
                isExternal: true,
                isSelected: false,
                ffIndex: nil,
                srcId: d.index
            ))
        }
        subtitleTracks = existingEmbedded
        Self.logger.info(
            "[CMP-SUB] subtitle tracks after sidecar append total=\(self.subtitleTracks.count, privacy: .public)"
        )

        var restoredPrimarySidecar = false
        if let pendingTrackId = pendingSidecarSubtitleTrackId {
            pendingSidecarSubtitleTrackId = nil
            if subtitleTracks.contains(where: { $0.trackId == pendingTrackId }) {
                restoredPrimarySidecar = true
                if selectedSubtitleId != pendingTrackId {
                    selectedSubtitleId = pendingTrackId
                    applySubtitleTrackSelection(pendingTrackId)
                }
                // M5 seamless swap: the persisted AI track is now selected; it's
                // safe to drop the synthetic live row + libass track with no
                // no-subtitle flicker. (No-op unless a deferred close is armed.)
                performDeferredLiveSubtitleCloseIfNeeded()
            }
        }

        if let pendingTrackId = pendingRecoveredSecondarySubtitleId,
           subtitleTracks.contains(where: { $0.trackId == pendingTrackId }) {
            pendingRecoveredSecondarySubtitleId = nil
            if pendingTrackId != selectedSubtitleId {
                selectedSecondarySubtitleId = pendingTrackId
                applySecondarySubtitleTrackSelection(pendingTrackId)
            }
        }

        if restoredPrimarySidecar { return }

        // A pre-restart embedded selection can resurface as a sidecar when
        // the new route has the server extract embedded streams into
        // `subtitle_urls` (direct → transcode switch). If the embedded
        // snapshot is still pending — no embedded track matched it in
        // `applyTrackList` — fuzzy-match it against the sidecar rows.
        if let snapshot = pendingRecoveredSubtitleSelection,
           let match = bestTrackMatch(
               for: snapshot,
               in: subtitleTracks.filter { SubtitleTrackIdSpace.isSidecar($0.trackId) }
           ) {
            pendingRecoveredSubtitleSelection = nil
            if selectedSubtitleId != match.trackId {
                selectedSubtitleId = match.trackId
                applySubtitleTrackSelection(match.trackId)
            }
            return
        }

        // If a forced sidecar is present, auto-select it. Forced tracks
        // (for non-native dialogue or song lyrics in anime) are meant
        // to display regardless of the user's subtitle preference.
        if selectedSubtitleId == nil,
           let forced = descriptors.first(where: { $0.forced == true }) {
            let trackId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: forced.index)
            selectedSubtitleId = trackId
            applySubtitleTrackSelection(trackId)
            return
        }

        applyAutoSubtitlePreferencesIfNeeded(forceWhenNoSelection: true)
    }

    /// Called on every `track-list` change. Updates the published track lists,
    /// tracks the current live player selection, and applies any pending
    /// server-preferred indices once a matching track appears. Preserves previously-appended
    /// sidecar entries — `PlayerCore.onTracksChange` only enumerates
    /// embedded streams, and the sidecar tracks from
    /// `onSidecarTracksRegistered` are layered in separately.
    private func applyTrackList(_ tracks: [PlayerTrack]) {
        audioTracks = tracks.filter { $0.kind == .audio }
        let embeddedSubs = tracks.filter { $0.kind == .sub }
        // Preserve separately-layered subtitle rows that `onTracksChange`
        // does not enumerate: server sidecars (from
        // `onSidecarTracksRegistered`) and synthetic live AI tracks (from
        // the live-subtitle seam). Both live outside the embedded-stream
        // id space, so a track-list refresh must not drop them.
        let existingSidecars = subtitleTracks.filter { SubtitleTrackIdSpace.isSidecar($0.trackId) }
        let existingLive = subtitleTracks.filter { SubtitleTrackIdSpace.isAILive($0.trackId) }
        subtitleTracks = embeddedSubs + existingSidecars + existingLive

        if let selectedSubtitleId,
           !subtitleTracks.contains(where: { $0.trackId == selectedSubtitleId }) {
            self.selectedSubtitleId = nil
        }
        if let selectedSecondarySubtitleId,
           !subtitleTracks.contains(where: { $0.trackId == selectedSecondarySubtitleId }) {
            self.selectedSecondarySubtitleId = nil
        }

        selectedAudioId = audioTracks.first(where: { $0.isSelected })?.trackId
        if let live = embeddedSubs.first(where: { $0.isSelected })?.trackId {
            selectedSubtitleId = live
        }

        if let wantedFf = pendingAudioFfIndex,
           let match = audioTracks.first(where: { audioSelectionIndex(for: $0) == wantedFf }) {
            pendingAudioFfIndex = nil
            if selectedAudioId != match.trackId {
                selectedAudioId = match.trackId
                applyAudioTrackSelection(match.trackId)
            }
        }

        if let wantedFf = pendingSubtitleFfIndex {
            if wantedFf < 0 {
                // Explicit "Off" from the detail screen — disable subs so
                // a file-default or forced track doesn't surprise the user.
                pendingSubtitleFfIndex = nil
                if selectedSubtitleId != nil {
                    selectedSubtitleId = nil
                    applySubtitleTrackSelection(nil)
                }
            } else if let match = embeddedSubs.first(where: { $0.ffIndex == wantedFf }) {
                pendingSubtitleFfIndex = nil
                if selectedSubtitleId != match.trackId {
                    selectedSubtitleId = match.trackId
                    applySubtitleTrackSelection(match.trackId)
                }
            }
        }

        if let snapshot = pendingRecoveredAudioSelection,
           let match = bestTrackMatch(for: snapshot, in: audioTracks) {
            pendingRecoveredAudioSelection = nil
            if selectedAudioId != match.trackId {
                selectedAudioId = match.trackId
                applyAudioTrackSelection(match.trackId)
            }
        }

        if let snapshot = pendingRecoveredSubtitleSelection,
           let match = bestTrackMatch(for: snapshot, in: embeddedSubs) {
            pendingRecoveredSubtitleSelection = nil
            if selectedSubtitleId != match.trackId {
                selectedSubtitleId = match.trackId
                applySubtitleTrackSelection(match.trackId)
            }
        }

        if let pendingTrackId = pendingRecoveredSecondarySubtitleId,
           embeddedSubs.contains(where: { $0.trackId == pendingTrackId }) {
            pendingRecoveredSecondarySubtitleId = nil
            if pendingTrackId != selectedSubtitleId {
                selectedSecondarySubtitleId = pendingTrackId
                applySecondarySubtitleTrackSelection(pendingTrackId)
            }
        }

        // Auto-resolution from server prefs. Only runs when no
        // explicit caller-supplied subtitle index applied (no manual
        // override) and only once per loaded item — repeated track-
        // list updates after a stream change shouldn't keep flipping
        // subs back on after the user disabled them.
        applyAutoSubtitlePreferencesIfNeeded()
    }

    private func bestTrackMatch(
        for snapshot: TrackSelectionSnapshot,
        in tracks: [PlayerTrack]
    ) -> PlayerTrack? {
        let scored = tracks.map { track in
            (track: track, score: snapshot.score(against: track))
        }
        let best = scored.max { lhs, rhs in
            lhs.score < rhs.score
        }
        guard let best, best.score >= 3 else { return nil }
        return best.track
    }

    private func applyAutoSubtitlePreferencesIfNeeded(forceWhenNoSelection: Bool = false) {
        guard !hasExplicitSubtitleChoice, let prefs = prefsForCurrentItem else { return }
        if prefsResolvedForCurrentItem && !(forceWhenNoSelection && selectedSubtitleId == nil) {
            return
        }

        let allSubs = subtitleTracks
        guard !allSubs.isEmpty else { return }

        let audioLang = audioTracks
            .first(where: { $0.trackId == selectedAudioId })?
            .lang
        let pick = SubtitleAutoResolver.resolve(.init(
            preferredLanguage: prefs.preferredLanguage,
            mode: prefs.mode,
            showForced: prefs.showForced,
            trackSignature: prefs.trackSignature,
            availableSubtitles: allSubs,
            currentAudioLanguage: audioLang
        ))
        prefsResolvedForCurrentItem = true
        applyAutoSubtitle(pick)
    }

    /// Apply a resolver verdict. `noChange` is the "leave the player
    /// alone" case (no preference points anywhere); `disable` and
    /// `select` actually mutate state.
    private func applyAutoSubtitle(_ pick: SubtitleAutoSelection) {
        switch pick {
        case .noChange:
            return
        case .disable:
            if selectedSubtitleId != nil {
                selectedSubtitleId = nil
                applySubtitleTrackSelection(nil)
            }
        case .select(let track):
            if selectedSubtitleId != track.trackId {
                selectedSubtitleId = track.trackId
                applySubtitleTrackSelection(track.trackId)
            }
        }
    }

    private func startProgressReporting() {
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if let offline = self.offlinePlaybackContext {
                    self.recordOfflineProgress(context: offline)
                    continue
                }
                let result = await self.sessionBridge.reportProgress(
                    position: self.currentTime,
                    isPaused: !self.isPlaying
                )
                if result == .missingSession {
                    if self.attemptBackgroundSessionRenewal(
                        reason: "progress",
                        observedPosition: self.currentTime
                    ) {
                        continue
                    }
                    _ = self.attemptStaleSessionRenewal(
                        reason: "progress",
                        observedPosition: self.currentTime
                    )
                }
            }
        }
    }

    /// Route one watch-progress sample into the offline queue. The explicit
    /// `position` lets the terminal flushes (EOF, player close) pin the
    /// end-state instead of relying on the last observed tick; `markCompleted`
    /// force-latches watched on natural end even when the file's duration
    /// never resolved.
    @MainActor
    private func recordOfflineProgress(
        context: OfflinePlaybackContext,
        position: Double? = nil,
        markCompleted: Bool = false
    ) {
        let position = position ?? currentTime
        guard position.isFinite, position >= 0 else { return }
        let duration = duration.isFinite && duration > 0 ? duration : 0
        let watched = markCompleted
            || (duration > 0 && position / duration > Self.offlineWatchedFraction)
        DownloadManager.shared.recordOfflineProgress(
            mediaItemId: context.mediaItemId,
            position: position,
            duration: duration,
            completed: watched
        )
    }

    /// Duration the transport overlay stays on-screen after the last user
    /// interaction before auto-hiding while playing. Matches Infuse/Apple TV.
    private static let autoHideSeconds: UInt64 = 5

    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        showControls = true
        guard !isBackgroundSuspended else { return }
        hideControlsTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: Self.autoHideSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                #if os(iOS)
                // A native Menu offers no isPresented hook, so the hide
                // deadline checks for a live menu platter instead of the
                // menus pinning the overlay: wait out an open menu, then
                // give the overlay a fresh full window before hiding.
                if Self.isSystemMenuPresented() {
                    while Self.isSystemMenuPresented() {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard !Task.isCancelled else { return }
                    }
                    continue
                }
                #endif
                break
            }
            guard let self, self.isPlaying else { return }
            withAnimation { self.showControls = false }
        }
    }

    #if os(iOS)
    /// True while a UIKit menu platter is on screen. SwiftUI `Menu`s are
    /// UIContextMenuInteraction-backed, and the presented platter lives in
    /// a window (or a window's immediate subview) whose class name carries
    /// "ContextMenu" — there is no public presentation hook to observe.
    private static func isSystemMenuPresented() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { window in
                NSStringFromClass(type(of: window)).contains("ContextMenu")
                    || window.subviews.contains {
                        NSStringFromClass(type(of: $0)).contains("ContextMenu")
                    }
            }
    }
    #endif

    private func pauseForForegroundInterruptionIfNeeded() {
        guard !isBackgroundSuspended else { return }
        guard isPlaying else { return }
        let position = currentTime
        let wasPlaying = isPlaying
        Self.logger.info("tvOS player entering transient inactive pause at position=\(position, privacy: .public)")
        print("[CMP-LIFECYCLE] tvOS inactive; pausing for transient interruption position=\(position)")
        playbackInterruption = PlaybackInterruptionState(
            wasPlaying: wasPlaying,
            positionSeconds: position,
            recoveryDeadline: Date(),
            didAutoRecover: false,
            isPending: wasPlaying
        )
        interruptionRecoveryTask?.cancel()
        interruptionRecoveryTask = nil
        error = nil
        activePlayer.pause()
    }

    private func suspendForBackground() {
        guard !isBackgroundSuspended else { return }
        guard let suspendedContext = makeSuspendedPlaybackContext() else { return }

        let position = suspendedContext.resumePosition
        Self.logger.info("tvOS player background suspend at position=\(position, privacy: .public)")
        print("[CMP-LIFECYCLE] tvOS background suspend position=\(position)")

        suspendedPlayback = suspendedContext
        clearForegroundInterruptionState()

        freshLoadTask?.cancel()
        freshLoadTask = nil
        progressTask?.cancel()
        progressTask = nil
        hideControlsTask?.cancel()
        noticeDismissTask?.cancel()
        noticeDismissTask = nil
        remoteDismissTask?.cancel()
        remoteDismissTask = nil
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        seekFilterTimeoutTask?.cancel()
        seekFilterTimeoutTask = nil
        holdSeekTask?.cancel()
        holdSeekTask = nil
        holdSeekAutoRampTask?.cancel()
        holdSeekAutoRampTask = nil
        sleepTimer.cancel()

        activeNotice = nil
        isHUDPresented = false
        isBuffering = false
        bufferingProgress = nil
        isLoading = false
        isPlaying = false
        showControls = true
        holdSeekRate = 0
        isScrubbing = false
        scrubPreviewTime = position

        nowPlaying.detach()
        activePlayer.dispose()

        Task { [weak self] in
            await self?.realtimeClient.unbind()
            await self?.sessionBridge.stopSession(position: position, isPaused: true)
        }
    }

    private func resumeSuspendedPlayback() {
        guard let suspendedPlayback else { return }
        Self.logger.info("tvOS explicit resume from suspended playback at position=\(suspendedPlayback.resumePosition, privacy: .public)")
        print("[CMP-LIFECYCLE] explicit resume from suspended playback position=\(suspendedPlayback.resumePosition)")
        clearSuspendedPlaybackState()
        error = nil
        showControls = true
        beginFreshLoad(
            request: suspendedPlayback.request,
            progressPosition: nil,
            resumePositionOverride: suspendedPlayback.resumePosition,
            allowNearEndResume: true
        )
    }
}

private enum SiloControlPlayerError: LocalizedError {
    case missingSeekPosition
    case missingTrackId
    case missingSpeed
    case missingValue
    case missingEnabledValue
    case missingMilliseconds
    case trackNotFound
    case invalidVideoGravity
    case invalidSubtitlePosition

    var errorDescription: String? {
        switch self {
        case .missingSeekPosition:
            return "Missing seek position."
        case .missingTrackId:
            return "Missing track id."
        case .missingSpeed:
            return "Missing playback speed."
        case .missingValue:
            return "Missing setting value."
        case .missingEnabledValue:
            return "Missing enabled value."
        case .missingMilliseconds:
            return "Missing millisecond value."
        case .trackNotFound:
            return "Track not found."
        case .invalidVideoGravity:
            return "Invalid aspect setting."
        case .invalidSubtitlePosition:
            return "Invalid subtitle position."
        }
    }
}

extension PlayerViewModel {
    @MainActor
    func applySiloControlCommand(_ command: SiloControlCommand) throws {
        switch command.name {
        case .play:
            activePlayer.play()
            scheduleHideControls()
        case .pause:
            activePlayer.pause()
            scheduleHideControls()
        case .playPause:
            togglePlayPause()
        case .seek:
            guard let seconds = command.seconds else {
                throw SiloControlPlayerError.missingSeekPosition
            }
            seekTo(seconds: seconds)
        case .stop:
            activePlayer.pause()
            requestRemoteDismiss()
        case .selectAudioTrack:
            guard let trackId = command.trackId else {
                throw SiloControlPlayerError.missingTrackId
            }
            guard let track = audioTracks.first(where: { $0.trackId == trackId }) else {
                throw SiloControlPlayerError.trackNotFound
            }
            selectAudio(track)
        case .selectSubtitleTrack:
            guard let trackId = command.trackId else {
                disableSubtitles()
                return
            }
            guard let track = subtitleTracks.first(where: { $0.trackId == trackId }) else {
                throw SiloControlPlayerError.trackNotFound
            }
            selectSubtitle(track)
        case .setPlaybackSpeed:
            guard let speed = command.speed, speed.isFinite, speed > 0 else {
                throw SiloControlPlayerError.missingSpeed
            }
            setPlaybackSpeed(speed)
        case .setQuality:
            guard let value = command.value else {
                throw SiloControlPlayerError.missingValue
            }
            switchQuality(value)
        case .setVideoGravity:
            guard let value = command.value else {
                throw SiloControlPlayerError.missingValue
            }
            guard let gravity = VideoGravity(rawValue: value) else {
                throw SiloControlPlayerError.invalidVideoGravity
            }
            setVideoGravity(gravity)
        case .setHDREnabled:
            guard let enabled = command.enabled else {
                throw SiloControlPlayerError.missingEnabledValue
            }
            setHDREnabled(enabled)
        case .setSubtitleSyncMs:
            guard let milliseconds = command.milliseconds else {
                throw SiloControlPlayerError.missingMilliseconds
            }
            setSubtitleSyncMilliseconds(milliseconds)
        case .setSubtitlePosition:
            guard let value = command.value else {
                throw SiloControlPlayerError.missingValue
            }
            guard let position = SubtitlePositionPreset(rawValue: value) else {
                throw SiloControlPlayerError.invalidSubtitlePosition
            }
            setSubtitlePosition(position)
        case .setVolume:
            guard let volume = command.volume, volume.isFinite else {
                throw SiloControlPlayerError.missingValue
            }
            applyUserVolume(Float(volume))
        case .setMuted:
            guard let enabled = command.enabled else {
                throw SiloControlPlayerError.missingEnabledValue
            }
            applyUserMuted(enabled)
        case .playNext:
            playNextEpisodeNow()
        }
    }

    @MainActor
    func makeSiloControlPlaybackState(contentId: String?) -> SiloControlPlaybackState {
        let liveContentId = lastLoadRequest?.contentId ?? contentId
        let titleText = metadata.primaryTitle.isEmpty ? title : metadata.primaryTitle
        let subtitleText = [metadata.seriesTitle, metadata.episodeTag]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")

        return SiloControlPlaybackState(
            contentId: liveContentId,
            sessionId: activePlaybackSessionId,
            title: titleText.isEmpty ? "Loading" : titleText,
            subtitle: subtitleText.isEmpty ? nil : subtitleText,
            isPlaying: isPlaying,
            isLoading: isLoading,
            isBuffering: isBuffering,
            currentTime: currentTime,
            duration: duration,
            audioTracks: audioTracks.map(makeSiloControlTrack),
            subtitleTracks: subtitleTracks.map(makeSiloControlTrack),
            selectedAudioTrackId: selectedAudioId,
            selectedSubtitleTrackId: selectedSubtitleId,
            qualityOptions: qualityOptions.map(makeSiloControlOption),
            activeQualityId: activeQualityId,
            isQualitySwitching: isQualitySwitching,
            playbackSpeed: settings.playbackSpeed,
            videoGravity: settings.videoGravity.rawValue,
            hdrEnabled: settings.hdrEnabled,
            supportsVideoGravity: backendCapabilities.supportsVideoGravity,
            supportsHDRToggle: backendCapabilities.supportsHDRToggle,
            subtitleSyncMs: settings.subtitleSyncMs,
            subtitlePosition: settings.effectiveSubtitleAppearance.position.rawValue,
            supportsSubtitleDelay: backendCapabilities.supportsSubtitleDelay,
            supportsSubtitlePosition: backendCapabilities.supportsSubtitleStyling,
            volume: Double(userVolume),
            isMuted: userMuted,
            hasNextEpisode: nextUpEpisode != nil,
            nextEpisodeTitle: nextUpEpisode?.title,
            error: error
        )
    }

    private func makeSiloControlTrack(_ track: PlayerTrack) -> SiloControlTrack {
        SiloControlTrack(
            kind: track.kind.rawValue,
            trackId: track.trackId,
            title: track.primaryLabel,
            detail: track.attributesLabel
        )
    }

    private func makeSiloControlOption(_ option: ApplePlaybackQualityOption) -> SiloControlOption {
        SiloControlOption(
            id: option.id,
            label: option.labelWithBitrate,
            detail: option.subtitle
        )
    }
}

// MARK: - Live AI subtitle coordinator adapters (M4)

/// `LivePlaybackControls` over the VM's playback transport. The coordinator is
/// the single owner of pause/resume intent during a live job; this adapter
/// just forwards. Holds the VM weakly so a torn-down player can't be revived
/// by a late coordinator call.
@MainActor
private final class LiveSubtitlePlaybackAdapter: LivePlaybackControls {
    private weak var owner: PlayerViewModel?

    init(owner: PlayerViewModel) { self.owner = owner }

    func pause() { owner?.activePlayer.pause() }
    func play() { owner?.activePlayer.play() }
    var isPlaying: Bool { owner?.isPlaying ?? false }
}

/// `LiveSubtitleSink` over the VM's live-track primitives, selection plumbing,
/// completion handoff, and notice surface. Owns the per-`track_key`
/// `LiveSubtitleTrack` converters (cue dedupe + ASS escaping) and the
/// `track_key → ordinal` mapping, and applies the media-time → movie-time
/// offset before feeding libass.
@MainActor
private final class LiveSubtitleSinkAdapter: LiveSubtitleSink {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "LiveSubtitle"
    )

    private weak var owner: PlayerViewModel?

    /// How many fed cues still get a `[AI-LIVE-DIAG]` line. Bounded so the log
    /// shows the opening cues' timing (cue start vs playhead vs the shift) — the
    /// thing that tells us whether streamed cues land at the playhead — without
    /// spamming a line per cue. Reset when a new live track is installed.
    private var diagCueLogBudget = 0

    /// One cue converter per live `track_key` (holds dedupe state).
    private var converters: [String: LiveSubtitleTrack] = [:]
    /// `track_key → live-track ordinal`. Assigned monotonically; typically 0
    /// (one live job at a time), but stable per key so re-entrancy is safe.
    private var ordinals: [String: Int] = [:]
    private var nextOrdinal = 0
    /// The currently installed live track id (for selection / close).
    private var installedTrackId: Int64?
    /// The `track_key` of the currently installed live track.
    private var installedTrackKey: String?

    init(owner: PlayerViewModel) { self.owner = owner }

    func installLiveTrack(trackKey: String, label: String?, language: String?) {
        guard let owner else { return }
        let ordinal: Int
        if let existing = ordinals[trackKey] {
            ordinal = existing
        } else {
            ordinal = nextOrdinal
            nextOrdinal += 1
            ordinals[trackKey] = ordinal
        }
        converters[trackKey] = LiveSubtitleTrack()
        diagCueLogBudget = 5
        let trackId = owner.installLiveSubtitleTrackRow(
            ordinal: ordinal,
            label: label ?? "AI subtitles",
            language: language
        )
        installedTrackId = trackId
        installedTrackKey = trackKey
    }

    func feedCue(_ cue: PlaybackRealtimeSubtitleCue) {
        guard let owner, let key = installedTrackKey else { return }
        // Cue timestamps are absolute MEDIA time. Shift them onto the ACTIVE
        // backend's libass tick clock: CoreMedia ticks in movie time (shift by
        // the timeline offset), AVPlayer ticks in absolute media time (shift 0).
        // The VM owns the backend-aware conversion (see
        // `liveSubtitleCueMediaTimeShift`) so this stays correct on either
        // backend and under transcode.
        let shift = owner.liveSubtitleCueMediaTimeShift
        let movieStart = cue.start - shift
        let movieEnd = cue.end - shift
        guard var converter = converters[key] else { return }
        let converted = converter.makeCue(start: movieStart, end: movieEnd, text: cue.text)
        converters[key] = converter // persist dedupe state (value type)
        guard let converted else { return }
        if diagCueLogBudget > 0 {
            diagCueLogBudget -= 1
            // playhead = the libass tick clock the renderer paints against.
            // For a cue to be visible its [startMs, startMs+durationMs] window
            // must straddle playheadMs. If startMs is far from playheadMs, the
            // streamed cue lands off the current scene (timing); if it straddles
            // but nothing shows, the miss is downstream (render / shaping / font).
            let playheadMs = Int64((owner.currentTime - shift) * 1000.0)
            Self.logger.info(
                "[AI-LIVE-DIAG] feed cue start=\(cue.start, privacy: .public) shift=\(shift, privacy: .public) startMs=\(converted.startMs, privacy: .public) durMs=\(converted.durationMs, privacy: .public) playheadMs=\(playheadMs, privacy: .public) Δms=\(converted.startMs - playheadMs, privacy: .public) textLen=\(converted.eventText.count, privacy: .public)"
            )
        }
        owner.feedLiveSubtitleCue(
            slot: .primary,
            eventText: converted.eventText,
            startMs: converted.startMs,
            durationMs: converted.durationMs
        )
    }

    func selectLive(trackKey: String) {
        guard let owner, let trackId = installedTrackId, installedTrackKey == trackKey else { return }
        owner.selectLiveSubtitleTrack(trackId: trackId)
    }

    func closeLiveTrack(trackKey: String) {
        guard let owner else { return }
        if let trackId = installedTrackId, installedTrackKey == trackKey {
            owner.closeLiveSubtitleTrackRow(trackId: trackId)
            installedTrackId = nil
            installedTrackKey = nil
        }
        converters[trackKey] = nil
    }

    func closeLiveTrackAfterPersistedSelected(trackKey: String) {
        guard let owner else { return }
        // Hand the live track id to the VM to close AFTER the persisted track is
        // selected (M5 seamless swap). Clear our own bookkeeping now: from the
        // coordinator's perspective this track is finished, and the VM owns the
        // deferred row removal + libass teardown from here.
        if let trackId = installedTrackId, installedTrackKey == trackKey {
            owner.armDeferredLiveSubtitleClose(trackId: trackId)
            installedTrackId = nil
            installedTrackKey = nil
        }
        converters[trackKey] = nil
    }

    func restorePriorSelection(_ selection: Int64?) {
        owner?.restoreLiveSubtitleSelection(selection)
    }

    func registerPersisted(subtitleId: Int) {
        // Route through the controller's shared, latched handoff so the
        // websocket and poller never double-register the track.
        owner?.subtitleAI.completeLivePersistedHandoff(subtitleId: subtitleId)
    }

    func showPreparingNotice() {
        owner?.showLiveSubtitlePreparingNotice()
    }

    func hidePreparingNotice() {
        owner?.dismissLiveSubtitlePreparingNotice()
    }

    func showFailureNotice(_ message: String) {
        owner?.showLiveSubtitleFailureNotice(message)
    }
}
