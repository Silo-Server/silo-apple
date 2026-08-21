import AVFoundation
import Foundation
import XCTest
@testable import Silo

/// First coverage for the player's track half (inventory-2 §6: nothing pinned
/// `applyTrackList`, `appendSidecarTracks`, the `pending*` consumption order,
/// `bestTrackMatch`'s threshold or the forced-sidecar auto-select before this).
///
/// The coordinator is driven through `TrackSelectionPorts` with a nil backend,
/// so the assertions are on published ids plus the port calls the recorder
/// captures. The "…and does not apply locally" halves of the sidecar cases need
/// the backend double that lands with the `PlaybackBackend` package; what is
/// observable without it is asserted here.
@MainActor
final class TrackSelectionCoordinatorTests: XCTestCase {

    // MARK: - applyTrackList: pending indices

    func testApplyTrackListAppliesPendingAudioIndexAndClearsIt() {
        let recorder = PortRecorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.resetForLoad(
            preferredAudioTrackIndex: 1,
            preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: nil,
            preferredProtocolV3SubtitleIndex: nil
        )

        coordinator.applyTrackList([
            audioTrack(trackId: 10, srcId: 0),
            audioTrack(trackId: 11, srcId: 1),
        ])

        XCTAssertEqual(coordinator.selectedAudioId, 11)
        XCTAssertNil(coordinator.selection.audio.planIndex, "the pending index is consumed once it matches")

        // A second track list must not re-apply the (now consumed) intent.
        coordinator.applyTrackList([
            audioTrack(trackId: 10, srcId: 0, isSelected: true),
            audioTrack(trackId: 11, srcId: 1),
        ])
        XCTAssertEqual(coordinator.selectedAudioId, 10, "AVFoundation's reported selection wins once nothing is pending")
    }

    func testApplyTrackListPendingSubtitleOffSentinelDisablesReportedSelection() {
        let recorder = PortRecorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.resetForLoad(
            preferredAudioTrackIndex: nil,
            preferredSubtitleTrackIndex: -1,
            preferredSidecarSubtitleTrackId: nil,
            preferredProtocolV3SubtitleIndex: nil
        )

        // The player reports a selected embedded track; the explicit "Off"
        // sentinel is consumed *after* that adoption, so subtitles end up off.
        coordinator.applyTrackList([
            subtitleTrack(trackId: 20, ffIndex: 2, isSelected: true),
        ])

        XCTAssertNil(coordinator.selectedSubtitleId)
    }

    func testApplyTrackListAppliesPendingSubtitleIndexWhenItsTrackAppears() {
        let recorder = PortRecorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.resetForLoad(
            preferredAudioTrackIndex: nil,
            preferredSubtitleTrackIndex: 5,
            preferredSidecarSubtitleTrackId: nil,
            preferredProtocolV3SubtitleIndex: nil
        )

        // First list has no ffIndex 5 — the intent survives.
        coordinator.applyTrackList([subtitleTrack(trackId: 20, ffIndex: 2)])
        XCTAssertNil(coordinator.selectedSubtitleId)

        coordinator.applyTrackList([
            subtitleTrack(trackId: 20, ffIndex: 2),
            subtitleTrack(trackId: 21, ffIndex: 5),
        ])
        XCTAssertEqual(coordinator.selectedSubtitleId, 21)
    }

    // MARK: - Fuzzy recovery match (TrackSelectionSnapshot threshold)

    /// The restore needs a positive anchor. "English AC3 5.1 Director" shares
    /// nothing with "French AAC stereo Other" except three `false` booleans,
    /// which used to add up to the `>= 3` floor and silently switch the user's
    /// language; now the candidate scores nothing and the engine's own reported
    /// selection stands.
    func testFuzzyRestoreRejectsFlagOnlyAgreement() {
        let recorder = PortRecorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.restoreAfterRecovery(recoverySnapshot(audio: previousAudioTrack))

        coordinator.applyTrackList([
            audioTrack(
                trackId: 30,
                srcId: 0,
                title: "Other",
                lang: "fra",
                codec: "aac",
                layout: "stereo"
            )
        ])

        XCTAssertNil(coordinator.selectedAudioId, "no anchor, no restore")
        XCTAssertNotNil(
            coordinator.selection.audio.recovered,
            "an unmatched snapshot stays armed for the next track list"
        )
    }

