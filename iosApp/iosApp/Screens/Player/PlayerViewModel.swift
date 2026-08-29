import AetherEngine
import AVFoundation
import CoreGraphics
import Foundation
import OSLog
import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#else
import AppKit
#endif

/// Engine-neutral chapter projection consumed by Silo's controls.
struct PlayerChapterInfo: Equatable, Identifiable, Sendable {
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
    let supportsSubtitleDelay: Bool
    let supportsSubtitleStyling: Bool

    static func aether(
        subtitleOverlayControls: Bool,
        hasTextSubtitleTrack: Bool
    ) -> PlayerBackendCapabilities {
        PlayerBackendCapabilities(
            supportsBufferedAhead: true,
            supportsExternalPrimarySubtitles: true,
            supportsSecondarySubtitles: hasTextSubtitleTrack,
            supportsChapters: true,
            supportsVideoGravity: true,
            supportsSubtitleDelay: subtitleOverlayControls,
            supportsSubtitleStyling: subtitleOverlayControls
        )
    }
}

/// Video playback teardown at an app identity boundary — sign-out, server or
/// profile switch, or a cleared session.
///
/// Those transitions replace the authenticated view hierarchy, which removes
/// the player cover. That path deliberately defers the player's `cleanup()`
/// while Picture in Picture is engaged, so nothing else ends an engaged video
/// session: the previous identity's engine, its open server playback session,
/// and a live PiP window would otherwise all survive into the next identity.
///
/// Callable from the shared auth paths on every platform; a no-op where video
/// Picture in Picture is not hosted.
enum PlayerIdentityBoundary {
    static func endEngagedVideoPictureInPicture() {
        #if os(iOS)
        PictureInPictureCoordinator.endEngagedSessionForIdentityChange()
        #endif
    }
}

