import AVFoundation
import Foundation
import OSLog
import SwiftUI

/// Chapter marker published to the player UI (ChapterSheet, HUD chapter
/// pickers) by whichever backend or server payload resolved the list.
struct PlayerChapterInfo: Equatable, Identifiable {
    let index: Int
    let title: String?
    let time: Double
    var id: Int { index }
}

/// Pure decision boundary for the credits setting's playback behavior.
///
/// Keeping the range/key checks outside the player backend makes every edge
/// deterministic to test: the VM owns the seek side effect, while this policy
/// decides whether the current time is the first eligible visit to this
/// session/file/marker combination.
enum CreditsAutoSkipPolicy {
    static func target(
        enabled: Bool,
        playbackEligible: Bool,
        time: Double,
        range: TimeRange?,
        markerKey: String?,
        lastSkippedKey: String?
    ) -> Double? {
        guard enabled,
              playbackEligible,
              time.isFinite,
              let range,
              range.start.isFinite,
              range.end.isFinite,
              range.start >= 0,
              range.end > range.start,
              let markerKey,
              markerKey != lastSkippedKey,
              time >= range.start,
              time < range.end else {
            return nil
        }
        return range.end
    }
}

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
    let artworkUrl: String?
    let artworkThumbhash: String?

    var id: String { contentId }

    init(
        item: SectionItem,
        artworkUrl preferredArtworkUrl: String? = nil,
        artworkThumbhash preferredArtworkThumbhash: String? = nil
    ) {
        sectionItem = item
        contentId = item.contentId
        artworkUrl = preferredArtworkUrl ?? item.backdropUrl
        artworkThumbhash = preferredArtworkThumbhash ?? item.backdropThumbhash
    }
}

struct PlayerBackendCapabilities: Equatable {
    let supportsExternalPrimarySubtitles: Bool
    let supportsSecondarySubtitles: Bool
    let supportsVideoGravity: Bool
    let supportsSubtitleDelay: Bool
    let supportsSubtitleStyling: Bool

    func withSubtitleControls(_ supported: Bool) -> PlayerBackendCapabilities {
        PlayerBackendCapabilities(
            supportsExternalPrimarySubtitles: supportsExternalPrimarySubtitles,
            supportsSecondarySubtitles: supportsSecondarySubtitles,
            supportsVideoGravity: supportsVideoGravity,
            supportsSubtitleDelay: supported,
            supportsSubtitleStyling: supported
        )
    }

    static let avFoundation = PlayerBackendCapabilities(
        supportsExternalPrimarySubtitles: true,
        supportsSecondarySubtitles: true,
        supportsVideoGravity: true,
        supportsSubtitleDelay: false,
        supportsSubtitleStyling: false
    )

    static let macAVFoundation = PlayerBackendCapabilities(
        supportsExternalPrimarySubtitles: true,
        supportsSecondarySubtitles: true,
        supportsVideoGravity: false,
        supportsSubtitleDelay: false,
        supportsSubtitleStyling: false
    )
}