    /// The language on its own is an anchor and clears the floor, so a stream
    /// that re-encodes the track (new codec, new layout, no title) still
    /// restores it.
    func testFuzzyRestoreAcceptsAMatchAnchoredOnLanguageAlone() {
        let recorder = PortRecorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.restoreAfterRecovery(recoverySnapshot(audio: previousAudioTrack))

        coordinator.applyTrackList([
            audioTrack(
                trackId: 30,
                srcId: 0,
                title: nil,
                lang: "eng",
                codec: "aac",
                layout: "stereo"
            )
        ])

        XCTAssertEqual(coordinator.selectedAudioId, 30)
        XCTAssertNil(coordinator.selection.audio.recovered, "a landed snapshot is consumed")
    }

    /// Attributes neither track reports are not agreement: two tracks that both
    /// omit the title and the layout must not restore onto each other on the
    /// strength of a shared codec.
    func testFuzzyRestoreRejectsAgreementOnAbsentMetadata() {
        let recorder = PortRecorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.restoreAfterRecovery(
            recoverySnapshot(
                audio: audioTrack(trackId: 99, srcId: 0, title: nil, lang: "eng", layout: nil)
            )
        )

        coordinator.applyTrackList([
            audioTrack(trackId: 30, srcId: 0, title: nil, lang: "fra", layout: nil)
        ])

        XCTAssertNil(coordinator.selectedAudioId)
    }

    // MARK: - appendSidecarTracks

    func testAppendSidecarTracksRestoresPendingSidecarSelection() {
        let recorder = PortRecorder()
        let coordinator = makeCoordinator(recorder)
        let sidecarId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 2)
        coordinator.resetForLoad(
            preferredAudioTrackIndex: nil,
            preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: sidecarId,
            preferredProtocolV3SubtitleIndex: nil
        )

        coordinator.appendSidecarTracks([
            descriptor(index: 1),
            descriptor(index: 2),
        ])