@MainActor
@Observable
class PlayerViewModel {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "Player"
    )

    @ObservationIgnored
    fileprivate var aetherPlaybackController: AetherPlaybackController!
    @ObservationIgnored
    private var activeAetherLoadEpoch: AetherPlaybackController.LoadEpoch?
    /// The epoch whose `finishLoad` has returned, i.e. whose engine startup ran
    /// to completion and whose decode route is therefore settled.
    ///
    /// Aether publishes its track inventory during startup (`streamsProbed`),
    /// several steps before it dispatches the source onto a backend. Applying a
    /// deferred track pick at that point makes the engine rebuild its pipeline
    /// against a route it has not chosen yet — on a software-decode source
    /// (VC-1, AV1) the rebuild lands on the native path, which rejects the
    /// codec, kills the in-flight load and leaves the app on a spinner. Nothing
    /// that drives the engine off a *pending* selection may run before this is
    /// set for the current epoch.
    @ObservationIgnored
    private var establishedAetherLoadEpoch: AetherPlaybackController.LoadEpoch?
    @ObservationIgnored
    private var committedProtocolV3LoadEpoch: AetherPlaybackController.LoadEpoch?
    @ObservationIgnored
    private var pendingProtocolV3FirstFrameEpoch: AetherPlaybackController.LoadEpoch?
    @ObservationIgnored
    private var pendingProtocolV3SeekReanchorPosition: Double?
    /// The load epoch whose startup milestone (`handleFileLoaded`) has already
    /// run. Video loads reach that milestone on Aether's first frame; audio-only
    /// loads have no picture and reach it when the audio route starts playing.
    /// Both funnel through one epoch-scoped latch so a load can never take the
    /// milestone twice.
    @ObservationIgnored
    private var startedAetherLoadEpoch: AetherPlaybackController.LoadEpoch?
    /// A user track change that arrived while a replan was already in flight.
    /// Re-issued when the in-flight replan settles so the local selection the
    /// UI already shows is actually applied by the server. Position is
    /// re-read at drain time — playback moved on while we waited.
    @ObservationIgnored
    private var pendingProtocolV3TrackChange: QueuedProtocolV3TrackChange?
    @ObservationIgnored
    private var scrubPreviewProvider: AetherScrubPreviewProvider!
    @MainActor var aetherEngine: AetherEngine { aetherPlaybackController.engine }
    private var hasActiveAetherSession: Bool {
        aetherPlaybackController.activeSpec != nil
    }

    /// Keeps the auxiliary Aether still decoder in the same lifetime as the
    /// transport. Replacement loads preserve Aether's display/audio handoff;
    /// callers that own final teardown can await the returned task.
    @discardableResult
    private func disposeAetherPlayback(forReplacement: Bool = false) -> Task<Void, Never>? {
        let previewShutdown = scrubPreviewProvider.endSession()
        activeAetherLoadEpoch = nil
        establishedAetherLoadEpoch = nil
        committedProtocolV3LoadEpoch = nil
        pendingProtocolV3FirstFrameEpoch = nil
        pendingProtocolV3SeekReanchorPosition = nil
        pendingProtocolV3TrackChange = nil
        if forReplacement {
            aetherPlaybackController.prepareForReplacement()
        } else {
            aetherPlaybackController.dispose()
        }
        return previewShutdown
    }

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
    /// Realtime AI cues stay in Silo's product layer because Aether 6.34 does
    /// not expose a host cue-injection API. The presentation overlay merges
    /// these normalized source-time cues with Aether's decoded cue arrays.
    var livePrimarySubtitleCues: [LiveSubtitleCue] = []
    var liveSecondarySubtitleCues: [LiveSubtitleCue] = []
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
    /// Latest generation-fenced Aether still for the active scrub target.
    /// Nil is a first-class state: native cache misses and sources that cannot
    /// vend an independent reader keep the existing time-only affordance.
    var scrubPreviewImage: CGImage?
    private(set) var scrubPreviewImageSourceTime: Double?
    /// True while the iOS touch-and-hold fast-forward gesture is engaged.
    /// The temporary rate is applied straight to the backend and never
    /// persisted, so releasing always restores `settings.playbackSpeed`.
    var isHoldFastForwarding = false
    /// Seconds of media buffered ahead of `currentTime`, projected from
    /// Aether's public telemetry. The scrubber omits its buffered layer when
    /// the active route cannot report a comparable value.
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

    var showCreditsSkip: Bool {
        guard let creditsRange else { return false }
        return currentTime >= creditsRange.start && currentTime < creditsRange.end
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

    #if DEBUG
    /// Drives the `debugStartFakeLiveSubtitles()` stub. Repeating timer
    /// that feeds canned live cues at `currentTime+` to prove the M2 live
    /// subtitle render seam end-to-end with no server. DEBUG-only.
    private var debugLiveSubtitleTimer: Timer?
    private var debugLiveSubtitleTrack = LiveSubtitleTrack()
    private var debugLiveSubtitleLineIndex = 0
    #endif
    /// Canonical user volume/mute, owned by the VM. A fresh Aether load can
    /// replace its internal route, so the VM reapplies these values and keeps
    /// the cast UI in sync.
    private var userVolume: Float = 1.0
    private var userMuted = false
    private var streamLoadGeneration: UInt64 = 0
    var backendCapabilities: PlayerBackendCapabilities {
        let engine = aetherPlaybackController.engine
        let nativeSubtitleIsSelected = engine.activeSubtitleTrackIndex.flatMap { selectedID in
            engine.subtitleTracks.first { $0.id == selectedID }
        }?.isNativelyRenderedSubtitle == true
        return .aether(
            subtitleOverlayControls: !nativeSubtitleIsSelected,
            hasTextSubtitleTrack: subtitleTracks.contains {
                !SubtitleCodecClassifier.isBitmap($0.codec)
            }
        )
    }
    var activeRouteLabel: String {
        guard let delivery = aetherPlaybackController.activeSpec?.delivery else {
            return "AetherEngine"
        }
        switch delivery {
        case PlaybackProtocolV3.PlanDelivery.originalHTTP: return "Original"
        case PlaybackProtocolV3.PlanDelivery.remuxProgressive: return "Server Remux"
        case PlaybackProtocolV3.PlanDelivery.remuxHLS: return "Server Remux HLS"
        case PlaybackProtocolV3.PlanDelivery.transcodeHLS: return "Server Transcode HLS"
        default: return delivery.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    /// One-line, user-facing Aether route description for the player HUD.
    var playbackRouteDisplay: String {
        "AetherEngine · \(activeRouteLabel)"
    }
    var routeStatusRows: [PlayerRouteStatusRow] {
        [
            PlayerRouteStatusRow(label: "Playback", value: activeRouteLabel),
            PlayerRouteStatusRow(label: "Engine", value: "AetherEngine"),
            PlayerRouteStatusRow(
                label: "Route",
                value: aetherPlaybackController.engine.videoRoute.rawValue
            ),
        ]
    }
    var routeDecisionSummary: String? {
        activePreparedProtocolV3?.plan.decisionReason
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
    var routeWarnings: [String] {
        activePreparedProtocolV3?.plan.degradationWarnings.map(\.message) ?? []
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
        return orderedSubtitles(subtitleTracks.filter {
            !SubtitleCodecClassifier.isBitmap($0.codec) && canRenderAsSecondarySubtitle($0)
        })
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
    var needsReplacementForPresentation: Bool { isDisposed }
    /// Whether Aether currently has a receiver-fetchable native video route.
    /// Header-authenticated remote HLS remains false because the receiver
    /// cannot reproduce the sender's AVURLAsset request headers.
    private(set) var supportsExternalPlayback = false
    /// Mirrors the active AVPlayer route, with the AirPlay/HDMI audio route
    /// used only to bridge Aether's transient native-item replacement gap.
    private(set) var isExternalPlaybackActive = false
    #if os(iOS)
    private var isPlayerPresentationVisible = false
    /// AVKit's restore completion handler, held while the re-presented cover
    /// is still on its way to `PlayerView.onAppear`. See
    /// `restorePictureInPictureUserInterface`.
    private var pendingRestoreCompletion: ((Bool) -> Void)?
    private var pendingRestoreTimeoutTask: Task<Void, Never>?
    /// How long the re-presented cover gets to actually mount before the
    /// restore is treated as failed. Generous next to a SwiftUI presentation,
    /// short next to a session that would otherwise play on forever.
    private static let pictureInPictureRestoreTimeoutNanoseconds: UInt64 = 3_000_000_000
    #endif
    /// True after the active backend reports natural EOF. Used to keep the
    /// UI in a terminal paused state without letting tail-drain callbacks
    /// overwrite it or surface a false decode error.
    private var hasReachedEndOfFile = false
    let settings = PlayerSettings.shared
    let sleepTimer = SleepTimer()
    private let nowPlaying = AetherVideoNowPlayingCoordinator()
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
    @ObservationIgnored
    private var realtimeClient: PlaybackRealtimeClient!
    @ObservationIgnored
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

    /// A marker update can finish after the playback session starts but before
    /// the realtime websocket has connected. Reconcile once after the socket
    /// is live so that event-delivery race cannot hide intro/credits prompts
    /// for the current Aether load.
    private var markerReconciledSessionId: String?
    private var markerReconcileTask: Task<Void, Never>?

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
    /// Held so the init-time `refreshSettingsFromServer` call can be cancelled
    /// from `cleanup()`. Without a handle the task lingered on a dismissed VM
    /// and could observe `self` after dispose.
    private var settingsRefreshTask: Task<Void, Never>?
    private var freshLoadTask: Task<Void, Never>?
    private var freshLoadGeneration: UInt64 = 0
    /// True while `freshLoadTask` is the sole owner of a load failure's
    /// outcome. Aether publishes its typed failure before the load throws, so
    /// without this the direct-play and offline paths surface the same
    /// failure twice — once through `handleAetherFailure` and again through
    /// the load's own catch.
    private var freshLoadOwnsFailureHandling = false
    /// The most recent `audioTrackSwitchFailed` Aether published while a load
    /// owned failure handling. The engine kills the in-flight load as part of
    /// the same rebuild, so the load's own catch sees only a cancellation and
    /// would otherwise have no idea why it was abandoned.
    @ObservationIgnored
    private var lastAetherAudioTrackSwitchFailure: PlaybackErrorInfo?
    /// Serializes every Protocol V3 source replacement, including a same-plan
    /// reload whose only change is a refreshed bearer. Reusing this gate keeps
    /// credential recovery from racing route replans, seeks, or track changes.
    private var protocolV3ReplanTask: Task<Void, Never>?
    private var nextUpLookupTask: Task<Void, Never>?
    private var nextUpOnDeckTask: Task<Void, Never>?
    private var nextUpCountdownTask: Task<Void, Never>?
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
    /// asked Aether to jump to. Clock reports that are closer to
    /// `seekOriginTime` than to `seekTargetTime` are treated as stale and
    /// dropped. This is direction-agnostic and handles back-to-back seeks.
    /// The filter releases as soon as a report crosses the midpoint
    /// between origin and target, which is the earliest point we can
    /// confidently say the new position has landed. Safety timeout below
    /// drops the filter if no matching report arrives (e.g. transport
    /// error on HLS transcode), since a stuck filter would pin the
    /// scrubber to the optimistic target forever.
    private var seekOriginTime: Double?
    private var seekTargetTime: Double?
    private var seekFilterTimeoutTask: Task<Void, Never>?
    /// The in-flight `commitSeek` await. Held so a new load can cancel a seek
    /// whose `.requiresReplan` answer would otherwise arrive after the item
    /// it was issued against is gone.
    private var seekReplanTask: Task<Void, Never>?
    private static let seekFilterNanos: UInt64 = 5_000_000_000 // 5s
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
    /// Picker rows for sidecars this session registered with Aether itself —
    /// a finished AI translation/transcription or a downloaded subtitle.
    ///
    /// Under Protocol V3 the published picker is rebuilt from the plan's
    /// inventory, and the plan that is active when a job completes predates
    /// the new track, so without this the finished subtitle would vanish from
    /// the menu until the next replan. Rows are unioned in, de-duped against
    /// the plan, and dropped once the server publishes the same ordinal.
    private var locallyRegisteredSidecarSubtitleTracks: [PlayerTrack] = []
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
    /// A protocol-v3 subtitle can remain represented by a sidecar picker row
    /// even when the replacement plan renders it on the server (for example,
    /// bitmap PGS subtitles burned into HLS). Preserve that picker selection
    /// across an Aether reload without also opening the sidecar locally.
    private var pendingServerRenderedSubtitleTrackId: Int64?
    /// Seamless live→persisted swap: the synthetic AI-live track id whose row
    /// is closed only after the handed-off persisted track is selected.
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
        let additionalPreferredLanguages: [String]
        let mode: SubtitleMode?
        let showForced: Bool
        let forcedOnly: Bool
        let preferAccessibilityTracks: Bool
        let disableWhenNoLanguageMatch: Bool
        let trackSignature: SubtitleTrackSignature?
    }
    /// Set after the resolver has fired once for the current item so we
    /// don't keep re-evaluating (and overriding the user) on every
    /// subsequent track-list update.
    private var prefsResolvedForCurrentItem: Bool = false
    private var resolvedServerUrl: String = ""
    private var currentWatchDetail: WatchDetail?
    private var currentSelectedVersion: FileVersion?
    private var activePreparedProtocolV3: PreparedPlaybackV3?
    private var activePlaybackSessionId: String?
    private var autoSkippedIntroKey: String?
    private var autoSkippedCreditsKey: String?
    private var autoSkipIntroCancelledKey: String?
    private var pendingAutoSkipIntroKey: String?
    private var autoSkipIntroCountdownTask: Task<Void, Never>?
    private var staleSessionRecoverySessionId: String?
    struct LoadRequest {
        let contentId: String
        let preferredFileId: Int?
        let preferredAudioTrackIndex: Int?
        let preferredSubtitleTrackIndex: Int?
        let preferredSidecarSubtitleTrackId: Int64?
        let startFromBeginning: Bool
        /// Authoritative protocol-v3 combined ordinal. Unlike
        /// `preferredSubtitleTrackIndex`, this also represents external,
        /// downloaded, and server-extracted subtitle rows.
        var preferredProtocolV3SubtitleIndex: Int? = nil
        /// Set for local playback of a completed download. Routes the
        /// prepare through `OfflinePlaybackBuilder` instead of a server
        /// session, so retry after an error stays on the offline path.
        var offlineDownloadId: String? = nil
        /// Explicit quality for this load (mid-stream quality-change replan);
        /// wins over `PlayerSettings.preferredQuality` in the bridge.
        var preferredQualityOverride: String? = nil

        /// Rebuild a request for the same playback session while retaining the
        /// user's temporary quality choice. Recovery must not fall back to the
        /// persisted preference merely because tracks or the file id changed.
        func copyForRecovery(
            preferredFileId: Int?,
            preferredAudioTrackIndex: Int?,
            preferredSubtitleTrackIndex: Int?,
            preferredSidecarSubtitleTrackId: Int64?,
            offlineDownloadId: String?
        ) -> LoadRequest {
            var request = LoadRequest(
                contentId: contentId,
                preferredFileId: preferredFileId,
                preferredAudioTrackIndex: preferredAudioTrackIndex,
                preferredSubtitleTrackIndex: preferredSubtitleTrackIndex,
                preferredSidecarSubtitleTrackId: preferredSidecarSubtitleTrackId,
                startFromBeginning: false,
                offlineDownloadId: offlineDownloadId,
                preferredQualityOverride: preferredQualityOverride
            )
            request.preferredProtocolV3SubtitleIndex = preferredProtocolV3SubtitleIndex
            return request
        }

        /// Refresh the inputs used by session renewal from an adopted V3 plan.
        /// Player track lists are transient and may already be empty when a
        /// failed transport reports that its server session disappeared.
        func adoptingProtocolV3Intent(
            plan: PlaybackV3Plan,
            selectedVersion: FileVersion,
            activeQualityId: String
        ) -> LoadRequest {
            // Shared resolution order; see
            // `PlaybackV3Plan.selectedSubtitleInventoryItem`. An `off` plan
            // selects nothing even if it still carries a stale identity.
            let isSubtitleOff = plan.subtitle.mode == PlaybackProtocolV3.SubtitleMode.off
            let selectedSubtitleIndex = isSubtitleOff
                ? nil
                : plan.selectedSubtitleCombinedIndex
            let selectedSubtitle = isSubtitleOff ? nil : plan.selectedSubtitleInventoryItem
            let embeddedFFmpegIndex: Int? = selectedSubtitle.flatMap { item in
                // A sidecar is the server-selected artifact even when it was
                // extracted from an embedded stream. Arming both identities
                // would publish and select the same subtitle twice.
                guard item.source == "embedded", item.delivery != "sidecar" else { return nil }
                return ApplePlaybackV3PlanAdapter.ffmpegSubtitleStreamIndex(
                    serverCombinedIndex: item.combinedIndex,
                    in: selectedVersion,
                    inventory: plan.subtitle.inventory
                )
            }
            let sidecarTrackId: Int64? = selectedSubtitle.flatMap { item in
                guard item.delivery == "sidecar" else { return nil }
                return SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: item.combinedIndex)
            }
            var request = copyForRecovery(
                preferredFileId: plan.effectiveMediaFileId,
                preferredAudioTrackIndex: plan.selectedTracks.audio?.index,
                preferredSubtitleTrackIndex: embeddedFFmpegIndex,
                preferredSidecarSubtitleTrackId: sidecarTrackId,
                offlineDownloadId: offlineDownloadId
            )
            request.preferredProtocolV3SubtitleIndex = selectedSubtitleIndex
            request.preferredQualityOverride = activeQualityId
            return request
        }
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
        /// Automatic playback recovery. Failures stay on the player surface
        /// instead of using the Next Up postroll.
        case recovery
    }

    private enum BeginFreshLoadError: Error {
        case startSessionTimeout
    }

    private static let autoplayStartSessionTimeout: TimeInterval = 15
    private var lastLoadRequest: LoadRequest?
    private static let nextUpCountdownDefaultSeconds = 10
    private static let nextUpHUDCountdownThresholdSeconds: Double = 100
    private static let introAutoSkipCountdownDefaultSeconds = 5
    static var nextUpCountdownTotal: Int { nextUpCountdownDefaultSeconds }
    private static let nearEndPlaybackErrorThresholdSeconds: Double = 8
    private var nextUpAutoplayCancelled = false
    /// Set when the user taps Keep Watching; suppresses re-presenting the
    /// pre-end Next Up prompt while the playhead stays inside the prompt
    /// window. Cleared when the playhead leaves the window (seek back) or a
    /// new item loads, so the prompt can appear again naturally. Does not
    /// apply to the end-of-playback screen.
    private var nextUpPromptDismissed = false
    private(set) var contentIdsNeedingDetailRefresh: Set<String> = []
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

    /// Re-applies subtitle styling when the user edits the system's
    /// Subtitles & Captioning preferences mid-playback.
    private var systemCaptionObserverToken: NSObjectProtocol?
    /// Triggers a V3 replan when the audio route the session was planned
    /// against changes. iOS/tvOS only — macOS has no `AVAudioSession`.
    private var outputRouteObserverToken: NSObjectProtocol?
    /// Flushes the resume point when the app is about to stop getting
    /// foreground time. The periodic reporter ticks every 10s, so without
    /// this a backgrounded (or terminated) player loses up to that much
    /// progress. Deliberately does not stop the session — PiP and background
    /// audio keep playing after this fires.
    private var foregroundExitObserverToken: NSObjectProtocol?

    init() {
        do {
            aetherPlaybackController = try AetherPlaybackController()
        } catch {
            fatalError("AetherEngine initialization failed: \(error)")
        }
        scrubPreviewProvider = AetherScrubPreviewProvider(
            engine: aetherPlaybackController.engine
        )
        scrubPreviewProvider.onPreview = { [weak self] preview in
            guard let self else { return }
            self.scrubPreviewImage = preview?.image
            self.scrubPreviewImageSourceTime = preview?.sourceTime
        }
        aetherPlaybackController.onEvent = { [weak self] event in
            self?.handleAetherEvent(event)
        }
        aetherPlaybackController.onControllerEvent = { [weak self] event in
            self?.handleAetherControllerEvent(event)
        }
        aetherPlaybackController.onSystemCaptionRequest = { [weak self] epoch, request in
            self?.handleSystemCaptionRequest(epoch: epoch, request: request)
        }
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
                if connected && !wasConnected {
                    self.reconcileMarkersAfterRealtimeConnect()
                }
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
        sleepTimer.configure { [weak self] in
            MainActor.assumeIsolated {
                self?.aetherPlaybackController.pause()
            }
        }

        systemCaptionObserverToken = NotificationCenter.default.addObserver(
            forName: SystemCaptionAppearance.settingsChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isDisposed,
                      self.settings.subtitleMatchesSystemAppearance else { return }
                self.settings.refreshSubtitleSystemAppearance()
                self.applySubtitleAppearanceToPlayer()
                self.subtitleOrderingLanguage = self.settings
                    .subtitleSystemSelectionPreferences.preferredLanguages.first
                guard !self.hasExplicitSubtitleChoice else { return }
                self.prefsForCurrentItem = self.systemCaptionPrefsSnapshot()
                self.prefsResolvedForCurrentItem = false
                self.applyAutoSubtitlePreferencesIfNeeded(forceReevaluation: true)
            }
        }
        #if !os(macOS)
        outputRouteObserverToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let activeProtocolV3 = self.activePreparedProtocolV3,
                      !self.isDisposed,
                      !self.isLoading else { return }
                let observedSnapshot = ApplePlaybackV3Capabilities.snapshot()
                guard PlaybackSessionBridge.isMaterialOutputRouteChange(
                    activeOutputContextId: activeProtocolV3.outputContextId,
                    observedOutputContextId: observedSnapshot.outputContextId
                ) else {
                    Self.logger.debug(
                        "Ignoring AVAudioSession route notification with unchanged Playback V3 output context"
                    )
                    return
                }
                self.attemptProtocolV3Replan(
                    position: self.currentTime,
                    classification: "output_route_changed",
                    message: "The Apple audio output route changed.",
                    outputRouteSnapshot: observedSnapshot
                )
            }
        }
        #endif
        #if os(iOS) || os(tvOS)
        let foregroundExitNotification = UIApplication.didEnterBackgroundNotification
        #else
        let foregroundExitNotification = NSApplication.willTerminateNotification
        #endif
        foregroundExitObserverToken = NotificationCenter.default.addObserver(
            forName: foregroundExitNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushPlaybackProgressNow(reason: "foreground_exit")
            }
        }
        settingsRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshSettingsFromServer()
        }
    }

    /// Best-effort, non-blocking write of the current resume point, outside
    /// the 10s reporting cadence. Used when the app loses the foreground and
    /// on terminal failure, where the next scheduled tick may never run.
    @MainActor
    private func flushPlaybackProgressNow(reason: String) {
        guard !isDisposed else { return }
        if let offline = offlinePlaybackContext {
            recordOfflineProgress(context: offline)
            return
        }
        guard activePlaybackSessionId != nil else { return }
        let position = currentTime
        guard position.isFinite, position >= 0 else { return }
        let isPaused = !isPlaying
        Self.logger.debug("Flushing playback progress (\(reason, privacy: .public))")
        Task { [sessionBridge] in
            _ = await sessionBridge.reportProgress(position: position, isPaused: isPaused)
        }
    }

    @MainActor
    private func handleAetherEvent(_ scopedEvent: AetherPlaybackController.ScopedEvent) {
        guard !isDisposed, scopedEvent.epoch == activeAetherLoadEpoch else { return }
        switch scopedEvent.event {
        case .state(let state):
            switch state {
            case .playing:
                isPlaying = true
                pushNowPlayingSnapshot()
                // An audio-only load has no picture, so Aether's audio route
                // never latches `hasFirstFrameReadyForDisplay` and the
                // `.firstFrame` milestone below never arrives. The audio route
                // reaching playback is the equivalent milestone; without it
                // these loads would never start progress reporting and would
                // lose their server session mid-listen.
                if isAudioOnlyAetherLoad {
                    handleAetherStartupMilestone(epoch: scopedEvent.epoch)
                }
            case .paused:
                isPlaying = false
                pushNowPlayingSnapshot()
            case .idle, .ended, .error:
                isPlaying = false
            case .loading, .seeking:
                break
            }
        case .phase(let phase):
            switch phase {
            case .loading, .rebuffering, .stalled:
                isLoading = true
            case .playing, .paused, .seeking, .ended, .idle, .error:
                isLoading = false
            }
            refreshPlaybackStats(force: true)
        case .playerTime(let playerSeconds):
            guard !hasReachedEndOfFile,
                  playerSeconds.isFinite,
                  let timeline = aetherPlaybackController.activeSpec?.timeline else { return }
            let movieTime = timeline.sourcePosition(forPlayerTime: playerSeconds)
            if Self.isUnexpectedBackwardPlaybackTime(
                movieTime,
                currentTime: currentTime,
                explicitSeekInFlight: seekTargetTime != nil
            ) {
                pushNowPlayingIfDue()
                return
            }
            if let origin = seekOriginTime, let target = seekTargetTime {
                if abs(movieTime - origin) < abs(movieTime - target) {
                    pushNowPlayingIfDue()
                    return
                }
                seekOriginTime = nil
                seekTargetTime = nil
                seekFilterTimeoutTask?.cancel()
                seekFilterTimeoutTask = nil
            }
            currentTime = movieTime
            updateNextUpPresentation(for: movieTime)
            autoSkipIntroIfNeeded(at: movieTime)
            autoSkipCreditsIfNeeded(at: movieTime)
            pushNowPlayingIfDue()
            refreshPlaybackStats()
        case .duration(let reportedDuration):
            // Aether reports duration on the player/transport axis, while
            // `currentTime` (and every marker, chapter and progress report
            // derived from it) is on the source axis. Adopting the raw value
            // under an HLS reanchor would shorten the scrubber by exactly the
            // timeline offset, so convert before publishing.
            if duration <= 0, reportedDuration.isFinite, reportedDuration > 0 {
                if let timeline = aetherPlaybackController.activeSpec?.timeline {
                    duration = timeline.sourcePosition(forPlayerTime: reportedDuration)
                } else {
                    duration = reportedDuration
                }
            }
        case .buffering(let buffering):
            isBuffering = buffering
            refreshPlaybackStats(force: true)
        case .firstFrame:
            handleAetherStartupMilestone(epoch: scopedEvent.epoch)
        case .inventoryChanged:
            adoptAetherInventory()
            refreshPlaybackStats(force: true)
        case .telemetryChanged:
            refreshPlaybackStats(force: true)
        case .ended:
            handleEndOfFile()
            refreshPlaybackStats(force: true)
        case .failure(let failure):
            handleAetherFailure(failure)
        case .transportRestoreFailed(let message):
            // The engine tore its media session down in the background and the
            // rebuild for this Play failed. That is a source failure like any
            // other post-load one — the committed plan may simply have expired
            // while suspended — so it goes through the same recovery boundary
            // (replan / stale-session renewal) instead of straight to the
            // terminal wall. `handlePlaybackError` still finalizes the cases
            // that genuinely have nowhere left to go.
            handlePlaybackError(message)
        }
    }

    @MainActor
    private func handleAetherControllerEvent(_ event: AetherPlaybackController.ControllerEvent) {
        guard !isDisposed else { return }
        switch event {
        case .systemMediaChanged:
            syncNowPlayingDestination()
            refreshPlaybackStats(force: true)
        case .externalPlaybackChanged(let supported, let active):
            supportsExternalPlayback = supported
            isExternalPlaybackActive = active
            refreshPlaybackStats(force: true)
        }
    }

    private func refreshPlaybackStats(force: Bool = false) {
        guard let spec = aetherPlaybackController.activeSpec else {
            playbackStats = .empty
            bufferedAheadSeconds = 0
            return
        }

        let sampledAt = Date()
        if !force,
           playbackStats.hasRows,
           sampledAt.timeIntervalSince(playbackStats.sampledAt) < 0.9 {
            return
        }

        let secondaryLabel = selectedSecondarySubtitleId.flatMap { selectedID in
            subtitleTracks.first { $0.trackId == selectedID }?.primaryLabel
        }
        let playbackPlan = activePreparedProtocolV3?.plan
        let source = AetherPlaybackStatsSourceMetadata(
            sourceURL: spec.sourceURL,
            delivery: spec.delivery,
            container: currentSelectedVersion?.container,
            playbackRate: isHoldFastForwarding ? 2 : settings.playbackSpeed,
            secondarySubtitleLabel: secondaryLabel,
            plannedSourceDynamicRange: playbackPlan?.source.dynamicRange,
            plannedOutputDynamicRange: playbackPlan?.effectiveRecipe.dynamicRange,
            plannedSourceDolbyVisionProfile: playbackPlan?.source.dolbyVisionProfile
        )
        let snapshot = AetherPlaybackStatsSnapshot(
            engine: aetherPlaybackController.engine
        )
        let projected = AetherPlaybackStatsProjection.make(
            snapshot: snapshot,
            source: source,
            sampledAt: sampledAt
        )
        playbackStats = projected
        bufferedAheadSeconds = max(0, projected.bufferedAheadSeconds ?? 0)
    }

    @MainActor
    private func handleAetherFailure(_ failure: PlaybackErrorInfo) {
        if failure.kind == .audioTrackSwitchFailed {
            // The engine tore its pipeline down for the switch and the rebuild
            // failed, so there is nothing left playing whatever the phase. It
            // also restored `activeAudioTrackIndex`, so republish the engine's
            // truth before any recovery re-reads the selection.
            lastAetherAudioTrackSwitchFailure = failure
            selectedAudioId = aetherPlaybackController.engine.activeAudioTrackIndex
                .map(Int64.init)
            isBuffering = false
            bufferingProgress = nil
            isQualitySwitching = false
            if freshLoadOwnsFailureHandling || !isAetherLoadEstablished {
                // The load this switch killed is unwinding right now;
                // `resolveAbandonedAetherLoad` turns its cancellation into this
                // failure so exactly one handler recovers it.
                return
            }
            // Mid-playback, after the load was established: the switch was an
            // explicit pick, so recover the session the same way any other
            // post-load engine failure is recovered rather than stranding the
            // user on a spinner.
            showNotice(
                title: "Couldn't change audio",
                message: "The audio track couldn't be switched. The previous track was kept.",
                tone: .warning,
                duration: 5
            )
            handlePlaybackError(failure.message, failure: failure)
            return
        }
        // Aether deliberately publishes its typed failure *before* the load
        // throws, so every in-flight load would otherwise be handled twice:
        // once here and once in the load's own catch. The owning load task is
        // the single handler on every path — V3, direct play and offline
        // alike — because only it knows the load's origin, and therefore
        // whether the failure gets the full-screen wall or the recoverable
        // Next Up surface.
        if freshLoadOwnsFailureHandling {
            return
        }
        if activePreparedProtocolV3 != nil,
           committedProtocolV3LoadEpoch == nil {
            // Same rule for a replan's load: it owns provisional-route
            // recovery, and reacting here too would start two competing
            // replans.
            return
        }
        if attemptProtocolV3AuthenticationReload(after: failure) {
            return
        }
        let serverCanAdapt: Set<PlaybackErrorKind> = [
            .sourceRefused,
            .vodSourceFailed,
            .nativeItemFailed,
            .noPlayableTrackWithinBudget,
            .masterPlaylistRejected,
            .softwarePipelineFailed,
            .audioBridgeProducedNoOutput,
            .dolbyVisionRequiresHardware,
            .demuxedAudioLiveUnsupported,
        ]
        // Aether publishes errorInfo before a throwing load returns. Only the
        // owning load task may recover a provisional plan; starting a second
        // replan here would race its rollback/route-ladder handling.
        if serverCanAdapt.contains(failure.kind),
           activePreparedProtocolV3 != nil,
           committedProtocolV3LoadEpoch != nil {
            attemptProtocolV3Replan(
                position: currentTime,
                classification: failure.kind.rawValue,
                message: failure.message
            )
            return
        }
        if failure.kind == .sourceRateLimited {
            showNotice(
                title: "Playback delayed",
                message: "The media source is rate limiting requests. Try again in a moment.",
                tone: .info,
                duration: 5
            )
            return
        }
        handlePlaybackError(failure.message, failure: failure)
    }

    /// Whether the active load asked Aether for its audio-only route, which
    /// publishes no video-display signal at all.
    private var isAudioOnlyAetherLoad: Bool {
        aetherPlaybackController.activeSpec?.options.audioOnly == true
    }

    /// The single place a load's startup milestone is taken.
    ///
    /// Latched per epoch, because the milestone has two sources that must
    /// never both count: Aether's first frame for anything with a picture, and
    /// the audio route starting for an audio-only load. Everything a started
    /// load owes the server — progress reporting, keepalives, the Playback V3
    /// first-frame report — hangs off this one call.
    private func handleAetherStartupMilestone(epoch: AetherPlaybackController.LoadEpoch) {
        guard startedAetherLoadEpoch != epoch else { return }
        startedAetherLoadEpoch = epoch
        handleFileLoaded()
        if activePreparedProtocolV3 != nil {
            pendingProtocolV3FirstFrameEpoch = epoch
            completeProtocolV3FirstFrameIfCommitted(epoch)
        } else {
            startProgressReporting()
        }
        refreshPlaybackStats(force: true)
    }

    private func handleFileLoaded() {
        hasReachedEndOfFile = false
        error = nil
        isLoading = false
        isPlaying = true
        applySettingsToPlayer()
        Self.logger.info(
            "[CMP-SUB] file loaded engine=AetherEngine route=\(self.activeRouteLabel, privacy: .public) pendingExternal=\(self.pendingExternalSubtitles.count, privacy: .public) tracks=\(self.subtitleTracks.count, privacy: .public)"
        )
        loadPendingExternalSubtitles()
        hideControlsTask?.cancel()
        showControls = false
        nowPlaying.update(
            title: title,
            duration: duration,
            position: currentTime,
            isPlaying: true,
            playbackRate: settings.playbackSpeed
        )
    }

    /// Aether may publish its first-frame flag synchronously while the server
    /// plan is still provisional. Hold that observation until the owning load
    /// and bridge transition both commit so a failed/cancelled candidate never
    /// appears as successfully presented in Playback V3 telemetry.
    private func markProtocolV3AetherLoadCommitted() {
        guard activePreparedProtocolV3 != nil,
              let epoch = activeAetherLoadEpoch else { return }
        committedProtocolV3LoadEpoch = epoch
        completeProtocolV3FirstFrameIfCommitted(epoch)
    }

    private func completeProtocolV3FirstFrameIfCommitted(
        _ epoch: AetherPlaybackController.LoadEpoch
    ) {
        guard committedProtocolV3LoadEpoch == epoch,
              pendingProtocolV3FirstFrameEpoch == epoch,
              let planId = activePreparedProtocolV3?.plan.planId,
              let sessionId = activePlaybackSessionId else { return }
        pendingProtocolV3FirstFrameEpoch = nil
        startProgressReporting()
        Task { [sessionBridge] in
            await sessionBridge.reportProtocolV3FirstFrame(
                planId: planId,
                sessionId: sessionId,
                milliseconds: nil
            )
        }
    }

    private func handlePlaybackError(_ message: String, failure: PlaybackErrorInfo? = nil) {
        let logMessage = MediaLogRedactor.sanitize(message)
        Self.logger.error("Player error: \(logMessage, privacy: .public)")
        guard !hasReachedEndOfFile else {
            Self.logger.info("Ignoring playback error after EOF: \(logMessage, privacy: .public)")
            return
        }
        if shouldTreatPlaybackErrorAsNaturalEnd() {
            Self.logger.info("Treating near-end playback error as EOF: \(logMessage, privacy: .public)")
            handleEndOfFile()
            return
        }
        if activePreparedProtocolV3 != nil,
           committedProtocolV3LoadEpoch != nil {
            attemptProtocolV3Recovery(after: message)
            return
        }
        if isPlaybackSessionMissingMessage(message) || isExpiredPlaybackSessionSource(failure) {
            if attemptStaleSessionRenewal(reason: "player_error", observedPosition: currentTime) {
                return
            }
        }
        progressTask?.cancel()
        finalizeTerminalPlaybackError(message)
    }

    private func attemptProtocolV3Recovery(after message: String) {
        attemptProtocolV3Replan(
            position: currentTime,
            classification: protocolV3FailureClassification(message),
            message: message
        )
    }

    /// Rebuilds the committed plan with the account bearer currently held by
    /// `ContinuumAPI`. Protocol V3 media URLs are stable across access-token
    /// refreshes, but Aether/AVPlayer freezes request headers at asset load.
    /// A normal authenticated progress request first gives the shared HTTP
    /// client a chance to refresh an expired token; the reload proceeds only
    /// when that produced a different Authorization value.
    @discardableResult
    private func attemptProtocolV3AuthenticationReload(
        after failure: PlaybackErrorInfo
    ) -> Bool {
        guard AetherAuthenticationRecoveryPolicy.isExpiredBearerFailure(failure),
              protocolV3ReplanTask == nil,
              let protocolV3 = activePreparedProtocolV3,
              protocolV3.serverFeatures.contains(
                  PlaybackProtocolV3.headerAuthenticatedMediaFeature
              ),
              let sessionId = activePlaybackSessionId,
              let watchDetail = currentWatchDetail,
              let selectedVersion = currentSelectedVersion,
              let failedSpec = aetherPlaybackController.activeSpec,
              failedSpec.planID == protocolV3.plan.planId,
              failedSpec.sessionID == sessionId,
              committedProtocolV3LoadEpoch != nil else {
            return false
        }

        let planId = protocolV3.plan.planId
        let resumePosition = currentTime.isFinite ? max(0, currentTime) : 0
        let failedHeaders = failedSpec.options.httpHeaders
        let fallbackClassification = failure.kind.rawValue
        let fallbackMessage = failure.message

        progressTask?.cancel()
        progressTask = nil
        isLoading = true
        isBuffering = false
        bufferingProgress = nil
        streamLoadGeneration &+= 1
        let recoveryGeneration = streamLoadGeneration

        Self.logger.warning(
            "Protocol V3 media credential expired; refreshing and reloading plan \(planId, privacy: .public) at source position \(resumePosition, privacy: .public)"
        )

        protocolV3ReplanTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            var shouldFallbackToReplan = true
            defer {
                self.protocolV3ReplanTask = nil
                if !self.isDisposed,
                   recoveryGeneration == self.streamLoadGeneration {
                    if shouldFallbackToReplan {
                        if !self.attemptProtocolV3Replan(
                            position: resumePosition,
                            classification: fallbackClassification,
                            message: fallbackMessage
                        ) {
                            self.finalizeTerminalPlaybackError(fallbackMessage)
                        }
                    } else if let queuedTrackChange = self.pendingProtocolV3TrackChange {
                        self.pendingProtocolV3TrackChange = nil
                        self.attemptProtocolV3Replan(
                            position: self.currentTime,
                            classification: queuedTrackChange.classification,
                            message: queuedTrackChange.message,
                            requeueWhenBusy: true,
                            trackTarget: queuedTrackChange.target
                        )
                    } else if let queuedTarget = self.pendingProtocolV3SeekReanchorPosition {
                        self.pendingProtocolV3SeekReanchorPosition = nil
                        self.commitSeek(to: queuedTarget, source: "queuedAuthReloadReanchor")
                    }
                }
            }

            do {
                // This request uses the normal API transport, whose 401 path
                // refreshes TokenStore before retrying. Its result is otherwise
                // best-effort; the header comparison below is authoritative.
                _ = await self.sessionBridge.reportProgress(
                    position: resumePosition,
                    isPaused: !self.aetherPlaybackController.shouldPlayWhenReady
                )
                try self.requireCurrentStreamLoad(recoveryGeneration)
                guard self.activePlaybackSessionId == sessionId,
                      self.activePreparedProtocolV3?.plan.planId == planId,
                      let session = await self.sessionBridge.committedProtocolV3Session(
                          planId: planId,
                          sessionId: sessionId
                      ) else {
                    throw CancellationError()
                }
                try self.requireCurrentStreamLoad(recoveryGeneration)

                let prepared = PreparedPlayback(
                    watchDetail: watchDetail,
                    selectedVersion: selectedVersion,
                    session: session,
                    activeQualityId: self.activeQualityId,
                    protocolV3: protocolV3
                )
                guard let streamRequest = await self.makeStreamRequest(
                    session: session,
                    additionalHeaders: protocolV3.plan.stream.headers,
                    requiresHeaderAuthenticatedMedia: true,
                    allowsAuthorizedMediaOrigins:
                        protocolV3.negotiatedAuthorizedMediaOrigins
                ) else {
                    throw AetherLoadSpec.ValidationError.invalidStreamURL(session.streamUrl)
                }
                try self.requireCurrentStreamLoad(recoveryGeneration)
                guard AetherAuthenticationRecoveryPolicy.shouldReload(
                    failedHeaders: failedHeaders,
                    refreshedHeaders: streamRequest.headers
                ) else {
                    Self.logger.warning(
                        "Protocol V3 media credential did not change; using bounded route recovery"
                    )
                    return
                }

                // A local in-window seek can finish while the refresh request
                // is suspended. Sample the source-axis position again at the
                // last synchronous point before beginLoad replaces the epoch,
                // so credential recovery never jumps back over that seek.
                let reloadPosition = self.currentTime.isFinite
                    ? max(0, self.currentTime)
                    : resumePosition
                let shouldPlayWhenReady = self.aetherPlaybackController.shouldPlayWhenReady
                self.resolvedServerUrl = streamRequest.serverUrl
                try await self.loadAether(
                    prepared: prepared,
                    streamRequest: streamRequest,
                    expectedStreamLoadGeneration: recoveryGeneration,
                    resumeSourcePosition: reloadPosition,
                    shouldPlayWhenReady: shouldPlayWhenReady
                )
                try self.requireCurrentStreamLoad(recoveryGeneration)
                guard self.activePlaybackSessionId == sessionId,
                      self.activePreparedProtocolV3?.plan.planId == planId else {
                    throw CancellationError()
                }
                self.markProtocolV3AetherLoadCommitted()
                shouldFallbackToReplan = false
                Self.logger.info(
                    "Protocol V3 media credential reload succeeded for plan \(planId, privacy: .public)"
                )
            } catch is CancellationError {
                shouldFallbackToReplan = false
            } catch {
                Self.logger.error(
                    "Protocol V3 media credential reload failed; using bounded route recovery: \(MediaLogRedactor.sanitize(error), privacy: .public)"
                )
            }
        }
        return true
    }

    /// The track a queued change is actually asking for. `.subtitle(nil)` is
    /// "turn subtitles off", which is why this is an enum and not two optional
    /// ids.
    ///
    /// Each case carries both the Aether `trackId` the user tapped and the
    /// server-side identity the deferred replan will actually be resolved from
    /// — the audio selection ordinal (`srcId ?? ffIndex`) and the subtitle
    /// combined index. The interim replan can repackage streams, so an Aether
    /// id recorded before it can vanish or land on a different stream by drain
    /// time; the server identity is what `resolvedAudioTrackIndexForResume` /
    /// `resolvedProtocolV3SubtitleIndexForResume` send, and it survives that.
    private enum QueuedProtocolV3TrackTarget {
        case audio(trackId: Int64, selectionIndex: Int?)
        case subtitle(trackId: Int64?, combinedIndex: Int?)
    }

    /// Server-side ordinal a queued audio pick must resolve back to.
    private func queuedTrackTarget(forAudio track: PlayerTrack) -> QueuedProtocolV3TrackTarget {
        .audio(trackId: track.trackId, selectionIndex: audioSelectionIndex(for: track))
    }

    /// Server-side combined subtitle index a queued subtitle pick must resolve
    /// back to. Nil for live AI tracks and anything the current plan cannot
    /// place, which simply leaves the id as the only matcher.
    private func queuedTrackTarget(
        forSubtitle track: PlayerTrack
    ) -> QueuedProtocolV3TrackTarget {
        .subtitle(
            trackId: track.trackId,
            combinedIndex: serverCombinedSubtitleIndex(for: track)
        )
    }

    private func serverCombinedSubtitleIndex(for track: PlayerTrack) -> Int? {
        guard !SubtitleTrackIdSpace.isAILive(track.trackId),
              let version = currentSelectedVersion else { return nil }
        return ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
            for: track,
            in: version,
            inventory: activePreparedProtocolV3?.plan.subtitle.inventory ?? []
        )
    }

    /// A track change deferred until the in-flight replan settles. Position
    /// is deliberately absent: it is re-read when the queue drains, because
    /// playback keeps moving while the earlier replan completes.
    ///
    /// The target, unlike the position, is *not* re-read. The in-flight replan
    /// publishes its own plan's inventory on the way through, and
    /// `adoptAetherInventory` republishes `selectedAudioId`/`selectedSubtitleId`
    /// from the engine as it does — so by drain time the optimistic selection
    /// the user's tap wrote has been overwritten by the interim plan's. A
    /// deferred replan that re-read the selection would therefore ask the
    /// server for the track the user was already on and silently drop the tap.
    private struct QueuedProtocolV3TrackChange {
        let classification: String
        let message: String
        let target: QueuedProtocolV3TrackTarget?
    }

    /// Re-publishes a queued track pick just before the deferred replan reads
    /// the selection back, undoing any interim `adoptAetherInventory`.
    ///
    /// The recorded Aether id is tried first; if the interim plan repackaged
    /// the streams and that id is gone, the pick is re-found by the server
    /// identity captured at queue time — the same ordinal the replan would
    /// have sent — so a renumbered stream still restores the user's tap.
    ///
    /// A target that resolves to neither is dropped rather than forced: the
    /// interim plan may not carry that track at all, and a selection pointing
    /// at nothing resolves to no index, which is a worse answer than the one
    /// the engine is actually rendering.
    private func restoreQueuedProtocolV3TrackSelection(
        _ target: QueuedProtocolV3TrackTarget
    ) {
        switch target {
        case .audio(let trackId, let selectionIndex):
            let resolved = audioTracks.first { $0.trackId == trackId }
                ?? selectionIndex.flatMap { wanted in
                    audioTracks.first { audioSelectionIndex(for: $0) == wanted }
                }
            guard let resolved, selectedAudioId != resolved.trackId else { return }
            pendingAudioFfIndex = nil
            selectedAudioId = resolved.trackId
            reapplySystemSubtitlePolicy()
        case .subtitle(let trackId, let combinedIndex):
            guard let trackId else {
                guard selectedSubtitleId != nil else { return }
                pendingSubtitleFfIndex = nil
                hasExplicitSubtitleChoice = true
                selectedSubtitleId = nil
                return
            }
            let resolved = subtitleTracks.first { $0.trackId == trackId }
                ?? combinedIndex.flatMap { wanted in
                    subtitleTracks.first { serverCombinedSubtitleIndex(for: $0) == wanted }
                }
            guard let resolved, selectedSubtitleId != resolved.trackId else { return }
            pendingSubtitleFfIndex = nil
            hasExplicitSubtitleChoice = true
            selectedSubtitleId = resolved.trackId
        }
    }

    @discardableResult
    private func attemptProtocolV3Replan(
        position: Double,
        classification: String,
        message: String,
        operation: String? = nil,
        qualityPreference: String? = nil,
        completesQualitySwitch: Bool = false,
        requeueWhenBusy: Bool = false,
        trackTarget: QueuedProtocolV3TrackTarget? = nil,
        outputRouteSnapshot: ApplePlaybackV3CapabilitySnapshot? = nil
    ) -> Bool {
        // One classification of the user's target. A track change must have a
        // stable server ordinal before it is queued or issued: falling back to
        // the currently published engine selection would turn an unmappable tap
        // into a successful replan for the track that was already playing.
        //
        // The dimension the user did not touch stays `nil` here and is read
        // back from the player below, after any queued pick is re-published.
        let explicitAudioTrackIndex: Int?
        let explicitSubtitleTrackIndex: Int?
        let targetsSubtitle: Bool
        switch trackTarget {
        case .audio(_, nil), .subtitle(.some, nil):
            return false
        case .audio(_, let selectionIndex):
            explicitAudioTrackIndex = selectionIndex
            explicitSubtitleTrackIndex = nil
            targetsSubtitle = false
        case .subtitle(let trackId, let combinedIndex):
            explicitAudioTrackIndex = nil
            // Nil subtitle with a nil track id is explicit Off.
            explicitSubtitleTrackIndex = trackId == nil ? nil : combinedIndex
            targetsSubtitle = true
        case nil:
            explicitAudioTrackIndex = nil
            explicitSubtitleTrackIndex = nil
            targetsSubtitle = false
        }
        if protocolV3ReplanTask != nil {
            if operation == PlaybackProtocolV3.ReplanOperation.seekReanchor {
                // Rapid windowed seeks are latest-wins. Re-issue the newest
                // target after the in-flight route transition settles.
                pendingProtocolV3SeekReanchorPosition = position
                return true
            }
            if requeueWhenBusy {
                // A user track change. The UI already shows the new
                // selection, so dropping the switch here would leave the
                // player permanently disagreeing with itself. Latest-wins,
                // same as a seek: re-issued when the in-flight replan
                // settles, at whatever position playback has reached by then.
                pendingProtocolV3TrackChange = QueuedProtocolV3TrackChange(
                    classification: classification,
                    message: message,
                    target: trackTarget
                )
                return true
            }
            if completesQualitySwitch { isQualitySwitching = false }
            return false
        }
        guard let watchDetail = currentWatchDetail else {
            if completesQualitySwitch { isQualitySwitching = false }
            return false
        }
        // This replan is about to read the current selection back. On the
        // deferred path that selection may have been republished from the
        // interim plan's inventory while the user's pick waited, so reassert
        // the pick first. On the direct path the pick is already published and
        // this is a no-op.
        if let trackTarget {
            restoreQueuedProtocolV3TrackSelection(trackTarget)
        }
        let selectedSubtitleSnapshot = selectedSubtitleId
        // The user-facing selection can be republished from Aether while the
        // async replan task is waiting to start (inventory/store discovery is
        // still active after a replacement load). A user track change already
        // carries the stable server identity captured at tap time; freeze the
        // request indices here instead of re-reading mutable player state from
        // inside the task.
        let requestedAudioTrackIndex = explicitAudioTrackIndex
            ?? resolvedAudioTrackIndexForResume()
        let requestedSubtitleTrackIndex = targetsSubtitle
            ? explicitSubtitleTrackIndex
            : resolvedProtocolV3SubtitleIndexForResume()
        if targetsSubtitle {
            cmpLog(
                "[CMP-SUB] phase=replan_request requested_index="
                    + (requestedSubtitleTrackIndex.map(String.init) ?? "off")
            )
        }
        progressTask?.cancel()
        isLoading = true
        isBuffering = false
        bufferingProgress = nil
        streamLoadGeneration &+= 1
        let currentStreamLoadGeneration = streamLoadGeneration
        protocolV3ReplanTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            let priorActivePlaybackSessionId = self.activePlaybackSessionId
            let priorAetherLoadEpoch = self.activeAetherLoadEpoch
            let priorWatchDetail = self.currentWatchDetail
            let priorSelectedVersion = self.currentSelectedVersion
            let priorPreparedProtocolV3 = self.activePreparedProtocolV3
            let priorLastLoadRequest = self.lastLoadRequest
            let priorPendingAudioFfIndex = self.pendingAudioFfIndex
            let priorPendingSubtitleFfIndex = self.pendingSubtitleFfIndex
            let priorPendingSidecarSubtitleTrackId = self.pendingSidecarSubtitleTrackId
            let priorPendingServerRenderedSubtitleTrackId = self.pendingServerRenderedSubtitleTrackId
            let priorPendingExternalSubtitles = self.pendingExternalSubtitles
            let priorKnownExternalSubtitles = self.knownExternalSubtitles
            let priorDuration = self.duration
            let priorCurrentTime = self.currentTime
            let priorActiveQualityId = self.activeQualityId
            let priorQualityOptions = self.qualityOptions
            let priorResolvedServerUrl = self.resolvedServerUrl
            let priorPrefsForCurrentItem = self.prefsForCurrentItem
            let priorPrefsResolvedForCurrentItem = self.prefsResolvedForCurrentItem
            var uncommittedPrepared: PreparedPlayback?
            var chainedLoadFailureRecovery: (position: Double, classification: String, message: String)?
            defer {
                self.protocolV3ReplanTask = nil
                if completesQualitySwitch { self.isQualitySwitching = false }
                if let recovery = chainedLoadFailureRecovery {
                    self.attemptProtocolV3Replan(
                        position: recovery.position,
                        classification: recovery.classification,
                        message: recovery.message
                    )
                } else if let queuedTrackChange = self.pendingProtocolV3TrackChange {
                    // Drained before the queued seek: this replan will pick
                    // up any still-pending reanchor in its own defer, so both
                    // user intents survive and the seek lands last.
                    self.pendingProtocolV3TrackChange = nil
                    if !self.isDisposed, self.activePreparedProtocolV3 != nil {
                        self.attemptProtocolV3Replan(
                            position: self.currentTime,
                            classification: queuedTrackChange.classification,
                            message: queuedTrackChange.message,
                            requeueWhenBusy: true,
                            trackTarget: queuedTrackChange.target
                        )
                    }
                } else if let queuedTarget = self.pendingProtocolV3SeekReanchorPosition {
                    self.pendingProtocolV3SeekReanchorPosition = nil
                    if !self.isDisposed, self.activePreparedProtocolV3 != nil {
                        self.commitSeek(to: queuedTarget, source: "queuedReanchor")
                    }
                }
            }
            do {
                guard let prepared = try await self.sessionBridge.replanProtocolV3(
                    watchDetail: watchDetail,
                    position: position,
                    classification: classification,
                    message: message,
                    operation: operation,
                    qualityPreference: qualityPreference,
                    audioTrackIndex: requestedAudioTrackIndex,
                    subtitleTrackIndex: requestedSubtitleTrackIndex,
                    outputRouteSnapshot: outputRouteSnapshot
                ) else {
                    self.finalizeTerminalPlaybackError(message)
                    return
                }
                if targetsSubtitle {
                    cmpLog(
                        "[CMP-SUB] phase=replan_response selected_index="
                            + (prepared.protocolV3?.plan.selectedTracks.subtitle?.index.map(String.init) ?? "off")
                            + " mode="
                            + (prepared.protocolV3?.plan.subtitle.mode ?? "unknown")
                    )
                }
                uncommittedPrepared = prepared
                guard !Task.isCancelled,
                      !self.isDisposed,
                      currentStreamLoadGeneration == self.streamLoadGeneration else {
                    throw CancellationError()
                }

                let previousSessionId = self.activePlaybackSessionId
                self.activePlaybackSessionId = prepared.session.sessionId
                self.currentWatchDetail = prepared.watchDetail
                self.currentSelectedVersion = prepared.selectedVersion
                self.activePreparedProtocolV3 = prepared.protocolV3
                self.adoptProtocolV3RenewalIntent(from: prepared)
                switch Self.protocolV3SidecarRestoreIntent(
                    snapshot: selectedSubtitleSnapshot,
                    selectedSubtitleIndex: prepared.protocolV3?.plan.selectedTracks.subtitle?.index,
                    subtitleMode: prepared.protocolV3?.plan.subtitle.mode
                ) {
                case .renderLocally(let trackId):
                    self.pendingSidecarSubtitleTrackId = trackId
                    self.pendingServerRenderedSubtitleTrackId = nil
                case .serverRendered(let trackId):
                    self.pendingSidecarSubtitleTrackId = nil
                    self.pendingServerRenderedSubtitleTrackId = trackId
                case nil:
                    self.pendingServerRenderedSubtitleTrackId = nil
                }
                self.pendingExternalSubtitles = prepared.session.subtitleUrls ?? []
                self.knownExternalSubtitles = self.pendingExternalSubtitles
                self.duration = prepared.session.durationSeconds ?? prepared.selectedVersion.duration ?? self.duration
                self.currentTime = self.movieTime(for: prepared.session)
                self.activeQualityId = prepared.activeQualityId
                self.qualityOptions = ApplePlaybackQuality.playbackOptions(
                    serverQualities: prepared.protocolV3?.plan.availableQualities ?? [],
                    fallbackVersion: prepared.selectedVersion
                )

                try self.requireCurrentStreamLoad(currentStreamLoadGeneration)
                guard let streamRequest = await self.makeStreamRequest(
                    session: prepared.session,
                    additionalHeaders: prepared.protocolV3?.plan.stream.headers ?? [:],
                    requiresHeaderAuthenticatedMedia: prepared.protocolV3?.serverFeatures.contains(
                        PlaybackProtocolV3.headerAuthenticatedMediaFeature
                    ) == true,
                    allowsAuthorizedMediaOrigins:
                        prepared.protocolV3?.negotiatedAuthorizedMediaOrigins == true
                ) else {
                    throw AetherLoadSpec.ValidationError.invalidStreamURL(prepared.session.streamUrl)
                }
                try self.requireCurrentStreamLoad(currentStreamLoadGeneration)
                self.resolvedServerUrl = streamRequest.serverUrl
                let shouldPlayWhenReady = self.aetherPlaybackController.shouldPlayWhenReady
                try await self.loadAether(
                    prepared: prepared,
                    streamRequest: streamRequest,
                    expectedStreamLoadGeneration: currentStreamLoadGeneration,
                    shouldPlayWhenReady: shouldPlayWhenReady
                )
                guard await self.sessionBridge.commitPendingProtocolV3Transition(prepared) else {
                    throw CancellationError()
                }
                self.markProtocolV3AetherLoadCommitted()
                uncommittedPrepared = nil
                if completesQualitySwitch {
                    self.lastLoadRequest?.preferredQualityOverride = prepared.activeQualityId
                }
                if previousSessionId != prepared.session.sessionId {
                    await self.realtimeClient.unbind()
                    await self.realtimeClient.bind(sessionId: prepared.session.sessionId)
                }
                await self.sessionBridge.reportProtocolV3PlanExecutionStarted(prepared)
            } catch is CancellationError {
                // Same rule as the fresh-load arm: an abandoned replan load
                // must not leave the engine reading a retired session. Only
                // once `loadAether` moved the epoch does the engine hold the
                // candidate source; before that the prior source still plays.
                if currentStreamLoadGeneration == self.streamLoadGeneration,
                   self.activeAetherLoadEpoch != priorAetherLoadEpoch {
                    _ = self.disposeAetherPlayback()
                }
                if let uncommittedPrepared {
                    await self.sessionBridge.rollbackPendingProtocolV3Transition(uncommittedPrepared)
                }
                if currentStreamLoadGeneration == self.streamLoadGeneration {
                    self.activePlaybackSessionId = priorActivePlaybackSessionId
                    self.currentWatchDetail = priorWatchDetail
                    self.currentSelectedVersion = priorSelectedVersion
                    self.activePreparedProtocolV3 = priorPreparedProtocolV3
                    self.lastLoadRequest = priorLastLoadRequest
                    self.pendingAudioFfIndex = priorPendingAudioFfIndex
                    self.pendingSubtitleFfIndex = priorPendingSubtitleFfIndex
                    self.pendingSidecarSubtitleTrackId = priorPendingSidecarSubtitleTrackId
                    self.pendingServerRenderedSubtitleTrackId = priorPendingServerRenderedSubtitleTrackId
                    self.pendingExternalSubtitles = priorPendingExternalSubtitles
                    self.knownExternalSubtitles = priorKnownExternalSubtitles
                    self.duration = priorDuration
                    self.currentTime = priorCurrentTime
                    self.activeQualityId = priorActiveQualityId
                    self.qualityOptions = priorQualityOptions
                    self.resolvedServerUrl = priorResolvedServerUrl
                    self.prefsForCurrentItem = priorPrefsForCurrentItem
                    self.prefsResolvedForCurrentItem = priorPrefsResolvedForCurrentItem
                }
                return
            } catch {
                let loadFailure = self.protocolV3LoadFailureRecovery(error)
                if let uncommittedPrepared {
                    if loadFailure.shouldAdvanceRoute {
                        // Aether rejected the replacement before it could
                        // commit. Preserve that exact failed plan as the V3
                        // attempt being reported, then advance the bounded
                        // route ladder. No realtime/first-frame/success event
                        // is published.
                        if await self.sessionBridge.promotePendingProtocolV3TransitionForRecovery(
                            uncommittedPrepared
                        ) {
                            chainedLoadFailureRecovery = (
                                position,
                                loadFailure.classification,
                                loadFailure.message
                            )
                            return
                        }
                    }
                    await self.sessionBridge.rollbackPendingProtocolV3Transition(uncommittedPrepared)
                }
                if currentStreamLoadGeneration == self.streamLoadGeneration {
                    self.activePlaybackSessionId = priorActivePlaybackSessionId
                    self.currentWatchDetail = priorWatchDetail
                    self.currentSelectedVersion = priorSelectedVersion
                    self.activePreparedProtocolV3 = priorPreparedProtocolV3
                    self.lastLoadRequest = priorLastLoadRequest
                    self.pendingAudioFfIndex = priorPendingAudioFfIndex
                    self.pendingSubtitleFfIndex = priorPendingSubtitleFfIndex
                    self.pendingSidecarSubtitleTrackId = priorPendingSidecarSubtitleTrackId
                    self.pendingServerRenderedSubtitleTrackId = priorPendingServerRenderedSubtitleTrackId
                    self.pendingExternalSubtitles = priorPendingExternalSubtitles
                    self.knownExternalSubtitles = priorKnownExternalSubtitles
                    self.duration = priorDuration
                    self.currentTime = priorCurrentTime
                    self.activeQualityId = priorActiveQualityId
                    self.qualityOptions = priorQualityOptions
                    self.resolvedServerUrl = priorResolvedServerUrl
                    self.prefsForCurrentItem = priorPrefsForCurrentItem
                    self.prefsResolvedForCurrentItem = priorPrefsResolvedForCurrentItem
                }
                guard !Task.isCancelled, !self.isDisposed else { return }
                Self.logger.error(
                    "Protocol V3 replan failed: \(MediaLogRedactor.sanitize(error), privacy: .public)"
                )
                if PlaybackSessionBridge.isPlaybackSessionMissing(error),
                   self.attemptStaleSessionRenewal(
                       reason: "protocol_v3_replan_missing_session",
                       observedPosition: position
                   ) {
                    return
                }
                self.finalizeTerminalPlaybackError(error.localizedDescription)
            }
        }
        return true
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

    private func protocolV3LoadFailureRecovery(
        _ error: Error
    ) -> (shouldAdvanceRoute: Bool, classification: String, message: String) {
        if let loadFailure = error as? AetherPlaybackController.LoadFailure {
            let failure = loadFailure.failure
            // Aether defines rate limiting as a retry-later condition at the
            // same origin, not evidence that another decode/remux rung is
            // suitable. All other typed open failures are useful V3 ladder
            // evidence and remain bounded by the bridge's attempt limit.
            return (
                failure.kind != .sourceRateLimited,
                failure.kind.rawValue,
                failure.message
            )
        }
        let message = error.localizedDescription
        return (true, protocolV3FailureClassification(message), message)
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
        guard hasActiveAetherSession else { return false }

        let shouldResumeAfterEnd = nextUpScreenVideoEnded || hasReachedEndOfFile
        nextUpAutoplayCancelled = true
        nextUpPromptDismissed = true
        showNextUpScreen = false
        nextUpScreenVideoEnded = false
        cancelNextUpCountdown()

        if shouldResumeAfterEnd,
           duration.isFinite,
           duration > 0,
           hasActiveAetherSession {
            // Returning from the terminal postroll needs a real playable
            // position; resuming at exact EOF would immediately present the
            // postroll again. Replay a short tail of the current episode.
            hasReachedEndOfFile = false
            let target = max(0, duration - 10)
            let reloadsPlaybackPipeline = commitSeek(to: target, source: "nextUpBack")
            if !reloadsPlaybackPipeline {
                aetherPlaybackController.play()
            }
        } else if !isPlaying {
            aetherPlaybackController.play()
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

    private func loadAether(
        prepared: PreparedPlayback,
        streamRequest: StreamRequest,
        expectedStreamLoadGeneration: UInt64,
        resumeSourcePosition: Double? = nil,
        shouldPlayWhenReady: Bool
    ) async throws {
        try requireCurrentStreamLoad(expectedStreamLoadGeneration)
        let preferredSubtitles = subtitleOrderingLanguage.map { [$0] } ?? []
        let preferredAudio = AetherInitialAudioPreference.languages(
            selectedOrdinal: prepared.protocolV3?.plan.selectedTracks.audio?.index,
            tracks: prepared.selectedVersion.audioTracks ?? [],
            fallbackLanguage: settings.audioLanguage
        )
        // The explicit Buffer Ahead choice wins; `automatic` has no count of
        // its own and keeps the historical mapping from the synced Seek Cache
        // toggle, so a device that never touches this picker behaves exactly as
        // before.
        let forwardBufferSegments = settings.bufferAhead.forwardBufferSegments
            ?? (settings.seekCacheEnabled ? Int.max : 4)
        let audioBridgeMode: AudioBridgeMode = settings.losslessAudioEnabled
            ? .lossless
            : .surroundCompat
        let deinterlaceMode: DeinterlaceMode = settings.deinterlaceMode == .software
            ? .software
            : .auto
        let deinterlaceFieldRate: DeinterlaceFieldRate = settings.deinterlaceFieldRate == .film
            ? .frame
            : .field
        let spec: AetherLoadSpec
        if let v3 = prepared.protocolV3 {
            let audioSourceStreamIndex: Int32?
            let selectedAudioOrdinal = v3.plan.selectedTracks.audio?.index
            let catalogAudioTracks = prepared.selectedVersion.audioTracks ?? []
            if v3.plan.delivery == PlaybackProtocolV3.PlanDelivery.originalHTTP,
               AetherInitialAudioPreference.requiresExactStreamProbe(
                   selectedOrdinal: selectedAudioOrdinal,
                   tracks: catalogAudioTracks
               ),
               let selectedAudioOrdinal {
                // A V3 audio identity is a dense ordinal, but Aether's exact
                // first-open override is an FFmpeg AVStream id. Resolve it
                // with the same authenticated source and headers the real
                // load will use. This extra open is limited to non-default
                // original-file audio; without it, a same-language
                // TrueHD/compatibility pair starts on the container default
                // and depends on a fragile post-load pipeline rebuild.
                let sourceURL = streamRequest.url
                let sourceHeaders = streamRequest.headers
                let probe = try await Task.detached(priority: .userInitiated) {
                    try AetherEngine.probe(
                        url: sourceURL,
                        options: LoadOptions(httpHeaders: sourceHeaders)
                    )
                }.value
                try requireCurrentStreamLoad(expectedStreamLoadGeneration)
                guard probe.audioTracks.indices.contains(selectedAudioOrdinal),
                      let exactStreamIndex = Int32(exactly: probe.audioTracks[selectedAudioOrdinal].id) else {
                    throw AetherLoadSpec.ValidationError.invalidAudioTrackIndex(selectedAudioOrdinal)
                }
                audioSourceStreamIndex = exactStreamIndex
            } else {
                audioSourceStreamIndex = nil
            }
            spec = try AetherLoadSpec(
                validating: v3.plan,
                sessionID: prepared.session.sessionId,
                matchContentEnabled: settings.hdrEnabled && AetherDisplayContext.matchContentEnabled,
                sourceURLOverride: streamRequest.url,
                requestHeaders: streamRequest.headers,
                // Subtitle artifacts, inventory sidecars and font bundles stay
                // relative API-origin routes even when the media itself moved
                // to a proxy, so this resolver never accepts absolute URLs.
                resolveURL: { raw in
                    StreamRequest.resolve(
                        rawURL: raw,
                        serverURL: streamRequest.serverUrl,
                        additionalHeaders: [:],
                        accessToken: nil,
                        requiresHeaderAuthenticatedMedia: true
                    )?.url
                },
                apiOriginURL: URL(string: streamRequest.serverUrl),
                audioSourceStreamIndex: audioSourceStreamIndex,
                preferredAudioLanguages: preferredAudio,
                forwardBufferSegments: forwardBufferSegments,
                audioBridgeMode: audioBridgeMode,
                deinterlaceMode: deinterlaceMode,
                deinterlaceFieldRate: deinterlaceFieldRate,
                resumeSourcePosition: resumeSourcePosition
            )
        } else if streamRequest.url.isFileURL {
            let audioStreamIndex: Int32?
            if let ordinal = prepared.session.audioTrackIndex {
                let localURL = streamRequest.url
                let probe = try await Task.detached(priority: .userInitiated) {
                    try AetherEngine.probe(url: localURL)
                }.value
                try requireCurrentStreamLoad(expectedStreamLoadGeneration)
                guard probe.audioTracks.indices.contains(ordinal) else {
                    throw AetherLoadSpec.ValidationError.invalidAudioTrackIndex(ordinal)
                }
                audioStreamIndex = Int32(probe.audioTracks[ordinal].id)
            } else {
                audioStreamIndex = nil
            }
            spec = try AetherLoadSpec(
                offlineURL: streamRequest.url,
                startPosition: prepared.session.position,
                audioOnly: prepared.selectedVersion.codecVideo == nil,
                audioSourceStreamIndex: audioStreamIndex,
                sidecars: prepared.session.subtitleUrls ?? [],
                preferredAudioLanguages: preferredAudio,
                preferredSubtitleLanguages: preferredSubtitles,
                forwardBufferSegments: forwardBufferSegments,
                audioBridgeMode: audioBridgeMode,
                deinterlaceMode: deinterlaceMode,
                deinterlaceFieldRate: deinterlaceFieldRate
            )
        } else {
            spec = try AetherLoadSpec(
                directURL: streamRequest.url,
                headers: streamRequest.headers,
                startPosition: prepared.session.position,
                audioOnly: prepared.selectedVersion.codecVideo == nil,
                sidecars: prepared.session.subtitleUrls ?? [],
                preferredAudioLanguages: preferredAudio,
                preferredSubtitleLanguages: preferredSubtitles,
                forwardBufferSegments: forwardBufferSegments,
                audioBridgeMode: audioBridgeMode,
                deinterlaceMode: deinterlaceMode,
                deinterlaceFieldRate: deinterlaceFieldRate
            )
        }

        try requireCurrentStreamLoad(expectedStreamLoadGeneration)
        isLoading = true
        isBuffering = false
        bufferingProgress = nil
        scrubPreviewProvider.endSession()
        let loadEpoch = aetherPlaybackController.beginLoad(
            spec,
            shouldPlayWhenReady: shouldPlayWhenReady
        )
        activeAetherLoadEpoch = loadEpoch
        establishedAetherLoadEpoch = nil
        lastAetherAudioTrackSwitchFailure = nil
        committedProtocolV3LoadEpoch = nil
        pendingProtocolV3FirstFrameEpoch = nil
        do {
            try await aetherPlaybackController.finishLoad(loadEpoch)
        } catch {
            let resolved = resolveAbandonedAetherLoad(
                error,
                epoch: loadEpoch,
                expectedStreamLoadGeneration: expectedStreamLoadGeneration
            )
            if activeAetherLoadEpoch == loadEpoch {
                activeAetherLoadEpoch = nil
                establishedAetherLoadEpoch = nil
                committedProtocolV3LoadEpoch = nil
                pendingProtocolV3FirstFrameEpoch = nil
            }
            if !(resolved is CancellationError),
               aetherPlaybackController.activeLoadEpoch == loadEpoch {
                // The engine, not the app, abandoned this load. Nobody else
                // will tear the source down, and the load's own catch is about
                // to retire its server session.
                disposeAetherPlayback()
            }
            throw resolved
        }
        do {
            try requireCurrentStreamLoad(expectedStreamLoadGeneration)
            guard activeAetherLoadEpoch == loadEpoch,
                  aetherPlaybackController.activeLoadEpoch == loadEpoch else {
                throw CancellationError()
            }
        } catch {
            if aetherPlaybackController.activeLoadEpoch == loadEpoch {
                disposeAetherPlayback()
            }
            throw error
        }
        // Startup ran to completion on this epoch, so the decode route is now
        // settled and deferred track picks may drive the engine.
        establishedAetherLoadEpoch = loadEpoch
        scrubPreviewProvider.activate(spec)
        adoptAetherInventory()
        reapplyAetherGain()

        if aetherPlaybackController.shouldPlayWhenReady {
            aetherPlaybackController.play()
        } else {
            aetherPlaybackController.pause()
        }
    }

    /// Whether the engine may be driven off a deferred (not user-initiated)
    /// track pick for the load that is currently active.
    private var isAetherLoadEstablished: Bool {
        activeAetherLoadEpoch != nil && establishedAetherLoadEpoch == activeAetherLoadEpoch
    }

    /// Distinguishes "the app abandoned this load" from "the engine abandoned
    /// it under us".
    ///
    /// `AetherEngine.load` unwinds as a cancellation whenever a newer engine
    /// generation supersedes it — including when the *engine itself* started
    /// that newer generation, as an audio-track switch's pipeline rebuild does.
    /// Treating that as an app-side abort is what leaves the player on an
    /// endless spinner: the load task returns silently, no plan failure is
    /// reported and no replan runs. If nothing on the app side asked for this
    /// load to stop, the cancellation is a failure and has to be surfaced as
    /// one so the V3 route ladder (and its server-transcode fallback) runs.
    private func resolveAbandonedAetherLoad(
        _ error: Error,
        epoch: AetherPlaybackController.LoadEpoch,
        expectedStreamLoadGeneration: UInt64
    ) -> Error {
        guard error is CancellationError,
              !Task.isCancelled,
              !isDisposed,
              expectedStreamLoadGeneration == streamLoadGeneration,
              activeAetherLoadEpoch == epoch else {
            return error
        }
        let failure = lastAetherAudioTrackSwitchFailure
            ?? aetherPlaybackController.engine.errorInfo
            ?? PlaybackErrorInfo(
                kind: .audioTrackSwitchFailed,
                message: "Playback could not be set up with the selected audio track."
            )
        Self.logger.error(
            "Aether abandoned an in-flight load (kind=\(failure.kind.rawValue, privacy: .public)); treating as a load failure"
        )
        return AetherPlaybackController.LoadFailure(
            failure: failure,
            underlying: error
        )
    }

    private func requireCurrentStreamLoad(_ expectedGeneration: UInt64) throws {
        guard !Task.isCancelled,
              !isDisposed,
              expectedGeneration == streamLoadGeneration else {
            throw CancellationError()
        }
    }

    @MainActor
    private func adoptAetherInventory() {
        let engine = aetherPlaybackController.engine
        let existingLiveTracks = subtitleTracks.filter {
            SubtitleTrackIdSpace.isAILive($0.trackId)
        }
        audioTracks = engine.audioTracks.enumerated().map { ordinal, track in
            PlayerTrack(
                trackId: Int64(track.id),
                kind: .audio,
                title: track.name,
                lang: track.language,
                codec: track.codec,
                audioChannelCount: track.channels > 0 ? track.channels : nil,
                bitrate: track.bitrate > 0 ? track.bitrate : nil,
                isDefault: track.isDefault,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                isExternal: track.isExternal,
                isSelected: engine.activeAudioTrackIndex == track.id,
                ffIndex: track.id,
                srcId: ordinal
            )
        }
        let aetherSubtitleTracks = engine.subtitleTracks.map { track in
            let appTrackID = aetherPlaybackController.appSubtitleID(forAetherID: track.id)
            return PlayerTrack(
                trackId: appTrackID,
                kind: .sub,
                title: track.name,
                lang: track.language,
                codec: track.codec,
                audioChannelCount: nil,
                bitrate: nil,
                isDefault: track.isDefault,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                isExternal: track.isExternal,
                isSelected: engine.activeSubtitleTrackIndex == track.id,
                ffIndex: track.isExternal ? nil : track.id,
                srcId: track.isExternal
                    ? SubtitleTrackIdSpace.sidecarIndex(from: appTrackID)
                    : nil
            )
        }
        // V3 inventory is an authoritative menu, not a preload list. Aether
        // receives only the current plan's artifact; presenting its probed
        // embedded tracks alongside every server sidecar would create two
        // identities (and two selectors) for the same subtitle rows.
        let planSubtitleTracks = activePreparedProtocolV3.map { prepared in
            ApplePlaybackV3PlanAdapter.subtitlePickerTracks(
                plan: prepared.plan,
                version: currentSelectedVersion
            )
        }
        // …but a sidecar this session registered itself (a finished AI job or
        // a downloaded subtitle) is real and selectable before any plan names
        // it, so it is unioned in until the server publishes its ordinal.
        let publishedSubtitleTracks = planSubtitleTracks.map { planTracks in
            planTracks + locallyRegisteredSidecarSubtitleTracks.filter { local in
                !planTracks.contains { $0.trackId == local.trackId }
            }
        } ?? aetherSubtitleTracks
        subtitleTracks = publishedSubtitleTracks + existingLiveTracks.filter { liveTrack in
            !publishedSubtitleTracks.contains { $0.trackId == liveTrack.trackId }
        }
        let mediaChapters = engine.mediaChapters.map { chapter in
            PlayerChapterInfo(
                index: chapter.id,
                title: chapter.name,
                time: chapter.startSeconds
            )
        }
        chapters = mediaChapters.isEmpty ? serverProvidedChapters : mediaChapters

        selectedAudioId = engine.activeAudioTrackIndex.map(Int64.init)
        // A locally-registered sidecar is selected client-side, so the plan —
        // which predates the track — must not republish over it. Once the
        // server publishes that ordinal the plan is authoritative again.
        let holdsLocalSidecarSelection = selectedSubtitleId.map { id in
            locallyRegisteredSidecarSubtitleTracks.contains { $0.trackId == id }
                && planSubtitleTracks?.contains { $0.trackId == id } != true
        } ?? false
        if selectedSubtitleId.map(SubtitleTrackIdSpace.isAILive) != true,
           !holdsLocalSidecarSelection {
            if activePreparedProtocolV3 != nil {
                selectedSubtitleId = publishedSubtitleTracks
                    .first(where: \.isSelected)?.trackId
            } else {
                selectedSubtitleId = engine.activeSubtitleTrackIndex.map {
                    aetherPlaybackController.appSubtitleID(forAetherID: $0)
                }
            }
        }

        // Inventory arrives mid-startup, so a deferred pick applied here would
        // reach the engine before its decode route exists. Hold it until the
        // load is established; `loadAether` re-enters this method at that point.
        let loadIsEstablished = isAetherLoadEstablished

        if let wantedIndex = pendingAudioFfIndex,
           let match = audioTracks.first(where: { audioSelectionIndex(for: $0) == wantedIndex }) {
            switch DeferredTrackSelectionGate.outcome(
                isLoadEstablished: loadIsEstablished,
                engineAlreadyMatches: engine.activeAudioTrackIndex.map(Int64.init) == match.trackId
            ) {
            case .deferUntilEstablished:
                break
            case .adoptWithoutEngineCall:
                pendingAudioFfIndex = nil
                selectedAudioId = match.trackId
            case .applyToEngine:
                pendingAudioFfIndex = nil
                selectedAudioId = match.trackId
                applyAudioTrackSelection(match.trackId, reason: "pending_audio_index")
            }
        }

        if let wantedIndex = pendingSubtitleFfIndex {
            if wantedIndex < 0 {
                switch DeferredTrackSelectionGate.outcome(
                    isLoadEstablished: loadIsEstablished,
                    engineAlreadyMatches: engine.activeSubtitleTrackIndex == nil
                ) {
                case .deferUntilEstablished:
                    break
                case .adoptWithoutEngineCall:
                    pendingSubtitleFfIndex = nil
                    selectedSubtitleId = nil
                case .applyToEngine:
                    pendingSubtitleFfIndex = nil
                    selectedSubtitleId = nil
                    applySubtitleTrackSelection(nil, reason: "pending_subtitle_off")
                }
            } else if let match = aetherSubtitleTracks.first(where: { $0.ffIndex == wantedIndex }) {
                // The engine still selects an embedded stream by its raw id,
                // but under V3 the *published* row for that stream lives in
                // the plan's sidecar id space. Publishing the engine id would
                // leave the picker showing nothing selected and resolve to no
                // combined ordinal on the next replan.
                let publishedTrackID = publishedSubtitleTracks
                    .first { $0.ffIndex == wantedIndex }?
                    .trackId ?? match.trackId
                switch DeferredTrackSelectionGate.outcome(
                    isLoadEstablished: loadIsEstablished,
                    engineAlreadyMatches: engine.activeSubtitleTrackIndex == wantedIndex
                ) {
                case .deferUntilEstablished:
                    break
                case .adoptWithoutEngineCall:
                    pendingSubtitleFfIndex = nil
                    selectedSubtitleId = publishedTrackID
                case .applyToEngine:
                    pendingSubtitleFfIndex = nil
                    selectedSubtitleId = publishedTrackID
                    applySubtitleTrackSelection(match.trackId, reason: "pending_subtitle_index")
                }
            }
        }

        // Reassert even when Aether publishes the same synthetic id: V3 changed
        // the resource behind that reused id, and the current plan's artifact
        // URL — not id equality — is authoritative.
        if let pendingTrackID = pendingSidecarSubtitleTrackId,
           loadIsEstablished,
           subtitleTracks.contains(where: { $0.trackId == pendingTrackID }) {
            pendingSidecarSubtitleTrackId = nil
            selectedSubtitleId = pendingTrackID
            applySubtitleTrackSelection(pendingTrackID, reason: "restored_sidecar_selection")
            performDeferredLiveSubtitleCloseIfNeeded()
        }
        if let pendingTrackID = pendingServerRenderedSubtitleTrackId,
           subtitleTracks.contains(where: { $0.trackId == pendingTrackID }) {
            pendingServerRenderedSubtitleTrackId = nil
            selectedSubtitleId = pendingTrackID
        }
        applyAutoSubtitlePreferencesIfNeeded()
    }

    @MainActor
    private func reapplyAetherGain() {
        aetherPlaybackController.setVolume(userVolume)
        aetherPlaybackController.setMuted(userMuted)
        aetherPlaybackController.setRate(Float(settings.playbackSpeed))
        aetherPlaybackController.engine.videoGravity = settings.videoGravity.avGravity
    }

    var currentUserVolume: Float {
        userMuted ? 0 : userVolume
    }

    func applyUserVolume(_ volume: Float) {
        userVolume = min(max(volume, 0), 1)
        if userVolume > 0 { userMuted = false }
        aetherPlaybackController.setMuted(userMuted)
        aetherPlaybackController.setVolume(userVolume)
    }

    func applyUserMuted(_ muted: Bool) {
        userMuted = muted
        aetherPlaybackController.setMuted(muted)
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

    func applySettingsToPlayer() {
        aetherPlaybackController.setSpeed(settings.playbackSpeed)
        aetherPlaybackController.engine.videoGravity = settings.videoGravity.avGravity
    }

    private func applySubtitleAppearanceToPlayer() {
        // Silo's Aether subtitle overlay reads the published appearance
        // settings directly; the media engine remains the sole cue source.
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
        subtitleOrderingLanguage = enabled
            ? settings.subtitleSystemSelectionPreferences.preferredLanguages.first
            : currentWatchDetail?.effectiveSubtitleLanguage
        hasExplicitSubtitleChoice = false
        prefsForCurrentItem = enabled
            ? systemCaptionPrefsSnapshot()
            : currentWatchDetail.map(serverSubtitlePrefsSnapshot)
        prefsResolvedForCurrentItem = false
        applyAutoSubtitlePreferencesIfNeeded(forceReevaluation: true)
    }

    func setPlaybackSpeed(_ rate: Double) {
        settings.setPlaybackSpeed(rate)
        aetherPlaybackController.setSpeed(settings.playbackSpeed)
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
        aetherPlaybackController.setSpeed(rate)
    }

    /// Always restores the configured speed, even if playback paused during
    /// the hold: backends don't start a paused clock on `setSpeed`, and
    /// leaving the hold rate behind would make the next play resume at 2×.
    func endHoldFastForward() {
        guard isHoldFastForwarding else { return }
        isHoldFastForwarding = false
        aetherPlaybackController.setSpeed(settings.playbackSpeed)
    }

    func setVideoGravity(_ gravity: VideoGravity) {
        settings.setVideoGravity(gravity)
        guard backendCapabilities.supportsVideoGravity else { return }
        aetherPlaybackController.engine.videoGravity = settings.videoGravity.avGravity
    }

    func setSubtitleSyncMilliseconds(_ milliseconds: Int) {
        settings.setSubtitleSyncMs(milliseconds)
    }

    /// Pushes the current item's poster into the Now Playing artwork field
    /// so the lock-screen, Control Center, and Apple TV "What's Playing"
    /// surface have a thumbnail. The poster URL is derived from the
    /// content's library catalog entry rather than `WatchDetail`, which
    /// doesn't expose image fields. The fetch runs in a background task on
    /// the Aether video Now Playing coordinator and is best-effort: any
    /// failure leaves the existing artwork (or none) unchanged.
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
        pushNowPlayingSnapshot()
    }

    private func pushNowPlayingSnapshot() {
        guard hasActiveAetherSession, !title.isEmpty else { return }
        nowPlaying.update(
            title: title,
            duration: duration,
            position: currentTime,
            isPlaying: isPlaying,
            playbackRate: settings.playbackSpeed
        )
    }

    /// Called when the active backend reports natural EOF. Move the shell into
    /// a paused end-state immediately so the player does not look frozen if
    /// auto-play-next is unavailable.
    private func handleEndOfFile() {
        // Once per load. Two callers can land here for the same end — the
        // `.ended` event and a near-end playback error reclassified as a
        // natural finish — and running twice would raise the Next Up postroll
        // twice. Latching the flag up-front (rather than at the bottom, as
        // before) is what makes the guard airtight; every intentional resume
        // (`beginFreshLoad`, `keepWatchingCurrentEpisode`, `commitSeek`,
        // `handleFileLoaded`) already clears it, so a genuine second end
        // still reports.
        guard !hasReachedEndOfFile else { return }
        hasReachedEndOfFile = true

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
                "play_method": .string(activeRouteLabel),
                "position_ms": .int(
                    PlaybackSessionBridge.diagnosticsPositionMilliseconds(observedPosition)
                ),
            ]
        )
        #endif

        hideControlsTask?.cancel()
        hideControlsTask = nil
        aetherPlaybackController.pause()
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
            isPlaying: false,
            playbackRate: settings.playbackSpeed
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
        syncNowPlayingDestination()
    }

    /// Rebind commands and publication whenever Aether swaps its effective
    /// video route. Native video uses Aether's player-scoped session;
    /// software video (and macOS, where upstream has no video session) uses
    /// the shared fallback. Rebinding clears the previous destination first.
    private func syncNowPlayingDestination() {
        guard !isDisposed else {
            nowPlaying.detach()
            return
        }
        let handlers = AetherVideoNowPlayingCoordinator.Handlers(
            // On tvOS the physical Play/Pause button can arrive through the
            // player-scoped media command center instead of SwiftUI's
            // `onPlayPauseCommand`. Keep that route visually consistent with
            // Select by revealing the transport controls as playback changes.
            play:        { [weak self] in self?.handleNowPlayingPlay() },
            pause:       { [weak self] in self?.handleNowPlayingPause() },
            isPaused:    { [weak self] in
                guard let self else { return true }
                return self.hasReachedEndOfFile || self.aetherPlaybackController.isPaused
            },
            currentTime: { [weak self] in self?.currentTime ?? 0 },
            // Remote-position events use the source axis published above and
            // must pass through the VM so a bounded V3 transport can replan.
            seek:        { [weak self] t in self?.seekTo(seconds: t) },
            // A command answered `.success` while the controller has no load
            // reports work the system will never observe.
            hasActiveLoad: { [weak self] in
                self?.aetherPlaybackController.hasActiveLoad ?? false
            }
        )
        #if os(iOS) || os(tvOS)
        nowPlaying.attach(
            session: aetherPlaybackController.videoNowPlayingSession,
            useSharedFallback: aetherPlaybackController.shouldUseSharedVideoNowPlayingFallback,
            handlers: handlers
        )
        #else
        nowPlaying.attach(
            useSharedFallback: aetherPlaybackController.shouldUseSharedVideoNowPlayingFallback,
            handlers: handlers
        )
        #endif
    }

    private func handleNowPlayingPlay() {
        aetherPlaybackController.play()
        #if os(tvOS)
        scheduleHideControls()
        #endif
    }

    private func handleNowPlayingPause() {
        aetherPlaybackController.pause()
        #if os(tvOS)
        scheduleHideControls()
        #endif
    }

    private func resetPublishedLoadState(
        preferredAudioTrackIndex: Int?,
        preferredSubtitleTrackIndex: Int?,
        preferredSidecarSubtitleTrackId: Int64?,
        preferredProtocolV3SubtitleIndex: Int? = nil
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
        scrubPreviewProvider.endInteraction()
        scrubPreviewImage = nil
        scrubPreviewImageSourceTime = nil
        seekOriginTime = nil
        seekTargetTime = nil
        showControls = false
        // The HUD belongs to the outgoing item. Replans deliberately bypass
        // this reset so the HUD survives them; a replacement load must close
        // it, both because its content is stale and because the tvOS controls
        // host stays mounted through `isLoading` whenever this flag is up.
        isHUDPresented = false
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
        livePrimarySubtitleCues = []
        liveSecondarySubtitleCues = []
        chapters = []
        introRange = nil
        creditsRange = nil
        markerReconcileTask?.cancel()
        markerReconcileTask = nil
        markerReconciledSessionId = nil
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
        autoSkippedCreditsKey = nil
        autoSkipIntroCancelledKey = nil
        selectedAudioId = nil
        selectedSubtitleId = nil
        selectedSecondarySubtitleId = nil
        bufferedAheadSeconds = 0
        playbackStats = .empty
        knownExternalSubtitles = []
        locallyRegisteredSidecarSubtitleTracks = []
        pendingServerRenderedSubtitleTrackId = nil
        // Subtitle `-1` is the explicit "Off" sentinel; Aether inventory
        // adoption disables subtitles when it sees a negative value.
        pendingAudioFfIndex = preferredAudioTrackIndex
        pendingSubtitleFfIndex = preferredSubtitleTrackIndex
        pendingSidecarSubtitleTrackId = preferredSidecarSubtitleTrackId
        hasExplicitSubtitleChoice =
            preferredSubtitleTrackIndex != nil
            || preferredSidecarSubtitleTrackId != nil
            || preferredProtocolV3SubtitleIndex != nil
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
        // The id space decides, not the row's metadata: a V3 picker row is
        // published in the sidecar space and carries its FFmpeg index only so
        // an embedded pick can be persisted. Restoring it as an embedded index
        // would arm both identities for the same subtitle.
        if let selectedSubtitleId, SubtitleTrackIdSpace.isSidecar(selectedSubtitleId) {
            // Sidecars are re-applied client-side after the playback
            // session returns `subtitle_urls`; keep embedded subtitles off
            // until that explicit sidecar selection is restored.
            return -1
        }
        if let selectedSubtitleId,
           let selected = subtitleTracks.first(where: { $0.trackId == selectedSubtitleId }),
           let ffIndex = selected.ffIndex {
            return ffIndex
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
            in: version,
            inventory: activePreparedProtocolV3?.plan.subtitle.inventory ?? []
        )
    }

    private func resolvedSidecarSubtitleTrackIdForResume() -> Int64? {
        if let selectedSubtitleId, SubtitleTrackIdSpace.isSidecar(selectedSubtitleId) {
            return selectedSubtitleId
        }
        return lastLoadRequest?.preferredSidecarSubtitleTrackId
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

        armAdoptedProtocolV3TrackIntent(
            plan: protocolV3.plan,
            request: adopted
        )

        // Adopting an authoritative server plan does not convert an automatic
        // system/server policy into a user choice. Manual choices stay latched;
        // automatic choices remain eligible for later policy changes.
        if hasExplicitSubtitleChoice {
            prefsForCurrentItem = nil
            prefsResolvedForCurrentItem = true
        }
    }

    private func rearmAdoptedProtocolV3TrackIntent() {
        guard let plan = activePreparedProtocolV3?.plan,
              let request = lastLoadRequest else { return }
        armAdoptedProtocolV3TrackIntent(plan: plan, request: request)
    }

    private func armAdoptedProtocolV3TrackIntent(
        plan: PlaybackV3Plan,
        request: LoadRequest
    ) {
        // The V3 plan is authoritative for the tracks actually rendered.
        // Apply it before the new source publishes a track list so container
        // defaults and the post-open Auto resolver cannot drift away from the
        // selection the server will preserve through replans and renewals.
        let intent = Self.protocolV3PendingTrackIntent(plan: plan, request: request)
        pendingAudioFfIndex = intent.audioIndex
        pendingSubtitleFfIndex = intent.embeddedSubtitleIndex
        pendingSidecarSubtitleTrackId = intent.sidecarSubtitleTrackId
    }

    private func beginFreshLoad(
        request: LoadRequest,
        progressPosition: Double?,
        finalizeCurrentSession: Bool = false,
        resumePositionOverride: Double? = nil,
        allowNearEndResume: Bool = false,
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
        // Retire the outgoing load's epoch *synchronously*. The actual
        // dispose happens several awaits down, and until this is nil a late
        // `.ended` or failure from the item we're replacing still matches
        // `handleAetherEvent`'s epoch filter — landing end-of-file, or a
        // terminal error, on the item that is only just starting to load.
        activeAetherLoadEpoch = nil
        committedProtocolV3LoadEpoch = nil
        pendingProtocolV3FirstFrameEpoch = nil
        // The outgoing item's queued follow-ups must not be replayed against
        // the incoming one.
        pendingProtocolV3SeekReanchorPosition = nil
        pendingProtocolV3TrackChange = nil
        seekReplanTask?.cancel()
        seekReplanTask = nil
        cancelNextUpFlow()
        attachNowPlayingIfNeeded()
        resetPublishedLoadState(
            preferredAudioTrackIndex: request.preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: request.preferredSubtitleTrackIndex,
            preferredSidecarSubtitleTrackId: request.preferredSidecarSubtitleTrackId,
            preferredProtocolV3SubtitleIndex: request.preferredProtocolV3SubtitleIndex
        )

        // The prior item's timer reads bridge state at each tick. Stop it
        // before a replacement session becomes provisional or it can publish
        // the new item's reset position against an uncommitted candidate.
        progressTask?.cancel()
        progressTask = nil
        freshLoadTask?.cancel()
        protocolV3ReplanTask?.cancel()
        protocolV3ReplanTask = nil
        freshLoadGeneration &+= 1
        let currentFreshLoadGeneration = freshLoadGeneration
        streamLoadGeneration &+= 1
        let currentStreamLoadGeneration = streamLoadGeneration
        let snapshotPosition = progressPosition
        // Offline loads never start a replacement server session, so the
        // prior one must be finalized here — otherwise the bridge keeps
        // holding it and a later teardown would report the offline item's
        // position against the stale session.
        let shouldFinalizeCurrentSession = finalizeCurrentSession || request.offlineDownloadId != nil
        // From here until this task exits, its catch is the only handler for
        // a load failure — see `handleAetherFailure`.
        freshLoadOwnsFailureHandling = true
        freshLoadTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            var uncommittedPrepared: PreparedPlayback?
            defer {
                if self.freshLoadGeneration == currentFreshLoadGeneration {
                    self.freshLoadTask = nil
                    self.freshLoadOwnsFailureHandling = false
                }
            }

            if let snapshotPosition, snapshotPosition.isFinite, snapshotPosition >= 0 {
                if shouldFinalizeCurrentSession {
                    await self.sessionBridge.stopSession(position: snapshotPosition, isPaused: true)
                } else {
                    await self.sessionBridge.reportProgress(position: snapshotPosition, isPaused: true)
                }
            }
            guard !Task.isCancelled,
                  !self.isDisposed,
                  currentFreshLoadGeneration == self.freshLoadGeneration,
                  currentStreamLoadGeneration == self.streamLoadGeneration else { return }

            await self.realtimeClient.unbind()
            guard !Task.isCancelled,
                  !self.isDisposed,
                  currentFreshLoadGeneration == self.freshLoadGeneration,
                  currentStreamLoadGeneration == self.streamLoadGeneration else { return }

            do {
                self.disposeAetherPlayback(forReplacement: true)
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
                try self.requireCurrentStreamLoad(currentStreamLoadGeneration)
                guard currentFreshLoadGeneration == self.freshLoadGeneration else {
                    throw CancellationError()
                }

                let prepared: PreparedPlayback
                var preparedOfflineContext: OfflinePlaybackContext?
                var preparedOfflineArtworkURL: URL?
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
                    preparedOfflineContext = OfflinePlaybackContext(
                        downloadId: offline.downloadId,
                        mediaItemId: offline.mediaItemId
                    )
                    preparedOfflineArtworkURL = offline.posterFileURL
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
                try self.requireCurrentStreamLoad(currentStreamLoadGeneration)
                guard currentFreshLoadGeneration == self.freshLoadGeneration else {
                    throw CancellationError()
                }
                if prepared.protocolV3 != nil {
                    uncommittedPrepared = prepared
                }
                if let preparedOfflineContext {
                    self.offlinePlaybackContext = preparedOfflineContext
                }
                if let preparedOfflineArtworkURL {
                    self.nowPlaying.setArtworkURL(preparedOfflineArtworkURL)
                }

                let session = prepared.session
                self.activePlaybackSessionId = session.sessionId
                self.autoSkippedIntroKey = nil
                self.autoSkippedCreditsKey = nil
                self.autoSkipIntroCancelledKey = nil
                self.cancelPendingIntroAutoSkip()
                self.staleSessionRecoverySessionId = nil
                // Snapshot the preferred language for track-list ordering
                // unconditionally (even with an explicit choice) so the
                // displayed groups float the user's language to the top.
                self.subtitleOrderingLanguage = self.settings.subtitleMatchesSystemAppearance
                    ? self.settings.subtitleSystemSelectionPreferences.preferredLanguages.first
                    : prepared.watchDetail.effectiveSubtitleLanguage

                // Snapshot the server-resolved subtitle policy so the
                // track-list callback (which fires after Aether opens media)
                // can pick the right track without another fetch. Skip
                // entirely if the caller already passed an explicit
                // subtitle index — manual override always wins.
                if !self.hasExplicitSubtitleChoice {
                    self.prefsForCurrentItem = self.settings.subtitleMatchesSystemAppearance
                        ? self.systemCaptionPrefsSnapshot()
                        : self.serverSubtitlePrefsSnapshot(prepared.watchDetail)
                }

                self.title = prepared.displayTitle
                self.metadata = prepared.playerMetadata()
                self.pendingExternalSubtitles = session.subtitleUrls ?? []
                self.knownExternalSubtitles = self.pendingExternalSubtitles
                self.currentWatchDetail = prepared.watchDetail
                self.currentSelectedVersion = prepared.selectedVersion
                self.activePreparedProtocolV3 = prepared.protocolV3
                self.adoptProtocolV3RenewalIntent(from: prepared)
                // Artwork and Next Up are catalog fetches; the offline path
                // already published its cached poster above and has no
                // server to resolve a next episode against.
                if request.offlineDownloadId == nil {
                    self.pushNowPlayingArtwork(contentId: prepared.watchDetail.contentId)
                    self.loadNextUpCandidate(for: prepared.watchDetail)
                    self.loadNextUpOnDeckItems(for: prepared.watchDetail)
                }
                self.qualityOptions = ApplePlaybackQuality.playbackOptions(
                    serverQualities: prepared.protocolV3?.plan.availableQualities ?? [],
                    fallbackVersion: prepared.selectedVersion
                )
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

                guard let streamRequest = await self.makeStreamRequest(
                    session: session,
                    additionalHeaders: prepared.protocolV3?.plan.stream.headers ?? [:],
                    requiresHeaderAuthenticatedMedia: prepared.protocolV3?.serverFeatures.contains(
                        PlaybackProtocolV3.headerAuthenticatedMediaFeature
                    ) == true,
                    allowsAuthorizedMediaOrigins:
                        prepared.protocolV3?.negotiatedAuthorizedMediaOrigins == true
                ) else {
                    throw AetherLoadSpec.ValidationError.invalidStreamURL(session.streamUrl)
                }
                try self.requireCurrentStreamLoad(currentStreamLoadGeneration)
                guard currentFreshLoadGeneration == self.freshLoadGeneration else {
                    throw CancellationError()
                }
                self.resolvedServerUrl = streamRequest.serverUrl

                Self.logger.info("Play method: \(session.playMethod, privacy: .public)")
                // Keep the tvOS console breadcrumb useful without printing the
                // signed stream URL or any server identity.
                print("[CMP] streamPrepared engine=AetherEngine playMethod=\(session.playMethod) startTime=\(session.position)")

                try await self.loadAether(
                    prepared: prepared,
                    streamRequest: streamRequest,
                    expectedStreamLoadGeneration: currentStreamLoadGeneration,
                    shouldPlayWhenReady: true
                )
                if prepared.protocolV3 != nil {
                    guard await self.sessionBridge.commitPendingProtocolV3Transition(prepared) else {
                        throw CancellationError()
                    }
                    self.markProtocolV3AetherLoadCommitted()
                    uncommittedPrepared = nil
                    // The realtime channel is a server websocket keyed by the
                    // committed session. Binding before Aether accepts the
                    // candidate can leave commands attached to a rolled-back
                    // session after a failed load.
                    await self.realtimeClient.bind(sessionId: session.sessionId)
                    await self.sessionBridge.reportProtocolV3PlanExecutionStarted(prepared)
                }
            } catch is CancellationError {
                // Tear the abandoned Aether load down before retiring its
                // session. Without this the engine keeps reading the stream
                // URL after the DELETE and spends minutes in 404 backoff.
                // Skip when a newer load already took the controller: its
                // own `beginLoad` replaced this source.
                if currentFreshLoadGeneration == self.freshLoadGeneration,
                   currentStreamLoadGeneration == self.streamLoadGeneration {
                    _ = self.disposeAetherPlayback()
                }
                if let uncommittedPrepared {
                    await self.sessionBridge.rollbackPendingProtocolV3Transition(uncommittedPrepared)
                }
                return
            } catch let error {
                let loadFailure = self.protocolV3LoadFailureRecovery(error)
                if let uncommittedPrepared {
                    // `errorInfo` may already have been published for this
                    // epoch, but the committed-load gate prevents that event
                    // from racing us. Promote only the failed V3 identity (not
                    // execution success) and let the server choose the next
                    // bounded route rather than ending at the first open
                    // failure.
                    if loadFailure.shouldAdvanceRoute {
                        if await self.sessionBridge.promotePendingProtocolV3TransitionForRecovery(
                            uncommittedPrepared
                        ) {
                            Self.logger.warning(
                                "Initial Protocol V3 route failed to open; requesting next route: \(MediaLogRedactor.sanitize(error), privacy: .public)"
                            )
                            if self.attemptProtocolV3Replan(
                                position: self.currentTime,
                                classification: loadFailure.classification,
                                message: loadFailure.message
                            ) {
                                return
                            }
                        }
                    }
                    await self.sessionBridge.rollbackPendingProtocolV3Transition(uncommittedPrepared)
                }
                guard !Task.isCancelled, !self.isDisposed else { return }
                await self.sessionBridge.stopSession(
                    position: self.currentTime,
                    isPaused: true
                )
                Self.logger.error(
                    "Load failed: \(MediaLogRedactor.sanitize(error), privacy: .public)"
                )
                self.handleBeginFreshLoadFailure(error: error, origin: origin)
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
        let initialSubtitlePreferences: PlaybackSessionBridge.InitialProtocolV3SubtitlePreferences? = {
            guard settings.subtitleMatchesSystemAppearance, !hasExplicitSubtitleChoice else {
                return nil
            }
            let preferences = systemCaptionPrefsSnapshot()
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

    /// Routes a `beginFreshLoad` failure based on what triggered the load.
    /// User-initiated loads keep the historical full-screen error wall.
    /// Autoplay and interruption-recovery loads instead restore the Next Up
    /// postroll with `nextUpStartError` set so the user can pick something
    /// from On Deck or hit Back without the player being taken hostage by an
    /// `error` overlay.
    @MainActor
    private func handleBeginFreshLoadFailure(error: Error, origin: LoadOrigin) {
        let message: String = {
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
            let logMessage = MediaLogRedactor.sanitize(message)
            Self.logger.warning(
                "[CMP] beginFreshLoad recovered from autoplay failure: \(logMessage, privacy: .public)"
            )
            // Tear down the disposed player the same way
            // `finalizeTerminalPlaybackError` would, but DON'T set
            // `viewModel.error` — we want a recoverable surface, not a wall.
            disposeAetherPlayback()
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
            let logMessage = MediaLogRedactor.sanitize(message)
            Self.logger.warning(
                "[CMP] beginFreshLoad recovered from playback recovery failure: \(logMessage, privacy: .public)"
            )
            disposeAetherPlayback()
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

    private func finalizeTerminalPlaybackError(_ message: String) {
        #if os(iOS) || os(tvOS)
        // Terminal outcome #1 of 2 (the other is `handleEndOfFile`). Every
        // Every Aether recovery path ends either here or in `handleEndOfFile`,
        // so a report always shows how playback finished. Emit before teardown
        // so position and plan still describe the failed session.
        DiagTrace.breadcrumb(
            .essential,
            level: .error,
            category: .playback,
            tag: "Player",
            message: "playback ended in failure",
            attrs: [
                "reason": .string(stablePlaybackFailureToken(for: message)),
                "play_method": .string(activeRouteLabel),
                // Shared with the bridge's session breadcrumbs so a report's
                // positions are all on the same scale and rounding.
                "position_ms": .int(PlaybackSessionBridge.diagnosticsPositionMilliseconds(currentTime)),
            ]
        )
        #endif
        // Pin the resume point before anything is torn down. The periodic
        // reporter ticks every 10s and is cancelled immediately below, so
        // without this the user resumes up to ten seconds behind where the
        // failure actually happened. Best-effort and non-blocking; issued
        // while `activePlaybackSessionId` is still live.
        flushPlaybackProgressNow(reason: "terminal_failure")
        progressTask?.cancel()
        progressTask = nil
        staleSessionRecoveryTask?.cancel()
        staleSessionRecoveryTask = nil
        disposeAetherPlayback()
        activePlaybackSessionId = nil
        activePreparedProtocolV3 = nil
        error = message
        isLoading = false
        isPlaying = false
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
        let resumePosition = observedPosition.isFinite
            ? max(0, observedPosition)
            : max(0, currentTime)
        let contentId = currentWatchDetail?.contentId ?? lastLoadRequest.contentId
        let durationHint = duration.isFinite && duration > 0
            ? duration
            : (currentSelectedVersion?.duration ?? 0)
        let renewalRequest = lastLoadRequest.copyForRecovery(
            preferredFileId: currentSelectedVersion?.fileId ?? lastLoadRequest.preferredFileId,
            preferredAudioTrackIndex: resolvedAudioTrackIndexForResume(),
            preferredSubtitleTrackIndex: resolvedSubtitleTrackIndexForResume(),
            preferredSidecarSubtitleTrackId: resolvedSidecarSubtitleTrackIdForResume(),
            offlineDownloadId: nil
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
                origin: .recovery
            )
        }
        return true
    }

    private func isPlaybackSessionMissingMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("playback_session_not_found")
            || lowered.contains("playback session not found")
    }

    /// A signed playback URL can surface a bare 404 through Aether. Renew once
    /// at the current source position before treating it as a missing file.
    ///
    /// Deliberately typed rather than a substring match on the message. Only
    /// `sourceRefused` names the *session's own* source request, and only with
    /// `underlyingDomain == nil` is `underlyingCode` the origin's HTTP status
    /// rather than some framework's error code. Matching "404" anywhere in
    /// free text used to tear down a live session over a sidecar or segment
    /// 404, and could never fire at all on a non-English device — half of
    /// Aether's messages are `localizedDescription` forwarded from underneath.
    private func isExpiredPlaybackSessionSource(_ failure: PlaybackErrorInfo?) -> Bool {
        guard let failure,
              failure.kind == .sourceRefused,
              failure.underlyingDomain == nil,
              failure.underlyingCode == 404 else {
            return false
        }
        // Nothing to renew unless we actually hold a server session.
        return activePlaybackSessionId != nil
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
        // `isPlaying` is driven by the backend's `onPauseChange` callback;
        // let that be the single writer so the UI can't drift out of sync
        // with the actual pipeline state on error paths.
        if isPlaying {
            aetherPlaybackController.pause()
        } else {
            aetherPlaybackController.play()
        }
        scheduleHideControls()
    }

    #if os(tvOS)
    /// Native-player Select behavior for timeline entry: pause immediately
    /// and keep the full transport mounted. When controls were hidden,
    /// `TVPlayerControls` consumes a separate request token to focus and
    /// activate its timeline scrubber.
    func pauseForTimelineSelection() {
        guard !isLoading, !hasReachedEndOfFile else { return }
        if isPlaying {
            aetherPlaybackController.pause()
        }
        pinControlsVisible()
    }
    #endif

    func switchQuality(_ qualityId: String) {
        let resolvedQualityId = activePreparedProtocolV3 == nil
            ? ApplePlaybackQuality.normalizeStoredId(qualityId)
            : ApplePlaybackQuality.protocolV3QualityId(qualityId)
        guard resolvedQualityId != activeQualityId || qualitySwitchError != nil else { return }

        let target = currentTime.isFinite ? max(0, currentTime) : 0
        isQualitySwitching = true
        qualitySwitchError = nil
        showControls = true
        hideControlsTask?.cancel()

        if activePreparedProtocolV3 != nil {
            // A rejected replan already cleared `isQualitySwitching`, but
            // without a message the sheet just silently snapped back to the
            // old quality with no explanation.
            if !attemptProtocolV3Replan(
                position: target,
                classification: "quality_changed",
                message: "User selected playback quality \(resolvedQualityId).",
                operation: PlaybackProtocolV3.ReplanOperation.qualityChange,
                qualityPreference: resolvedQualityId,
                completesQualitySwitch: true
            ) {
                isQualitySwitching = false
                qualitySwitchError = "Couldn't change quality right now. Try again."
            }
            return
        }

        guard var request = lastLoadRequest,
              request.offlineDownloadId == nil else {
            isQualitySwitching = false
            qualitySwitchError = "Quality selection is unavailable for offline playback."
            return
        }
        request = request.copyForRecovery(
            preferredFileId: request.preferredFileId,
            preferredAudioTrackIndex: resolvedAudioTrackIndexForResume(),
            preferredSubtitleTrackIndex: resolvedSubtitleTrackIndexForResume(),
            preferredSidecarSubtitleTrackId: resolvedSidecarSubtitleTrackIdForResume(),
            offlineDownloadId: nil
        )
        request.preferredQualityOverride = resolvedQualityId
        beginFreshLoad(
            request: request,
            progressPosition: target,
            finalizeCurrentSession: true,
            resumePositionOverride: target,
            allowNearEndResume: true
        )
    }

    #if os(iOS)
    func playerPresentationDidAppear() {
        isPlayerPresentationVisible = true
        // Only reached once SwiftUI really mounted the cover — for a restore,
        // via `PlayerPresentationRestoration.consumeAdoption`. That is the
        // first moment AVKit's restore can honestly be reported successful.
        resolvePendingPictureInPictureRestore(true)
    }

    /// SwiftUI can remove the full-screen player while AVKit is moving the
    /// same Aether graph into PiP. Defer final teardown only for that exact,
    /// owner-scoped engagement; every ordinary dismissal still cleans up now.
    func playerPresentationDidDisappear() {
        isPlayerPresentationVisible = false
        guard PictureInPictureCoordinator.shared.ownsEngagedSession(self) else {
            cleanup()
            return
        }
        Self.logger.info("Deferring player cleanup while Aether PiP is engaged")
    }

    func pictureInPictureEngagementDidEnd() {
        guard !isPlayerPresentationVisible else { return }
        // A restore still in flight owns the outcome: AVKit can report the
        // stop before the re-presented cover mounts, and cleaning up here
        // would tear down the very session the user asked to come back to.
        // The restore timeout is the backstop if the cover never arrives.
        guard pendingRestoreCompletion == nil else {
            Self.logger.info("Deferring player cleanup while a PiP restore is still pending")
            return
        }
        cleanup()
    }

    /// Answer AVKit's restore-user-interface request for this session.
    ///
    /// Three outcomes, and every one of them has to be truthful: AVKit tears the
    /// PiP window down regardless, so an optimistic `true` with nothing behind it
    /// leaves the engine playing to no surface with the server session still open.
    func restorePictureInPictureUserInterface(_ completion: @escaping (Bool) -> Void) {
        guard !isDisposed else {
            completion(false)
            return
        }
        // Auto-PiP from inline never removed the cover, so it is already the
        // interface AVKit is asking for.
        if isPlayerPresentationVisible {
            completion(true)
            return
        }
        guard PlayerPresentationRestoration.reopen(self) else {
            Self.logger.error("PiP restore found no player presentation owner; ending the session")
            completion(false)
            // Nothing can come back, so the deferred teardown happens now rather
            // than waiting for a stop callback that leaves playback headless.
            cleanup()
            return
        }
        Self.logger.info("PiP restore re-presenting the full-screen player")
        // Asking the router to re-present is not the same as the cover being
        // on screen: another full-screen cover can keep SwiftUI from mounting
        // this one. Reporting success there leaves AVKit's window gone,
        // `handleDidStop` suppressed because the restore "worked", and a
        // headless playing session parked on `pendingAdoption` forever. Hold
        // AVKit's handler until `playerPresentationDidAppear` confirms the
        // adoption, or until the timeout ends the session.
        resolvePendingPictureInPictureRestore(false)
        pendingRestoreCompletion = completion
        pendingRestoreTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.pictureInPictureRestoreTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            self?.abandonPictureInPictureRestore()
        }
    }

    /// Answer AVKit's held restore handler at most once and stop the timeout.
    private func resolvePendingPictureInPictureRestore(_ didRestore: Bool) {
        pendingRestoreTimeoutTask?.cancel()
        pendingRestoreTimeoutTask = nil
        guard let completion = pendingRestoreCompletion else { return }
        pendingRestoreCompletion = nil
        completion(didRestore)
    }

    /// The re-presented cover never mounted. AVKit has taken the PiP window
    /// down regardless, so the session ends here — final progress and the
    /// server session stop — rather than playing on with no surface.
    private func abandonPictureInPictureRestore() {
        guard pendingRestoreCompletion != nil else { return }
        Self.logger.error("PiP restore never mounted the player; ending the session")
        PlayerPresentationRestoration.discardAdoption(for: self)
        resolvePendingPictureInPictureRestore(false)
        cleanup()
    }

    /// A Picture in Picture start that never happened is invisible to the user —
    /// AVKit reports both cases to the delegate only, so the tapped button just
    /// looks inert. Surface it on the same transient notice the player already
    /// uses for replan rejections.
    func reportPictureInPictureStartFailure(
        _ failure: PictureInPictureCoordinator.StartFailure
    ) {
        guard !isDisposed else { return }
        switch failure {
        case .notReady:
            showNotice(
                title: "Picture in Picture not ready",
                message: "This video isn't ready for Picture in Picture yet. Try again in a moment.",
                tone: .warning,
                duration: 4
            )
        case .failed:
            showNotice(
                title: "Picture in Picture failed",
                message: "iOS couldn't start Picture in Picture for this video.",
                tone: .warning,
                duration: 5
            )
        }
    }
    #endif

    func skipForward(_ seconds: Double = 30, revealingControls: Bool = true) {
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

    func skipCredits() {
        guard let creditsRange else { return }
        if let key = currentCreditsSkipKey(for: creditsRange) {
            autoSkippedCreditsKey = key
        }
        performCreditsSkip(to: creditsRange.end)
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
        scrubPreviewProvider.begin(atSourceTime: scrubPreviewTime)

        holdSeekTask?.cancel()
        holdSeekTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let rate = self.holdSeekRate
                if rate == 0 { break }
                let step = Self.holdSeekBaseStep * Double(rate)
                let cap = self.duration > 0 ? self.duration : self.scrubPreviewTime + abs(step)
                self.scrubPreviewTime = max(0, min(self.scrubPreviewTime + step, cap))
                self.scrubPreviewProvider.request(atSourceTime: self.scrubPreviewTime)
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
        let wasScrubbing = isScrubbing
        let base = isScrubbing ? scrubPreviewTime : currentTime
        let cap = duration > 0 ? duration : base + abs(delta)
        let target = max(0, min(base + delta, cap))

        isScrubbing = true
        scrubPreviewTime = target
        if wasScrubbing {
            scrubPreviewProvider.request(atSourceTime: target)
        } else {
            scrubPreviewProvider.begin(atSourceTime: target)
        }
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
        let clampedTarget = duration > 0 ? min(max(0, target), duration) : max(0, target)
        let requiresReplan: Bool = {
            guard let timeline = aetherPlaybackController.activeSpec?.timeline else { return true }
            if case .replan = timeline.seekDisposition(forSourceTime: clampedTarget) {
                return true
            }
            return false
        }()

        Self.logger.info(
            "[CMP-SEEK] commit requested source=\(source, privacy: .public) target=\(clampedTarget, privacy: .public) current=\(self.currentTime, privacy: .public) route=\(self.activeRouteLabel, privacy: .public) replan=\(requiresReplan, privacy: .public)"
        )
        hasReachedEndOfFile = false
        seekOriginTime = currentTime
        seekTargetTime = clampedTarget
        currentTime = clampedTarget
        scrubPreviewTime = clampedTarget
        isScrubbing = false
        scrubPreviewProvider.endInteraction()

        // Snapshotted synchronously, before the seek is even issued. A seek
        // that resolves `.requiresReplan` after a different item began
        // loading would otherwise restart that *new* item at this item's
        // position, because `lastLoadRequest` has already been replaced.
        let seekFreshLoadGeneration = freshLoadGeneration
        let seekLoadEpoch = aetherPlaybackController.activeLoadEpoch
        seekReplanTask?.cancel()
        seekReplanTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            let result = await self.aetherPlaybackController.seek(toSourceTime: clampedTarget)
            guard !Task.isCancelled,
                  !self.isDisposed,
                  self.freshLoadGeneration == seekFreshLoadGeneration,
                  self.aetherPlaybackController.activeLoadEpoch == seekLoadEpoch else {
                return
            }
            self.seekReplanTask = nil
            switch result {
            case .completed:
                break
            case .requiresReplan(let sourceSeconds):
                if let protocolV3 = self.activePreparedProtocolV3,
                   protocolV3.serverFeatures.contains(PlaybackProtocolV3.seekReanchorFeature) {
                    // `attemptProtocolV3Replan` raises the spinner itself once
                    // it commits to a replan. Raising it here first meant an
                    // early rejection (no watch detail) left the player
                    // spinning with nothing in flight to ever clear it.
                    guard self.attemptProtocolV3Replan(
                        position: sourceSeconds,
                        classification: "seek_reanchor",
                        message: "Reanchor the active stream at the requested source position.",
                        operation: PlaybackProtocolV3.ReplanOperation.seekReanchor
                    ) else {
                        self.isLoading = false
                        self.showNotice(
                            title: "Couldn't seek",
                            message: "Playback couldn't move to that position. Try again.",
                            tone: .warning,
                            duration: 5
                        )
                        return
                    }
                } else if let request = self.lastLoadRequest {
                    self.beginFreshLoad(
                        request: request,
                        progressPosition: self.seekOriginTime,
                        resumePositionOverride: sourceSeconds,
                        allowNearEndResume: true
                    )
                }
            }
        }

        seekFilterTimeoutTask?.cancel()
        seekFilterTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.seekFilterNanos)
            guard !Task.isCancelled, let self else { return }
            self.seekOriginTime = nil
            self.seekTargetTime = nil
            self.seekFilterTimeoutTask = nil
        }
        return requiresReplan
    }

    func seek(to fraction: Double) {
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
        if let creditsRange {
            Self.logger.info(
                "[CMP-MARKERS] credits range active start=\(creditsRange.start, privacy: .public) end=\(creditsRange.end, privacy: .public)"
            )
        }
        autoSkipIntroIfNeeded(at: currentTime)
        autoSkipCreditsIfNeeded(at: currentTime)
    }

    private func reconcileMarkersAfterRealtimeConnect() {
        guard offlinePlaybackContext == nil,
              introRange == nil || creditsRange == nil,
              let sessionId = activePlaybackSessionId,
              markerReconciledSessionId != sessionId,
              let contentId = currentWatchDetail?.contentId,
              let fileId = currentSelectedVersion?.fileId else {
            return
        }

        markerReconciledSessionId = sessionId
        markerReconcileTask?.cancel()
        markerReconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.markerReconciledSessionId == sessionId {
                    self.markerReconcileTask = nil
                }
            }
            do {
                let detail = try await ContinuumAPI.shared.watchDetail(contentId: contentId)
                guard !Task.isCancelled,
                      self.activePlaybackSessionId == sessionId,
                      self.currentSelectedVersion?.fileId == fileId,
                      let version = detail.versions.first(where: { $0.fileId == fileId }) else {
                    return
                }
                let refreshedIntro = version.intro ?? detail.intro
                let refreshedCredits = version.credits ?? detail.credits
                self.applyMarkerRanges(
                    intro: self.introRange ?? refreshedIntro,
                    credits: self.creditsRange ?? refreshedCredits
                )
            } catch {
                if self.activePlaybackSessionId == sessionId {
                    self.markerReconciledSessionId = nil
                }
                Self.logger.warning(
                    "[CMP-MARKERS] realtime marker reconciliation failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
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

    private func autoSkipCreditsIfNeeded(at time: Double) {
        let key = creditsRange.flatMap(currentCreditsSkipKey(for:))
        guard let target = CreditsAutoSkipPolicy.target(
            enabled: settings.autoSkipCredits,
            playbackEligible: !isLoading && !hasReachedEndOfFile,
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
        performCreditsSkip(to: target)
    }

    private func performCreditsSkip(to target: Double) {
        // Aether deliberately parks a programmatic seek at the exact duration
        // in a paused state. TheIntroDB uses that exact bound when credits run
        // to EOF, so complete the item through Silo's normal end/Next Up path
        // instead of leaving a frozen final frame.
        if duration.isFinite,
           duration > 0,
           target >= duration - 0.5 {
            currentTime = duration
            handleEndOfFile()
            return
        }
        seekTo(seconds: target)
    }

    private func currentIntroSkipKey(for range: TimeRange) -> String? {
        guard let sessionId = activePlaybackSessionId,
              let fileId = currentSelectedVersion?.fileId else {
            return nil
        }
        return "\(sessionId):\(fileId):\(range.start):\(range.end)"
    }

    private func currentCreditsSkipKey(for range: TimeRange) -> String? {
        guard let sessionId = activePlaybackSessionId,
              let fileId = currentSelectedVersion?.fileId else {
            return nil
        }
        return "\(sessionId):\(fileId):credits:\(range.start):\(range.end)"
    }

    func beginScrub(fraction: Double) {
        guard !hasReachedEndOfFile else { return }
        guard duration > 0 else { return }
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        isScrubbing = true
        scrubPreviewTime = max(0, min(fraction, 1)) * duration
        scrubPreviewProvider.begin(atSourceTime: scrubPreviewTime)
        hideControlsTask?.cancel()
    }

    func updateScrub(fraction: Double) {
        guard !hasReachedEndOfFile else { return }
        guard duration > 0 else { return }
        scrubPreviewTime = max(0, min(fraction, 1)) * duration
        scrubPreviewProvider.request(atSourceTime: scrubPreviewTime)
    }

    func endScrub(resumePlayback: Bool = false, shouldSeek: Bool = true) {
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
            scrubPreviewProvider.endInteraction()
            reloadsPlaybackPipeline = false
            Self.logger.info(
                "[CMP-SEEK] scrub ended without movement; resuming without seek at current=\(self.currentTime, privacy: .public)"
            )
        }
        if resumePlayback, !reloadsPlaybackPipeline {
            aetherPlaybackController.play()
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
        scrubPreviewProvider.endInteraction()
    }

    // MARK: - Track selection
    //
    // Aether owns all embedded and external media-track selection. Synthetic
    // realtime AI tracks remain app-owned and deliberately never enter
    // Aether's media-track id namespace.

    func selectAudio(_ track: PlayerTrack) {
        if activePreparedProtocolV3 != nil {
            // The server owns the switch on this path, so the track must not
            // be applied locally before its plan arrives. The selection is
            // published optimistically because the replan reads it back, but
            // nothing is persisted or recorded until the replan is actually
            // under way — a dropped switch must not be filed as a success.
            let priorAudioId = selectedAudioId
            let priorPendingAudioFfIndex = pendingAudioFfIndex
            pendingAudioFfIndex = nil
            selectedAudioId = track.trackId
            reapplySystemSubtitlePolicy()
            guard attemptProtocolV3Replan(
                position: currentTime,
                classification: "audio_track_changed",
                message: "User selected audio track \(track.title ?? String(track.trackId)).",
                requeueWhenBusy: true,
                trackTarget: queuedTrackTarget(forAudio: track)
            ) else {
                selectedAudioId = priorAudioId
                pendingAudioFfIndex = priorPendingAudioFfIndex
                reapplySystemSubtitlePolicy()
                showNotice(
                    title: "Couldn't change audio",
                    message: "The audio track couldn't be switched. Try again.",
                    tone: .warning,
                    duration: 5
                )
                scheduleHideControls()
                return
            }
            persistAudioSelection(track)
            recordAudioTrackSelectionBreadcrumb(
                track.trackId,
                reason: "user_selection",
                viaServerReplan: true
            )
            scheduleHideControls()
            return
        }
        pendingAudioFfIndex = nil
        selectedAudioId = track.trackId
        persistAudioSelection(track)
        reapplySystemSubtitlePolicy()
        applyAudioTrackSelection(track.trackId, reason: "user_selection")
        scheduleHideControls()
    }

    func selectSubtitle(_ track: PlayerTrack) {
        // Snapshot for the V3 branch below, which has to undo the optimistic
        // local selection if the server switch never gets issued.
        let priorSubtitleId = selectedSubtitleId
        let priorSecondarySubtitleId = selectedSecondarySubtitleId
        let priorPendingSubtitleFfIndex = pendingSubtitleFfIndex
        let priorHasExplicitSubtitleChoice = hasExplicitSubtitleChoice
        hasExplicitSubtitleChoice = true
        pendingSubtitleFfIndex = nil
        if selectedSecondarySubtitleId == track.trackId {
            selectedSecondarySubtitleId = nil
            applySecondarySubtitleTrackSelection(nil)
        }
        selectedSubtitleId = track.trackId
        Self.logger.info(
            "[CMP-SUB] select primary trackId=\(track.trackId, privacy: .public) title=\(track.title ?? "nil", privacy: .public) external=\(track.isExternal, privacy: .public) codec=\(track.codec ?? "nil", privacy: .public)"
        )
        if activePreparedProtocolV3 != nil,
           !SubtitleTrackIdSpace.isAILive(track.trackId) {
            let trackTarget = queuedTrackTarget(forSubtitle: track)
            if case .subtitle(_, let combinedIndex) = trackTarget {
                cmpLog(
                    "[CMP-SUB] phase=user_tap source="
                        + (track.isExternal ? "external" : "embedded")
                        + " combined_index="
                        + (combinedIndex.map(String.init) ?? "unmapped")
                )
            }
            // The replan is what actually switches the track, so nothing is
            // persisted or recorded until one is under way.
            guard attemptProtocolV3Replan(
                position: currentTime,
                classification: "subtitle_track_changed",
                message: "User selected subtitle track \(track.title ?? String(track.trackId)).",
                requeueWhenBusy: true,
                trackTarget: trackTarget
            ) else {
                selectedSubtitleId = priorSubtitleId
                pendingSubtitleFfIndex = priorPendingSubtitleFfIndex
                hasExplicitSubtitleChoice = priorHasExplicitSubtitleChoice
                if selectedSecondarySubtitleId != priorSecondarySubtitleId {
                    selectedSecondarySubtitleId = priorSecondarySubtitleId
                    applySecondarySubtitleTrackSelection(priorSecondarySubtitleId)
                }
                showNotice(
                    title: "Couldn't change subtitles",
                    message: "The subtitle track couldn't be switched. Try again.",
                    tone: .warning,
                    duration: 5
                )
                scheduleHideControls()
                return
            }
            persistSubtitleSelection(track)
            recordSubtitleTrackSelectionBreadcrumb(
                track.trackId,
                reason: "user_selection",
                viaServerReplan: true
            )
            scheduleHideControls()
            return
        }
        persistSubtitleSelection(track)
        applySubtitleTrackSelection(track.trackId, reason: "user_selection")
        scheduleHideControls()
    }

    func disableSubtitles() {
        let priorSubtitleId = selectedSubtitleId
        let priorSecondarySubtitleId = selectedSecondarySubtitleId
        let priorPendingSubtitleFfIndex = pendingSubtitleFfIndex
        let priorHasExplicitSubtitleChoice = hasExplicitSubtitleChoice
        hasExplicitSubtitleChoice = true
        pendingSubtitleFfIndex = nil
        if selectedSecondarySubtitleId != nil {
            selectedSecondarySubtitleId = nil
            applySecondarySubtitleTrackSelection(nil)
        }
        selectedSubtitleId = nil
        Self.logger.info("[CMP-SUB] disable primary subtitles")
        if activePreparedProtocolV3 != nil {
            // The replan is what actually clears the track, so nothing is
            // persisted or recorded until one is under way.
            guard attemptProtocolV3Replan(
                position: currentTime,
                classification: "subtitle_track_changed",
                message: "User disabled subtitles.",
                requeueWhenBusy: true,
                trackTarget: .subtitle(trackId: nil, combinedIndex: nil)
            ) else {
                selectedSubtitleId = priorSubtitleId
                pendingSubtitleFfIndex = priorPendingSubtitleFfIndex
                hasExplicitSubtitleChoice = priorHasExplicitSubtitleChoice
                if selectedSecondarySubtitleId != priorSecondarySubtitleId {
                    selectedSecondarySubtitleId = priorSecondarySubtitleId
                    applySecondarySubtitleTrackSelection(priorSecondarySubtitleId)
                }
                showNotice(
                    title: "Couldn't change subtitles",
                    message: "Subtitles couldn't be turned off. Try again.",
                    tone: .warning,
                    duration: 5
                )
                scheduleHideControls()
                return
            }
            persistSubtitleSelection(nil)
            recordSubtitleTrackSelectionBreadcrumb(
                nil,
                reason: "user_selection",
                viaServerReplan: true
            )
            scheduleHideControls()
            return
        }
        persistSubtitleSelection(nil)
        applySubtitleTrackSelection(nil, reason: "user_selection")
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
        guard backendCapabilities.supportsSecondarySubtitles else { return }
        guard !SubtitleCodecClassifier.isBitmap(track.codec) else { return }
        // Secondary sub cannot equal the primary sid; guard at the UI layer
        // so the user gets an immediate no-op rather than seeing stale state.
        guard track.trackId != selectedSubtitleId else { return }
        guard canRenderAsSecondarySubtitle(track) else { return }
        selectedSecondarySubtitleId = track.trackId
        applySecondarySubtitleTrackSelection(track.trackId)
        scheduleHideControls()
    }

    func disableSecondarySubtitles() {
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

    /// **Visibility** predicate for the "Search Subtitles…" entry row: an
    /// active playback session (the synthesized stream URL is session-scoped),
    /// a known media file, and a backend that can host downloaded sidecars.
    /// False for offline/local playback, where the row is meaningless and is
    /// hidden outright.
    ///
    /// This is the client-side half of the gate — it says nothing about
    /// whether the *server* can actually service a search. See
    /// ``subtitleSearchEnabled``.
    @MainActor
    var subtitleSearchVisible: Bool {
        activePlaybackSessionId != nil
            && currentSelectedVersion?.fileId != nil
            && backendCapabilities.supportsExternalPrimarySubtitles
    }

    /// **Enablement** predicate: visible *and* the server actually has
    /// external subtitle providers configured.
    ///
    /// The split exists because a server with no providers answers the search
    /// endpoint `200 {"results": null}` — so without this the user picks a
    /// language, waits out the 20–30s provider fan-out, and gets "No subtitles
    /// found", which reads as a broken feature rather than an unconfigured
    /// one. The row instead renders disabled with
    /// ``subtitleSearchUnavailableReason``.
    ///
    /// ``SubtitleProvidersStore/isAvailable`` fails **open**: older servers
    /// that 404 the provider-status probe keep a fully enabled row.
    @MainActor
    var subtitleSearchEnabled: Bool {
        subtitleSearchVisible && SubtitleProvidersStore.shared.isAvailable
    }

    /// Why the visible "Search Subtitles…" row is disabled, or `nil` when it
    /// is enabled (or not shown at all). Rendered in the row's value slot on
    /// tvOS and as the menu-item subtitle on iOS, so the disabled state is
    /// self-explaining rather than a mystery grey row.
    @MainActor
    var subtitleSearchUnavailableReason: String? {
        guard subtitleSearchVisible, !subtitleSearchEnabled else { return nil }
        return "Not set up on this server"
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
    /// `baseTrackCount` is the combined ordinal the **first** downloaded track
    /// occupies. The V3 plan's subtitle inventory is the authoritative track
    /// list — it publishes every track, including burn-in-only bitmap streams
    /// that carry no fetchable URL, over one dense ordinal space ordered
    /// externals → embedded → downloaded. So the first downloaded ordinal is
    /// exactly the number of non-downloaded inventory entries. Never derive
    /// this by counting or max-ing the delivered sidecar URLs: those omit
    /// burn-in-only tracks and would address the wrong track.
    @MainActor
    private func makeSubtitleHandoffContext() -> SubtitleAIController.HandoffContext? {
        guard backendCapabilities.supportsExternalPrimarySubtitles else {
            Self.logger.info(
                "[AI-SUB] backend \(self.activeRouteLabel, privacy: .public) can't host downloaded subtitles; handoff unavailable"
            )
            return nil
        }
        guard let sessionId = activePlaybackSessionId, !sessionId.isEmpty else {
            Self.logger.warning("[AI-SUB] no active session id for subtitle handoff")
            return nil
        }
        let serverUrl = resolvedServerUrl
        guard let inventory = activePreparedProtocolV3?.plan.subtitle.inventory else {
            Self.logger.warning("[AI-SUB] no V3 subtitle inventory for subtitle handoff")
            return nil
        }
        let baseTrackCount = Self.protocolV3DownloadedSubtitleBaseTrackCount(inventory)
        return SubtitleAIController.HandoffContext(
            sessionId: sessionId,
            baseTrackCount: baseTrackCount,
            resolveURL: { [weak self] path in self?.resolveServerUrl(path, serverUrl: serverUrl) }
        )
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
        case let mode? where PlaybackProtocolV3.SubtitleMode.locallyRendered.contains(mode):
            return .renderLocally(snapshot)
        case PlaybackProtocolV3.SubtitleMode.burnIn:
            return .serverRendered(snapshot)
        default:
            return nil
        }
    }

    static func isCurrentStreamCallback(
        _ callbackGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        callbackGeneration == currentGeneration
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
        let rendersSubtitleLocally = PlaybackProtocolV3.SubtitleMode.locallyRendered
            .contains(plan.subtitle.mode)
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
                "[AI-SUB] backend \(self.activeRouteLabel, privacy: .public) can't host downloaded subtitles; skipping handoff"
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
        aetherPlaybackController.addExternalSubtitleTrack(
            ExternalSubtitleTrack(
                url: descriptor.url,
                name: descriptor.label,
                language: descriptor.language,
                isForced: descriptor.forced ?? false,
                isHearingImpaired: descriptor.isHearingImpaired ?? false,
                isDefault: descriptor.isDefault ?? false,
                httpHeaders: aetherSubtitleRequestHeaders(for: descriptor.url),
                formatHint: descriptor.codec
            ),
            appTrackID: trackId
        )
        // The active V3 plan predates this track, so the plan-derived picker
        // cannot name it. Keep the row session-side until a later plan's
        // inventory publishes the same ordinal.
        if !locallyRegisteredSidecarSubtitleTracks.contains(where: { $0.trackId == trackId }) {
            locallyRegisteredSidecarSubtitleTracks.append(PlayerTrack(
                trackId: trackId,
                kind: .sub,
                title: descriptor.label,
                lang: descriptor.language,
                codec: descriptor.codec,
                audioChannelCount: nil,
                bitrate: nil,
                isDefault: descriptor.isDefault ?? false,
                isForced: descriptor.forced ?? false,
                isHearingImpaired: descriptor.isHearingImpaired ?? false,
                isExternal: true,
                isSelected: false,
                ffIndex: nil,
                srcId: descriptor.index
            ))
        }
        adoptAetherInventory()
    }

    // MARK: - Live AI subtitle bridge (M4)
    //
    // Thin internal accessors the `LiveSubtitleCoordinator` adapters call.
    // They exist because the adapters are distinct fileprivate types and so
    // can't reach the VM's `private` playback/notice state directly. Each is a
    // one-liner over an existing primitive; the interesting logic (offset-aware
    // cue conversion, dedupe) lives in the sink adapter.

    /// Live cues are normalized to Silo source time before the app-owned
    /// overlay consumes them. Aether's product-facing clock is source time.
    var liveSubtitleCueMediaTimeShift: Double {
        0
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
    /// newer live renderer already owns the single primary product slot.
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

    /// Perform the deferred live-track close, if armed. Called when Aether's
    /// inventory publishes the persisted sidecar selection, so the swap is
    /// seamless (selection has already moved off the live row).
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
        guard !audioTracks.isEmpty else { return }
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
        guard !subtitleTracks.isEmpty else { return }

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
        if selectedSubtitleId != nil {
            disableSubtitles()
        } else if let first = subtitleTracks.first {
            selectSubtitle(first)
        }
    }

    func seekToAdjacentChapter(forward: Bool) {
        guard !chapters.isEmpty else { return }
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
        showControls.toggle()
        if showControls {
            scheduleHideControls()
        }
    }

    func revealControls() {
        scheduleHideControls()
    }

    /// Hide the controls overlay immediately, cancelling any pending
    /// auto-hide. Wired to the Siri Remote Menu button on tvOS so the user
    /// can dismiss the overlay without waiting out the 5s timer; tapping
    /// Menu again falls through to player dismissal via `PlayerView`.
    func dismissControls() {
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
        // A restore waiting on a cover that will now never mount has to be
        // answered, or AVKit is left holding a handler for a dead session.
        resolvePendingPictureInPictureRestore(false)
        // The PiP coordinator is a singleton and its controller strongly
        // retains the AVPlayerLayer, the AVPlayer, and everything hanging off
        // it. SwiftUI's `dismantleUIView` normally releases it, but ordering
        // there is not guaranteed relative to this teardown, so drop it here
        // too rather than risk stranding the whole playback graph. Owner-keyed
        // so a late teardown cannot unbind a newer session's PiP.
        PictureInPictureCoordinator.shared.endSession(owner: self)
        // A restore that staged this view model but never reached SwiftUI would
        // otherwise hold the whole playback graph on a static.
        PlayerPresentationRestoration.discardAdoption(for: self)
        #endif
        activePlaybackSessionId = nil
        staleSessionRecoverySessionId = nil
        currentWatchDetail = nil
        currentSelectedVersion = nil
        playbackStats = .empty
        introRange = nil
        creditsRange = nil
        markerReconcileTask?.cancel()
        markerReconcileTask = nil
        markerReconciledSessionId = nil
        cancelPendingIntroAutoSkip()
        autoSkippedIntroKey = nil
        autoSkippedCreditsKey = nil
        autoSkipIntroCancelledKey = nil
        knownExternalSubtitles = []
        locallyRegisteredSidecarSubtitleTracks = []
        subtitleAI.reset()
        deferredLiveSubtitleCloseTask?.cancel()
        deferredLiveSubtitleCloseTask = nil
        pendingLiveSubtitleCloseTrackId = nil
        pendingServerRenderedSubtitleTrackId = nil
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
        settingsRefreshTask?.cancel()
        settingsRefreshTask = nil
        freshLoadTask?.cancel()
        freshLoadOwnsFailureHandling = false
        streamLoadGeneration &+= 1
        protocolV3ReplanTask?.cancel()
        protocolV3ReplanTask = nil
        seekReplanTask?.cancel()
        seekReplanTask = nil
        if let outputRouteObserverToken {
            NotificationCenter.default.removeObserver(outputRouteObserverToken)
            self.outputRouteObserverToken = nil
        }
        if let systemCaptionObserverToken {
            NotificationCenter.default.removeObserver(systemCaptionObserverToken)
            self.systemCaptionObserverToken = nil
        }
        if let foregroundExitObserverToken {
            NotificationCenter.default.removeObserver(foregroundExitObserverToken)
            self.foregroundExitObserverToken = nil
        }
        nextUpLookupTask?.cancel()
        nextUpOnDeckTask?.cancel()
        nextUpCountdownTask?.cancel()
        autoSkipIntroCountdownTask?.cancel()
        autoSkipIntroCountdownTask = nil
        skipDebounceTask?.cancel()
        seekFilterTimeoutTask?.cancel()
        holdSeekTask?.cancel()
        holdSeekAutoRampTask?.cancel()
        sleepTimer.cancel()
        nowPlaying.detach()
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

        // Same completion rule as the offline branch above. Closing from the
        // Next Up prompt (or after EOF) means the user finished the item, so
        // the final `stopSession` has to report the duration rather than the
        // paused position a few seconds short of it — otherwise online
        // playback never latches watched from that surface, while offline
        // playback does.
        let finalPosition = completionProgressPositionForCurrentItem()
        let scrubPreviewShutdown = disposeAetherPlayback()

        let connectivityToken = realtimeConnectivityObserverToken
        realtimeConnectivityObserverToken = nil
        let unavailabilityToken = realtimeUnavailabilityObserverToken
        realtimeUnavailabilityObserverToken = nil
        cleanupCompletionTask = Task {
            await scrubPreviewShutdown?.value
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
        MainActor.assumeIsolated {
            Self.logger.info("PlayerViewModel.deinit")
            isDisposed = true
            if let systemCaptionObserverToken {
                NotificationCenter.default.removeObserver(systemCaptionObserverToken)
            }
            if let outputRouteObserverToken {
                NotificationCenter.default.removeObserver(outputRouteObserverToken)
            }
            if let foregroundExitObserverToken {
                NotificationCenter.default.removeObserver(foregroundExitObserverToken)
            }
            freshLoadTask?.cancel()
            markerReconcileTask?.cancel()
            streamLoadGeneration &+= 1
            protocolV3ReplanTask?.cancel()
            seekReplanTask?.cancel()
            staleSessionRecoveryTask?.cancel()
            autoSkipIntroCountdownTask?.cancel()
            #if DEBUG
            debugLiveSubtitleTimer?.invalidate()
            debugLiveSubtitleTimer = nil
            #endif
            disposeAetherPlayback()
            let realtimeClient = self.realtimeClient
            Task {
                await realtimeClient?.unbind()
            }
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
            aetherPlaybackController.pause()
            if isAdminIssued(command) {
                showNotice(
                    title: "Playback paused by admin",
                    message: "An administrator paused this session.",
                    tone: .warning,
                    duration: 6
                )
            }
        case .unpause:
            aetherPlaybackController.play()
            if isAdminIssued(command) {
                showNotice(
                    title: "Playback resumed by admin",
                    message: "An administrator resumed this session.",
                    tone: .info,
                    duration: 6
                )
            }
        case .playPause:
            let wasPaused = aetherPlaybackController.isPaused
            if wasPaused {
                aetherPlaybackController.play()
            } else {
                aetherPlaybackController.pause()
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
            aetherPlaybackController.pause()
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
        additionalHeaders: [String: String] = [:],
        requiresHeaderAuthenticatedMedia: Bool = false,
        allowsAuthorizedMediaOrigins: Bool = false
    ) async -> StreamRequest? {
        let serverUrl = await ContinuumAPI.shared.currentServerUrl()
        let token = await ContinuumAPI.shared.currentAccessToken()
        return StreamRequest.resolve(
            rawURL: session.streamUrl,
            serverURL: serverUrl,
            additionalHeaders: additionalHeaders,
            accessToken: token,
            requiresHeaderAuthenticatedMedia: requiresHeaderAuthenticatedMedia,
            // The caller knows the attempt's session, so a proxy URL naming a
            // different one is rejected rather than trusted.
            authorizedMediaOriginSessionId: allowsAuthorizedMediaOrigins
                ? session.sessionId
                : nil
        )
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

    private func audioSelectionIndex(for track: PlayerTrack) -> Int? {
        track.srcId ?? track.ffIndex
    }

    /// Re-registers session-created sidecars (finished AI jobs, downloaded
    /// subtitles) with a freshly loaded engine under V3.
    ///
    /// Their `knownExternalSubtitles` entries were recorded for exactly this
    /// moment, but the V3 picker-only gate skips the generic re-registration
    /// path, so without this a quality/route replan leaves the row selected
    /// in the menu with no Aether resource behind it.
    private func reregisterLocallyCreatedSidecarsWithAether() {
        guard backendCapabilities.supportsExternalPrimarySubtitles else { return }
        var reregistered = false
        for local in locallyRegisteredSidecarSubtitleTracks {
            guard !aetherPlaybackController.containsSubtitle(appTrackID: local.trackId),
                  let known = knownExternalSubtitles.first(where: {
                      SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: $0.index) == local.trackId
                  }),
                  let url = resolveServerUrl(known.url, serverUrl: resolvedServerUrl) else {
                continue
            }
            aetherPlaybackController.addExternalSubtitleTrack(
                ExternalSubtitleTrack(
                    url: url,
                    name: known.label,
                    language: known.language,
                    isForced: known.forced ?? false,
                    isHearingImpaired: known.hearingImpaired ?? false,
                    isDefault: known.default ?? false,
                    httpHeaders: aetherSubtitleRequestHeaders(for: url),
                    formatHint: known.codec
                ),
                appTrackID: local.trackId
            )
            reregistered = true
        }
        guard reregistered else { return }
        // If the local row was the active selection, the new engine load lost
        // it; arm the existing pending path so inventory adoption reasserts
        // the engine-side selection once the load is established. The plan
        // cannot contest this id — it does not know the track.
        if let selectedSubtitleId,
           locallyRegisteredSidecarSubtitleTracks.contains(where: { $0.trackId == selectedSubtitleId }) {
            pendingSidecarSubtitleTrackId = selectedSubtitleId
        }
        adoptAetherInventory()
    }

    private func loadPendingExternalSubtitles() {
        if activePreparedProtocolV3 != nil {
            // `subtitle.inventory` feeds the V3 picker. Loading all of its URLs
            // into Aether gives the engine an uncommitted set of alternatives
            // and lets language/default policy override `subtitle.artifact`.
            // The exact selected artifact was already declared in AetherLoadSpec.
            pendingExternalSubtitles = []
            // A sidecar this session created itself (finished AI job or
            // downloaded subtitle) is not in the plan, so a reload rebuilds
            // the alias table without it while the picker still shows its
            // row; only those tracks are re-registered here.
            reregisterLocallyCreatedSidecarsWithAether()
            Self.logger.info("[CMP-SUB] keeping V3 subtitle inventory picker-only")
            return
        }
        let restoredFromKnownCache = pendingExternalSubtitles.isEmpty
        let allPending = restoredFromKnownCache
            ? knownExternalSubtitles
            : pendingExternalSubtitles
        let pending = allPending
        pendingExternalSubtitles = []
        if pending.isEmpty {
            Self.logger.info(
                "[CMP-SUB] no external subtitles to register route=\(self.activeRouteLabel, privacy: .public) currentTracks=\(self.subtitleTracks.count, privacy: .public)"
            )
        }

        Self.logger.info(
            "[CMP-SUB] resolving external subtitles count=\(pending.count, privacy: .public) route=\(self.activeRouteLabel, privacy: .public) supportsExternal=\(self.backendCapabilities.supportsExternalPrimarySubtitles, privacy: .public) fromKnownCache=\(restoredFromKnownCache, privacy: .public)"
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
                isDefault: sub.default,
                isHearingImpaired: sub.hearingImpaired,
                fontBundleUrl: sub.fontBundleUrl.flatMap {
                    resolveServerUrl($0, serverUrl: resolvedServerUrl)
                },
                url: url
            ))
        }
        if !pending.isEmpty, descriptors.isEmpty {
            Self.logger.warning("[CMP-SUB] no external subtitle descriptors survived URL resolution")
        }
        if backendCapabilities.supportsExternalPrimarySubtitles {
            Self.logger.info(
                "[CMP-SUB] registering sidecar subtitles descriptors=\(descriptors.count, privacy: .public) route=\(self.activeRouteLabel, privacy: .public)"
            )
            for descriptor in descriptors {
                let appTrackID = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: descriptor.index)
                guard !aetherPlaybackController.containsSubtitle(appTrackID: appTrackID) else { continue }
                aetherPlaybackController.addExternalSubtitleTrack(
                    ExternalSubtitleTrack(
                        url: descriptor.url,
                        name: descriptor.label,
                        language: descriptor.language,
                        isForced: descriptor.forced ?? false,
                        isHearingImpaired: descriptor.isHearingImpaired ?? false,
                        isDefault: descriptor.isDefault ?? false,
                        httpHeaders: aetherSubtitleRequestHeaders(for: descriptor.url),
                        formatHint: descriptor.codec
                    ),
                    appTrackID: appTrackID
                )
            }
            adoptAetherInventory()
        } else {
            Self.logger.info(
                "[CMP-ROUTE] skipping sidecar subtitle registration on backend=\(self.activeRouteLabel, privacy: .public)"
            )
        }
    }

    /// Aether interprets nil subtitle headers as "inherit every media header."
    /// Always pass an explicit dictionary so Silo's bearer is shared only with
    /// the active media/server origin and never with an absolute third-party
    /// sidecar URL.
    private func aetherSubtitleRequestHeaders(for resourceURL: URL) -> [String: String] {
        guard let spec = aetherPlaybackController.activeSpec else { return [:] }
        let serverOrigin = URL(string: resolvedServerUrl)
        return AetherLoadSpec.subtitleRequestHeaders(
            spec.options.httpHeaders,
            resourceURL: resourceURL,
            trustedOriginURLs: [spec.sourceURL, serverOrigin].compactMap { $0 }
        )
    }

    /// Every audio-track change — user pick, resume of a persisted or
    /// detail-screen choice, post-route-switch restore — reaches the backend
    /// through here, so `reason` is required rather than defaulted: a report
    /// that cannot tell "the user chose this" from "we restored this" cannot
    /// answer the question these breadcrumbs exist for.
    private func applyAudioTrackSelection(_ trackId: Int64, reason: String) {
        recordAudioTrackSelectionBreadcrumb(trackId, reason: reason, viaServerReplan: false)
        guard let id = Int(exactly: trackId) else { return }
        aetherPlaybackController.selectAudioTrack(id: id)
    }

    /// Same contract as `applyAudioTrackSelection`: the one funnel every
    /// primary-subtitle change passes through, with an explicit `reason`.
    /// `nil` means subtitles off.
    private func applySubtitleTrackSelection(_ trackId: Int64?, reason: String) {
        Self.logger.info(
            "[CMP-SUB] apply primary selection trackId=\(trackId.map(String.init) ?? "nil", privacy: .public) route=\(self.activeRouteLabel, privacy: .public)"
        )
        recordSubtitleTrackSelectionBreadcrumb(trackId, reason: reason, viaServerReplan: false)
        if let trackId, SubtitleTrackIdSpace.isAILive(trackId) {
            // Synthetic live cues are rendered by Silo's overlay and must
            // never be forwarded into Aether's media-track id namespace.
            aetherPlaybackController.selectSubtitleTrack(id: nil)
        } else {
            aetherPlaybackController.selectSubtitleTrack(id: trackId)
        }
    }

    // MARK: - Track-selection breadcrumbs
    //
    // Split out of the two apply funnels because the funnels are not the only
    // way a track change happens: when a Protocol V3 plan is active the change
    // is executed by the *server* — the pick is sent up as a replan and comes
    // back as a new plan — so `selectAudio`/`selectSubtitle`/`disableSubtitles`
    // return before ever reaching an apply call. Without these helpers the only
    // trace of a server-side track change is the bridge's replan breadcrumb,
    // whose `reason` is the coarse classification (`audio_track_changed`) and
    // which knows nothing about the ordinal or the subtitle source.
    //
    // Both are strictly side-effect free — they read state and emit, nothing
    // else. That is the invariant that lets them be called on the replan path:
    // recording an intent must not apply it, because applying a track locally
    // before the server's replacement plan lands is exactly the desync these
    // breadcrumbs exist to diagnose.

    /// Records an audio pick. `viaServerReplan` distinguishes "the engine was
    /// told to switch" from "the pick was sent to the server and playback
    /// reloads" — a real difference in what the user sees (an instant switch
    /// versus a rebuffer), and one no registered key expresses, so it goes in
    /// the free-text message.
    private func recordAudioTrackSelectionBreadcrumb(
        _ trackId: Int64,
        reason: String,
        viaServerReplan: Bool
    ) {
        #if os(iOS) || os(tvOS)
        // The track's title and language are user-visible content metadata,
        // not diagnostics; the registry offers no key for them and they are
        // deliberately not smuggled into `msg`. The ordinal is enough to
        // correlate against the plan's selected_tracks.
        DiagTrace.breadcrumb(
            .essential,
            category: .playback,
            tag: "Player",
            message: viaServerReplan
                ? "audio track selected, requesting server replan"
                : "audio track selected",
            attrs: [
                "reason": .string(reason),
                "sink": .string(
                    audioTracks.first(where: { $0.trackId == trackId })
                        .flatMap(audioSelectionIndex(for:))
                        .map { "audio_ordinal_\($0)" } ?? "audio_ordinal_unknown"
                ),
                "play_method": .string(activeRouteLabel),
            ]
        )
        #endif
    }

    /// Records a primary-subtitle pick, or an explicit "off" when `trackId` is
    /// nil. Same `viaServerReplan` contract as the audio helper.
    private func recordSubtitleTrackSelectionBreadcrumb(
        _ trackId: Int64?,
        reason: String,
        viaServerReplan: Bool
    ) {
        #if os(iOS) || os(tvOS)
        // `sink` carries the track's *kind*, not its identity: whether the
        // cues come from an embedded stream, a server sidecar, or a live AI
        // track is the thing that explains a rendering complaint, and unlike
        // the title it is not user content.
        let action = trackId == nil ? "subtitles disabled" : "subtitle track selected"
        DiagTrace.breadcrumb(
            .essential,
            category: .playback,
            tag: "Player",
            message: viaServerReplan ? "\(action), requesting server replan" : action,
            attrs: [
                "reason": .string(reason),
                "sink": .string(trackId.map(Self.subtitleTrackKind) ?? "none"),
                "play_method": .string(activeRouteLabel),
            ]
        )
        #endif
    }

    /// Which subtitle source a track id names. The id space is the only
    /// classifier available at the funnel, and it is exactly the distinction
    /// worth recording.
    private static func subtitleTrackKind(_ trackId: Int64) -> String {
        if SubtitleTrackIdSpace.isAILive(trackId) { return "ai_live" }
        if SubtitleTrackIdSpace.isSidecar(trackId) { return "sidecar" }
        return "embedded"
    }

    private func applySecondarySubtitleTrackSelection(_ trackId: Int64?) {
        guard let trackId else {
            aetherPlaybackController.selectSecondarySubtitleTrack(id: nil)
            return
        }
        guard !SubtitleTrackIdSpace.isAILive(trackId),
              let track = subtitleTracks.first(where: { $0.trackId == trackId }),
              !SubtitleCodecClassifier.isBitmap(track.codec) else {
            selectedSecondarySubtitleId = nil
            aetherPlaybackController.selectSecondarySubtitleTrack(id: nil)
            return
        }
        registerSecondarySubtitleWithAetherIfNeeded(track)
        // Only a track Aether actually holds can be rendered as the secondary
        // one. Under V3 the plan mounts a single artifact, so an inventory row
        // that could not be registered above has no engine id at all — showing
        // it checked while nothing renders is worse than refusing the pick.
        guard aetherPlaybackController.containsSubtitle(appTrackID: trackId)
                || !SubtitleTrackIdSpace.isSidecar(trackId) else {
            Self.logger.warning(
                "[CMP-SUB] secondary subtitle \(trackId, privacy: .public) has no Aether track; clearing"
            )
            selectedSecondarySubtitleId = nil
            aetherPlaybackController.selectSecondarySubtitleTrack(id: nil)
            return
        }
        aetherPlaybackController.selectSecondarySubtitleTrack(id: trackId)
    }

    /// Mounts a V3 inventory sidecar on demand so it can be used as the
    /// secondary subtitle.
    ///
    /// The plan declares exactly one artifact, which is the primary. Every
    /// other picker row is server metadata the engine has never seen, so a
    /// dual-subtitle pick has to register its URL before it can be selected.
    private func registerSecondarySubtitleWithAetherIfNeeded(_ track: PlayerTrack) {
        guard !aetherPlaybackController.containsSubtitle(appTrackID: track.trackId),
              let url = protocolV3InventorySidecarURL(for: track) else {
            return
        }
        aetherPlaybackController.addExternalSubtitleTrack(
            ExternalSubtitleTrack(
                url: url,
                name: track.title,
                language: track.lang,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                isDefault: track.isDefault,
                httpHeaders: aetherSubtitleRequestHeaders(for: url),
                formatHint: track.codec
            ),
            appTrackID: track.trackId
        )
    }

    /// Resolved sidecar URL the active plan publishes for this picker row, or
    /// nil when the row is not a downloadable sidecar (`burn_in_only` rows
    /// carry no URL) or no V3 plan is active.
    private func protocolV3InventorySidecarURL(for track: PlayerTrack) -> URL? {
        guard let plan = activePreparedProtocolV3?.plan,
              let combinedIndex = track.srcId,
              let item = plan.subtitle.inventory.first(where: {
                  $0.combinedIndex == combinedIndex
              }),
              item.delivery == "sidecar",
              let raw = item.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return resolveServerUrl(raw, serverUrl: resolvedServerUrl)
    }

    /// Whether a picker row can actually be rendered as the secondary
    /// subtitle: it is either already mounted in Aether or can be mounted from
    /// the plan inventory on demand.
    private func canRenderAsSecondarySubtitle(_ track: PlayerTrack) -> Bool {
        guard activePreparedProtocolV3 != nil else { return true }
        if SubtitleTrackIdSpace.isAILive(track.trackId) { return false }
        return aetherPlaybackController.containsSubtitle(appTrackID: track.trackId)
            || protocolV3InventorySidecarURL(for: track) != nil
    }

    // MARK: - Live AI subtitle track seam

    /// Open a synthetic live AI subtitle track in the given slot on the
    /// active backend. Cues are then streamed in via `feedLiveSubtitleCue`.
    /// Route-agnostic so a backend switch keeps working.
    func openLiveSubtitleTrack(slot: SubtitleSlot = .primary, label: String?, language: String?) {
        switch slot {
        case .primary:
            livePrimarySubtitleCues = []
        case .secondary:
            liveSecondarySubtitleCues = []
        }
    }

    /// Feed one normalized source-time cue into the app-owned overlay.
    func feedLiveSubtitleCue(
        slot: SubtitleSlot = .primary,
        cue: LiveSubtitleCue
    ) {
        switch slot {
        case .primary:
            livePrimarySubtitleCues.append(cue)
            livePrimarySubtitleCues = Self.evictingLiveSubtitleCues(
                livePrimarySubtitleCues,
                position: currentTime
            )
        case .secondary:
            liveSecondarySubtitleCues.append(cue)
            liveSecondarySubtitleCues = Self.evictingLiveSubtitleCues(
                liveSecondarySubtitleCues,
                position: currentTime
            )
        }
    }

    /// Bound on retained live AI cues. A fast translator can outrun the
    /// playhead by a wide margin, so the buffer still needs a hard cap.
    static let liveSubtitleCueLimit = 512

    /// Trims a live cue buffer back to `limit` without dropping anything the
    /// playhead has not reached yet.
    ///
    /// A plain oldest-first trim is wrong here: cues arrive as fast as the
    /// translator emits them, not in playback lockstep, so a big batch can
    /// push the count over the cap while every cue in the buffer is still
    /// ahead of the playhead — and the ones evicted first would be exactly the
    /// ones about to render. Already-passed cues (earliest end first) go
    /// first; only if evicting all of them still leaves the buffer over the
    /// cap do the furthest-future cues go, so the cues nearest the playhead
    /// are always the last to be dropped.
    static func evictingLiveSubtitleCues(
        _ cues: [LiveSubtitleCue],
        position: Double,
        limit: Int = PlayerViewModel.liveSubtitleCueLimit
    ) -> [LiveSubtitleCue] {
        guard cues.count > limit else { return cues }
        var overflow = cues.count - limit
        var evicted = Set(
            cues.indices
                .filter { cues[$0].endTime < position }
                .sorted { cues[$0].endMs < cues[$1].endMs }
                .prefix(overflow)
        )
        overflow -= evicted.count
        if overflow > 0 {
            evicted.formUnion(
                cues.indices
                    .filter { !evicted.contains($0) }
                    .sorted { cues[$0].startMs > cues[$1].startMs }
                    .prefix(overflow)
            )
        }
        return cues.indices.filter { !evicted.contains($0) }.map { cues[$0] }
    }

    func closeLiveSubtitleTrack(slot: SubtitleSlot = .primary) {
        switch slot {
        case .primary:
            livePrimarySubtitleCues = []
        case .secondary:
            liveSecondarySubtitleCues = []
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
                audioChannelCount: nil,
                bitrate: nil,
                isDefault: false,
                isForced: false,
                isHearingImpaired: false,
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

        debugLiveSubtitleLineIndex = 0
        let cannedLines = [
            "Live AI subtitle seam is working.",
            "Cue two — rendered from normalized source time.",
            "Multi-line cue:\nsecond line here.",
            "Escapes are stripped: {not an override}.",
            "These cues stream at currentTime+.",
        ]

        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = self.currentTime
                let start = now + 0.3
                let end = start + 2.6
                let text = cannedLines[self.debugLiveSubtitleLineIndex % cannedLines.count]
                self.debugLiveSubtitleLineIndex += 1
                if let cue = self.debugLiveSubtitleTrack.makeCue(start: start, end: end, text: text) {
                    self.feedLiveSubtitleCue(slot: .primary, cue: cue)
                    Self.logger.info(
                        "[CMP-SUB] DEBUG fed live cue startMs=\(cue.startMs, privacy: .public) durMs=\(cue.durationMs, privacy: .public) textLen=\(cue.text.count, privacy: .public)"
                    )
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        debugLiveSubtitleTimer = timer
    }

    /// DEBUG-only: stop the fake-live-subtitle stub and close the track.
    func debugStopFakeLiveSubtitles() {
        debugLiveSubtitleTimer?.invalidate()
        debugLiveSubtitleTimer = nil
        debugLiveSubtitleLineIndex = 0
        if selectedSubtitleId.map(SubtitleTrackIdSpace.isAILive) == true {
            disableSubtitles()
        }
        subtitleTracks.removeAll { SubtitleTrackIdSpace.isAILive($0.trackId) }
        closeLiveSubtitleTrack(slot: .primary)
        Self.logger.info("[CMP-SUB] DEBUG fake live subtitles stopped")
    }
    #endif

    private func applyAutoSubtitlePreferencesIfNeeded(forceReevaluation: Bool = false) {
        guard !hasExplicitSubtitleChoice, let prefs = prefsForCurrentItem else { return }
        if prefsResolvedForCurrentItem && !forceReevaluation {
            return
        }

        let allSubs = subtitleTracks
        guard !allSubs.isEmpty else {
            prefsResolvedForCurrentItem = false
            return
        }

        let audioLang = audioTracks
            .first(where: { $0.trackId == selectedAudioId })?
            .lang
        let pick = SubtitleAutoResolver.resolve(.init(
            preferredLanguage: prefs.preferredLanguage,
            additionalPreferredLanguages: prefs.additionalPreferredLanguages,
            mode: prefs.mode,
            showForced: prefs.showForced,
            forcedOnly: prefs.forcedOnly,
            preferAccessibilityTracks: prefs.preferAccessibilityTracks,
            disableWhenNoLanguageMatch: prefs.disableWhenNoLanguageMatch,
            trackSignature: prefs.trackSignature,
            availableSubtitles: allSubs,
            currentAudioLanguage: audioLang
        ))
        // An empty callback still has to clear a server-seeded automatic
        // selection in device-settings mode, but it must not latch the
        // resolver: embedded or sidecar tracks can arrive in a later update.
        prefsResolvedForCurrentItem = !allSubs.isEmpty
        applyAutoSubtitle(pick)
    }

    /// Answer AetherEngine's `systemCaptionRequest` (upstream api.md, "The
    /// system asks for captions").
    ///
    /// iOS 26's Automatic Subtitles turn captions on with no read API behind
    /// them, so the engine forwarding the ask is the only observable signal.
    /// Aether has already deselected its own rendition by the time this lands —
    /// a fullscreen native caption box would draw over Silo's overlay — so the
    /// host answers by selecting its own matching track. No match is a no-op:
    /// the contract is "select a matching track", not "turn something on".
    private func handleSystemCaptionRequest(
        epoch: AetherPlaybackController.LoadEpoch,
        request: SystemCaptionRequest
    ) {
        // Track lists and V3 plans are per-load; a request that crossed a
        // reload seam names a language against inventory that no longer exists.
        guard epoch == aetherPlaybackController.activeLoadEpoch else { return }
        guard let language = request.language, !language.isEmpty else { return }
        guard !subtitleTracks.isEmpty else { return }

        // `.always` because the system already decided captions should be on;
        // `disableWhenNoLanguageMatch: false` keeps an unmatched language a
        // no-op rather than clearing a selection the user can see.
        let pick = SubtitleAutoResolver.resolve(.init(
            preferredLanguage: language,
            mode: .always,
            showForced: false,
            disableWhenNoLanguageMatch: false,
            trackSignature: nil,
            availableSubtitles: subtitleTracks,
            currentAudioLanguage: audioTracks
                .first(where: { $0.trackId == selectedAudioId })?
                .lang
        ))
        guard case .select(let track) = pick else { return }
        Self.logger.info(
            "[CMP-SUB] system caption request answered language=\(language, privacy: .public) trackId=\(track.trackId, privacy: .public)"
        )
        // Routed through the shared applier so a V3 session replans server-side
        // instead of drifting from `selected_tracks`.
        applyAutoSubtitle(.select(track))
    }

    private func reapplySystemSubtitlePolicy() {
        guard settings.subtitleMatchesSystemAppearance, !hasExplicitSubtitleChoice else { return }
        subtitleOrderingLanguage = settings.subtitleSystemSelectionPreferences
            .preferredLanguages.first
        prefsForCurrentItem = systemCaptionPrefsSnapshot()
        prefsResolvedForCurrentItem = false
        applyAutoSubtitlePreferencesIfNeeded(forceReevaluation: true)
    }

    private func systemCaptionPrefsSnapshot() -> PrefsSnapshot {
        let system = settings.subtitleSystemSelectionPreferences
        let firstLanguage = system.preferredLanguages.first
        let remainingLanguages = Array(system.preferredLanguages.dropFirst())
        switch system.displayMode {
        case .forcedOnly:
            return PrefsSnapshot(
                preferredLanguage: firstLanguage,
                additionalPreferredLanguages: remainingLanguages,
                mode: .auto,
                showForced: true,
                forcedOnly: true,
                preferAccessibilityTracks: system.prefersAccessibilityTracks,
                disableWhenNoLanguageMatch: true,
                trackSignature: nil
            )
        case .automatic:
            return PrefsSnapshot(
                preferredLanguage: firstLanguage,
                additionalPreferredLanguages: remainingLanguages,
                mode: .auto,
                showForced: true,
                forcedOnly: false,
                preferAccessibilityTracks: system.prefersAccessibilityTracks,
                disableWhenNoLanguageMatch: true,
                trackSignature: nil
            )
        case .alwaysOn:
            return PrefsSnapshot(
                preferredLanguage: firstLanguage,
                additionalPreferredLanguages: remainingLanguages,
                mode: .always,
                showForced: false,
                forcedOnly: false,
                preferAccessibilityTracks: system.prefersAccessibilityTracks,
                disableWhenNoLanguageMatch: true,
                trackSignature: nil
            )
        }
    }

    private func serverSubtitlePrefsSnapshot(_ watchDetail: WatchDetail) -> PrefsSnapshot {
        PrefsSnapshot(
            preferredLanguage: watchDetail.effectiveSubtitleLanguage,
            additionalPreferredLanguages: [],
            mode: SubtitleMode(rawValue: watchDetail.effectiveSubtitleMode ?? ""),
            showForced: watchDetail.effectiveShowForcedSubtitles ?? false,
            forcedOnly: false,
            preferAccessibilityTracks: false,
            disableWhenNoLanguageMatch: false,
            trackSignature: watchDetail.effectiveSubtitleTrackSignature
        )
    }

    /// Apply a resolver verdict. `noChange` is the "leave the player
    /// alone" case (no preference points anywhere); `disable` and
    /// `select` actually mutate state.
    private func applyAutoSubtitle(_ pick: SubtitleAutoSelection) {
        switch pick {
        case .noChange:
            return
        case .disable:
            if replanAutomaticProtocolV3SubtitleSelection(nil) { return }
            if selectedSubtitleId != nil {
                selectedSubtitleId = nil
                applySubtitleTrackSelection(nil, reason: "auto_preference")
            }
        case .select(let track):
            if replanAutomaticProtocolV3SubtitleSelection(track) { return }
            if selectedSubtitleId != track.trackId {
                selectedSubtitleId = track.trackId
                applySubtitleTrackSelection(track.trackId, reason: "auto_preference")
            }
        }
    }

    /// System/server caption policy changes are protocol intent on V3. The
    /// server must mint the replacement plan; mutating only the local player
    /// would make selected_tracks and later recovery disagree with the UI.
    private func replanAutomaticProtocolV3SubtitleSelection(_ track: PlayerTrack?) -> Bool {
        guard let activePreparedProtocolV3,
              let version = currentSelectedVersion,
              protocolV3ReplanTask == nil,
              currentWatchDetail != nil else {
            return false
        }
        let combinedIndex = track.flatMap {
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                for: $0,
                in: version,
                inventory: activePreparedProtocolV3.plan.subtitle.inventory
            )
        }
        guard combinedIndex != activePreparedProtocolV3.plan.selectedTracks.subtitle?.index else {
            return false
        }

        selectedSubtitleId = track?.trackId
        lastLoadRequest?.preferredProtocolV3SubtitleIndex = combinedIndex
        attemptProtocolV3Replan(
            position: currentTime,
            classification: "subtitle_track_changed",
            message: "Automatic caption policy selected a different subtitle track."
        )
        return true
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
        // The HUD pins its host visible (`pinControlsVisible` in `openHUD`).
        // Actions taken from inside it — track selection, remote play/pause —
        // funnel through here and must not re-arm the auto-hide out from
        // under the open HUD: on tvOS the hide swaps the press-capture sink
        // in beneath it, splitting remote presses across two owners.
        // `closeHUD()` calls back in after clearing the flag, which restores
        // the normal auto-hide lifecycle.
        if isHUDPresented {
            pinControlsVisible()
            return
        }
        hideControlsTask?.cancel()
        showControls = true
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
        switch command.name {
        case .play:
            aetherPlaybackController.play()
            scheduleHideControls()
        case .pause:
            aetherPlaybackController.pause()
            scheduleHideControls()
        case .playPause:
            togglePlayPause()
        case .seek:
            guard let seconds = command.seconds else {
                throw SiloControlPlayerError.missingSeekPosition
            }
            seekTo(seconds: seconds)
        case .stop:
            aetherPlaybackController.pause()
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

    func pause() { owner?.aetherPlaybackController.pause() }
    func play() { owner?.aetherPlaybackController.play() }
    var isPlaying: Bool { owner?.isPlaying ?? false }
}

/// `LiveSubtitleSink` over the VM's live-track primitives, selection plumbing,
/// completion handoff, and notice surface. Owns the per-`track_key`
/// normalized `LiveSubtitleTrack` converters and the `track_key → ordinal`
/// mapping before publishing source-time cues to Silo's overlay.
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
        // Realtime cue timestamps are already absolute Silo source time.
        let shift = owner.liveSubtitleCueMediaTimeShift
        let movieStart = cue.start - shift
        let movieEnd = cue.end - shift
        guard var converter = converters[key] else { return }
        let converted = converter.makeCue(start: movieStart, end: movieEnd, text: cue.text)
        converters[key] = converter // persist dedupe state (value type)
        guard let converted else { return }
        if diagCueLogBudget > 0 {
            diagCueLogBudget -= 1
            let playheadMs = Int64((owner.currentTime - shift) * 1000.0)
            Self.logger.info(
                "[AI-LIVE-DIAG] feed cue start=\(cue.start, privacy: .public) shift=\(shift, privacy: .public) startMs=\(converted.startMs, privacy: .public) durMs=\(converted.durationMs, privacy: .public) playheadMs=\(playheadMs, privacy: .public) Δms=\(converted.startMs - playheadMs, privacy: .public) textLen=\(converted.text.count, privacy: .public)"
            )
        }
        owner.feedLiveSubtitleCue(
            slot: .primary,
            cue: converted
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
        // deferred row removal + live-cue teardown from here.
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
