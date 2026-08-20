import Foundation
import OSLog

/// The player's track half: the published audio/subtitle lists and selection
/// ids, the eight `pending*` restore intents, the subtitle-preference
/// resolution funnels, the provider-search + AI-subtitle surface, and the live
/// AI-subtitle bridge.
///
/// Extracted from `PlayerViewModel` unchanged (Stage 2 wave 1C). Every decision
/// site, reason string, breadcrumb and persist call is the one that was there
/// before; the only difference is that the ~40 reads of core session state and
/// the handful of writes into it now go through `TrackSelectionPorts` instead
/// of touching the view model directly.
///
/// `PlayerViewModel` keeps a forwarding member for every name the views used,
/// so no view file changed. Observation is transitive: the view model holds
/// this object, its forwarders read this object's `@Observable` state, and
/// SwiftUI registers the dependency it actually touched.
///
/// Isolation mirrors the view model's: the type is nonisolated and `@MainActor`
/// sits on exactly the members that carried it before the move (the AI/search
/// surface and the live-subtitle notice seam), so no call site changes actor.
@Observable
final class TrackSelectionCoordinator {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Player"
    )

    // MARK: - Published track state (the five members the views read)

    var audioTracks: [PlayerTrack] = []
    var subtitleTracks: [PlayerTrack] = []
    var selectedAudioId: Int64?
    var selectedSubtitleId: Int64?
    var selectedSecondarySubtitleId: Int64?

    /// Server-resolved preferred subtitle language for the current item,
    /// snapshotted at prepare time. Used only to float the matching
    /// language group to the top of the displayed track lists.
    private var subtitleOrderingLanguage: String?

    // MARK: - Pending restore intents

    /// Cached external subtitle URLs returned by the server; added to the
    /// player once the file has loaded.
    private(set) var pendingExternalSubtitles: [SubtitleUrl] = []
    /// Full sidecar subtitle set for the current item. Unlike
    /// `pendingExternalSubtitles`, this survives the first successful
    /// registration so route recovery can re-register sidecars later.
    private(set) var knownExternalSubtitles: [SubtitleUrl] = []

    struct TrackSelectionSnapshot {
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

    /// Server-supplied preferred track indices (ffmpeg stream indices). Kept
    /// until we've observed a matching track in the core's track-list and
    /// applied it, or until the user makes a manual selection.
    private(set) var pendingAudioFfIndex: Int?
    private var pendingSubtitleFfIndex: Int?
    /// True when the most recent `loadAndPlay` came in with an explicit
    /// subtitle index from the caller (route arg / detail screen). The
    /// auto-resolver yields to the user in that case.
    private(set) var hasExplicitSubtitleChoice: Bool = false
    /// External subtitle picks don't have an FFmpeg stream index, so a
    /// reload/resume has to remember the synthesised sidecar `trackId`
    /// and re-apply it once `subtitle_urls` have been registered again.
    private var pendingSidecarSubtitleTrackId: Int64?
    /// A protocol-v3 subtitle can remain represented by a sidecar picker row
    /// even when the replacement plan renders it on the server (for example,
    /// bitmap PGS subtitles burned into HLS). Preserve that picker selection
    /// across the backend rebuild without also opening the sidecar locally.
    private var pendingServerRenderedSubtitleTrackId: Int64?
    /// M5 seamless live→persisted swap: the synthetic AI-live track id whose
    /// row + libass track must be closed AFTER the handed-off persisted track is
    /// selected. Set by `armDeferredLiveSubtitleClose` when a live job completes;
    /// consumed in `appendSidecarTracks` immediately after the persisted
    /// selection is applied, so there is never a frame with no subtitle between
    /// dropping the live row and the persisted track landing.
    private var pendingLiveSubtitleCloseTrackId: Int64?
    /// Bounded fallback timer that closes a deferred live track if the persisted
    /// selection never lands. Cancelled when the seamless close fires or on
    /// cleanup. Stored in the view model's task registry (see the port) so the
    /// teardown sweep keeps owning its lifetime.
    private var deferredLiveSubtitleCloseTask: Task<Void, Never>? {
        get { ports.deferredLiveSubtitleCloseTask() }
        set { ports.setDeferredLiveSubtitleCloseTask(newValue) }
    }
    /// Snapshot of the server-cascaded subtitle prefs for the currently
    /// loaded content. Captured from `WatchDetail.effective_*` at
    /// session-start time and consumed once the player reports its
    /// track list. Cleared on cleanup so a follow-up load doesn't apply
    /// stale prefs to a different file.
    private var prefsForCurrentItem: PrefsSnapshot?
    struct PrefsSnapshot {
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
    /// Id of the live-subtitle "Preparing subtitles" notice while it's on
    /// screen, so `dismissLiveSubtitlePreparingNotice()` can clear it the moment
    /// playback resumes without clobbering a newer, unrelated notice.
    private var liveSubtitlePreparingNoticeId: UUID?

    private let settings = PlayerSettings.shared
    fileprivate let ports: TrackSelectionPorts
    private var context: TrackSelectionContext { ports.context() }

    init(ports: TrackSelectionPorts) {
        self.ports = ports
    }

    /// Owns the in-player AI subtitle suite (translate / transcribe over
    /// polling). Constructed with closures into the session context + the
    /// sidecar-registration handoff, and `reset()` on teardown.
    /// `@ObservationIgnored` because the UI binds to the controller's own
    /// `@Observable` state, not through this coordinator.
    ///
    /// Lazy so the `@MainActor`-isolated controller is constructed on first
    /// access rather than in `init`, which keeps the coordinator constructible
    /// from the view model's own lazy initializer.
    @ObservationIgnored
    private(set) lazy var subtitleAI: SubtitleAIController = MainActor.assumeIsolated {
        SubtitleAIController(
            mediaFileId: { [weak self] in self?.context.currentSelectedVersion?.fileId },
            currentTime: { [weak self] in self?.context.currentTime ?? 0 },
            sessionId: { [weak self] in self?.context.serverSessionId },
            realtimeUnavailable: { [weak self] in !(self?.ports.subtitleAILiveOverlayAvailable() ?? false) },
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

    /// Build the live-subtitle coordinator with adapters bound to this
    /// coordinator. The adapters touch the playback + live-track + notice
    /// surface, so they live in this file. Called only from the `subtitleAI`
    /// lazy initializer. It only wires immutable closures.
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

    // MARK: - Display projections

    var orderedSubtitleTracks: [PlayerTrack] {
        orderedSubtitles(subtitleTracks)
    }

    /// Reads the narrow capability port rather than the whole context: this is
    /// a display member, so its reads are the enclosing SwiftUI body's
    /// invalidation set (see `TrackSelectionPorts`).
    var availableSecondarySubtitleTracks: [PlayerTrack] {
        guard ports.backendCapabilities().supportsSecondarySubtitles else { return [] }
        guard ports.backend() != nil else { return [] }
        return orderedSubtitles(subtitleTracks.filter { SubtitleTrackIdSpace.isSidecar($0.trackId) })
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

    // MARK: - Track selection
    //
    // Primary audio/subtitle selection routes through AVFoundation media
    // selection groups; secondary subtitles are sidecar-only.

    func selectAudio(_ track: PlayerTrack) {
        guard !context.isBackgroundSuspended else { return }
        pendingAudioFfIndex = nil
        selectedAudioId = track.trackId
        persistAudioSelection(track)
        reapplySystemSubtitlePolicy()
        if context.activePreparedProtocolV3 != nil {
            // Record only — the server owns the switch on this path, so the
            // track must not be applied locally before its plan arrives.
            recordAudioTrackSelectionBreadcrumb(
                track.trackId,
                reason: "user_selection",
                viaServerReplan: true
            )
            ports.requestReplan(
                "audio_track_changed",
                "User selected audio track \(track.title ?? String(track.trackId)).",
                nil
            )
            ports.scheduleHideControls()
            return
        }
        applyAudioTrackSelection(track.trackId, reason: "user_selection")
        ports.scheduleHideControls()
    }

    func selectSubtitle(_ track: PlayerTrack) {
        guard !context.isBackgroundSuspended else { return }
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
        persistSubtitleSelection(track)
        if context.activePreparedProtocolV3 != nil,
           !SubtitleTrackIdSpace.isAILive(track.trackId) {
            // Record only; the replan below is what actually switches the track.
            recordSubtitleTrackSelectionBreadcrumb(
                track.trackId,
                reason: "user_selection",
                viaServerReplan: true
            )
            ports.requestReplan(
                "subtitle_track_changed",
                "User selected subtitle track \(track.title ?? String(track.trackId)).",
                nil
            )
            ports.scheduleHideControls()
            return
        }
        applySubtitleTrackSelection(track.trackId, reason: "user_selection")
        ports.scheduleHideControls()
    }

    func disableSubtitles() {
        guard !context.isBackgroundSuspended else { return }
        hasExplicitSubtitleChoice = true
        pendingSubtitleFfIndex = nil
        if selectedSecondarySubtitleId != nil {
            selectedSecondarySubtitleId = nil
            applySecondarySubtitleTrackSelection(nil)
        }
        selectedSubtitleId = nil
        Self.logger.info("[CMP-SUB] disable primary subtitles")
        persistSubtitleSelection(nil)
        if context.activePreparedProtocolV3 != nil {
            // Record only; the replan below is what actually clears the track.
            recordSubtitleTrackSelectionBreadcrumb(
                nil,
                reason: "user_selection",
                viaServerReplan: true
            )
            ports.requestReplan(
                "subtitle_track_changed",
                "User disabled subtitles.",
                nil
            )
            ports.scheduleHideControls()
            return
        }
        applySubtitleTrackSelection(nil, reason: "user_selection")
        ports.scheduleHideControls()
    }

    /// Server pref key for remembering explicit track picks: series id
    /// for episodes (one choice covers the series), the item's own
    /// content id for movies. Nil during offline playback — there is no
    /// server to remember anything for.
    private var trackPrefPersistKey: String? {
        let context = self.context
        guard context.offlinePlaybackContext == nil, let detail = context.currentWatchDetail else { return nil }
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
        let ordinal = ApplePlaybackRoutePlanner.audioSelectionIndex(for: track)
        let request: AudioPrefRequest
        if let ordinal,
           let version = context.currentSelectedVersion,
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
        let context = self.context
        let showForced = context.currentWatchDetail?.effectiveShowForcedSubtitles
        let request: SubtitlePrefRequest
        if let track {
            if !track.isExternal,
               let ffIndex = track.ffIndex,
               let version = context.currentSelectedVersion,
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
        guard !context.isBackgroundSuspended else { return }
        guard context.backendCapabilities.supportsSecondarySubtitles else { return }
        // Secondary sub cannot equal the primary sid; guard at the UI layer
        // so the user gets an immediate no-op rather than seeing stale state.
        guard track.trackId != selectedSubtitleId else { return }
        selectedSecondarySubtitleId = track.trackId
        applySecondarySubtitleTrackSelection(track.trackId)
        ports.scheduleHideControls()
    }

    func disableSecondarySubtitles() {
        guard !context.isBackgroundSuspended else { return }
        guard context.backendCapabilities.supportsSecondarySubtitles else { return }
        selectedSecondarySubtitleId = nil
        applySecondarySubtitleTrackSelection(nil)
        ports.scheduleHideControls()
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
    ///
    /// Reads the three narrow ports rather than the whole context, and in the
    /// original order so `&&` still short-circuits: this member and the two
    /// derived from it are evaluated inside view bodies, where every property
    /// touched joins the body's invalidation set (see `TrackSelectionPorts`).
    @MainActor
    var subtitleSearchVisible: Bool {
        ports.serverSessionId() != nil
            && ports.currentSelectedVersion()?.fileId != nil
            && ports.backendCapabilities().supportsExternalPrimarySubtitles
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
        guard let fileId = context.currentSelectedVersion?.fileId else {
            throw HTTPError.invalidURL("subtitle search requires an active media file")
        }
        return try await SiloAI.shared.searchSubtitles(
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
        guard let fileId = context.currentSelectedVersion?.fileId else { return false }
        do {
            let subtitle = try await SiloAI.shared.downloadSubtitle(
                SubtitleDownloadBody(from: result, mediaFileId: fileId)
            )
            let downloaded = try await SiloAI.shared.downloadedSubtitles(mediaFileId: fileId)
            // Revalidate after the awaits: if playback moved to a different
            // file while the download was in flight, `makeSubtitleHandoffContext`
            // would now describe the NEW session, and registering the OLD
            // file's listing position against it would select a wrong or
            // invalid track. The download itself is persisted server-side
            // either way; the next session of that file picks it up.
            guard context.currentSelectedVersion?.fileId == fileId else {
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
            guard let handoff = makeSubtitleHandoffContext(),
                  let descriptor = downloaded[position].synthesizedDescriptor(
                      sessionId: handoff.sessionId,
                      baseTrackCount: handoff.baseTrackCount,
                      position: position,
                      resolveURL: handoff.resolveURL
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
        let context = self.context
        guard context.backendCapabilities.supportsExternalPrimarySubtitles else {
            Self.logger.info(
                "[AI-SUB] backend \(context.activeRouteKind.label, privacy: .public) can't host downloaded subtitles; handoff unavailable"
            )
            return nil
        }
        guard let sessionId = context.serverSessionId, !sessionId.isEmpty else {
            Self.logger.warning("[AI-SUB] no active session id for subtitle handoff")
            return nil
        }
        let serverUrl = context.resolvedServerUrl
        guard let inventory = context.activePreparedProtocolV3?.plan.subtitle.inventory else {
            Self.logger.warning("[AI-SUB] no V3 subtitle inventory for subtitle handoff")
            return nil
        }
        let baseTrackCount = PlayerViewModel.protocolV3DownloadedSubtitleBaseTrackCount(inventory)
        return SubtitleAIController.HandoffContext(
            sessionId: sessionId,
            baseTrackCount: baseTrackCount,
            resolveURL: { [weak self] path in self?.ports.resolveServerUrl(path, serverUrl) }
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
        let context = self.context
        guard context.backendCapabilities.supportsExternalPrimarySubtitles else {
            Self.logger.info(
                "[AI-SUB] backend \(context.activeRouteKind.label, privacy: .public) can't host downloaded subtitles; skipping handoff"
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
        // A nil backend is fine: the descriptor is picked up on the next file
        // load via `loadPendingExternalSubtitles`/`knownExternalSubtitles`.
        ports.backend()?.registerSidecarSubtitles([descriptor])
    }

    // MARK: - Live AI subtitle bridge (M4)
    //
    // Thin accessors the `LiveSubtitleCoordinator` adapters call. They exist
    // because the adapters are distinct fileprivate types and so can't reach
    // this coordinator's `private` playback/notice state directly. Each is a
    // one-liner over an existing primitive; the interesting logic (offset-aware
    // cue conversion, dedupe) lives in the sink adapter.

    /// Open the synthetic live track on the active backend and add its picker
    /// row. Returns the live track id.
    @discardableResult
    fileprivate func installLiveSubtitleTrackRow(ordinal: Int, label: String?, language: String?) -> Int64 {
        openLiveSubtitleTrack(slot: .primary, label: label, language: language)
        return appendLiveSubtitleTrack(ordinal: ordinal, label: label, language: language)
    }

    /// Select the live track (no-op selection of an already-installed track is
    /// handled in the backends).
    fileprivate func selectLiveSubtitleTrack(trackId: Int64) {
        if let track = subtitleTracks.first(where: { $0.trackId == trackId }) {
            selectSubtitle(track)
        }
    }

    /// Close the live track and remove its picker row. If it was selected,
    /// `restoreLiveSubtitleSelection` is expected to follow (the coordinator
    /// drives that separately).
    fileprivate func closeLiveSubtitleTrackRow(trackId: Int64) {
        removeLiveSubtitleTrackRow(trackId: trackId)
        closeLiveSubtitleTrack(slot: .primary)
    }

    /// Remove only the picker row for a stale synthetic live track. Used when a
    /// newer live renderer already owns the single primary libass slot.
    private func removeLiveSubtitleTrackRow(trackId: Int64) {
        subtitleTracks.removeAll { $0.trackId == trackId }
    }

    /// M5 seamless swap: arm the live track `trackId` to be closed AFTER the
    /// handed-off persisted track is selected (in `appendSidecarTracks`), rather
    /// than synchronously. A bounded fallback timer guarantees the row is never
    /// stranded if the persisted selection never lands (e.g. the handoff listing
    /// fetch failed after the server reported completion): the live track is
    /// closed anyway once the window elapses.
    fileprivate func armDeferredLiveSubtitleClose(trackId: Int64) {
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
    fileprivate func restoreLiveSubtitleSelection(_ trackId: Int64?) {
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
    fileprivate func showLiveSubtitlePreparingNotice() {
        ports.showNotice(
            "Preparing subtitles",
            "Generating subtitles for the current scene — playback resumes in a moment.",
            .info,
            30
        )
        // Remember which notice is the preparing one so we can retract it the
        // instant playback resumes — otherwise the 30s safety duration leaves
        // "playback resumes in a moment" on screen long after it already has,
        // which reads as a stuck/broken pause.
        liveSubtitlePreparingNoticeId = ports.activeNotice()?.id
    }

    /// Clear the live-subtitle "Preparing subtitles" notice once playback has
    /// resumed (first cues) or the job finished. No-ops if it has already been
    /// replaced by a newer notice, so an unrelated message is never clobbered.
    @MainActor
    fileprivate func dismissLiveSubtitlePreparingNotice() {
        guard let id = liveSubtitlePreparingNoticeId else { return }
        liveSubtitlePreparingNoticeId = nil
        guard ports.activeNotice()?.id == id else { return }
        ports.dismissNotice()
    }

    /// Soft failure notice for the live subtitle path.
    @MainActor
    fileprivate func showLiveSubtitleFailureNotice(_ message: String) {
        ports.showNotice(
            "Subtitles unavailable",
            message,
            .warning,
            5
        )
    }

    // MARK: - Keyboard cycling (macOS)

    func cycleAudioTrack() {
        guard !context.isBackgroundSuspended, !audioTracks.isEmpty else { return }
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
        guard !context.isBackgroundSuspended, !subtitleTracks.isEmpty else { return }

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
        guard !context.isBackgroundSuspended else { return }
        if selectedSubtitleId != nil {
            disableSubtitles()
        } else if let first = subtitleTracks.first {
            selectSubtitle(first)
        }
    }

    // MARK: - Sidecar registration

    func loadPendingExternalSubtitles() {
        let context = self.context
        let restoredFromKnownCache = pendingExternalSubtitles.isEmpty
        let allPending = restoredFromKnownCache
            ? knownExternalSubtitles
            : pendingExternalSubtitles
        let pending = subtitleUrlsForCurrentRoute(allPending)
        pendingExternalSubtitles = []
        if pending.isEmpty {
            Self.logger.info(
                "[CMP-SUB] no external subtitles to register route=\(context.activeRouteKind.label, privacy: .public) currentTracks=\(self.subtitleTracks.count, privacy: .public)"
            )
        }

        Self.logger.info(
            "[CMP-SUB] resolving external subtitles count=\(pending.count, privacy: .public) route=\(context.activeRouteKind.label, privacy: .public) supportsExternal=\(context.backendCapabilities.supportsExternalPrimarySubtitles, privacy: .public) fromKnownCache=\(restoredFromKnownCache, privacy: .public)"
        )

        var descriptors: [SidecarSubtitleDescriptor] = []
        descriptors.reserveCapacity(pending.count)
        for sub in pending {
            guard let url = ports.resolveServerUrl(sub.url, context.resolvedServerUrl) else {
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
                    ports.resolveServerUrl($0, context.resolvedServerUrl)
                },
                url: url
            ))
        }
        if !pending.isEmpty, descriptors.isEmpty {
            Self.logger.warning("[CMP-SUB] no external subtitle descriptors survived URL resolution")
        }
        if context.backendCapabilities.supportsExternalPrimarySubtitles {
            Self.logger.info(
                "[CMP-SUB] registering sidecar subtitles descriptors=\(descriptors.count, privacy: .public) route=\(context.activeRouteKind.label, privacy: .public)"
            )
            ports.backend()?.registerSidecarSubtitles(descriptors)
        } else {
            Self.logger.info(
                "[CMP-ROUTE] skipping sidecar subtitle registration on backend=\(context.activeRouteKind.label, privacy: .public)"
            )
        }
    }

    private func subtitleUrlsForCurrentRoute(_ urls: [SubtitleUrl]) -> [SubtitleUrl] {
        let context = self.context
        let filtered = PlayerViewModel.protocolV3SubtitleUrlsForCurrentRoute(
            urls,
            routeUsesEmbeddedExtraction: activeRouteUsesEmbeddedAVPlayerSubtitleExtraction,
            selectedSubtitleIndex: context.activePreparedProtocolV3?.plan.selectedTracks.subtitle?.index,
            subtitleMode: context.activePreparedProtocolV3?.plan.subtitle.mode
        )
        if filtered.count != urls.count {
            Self.logger.info(
                "[CMP-SUB] skipped embedded sidecar subtitle urls count=\(urls.count - filtered.count, privacy: .public) route=\(context.activeRouteKind.label, privacy: .public)"
            )
        }
        return filtered
    }

    private var activeRouteUsesEmbeddedAVPlayerSubtitleExtraction: Bool {
        switch context.activeRouteKind {
        case .avPlayerNativeDirect, .siloPlayerLoopback:
            return true
        case .avPlayerHLS:
            return false
        }
    }

    // MARK: - Apply funnels

    /// Every audio-track change — user pick, resume of a persisted or
    /// detail-screen choice, post-route-switch restore — reaches the backend
    /// through here, so `reason` is required rather than defaulted: a report
    /// that cannot tell "the user chose this" from "we restored this" cannot
    /// answer the question these breadcrumbs exist for.
    private func applyAudioTrackSelection(_ trackId: Int64, reason: String) {
        recordAudioTrackSelectionBreadcrumb(trackId, reason: reason, viaServerReplan: false)
        ports.backend()?.selectAudioTrack(trackId)
    }

    /// Same contract as `applyAudioTrackSelection`: the one funnel every
    /// primary-subtitle change passes through, with an explicit `reason`.
    /// `nil` means subtitles off.
    private func applySubtitleTrackSelection(_ trackId: Int64?, reason: String) {
        let routeLabel = context.activeRouteKind.label
        Self.logger.info(
            "[CMP-SUB] apply primary selection trackId=\(trackId.map(String.init) ?? "nil", privacy: .public) route=\(routeLabel, privacy: .public)"
        )
        recordSubtitleTrackSelectionBreadcrumb(trackId, reason: reason, viaServerReplan: false)
        ports.backend()?.selectSubtitleTrack(trackId)
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
                        .flatMap { ApplePlaybackRoutePlanner.audioSelectionIndex(for: $0) }
                        .map { "audio_ordinal_\($0)" } ?? "audio_ordinal_unknown"
                ),
                "play_method": .string(context.activeRouteKind.label),
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
                "play_method": .string(context.activeRouteKind.label),
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
        ports.backend()?.setSecondarySubtitleTrack(trackId)
    }

    // MARK: - Live AI subtitle track seam

    /// Open a synthetic live AI subtitle track in the given slot on the
    /// active backend. Cues are then streamed in via `feedLiveSubtitleCue`.
    /// Route-agnostic so a backend switch keeps working.
    private func openLiveSubtitleTrack(slot: SubtitleSlot = .primary, label: String?, language: String?) {
        ports.backend()?.openLiveSubtitleTrack(slot: slot, label: label, language: language)
    }

    /// Feed a single converted live AI cue (from `LiveSubtitleTrack`) to
    /// the live track in the given slot on the active backend.
    fileprivate func feedLiveSubtitleCue(
        slot: SubtitleSlot = .primary,
        eventText: String,
        startMs: Int64,
        durationMs: Int64
    ) {
        ports.backend()?.feedLiveSubtitleCue(slot: slot, eventText: eventText, startMs: startMs, durationMs: durationMs)
    }

    /// Close the live AI subtitle track in the given slot on the active
    /// backend.
    private func closeLiveSubtitleTrack(slot: SubtitleSlot = .primary) {
        ports.backend()?.closeLiveSubtitleTrack(slot: slot)
    }

    /// Append a synthetic live AI subtitle row to `subtitleTracks` so the
    /// picker can select it, and return its track id. De-dupes by id.
    @discardableResult
    private func appendLiveSubtitleTrack(ordinal: Int, label: String?, language: String?) -> Int64 {
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

    /// Append sidecar tracks to `subtitleTracks` as synthesised
    /// `PlayerTrack` rows so the picker shows every available caption
    /// track alongside embedded ones. Called on main by the session.
    func appendSidecarTracks(_ descriptors: [SidecarSubtitleDescriptor]) {
        Self.logger.info(
            "[CMP-SUB] append sidecar tracks descriptors=\(descriptors.count, privacy: .public) existingTracks=\(self.subtitleTracks.count, privacy: .public)"
        )
        // Remove any previously appended sidecars before re-appending —
        // `loadPendingExternalSubtitles` fires once per file load, so
        // de-duplication here prevents drift on retry paths.
        var existingEmbedded = subtitleTracks.filter { track in
            !SubtitleTrackIdSpace.isSidecar(track.trackId)
        }
        if let version = context.currentSelectedVersion {
            let shadowedEmbeddedFFmpegIndices: Set<Int> = Set(descriptors.compactMap { descriptor in
                guard descriptor.source?.caseInsensitiveCompare("embedded") == .orderedSame else {
                    return nil
                }
                return ApplePlaybackV3PlanAdapter.ffmpegSubtitleStreamIndex(
                    serverCombinedIndex: descriptor.index,
                    in: version
                )
            })
            existingEmbedded.removeAll { track in
                track.ffIndex.map { shadowedEmbeddedFFmpegIndices.contains($0) } == true
            }
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
                isDefault: d.isDefault ?? false,
                isForced: d.forced ?? false,
                isHearingImpaired: d.isHearingImpaired ?? false,
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
                    applySubtitleTrackSelection(pendingTrackId, reason: "restored_sidecar_selection")
                }
                // M5 seamless swap: the persisted AI track is now selected; it's
                // safe to drop the synthetic live row + libass track with no
                // no-subtitle flicker. (No-op unless a deferred close is armed.)
                performDeferredLiveSubtitleCloseIfNeeded()
            }
        }
        if let pendingTrackId = pendingServerRenderedSubtitleTrackId {
            pendingServerRenderedSubtitleTrackId = nil
            if subtitleTracks.contains(where: { $0.trackId == pendingTrackId }) {
                restoredPrimarySidecar = true
                selectedSubtitleId = pendingTrackId
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

        if restoredPrimarySidecar,
           !settings.subtitleMatchesSystemAppearance || hasExplicitSubtitleChoice {
            return
        }

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
                applySubtitleTrackSelection(match.trackId, reason: "restored_selection_as_sidecar")
            }
            if !settings.subtitleMatchesSystemAppearance || hasExplicitSubtitleChoice {
                return
            }
        }

        // If a forced sidecar is present, auto-select it when the protocol plan
        // has not already made an explicit choice. Forced tracks (for
        // non-native dialogue or song lyrics in anime) otherwise display
        // regardless of the Silo subtitle preference. Device settings mode
        // routes every sidecar through Apple's ordered language policy,
        // including Forced Only.
        if !settings.subtitleMatchesSystemAppearance,
           !hasExplicitSubtitleChoice,
           selectedSubtitleId == nil,
           let forced = descriptors.first(where: { $0.forced == true }) {
            let trackId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: forced.index)
            selectedSubtitleId = trackId
            applySubtitleTrackSelection(trackId, reason: "forced_sidecar_auto")
            return
        }

        applyAutoSubtitlePreferencesIfNeeded(
            forceReevaluation: settings.subtitleMatchesSystemAppearance || selectedSubtitleId == nil
        )
    }

    /// Called on every `track-list` change. Updates the published track lists,
    /// tracks the current live player selection, and applies any pending
    /// server-preferred indices once a matching track appears. Preserves previously-appended
    /// sidecar entries — the backend's track list only enumerates
    /// embedded streams, and the sidecar tracks from
    /// `onSidecarTracksRegistered` are layered in separately.
    func applyTrackList(_ tracks: [PlayerTrack]) {
        audioTracks = tracks.filter { $0.kind == .audio }
        let shadowedEmbeddedFFmpegIndices: Set<Int> = {
            guard let version = context.currentSelectedVersion else { return [] }
            return Set(subtitleTracks.compactMap { track in
                guard SubtitleTrackIdSpace.isSidecar(track.trackId),
                      let combinedIndex = track.srcId else {
                    return nil
                }
                return ApplePlaybackV3PlanAdapter.ffmpegSubtitleStreamIndex(
                    serverCombinedIndex: combinedIndex,
                    in: version
                )
            })
        }()
        let embeddedSubs = tracks.filter { track in
            guard track.kind == .sub else { return false }
            guard let ffIndex = track.ffIndex else { return true }
            return !shadowedEmbeddedFFmpegIndices.contains(ffIndex)
        }
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
           let match = audioTracks.first(where: { ApplePlaybackRoutePlanner.audioSelectionIndex(for: $0) == wantedFf }) {
            pendingAudioFfIndex = nil
            if selectedAudioId != match.trackId {
                selectedAudioId = match.trackId
                applyAudioTrackSelection(match.trackId, reason: "pending_audio_index")
            }
        }

        if let wantedFf = pendingSubtitleFfIndex {
            if wantedFf < 0 {
                // Explicit "Off" from the detail screen — disable subs so
                // a file-default or forced track doesn't surprise the user.
                pendingSubtitleFfIndex = nil
                if selectedSubtitleId != nil {
                    selectedSubtitleId = nil
                    applySubtitleTrackSelection(nil, reason: "pending_subtitle_off")
                }
            } else if let match = embeddedSubs.first(where: { $0.ffIndex == wantedFf }) {
                pendingSubtitleFfIndex = nil
                if selectedSubtitleId != match.trackId {
                    selectedSubtitleId = match.trackId
                    applySubtitleTrackSelection(match.trackId, reason: "pending_subtitle_index")
                }
            }
        }

        if let snapshot = pendingRecoveredAudioSelection,
           let match = bestTrackMatch(for: snapshot, in: audioTracks) {
            pendingRecoveredAudioSelection = nil
            if selectedAudioId != match.trackId {
                selectedAudioId = match.trackId
                applyAudioTrackSelection(match.trackId, reason: "restored_selection")
            }
        }

        if let snapshot = pendingRecoveredSubtitleSelection,
           let match = bestTrackMatch(for: snapshot, in: embeddedSubs) {
            pendingRecoveredSubtitleSelection = nil
            if selectedSubtitleId != match.trackId {
                selectedSubtitleId = match.trackId
                applySubtitleTrackSelection(match.trackId, reason: "restored_selection")
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

    private func reapplySystemSubtitlePolicy() {
        guard settings.subtitleMatchesSystemAppearance, !hasExplicitSubtitleChoice else { return }
        subtitleOrderingLanguage = settings.subtitleSystemSelectionPreferences
            .preferredLanguages.first
        prefsForCurrentItem = systemCaptionPrefsSnapshot()
        prefsResolvedForCurrentItem = false
        applyAutoSubtitlePreferencesIfNeeded(forceReevaluation: true)
    }

    func systemCaptionPrefsSnapshot() -> PrefsSnapshot {
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
        let context = self.context
        guard let activePreparedProtocolV3 = context.activePreparedProtocolV3,
              let version = context.currentSelectedVersion,
              !ports.isReplanInFlight(),
              context.currentWatchDetail != nil else {
            return false
        }
        let combinedIndex = track.flatMap {
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(for: $0, in: version)
        }
        guard combinedIndex != activePreparedProtocolV3.plan.selectedTracks.subtitle?.index else {
            return false
        }

        selectedSubtitleId = track?.trackId
        ports.setLastLoadRequestProtocolV3SubtitleIndex(combinedIndex)
        ports.requestReplan(
            "subtitle_track_changed",
            "Automatic caption policy selected a different subtitle track.",
            combinedIndex
        )
        return true
    }

    // MARK: - Appearance coupling

    /// The selection half of `PlayerViewModel.setSubtitleMatchesSystemAppearance`:
    /// switching between device-settings and server-policy subtitle selection
    /// drops any latched manual choice and re-resolves from the new source.
    func setMatchesSystemAppearance(_ enabled: Bool) {
        subtitleOrderingLanguage = enabled
            ? settings.subtitleSystemSelectionPreferences.preferredLanguages.first
            : context.currentWatchDetail?.effectiveSubtitleLanguage
        hasExplicitSubtitleChoice = false
        prefsForCurrentItem = enabled
            ? systemCaptionPrefsSnapshot()
            : context.currentWatchDetail.map(serverSubtitlePrefsSnapshot)
        prefsResolvedForCurrentItem = false
        applyAutoSubtitlePreferencesIfNeeded(forceReevaluation: true)
    }

    /// The selection half of the system-caption-settings observer. The
    /// appearance half (refresh + push to the player) stays in the view model;
    /// the `subtitleMatchesSystemAppearance` gate is checked by the observer
    /// before this is called.
    func applySystemCaptionSettingsChange() {
        subtitleOrderingLanguage = settings
            .subtitleSystemSelectionPreferences.preferredLanguages.first
        guard !hasExplicitSubtitleChoice else { return }
        prefsForCurrentItem = systemCaptionPrefsSnapshot()
        prefsResolvedForCurrentItem = false
        applyAutoSubtitlePreferencesIfNeeded(forceReevaluation: true)
    }

    // MARK: - Resume / renewal intent

    func resolvedAudioTrackIndexForResume() -> Int? {
        guard let selectedAudioId,
              let selected = audioTracks.first(where: { $0.trackId == selectedAudioId }),
              let selectionIndex = ApplePlaybackRoutePlanner.audioSelectionIndex(for: selected) else {
            return ports.lastLoadRequest()?.preferredAudioTrackIndex
        }
        return selectionIndex
    }

    func resolvedSubtitleTrackIndexForResume() -> Int? {
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
        if !subtitleTracks.isEmpty || ports.lastLoadRequest()?.preferredSubtitleTrackIndex == -1 {
            return -1
        }
        return ports.lastLoadRequest()?.preferredSubtitleTrackIndex
    }

    func resolvedProtocolV3SubtitleIndexForResume() -> Int? {
        guard let selectedSubtitleId,
              !SubtitleTrackIdSpace.isAILive(selectedSubtitleId),
              let selected = subtitleTracks.first(where: { $0.trackId == selectedSubtitleId }),
              let version = context.currentSelectedVersion else {
            return nil
        }
        return ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
            for: selected,
            in: version
        )
    }

    func resolvedSidecarSubtitleTrackIdForResume() -> Int64? {
        if let selectedSubtitleId, SubtitleTrackIdSpace.isSidecar(selectedSubtitleId) {
            return selectedSubtitleId
        }
        return ports.lastLoadRequest()?.preferredSidecarSubtitleTrackId
    }

    /// The track half of `adoptProtocolV3RenewalIntent`: arm the plan's
    /// authoritative selection and, when the choice is a latched manual one,
    /// stop the auto-resolver from revisiting it.
    func adoptProtocolV3RenewalIntent(plan: PlaybackV3Plan, request: LoadRequest) {
        armAdoptedProtocolV3TrackIntent(plan: plan, request: request)

        // Adopting an authoritative server plan does not convert an automatic
        // system/server policy into a user choice. Manual choices stay latched;
        // automatic choices remain eligible for later policy changes.
        if hasExplicitSubtitleChoice {
            prefsForCurrentItem = nil
            prefsResolvedForCurrentItem = true
        }
    }

    func rearmAdoptedProtocolV3TrackIntent() {
        guard let plan = context.activePreparedProtocolV3?.plan,
              let request = ports.lastLoadRequest() else { return }
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
        let intent = PlayerViewModel.protocolV3PendingTrackIntent(plan: plan, request: request)
        pendingAudioFfIndex = intent.audioIndex
        pendingSubtitleFfIndex = intent.embeddedSubtitleIndex
        pendingSidecarSubtitleTrackId = intent.sidecarSubtitleTrackId
    }

    /// Re-establish the subtitle selection the caller snapshotted before the
    /// server replaced the plan. Sidecar ids are stable (urlIndex-derived) and
    /// restore by id; a server-rendered choice is latched separately so the
    /// track list doesn't fight the server. An AI-live selection is
    /// intentionally dropped: its cues can't be replayed.
    private func applySidecarRestoreIntent(
        snapshot: Int64?,
        prepared: PreparedPlayback
    ) {
        switch PlayerViewModel.protocolV3SidecarRestoreIntent(
            snapshot: snapshot,
            selectedSubtitleIndex: prepared.protocolV3?.plan.selectedTracks.subtitle?.index,
            subtitleMode: prepared.protocolV3?.plan.subtitle.mode
        ) {
        case .renderLocally(let trackId):
            pendingSidecarSubtitleTrackId = trackId
            pendingServerRenderedSubtitleTrackId = nil
        case .serverRendered(let trackId):
            pendingSidecarSubtitleTrackId = nil
            pendingServerRenderedSubtitleTrackId = trackId
        case nil:
            // `armAdoptedProtocolV3TrackIntent` already carries the
            // replacement plan's authoritative local selection.
            pendingServerRenderedSubtitleTrackId = nil
        }
    }

    // MARK: - Load lifecycle

    /// The subtitle-policy half of a fresh-load adoption: snapshot the
    /// preferred language for track-list ordering unconditionally (even with an
    /// explicit choice) so the displayed groups float the user's language to
    /// the top, then snapshot the server-resolved subtitle policy so the
    /// track-list callback (which fires post-FFmpeg-open) can pick the right
    /// track without another fetch. The policy snapshot is skipped entirely if
    /// the caller already passed an explicit subtitle index — manual override
    /// always wins.
    func adoptFreshLoadSubtitlePolicy(watchDetail: WatchDetail) {
        subtitleOrderingLanguage = settings.subtitleMatchesSystemAppearance
            ? settings.subtitleSystemSelectionPreferences.preferredLanguages.first
            : watchDetail.effectiveSubtitleLanguage

        if !hasExplicitSubtitleChoice {
            prefsForCurrentItem = settings.subtitleMatchesSystemAppearance
                ? systemCaptionPrefsSnapshot()
                : serverSubtitlePrefsSnapshot(watchDetail)
        }
    }

    /// The sidecar-list + per-origin restore half of `adoptPreparedPlayback`,
    /// applied after the renewal intent has been armed so an explicit sidecar
    /// restore wins over the plan's own selection.
    func adopt(prepared: PreparedPlayback, origin: PlayerViewModel.PlaybackAdoptionOrigin) {
        pendingExternalSubtitles = prepared.session.subtitleUrls ?? origin.subtitleUrlFallback
        knownExternalSubtitles = pendingExternalSubtitles

        switch origin {
        case .freshLoad:
            break
        case .protocolV3Replan(let replan):
            applySidecarRestoreIntent(snapshot: replan.selectedSubtitleSnapshot, prepared: prepared)
        case .transcodeRestart(let restart):
            applySidecarRestoreIntent(snapshot: restart.selectedSubtitleSnapshot, prepared: prepared)
            // An embedded selection can't be re-established by trackId across
            // the backend rebuild (ids aren't stable), and after a switch to
            // transcode the same stream may resurface as a sidecar instead, so
            // it restores by fuzzy attribute match.
            pendingRecoveredSubtitleSelection = restart.recoveredEmbeddedSubtitleSelection
            hasExplicitSubtitleChoice = restart.hasExplicitSubtitleChoice
            pendingRecoveredSecondarySubtitleId = restart.recoveredSecondarySubtitleId
        }
    }

    /// Silent session renewal keeps the sidecar list it already has when the
    /// replacement session omits one.
    func adoptRenewedSubtitleUrls(_ urls: [SubtitleUrl]?) {
        pendingExternalSubtitles = urls ?? pendingExternalSubtitles
        knownExternalSubtitles = pendingExternalSubtitles
    }

    /// The track half of `resetPublishedLoadState`: drop the published lists
    /// and selections, drop the recovery intents, and seed the pending intents
    /// this load was asked to restore. Subtitle `-1` is the explicit "Off"
    /// sentinel; `applyTrackList` disables subs when it sees a negative value.
    func resetForLoad(
        preferredAudioTrackIndex: Int?,
        preferredSubtitleTrackIndex: Int?,
        preferredSidecarSubtitleTrackId: Int64?,
        preferredProtocolV3SubtitleIndex: Int?
    ) {
        audioTracks = []
        subtitleTracks = []
        selectedAudioId = nil
        selectedSubtitleId = nil
        selectedSecondarySubtitleId = nil
        knownExternalSubtitles = []
        pendingRecoveredAudioSelection = nil
        pendingRecoveredSubtitleSelection = nil
        pendingRecoveredSecondarySubtitleId = nil
        pendingServerRenderedSubtitleTrackId = nil
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

    /// The track half of `cleanup()`.
    @MainActor
    func reset() {
        knownExternalSubtitles = []
        subtitleAI.reset()
        pendingLiveSubtitleCloseTrackId = nil
        pendingRecoveredAudioSelection = nil
        pendingRecoveredSubtitleSelection = nil
        pendingRecoveredSecondarySubtitleId = nil
        pendingServerRenderedSubtitleTrackId = nil
    }

    // MARK: - Route-recovery snapshot

    /// Everything the offline native-direct → fallback route recovery has to
    /// carry across `resetPublishedLoadState`.
    struct RecoverySnapshot {
        let prefs: PrefsSnapshot?
        let externalSubtitles: [SubtitleUrl]
        let audioSelection: TrackSelectionSnapshot?
        let subtitleSelection: TrackSelectionSnapshot?
        let secondarySubtitleId: Int64?
        let hasExplicitSubtitleChoice: Bool
    }

    func snapshotForRecovery() -> RecoverySnapshot {
        RecoverySnapshot(
            prefs: prefsForCurrentItem,
            externalSubtitles: knownExternalSubtitles,
            audioSelection: selectedAudioId
                .flatMap { selectedId in audioTracks.first(where: { $0.trackId == selectedId }) }
                .map(TrackSelectionSnapshot.init),
            subtitleSelection: embeddedSubtitleSelectionSnapshot(),
            secondarySubtitleId: selectedSecondarySubtitleId,
            hasExplicitSubtitleChoice: hasExplicitSubtitleChoice
        )
    }

    func restoreAfterRecovery(_ snapshot: RecoverySnapshot) {
        prefsForCurrentItem = snapshot.prefs
        pendingExternalSubtitles = snapshot.externalSubtitles
        knownExternalSubtitles = snapshot.externalSubtitles
        pendingRecoveredAudioSelection = snapshot.audioSelection
        pendingRecoveredSubtitleSelection = snapshot.subtitleSelection
        pendingRecoveredSecondarySubtitleId = snapshot.secondarySubtitleId
        hasExplicitSubtitleChoice = snapshot.hasExplicitSubtitleChoice
    }

    /// Attribute snapshot of the current embedded subtitle selection, for fuzzy
    /// re-selection across a backend rebuild. Synthetic (sidecar / AI-live) ids
    /// must not be recovered as embedded tracks; sidecar has its own recovery
    /// path and live re-selection is M4's responsibility.
    func embeddedSubtitleSelectionSnapshot() -> TrackSelectionSnapshot? {
        selectedSubtitleId
            .flatMap { selectedId in subtitleTracks.first(where: { $0.trackId == selectedId }) }
            .flatMap { track in
                SubtitleTrackIdSpace.isSyntheticNonEmbedded(track.trackId) ? nil : TrackSelectionSnapshot(track: track)
            }
    }
}

// MARK: - Live AI subtitle coordinator adapters (M4)

/// `LivePlaybackControls` over the playback transport. The coordinator is
/// the single owner of pause/resume intent during a live job; this adapter
/// just forwards. Holds its owner weakly so a torn-down player can't be revived
/// by a late coordinator call.
@MainActor
private final class LiveSubtitlePlaybackAdapter: LivePlaybackControls {
    private weak var owner: TrackSelectionCoordinator?

    init(owner: TrackSelectionCoordinator) { self.owner = owner }

    func pause() { owner?.ports.backend()?.pause() }
    func play() { owner?.ports.backend()?.play() }
    var isPlaying: Bool { owner?.ports.context().isPlaying ?? false }
}

/// `LiveSubtitleSink` over the live-track primitives, selection plumbing,
/// completion handoff, and notice surface. Owns the per-`track_key`
/// `LiveSubtitleTrack` converters (cue dedupe + ASS escaping) and the
/// `track_key → ordinal` mapping, and applies the media-time → movie-time
/// offset before feeding libass.
@MainActor
private final class LiveSubtitleSinkAdapter: LiveSubtitleSink {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "LiveSubtitle"
    )

    private weak var owner: TrackSelectionCoordinator?

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

    init(owner: TrackSelectionCoordinator) { self.owner = owner }

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
        // Cue timestamps are absolute MEDIA time, which is also the clock
        // AVPlayer's libass renderer ticks on, so cues are fed as-is.
        let movieStart = cue.start
        let movieEnd = cue.end
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
            let playheadMs = Int64(owner.ports.context().currentTime * 1000.0)
            Self.logger.info(
                "[AI-LIVE-DIAG] feed cue start=\(cue.start, privacy: .public) startMs=\(converted.startMs, privacy: .public) durMs=\(converted.durationMs, privacy: .public) playheadMs=\(playheadMs, privacy: .public) Δms=\(converted.startMs - playheadMs, privacy: .public) textLen=\(converted.eventText.count, privacy: .public)"
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
        // Hand the live track id to the coordinator to close AFTER the persisted
        // track is selected (M5 seamless swap). Clear our own bookkeeping now:
        // from the live coordinator's perspective this track is finished, and the
        // track coordinator owns the deferred row removal + libass teardown from
        // here.
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