        XCTAssertEqual(coordinator.selectedSubtitleId, sidecarId)
        XCTAssertEqual(coordinator.subtitleTracks.map(\.trackId), [
            SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 1),
            sidecarId,
        ])
    }

    func testServerRenderedRestoreIntentSelectsThePickerRowAfterRegistration() throws {
        let recorder = PortRecorder()
        let coordinator = makeCoordinator(recorder)
        let sidecarId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 2)

        // A burn-in plan whose selected subtitle is combined index 2: the
        // sidecar row stays selected in the picker even though the server
        // renders it. (That it is *not* opened locally is the backend-double
        // half of this case.)
        let prepared = try preparedPlayback(subtitleMode: "burn_in", selectedSubtitleIndex: 2)
        coordinator.adopt(
            prepared: prepared,
            origin: .protocolV3Replan(
                PlaybackAdoptionOrigin.Replan(selectedSubtitleSnapshot: sidecarId)
            )
        )

        coordinator.appendSidecarTracks([descriptor(index: 2)])

        XCTAssertEqual(coordinator.selectedSubtitleId, sidecarId)
    }

    func testForcedSidecarIsAutoSelectedWithoutAnExplicitChoice() {
        let recorder = PortRecorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.resetForLoad(
            preferredAudioTrackIndex: nil,
            preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: nil,
            preferredProtocolV3SubtitleIndex: nil
        )
        XCTAssertNotEqual(coordinator.selection.origin, .user)

        coordinator.appendSidecarTracks([
            descriptor(index: 0),
            descriptor(index: 1, forced: true),
        ])

        XCTAssertEqual(
            coordinator.selectedSubtitleId,
            SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 1)
        )
    }

    func testForcedSidecarAutoSelectIsSuppressedByAnExplicitChoiceAndBySystemAppearanceMode() {
        // (a) explicit caller-supplied subtitle intent latches the choice.
        let explicit = makeCoordinator(PortRecorder())
        explicit.resetForLoad(
            preferredAudioTrackIndex: nil,
            preferredSubtitleTrackIndex: -1,
            preferredSidecarSubtitleTrackId: nil,
            preferredProtocolV3SubtitleIndex: nil
        )
        XCTAssertEqual(explicit.selection.origin, .user)
        explicit.appendSidecarTracks([descriptor(index: 1, forced: true)])
        XCTAssertNil(explicit.selectedSubtitleId, "an explicit choice outranks the forced sidecar")

        // (b) device-settings mode routes every sidecar through Apple's policy.
        let systemMode = makeCoordinator(PortRecorder(), matchesSystemAppearance: true)
        systemMode.resetForLoad(
            preferredAudioTrackIndex: nil,
            preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: nil,
            preferredProtocolV3SubtitleIndex: nil
        )
        systemMode.appendSidecarTracks([descriptor(index: 1, forced: true)])
        XCTAssertNil(systemMode.selectedSubtitleId, "system appearance mode skips the forced auto-select")
    }

    // MARK: - Bitmap sidecars are rows, never local opens

    /// The secondary slot has no server plan behind it — it is always opened
    /// locally — so a bitmap sidecar (the `.sup` the server publishes for every
    /// embedded PGS track) must not be offered on any route. Selecting one
    /// anyway is a no-op.
    func testBitmapSidecarIsNeverASecondarySubtitleCandidateOnAnyRoute() throws {
        let bitmapId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 1)
        for route in [
            PlaybackEngineKind.avPlayerNativeDirect,
            .siloPlayerLoopback,
            .avPlayerHLS,
        ] {
            let backend = AVPlayerBackend(player: AVPlayer())
            defer { backend.dispose() }
            let coordinator = makeCoordinator(
                PortRecorder(),
                routeKind: route,
                backend: backend
            )
            coordinator.appendSidecarTracks([
                descriptor(index: 0),
                descriptor(index: 1, codec: "hdmv_pgs_subtitle"),
            ])

            XCTAssertEqual(
                coordinator.subtitleTracks.count,
                2,
                "the row stays in the inventory on \(route.label)"
            )
            XCTAssertEqual(
                coordinator.availableSecondarySubtitleTracks.map(\.trackId),
                [SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 0)],
                "bitmap sidecar offered as a secondary candidate on \(route.label)"
            )

            let bitmapRow = try XCTUnwrap(
                coordinator.subtitleTracks.first(where: { $0.trackId == bitmapId })
            )
            coordinator.selectSecondarySubtitle(bitmapRow)
            XCTAssertNil(
                coordinator.selectedSecondarySubtitleId,
                "bitmap sidecar selected into the secondary slot on \(route.label)"
            )
        }
    }

    /// Without a live V3 plan there is no replan and no server burn-in, so the
    /// only thing a bitmap sidecar pick could do is open a `.sup` through the
    /// text sidecar path — a checked-but-blank track. The pick is refused.
    func testBitmapSidecarPrimaryPickIsRefusedWithoutAProtocolV3Plan() throws {
        let recorder = PortRecorder()
        let coordinator = makeCoordinator(recorder, routeKind: .avPlayerHLS)
        coordinator.appendSidecarTracks([descriptor(index: 1, codec: "hdmv_pgs_subtitle")])
        let row = try XCTUnwrap(coordinator.subtitleTracks.first)

        coordinator.selectSubtitle(row)

        XCTAssertNil(coordinator.selectedSubtitleId)
        XCTAssertNotEqual(coordinator.selection.origin, .user, "a refused pick decides nothing")
        XCTAssertTrue(recorder.replans.isEmpty)
    }

    /// With a plan the same row is selectable: the pick goes up as a replan and
    /// the server burns the bitmap into the stream. Nothing is opened locally.
    func testBitmapSidecarPrimaryPickReplansWhenAProtocolV3PlanIsActive() throws {
        let recorder = PortRecorder()
        let prepared = try preparedPlayback(subtitleMode: "burn_in", selectedSubtitleIndex: 1)
        let coordinator = makeCoordinator(
            recorder,
            routeKind: .avPlayerHLS,
            protocolV3: try XCTUnwrap(prepared.protocolV3)
        )
        coordinator.appendSidecarTracks([descriptor(index: 1, codec: "hdmv_pgs_subtitle")])
        let row = try XCTUnwrap(coordinator.subtitleTracks.first)

        coordinator.selectSubtitle(row)

        XCTAssertEqual(coordinator.selectedSubtitleId, row.trackId)
        XCTAssertEqual(recorder.replans.map(\.classification), ["subtitle_track_changed"])
    }

    /// A resumed sidecar intent that lands on a bitmap row is not restored —
    /// that rung opens the sidecar locally. The forced-sidecar auto-select
    /// skips bitmap rows for the same reason.
    func testBitmapSidecarIsNotRestoredOrForcedAutoSelected() {
        let bitmapId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 2)
        let restore = makeCoordinator(PortRecorder())
        restore.resetForLoad(
            preferredAudioTrackIndex: nil,
            preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: bitmapId,
            preferredProtocolV3SubtitleIndex: nil
        )
        restore.appendSidecarTracks([descriptor(index: 2, codec: "hdmv_pgs_subtitle")])
        XCTAssertNil(restore.selectedSubtitleId)

        let forced = makeCoordinator(PortRecorder())
        forced.resetForLoad(
            preferredAudioTrackIndex: nil,
            preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: nil,
            preferredProtocolV3SubtitleIndex: nil
        )
        forced.appendSidecarTracks([descriptor(index: 1, forced: true, codec: "dvd_subtitle")])
        XCTAssertNil(forced.selectedSubtitleId)
    }

    // MARK: - Suspension gate + user commands

    func testUserCommandsAreDroppedWhileBackgroundSuspended() {
        let recorder = PortRecorder()
        let coordinator = makeCoordinator(recorder, isBackgroundSuspended: true)
        coordinator.applyTrackList([
            audioTrack(trackId: 10, srcId: 0),
            subtitleTrack(trackId: 20, ffIndex: 2),
        ])

        coordinator.selectAudio(coordinator.audioTracks[0])
        coordinator.selectSubtitle(coordinator.subtitleTracks[0])
        coordinator.disableSubtitles()
        coordinator.cycleAudioTrack()
        coordinator.toggleSubtitles()

        XCTAssertNil(coordinator.selectedAudioId)
        XCTAssertNil(coordinator.selectedSubtitleId)
        XCTAssertNotEqual(coordinator.selection.origin, .user)
        XCTAssertEqual(recorder.hideControlsCount, 0)
    }

    func testUserAudioSelectionClearsThePendingIntentAndRevealsControls() {
        let recorder = PortRecorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.resetForLoad(
            preferredAudioTrackIndex: 1,
            preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: nil,
            preferredProtocolV3SubtitleIndex: nil
        )
        coordinator.applyTrackList([audioTrack(trackId: 10, srcId: 0)])
        XCTAssertEqual(coordinator.selection.audio.planIndex, 1, "no track matched, so the intent survives")

        coordinator.selectAudio(coordinator.audioTracks[0])

        XCTAssertEqual(coordinator.selectedAudioId, 10)
        XCTAssertNil(coordinator.selection.audio.planIndex, "a manual pick drops the server intent")
        XCTAssertEqual(recorder.hideControlsCount, 1)
        XCTAssertTrue(recorder.replans.isEmpty, "no V3 plan is active, so the switch is local")
    }

    // MARK: - resetForLoad

    func testResetForLoadClearsPublishedStateAndSeedsTheRequestedIntents() {
        let recorder = PortRecorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.applyTrackList([
            audioTrack(trackId: 10, srcId: 0, isSelected: true),
            subtitleTrack(trackId: 20, ffIndex: 2, isSelected: true),
        ])
        XCTAssertEqual(coordinator.selectedAudioId, 10)
        XCTAssertEqual(coordinator.selectedSubtitleId, 20)

        coordinator.resetForLoad(
            preferredAudioTrackIndex: 3,
            preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: nil,
            preferredProtocolV3SubtitleIndex: nil
        )

        XCTAssertTrue(coordinator.audioTracks.isEmpty)
        XCTAssertTrue(coordinator.subtitleTracks.isEmpty)
        XCTAssertNil(coordinator.selectedAudioId)
        XCTAssertNil(coordinator.selectedSubtitleId)
        XCTAssertNil(coordinator.selectedSecondarySubtitleId)
        XCTAssertEqual(coordinator.selection.audio.planIndex, 3)
        XCTAssertNotEqual(
            coordinator.selection.origin,
            .user,
            "an audio-only intent is not an explicit subtitle choice"
        )

        // Any of the three subtitle intents latches the explicit-choice flag.
        coordinator.resetForLoad(
            preferredAudioTrackIndex: nil,
            preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: nil,
            preferredProtocolV3SubtitleIndex: 4
        )
        XCTAssertEqual(coordinator.selection.origin, .user)
        XCTAssertNil(coordinator.selection.audio.planIndex)
    }

    // MARK: - Display members: observation scope

    /// The members a SwiftUI body evaluates must read the narrow ports, never
    /// the whole-context port.
    ///
    /// `PlayerViewModel` is `@Observable`, so a body's invalidation set is
    /// whatever the members it reads happen to touch. Building the whole
    /// context here would add `currentTime` — written ten times a second by the
    /// 0.1 s periodic time observer — to that set, and on tvOS the info HUD and
    /// its subtitle pane (which read `subtitleSearchEnabled`,
    /// `availableSecondarySubtitleTracks` and `subtitleSearchUnavailableReason`
    /// and hold the focusable track rows) would re-evaluate at that rate
    /// instead of only on real track/session changes.
    func testDisplayMembersReadOnlyTheNarrowPorts() {
        let recorder = PortRecorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.applyTrackList([subtitleTrack(trackId: 20, ffIndex: 0)])
        recorder.contextCount = 0
        recorder.narrowReadCount = 0

        _ = coordinator.subtitleSearchVisible
        _ = coordinator.subtitleSearchEnabled
        _ = coordinator.subtitleSearchUnavailableReason
        _ = coordinator.availableSecondarySubtitleTracks
        _ = coordinator.orderedSubtitleTracks

        XCTAssertEqual(
            recorder.contextCount,
            0,
            "a display member that builds the whole context makes every view body reading it depend on currentTime"
        )
        XCTAssertGreaterThan(
            recorder.narrowReadCount,
            0,
            "the display members still read the session facts they gate on"
        )
    }

    // MARK: - Doubles / builders

    /// Records the port calls the assertions read back.
    private final class PortRecorder {
        var replans: [(classification: String, message: String)] = []
        var hideControlsCount = 0
        var lastLoadRequestSubtitleIndexWrites: [Int?] = []
        /// How often the whole-context port was built. The display members must
        /// never build it (see `testDisplayMembersReadOnlyTheNarrowPorts`).
        var contextCount = 0
        var narrowReadCount = 0
    }

    private func makeCoordinator(
        _ recorder: PortRecorder,
        isBackgroundSuspended: Bool = false,
        matchesSystemAppearance: Bool = false,
        routeKind: PlaybackEngineKind = .avPlayerNativeDirect,
        protocolV3: PreparedPlaybackV3? = nil,
        backend: AVPlayerBackend? = nil
    ) -> TrackSelectionCoordinator {
        var ports = TrackSelectionPorts(
            backend: { backend },
            context: {
                recorder.contextCount += 1
                return TrackSelectionContext(
                    activePreparedProtocolV3: protocolV3,
                    currentSelectedVersion: nil,
                    currentWatchDetail: nil,
                    serverSessionId: nil,
                    resolvedServerUrl: "",
                    activeRouteKind: routeKind,
                    backendCapabilities: .avFoundation,
                    isOfflinePlayback: false,
                    currentTime: 0,
                    isBackgroundSuspended: isBackgroundSuspended,
                    isPlaying: false
                )
            },
            backendCapabilities: {
                recorder.narrowReadCount += 1
                return .avFoundation
            },
            serverSessionId: {
                recorder.narrowReadCount += 1
                return "session-1"
            },
            currentSelectedVersion: {
                recorder.narrowReadCount += 1
                return nil
            },
            requestReplan: { _, _ in },
            isReplanInFlight: { false },
            lastLoadRequest: { nil },
            setLastLoadRequestProtocolV3SubtitleIndex: { _ in },
            showNotice: { _, _, _, _ in },
            activeNotice: { nil },
            dismissNotice: {},
            scheduleHideControls: {},
            resolveServerUrl: { raw, _ in URL(string: raw) },
            subtitleAILiveOverlayAvailable: { false },
            subtitleMatchesSystemAppearance: { matchesSystemAppearance },
            systemSelectionPreferences: {
                SystemCaptionSelectionPreferences(
                    displayMode: .automatic,
                    preferredLanguages: [],
                    prefersAccessibilityTracks: false
                )
            }
        )
        ports.requestReplan = { classification, message in
            recorder.replans.append((classification, message))
        }
        ports.scheduleHideControls = { recorder.hideControlsCount += 1 }
        ports.setLastLoadRequestProtocolV3SubtitleIndex = { index in
            recorder.lastLoadRequestSubtitleIndexWrites.append(index)
        }
        return TrackSelectionCoordinator(ports: ports)
    }

    private var previousAudioTrack: PlayerTrack {
        audioTrack(trackId: 99, srcId: 0, title: "Director", lang: "eng", codec: "ac3", layout: "5.1")
    }

    private func recoverySnapshot(
        audio: PlayerTrack
    ) -> TrackSelectionCoordinator.RecoverySnapshot {
        TrackSelectionCoordinator.RecoverySnapshot(
            prefs: nil,
            externalSubtitles: [],
            audioSelection: TrackSelectionSnapshot(track: audio),
            subtitleSelection: nil,
            secondarySubtitleId: nil,
            origin: .automatic
        )
    }

    private func audioTrack(
        trackId: Int64,
        srcId: Int?,
        title: String? = "Director",
        lang: String? = "eng",
        codec: String? = "ac3",
        layout: String? = "5.1",
        isForced: Bool = false,
        isSelected: Bool = false
    ) -> PlayerTrack {
        PlayerTrack(
            trackId: trackId,
            kind: .audio,
            title: title,
            lang: lang,
            codec: codec,
            audioChannelsLayout: layout,
            audioChannelCount: nil,
            bitrate: nil,
            isDefault: false,
            isForced: isForced,
            isHearingImpaired: false,
            isVisualImpaired: false,
            isExternal: false,
            isSelected: isSelected,
            ffIndex: nil,
            srcId: srcId
        )
    }

    private func subtitleTrack(
        trackId: Int64,
        ffIndex: Int?,
        isSelected: Bool = false
    ) -> PlayerTrack {
        PlayerTrack(
            trackId: trackId,
            kind: .sub,
            title: "Sub \(trackId)",
            lang: "eng",
            codec: "subrip",
            audioChannelsLayout: nil,
            audioChannelCount: nil,
            bitrate: nil,
            isDefault: false,
            isForced: false,
            isHearingImpaired: false,
            isVisualImpaired: false,
            isExternal: false,
            isSelected: isSelected,
            ffIndex: ffIndex,
            srcId: nil
        )
    }

    private func descriptor(
        index: Int,
        forced: Bool = false,
        codec: String = "srt"
    ) -> SidecarSubtitleDescriptor {
        SidecarSubtitleDescriptor(
            index: index,
            language: "eng",
            codec: codec,
            label: "Sidecar \(index)",
            source: "external",
            forced: forced,
            isDefault: false,
            isHearingImpaired: false,
            fontBundleUrl: nil,
            url: URL(string: "https://example.test/subs/\(index).vtt")!
        )
    }

    /// A prepared playback whose V3 plan carries the requested subtitle mode
    /// and selected combined index. Built from the vendored decision fixture so
    /// the plan stays a real wire object.
    private func preparedPlayback(
        subtitleMode: String,
        selectedSubtitleIndex: Int
    ) throws -> PreparedPlayback {
        let url = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "decision_response",
            bundleClass: Self.self
        )
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var plan = try XCTUnwrap(root["playback_plan"] as? [String: Any])
        var selectedTracks = try XCTUnwrap(plan["selected_tracks"] as? [String: Any])
        selectedTracks["subtitle"] = ["id": "file:42:subtitle:\(selectedSubtitleIndex)",
                                      "index": selectedSubtitleIndex]
        plan["selected_tracks"] = selectedTracks
        var subtitle = try XCTUnwrap(plan["subtitle"] as? [String: Any])
        subtitle["mode"] = subtitleMode
        plan["subtitle"] = subtitle
        root["playback_plan"] = plan

        let decoded = try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3DecisionResponse.self,
            from: JSONSerialization.data(withJSONObject: root)
        )
        let v3Plan = try XCTUnwrap(decoded.playbackPlan)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let version = try decoder.decode(
            FileVersion.self,
            from: Data(#"{"file_id": 42, "path": "/media/movie.mkv"}"#.utf8)
        )
        let watchDetail = try decoder.decode(
            WatchDetail.self,
            from: Data(#"{"content_id": "movie:1", "type": "movie", "title": "Movie"}"#.utf8)
        )
        let session = PlaybackSessionResponse(
            sessionId: "11111111-1111-4111-8111-111111111111",
            userId: nil,
            profileId: nil,
            mediaFileId: 42,
            playMethod: "direct",
            position: 0,
            isPaused: false,
            streamUrl: "/stream/11111111-1111-4111-8111-111111111111",
            audioTrackIndex: nil,
            durationSeconds: 100,
            subtitleUrls: nil,
            playbackInfo: nil
        )
        return PreparedPlayback(
            watchDetail: watchDetail,
            selectedVersion: version,
            session: session,
            protocolV3: PreparedPlaybackV3(
                playbackAttemptId: "apple:test",
                planAttemptId: "apple-plan:test",
                planAttemptKey: "key",
                outputContextId: nil,
                serverFeatures: [],
                plan: v3Plan
            )
        )
    }
}