@Observable
class PlayerViewModel {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Player"
    )

    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var title: String = ""
    var isLoading = true
    var isBuffering = false
    var error: String?
    var showControls = false
    var activeNotice: PlayerNotice?
    var remoteDismissToken: UUID?
    /// The five published track members live on `TrackSelectionCoordinator`;
    /// these forwarders keep the view API — and its observation — unchanged.
    var audioTracks: [PlayerTrack] { trackSelection.audioTracks }
    var subtitleTracks: [PlayerTrack] { trackSelection.subtitleTracks }
    var chapters: [PlayerChapterInfo] = []
    var introRange: TimeRange?
    var creditsRange: TimeRange?
    var introAutoSkipCountdownSeconds: Int?
    var selectedAudioId: Int64? { trackSelection.selectedAudioId }
    var selectedSubtitleId: Int64? { trackSelection.selectedSubtitleId }
    var selectedSecondarySubtitleId: Int64? { trackSelection.selectedSecondarySubtitleId }
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

    /// Raw AVPlayer decode buffer ahead of `currentTime`. Diagnostics and the
    /// near-end error heuristic only — the UI shows `playbackRunwaySeconds`.
    /// Populated by `AVPlayerBackend` (KVO on `loadedTimeRanges`); stays 0
    /// until the player item publishes a range.
    var bufferedAheadSeconds: Double = 0
    /// Seconds of media that will play with zero network. What every
    /// scrubber's buffered fill draws. On the loopback route this is normally
    /// far larger than `bufferedAheadSeconds`, because AVPlayer's own buffer
    /// is deliberately held small — a few segments
    /// (`AVPlayerBackend.loopbackSteadyStateForwardBufferTarget`) — while the
    /// local store runs minutes ahead.
    var playbackRunwaySeconds: Double = 0
    /// The scrubber buffered-fill fraction, defined once for all four
    /// platform controls: playhead plus runway over duration, clamped.
    var bufferedFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max((currentTime + playbackRunwaySeconds) / duration, 0), 1)
    }
    /// The time the scrubber and its time labels should show: the scrub
    /// preview while a scrub is in flight, otherwise the playhead.
    var scrubDisplayTime: Double {
        isScrubbing ? scrubPreviewTime : currentTime
    }
    /// The scrubber playhead fraction, defined once for all four platform
    /// controls: scrub display time over duration, clamped.
    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(scrubDisplayTime / duration, 0), 1)
    }
    /// Index of the chapter containing the playhead, for the chapter lists and
    /// the info HUD. `chapters` is ascending by time.
    var currentChapterIndex: Int? {
        chapters.lastIndex(where: { $0.time <= currentTime })
    }
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

    /// The live engine session: one per `LoadID`, owning the backend, the
    /// source proxy and the load's `RecoveryDriver`. Nil until the execution
    /// plan resolves.
    private(set) var engineSession: PlaybackEngineSession?
    /// Single source of truth for the playback backend. Nil until the
    /// execution plan resolves, then holds the `AVPlayerBackend` serving
    /// whichever AVPlayer-backed route was planned (native direct, SiloPlayer
    /// loopback, or server HLS). UI surface rendering binds to this directly.
    var avPlayerBackend: AVPlayerBackend? { engineSession?.surfaceBackend }
    private var activeRouteKind: PlaybackEngineKind

    /// Canonical user volume/mute, owned by the VM rather than the backend.
    /// Backends are rebuilt on every quality switch / loopback fallback and
    /// come up at full volume, so the VM re-applies these after each swap and
    /// reports them to the cast UI — otherwise a remote-set level is lost.
    private var userVolume: Float = 1.0
    private var userMuted = false
    private(set) var activeExecutionPlan: PlaybackExecutionPlan?
    /// Owned by the engine session; read here for stats, the outage predicate
    /// and the renewals' retarget.
    private var sourceProxy: PlaybackSourceProxy? { engineSession?.transport }
    /// Identity of the load `installEngine` is currently assembling. It is the
    /// guard on both sides of `await prepareSource`, which has to drop a load
    /// that was superseded while the proxy was starting. The actor holds the
    /// same value; this copy exists because the install runs on the main actor.
    private var pendingLoadID: LoadID?
    /// The cache carried between two proxies for the same file. It deliberately
    /// outlives an engine session, so the slot lives here.
    private var sourceCacheHandoff: PlaybackEngineSession.SourceCacheHandoff?
    /// The full `PlaybackExecutionPlan` the pending adopt resolved. The control
    /// plane carries only the `ExecutablePlan` it decides with; the engine
    /// install needs the whole thing, because the source proxy rewrites its URLs
    /// and the loopback session spec travels on it. One slot, filled by
    /// `adoptPrepared` and consumed by `installEngine`.
    private var pendingExecutionPlan: PlaybackExecutionPlan?
    var backendCapabilities: PlayerBackendCapabilities {
        #if os(macOS)
        let base = PlayerBackendCapabilities.macAVFoundation
        #else
        let base = currentRouteCapabilities.backendCapabilities
        #endif
        guard let avPlayerBackend else { return base }
        return base.withSubtitleControls(avPlayerBackend.hasControlledSubtitleSelection)
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
    var orderedSubtitleTracks: [PlayerTrack] { trackSelection.orderedSubtitleTracks }
    var availableSecondarySubtitleTracks: [PlayerTrack] {
        trackSelection.availableSecondarySubtitleTracks
    }
    /// Set in `cleanup()` / `deinit`. All async callbacks into the VM gate
    /// on this so a late-landing handoff signal can't spin up a fresh
    /// pipeline on a view that's already gone.
    private var isDisposed = false
    var needsReplacementForPresentation: Bool { isDisposed }
    #if os(iOS)
    /// Mirrors the last `ScenePhase` handed to `handleScenePhase`. Lets the
    /// AirPlay route observer tell "receiver disconnected while we're in the
    /// background" (pause) from a normal foreground disconnect (keep playing
    /// on the phone).
    private var isSceneBackgrounded = false
    /// Gives automatic PiP a bounded window to publish `willStart` after the
    /// scene backgrounds. If no transition arrives, normal pause policy wins.
    private var pictureInPictureBackgroundGraceTask: Task<Void, Never>? {
        get { tasks[.pictureInPictureBackgroundGrace] }
        set { tasks[.pictureInPictureBackgroundGrace] = newValue }
    }
    /// Whether the active route can hand video to an AirPlay receiver. False
    /// on routes whose stream URL is authenticated by a request header the
    /// receiver cannot send — the picker is hidden there rather than offering
    /// a handoff that would 401 on the TV.
    private(set) var supportsExternalPlayback = false
    #endif
    /// The control plane. It holds `PlaybackState`, runs `PlaybackReducer` and
    /// executes its effects; this view model forwards view commands to it as
    /// `PlayerIntent`s and projects what it publishes back.
    @ObservationIgnored
    private var controlPlane: PlaybackSessionActor!
    /// `Sub.ended`, mirrored from the last publish. It replaces the stored
    /// `hasReachedEndOfFile` latch: the postroll guard on every transport
    /// command reads the control plane's answer instead of a second copy.
    private var hasEndedStream = false
    /// `PlaybackState.suspended`, mirrored from the last publish.
    var isBackgroundSuspended = false
    /// `SessionIdentity.serverSessionId`, mirrored from the last publish. It
    /// replaces the view model's active-session mirror; the SiloControl wire
    /// projection and the subtitle-AI live gate are its only readers.
    private var currentServerSessionId: String?
    /// Whether the visible server-outage recovery is on screen, so the
    /// "Reconnecting" notice is raised exactly once per recovery.
    private var isReconnectingAfterOutage = false
    /// The session holding the `server_replan` in-route suspension for the
    /// round trip in flight, and — because exactly one replan may be in flight —
    /// the shell's answer to `RecoveryContext.isReplanInFlight`.
    private var replanSuspensionHolder: PlaybackEngineSession?
    /// `shouldAutoRecoverFromInterruption()`: the pending interruption's
    /// deadline, mirrored from the last publish. The interruption itself is
    /// reducer state; the policy reads only "is there still time".
    private var interruptionRecoveryDeadline: Date?
    /// `RecoveryContext.canAutoRecoverInterruption`.
    private var canAutoRecoverInterruption: Bool {
        guard let interruptionRecoveryDeadline else { return false }
        return Date() <= interruptionRecoveryDeadline
    }
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
    /// Scope-tagged storage behind every `…Task` accessor below. Teardown
    /// paths cancel by scope through this rather than each keeping its own
    /// list. See `PlayerTaskRegistry`.
    @ObservationIgnored
    private let tasks = PlayerTaskRegistry()
    @ObservationIgnored
    private var realtimeClient: PlaybackRealtimeClient!
    /// The player's track half: the published lists and ids, the pending
    /// restore intents, subtitle policy resolution, provider search, and the
    /// AI/live-subtitle surface. Lazy so its ports can capture a fully
    /// initialized `self`; `@ObservationIgnored` because the forwarders below
    /// read the coordinator's own `@Observable` state, which SwiftUI tracks
    /// directly through them.
    @ObservationIgnored
    private lazy var trackSelection = TrackSelectionCoordinator(ports: makeTrackSelectionPorts())

    /// Owns the in-player AI subtitle suite (translate / transcribe over
    /// polling). Lives on the track coordinator; kept under this name because
    /// `SubtitleTranslateMenu` reaches the whole AI surface through it.
    var subtitleAI: SubtitleAIController { trackSelection.subtitleAI }

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
        realtimeConnectedSnapshot && !realtimeUnavailableSnapshot && currentServerSessionId != nil
    }

    /// The `observeUnavailability` token, retained so `cleanup()` can remove
    /// the observer explicitly. `unbind()` preserves observers across fresh
    /// load cycles because this snapshot is a long-lived PlayerViewModel concern.
    private var realtimeUnavailabilityObserverToken: UUID?
    private var realtimeConnectivityObserverToken: UUID?
    private var cleanupCompletionTask: Task<Void, Never>? {
        get { tasks[.cleanupCompletion] }
        set { tasks[.cleanupCompletion] = newValue }
    }
    /// The tvOS background-suspend stop, registered so it is observable
    /// instead of unstructured. Like the cleanup flush it belongs to no
    /// teardown scope: cancelling it mid-flight would leave the server
    /// session behind.
    private var suspendStopSessionTask: Task<Void, Never>? {
        get { tasks[.suspendStopSession] }
        set { tasks[.suspendStopSession] = newValue }
    }

    private var hideControlsTask: Task<Void, Never>? {
        get { tasks[.hideControls] }
        set { tasks[.hideControls] = newValue }
    }
    private var noticeDismissTask: Task<Void, Never>? {
        get { tasks[.noticeDismiss] }
        set { tasks[.noticeDismiss] = newValue }
    }
    private var remoteDismissTask: Task<Void, Never>? {
        get { tasks[.remoteDismiss] }
        set { tasks[.remoteDismiss] = newValue }
    }
    /// Presentation latch for the "Reconnecting" / "Reconnected" notice pair.
    /// The *gate* that decides whether the notice is due is
    /// `RecoveryContext.OutageState.noticeShown`; this records whether it fired
    /// so the exit knows whether to say "Reconnected".
    private var sourceOutageNoticeShown = false
    /// Held so the init-time `refreshSettingsFromServer` call can be cancelled
    /// from `cleanup()`. Without a handle the task lingered on a dismissed VM
    /// and could observe `self` after dispose.
    private var settingsRefreshTask: Task<Void, Never>? {
        get { tasks[.settingsRefresh] }
        set { tasks[.settingsRefresh] = newValue }
    }
    private var nextUpLookupTask: Task<Void, Never>? {
        get { tasks[.nextUpLookup] }
        set { tasks[.nextUpLookup] = newValue }
    }
    private var nextUpOnDeckTask: Task<Void, Never>? {
        get { tasks[.nextUpOnDeck] }
        set { tasks[.nextUpOnDeck] = newValue }
    }
    private var nextUpCountdownTask: Task<Void, Never>? {
        get { tasks[.nextUpCountdown] }
        set { tasks[.nextUpCountdown] = newValue }
    }
    /// Trailing-edge skip debounce: each tap updates the preview and resets
    /// this timer. The seek fires exactly once, after `skipDebounceNanos` of
    /// quiet. A leading-edge seek was tempting for responsiveness but led
    /// to visible stutter on bursts — the video would seek to tap #1, play
    /// briefly, and then jump again on the trailing commit. A single
    /// deferred seek is smooth at any burst length.
    private var skipDebounceTask: Task<Void, Never>? {
        get { tasks[.skipDebounce] }
        set { tasks[.skipDebounce] = newValue }
    }
    private let skipDebounceNanos: UInt64 = 200_000_000 // 200ms

    /// Drives the repeating preview advance while a seek session is
    /// active. Ticks at `holdSeekTickNanos`, advancing `scrubPreviewTime`
    /// by `holdSeekBaseStep * holdSeekRate` seconds each tick. Runs
    /// until `commitHoldSeek` / `cancelHoldSeek`.
    private var holdSeekTask: Task<Void, Never>? {
        get { tasks[.holdSeek] }
        set { tasks[.holdSeek] = newValue }
    }
    /// Auto-ramps the rate magnitude 1 → 2 → 4 → 8 during the first ~4 s
    /// of a hold so the user gets acceleration without having to manually
    /// tap up. Cancelled the moment the user manually adjusts the rate
    /// — they've taken control, stop second-guessing them.
    private var holdSeekAutoRampTask: Task<Void, Never>? {
        get { tasks[.holdSeekAutoRamp] }
        set { tasks[.holdSeekAutoRamp] = newValue }
    }
    private static let holdSeekBaseStep: Double = 2.0 // seconds per tick at 1x
    private static let holdSeekTickNanos: UInt64 = 100_000_000 // 100ms (10Hz)

    /// Remux HLS manifests are generated from the requested origin and then
    /// presented to AVPlayer as a local 0-based timeline. Keep the movie-time
    /// offset here so UI/progress reporting remain full-runtime based.
    private var playbackTimelineOffset: Double = 0

    /// Identity of the active offline download when playback was prepared
    /// locally (no server session). While set, watch progress is routed to
    /// `DownloadManager.recordOfflineProgress` — which queues it for the
    /// next `/sync/progress` flush — instead of the session bridge, so
    /// nothing on this path ever hits a server session/progress endpoint.
    struct OfflinePlaybackContext {
        let downloadId: String
        let mediaItemId: String
    }
    private var offlinePlaybackContext: OfflinePlaybackContext?
    /// Mirrors the server's default watched threshold (90%) so an offline
    /// watch latches `completed` — and with it delete-watched retention and
    /// the reclaim sheet — the same way an online session would.
    private static let offlineWatchedFraction: Double = 0.9

    /// Bounded fallback timer that closes a deferred live track if the persisted
    /// selection never lands. Cancelled when the seamless close fires or on
    /// cleanup.
    private var deferredLiveSubtitleCloseTask: Task<Void, Never>? {
        get { tasks[.deferredLiveSubtitleClose] }
        set { tasks[.deferredLiveSubtitleClose] = newValue }
    }
    private var resolvedServerUrl: String = ""
    private var currentDeliveryStrategy: PlaybackDeliveryStrategy = .direct
    private var currentWatchDetail: WatchDetail?
    private var currentSelectedVersion: FileVersion?
    private var activePreparedProtocolV3: PreparedPlaybackV3?
    private var autoSkippedIntroKey: String?
    private var autoSkippedCreditsKey: String?
    private var autoSkipIntroCancelledKey: String?
    private var pendingAutoSkipIntroKey: String?
    private var autoSkipIntroCountdownTask: Task<Void, Never>? {
        get { tasks[.autoSkipIntroCountdown] }
        set { tasks[.autoSkipIntroCountdown] = newValue }
    }

    private enum BeginFreshLoadError: Error {
        case playerDisposeTimeout
        case startSessionTimeout
    }

    private static let autoplayPlayerDisposeTimeout: TimeInterval = 5
    private static let autoplayStartSessionTimeout: TimeInterval = 15
    /// The replay intent the control plane last adopted, mirrored here for the
    /// three shell readers that need it synchronously: the Next Up carousel's
    /// "hide what is playing" filter, the SiloControl wire projection, and
    /// `switchQuality`'s pre-V3 branches, which build their own `.load` from it.
    private var lastLoadRequest: LoadRequest?
    private static let nextUpCountdownDefaultSeconds = 10
    private static let nextUpHUDCountdownThresholdSeconds: Double = 100
    private static let introAutoSkipCountdownDefaultSeconds = 5
    private static let nearEndPlaybackErrorThresholdSeconds: Double = 8
    /// How much media may still sit ahead of the playhead for a near-end
    /// failure to still read as the stream draining. A real drain leaves the
    /// player with essentially nothing queued.
    private static let nearEndPlaybackErrorMaxBufferedAheadSeconds: Double = 1
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
    /// Triggers a V3 replan when the audio route the session was planned
    /// against changes. iOS/tvOS only — macOS has no `AVAudioSession`.
    private var outputRouteObserverToken: NSObjectProtocol?

    init() {
        activeRouteKind = .avPlayerNativeDirect
        controlPlane = PlaybackSessionActor(bridge: sessionBridge, shell: self)
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
        // resolves the execution plan, so loading a stream does not spin up
        // and immediately tear down an unused backend.

        sleepTimer.configure { [weak self] in
            self?.send(.pause)
        }

        systemCaptionObserverToken = NotificationCenter.default.addObserver(
            forName: SystemCaptionAppearance.settingsChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.settings.subtitleMatchesSystemAppearance else { return }
            self.settings.refreshSubtitleSystemAppearance()
            self.applySubtitleAppearanceToPlayer()
            self.trackSelection.applySystemCaptionSettingsChange()
        }
        #if !os(macOS)
        outputRouteObserverToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The observer only forwards. The materiality rule, the
            // `hasProtocolV3` precondition and the replan itself are the
            // reducer's `.outputRouteChanged` arm; the `!isLoading` half of the
            // legacy guard is structural there (a load in flight is
            // `.preparing`, which the arm refuses).
            guard let self, !self.isDisposed else { return }
            self.send(.outputRouteChanged(ApplePlaybackV3Capabilities.snapshot()))
        }
        #endif
        settingsRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshSettingsFromServer()
        }
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
        avPlayerBackend?.setUserVolume(userVolume)
    }
    func applyUserMuted(_ m: Bool) {
        userMuted = m
        avPlayerBackend?.setUserMuted(m)
    }

    /// The presentation half of one engine event.
    ///
    /// It is `apply(_:from:)`'s body with every control decision removed: the
    /// reducer has already ruled on the event by the time this runs and the
    /// actor has already published whatever moved. What is left is the work that
    /// was never control plane — Now Playing, next-up presentation, auto-skip,
    /// stats composition, track application and the console breadcrumbs.
    ///
    /// - Parameter playheadAdvanced: whether the reducer accepted this tick.
    ///   `onTimeChange` drops stale drainage frames and backward loader frames
    ///   but still keeps Now Playing fresh with the optimistic target, so the
    ///   two outcomes are not interchangeable.
    @MainActor
    func applyEngineEventToPresentation(_ event: EngineEvent, playheadAdvanced: Bool) {
        guard !isDisposed else { return }
        switch event {
        case let .time(seconds):
            guard seconds.isFinite else { return }
            let movieTime = seconds + playbackTimelineOffset
            guard playheadAdvanced else {
                // Still stale — the scrubber keeps the optimistic target, but
                // Now Playing is kept fresh so the remote widget does not
                // appear frozen.
                pushNowPlayingIfDue()
                return
            }
            updateNextUpPresentation(for: movieTime)
            autoSkipIntroIfNeeded(at: movieTime)
            autoSkipCreditsIfNeeded(at: movieTime)
            pushNowPlayingIfDue()

        case .duration:
            updateNextUpPresentation(for: currentTime)

        case let .pauseChanged(paused):
            // A pause from any source (remote button, transport button,
            // Siri, interruption) surfaces the transport overlay and pins
            // it — no auto-hide runs while paused, so it stays up until
            // the user acts. Resuming re-arms the auto-hide so a resume
            // from an external source (Now Playing, Siri) does not leave
            // the overlay stuck on-screen.
            if paused, isPlaying, !isLoading, !hasEndedStream {
                pinControlsVisible()
            } else if !paused, showControls, !isHUDPresented {
                scheduleHideControls()
            }
            nowPlaying.update(
                title: title,
                duration: duration,
                position: currentTime,
                isPlaying: !paused
            )

        case let .fileLoaded(reason):
            handleFileLoaded(reason: reason)

        case .firstFrame, .failed, .recoveryAction:
            // Reported and decided by the control plane.
            break

        case let .tracks(tracks):
            trackSelection.applyTrackList(tracks)

        case let .chapters(chapters):
            self.chapters = chapters

        case let .buffering(buffering):
            // Order matters: legacy's `onBufferingChange` set `isBuffering`
            // synchronously and deferred `noteBufferingDuringSourceOutage()`
            // into a `Task { @MainActor }`, so the "Reconnecting" notice was
            // always raised after the flag had flipped.
            setBuffering(
                buffering,
                cause: buffering ? "buffer_empty" : "likely_to_keep_up"
            )
            if buffering {
                noteBufferingDuringSourceOutage()
            }

        case .bufferedAhead:
            // Published by the control plane's coalesced transport merge.
            break

        case let .stats(stats):
            let composed = PlaybackStatsComposer.compose(
                PlaybackStatsComposer.Inputs(
                    backend: stats,
                    proxy: sourceProxy?.stats(),
                    engine: activeExecutionPlan?.engine,
                    nominalFileBitrateBps: currentSelectedVersion?.bitrate
                        .flatMap { $0 > 0 ? Double($0) * 1_000 : nil },
                    originHost: activeExecutionPlan.flatMap(Self.originHost(for:))
                )
            )
            playbackStats = composed
            // Separate step, deliberately not part of stats composition: this
            // writes `metadata.badges`, which is player chrome, not telemetry.
            reconcileDynamicRangeBadge(with: composed.confirmedDynamicRange)

        case .endOfFile:
            handleEndOfFile()

        case let .timelineOffset(offset):
            guard offset.isFinite else { return }
            playbackTimelineOffset = max(0, offset)

        case let .externalPlayback(active):
            #if os(iOS)
            handleExternalPlaybackActiveChange(active)
            #else
            _ = active
            #endif

        case let .externalPlaybackAllowed(allowed):
            #if os(iOS)
            supportsExternalPlayback = allowed
            #else
            _ = allowed
            #endif

        case .externalPlaybackUnavailable:
            #if os(iOS)
            showNotice(
                title: "AirPlay Unavailable",
                message: "This device has no Wi-Fi address the receiver can reach. Playback stayed on this device.",
                tone: .warning,
                duration: 6
            )
            #endif

        case let .sidecarTracksRegistered(descriptors):
            trackSelection.appendSidecarTracks(descriptors)
        }
    }

    /// Merge one control-plane projection onto the published view state.
    ///
    /// It is a **merge**, never an assign (design section 2.3 contract note
    /// (f)): `Presentation` still stubs `metadata`, and the view-local state
    /// (controls, scrubbing, notices, next-up) is this model's alone.
    /// `transportOnly` is the coalesced per-tick publish note (g) owes — the
    /// playhead and the buffer gauges, nothing that could fight a transition.
    @MainActor
    func applyPresentation(_ presentation: Presentation, transportOnly: Bool) {
        currentTime = presentation.currentTime
        duration = presentation.duration
        bufferedAheadSeconds = presentation.bufferedAheadSeconds
        playbackRunwaySeconds = presentation.playbackRunwaySeconds
        if let stats = presentation.playbackStats { playbackStats = stats }
        guard !transportOnly else { return }

        isPlaying = presentation.isPlaying
        if error == nil, let failure = presentation.error {
            // Terminal outcome #1 of 2 (the other is `handleEndOfFile`). Every
            // recovery ladder ends either here or there, so between them a
            // report always shows how a playback finished.
            #if os(iOS) || os(tvOS)
            DiagTrace.breadcrumb(
                .essential,
                level: .error,
                category: .playback,
                tag: "Player",
                message: "playback ended in failure",
                attrs: [
                    "reason": .string(PlaybackFailure.stableToken(forLegacyMessage: failure)),
                    "play_method": .string(activeRouteKind.label),
                    // Shared with the bridge's session breadcrumbs so a
                    // report's positions are all on the same scale.
                    "position_ms": .int(
                        PlaybackSessionBridge.diagnosticsPositionMilliseconds(presentation.currentTime)
                    ),
                ]
            )
            #endif
            activePreparedProtocolV3 = nil
        }
        error = presentation.error
        if let quality = presentation.activeQualityId { activeQualityId = quality }
        isQualitySwitching = presentation.isQualitySwitching
        hasEndedStream = presentation.hasEnded
        currentServerSessionId = presentation.serverSessionId
        interruptionRecoveryDeadline = presentation.interruptionRecoveryDeadline
        setBuffering(presentation.isBuffering, cause: presentation.bufferingCause)
        if presentation.isLoading {
            isLoading = true
        } else {
            clearLoadingOverlay(reason: presentation.loadingReason)
        }
        applySuspendedState(presentation.isBackgroundSuspended)
        applyReconnectingState(presentation.isReconnecting)
    }

    /// `suspendForBackground`'s presentation half, driven by the state rather
    /// than by the scene-phase handler: it runs exactly when the control plane
    /// enters (or leaves) `PlaybackState.suspended`.
    @MainActor
    private func applySuspendedState(_ suspended: Bool) {
        guard suspended != isBackgroundSuspended else { return }
        isBackgroundSuspended = suspended
        guard suspended else { return }
        Self.logger.info(
            "[CMP-LIFECYCLE] tvOS player background suspend at position=\(self.currentTime, privacy: .public)"
        )
        cancelPendingIntroAutoSkip()
        cancelNextUpCountdown()
        tasks.cancelAll(in: .interaction)
        sleepTimer.cancel()
        activeNotice = nil
        isHUDPresented = false
        showControls = true
        holdSeekRate = 0
        isScrubbing = false
        scrubPreviewTime = currentTime
        nowPlaying.detach()
        // The realtime socket is keyed by the session the suspend is about to
        // stop; the resume's own load rebinds.
        Task { [realtimeClient] in await realtimeClient?.unbind() }
    }

    /// The visible server-outage recovery's notice, raised once per recovery.
    @MainActor
    private func applyReconnectingState(_ reconnecting: Bool) {
        guard reconnecting != isReconnectingAfterOutage else { return }
        isReconnectingAfterOutage = reconnecting
        guard reconnecting else { return }
        showNotice(
            title: "Reconnecting",
            message: "The server is updating. Playback will resume when it is ready.",
            tone: .warning,
            duration: RecoveryPolicy.serverOutageRecoveryTimeout
        )
    }

    /// Single exit point for "startup is finished", which is what `isLoading`
    /// now means: the buffering capsule keys off `isLoading || isBuffering`,
    /// so there is no separate overlay left to take down. Every clear still
    /// reports why, under its original log wording, so a console capture can
    /// read the ordering against the backend's
    /// `[CMP-AVP] initial video display gate released` line. User exit is the
    /// one path with no reason of its own: it tears the whole view down.
    private func clearLoadingOverlay(reason: String) {
        let wasLoading = isLoading
        isLoading = false
        guard wasLoading else { return }
        cmpLog("[CMP] playback loading overlay dismissed reason=\(reason)")
    }

    /// Single exit point for the buffering capsule, so every flip names its
    /// cause on the console the way the startup clear does.
    private func setBuffering(_ buffering: Bool, cause: String) {
        guard isBuffering != buffering else { return }
        isBuffering = buffering
        cmpLog("[CMP] playback buffering=\(buffering ? 1 : 0) cause=\(cause)")
    }

    private func handleFileLoaded(reason: String) {
        _ = reason
        applySettingsToPlayer()
        Self.logger.info(
            "[CMP-SUB] file loaded route=\(self.activeRouteKind.label, privacy: .public) pendingExternal=\(self.trackSelection.pendingExternalSubtitles.count, privacy: .public) tracks=\(self.subtitleTracks.count, privacy: .public)"
        )
        trackSelection.loadPendingExternalSubtitles()
        hideControlsTask?.cancel()
        showControls = false
        nowPlaying.update(
            title: title,
            duration: duration,
            position: currentTime,
            isPlaying: true
        )
    }

    /// Hand one shell-owned recovery signal to the live load's recovery owner.
    ///
    /// `PlaybackEngineSession.observe` is wave 2b's single entry point for a
    /// signal from anywhere — the backend's ladders, the source proxy's three
    /// reports, or this shell. It performs the engine-level arms where the rung
    /// ran and forwards the shell-owned ones on its event stream, which is how
    /// the decision reaches the reducer as `PlayerEvent.recovery`. Nothing is
    /// decided here (design section 4 I3); the context refresh below is only the
    /// shell-held inputs the policy reads.
    @MainActor
    func observeRecovery(_ observation: RecoveryObservation) {
        guard let session = engineSession else { return }
        if case let .engineFailed(failure) = observation {
            Self.logger.error("Player error: \(failure.legacyMessage, privacy: .public)")
        }
        refreshRecoveryContext(session: session)
        session.observe(observation)
    }

    /// The live load's origin-outage ride-through, for the actor's
    /// player-scoped carry (design section 2.8 wave-2b gap (b)).
    @MainActor
    func liveOutageState() -> RecoveryContext.OutageState? {
        engineSession?.driver.context.outage
    }

    /// `clearServerOutageRecoveryState()`'s policy half: the slot has to be
    /// released with the task that owned the wait.
    @MainActor
    func clearServerOutageRecoverySlot() {
        engineSession?.driver.clearServerOutageRecovery()
    }

    /// `clearSourceOutageRideThroughState()`'s presentation half.
    @MainActor
    func clearOutageNoticeLatch() {
        sourceOutageNoticeShown = false
    }

    /// Release the in-route suspension a replan held for its whole round trip.
    ///
    /// The hold travels with the backend instance: a same-engine replan's
    /// replacement session inherits it when it adopts the backend, a route
    /// change builds a session whose driver never held the reason. Both
    /// candidates are released because only one of them can be holding it, and
    /// releasing a reason a driver never took is a no-op.
    @MainActor
    func releaseReplanSuspension(completingQualitySwitch: Bool) {
        replanSuspensionHolder?.suspendRecovery(
            false,
            reason: RecoveryDriver.serverReplanSuspensionReason
        )
        replanSuspensionHolder = nil
        engineSession?.suspendRecovery(
            false,
            reason: RecoveryDriver.serverReplanSuspensionReason
        )
        if completingQualitySwitch { isQualitySwitching = false }
    }

    /// Everything the failure ladder and the two renewals need that lives on
    /// the shell, refreshed immediately before the observation that reads it.
    @MainActor
    private func refreshRecoveryContext(session: PlaybackEngineSession) {
        session.driver.note(
            isProtocolV3Active: activePreparedProtocolV3 != nil,
            isReplanInFlight: replanSuspensionHolder != nil,
            hasWatchDetail: currentWatchDetail != nil,
            // `attemptBackgroundSessionRenewal`'s four preconditions: online,
            // direct delivery, a loaded watch detail and a live proxy.
            canRenewSourceInBackground: !isDisposed
                && offlinePlaybackContext == nil
                && currentDeliveryStrategy == .direct
                && currentWatchDetail != nil
                && sourceProxy != nil,
            canAutoRecoverInterruption: canAutoRecoverInterruption,
            canBuildLoopbackFallback: makeNativeDirectLoopbackFallbackPlan() != nil,
            nearEnd: RecoveryContext.NearEndInputs(
                duration: duration,
                currentTime: currentTime,
                bufferedAhead: bufferedAheadSeconds,
                sourceOutageActive: session.driver.context.outage != nil
                    || (sourceProxy?.isOriginOutageActive ?? false)
            )
        )
    }

    /// The shell half of a recovery the reducer routed back as
    /// `Effect.runRecovery`. The engine-level arms already ran on the backend,
    /// where wave 2b's `PlaybackEngineSession.perform` executed them the moment
    /// the rung fired; what is left here is the presentation and the two
    /// shell-executed route fallbacks.
    @MainActor
    func performEngineRecovery(_ action: RecoveryAction) {
        switch action {
        case .treatAsNaturalEnd:
            Self.logger.info("Treating near-end playback error as EOF")
            handleEndOfFile()

        case let .switchRoute(fallback):
            switch fallback {
            case .loopbackFallback:
                performNativeDirectLoopbackFallback(failure: nil)
            case .serverHLS:
                // The reducer turns this into a server replan; there is no
                // engine-level half.
                break
            }

        case let .rideThroughOutage(probeAfter):
            guard probeAfter == .zero else { return }
            sourceOutageNoticeShown = false
            Self.logger.warning("[CMP-OUTAGE] ride-through started")
            // Already out of runway when the outage was detected (e.g. a seek
            // beyond the cache raced the outage) — the buffering edge will not
            // fire again, so the engine session re-fed the gate at entry.
            if engineSession?.driver.context.outage?.noticeShown == true {
                showSourceOutageReconnectingNotice()
            }

        case .endOutageRideThrough:
            // The latch release and the post-outage kick are the engine
            // session's half of the same action.
            Self.logger.info("[CMP-OUTAGE] ride-through ended; origin recovered")
            let showReconnected = sourceOutageNoticeShown
            sourceOutageNoticeShown = false
            if showReconnected {
                showNotice(
                    title: "Reconnected",
                    message: "Connection to the server was restored.",
                    tone: .info,
                    duration: 3
                )
            }

        case .requestServerReplan, .renewSourceInBackground, .renewSessionFresh,
             .recoverFromServerOutage, .waitForServerReady, .autoRecoverInterruption,
             .fail, .reassertPlay, .nudgeStartup, .reloadStartupItem, .reanchor,
             .reloadItem, .restartProducer, .rebuildLocalSession,
             .deferUntilPlay, .resumePlayback:
            // Reducer transitions, or engine arms the session already performed.
            break
        }
    }

    /// `attemptProtocolV3Replan`'s round trip. The single-flight, the overlay,
    /// the heartbeat cancel and the quality latch are the reducer's; what is
    /// left is the server call and the adopt.
    @MainActor
    func prepareReplan(
        _ intent: ReplanIntent
    ) async throws -> (prepared: PreparedPlayback, plan: ExecutablePlan, identity: SessionIdentity)? {
        guard let watchDetail = currentWatchDetail else { return nil }
        let selectedSubtitleSnapshot = selectedSubtitleId
        // Hold every in-route recovery rung for the whole replan round trip:
        // the shell owns the route decision now, and a watchdog
        // reanchor/reload/rebuild racing the server negotiation was review
        // section 3 #3.
        replanSuspensionHolder = engineSession
        replanSuspensionHolder?.suspendRecovery(
            true,
            reason: RecoveryDriver.serverReplanSuspensionReason
        )

        switch intent.kind {
        case .serverReplan:
            guard let prepared = try await sessionBridge.replanProtocolV3(
                watchDetail: watchDetail,
                position: intent.position,
                classification: intent.classification,
                message: intent.message,
                operation: intent.operation,
                qualityPreference: intent.qualityPreference,
                audioTrackIndex: trackSelection.resolvedAudioTrackIndexForResume(),
                subtitleTrackIndex: trackSelection.resolvedProtocolV3SubtitleIndexForResume(),
                outputRouteSnapshot: intent.outputRouteSnapshot
            ) else {
                return nil
            }
            try Task.checkCancellation()
            let plan = try await adoptPrepared(
                prepared,
                origin: .protocolV3Replan(PlaybackAdoptionOrigin.Replan(
                    selectedSubtitleSnapshot: selectedSubtitleSnapshot
                ))
            )
            return (prepared, plan, Self.identity(for: prepared))

        case let .transcodeRestart(restart):
            guard activePreparedProtocolV3 != nil, currentSelectedVersion != nil else {
                Self.logger.warning(
                    "[CMP-SEEK] V3 stream replan skipped: missing active protocol or item snapshot"
                )
                return nil
            }
            let isQualitySwitch: Bool
            let qualityId: String
            switch restart {
            case let .qualityChange(id):
                isQualitySwitch = true
                qualityId = id
            case .seekReanchor:
                isQualitySwitch = false
                qualityId = activeQualityId
            }
            let externalSubtitleSnapshot = trackSelection.knownExternalSubtitles
            let selectedSecondarySubtitleSnapshot = selectedSecondarySubtitleId
            let explicitSubtitleChoiceSnapshot = trackSelection.hasExplicitSubtitleChoice
            // An embedded selection cannot be re-established by trackId across
            // the backend rebuild (ids are not stable), and after a switch to
            // transcode the same stream may resurface as a sidecar instead.
            let embeddedSubtitleSelectionSnapshot =
                trackSelection.embeddedSubtitleSelectionSnapshot()
            if isQualitySwitch { activeQualityId = qualityId }
            if !isQualitySwitch {
                // Engine only: the replacement load still has to stash the live
                // proxy's cache, so the transport stays up.
                engineSession?.disposeEngineOnly(reason: "transcode_restart")
            }
            guard let prepared = try await sessionBridge.replanProtocolV3(
                watchDetail: watchDetail,
                position: intent.position,
                classification: intent.classification,
                message: intent.message,
                operation: intent.operation,
                qualityPreference: intent.qualityPreference,
                audioTrackIndex: trackSelection.resolvedAudioTrackIndexForResume(),
                subtitleTrackIndex: trackSelection.resolvedProtocolV3SubtitleIndexForResume()
            ) else {
                throw PlaybackV3TerminalFailure(
                    reason: "replan_unavailable",
                    message: "The active V3 playback plan cannot be replaced in place.",
                    retryable: false
                )
            }
            try Task.checkCancellation()
            let plan = try await adoptPrepared(
                prepared,
                origin: .transcodeRestart(PlaybackAdoptionOrigin.TranscodeRestart(
                    target: intent.position,
                    isQualitySwitch: isQualitySwitch,
                    selectedSubtitleSnapshot: selectedSubtitleSnapshot,
                    subtitleUrlFallback: externalSubtitleSnapshot,
                    recoveredEmbeddedSubtitleSelection: embeddedSubtitleSelectionSnapshot,
                    recoveredSecondarySubtitleId: selectedSecondarySubtitleSnapshot,
                    hasExplicitSubtitleChoice: explicitSubtitleChoiceSnapshot
                ))
            )
            return (prepared, plan, Self.identity(for: prepared))
        }
    }

    /// The `SessionIdentity` a prepared session publishes. Offline prepares
    /// carry no server session, no plan attempt and no negotiated output
    /// context, so they get the stable offline stand-in.
    static func identity(for prepared: PreparedPlayback) -> SessionIdentity {
        guard let protocolV3 = prepared.protocolV3 else {
            return SessionIdentity(
                serverSessionId: prepared.session.sessionId,
                playbackAttemptId: "legacy:\(prepared.session.sessionId)",
                planAttemptId: nil,
                planAttemptKey: nil,
                outputContextId: ""
            )
        }
        return SessionIdentity(
            serverSessionId: prepared.session.sessionId,
            playbackAttemptId: protocolV3.playbackAttemptId,
            planAttemptId: protocolV3.planAttemptId,
            planAttemptKey: protocolV3.planAttemptKey,
            outputContextId: protocolV3.outputContextId ?? ""
        )
    }

    /// Converting a playback error into a natural end is only safe when the
    /// stream really did run out. The position alone cannot tell the two
    /// apart, so the decision is corroborated: the source must not be in an
    /// outage (the failure is then a transport problem the recovery ladder
    /// owns) and the player must be out of runway (a failure with media still
    /// queued ahead is a mid-stream fault, not a drain). Without the
    /// corroboration the caller falls through to the normal ladder, which is
    /// also what makes `handleEndOfFile`'s premature branch reachable again —
    /// the old ratio arm made this predicate the exact negation of that check.
    static func shouldTreatPlaybackErrorAsNaturalEnd(
        duration: Double,
        currentTime: Double,
        bufferedAheadSeconds: Double,
        isSourceOutageActive: Bool
    ) -> Bool {
        guard duration.isFinite, duration > 0, currentTime.isFinite, currentTime > 0 else {
            return false
        }
        guard !isSourceOutageActive else { return false }
        if bufferedAheadSeconds.isFinite,
           bufferedAheadSeconds > Self.nearEndPlaybackErrorMaxBufferedAheadSeconds {
            return false
        }
        return duration - currentTime <= Self.nearEndPlaybackErrorThresholdSeconds
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
                let response = try await SiloAPI.shared.homeSections()
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
                let response = try await SiloAPI.shared.episodes(
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
            let detail = try await SiloAPI.shared.itemDetail(contentId: item.contentId)
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
        async let seasonsTask = SiloAPI.shared.seasons(seriesId: seriesId)
        async let currentEpisodesTask = SiloAPI.shared.episodes(
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
            let nextSeasonEpisodes = try await SiloAPI.shared.episodes(
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
        guard !hasEndedStream else { return }
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
        guard avPlayerBackend != nil else { return false }

        let shouldResumeAfterEnd = nextUpScreenVideoEnded || hasEndedStream
        nextUpAutoplayCancelled = true
        nextUpPromptDismissed = true
        showNextUpScreen = false
        nextUpScreenVideoEnded = false
        cancelNextUpCountdown()

        if shouldResumeAfterEnd,
           duration.isFinite,
           duration > 0,
           avPlayerBackend != nil {
            // Returning from the terminal postroll needs a real playable
            // position; resuming at exact EOF would immediately present the
            // postroll again. Replay a short tail of the current episode.
            // `.nextUpKeepWatching` is one of the two seek origins the reducer
            // lets out of the postroll latch.
            let target = max(0, duration - 10)
            let reloadsPlaybackPipeline = commitSeek(to: target, source: "keepWatching")
            if !reloadsPlaybackPipeline {
                send(.play)
            }
        } else if !isPlaying {
            send(.play)
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
        send(
            .load(
                request,
                origin: .autoplay,
                options: LoadOptions(
                    progressPosition: completionProgressPositionForCurrentItem(),
                    finalizeCurrentSession: true
                )
            )
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
        send(
            .load(
                request,
                origin: .userInitiated,
                options: LoadOptions(
                    progressPosition: completionProgressPositionForCurrentItem(),
                    finalizeCurrentSession: true
                )
            )
        )
    }

    private func completionProgressPositionForCurrentItem() -> Double {
        PlayerNextUpCompletionPolicy.progressPosition(
            isNextUpPresented: showNextUpScreen,
            hasReachedEndOfFile: hasEndedStream,
            currentTime: currentTime,
            duration: duration,
            promptSeconds: settings.nextUpPromptSeconds
        )
    }

    /// The SiloPlayer loopback plan the failed native-direct route can fall
    /// back to, or nil when nothing local can remux this source. The policy
    /// reads it as a precondition (`RecoveryContext.canBuildLoopbackFallback`);
    /// the executor below builds it again for the load it issues.
    private func makeNativeDirectLoopbackFallbackPlan() -> PlaybackExecutionPlan? {
        guard !isDisposed,
              let activeExecutionPlan,
              activeExecutionPlan.engine == .avPlayerNativeDirect else {
            return nil
        }
        let startTime = currentTime.isFinite && currentTime > 0
            ? currentTime
            : activeExecutionPlan.startMode.seconds
        return makeLoopbackFallbackPlan(
            from: activeExecutionPlan,
            requirements: activeExecutionPlan.requirements,
            startTime: startTime,
            traceToken: "fallback_silo_loopback_after_native_direct",
            reason: "native_direct_avplayer_failed_silo_fallback"
        )
    }

    /// `attemptNativeDirectRouteRecovery`'s execution half: hand the failed
    /// native-direct source to the local loopback remuxer. Which route may fall
    /// back, how often, and whether a loopback plan exists at all are
    /// `RecoveryPolicy.decideEngineFailed`'s rung 9.
    @MainActor
    private func performNativeDirectLoopbackFallback(failure: PlaybackFailure?) {
        guard let fallbackPlan = makeNativeDirectLoopbackFallbackPlan() else { return }
        Self.logger.warning(
            "[CMP-ROUTE] native-direct AVPlayer failed; retrying route=\(fallbackPlan.implementationRoute, privacy: .public) error=\(failure?.legacyMessage ?? "", privacy: .public)"
        )
        let preferredAudioTrackIndex = trackSelection.resolvedAudioTrackIndexForResume()
        let preferredSubtitleTrackIndex = trackSelection.resolvedSubtitleTrackIndexForResume()
        let preferredSidecarSubtitleTrackId = trackSelection.resolvedSidecarSubtitleTrackIdForResume()
        let watchDetailSnapshot = currentWatchDetail
        let selectedVersionSnapshot = currentSelectedVersion
        let chapterSnapshot = serverProvidedChapters
        let trackSnapshot = trackSelection.snapshotForRecovery()
        resetPublishedLoadState(
            preferredAudioTrackIndex: preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: preferredSubtitleTrackIndex,
            preferredSidecarSubtitleTrackId: preferredSidecarSubtitleTrackId
        )
        currentWatchDetail = watchDetailSnapshot
        currentSelectedVersion = selectedVersionSnapshot
        serverProvidedChapters = chapterSnapshot
        trackSelection.restoreAfterRecovery(trackSnapshot)
        engineSession?.disposeEngineOnly(reason: "native_direct_fallback")
        logExecutionPlan(fallbackPlan)
        // A replacement item inside the same load: the server session is
        // untouched, only the local execution route changes.
        pendingExecutionPlan = fallbackPlan
        guard let controlPlane else { return }
        Task { await controlPlane.reloadEngineInPlace() }
    }

    /// Retarget a route onto server HLS. Every remaining engine is
    /// AVPlayer-backed, so "fall back" now means renegotiating the session with
    /// the server rather than swapping in another local decoder.
    ///
    /// Returns false when there is nothing to replan against or a replan is
    /// already running — the precondition `loadStream`'s direct-unplayable
    /// branch still owns, and the same one `RecoveryPolicy` carries as
    /// `hasWatchDetail` / `isReplanInFlight` for the two failure-ladder rungs.
    @discardableResult
    private func requestServerHLSReplan(
        classification: String,
        message: String,
        trace: String,
        failureToken: String
    ) -> Bool {
        guard currentWatchDetail != nil else { return false }
        Self.logger.warning(
            "[CMP-ROUTE] \(trace, privacy: .public); requesting a server HLS replan failureToken=\(failureToken, privacy: .public)"
        )
        requestReplan(
            ReplanIntent(
                kind: .serverReplan,
                position: currentTime,
                classification: classification,
                message: message
            )
        )
        return true
    }

    @MainActor
    private func performServerHLSRouteFallback(
        classification: String,
        failure: PlaybackFailure?
    ) {
        requestServerHLSReplan(
            classification: classification,
            message: failure?.legacyMessage ?? "",
            trace: classification == "silo_loopback_failed"
                ? "fallback_hls_after_silo"
                : "native_direct_blocked_hls_fallback",
            failureToken: failure?.stableToken ?? "-"
        )
    }

    /// Build a SiloPlayer loopback plan that reuses the failed route's source
    /// stream. Returns nil when the item cannot be locally remuxed (no
    /// resolved version, or no loopback session spec) — the caller then falls
    /// through to the server HLS rung.
    private func makeLoopbackFallbackPlan(
        from activeExecutionPlan: PlaybackExecutionPlan,
        requirements: PlaybackRouteRequirements,
        startTime: Double,
        traceToken: String,
        reason: String
    ) -> PlaybackExecutionPlan? {
        guard let version = currentSelectedVersion else { return nil }
        let videoMode: LoopbackSessionSpec.VideoMode = isH264Video(version)
            ? .passthroughH264
            : .passthroughHEVC
        guard let loopbackSession = makeFallbackLoopbackSession(
            streamRequest: activeExecutionPlan.sourceStreamRequest,
            videoMode: videoMode,
            videoRange: ApplePlaybackRoutePlanner.videoRange(for: videoMode, source: version),
            sourceStartTimeSeconds: startTime
        ) else {
            return nil
        }
        return PlaybackExecutionPlan(
            delivery: .direct,
            engine: .siloPlayerLoopback,
            startMode: .absolutePosition(startTime),
            streamRequest: activeExecutionPlan.sourceStreamRequest,
            sourceStreamRequest: activeExecutionPlan.sourceStreamRequest,
            loopbackSession: loopbackSession,
            requirements: requirements,
            parityBlockers: [],
            decisionTrace: activeExecutionPlan.decisionTrace + [traceToken],
            degradationWarnings: PlaybackEngineKind.siloPlayerLoopback.routeCapabilities
                .degradationNotes(for: requirements),
            reason: reason,
            playbackSessionId: activeExecutionPlan.playbackSessionId,
            wireDelivery: activeExecutionPlan.wireDelivery,
            serverFeatures: activeExecutionPlan.serverFeatures,
            sourceMetadata: activeExecutionPlan.sourceMetadata,
            normalizationSummary: ApplePlaybackRoutePlanner.normalizationSummary(
                engine: .siloPlayerLoopback,
                delivery: .direct,
                loopbackSession: loopbackSession,
                sourceMetadata: activeExecutionPlan.sourceMetadata
            )
        )
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
                pendingAudioFfIndex: trackSelection.pendingAudioFfIndex,
                preferredAudioTrackIndex: trackSelection.resolvedAudioTrackIndexForResume(),
                selectedPrimarySubtitleTrackId: selectedSubtitleId,
                selectedSecondarySubtitleTrackId: selectedSecondarySubtitleId,
                dolbyVisionPolicy: settings.dolbyVisionPolicySnapshot
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
            "delivery=\(plan.delivery.name) wireDelivery=\(plan.wireDelivery ?? "unknown") " +
            "routeFamily=\(plan.routeFamily.diagnosticsLabel) " +
            "implementationRoute=\(plan.implementationRoute) backend=\(plan.engine.label) " +
            "appLabel=\(plan.appPlaybackLabel) " +
            "requirements=\(requirements) " +
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

    /// True when the resolved plan cannot be handed to a backend as-is.
    ///
    /// Removing the compatibility backend left one reachable gap: the direct
    /// branch of `ApplePlaybackRoutePlanner` can fall all the way to
    /// `.avPlayerHLS` for a session the server is still delivering as a direct
    /// source (theora/ogv, DVB subtitles — anything neither native-direct nor
    /// locally normalizable). `plan.streamRequest.url` is then the original
    /// file, not a manifest, and `loadRemoteHLS` would hand AVPlayer something
    /// it cannot parse. The load path asks the server to replan as
    /// remux/transcode instead.
    static func needsServerReplanBeforeLoad(plan: PlaybackExecutionPlan) -> Bool {
        plan.engine == .avPlayerHLS && plan.delivery == .direct
    }

    /// Origin-specific inputs for `adoptPreparedPlayback`.
    ///
    /// The three pipelines that adopt a prepared playback (`beginFreshLoad`,
    /// `attemptProtocolV3Replan`, `restartCurrentTranscodeHLS`) publish the
    /// same session/track/quality state and then run the identical
    /// `makeStreamRequest` → `makeExecutionPlan` → `logExecutionPlan` →
    /// `loadStream` tail. Everything they genuinely disagree about is spelled
    /// out here rather than being silently unified.
    enum PlaybackAdoptionOrigin {
        /// A brand-new item. Owns the fields nothing else republishes — title,
        /// metadata, chapters, marker ranges, the subtitle-policy snapshot —
        /// and binds realtime unconditionally because there is no prior
        /// session to keep.
        case freshLoad(FreshLoad)
        /// An in-place V3 plan replacement (error recovery, output-route
        /// change, quality-switch completion). The only origin that keeps the
        /// outgoing backend alive across the reload.
        case protocolV3Replan(Replan)
        /// An in-place stream restart for a seek reanchor or a quality change.
        case transcodeRestart(TranscodeRestart)

        struct FreshLoad {
            /// Offline playback has no server session: no realtime channel, no
            /// catalog artwork, no Next Up lookup.
            let isOffline: Bool
            /// `resumePositionOverride`; feeds `timelineOffset(for:session:requestedStart:)`.
            let requestedStart: Double?
        }

        struct Replan {
            /// Subtitle selection captured before the replan started, used to
            /// re-establish a sidecar / server-rendered choice afterwards.
            let selectedSubtitleSnapshot: Int64?
        }

        struct TranscodeRestart {
            let target: Double
            let isQualitySwitch: Bool
            let selectedSubtitleSnapshot: Int64?
            /// The restart keeps the previous sidecar list when the replacement
            /// session omits one; the other two origins reset to empty.
            let subtitleUrlFallback: [SubtitleUrl]
            let recoveredEmbeddedSubtitleSelection: TrackSelectionCoordinator.TrackSelectionSnapshot?
            let recoveredSecondarySubtitleId: Int64?
            let hasExplicitSubtitleChoice: Bool
        }

        var subtitleUrlFallback: [SubtitleUrl] {
            if case .transcodeRestart(let restart) = self { return restart.subtitleUrlFallback }
            return []
        }

        /// Only a live protocol replan has a known-good outgoing backend worth
        /// preserving across the reload.
        var reusesActiveEngine: Bool {
            if case .protocolV3Replan = self { return true }
            return false
        }

        var invalidStreamURLMessage: String {
            if case .protocolV3Replan = self {
                return "The replacement V3 plan returned an invalid stream URL."
            }
            return "Invalid stream URL"
        }
    }

    /// `adoptPreparedPlayback`'s shell half: everything the prepared session
    /// changes about the player that is *not* control-plane state, plus the
    /// execution plan it resolves to.
    ///
    /// The control-plane half — the playhead, the duration, the quality label,
    /// the replay-request adopt and the engine load — is the reducer's, driven
    /// by the `SessionEvent` this plan travels on. Plan-execution reporting is
    /// the actor's `Effect.reportPlanExecutionStarted`, emitted in the same
    /// position this method used to `await` it: before the engine load.
    @MainActor
    private func adoptPrepared(
        _ prepared: PreparedPlayback,
        origin: PlaybackAdoptionOrigin,
        retryingUnplayableDirect: Bool = true
    ) async throws -> ExecutablePlan {
        let session = prepared.session
        let previousSessionId = currentServerSessionId

        // Origin-specific state that has to land before the shared publish.
        switch origin {
        case .freshLoad:
            autoSkippedIntroKey = nil
            autoSkippedCreditsKey = nil
            autoSkipIntroCancelledKey = nil
            cancelPendingIntroAutoSkip()
            // The transient-failure budget lives in `RecoveryContext` and is
            // load-scoped, so the replacement session starts with a full one.
            engineSession?.driver.noteBackgroundRenewalSucceeded()

            trackSelection.adoptFreshLoadSubtitlePolicy(watchDetail: prepared.watchDetail)

            title = prepared.displayTitle
            metadata = prepared.playerMetadata()
        case .protocolV3Replan:
            break
        case .transcodeRestart(let restart):
            autoSkippedIntroKey = nil
            autoSkippedCreditsKey = nil
            autoSkipIntroCancelledKey = nil
            cancelPendingIntroAutoSkip()
            if restart.isQualitySwitch {
                // Contract note (d): the quality restart's overlay is raised at
                // the *adopt*, not when the replan was requested.
                isLoading = true
                setBuffering(false, cause: "quality_switch")
                // Engine only — the replacement load stashes the live proxy's
                // cache on its way through `installEngine`.
                engineSession?.disposeEngineOnly(reason: "quality_switch")
            }
        }

        currentWatchDetail = prepared.watchDetail
        currentSelectedVersion = prepared.selectedVersion
        activePreparedProtocolV3 = prepared.protocolV3
        adoptProtocolV3RenewalIntent(from: prepared)
        trackSelection.adopt(prepared: prepared, origin: origin)

        qualityOptions = ApplePlaybackQuality.playbackOptions(
            serverQualities: prepared.protocolV3?.plan.availableQualities ?? [],
            fallbackVersion: prepared.selectedVersion
        )

        switch origin {
        case .freshLoad(let fresh):
            qualitySwitchError = nil
            serverProvidedChapters = chapterInfoList(from: prepared.selectedVersion)
            applyMarkerRanges(
                intro: prepared.selectedVersion.intro ?? prepared.watchDetail.intro,
                credits: prepared.selectedVersion.credits ?? prepared.watchDetail.credits
            )
            // Artwork and Next Up are catalog fetches; the offline path already
            // published its cached poster and has no server to resolve a next
            // episode against.
            if !fresh.isOffline {
                pushNowPlayingArtwork(contentId: prepared.watchDetail.contentId)
                loadNextUpCandidate(for: prepared.watchDetail)
                loadNextUpOnDeckItems(for: prepared.watchDetail)
            }
        case .protocolV3Replan:
            break
        case .transcodeRestart:
            qualitySwitchError = nil
        }

        switch origin {
        case .freshLoad(let fresh):
            // The realtime channel is a server websocket keyed by a real
            // session id; the synthetic offline session has neither.
            if !fresh.isOffline {
                await realtimeClient.bind(sessionId: session.sessionId)
                try Task.checkCancellation()
            }
        case .protocolV3Replan, .transcodeRestart:
            // Rebinding on a changed session id used to be replan-only:
            // `restartCurrentTranscodeHLS` left the socket bound to the
            // retired session and went deaf to server events. A new session id
            // always means a new channel.
            if previousSessionId != session.sessionId {
                await realtimeClient.unbind()
                await realtimeClient.bind(sessionId: session.sessionId)
            }
        }

        guard let streamRequest = await makeStreamRequest(
            session: session,
            additionalHeaders: prepared.protocolV3?.plan.stream.headers ?? [:]
        ) else {
            throw PlaybackAdoptionFailure(message: origin.invalidStreamURLMessage)
        }
        resolvedServerUrl = streamRequest.serverUrl

        let plan = try makeExecutionPlan(prepared: prepared, streamRequest: streamRequest)
        currentDeliveryStrategy = plan.delivery
        switch origin {
        case .freshLoad(let fresh):
            playbackTimelineOffset = timelineOffset(
                for: plan,
                session: session,
                requestedStart: fresh.requestedStart
            )
        case .protocolV3Replan:
            // Preserved drift: the replan path trusts the session's own offset
            // instead of recomputing it from the plan.
            playbackTimelineOffset = session.timelineOffsetSeconds
        case .transcodeRestart(let restart):
            playbackTimelineOffset = timelineOffset(
                for: plan,
                session: session,
                requestedStart: restart.target
            )
        }
        logExecutionPlan(plan)

        switch origin {
        case .freshLoad:
            Self.logger.info("Play method: \(session.playMethod, privacy: .public)")
            // Keep the console breadcrumb useful without logging the signed
            // stream URL or any server identity.
            Self.logger.info(
                "[CMP] streamPrepared playMethod=\(session.playMethod, privacy: .public) startTime=\(plan.startMode.seconds, privacy: .public)"
            )
        case .protocolV3Replan:
            break
        case .transcodeRestart(let restart):
            Self.logger.info(
                "[CMP-SEEK] in-place transcode restart loaded target=\(restart.target, privacy: .public)"
            )
            // Preserved drift: the in-place restart has never reported plan
            // execution to the server.
        }

        // The one plan the engine must never be handed. Legacy discovered it at
        // the top of `loadStream` and asked the server for a different one;
        // asking here keeps the same bridge call with the same classification
        // and message, one `await` earlier, and out of the state machine — a
        // plan that was never executable never becomes a load.
        if offlinePlaybackContext == nil, Self.needsServerReplanBeforeLoad(plan: plan) {
            let message = "This title can't be played directly on this device."
            Self.logger.warning(
                "[CMP-ROUTE] direct delivery resolved to the server HLS route; requesting a server transcode reason=\(plan.reason, privacy: .public)"
            )
            // One attempt only: a direct source the server refuses to re-plan
            // terminates instead of looping.
            guard retryingUnplayableDirect, let watchDetail = currentWatchDetail else {
                throw PlaybackAdoptionFailure(message: message)
            }
            guard let replanned = try await sessionBridge.replanProtocolV3(
                watchDetail: watchDetail,
                position: currentTime,
                classification: "direct_source_unplayable",
                message: message,
                audioTrackIndex: trackSelection.resolvedAudioTrackIndexForResume(),
                subtitleTrackIndex: trackSelection.resolvedProtocolV3SubtitleIndexForResume()
            ) else {
                throw PlaybackAdoptionFailure(message: message)
            }
            try Task.checkCancellation()
            return try await adoptPrepared(
                replanned,
                origin: origin,
                retryingUnplayableDirect: false
            )
        }

        // The engine install needs the *full* plan (the source proxy rewrites
        // its URLs and the loopback spec travels on it); `ExecutablePlan` keeps
        // only what the control plane decides with. The slot is the hand-off
        // between the two halves of one adopt.
        pendingExecutionPlan = plan
        return try ExecutablePlan(plan, request: plan.streamRequest)
    }

    /// A prepared session that cannot be executed. It carries the exact message
    /// the legacy terminal path published, so the error wall reads the same.
    struct PlaybackAdoptionFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `AVPlayerBackend` is not `Sendable`, but tearing one down off the main
    /// thread is safe and deliberate: a slow `dispose()` must not stall the
    /// replacement load. The box carries the reference across the hop.
    private struct DisposableBackend: @unchecked Sendable {
        let backend: AVPlayerBackend
    }

    /// `loadStream`, driven by `Effect.loadEngine`.
    ///
    /// Returns the new session's event stream for the actor to consume, or
    /// `nil` plus a failure message when the source proxy or the plan could not
    /// be executed.
    @MainActor
    func installEngine(
        plan executable: ExecutablePlan,
        loadID: LoadID,
        reuseEngine: Bool,
        adoptingOutage outage: RecoveryContext.OutageState?
    ) async -> (events: AsyncStream<EngineEvent>?, failure: String?) {
        guard let plan = pendingExecutionPlan else {
            return (nil, "The playback plan was unavailable.")
        }
        pendingLoadID = loadID
        // Stop presentation while the replacement proxy is prepared, but retain
        // the backend. If the implementation route is unchanged, the replacement
        // session adopts that backend in place so tvOS can preserve identical
        // display criteria and the active audio session.
        avPlayerBackend?.pause()
        // Re-arm the authoritative V3 intent for the replacement stream. A final
        // track callback from the outgoing session may have consumed the first
        // copy between replan adoption and this point; that session's stream is
        // about to end, so it cannot consume this one.
        trackSelection.rearmAdoptedProtocolV3TrackIntent()
        stashSourceCacheHandoff()
        engineSession?.stopTransport()

        let outgoing = engineSession
        let prepared: PlaybackEngineSession.SourcePreparation
        do {
            prepared = try await prepareSource(for: plan, loadID: loadID)
        } catch {
            guard loadID == pendingLoadID, !isDisposed else { return (nil, nil) }
            return (
                nil,
                "SiloPlayer local source proxy failed to start: \(error.localizedDescription)"
            )
        }
        guard loadID == pendingLoadID, !Task.isCancelled, !isDisposed else {
            prepared.proxy?.stop()
            return (nil, nil)
        }
        let loadPlan = prepared.plan
        activeExecutionPlan = loadPlan
        let installable: ExecutablePlan
        do {
            installable = try ExecutablePlan(loadPlan, request: loadPlan.streamRequest)
        } catch {
            prepared.proxy?.stop()
            return (nil, error.localizedDescription)
        }
        _ = executable
        // Only a live protocol replan has a known-good outgoing backend to
        // preserve, and only when the implementation route is unchanged: a route
        // change has to renegotiate the audio session and the display criteria
        // on a fresh engine. Fresh loads and recovery paths already disposed
        // theirs, so they must build a new one even when the route kind matches.
        let reusable = reuseEngine
            && outgoing?.surfaceBackend != nil
            && activeRouteKind == loadPlan.engine
            ? outgoing : nil
        if reusable != nil {
            Self.logger.info(
                "[CMP-ENGINE] reusing kind=\(loadPlan.engine.label, privacy: .public) family=\(loadPlan.engine.routeFamily.diagnosticsLabel, privacy: .public) load=\(loadID.raw.uuidString, privacy: .public)"
            )
        } else {
            outgoing?.dispose(reason: "replaced")
            Self.logger.info(
                "[CMP-ENGINE] installed kind=\(loadPlan.engine.label, privacy: .public) family=\(loadPlan.engine.routeFamily.diagnosticsLabel, privacy: .public) load=\(loadID.raw.uuidString, privacy: .public)"
            )
        }
        let session = PlaybackEngineSession(
            loadID: loadID,
            plan: installable,
            backendFactory: { AVPlayerBackend() },
            reusing: reusable,
            transport: prepared.proxy
        )
        // A hold may only be adopted together with its releaser: the actor holds
        // the ride-through across a route change, so the session that replaces
        // the retired backend inherits both the outage state and the
        // `origin_outage` suspension that ends it.
        if let outage, reusable == nil {
            session.driver.adoptOutageRideThrough(outage)
            session.driver.setSuspended(
                true,
                reason: RecoveryDriver.originOutageSuspensionReason
            )
        }
        engineSession = session
        activeRouteKind = loadPlan.engine
        sourceProxyFileId = prepared.proxy != nil ? currentSelectedVersion?.fileId : nil
        prepared.proxy?.setPlaybackRate(settings.playbackSpeed)
        session.backend.setServerChapters(serverProvidedChapters)
        let backendTimelineOffset = avPlayerTimelineOffset(for: loadPlan)
        if loadPlan.engine == .siloPlayerLoopback {
            playbackTimelineOffset = backendTimelineOffset
        }
        session.backend.setMediaTimelineOffset(backendTimelineOffset)
        #if os(iOS)
        supportsExternalPlayback = session.backend.isExternalPlaybackAllowed
        session.backend.isPictureInPictureActiveProvider = {
            PictureInPictureCoordinator.shared.isActive
        }
        PictureInPictureCoordinator.shared.bindLifecycle(owner: self) { [weak self] in
            guard let self, !self.isDisposed else { return }
            self.handlePictureInPictureEngagementEnded()
        }
        #endif
        let events = session.events
        session.start(startSeconds: installable.startSeconds)
        // Re-applies the canonical user volume/mute after a swap (quality
        // switch, loopback fallback, route retarget): a fresh backend comes up
        // at full volume, so a remote-set level would otherwise be lost.
        session.backend.setUserVolume(userVolume)
        session.backend.setUserMuted(userMuted)
        return (events, nil)
    }

    /// Tear one load's engine down. `engineOnly` is the visible server-outage
    /// recovery, which keeps the session alive as that load's recovery owner
    /// while it waits the server out.
    @MainActor
    func teardownEngine(
        loadID: LoadID,
        sourceCache: SourceCacheDisposition,
        engineOnly: Bool
    ) {
        switch sourceCache {
        case .stash:
            stashSourceCacheHandoff()
        case .discard:
            discardSourceCacheHandoff()
        case .retainProxy:
            break
        }
        guard let session = engineSession, session.loadID == loadID else { return }
        if engineOnly {
            session.stopTransport()
            session.disposeEngineOnly(reason: "server_outage")
            return
        }
        switch sourceCache {
        case .retainProxy:
            // The tvOS background suspend disposes the engine and deliberately
            // leaves the proxy — and its cache — running for the resume.
            session.dispose(reason: "background_suspend", retainingTransport: true)
        case .stash, .discard:
            // Tearing an `AVPlayerBackend` down off the main thread is safe and
            // deliberate: a slow `dispose()` must not stall the replacement
            // load behind it.
            session.stopTransport()
            let disposable = session.detachBackendForDisposal()
            Self.logger.info("[CMP-ENGINE] session disposed reason=replaced")
            if let disposable {
                let box = DisposableBackend(backend: disposable)
                DispatchQueue.global(qos: .userInitiated).async { box.backend.dispose() }
            }
        }
        engineSession = nil
        activeExecutionPlan = nil
    }

    /// File id the live proxy was built for — the stash metadata.
    /// (`currentSelectedVersion` is already reset by the time some teardown
    /// paths stop the proxy, so the association must be recorded at install.)
    private var sourceProxyFileId: Int?

    /// Retain the outgoing proxy's cache for possible adoption by the next
    /// same-file proxy. Called immediately before the proxy is stopped on
    /// non-terminal teardown paths. The slot lives here rather than on the
    /// engine session because it deliberately outlives one.
    private func stashSourceCacheHandoff() {
        guard let handoff = PlaybackEngineSession.stashSourceCache(
            from: sourceProxy,
            fileId: sourceProxyFileId
        ) else { return }
        sourceCacheHandoff = handoff
    }

    private func discardSourceCacheHandoff() {
        if sourceCacheHandoff != nil {
            Self.logger.info("[CMP-SOURCE-CACHE] handoff released")
        }
        sourceCacheHandoff = nil
    }

    /// Builds (or declines to build) the source proxy for a plan, resolving the
    /// handoff slot against it. A handoff lives for exactly one load attempt,
    /// so the slot is emptied either way.
    private func prepareSource(
        for plan: PlaybackExecutionPlan,
        loadID: LoadID
    ) async throws -> PlaybackEngineSession.SourcePreparation {
        let handoff = sourceCacheHandoff
        if PlaybackEngineSession.usesSourceProxy(for: plan) {
            sourceCacheHandoff = nil
        } else {
            // No adopter on this load — release it rather than hold its disk
            // spans for the rest of playback.
            discardSourceCacheHandoff()
        }
        return try await PlaybackEngineSession.prepareSource(
            for: plan,
            handoff: handoff,
            inputs: PlaybackEngineSession.SourceInputs(
                fileId: currentSelectedVersion?.fileId,
                expectedFileSize: currentSelectedVersion?.fileSize,
                diskSpillRequested: PlayerSettings.shared.seekCacheEnabled,
                nominalBitrateBps: currentSelectedVersion?.bitrate
                    .flatMap { $0 > 0 ? Double($0) * 1_000 : nil }
            ),
            onPlaybackSessionMissing: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let session = self.engineSession else { return }
                    self.refreshRecoveryContext(session: session)
                    session.observe(.sessionMissing(source: .proxy404))
                }
            },
            onPlaybackSourceInterrupted: { [weak self] reason in
                Task { @MainActor [weak self] in
                    // `attemptServerOutageRecovery`'s `!hasReachedEndOfFile`
                    // gate (PVM:4390) is a load-state gate, not a recovery
                    // decision: after end-of-file the load is terminal and the
                    // engine reports nothing into recovery, so the observation
                    // is dropped here rather than latching the policy's
                    // single-flight against a recovery that will never run.
                    guard let self, !self.isDisposed, !self.hasEndedStream,
                          let session = self.engineSession else { return }
                    self.refreshRecoveryContext(session: session)
                    session.observe(.sourceInterrupted(reason: reason))
                }
            },
            onOriginOutageChanged: { [weak self] active in
                Task { @MainActor [weak self] in
                    guard let self, !self.isDisposed, let session = self.engineSession else { return }
                    self.refreshRecoveryContext(session: session)
                    // The runway gate reads the shell's buffering flag, exactly
                    // as `handleOriginOutageChanged(true)`'s `if isBuffering`
                    // did (wave-1B obligation (c)).
                    session.reportOriginOutage(active, isBuffering: self.isBuffering)
                }
            }
        )
    }

    private func timelineOffset(
        for plan: PlaybackExecutionPlan,
        session: PlaybackSessionResponse,
        requestedStart: Double?
    ) -> Double {
        // The static VOD playlist's requested start is an in-item seek on the
        // plan's stable playlist axis, not the playlist origin. Treating it as
        // the origin would double the reported position after a mid-playback
        // replan; start at zero and let the backend publish the resolved
        // segment-plan anchor before item creation.
        if plan.engine == .siloPlayerLoopback {
            return 0
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

    private func avPlayerTimelineOffset(for plan: PlaybackExecutionPlan) -> Double {
        switch plan.engine {
        case .siloPlayerLoopback:
            // See `timelineOffset(for:session:requestedStart:)`: the static
            // VOD item always starts on the plan's own axis.
            return 0
        case .avPlayerHLS:
            return playbackTimelineOffset
        case .avPlayerNativeDirect:
            return 0
        }
    }

    /// A server transcode is exposed as a growing HLS playlist while FFmpeg is
    /// producing it. AVPlayer reports the currently published playlist length
    /// as the item duration, but that is not the VOD duration and can grow past
    /// the probed media length. Keep a known server duration authoritative;
    /// backend duration remains the fallback when the server has no value.
    static func shouldAdoptBackendDuration(
        _ reportedDuration: Double,
        currentDuration: Double,
        delivery: PlaybackDeliveryStrategy
    ) -> Bool {
        guard reportedDuration.isFinite, reportedDuration > 0 else { return false }
        guard currentDuration.isFinite, currentDuration > 0 else { return true }
        if case .transcode = delivery {
            return false
        }
        return reportedDuration >= currentDuration
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

    /// Apply every persisted player preference. Called once per loaded file
    /// (from `onFileLoaded`) and after full settings refreshes. Targeted
    /// mutations should use narrower backend calls so unrelated knobs do not
    /// get re-applied during playback.
    func applySettingsToPlayer() {
        guard let avPlayerBackend else { return }
        avPlayerBackend.setSpeed(settings.playbackSpeed)
        avPlayerBackend.setSubtitleDelay(Double(settings.subtitleSyncMs) / 1000.0)
        avPlayerBackend.applySubtitleAppearance(settings.effectiveSubtitleAppearance)
    }

    private func applySubtitleAppearanceToPlayer() {
        avPlayerBackend?.applySubtitleAppearance(settings.effectiveSubtitleAppearance)
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
    func mutateSubtitleAppearance(_ mutate: (inout SubtitleAppearance) -> Void) {
        var next = settings.subtitleAppearance
        mutate(&next)
        Task { await setSubtitleAppearance(next) }
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
        trackSelection.setMatchesSystemAppearance(enabled)
    }

    func setPlaybackSpeed(_ rate: Double) {
        settings.setPlaybackSpeed(rate)
        avPlayerBackend?.setSpeed(settings.playbackSpeed)
        sourceProxy?.setPlaybackRate(settings.playbackSpeed)
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
        avPlayerBackend?.setSpeed(rate)
    }

    /// Always restores the configured speed, even if playback paused during
    /// the hold: backends don't start a paused clock on `setSpeed`, and
    /// leaving the hold rate behind would make the next play resume at 2×.
    func endHoldFastForward() {
        guard isHoldFastForwarding else { return }
        isHoldFastForwarding = false
        avPlayerBackend?.setSpeed(settings.playbackSpeed)
    }

    /// Gravity reaches the surface declaratively through
    /// `AVPlayerSurface(backend:videoGravity:)`, so persisting the preference
    /// is the whole job here.
    func setVideoGravity(_ gravity: VideoGravity) {
        settings.setVideoGravity(gravity)
    }

    func setSubtitleSyncMilliseconds(_ milliseconds: Int) {
        settings.setSubtitleSyncMs(milliseconds)
        guard backendCapabilities.supportsSubtitleDelay else { return }
        avPlayerBackend?.setSubtitleDelay(Double(settings.subtitleSyncMs) / 1000.0)
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
                detail = try await SiloAPI.shared.itemDetail(contentId: contentId)
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
    /// End of stream, presentation half. The postroll latch, the pause, the
    /// playhead clamp, the overlay and the buffering capsule are the reducer's
    /// `endOfFile` arm; what is left is the premature-EOF classification, the
    /// terminal breadcrumb, the Now Playing push and the Next Up hand-off.
    @MainActor
    private func handleEndOfFile() {
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
            showNotice(
                title: "Connection lost",
                message: "Lost connection to the server before the episode finished.",
                tone: .warning,
                duration: 6
            )
        }

        #if os(iOS) || os(tvOS)
        // Terminal outcome #2 of 2. A premature EOF is a failure the user
        // sees as "it just stopped", so it must not be filed as a clean
        // finish — the `reason` token is the only thing separating the two in
        // a report, since both arrive on this same path.
        DiagTrace.breadcrumb(
            .essential,
            level: isPremature ? .warning : .info,
            category: .playback,
            tag: "Player",
            message: "playback reached end of stream",
            attrs: [
                "reason": .string(isPremature ? "premature_source_end" : "natural_end"),
                "play_method": .string(activeRouteKind.label),
                "position_ms": .int(
                    PlaybackSessionBridge.diagnosticsPositionMilliseconds(observedPosition)
                ),
            ]
        )
        #endif

        hideControlsTask?.cancel()
        hideControlsTask = nil
        showControls = true
        nowPlaying.update(
            title: title,
            duration: duration,
            position: currentTime,
            isPlaying: false
        )

        // Natural end of an offline download: latch the local watched state
        // immediately (not just at close) so retention/reclaim see it even
        // if the process dies before `cleanup()` runs.
        if !isPremature, let offline = offlinePlaybackContext {
            recordOfflineProgress(
                context: offline,
                position: currentTime,
                markCompleted: true
            )
        }

        beginNextUpPostroll(videoEnded: true)
    }

    private func attachNowPlayingIfNeeded() {
        // Attach Now Playing on first load. Idempotent — subsequent loads
        // just reuse the same controller; we tear down in `cleanup()`.
        // Handlers route through `avPlayerBackend` so later route switches keep
        // driving remote commands against the current backend without a
        // re-attach step.
        nowPlaying.attach(handlers: NowPlayingController.Handlers(
            play:        { [weak self] in self?.send(.play) },
            pause:       { [weak self] in self?.send(.pause) },
            isPaused:    { [weak self] in
                guard let self else { return true }
                return self.hasEndedStream || !self.isPlaying
            },
            currentTime: { [weak self] in self?.currentTime ?? 0 },
            seek:        { [weak self] t in
                self?.send(.seek(targetSeconds: t, origin: .user))
            }
        ))
    }

    /// The view-local half of a fresh load. `isLoading`/`error` and every
    /// control-plane projection are published by the reducer's own `beginLoad`.
    private func resetPublishedLoadState(
        preferredAudioTrackIndex: Int?,
        preferredSubtitleTrackIndex: Int?,
        preferredSidecarSubtitleTrackId: Int64?,
        preferredProtocolV3SubtitleIndex: Int? = nil
    ) {
        // Drops the notice/auto-hide/seek-debounce timers that belonged to the
        // outgoing stream. `tearDownHoldSeek` still runs for its UI state.
        tasks.cancelAll(in: .interaction)
        activeNotice = nil
        remoteDismissToken = nil
        tearDownHoldSeek()
        isScrubbing = false
        scrubPreviewTime = currentTime
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
        trackSelection.resetForLoad(
            preferredAudioTrackIndex: preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: preferredSubtitleTrackIndex,
            preferredSidecarSubtitleTrackId: preferredSidecarSubtitleTrackId,
            preferredProtocolV3SubtitleIndex: preferredProtocolV3SubtitleIndex
        )
        chapters = []
        introRange = nil
        creditsRange = nil
        cancelPendingIntroAutoSkip()
        qualityOptions = [ApplePlaybackQuality.auto]
        qualitySwitchError = nil
        serverProvidedChapters = []
        currentWatchDetail = nil
        currentSelectedVersion = nil
        activePreparedProtocolV3 = nil
        autoSkippedIntroKey = nil
        autoSkippedCreditsKey = nil
        autoSkipIntroCancelledKey = nil
    }

    private func adoptProtocolV3RenewalIntent(from prepared: PreparedPlayback) {
        guard let protocolV3 = prepared.protocolV3,
              let lastLoadRequest,
              lastLoadRequest.offlineDownloadId == nil else {
            return
        }
        let adopted = lastLoadRequest.adoptingProtocolV3Intent(
            plan: protocolV3.plan,
            selectedVersion: prepared.selectedVersion,
            activeQualityId: prepared.activeQualityId
        )
        self.lastLoadRequest = adopted

        trackSelection.adoptProtocolV3RenewalIntent(
            plan: protocolV3.plan,
            request: adopted
        )
    }

    /// `beginFreshLoad`'s task body, driven by `Effect.startSession`.
    ///
    /// The prologue that used to sit in front of it — the timer cancels, the
    /// outgoing progress report or finalize, and the outgoing engine dispose —
    /// is the reducer's `beginLoad`, emitted as effects the actor already ran
    /// by the time this is entered.
    @MainActor
    func prepareFreshSession(
        request: LoadRequest,
        options: LoadOptions,
        origin: LoadOrigin
    ) async throws -> (prepared: PreparedPlayback, plan: ExecutablePlan, identity: SessionIdentity) {
        #if os(tvOS)
        PosterImageCache.trimDecodedMemory()
        #endif
        lastLoadRequest = request
        offlinePlaybackContext = nil
        contentIdsNeedingDetailRefresh.insert(request.contentId)
        cancelNextUpFlow()
        attachNowPlayingIfNeeded()
        resetPublishedLoadState(
            preferredAudioTrackIndex: request.preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: request.preferredSubtitleTrackIndex,
            preferredSidecarSubtitleTrackId: request.preferredSidecarSubtitleTrackId,
            preferredProtocolV3SubtitleIndex: request.preferredProtocolV3SubtitleIndex
        )

        await realtimeClient.unbind()
        try Task.checkCancellation()

        // The init kicked off `settingsRefreshTask` to fetch the server's
        // effective device settings before playback starts. Awaiting it here
        // (instead of issuing a fresh `refreshFromServer`) avoids the race that
        // produced two back-to-back `/settings/effective` round-trips on every
        // play — the init request is already in flight and its result is what we
        // want anyway.
        await settingsRefreshTask?.value
        try Task.checkCancellation()

        let prepared: PreparedPlayback
        if let offlineDownloadId = request.offlineDownloadId {
            // Fully local prepare from the stored record + manifest. Must keep
            // working in airplane mode, so nothing on this branch (or downstream
            // of it while `offlinePlaybackContext` is set) may require the
            // server.
            let offline = try await OfflinePlaybackBuilder.loadPreparedPlayback(
                downloadId: offlineDownloadId,
                startFromBeginning: request.startFromBeginning,
                resumePositionOverride: options.resumePosition
            )
            offlinePlaybackContext = OfflinePlaybackContext(
                downloadId: offline.downloadId,
                mediaItemId: offline.mediaItemId
            )
            nowPlaying.setArtworkURL(offline.posterFileURL)
            prepared = offline.prepared
        } else {
            // Bound the start-session call when the load was triggered by
            // autoplay or interruption recovery. A user-initiated load keeps the
            // unbounded behavior — a slow manual pick is annoying but does not
            // wedge the UI; a hung autoplay does.
            prepared = try await startServerSession(
                request: request,
                resumePosition: options.resumePosition,
                allowNearEndResume: options.allowNearEndResume,
                timeout: origin == .userInitiated ? nil : Self.autoplayStartSessionTimeout
            )
        }
        try Task.checkCancellation()

        let plan = try await adoptPrepared(
            prepared,
            origin: .freshLoad(PlaybackAdoptionOrigin.FreshLoad(
                isOffline: request.offlineDownloadId != nil,
                requestedStart: options.resumePosition
            ))
        )
        let identity = request.offlineDownloadId != nil
            ? SessionIdentity.offline()
            : Self.identity(for: prepared)
        return (prepared, plan, identity)
    }

    /// Race `sessionBridge.startSession` against an optional timeout. A nil
    /// `timeout` runs unbounded (matches the historical behavior). A non-nil
    /// timeout cancels the in-flight start when it elapses; URLSession's
    /// cancellation propagates as `CancellationError`, which we translate to
    /// `BeginFreshLoadError.startSessionTimeout` for the caller's catch block.
    private func startServerSession(
        request: LoadRequest,
        resumePosition: Double?,
        allowNearEndResume: Bool,
        timeout: TimeInterval?
    ) async throws -> PreparedPlayback {
        let initialSubtitlePreferences: PlaybackSessionBridge.InitialProtocolV3SubtitlePreferences? = {
            guard settings.subtitleMatchesSystemAppearance,
                  !trackSelection.hasExplicitSubtitleChoice else {
                return nil
            }
            let preferences = trackSelection.systemCaptionPrefsSnapshot()
            return PlaybackSessionBridge.InitialProtocolV3SubtitlePreferences(
                preferredLanguage: preferences.preferredLanguage,
                additionalPreferredLanguages: preferences.additionalPreferredLanguages,
                mode: preferences.mode,
                showForced: preferences.showForced,
                forcedOnly: preferences.forcedOnly,
                preferAccessibilityTracks: preferences.preferAccessibilityTracks,
                disableWhenNoLanguageMatch: preferences.disableWhenNoLanguageMatch,
                trackSignature: preferences.trackSignature
            )
        }()
        if let timeout {
            let startTask = Task<PreparedPlayback, Error> { [sessionBridge] in
                try await sessionBridge.startSession(
                    contentId: request.contentId,
                    preferredFileId: request.preferredFileId,
                    preferredAudioTrackIndex: request.preferredAudioTrackIndex,
                    preferredSubtitleTrackIndex: request.preferredSubtitleTrackIndex,
                    preferredProtocolV3SubtitleIndex: request.preferredProtocolV3SubtitleIndex,
                    initialSubtitlePreferences: initialSubtitlePreferences,
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
                preferredProtocolV3SubtitleIndex: request.preferredProtocolV3SubtitleIndex,
                initialSubtitlePreferences: initialSubtitlePreferences,
                startFromBeginning: request.startFromBeginning,
                resumePosition: resumePosition,
                allowNearEndResume: allowNearEndResume,
                preferredQualityOverride: request.preferredQualityOverride
            )
        }
    }

    /// Routes a failed load based on what triggered it, and answers with the
    /// message the error wall should carry — or `nil` when this origin keeps the
    /// player on a recoverable surface instead.
    ///
    /// User-initiated loads keep the historical full-screen error wall. Autoplay
    /// and interruption-recovery loads restore the Next Up postroll with
    /// `nextUpStartError` set so the user can pick something from On Deck or hit
    /// Back without the player being taken hostage by an `error` overlay.
    @MainActor
    func presentLoadFailure(_ error: Error, origin: LoadOrigin) -> String? {
        Self.logger.error("Load failed: \(String(describing: error), privacy: .public)")
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
            return message
        case .autoplay:
            Self.logger.warning(
                "[CMP] beginFreshLoad recovered from autoplay failure: \(message, privacy: .public)"
            )
            engineSession?.stopTransport()
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
            return nil
        case .recovery:
            Self.logger.warning(
                "[CMP] beginFreshLoad recovered from playback recovery failure: \(message, privacy: .public)"
            )
            engineSession?.stopTransport()
            showNotice(
                title: "Playback recovery failed",
                message: message,
                tone: .warning,
                duration: 6
            )
            return nil
        }
    }

    /// `attemptBackgroundSessionRenewal`'s round trip and adoption.
    ///
    /// Whether this playback *can* be renewed in place, and whether one is
    /// already in flight, are `RecoveryPolicy.decideSessionMissing`'s; the
    /// single-flight is the reducer's `Sub.renewingSource`. What is left here is
    /// the bridge call, the proxy retarget and the shell-side adoption.
    ///
    /// Returns `nil` when the load moved on while the renewal was in flight —
    /// adopting the new session into it would cross-wire two loads.
    @MainActor
    func prepareRenewal(
        _ renewal: SourceRenewal
    ) async throws -> (prepared: PreparedPlayback, identity: SessionIdentity)? {
        guard let currentWatchDetail, let session = engineSession else { return nil }
        let staleSessionId = renewal.issuedFor.serverSessionId ?? "unknown"
        let resumePosition = renewal.observedPosition.isFinite
            ? max(0, renewal.observedPosition)
            : max(0, currentTime)

        Self.logger.warning(
            "[CMP-RECOVERY] background session renewal started session=\(staleSessionId, privacy: .public) reason=\(renewal.reason, privacy: .public) position=\(resumePosition, privacy: .public)"
        )

        let renewed = try await sessionBridge.renewDirectSession(
            watchDetail: currentWatchDetail,
            position: resumePosition,
            // The bridge owns the adopted V3 plan. Passing no overrides makes
            // renewal repeat that exact tuple instead of consulting player
            // tracks that may already be empty.
            audioTrackIndex: nil,
            subtitleTrackIndex: nil
        )
        try Task.checkCancellation()
        guard currentServerSessionId == staleSessionId,
              engineSession === session,
              session.transport != nil else {
            Self.logger.info(
                "[CMP-RECOVERY] background renewal superseded session=\(staleSessionId, privacy: .public)"
            )
            return nil
        }
        guard let streamRequest = await makeStreamRequest(
            session: renewed.session,
            additionalHeaders: renewed.protocolV3?.plan.stream.headers ?? [:]
        ) else {
            throw PlaybackAdoptionFailure(message: "invalid renewed stream URL")
        }
        session.retargetSource(url: streamRequest.url, headers: streamRequest.headers)
        currentWatchDetailAdopt(renewed)
        session.driver.noteBackgroundRenewalSucceeded()
        await realtimeClient.unbind()
        try Task.checkCancellation()
        await realtimeClient.bind(sessionId: renewed.session.sessionId)
        Self.logger.info(
            "[CMP-RECOVERY] background session renewal succeeded old=\(staleSessionId, privacy: .public) new=\(renewed.session.sessionId, privacy: .public) reason=\(renewal.reason, privacy: .public)"
        )
        return (renewed, Self.identity(for: renewed))
    }

    /// The renewal's shell-side adoption: the plan facts a re-probed source may
    /// have changed. The playhead is deliberately *not* adopted — the retarget
    /// is silent and playback never stopped.
    @MainActor
    private func currentWatchDetailAdopt(_ renewed: PreparedPlayback) {
        currentWatchDetail = renewed.watchDetail
        currentSelectedVersion = renewed.selectedVersion
        activePreparedProtocolV3 = renewed.protocolV3
        adoptProtocolV3RenewalIntent(from: renewed)
        trackSelection.adoptRenewedSubtitleUrls(renewed.session.subtitleUrls)
        trackSelection.loadPendingExternalSubtitles()
        qualityOptions = ApplePlaybackQuality.playbackOptions(
            serverQualities: renewed.protocolV3?.plan.availableQualities ?? [],
            fallbackVersion: renewed.selectedVersion
        )
    }

    /// Record a failed silent renewal on the load's recovery owner and report
    /// whether the silent path is now spent. The `_bg_renewal_failed` suffix and
    /// the escalation to the visible renewal are the policy's decision.
    @MainActor
    func noteRenewalFailure(_ error: Error, reason: String) -> Bool {
        guard let session = engineSession else { return false }
        if error is PlaybackSessionBridge.DirectSessionRenewalError {
            // The server re-planned (or nothing is renewable): only a full
            // visible renewal can pick up the new plan.
            Self.logger.warning(
                "[CMP-RECOVERY] background renewal escalating to visible renewal reason=\(reason, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            session.driver.noteBackgroundRenewalExhausted()
            refreshRecoveryContext(session: session)
            return true
        }
        if session.driver.noteBackgroundRenewalTransientFailure() {
            Self.logger.warning(
                "[CMP-RECOVERY] background renewal escalating to visible renewal reason=\(reason, privacy: .public): transient failures exhausted: \(String(describing: error), privacy: .public)"
            )
            session.driver.noteBackgroundRenewalExhausted()
            refreshRecoveryContext(session: session)
            return true
        }
        // The in-flight flag is already clear, so the next trigger (progress
        // heartbeat or stream 404) retries; a genuinely dead server escalates
        // through the source-interruption path independently of this renewal.
        Self.logger.warning(
            "[CMP-RECOVERY] background renewal transient failure #\(session.driver.context.backgroundRenewalTransientFailures) reason=\(reason, privacy: .public): \(String(describing: error), privacy: .public)"
        )
        return false
    }

    /// One server health probe. Auth statuses count as reachable — the server is
    /// up even if this credential cannot read /health — but the log line names
    /// them apart from a clean 200, and the failure line carries the error, so
    /// the three outcomes stay distinguishable on the console.
    @MainActor
    func probeServerHealthOnce(reporting timerID: TimerID) async -> Bool {
        do {
            let _: HealthStatus = try await HTTPClient.shared.get("/api/v1/health")
            if timerID == .serverOutageRecovery {
                Self.logger.info("[CMP-RECOVERY] server health probe succeeded")
            }
            return true
        } catch {
            if let httpError = error as? HTTPError,
               let statusCode = httpError.statusCode,
               statusCode == 401 || statusCode == 403 {
                if timerID == .serverOutageRecovery {
                    Self.logger.info(
                        "[CMP-RECOVERY] server health probe reached auth status=\(statusCode, privacy: .public); treating server as ready"
                    )
                }
                return true
            }
            if timerID == .serverOutageRecovery {
                // The delay in force at *this* probe — `waitForServerReady`'s
                // `delay` local, which it logged before doubling it.
                let retryDelay = engineSession?.driver.context.serverOutageRecovery?.nextDelay
                    ?? RecoveryPolicy.serverOutageRecoveryInitialDelay
                Self.logger.warning(
                    "[CMP-RECOVERY] server health probe failed; retrying in \(retryDelay, privacy: .public)s error=\(String(describing: error), privacy: .public)"
                )
            }
            return false
        }
    }

    /// Nudge the source proxy to re-probe its origin after a healthy server
    /// probe during a ride-through.
    @MainActor
    func reprobeOrigin() {
        sourceProxy?.reprobeOrigin()
    }

    /// `Effect.seek`. The reducer already moved the published playhead and
    /// armed the stale-frame filter; this is the engine call.
    @MainActor
    func engineSeek(to seconds: Double) {
        engineSession?.seek(to: seconds)
    }

    /// `Effect.transport`. Fire and forget: `isPlaying` has one writer, the
    /// backend's `onPauseChange`, which comes back through the reducer.
    @MainActor
    func engineTransport(_ command: TransportCommand) {
        switch command {
        case .play: avPlayerBackend?.play()
        case .pause: avPlayerBackend?.pause()
        }
    }

    /// Flush one watch-progress sample into the offline queue, if this load is
    /// an offline download. Answers whether it was — the online heartbeat must
    /// not also report against a server session the offline path never minted.
    @MainActor
    func recordOfflineProgressIfOffline() -> Bool {
        guard let offline = offlinePlaybackContext else { return false }
        recordOfflineProgress(context: offline)
        return true
    }

    /// The runway gate: report the buffering edge and show the "Reconnecting"
    /// notice the first time the player actually runs out of runway during an
    /// origin outage. `RecoveryContext.OutageState.noticeShown` is the gate.
    @MainActor
    private func noteBufferingDuringSourceOutage() {
        guard let session = engineSession else { return }
        let wasShown = session.driver.context.outage?.noticeShown ?? true
        session.observe(.bufferingChanged(true))
        guard !wasShown, session.driver.context.outage?.noticeShown == true else { return }
        showSourceOutageReconnectingNotice()
    }

    @MainActor
    private func showSourceOutageReconnectingNotice() {
        sourceOutageNoticeShown = true
        Self.logger.warning("[CMP-OUTAGE] runway exhausted; showing reconnecting notice")
        showNotice(
            title: "Reconnecting",
            message: "Connection to the server was lost. Trying to reconnect…",
            tone: .warning,
            duration: RecoveryPolicy.serverOutageRecoveryTimeout
        )
    }

    /// Forward one view command to the control plane. Every command is an
    /// intent: the reducer decides what it means, the actor runs the effects,
    /// and whatever moved comes back as a `Presentation`.
    private func send(_ intent: PlayerIntent) {
        guard !isDisposed, let controlPlane else { return }
        Task { await controlPlane.send(intent) }
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
        send(
            .load(
                request,
                origin: .userInitiated,
                options: LoadOptions(
                    progressPosition: currentTime,
                    resumePosition: resumePositionOverride
                )
            )
        )
    }

    /// Re-run the last load from scratch after an error — or, on tvOS, resume a
    /// player the system suspended. `PlaybackReducer.retry` rebuilds the request
    /// from whichever state the player rests in and resumes at the playhead the
    /// failure left behind.
    func retry() {
        #if os(tvOS)
        if isBackgroundSuspended {
            Self.logger.info("[CMP-LIFECYCLE] tvOS explicit resume from suspended playback")
            error = nil
            showControls = true
            send(.resumeSuspended)
            return
        }
        #endif
        send(.retry)
    }

    func togglePlayPause() {
        send(.togglePlayPause)
        guard !isBackgroundSuspended else { return }
        scheduleHideControls()
    }

    #if os(tvOS)
    /// Native-player Select behavior for timeline entry: pause immediately
    /// and keep the full transport mounted. When controls were hidden,
    /// `TVPlayerControls` consumes a separate request token to focus and
    /// activate its timeline scrubber.
    func pauseForTimelineSelection() {
        guard !isBackgroundSuspended, !isLoading, !hasEndedStream else { return }
        if isPlaying {
            send(.pause)
        }
        pinControlsVisible()
    }
    #endif

    func switchQuality(_ qualityId: String) {
        guard !isBackgroundSuspended else { return }
        guard let plan = activeExecutionPlan else { return }
        let normalized = activePreparedProtocolV3 == nil
            ? ApplePlaybackQuality.normalizeStoredId(qualityId)
            : ApplePlaybackQuality.protocolV3QualityId(qualityId)
        let resolvedQualityId = normalized

        guard resolvedQualityId != activeQualityId || qualitySwitchError != nil else { return }
        if activePreparedProtocolV3 != nil {
            // The V3 branch is the reducer's `.changeQuality`: it applies the
            // same "already on this rung" guard, mints the replan and clears the
            // spinner when the round trip ends.
            isQualitySwitching = true
            qualitySwitchError = nil
            showControls = true
            hideControlsTask?.cancel()
            send(.changeQuality(resolvedQualityId))
            return
        }
        // The pre-V3 branches need version and plan knowledge the control plane
        // does not hold, so they stay here and issue their own `.load`.
        let qualityOverrideCapKbps = AppleQualityAxes.resolvedBitrateCap(
            qualityOverride: resolvedQualityId,
            fallbackBitrateKbps: nil
        )
        let qualityRequiresTranscode = currentSelectedVersion.map {
            ApplePlaybackQuality.shouldForceTranscode(
                preferredQualityId: resolvedQualityId,
                selectedVersion: $0,
                capKbps: qualityOverrideCapKbps
            )
        } ?? true
        if !qualityRequiresTranscode {
            if plan.delivery == .direct || plan.delivery == .remux {
                if let selectedVersion = currentSelectedVersion,
                   let watchDetail = currentWatchDetail,
                   let lastLoadRequest,
                   lastLoadRequest.offlineDownloadId == nil,
                   ApplePlaybackQuality.shouldReselectSource(
                       preferredQualityId: resolvedQualityId,
                       selectedVersion: selectedVersion,
                       availableVersions: watchDetail.versions
                   ) {
                    var request = lastLoadRequest.copyForRecovery(
                        preferredFileId: nil,
                        preferredAudioTrackIndex: trackSelection.resolvedAudioTrackIndexForResume(),
                        preferredSubtitleTrackIndex: trackSelection.resolvedSubtitleTrackIndexForResume(),
                        preferredSidecarSubtitleTrackId: trackSelection.resolvedSidecarSubtitleTrackIdForResume(),
                        offlineDownloadId: nil
                    )
                    request.preferredQualityOverride = resolvedQualityId
                    let target = currentTime.isFinite ? max(0, currentTime) : 0
                    qualitySwitchError = nil
                    send(
                        .load(
                            request,
                            origin: .userInitiated,
                            options: LoadOptions(
                                progressPosition: target,
                                finalizeCurrentSession: true,
                                resumePosition: target,
                                allowNearEndResume: true
                            )
                        )
                    )
                    return
                }
                activeQualityId = resolvedQualityId
                lastLoadRequest?.preferredQualityOverride = resolvedQualityId
                qualitySwitchError = nil
                return
            }
            if plan.delivery == .transcode, let lastLoadRequest {
                // Currently transcoding, but the requested quality (e.g. back
                // to Auto after a manual downgrade) no longer needs it. An
                // in-place transcode restart can only produce HLS again —
                // replan the whole session so the server can hand back direct
                // play.
                var request = lastLoadRequest.copyForRecovery(
                    preferredFileId: lastLoadRequest.preferredFileId,
                    preferredAudioTrackIndex: trackSelection.resolvedAudioTrackIndexForResume(),
                    preferredSubtitleTrackIndex: trackSelection.resolvedSubtitleTrackIndexForResume(),
                    preferredSidecarSubtitleTrackId: trackSelection.resolvedSidecarSubtitleTrackIdForResume(),
                    offlineDownloadId: lastLoadRequest.offlineDownloadId
                )
                request.preferredQualityOverride = resolvedQualityId
                let target = currentTime.isFinite ? max(0, currentTime) : 0
                qualitySwitchError = nil
                send(
                    .load(
                        request,
                        origin: .userInitiated,
                        options: LoadOptions(
                            progressPosition: target,
                            finalizeCurrentSession: true,
                            resumePosition: target,
                            allowNearEndResume: true
                        )
                    )
                )
                return
            }
        }

        // No live V3 plan to replan against: the in-place restart refuses and
        // re-arms the picker with its own error.
        isQualitySwitching = false
        qualitySwitchError = "Quality unavailable for this item."
        Self.logger.warning(
            "[CMP-SEEK] V3 stream replan skipped: missing active protocol or item snapshot"
        )
    }

    func handleScenePhase(_ phase: ScenePhase) {
        #if os(tvOS)
        if phase == .active, isBackgroundSuspended {
            Self.logger.info("[CMP-LIFECYCLE] tvOS player woke from background suspend; awaiting explicit resume")
            showControls = true
            hideControlsTask?.cancel()
            return
        }
        if phase == .active, interruptionRecoveryDeadline != nil {
            Self.logger.info("[CMP-LIFECYCLE] tvOS player resuming after transient inactive interruption")
        }
        if phase == .inactive, !isBackgroundSuspended, isPlaying {
            Self.logger.info(
                "[CMP-LIFECYCLE] tvOS player entering transient inactive pause at position=\(self.currentTime, privacy: .public)"
            )
        }
        #endif
        #if os(iOS)
        isSceneBackgrounded = phase == .background
        if phase == .background {
            // The third background exemption — automatic PiP that has not
            // published `willStart` yet — is a UI timer, so the shell resolves it
            // *before* the control plane sees the phase (design section 2.3
            // contract note (b)).
            if avPlayerBackend?.isExternalPlaybackActive != true,
               !PictureInPictureCoordinator.shared.isEngaged,
               PictureInPictureCoordinator.shared.isPossible {
                schedulePictureInPictureBackgroundGrace()
                return
            }
        }
        if phase == .active {
            pictureInPictureBackgroundGraceTask?.cancel()
            pictureInPictureBackgroundGraceTask = nil
        }
        #endif
        send(.scenePhase(phase))
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
        send(.pause)
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
        guard !hasEndedStream else { return }
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
        guard !hasEndedStream else { return }
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
        guard !hasEndedStream else { return }
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

    /// Commit a seek target.
    ///
    /// The optimistic playhead move, the origin/target filter and its 5 s safety
    /// valve are the reducer's `beginSeek`; what is left here is the branch it
    /// deliberately does not model (design section 2.3 contract note (e)): a
    /// target the *current stream cannot contain* has to rebuild the stream
    /// instead of seeking it. That decision needs plan knowledge — the delivery,
    /// the loopback anchor, the server's `seek_reanchor` feature — which the
    /// control plane does not hold.
    @discardableResult
    private func commitSeek(to target: Double, source: String = "unspecified") -> Bool {
        Self.logger.info(
            "[CMP-SEEK] commit requested source=\(source, privacy: .public) target=\(target, privacy: .public) current=\(self.currentTime, privacy: .public) preview=\(self.scrubPreviewTime, privacy: .public) isScrubbing=\(self.isScrubbing, privacy: .public) route=\(self.activeRouteKind.label, privacy: .public) offset=\(self.playbackTimelineOffset, privacy: .public)"
        )
        if reloadServerBackedHLSForSeek(to: target) {
            return true
        }

        send(.seek(targetSeconds: target, origin: seekOrigin(for: source)))
        isScrubbing = false
        Self.logger.info(
            "[CMP-SEEK] commit dispatched source=\(source, privacy: .public) origin=\(self.currentTime, privacy: .public) target=\(target, privacy: .public)"
        )
        return false
    }

    /// The `SeekOrigin` a `commitSeek` caller stands for. `SeekOrigin` is the
    /// reducer's, so the shell's string source maps onto it once, here.
    private func seekOrigin(for source: String) -> SeekOrigin {
        switch source {
        case "skipDebounce": return .skip
        case "chapter": return .chapter
        case "intro": return .intro
        case "credits": return .credits
        case "keepWatching": return .nextUpKeepWatching
        case "scrub": return .scrub
        default: return .user
        }
    }

    /// The UI half of a re-anchor: the stream rebuild that follows is what
    /// actually moves the playhead, so the reducer's `.reanchor` origin arms the
    /// filter, moves the scrubber and takes down the safety valve without
    /// issuing an engine seek.
    private func beginReanchorSeekUI(origin: Double, target: Double) {
        _ = origin
        send(.seek(targetSeconds: target, origin: .reanchor))
        scrubPreviewTime = target
        isScrubbing = false
        isLoading = true
        setBuffering(false, cause: "restart")
        showControls = true
        hideControlsTask?.cancel()
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

        beginReanchorSeekUI(origin: origin, target: clampedTarget)

        if let protocolV3 = activePreparedProtocolV3,
           protocolV3.serverFeatures.contains(PlaybackProtocolV3.seekReanchorFeature) {
            requestReplan(
                ReplanIntent(
                    kind: .serverReplan,
                    position: clampedTarget,
                    classification: "seek_reanchor",
                    message: "Reanchor the active stream at the requested source position.",
                    operation: "seek_reanchor"
                )
            )
            return true
        }

        Self.logger.info(
            "[CMP-SEEK] server-backed HLS reload seek delivery=\(plan.delivery.name, privacy: .public) target=\(clampedTarget, privacy: .public) origin=\(origin, privacy: .public) offset=\(self.playbackTimelineOffset, privacy: .public)"
        )

        let seekRequest = lastLoadRequest.copyForRecovery(
            preferredFileId: lastLoadRequest.preferredFileId,
            preferredAudioTrackIndex: lastLoadRequest.preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: lastLoadRequest.preferredSubtitleTrackIndex,
            preferredSidecarSubtitleTrackId: lastLoadRequest.preferredSidecarSubtitleTrackId,
            offlineDownloadId: nil
        )
        send(
            .load(
                seekRequest,
                origin: .userInitiated,
                options: LoadOptions(
                    progressPosition: origin,
                    resumePosition: clampedTarget,
                    allowNearEndResume: true
                )
            )
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
            requirements: plan.requirements,
            parityBlockers: plan.parityBlockers,
            decisionTrace: plan.decisionTrace + ["loopback_reanchor_seek"],
            degradationWarnings: plan.degradationWarnings,
            reason: plan.reason,
            playbackSessionId: plan.playbackSessionId,
            wireDelivery: plan.wireDelivery,
            serverFeatures: plan.serverFeatures,
            sourceMetadata: plan.sourceMetadata,
            normalizationSummary: plan.normalizationSummary,
            validationClaims: plan.validationClaims
        )

        beginReanchorSeekUI(origin: origin, target: clampedTarget)
        playbackTimelineOffset = clampedTarget

        Self.logger.info(
            "[CMP-SEEK] local loopback reanchor seek target=\(clampedTarget, privacy: .public) origin=\(origin, privacy: .public) previousOffset=\(plan.loopbackSession?.sourceStartTimeSeconds ?? -1, privacy: .public)"
        )
        // A replacement item inside the *same* load, which is exactly what the
        // reducer's `fileLoaded` `.playing` arm models: the server session is
        // untouched, only the local remux is re-anchored.
        pendingExecutionPlan = updatedPlan
        guard let controlPlane else { return true }
        Task { await controlPlane.reloadEngineInPlace() }
        return true
    }

    /// Mint a replan the reducer did not decide for itself: the two seek
    /// re-anchor paths and, historically, the in-place transcode restart.
    private func requestReplan(_ intent: ReplanIntent) {
        guard !isDisposed, let controlPlane else { return }
        Task { await controlPlane.requestReplan(intent) }
    }

    func seek(to fraction: Double) {
        guard !isBackgroundSuspended else { return }
        guard !hasEndedStream else { return }
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
        guard !hasEndedStream else { return }
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
        if let creditsRange {
            Self.logger.info(
                "[CMP-MARKERS] credits range active start=\(creditsRange.start, privacy: .public) end=\(creditsRange.end, privacy: .public)"
            )
        }
        autoSkipIntroIfNeeded(at: currentTime)
        autoSkipCreditsIfNeeded(at: currentTime)
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
              !hasEndedStream,
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
                  !self.hasEndedStream,
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

    private func autoSkipCreditsIfNeeded(at time: Double) {
        let key = creditsRange.flatMap(currentCreditsSkipKey(for:))
        guard let target = CreditsAutoSkipPolicy.target(
            enabled: settings.autoSkipCredits,
            playbackEligible: !isLoading && !isBackgroundSuspended && !hasEndedStream,
            time: time,
            range: creditsRange,
            markerKey: key,
            lastSkippedKey: autoSkippedCreditsKey
        ), let key else {
            return
        }

        // Set the latch before seeking: a synchronous backend time callback
        // caused by the seek must see this marker as already handled.
        autoSkippedCreditsKey = key
        Self.logger.info(
            "[CMP-MARKERS] auto-skip credits target=\(target, privacy: .public) current=\(time, privacy: .public)"
        )
        seekTo(seconds: target)
    }

    private func currentIntroSkipKey(for range: TimeRange) -> String? {
        guard let sessionId = currentServerSessionId,
              let fileId = currentSelectedVersion?.fileId else {
            return nil
        }
        return "\(sessionId):\(fileId):\(range.start):\(range.end)"
    }

    private func currentCreditsSkipKey(for range: TimeRange) -> String? {
        guard let sessionId = currentServerSessionId,
              let fileId = currentSelectedVersion?.fileId else {
            return nil
        }
        return "\(sessionId):\(fileId):credits:\(range.start):\(range.end)"
    }

    func beginScrub(fraction: Double) {
        guard !isBackgroundSuspended else { return }
        guard !hasEndedStream else { return }
        guard duration > 0 else { return }
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        isScrubbing = true
        scrubPreviewTime = max(0, min(fraction, 1)) * duration
        hideControlsTask?.cancel()
    }

    func updateScrub(fraction: Double) {
        guard !isBackgroundSuspended else { return }
        guard !hasEndedStream else { return }
        guard duration > 0 else { return }
        scrubPreviewTime = max(0, min(fraction, 1)) * duration
    }

    func endScrub(resumePlayback: Bool = false, shouldSeek: Bool = true) {
        guard !isBackgroundSuspended else { return }
        guard !hasEndedStream else { return }
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
            send(.play)
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
    // Primary audio/subtitle selection routes through AVFoundation media
    // selection groups; secondary subtitles are sidecar-only. The half itself
    // lives on `TrackSelectionCoordinator`; what stays here is the port wiring
    // plus one forwarder per name the views and the LAN remote use.

    /// Wire the track coordinator to the playback core. Every closure is the
    /// exact core read or write the track code did inline before the
    /// extraction. `self` is captured weakly; because the view model owns the
    /// coordinator outright, none of these can actually outlive it.
    private func makeTrackSelectionPorts() -> TrackSelectionPorts {
        TrackSelectionPorts(
            backend: { [weak self] in self?.avPlayerBackend },
            context: { [weak self] in
                guard let self else { return .unavailable }
                return TrackSelectionContext(
                    activePreparedProtocolV3: self.activePreparedProtocolV3,
                    currentSelectedVersion: self.currentSelectedVersion,
                    currentWatchDetail: self.currentWatchDetail,
                    serverSessionId: self.currentServerSessionId,
                    resolvedServerUrl: self.resolvedServerUrl,
                    activeRouteKind: self.activeRouteKind,
                    backendCapabilities: self.backendCapabilities,
                    offlinePlaybackContext: self.offlinePlaybackContext,
                    currentTime: self.currentTime,
                    isBackgroundSuspended: self.isBackgroundSuspended,
                    isPlaying: self.isPlaying
                )
            },
            // Narrow reads for the coordinator's display members. Kept separate
            // from `context` so a SwiftUI body that evaluates them registers
            // only these properties — the whole context would drag in
            // `currentTime`, which the periodic time observer writes 10x/s.
            backendCapabilities: { [weak self] in
                self?.backendCapabilities ?? TrackSelectionContext.unavailable.backendCapabilities
            },
            serverSessionId: { [weak self] in self?.currentServerSessionId ?? nil },
            currentSelectedVersion: { [weak self] in self?.currentSelectedVersion ?? nil },
            // The subtitle index the third parameter carries is diagnostic
            // only: the durable write already happened through
            // `setLastLoadRequestProtocolV3SubtitleIndex` at the one site that
            // has a value, and the replan intent takes no such argument.
            requestReplan: { [weak self] classification, message, _ in
                guard let self else { return }
                self.requestReplan(
                    ReplanIntent(
                        kind: .serverReplan,
                        position: self.currentTime,
                        classification: classification,
                        message: message
                    )
                )
            },
            isReplanInFlight: { [weak self] in self?.replanSuspensionHolder != nil },
            lastLoadRequest: { [weak self] in self?.lastLoadRequest ?? nil },
            setLastLoadRequestProtocolV3SubtitleIndex: { [weak self] index in
                self?.lastLoadRequest?.preferredProtocolV3SubtitleIndex = index
            },
            showNotice: { [weak self] title, message, tone, duration in
                self?.showNotice(title: title, message: message, tone: tone, duration: duration)
            },
            activeNotice: { [weak self] in self?.activeNotice ?? nil },
            dismissNotice: { [weak self] in
                guard let self else { return }
                self.noticeDismissTask?.cancel()
                self.noticeDismissTask = nil
                self.activeNotice = nil
            },
            scheduleHideControls: { [weak self] in self?.scheduleHideControls() },
            resolveServerUrl: { [weak self] raw, serverUrl in
                self?.resolveServerUrl(raw, serverUrl: serverUrl) ?? nil
            },
            subtitleAILiveOverlayAvailable: { [weak self] in
                self?.subtitleAILiveOverlayAvailable ?? false
            },
            deferredLiveSubtitleCloseTask: { [weak self] in
                self?.deferredLiveSubtitleCloseTask ?? nil
            },
            setDeferredLiveSubtitleCloseTask: { [weak self] task in
                self?.deferredLiveSubtitleCloseTask = task
            }
        )
    }

    func selectAudio(_ track: PlayerTrack) { trackSelection.selectAudio(track) }

    func selectSubtitle(_ track: PlayerTrack) { trackSelection.selectSubtitle(track) }

    func disableSubtitles() { trackSelection.disableSubtitles() }

    func selectSecondarySubtitle(_ track: PlayerTrack) {
        trackSelection.selectSecondarySubtitle(track)
    }

    func disableSecondarySubtitles() { trackSelection.disableSecondarySubtitles() }

    // MARK: - AI subtitles (translate / transcribe over polling)

    /// Start an AI translation of an existing text subtitle track into
    /// `targetLanguage`.
    @MainActor
    func startSubtitleTranslation(track: PlayerTrack, to targetLanguage: String) {
        trackSelection.startSubtitleTranslation(track: track, to: targetLanguage)
    }

    /// Start an AI transcription of an audio track (`audioIndex`, `-1` =
    /// server default), optionally translating the transcript into
    /// `translateTo`.
    @MainActor
    func startSubtitleTranscription(audioIndex: Int, translateTo: String?) {
        trackSelection.startSubtitleTranscription(audioIndex: audioIndex, translateTo: translateTo)
    }

    // MARK: - Subtitle provider search (synchronous, no job machinery)

    @MainActor
    var subtitleSearchVisible: Bool { trackSelection.subtitleSearchVisible }

    @MainActor
    var subtitleSearchEnabled: Bool { trackSelection.subtitleSearchEnabled }

    @MainActor
    var subtitleSearchUnavailableReason: String? { trackSelection.subtitleSearchUnavailableReason }

    @MainActor
    func searchSubtitles(languages: [String]) async throws -> SubtitleSearchResponse {
        try await trackSelection.searchSubtitles(languages: languages)
    }

    @MainActor
    func downloadSearchedSubtitle(_ result: SubtitleSearchResult) async -> Bool {
        await trackSelection.downloadSearchedSubtitle(result)
    }

    static func protocolV3DownloadedSubtitleBaseTrackCount(
        _ inventory: [PlaybackV3SubtitleInventoryItem]
    ) -> Int {
        inventory.filter {
            $0.source.caseInsensitiveCompare("downloaded") != .orderedSame
        }.count
    }

    enum ProtocolV3SidecarRestoreIntent: Equatable {
        case renderLocally(Int64)
        case serverRendered(Int64)
    }

    static func protocolV3SidecarRestoreIntent(
        snapshot: Int64?,
        selectedSubtitleIndex: Int?,
        subtitleMode: String?
    ) -> ProtocolV3SidecarRestoreIntent? {
        guard let snapshot,
              SubtitleTrackIdSpace.isSidecar(snapshot),
              SubtitleTrackIdSpace.sidecarIndex(from: snapshot) == selectedSubtitleIndex else {
            return nil
        }
        switch subtitleMode {
        case "render":
            return .renderLocally(snapshot)
        case "burn_in":
            return .serverRendered(snapshot)
        default:
            return nil
        }
    }

    static func isUnexpectedBackwardPlaybackTime(
        _ candidate: Double,
        currentTime: Double,
        explicitSeekInFlight: Bool
    ) -> Bool {
        guard !explicitSeekInFlight,
              candidate.isFinite,
              currentTime.isFinite else {
            return false
        }
        return candidate + 0.75 < currentTime
    }

    struct ProtocolV3PendingTrackIntent: Equatable {
        let audioIndex: Int?
        let embeddedSubtitleIndex: Int?
        let sidecarSubtitleTrackId: Int64?
    }

    static func protocolV3PendingTrackIntent(
        plan: PlaybackV3Plan,
        request: LoadRequest
    ) -> ProtocolV3PendingTrackIntent {
        let rendersSubtitleLocally = plan.subtitle.mode == "render"
        return ProtocolV3PendingTrackIntent(
            audioIndex: request.preferredAudioTrackIndex,
            embeddedSubtitleIndex: rendersSubtitleLocally
                ? request.preferredSubtitleTrackIndex
                : -1,
            sidecarSubtitleTrackId: rendersSubtitleLocally
                ? request.preferredSidecarSubtitleTrackId
                : nil
        )
    }

    static func protocolV3SubtitleUrlsForCurrentRoute(
        _ urls: [SubtitleUrl],
        routeUsesEmbeddedExtraction: Bool,
        selectedSubtitleIndex: Int?,
        subtitleMode: String?
    ) -> [SubtitleUrl] {
        guard routeUsesEmbeddedExtraction else { return urls }
        let selectedRenderedSidecarIndex = subtitleMode == "render"
            ? selectedSubtitleIndex
            : nil
        return urls.filter { subtitle in
            subtitle.source?.localizedCaseInsensitiveCompare("embedded") != .orderedSame
                || subtitle.index == selectedRenderedSidecarIndex
        }
    }

    func cycleAudioTrack() { trackSelection.cycleAudioTrack() }

    func cycleSubtitleTrack() { trackSelection.cycleSubtitleTrack() }

    func toggleSubtitles() { trackSelection.toggleSubtitles() }

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
        // The PiP coordinator is a singleton and its controller strongly
        // retains the AVPlayerLayer, the AVPlayer, and everything hanging off
        // it. SwiftUI's `dismantleUIView` normally releases it, but ordering
        // there is not guaranteed relative to this teardown, so drop it here
        // too rather than risk stranding the whole playback graph. Owner-keyed
        // so a late teardown cannot unbind a newer session's PiP.
        PictureInPictureCoordinator.shared.endSession(owner: self)
        isSceneBackgrounded = false
        #endif
        activeExecutionPlan = nil
        currentWatchDetail = nil
        currentSelectedVersion = nil
        introRange = nil
        creditsRange = nil
        cancelPendingIntroAutoSkip()
        autoSkippedIntroKey = nil
        autoSkippedCreditsKey = nil
        autoSkipIntroCancelledKey = nil
        trackSelection.reset()
        activeNotice = nil
        tearDownHoldSeek()
        sourceOutageNoticeShown = false
        // Everything except the cleanup-completion task installed below.
        tasks.cancelAll(in: .teardown)
        if let outputRouteObserverToken {
            NotificationCenter.default.removeObserver(outputRouteObserverToken)
            self.outputRouteObserverToken = nil
        }
        sleepTimer.cancel()
        nowPlaying.detach()
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
                hasReachedEndOfFile: hasEndedStream,
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
        // `.dismiss` cancels every control-plane timer, disposes the engine
        // (discarding the source-cache handoff) and stops the server session.
        // The stop below is the one the bridge still owes for a *non-offline*
        // load; `PlaybackReducer.dismiss` emits its own `.stopSession` only when
        // the state still holds an identity, and both are identity-guarded, so
        // whichever lands second is a no-op.
        let controlPlane = self.controlPlane
        self.controlPlane = nil
        if let controlPlane {
            Task { await controlPlane.shutdown() }
        }
        engineSession?.dispose(reason: "cleanup")
        // Drop the disposed session so any post-teardown call is an explicit
        // no-op rather than relying on the backend's own `isDisposed` guard.
        // `finalPosition` is captured above, before this.
        engineSession = nil
        discardSourceCacheHandoff()

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
        Self.logger.info("[CMP-LIFE] PlayerViewModel.deinit")
        isDisposed = true
        if let systemCaptionObserverToken {
            NotificationCenter.default.removeObserver(systemCaptionObserverToken)
        }
        if let outputRouteObserverToken {
            NotificationCenter.default.removeObserver(outputRouteObserverToken)
        }
        tasks.cancelAll(in: .teardown)
        engineSession?.dispose(reason: "deinit")
        let realtimeClient = self.realtimeClient
        Task {
            await realtimeClient?.unbind()
        }
    }

    @MainActor
    private func handleRealtimeEvent(_ event: PlaybackRealtimeEventEnvelope) async {
        guard event.sessionId == currentServerSessionId else { return }
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
            send(.pause)
            if isAdminIssued(command) {
                showNotice(
                    title: "Playback paused by admin",
                    message: "An administrator paused this session.",
                    tone: .warning,
                    duration: 6
                )
            }
        case .unpause:
            send(.play)
            if isAdminIssued(command) {
                showNotice(
                    title: "Playback resumed by admin",
                    message: "An administrator resumed this session.",
                    tone: .info,
                    duration: 6
                )
            }
        case .playPause:
            let wasPaused = !isPlaying
            send(.togglePlayPause)
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
            send(.pause)
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
        let serverUrl = await SiloAPI.shared.currentServerUrl()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let token = await SiloAPI.shared.currentAccessToken()

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

    /// Backends report the source they were handed, which behind the
    /// source proxy or loopback is the in-app 127.0.0.1 server — an
    /// implementation detail, not the origin. `PlaybackStatsComposer` swaps
    /// this in for the HUD.
    private static func originHost(for plan: PlaybackExecutionPlan) -> String? {
        plan.sourceStreamRequest.url.host
            ?? URL(string: plan.sourceStreamRequest.serverUrl)?.host
    }

    /// The session metadata is available before the engine has inspected its
    /// format description, and derives its badge from the server's `hdr`
    /// flag — so it may only say "HDR", or claim HDR for a source the user's
    /// settings have since routed to SDR. Once the engine confirms what it is
    /// actually rendering, reconcile the visible badge with that.
    ///
    /// Only `confirmedDynamicRange` is trusted here: `stats.dynamicRange` is
    /// a prose label that describes the *source* ("Dolby Vision Profile 7 …
    /// as HDR10") and falls back to the planned route when introspection is
    /// unavailable, so matching on it claims Dolby Vision for pictures
    /// rendering as plain HDR10. A `nil` confirmation means "not determined
    /// yet" and leaves the source-derived badge untouched.
    private func reconcileDynamicRangeBadge(with confirmed: PlaybackStats.ConfirmedDynamicRange?) {
        guard let confirmed else { return }

        let replacement: String?
        switch confirmed {
        case .dolbyVision: replacement = "Dolby Vision"
        case .hdr10, .hlg: replacement = "HDR"
        case .sdr: replacement = nil
        }

        let isDynamicRangeBadge: (String) -> Bool = { badge in
            let normalized = badge.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return normalized == "HDR" || normalized == "DV" || normalized == "DOLBY VISION"
        }

        // Keep the badge where the source put it — between resolution and
        // video codec — rather than re-inserting it at a fixed index.
        var expectedBadges = metadata.badges
        let existing = expectedBadges.firstIndex(where: isDynamicRangeBadge)
        expectedBadges.removeAll(where: isDynamicRangeBadge)
        if let replacement {
            expectedBadges.insert(replacement, at: min(existing ?? 1, expectedBadges.count))
        }

        guard metadata.badges != expectedBadges else { return }
        metadata.badges = expectedBadges
    }

    /// Loopback spec for a route-fallback plan. Routed through the planner so
    /// the fallback rung normalizes codecs and picks a serving mode exactly
    /// the way the initial route decision did — the view model used to carry a
    /// drifted copy of this table.
    private func makeFallbackLoopbackSession(
        streamRequest: StreamRequest,
        videoMode: LoopbackSessionSpec.VideoMode,
        videoRange: String,
        sourceStartTimeSeconds: Double
    ) -> LoopbackSessionSpec? {
        currentSelectedVersion.flatMap { version in
            ApplePlaybackRoutePlanner.makeLoopbackSessionSpec(
                for: version,
                selectedAudioTrackIndex: trackSelection.resolvedAudioTrackIndexForResume()
                    ?? trackSelection.pendingAudioFfIndex,
                selectedAudioTrackId: selectedAudioId,
                pendingAudioFfIndex: trackSelection.pendingAudioFfIndex,
                preferredAudioTrackIndex: trackSelection.resolvedAudioTrackIndexForResume(),
                streamRequest: streamRequest,
                videoMode: videoMode,
                videoRange: videoRange,
                sourceStartTimeSeconds: sourceStartTimeSeconds
            )
        }
    }

    private func isH264Video(_ version: FileVersion) -> Bool {
        var tokens = [version.codecVideo]
        tokens.append(contentsOf: (version.videoTracks ?? []).map(\.codec))
        return tokens.compactMap(ApplePlaybackRoutePlanner.normalizedToken).contains { token in
            token == "h264"
                || token == "avc1"
                || token.contains("h.264")
                || token.contains("avc")
        }
    }

    private func humanReadableRouteReason(_ reason: String) -> String {
        switch reason {
        case "dolby_vision_profile7_to81_base_layer_loopback":
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
        case "native_direct_avplayer_failed_silo_fallback":
            return "Native Player Direct failed, so playback fell back to SiloPlayer normalization"
        case "native_direct_blocked_silo_fallback":
            return "The Native Player Direct allowlist did not match, so SiloPlayer normalization was selected"
        case "native_direct_blocked_hls_fallback":
            return "The Native Player Direct allowlist did not match and the source cannot be normalized locally, so playback uses the server stream"
        case "apple_hls_route_enabled":
            return "Native Player HLS route selected"
        default:
            return reason.replacingOccurrences(of: "_", with: " ")
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
        // Track, quality and seek commands replace what is playing (a V3
        // replan or an in-place restart). Accepting one from the LAN remote
        // while a load is already in flight would stack a second replacement
        // on top of the first; the realtime command path guards its seek the
        // same way. Transport-only commands stay live, and the ignore is
        // quiet — a remote peer should not see a failure for pressing a
        // button mid-load.
        switch command.name {
        case .seek, .selectAudioTrack, .selectSubtitleTrack, .setQuality:
            guard !isLoading else { return }
        default:
            break
        }
        switch command.name {
        case .play:
            send(.play)
            scheduleHideControls()
        case .pause:
            send(.pause)
            scheduleHideControls()
        case .playPause:
            togglePlayPause()
        case .seek:
            guard let seconds = command.seconds else {
                throw SiloControlPlayerError.missingSeekPosition
            }
            seekTo(seconds: seconds)
        case .stop:
            send(.pause)
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
            // Deprecated: no route exposes an HDR passthrough toggle any
            // more. Accepted (and ignored) so an older remote peer does not
            // see a command failure.
            break
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
            sessionId: currentServerSessionId,
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
            hdrEnabled: false,
            supportsVideoGravity: backendCapabilities.supportsVideoGravity,
            supportsHDRToggle: false,
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
