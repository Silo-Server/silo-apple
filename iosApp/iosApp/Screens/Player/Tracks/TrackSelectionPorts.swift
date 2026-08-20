import Foundation

/// The read-only session/plan facts the track half needs from the playback
/// core, snapshotted per call.
///
/// Before the extraction each of these was a direct `PlayerViewModel` property
/// read from inside the track code (inventory-2 §4, "Track half → core"). The
/// coordinator takes them through one value so it never holds a reference to
/// the view model and so the engine session can supply the same facts in a
/// later wave without the coordinator changing.
struct TrackSelectionContext {
    let activePreparedProtocolV3: PreparedPlaybackV3?
    let currentSelectedVersion: FileVersion?
    let currentWatchDetail: WatchDetail?
    let serverSessionId: String?
    let resolvedServerUrl: String
    let activeRouteKind: PlaybackEngineKind
    let backendCapabilities: PlayerBackendCapabilities
    /// True while playback is running from a local download — there is no
    /// server session, so nothing the track half persists has anywhere to go.
    let isOfflinePlayback: Bool
    let currentTime: Double
    let isBackgroundSuspended: Bool
    let isPlaying: Bool
}

/// Everything `TrackSelectionCoordinator` needs from its host that is not
/// track state: the backend it applies selections to, the session context it
/// reads, the server replan it requests, and the three UI affordances the
/// selection commands touch (notice, control auto-hide, URL resolution).
///
/// A struct of closures rather than a protocol: the coordinator is the only
/// consumer, the view model is the only producer today, and a later wave
/// swaps the producer for the engine session/actor without the coordinator
/// changing shape.
struct TrackSelectionPorts {
    /// The active playback backend, or nil before the execution plan resolves
    /// (every track apply is a no-op then — the pending state carries the
    /// intent to the next track list instead).
    var backend: () -> AVPlayerBackend?
    var context: () -> TrackSelectionContext
    // The three narrow reads below duplicate fields of `context` on purpose.
    // `PlayerViewModel` is `@Observable`, so whatever a member touches while a
    // SwiftUI body evaluates it becomes that body's invalidation set. The
    // display members (`subtitleSearchVisible` and friends,
    // `availableSecondarySubtitleTracks`) are evaluated inside the tvOS info
    // HUD and the subtitle panes; taking the whole context there would add
    // `currentTime` — which the 0.1 s periodic time observer writes ten times a
    // second — to that set and re-run those bodies at that rate. They read
    // exactly the properties they read before the extraction, one closure per
    // property so the `&&` short-circuit still decides which ones are touched.
    // Everything else in the coordinator runs from a command or a callback,
    // never inside a body, and keeps using the whole-context snapshot.
    var backendCapabilities: () -> PlayerBackendCapabilities
    var serverSessionId: () -> String?
    var currentSelectedVersion: () -> FileVersion?
    /// Ask the server for a replacement V3 plan. Maps onto the shell's
    /// `requestReplan(_: ReplanIntent)` with `position` taken from the same
    /// `currentTime` the four call sites passed. The subtitle the replan is
    /// about travels through
    /// `setLastLoadRequestProtocolV3SubtitleIndex` — the one channel that can
    /// distinguish "write nil" from "no write" — at the single site that has a
    /// value.
    var requestReplan: (_ classification: String, _ message: String) -> Void
    /// True while a V3 replan round trip is outstanding. The producer reads
    /// `PlayerViewModel.replanSuspensionHolder`, which `prepareReplan` arms
    /// *inside* the async round trip (not when the replan is requested) and
    /// `releaseReplanSuspension` clears — so this is the "a replacement plan is
    /// actually being fetched" predicate, not "a replan was asked for".
    var isReplanInFlight: () -> Bool
    /// The durable load request whose `preferred*` fields are the fallback for
    /// the resume resolvers. Read-only: the only field the track half writes is
    /// covered by `setLastLoadRequestProtocolV3SubtitleIndex`.
    var lastLoadRequest: () -> LoadRequest?
    var setLastLoadRequestProtocolV3SubtitleIndex: (Int?) -> Void
    var showNotice: @MainActor (_ title: String, _ message: String, _ tone: PlayerNoticeTone, _ duration: TimeInterval) -> Void
    var activeNotice: () -> PlayerNotice?
    /// Drop the on-screen notice and its dismissal timer.
    var dismissNotice: () -> Void
    var scheduleHideControls: () -> Void
    var resolveServerUrl: (_ raw: String, _ serverUrl: String) -> URL?
    /// Whether the realtime websocket can carry live AI-subtitle cues. Owned by
    /// the view model (it mirrors the realtime client's connectivity).
    var subtitleAILiveOverlayAvailable: () -> Bool
    /// Device-settings vs server-policy subtitle selection: the gate on almost
    /// every automatic subtitle branch. Defaults to the process-wide settings
    /// object the view model would otherwise hand over, so the production
    /// construction site says nothing and a test can vary it per instance.
    var subtitleMatchesSystemAppearance: () -> Bool = {
        PlayerSettings.shared.subtitleMatchesSystemAppearance
    }
    /// Apple's caption *selection* preferences (ordered languages, display
    /// mode, accessibility preference). Same default, same reason.
    var systemSelectionPreferences: () -> SystemCaptionSelectionPreferences = {
        PlayerSettings.shared.subtitleSystemSelectionPreferences
    }
}

extension TrackSelectionContext {
    /// Stand-in for the impossible case of the context port being called after
    /// the view model that owns the coordinator has gone away. Describes "no
    /// session, no plan, no capabilities, suspended", so nothing could be
    /// applied through it if it ever were reached.
    static let unavailable = TrackSelectionContext(
        activePreparedProtocolV3: nil,
        currentSelectedVersion: nil,
        currentWatchDetail: nil,
        serverSessionId: nil,
        resolvedServerUrl: "",
        activeRouteKind: .avPlayerNativeDirect,
        backendCapabilities: PlayerBackendCapabilities(
            supportsExternalPrimarySubtitles: false,
            supportsSecondarySubtitles: false,
            supportsVideoGravity: false,
            supportsSubtitleDelay: false,
            supportsSubtitleStyling: false
        ),
        isOfflinePlayback: false,
        currentTime: 0,
        isBackgroundSuspended: true,
        isPlaying: false
    )
}
